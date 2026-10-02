//! Code the documentation shows, compiled and run with the unit tests so
//! that it cannot drift from the library. tools/check_docs.py holds each
//! block marked `<!-- snippet: tests/docs_examples.zig#name -->` to the
//! lines between `// snippet: name` and `// end snippet` here.

// snippet: testing-with-fakes
const std = @import("std");
const core = @import("core");
const pubsub = @import("pubsub");

test "a publish, answered by a fake" {
    var fake: core.testing.FakeTransport = .init(std.testing.allocator, &.{
        .{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } },
    });
    defer fake.deinit();
    var tokens: core.testing.FakeTokenProvider = .{};
    var client = try pubsub.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = tokens.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();

    var sent = try client.topic("orders").publish(&.{.{ .data = "hello" }}, .{});
    defer sent.deinit();
    try std.testing.expectEqualStrings("1", sent.value.message_ids[0]);

    const request = try fake.request(0);
    try std.testing.expectEqualStrings(
        "https://pubsub.googleapis.com/v1/projects/my-project/topics/orders:publish",
        request.url,
    );
}
// end snippet

const secret_manager = @import("secret_manager");

// snippet: secret-set-label
/// Sets one label and keeps the others. The update replaces every label,
/// so it goes under the etag the read returned: another change made in
/// between is error.Aborted rather than lost, and the loop reads again.
fn setLabel(gpa: std.mem.Allocator, secret: secret_manager.Secret, key: []const u8, value: []const u8) !void {
    while (true) {
        var read = try secret.get();
        defer read.deinit();
        var labels: std.ArrayList(secret_manager.Label) = .empty;
        defer labels.deinit(gpa);
        for (read.value.labels) |l| {
            if (!std.mem.eql(u8, l.key, key)) try labels.append(gpa, l);
        }
        try labels.append(gpa, .{ .key = key, .value = value });

        var updated = secret.update(.{
            .labels = .{ .set = labels.items },
            .etag = read.value.etag,
        }) catch |err| switch (err) {
            error.Aborted => continue, // changed since the read
            else => return err,
        };
        updated.deinit();
        return;
    }
}
// end snippet

test "setLabel reads again when the secret changed in between" {
    var fake: core.testing.FakeTransport = .init(std.testing.allocator, &.{
        .{ .respond = .{ .body = "{\"name\":\"projects/1/secrets/db\",\"etag\":\"\\\"e1\\\"\",\"labels\":{\"team\":\"payments\"}}" } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"status\":\"FAILED_PRECONDITION\",\"message\":\"The etag provided in the request does not match the resource's current etag.\"}}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/1/secrets/db\",\"etag\":\"\\\"e2\\\"\",\"labels\":{\"team\":\"payments\",\"tier\":\"gold\"}}" } },
        .{ .respond = .{ .body = "{\"name\":\"projects/1/secrets/db\",\"etag\":\"\\\"e3\\\"\"}" } },
    });
    defer fake.deinit();
    var tokens: core.testing.FakeTokenProvider = .{};
    var client = try secret_manager.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "my-project",
        .token_provider = tokens.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();

    try setLabel(std.testing.allocator, client.secret("db"), "env", "prod");
    try std.testing.expectEqual(4, fake.requests.items.len);
    try std.testing.expectEqualStrings(
        "{\"labels\":{\"team\":\"payments\",\"tier\":\"gold\",\"env\":\"prod\"},\"etag\":\"\\\"e2\\\"\"}",
        (try fake.request(3)).body.?,
    );
}
