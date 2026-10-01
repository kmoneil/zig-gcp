//! The README's quick start: finds credentials, uploads an object to Cloud
//! Storage, and publishes a Pub/Sub message that names it.
//!
//!     zig build example-quickstart
//!
//! Name a bucket and a project of your own, and a topic that exists, before
//! running it. tools/check_docs.py holds the README's copy to this file.

const std = @import("std");
const auth = @import("auth");
const pubsub = @import("pubsub");
const storage = @import("storage");

pub fn main(init: std.process.Init) !void {
    // Credentials, found the way Google's own libraries find them: the file
    // GOOGLE_APPLICATION_CREDENTIALS names, gcloud's login, or the metadata
    // server on Google Cloud.
    const lookup = try auth.Lookup.fromEnv(init.environ_map, init.arena.allocator());
    var creds = try auth.findDefault(init.gpa, init.io, lookup, .{});
    defer creds.deinit();

    // An upload that only creates, with a CRC-32C that Cloud Storage
    // checks: a body changed on the way is refused, never stored.
    var gcs = try storage.Client.init(init.gpa, init.io, .{ .token_provider = creds.provider() });
    defer gcs.deinit();
    const report = gcs.bucket("my-bucket").object("reports/q3.txt");
    var stored = try report.upload("hello world\n", .{
        .content_type = "text/plain",
        .preconditions = .does_not_exist,
    });
    defer stored.deinit();

    // A message that names it, for whoever subscribes.
    var ps = try pubsub.Client.init(init.gpa, init.io, .{
        .project_id = "my-project",
        .token_provider = creds.provider(),
    });
    defer ps.deinit();
    var sent = try ps.topic("reports").publish(&.{.{ .data = report.name }}, .{});
    defer sent.deinit();

    std.log.info("stored generation {d}, published message {s}", .{
        stored.value.generation,
        sent.value.message_ids[0],
    });
}
