//! Cloud Storage's Pub/Sub notifications end to end, on both emulators:
//! fake-gcs-server publishes each change to the Pub/Sub emulator, and this
//! library reads the messages back and decodes them. Set
//! STORAGE_EMULATOR_HOST and PUBSUB_EMULATOR_HOST, and start fake-gcs-server
//! with PUBSUB_EMULATOR_HOST in its own environment, or it publishes
//! nowhere (CI does both). With either unset, the test skips.
//!
//! fake-gcs-server 1.56.1 sends no `notificationConfig`, whole-second times
//! in its own zone, and a payload without a metageneration: the decoder
//! takes all of that, and production's own messages are its unit tests'.

const std = @import("std");
const pubsub = @import("pubsub");
const storage = @import("storage");
const testing = std.testing;

const Seen = struct {
    kind: storage.EventType,
    generation: u64,
    overwrote: ?u64,
    overwritten_by: ?u64,
};

test "notifications: an upload, an overwrite, a patch and a delete reach a subscriber as events" {
    const gpa = testing.allocator;
    var env = try testing.environ.createMap(gpa);
    defer env.deinit();
    const gcs_endpoint = storage.Endpoint.fromEnv(&env) orelse return error.SkipZigTest;
    const ps_endpoint = pubsub.Endpoint.fromEnv(&env) orelse return error.SkipZigTest;
    const project = env.get("PUBSUB_PROJECT_ID") orelse "test";

    var random: [4]u8 = undefined;
    testing.io.random(&random);
    var name_buf: [14]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "zigps-{x}", .{random});

    var ps_diag: pubsub.Diagnostics = .{};
    var ps = try pubsub.Client.init(gpa, testing.io, .{ .project_id = project, .endpoint = ps_endpoint, .diagnostics = &ps_diag });
    defer ps.deinit();
    var gcs_diag: storage.Diagnostics = .{};
    var gcs = try storage.Client.init(gpa, testing.io, .{ .project_id = project, .endpoint = gcs_endpoint, .diagnostics = &gcs_diag });
    defer gcs.deinit();

    const topic = ps.topic(name);
    var made_topic = try topic.create(.{});
    made_topic.deinit();
    defer topic.delete() catch {};
    const sub = ps.subscription(name);
    var made_sub = try sub.create(.{ .topic_id = name });
    made_sub.deinit();
    defer sub.delete() catch {};

    const bucket = gcs.bucket(name);
    var made_bucket = try bucket.create(.{});
    made_bucket.deinit();
    defer bucket.delete() catch {};
    var config = try bucket.createNotification(.{
        .topic = .{ .project = project, .topic = name },
        .custom_attributes = &.{.{ .key = "team", .value = "data" }},
        .object_name_prefix = "in/",
    });
    defer config.deinit();
    defer bucket.deleteNotification(config.value.id) catch {};

    const object = bucket.object("in/a.txt");
    var first = try object.upload("one", .{ .content_type = "text/plain" });
    defer first.deinit();
    var second = try object.upload("two", .{ .content_type = "text/plain" });
    defer second.deinit();
    var patched = try object.updateMetadata(.{ .edit = .{ .change = &.{.{ .key = "k", .value = "v" }} } });
    patched.deinit();
    try object.delete(.{});
    // Outside the prefix: no event.
    var outside = try bucket.object("out/b.txt").upload("x", .{});
    outside.deinit();
    defer bucket.object("out/b.txt").delete(.{}) catch {};

    const g1 = first.value.generation;
    const g2 = second.value.generation;
    const want = [_]Seen{
        .{ .kind = .finalize, .generation = g1, .overwrote = null, .overwritten_by = null },
        .{ .kind = .delete, .generation = g1, .overwrote = null, .overwritten_by = g2 },
        .{ .kind = .finalize, .generation = g2, .overwrote = g1, .overwritten_by = null },
        .{ .kind = .metadata_update, .generation = g2, .overwrote = null, .overwritten_by = null },
        .{ .kind = .delete, .generation = g2, .overwrote = null, .overwritten_by = null },
    };

    // The emulator publishes from tasks of its own: wait for every event.
    var seen: std.ArrayList(Seen) = .empty;
    defer seen.deinit(gpa);
    var keys: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = keys.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        keys.deinit(gpa);
    }
    const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 30_000;
    while (seen.items.len < want.len and std.Io.Clock.awake.now(testing.io).toMilliseconds() < deadline) {
        var pulled = try sub.pull(.{ .return_immediately = true });
        defer pulled.deinit();
        if (pulled.value.messages.len == 0) {
            try testing.io.sleep(.fromMilliseconds(200), .awake);
            continue;
        }
        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(gpa);
        for (pulled.value.messages) |message| {
            try ids.append(gpa, message.ack_id);
            var event = try storage.decodeEvent(gpa, message, .{});
            defer event.deinit();
            const e = event.value;
            try testing.expectEqualStrings(name, e.bucket);
            try testing.expectEqualStrings("in/a.txt", e.object);
            try testing.expectEqualStrings("team", e.custom_attributes[0].key);
            try testing.expectEqualStrings("data", e.custom_attributes[0].value);
            try testing.expectEqualStrings("in/a.txt", e.info.?.name);
            // A repeat delivery is the same change: counted once.
            const gop = try keys.getOrPut(gpa, e.key);
            if (gop.found_existing) continue;
            gop.key_ptr.* = try gpa.dupe(u8, e.key);
            try seen.append(gpa, .{
                .kind = e.kind,
                .generation = e.generation,
                .overwrote = e.overwrote_generation,
                .overwritten_by = e.overwritten_by_generation,
            });
        }
        try sub.ack(ids.items);
    }
    // Every change once, in any order: Cloud Storage keeps none.
    try testing.expectEqual(want.len, seen.items.len);
    for (want) |w| {
        const found = for (seen.items) |s| {
            if (std.meta.eql(s, w)) break true;
        } else false;
        if (!found) {
            std.debug.print("missing {any}; saw {any}\n", .{ w, seen.items });
            return error.TestExpectedEqual;
        }
    }
}
