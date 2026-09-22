//! Signed URLs against a real bucket: what only Google can check, which is
//! the signature itself and what Cloud Storage does with each kind of URL.
//!
//!     GCP_TEST_BUCKET=my-test-bucket \
//!     GCP_TEST_TOKEN=$(gcloud auth application-default print-access-token) \
//!     GCP_TEST_SIGNER_KEY=/path/to/key.json \
//!     GCP_TEST_SIGNER_EMAIL=signer@my-project.iam.gserviceaccount.com \
//!     zig build test-integration-gcp
//!
//! The token manages the test objects; the URLs themselves are used with no
//! credentials at all, as a browser would. Every test runs once for each
//! signer configured: the key file signs on this machine, and the email
//! signs through IAM with the token, whose principal needs Token Creator on
//! that account. The account needs Storage Object Admin on the bucket,
//! since a signed URL grants only what its signer may do. Without a bucket,
//! a token and at least one signer, every test skips. Objects live under
//! `zig-gcp-test/<random>/` and are deleted when each test ends.

const std = @import("std");
const core = @import("core");
const storage = @import("storage");
const auth = @import("auth");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// A signer, and what to call it when a test fails.
const Named = struct { name: []const u8, signer: core.Signer };

const Fixture = struct {
    env: std.process.Environ.Map,
    token: storage.StaticToken,
    diag: storage.Diagnostics,
    signer_diag: storage.Diagnostics,
    client: storage.Client,
    arena: std.heap.ArenaAllocator,
    /// Borrowed from `env`.
    bucket_name: []const u8,
    /// "zig-gcp-test/" plus 8 random hex digits and a slash, unique per test.
    prefix: [22]u8,
    key: ?auth.ServiceAccount,
    iam: ?auth.IamSigner,

    /// Returns false when the suite is not configured; the test should skip.
    fn init(f: *Fixture) !bool {
        const gpa = testing.allocator;
        f.env = try testing.environ.createMap(gpa);
        errdefer f.env.deinit();
        const bucket_name = f.env.get("GCP_TEST_BUCKET") orelse return f.skip();
        const token = f.env.get("GCP_TEST_TOKEN") orelse return f.skip();
        const key_path = f.env.get("GCP_TEST_SIGNER_KEY");
        const signer_email = f.env.get("GCP_TEST_SIGNER_EMAIL");
        if (key_path == null and signer_email == null) return f.skip();
        f.bucket_name = trim(bucket_name);
        f.token = .{ .token = trim(token) };
        f.diag = .{};
        f.signer_diag = .{};
        f.arena = .init(gpa);
        errdefer f.arena.deinit();
        var random: [4]u8 = undefined;
        testing.io.random(&random);
        _ = try std.fmt.bufPrint(&f.prefix, "zig-gcp-test/{x}/", .{random});
        f.client = try .init(gpa, testing.io, .{
            .token_provider = f.token.provider(),
            .diagnostics = &f.diag,
            .user_agent = user_agent,
        });
        errdefer f.client.deinit();
        f.key = if (key_path) |path|
            try auth.ServiceAccount.initFromFile(gpa, testing.io, trim(path), .{ .diagnostics = &f.signer_diag })
        else
            null;
        errdefer if (f.key) |*k| k.deinit();
        f.iam = if (signer_email) |email| try auth.IamSigner.init(gpa, testing.io, .{
            .service_account = trim(email),
            .token_provider = f.token.provider(),
            .diagnostics = &f.signer_diag,
        }) else null;
        return true;
    }

    const user_agent = "zig-gcp-signed-url-gcp-integration/0.1";

    fn skip(f: *Fixture) bool {
        f.env.deinit();
        return false;
    }

    fn deinit(f: *Fixture) void {
        const b = f.bucket();
        var page_token: ?[]const u8 = null;
        for (0..100) |_| {
            var page = b.listObjects(.{ .prefix = &f.prefix, .page_token = page_token }) catch break;
            defer page.deinit();
            for (page.value.objects) |info| {
                b.object(info.name).delete(.{ .generation = info.generation }) catch |err| {
                    std.debug.print("cleanup: could not delete {s}: {t}\n", .{ info.name, err });
                };
            }
            const next = page.value.next_page_token orelse break;
            page_token = f.arena.allocator().dupe(u8, next) catch break;
        }
        if (f.iam) |*i| i.deinit();
        if (f.key) |*k| k.deinit();
        f.client.deinit();
        f.arena.deinit();
        f.env.deinit();
    }

    fn bucket(f: *Fixture) storage.Bucket {
        return f.client.bucket(f.bucket_name);
    }

    /// A handle on `what` under the test's prefix.
    fn object(f: *Fixture, what: []const u8) !storage.Object {
        const name = try std.fmt.allocPrint(f.arena.allocator(), "{s}{s}", .{ &f.prefix, what });
        return f.bucket().object(name);
    }

    /// Uploads `data` as `what`, through the client and its token.
    fn put(f: *Fixture, what: []const u8, data: []const u8) !storage.Object {
        const obj = try f.object(what);
        var info = obj.upload(data, .{ .content_type = "text/plain" }) catch |err| return f.report(err);
        info.deinit();
        return obj;
    }

    /// The signers configured, the key file first.
    fn signers(f: *Fixture, out: *[2]Named) []const Named {
        var n: usize = 0;
        if (f.key) |*k| {
            out[n] = .{ .name = "key", .signer = k.signer() };
            n += 1;
        }
        if (f.iam) |*i| {
            out[n] = .{ .name = "iam", .signer = i.signer() };
            n += 1;
        }
        return out[0..n];
    }

    /// Signs, printing the server's or the signer's own words on failure.
    fn sign(f: *Fixture, obj: storage.Object, signer: core.Signer, options: storage.SignedUrlOptions) ![]const u8 {
        var url = obj.signedUrl(signer, options) catch |err| {
            std.debug.print("signing failed: {t}: {s} {s}\n", .{ err, f.diag.message(), f.signer_diag.message() });
            return err;
        };
        defer url.deinit();
        return f.arena.allocator().dupe(u8, url.value);
    }

    fn report(f: *const Fixture, err: anyerror) anyerror {
        std.debug.print("{t}: HTTP {d} {s}: {s}\n", .{ err, f.diag.http_status, f.diag.status(), f.diag.message() });
        return err;
    }
};

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, &std.ascii.whitespace);
}

/// What came back from using a URL.
const Answer = struct {
    status: u16,
    headers: []const std.http.Header,
    body: []const u8,

    fn header(a: Answer, name: []const u8) ?[]const u8 {
        for (a.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    /// The `<Code>` of an XML error body, or "".
    fn code(a: Answer) []const u8 {
        return xmlElement(a.body, "Code") orelse "";
    }
};

/// Uses `url` as a browser would: no credentials, nothing but `headers`
/// and the body. Everything that comes back lands in `arena`.
fn useUrl(arena: Allocator, method: std.http.Method, url: []const u8, headers: []const std.http.Header, body: ?[]const u8) !Answer {
    var http: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer http.deinit();
    var request = try http.request(method, try std.Uri.parse(url), .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{
            .user_agent = .{ .override = Fixture.user_agent },
            .accept_encoding = .{ .override = "identity" },
            .content_type = .omit,
        },
        .extra_headers = headers,
    });
    defer request.deinit();
    if (body != null or method.requestHasBody()) {
        const data = body orelse "";
        request.transfer_encoding = .{ .content_length = data.len };
        var buffer: [4096]u8 = undefined;
        var writer = try request.sendBodyUnflushed(&buffer);
        try writer.writer.writeAll(data);
        try writer.end();
        try request.connection.?.flush();
    } else {
        try request.sendBodiless();
    }
    var response = try request.receiveHead(&.{});
    var copied: std.ArrayList(std.http.Header) = .empty;
    var it = response.head.iterateHeaders();
    while (it.next()) |h| try copied.append(arena, .{ .name = try arena.dupe(u8, h.name), .value = try arena.dupe(u8, h.value) });
    const status: u16 = @intFromEnum(response.head.status);
    var transfer: [64]u8 = undefined;
    const got = try response.reader(&transfer).allocRemaining(arena, .limited(16 * 1024 * 1024));
    return .{ .status = status, .headers = copied.items, .body = got };
}

/// The text of the first `<name>` element, XML entities and all.
fn xmlElement(xml: []const u8, comptime name: []const u8) ?[]const u8 {
    const open = "<" ++ name ++ ">";
    const start = (std.mem.indexOf(u8, xml, open) orelse return null) + open.len;
    const end = std.mem.indexOfPos(u8, xml, start, "</" ++ name ++ ">") orelse return null;
    return xml[start..end];
}

/// Undoes XML's five entities, which Google's error bodies use.
fn xmlText(arena: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const entities = [_][2][]const u8{ .{ "&amp;", "&" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&apos;", "'" } };
        const found = for (entities) |e| {
            if (std.mem.startsWith(u8, text[i..], e[0])) break e;
        } else null;
        if (found) |e| {
            try out.appendSlice(arena, e[1]);
            i += e[0].len;
        } else {
            try out.append(arena, text[i]);
            i += 1;
        }
    }
    return out.items;
}

/// Signs through another signer and keeps the last string to sign.
const Recording = struct {
    inner: core.Signer,
    buffer: [256]u8 = undefined,
    len: usize = 0,

    fn signer(self: *Recording) core.Signer {
        return .{ .ptr = self, .vtable = &.{ .email = email, .sign = sign, .lifetime_s = lifetime } };
    }

    fn message(self: *const Recording) []const u8 {
        return self.buffer[0..self.len];
    }

    fn fromPtr(ptr: *anyopaque) *Recording {
        return @ptrCast(@alignCast(ptr));
    }

    fn email(ptr: *anyopaque, io: std.Io, arena: Allocator) core.Signer.Error![]const u8 {
        return fromPtr(ptr).inner.email(io, arena);
    }

    fn sign(ptr: *anyopaque, io: std.Io, arena: Allocator, bytes: []const u8) core.Signer.Error![]const u8 {
        const self = fromPtr(ptr);
        self.len = @min(bytes.len, self.buffer.len);
        @memcpy(self.buffer[0..self.len], bytes[0..self.len]);
        return self.inner.sign(io, arena, bytes);
    }

    fn lifetime(ptr: *anyopaque) ?u32 {
        return fromPtr(ptr).inner.lifetimeS();
    }
};

fn expectStatus(want: u16, got: Answer, what: []const u8) !void {
    if (want == got.status) return;
    std.debug.print("{s}: expected HTTP {d}, got {d}: {s}\n", .{ what, want, got.status, got.body[0..@min(got.body.len, 600)] });
    return error.TestUnexpectedStatus;
}

const hello = "hello, signed world\n";

test "signed URLs, real bucket: GET and HEAD read a private object with no credentials" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const a = f.arena.allocator();
    var buffer: [2]Named = undefined;
    for (f.signers(&buffer)) |s| {
        const obj = try f.put(s.name, hello);
        const get = try useUrl(a, .GET, try f.sign(obj, s.signer, .{ .expires_in_s = 300 }), &.{}, null);
        try expectStatus(200, get, s.name);
        try testing.expectEqualStrings(hello, get.body);
        try testing.expectEqualStrings("text/plain", get.header("Content-Type").?);
        const head = try useUrl(a, .HEAD, try f.sign(obj, s.signer, .{ .method = .HEAD, .expires_in_s = 300 }), &.{}, null);
        try expectStatus(200, head, s.name);
        try testing.expectEqualStrings("20", head.header("Content-Length").?);
        // A GET URL does not stretch to a DELETE.
        const wrong = try useUrl(a, .DELETE, try f.sign(obj, s.signer, .{ .expires_in_s = 300 }), &.{}, null);
        try expectStatus(403, wrong, s.name);
    }
}

test "signed URLs, real bucket: a PUT stores with its signed content type, and no other" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const a = f.arena.allocator();
    var buffer: [2]Named = undefined;
    for (f.signers(&buffer)) |s| {
        const obj = try f.object(s.name);
        const content_type: std.http.Header = .{ .name = "content-type", .value = "image/png" };
        const url = try f.sign(obj, s.signer, .{ .method = .PUT, .expires_in_s = 300, .headers = &.{content_type} });
        try expectStatus(200, try useUrl(a, .PUT, url, &.{content_type}, "not really a png"), s.name);
        var info = try obj.get(.{});
        defer info.deinit();
        try testing.expectEqualStrings("image/png", info.value.content_type);
        try testing.expectEqual(16, info.value.size);
        const other = try useUrl(a, .PUT, url, &.{.{ .name = "content-type", .value = "text/html" }}, "<script>");
        try expectStatus(403, other, s.name);
        try testing.expectEqualStrings("SignatureDoesNotMatch", other.code());
    }
}

test "signed URLs, real bucket: DELETE removes the object" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const a = f.arena.allocator();
    var buffer: [2]Named = undefined;
    for (f.signers(&buffer)) |s| {
        const obj = try f.put(s.name, hello);
        const gone = try useUrl(a, .DELETE, try f.sign(obj, s.signer, .{ .method = .DELETE, .expires_in_s = 300 }), &.{}, null);
        try expectStatus(204, gone, s.name);
        try testing.expect(!try obj.exists());
    }
}

test "signed URLs, real bucket: a signed POST starts a resumable upload, and its session needs no signature" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const a = f.arena.allocator();
    var buffer: [2]Named = undefined;
    for (f.signers(&buffer)) |s| {
        const obj = try f.object(s.name);
        const resumable: std.http.Header = .{ .name = "x-goog-resumable", .value = "start" };
        const start = try useUrl(a, .POST, try f.sign(obj, s.signer, .{ .method = .POST, .expires_in_s = 300, .headers = &.{resumable} }), &.{resumable}, null);
        try expectStatus(201, start, s.name);
        const session = start.header("Location") orelse return error.TestNoSessionUri;
        const done = try useUrl(a, .PUT, session, &.{}, "sent to the session URI\n");
        if (done.status != 200 and done.status != 201) try expectStatus(200, done, s.name);
        var round = try obj.downloadAlloc(1024, .{});
        defer round.deinit();
        try testing.expectEqualStrings("sent to the session URI\n", round.value.data);
    }
}

test "signed URLs, real bucket: an expired URL is refused" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const a = f.arena.allocator();
    var buffer: [2]Named = undefined;
    for (f.signers(&buffer)) |s| {
        const obj = try f.put(s.name, hello);
        const url = try f.sign(obj, s.signer, .{ .expires_in_s = 1 });
        try testing.io.sleep(.fromSeconds(3), .awake);
        const late = try useUrl(a, .GET, url, &.{}, null);
        try expectStatus(400, late, s.name);
        try testing.expectEqualStrings("ExpiredToken", late.code());
    }
}

test "signed URLs, real bucket: Google computes the same canonical request, for every awkward input" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const a = f.arena.allocator();
    var buffer: [2]Named = undefined;
    for (f.signers(&buffer)) |s| {
        // Every character a URL treats specially, UTF-8, a space and a plus.
        const name = try std.fmt.allocPrint(a, "{s} awk ward/+%\xc3\xa9~!*'();:@&=$,[]#?.txt", .{s.name});
        const obj = try f.put(name, hello);
        var recording: Recording = .{ .inner = s.signer };
        const headers: []const std.http.Header = &.{.{ .name = "x-goog-meta-note", .value = "runs \t of   spaces" }};
        const url = try f.sign(obj, recording.signer(), .{
            .expires_in_s = 300,
            .headers = headers,
            // Names where one is a prefix of another, sorted by name, and a
            // value full of what query strings reserve.
            .query = &.{
                .{ .name = "a0", .value = "3" },
                .{ .name = "a", .value = "1" },
                .{ .name = "a-b", .value = "2" },
                .{ .name = "q", .value = "x y/z&w=v+%\xc3\xa9" },
            },
        });
        // One hex digit off, the signature fails, and Google says what it
        // computed: the string to sign names the canonical request's hash.
        const tampered = try a.dupe(u8, url);
        const last = &tampered[tampered.len - 1];
        last.* = if (last.* == '0') '1' else '0';
        const refused = try useUrl(a, .GET, tampered, headers, null);
        try expectStatus(403, refused, s.name);
        try testing.expectEqualStrings("SignatureDoesNotMatch", refused.code());
        const google_sts = try xmlText(a, xmlElement(refused.body, "StringToSign") orelse return error.TestNoStringToSign);
        if (!std.mem.eql(u8, google_sts, recording.message())) {
            const google_cr = try xmlText(a, xmlElement(refused.body, "CanonicalRequest") orelse "");
            std.debug.print("{s}: Google's canonical request:\n{s}\nGoogle's string to sign:\n{s}\nours:\n{s}\n", .{ s.name, google_cr, google_sts, recording.message() });
            return error.TestCanonicalRequestsDiffer;
        }
        if (xmlElement(refused.body, "CanonicalRequest")) |text| {
            var digest: [Sha256.digest_length]u8 = undefined;
            Sha256.hash(try xmlText(a, text), &digest, .{});
            try testing.expect(std.mem.endsWith(u8, recording.message(), &std.fmt.bytesToHex(digest, .lower)));
        }
        // And the real signature works.
        try expectStatus(200, try useUrl(a, .GET, url, headers, null), s.name);
    }
}

test "signed URLs, real bucket: response-content-disposition comes back as Content-Disposition" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const a = f.arena.allocator();
    var buffer: [2]Named = undefined;
    for (f.signers(&buffer)) |s| {
        const obj = try f.put(s.name, hello);
        const disposition = "attachment; filename=\"tom.txt\"";
        const got = try useUrl(a, .GET, try f.sign(obj, s.signer, .{
            .expires_in_s = 300,
            .query = &.{.{ .name = "response-content-disposition", .value = disposition }},
        }), &.{}, null);
        try expectStatus(200, got, s.name);
        try testing.expectEqualStrings(disposition, got.header("Content-Disposition").?);
    }
}

test "signed URLs, real bucket: virtual-hosted style over https" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    if (std.mem.indexOfScalar(u8, f.bucket_name, '.') != null) return error.SkipZigTest;
    const a = f.arena.allocator();
    var buffer: [2]Named = undefined;
    for (f.signers(&buffer)) |s| {
        const obj = try f.put(s.name, hello);
        const url = try f.sign(obj, s.signer, .{ .expires_in_s = 300, .style = .virtual_hosted });
        try testing.expect(std.mem.startsWith(u8, url, try std.fmt.allocPrint(a, "https://{s}.storage.googleapis.com/", .{f.bucket_name})));
        const got = try useUrl(a, .GET, url, &.{}, null);
        try expectStatus(200, got, s.name);
        try testing.expectEqualStrings(hello, got.body);
    }
}

test "signed URLs, real bucket: create-only and size-capped uploads" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const a = f.arena.allocator();
    var buffer: [2]Named = undefined;
    for (f.signers(&buffer)) |s| {
        const create_only: std.http.Header = .{ .name = "x-goog-if-generation-match", .value = "0" };
        const once = try f.sign(try f.object(s.name), s.signer, .{ .method = .PUT, .expires_in_s = 300, .headers = &.{create_only} });
        try expectStatus(200, try useUrl(a, .PUT, once, &.{create_only}, "first"), s.name);
        try expectStatus(412, try useUrl(a, .PUT, once, &.{create_only}, "second"), s.name);

        const capped: std.http.Header = .{ .name = "x-goog-content-length-range", .value = "0,10" };
        const small = try f.sign(try f.object(try std.fmt.allocPrint(a, "{s}-capped", .{s.name})), s.signer, .{ .method = .PUT, .expires_in_s = 300, .headers = &.{capped} });
        try expectStatus(200, try useUrl(a, .PUT, small, &.{capped}, "ten bytes!"), s.name);
        const big = try useUrl(a, .PUT, small, &.{capped}, "eleven byte");
        try expectStatus(400, big, s.name);
    }
}

test "signed URLs, real bucket: a URL is good from 15 minutes before its date, and not earlier" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const a = f.arena.allocator();
    var buffer: [2]Named = undefined;
    for (f.signers(&buffer)) |s| {
        const obj = try f.put(s.name, hello);
        for ([_]struct { minutes: i64, works: bool }{ .{ .minutes = 5, .works = true }, .{ .minutes = 20, .works = false } }) |case| {
            // A client whose clock runs ahead signs a URL dated in the future.
            var clock: core.testing.FakeClock = .{ .now_ns = std.Io.Clock.real.now(testing.io).nanoseconds + @as(i96, case.minutes) * 60 * std.time.ns_per_s };
            var ahead: storage.Client = try .init(testing.allocator, clock.io(), .{ .token_provider = f.token.provider() });
            defer ahead.deinit();
            var url = try ahead.bucket(f.bucket_name).object(obj.name).signedUrl(s.signer, .{ .expires_in_s = 3600 });
            defer url.deinit();
            const got = try useUrl(a, .GET, url.value, &.{}, null);
            if (case.works) {
                try expectStatus(200, got, s.name);
            } else {
                // Measured 2026-09-22: too early is AccessDenied, not the
                // ExpiredToken that being too late gives.
                try expectStatus(403, got, s.name);
                try testing.expectEqualStrings("AccessDenied", got.code());
            }
        }
    }
}

test "signed URLs, real bucket: a signed payload hash is signed, but Cloud Storage does not check the body against it" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const a = f.arena.allocator();
    var buffer: [2]Named = undefined;
    for (f.signers(&buffer)) |s| {
        const body = "exactly these bytes";
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(body, &digest, .{});
        const hash: std.http.Header = .{ .name = "x-goog-content-sha256", .value = &std.fmt.bytesToHex(digest, .lower) };
        const obj = try f.object(s.name);
        const url = try f.sign(obj, s.signer, .{ .method = .PUT, .expires_in_s = 300, .headers = &.{hash} });
        try expectStatus(200, try useUrl(a, .PUT, url, &.{hash}, body), s.name);
        // The header is part of the signature, so it must be sent as signed:
        // a different value is a different canonical request.
        const changed: std.http.Header = .{ .name = "x-goog-content-sha256", .value = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" };
        const wrong_header = try useUrl(a, .PUT, url, &.{changed}, body);
        try expectStatus(403, wrong_header, s.name);
        try testing.expectEqualStrings("SignatureDoesNotMatch", wrong_header.code());
        // But measured 2026-09-22: Cloud Storage does not hash the body of a
        // signed URL request, so other bytes under the same signed hash are
        // stored. The docs only promise the check for a signature in an
        // Authorization header, and say a signed URL's payload "should be
        // UNSIGNED-PAYLOAD".
        try expectStatus(200, try useUrl(a, .PUT, url, &.{hash}, "other bytes, same hash"), s.name);
        var round = try obj.downloadAlloc(1024, .{});
        defer round.deinit();
        try testing.expectEqualStrings("other bytes, same hash", round.value.data);
    }
}

test "signed URLs, real bucket: IAM's signature verifies against the account's published certificates" {
    var f: Fixture = undefined;
    if (!try f.init()) return error.SkipZigTest;
    defer f.deinit();
    const iam = if (f.iam) |*i| i.signer() else return error.SkipZigTest;
    const a = f.arena.allocator();
    var recording: Recording = .{ .inner = iam };
    const obj = try f.object("iam-certificate");
    const url = try f.sign(obj, recording.signer(), .{ .expires_in_s = 300 });
    const marker = "&X-Goog-Signature=";
    const signature_hex = url[std.mem.lastIndexOf(u8, url, marker).? + marker.len ..];
    var signature: [256]u8 = undefined;
    try testing.expectEqual(256, (try std.fmt.hexToBytes(&signature, signature_hex)).len);

    // Google publishes every service account's public certificates.
    const account = try iam.email(testing.io, a);
    const certs = try useUrl(a, .GET, try std.fmt.allocPrint(a, "https://www.googleapis.com/service_accounts/v1/metadata/x509/{s}", .{account}), &.{}, null);
    try expectStatus(200, certs, "certificates");
    const parsed = try std.json.parseFromSliceLeaky(std.json.ArrayHashMap([]const u8), a, certs.body, .{});
    var verified = false;
    for (parsed.map.values()) |pem| {
        const begin = "-----BEGIN CERTIFICATE-----";
        const end = "-----END CERTIFICATE-----";
        const start = (std.mem.indexOf(u8, pem, begin) orelse continue) + begin.len;
        const stop = std.mem.indexOfPos(u8, pem, start, end) orelse continue;
        var body: std.ArrayList(u8) = .empty;
        for (pem[start..stop]) |c| if (!std.ascii.isWhitespace(c)) try body.append(a, c);
        const der = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(body.items));
        try std.base64.standard.Decoder.decode(der, body.items);
        const cert = try (std.crypto.Certificate{ .buffer = der, .index = 0 }).parse();
        const key = try std.crypto.Certificate.rsa.PublicKey.parseDer(cert.pubKey());
        const public_key = try std.crypto.Certificate.rsa.PublicKey.fromBytes(key.exponent, key.modulus);
        std.crypto.Certificate.rsa.PKCS1v1_5Signature.verify(256, signature, recording.message(), public_key, Sha256) catch continue;
        verified = true;
    }
    try testing.expect(verified);
}
