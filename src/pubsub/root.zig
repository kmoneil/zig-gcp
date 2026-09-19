//! Pub/Sub v1 REST client.
//!
//! `Client` holds the configuration and the connection pool; `Topic` and
//! `Subscription` are cheap handles on it. Every call that returns data
//! returns an `Owned(T)`, freed with one `deinit`. Errors carry no payload:
//! pass a `Diagnostics` in `Client.Options` for the server's message.

pub const Client = @import("Client.zig");
pub const Topic = @import("Topic.zig");
pub const Subscription = @import("Subscription.zig");
pub const Endpoint = @import("Endpoint.zig");

pub const TokenProvider = @import("auth.zig").TokenProvider;
pub const StaticToken = @import("auth.zig").StaticToken;
/// The OAuth scope the client requests from its `TokenProvider`.
pub const auth_scope = @import("auth.zig").scope;

pub const RetryPolicy = @import("retry.zig").RetryPolicy;
pub const Diagnostics = @import("errors.zig").Diagnostics;
pub const Error = @import("errors.zig").Error;
pub const ApiError = @import("errors.zig").ApiError;

pub const Owned = @import("types.zig").Owned;
pub const Attribute = @import("types.zig").Attribute;
pub const Message = @import("types.zig").Message;
pub const PublishOptions = @import("types.zig").PublishOptions;
pub const PublishResult = @import("types.zig").PublishResult;
pub const PageOptions = @import("types.zig").PageOptions;
pub const PullOptions = @import("types.zig").PullOptions;
pub const PullResult = @import("types.zig").PullResult;
pub const ReceivedMessage = @import("types.zig").ReceivedMessage;
pub const TopicConfig = @import("types.zig").TopicConfig;
pub const TopicInfo = @import("types.zig").TopicInfo;
pub const TopicPage = @import("types.zig").TopicPage;
pub const SubscriptionConfig = @import("types.zig").SubscriptionConfig;
pub const SubscriptionInfo = @import("types.zig").SubscriptionInfo;
pub const SubscriptionPage = @import("types.zig").SubscriptionPage;

/// Parses a `publish_time` (RFC 3339) to nanoseconds since the Unix epoch.
pub const parseTimestamp = @import("timestamp.zig").parse;

/// The fixed API limits and naming rules the client checks before sending.
pub const limits = @import("validate.zig");

/// The HTTP seam: implement `transport.Transport` to send requests another
/// way, or to fake the server in your own tests.
pub const transport = @import("transport.zig");

test "usage: the spec's example, against a fake server" {
    const std = @import("std");
    const pubsub = @This();
    const test_util = @import("test_util.zig");

    // A caller can fake the server by implementing `transport.Transport`.
    var fake: test_util.FakeTransport = .init(std.testing.allocator, &.{
        .{ .respond = .{ .body = "{\"name\":\"projects/test/topics/orders\"}" } },
        .{ .respond = .{ .body = "{\"messageIds\":[\"1\"]}" } },
        .{ .respond = .{ .body = "{\"receivedMessages\":[{\"ackId\":\"a1\",\"message\":{\"data\":\"aGVsbG8=\",\"attributes\":{\"origin\":\"zig\"},\"messageId\":\"1\"}}]}" } },
        .{ .respond = .{ .body = "{}" } },
    });
    defer fake.deinit();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("PUBSUB_EMULATOR_HOST", "localhost:8085");
    var diag: pubsub.Diagnostics = .{};

    var client = try pubsub.Client.init(std.testing.allocator, std.testing.io, .{
        .project_id = "test",
        .endpoint = pubsub.Endpoint.fromEnv(&env),
        .diagnostics = &diag,
        .transport = fake.transport(),
    });
    defer client.deinit();

    const orders = client.topic("orders");
    var created = try orders.create(.{});
    defer created.deinit();

    var sent = try orders.publish(&.{
        .{ .data = "hello", .attributes = &.{.{ .key = "origin", .value = "zig" }} },
    }, .{});
    defer sent.deinit();

    const worker = client.subscription("orders-worker");
    var batch = try worker.pull(.{ .max_messages = 10 });
    defer batch.deinit();
    for (batch.value.messages) |m| {
        try std.testing.expectEqualStrings("hello", m.data);
        try worker.ack(&.{m.ack_id});
    }
    try std.testing.expectEqual(4, fake.requests.items.len);
}

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("auth.zig");
    _ = @import("codec.zig");
    _ = @import("errors.zig");
    _ = @import("logging.zig");
    _ = @import("retry.zig");
    _ = @import("rpc.zig");
    _ = @import("test_util.zig");
    _ = @import("timestamp.zig");
    _ = @import("types.zig");
    _ = @import("url.zig");
    _ = @import("validate.zig");
}
