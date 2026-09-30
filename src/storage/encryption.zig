//! Encryption keys on the way out: the headers that carry a
//! customer-supplied key, built for one call on its stack and wiped when it
//! returns, the Cloud KMS key names a write may carry, and the checks
//! every keyed call shares.
//!
//! Measured against Cloud Storage on 2026-09-30:
//!
//! - A customer-supplied key travels as three headers, `x-goog-encryption-`
//!   `algorithm`, `key` and `key-sha256`, all three together; a rewrite's
//!   source takes the same three with `x-goog-copy-source-encryption-`.
//! - A media read, an upload, compose, and every XML multipart request that
//!   touches data (the start, each part, the finish) need the key. A read
//!   without it, or with another, is 400; so is a read that sends one for
//!   an object stored without one.
//! - A resumable upload takes the key at its start and nowhere else: its
//!   chunks ignore a key, even a wrong one, and a key sent only on the
//!   chunks encrypts nothing. So the key goes on the start alone.
//! - A metadata read or a patch works without the key but then withholds
//!   `crc32c` and `md5Hash`, and a listing always withholds them. A delete,
//!   a restore and `objects.move` never need it, and the last two ignore
//!   even a wrong one. So do the XML part list and abort.
//! - A Cloud KMS key is named by `kmsKeyName` on an upload, a resumable
//!   start and a compose, `destinationKmsKeyName` on a rewrite, and the
//!   `x-goog-encryption-kms-key-name` header on the XML API's start. A key
//!   version's name is refused as malformed, though objects report theirs.
//!   A copy that names no key gets the destination bucket's default, not
//!   the source's key. A customer key and a KMS key in one request are 409.
//! - Without the service agent's grant on the KMS key, or with a key that
//!   does not exist, a write is 403 "Permission denied on Cloud KMS key".

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const bucket_settings = @import("bucket_settings.zig");
const logging = @import("logging.zig");
const types = @import("types.zig");
const Error = @import("errors.zig").Error;
const Header = core.transport.Header;

/// The three headers that carry a customer-supplied key on one request,
/// with the key's base64 kept here rather than on the heap. Made on a
/// call's stack, where nothing moves it, and wiped when the call returns;
/// the header list points into it.
pub const KeyHeaders = struct {
    key_text: [44]u8 = @splat(0),
    sha_text: [44]u8 = @splat(0),
    list: [3]Header = undefined,
    len: usize = 0,

    /// Which request's key: the object's own, or a rewrite's source.
    pub const Role = enum { object, copy_source };

    /// Fills the headers for `key`, or leaves none for null.
    pub fn init(self: *KeyHeaders, key: ?*const types.EncryptionKey, role: Role) void {
        self.* = .{};
        const k = key orelse return;
        const encoder = std.base64.standard.Encoder;
        _ = encoder.encode(&self.key_text, &k.bytes);
        _ = encoder.encode(&self.sha_text, &k.sha256());
        const names: [3][]const u8 = switch (role) {
            .object => .{ "x-goog-encryption-algorithm", "x-goog-encryption-key", "x-goog-encryption-key-sha256" },
            .copy_source => .{ "x-goog-copy-source-encryption-algorithm", "x-goog-copy-source-encryption-key", "x-goog-copy-source-encryption-key-sha256" },
        };
        self.list = .{
            .{ .name = names[0], .value = "AES256" },
            .{ .name = names[1], .value = &self.key_text },
            .{ .name = names[2], .value = &self.sha_text },
        };
        self.len = 3;
    }

    pub fn slice(self: *const KeyHeaders) []const Header {
        return self.list[0..self.len];
    }

    /// Zeroes what held the key.
    pub fn wipe(self: *KeyHeaders) void {
        std.crypto.secureZero(u8, &self.key_text);
        std.crypto.secureZero(u8, &self.sha_text);
        self.len = 0;
    }
};

/// The base64 of `key`'s SHA-256 in `buf`, as a checkpoint records it, or
/// null for no key.
pub fn sha256Text(key: ?*const types.EncryptionKey, buf: *[44]u8) ?[]const u8 {
    const k = key orelse return null;
    return std.base64.standard.Encoder.encode(buf, &k.sha256());
}

/// Whether two optional strings are both null or equal.
pub fn sameOptional(a: ?[]const u8, b: ?[]const u8) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return std.mem.eql(u8, x, y);
}

/// A request's headers: `fixed`, then a key's, in `buffer`.
pub fn withKey(buffer: []Header, fixed: []const Header, key: *const KeyHeaders) []const Header {
    const keyed = key.slice();
    std.debug.assert(buffer.len >= fixed.len + keyed.len);
    @memcpy(buffer[0..fixed.len], fixed);
    @memcpy(buffer[fixed.len..][0..keyed.len], keyed);
    return buffer[0 .. fixed.len + keyed.len];
}

/// The Cloud KMS key a write names, as Cloud Storage takes it:
/// `projects/P/locations/L/keyRings/R/cryptoKeys/K`. A key version's
/// name, which `ObjectInfo.kms_key_name` holds, loses its
/// `/cryptoKeyVersions/N`, since Cloud Storage refuses a version as
/// malformed. Anything else is refused before sending. The result is a
/// prefix of `name`.
pub fn kmsKeyName(client: *Client, name: ?[]const u8) Error!?[]const u8 {
    const given = name orelse return null;
    const key = normalizedKmsKeyName(given) orelse {
        if (client.diagnostics) |d| d.print("the KMS key name is not projects/{{p}}/locations/{{l}}/keyRings/{{r}}/cryptoKeys/{{k}}", .{});
        return error.InvalidArgument;
    };
    if (key.len < given.len) logging.debug("the KMS key name names version {s}; writing under the key itself", .{given[key.len + version_marker.len ..]});
    return key;
}

const version_marker = "/cryptoKeyVersions/";

/// `name` as a write names a Cloud KMS key, its version dropped, or null
/// when it is not a key's name, or a version's. A name may go into a
/// header, on the XML API, so it must be a header value too.
pub fn normalizedKmsKeyName(name: []const u8) ?[]const u8 {
    var key = name;
    if (std.mem.lastIndexOf(u8, name, version_marker)) |at| {
        const version = name[at + version_marker.len ..];
        if (version.len > 0 and isDigits(version)) key = name[0..at];
    }
    if (bucket_settings.isKmsKeyName(key) and core.transport.isValidHeaderValue(key)) return key;
    return null;
}

fn isDigits(text: []const u8) bool {
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// A customer-supplied key and a Cloud KMS key cannot both encrypt one
/// object: Cloud Storage refuses the pair with 409.
pub fn checkOneKey(client: *Client, key: ?*const types.EncryptionKey, kms_key_name: ?[]const u8) Error!void {
    if (key == null or kms_key_name == null) return;
    if (client.diagnostics) |d| d.print("a customer-supplied key and a Cloud KMS key cannot both encrypt one object: name one", .{});
    return error.InvalidArgument;
}

const Allocator = std.mem.Allocator;
const checkpoint = @import("checkpoint.zig");
const test_util = @import("test_util.zig");
const testing = std.testing;
const EncryptionKey = types.EncryptionKey;

/// Bytes 0 to 31, and all ones: two keys, their base64, and the base64 of
/// their SHA-256, computed with Python.
const key_a_text = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=";
const key_a_sha = "Yw3NKWbEM2aRElRIu7JbT/QSpJxzLbLIq8G4WBvXEN0=";
const key_b_text = "//////////////////////////////////////////8=";
const key_b_sha = "r5YTdg9yY1+9tEpaCmPDnxKvMPlQpu5clxvhiOicQFE=";
const kms = "projects/p/locations/us/keyRings/r/cryptoKeys/k";

/// How many of `r`'s headers carry a customer key or a KMS key.
fn keyHeaderCount(r: anytype) usize {
    var n: usize = 0;
    for (r.headers) |h| {
        if (std.ascii.startsWithIgnoreCase(h.name, "x-goog-encryption-") or
            std.ascii.startsWithIgnoreCase(h.name, "x-goog-copy-source-encryption-")) n += 1;
    }
    return n;
}

/// `r` carries exactly the key whose base64 and SHA-256 are given, under
/// `prefix`, and those are its only key headers when `alone`.
fn expectKey(r: anytype, comptime prefix: []const u8, text: []const u8, sha: []const u8) !void {
    try testing.expectEqualStrings("AES256", r.header(prefix ++ "algorithm") orelse return error.TestNoKey);
    try testing.expectEqualStrings(text, r.header(prefix ++ "key") orelse return error.TestNoKey);
    try testing.expectEqualStrings(sha, r.header(prefix ++ "key-sha256") orelse return error.TestNoKey);
}

fn expectNoKey(r: anytype) !void {
    if (keyHeaderCount(r) != 0) {
        std.debug.print("unexpected key headers on {s}\n", .{r.url});
        return error.TestUnexpectedKey;
    }
}

test "keys: the three headers, and the wipe that zeroes them" {
    const key: EncryptionKey = try .fromBase64(key_a_text);
    var headers: KeyHeaders = undefined;
    headers.init(&key, .object);
    try testing.expectEqual(3, headers.slice().len);
    try testing.expectEqualStrings("x-goog-encryption-algorithm", headers.slice()[0].name);
    try testing.expectEqualStrings("AES256", headers.slice()[0].value);
    try testing.expectEqualStrings("x-goog-encryption-key", headers.slice()[1].name);
    try testing.expectEqualStrings(key_a_text, headers.slice()[1].value);
    try testing.expectEqualStrings("x-goog-encryption-key-sha256", headers.slice()[2].name);
    try testing.expectEqualStrings(key_a_sha, headers.slice()[2].value);
    headers.wipe();
    // Zeros, not merely the key gone.
    try testing.expectEqualSlices(u8, &@as([44]u8, @splat(0)), &headers.key_text);
    try testing.expectEqualSlices(u8, &@as([44]u8, @splat(0)), &headers.sha_text);
    try testing.expectEqual(0, headers.slice().len);

    headers.init(&key, .copy_source);
    defer headers.wipe();
    try testing.expectEqualStrings("x-goog-copy-source-encryption-key", headers.slice()[1].name);
    var none: KeyHeaders = undefined;
    none.init(null, .object);
    try testing.expectEqual(0, none.slice().len);

    var buffer: [4]Header = undefined;
    const joined = withKey(&buffer, &.{.{ .name = "Range", .value = "bytes=0-9" }}, &headers);
    try testing.expectEqual(4, joined.len);
    try testing.expectEqualStrings("Range", joined[0].name);
    try testing.expectEqualStrings("x-goog-copy-source-encryption-algorithm", joined[1].name);
}

const keyed_json =
    \\{"name":"a","bucket":"b","generation":"7","metageneration":"1","size":"2","crc32c":"UryDEg==",
    \\ "customerEncryption":{"encryptionAlgorithm":"AES256","keySha256":"Yw3NKWbEM2aRElRIu7JbT/QSpJxzLbLIq8G4WBvXEN0="}}
;

test "keys: a keyed handle carries its key where a call reads or writes the data, and nowhere else" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = keyed_json } },
        .{ .respond = .{ .body = keyed_json } },
        .{ .respond = .{ .body = keyed_json } },
        .{ .respond = .{ .body = "{\"done\":true,\"resource\":" ++ keyed_json ++ "}" } },
        .{ .respond = .{ .body = keyed_json } },
        .{ .respond = .{ .body = keyed_json } },
        .{ .respond = .{ .status = 204, .body = "" } },
        .{ .respond = .{ .body = "{\"items\":[]}" } },
        .{ .respond = .{ .body = keyed_json } },
        .{ .respond = .{ .body = keyed_json } },
        .{ .respond = .{ .body = "ab", .headers = &.{.{ .name = "x-goog-generation", .value = "7" }} } },
    }, .{});
    defer h.deinit();
    const a: EncryptionKey = try .fromBase64(key_a_text);
    const b: EncryptionKey = try .fromBase64(key_b_text);
    const bucket = h.client.bucket("b");
    const obj = bucket.object("a").withEncryptionKey(&a);

    var info = try obj.get(.{});
    try testing.expectEqualSlices(u8, &a.sha256(), &info.value.encryption_key_sha256.?);
    info.deinit();
    try testing.expect(try obj.exists());
    var patched = try obj.updateMetadata(.{ .content_type = "text/plain" });
    patched.deinit();
    // Rotation: the source's key as the copy source's, the destination's as
    // the object's own.
    var rotated = try obj.copyTo(bucket.object("c").withEncryptionKey(&b), .{});
    rotated.deinit();
    var composed = try obj.composeFrom(&.{.{ .name = "a" }}, .{});
    composed.deinit();
    var restored = try obj.restore(.{ .generation = 5 });
    restored.deinit();
    try obj.delete(.{ .generation = 7 });
    var listed = try bucket.listObjects(.{});
    listed.deinit();
    var soft = try obj.get(.{ .generation = 5, .soft_deleted = true });
    soft.deinit();
    var up = try obj.upload("ab", .{});
    up.deinit();
    var down = try obj.downloadAlloc(16, .{});
    down.deinit();

    try h.expectRequestCount(9);
    try expectKey(try h.fake.request(0), "x-goog-encryption-", key_a_text, key_a_sha);
    try testing.expectEqual(3, keyHeaderCount(try h.fake.request(0)));
    try expectNoKey(try h.fake.request(1));
    try expectKey(try h.fake.request(2), "x-goog-encryption-", key_a_text, key_a_sha);
    const rewrite = try h.fake.request(3);
    try testing.expect(std.mem.indexOf(u8, rewrite.url, "/rewriteTo/") != null);
    try expectKey(rewrite, "x-goog-copy-source-encryption-", key_a_text, key_a_sha);
    try expectKey(rewrite, "x-goog-encryption-", key_b_text, key_b_sha);
    try testing.expectEqual(6, keyHeaderCount(rewrite));
    try expectKey(try h.fake.request(4), "x-goog-encryption-", key_a_text, key_a_sha);
    // A restore, a delete, a listing and a soft-deleted read need none.
    for (5..9) |i| try expectNoKey(try h.fake.request(i));
    try expectKey(try h.fake.streamRequest(0), "x-goog-encryption-", key_a_text, key_a_sha);
    try expectKey(try h.fake.streamRequest(1), "x-goog-encryption-", key_a_text, key_a_sha);

    // Only the destination keyed, and only the source: the other set is
    // left out.
    var h2: test_util.Harness = undefined;
    const done = "{\"done\":true,\"resource\":" ++ keyed_json ++ "}";
    try h2.init(&.{ .{ .respond = .{ .body = done } }, .{ .respond = .{ .body = done } } }, .{});
    defer h2.deinit();
    const plain = h2.client.bucket("b").object("p");
    var encrypted = try plain.copyTo(plain.withEncryptionKey(&a), .{});
    encrypted.deinit();
    var decrypted = try plain.withEncryptionKey(&a).copyTo(plain, .{});
    decrypted.deinit();
    try expectKey(try h2.fake.request(0), "x-goog-encryption-", key_a_text, key_a_sha);
    try testing.expectEqual(3, keyHeaderCount(try h2.fake.request(0)));
    try expectKey(try h2.fake.request(1), "x-goog-copy-source-encryption-", key_a_text, key_a_sha);
    try testing.expectEqual(3, keyHeaderCount(try h2.fake.request(1)));
}

test "keys: a changed copy reads its source without the key, and every rewrite call carries both" {
    const source_json =
        \\{"name":"a","generation":"7","metageneration":"2","contentType":"text/plain"}
    ;
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = source_json } },
        .{ .respond = .{ .body = "{\"done\":false,\"rewriteToken\":\"t1\",\"totalBytesRewritten\":\"1\"}" } },
        .{ .respond = .{ .body = "{\"done\":true,\"resource\":" ++ keyed_json ++ "}" } },
    }, .{});
    defer h.deinit();
    const a: EncryptionKey = try .fromBase64(key_a_text);
    const b: EncryptionKey = try .fromBase64(key_b_text);
    const bucket = h.client.bucket("b");
    var copied = try bucket.object("a").withEncryptionKey(&a).copyTo(bucket.object("c").withEncryptionKey(&b), .{ .storage_class = "NEARLINE" });
    copied.deinit();
    try expectNoKey(try h.fake.request(0));
    for (1..3) |i| {
        const r = try h.fake.request(i);
        try expectKey(r, "x-goog-copy-source-encryption-", key_a_text, key_a_sha);
        try expectKey(r, "x-goog-encryption-", key_b_text, key_b_sha);
    }
    try testing.expect(std.mem.indexOf(u8, (try h.fake.request(2)).url, "rewriteToken=t1") != null);
}

test "keys: a Cloud KMS key goes as each call's parameter, a version dropped" {
    var h: test_util.Harness = undefined;
    const done = "{\"done\":true,\"resource\":" ++ keyed_json ++ "}";
    try h.init(&.{
        .{ .respond = .{ .body = "{}" } },
        .{ .respond = .{ .body = done } },
        .{ .respond = .{ .body = "{}" } },
    }, .{});
    defer h.deinit();
    const obj = h.client.bucket("b").object("a");
    var up = try obj.upload("ab", .{ .kms_key_name = kms ++ "/cryptoKeyVersions/3" });
    up.deinit();
    var copied = try obj.copyTo(h.client.bucket("b").object("c"), .{ .kms_key_name = kms });
    copied.deinit();
    var composed = try obj.composeFrom(&.{.{ .name = "a" }}, .{ .kms_key_name = kms, .preconditions = .does_not_exist });
    composed.deinit();
    const encoded = "projects%2Fp%2Flocations%2Fus%2FkeyRings%2Fr%2FcryptoKeys%2Fk";
    try testing.expectEqualStrings(
        "https://storage.googleapis.com/upload/storage/v1/b/b/o?uploadType=multipart&kmsKeyName=" ++ encoded,
        (try h.fake.streamRequest(0)).url,
    );
    try h.expectRequest(0, .POST, "https://storage.googleapis.com/storage/v1/b/b/o/a/rewriteTo/b/b/o/c?destinationKmsKeyName=" ++ encoded, "{}");
    try testing.expectEqualStrings(
        "https://storage.googleapis.com/storage/v1/b/b/o/a/compose?ifGenerationMatch=0&kmsKeyName=" ++ encoded,
        (try h.fake.request(1)).url,
    );
    for (0..2) |i| try expectNoKey(try h.fake.request(i));
    try expectNoKey(try h.fake.streamRequest(0));
}

test "keys: what cannot travel is refused before sending" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const a: EncryptionKey = try .fromBase64(key_a_text);
    const obj = h.client.bucket("b").object("a");
    const keyed = obj.withEncryptionKey(&a);

    // A customer key and a KMS key, on every call that writes.
    try testing.expectError(error.InvalidArgument, keyed.upload("ab", .{ .kms_key_name = kms }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "cannot both encrypt") != null);
    var reader: std.Io.Reader = .fixed("ab");
    try testing.expectError(error.InvalidArgument, keyed.uploadFrom(&reader, .{ .kms_key_name = kms }));
    try testing.expectError(error.InvalidArgument, keyed.uploadParallel(.{ .data = "ab" }, .{ .kms_key_name = kms }));
    try testing.expectError(error.InvalidArgument, keyed.composeFrom(&.{.{ .name = "a" }}, .{ .kms_key_name = kms }));
    try testing.expectError(error.InvalidArgument, obj.copyTo(keyed, .{ .kms_key_name = kms }));
    // A source's key goes as the copy source's: the destination may be
    // under a KMS key.
    // Names that are not a key's.
    for ([_][]const u8{
        "",
        "projects/p/locations/us/keyRings/r",
        "projects/p/locations/us/keyRings/r/cryptoKeys/",
        kms ++ "/cryptoKeyVersions/",
        kms ++ "/cryptoKeyVersions/x",
        kms ++ "/extra",
        "projects/p/locations/us/keyRings/r/cryptoKeys/k\r\nX: y",
    }) |bad| {
        errdefer std.debug.print("accepted {s}\n", .{bad});
        try testing.expectError(error.InvalidArgument, obj.upload("ab", .{ .kms_key_name = bad }));
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), "KMS key name") != null);
    }
    try testing.expectEqual(0, h.fake.stream_requests.items.len);
    try h.expectRequestCount(0);
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

test "keys: a signed URL signs the key's headers in, and a POST policy refuses a key" {
    var s: SigningSetup = undefined;
    try s.init();
    defer s.deinit();
    const a: EncryptionKey = try .fromBase64(key_a_text);
    const obj = s.client.bucket("b").object("a");
    var keyed = try obj.withEncryptionKey(&a).signedUrl(s.signer.signer(), .{
        .expires_in_s = 60,
        .headers = &.{.{ .name = "content-type", .value = "text/plain" }},
    });
    defer keyed.deinit();
    const keyed_message = try testing.allocator.dupe(u8, s.signer.message_buffer[0..s.signer.message_len]);
    defer testing.allocator.free(keyed_message);
    var by_hand = try obj.signedUrl(s.signer.signer(), .{
        .expires_in_s = 60,
        .headers = &.{
            .{ .name = "content-type", .value = "text/plain" },
            .{ .name = "x-goog-encryption-algorithm", .value = "AES256" },
            .{ .name = "x-goog-encryption-key", .value = key_a_text },
            .{ .name = "x-goog-encryption-key-sha256", .value = key_a_sha },
        },
    });
    defer by_hand.deinit();
    try testing.expectEqualStrings(by_hand.value, keyed.value);
    try testing.expectEqualStrings(s.signer.message_buffer[0..s.signer.message_len], keyed_message);
    // The names are in the URL; the key is not.
    try testing.expect(std.mem.indexOf(u8, keyed.value, "x-goog-encryption-key-sha256") != null);
    try testing.expectEqual(null, std.mem.indexOf(u8, keyed.value, key_a_text[0..20]));

    // Named by the caller too, on a keyed handle: refused, naming the header
    // and not its value.
    try testing.expectError(error.InvalidSignedUrlOptions, obj.withEncryptionKey(&a).signedUrl(s.signer.signer(), .{
        .expires_in_s = 60,
        .headers = &.{.{ .name = "X-Goog-Encryption-Key", .value = key_b_text }},
    }));
    try testing.expect(std.mem.indexOf(u8, s.diag.message(), "signs its own headers") != null);
    try testing.expectEqual(null, std.mem.indexOf(u8, s.diag.message(), key_b_text));

    const calls = s.signer.calls;
    try testing.expectError(error.InvalidPostPolicyOptions, obj.withEncryptionKey(&a).postPolicy(s.signer.signer(), .{ .expires_in_s = 60 }));
    try testing.expect(std.mem.indexOf(u8, s.diag.message(), "customer-supplied key") != null);
    try testing.expectEqual(calls, s.signer.calls);
}

test "keys: a refusal a key or a grant would have avoided says which" {
    const kms_refusal =
        \\{"error":{"code":403,"message":"Permission denied on Cloud KMS key. Please ensure that your Cloud Storage service account has been authorized to use this key.",
        \\ "errors":[{"message":"Permission denied on Cloud KMS key.","domain":"global","reason":"forbidden"}]}}
    ;
    var h: test_util.Harness = undefined;
    try h.init(&.{
        // Measured: a media read's refusal is plain text.
        .{ .respond = .{ .status = 400, .body = "The target object is encrypted by a customer-supplied encryption key." } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"The target object is encrypted by a customer-supplied encryption key.\",\"errors\":[{\"reason\":\"resourceIsEncryptedWithCustomerEncryptionKey\"}]}}" } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"The provided encryption key is incorrect.\",\"errors\":[{\"reason\":\"customerEncryptionKeyIsIncorrect\"}]}}" } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"The target object is not encrypted by a customer-supplied encryption key.\"}}" } },
        .{ .respond = .{ .status = 403, .body = kms_refusal } },
        .{ .respond = .{ .status = 403, .body = "{\"error\":{\"code\":403,\"message\":\"forbidden\"}}" } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"The target object is encrypted by a customer-supplied encryption key.\"}}" } },
        .{ .respond = .{ .status = 400, .body = "<?xml version='1.0' encoding='UTF-8'?><Error><Code>ResourceIsEncryptedWithCustomerEncryptionKey</Code><Message>The resource is encrypted with a customer encryption key.</Message></Error>" } },
        .{ .respond = .{ .status = 400, .body = "{\"error\":{\"code\":400,\"message\":\"The target object is not encrypted by a customer-supplied encryption key.\"}}" } },
    }, .{});
    defer h.deinit();
    const a: EncryptionKey = try .fromBase64(key_a_text);
    const obj = h.client.bucket("b").object("a");
    try testing.expectError(error.InvalidArgument, obj.downloadAlloc(16, .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "withEncryptionKey") != null);
    try testing.expectError(error.InvalidArgument, obj.get(.{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "withEncryptionKey") != null);
    // A keyed call keeps the server's words: the key it sent was wrong.
    try testing.expectError(error.InvalidArgument, obj.withEncryptionKey(&a).get(.{}));
    try testing.expectEqualStrings("The provided encryption key is incorrect.", h.diag.message());
    // So does a key sent for a plain object.
    try testing.expectError(error.InvalidArgument, obj.withEncryptionKey(&a).get(.{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "is not encrypted") != null);
    try testing.expectError(error.PermissionDenied, obj.upload("ab", .{ .kms_key_name = kms }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "Client.serviceAgent") != null);
    // Another 403 is left alone.
    try testing.expectError(error.PermissionDenied, obj.get(.{}));
    try testing.expectEqualStrings("forbidden", h.diag.message());
    // A request that carried a key is not told to carry one.
    try testing.expectError(error.InvalidArgument, obj.withEncryptionKey(&a).get(.{}));
    try testing.expectEqualStrings("The target object is encrypted by a customer-supplied encryption key.", h.diag.message());
    // The XML API's words for the same refusal.
    try testing.expectError(error.InvalidArgument, obj.downloadAlloc(16, .{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "withEncryptionKey") != null);
    // A refusal about a key sent where none belongs is not one of these.
    try testing.expectError(error.InvalidArgument, obj.get(.{}));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "withEncryptionKey") == null);
}

test "keys: serviceAgent reads the project's Cloud Storage service agent" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        // Measured on 2026-09-30.
        .{ .respond = .{ .body = "{\"kind\":\"storage#serviceAccount\",\"email_address\":\"service-82150720798@gs-project-accounts.iam.gserviceaccount.com\"}" } },
        .{ .respond = .{ .body = "{\"kind\":\"storage#serviceAccount\"}" } },
    }, .{});
    defer h.deinit();
    var agent = try h.client.serviceAgent();
    defer agent.deinit();
    try testing.expectEqualStrings("service-82150720798@gs-project-accounts.iam.gserviceaccount.com", agent.value);
    try h.expectRequest(0, .GET, "https://storage.googleapis.com/storage/v1/projects/extractctl/serviceAccount", null);
    try testing.expectError(error.InvalidResponse, h.client.serviceAgent());

    var none: test_util.Harness = undefined;
    try none.init(&.{}, .{ .project_id = null });
    defer none.deinit();
    try testing.expectError(error.MissingProject, none.client.serviceAgent());
    try testing.expect(std.mem.indexOf(u8, none.diag.message(), "service agent") != null);
}

// Against `FakeMultipart`, which holds keys to production's rules and
// fails any request this library must never send.

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

fn fillData(buf: []u8, seed: u64) void {
    var prng: std.Random.DefaultPrng = .init(seed);
    prng.random().bytes(buf);
}

test "against the fake: every transfer under a key goes and comes back, and none goes without it" {
    var fake: test_util.FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    fake.min_part_size = 1024;
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: core.Diagnostics = .{};
    var client = try clientOn(&fake, token.provider(), &diag);
    defer client.deinit();
    const a: EncryptionKey = try .fromBase64(key_a_text);
    const b: EncryptionKey = try .fromBase64(key_b_text);
    const bucket = client.bucket("b");

    var data: [600 * 1024]u8 = undefined;
    fillData(&data, 7);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source", .data = &data });
    const file = try tmp.dir.openFile(testing.io, "source", .{});
    defer file.close(testing.io);

    // One request, a resumable session from a stream and from a file, and
    // parallel parts, with and without conditions.
    var one = try bucket.object("one").withEncryptionKey(&a).upload(data[0..1000], .{});
    one.deinit();
    var reader: std.Io.Reader = .fixed(&data);
    var streamed = try bucket.object("streamed").withEncryptionKey(&a).uploadFrom(&reader, .{});
    try testing.expectEqual(core.crc32c.hash(&data), streamed.value.crc32c.?);
    streamed.deinit();
    var from_file = try bucket.object("file").withEncryptionKey(&a).uploadFile(file, .{});
    from_file.deinit();
    var parts = try bucket.object("parts").withEncryptionKey(&a).uploadParallel(.{ .data = &data }, .{ .part_size = 128 * 1024, .concurrency = 3 });
    try testing.expectEqual(core.crc32c.hash(&data), parts.value.crc32c.?);
    parts.deinit();
    var created = try bucket.object("created").withEncryptionKey(&a).uploadParallel(.{ .data = &data }, .{
        .part_size = 128 * 1024,
        .preconditions = .does_not_exist,
    });
    // The move names no checksum for a keyed object: the read back did.
    try testing.expectEqual(core.crc32c.hash(&data), created.value.crc32c.?);
    created.deinit();
    var zipped = try bucket.object("zipped").withEncryptionKey(&a).upload(data[0..2000], .{ .gzip = .{} });
    zipped.deinit();
    try expectNeverSent(&diag);
    for ([_][]const u8{ "one", "streamed", "file", "parts", "created", "zipped" }) |name| {
        errdefer std.debug.print("object {s}\n", .{name});
        try testing.expectEqualSlices(u8, &a.sha256(), &fake.object(name).?.key_sha256.?);
    }

    // Back, whole, in ranges, decompressed, and its metadata with checksums.
    for ([_][]const u8{ "streamed", "file", "parts", "created" }) |name| {
        errdefer std.debug.print("object {s}\n", .{name});
        var whole = try bucket.object(name).withEncryptionKey(&a).downloadAlloc(data.len, .{});
        defer whole.deinit();
        try testing.expect(whole.value.result.checksum_verified);
        try testing.expectEqualSlices(u8, &data, whole.value.data);
        var buffer: [data.len]u8 = undefined;
        const ranged = try bucket.object(name).withEncryptionKey(&a).downloadParallel(.{ .buffer = &buffer }, .{ .part_size = 1024 * 1024, .concurrency = 2 });
        try testing.expect(ranged.checksum_verified);
        try testing.expectEqualSlices(u8, &data, &buffer);
    }
    var unzipped = try bucket.object("zipped").withEncryptionKey(&a).downloadAlloc(data.len, .{});
    try testing.expectEqualSlices(u8, data[0..2000], unzipped.value.data);
    unzipped.deinit();
    var with_key = try bucket.object("one").withEncryptionKey(&a).get(.{});
    try testing.expect(with_key.value.crc32c != null);
    with_key.deinit();
    var without = try bucket.object("one").get(.{});
    try testing.expectEqual(null, without.value.crc32c);
    try testing.expectEqualSlices(u8, &a.sha256(), &without.value.encryption_key_sha256.?);
    without.deinit();
    try testing.expect(try bucket.object("one").withEncryptionKey(&b).exists());
    try expectNeverSent(&diag);

    // Without the key, with another, and a key for a plain object.
    try testing.expectError(error.InvalidArgument, bucket.object("parts").downloadAlloc(data.len, .{}));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "withEncryptionKey") != null);
    try testing.expectError(error.InvalidArgument, bucket.object("parts").withEncryptionKey(&b).downloadAlloc(data.len, .{}));
    try testing.expectEqualStrings("The provided encryption key is incorrect.", diag.message());
    var plain = try bucket.object("plain").upload("plain", .{});
    plain.deinit();
    try testing.expectError(error.InvalidArgument, bucket.object("plain").withEncryptionKey(&a).downloadAlloc(16, .{}));
    try testing.expectError(error.InvalidArgument, bucket.object("plain").withEncryptionKey(&a).get(.{}));
    // A parallel upload's parts under one key cannot be finished under another.
    try testing.expectEqual(0, fake.openUploads());
    try bucket.object("one").delete(.{});
    try expectNeverSent(&diag);
}

test "against the fake: a Cloud KMS key reaches every kind of upload, and a missing grant says what to grant" {
    var fake: test_util.FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    fake.min_part_size = 1024;
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: core.Diagnostics = .{};
    var client = try clientOn(&fake, token.provider(), &diag);
    defer client.deinit();
    const bucket = client.bucket("b");
    var data: [300 * 1024]u8 = undefined;
    fillData(&data, 11);

    var one = try bucket.object("one").upload(data[0..10], .{ .kms_key_name = kms });
    one.deinit();
    var reader: std.Io.Reader = .fixed(&data);
    var streamed = try bucket.object("streamed").uploadFrom(&reader, .{ .kms_key_name = kms ++ "/cryptoKeyVersions/2" });
    streamed.deinit();
    var parts = try bucket.object("parts").uploadParallel(.{ .data = &data }, .{ .part_size = 64 * 1024, .kms_key_name = kms });
    // The finish names no checksum under a KMS key: the read back did.
    try testing.expectEqual(core.crc32c.hash(&data), parts.value.crc32c.?);
    try testing.expectEqualStrings(kms ++ "/cryptoKeyVersions/1", parts.value.kms_key_name.?);
    parts.deinit();
    for ([_][]const u8{ "one", "streamed", "parts" }) |name| {
        errdefer std.debug.print("object {s}\n", .{name});
        try testing.expectEqualStrings(kms, fake.object(name).?.kms_key_name.?);
    }
    var back = try bucket.object("parts").downloadAlloc(data.len, .{});
    try testing.expectEqualSlices(u8, &data, back.value.data);
    back.deinit();
    try expectNeverSent(&diag);

    fake.kms_granted = false;
    try testing.expectError(error.PermissionDenied, bucket.object("x").upload("x", .{ .kms_key_name = kms }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "roles/cloudkms.cryptoKeyEncrypterDecrypter") != null);
    try testing.expectError(error.PermissionDenied, bucket.object("x").uploadParallel(.{ .data = &data }, .{ .part_size = 64 * 1024, .kms_key_name = kms }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "Client.serviceAgent") != null);
    try testing.expectEqual(0, fake.openUploads());
}

test "against the fake: requests carrying a key where none belongs fail the test that sent them" {
    var fake: test_util.FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    try fake.put("o", "bytes");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const keyed = [_]Header{
        .{ .name = "x-goog-encryption-algorithm", .value = "AES256" },
        .{ .name = "x-goog-encryption-key", .value = key_a_text },
        .{ .name = "x-goog-encryption-key-sha256", .value = key_a_sha },
    };
    const copy_source = [_]Header{
        .{ .name = "x-goog-copy-source-encryption-algorithm", .value = "AES256" },
        .{ .name = "x-goog-copy-source-encryption-key", .value = key_a_text },
        .{ .name = "x-goog-copy-source-encryption-key-sha256", .value = key_a_sha },
    };
    const base = "https://storage.googleapis.com/storage/v1/b/b/o/o";
    const cases = [_]struct { method: core.transport.Method, url: []const u8, headers: []const Header }{
        .{ .method = .DELETE, .url = base, .headers = &keyed },
        .{ .method = .GET, .url = base ++ "?generation=1&softDeleted=true", .headers = &keyed },
        .{ .method = .GET, .url = base, .headers = &copy_source },
        .{ .method = .GET, .url = base ++ "?kmsKeyName=k", .headers = &.{} },
        .{ .method = .GET, .url = base, .headers = &.{.{ .name = "x-goog-encryption-kms-key-name", .value = kms }} },
        .{ .method = .POST, .url = base ++ "/moveTo/o/p?ifSourceGenerationMatch=1000", .headers = &keyed },
        .{ .method = .DELETE, .url = "https://storage.googleapis.com/b/o?uploadId=u", .headers = &keyed },
        .{ .method = .GET, .url = "https://storage.googleapis.com/b/o?uploadId=u", .headers = &keyed },
    };
    for (cases) |case| {
        errdefer std.debug.print("{t} {s}\n", .{ case.method, case.url });
        const res = try fake.transport().send(.{ .method = case.method, .url = case.url, .headers = case.headers }, arena);
        try testing.expectEqual(400, res.status);
        try testing.expect(std.mem.indexOf(u8, res.body, "must never send") != null);
    }
    // And the three headers must agree, as production holds them.
    const read = try fake.transport().send(.{ .method = .GET, .url = base, .headers = &.{
        .{ .name = "x-goog-encryption-algorithm", .value = "AES256" },
        .{ .name = "x-goog-encryption-key", .value = key_a_text },
        .{ .name = "x-goog-encryption-key-sha256", .value = key_b_sha },
    } }, arena);
    try testing.expectEqual(400, read.status);
    try testing.expect(std.mem.indexOf(u8, read.body, "does not match the encryption key") != null);
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

/// Who resumes a checkpointed upload begun under key A.
const Resumer = enum { same_key, other_key, no_key, kms_key };

test "against the fake: a checkpointed upload resumes under the keys it began with, and starts over under others" {
    const a: EncryptionKey = try .fromBase64(key_a_text);
    const b: EncryptionKey = try .fromBase64(key_b_text);
    var data: [600 * 1024]u8 = undefined;
    fillData(&data, 23);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source", .data = &data });
    const file = try tmp.dir.openFile(testing.io, "source", .{});
    defer file.close(testing.io);

    for (std.enums.values(Resumer)) |resumer| {
        errdefer std.debug.print("resumed by {t}\n", .{resumer});
        for ([_]bool{ false, true }) |parallel_upload| {
            errdefer std.debug.print("parallel: {}\n", .{parallel_upload});
            var fake: test_util.FakeMultipart = .init(testing.allocator, testing.io);
            defer fake.deinit();
            fake.min_part_size = 1024;
            var token: core.StaticToken = .{ .token = "ya29.t" };
            var diag: core.Diagnostics = .{};
            var client = try clientOn(&fake, token.provider(), &diag);
            defer client.deinit();
            var saved: test_util.MemoryCheckpoint = .{ .gpa = testing.allocator };
            defer saved.deinit();
            const target = client.bucket("b").object("o");

            // The first run, under key A, dies partway.
            var dies_chunk: DiesAtSecondChunk = .{};
            var dies_part: DiesAfterFirstPart = .{};
            fake.faults = if (parallel_upload) dies_part.plan() else dies_chunk.plan();
            const first = if (parallel_upload)
                target.withEncryptionKey(&a).uploadParallel(.{ .file = file }, .{ .part_size = 100 * 1024, .concurrency = 1, .checkpoint = saved.checkpoint() })
            else
                target.withEncryptionKey(&a).uploadFile(file, .{ .checkpoint = saved.checkpoint() });
            try testing.expectError(error.Canceled, first);
            fake.faults = null;
            {
                var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
                defer arena_state.deinit();
                const state = try checkpoint.parse(arena_state.allocator(), saved.stored.?);
                // The key's SHA-256, never the key.
                const recorded = switch (state) {
                    .upload_file => |s| s.key_sha256,
                    .upload_parallel => |s| s.key_sha256,
                    .download_parallel => unreachable,
                };
                try testing.expectEqualStrings(key_a_sha, recorded.?);
                try testing.expectEqual(null, std.mem.indexOf(u8, saved.stored.?, key_a_text));
            }

            // The second run resumes, or starts over.
            const handle = switch (resumer) {
                .same_key => target.withEncryptionKey(&a),
                .other_key => target.withEncryptionKey(&b),
                .no_key, .kms_key => target,
            };
            const kms_name: ?[]const u8 = if (resumer == .kms_key) kms else null;
            const starts_before = if (parallel_upload) fake.counts.starts else fake.counts.session_starts;
            logging.capture.reset();
            var info = if (parallel_upload)
                try handle.uploadParallel(.{ .file = file }, .{ .part_size = 100 * 1024, .concurrency = 1, .checkpoint = saved.checkpoint(), .kms_key_name = kms_name })
            else
                try handle.uploadFile(file, .{ .checkpoint = saved.checkpoint(), .kms_key_name = kms_name });
            info.deinit();
            try expectNeverSent(&diag);
            const starts = (if (parallel_upload) fake.counts.starts else fake.counts.session_starts) - starts_before;
            const o = fake.object("o").?;
            try testing.expectEqualSlices(u8, &data, o.bytes);
            if (resumer == .same_key) {
                try testing.expectEqual(0, starts);
            } else {
                try testing.expectEqual(1, starts);
                try testing.expect(std.mem.indexOf(u8, logging.capture.text(), "another encryption key") != null);
            }
            switch (resumer) {
                .same_key => try testing.expectEqualSlices(u8, &a.sha256(), &o.key_sha256.?),
                .other_key => try testing.expectEqualSlices(u8, &b.sha256(), &o.key_sha256.?),
                .no_key => try testing.expectEqual(null, o.key_sha256),
                .kms_key => try testing.expectEqualStrings(kms, o.kms_key_name.?),
            }
            // Nothing of the first run is left open.
            try testing.expectEqual(0, fake.openUploads());
            try testing.expectEqual(0, fake.openSessions());
            try testing.expectEqual(null, saved.stored);
        }
    }
}

test "checkpoint: the key's SHA-256 and the KMS key are held to what this library writes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const good: checkpoint.State = .{ .upload_file = .{
        .bucket = "b",
        .object = "o",
        .size = 5,
        .mtime = 1,
        .session = "https://storage.googleapis.com/upload/x",
        .key_sha256 = key_a_sha,
        .kms_key_name = null,
    } };
    const bytes = try checkpoint.encodeAlloc(arena, good);
    try testing.expectEqualStrings(key_a_sha, (try checkpoint.parse(arena, bytes)).upload_file.key_sha256.?);
    // An older state, naming neither, still loads.
    var older = good;
    older.upload_file.key_sha256 = null;
    const older_bytes = try checkpoint.encodeAlloc(arena, older);
    try testing.expectEqual(null, std.mem.indexOf(u8, older_bytes, "key_sha256"));
    try testing.expectEqual(null, (try checkpoint.parse(arena, older_bytes)).upload_file.key_sha256);

    for ([_][]const u8{ "", "short", key_a_sha[0..43] ++ "\x00", "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHg==" }) |bad| {
        var forged = good;
        forged.upload_file.key_sha256 = bad;
        try testing.expectError(error.CheckpointFailed, checkpoint.parse(arena, try checkpoint.encodeAlloc(arena, forged)));
    }
    for ([_][]const u8{ "", "projects/p", kms ++ "/cryptoKeyVersions/1", kms ++ "\r\n" }) |bad| {
        var forged: checkpoint.State = .{ .upload_parallel = .{
            .bucket = "b",
            .object = "o",
            .size = 5,
            .mtime = 1,
            .upload_id = "u",
            .part_size = 1024,
            .temp = null,
            .if_generation_match = null,
            .if_generation_not_match = null,
            .if_metageneration_match = null,
            .if_metageneration_not_match = null,
            .kms_key_name = bad,
        } };
        try testing.expectError(error.CheckpointFailed, checkpoint.parse(arena, try checkpoint.encodeAlloc(arena, forged)));
        forged.upload_parallel.kms_key_name = kms;
        try testing.expectEqualStrings(kms, (try checkpoint.parse(arena, try checkpoint.encodeAlloc(arena, forged))).upload_parallel.kms_key_name.?);
    }
}

/// Neither the key's base64 nor its bytes are in `text`.
fn expectNoSecret(text: []const u8, key: *const EncryptionKey, where: []const u8) !void {
    const leaked = std.mem.indexOf(u8, text, key_a_text) != null or
        std.mem.indexOf(u8, text, key_b_text) != null or
        std.mem.indexOf(u8, text, &key.bytes) != null;
    if (leaked) {
        std.debug.print("the key reached {s}\n", .{where});
        return error.TestKeyLeaked;
    }
}

test "secrecy: the key reaches no log, diagnostic, checkpoint, URL or body" {
    logging.capture.reset();
    var fake: test_util.FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    fake.min_part_size = 1024;
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: core.Diagnostics = .{};
    var client = try clientOn(&fake, token.provider(), &diag);
    defer client.deinit();
    const a: EncryptionKey = try .fromBase64(key_a_text);
    const b: EncryptionKey = try .fromBase64(key_b_text);
    const obj = client.bucket("b").object("o").withEncryptionKey(&a);
    var data: [300 * 1024]u8 = undefined;
    fillData(&data, 31);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "source", .data = &data });
    const file = try tmp.dir.openFile(testing.io, "source", .{});
    defer file.close(testing.io);
    var saved: test_util.MemoryCheckpoint = .{ .gpa = testing.allocator };
    defer saved.deinit();

    // Every path that carries the key, a resumed one, and failures.
    var dies: DiesAtSecondChunk = .{};
    fake.faults = dies.plan();
    try testing.expectError(error.Canceled, obj.uploadFile(file, .{ .checkpoint = saved.checkpoint() }));
    try expectNoSecret(saved.stored.?, &a, "the checkpoint");
    fake.faults = null;
    var resumed = try obj.uploadFile(file, .{ .checkpoint = saved.checkpoint() });
    const generation = resumed.value.generation;
    resumed.deinit();
    try expectNoSecret(diag.message(), &a, "the diagnostics");
    var parts = try obj.uploadParallel(.{ .data = &data }, .{ .part_size = 64 * 1024, .preconditions = .{ .if_generation_match = generation } });
    parts.deinit();
    var whole = try obj.downloadAlloc(data.len, .{});
    whole.deinit();
    var buffer: [data.len]u8 = undefined;
    _ = try obj.downloadParallel(.{ .buffer = &buffer }, .{ .part_size = 1024 * 1024 });
    var info = try obj.get(.{});
    info.deinit();
    try testing.expectError(error.InvalidArgument, client.bucket("b").object("o").withEncryptionKey(&b).downloadAlloc(data.len, .{}));
    try expectNoSecret(diag.message(), &b, "the diagnostics");
    try testing.expectError(error.InvalidArgument, obj.upload("x", .{ .kms_key_name = kms }));
    try expectNoSecret(diag.message(), &a, "the diagnostics");
    try testing.expect(logging.capture.lines > 0);
    try expectNoSecret(logging.capture.text(), &a, "the log");

    // The request lines and bodies a transport records.
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = keyed_json } },
        .{ .respond = .{ .body = "{\"done\":true,\"resource\":" ++ keyed_json ++ "}" } },
        .{ .respond = .{ .body = keyed_json } },
    }, .{});
    defer h.deinit();
    const keyed = h.client.bucket("b").object("a").withEncryptionKey(&a);
    var got = try keyed.get(.{});
    got.deinit();
    var copied = try keyed.copyTo(h.client.bucket("b").object("c").withEncryptionKey(&b), .{});
    copied.deinit();
    var up = try keyed.upload("ab", .{});
    up.deinit();
    for (h.fake.requests.items) |r| {
        try expectNoSecret(r.url, &a, "a URL");
        if (r.body) |body| try expectNoSecret(body, &a, "a body");
    }
    for (h.fake.stream_requests.items) |r| {
        try expectNoSecret(r.url, &a, "a URL");
        try expectNoSecret(r.body_prefix, &a, "a body");
    }

    // A key formats as its SHA-256 alone.
    var shown_buf: [64]u8 = undefined;
    const shown = try std.fmt.bufPrint(&shown_buf, "{f}", .{&a});
    try expectNoSecret(shown, &a, "the format");
    try testing.expectEqualStrings(key_a_sha, shown);
}

// The model property: calls drawn over handles with the right key, another
// key and none, against the fake, where two names hold objects written
// under a key or none. Every outcome is the model's, and no request is one
// the fake refuses as never to be sent.

const Held = struct {
    /// Which key the object is under: 0 none, 1 key A, 2 key B. Null when
    /// no object has the name.
    key: ?u2 = null,
    len: usize = 0,
    bytes: [3000]u8 = undefined,
};

fn keyProperty(_: void, input: []const u8) !void {
    var g: test_util.ByteGen = .init(input);
    var fake: test_util.FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    fake.min_part_size = 1024;
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: core.Diagnostics = .{};
    var client = try clientOn(&fake, token.provider(), &diag);
    defer client.deinit();
    const keys = [_]EncryptionKey{ try .fromBase64(key_a_text), try .fromBase64(key_b_text) };
    var held: [2]Held = .{ .{}, .{} };
    const names = [_][]const u8{ "n0", "n1" };

    for (0..g.intRange(u8, 1, 8)) |_| {
        const which = g.intRange(u8, 0, 1);
        const choice = g.intRange(u2, 0, 2);
        const plain = client.bucket("b").object(names[which]);
        const obj = if (choice == 0) plain else plain.withEncryptionKey(&keys[choice - 1]);
        const h = &held[which];
        // A read needs the object's own key, and refuses one sent for an
        // object without.
        const fits = if (h.key) |k| k == choice else false;
        switch (g.intRange(u8, 0, 6)) {
            0, 1, 2 => |how| {
                const len = g.intRange(usize, 0, h.bytes.len);
                var fresh: [3000]u8 = undefined;
                fillData(fresh[0..len], g.intRange(u64, 0, 1 << 20));
                var info = switch (how) {
                    0 => try obj.upload(fresh[0..len], .{}),
                    1 => r: {
                        var reader: std.Io.Reader = .fixed(fresh[0..len]);
                        break :r try obj.uploadFrom(&reader, .{});
                    },
                    else => try obj.uploadParallel(.{ .data = fresh[0..len] }, .{ .part_size = 1024, .concurrency = 2 }),
                };
                try testing.expectEqual(core.crc32c.hash(fresh[0..len]), info.value.crc32c.?);
                info.deinit();
                h.* = .{ .key = choice, .len = len };
                @memcpy(h.bytes[0..len], fresh[0..len]);
            },
            3 => {
                const outcome = obj.get(.{});
                if (h.key == null) {
                    try testing.expectError(error.NotFound, outcome);
                } else if (choice != 0 and !fits) {
                    try testing.expectError(error.InvalidArgument, outcome);
                } else {
                    var info = try outcome;
                    defer info.deinit();
                    // Without its key, an object under one names no
                    // checksum; with it, or under none, it does.
                    try testing.expectEqual(h.key.? != 0 and choice == 0, info.value.crc32c == null);
                    if (h.key.? == 0) {
                        try testing.expectEqual(null, info.value.encryption_key_sha256);
                    } else {
                        try testing.expectEqualSlices(u8, &keys[h.key.? - 1].sha256(), &info.value.encryption_key_sha256.?);
                    }
                }
            },
            4 => {
                const outcome = obj.downloadAlloc(h.bytes.len, .{});
                if (h.key == null) {
                    try testing.expectError(error.NotFound, outcome);
                } else if (!fits) {
                    try testing.expectError(error.InvalidArgument, outcome);
                    if (choice == 0) try testing.expect(std.mem.indexOf(u8, diag.message(), "withEncryptionKey") != null);
                } else {
                    var got = try outcome;
                    defer got.deinit();
                    try testing.expect(got.value.result.checksum_verified);
                    try testing.expectEqualSlices(u8, h.bytes[0..h.len], got.value.data);
                }
            },
            5 => try testing.expectEqual(h.key != null, try obj.exists()),
            else => {
                obj.delete(.{}) catch |err| switch (err) {
                    error.NotFound => try testing.expectEqual(null, h.key),
                    else => |e| return e,
                };
                h.key = null;
            },
        }
        try expectNeverSent(&diag);
    }
    try testing.expectEqual(0, fake.openUploads());
}

test "heavy property keys: every call under the right key, another or none, is what the model says, and no key goes where none belongs" {
    try test_util.fuzzBytes({}, keyProperty, .{ .corpus = &.{ "", "\x01" ** 64, "\x00\x01\x02\x03\x04\x05\x06\x07" ** 8, "\x02\x05\x01\x03\x04" ** 16 } });
}

fn keyedEverything(gpa: Allocator) !void {
    var fake: test_util.FakeTransport = .init(gpa, &.{
        .{ .respond = .{ .body = keyed_json } },
        .{ .respond = .{ .body = keyed_json } },
        .{ .respond = .{ .body = "{\"done\":true,\"resource\":" ++ keyed_json ++ "}" } },
        .{ .respond = .{ .body = "ab", .headers = &.{.{ .name = "x-goog-generation", .value = "7" }} } },
        .{ .respond = .{ .body = "{\"email_address\":\"service-1@gs-project-accounts.iam.gserviceaccount.com\"}" } },
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
    const a: EncryptionKey = try .fromBase64(key_a_text);
    const obj = client.bucket("b").object("a").withEncryptionKey(&a);
    var info = try obj.get(.{});
    info.deinit();
    var up = try obj.upload("ab", .{});
    up.deinit();
    var copied = try obj.copyTo(client.bucket("b").object("c"), .{ .kms_key_name = kms });
    copied.deinit();
    var down = try obj.downloadAlloc(16, .{});
    down.deinit();
    var agent = try client.serviceAgent();
    agent.deinit();
}

test "keys: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, keyedEverything, .{});
}

test "keys: a resumable upload names its key at the start, and its chunks carry none" {
    const session = "https://storage.googleapis.com/upload/storage/v1/b/b/o?uploadType=resumable&upload_id=x1";
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "", .headers = &.{.{ .name = "Location", .value = session }} } },
        .{ .respond = .{ .status = 308, .body = "", .headers = &.{.{ .name = "Range", .value = "bytes=0-262143" }} } },
        .{ .respond = .{ .body = "{\"name\":\"a\",\"generation\":\"7\",\"size\":\"307200\"}" } },
    }, .{ .chunk_size = 256 * 1024, .single_request_limit = 256 * 1024, .verify_checksums = false });
    defer h.deinit();
    const a: EncryptionKey = try .fromBase64(key_a_text);
    var data: [300 * 1024]u8 = undefined;
    fillData(&data, 3);
    var info = try h.client.bucket("b").object("a").withEncryptionKey(&a).upload(&data, .{});
    info.deinit();
    try testing.expectEqual(3, h.fake.stream_requests.items.len);
    try expectKey(try h.fake.streamRequest(0), "x-goog-encryption-", key_a_text, key_a_sha);
    // Measured: the chunks ignore a key, even a wrong one.
    try expectNoKey(try h.fake.streamRequest(1));
    try expectNoKey(try h.fake.streamRequest(2));
}

test "against the fake: a keyed parallel upload that fails is aborted, with no key on the abort" {
    var fake: test_util.FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    fake.min_part_size = 1024;
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: core.Diagnostics = .{};
    var client = try clientOn(&fake, token.provider(), &diag);
    defer client.deinit();
    const a: EncryptionKey = try .fromBase64(key_a_text);
    var data: [8 * 1024]u8 = undefined;
    fillData(&data, 5);
    try testing.expectError(error.ChecksumMismatch, client.bucket("b").object("o").withEncryptionKey(&a).uploadParallel(.{ .data = &data }, .{
        .part_size = 1024,
        .crc32c = core.crc32c.hash(&data) ^ 1,
    }));
    try testing.expectEqual(1, fake.counts.aborts);
    try testing.expectEqual(0, fake.openUploads());
    try testing.expect(std.mem.indexOf(u8, diag.message(), "checksum mismatch") != null);
}

/// A key's model: the 44-character text std decodes to exactly 32 bytes and
/// encodes back to the same text, or null.
fn modelKey(text: []const u8) ?[32]u8 {
    if (text.len != 44) return null;
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(text) catch return null;
    if (len != 32) return null;
    var raw: [32]u8 = undefined;
    decoder.decode(&raw, text) catch return null;
    var again: [44]u8 = undefined;
    if (!std.mem.eql(u8, std.base64.standard.Encoder.encode(&again, &raw), text)) return null;
    return raw;
}

fn fromBase64Property(_: void, bytes: []const u8) !void {
    var g: test_util.ByteGen = .init(bytes);
    var text_buf: [44]u8 = undefined;
    // Mostly a key's text, sometimes with one character changed, and
    // sometimes any bytes at all.
    const text: []const u8 = if (g.intRange(u8, 0, 3) == 0) g.slice(60) else t: {
        var raw: [32]u8 = undefined;
        for (&raw) |*c| c.* = g.byte();
        _ = std.base64.standard.Encoder.encode(&text_buf, &raw);
        if (g.boolean()) text_buf[g.intRange(usize, 0, 43)] = g.byte();
        break :t &text_buf;
    };
    const want = modelKey(text);
    if (EncryptionKey.fromBase64(text)) |key| {
        const w = want orelse {
            std.debug.print("accepted {x}\n", .{text});
            return error.TestAcceptedWhatIsNotAKey;
        };
        try testing.expectEqualSlices(u8, &w, &key.bytes);
    } else |_| if (want != null) {
        std.debug.print("refused {s}\n", .{text});
        return error.TestRefusedAKey;
    }
}

test "fuzz encryption keys: fromBase64 takes exactly the base64 of 32 bytes, and gives them back" {
    try test_util.fuzzBytes({}, fromBase64Property, .{ .corpus = &.{ "", "\x01" ** 40, "\x00" ** 34 } });
}

fn kmsNameProperty(_: void, bytes: []const u8) !void {
    var g: test_util.ByteGen = .init(bytes);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // A key's name from its four parts, each sometimes mangled, and
    // sometimes a version after it.
    var built_valid = true;
    for ([_][]const u8{ "projects", "locations", "keyRings", "cryptoKeys" }, 0..) |literal, i| {
        if (i > 0) try w.writeByte('/');
        if (g.intRange(u8, 0, 15) == 0) {
            try w.writeAll(g.slice(4));
            built_valid = false;
        } else try w.writeAll(literal);
        try w.writeByte('/');
        const id_len = g.intRange(u8, 0, 8);
        if (id_len == 0) built_valid = false;
        const pool = "abcXYZ019-_.:/ \r\x80";
        for (0..id_len) |_| {
            const c = pool[g.byte() % pool.len];
            if (c == '/' or c == '\r' or c == '\x80') built_valid = false;
            try w.writeByte(c);
        }
    }
    const versioned = g.intRange(u8, 0, 3) == 0;
    if (versioned) {
        try w.writeAll(version_marker);
        for (0..g.intRange(u8, 0, 3)) |_| try w.writeByte("0129x"[g.byte() % 5]);
    }
    const name = w.buffered();
    // A name goes into a header: a space may not end it.
    if (!core.transport.isValidHeaderValue(name)) built_valid = false;
    const got = normalizedKmsKeyName(name) orelse {
        // Only a name built from its parts with no version is sure to be one.
        if (built_valid and !versioned) {
            std.debug.print("refused {s}\n", .{name});
            return error.TestRefusedAKey;
        }
        return;
    };
    // What goes out is a key's name, fit for a header, and either the name
    // given or it without a version's digits.
    try testing.expect(bucket_settings.isKmsKeyName(got));
    try testing.expect(core.transport.isValidHeaderValue(got));
    try testing.expect(std.mem.startsWith(u8, name, got));
    if (got.len < name.len) {
        const rest = name[got.len..];
        try testing.expect(std.mem.startsWith(u8, rest, version_marker));
        try testing.expect(rest.len > version_marker.len and isDigits(rest[version_marker.len..]));
    }
}

test "fuzz kms key names: a key's name, or a version's, goes out as the key's, and nothing else goes out" {
    try test_util.fuzzBytes({}, kmsNameProperty, .{ .corpus = &.{ "", "\x01" ** 64, "\x00\x00\x00\x00\x00\x00\x00\x03" ** 8 } });
}

test "against the fake: an XML upload's parts and finish are held to the key it began with, as production holds them" {
    var fake: test_util.FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const t = fake.transport();
    const with_a = [_]Header{
        .{ .name = "x-goog-encryption-algorithm", .value = "AES256" },
        .{ .name = "x-goog-encryption-key", .value = key_a_text },
        .{ .name = "x-goog-encryption-key-sha256", .value = key_a_sha },
    };
    const with_b = [_]Header{
        .{ .name = "x-goog-encryption-algorithm", .value = "AES256" },
        .{ .name = "x-goog-encryption-key", .value = key_b_text },
        .{ .name = "x-goog-encryption-key-sha256", .value = key_b_sha },
    };
    const url = "https://storage.googleapis.com/b/o";
    const started = try t.send(.{ .method = .POST, .url = url ++ "?uploads", .headers = &with_a }, arena);
    try testing.expectEqual(200, started.status);
    const part = url ++ "?partNumber=1&uploadId=VXBs%2B1%3D";
    for ([_]struct { headers: []const Header, code: []const u8 }{
        .{ .headers = &.{}, .code = "ResourceIsEncryptedWithCustomerEncryptionKey" },
        .{ .headers = &with_b, .code = "CustomerEncryptionKeyIsIncorrect" },
        .{ .headers = with_a[0..2], .code = "InvalidArgument" },
    }) |case| {
        const refused = try t.send(.{ .method = .PUT, .url = part, .headers = case.headers, .body = "x" }, arena);
        try testing.expectEqual(400, refused.status);
        try testing.expect(std.mem.indexOf(u8, refused.body, case.code) != null);
    }
    const sent = try t.send(.{ .method = .PUT, .url = part, .headers = &with_a, .body = "x" }, arena);
    try testing.expectEqual(200, sent.status);
    // A finish without it is refused like a part.
    const finish = try t.send(.{ .method = .POST, .url = url ++ "?uploadId=VXBs%2B1%3D", .body = "<CompleteMultipartUpload/>" }, arena);
    try testing.expectEqual(400, finish.status);
    try testing.expect(std.mem.indexOf(u8, finish.body, "ResourceIsEncryptedWithCustomerEncryptionKey") != null);

    // An upload begun without a key refuses a part that carries one.
    _ = try t.send(.{ .method = .POST, .url = "https://storage.googleapis.com/b/p?uploads" }, arena);
    const unexpected = try t.send(.{ .method = .PUT, .url = "https://storage.googleapis.com/b/p?partNumber=1&uploadId=VXBs%2B2%3D", .headers = &with_a, .body = "x" }, arena);
    try testing.expectEqual(400, unexpected.status);
    try testing.expect(std.mem.indexOf(u8, unexpected.body, "ResourceNotEncryptedWithCustomerEncryptionKey") != null);
    // A start or an upload whose key headers disagree, and a start naming
    // both kinds of key.
    const malformed = try t.send(.{ .method = .POST, .url = url ++ "?uploads", .headers = with_a[0..2] }, arena);
    try testing.expectEqual(400, malformed.status);
    const both = try t.send(.{ .method = .POST, .url = url ++ "?uploads", .headers = &(with_a ++ [_]Header{.{ .name = "x-goog-encryption-kms-key-name", .value = kms }}) }, arena);
    try testing.expectEqual(409, both.status);
}

test "against the fake: an emulator's one ordinary upload in place of a parallel one carries the keys" {
    var fake: test_util.FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var diag: core.Diagnostics = .{};
    var client: Client = try .init(testing.allocator, fake.io, .{
        .endpoint = .{ .url = "localhost:4443", .emulator = true },
        .transport = fake.transport(),
        .diagnostics = &diag,
    });
    defer client.deinit();
    const a: EncryptionKey = try .fromBase64(key_a_text);
    var data: [3000]u8 = undefined;
    fillData(&data, 41);
    var keyed = try client.bucket("b").object("keyed").withEncryptionKey(&a).uploadParallel(.{ .data = &data }, .{});
    keyed.deinit();
    var under_kms = try client.bucket("b").object("kms").uploadParallel(.{ .data = &data }, .{ .kms_key_name = kms });
    under_kms.deinit();
    try testing.expectEqual(0, fake.counts.starts);
    try testing.expectEqual(2, fake.counts.inserts);
    try testing.expectEqualSlices(u8, &a.sha256(), &fake.object("keyed").?.key_sha256.?);
    try testing.expectEqualStrings(kms, fake.object("kms").?.kms_key_name.?);
}

test "against the fake: a keyed gzip object larger than a chunk is pulled in ranges, each with the key" {
    var fake: test_util.FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: core.Diagnostics = .{};
    var client = try clientOn(&fake, token.provider(), &diag);
    defer client.deinit();
    const a: EncryptionKey = try .fromBase64(key_a_text);
    // Random bytes barely compress, so the stored object spans chunks.
    var data: [700 * 1024]u8 = undefined;
    fillData(&data, 43);
    const obj = client.bucket("b").object("big.gz").withEncryptionKey(&a);
    var up = try obj.upload(&data, .{ .gzip = .{} });
    up.deinit();
    try testing.expect(fake.object("big.gz").?.bytes.len > 2 * 256 * 1024);
    const media_before = fake.counts.media;
    var back = try obj.downloadAlloc(data.len, .{});
    defer back.deinit();
    try testing.expectEqualSlices(u8, &data, back.value.data);
    try testing.expect(fake.counts.media - media_before > 1);
    try expectNeverSent(&diag);
}
