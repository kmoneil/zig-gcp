//! A Secret Manager for tests, behind the `Transport` seam: secrets, their
//! settings and versions, global and regional, kept as production keeps
//! them and refused as production refuses, as measured on 2026-10-02
//! (`_tmp/secrets-fill/production-s.md`). It is written from what
//! production did, not from this library's encoder, so a body or mask the
//! encoder gets wrong is refused or misapplied here as production would.
//! Test code only.
//!
//! What it models:
//!
//! - `secrets.patch` needs `updateMask` ("Field [update_mask] is
//!   required."); an empty one changes nothing but the etag. Paths in
//!   snake_case or lowerCamelCase; `*`, unknown paths and map keys
//!   (`labels.team`) are 400 "Request contains an invalid argument.";
//!   `name`, `create_time` and `tags` are ignored; `secret_type` and
//!   `policy_member` are immutable. A path the body leaves out clears its
//!   field, a body field outside the mask is ignored, a map is replaced
//!   whole, and a refused patch changes nothing.
//! - Etags: every write moves its own resource's etag, a no-op included;
//!   a version's changes and `addVersion` leave the secret's alone. A body
//!   or query etag that is not `""` and not the current one is the 400
//!   `FAILED_PRECONDITION` "The etag provided in the request does not
//!   match ...", checked after a 404 and before anything else.
//! - Labels (64; keys `[\p{Ll}\p{Lo}][\p{Ll}\p{Lo}\p{N}_-]{0,62}`, values
//!   `[\p{Ll}\p{Lo}\p{N}_-]{0,63}`, each at most 128 bytes; any non-ASCII
//!   character counts as a lowercase letter here), annotations (keys of 1
//!   to 64 ASCII alphanumerics with `.`, `_`, `-` inside; 16,384 bytes in
//!   all), aliases (50; names `[a-zA-Z][a-zA-Z0-9_-]*` up to 63, never
//!   `latest` or `NEW` exactly; versions that exist, destroyed included;
//!   `"01"` read as 1), expiry (`ttl` or `expireTime`, never both, 60 s to
//!   876,000 h ahead of `now_s`) and the destruction delay (86,400 to
//!   86,400,000 s), each refused in production's words.
//! - Versions: `latest` is the newest; aliases are case-sensitive, and an
//!   unknown one is 404 "Secret [...] has no alias [x]"; enable, disable
//!   and destroy take numbers only. With a delay, destroy leaves a version
//!   `DISABLED` with `scheduledDestroyTime`, a second destroy is "already
//!   scheduled for DESTRUCTION.", and enable or disable cancels; without
//!   one it is `DESTROYED` at once. Access to a version that is not
//!   enabled is "... is in DISABLED state." (or DESTROYED).
//!
//! - Topics (2026-10-02): at most 10 ("No more than 10 topics can be
//!   configured on a secret."), distinct ("Topics must have distinct
//!   names."), each `projects/P/topics/T` or "Failed to Publish to topic
//!   [NAME], got an error from Pub/Sub."; then each is published to, as
//!   production does before judging anything else, so a topic `setTopic`
//!   names missing is 404 "Topic [NAME] not found." and one it names
//!   unpublishable the 400 `FAILED_PRECONDITION` naming
//!   `pubsub.topics.publish`. Checked on create and on a patch whose mask
//!   names `topics`, never otherwise. A list sent as one object is a list
//!   of one.
//! - Rotation: needs topics ("There must be at least one topic configured
//!   when a Rotation policy is set."), a time 5 minutes to 876,000 hours
//!   ahead, a period of at least an hour, and a time whenever there is a
//!   period (a 400 `FAILED_PRECONDITION`, the one refusal of its kind);
//!   masks `rotation`, `rotation.next_rotation_time` and
//!   `rotation.rotation_period`. `fireRotation` does what production did
//!   when one came due: advance the time by the period, or, without one,
//!   remove the rotation; and move the etag.
//!
//! Not modelled yet: customer-managed keys (501), list filters and paging,
//! expiry actually deleting a secret, a scheduled destruction coming due,
//! publishing events.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const core = @import("core");
const tp = core.transport;

pub const FakeSecrets = struct {
    gpa: Allocator,
    /// Holds everything stored. Replaced maps stay in it until `deinit`.
    store: std.heap.ArenaAllocator,
    /// By location (`""` for global) and id.
    secrets: std.StringArrayHashMapUnmanaged(*Stored) = .empty,
    next_etag: u64 = 0x165cdb26000000,
    /// The server's clock, in seconds since the epoch: 2026-10-02T13:00:00Z.
    now_s: i64 = 1_790_946_000,
    /// Production answers names with the project number.
    project_number: []const u8 = "82150720798",
    /// Requests served, by every route.
    requests: u32 = 0,
    /// Topics Secret Manager could not publish to; any other is fine.
    topic_states: std.StringHashMapUnmanaged(TopicState) = .empty,

    pub const TopicState = enum { missing, unpublishable };

    pub const Reply = struct { status: u16, body: []const u8 };

    const Map = std.StringArrayHashMapUnmanaged([]const u8);
    const Aliases = std.StringArrayHashMapUnmanaged(u64);

    const Stored = struct {
        name: []const u8,
        create_s: i64,
        etag: u64,
        /// The replication as created, echoed back; null for regional.
        replication: ?[]const u8,
        labels: Map = .empty,
        annotations: Map = .empty,
        aliases: Aliases = .empty,
        expire_s: ?i64 = null,
        delay_s: ?u64 = null,
        topics: []const []const u8 = &.{},
        rotation_next_s: ?i64 = null,
        rotation_period_s: ?u64 = null,
        versions: std.ArrayListUnmanaged(StoredVersion) = .empty,
    };

    const State = enum { ENABLED, DISABLED, DESTROYED };

    const StoredVersion = struct {
        etag: u64,
        state: State,
        data: []const u8,
        create_s: i64,
        scheduled_s: ?i64 = null,
        destroy_s: ?i64 = null,
    };

    pub fn init(gpa: Allocator) FakeSecrets {
        return .{ .gpa = gpa, .store = .init(gpa) };
    }

    pub fn deinit(self: *FakeSecrets) void {
        self.store.deinit();
        self.* = undefined;
    }

    pub fn transport(self: *FakeSecrets) tp.Transport {
        return .{ .ptr = self, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, req: tp.Request, arena: Allocator) tp.Error!tp.Response {
        const self: *FakeSecrets = @ptrCast(@alignCast(ptr));
        const reply = self.serve(req.method, req.url, req.body orelse "", arena) catch return error.OutOfMemory;
        return .{ .status = reply.status, .body = reply.body };
    }

    /// Makes `topic` (`projects/P/topics/T`) one Secret Manager cannot
    /// publish to.
    pub fn setTopic(self: *FakeSecrets, topic: []const u8, state: TopicState) Allocator.Error!void {
        const a = self.store.allocator();
        try self.topic_states.put(a, try a.dupe(u8, topic), state);
    }

    /// What production did when a rotation came due: the next time moves on
    /// by the period, or a rotation without one is removed; the etag moves.
    pub fn fireRotation(self: *FakeSecrets, location: ?[]const u8, id: []const u8) void {
        var buf: [320]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}|{s}", .{ location orelse "", id }) catch return;
        const s = self.secrets.get(key) orelse return;
        const next = s.rotation_next_s orelse return;
        if (s.rotation_period_s) |p| {
            s.rotation_next_s = next + @as(i64, @intCast(p));
        } else {
            s.rotation_next_s = null;
        }
        s.etag = self.etag();
    }

    /// A secret as stored, for tests to inspect; null when there is none.
    pub fn secret(self: *const FakeSecrets, location: ?[]const u8, id: []const u8) ?*const Stored {
        var buf: [320]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}|{s}", .{ location orelse "", id }) catch return null;
        return self.secrets.get(key);
    }

    /// Answers one request.
    pub fn serve(self: *FakeSecrets, method: tp.Method, url: []const u8, body: []const u8, arena: Allocator) Allocator.Error!Reply {
        self.requests += 1;
        const target = parseUrl(arena, url) catch return fail(arena, 404, "NOT_FOUND", "fake: no such route");
        if (target.secret_id == null) {
            if (method == .POST) return self.create(target, body, arena);
            return fail(arena, 501, "UNIMPLEMENTED", "fake: listing secrets is not modelled");
        }
        const id = target.secret_id.?;
        const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ target.location orelse "", id });
        const s = self.secrets.get(key) orelse {
            const name = try self.secretName(arena, target.location, id);
            return fail(arena, 404, "NOT_FOUND", try std.fmt.allocPrint(arena, "Secret [{s}] not found.", .{name}));
        };
        if (target.versions) {
            return self.version(s, target, method, body, arena);
        }
        if (target.verb) |verb| {
            if (std.mem.eql(u8, verb, "addVersion") and method == .POST) return self.addVersion(s, body, arena);
            return fail(arena, 501, "UNIMPLEMENTED", "fake: no such secret method");
        }
        return switch (method) {
            .GET => .{ .status = 200, .body = try self.secretJson(arena, s) },
            .PATCH => self.patch(s, target, body, arena),
            .DELETE => self.delete(s, key, target, arena),
            else => fail(arena, 501, "UNIMPLEMENTED", "fake: no such secret method"),
        };
    }

    fn create(self: *FakeSecrets, target: Target, body: []const u8, arena: Allocator) Allocator.Error!Reply {
        const id = target.query_secret_id orelse return fail(arena, 400, "INVALID_ARGUMENT", "Secret ID must be provided.");
        const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ target.location orelse "", id });
        const name = try self.secretName(arena, target.location, id);
        if (self.secrets.contains(key)) {
            return fail(arena, 409, "ALREADY_EXISTS", try std.fmt.allocPrint(arena, "Secret [{s}] already exists.", .{name}));
        }
        const fields = switch (try parseBody(arena, body)) {
            .ok => |f| f,
            .refused => |r| return r,
        };
        var draft: Draft = .{};
        if (fields.replication) |r| {
            if (target.location != null) return fail(arena, 400, "INVALID_ARGUMENT", "Secret.replication should not be provided.");
            draft.replication = try Stringify.valueAlloc(arena, r, .{});
        } else if (target.location == null) {
            return fail(arena, 400, "INVALID_ARGUMENT", "Secret.replication must be provided.");
        }
        if (fields.unsupported) |what| return unsupported(arena, what);
        if (fields.topics) |v| {
            draft.topics = switch (try self.readTopics(arena, v)) {
                .ok => |t| t,
                .refused => |r| return r,
            };
            draft.rotation_changed = true;
        }
        if (fields.rotation) |v| {
            if (try readRotation(arena, v, &draft, true, true)) |refused| return refused;
        }
        if (fields.labels) |v| draft.labels = switch (try readMap(arena, v, "labels")) {
            .ok => |m| m,
            .refused => |r| return r,
        };
        if (fields.annotations) |v| draft.annotations = switch (try readMap(arena, v, "annotations")) {
            .ok => |m| m,
            .refused => |r| return r,
        };
        if (fields.aliases != null) return fail(arena, 400, "INVALID_ARGUMENT", "Aliases cannot be assigned to versions that don't exist");
        if (try self.readExpiry(arena, fields)) |refused| return refused;
        draft.expire_s = fields.expire_s;
        if (fields.delay) |text| draft.delay_s = switch (try readDelay(arena, text)) {
            .ok => |d| d,
            .refused => |r| return r,
        };
        if (try self.checkDraft(arena, draft, 0)) |refused| return refused;

        const a = self.store.allocator();
        const stored = try a.create(Stored);
        stored.* = .{
            .name = try a.dupe(u8, name),
            .create_s = self.now_s,
            .etag = self.etag(),
            .replication = if (draft.replication) |r| try a.dupe(u8, r) else null,
        };
        try self.commit(stored, draft);
        try self.secrets.put(a, try a.dupe(u8, key), stored);
        return .{ .status = 200, .body = try self.secretJson(arena, stored) };
    }

    fn patch(self: *FakeSecrets, s: *Stored, target: Target, body: []const u8, arena: Allocator) Allocator.Error!Reply {
        const mask = target.update_mask orelse return fail(arena, 400, "INVALID_ARGUMENT", "Field [update_mask] is required.");
        const fields = switch (try parseBody(arena, body)) {
            .ok => |f| f,
            .refused => |r| return r,
        };
        if (fields.etag) |e| if (e.len > 0 and !try self.etagMatches(arena, s.etag, e)) return stale(arena);

        var draft: Draft = .{
            .labels = s.labels,
            .annotations = s.annotations,
            .aliases = s.aliases,
            .expire_s = s.expire_s,
            .delay_s = s.delay_s,
            .topics = s.topics,
            .rotation_next_s = s.rotation_next_s,
            .rotation_period_s = s.rotation_period_s,
        };
        // Production publishes to every topic a patch names before it
        // judges anything else.
        if (std.mem.indexOf(u8, mask, "topics") != null) {
            draft.topics = if (fields.topics) |v| switch (try self.readTopics(arena, v)) {
                .ok => |t| t,
                .refused => |r| return r,
            } else &.{};
        }
        var paths = std.mem.splitScalar(u8, mask, ',');
        while (paths.next()) |raw| {
            if (raw.len == 0 and mask.len == 0) break;
            const path = canonicalPath(raw) orelse return invalidArgument(arena);
            switch (path) {
                .ignored => {},
                .immutable => |field| return fail(
                    arena,
                    400,
                    "INVALID_ARGUMENT",
                    try std.fmt.allocPrint(arena, "Field '{s}' is immutable and cannot be updated.", .{field}),
                ),
                .replication => {
                    if (s.replication == null) return fail(arena, 400, "INVALID_ARGUMENT", "Field mask paths starting with \"replication\" are not supported in updates of regional secret.");
                    const sent = fields.replication orelse return invalidArgument(arena);
                    const text = try Stringify.valueAlloc(arena, sent, .{});
                    if (!std.mem.eql(u8, text, s.replication.?)) return fail(arena, 400, "INVALID_ARGUMENT", "Existing secret has automatic replication, but requested secret does not. Updating secret replication is not supported.");
                },
                .unsupported => |what| return unsupported(arena, what),
                .labels => draft.labels = if (fields.labels) |v| switch (try readMap(arena, v, "labels")) {
                    .ok => |m| m,
                    .refused => |r| return r,
                } else .empty,
                .annotations => draft.annotations = if (fields.annotations) |v| switch (try readMap(arena, v, "annotations")) {
                    .ok => |m| m,
                    .refused => |r| return r,
                } else .empty,
                .aliases => draft.aliases = if (fields.aliases) |v| switch (try readAliases(arena, v)) {
                    .ok => |m| m,
                    .refused => |r| return r,
                } else .empty,
                .expire_time, .ttl => {
                    if (try self.readExpiry(arena, fields)) |refused| return refused;
                    draft.expire_s = fields.expire_s;
                },
                .delay => draft.delay_s = if (fields.delay) |text| switch (try readDelay(arena, text)) {
                    .ok => |d| d,
                    .refused => |r| return r,
                } else null,
                .topics => draft.rotation_changed = true,
                .rotation, .rotation_next, .rotation_period => {
                    const whole = path == .rotation;
                    if (fields.rotation) |v| {
                        if (try readRotation(arena, v, &draft, whole or path == .rotation_next, whole or path == .rotation_period)) |refused| return refused;
                    } else {
                        if (whole or path == .rotation_next) draft.rotation_next_s = null;
                        if (whole or path == .rotation_period) draft.rotation_period_s = null;
                        draft.rotation_changed = true;
                    }
                },
            }
        }
        if (try self.checkDraft(arena, draft, s.versions.items.len)) |refused| return refused;
        try self.commit(s, draft);
        s.etag = self.etag();
        return .{ .status = 200, .body = try self.secretJson(arena, s) };
    }

    fn delete(self: *FakeSecrets, s: *Stored, key: []const u8, target: Target, arena: Allocator) Allocator.Error!Reply {
        if (target.query_etag) |e| if (e.len > 0 and !try self.etagMatches(arena, s.etag, e)) return stale(arena);
        _ = self.secrets.orderedRemove(key);
        return .{ .status = 200, .body = "{}" };
    }

    fn addVersion(self: *FakeSecrets, s: *Stored, body: []const u8, arena: Allocator) Allocator.Error!Reply {
        const parsed = std.json.parseFromSliceLeaky(struct {
            payload: struct { data: []const u8 = "", dataCrc32c: ?[]const u8 = null } = .{},
        }, arena, body, .{ .ignore_unknown_fields = true }) catch return invalidArgument(arena);
        const data = core.base64.decode(arena, parsed.payload.data) catch return invalidArgument(arena);
        if (data.len == 0) return fail(arena, 400, "INVALID_ARGUMENT", "SecretPayload.data must not be empty.");
        if (parsed.payload.dataCrc32c) |sum| {
            const want = std.fmt.parseInt(u32, sum, 10) catch return invalidArgument(arena);
            if (core.crc32c.hash(data) != want) return fail(arena, 400, "INVALID_ARGUMENT", "Provided SecretPayload.data crc32c does not match calculated crc32c.");
        }
        const a = self.store.allocator();
        try s.versions.append(a, .{ .etag = self.etag(), .state = .ENABLED, .data = try a.dupe(u8, data), .create_s = self.now_s });
        return .{ .status = 200, .body = try self.versionJson(arena, s, s.versions.items.len) };
    }

    fn version(self: *FakeSecrets, s: *Stored, target: Target, method: tp.Method, body: []const u8, arena: Allocator) Allocator.Error!Reply {
        const ref = target.version_ref orelse {
            if (method != .GET) return fail(arena, 501, "UNIMPLEMENTED", "fake: no such versions method");
            var parts: std.ArrayListUnmanaged([]const u8) = .empty;
            var n = s.versions.items.len;
            while (n > 0) : (n -= 1) try parts.append(arena, try self.versionJson(arena, s, n));
            const joined = try std.mem.join(arena, ",", parts.items);
            return .{ .status = 200, .body = try std.fmt.allocPrint(arena, "{{\"versions\":[{s}],\"totalSize\":{d}}}", .{ joined, s.versions.items.len }) };
        };
        const as_number = std.fmt.parseInt(u64, ref, 10) catch null;
        if (target.verb) |verb| {
            if (std.mem.eql(u8, verb, "access") and method == .GET) {
                const resolved = try self.resolve(arena, s, ref);
                const n = resolved.ok orelse return resolved.refused.?;
                const v = s.versions.items[n - 1];
                if (v.state != .ENABLED) return fail(
                    arena,
                    400,
                    "FAILED_PRECONDITION",
                    try std.fmt.allocPrint(arena, "Secret Version [{s}/versions/{d}] is in {t} state.", .{ s.name, n, v.state }),
                );
                var out: std.Io.Writer.Allocating = .init(arena);
                var jw: Stringify = .{ .writer = &out.writer };
                jw.write(.{
                    .name = try std.fmt.allocPrint(arena, "{s}/versions/{d}", .{ s.name, n }),
                    .payload = .{
                        .data = try encodeBase64(arena, v.data),
                        .dataCrc32c = try std.fmt.allocPrint(arena, "{d}", .{core.crc32c.hash(v.data)}),
                    },
                }) catch return error.OutOfMemory;
                return .{ .status = 200, .body = try out.toOwnedSlice() };
            }
            if (method != .POST) return fail(arena, 501, "UNIMPLEMENTED", "fake: no such version method");
            const n = as_number orelse return fail(
                arena,
                400,
                "INVALID_ARGUMENT",
                try std.fmt.allocPrint(arena, "The provided Secret Version ID [{s}/versions/{s}] does not match the expected format [projects/*/secrets/*/versions*]", .{ s.name, ref }),
            );
            if (n == 0 or n > s.versions.items.len) return fail(
                arena,
                404,
                "NOT_FOUND",
                try std.fmt.allocPrint(arena, "Secret Version [{s}/versions/{d}] not found.", .{ s.name, n }),
            );
            const v = &s.versions.items[n - 1];
            const parsed = std.json.parseFromSliceLeaky(struct { etag: []const u8 = "" }, arena, if (body.len == 0) "{}" else body, .{ .ignore_unknown_fields = true }) catch return invalidArgument(arena);
            if (parsed.etag.len > 0 and !try self.etagMatches(arena, v.etag, parsed.etag)) return stale(arena);
            if (std.mem.eql(u8, verb, "destroy")) {
                if (v.state == .DESTROYED) return fail(arena, 400, "FAILED_PRECONDITION", "SecretVersion.state is already DESTROYED");
                if (v.scheduled_s != null) return fail(arena, 400, "FAILED_PRECONDITION", "SecretVersion is already scheduled for DESTRUCTION.");
                if (s.delay_s) |d| {
                    v.state = .DISABLED;
                    v.scheduled_s = self.now_s + @as(i64, @intCast(d));
                } else {
                    v.state = .DESTROYED;
                    v.destroy_s = self.now_s;
                    v.data = "";
                }
            } else if (std.mem.eql(u8, verb, "enable") or std.mem.eql(u8, verb, "disable")) {
                if (v.state == .DESTROYED) return fail(arena, 400, "FAILED_PRECONDITION", "SecretVersion.state is already DESTROYED");
                v.state = if (verb[0] == 'e') .ENABLED else .DISABLED;
                v.scheduled_s = null;
            } else return fail(arena, 501, "UNIMPLEMENTED", "fake: no such version method");
            v.etag = self.etag();
            return .{ .status = 200, .body = try self.versionJson(arena, s, n) };
        }
        if (method != .GET) return fail(arena, 501, "UNIMPLEMENTED", "fake: no such version method");
        const resolved = try self.resolve(arena, s, ref);
        const n = resolved.ok orelse return resolved.refused.?;
        return .{ .status = 200, .body = try self.versionJson(arena, s, n) };
    }

    const Resolved = struct { ok: ?usize = null, refused: ?Reply = null };

    /// A version reference as production reads it: a number, `latest` (the
    /// newest), or an alias, case and all.
    fn resolve(self: *FakeSecrets, arena: Allocator, s: *Stored, ref: []const u8) Allocator.Error!Resolved {
        _ = self;
        if (std.fmt.parseInt(u64, ref, 10)) |n| {
            if (n == 0 or n > s.versions.items.len) return .{ .refused = try fail(
                arena,
                404,
                "NOT_FOUND",
                try std.fmt.allocPrint(arena, "Secret Version [{s}/versions/{d}] not found.", .{ s.name, n }),
            ) };
            return .{ .ok = n };
        } else |_| {}
        if (std.mem.eql(u8, ref, "latest")) {
            if (s.versions.items.len == 0) return .{ .refused = try fail(
                arena,
                404,
                "NOT_FOUND",
                try std.fmt.allocPrint(arena, "Secret Version [{s}/versions/latest] not found.", .{s.name}),
            ) };
            return .{ .ok = s.versions.items.len };
        }
        const n = s.aliases.get(ref) orelse return .{ .refused = try fail(
            arena,
            404,
            "NOT_FOUND",
            try std.fmt.allocPrint(arena, "Secret [{s}] has no alias [{s}]", .{ s.name, ref }),
        ) };
        return .{ .ok = n };
    }

    // Settings

    /// What a create or patch would leave, before it is committed.
    const Draft = struct {
        replication: ?[]const u8 = null,
        labels: Map = .empty,
        annotations: Map = .empty,
        aliases: Aliases = .empty,
        expire_s: ?i64 = null,
        delay_s: ?u64 = null,
        topics: []const []const u8 = &.{},
        rotation_next_s: ?i64 = null,
        rotation_period_s: ?u64 = null,
        /// Whether this request set the rotation's time, so its bounds are
        /// judged, or anything a rotation depends on.
        rotation_changed: bool = false,
        next_sent: bool = false,
        period_sent: ?u64 = null,
    };

    fn commit(self: *FakeSecrets, s: *Stored, draft: Draft) Allocator.Error!void {
        const a = self.store.allocator();
        s.labels = try copyMap(a, draft.labels);
        s.annotations = try copyMap(a, draft.annotations);
        s.aliases = .empty;
        for (draft.aliases.keys(), draft.aliases.values()) |k, v| try s.aliases.put(a, try a.dupe(u8, k), v);
        s.expire_s = draft.expire_s;
        s.delay_s = draft.delay_s;
        const topics = try a.alloc([]const u8, draft.topics.len);
        for (draft.topics, topics) |t, *copy| copy.* = try a.dupe(u8, t);
        s.topics = topics;
        s.rotation_next_s = draft.rotation_next_s;
        s.rotation_period_s = draft.rotation_period_s;
    }

    /// The rules production holds a secret's settings to, judged on the
    /// whole result, as production judges them.
    fn checkDraft(self: *FakeSecrets, arena: Allocator, draft: Draft, versions: usize) Allocator.Error!?Reply {
        if (draft.rotation_next_s != null or draft.rotation_period_s != null) {
            if (draft.topics.len == 0) return try fail(arena, 400, "INVALID_ARGUMENT", "There must be at least one topic configured when a Rotation policy is set.");
            if (draft.rotation_next_s == null) return try fail(arena, 400, "FAILED_PRECONDITION", "Next rotation time must be set while the rotation period is set.");
        }
        if (draft.next_sent) {
            const next = draft.rotation_next_s.?;
            if (next < self.now_s + 300) return try fail(arena, 400, "INVALID_ARGUMENT", "Next rotation time must be at least [5m] in the future.");
            if (next > self.now_s + 876_000 * 3600) return try fail(arena, 400, "INVALID_ARGUMENT", "Next rotation time cannot be more than [876000h] from now.");
        }
        if (draft.period_sent) |p| {
            if (p < 3600) return try fail(arena, 400, "INVALID_ARGUMENT", "Rotation period cannot be shorter than [1h].");
        }
        if (draft.labels.count() > 64) return try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(
            arena,
            "Invalid field \"labels\"; at most 64 entries allowed but found {d}",
            .{draft.labels.count()},
        ));
        for (draft.labels.keys(), draft.labels.values()) |k, v| {
            if (labelProblem(k, true)) |p| return try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid field \"labels\"; key \"{s}\" {s}", .{ k, p }));
            if (labelProblem(v, false)) |p| return try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(arena, "Invalid field \"labels.{s}\"; value \"{s}\" {s}", .{ k, v, p }));
        }
        var total: usize = 0;
        for (draft.annotations.keys(), draft.annotations.values()) |k, v| {
            if (!annotationKey(k)) return try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(
                arena,
                "[{s}] must follow pattern [a-z0-9A-Z]+([_\\.\\-]*[a-z0-9A-Z]+)*), be less than 64 characters, and must have a UTF encoding of less than 128 bytes",
                .{k},
            ));
            total += k.len + v.len;
        }
        if (total > 16 * 1024) return try fail(arena, 400, "INVALID_ARGUMENT", "Annotation map must not exceed 16kib.");
        if (draft.aliases.count() > 50) return try fail(arena, 400, "INVALID_ARGUMENT", "No more than 50 aliases can be assgined to any given secret");
        for (draft.aliases.keys(), draft.aliases.values()) |k, v| {
            if (!aliasName(k)) return try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(
                arena,
                "[{s}] must follow pattern [a-zA-Z][a-Aa-Z0-9_-]+, be less than 64 characters and cannot be \"latest\" or \"NEW\"",
                .{k},
            ));
            if (v == 0 or v > versions) return try fail(arena, 400, "INVALID_ARGUMENT", "Aliases cannot be assigned to versions that don't exist");
        }
        return null;
    }

    fn readExpiry(self: *FakeSecrets, arena: Allocator, fields: *Fields) Allocator.Error!?Reply {
        if (fields.ttl != null and fields.expire_time != null) return try fail(
            arena,
            400,
            "INVALID_ARGUMENT",
            "Invalid value at 'secret' (oneof), oneof field 'expiration' is already set. Cannot set 'expireTime'",
        );
        fields.expire_s = null;
        if (fields.ttl) |text| {
            const d = core.duration.parse(text) catch return try invalidArgument(arena);
            fields.expire_s = self.now_s + @as(i64, @intCast(@divFloor(d.nanoseconds, std.time.ns_per_s)));
        }
        if (fields.expire_time) |text| {
            const t = core.timestamp.parse(text) catch return try invalidArgument(arena);
            fields.expire_s = @intCast(@divFloor(t.nanoseconds, std.time.ns_per_s));
        }
        const at = fields.expire_s orelse return null;
        if (at < self.now_s + 60) return try fail(arena, 400, "INVALID_ARGUMENT", "Expiration time must be at least [1m] in the future.");
        if (at > self.now_s + 876_000 * 3600) return try fail(arena, 400, "INVALID_ARGUMENT", "Expiration time cannot be more than [876000h] from now.");
        return null;
    }

    // JSON out

    fn secretJson(self: *FakeSecrets, arena: Allocator, s: *const Stored) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        _ = self;
        writeSecretJson(&out.writer, s) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    fn writeSecretJson(w: *std.Io.Writer, s: *const Stored) std.Io.Writer.Error!void {
        var jw: Stringify = .{ .writer = w };
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(s.name);
        if (s.replication) |r| {
            try jw.objectField("replication");
            try jw.beginWriteRaw();
            try w.writeAll(r);
            jw.endWriteRaw();
        }
        try jw.objectField("createTime");
        try writeTime(&jw, s.create_s);
        inline for (.{ .{ "labels", s.labels }, .{ "annotations", s.annotations } }) |entry| {
            if (entry[1].count() > 0) {
                try jw.objectField(entry[0]);
                try jw.beginObject();
                for (entry[1].keys(), entry[1].values()) |k, v| {
                    try jw.objectField(k);
                    try jw.write(v);
                }
                try jw.endObject();
            }
        }
        if (s.aliases.count() > 0) {
            try jw.objectField("versionAliases");
            try jw.beginObject();
            for (s.aliases.keys(), s.aliases.values()) |k, v| {
                try jw.objectField(k);
                try jw.print("\"{d}\"", .{v});
            }
            try jw.endObject();
        }
        if (s.expire_s) |at| {
            try jw.objectField("expireTime");
            try writeTime(&jw, at);
        }
        if (s.delay_s) |d| {
            try jw.objectField("versionDestroyTtl");
            try jw.print("\"{d}s\"", .{d});
        }
        if (s.topics.len > 0) {
            try jw.objectField("topics");
            try jw.beginArray();
            for (s.topics) |t| {
                try jw.beginObject();
                try jw.objectField("name");
                try jw.write(t);
                try jw.endObject();
            }
            try jw.endArray();
        }
        if (s.rotation_next_s) |next| {
            try jw.objectField("rotation");
            try jw.beginObject();
            try jw.objectField("nextRotationTime");
            try writeTime(&jw, next);
            if (s.rotation_period_s) |p| {
                try jw.objectField("rotationPeriod");
                try jw.print("\"{d}s\"", .{p});
            }
            try jw.endObject();
        }
        try jw.objectField("etag");
        try jw.print("\"\\\"{x}\\\"\"", .{s.etag});
        try jw.endObject();
    }

    fn versionJson(self: *FakeSecrets, arena: Allocator, s: *const Stored, n: usize) Allocator.Error![]const u8 {
        _ = self;
        const v = s.versions.items[n - 1];
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: Stringify = .{ .writer = &out.writer };
        writeVersion(&jw, s, n, v) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    fn writeVersion(jw: *Stringify, s: *const Stored, n: usize, v: StoredVersion) Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.print("\"{s}/versions/{d}\"", .{ s.name, n });
        try jw.objectField("createTime");
        try writeTime(jw, v.create_s);
        if (v.destroy_s) |at| {
            try jw.objectField("destroyTime");
            try writeTime(jw, at);
        }
        try jw.objectField("state");
        try jw.write(@tagName(v.state));
        if (s.replication != null) {
            try jw.objectField("replicationStatus");
            try jw.beginObject();
            try jw.objectField("automatic");
            try jw.beginObject();
            try jw.endObject();
            try jw.endObject();
        }
        try jw.objectField("etag");
        try jw.print("\"\\\"{x}\\\"\"", .{v.etag});
        try jw.objectField("clientSpecifiedPayloadChecksum");
        try jw.write(true);
        if (v.scheduled_s) |at| {
            try jw.objectField("scheduledDestroyTime");
            try writeTime(jw, at);
        }
        try jw.endObject();
    }

    // Helpers

    /// Topics from a body, checked as production checks them, publishing
    /// included.
    fn readTopics(self: *FakeSecrets, arena: Allocator, value: std.json.Value) Allocator.Error!TopicsResult {
        const items: []const std.json.Value = switch (value) {
            .array => |list| list.items,
            .object => &.{value},
            else => return .{ .refused = try invalidArgument(arena) },
        };
        if (items.len > 10) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "No more than 10 topics can be configured on a secret.") };
        const out = try arena.alloc([]const u8, items.len);
        for (items, out, 0..) |item, *name, i| {
            if (item != .object) return .{ .refused = try invalidArgument(arena) };
            const n = item.object.get("name") orelse return .{ .refused = try invalidArgument(arena) };
            if (n != .string) return .{ .refused = try invalidArgument(arena) };
            name.* = n.string;
            for (out[0..i]) |earlier| if (std.mem.eql(u8, earlier, n.string)) {
                return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "Topics must have distinct names.") };
            };
        }
        for (out) |name| {
            if (!fullTopicName(name)) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(
                arena,
                "Failed to Publish to topic [{s}], got an error from Pub/Sub.",
                .{name},
            )) };
            const state = self.topic_states.get(name) orelse continue;
            return .{ .refused = switch (state) {
                .missing => try fail(arena, 404, "NOT_FOUND", try std.fmt.allocPrint(arena, "Topic [{s}] not found.", .{name})),
                .unpublishable => try fail(arena, 400, "FAILED_PRECONDITION", try std.fmt.allocPrint(
                    arena,
                    "Permission 'pubsub.topics.publish' denied for service-{s}@gcp-sa-secretmanager.iam.gserviceaccount.com for pubsub topic: {s} or the topic doesn't exist. Grant the 'pubsub.topic.publish' permission (or 'roles/pubsub.publisher') on this topic to service-{s}@gcp-sa-secretmanager.iam.gserviceaccount.com.",
                    .{ self.project_number, name, self.project_number },
                )),
            } };
        }
        return .{ .ok = out };
    }

    fn etag(self: *FakeSecrets) u64 {
        self.next_etag += 1 + (self.next_etag % 7);
        return self.next_etag;
    }

    fn etagMatches(self: *FakeSecrets, arena: Allocator, current: u64, sent: []const u8) Allocator.Error!bool {
        _ = self;
        return std.mem.eql(u8, sent, try std.fmt.allocPrint(arena, "\"{x}\"", .{current}));
    }

    fn secretName(self: *FakeSecrets, arena: Allocator, location: ?[]const u8, id: []const u8) Allocator.Error![]const u8 {
        if (location) |loc| return std.fmt.allocPrint(arena, "projects/{s}/locations/{s}/secrets/{s}", .{ self.project_number, loc, id });
        return std.fmt.allocPrint(arena, "projects/{s}/secrets/{s}", .{ self.project_number, id });
    }
};

/// What a request addresses, read from its URL.
const Target = struct {
    location: ?[]const u8 = null,
    secret_id: ?[]const u8 = null,
    versions: bool = false,
    version_ref: ?[]const u8 = null,
    verb: ?[]const u8 = null,
    query_secret_id: ?[]const u8 = null,
    update_mask: ?[]const u8 = null,
    query_etag: ?[]const u8 = null,
};

fn parseUrl(arena: Allocator, url: []const u8) !Target {
    const scheme = "https://";
    if (!std.mem.startsWith(u8, url, scheme)) return error.NoRoute;
    const rest = url[scheme.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.NoRoute;
    const host = rest[0..slash];
    var path = rest[slash..];
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, path, '?')) |q| {
        query = path[q + 1 ..];
        path = path[0..q];
    }
    var t: Target = .{};
    const prefix = "/v1/projects/";
    if (!std.mem.startsWith(u8, path, prefix)) return error.NoRoute;
    var parts = std.mem.splitScalar(u8, path[prefix.len..], '/');
    _ = parts.next() orelse return error.NoRoute; // the project
    var next = parts.next() orelse return error.NoRoute;
    if (std.mem.eql(u8, next, "locations")) {
        t.location = parts.next() orelse return error.NoRoute;
        const want = try std.fmt.allocPrint(arena, "secretmanager.{s}.rep.googleapis.com", .{t.location.?});
        if (!std.mem.eql(u8, host, want)) return error.NoRoute;
        next = parts.next() orelse return error.NoRoute;
    } else if (!std.mem.eql(u8, host, "secretmanager.googleapis.com")) return error.NoRoute;
    if (!std.mem.eql(u8, next, "secrets")) return error.NoRoute;
    if (parts.next()) |id_part| {
        const id, const verb = splitVerb(id_part);
        t.secret_id = try decode(arena, id);
        t.verb = verb;
        if (parts.next()) |versions| {
            if (!std.mem.eql(u8, versions, "versions")) return error.NoRoute;
            t.versions = true;
            if (parts.next()) |ref_part| {
                const ref, const v = splitVerb(ref_part);
                t.version_ref = try decode(arena, ref);
                t.verb = v;
            }
        }
    }
    var params = std.mem.splitScalar(u8, query, '&');
    while (params.next()) |param| {
        if (param.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, param, '=') orelse param.len;
        const name = param[0..eq];
        const value = try decode(arena, if (eq < param.len) param[eq + 1 ..] else "");
        if (std.mem.eql(u8, name, "secretId")) t.query_secret_id = value;
        if (std.mem.eql(u8, name, "updateMask")) t.update_mask = value;
        if (std.mem.eql(u8, name, "etag")) t.query_etag = value;
    }
    return t;
}

fn splitVerb(part: []const u8) struct { []const u8, ?[]const u8 } {
    const colon = std.mem.indexOfScalar(u8, part, ':') orelse return .{ part, null };
    return .{ part[0..colon], part[colon + 1 ..] };
}

fn decode(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    const copy = try arena.dupe(u8, text);
    return std.Uri.percentDecodeInPlace(copy);
}

/// A request body's Secret fields, by either name production takes.
const Fields = struct {
    labels: ?std.json.Value = null,
    annotations: ?std.json.Value = null,
    aliases: ?std.json.Value = null,
    expire_time: ?[]const u8 = null,
    ttl: ?[]const u8 = null,
    delay: ?[]const u8 = null,
    etag: ?[]const u8 = null,
    replication: ?std.json.Value = null,
    topics: ?std.json.Value = null,
    rotation: ?std.json.Value = null,
    unsupported: ?[]const u8 = null,
    expire_s: ?i64 = null,
};

const Parsed = union(enum) { ok: *Fields, refused: FakeSecrets.Reply };

fn parseBody(arena: Allocator, body: []const u8) Allocator.Error!Parsed {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, if (body.len == 0) "{}" else body, .{}) catch
        return .{ .refused = try invalidArgument(arena) };
    if (value != .object) return .{ .refused = try invalidArgument(arena) };
    const f = try arena.create(Fields);
    f.* = .{};
    var it = value.object.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        if (eqlAny(k, &.{"labels"})) {
            f.labels = v;
        } else if (eqlAny(k, &.{"annotations"})) {
            f.annotations = v;
        } else if (eqlAny(k, &.{ "versionAliases", "version_aliases" })) {
            f.aliases = v;
        } else if (eqlAny(k, &.{ "expireTime", "expire_time" })) {
            if (v != .string) return .{ .refused = try invalidArgument(arena) };
            f.expire_time = v.string;
        } else if (eqlAny(k, &.{"ttl"})) {
            if (v != .string) return .{ .refused = try invalidArgument(arena) };
            f.ttl = v.string;
        } else if (eqlAny(k, &.{ "versionDestroyTtl", "version_destroy_ttl" })) {
            if (v != .string) return .{ .refused = try invalidArgument(arena) };
            f.delay = v.string;
        } else if (eqlAny(k, &.{"etag"})) {
            if (v != .string) return .{ .refused = try invalidArgument(arena) };
            f.etag = v.string;
        } else if (eqlAny(k, &.{"replication"})) {
            f.replication = v;
        } else if (eqlAny(k, &.{"topics"})) {
            f.topics = v;
        } else if (eqlAny(k, &.{"rotation"})) {
            f.rotation = v;
        } else if (eqlAny(k, &.{ "customerManagedEncryption", "customer_managed_encryption" })) {
            f.unsupported = k;
        } else if (eqlAny(k, &.{ "name", "createTime", "create_time", "tags", "secretType", "secret_type", "policyMember", "policy_member" })) {
            // Ignored on patch, or immutable: the mask decides.
        } else {
            return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(
                arena,
                "Invalid JSON payload received. Unknown name \"{s}\" at 'secret': Cannot find field.",
                .{k},
            )) };
        }
    }
    return .{ .ok = f };
}

const Path = union(enum) {
    labels,
    annotations,
    aliases,
    expire_time,
    ttl,
    delay,
    replication,
    topics,
    rotation,
    rotation_next,
    rotation_period,
    ignored,
    immutable: []const u8,
    unsupported: []const u8,
};

/// A mask path as production reads it, in either case; null for one it
/// refuses outright, map keys and `*` included.
fn canonicalPath(raw: []const u8) ?Path {
    if (eqlAny(raw, &.{"labels"})) return .labels;
    if (eqlAny(raw, &.{"annotations"})) return .annotations;
    if (eqlAny(raw, &.{ "version_aliases", "versionAliases" })) return .aliases;
    if (eqlAny(raw, &.{ "expire_time", "expireTime" })) return .expire_time;
    if (eqlAny(raw, &.{"ttl"})) return .ttl;
    if (eqlAny(raw, &.{ "version_destroy_ttl", "versionDestroyTtl" })) return .delay;
    if (eqlAny(raw, &.{"replication"})) return .replication;
    if (eqlAny(raw, &.{ "name", "create_time", "createTime", "tags", "etag" })) return .ignored;
    if (eqlAny(raw, &.{ "secret_type", "secretType" })) return .{ .immutable = "secret_type" };
    if (eqlAny(raw, &.{ "policy_member", "policyMember" })) return .{ .immutable = "policy_member" };
    if (eqlAny(raw, &.{"topics"})) return .topics;
    if (eqlAny(raw, &.{"rotation"})) return .rotation;
    if (eqlAny(raw, &.{ "rotation.next_rotation_time", "rotation.nextRotationTime" })) return .rotation_next;
    if (eqlAny(raw, &.{ "rotation.rotation_period", "rotation.rotationPeriod" })) return .rotation_period;
    if (eqlAny(raw, &.{ "customer_managed_encryption", "customerManagedEncryption" })) return .{ .unsupported = raw };
    return null;
}

const TopicsResult = union(enum) { ok: []const []const u8, refused: FakeSecrets.Reply };

/// Rotation fields from a body, into `draft`: the time and the period
/// where `take_next` and `take_period` say the mask names them.
fn readRotation(arena: Allocator, value: std.json.Value, draft: *FakeSecrets.Draft, take_next: bool, take_period: bool) Allocator.Error!?FakeSecrets.Reply {
    if (value != .object) return try invalidArgument(arena);
    draft.rotation_changed = true;
    if (take_next) {
        draft.rotation_next_s = null;
        if (value.object.get("nextRotationTime") orelse value.object.get("next_rotation_time")) |t| {
            if (t != .string) return try invalidArgument(arena);
            const ts = core.timestamp.parse(t.string) catch return try invalidArgument(arena);
            draft.rotation_next_s = @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));
            draft.next_sent = true;
        }
    }
    if (take_period) {
        draft.rotation_period_s = null;
        if (value.object.get("rotationPeriod") orelse value.object.get("rotation_period")) |p| {
            if (p != .string) return try invalidArgument(arena);
            const d = core.duration.parse(p.string) catch return try invalidArgument(arena);
            if (d.nanoseconds < 0) return try invalidArgument(arena);
            const secs: u64 = @intCast(@divFloor(d.nanoseconds, std.time.ns_per_s));
            draft.rotation_period_s = secs;
            draft.period_sent = secs;
        }
    }
    return null;
}

const MapResult = union(enum) { ok: FakeSecrets.Map, refused: FakeSecrets.Reply };

fn readMap(arena: Allocator, value: std.json.Value, field: []const u8) Allocator.Error!MapResult {
    if (value != .object) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", try std.fmt.allocPrint(
        arena,
        "Invalid value at 'secret' (Map), Cannot bind a list to map for field '{s}'.",
        .{field},
    )) };
    var map: FakeSecrets.Map = .empty;
    var it = value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) return .{ .refused = try invalidArgument(arena) };
        try map.put(arena, entry.key_ptr.*, entry.value_ptr.string);
    }
    return .{ .ok = map };
}

const AliasResult = union(enum) { ok: FakeSecrets.Aliases, refused: FakeSecrets.Reply };

fn readAliases(arena: Allocator, value: std.json.Value) Allocator.Error!AliasResult {
    if (value != .object) return .{ .refused = try invalidArgument(arena) };
    var map: FakeSecrets.Aliases = .empty;
    var it = value.object.iterator();
    while (it.next()) |entry| {
        // A version that cannot exist reads as 0, which no version is.
        const n: i64 = switch (entry.value_ptr.*) {
            .integer => |i| i,
            .string, .number_string => |text| std.fmt.parseInt(i64, text, 10) catch return .{ .refused = try invalidArgument(arena) },
            else => return .{ .refused = try invalidArgument(arena) },
        };
        try map.put(arena, entry.key_ptr.*, std.math.cast(u64, n) orelse 0);
    }
    return .{ .ok = map };
}

const DelayResult = union(enum) { ok: u64, refused: FakeSecrets.Reply };

fn readDelay(arena: Allocator, text: []const u8) Allocator.Error!DelayResult {
    const d = core.duration.parse(text) catch return .{ .refused = try invalidArgument(arena) };
    if (d.nanoseconds < 86_400 * std.time.ns_per_s) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "Version destroy TTL must be at least [24h].") };
    if (d.nanoseconds > 86_400_000 * std.time.ns_per_s) return .{ .refused = try fail(arena, 400, "INVALID_ARGUMENT", "Version destroy TTL cannot be more than [24000h].") };
    return .{ .ok = @intCast(@divFloor(d.nanoseconds, std.time.ns_per_s)) };
}

/// Why a label key or value is refused, or null. Any character beyond
/// ASCII passes as a lowercase or uncased letter.
fn labelProblem(text: []const u8, key: bool) ?[]const u8 {
    if (key and text.len == 0) return "does not conform to regular expression \"[\\p{Ll}\\p{Lo}][\\p{Ll}\\p{Lo}\\p{N}_-]{0,62}\"";
    if (text.len > 128) return "exceeds maximum byte length 128";
    const n = std.unicode.utf8CountCodepoints(text) catch return "is not valid UTF-8";
    if (n > 63) return if (key) "exceeds maximum character length 63" else "exceeds maximum value length 63";
    for (text, 0..) |c, i| {
        if (c >= 0x80) continue;
        const ok = switch (c) {
            'a'...'z' => true,
            '0'...'9', '_', '-' => !key or i > 0,
            else => false,
        };
        if (!ok) return if (key)
            "does not conform to regular expression \"[\\p{Ll}\\p{Lo}][\\p{Ll}\\p{Lo}\\p{N}_-]{0,62}\""
        else
            "does not conform to regular expression \"[\\p{Ll}\\p{Lo}\\p{N}_-]{0,63}\"";
    }
    return null;
}

fn fullTopicName(name: []const u8) bool {
    var parts = std.mem.splitScalar(u8, name, '/');
    const a = parts.next() orelse return false;
    const project = parts.next() orelse return false;
    const b = parts.next() orelse return false;
    const topic = parts.next() orelse return false;
    return std.mem.eql(u8, a, "projects") and project.len > 0 and std.mem.eql(u8, b, "topics") and topic.len > 0 and parts.next() == null;
}

fn annotationKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 64) return false;
    var last_alnum = false;
    for (key, 0..) |c, i| {
        const alnum = std.ascii.isAlphanumeric(c);
        if (!alnum and !(c == '.' or c == '_' or c == '-')) return false;
        if (i == 0 and !alnum) return false;
        last_alnum = alnum;
    }
    return last_alnum;
}

fn aliasName(name: []const u8) bool {
    if (name.len == 0 or name.len > 63 or !std.ascii.isAlphabetic(name[0])) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return !std.mem.eql(u8, name, "latest") and !std.mem.eql(u8, name, "NEW");
}

fn copyMap(a: Allocator, map: FakeSecrets.Map) Allocator.Error!FakeSecrets.Map {
    var out: FakeSecrets.Map = .empty;
    for (map.keys(), map.values()) |k, v| try out.put(a, try a.dupe(u8, k), try a.dupe(u8, v));
    return out;
}

fn encodeBase64(arena: Allocator, data: []const u8) Allocator.Error![]const u8 {
    const out = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(data.len));
    return std.base64.standard.Encoder.encode(out, data);
}

fn eqlAny(text: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, text, o)) return true;
    return false;
}

/// `2026-10-02T13:00:00Z`, from seconds since the epoch.
fn writeTime(jw: *Stringify, seconds: i64) Stringify.Error!void {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    try jw.print("\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\"", .{
        day.year,             md.month.numeric(),      md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

fn fail(arena: Allocator, code: u16, status: []const u8, message: []const u8) Allocator.Error!FakeSecrets.Reply {
    return .{ .status = code, .body = try Stringify.valueAlloc(arena, .{ .@"error" = .{
        .code = code,
        .message = message,
        .status = status,
    } }, .{}) };
}

fn invalidArgument(arena: Allocator) Allocator.Error!FakeSecrets.Reply {
    return fail(arena, 400, "INVALID_ARGUMENT", "Request contains an invalid argument.");
}

fn stale(arena: Allocator) Allocator.Error!FakeSecrets.Reply {
    return fail(arena, 400, "FAILED_PRECONDITION", "The etag provided in the request does not match the resource's current etag. Please retry the whole read-modify-write with exponential backoff.");
}

fn unsupported(arena: Allocator, what: []const u8) Allocator.Error!FakeSecrets.Reply {
    return fail(arena, 501, "UNIMPLEMENTED", try std.fmt.allocPrint(arena, "FakeSecrets does not model {s} yet", .{what}));
}

const testing = std.testing;
const Client = @import("Client.zig");
const test_util = @import("test_util.zig");

/// A real client wired to a `FakeSecrets`.
const Rig = struct {
    fake: FakeSecrets,
    clock: test_util.FakeClock,
    token: test_util.FakeTokenProvider,
    diag: core.Diagnostics,
    client: Client,

    fn init(r: *Rig, location: ?[]const u8) !void {
        r.* = .{ .fake = .init(testing.allocator), .clock = .{}, .token = .{}, .diag = .{}, .client = undefined };
        errdefer r.fake.deinit();
        r.client = try .init(testing.allocator, r.clock.io(), .{
            .project_id = "extractctl",
            .location = location,
            .token_provider = r.token.provider(),
            .diagnostics = &r.diag,
            .transport = r.fake.transport(),
        });
    }

    fn deinit(r: *Rig) void {
        r.client.deinit();
        r.fake.deinit();
    }
};

test "FakeSecrets: a secret's settings through the real client, as production answered" {
    for ([_]?[]const u8{ null, "europe-west3" }) |location| {
        var r: Rig = undefined;
        try r.init(location);
        defer r.deinit();
        const secret = r.client.secret("db-password");

        var created = try secret.create(.{
            .labels = &.{.{ .key = "team", .value = "payments" }},
            .annotations = &.{.{ .key = "owner", .value = "Ann" }},
            .version_destroy_delay_s = 86_400,
        });
        defer created.deinit();
        try testing.expectEqualStrings("payments", created.value.label("team").?);
        try testing.expectEqual(86_400, created.value.version_destroy_delay_s.?);
        for (0..2) |_| {
            var v = try secret.addVersion("s3cr3t");
            v.deinit();
        }

        var updated = try secret.update(.{
            .labels = .clear,
            .aliases = .{ .set = &.{ .{ .name = "prod", .version = 2 }, .{ .name = "Prod", .version = 1 } } },
            .expiry = .{ .set = .{ .after_s = 3600 } },
            .etag = created.value.etag,
        });
        defer updated.deinit();
        try testing.expectEqual(0, updated.value.labels.len);
        try testing.expectEqualStrings("Ann", updated.value.annotation("owner").?);
        try testing.expectEqual(2, updated.value.alias("prod").?);
        try testing.expectEqual(1, updated.value.alias("Prod").?);
        try testing.expectEqualStrings("2026-10-02T14:00:00Z", updated.value.expire_time);
        try testing.expect(!std.mem.eql(u8, created.value.etag, updated.value.etag));

        // The read before is stale now.
        try testing.expectError(error.Aborted, secret.update(.{ .annotations = .clear, .etag = created.value.etag }));
        try testing.expectError(error.Aborted, secret.deleteIf(created.value.etag));
        // Aliases read through, case and all.
        var by_alias = try secret.access(.{ .alias = "Prod" });
        defer by_alias.deinit();
        try testing.expectEqual(1, by_alias.versionNumber().?);
        try testing.expectError(error.NotFound, secret.access(.{ .alias = "stable" }));
        // An alias to a version the secret does not have is the server's.
        try testing.expectError(error.InvalidArgument, secret.update(.{ .aliases = .{ .set = &.{.{ .name = "next", .version = 3 }} } }));
        try testing.expect(std.mem.indexOf(u8, r.diag.message(), "don't exist") != null);

        // A destruction delay: scheduled, refused twice, cancelled.
        const v1 = secret.version(.{ .number = 1 });
        var scheduled = try v1.destroy();
        defer scheduled.deinit();
        try testing.expectEqual(.disabled, scheduled.value.state);
        try testing.expectEqualStrings("2026-10-03T13:00:00Z", scheduled.value.scheduled_destroy_time);
        try testing.expectError(error.FailedPrecondition, v1.destroy());
        try testing.expectError(error.FailedPrecondition, secret.access(.{ .alias = "Prod" }));
        try testing.expectError(error.Aborted, v1.enableIf(created.value.etag));
        var back = try v1.enableIf(scheduled.value.etag);
        defer back.deinit();
        try testing.expectEqual(.enabled, back.value.state);
        try testing.expectEqualStrings("", back.value.scheduled_destroy_time);

        // Without the delay, destroy is at once, and the alias stays.
        var plain = try secret.update(.{ .version_destroy_delay_s = .clear, .expiry = .clear });
        defer plain.deinit();
        try testing.expectEqual(null, plain.value.version_destroy_delay_s);
        try testing.expectEqualStrings("", plain.value.expire_time);
        var gone = try secret.version(.{ .number = 2 }).destroy();
        defer gone.deinit();
        try testing.expectEqual(.destroyed, gone.value.state);
        var after = try secret.get();
        defer after.deinit();
        try testing.expectEqual(2, after.value.alias("prod").?);

        try secret.deleteIf(after.value.etag);
        try testing.expectError(error.NotFound, secret.get());
    }
}

test "FakeSecrets: what production refuses, refused in its words" {
    var f: FakeSecrets = .init(testing.allocator);
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "https://secretmanager.googleapis.com/v1/projects/extractctl/secrets";
    try testing.expectEqual(200, (try f.serve(.POST, base ++ "?secretId=s", "{\"replication\":{\"automatic\":{}}}", a)).status);
    const Case = struct { tp.Method, []const u8, []const u8, u16, []const u8 };
    for ([_]Case{
        .{ .PATCH, base ++ "/s", "{}", 400, "Field [update_mask] is required." },
        .{ .PATCH, base ++ "/s?updateMask=*", "{}", 400, "invalid argument" },
        .{ .PATCH, base ++ "/s?updateMask=labels.team", "{}", 400, "invalid argument" },
        .{ .PATCH, base ++ "/s?updateMask=bogus", "{}", 400, "invalid argument" },
        .{ .PATCH, base ++ "/s?updateMask=secret_type", "{}", 400, "immutable" },
        .{ .PATCH, base ++ "/s?updateMask=labels", "{\"labels\":{\"Abc\":\"v\"}}", 400, "does not conform" },
        .{ .PATCH, base ++ "/s?updateMask=annotations", "{\"annotations\":{\"a.\":\"v\"}}", 400, "must follow pattern" },
        .{ .PATCH, base ++ "/s?updateMask=version_aliases", "{\"versionAliases\":{\"latest\":\"1\"}}", 400, "cannot be \\\"latest\\\"" },
        .{ .PATCH, base ++ "/s?updateMask=ttl", "{\"ttl\":\"59s\"}", 400, "at least [1m]" },
        .{ .PATCH, base ++ "/s?updateMask=version_destroy_ttl", "{\"versionDestroyTtl\":\"86399s\"}", 400, "at least [24h]" },
        .{ .PATCH, base ++ "/s?updateMask=labels", "{\"labels\":{},\"etag\":\"\\\"0\\\"\"}", 400, "etag provided" },
        .{ .PATCH, base ++ "/s?updateMask=labels", "{\"noSuchField\":1}", 400, "Unknown name" },
        .{ .PATCH, base ++ "/s?updateMask=customer_managed_encryption", "{}", 501, "does not model" },
        .{ .DELETE, base ++ "/s?etag=%220%22", "", 400, "etag provided" },
        .{ .GET, base ++ "/missing", "", 404, "not found" },
        .{ .POST, base ++ "/s/versions/latest:destroy", "{}", 400, "expected format" },
    }) |case| {
        const reply = try f.serve(case[0], case[1], case[2], a);
        try testing.expectEqual(case[3], reply.status);
        if (std.mem.indexOf(u8, reply.body, case[4]) == null) {
            std.debug.print("{s} {s}: {s}\n", .{ @tagName(case[0]), case[1], reply.body });
            return error.TestUnexpectedReply;
        }
    }
    // An empty mask changes nothing but the etag; "" as an etag is none.
    const before = f.secret(null, "s").?.etag;
    try testing.expectEqual(200, (try f.serve(.PATCH, base ++ "/s?updateMask=", "{\"labels\":{\"a\":\"1\"}}", a)).status);
    try testing.expectEqual(0, f.secret(null, "s").?.labels.count());
    try testing.expect(f.secret(null, "s").?.etag != before);
    try testing.expectEqual(200, (try f.serve(.PATCH, base ++ "/s?updateMask=labels", "{\"labels\":{\"a\":\"1\"},\"etag\":\"\"}", a)).status);
    try testing.expectEqual(200, (try f.serve(.DELETE, base ++ "/s?etag=", "", a)).status);
}

/// What a secret should hold after a sequence of calls, kept independently
/// of the client and the fake: settings as bit sets over small pools.
const Model = struct {
    labels: u4 = 0,
    annotations: u4 = 0,
    aliases: [4]?u64 = @splat(null),
    expire_time: []const u8 = "",
    delay_s: ?u64 = null,
    topics: u3 = 0,
    /// The rotation's next time and period, as the server writes them.
    rotation: ?struct { next: []const u8, period_s: ?u64 } = null,
    versions: [8]VersionModel = undefined,
    version_count: usize = 0,
    /// Every secret etag seen, oldest first; the last is current.
    etags: [64][]const u8 = undefined,
    etag_count: usize = 0,

    const VersionModel = struct { state: @import("types.zig").State, scheduled: bool, etag: []const u8, stale_etag: ?[]const u8 = null };

    const label_pool = [4]@import("types.zig").Label{
        .{ .key = "a", .value = "1" },
        .{ .key = "team", .value = "payments" },
        .{ .key = "k-1", .value = "" },
        .{ .key = "\xc3\xa9", .value = "x_y" },
    };
    const annotation_pool = [4]@import("types.zig").Annotation{
        .{ .key = "k", .value = "v" },
        .{ .key = "Owner", .value = "line\nbreak" },
        .{ .key = "a.b", .value = "" },
        .{ .key = "n", .value = "\xc3\xa9" },
    };
    const alias_names = [4][]const u8{ "prod", "Prod", "stable", "new" };
    /// The last one Secret Manager cannot publish to.
    const topic_pool = [3][]const u8{ "projects/p/topics/alpha", "projects/p/topics/bravo", "projects/p/topics/badly" };
    const bad_topic: u3 = 0b100;

    fn currentEtag(m: *const Model) []const u8 {
        return m.etags[m.etag_count - 1];
    }

    fn sawEtag(m: *Model, arena: Allocator, etag_text: []const u8) !void {
        if (m.etag_count == m.etags.len) {
            std.mem.copyForwards([]const u8, m.etags[0 .. m.etags.len - 1], m.etags[1..]);
            m.etag_count -= 1;
        }
        m.etags[m.etag_count] = try arena.dupe(u8, etag_text);
        m.etag_count += 1;
    }

    /// Checks a secret as read against the model.
    fn expectSecret(m: *const Model, info: @import("types.zig").SecretInfo) !void {
        try testing.expectEqual(@as(usize, @popCount(m.labels)), info.labels.len);
        for (label_pool, 0..) |l, i| {
            const want: ?[]const u8 = if (m.labels & (@as(u4, 1) << @intCast(i)) != 0) l.value else null;
            if (want) |w| try testing.expectEqualStrings(w, info.label(l.key).?) else try testing.expectEqual(null, info.label(l.key));
        }
        try testing.expectEqual(@as(usize, @popCount(m.annotations)), info.annotations.len);
        for (annotation_pool, 0..) |a, i| {
            const want: ?[]const u8 = if (m.annotations & (@as(u4, 1) << @intCast(i)) != 0) a.value else null;
            if (want) |w| try testing.expectEqualStrings(w, info.annotation(a.key).?) else try testing.expectEqual(null, info.annotation(a.key));
        }
        var alias_count: usize = 0;
        for (alias_names, m.aliases) |name, want| {
            try testing.expectEqual(want, info.alias(name));
            if (want != null) alias_count += 1;
        }
        try testing.expectEqual(alias_count, info.aliases.len);
        try testing.expectEqualStrings(m.expire_time, info.expire_time);
        try testing.expectEqual(m.delay_s, info.version_destroy_delay_s);
        try testing.expectEqual(@as(usize, @popCount(m.topics)), info.topics.len);
        var t: usize = 0;
        for (topic_pool, 0..) |name, i| if (m.topics & (@as(u3, 1) << @intCast(i)) != 0) {
            try testing.expectEqualStrings(name, info.topics[t]);
            t += 1;
        };
        if (m.rotation) |r| {
            try testing.expectEqualStrings(r.next, info.rotation.?.next_time);
            try testing.expectEqual(r.period_s, info.rotation.?.period_s);
        } else try testing.expectEqual(null, info.rotation);
        try testing.expectEqualStrings(m.currentEtag(), info.etag);
    }
};

fn modelProperty(_: void, input: []const u8) !void {
    const types = @import("types.zig");
    var r: Rig = undefined;
    try r.init(if (input.len > 0 and input[0] & 1 == 1) "europe-west3" else null);
    defer r.deinit();
    try r.fake.setTopic(Model.topic_pool[2], .unpublishable);
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var g: test_util.ByteGen = .init(input);
    var m: Model = .{};
    const secret = r.client.secret("model");

    {
        var created = try secret.create(.{});
        defer created.deinit();
        try m.sawEtag(a, created.value.etag);
    }

    var steps: usize = 0;
    while (steps < 24 and g.pos < g.bytes.len) : (steps += 1) {
        switch (g.intRange(u8, 0, 6)) {
            0, 1 => {
                var changes: types.SecretUpdate = .{};
                var next = m;
                var alias_ok = true;
                switch (g.intRange(u8, 0, 2)) {
                    0 => {},
                    1 => {
                        const bits: u4 = @truncate(g.byte());
                        var list: std.ArrayListUnmanaged(types.Label) = .empty;
                        for (Model.label_pool, 0..) |l, i| if (bits & (@as(u4, 1) << @intCast(i)) != 0) try list.append(a, l);
                        changes.labels = .{ .set = list.items };
                        next.labels = bits;
                    },
                    else => {
                        changes.labels = .clear;
                        next.labels = 0;
                    },
                }
                switch (g.intRange(u8, 0, 2)) {
                    0 => {},
                    1 => {
                        const bits: u4 = @truncate(g.byte());
                        var list: std.ArrayListUnmanaged(types.Annotation) = .empty;
                        for (Model.annotation_pool, 0..) |an, i| if (bits & (@as(u4, 1) << @intCast(i)) != 0) try list.append(a, an);
                        changes.annotations = .{ .set = list.items };
                        next.annotations = bits;
                    },
                    else => {
                        changes.annotations = .clear;
                        next.annotations = 0;
                    },
                }
                switch (g.intRange(u8, 0, 2)) {
                    0 => {},
                    1 => {
                        var list: std.ArrayListUnmanaged(types.Alias) = .empty;
                        for (Model.alias_names, 0..) |name, i| {
                            // One past the last version names none.
                            const pick = g.intRange(u8, 0, @intCast(m.version_count + 1));
                            next.aliases[i] = if (pick == 0) null else pick;
                            if (pick == 0) continue;
                            if (pick > m.version_count) alias_ok = false;
                            try list.append(a, .{ .name = name, .version = pick });
                        }
                        changes.aliases = .{ .set = list.items };
                    },
                    else => {
                        changes.aliases = .clear;
                        next.aliases = @splat(null);
                    },
                }
                switch (g.intRange(u8, 0, 3)) {
                    0 => {},
                    1 => {
                        changes.expiry = .{ .set = .{ .after_s = 3600 } };
                        next.expire_time = "2026-10-02T14:00:00Z";
                    },
                    2 => {
                        changes.expiry = .{ .set = .{ .at = "2027-01-01T00:00:00Z" } };
                        next.expire_time = "2027-01-01T00:00:00Z";
                    },
                    else => {
                        changes.expiry = .clear;
                        next.expire_time = "";
                    },
                }
                switch (g.intRange(u8, 0, 2)) {
                    0 => {},
                    1 => {
                        const d: u64 = if (g.boolean()) 86_400 else 172_800;
                        changes.version_destroy_delay_s = .{ .set = d };
                        next.delay_s = d;
                    },
                    else => {
                        changes.version_destroy_delay_s = .clear;
                        next.delay_s = null;
                    },
                }
                switch (g.intRange(u8, 0, 2)) {
                    0 => {},
                    1 => {
                        const bits: u3 = @truncate(g.byte());
                        var list: std.ArrayListUnmanaged([]const u8) = .empty;
                        for (Model.topic_pool, 0..) |t, i| if (bits & (@as(u3, 1) << @intCast(i)) != 0) try list.append(a, t);
                        changes.topics = .{ .set = list.items };
                        next.topics = bits;
                    },
                    else => {
                        changes.topics = .clear;
                        next.topics = 0;
                    },
                }
                switch (g.intRange(u8, 0, 2)) {
                    0 => {},
                    1 => {
                        const period: ?u64 = switch (g.intRange(u8, 0, 2)) {
                            0 => null,
                            1 => 3600,
                            else => 7200,
                        };
                        changes.rotation = .{ .set = .{ .next_time = "2026-10-02T14:00:00Z", .period_s = period } };
                        next.rotation = .{ .next = "2026-10-02T14:00:00Z", .period_s = period };
                    },
                    else => {
                        changes.rotation = .clear;
                        next.rotation = null;
                    },
                }
                // A rotation set beside no topics is refused before sending;
                // one the server would be left with without topics is
                // refused by the server.
                const local_rotation = changes.rotation == .set and switch (changes.topics) {
                    .keep => false,
                    .clear => true,
                    .set => |list| list.len == 0,
                };
                const bad_topics = changes.topics == .set and next.topics & Model.bad_topic != 0;
                const orphan_rotation = next.rotation != null and next.topics == 0;
                var stale_etag = false;
                switch (g.intRange(u8, 0, 2)) {
                    0 => {},
                    1 => changes.etag = m.currentEtag(),
                    else => if (m.etag_count > 1) {
                        changes.etag = m.etags[g.intRange(u8, 0, @intCast(m.etag_count - 2))];
                        stale_etag = true;
                    },
                }
                const sent_before = r.fake.requests;
                if (secret.update(changes)) |got| {
                    var owned = got;
                    defer owned.deinit();
                    try testing.expect(!changes.isEmpty() and !stale_etag and alias_ok and !local_rotation and !bad_topics and !orphan_rotation);
                    try next.sawEtag(a, owned.value.etag);
                    m = next;
                    try m.expectSecret(owned.value);
                } else |err| {
                    if (changes.isEmpty() or local_rotation) {
                        try testing.expectEqual(error.InvalidArgument, err);
                        try testing.expectEqual(sent_before, r.fake.requests);
                    } else if (stale_etag) {
                        try testing.expectEqual(error.Aborted, err);
                    } else if (bad_topics) {
                        try testing.expectEqual(error.TopicNotPublishable, err);
                    } else {
                        try testing.expect(!alias_ok or orphan_rotation);
                        try testing.expectEqual(error.InvalidArgument, err);
                    }
                }
            },
            2 => if (m.version_count < m.versions.len) {
                var added = try secret.addVersion("s3cr3t");
                defer added.deinit();
                m.versions[m.version_count] = .{ .state = .enabled, .scheduled = false, .etag = try a.dupe(u8, added.value.etag) };
                m.version_count += 1;
            },
            3, 4 => if (m.version_count > 0) {
                const n: usize = g.intRange(u8, 1, @intCast(m.version_count));
                const vm = &m.versions[n - 1];
                const verb = g.intRange(u8, 0, 2);
                const use_etag = g.intRange(u8, 0, 2);
                const etag_sent: ?[]const u8 = switch (use_etag) {
                    0 => null,
                    1 => vm.etag,
                    else => vm.stale_etag,
                };
                const stale_v = use_etag == 2 and vm.stale_etag != null;
                const v = secret.version(.{ .number = n });
                const result = switch (verb) {
                    0 => if (etag_sent) |e| v.enableIf(e) else v.enable(),
                    1 => if (etag_sent) |e| v.disableIf(e) else v.disable(),
                    else => if (etag_sent) |e| v.destroyIf(e) else v.destroy(),
                };
                if (result) |got| {
                    var owned = got;
                    defer owned.deinit();
                    try testing.expect(!stale_v and vm.state != .destroyed);
                    switch (verb) {
                        0, 1 => {
                            try testing.expect(verb == 0 or verb == 1);
                            vm.state = if (verb == 0) .enabled else .disabled;
                            vm.scheduled = false;
                        },
                        else => {
                            try testing.expect(!vm.scheduled);
                            vm.state = if (m.delay_s != null) .disabled else .destroyed;
                            vm.scheduled = m.delay_s != null;
                        },
                    }
                    try testing.expectEqual(vm.state, owned.value.state);
                    try testing.expectEqual(vm.scheduled, owned.value.scheduled_destroy_time.len > 0);
                    try testing.expect(!std.mem.eql(u8, vm.etag, owned.value.etag));
                    vm.stale_etag = vm.etag;
                    vm.etag = try a.dupe(u8, owned.value.etag);
                } else |err| {
                    if (stale_v) {
                        try testing.expectEqual(error.Aborted, err);
                    } else {
                        // A destroyed version takes no change, and a
                        // scheduled one no second destroy.
                        try testing.expectEqual(error.FailedPrecondition, err);
                        try testing.expect(vm.state == .destroyed or (verb == 2 and vm.scheduled));
                    }
                }
            },
            5 => if (m.rotation) |rot| {
                // The rotation comes due, as production did it.
                r.fake.fireRotation(if (input[0] & 1 == 1) "europe-west3" else null, "model");
                if (rot.period_s) |p| {
                    const t = try core.timestamp.parse(rot.next);
                    const next_s = @divFloor(t.nanoseconds, std.time.ns_per_s) + @as(i96, p);
                    var buf: std.ArrayListUnmanaged(u8) = .empty;
                    var jw_out: std.Io.Writer.Allocating = .init(a);
                    var jw: Stringify = .{ .writer = &jw_out.writer };
                    try writeTime(&jw, @intCast(next_s));
                    const quoted = jw_out.written();
                    try buf.appendSlice(a, quoted[1 .. quoted.len - 1]);
                    m.rotation = .{ .next = buf.items, .period_s = p };
                } else {
                    m.rotation = null;
                }
                var fired = try secret.get();
                defer fired.deinit();
                try m.sawEtag(a, fired.value.etag);
            },
            else => {},
        }
        // Whatever happened, a read agrees with the model.
        var read = try secret.get();
        defer read.deinit();
        try m.expectSecret(read.value);
        var versions = try secret.listVersions(.{});
        defer versions.deinit();
        try testing.expectEqual(m.version_count, versions.value.versions.len);
        for (versions.value.versions) |info| {
            const vm = m.versions[info.number().? - 1];
            try testing.expectEqual(vm.state, info.state);
            try testing.expectEqual(vm.scheduled, info.scheduled_destroy_time.len > 0);
            try testing.expectEqualStrings(vm.etag, info.etag);
        }
    }
}

test "heavy property secret updates, conditions and version changes: the secret is what a model says" {
    try test_util.fuzzBytes({}, modelProperty, .{ .corpus = &.{
        "",
        "\x00\x02\x02\x02\x00\x01\x0f\x01\x0f\x01\x01\x01\x02\x01\x01\x01\x00",
        "\x01\x02\x02\x00\x01\x01\x01\x02\x02\x02\x01\x03\x01\x02\x01\x03\x02\x02\x01",
        "\x00\x00\x01\x05\x01\x05\x02\x01\x00\x01\x01\x01\x02\x00\x01\x02",
    } });
}
