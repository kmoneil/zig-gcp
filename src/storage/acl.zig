//! Access control lists: how an entity and a role are spelled on the wire,
//! the canned lists' names in both APIs, the entries a resource carries,
//! and the two refusals an ACL meets that this library names.
//!
//! Measured in production on 2026-10-05:
//!
//! - An entity is `user-EMAIL`, `group-EMAIL`, `domain-DOMAIN`,
//!   `project-TEAM-NUMBER`, `allUsers` or `allAuthenticatedUsers`. Emails
//!   come back in lower case, and a project named by ID is stored under
//!   its number. Roles are upper case: `reader` is refused.
//! - On a bucket with uniform bucket-level access, every ACL call, and
//!   every write carrying an `acl` or a predefined list, is 400 `invalid`
//!   in one of five wordings, each naming uniform bucket-level access and
//!   ACLs or access control: `error.UniformAccessEnabled` here.
//! - Under public access prevention, a grant to `allUsers` or
//!   `allAuthenticatedUsers`, by ACL, predefined list or IAM, is 412
//!   `conditionNotMet`, the reason a failed precondition has, told apart
//!   only by its message: `error.PublicAccessPrevented` here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const core = @import("core");
const types = @import("types.zig");

const AclEntity = types.AclEntity;

/// An entity as Cloud Storage spells it. Every string reads as some
/// entity, an unknown one as `.other`, and `writeEntity` gives back
/// exactly the string it was read from.
pub fn parseEntity(text: []const u8) AclEntity {
    if (std.mem.eql(u8, text, "allUsers")) return .all_users;
    if (std.mem.eql(u8, text, "allAuthenticatedUsers")) return .all_authenticated_users;
    if (std.mem.startsWith(u8, text, "user-")) return .{ .user = text["user-".len..] };
    if (std.mem.startsWith(u8, text, "group-")) return .{ .group = text["group-".len..] };
    if (std.mem.startsWith(u8, text, "domain-")) return .{ .domain = text["domain-".len..] };
    if (std.mem.startsWith(u8, text, "project-")) {
        const rest = text["project-".len..];
        for (std.enums.values(AclEntity.Team)) |team| {
            const name = @tagName(team);
            if (rest.len > name.len and std.mem.startsWith(u8, rest, name) and rest[name.len] == '-')
                return .{ .project = .{ .team = team, .number = rest[name.len + 1 ..] } };
        }
    }
    return .{ .other = text };
}

/// Writes `entity` as Cloud Storage spells it.
pub fn writeEntity(w: *Writer, entity: AclEntity) Writer.Error!void {
    switch (entity) {
        .user => |email| try w.print("user-{s}", .{email}),
        .group => |email| try w.print("group-{s}", .{email}),
        .domain => |domain| try w.print("domain-{s}", .{domain}),
        .project => |p| try w.print("project-{t}-{s}", .{ p.team, p.number }),
        .all_users => try w.writeAll("allUsers"),
        .all_authenticated_users => try w.writeAll("allAuthenticatedUsers"),
        .other => |text| try w.writeAll(text),
    }
}

/// `entity` spelled out in `arena`.
pub fn entityText(arena: Allocator, entity: AclEntity) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeEntity(&out.writer, entity) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Whether two entities name the same grantee as Cloud Storage stores it:
/// emails and domains compared without regard to ASCII case, which the
/// server lowers.
pub fn sameEntity(a: AclEntity, b: AclEntity) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .user => |email| std.ascii.eqlIgnoreCase(email, b.user),
        .group => |email| std.ascii.eqlIgnoreCase(email, b.group),
        .domain => |domain| std.ascii.eqlIgnoreCase(domain, b.domain),
        .project => |p| p.team == b.project.team and std.mem.eql(u8, p.number, b.project.number),
        .all_users, .all_authenticated_users => true,
        .other => |text| std.mem.eql(u8, text, b.other),
    };
}

/// A role as the wire spells it, or null for `.unknown`, which is never
/// sent.
pub fn roleName(role: types.AclRole) ?[]const u8 {
    return switch (role) {
        .owner => "OWNER",
        .writer => "WRITER",
        .reader => "READER",
        .unknown => null,
    };
}

/// The role a wire name means; anything else is `.unknown`.
pub fn roleOf(name: []const u8) types.AclRole {
    if (std.mem.eql(u8, name, "OWNER")) return .owner;
    if (std.mem.eql(u8, name, "WRITER")) return .writer;
    if (std.mem.eql(u8, name, "READER")) return .reader;
    return .unknown;
}

/// An object's canned list as the JSON API's `predefinedAcl`,
/// `destinationPredefinedAcl` and `predefinedDefaultObjectAcl` name it.
pub fn predefinedName(acl: types.PredefinedAcl) []const u8 {
    return switch (acl) {
        .authenticated_read => "authenticatedRead",
        .bucket_owner_full_control => "bucketOwnerFullControl",
        .bucket_owner_read => "bucketOwnerRead",
        .private => "private",
        .project_private => "projectPrivate",
        .public_read => "publicRead",
    };
}

/// The list `predefinedName` names, or null for any other text.
pub fn predefinedOf(name: []const u8) ?types.PredefinedAcl {
    for (std.enums.values(types.PredefinedAcl)) |acl| {
        if (std.mem.eql(u8, predefinedName(acl), name)) return acl;
    }
    return null;
}

/// The same list as the XML API's `x-goog-acl` header names it.
pub fn predefinedXmlName(acl: types.PredefinedAcl) []const u8 {
    return switch (acl) {
        .authenticated_read => "authenticated-read",
        .bucket_owner_full_control => "bucket-owner-full-control",
        .bucket_owner_read => "bucket-owner-read",
        .private => "private",
        .project_private => "project-private",
        .public_read => "public-read",
    };
}

/// A bucket's canned list as `predefinedAcl` names it.
pub fn predefinedBucketName(acl: types.PredefinedBucketAcl) []const u8 {
    return switch (acl) {
        .authenticated_read => "authenticatedRead",
        .private => "private",
        .project_private => "projectPrivate",
        .public_read => "publicRead",
        .public_read_write => "publicReadWrite",
    };
}

/// One entry as the wire carries it, in a resource's `acl` or in a list.
/// `kind`, `id`, `selfLink`, `etag`, `bucket`, `object` and `generation`
/// are left unread: the resource around it says them.
pub const WireEntry = struct {
    entity: ?[]const u8 = null,
    role: ?[]const u8 = null,
    email: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    entityId: ?[]const u8 = null,
};

/// A resource's `acl`, or null when it carries none: not asked for, not
/// readable by the caller, or uniform access. An entry without an entity
/// is `InvalidResponse`, since nothing could name it again.
pub fn entriesFromWire(arena: Allocator, wire: ?[]const WireEntry) error{ InvalidResponse, OutOfMemory }!?[]const types.AclEntry {
    const listed = wire orelse return null;
    const entries = try arena.alloc(types.AclEntry, listed.len);
    for (listed, entries) |w, *entry| entry.* = try entryFromWire(w);
    return entries;
}

pub fn entryFromWire(w: WireEntry) error{InvalidResponse}!types.AclEntry {
    const entity = w.entity orelse return error.InvalidResponse;
    if (entity.len == 0) return error.InvalidResponse;
    return .{
        .entity = parseEntity(entity),
        .role = roleOf(w.role orelse ""),
        .email = nonEmpty(w.email),
        .domain = nonEmpty(w.domain),
        .entity_id = nonEmpty(w.entityId),
    };
}

/// A resource's `owner`, or null when it carries none or names no entity.
pub fn ownerFromWire(wire: ?WireOwner) ?AclEntity {
    const owner = wire orelse return null;
    const entity = nonEmpty(owner.entity) orelse return null;
    return parseEntity(entity);
}

pub const WireOwner = struct { entity: ?[]const u8 = null };

fn nonEmpty(text: ?[]const u8) ?[]const u8 {
    const t = text orelse return null;
    return if (t.len == 0) null else t;
}

/// Whether a failed request was refused because its bucket has uniform
/// bucket-level access: 400, in one of the wordings measured, each naming
/// uniform bucket-level access and ACLs or access control. Other refusals
/// that name uniform access, such as a bucket setting that needs it, are
/// not this.
pub fn isUniformAccessRefusal(err: anyerror, diag: *const core.Diagnostics) bool {
    if (err != error.InvalidArgument) return false;
    const message = diag.message();
    if (std.ascii.findIgnoreCase(message, "uniform bucket-level access") == null) return false;
    return std.mem.indexOf(u8, message, "ACL") != null or
        std.ascii.findIgnoreCase(message, "access control") != null;
}

/// Whether a failed request was refused for granting `allUsers` or
/// `allAuthenticatedUsers` under public access prevention: 412, told apart
/// from a failed precondition by its message.
pub fn isPublicAccessRefusal(err: anyerror, diag: *const core.Diagnostics) bool {
    return err == error.FailedPrecondition and
        std.ascii.findIgnoreCase(diag.message(), "public access prevention") != null;
}

const testing = std.testing;
const test_util = @import("test_util.zig");

fn expectEntity(text: []const u8, expected: AclEntity) !void {
    const parsed = parseEntity(text);
    try testing.expect(sameEntity(expected, parsed));
    try testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(parsed));
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeEntity(&w, parsed);
    try testing.expectEqualStrings(text, w.buffered());
}

test "entities: every form production sent reads and writes back" {
    try expectEntity("user-zigps-acl-c8db87@extractctl.iam.gserviceaccount.com", .{ .user = "zigps-acl-c8db87@extractctl.iam.gserviceaccount.com" });
    try expectEntity("group-cloud-storage-analytics@google.com", .{ .group = "cloud-storage-analytics@google.com" });
    try expectEntity("domain-example.com", .{ .domain = "example.com" });
    try expectEntity("project-owners-82150720798", .{ .project = .{ .team = .owners, .number = "82150720798" } });
    try expectEntity("project-editors-82150720798", .{ .project = .{ .team = .editors, .number = "82150720798" } });
    try expectEntity("project-viewers-82150720798", .{ .project = .{ .team = .viewers, .number = "82150720798" } });
    try expectEntity("allUsers", .all_users);
    try expectEntity("allAuthenticatedUsers", .all_authenticated_users);
    // Not modeled, kept whole.
    try expectEntity("project-admins-1", .{ .other = "project-admins-1" });
    try expectEntity("project-owners", .{ .other = "project-owners" });
    try expectEntity("allusers", .{ .other = "allusers" });
    try expectEntity("someone", .{ .other = "someone" });
    try expectEntity("", .{ .other = "" });
}

test "entities compare as the server stores them" {
    try testing.expect(sameEntity(.{ .user = "ZiGpS@Example.com" }, .{ .user = "zigps@example.com" }));
    try testing.expect(sameEntity(.{ .domain = "Example.COM" }, .{ .domain = "example.com" }));
    try testing.expect(!sameEntity(.{ .user = "a@x" }, .{ .group = "a@x" }));
    try testing.expect(!sameEntity(.{ .project = .{ .team = .owners, .number = "1" } }, .{ .project = .{ .team = .editors, .number = "1" } }));
    try testing.expect(!sameEntity(.{ .project = .{ .team = .owners, .number = "1" } }, .{ .project = .{ .team = .owners, .number = "2" } }));
    try testing.expect(sameEntity(.all_users, .all_users));
    try testing.expect(!sameEntity(.all_users, .all_authenticated_users));
    // `.other` is compared exactly: nothing is known about its case.
    try testing.expect(!sameEntity(.{ .other = "X" }, .{ .other = "x" }));
}

test "roles: only the upper-case names, which production takes" {
    for ([_]types.AclRole{ .owner, .writer, .reader }) |role| try testing.expectEqual(role, roleOf(roleName(role).?));
    try testing.expectEqual(null, roleName(.unknown));
    try testing.expectEqual(.unknown, roleOf("reader"));
    try testing.expectEqual(.unknown, roleOf("ADMIN"));
    try testing.expectEqual(.unknown, roleOf(""));
}

test "predefined lists: the JSON and XML names" {
    try testing.expectEqualStrings("bucketOwnerFullControl", predefinedName(.bucket_owner_full_control));
    try testing.expectEqualStrings("bucket-owner-full-control", predefinedXmlName(.bucket_owner_full_control));
    try testing.expectEqualStrings("projectPrivate", predefinedName(.project_private));
    try testing.expectEqualStrings("project-private", predefinedXmlName(.project_private));
    try testing.expectEqualStrings("publicReadWrite", predefinedBucketName(.public_read_write));
    for (std.enums.values(types.PredefinedAcl)) |acl| try testing.expectEqual(acl, predefinedOf(predefinedName(acl)).?);
    try testing.expectEqual(null, predefinedOf("project-private"));
    try testing.expectEqual(null, predefinedOf(""));
    // Every JSON name is the XML name in camel case.
    for (std.enums.values(types.PredefinedAcl)) |acl| {
        var camel: [64]u8 = undefined;
        var n: usize = 0;
        var upper = false;
        for (predefinedXmlName(acl)) |c| {
            if (c == '-') {
                upper = true;
                continue;
            }
            camel[n] = if (upper) std.ascii.toUpper(c) else c;
            upper = false;
            n += 1;
        }
        try testing.expectEqualStrings(predefinedName(acl), camel[0..n]);
    }
}

test "entries decode as production sent them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = (try entriesFromWire(a, &.{
        .{ .entity = "project-owners-82150720798", .role = "OWNER" },
        .{ .entity = "user-zigps-acl-c8db87@extractctl.iam.gserviceaccount.com", .role = "READER", .email = "zigps-acl-c8db87@extractctl.iam.gserviceaccount.com" },
        .{ .entity = "group-cloud-storage-analytics@google.com", .role = "WRITER", .email = "cloud-storage-analytics@google.com" },
        .{ .entity = "domain-example.com", .role = "LEGACY", .domain = "example.com", .entityId = "" },
    })).?;
    try testing.expectEqual(4, entries.len);
    try testing.expectEqualStrings("82150720798", entries[0].entity.project.number);
    try testing.expectEqual(.reader, entries[1].role);
    try testing.expectEqualStrings("zigps-acl-c8db87@extractctl.iam.gserviceaccount.com", entries[1].email.?);
    try testing.expectEqual(.writer, entries[2].role);
    try testing.expectEqual(.unknown, entries[3].role);
    try testing.expectEqualStrings("example.com", entries[3].domain.?);
    try testing.expectEqual(null, entries[3].entity_id);

    try testing.expectEqual(null, try entriesFromWire(a, null));
    try testing.expectEqual(0, (try entriesFromWire(a, &.{})).?.len);
    try testing.expectError(error.InvalidResponse, entriesFromWire(a, &.{.{ .role = "OWNER" }}));
    try testing.expectError(error.InvalidResponse, entriesFromWire(a, &.{.{ .entity = "", .role = "OWNER" }}));

    try testing.expect(sameEntity(.{ .user = "zig-gcp@extractctl.iam.gserviceaccount.com" }, ownerFromWire(.{ .entity = "user-zig-gcp@extractctl.iam.gserviceaccount.com" }).?));
    try testing.expectEqual(null, ownerFromWire(null));
    try testing.expectEqual(null, ownerFromWire(.{}));
    try testing.expectEqual(null, ownerFromWire(.{ .entity = "" }));
}

fn diagnosed(message: []const u8) core.Diagnostics {
    var d: core.Diagnostics = .{};
    d.set(400, "invalid", message);
    return d;
}

test "the uniform access refusals are the five wordings measured, and nothing else" {
    for ([_][]const u8{
        "Cannot get legacy ACL for a bucket that has uniform bucket-level access. Read more at https://cloud.google.com/storage/docs/uniform-bucket-level-access",
        "Cannot use ACL API to update bucket policy when uniform bucket-level access is enabled. Read more at https://cloud.google.com/storage/docs/uniform-bucket-level-access",
        "Cannot get legacy ACL for an object when uniform bucket-level access is enabled. Read more at https://cloud.google.com/storage/docs/uniform-bucket-level-access",
        "Cannot update access control for an object when uniform bucket-level access is enabled. Read more at https://cloud.google.com/storage/docs/uniform-bucket-level-access",
        "Cannot insert legacy ACL for an object when uniform bucket-level access is enabled. Read more at https://cloud.google.com/storage/docs/uniform-bucket-level-access",
    }) |message| {
        const d = diagnosed(message);
        try testing.expect(isUniformAccessRefusal(error.InvalidArgument, &d));
        try testing.expect(!isUniformAccessRefusal(error.FailedPrecondition, &d));
    }
    for ([_][]const u8{
        // A setting that needs uniform access is not an ACL refusal.
        "Uniform bucket-level access cannot be disabled after 90 days.",
        "Invalid value for: WRITER is not a valid value",
        "",
    }) |message| {
        const d = diagnosed(message);
        try testing.expect(!isUniformAccessRefusal(error.InvalidArgument, &d));
    }
}

test "public access prevention is told apart from a failed precondition" {
    const refused = diagnosed("The member bindings allUsers and allAuthenticatedUsers are not allowed since public access prevention is enforced.");
    try testing.expect(isPublicAccessRefusal(error.FailedPrecondition, &refused));
    try testing.expect(!isPublicAccessRefusal(error.InvalidArgument, &refused));
    const stale = diagnosed("At least one of the pre-conditions you specified did not hold.");
    try testing.expect(!isPublicAccessRefusal(error.FailedPrecondition, &stale));
}

fn roundTripProperty(_: void, input: []const u8) anyerror!void {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const entity = parseEntity(input);
    try writeEntity(&out.writer, entity);
    try testing.expectEqualStrings(input, out.written());
    try testing.expect(sameEntity(entity, parseEntity(out.written())));
}

test "fuzz: every string reads as an entity and writes back unchanged" {
    try test_util.fuzzBytes({}, roundTripProperty, .{ .corpus = &.{
        "",                    "user-",                                "user-a@b",              "group-x",
        "domain-y",            "project-",                             "project-owners-",       "project-owners-1",
        "project-viewers-x-y", "allUsers",                             "allAuthenticatedUsers", "project-ownersx",
        "user-\xff\x00",       "project-editors-12345678901234567890",
    } });
}

const object_answer: test_util.FakeTransport.Reply = .{ .respond = .{ .body = "{\"name\":\"a\",\"bucket\":\"b\",\"generation\":\"7\"}" } };

test "golden: a predefined list on every object write, under its JSON name" {
    {
        var h: test_util.Harness = undefined;
        try h.init(&.{object_answer}, .{});
        defer h.deinit();
        var info = try h.client.bucket("b").object("a").upload("x", .{ .predefined_acl = .bucket_owner_read });
        defer info.deinit();
        try testing.expectEqualStrings(
            "https://storage.googleapis.com/upload/storage/v1/b/b/o?uploadType=multipart&predefinedAcl=bucketOwnerRead",
            (try h.fake.streamRequest(0)).url,
        );
    }
    {
        var h: test_util.Harness = undefined;
        try h.init(&.{
            .{ .respond = .{ .body = "", .headers = &.{.{ .name = "Location", .value = "https://storage.example.test/upload/session/s1" }} } },
            object_answer,
        }, .{});
        defer h.deinit();
        var reader: std.Io.Reader = .fixed("x");
        var info = try h.client.bucket("b").object("a").uploadFrom(&reader, .{ .predefined_acl = .private, .size = 1 });
        defer info.deinit();
        try testing.expectEqualStrings(
            "https://storage.googleapis.com/upload/storage/v1/b/b/o?uploadType=resumable&predefinedAcl=private",
            (try h.fake.streamRequest(0)).url,
        );
    }
    {
        var h: test_util.Harness = undefined;
        try h.init(&.{.{ .respond = .{ .body = "{\"done\":true,\"totalBytesRewritten\":\"1\",\"objectSize\":\"1\",\"resource\":{\"name\":\"c\",\"generation\":\"8\"}}" } }}, .{});
        defer h.deinit();
        const b = h.client.bucket("b");
        var info = try b.object("a").copyTo(b.object("c"), .{ .predefined_acl = .project_private });
        defer info.deinit();
        try testing.expectEqualStrings(
            "https://storage.googleapis.com/storage/v1/b/b/o/a/rewriteTo/b/b/o/c?destinationPredefinedAcl=projectPrivate",
            (try h.fake.request(0)).url,
        );
    }
    {
        var h: test_util.Harness = undefined;
        try h.init(&.{object_answer}, .{});
        defer h.deinit();
        var info = try h.client.bucket("b").object("a").composeFrom(&.{.{ .name = "p1" }}, .{
            .predefined_acl = .private,
            .preconditions = .does_not_exist,
        });
        defer info.deinit();
        try testing.expectEqualStrings(
            "https://storage.googleapis.com/storage/v1/b/b/o/a/compose?ifGenerationMatch=0&destinationPredefinedAcl=private",
            (try h.fake.request(0)).url,
        );
    }
    {
        // A patch sends the list beside an empty `acl`, which alone the
        // server ignores and which keeps a list out of the request.
        var h: test_util.Harness = undefined;
        try h.init(&.{object_answer}, .{});
        defer h.deinit();
        var info = try h.client.bucket("b").object("a").updateMetadata(.{
            .content_type = "text/plain",
            .predefined_acl = .bucket_owner_full_control,
            .preconditions = .{ .if_metageneration_match = 2 },
        });
        defer info.deinit();
        try h.expectRequest(
            0,
            .PATCH,
            "https://storage.googleapis.com/storage/v1/b/b/o/a?ifMetagenerationMatch=2&predefinedAcl=bucketOwnerFullControl",
            "{\"contentType\":\"text/plain\",\"acl\":[]}",
        );
    }
}

test "golden: a bucket's predefined lists on create and update, and their refusals" {
    {
        var h: test_util.Harness = undefined;
        try h.init(&.{.{ .respond = .{ .body = "{\"name\":\"b\",\"metageneration\":\"1\"}" } }}, .{});
        defer h.deinit();
        var info = try h.client.bucket("b").create(.{ .predefined_acl = .private, .predefined_default_object_acl = .bucket_owner_read });
        defer info.deinit();
        const sent = try h.fake.request(0);
        try testing.expectEqualStrings(
            "https://storage.googleapis.com/storage/v1/b?project=extractctl&predefinedAcl=private&predefinedDefaultObjectAcl=bucketOwnerRead",
            sent.url,
        );
        // The body holds no list: a create has none to replace.
        try testing.expect(std.mem.indexOf(u8, sent.body.?, "acl") == null);
    }
    {
        var h: test_util.Harness = undefined;
        try h.init(&.{
            .{ .respond = .{ .body = "{\"name\":\"b\",\"metageneration\":\"4\"}" } },
            .{ .respond = .{ .body = "{\"name\":\"b\",\"metageneration\":\"5\"}" } },
        }, .{});
        defer h.deinit();
        const b = h.client.bucket("b");
        var one = try b.update(.{ .predefined_acl = .project_private, .if_metageneration_match = 3 });
        defer one.deinit();
        try h.expectRequest(0, .PATCH, "https://storage.googleapis.com/storage/v1/b/b?projection=noAcl&ifMetagenerationMatch=3&predefinedAcl=projectPrivate", "{\"acl\":[]}");
        var two = try b.update(.{ .predefined_default_object_acl = .private });
        defer two.deinit();
        try h.expectRequest(1, .PATCH, "https://storage.googleapis.com/storage/v1/b/b?projection=noAcl&predefinedDefaultObjectAcl=private", "{\"defaultObjectAcl\":[]}");

        // Uniform access keeps no lists: refused before anything is sent.
        try testing.expectError(error.InvalidBucketSettings, b.create(.{ .uniform_bucket_level_access = true, .predefined_acl = .private }));
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), "uniform bucket-level access") != null);
        try testing.expectError(error.InvalidBucketSettings, b.create(.{ .hierarchical_namespace = true, .predefined_default_object_acl = .private }));
        try testing.expectError(error.InvalidBucketSettings, b.update(.{ .uniform_bucket_level_access = true, .predefined_acl = .private }));
        try h.expectRequestCount(2);
    }
    {
        // Turning uniform access off and applying a list in one update is
        // the order that works, so it is sent.
        var h: test_util.Harness = undefined;
        try h.init(&.{.{ .respond = .{ .body = "{\"name\":\"b\",\"metageneration\":\"6\"}" } }}, .{});
        defer h.deinit();
        var info = try h.client.bucket("b").update(.{ .uniform_bucket_level_access = false, .predefined_acl = .private });
        defer info.deinit();
        try h.expectRequestCount(1);
    }
}

const ubla_upload_body =
    \\{"error":{"code":400,"message":"Cannot insert legacy ACL for an object when uniform bucket-level access is enabled. Read more at https://cloud.google.com/storage/docs/uniform-bucket-level-access","errors":[{"message":"Cannot insert legacy ACL for an object when uniform bucket-level access is enabled. Read more at https://cloud.google.com/storage/docs/uniform-bucket-level-access","domain":"global","reason":"invalid"}]}}
;
const pap_upload_body =
    \\{"error":{"code":412,"message":"The member bindings allUsers and allAuthenticatedUsers are not allowed since public access prevention is enforced.","errors":[{"message":"The member bindings allUsers and allAuthenticatedUsers are not allowed since public access prevention is enforced.","domain":"global","reason":"conditionNotMet","locationType":"header","location":"If-Match"}]}}
;
const stale_patch_body =
    \\{"error":{"code":412,"message":"At least one of the pre-conditions you specified did not hold.","errors":[{"message":"At least one of the pre-conditions you specified did not hold.","domain":"global","reason":"conditionNotMet","locationType":"header","location":"If-Match"}]}}
;

test "production's refusals arrive as their own errors, and are never retried" {
    {
        var h: test_util.Harness = undefined;
        try h.init(&.{.{ .respond = .{ .status = 400, .body = ubla_upload_body } }}, .{});
        defer h.deinit();
        try testing.expectError(error.UniformAccessEnabled, h.client.bucket("b").object("a").upload("x", .{
            .predefined_acl = .private,
            .preconditions = .does_not_exist,
        }));
        try testing.expectEqualStrings("invalid", h.diag.status());
        try testing.expectEqual(1, h.fake.stream_requests.items.len);
    }
    {
        var h: test_util.Harness = undefined;
        try h.init(&.{.{ .respond = .{ .status = 412, .body = pap_upload_body } }}, .{});
        defer h.deinit();
        try testing.expectError(error.PublicAccessPrevented, h.client.bucket("b").object("a").upload("x", .{
            .predefined_acl = .public_read,
            .preconditions = .does_not_exist,
        }));
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), "public access prevention") != null);
        try testing.expectEqual(1, h.fake.stream_requests.items.len);
    }
    {
        // The same status for a stale guard stays what it was.
        var h: test_util.Harness = undefined;
        try h.init(&.{.{ .respond = .{ .status = 412, .body = stale_patch_body } }}, .{});
        defer h.deinit();
        try testing.expectError(error.FailedPrecondition, h.client.bucket("b").object("a").updateMetadata(.{
            .predefined_acl = .private,
            .preconditions = .{ .if_metageneration_match = 1 },
        }));
    }
    {
        var h: test_util.Harness = undefined;
        try h.init(&.{.{ .respond = .{ .status = 400, .body = ubla_upload_body } }}, .{});
        defer h.deinit();
        try testing.expectError(error.UniformAccessEnabled, h.client.bucket("b").update(.{ .predefined_default_object_acl = .private }));
    }
}

/// Cancels the first session chunk past the first 256 KiB, once: the first
/// run of a checkpointed upload stores a chunk and dies.
const DiesAtSecondChunk = struct {
    done: bool = false,
    fn plan(self: *DiesAtSecondChunk) test_util.FakeMultipart.FaultPlan {
        return .{ .ctx = self, .decide = decide };
    }
    fn decide(ctx: ?*anyopaque, kind: test_util.FakeMultipart.Kind, part: u32) test_util.FakeMultipart.Fault {
        const self: *DiesAtSecondChunk = @ptrCast(@alignCast(ctx.?));
        if (kind != .session_put or part != 256 * 1024 + 1 or self.done) return .none;
        self.done = true;
        return .canceled;
    }
};

/// Cancels every part past the first: the first run of a checkpointed
/// parallel upload sends one part and dies.
const DiesAfterFirstPart = struct {
    parts: u32 = 0,
    fn plan(self: *DiesAfterFirstPart) test_util.FakeMultipart.FaultPlan {
        return .{ .ctx = self, .decide = decide };
    }
    fn decide(ctx: ?*anyopaque, kind: test_util.FakeMultipart.Kind, _: u32) test_util.FakeMultipart.Fault {
        const self: *DiesAfterFirstPart = @ptrCast(@alignCast(ctx.?));
        if (kind != .part) return .none;
        self.parts += 1;
        return if (self.parts > 1) .canceled else .none;
    }
};

test "against the fake: a checkpointed upload resumes with the list it began with, and starts over with another" {
    const Client = @import("Client.zig");
    const checkpoint = @import("checkpoint.zig");
    const logging = @import("logging.zig");
    var data: [600 * 1024]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(41);
    prng.random().bytes(&data);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source", .data = &data });
    const file = try tmp.dir.openFile(testing.io, "source", .{});
    defer file.close(testing.io);

    for ([_]?types.PredefinedAcl{ .private, .bucket_owner_read, null }) |second| {
        errdefer std.debug.print("resumed with {?t}\n", .{second});
        for ([_]bool{ false, true }) |parallel_upload| {
            errdefer std.debug.print("parallel: {}\n", .{parallel_upload});
            var fake: test_util.FakeMultipart = .init(testing.allocator, testing.io);
            defer fake.deinit();
            fake.min_part_size = 1024;
            var token: core.StaticToken = .{ .token = "ya29.t" };
            var diag: core.Diagnostics = .{};
            var client: Client = try .init(testing.allocator, fake.io, .{
                .project_id = "extractctl",
                .token_provider = token.provider(),
                .transport = fake.transport(),
                .diagnostics = &diag,
                .chunk_size = 256 * 1024,
                .single_request_limit = 256 * 1024,
                .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
            });
            defer client.deinit();
            client.multipart_test = .{ .min_part_size = 1024 };
            var saved: test_util.MemoryCheckpoint = .{ .gpa = testing.allocator };
            defer saved.deinit();
            const target = client.bucket("b").object("o");

            // The first run, with `.private`, dies partway.
            var dies_chunk: DiesAtSecondChunk = .{};
            var dies_part: DiesAfterFirstPart = .{};
            fake.faults = if (parallel_upload) dies_part.plan() else dies_chunk.plan();
            const first = if (parallel_upload)
                target.uploadParallel(.{ .file = file }, .{ .part_size = 100 * 1024, .concurrency = 1, .checkpoint = saved.checkpoint(), .predefined_acl = .private })
            else
                target.uploadFile(file, .{ .checkpoint = saved.checkpoint(), .predefined_acl = .private });
            try testing.expectError(error.Canceled, first);
            fake.faults = null;
            {
                var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
                defer arena_state.deinit();
                const recorded = switch (try checkpoint.parse(arena_state.allocator(), saved.stored.?)) {
                    .upload_file => |s| s.predefined_acl,
                    .upload_parallel => |s| s.predefined_acl,
                    .download_parallel => unreachable,
                };
                try testing.expectEqual(.private, recorded.?);
            }

            // The second run resumes, or starts over.
            const starts_before = if (parallel_upload) fake.counts.starts else fake.counts.session_starts;
            logging.capture.reset();
            var info = if (parallel_upload)
                try target.uploadParallel(.{ .file = file }, .{ .part_size = 100 * 1024, .concurrency = 1, .checkpoint = saved.checkpoint(), .predefined_acl = second })
            else
                try target.uploadFile(file, .{ .checkpoint = saved.checkpoint(), .predefined_acl = second });
            info.deinit();
            const starts = (if (parallel_upload) fake.counts.starts else fake.counts.session_starts) - starts_before;
            const o = fake.object("o").?;
            try testing.expectEqualSlices(u8, &data, o.bytes);
            // The object has the list the upload that made it began with.
            try testing.expectEqual(second, o.predefined_acl);
            if (second == .private) {
                try testing.expectEqual(0, starts);
            } else {
                try testing.expectEqual(1, starts);
                try testing.expect(std.mem.indexOf(u8, logging.capture.text(), "another predefined access control list") != null);
            }
            try testing.expectEqual(0, fake.openUploads());
            try testing.expectEqual(0, fake.openSessions());
            try testing.expectEqual(null, saved.stored);
        }
    }
}
