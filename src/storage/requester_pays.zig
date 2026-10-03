//! Requester pays, end to end: the tests of how a handle's billing project
//! reaches every request a call makes. The mechanism is `rpc.billed`, a
//! copy of the client that bills the handle's project for one call, and
//! the request wrappers that write it, once, into every request.
//!
//! Measured against Cloud Storage on 2026-09-29, with a throwaway service
//! account on a throwaway requester pays bucket:
//!
//! - Anyone but the bucket's owners is refused without a billing project,
//!   with 400 reason `required`, "Bucket is a requester pays bucket but no
//!   user project provided." A project the caller may not bill is 403. A
//!   project that does not exist fails even the owners' requests, with 400
//!   invalid.
//! - On the JSON API the `userProject` parameter and the
//!   `x-goog-user-project` header each bill a project, and where both name
//!   one, the parameter wins: a wrong parameter fails however right the
//!   header is. So both go, with one value.
//! - A resumable upload names it at the start; the session URL Google
//!   returns carries `userProject` itself, and its chunks need nothing
//!   more. The XML API takes the header on every request: start, each
//!   part, the part list, the finish and the abort. Every call of a
//!   rewrite takes it, continuations included.
//! - The operations calls take either form, though discovery lists
//!   neither. A signed URL bills a project by signing `userProject` into
//!   its query; one that names none is refused, 400 `UserProjectMissing`,
//!   and one naming a project that does not exist, 400
//!   `UserProjectInvalid`.
//! - A form cannot bill a project. A policy that names
//!   `x-goog-user-project` is refused as an invalid policy document, and
//!   a query on the form's URL, in either style, turns the POST into a
//!   bucket create, which is refused.
//!
//! Test code only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");

const Client = @import("Client.zig");
const checkpoint = @import("checkpoint.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const test_util = @import("test_util.zig");
const testing = std.testing;

const project = "requester-project";

/// How many times `userProject=` appears in `url`.
fn userProjects(url: []const u8) usize {
    return std.mem.count(u8, url, "userProject=");
}

/// The request at `index` named `project` once, as the parameter, and the
/// header agrees.
fn expectBilled(r: anytype) !void {
    if (userProjects(r.url) != 1 or std.mem.indexOf(u8, r.url, "userProject=" ++ project) == null) {
        std.debug.print("unbilled: {s}\n", .{r.url});
        return error.TestNotBilled;
    }
    try testing.expectEqualStrings(project, r.header("x-goog-user-project") orelse return error.TestNoHeader);
}

const object_json =
    \\{"name":"a","bucket":"b","generation":"7","metageneration":"1","size":"2","crc32c":"UryDEg=="}
;
const bucket_json =
    \\{"name":"b","metageneration":"2"}
;
const operation_json =
    \\{"name":"projects/_/buckets/b/operations/op1","done":false}
;

test "billing: every JSON call names the handle's project once, as the parameter and the header" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = bucket_json } },
        .{ .respond = .{ .body = bucket_json } },
        .{ .respond = .{ .body = "{\"items\":[]}" } },
        .{ .respond = .{ .body = object_json } },
        .{ .respond = .{ .body = object_json } },
        .{ .respond = .{ .body = object_json } },
        .{ .respond = .{ .body = "{\"done\":true,\"resource\":" ++ object_json ++ "}" } },
        .{ .respond = .{ .body = object_json } },
        .{ .respond = .{ .status = 204, .body = "" } },
        .{ .respond = .{ .body = operation_json } },
        .{ .respond = .{ .body = operation_json } },
        .{ .respond = .{ .body = "{\"operations\":[]}" } },
        .{ .respond = .{ .status = 204, .body = "" } },
        .{ .respond = .{ .body = bucket_json } },
        .{ .respond = .{ .status = 204, .body = "" } },
    }, .{ .quota_project = "credentials-project" });
    defer h.deinit();
    const b = h.client.bucket("b").withBillingProject(project);
    const obj = b.object("a");

    var got = try b.get();
    got.deinit();
    var updated = try b.update(.{ .versioning = true });
    updated.deinit();
    var listed = try b.listObjects(.{ .versions = true });
    listed.deinit();
    var info = try obj.get(.{});
    info.deinit();
    var patched = try obj.updateMetadata(.{ .content_type = "text/plain" });
    patched.deinit();
    var restored = try obj.restore(.{ .generation = 5 });
    restored.deinit();
    var copied = try obj.copyTo(b.object("c"), .{});
    copied.deinit();
    var composed = try b.object("d").composeFrom(&.{.{ .name = "a" }}, .{});
    composed.deinit();
    try obj.delete(.{ .generation = 7 });
    var op = try b.bulkRestore(.{});
    op.deinit();
    var one = try b.operation("op1");
    one.deinit();
    var ops = try b.listOperations(.{});
    ops.deinit();
    try b.cancelOperation("op1");
    var back = try b.restore(3);
    back.deinit();
    try b.delete();

    try h.expectRequestCount(15);
    for (h.fake.requests.items, 0..) |_, i| {
        errdefer std.debug.print("request {d}\n", .{i});
        try expectBilled(try h.fake.request(i));
    }
    // Where a path already had a query, the parameter joins it.
    try testing.expect(std.mem.indexOf(u8, (try h.fake.request(2)).url, "?versions=true&userProject=" ++ project) != null);
}

test "billing: uploads and downloads name it too, and none named sends the credentials' quota project alone" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = object_json } },
        .{ .respond = .{ .body = "ab", .headers = &.{.{ .name = "x-goog-generation", .value = "7" }} } },
        .{ .respond = .{ .body = object_json } },
    }, .{ .quota_project = "credentials-project" });
    defer h.deinit();
    const billed = h.client.bucket("b").object("a").withBillingProject(project);
    var up = try billed.upload("ab", .{});
    up.deinit();
    var down = try billed.downloadAlloc(16, .{});
    down.deinit();
    try expectBilled(try h.fake.streamRequest(0));
    try expectBilled(try h.fake.streamRequest(1));

    // Without one, nothing is added, and the credentials bill as ever.
    var plain = try h.client.bucket("b").object("a").upload("ab", .{});
    plain.deinit();
    const sent = try h.fake.streamRequest(2);
    try testing.expectEqual(0, userProjects(sent.url));
    try testing.expectEqualStrings("credentials-project", sent.header("x-goog-user-project").?);
}

test "billing: a handle made on a call's billed client bills its project, as a transfer's own handles do" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = bucket_json } },
        .{ .respond = .{ .body = object_json } },
        .{ .respond = .{ .body = object_json } },
    }, .{ .quota_project = "credentials-project" });
    defer h.deinit();
    var copy = rpc.billed(&h.client, project);
    var got = try copy.bucket("b").get();
    got.deinit();
    var info = try copy.bucket("b").object("a").get(.{});
    info.deinit();
    try expectBilled(try h.fake.request(0));
    try expectBilled(try h.fake.request(1));
    // A handle's own project comes first.
    var own = try copy.bucket("b").object("a").withBillingProject("other-project").get(.{});
    own.deinit();
    const sent = try h.fake.request(2);
    try testing.expectEqual(1, userProjects(sent.url));
    try testing.expect(std.mem.indexOf(u8, sent.url, "userProject=other-project") != null);
    try testing.expectEqualStrings("other-project", sent.header("x-goog-user-project").?);
}

test "billing: a copy bills the source's project, else the destination's" {
    var h: test_util.Harness = undefined;
    const done = "{\"done\":true,\"resource\":" ++ object_json ++ "}";
    try h.init(&.{
        .{ .respond = .{ .body = done } },
        .{ .respond = .{ .body = done } },
    }, .{});
    defer h.deinit();
    const plain = h.client.bucket("b").object("a");
    var from_source = try plain.withBillingProject("source-project").copyTo(plain.withBillingProject("dest-project"), .{});
    from_source.deinit();
    try testing.expect(std.mem.indexOf(u8, (try h.fake.request(0)).url, "userProject=source-project") != null);
    var from_dest = try plain.copyTo(plain.withBillingProject("dest-project"), .{});
    from_dest.deinit();
    try testing.expect(std.mem.indexOf(u8, (try h.fake.request(1)).url, "userProject=dest-project") != null);
}

test "billing: a project that is not one is refused before sending" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    for ([_][]const u8{ "", "a b", "p\r\nX-Injected: 1", "p/q" }) |bad| {
        try testing.expectError(error.InvalidArgument, h.client.bucket("b").withBillingProject(bad).get());
        try testing.expectError(error.InvalidArgument, h.client.bucket("b").object("a").withBillingProject(bad).delete(.{}));
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), "billing project") != null);
    }
    try h.expectRequestCount(0);
}

test "billing: a requester pays refusal of an unbilled call says how to bill one" {
    const refusal =
        \\{"error":{"code":400,"message":"Bucket is a requester pays bucket but no user project provided.",
        \\ "errors":[{"message":"Bucket is a requester pays bucket but no user project provided.","domain":"global","reason":"required"}]}}
    ;
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 400, .body = refusal } },
        .{ .respond = .{ .status = 400, .body = refusal } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"something else\"}}" } },
    }, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidArgument, h.client.bucket("b").object("a").get(.{}));
    try testing.expectEqualStrings("required", h.diag.status());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "withBillingProject") != null);
    // A billed call keeps the server's own words.
    try testing.expectError(error.InvalidArgument, h.client.bucket("b").object("a").withBillingProject(project).get(.{}));
    try testing.expectEqualStrings("Bucket is a requester pays bucket but no user project provided.", h.diag.message());
    // Another refusal is left alone.
    try testing.expectError(error.InvalidArgument, h.client.bucket("b").object("a").get(.{}));
    try testing.expectEqualStrings("something else", h.diag.message());
}

/// A client whose clock stands still, so two signings sign the same time.
const SigningSetup = struct {
    fake: test_util.FakeTransport,
    clock: test_util.FakeClock,
    diag: core.Diagnostics,
    token: test_util.FakeTokenProvider,
    signer: core.testing.FakeSigner,
    client: Client,

    fn init(s: *SigningSetup) !void {
        s.* = .{
            .fake = .init(testing.allocator, &.{}),
            .clock = .{ .now_ns = 1_790_000_000 * std.time.ns_per_s },
            .diag = .{},
            .token = .{},
            .signer = .{},
            .client = undefined,
        };
        errdefer s.fake.deinit();
        s.client = try .init(testing.allocator, s.clock.io(), .{
            .token_provider = s.token.provider(),
            .diagnostics = &s.diag,
            .transport = s.fake.transport(),
        });
    }

    fn deinit(s: *SigningSetup) void {
        s.client.deinit();
        s.fake.deinit();
    }
};

test "billing: a signed URL signs the project in, as its own userProject would be" {
    var s: SigningSetup = undefined;
    try s.init();
    defer s.deinit();
    const obj = s.client.bucket("b").object("a");
    var billed = try obj.withBillingProject(project).signedUrl(s.signer.signer(), .{ .expires_in_s = 60 });
    defer billed.deinit();
    const billed_message = try testing.allocator.dupe(u8, s.signer.message_buffer[0..s.signer.message_len]);
    defer testing.allocator.free(billed_message);
    var by_hand = try obj.signedUrl(s.signer.signer(), .{
        .expires_in_s = 60,
        .query = &.{.{ .name = "userProject", .value = project }},
    });
    defer by_hand.deinit();
    try testing.expectEqualStrings(by_hand.value, billed.value);
    try testing.expectEqualStrings(s.signer.message_buffer[0..s.signer.message_len], billed_message);
    try testing.expect(std.mem.indexOf(u8, billed.value, "userProject=" ++ project) != null);

    // Named twice, once by the handle and once by the caller, is refused,
    // with the reason: the caller named it once.
    try testing.expectError(error.InvalidSignedUrlOptions, obj.withBillingProject(project).signedUrl(s.signer.signer(), .{
        .expires_in_s = 60,
        .query = &.{.{ .name = "userProject", .value = "other" }},
    }));
    try testing.expect(std.mem.indexOf(u8, s.diag.message(), "billing project signs already") != null);
    // A bucket's URL too.
    var listing = try s.client.bucket("b").withBillingProject(project).signedUrl(s.signer.signer(), .{ .expires_in_s = 60 });
    defer listing.deinit();
    try testing.expect(std.mem.indexOf(u8, listing.value, "userProject=" ++ project) != null);
}

test "billing: a POST policy, which a form cannot bill, is refused with one" {
    var s: SigningSetup = undefined;
    try s.init();
    defer s.deinit();
    try testing.expectError(error.InvalidPostPolicyOptions, s.client.bucket("b").object("a").withBillingProject(project).postPolicy(s.signer.signer(), .{ .expires_in_s = 60 }));
    try testing.expectError(error.InvalidPostPolicyOptions, s.client.bucket("b").withBillingProject(project).postPolicy(s.signer.signer(), .{
        .expires_in_s = 60,
        .key = .{ .starts_with = "" },
    }));
    try testing.expect(std.mem.indexOf(u8, s.diag.message(), "cannot bill") != null);
    try testing.expectEqual(0, s.signer.calls);
}

// Against `FakeMultipart` with requester pays on, which refuses as Cloud
// Storage did, and fails any request this library must never send.

fn clientOn(fake: *test_util.FakeMultipart, token: core.TokenProvider, diag: *core.Diagnostics) !Client {
    var client: Client = try .init(testing.allocator, fake.io, .{
        .project_id = "extractctl",
        .token_provider = token,
        .transport = fake.transport(),
        .diagnostics = diag,
        .chunk_size = 256 * 1024,
        .single_request_limit = 256 * 1024,
        .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
    });
    client.multipart_test = .{ .min_part_size = 1024 };
    return client;
}

fn expectNeverSent(diag: *const core.Diagnostics) !void {
    if (std.mem.indexOf(u8, diag.message(), "must never send") != null) {
        std.debug.print("the fake refused: {s}\n", .{diag.message()});
        return error.TestSentWhatMustNeverBeSent;
    }
}

test "against the fake: every transfer bills through, and fails, with the hint, without" {
    var fake: test_util.FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    fake.requester_pays = true;
    fake.billable = project;
    fake.min_part_size = 1024;
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: core.Diagnostics = .{};
    var client = try clientOn(&fake, token.provider(), &diag);
    defer client.deinit();
    const plain = client.bucket("b");
    const billed = plain.withBillingProject(project);

    var data: [600 * 1024]u8 = undefined;
    for (&data, 0..) |*c, i| c.* = @truncate(i *% 31 +% (i >> 9));

    // A resumable upload: its session URL carries the project on.
    var reader: std.Io.Reader = .fixed(&data);
    var streamed = try billed.object("streamed").uploadFrom(&reader, .{});
    streamed.deinit();
    // A parallel one, through the XML API's header.
    var parts = try billed.object("parts").uploadParallel(.{ .data = &data }, .{ .part_size = 128 * 1024, .concurrency = 3 });
    parts.deinit();
    // And back, whole and in ranges.
    var whole = try billed.object("parts").downloadAlloc(data.len, .{});
    defer whole.deinit();
    try testing.expectEqualSlices(u8, &data, whole.value.data);
    var buffer: [data.len]u8 = undefined;
    const ranged = try billed.object("streamed").downloadParallel(.{ .buffer = &buffer }, .{ .part_size = 1024 * 1024, .concurrency = 2 });
    try testing.expect(ranged.checksum_verified);
    try testing.expectEqualSlices(u8, &data, &buffer);
    try billed.object("streamed").delete(.{});
    try expectNeverSent(&diag);

    // Unbilled, each is refused, and told how to bill one.
    var again: std.Io.Reader = .fixed(&data);
    try testing.expectError(error.InvalidArgument, plain.object("x").uploadFrom(&again, .{}));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "withBillingProject") != null);
    try testing.expectError(error.InvalidArgument, plain.object("x").uploadParallel(.{ .data = &data }, .{ .part_size = 128 * 1024 }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "withBillingProject") != null);
    try testing.expectError(error.InvalidArgument, plain.object("parts").downloadAlloc(data.len, .{}));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "withBillingProject") != null);
    // A project the caller may not bill.
    try testing.expectError(error.PermissionDenied, plain.withBillingProject("someone-else").object("parts").get(.{}));
    try testing.expectEqual(0, fake.openUploads());
}

test "against the fake: a request naming two projects, or one twice, fails the test that sent it" {
    var fake: test_util.FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const url = "https://storage.googleapis.com/storage/v1/b/b/o/a?userProject=" ++ project;
    // The guard every other test leans on holds with requester pays on or
    // off: this library sends neither request.
    for ([_]bool{ false, true }) |on| {
        fake.requester_pays = on;
        const disagreeing = try fake.transport().send(.{
            .method = .GET,
            .url = url,
            .headers = &.{.{ .name = "x-goog-user-project", .value = "other-project" }},
        }, a);
        try testing.expectEqual(400, disagreeing.status);
        try testing.expect(std.mem.indexOf(u8, disagreeing.body, "must never send") != null);
        const twice = try fake.transport().send(.{ .method = .GET, .url = url ++ "&userProject=" ++ project }, a);
        try testing.expectEqual(400, twice.status);
        try testing.expect(std.mem.indexOf(u8, twice.body, "must never send") != null);
    }
}

test "against the fake: a checkpointed parallel upload's abandon bills the project it began with" {
    var fake: test_util.FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    fake.requester_pays = true;
    fake.billable = project;
    fake.min_part_size = 1024;
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: core.Diagnostics = .{};
    var client = try clientOn(&fake, token.provider(), &diag);
    defer client.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var data: [300 * 1024]u8 = undefined;
    for (&data, 0..) |*c, i| c.* = @truncate(i *% 7);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source", .data = &data });
    const file = try tmp.dir.openFile(testing.io, "source", .{});
    defer file.close(testing.io);

    // The process dies after the first part: the upload stays open, and
    // the checkpoint remembers who pays.
    var saved: test_util.MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();
    const Dies = struct {
        parts: u32 = 0,
        fn plan(self: *@This()) test_util.FakeMultipart.FaultPlan {
            return .{ .ctx = self, .decide = decide };
        }
        fn decide(ctx: ?*anyopaque, kind: test_util.FakeMultipart.Kind, _: u32) test_util.FakeMultipart.Fault {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (kind != .part) return .none;
            self.parts += 1;
            return if (self.parts > 1) .canceled else .none;
        }
    };
    var dies: Dies = .{};
    fake.faults = dies.plan();
    try testing.expectError(error.Canceled, client.bucket("b").withBillingProject(project).object("o").uploadParallel(
        .{ .file = file },
        .{ .part_size = 100 * 1024, .concurrency = 1, .checkpoint = saved.checkpoint() },
    ));
    fake.faults = null;
    try testing.expectEqual(1, fake.openUploads());
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const state = try checkpoint.parse(arena_state.allocator(), saved.stored.?);
    try testing.expectEqualStrings(project, state.upload_parallel.billing_project.?);

    // The abandon, from the checkpoint alone, carries the header the XML
    // abort needs.
    try client.abandonTransfer(saved.checkpoint());
    try testing.expectEqual(0, fake.openUploads());
    try expectNeverSent(&diag);
}

test "against the fake: an uploadFile resumed through any handle bills the project its session began with" {
    var fake: test_util.FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    fake.requester_pays = true;
    fake.billable = project;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var data: [600 * 1024]u8 = undefined;
    for (&data, 0..) |*c, i| c.* = @truncate(i *% 5 +% (i >> 10));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source", .data = &data });
    const file = try tmp.dir.openFile(testing.io, "source", .{});
    defer file.close(testing.io);

    // The first run stores a chunk and dies at the second.
    const DiesAtSecondChunk = struct {
        done: bool = false,
        fn plan(self: *@This()) test_util.FakeMultipart.FaultPlan {
            return .{ .ctx = self, .decide = decide };
        }
        fn decide(ctx: ?*anyopaque, kind: test_util.FakeMultipart.Kind, part: u32) test_util.FakeMultipart.Fault {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (kind != .session_put or part != 256 * 1024 + 1 or self.done) return .none;
            self.done = true;
            return .canceled;
        }
    };
    // Resumed with no billing project, by credentials that name a quota
    // project of their own, and by a handle that names another project:
    // the session's requests go by its URL, which names the project it
    // began with, and carry no credentials and no header to disagree.
    for ([_]?[]const u8{ null, "someone-else" }, 0..) |resumer, i| {
        errdefer std.debug.print("resumed by {?s}\n", .{resumer});
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "o{d}", .{i});
        var store: checkpoint.CheckpointFile = .init(testing.io, tmp.dir, "o.upload");
        const options: types.UploadOptions = .{ .checkpoint = store.checkpoint() };
        var dies: DiesAtSecondChunk = .{};
        fake.faults = dies.plan();
        {
            var token: core.StaticToken = .{ .token = "ya29.t" };
            var diag: core.Diagnostics = .{};
            var first = try clientOn(&fake, token.provider(), &diag);
            defer first.deinit();
            try testing.expectError(error.Canceled, first.bucket("b").withBillingProject(project).object(name).uploadFile(file, options));
        }
        fake.faults = null;
        try testing.expectEqual(1, fake.openSessions());

        var token: test_util.FakeTokenProvider = .{ .token = "ya29.t", .quota_project = "credentials-project" };
        var diag: core.Diagnostics = .{};
        var second = try clientOn(&fake, token.provider(), &diag);
        defer second.deinit();
        const plain = second.bucket("b").object(name);
        var info = try (if (resumer) |p| plain.withBillingProject(p) else plain).uploadFile(file, options);
        defer info.deinit();
        try expectNeverSent(&diag);
        try testing.expectEqualSlices(u8, &data, fake.object(name).?.bytes);
        try testing.expectEqual(0, fake.openSessions());
    }
}

// The model property: calls drawn over handles with and without a billing
// project, against the requester pays fake. A billed call succeeds, an
// unbilled one is refused with the hint, and no request is ever one the
// fake refuses as never to be sent.

fn billingProperty(_: void, bytes: []const u8) !void {
    var g: test_util.ByteGen = .init(bytes);
    var fake: test_util.FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    fake.requester_pays = true;
    fake.billable = project;
    fake.min_part_size = 1024;
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: core.Diagnostics = .{};
    var client = try clientOn(&fake, token.provider(), &diag);
    defer client.deinit();
    const billed_bucket = client.bucket("b").withBillingProject(project);
    // A create bills nothing: no bucket exists yet to charge anyone for.
    var created = try client.bucket("b").create(.{});
    created.deinit();

    // Something to read, written billed.
    var seed: [3000]u8 = undefined;
    for (&seed, 0..) |*c, i| c.* = @truncate(i *% 13);
    var put = try billed_bucket.object("seed").upload(&seed, .{});
    put.deinit();

    for (0..g.intRange(u8, 1, 6)) |_| {
        const billed = g.boolean();
        // The billing project on the bucket, or on the object alone.
        const on_object = g.boolean();
        const bucket = if (billed and !on_object) billed_bucket else client.bucket("b");
        const obj = if (billed and on_object) bucket.object("seed").withBillingProject(project) else bucket.object("seed");
        const outcome: anyerror!void = switch (g.intRange(u8, 0, 5)) {
            0 => r: {
                var info = obj.get(.{}) catch |err| break :r err;
                info.deinit();
            },
            1 => r: {
                var got = obj.downloadAlloc(seed.len, .{}) catch |err| break :r err;
                got.deinit();
            },
            2 => r: {
                var reader: std.Io.Reader = .fixed(&seed);
                var up = obj.uploadFrom(&reader, .{}) catch |err| break :r err;
                up.deinit();
            },
            3 => r: {
                var up = obj.uploadParallel(.{ .data = &seed }, .{ .part_size = 1024, .concurrency = 2 }) catch |err| break :r err;
                up.deinit();
            },
            4 => r: {
                var buffer: [seed.len]u8 = undefined;
                _ = obj.downloadParallel(.{ .buffer = &buffer }, .{ .part_size = 1024 * 1024 }) catch |err| break :r err;
            },
            else => r: {
                // A bucket call bills through the bucket's handle alone.
                var info = (if (billed) billed_bucket else client.bucket("b")).get() catch |err| break :r err;
                info.deinit();
            },
        };
        try expectNeverSent(&diag);
        if (billed) {
            try outcome;
        } else {
            try testing.expectError(error.InvalidArgument, outcome);
            try testing.expect(std.mem.indexOf(u8, diag.message(), "withBillingProject") != null);
        }
    }
    try testing.expectEqual(0, fake.openUploads());
}

test "heavy property billing: billed calls go through, unbilled ones are refused with the hint, and nothing else is ever sent" {
    try test_util.fuzzBytes({}, billingProperty, .{ .corpus = &.{ "", test_util.repeat("\x01", 32), test_util.repeat("\x00\x01\x02\x03\x04\x05\x06\x07", 4) } });
}

fn billedEverything(gpa: Allocator) !void {
    var fake: test_util.FakeTransport = .init(gpa, &.{
        .{ .respond = .{ .body = object_json } },
        .{ .respond = .{ .body = "{\"items\":[]}" } },
    });
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var token: test_util.FakeTokenProvider = .{ .token = "ya29.test-token" };
    var client: Client = try .init(gpa, clock.io(), .{
        .project_id = "extractctl",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    const b = client.bucket("b").withBillingProject(project);
    var info = try b.object("a").get(.{});
    info.deinit();
    var page = try b.listObjects(.{ .prefix = "p/" });
    page.deinit();
}

test "billing: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(test_util.no_grow_allocator, billedEverything, .{});
}
