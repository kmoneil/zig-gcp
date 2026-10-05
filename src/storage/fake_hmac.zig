//! HMAC keys for `FakeMultipart`, kept by the rules Cloud Storage was
//! measured keeping them by on 2026-10-05, in its own words. Test code
//! only. The storage testbench has the calls, but with other access IDs,
//! secrets and kinds, and drops deleted keys at once; fake-gcs-server has
//! none.
//!
//! - A key is made ACTIVE for an account of the project, with a 61-
//!   character access ID and a 40-character secret; an account holds at
//!   most 10 that are not deleted.
//! - Only ACTIVE and INACTIVE are set, in upper case; a change to the
//!   state the key has is refused, as is a stale etag, checked first.
//! - Only an INACTIVE key is deleted; a deleted one is still read, and
//!   listed with `showDeletedKeys`, and a second delete is refused.
//! - Not modelled: the minutes a state change takes to reach signatures,
//!   and when a deleted key is finally forgotten.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Method = @import("core").transport.Method;

pub const FakeHmacKeys = struct {
    arena: std.heap.ArenaAllocator,
    keys: std.ArrayListUnmanaged(Key) = .empty,
    /// The project the keys live in.
    project: []const u8 = "extractctl",
    /// The project's service accounts, which may hold keys.
    accounts: []const []const u8 = &.{ "zig-gcp@extractctl.iam.gserviceaccount.com", "zigps-hmac@extractctl.iam.gserviceaccount.com" },
    counts: Counts = .{},

    pub const Counts = struct { creates: u32 = 0, reads: u32 = 0, updates: u32 = 0, deletes: u32 = 0 };

    pub const State = enum { ACTIVE, INACTIVE, DELETED };

    pub const Key = struct {
        access_id: []const u8,
        email: []const u8,
        state: State = .ACTIVE,
        /// Moved by every change; the etag is its base64.
        version: u32 = 1,
    };

    /// What a `.../projects/{project}/hmacKeys` URL names.
    pub const Target = struct {
        project: []const u8,
        /// Null for the collection.
        access_id: ?[]const u8 = null,
        service_account_email: ?[]const u8 = null,
        show_deleted: bool = false,
        max_results: u32 = 0,
        page_token: ?[]const u8 = null,
    };

    pub const Reply = struct { status: u16, body: []const u8 = "" };

    pub fn init(gpa: Allocator) FakeHmacKeys {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *FakeHmacKeys) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The key as kept, or null.
    pub fn key(self: *const FakeHmacKeys, access_id: []const u8) ?Key {
        for (self.keys.items) |k| if (std.mem.eql(u8, k.access_id, access_id)) return k;
        return null;
    }

    /// One request. A method this fake does not serve fails the test.
    pub fn serve(self: *FakeHmacKeys, method: Method, target: Target, body: []const u8, arena: Allocator) error{ HttpProtocolError, OutOfMemory }!Reply {
        if (!std.mem.eql(u8, target.project, self.project)) {
            return refusal(arena, 404, "notFound", try arena.print("Project '{s}' not found.", .{target.project}));
        }
        const access_id = target.access_id orelse return switch (method) {
            .POST => self.create(target, arena),
            .GET => self.list(target, arena),
            else => error.HttpProtocolError,
        };
        const k = for (self.keys.items) |*k| {
            if (std.mem.eql(u8, k.access_id, access_id)) break k;
        } else return refusal(arena, 404, "notFound", "Access ID not found in project.");
        return switch (method) {
            .GET => {
                self.counts.reads += 1;
                return .{ .status = 200, .body = try metadataJson(arena, self.project, k.*) };
            },
            .PUT => self.update(k, body, arena),
            .DELETE => {
                self.counts.deletes += 1;
                return switch (k.state) {
                    .ACTIVE => refusal(arena, 400, "invalid", "Cannot delete keys in ACTIVE state.  Update state to 'INACTIVE' first."),
                    .DELETED => refusal(arena, 400, "invalid", "Key is already deleted."),
                    .INACTIVE => {
                        k.state = .DELETED;
                        k.version += 1;
                        return .{ .status = 204 };
                    },
                };
            },
            else => error.HttpProtocolError,
        };
    }

    fn create(self: *FakeHmacKeys, target: Target, arena: Allocator) Allocator.Error!Reply {
        self.counts.creates += 1;
        const email = target.service_account_email orelse return refusal(arena, 400, "required", "Required parameter: serviceAccountEmail");
        if (std.mem.indexOfScalar(u8, email, '@') == null) return refusal(arena, 400, "invalid", "Invalid argument.");
        if (std.mem.endsWith(u8, email, "@gs-project-accounts.iam.gserviceaccount.com")) {
            return refusal(arena, 403, "forbidden", try arena.print("The service account {s} is not in the project.", .{email}));
        }
        if (!self.isAccount(email)) return refusal(arena, 404, "notFound", try arena.print("Service Account '{s}' not found.", .{email}));
        var live: usize = 0;
        for (self.keys.items) |k| {
            if (std.mem.eql(u8, k.email, email) and k.state != .DELETED) live += 1;
        }
        if (live >= 10) return refusal(arena, 400, "invalid", "Service account HMAC key limit reached");
        const a = self.arena.allocator();
        const n = self.keys.items.len + 1;
        // `GOOG1E` and 55 upper-case letters and digits, as production's.
        var id: [61]u8 = undefined;
        @memcpy(id[0..6], "GOOG1E");
        for (id[6..], 0..) |*c, i| c.* = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"[(n * 7 + i * 13) % 32];
        const made: Key = .{ .access_id = try a.dupe(u8, &id), .email = try a.dupe(u8, email) };
        try self.keys.append(a, made);
        // 40 characters of base64, `+` and `/` among them.
        var secret: [40]u8 = undefined;
        for (&secret, 0..) |*c, i| c.* = std.base64.standard_alphabet_chars[(n * 11 + i * 5) % 64];
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: std.json.Stringify = .{ .writer = &out.writer };
        jw.beginObject() catch return error.OutOfMemory;
        jw.objectField("kind") catch return error.OutOfMemory;
        jw.write("storage#hmacKey") catch return error.OutOfMemory;
        jw.objectField("metadata") catch return error.OutOfMemory;
        jw.print("{s}", .{try metadataJson(arena, self.project, made)}) catch return error.OutOfMemory;
        jw.objectField("secret") catch return error.OutOfMemory;
        jw.write(@as([]const u8, &secret)) catch return error.OutOfMemory;
        jw.endObject() catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn list(self: *FakeHmacKeys, target: Target, arena: Allocator) Allocator.Error!Reply {
        self.counts.reads += 1;
        if (target.service_account_email) |email| if (!self.isAccount(email)) {
            return refusal(arena, 404, "notFound", try arena.print("Service Account '{s}' not found.", .{email}));
        };
        var shown: std.ArrayList(Key) = .empty;
        for (self.keys.items) |k| {
            if (k.state == .DELETED and !target.show_deleted) continue;
            if (target.service_account_email) |email| if (!std.mem.eql(u8, k.email, email)) continue;
            try shown.append(arena, k);
        }
        const start = if (target.page_token) |t| std.fmt.parseInt(usize, t, 10) catch 0 else 0;
        const size = if (target.max_results == 0) 250 else @min(target.max_results, 250);
        const from = @min(start, shown.items.len);
        const to = @min(from + size, shown.items.len);
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        w.writeAll("{\"kind\":\"storage#hmacKeysMetadata\"") catch return error.OutOfMemory;
        if (to > from) {
            w.writeAll(",\"items\":[") catch return error.OutOfMemory;
            for (shown.items[from..to], 0..) |k, i| {
                if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
                w.writeAll(try metadataJson(arena, self.project, k)) catch return error.OutOfMemory;
            }
            w.writeByte(']') catch return error.OutOfMemory;
        }
        if (to < shown.items.len) w.print(",\"nextPageToken\":\"{d}\"", .{to}) catch return error.OutOfMemory;
        w.writeByte('}') catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    }

    fn update(self: *FakeHmacKeys, k: *Key, body: []const u8, arena: Allocator) Allocator.Error!Reply {
        self.counts.updates += 1;
        const Wire = struct { state: ?[]const u8 = null, etag: ?[]const u8 = null, accessId: ?[]const u8 = null };
        const wire = std.json.parseFromSliceLeaky(Wire, arena, body, .{ .ignore_unknown_fields = true }) catch
            return refusal(arena, 400, "invalid", "Invalid JSON payload.");
        if (wire.accessId) |id| if (!std.mem.eql(u8, id, k.access_id)) {
            return refusal(arena, 400, "invalid", "The accessId supplied in request body does not match the accessId in the URL.");
        };
        if (k.state == .DELETED) return refusal(arena, 400, "invalid", "Deleted keys cannot be updated.");
        if (wire.etag) |etag| if (!std.mem.eql(u8, etag, try etagOf(arena, k.*))) {
            return refusal(arena, 412, "conditionNotMet", "Cannot update keys. Etag does not match expected value.");
        };
        const text = wire.state orelse return refusal(arena, 400, "invalid", "Must specify resource.state.");
        const next: State = if (std.mem.eql(u8, text, "ACTIVE"))
            .ACTIVE
        else if (std.mem.eql(u8, text, "INACTIVE"))
            .INACTIVE
        else if (std.mem.eql(u8, text, "DELETED"))
            return refusal(arena, 400, "invalid", "Cannot set state to 'DELETED'.")
        else
            return refusal(arena, 400, "invalid", "Must specify resource.state.");
        if (next == k.state) return refusal(arena, 400, "invalid", "Update must modify the credential.");
        k.state = next;
        k.version += 1;
        return .{ .status = 200, .body = try metadataJson(arena, self.project, k.*) };
    }

    fn isAccount(self: *const FakeHmacKeys, email: []const u8) bool {
        for (self.accounts) |a| if (std.mem.eql(u8, a, email)) return true;
        return false;
    }
};

fn etagOf(arena: Allocator, k: FakeHmacKeys.Key) Allocator.Error![]const u8 {
    const hex = try arena.print("{x:0>8}", .{k.version});
    const out = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(hex.len));
    return std.base64.standard.Encoder.encode(out, hex);
}

fn metadataJson(arena: Allocator, project: []const u8, k: FakeHmacKeys.Key) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    jw.write(.{
        .kind = "storage#hmacKeyMetadata",
        .id = try arena.print("{s}/{s}", .{ project, k.access_id }),
        .accessId = k.access_id,
        .projectId = project,
        .serviceAccountEmail = k.email,
        .state = @tagName(k.state),
        .timeCreated = "2026-10-05T15:36:10.539Z",
        .updated = if (k.version == 1) "2026-10-05T15:36:10.539Z" else "2026-10-05T15:36:18.112Z",
        .etag = try etagOf(arena, k),
    }) catch return error.OutOfMemory;
    return out.written();
}

fn refusal(arena: Allocator, status: u16, reason: []const u8, message: []const u8) Allocator.Error!FakeHmacKeys.Reply {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    jw.write(.{ .@"error" = .{ .code = status, .message = message, .errors = &[_]struct { message: []const u8, domain: []const u8, reason: []const u8 }{.{ .message = message, .domain = "global", .reason = reason }} } }) catch return error.OutOfMemory;
    return .{ .status = status, .body = out.written() };
}
