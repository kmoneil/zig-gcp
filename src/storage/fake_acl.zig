//! The rules `FakeBuckets` and `FakeMultipart` hold access control lists
//! to, as Cloud Storage kept them when measured on 2026-10-05. Written
//! from production's answers, not from this library's encoder. Test code
//! only.
//!
//! - A new bucket's list and default object list are `projectPrivate`:
//!   owners and editors OWNER, viewers READER. An object written without
//!   a list gets the default list, then its writer as OWNER; one written
//!   with a canned list gets its writer first.
//! - A whole list is held to: at most 100 entries, judged first; roles in
//!   upper case, WRITER on a bucket's list only; entities in the six
//!   forms; `allUsers` and `allAuthenticatedUsers` refused under public
//!   access prevention. Emails and domains are kept in lower case.
//! - The owner keeps OWNER: left out, it is added back at the end; given
//!   less, the write is refused 403. Production was measured adding it
//!   back; the refusal of a whole list that demotes it is assumed from the
//!   single-entry write's.
//! - An empty list is ignored. A canned list beside a list that is not
//!   empty is 409.
//! - Uniform access hides every list and refuses every write to one, in
//!   production's five wordings.
//! - Not modelled: a principal that does not exist (every well-formed one
//!   is taken), a bucket list's legacy IAM bindings, and the 30 s a
//!   default list change takes to reach new objects.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct { entity: []const u8, role: []const u8 };

/// Which list: a bucket's own, its default object list, or an object's.
pub const Kind = enum { bucket, default_object, object };

pub const project_number = "82150720798";
pub const owners = "project-owners-" ++ project_number;
pub const editors = "project-editors-" ++ project_number;
pub const viewers = "project-viewers-" ++ project_number;

/// A new bucket's list, and its default object list.
pub const project_private: []const Entry = &.{
    .{ .entity = owners, .role = "OWNER" },
    .{ .entity = editors, .role = "OWNER" },
    .{ .entity = viewers, .role = "READER" },
};

/// A bucket's canned list by its JSON name, or null for a name production
/// does not take.
pub fn bucketList(name: []const u8) ?[]const Entry {
    const lists = [_]struct { []const u8, []const Entry }{
        .{ "projectPrivate", project_private },
        .{ "private", &.{.{ .entity = owners, .role = "OWNER" }} },
        .{ "publicRead", &.{ .{ .entity = owners, .role = "OWNER" }, .{ .entity = "allUsers", .role = "READER" } } },
        .{ "publicReadWrite", &.{ .{ .entity = owners, .role = "OWNER" }, .{ .entity = "allUsers", .role = "WRITER" } } },
        .{ "authenticatedRead", &.{ .{ .entity = owners, .role = "OWNER" }, .{ .entity = "allAuthenticatedUsers", .role = "READER" } } },
    };
    for (lists) |l| if (std.mem.eql(u8, l[0], name)) return l[1];
    return null;
}

/// An object's canned list by its JSON name, without its owner: what a
/// default object list holds, and what follows the owner on an object.
pub fn objectList(name: []const u8) ?[]const Entry {
    const lists = [_]struct { []const u8, []const Entry }{
        .{ "projectPrivate", project_private },
        .{ "private", &.{} },
        .{ "bucketOwnerFullControl", &.{.{ .entity = owners, .role = "OWNER" }} },
        .{ "bucketOwnerRead", &.{.{ .entity = owners, .role = "READER" }} },
        .{ "publicRead", &.{.{ .entity = "allUsers", .role = "READER" }} },
        .{ "authenticatedRead", &.{.{ .entity = "allAuthenticatedUsers", .role = "READER" }} },
    };
    for (lists) |l| if (std.mem.eql(u8, l[0], name)) return l[1];
    return null;
}

/// The list a new object gets: its writer and the canned list, or the
/// bucket's default list and then its writer.
pub fn newObjectList(arena: Allocator, owner: []const u8, canned: ?[]const Entry, default: []const Entry) Allocator.Error![]const Entry {
    var list: std.ArrayList(Entry) = .empty;
    const owner_entry: Entry = .{ .entity = owner, .role = "OWNER" };
    if (canned) |c| {
        try list.append(arena, owner_entry);
        try list.appendSlice(arena, c);
    } else {
        try list.appendSlice(arena, default);
        try list.append(arena, owner_entry);
    }
    return list.items;
}

/// Whether a list grants the public anything.
pub fn isPublic(list: []const Entry) bool {
    for (list) |e| if (std.mem.eql(u8, e.entity, "allUsers") or std.mem.eql(u8, e.entity, "allAuthenticatedUsers")) return true;
    return false;
}

/// A refusal: a status and production's JSON body.
pub const Refusal = struct { status: u16, body: []const u8 };

pub const Outcome = union(enum) { list: []const Entry, refused: Refusal };

/// A patch body's list, held to the rules: normalized, the owner added
/// back, or refused as production refuses it.
pub fn fromBody(arena: Allocator, value: std.json.Value, kind: Kind, owner: ?[]const u8, prevented: bool) Allocator.Error!Outcome {
    const items = switch (value) {
        .array => |a| a.items,
        else => return .{ .refused = try refusal(arena, 400, "invalid", "Invalid value for access control list") },
    };
    if (items.len > 100) return .{ .refused = try refusal(arena, 400, "tooManyAccessControlEntries", "An access control list can contain at most 100 entries.") };
    var list: std.ArrayList(Entry) = .empty;
    for (items) |item| {
        const fields = switch (item) {
            .object => |o| o,
            else => return .{ .refused = try refusal(arena, 400, "invalid", "Invalid value for access control") },
        };
        const entity_text = switch (fields.get("entity") orelse return .{ .refused = try refusal(arena, 400, "required", "Required: entity") }) {
            .string => |s| s,
            else => return .{ .refused = try refusal(arena, 400, "invalid", "entity is not a string") },
        };
        const role = switch (fields.get("role") orelse return .{ .refused = try refusal(arena, 400, "required", "Access control must contain a role") }) {
            .string => |s| s,
            else => return .{ .refused = try refusal(arena, 400, "invalid", "role is not a string") },
        };
        if (!roleTaken(kind, role)) return .{ .refused = try refusal(arena, 400, "invalid", try arena.print("Invalid value for: {s} is not a valid value", .{role})) };
        // Kept: never a slice of the request, which goes when it ends.
        const kept_role = roleName(role);
        const entity = try normalized(arena, entity_text) orelse
            return .{ .refused = try refusal(arena, 400, "invalid", try arena.print("Scope text \"{s}\" is not valid.", .{entity_text})) };
        if (prevented and isPublic(&.{.{ .entity = entity, .role = kept_role }})) return .{ .refused = prevention_refusal };
        // A second entry for an entity replaces the first.
        if (find(list.items, entity)) |e| e.role = kept_role else try list.append(arena, .{ .entity = entity, .role = kept_role });
    }
    if (owner) |o| {
        if (find(list.items, o)) |e| {
            if (!std.mem.eql(u8, e.role, "OWNER")) return .{ .refused = owner_refusal };
        } else try list.append(arena, .{ .entity = o, .role = "OWNER" });
    }
    return .{ .list = list.items };
}

fn find(list: []Entry, entity: []const u8) ?*Entry {
    for (list) |*e| if (std.mem.eql(u8, e.entity, entity)) return e;
    return null;
}

/// Whether `kind`'s list takes `role`.
pub fn roleTaken(kind: Kind, role: []const u8) bool {
    if (std.mem.eql(u8, role, "OWNER") or std.mem.eql(u8, role, "READER")) return true;
    return kind == .bucket and std.mem.eql(u8, role, "WRITER");
}

/// One of the three roles, as a string that outlives any request.
fn roleName(role: []const u8) []const u8 {
    if (std.mem.eql(u8, role, "OWNER")) return "OWNER";
    if (std.mem.eql(u8, role, "WRITER")) return "WRITER";
    return "READER";
}

/// `text` as Cloud Storage keeps it, in `arena` or static memory, or null
/// when it is no entity.
pub fn normalized(arena: Allocator, text: []const u8) Allocator.Error!?[]const u8 {
    if (std.mem.eql(u8, text, "allUsers")) return "allUsers";
    if (std.mem.eql(u8, text, "allAuthenticatedUsers")) return "allAuthenticatedUsers";
    for ([_][]const u8{ "user-", "group-", "domain-" }) |prefix| {
        if (std.mem.startsWith(u8, text, prefix) and text.len > prefix.len) return try std.ascii.allocLowerString(arena, text);
    }
    for ([_][]const u8{ "project-owners-", "project-editors-", "project-viewers-" }) |prefix| {
        if (!std.mem.startsWith(u8, text, prefix) or text.len == prefix.len) continue;
        // An ID is kept as the number: this fake's one project.
        return try std.mem.concat(arena, u8, &.{ prefix, project_number });
    }
    return null;
}

pub const prevention_refusal: Refusal = .{ .status = 412, .body =
    \\{"error":{"code":412,"message":"The member bindings allUsers and allAuthenticatedUsers are not allowed since public access prevention is enforced.","errors":[{"message":"The member bindings allUsers and allAuthenticatedUsers are not allowed since public access prevention is enforced.","domain":"global","reason":"conditionNotMet","locationType":"header","location":"If-Match"}]}}
};

pub const owner_refusal: Refusal = .{ .status = 403, .body =
    \\{"error":{"code":403,"message":"The owner of the resource is required to have OWNER access.","errors":[{"message":"The owner of the resource is required to have OWNER access.","domain":"global","reason":"forbidden"}]}}
};

pub const both_refusal: Refusal = .{ .status = 409, .body =
    \\{"error":{"code":409,"message":"Cannot provide both a predefinedAcl and access controls.","errors":[{"message":"Cannot provide both a predefinedAcl and access controls.","domain":"global","reason":"conflict"}]}}
};

pub const missing_entry: Refusal = .{ .status = 404, .body =
    \\{"error":{"code":404,"message":"The specified key does not exist.","errors":[{"message":"The specified key does not exist.","domain":"global","reason":"notFound"}]}}
};

/// Uniform access's refusal, in the wording production used for the call.
pub fn uniformRefusal(arena: Allocator, what: enum { read_bucket, write_bucket, read_object, write_object, insert_object }) Allocator.Error!Refusal {
    const more = " Read more at https://cloud.google.com/storage/docs/uniform-bucket-level-access";
    const message = switch (what) {
        .read_bucket => "Cannot get legacy ACL for a bucket that has uniform bucket-level access." ++ more,
        .write_bucket => "Cannot use ACL API to update bucket policy when uniform bucket-level access is enabled." ++ more,
        .read_object => "Cannot get legacy ACL for an object when uniform bucket-level access is enabled." ++ more,
        .write_object => "Cannot update access control for an object when uniform bucket-level access is enabled." ++ more,
        .insert_object => "Cannot insert legacy ACL for an object when uniform bucket-level access is enabled." ++ more,
    };
    return refusal(arena, 400, "invalid", message);
}

pub fn refusal(arena: Allocator, status: u16, reason: []const u8, message: []const u8) Allocator.Error!Refusal {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    jw.write(.{ .@"error" = .{ .code = status, .message = message, .errors = &[_]struct { message: []const u8, domain: []const u8, reason: []const u8 }{.{ .message = message, .domain = "global", .reason = reason }} } }) catch return error.OutOfMemory;
    return .{ .status = status, .body = out.written() };
}

/// The list as a single-entry list call answers it: `items` left out when
/// there are none, as measured.
pub fn listBody(arena: Allocator, list: []const Entry, kind: Kind) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    jw.write(.{
        .kind = if (kind == .bucket) "storage#bucketAccessControls" else "storage#objectAccessControls",
        .items = if (list.len == 0) null else list,
    }) catch return error.OutOfMemory;
    return out.written();
}

/// One entry, or production's 404 when the list has none for `entity`.
pub fn entryBody(arena: Allocator, list: []const Entry, entity: []const u8) Allocator.Error!Refusal {
    const kept = try normalized(arena, entity) orelse entity;
    for (list) |e| if (std.mem.eql(u8, e.entity, kept)) {
        var out: std.Io.Writer.Allocating = .init(arena);
        var jw: std.json.Stringify = .{ .writer = &out.writer };
        jw.write(e) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written() };
    };
    return missing_entry;
}

const testing = std.testing;

test "fake ACL rules: production's expansions, normalizing, the owner, and the refusals" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqual(3, bucketList("projectPrivate").?.len);
    try testing.expectEqual(null, bucketList("bucketOwnerRead"));
    try testing.expectEqual(0, objectList("private").?.len);
    const fresh = try newObjectList(a, "user-w@x.com", null, project_private);
    try testing.expectEqualStrings("user-w@x.com", fresh[3].entity);
    const canned = try newObjectList(a, "user-w@x.com", objectList("bucketOwnerRead"), project_private);
    try testing.expectEqualStrings("user-w@x.com", canned[0].entity);
    try testing.expectEqualStrings("READER", canned[1].role);

    const body = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\[{"entity":"user-Ada@Example.COM","role":"READER"},{"entity":"project-viewers-extractctl","role":"READER"}]
    , .{});
    const kept = (try fromBody(a, body, .object, "user-w@x.com", false)).list;
    try testing.expectEqualStrings("user-ada@example.com", kept[0].entity);
    try testing.expectEqualStrings(viewers, kept[1].entity);
    try testing.expectEqualStrings("user-w@x.com", kept[2].entity);

    const writer_on_object = try std.json.parseFromSliceLeaky(std.json.Value, a, "[{\"entity\":\"allUsers\",\"role\":\"WRITER\"}]", .{});
    try testing.expectEqual(400, (try fromBody(a, writer_on_object, .object, null, false)).refused.status);
    try testing.expectEqual(412, (try fromBody(a, try std.json.parseFromSliceLeaky(std.json.Value, a, "[{\"entity\":\"allUsers\",\"role\":\"READER\"}]", .{}), .bucket, owners, true)).refused.status);
    const demoted = try std.json.parseFromSliceLeaky(std.json.Value, a, "[{\"entity\":\"user-w@x.com\",\"role\":\"READER\"}]", .{});
    try testing.expectEqual(403, (try fromBody(a, demoted, .object, "user-w@x.com", false)).refused.status);
    try testing.expectEqual(400, (try fromBody(a, try std.json.parseFromSliceLeaky(std.json.Value, a, "[{\"entity\":\"someone\",\"role\":\"READER\"}]", .{}), .bucket, owners, false)).refused.status);
    try testing.expectEqualStrings("{\"kind\":\"storage#objectAccessControls\"}", try listBody(a, &.{}, .default_object));
    try testing.expectEqual(404, (try entryBody(a, project_private, "allUsers")).status);
    try testing.expectEqual(200, (try entryBody(a, project_private, viewers)).status);
}
