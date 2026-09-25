//! Signs as a service account through the IAM Credentials API's
//! `signBlob`. The private key stays with Google, so this works for an
//! account with no key file at all. The token sent with each call must
//! belong to a principal allowed to sign as the account, which needs
//! `iam.serviceAccounts.signBlob`: the Service Account Token Creator role
//! grants it. A user's own login, for one, can sign as any account the user
//! holds that role on.
//!
//! Google rotates the keys IAM signs with, and promises each for 12 hours,
//! so `lifetimeS` says 43,200: a URL signed this way may last no longer.
//!
//! The string to sign goes to Google, as it must. The token and the
//! signature are the caller's arena's to wipe; the signed URL code does.

const IamSigner = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const TokenProvider = core.TokenProvider;
const Diagnostics = core.Diagnostics;
const HttpTransport = core.transport.HttpTransport;
const Transport = core.transport.Transport;
const iam_credentials = @import("iam_credentials.zig");
const token_response = @import("token_response.zig");

gpa: Allocator,
/// The account's email. Owned.
account: []u8,
/// Owned, each `projects/-/serviceAccounts/EMAIL`.
delegates: [][]u8,
/// `{iam_endpoint}/v1/projects/-/serviceAccounts/{account}:signBlob`. Owned.
url: []u8,
/// What a refusal says, naming the account and the role. Owned.
refused: []u8,
token_provider: TokenProvider,
retry: core.RetryPolicy,
request_timeout_ms: u32,
diagnostics: ?*Diagnostics,
transport: Transport,
/// The built-in transport, when `Options.transport` was null.
http: ?*HttpTransport,
/// Owned copy of `Options.user_agent`, which the built-in transport uses.
user_agent: []u8,

pub const Options = struct {
    /// The account to sign as, by email.
    service_account: []const u8,
    /// Whose token goes with each call: a principal allowed to sign as the
    /// account. Its scopes are asked for `cloud-platform`, which gcloud's
    /// logins and the metadata server's tokens carry.
    token_provider: TokenProvider,
    /// The accounts in between, each `projects/-/serviceAccounts/EMAIL`,
    /// when the right to sign passes along a chain of Token Creator grants.
    /// Usually none.
    delegates: []const []const u8 = &.{},
    /// Signing sits in front of handing out a URL, so it gives up sooner
    /// than an API call would.
    retry: core.RetryPolicy = .{ .max_attempts = 3 },
    /// How long one call may take before it is `error.TimedOut`, which the
    /// retry policy treats as transient. 0 removes the limit.
    request_timeout_ms: u32 = 30_000,
    /// Printable ASCII.
    user_agent: []const u8 = "zig-gcp-auth/0.21",
    /// Filled with the details of the last failure. Never holds a secret.
    diagnostics: ?*Diagnostics = null,
    /// Sends requests through this instead of `std.http.Client`.
    transport: ?Transport = null,
    /// Google's IAM Credentials endpoint, scheme and host. Plain http is
    /// accepted only to this machine (127.0.0.1, [::1] or localhost), as
    /// tests use.
    iam_endpoint: []const u8 = iam_credentials.default_endpoint,
};

pub const InitError = error{
    /// An account that is not an email, a delegate that names no account,
    /// an endpoint that is neither https nor on this machine, or an invalid
    /// retry policy or user agent.
    InvalidOptions,
    OutOfMemory,
};

/// Copies what it keeps from `options`; nothing borrowed outlives the call
/// except the token provider, `diagnostics` and the transport.
pub fn init(gpa: Allocator, io: std.Io, options: Options) InitError!IamSigner {
    const diag = options.diagnostics;
    if (diag) |d| d.clear();
    if (!iam_credentials.isEmail(options.service_account)) {
        if (diag) |d| d.print("invalid service account: expected an email, such as signer@my-project.iam.gserviceaccount.com", .{});
        return error.InvalidOptions;
    }
    for (options.delegates, 0..) |delegate, i| if (!iam_credentials.isDelegate(delegate)) {
        if (diag) |d| d.print("invalid delegate {d}: expected projects/-/serviceAccounts/EMAIL", .{i});
        return error.InvalidOptions;
    };
    if (!token_response.isAcceptableTokenUrl(options.iam_endpoint)) {
        if (diag) |d| d.print("invalid iam_endpoint: it must use https, or http to this machine", .{});
        return error.InvalidOptions;
    }
    if (!options.retry.isValid()) {
        if (diag) |d| d.print("invalid retry policy: max_attempts must be at least 1, multiplier finite and at least 1", .{});
        return error.InvalidOptions;
    }
    if (!isPrintable(options.user_agent)) {
        if (diag) |d| d.print("invalid user agent: expected printable ASCII", .{});
        return error.InvalidOptions;
    }

    const account = try gpa.dupe(u8, options.service_account);
    errdefer gpa.free(account);
    const delegates = try copyAll(gpa, options.delegates);
    errdefer freeAll(gpa, delegates);
    const url = try iam_credentials.signBlobUrl(gpa, options.iam_endpoint, options.service_account);
    errdefer gpa.free(url);
    const refused = try std.fmt.allocPrint(gpa, "signing was refused: the credentials need roles/iam.serviceAccountTokenCreator on {s}, and the IAM Service Account Credentials API must be enabled", .{options.service_account});
    errdefer gpa.free(refused);
    const user_agent = try gpa.dupe(u8, options.user_agent);
    errdefer gpa.free(user_agent);

    var http: ?*HttpTransport = null;
    const transport = options.transport orelse t: {
        const h = try gpa.create(HttpTransport);
        h.* = .init(gpa, io, user_agent);
        http = h;
        break :t h.transport();
    };
    return .{
        .gpa = gpa,
        .account = account,
        .delegates = delegates,
        .url = url,
        .refused = refused,
        .token_provider = options.token_provider,
        .retry = options.retry,
        .request_timeout_ms = options.request_timeout_ms,
        .diagnostics = diag,
        .transport = transport,
        .http = http,
        .user_agent = user_agent,
    };
}

pub fn deinit(self: *IamSigner) void {
    if (self.http) |h| {
        h.deinit();
        self.gpa.destroy(h);
    }
    freeAll(self.gpa, self.delegates);
    self.gpa.free(self.account);
    self.gpa.free(self.url);
    self.gpa.free(self.refused);
    self.gpa.free(self.user_agent);
    self.* = undefined;
}

/// Points at this struct, which must not move while the signer is in use.
pub fn signer(self: *IamSigner) core.Signer {
    return .{ .ptr = self, .vtable = &.{
        .email = email,
        .sign = sign,
        .lifetime_s = lifetime,
    } };
}

fn fromPtr(ptr: *anyopaque) *IamSigner {
    return @ptrCast(@alignCast(ptr));
}

fn email(ptr: *anyopaque, io: std.Io, arena: Allocator) core.Signer.Error![]const u8 {
    _ = io;
    return arena.dupe(u8, fromPtr(ptr).account);
}

fn sign(ptr: *anyopaque, io: std.Io, arena: Allocator, message: []const u8) core.Signer.Error![]const u8 {
    const self = fromPtr(ptr);
    return iam_credentials.sign(self.transport, io, arena, .{
        .provider = self.token_provider,
        .url = self.url,
        .payload = message,
        .delegates = self.delegates,
        .retry = self.retry,
        .timeout_ms = self.request_timeout_ms,
        .diagnostics = self.diagnostics,
        .refused = self.refused,
    });
}

fn lifetime(ptr: *anyopaque) ?u32 {
    _ = ptr;
    return iam_credentials.signature_lifetime_s;
}

fn copyAll(gpa: Allocator, items: []const []const u8) Allocator.Error![][]u8 {
    const out = try gpa.alloc([]u8, items.len);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |item| gpa.free(item);
        gpa.free(out);
    }
    for (items, out) |item, *slot| {
        slot.* = try gpa.dupe(u8, item);
        copied += 1;
    }
    return out;
}

fn freeAll(gpa: Allocator, items: [][]u8) void {
    for (items) |item| gpa.free(item);
    gpa.free(items);
}

fn isPrintable(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

const testing = std.testing;
const test_util = core.testing;
const Reply = test_util.FakeTransport.Reply;
const logging = @import("logging.zig");

const account_email = "signer@my-project.iam.gserviceaccount.com";
const sign_url = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/" ++ account_email ++ ":signBlob";
const test_message = "GOOG4-RSA-SHA256\n20250922T160000Z\n20250922/auto/storage/goog4_request\n6b6fbd4237d591267a5a40f8f9ffd28eddaf14e5e5a05262508cd9f7db403046";
/// 256 bytes of 0x5a, what IAM answers for a 2048-bit key, and its base64.
const test_signature: [256]u8 = @splat(0x5a);
const test_signature_base64 = b64: {
    var out: [std.base64.standard.Encoder.calcSize(test_signature.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &test_signature);
    const final = out;
    break :b64 final;
};
const signed: Reply = .{ .respond = .{ .body = "{\"keyId\":\"a1b2c3\",\"signedBlob\":\"" ++ test_signature_base64 ++ "\"}" } };
const busy: Reply = .{ .respond = .{ .status = 503, .body = "Service Unavailable" } };
const unauthenticated: Reply = .{ .respond = .{ .status = 401, .body = "{\"error\":{\"status\":\"UNAUTHENTICATED\",\"message\":\"expired\"}}" } };

/// An `IamSigner` wired to a fake transport, a fake token and a fake clock.
const Harness = struct {
    fake: test_util.FakeTransport,
    token: test_util.FakeTokenProvider,
    clock: test_util.FakeClock,
    diag: Diagnostics,
    arena: std.heap.ArenaAllocator,
    iam: IamSigner,

    /// Initializes in place: the signer points into the harness.
    fn init(h: *Harness, script: []const Reply, delegates: []const []const u8) !void {
        h.* = .{
            .fake = .init(testing.allocator, script),
            .token = .{ .token = "ya29.CALLER" },
            .clock = .{},
            .diag = .{},
            .arena = .init(testing.allocator),
            .iam = undefined,
        };
        errdefer h.fake.deinit();
        errdefer h.arena.deinit();
        h.iam = try .init(testing.allocator, h.clock.io(), .{
            .service_account = account_email,
            .token_provider = h.token.provider(),
            .delegates = delegates,
            .diagnostics = &h.diag,
            .transport = h.fake.transport(),
        });
    }

    fn deinit(h: *Harness) void {
        h.iam.deinit();
        h.arena.deinit();
        h.fake.deinit();
    }

    fn sign(h: *Harness) core.Signer.Error![]const u8 {
        return h.iam.signer().sign(h.clock.io(), h.arena.allocator(), test_message);
    }
};

test "IamSigner: one signBlob call, with the caller's token and the bytes in base64" {
    var h: Harness = undefined;
    try h.init(&.{ signed, signed }, &.{});
    defer h.deinit();
    try testing.expectEqualSlices(u8, &test_signature, try h.sign());
    const sent = try h.fake.request(0);
    try testing.expectEqual(.POST, sent.method);
    try testing.expectEqualStrings(sign_url, sent.url);
    try testing.expectEqualStrings("ya29.CALLER", sent.bearer.?);
    try testing.expectEqual(.json, sent.content_type);
    var payload: [std.base64.standard.Encoder.calcSize(test_message.len)]u8 = undefined;
    const want = try std.fmt.allocPrint(h.arena.allocator(), "{{\"payload\":\"{s}\"}}", .{std.base64.standard.Encoder.encode(&payload, test_message)});
    try testing.expectEqualStrings(want, sent.body.?);
    // The token is asked for the scope IAM Credentials takes.
    try testing.expectEqualStrings(iam_credentials.scope, h.token.firstScope());
}

test "IamSigner: delegates travel in the body, in order" {
    var h: Harness = undefined;
    try h.init(&.{signed}, &.{
        "projects/-/serviceAccounts/first@p.iam.gserviceaccount.com",
        "projects/-/serviceAccounts/second@p.iam.gserviceaccount.com",
    });
    defer h.deinit();
    _ = try h.sign();
    const body = (try h.fake.request(0)).body.?;
    try testing.expect(std.mem.startsWith(u8, body, "{\"delegates\":[\"projects/-/serviceAccounts/first@p.iam.gserviceaccount.com\",\"projects/-/serviceAccounts/second@p.iam.gserviceaccount.com\"],\"payload\":\""));
}

test "IamSigner: it names the account, and its signatures last 12 hours" {
    var h: Harness = undefined;
    try h.init(&.{}, &.{});
    defer h.deinit();
    const s = h.iam.signer();
    try testing.expectEqualStrings(account_email, try s.email(h.clock.io(), h.arena.allocator()));
    try testing.expectEqual(43_200, s.lifetimeS());
    try testing.expectEqual(0, h.fake.requests.items.len);
}

test "IamSigner: a 401 gets one fresh token; a second is SigningRejected" {
    var h: Harness = undefined;
    try h.init(&.{ unauthenticated, signed, unauthenticated, unauthenticated }, &.{});
    defer h.deinit();
    h.token.next_token = "ya29.FRESH";
    try testing.expectEqualSlices(u8, &test_signature, try h.sign());
    try testing.expectEqual(1, h.token.invalidations);
    try testing.expectEqualStrings("ya29.FRESH", (try h.fake.request(1)).bearer.?);
    try testing.expectError(error.SigningRejected, h.sign());
    try testing.expectEqual(2, h.token.invalidations);
    try testing.expectEqual(4, h.fake.requests.items.len);
}

test "IamSigner: busy IAM is retried with backoff, and three busy answers are SigningFailed" {
    var h: Harness = undefined;
    try h.init(&.{ busy, .{ .respond = .{ .status = 429, .body = "{}" } }, signed, busy, busy, busy }, &.{});
    defer h.deinit();
    try testing.expectEqualSlices(u8, &test_signature, try h.sign());
    try testing.expectEqual(2, h.clock.sleep_count);
    try testing.expectError(error.SigningFailed, h.sign());
    try testing.expectEqual(4, h.clock.sleep_count);
    try testing.expectEqual(6, h.fake.requests.items.len);
}

test "IamSigner: a dropped connection is retried; an unknown host is not" {
    var h: Harness = undefined;
    try h.init(&.{ .{ .fail = error.ConnectionResetByPeer }, signed, .{ .fail = error.UnknownHostName } }, &.{});
    defer h.deinit();
    try testing.expectEqualSlices(u8, &test_signature, try h.sign());
    try testing.expectError(error.UnknownHostName, h.sign());
    try testing.expectEqual(3, h.fake.requests.items.len);
}

test "IamSigner: a 403 names the role; other refusals keep the server's words" {
    var h: Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 403, .body = "{\"error\":{\"status\":\"PERMISSION_DENIED\",\"message\":\"denied\"}}" } },
        .{ .respond = .{ .status = 404, .body = "{\"error\":{\"status\":\"NOT_FOUND\",\"message\":\"Unknown service account\"}}" } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"status\":\"INVALID_ARGUMENT\",\"message\":\"bad payload\"}}" } },
    }, &.{});
    defer h.deinit();
    try testing.expectError(error.SigningRejected, h.sign());
    try testing.expectEqual(403, h.diag.http_status);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "roles/iam.serviceAccountTokenCreator on " ++ account_email) != null);
    try testing.expectError(error.SigningRejected, h.sign());
    try testing.expectEqualStrings("Unknown service account", h.diag.message());
    try testing.expectError(error.SigningRejected, h.sign());
    try testing.expectEqualStrings("bad payload", h.diag.message());
    // A refusal is an answer: none of them was retried.
    try testing.expectEqual(3, h.fake.requests.items.len);
}

test "IamSigner: an answer without a usable signature is SigningFailed" {
    const short = "{\"signedBlob\":\"" ++ "AAAA" ** 10 ++ "\"}";
    const long = "{\"signedBlob\":\"" ++ "AAAA" ** 180 ++ "\"}";
    for ([_][]const u8{ "<html>", "{}", "{\"signedBlob\":null}", "{\"signedBlob\":\"!!!!\"}", short, long }) |body| {
        var h: Harness = undefined;
        try h.init(&.{.{ .respond = .{ .body = body } }}, &.{});
        defer h.deinit();
        try testing.expectError(error.SigningFailed, h.sign());
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), "signedBlob") != null);
    }
}

test "IamSigner: the token's failure is the signer's" {
    var h: Harness = undefined;
    try h.init(&.{signed}, &.{});
    defer h.deinit();
    h.token.fail = error.RefreshTokenInvalid;
    try testing.expectError(error.RefreshTokenInvalid, h.sign());
    try testing.expectEqual(0, h.fake.requests.items.len);
}

test "IamSigner: init refuses what cannot work, and says why" {
    var diag: Diagnostics = .{};
    var token: test_util.FakeTokenProvider = .{};
    const good: Options = .{ .service_account = account_email, .token_provider = token.provider(), .diagnostics = &diag };
    const cases = [_]struct { Options, []const u8 }{
        .{ o: {
            var o = good;
            o.service_account = "123456789012345678901";
            break :o o;
        }, "expected an email" },
        .{ o: {
            var o = good;
            o.service_account = "sa@p/../other";
            break :o o;
        }, "expected an email" },
        .{ o: {
            var o = good;
            o.delegates = &.{"middle@p.iam.gserviceaccount.com"};
            break :o o;
        }, "invalid delegate 0" },
        .{ o: {
            var o = good;
            o.iam_endpoint = "http://iamcredentials.example.com";
            break :o o;
        }, "invalid iam_endpoint" },
        .{ o: {
            var o = good;
            o.retry = .{ .max_attempts = 0 };
            break :o o;
        }, "invalid retry policy" },
        .{ o: {
            var o = good;
            o.user_agent = "agent\r\nX: y";
            break :o o;
        }, "invalid user agent" },
    };
    for (cases) |case| {
        try testing.expectError(error.InvalidOptions, IamSigner.init(testing.failing_allocator, testing.io, case[0]));
        try testing.expect(std.mem.indexOf(u8, diag.message(), case[1]) != null);
    }
    // Plain http is fine to this machine, as tests use.
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{});
    defer fake.deinit();
    var local = good;
    local.iam_endpoint = "http://127.0.0.1:8080";
    local.transport = fake.transport();
    var iam = try IamSigner.init(testing.allocator, testing.io, local);
    defer iam.deinit();
    try testing.expectEqualStrings("http://127.0.0.1:8080/v1/projects/-/serviceAccounts/" ++ account_email ++ ":signBlob", iam.url);
}

test "IamSigner: neither the token nor the signature reaches the log or Diagnostics" {
    logging.capture.reset();
    var h: Harness = undefined;
    try h.init(&.{ busy, signed, .{ .respond = .{ .status = 403, .body = "{\"error\":{\"message\":\"denied\"}}" } } }, &.{});
    defer h.deinit();
    _ = try h.sign();
    _ = h.sign() catch {};
    for ([_][]const u8{ logging.capture.text(), h.diag.message() }) |text| {
        try testing.expect(std.mem.indexOf(u8, text, "ya29") == null);
        try testing.expect(std.mem.indexOf(u8, text, test_signature_base64[0..16]) == null);
    }
    try testing.expect(std.mem.indexOf(u8, logging.capture.text(), sign_url) != null);
}

fn signWithFailingAllocations(gpa: Allocator) !void {
    var fake: test_util.FakeTransport = .init(gpa, &.{signed});
    defer fake.deinit();
    var token: test_util.FakeTokenProvider = .{};
    var clock: test_util.FakeClock = .{};
    var iam: IamSigner = try .init(gpa, clock.io(), .{
        .service_account = account_email,
        .token_provider = token.provider(),
        .delegates = &.{"projects/-/serviceAccounts/middle@p.iam.gserviceaccount.com"},
        .transport = fake.transport(),
    });
    defer iam.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    _ = try iam.signer().sign(clock.io(), arena.allocator(), test_message);
}

test "IamSigner: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, signWithFailingAllocations, .{});
}
