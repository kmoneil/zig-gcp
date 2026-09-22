//! Signed URLs held to answers from outside this library, through the
//! public API and with no network: Google's 29 V4 signing conformance
//! vectors, byte for byte with real RSA signatures, and 400 cases Google's
//! Python library signed (testdata/signed_url_oracle.json). testdata/README.md
//! says where each file comes from.

const std = @import("std");
const storage = @import("storage");
const auth = @import("auth");
const core = @import("core");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const rsa = std.crypto.Certificate.rsa;

const vectors_json = @embedFile("testdata/v4_signatures.json");
const oracle_json = @embedFile("testdata/signed_url_oracle.json");

/// The account Google's vectors are signed as, and its key: `private_key`
/// of storage/v1/test_service_account.not-a-test.json in
/// googleapis/conformance-tests, under the Apache License 2.0
/// (testdata/LICENSE-conformance-tests). A key made for these tests, which
/// grants nothing anywhere.
const key_email = "test-iam-credentials@dummy-project-id.iam.gserviceaccount.com";

const key_pem =
    \\-----BEGIN PRIVATE KEY-----
    \\MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQCsPzMirIottfQ2
    \\ryjQmPWocSEeGo7f7Q4/tMQXHlXFzo93AGgU2t+clEj9L5loNhLVq+vk+qmnyDz5
    \\Q04y8jVWyMYzzGNNrGRW/yaYqnqlKZCy1O3bmnNjV7EDbC/jE1ZLBY0U3HaSHfn6
    \\S9ND8MXdgD0/ulRTWwq6vU8/w6i5tYsU7n2LLlQTl1fQ7/emO9nYcCFJezHZVa0H
    \\meWsdHwWsok0skwQYQNIzP3JF9BpR5gJT2gNge6KopDesJeLoLzaX7cUnDn+CAnn
    \\LuLDwwSsIVKyVxhBFsFXPplgpaQRwmGzwEbf/Xpt9qo26w2UMgn30jsOaKlSeAX8
    \\cS6ViF+tAgMBAAECggEACKRuJCP8leEOhQziUx8Nmls8wmYqO4WJJLyk5xUMUC22
    \\SI4CauN1e0V8aQmxnIc0CDkFT7qc9xBmsMoF+yvobbeKrFApvlyzNyM7tEa/exh8
    \\DGD/IzjbZ8VfWhDcUTwn5QE9DCoon9m1sG+MBNlokB3OVOt8LieAAREdEBG43kJu
    \\yQTOkY9BGR2AY1FnAl2VZ/jhNDyrme3tp1sW1BJrawzR7Ujo8DzlVcS2geKA9at7
    \\55ua5GbHz3hfzFgjVXDfnkWzId6aHypUyqHrSn1SqGEbyXTaleKTc6Pgv0PgkJjG
    \\hZazWWdSuf1T5Xbs0OhAK9qraoAzT6cXXvMEvvPt6QKBgQDXcZKqJAOnGEU4b9+v
    \\Odoh+nssdrIOBNMu1m8mYbUVYS1aakc1iDGIIWNM3qAwbG+yNEIi2xi80a2RMw2T
    \\9RyCNB7yqCXXVKLBiwg9FbKMai6Vpk2bWIrzahM9on7AhCax/X2AeOp+UyYhFEy6
    \\UFG4aHb8THscL7b515ukSuKb5QKBgQDMq+9PuaB0eHsrmL6q4vHNi3MLgijGg/zu
    \\AXaPygSYAwYW8KglcuLZPvWrL6OG0+CrfmaWTLsyIZO4Uhdj7MLvX6yK7IMnagvk
    \\L3xjgxSklEHJAwi5wFeJ8ai/1MIuCn8p2re3CbwISKpvf7Sgs/W4196P4vKvTiAz
    \\jcTiSYFIKQKBgCjMpkS4O0TakMlGTmsFnqyOneLmu4NyIHgfPb9cA4n/9DHKLKAT
    \\oaWxBPgatOVWs7RgtyGYsk+XubHkpC6f3X0+15mGhFwJ+CSE6tN+l2iF9zp52vqP
    \\Qwkjzm7+pdhZbmaIpcq9m1K+9lqPWJRz/3XXuqi+5xWIZ7NaxGvRjqaNAoGAdK2b
    \\utZ2y48XoI3uPFsuP+A8kJX+CtWZrlE1NtmS7tnicdd19AtfmTuUL6fz0FwfW4Su
    \\lQZfPT/5B339CaEiq/Xd1kDor+J7rvUHM2+5p+1A54gMRGCLRv92FQ4EON0RC1o9
    \\m2I4SHysdO3XmjmdXmfp4BsgAKJIJzutvtbqlakCgYB+Cb10z37NJJ+WgjDt+yT2
    \\yUNH17EAYgWXryfRgTyi2POHuJitd64Xzuy6oBVs3wVveYFM6PIKXlj8/DahYX5I
    \\R2WIzoCNLL3bEZ+nC6Jofpb4kspoAeRporj29SgesK6QBYWHWX2H645RkRGYGpDo
    \\51gjy9m/hSNqBbH2zmh04A==
    \\-----END PRIVATE KEY-----
;

/// The same key's public half, as `openssl rsa -modulus` prints it; the
/// exponent is 65537. std's own RSA code checks every signature with it.
const key_modulus_hex =
    "ac3f3322ac8a2db5f436af28d098f5a871211e1a8edfed0e3fb4c4171e55c5ce" ++
    "8f77006814dadf9c9448fd2f99683612d5abebe4faa9a7c83cf9434e32f23556" ++
    "c8c633cc634dac6456ff2698aa7aa52990b2d4eddb9a736357b1036c2fe31356" ++
    "4b058d14dc76921df9fa4bd343f0c5dd803d3fba54535b0ababd4f3fc3a8b9b5" ++
    "8b14ee7d8b2e54139757d0eff7a63bd9d87021497b31d955ad0799e5ac747c16" ++
    "b28934b24c10610348ccfdc917d0694798094f680d81ee8aa290deb0978ba0bc" ++
    "da5fb7149c39fe0809e72ee2c3c304ac2152b257184116c1573e9960a5a411c2" ++
    "61b3c046dffd7a6df6aa36eb0d943209f7d23b0e68a9527805fc712e95885fad";

/// One of Google's signing vectors, as tests.proto in the same repository
/// describes it.
const Vector = struct {
    description: []const u8,
    bucket: []const u8,
    object: ?[]const u8 = null,
    method: []const u8,
    expiration: u32,
    timestamp: []const u8,
    expectedUrl: []const u8,
    expectedCanonicalRequest: []const u8,
    expectedStringToSign: []const u8,
    headers: ?std.json.ArrayHashMap([]const u8) = null,
    queryParameters: ?std.json.ArrayHashMap([]const u8) = null,
    scheme: ?[]const u8 = null,
    urlStyle: ?[]const u8 = null,
    bucketBoundHostname: ?[]const u8 = null,
    hostname: ?[]const u8 = null,
    clientEndpoint: ?[]const u8 = null,
    emulatorHostname: ?[]const u8 = null,
    universeDomain: ?[]const u8 = null,
};

const VectorFile = struct { signingV4Tests: []const Vector };

/// The client endpoint a vector's host inputs describe: the first of
/// `hostname`, `clientEndpoint`, `emulatorHostname` and the universe's
/// `storage.` host, with the vector's scheme, else the input's own, else
/// https. A universe domain is only another endpoint as far as a URL goes.
/// Null is production.
fn endpointOf(arena: Allocator, v: Vector) !?storage.Endpoint {
    const input = v.hostname orelse v.clientEndpoint orelse v.emulatorHostname orelse
        if (v.universeDomain) |universe| try std.mem.concat(arena, u8, &.{ "storage.", universe }) else return null;
    const own_scheme, const host = if (std.mem.indexOf(u8, input, "://")) |at|
        .{ input[0..at], input[at + 3 ..] }
    else
        .{ null, input };
    const scheme = v.scheme orelse own_scheme orelse "https";
    // Only an emulator endpoint speaks plain http; none of these checks a signature anyway.
    return .{
        .url = try std.mem.concat(arena, u8, &.{ scheme, "://", host }),
        .emulator = std.mem.eql(u8, scheme, "http"),
    };
}

fn styleOf(v: Vector) storage.UrlStyle {
    const style = v.urlStyle orelse return .path;
    if (std.mem.eql(u8, style, "VIRTUAL_HOSTED_STYLE")) return .virtual_hosted;
    std.debug.assert(std.mem.eql(u8, style, "BUCKET_BOUND_HOSTNAME"));
    return .{ .bucket_bound = .{
        .host = v.bucketBoundHostname.?,
        .scheme = if (std.mem.eql(u8, v.scheme orelse "https", "http")) .http else .https,
    } };
}

fn headersOf(arena: Allocator, map: ?std.json.ArrayHashMap([]const u8)) ![]const storage.Header {
    const m = map orelse return &.{};
    const out = try arena.alloc(storage.Header, m.map.count());
    for (m.map.keys(), m.map.values(), out) |name, value, *header| header.* = .{ .name = name, .value = value };
    return out;
}

fn queryOf(arena: Allocator, map: ?std.json.ArrayHashMap([]const u8)) ![]const storage.QueryParam {
    const m = map orelse return &.{};
    const out = try arena.alloc(storage.QueryParam, m.map.count());
    for (m.map.keys(), m.map.values(), out) |name, value, *param| param.* = .{ .name = name, .value = value };
    return out;
}

/// A key file around `key_pem`, as Google writes one.
fn keyFileJson(arena: Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try json.beginObject();
    try json.objectField("type");
    try json.write("service_account");
    try json.objectField("client_email");
    try json.write(key_email);
    try json.objectField("private_key");
    try json.write(key_pem);
    try json.endObject();
    return out.written();
}

/// Signs through another signer, and keeps the last string to sign.
const Recording = struct {
    inner: core.Signer,
    message: std.ArrayList(u8) = .empty,

    fn signer(self: *Recording) core.Signer {
        return .{ .ptr = self, .vtable = &.{ .email = email, .sign = sign, .lifetime_s = lifetime } };
    }

    fn fromPtr(ptr: *anyopaque) *Recording {
        return @ptrCast(@alignCast(ptr));
    }

    fn email(ptr: *anyopaque, io: std.Io, arena: Allocator) core.Signer.Error![]const u8 {
        return fromPtr(ptr).inner.email(io, arena);
    }

    fn sign(ptr: *anyopaque, io: std.Io, arena: Allocator, message: []const u8) core.Signer.Error![]const u8 {
        const self = fromPtr(ptr);
        self.message.clearRetainingCapacity();
        self.message.appendSlice(testing.allocator, message) catch return error.OutOfMemory;
        return self.inner.sign(io, arena, message);
    }

    fn lifetime(ptr: *anyopaque) ?u32 {
        return fromPtr(ptr).inner.lifetimeS();
    }
};

fn publicKey() !rsa.PublicKey {
    var modulus: [256]u8 = undefined;
    _ = try std.fmt.hexToBytes(&modulus, key_modulus_hex);
    return rsa.PublicKey.fromBytes(&.{ 0x01, 0x00, 0x01 }, &modulus);
}

test "Google's V4 signing vectors, byte for byte, signatures included" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const file = try std.json.parseFromSliceLeaky(VectorFile, arena, vectors_json, .{ .ignore_unknown_fields = true });
    try testing.expectEqual(29, file.signingV4Tests.len);

    // Nothing is sent: both the key file's provider and the storage client
    // get a transport with nothing scripted.
    var fake: core.testing.FakeTransport = .init(gpa, &.{});
    defer fake.deinit();
    var account = try auth.ServiceAccount.initFromJson(gpa, testing.io, try keyFileJson(arena), .{ .transport = fake.transport() });
    defer account.deinit();
    var recording: Recording = .{ .inner = account.signer() };
    defer recording.message.deinit(gpa);
    const public_key = try publicKey();

    for (file.signingV4Tests) |v| {
        errdefer std.debug.print("vector: {s}\n", .{v.description});
        var clock: core.testing.FakeClock = .{ .now_ns = (try storage.parseTimestamp(v.timestamp)).nanoseconds };
        var token: core.testing.FakeTokenProvider = .{};
        var client: storage.Client = try .init(gpa, clock.io(), .{
            .endpoint = try endpointOf(arena, v),
            .token_provider = token.provider(),
            .transport = fake.transport(),
        });
        defer client.deinit();
        const options: storage.SignedUrlOptions = .{
            .method = std.meta.stringToEnum(storage.SignedMethod, v.method).?,
            .expires_in_s = v.expiration,
            .headers = try headersOf(arena, v.headers),
            .query = try queryOf(arena, v.queryParameters),
            .style = styleOf(v),
        };
        const bucket = client.bucket(v.bucket);
        const object = v.object orelse "";
        var url = if (object.len > 0)
            try bucket.object(object).signedUrl(recording.signer(), options)
        else
            try bucket.signedUrl(recording.signer(), options);
        defer url.deinit();

        try testing.expectEqualStrings(v.expectedUrl, url.value);
        try testing.expectEqualStrings(v.expectedStringToSign, recording.message.items);
        // The canonical request is in the string to sign as its hash. One
        // vector's expected canonical request is wrong in Google's data: it
        // keeps the bucket in the path that its own URL, string to sign and
        // signature have moved into the host.
        const hash = v.expectedStringToSign[std.mem.lastIndexOfScalar(u8, v.expectedStringToSign, '\n').? + 1 ..];
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(v.expectedCanonicalRequest, &digest, .{});
        const known_wrong = std.mem.eql(u8, v.description, "Universe domain with virtual hosted style");
        try testing.expectEqual(!known_wrong, std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), hash));
        // std's own RSA code, which shares nothing with auth's, accepts it.
        const marker = "&X-Goog-Signature=";
        const signature_hex = url.value[std.mem.lastIndexOf(u8, url.value, marker).? + marker.len ..];
        var signature: [256]u8 = undefined;
        try testing.expectEqual(signature.len, (try std.fmt.hexToBytes(&signature, signature_hex)).len);
        try rsa.PKCS1v1_5Signature.verify(256, signature, recording.message.items, public_key, Sha256);
    }
    try testing.expectEqual(0, fake.requests.items.len);
}

/// One case of testdata/signed_url_oracle.json.
const OracleCase = struct {
    bucket: []const u8,
    object: ?[]const u8,
    method: []const u8,
    expires: u32,
    signedAt: i64,
    style: []const u8,
    headers: []const [2][]const u8,
    query: []const [2][]const u8,
    boundHost: ?[]const u8 = null,
    boundScheme: ?[]const u8 = null,
    /// The URL up to its signature.
    url: []const u8,
    /// The last line of the string to sign.
    hash: []const u8,
};

const OracleFile = struct {
    library: []const u8,
    email: []const u8,
    cases: []const OracleCase,
};

test "400 cases Google's Python library signed, byte for byte" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const file = try std.json.parseFromSliceLeaky(OracleFile, arena, oracle_json, .{ .ignore_unknown_fields = true });
    try testing.expectEqual(400, file.cases.len);

    var fake: core.testing.FakeTransport = .init(gpa, &.{});
    defer fake.deinit();
    for (file.cases, 0..) |case, i| {
        errdefer std.debug.print("oracle case {d}: {s} {s}/{?s}\n", .{ i, case.method, case.bucket, case.object });
        var clock: core.testing.FakeClock = .{ .now_ns = @as(i96, case.signedAt) * std.time.ns_per_s };
        var token: core.testing.FakeTokenProvider = .{};
        var signer: core.testing.FakeSigner = .{ .account = file.email };
        var client: storage.Client = try .init(gpa, clock.io(), .{
            .token_provider = token.provider(),
            .transport = fake.transport(),
        });
        defer client.deinit();
        const headers = try arena.alloc(storage.Header, case.headers.len);
        for (case.headers, headers) |pair, *header| header.* = .{ .name = pair[0], .value = pair[1] };
        const query = try arena.alloc(storage.QueryParam, case.query.len);
        for (case.query, query) |pair, *param| param.* = .{ .name = pair[0], .value = pair[1] };
        const style: storage.UrlStyle = if (std.mem.eql(u8, case.style, "virtual"))
            .virtual_hosted
        else if (std.mem.eql(u8, case.style, "bound"))
            .{ .bucket_bound = .{
                .host = case.boundHost.?,
                .scheme = if (std.mem.eql(u8, case.boundScheme.?, "http")) .http else .https,
            } }
        else
            .path;
        const options: storage.SignedUrlOptions = .{
            .method = std.meta.stringToEnum(storage.SignedMethod, case.method).?,
            .expires_in_s = case.expires,
            .headers = headers,
            .query = query,
            .style = style,
        };
        const bucket = client.bucket(case.bucket);
        var url = if (case.object) |object|
            try bucket.object(object).signedUrl(signer.signer(), options)
        else
            try bucket.signedUrl(signer.signer(), options);
        defer url.deinit();

        try testing.expectEqualStrings(try std.mem.concat(arena, u8, &.{ case.url, "&X-Goog-Signature=5aa500ff" }), url.value);
        const date_marker = "X-Goog-Date=";
        const date_at = std.mem.indexOf(u8, case.url, date_marker).? + date_marker.len;
        const signed_at = case.url[date_at..][0..16];
        const want = try std.mem.concat(arena, u8, &.{
            "GOOG4-RSA-SHA256\n", signed_at, "\n", signed_at[0..8], "/auto/storage/goog4_request\n", case.hash,
        });
        try testing.expectEqualStrings(want, signer.lastMessage());
    }
}

test "through IAM: Google's first vector, with IAM answering its signature" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const file = try std.json.parseFromSliceLeaky(VectorFile, arena, vectors_json, .{ .ignore_unknown_fields = true });
    const v = file.signingV4Tests[0];
    try testing.expectEqualStrings("Simple GET", v.description);

    // IAM answers with the signature Google's vector expects.
    const marker = "&X-Goog-Signature=";
    const signature_hex = v.expectedUrl[std.mem.lastIndexOf(u8, v.expectedUrl, marker).? + marker.len ..];
    var signature: [256]u8 = undefined;
    _ = try std.fmt.hexToBytes(&signature, signature_hex);
    var encoded: [std.base64.standard.Encoder.calcSize(256)]u8 = undefined;
    const answer = try std.mem.concat(arena, u8, &.{
        "{\"keyId\":\"k1\",\"signedBlob\":\"", std.base64.standard.Encoder.encode(&encoded, &signature), "\"}",
    });
    var iam_fake: core.testing.FakeTransport = .init(gpa, &.{ .{ .respond = .{ .body = answer } }, .{ .respond = .{ .body = answer } } });
    defer iam_fake.deinit();
    var token: core.testing.FakeTokenProvider = .{ .token = "ya29.CALLER" };
    var clock: core.testing.FakeClock = .{ .now_ns = (try storage.parseTimestamp(v.timestamp)).nanoseconds };
    var iam: auth.IamSigner = try .init(gpa, clock.io(), .{
        .service_account = key_email,
        .token_provider = token.provider(),
        .transport = iam_fake.transport(),
    });
    defer iam.deinit();

    var storage_fake: core.testing.FakeTransport = .init(gpa, &.{});
    defer storage_fake.deinit();
    var client: storage.Client = try .init(gpa, clock.io(), .{ .token_provider = token.provider(), .transport = storage_fake.transport() });
    defer client.deinit();
    var url = try client.bucket(v.bucket).object(v.object.?).signedUrl(iam.signer(), .{ .expires_in_s = v.expiration });
    defer url.deinit();
    try testing.expectEqualStrings(v.expectedUrl, url.value);

    // What went to IAM is exactly the vector's string to sign, in base64.
    const body = (try iam_fake.request(0)).body.?;
    const prefix = "{\"payload\":\"";
    try testing.expect(std.mem.startsWith(u8, body, prefix) and std.mem.endsWith(u8, body, "\"}"));
    const payload = body[prefix.len .. body.len - 2];
    const decoded = try arena.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(payload));
    try std.base64.standard.Decoder.decode(decoded, payload);
    try testing.expectEqualStrings(v.expectedStringToSign, decoded);
    try testing.expectEqual(0, storage_fake.requests.items.len);

    // And through IAM, a URL may not outlast the 12 hours Google promises
    // its key for: refused before IAM is asked.
    try testing.expectError(error.InvalidSignedUrlOptions, client.bucket(v.bucket).object(v.object.?).signedUrl(iam.signer(), .{ .expires_in_s = 43_201 }));
    try testing.expectEqual(1, iam_fake.requests.items.len);
    var longest = try client.bucket(v.bucket).object(v.object.?).signedUrl(iam.signer(), .{ .expires_in_s = 43_200 });
    longest.deinit();
    try testing.expectEqual(2, iam_fake.requests.items.len);
}
