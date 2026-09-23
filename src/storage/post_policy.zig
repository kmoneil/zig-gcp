//! V4 POST policy documents: what a plain HTML form may upload, stated in
//! advance and signed. A signed URL allows one request; a policy allows one
//! kind of request, which is what a form needs, because a form cannot send
//! custom headers and the person at the browser picks the file.
//!
//! The signature is not a signed URL's. There is no canonical request and
//! no string to sign: the document is UTF-8, then base64, and that base64
//! text is signed directly, hex-encoded lowercase. Google publishes the
//! expected output for 11 policies, and tests/storage_signing.zig holds
//! this code to every byte of it.
//!
//! The rules those vectors pin:
//! - `conditions` comes before `expiration`, and the JSON is compact.
//!   Google's own example shows the other order; the vectors are what
//!   Google's library emits, which sorts the two keys.
//! - Every byte is ASCII: anything above it becomes `\uXXXX`, lowercase,
//!   as a surrogate pair above the basic plane.
//! - The expiry is RFC 3339 to the second, in UTC.
//! - The last conditions are always `bucket`, `key` when it is exact,
//!   `x-goog-date`, `x-goog-credential`, `x-goog-algorithm`, in that order.
//!   The caller's conditions come first, then its fields.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const core = @import("core");

const Client = @import("Client.zig");
const logging = @import("logging.zig");
const signing = @import("signing.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Error = @import("errors.zig").Error;

/// The longest a policy may work: seven days, as for a signed URL. Google's
/// library caps there through the same helper; no documentation states it.
pub const max_expires_s: u32 = signing.max_expires_s;

/// The largest object Cloud Storage stores, so the largest a
/// `content-length-range` can usefully name.
pub const max_object_size: u64 = 5 * (1 << 40);

/// Fields the policy sets itself. A caller's field may take none of these
/// names: the form would carry two, and the conditions could not both hold.
const reserved_fields = [_][]const u8{
    "bucket",
    "key",
    "policy",
    "x-goog-algorithm",
    "x-goog-credential",
    "x-goog-date",
    "x-goog-signature",
};

/// Fields that are never conditions, so a condition on one can never match:
/// Cloud Storage has nothing to compare it with.
const unconditionable_fields = [_][]const u8{ "file", "policy", "x-goog-signature" };

/// Cloud Storage ignores a field with this prefix, so it can never satisfy
/// a condition either. Google's library drops such a field silently;
/// this one refuses it, as it refuses the three above.
const ignored_prefix = "x-ignore-";

/// Signs a POST policy for `key` in `bucket`. The caller has begun the call
/// and checked the bucket name.
pub fn signPolicy(
    client: *Client,
    signer: core.Signer,
    bucket: []const u8,
    key: types.PostKey,
    options: types.PostPolicyOptions,
) Error!types.Owned(types.PostPolicy) {
    const diag = client.diagnostics;
    try check(diag, client.base_url, bucket, key, options, signer.lifetimeS());
    const now = std.Io.Clock.real.now(client.io);
    const signed_at = signing.timestamp(now) orelse {
        if (diag) |d| d.print("the clock reads a time a policy cannot carry: before 1970, or after 9999", .{});
        return error.InvalidPostPolicyOptions;
    };
    const expires_at = expiry(now, options.expires_in_s) orelse {
        if (diag) |d| d.print("the policy would expire after the year 9999", .{});
        return error.InvalidPostPolicyOptions;
    };

    // The signature and the document together are a credential until the
    // policy expires. The scratch memory that held them is wiped; only the
    // returned fields keep a copy.
    var wiping: core.WipingAllocator = .init(client.gpa);
    var scratch: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer scratch.deinit();
    const arena = scratch.allocator();

    const email = try signer.email(client.io, arena);
    if (email.len == 0) {
        if (diag) |d| d.print("the signer named no service account", .{});
        return error.SigningFailed;
    }
    const prepared = try prepare(arena, .{
        .bucket = bucket,
        .key = key,
        .email = email,
        .signed_at = &signed_at,
        .expires_at = &expires_at,
        .fields = options.fields,
        .conditions = options.conditions,
    });
    const signature = try signer.sign(client.io, arena, prepared.policy);
    if (signature.len == 0) {
        if (diag) |d| d.print("the signer returned an empty signature", .{});
        return error.SigningFailed;
    }

    var result: types.Owned(types.PostPolicy) = try .init(client.gpa);
    errdefer result.deinit();
    result.value = try finish(
        result.arena.allocator(),
        try url(result.arena.allocator(), client.base_url, bucket, options.style),
        prepared,
        options.fields,
        signature,
    );
    // Never the document or the signature: together they are what the
    // holder posts with.
    logging.debug("signed a POST policy for {s}/{s}, valid {d} s, {d} conditions", .{
        bucket, prepared.key_field, options.expires_in_s, prepared.condition_count,
    });
    return result;
}

/// Refuses what cannot be signed into a policy a form can satisfy, and says
/// why in `diag`. Field values never reach it: they can be secrets.
pub fn check(
    diag: ?*core.Diagnostics,
    base_url: []const u8,
    bucket: []const u8,
    key: types.PostKey,
    options: types.PostPolicyOptions,
    lifetime_s: ?u32,
) error{InvalidPostPolicyOptions}!void {
    if (options.expires_in_s == 0 or options.expires_in_s > max_expires_s) {
        if (diag) |d| d.print("invalid expiry: a POST policy works for 1 to {d} seconds, not {d}", .{ max_expires_s, options.expires_in_s });
        return error.InvalidPostPolicyOptions;
    }
    if (lifetime_s) |limit| if (options.expires_in_s > limit) {
        if (diag) |d| d.print(
            "invalid expiry: this signer's signatures are sure to verify for {d} seconds, not {d}; IAM rotates the keys it signs with, and only a key file lasts longer",
            .{ limit, options.expires_in_s },
        );
        return error.InvalidPostPolicyOptions;
    };
    switch (key) {
        .exact => |name| {
            if (!validate.isObjectName(name)) {
                if (diag) |d| d.print("the key is not an object name: 1 to {d} bytes of UTF-8, no carriage return or line feed", .{validate.max_object_name_len});
                return error.InvalidPostPolicyOptions;
            }
            // Stricter than an object name, which may hold any control
            // character but CR and LF: this one travels in a form's hidden
            // input, which cannot carry one.
            if (!isPolicyText(name)) {
                if (diag) |d| d.print("the key holds a control character, which a form cannot send in a hidden input", .{});
                return error.InvalidPostPolicyOptions;
            }
            if (signing.hasDotSegment(name)) {
                if (diag) |d| d.print("the key has a \".\" or \"..\" segment, which browsers remove from a path before sending it", .{});
                return error.InvalidPostPolicyOptions;
            }
        },
        .starts_with => |prefix| {
            if (prefix.len > validate.max_object_name_len) {
                if (diag) |d| d.print("the key prefix is longer than an object name: {d} bytes, not {d}", .{ prefix.len, validate.max_object_name_len });
                return error.InvalidPostPolicyOptions;
            }
            if (!isPolicyText(prefix)) {
                if (diag) |d| d.print("the key prefix is not UTF-8 without control characters", .{});
                return error.InvalidPostPolicyOptions;
            }
        },
    }
    for (options.fields, 0..) |field, i| {
        if (field.name.len == 0) {
            if (diag) |d| d.print("field {d} has no name", .{i});
            return error.InvalidPostPolicyOptions;
        }
        if (!isPolicyText(field.name) or !isPolicyText(field.value)) {
            if (diag) |d| d.print("field {d}: a name and a value are UTF-8 without control characters, which a form cannot send in a hidden input", .{i});
            return error.InvalidPostPolicyOptions;
        }
        for (reserved_fields) |reserved| if (std.ascii.eqlIgnoreCase(field.name, reserved)) {
            if (diag) |d| d.print("field {d} is named {s}, which the policy sets itself", .{ i, reserved });
            return error.InvalidPostPolicyOptions;
        };
        for (unconditionable_fields) |never| if (std.ascii.eqlIgnoreCase(field.name, never)) {
            if (diag) |d| d.print("field {d} is named {s}, which is never a condition, so no policy can allow it", .{ i, never });
            return error.InvalidPostPolicyOptions;
        };
        if (isIgnored(field.name)) {
            if (diag) |d| d.print("field {d} starts with {s}, which Cloud Storage ignores, so no policy can allow it", .{ i, ignored_prefix });
            return error.InvalidPostPolicyOptions;
        }
        for (options.fields[0..i]) |earlier| if (std.ascii.eqlIgnoreCase(earlier.name, field.name)) {
            if (diag) |d| d.print("field {s} appears twice; a form field has one value", .{field.name});
            return error.InvalidPostPolicyOptions;
        };
        if (std.ascii.eqlIgnoreCase(field.name, "success_action_status") and !isSuccessStatus(field.value)) {
            if (diag) |d| d.print("success_action_status is 200, 201 or 204", .{});
            return error.InvalidPostPolicyOptions;
        }
    }
    var ranges: usize = 0;
    for (options.conditions, 0..) |condition, i| switch (condition) {
        .starts_with => |s| {
            if (s.field.len == 0) {
                if (diag) |d| d.print("condition {d} has no field name", .{i});
                return error.InvalidPostPolicyOptions;
            }
            if (!isPolicyText(s.field) or !isPolicyText(s.prefix)) {
                if (diag) |d| d.print("condition {d}: a field name and a prefix are UTF-8 without control characters", .{i});
                return error.InvalidPostPolicyOptions;
            }
            for (unconditionable_fields) |never| if (std.ascii.eqlIgnoreCase(s.field, never)) {
                if (diag) |d| d.print("condition {d} is on {s}, which Cloud Storage never compares, so no policy can allow it", .{ i, never });
                return error.InvalidPostPolicyOptions;
            };
            if (isIgnored(s.field)) {
                if (diag) |d| d.print("condition {d} is on a field Cloud Storage ignores, so no policy can allow it", .{i});
                return error.InvalidPostPolicyOptions;
            }
        },
        .content_length_range => |r| {
            ranges += 1;
            if (ranges > 1) {
                if (diag) |d| d.print("condition {d} is a second content-length-range; one policy states one size range", .{i});
                return error.InvalidPostPolicyOptions;
            }
            if (r.min > r.max) {
                if (diag) |d| d.print("content-length-range: the smallest size is above the largest", .{});
                return error.InvalidPostPolicyOptions;
            }
            if (r.max > max_object_size) {
                if (diag) |d| d.print("content-length-range: the largest object Cloud Storage stores is {d} bytes", .{max_object_size});
                return error.InvalidPostPolicyOptions;
            }
        },
    };
    signing.checkStyle(diag, base_url, bucket, options.style) catch return error.InvalidPostPolicyOptions;
}

/// What a policy says, before it is signed.
pub const Request = struct {
    bucket: []const u8,
    key: types.PostKey,
    email: []const u8,
    /// `YYYYMMDDTHHMMSSZ`, in UTC.
    signed_at: []const u8,
    /// `YYYY-MM-DDTHH:MM:SSZ`, in UTC.
    expires_at: []const u8,
    fields: []const types.PostField,
    conditions: []const types.PostCondition,
};

pub const Prepared = struct {
    /// The document itself, which nothing sends: it is base64 first.
    document: []const u8,
    /// The base64 document: the bytes that are signed, and the form's
    /// `policy` field.
    policy: []const u8,
    /// The form's `key` field. A prefix key completes it with Google's
    /// `${filename}`, which Cloud Storage replaces with the name of the
    /// file the browser sent.
    key_field: []const u8,
    /// `{email}/{yyyymmdd}/auto/storage/goog4_request`.
    credential: []const u8,
    /// `YYYYMMDDTHHMMSSZ`, as the form's `x-goog-date` field carries it.
    signed_at: []const u8,
    condition_count: usize,
};

pub fn prepare(arena: Allocator, request: Request) Allocator.Error!Prepared {
    return prepareInner(arena, request) catch return error.OutOfMemory;
}

fn prepareInner(arena: Allocator, request: Request) (Allocator.Error || Writer.Error)!Prepared {
    const credential = try std.mem.concat(arena, u8, &.{
        request.email, "/", request.signed_at[0..8], "/auto/storage/goog4_request",
    });
    const key_field = switch (request.key) {
        .exact => |name| name,
        .starts_with => |prefix| try std.mem.concat(arena, u8, &.{ prefix, "${filename}" }),
    };

    var out: Writer.Allocating = .init(arena);
    // Every byte ASCII, as Google's library writes it. Validation has
    // already refused a control character, which this would escape and
    // Google's library would not, and invalid UTF-8, which would panic.
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .escape_unicode = true } };
    var count: usize = 0;
    try jw.beginObject();
    try jw.objectField("conditions");
    try jw.beginArray();
    switch (request.key) {
        .exact => {},
        .starts_with => |prefix| {
            try writeStartsWith(arena, &jw, "key", prefix);
            count += 1;
        },
    }
    for (request.conditions) |condition| {
        switch (condition) {
            .starts_with => |s| try writeStartsWith(arena, &jw, s.field, s.prefix),
            .content_length_range => |r| {
                try jw.beginArray();
                try jw.write("content-length-range");
                try jw.write(r.min);
                try jw.write(r.max);
                try jw.endArray();
            },
        }
        count += 1;
    }
    for (request.fields) |field| {
        try writeMatch(&jw, field.name, field.value);
        count += 1;
    }
    try writeMatch(&jw, "bucket", request.bucket);
    count += 1;
    switch (request.key) {
        .exact => |name| {
            try writeMatch(&jw, "key", name);
            count += 1;
        },
        .starts_with => {},
    }
    try writeMatch(&jw, "x-goog-date", request.signed_at);
    try writeMatch(&jw, "x-goog-credential", credential);
    try writeMatch(&jw, "x-goog-algorithm", signing.algorithm);
    count += 3;
    try jw.endArray();
    try jw.objectField("expiration");
    try jw.write(request.expires_at);
    try jw.endObject();
    const document = out.written();

    const encoder = std.base64.standard.Encoder;
    const policy = try arena.alloc(u8, encoder.calcSize(document.len));
    return .{
        .document = document,
        .policy = encoder.encode(policy, document),
        .key_field = key_field,
        .credential = credential,
        .signed_at = request.signed_at,
        .condition_count = count,
    };
}

/// `{"name":"value"}`, an exact-match condition.
fn writeMatch(jw: *std.json.Stringify, name: []const u8, value: []const u8) Writer.Error!void {
    try jw.beginObject();
    try jw.objectField(name);
    try jw.write(value);
    try jw.endObject();
}

/// `["starts-with","$name",prefix]`.
fn writeStartsWith(
    arena: Allocator,
    jw: *std.json.Stringify,
    name: []const u8,
    prefix: []const u8,
) (Allocator.Error || Writer.Error)!void {
    try jw.beginArray();
    try jw.write("starts-with");
    try jw.write(try std.mem.concat(arena, u8, &.{ "$", name }));
    try jw.write(prefix);
    try jw.endArray();
}

/// The finished policy: where the form posts, and every field it carries
/// but `file`, which holds the bytes and is the caller's to add, last.
pub fn finish(
    arena: Allocator,
    post_url: []const u8,
    prepared: Prepared,
    fields: []const types.PostField,
    signature: []const u8,
) Allocator.Error!types.PostPolicy {
    const out = try arena.alloc(types.PostField, fields.len + 6);
    out[0] = .{ .name = "key", .value = try arena.dupe(u8, prepared.key_field) };
    for (fields, out[1 .. 1 + fields.len]) |field, *slot| slot.* = .{
        .name = try arena.dupe(u8, field.name),
        .value = try arena.dupe(u8, field.value),
    };
    var hex: Writer.Allocating = .init(arena);
    hex.writer.printHex(signature, .lower) catch return error.OutOfMemory;
    const tail = out[1 + fields.len ..];
    tail[0] = .{ .name = "x-goog-algorithm", .value = signing.algorithm };
    tail[1] = .{ .name = "x-goog-credential", .value = try arena.dupe(u8, prepared.credential) };
    tail[2] = .{ .name = "x-goog-date", .value = try arena.dupe(u8, prepared.signed_at) };
    tail[3] = .{ .name = "policy", .value = try arena.dupe(u8, prepared.policy) };
    tail[4] = .{ .name = "x-goog-signature", .value = hex.written() };
    return .{ .url = post_url, .fields = out };
}

/// Where the form posts: the bucket's URL, which always ends in `/`.
pub fn url(
    arena: Allocator,
    base_url: []const u8,
    bucket: []const u8,
    style: types.UrlStyle,
) Allocator.Error![]const u8 {
    const t = try signing.target(arena, base_url, bucket, null, style);
    return std.mem.concat(arena, u8, &.{
        t.scheme, "://", t.authority, t.path, if (style == .path) "/" else "",
    });
}

/// `YYYY-MM-DDTHH:MM:SSZ` for `now` plus `seconds`, or null past 9999.
pub fn expiry(now: std.Io.Timestamp, seconds: u32) ?[20]u8 {
    const at: std.Io.Timestamp = .{
        .nanoseconds = now.nanoseconds + @as(i96, seconds) * std.time.ns_per_s,
    };
    const c = signing.civil(at) orelse return null;
    var out: [20]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        c.year, c.month, c.day, c.hour, c.minute, c.second,
    }) catch unreachable;
    return out;
}

/// What a form can carry in a hidden input and Cloud Storage can compare
/// byte for byte: UTF-8 without control characters. `0x7F` is refused with
/// them, which also keeps the document's escaping the same as Google's
/// library's, since std escapes it and Python does not.
fn isPolicyText(text: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |c| if (c < ' ' or c == 0x7f) return false;
    return true;
}

/// Whether Cloud Storage ignores a field of this name.
fn isIgnored(name: []const u8) bool {
    return name.len >= ignored_prefix.len and
        std.ascii.eqlIgnoreCase(name[0..ignored_prefix.len], ignored_prefix);
}

fn isSuccessStatus(value: []const u8) bool {
    for ([_][]const u8{ "200", "201", "204" }) |ok| {
        if (std.mem.eql(u8, value, ok)) return true;
    }
    return false;
}

const testing = std.testing;
const test_util = @import("test_util.zig");
const Object = @import("Object.zig");

const fixed_time_ns: i96 = 1_758_556_800 * std.time.ns_per_s; // 2025-09-22T16:00:00Z
const signed_at_text = "20250922T160000Z";
const credential_text = "signer@test-project.iam.gserviceaccount.com/20250922/auto/storage/goog4_request";

/// A client on a fake transport, a fake clock at `fixed_time_ns` and a
/// signer that answers "deadbeef" to everything.
const Harness = struct {
    fake: test_util.FakeTransport,
    clock: test_util.FakeClock,
    diag: core.Diagnostics,
    token: test_util.FakeTokenProvider,
    signer: core.testing.FakeSigner,
    client: Client,

    fn init(h: *Harness, gpa: Allocator, endpoint: ?@import("Endpoint.zig")) !void {
        h.* = .{
            .fake = .init(gpa, &.{}),
            .clock = .{ .now_ns = fixed_time_ns },
            .diag = .{},
            .token = .{},
            .signer = .{ .signature = "\xde\xad\xbe\xef" },
            .client = undefined,
        };
        errdefer h.fake.deinit();
        h.client = try .init(gpa, h.clock.io(), .{
            .endpoint = endpoint,
            .token_provider = h.token.provider(),
            .diagnostics = &h.diag,
            .transport = h.fake.transport(),
        });
    }

    fn deinit(h: *Harness) void {
        h.client.deinit();
        h.fake.deinit();
    }

    fn sign(h: *Harness, bucket: []const u8, options: types.PostPolicyOptions) Error!types.Owned(types.PostPolicy) {
        return h.client.bucket(bucket).postPolicy(h.signer.signer(), options);
    }
};

/// A document written out from the rules in the module comment, by hand,
/// beside the options that must produce it. The conformance vectors cover
/// an exact key; these cover what they do not: a prefix key, both kinds of
/// condition together, escaping, and a style on another endpoint.
const Golden = struct {
    label: []const u8,
    endpoint: ?[]const u8 = null,
    bucket: []const u8 = "photos",
    options: types.PostPolicyOptions,
    url: []const u8,
    key_field: []const u8,
    document: []const u8,
};

const goldens = [_]Golden{
    .{
        .label = "a prefix key, which the browser completes",
        .options = .{ .expires_in_s = 600, .key = .{ .starts_with = "avatars/" } },
        .url = "https://storage.googleapis.com/photos/",
        .key_field = "avatars/${filename}",
        .document = "{\"conditions\":[" ++
            "[\"starts-with\",\"$key\",\"avatars/\"]," ++
            "{\"bucket\":\"photos\"}," ++
            "{\"x-goog-date\":\"" ++ signed_at_text ++ "\"}," ++
            "{\"x-goog-credential\":\"" ++ credential_text ++ "\"}," ++
            "{\"x-goog-algorithm\":\"GOOG4-RSA-SHA256\"}" ++
            "],\"expiration\":\"2025-09-22T16:10:00Z\"}",
    },
    .{
        .label = "an exact key, a field, and both kinds of condition",
        .options = .{
            .expires_in_s = 60,
            .key = .{ .exact = "uploads/report.pdf" },
            .fields = &.{.{ .name = "content-type", .value = "application/pdf" }},
            .conditions = &.{
                .{ .starts_with = .{ .field = "acl", .prefix = "public" } },
                .{ .content_length_range = .{ .min = 1, .max = 1 << 20 } },
            },
        },
        .url = "https://storage.googleapis.com/photos/",
        .key_field = "uploads/report.pdf",
        .document = "{\"conditions\":[" ++
            "[\"starts-with\",\"$acl\",\"public\"]," ++
            "[\"content-length-range\",1,1048576]," ++
            "{\"content-type\":\"application/pdf\"}," ++
            "{\"bucket\":\"photos\"}," ++
            "{\"key\":\"uploads/report.pdf\"}," ++
            "{\"x-goog-date\":\"" ++ signed_at_text ++ "\"}," ++
            "{\"x-goog-credential\":\"" ++ credential_text ++ "\"}," ++
            "{\"x-goog-algorithm\":\"GOOG4-RSA-SHA256\"}" ++
            "],\"expiration\":\"2025-09-22T16:01:00Z\"}",
    },
    .{
        .label = "a quote, a backslash and UTF-8 in a value",
        .options = .{
            .expires_in_s = 600,
            .key = .{ .exact = "caf\xc3\xa9.txt" },
            .fields = &.{.{ .name = "x-goog-meta-note", .value = "a \"b\" \\ caf\xc3\xa9 \xf0\x9f\x98\x80" }},
        },
        .url = "https://storage.googleapis.com/photos/",
        .key_field = "caf\xc3\xa9.txt",
        .document = "{\"conditions\":[" ++
            "{\"x-goog-meta-note\":\"a \\\"b\\\" \\\\ caf\\u00e9 \\ud83d\\ude00\"}," ++
            "{\"bucket\":\"photos\"}," ++
            "{\"key\":\"caf\\u00e9.txt\"}," ++
            "{\"x-goog-date\":\"" ++ signed_at_text ++ "\"}," ++
            "{\"x-goog-credential\":\"" ++ credential_text ++ "\"}," ++
            "{\"x-goog-algorithm\":\"GOOG4-RSA-SHA256\"}" ++
            "],\"expiration\":\"2025-09-22T16:10:00Z\"}",
    },
    .{
        .label = "virtual-hosted style on an emulator, and any name in the bucket",
        .endpoint = "http://gcs.test:4443",
        .bucket = "uploads",
        .options = .{
            .expires_in_s = 3600,
            .key = .{ .starts_with = "" },
            .style = .virtual_hosted,
        },
        .url = "http://uploads.gcs.test:4443/",
        .key_field = "${filename}",
        .document = "{\"conditions\":[" ++
            "[\"starts-with\",\"$key\",\"\"]," ++
            "{\"bucket\":\"uploads\"}," ++
            "{\"x-goog-date\":\"" ++ signed_at_text ++ "\"}," ++
            "{\"x-goog-credential\":\"" ++ credential_text ++ "\"}," ++
            "{\"x-goog-algorithm\":\"GOOG4-RSA-SHA256\"}" ++
            "],\"expiration\":\"2025-09-22T17:00:00Z\"}",
    },
    .{
        .label = "a bucket-bound host over http",
        .options = .{
            .expires_in_s = 600,
            .key = .{ .exact = "o" },
            .style = .{ .bucket_bound = .{ .host = "media.example.com", .scheme = .http } },
        },
        .url = "http://media.example.com/",
        .key_field = "o",
        .document = "{\"conditions\":[" ++
            "{\"bucket\":\"photos\"}," ++
            "{\"key\":\"o\"}," ++
            "{\"x-goog-date\":\"" ++ signed_at_text ++ "\"}," ++
            "{\"x-goog-credential\":\"" ++ credential_text ++ "\"}," ++
            "{\"x-goog-algorithm\":\"GOOG4-RSA-SHA256\"}" ++
            "],\"expiration\":\"2025-09-22T16:10:00Z\"}",
    },
};

fn decodeBase64(arena: Allocator, text: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const out = try arena.alloc(u8, try decoder.calcSizeForSlice(text));
    try decoder.decode(out, text);
    return out;
}

test "golden: documents written from the rules, by hand" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (goldens) |golden| {
        errdefer std.debug.print("golden: {s}\n", .{golden.label});
        var h: Harness = undefined;
        try h.init(testing.allocator, if (golden.endpoint) |e| .{ .url = e, .emulator = true } else null);
        defer h.deinit();
        var policy = try h.sign(golden.bucket, golden.options);
        defer policy.deinit();

        try testing.expectEqualStrings(golden.url, policy.value.url);
        try testing.expectEqualStrings(golden.key_field, policy.value.field("key").?);
        try testing.expectEqualStrings(golden.document, try decodeBase64(arena, policy.value.field("policy").?));
        // The document itself is what was signed, base64 and all.
        try testing.expectEqualStrings(policy.value.field("policy").?, h.signer.lastMessage());
        try testing.expectEqualStrings("deadbeef", policy.value.field("x-goog-signature").?);
        try testing.expectEqualStrings(signing.algorithm, policy.value.field("x-goog-algorithm").?);
        try testing.expectEqualStrings(credential_text, policy.value.field("x-goog-credential").?);
        try testing.expectEqualStrings(signed_at_text, policy.value.field("x-goog-date").?);
        // Nothing reaches Cloud Storage.
        try testing.expectEqual(0, h.fake.requests.items.len);
    }
}

test "the fields are the form's, in the order a form would write them" {
    var h: Harness = undefined;
    try h.init(testing.allocator, null);
    defer h.deinit();
    var policy = try h.sign("photos", .{
        .expires_in_s = 600,
        .key = .{ .exact = "o" },
        .fields = &.{
            .{ .name = "content-type", .value = "image/png" },
            .{ .name = "success_action_status", .value = "201" },
        },
    });
    defer policy.deinit();
    const want = [_][]const u8{
        "key",              "content-type",      "success_action_status",
        "x-goog-algorithm", "x-goog-credential", "x-goog-date",
        "policy",           "x-goog-signature",
    };
    try testing.expectEqual(want.len, policy.value.fields.len);
    for (want, policy.value.fields) |name, field| try testing.expectEqualStrings(name, field.name);
    // `file` is the caller's to add, last: this library never sees the bytes.
    try testing.expectEqual(null, policy.value.field("file"));
}

test "expiry: RFC 3339 to the second, and the years a policy can carry" {
    try testing.expectEqualStrings("2025-09-22T16:10:00Z", &(expiry(.{ .nanoseconds = fixed_time_ns }, 600).?));
    // Sub-second time is truncated, where Google's library would print it.
    try testing.expectEqualStrings(
        "2025-09-22T16:00:01Z",
        &(expiry(.{ .nanoseconds = fixed_time_ns + 999_999_999 }, 1).?),
    );
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", &(expiry(.{ .nanoseconds = 0 }, 0).?));
    try testing.expectEqual(null, expiry(.{ .nanoseconds = -1 }, 0));
    // The year 9999 is the last one four digits can spell.
    const in_9999: i96 = 253_370_764_800 * std.time.ns_per_s; // 9999-01-01T00:00:00Z
    try testing.expectEqualStrings("9999-01-01T00:00:00Z", &(expiry(.{ .nanoseconds = in_9999 }, 0).?));
    try testing.expectEqual(null, expiry(.{ .nanoseconds = in_9999 }, 366 * 24 * 3600));
}

test "check: expiry from 1 second to 7 days, and no longer than the signer's keys last" {
    var h: Harness = undefined;
    try h.init(testing.allocator, null);
    defer h.deinit();
    const key: types.PostKey = .{ .exact = "o" };
    try testing.expectError(error.InvalidPostPolicyOptions, h.sign("photos", .{ .expires_in_s = 0, .key = key }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "1 to 604800") != null);
    try testing.expectError(error.InvalidPostPolicyOptions, h.sign("photos", .{ .expires_in_s = max_expires_s + 1, .key = key }));
    var ok = try h.sign("photos", .{ .expires_in_s = max_expires_s, .key = key });
    ok.deinit();
    // Through IAM, Google promises its keys for 12 hours and no longer.
    h.signer.lifetime_s = 43_200;
    try testing.expectError(error.InvalidPostPolicyOptions, h.sign("photos", .{ .expires_in_s = 43_201, .key = key }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "43200 seconds") != null);
    var still = try h.sign("photos", .{ .expires_in_s = 43_200, .key = key });
    still.deinit();
    try testing.expectEqual(0, h.fake.requests.items.len);
}

test "check: fields the policy sets itself, and fields that are never conditions" {
    var h: Harness = undefined;
    try h.init(testing.allocator, null);
    defer h.deinit();
    for ([_][]const u8{ "bucket", "key", "policy", "x-goog-algorithm", "X-Goog-Credential", "x-goog-date", "x-goog-signature" }) |name| {
        errdefer std.debug.print("field: {s}\n", .{name});
        try testing.expectError(error.InvalidPostPolicyOptions, h.sign("photos", .{
            .expires_in_s = 600,
            .key = .{ .exact = "o" },
            .fields = &.{.{ .name = name, .value = "v" }},
        }));
    }
    try testing.expectError(error.InvalidPostPolicyOptions, h.sign("photos", .{
        .expires_in_s = 600,
        .key = .{ .exact = "o" },
        .fields = &.{.{ .name = "file", .value = "v" }},
    }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "never a condition") != null);
    // Cloud Storage ignores an x-ignore- field, so it can never satisfy a
    // condition either. Google's library drops one without a word.
    try testing.expectError(error.InvalidPostPolicyOptions, h.sign("photos", .{
        .expires_in_s = 600,
        .key = .{ .exact = "o" },
        .fields = &.{.{ .name = "X-Ignore-Me", .value = "v" }},
    }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "Cloud Storage ignores") != null);
    // And a condition on one of those three can never match either.
    try testing.expectError(error.InvalidPostPolicyOptions, h.sign("photos", .{
        .expires_in_s = 600,
        .key = .{ .exact = "o" },
        .conditions = &.{.{ .starts_with = .{ .field = "file", .prefix = "" } }},
    }));
    try testing.expectEqual(0, h.signer.calls);
}

test "check: a repeated field, an empty name, and what a form cannot send" {
    var h: Harness = undefined;
    try h.init(testing.allocator, null);
    defer h.deinit();
    const key: types.PostKey = .{ .exact = "o" };
    try testing.expectError(error.InvalidPostPolicyOptions, h.sign("photos", .{
        .expires_in_s = 600,
        .key = key,
        .fields = &.{ .{ .name = "acl", .value = "a" }, .{ .name = "ACL", .value = "b" } },
    }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "twice") != null);
    try testing.expectError(error.InvalidPostPolicyOptions, h.sign("photos", .{
        .expires_in_s = 600,
        .key = key,
        .fields = &.{.{ .name = "", .value = "a" }},
    }));
    // A control character, a lone 0x7f, and invalid UTF-8.
    for ([_][]const u8{ "a\nb", "a\x00b", "a\x7fb", "a\xffb" }) |bad| {
        errdefer std.debug.print("value: {s}\n", .{bad});
        try testing.expectError(error.InvalidPostPolicyOptions, h.sign("photos", .{
            .expires_in_s = 600,
            .key = key,
            .fields = &.{.{ .name = "x-goog-meta-a", .value = bad }},
        }));
        try testing.expectError(error.InvalidPostPolicyOptions, h.sign("photos", .{
            .expires_in_s = 600,
            .key = key,
            .conditions = &.{.{ .starts_with = .{ .field = "acl", .prefix = bad } }},
        }));
    }
    // The value never reaches Diagnostics: it can be a secret.
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "\xff") == null);
    try testing.expectEqual(0, h.signer.calls);
}

test "check: success_action_status is one of the three Cloud Storage documents" {
    var h: Harness = undefined;
    try h.init(testing.allocator, null);
    defer h.deinit();
    for ([_][]const u8{ "200", "201", "204" }) |good| {
        var policy = try h.sign("photos", .{
            .expires_in_s = 600,
            .key = .{ .exact = "o" },
            .fields = &.{.{ .name = "success_action_status", .value = good }},
        });
        policy.deinit();
    }
    for ([_][]const u8{ "202", "301", "2001", "", "20" }) |bad| {
        errdefer std.debug.print("status: {s}\n", .{bad});
        try testing.expectError(error.InvalidPostPolicyOptions, h.sign("photos", .{
            .expires_in_s = 600,
            .key = .{ .exact = "o" },
            .fields = &.{.{ .name = "success_action_status", .value = bad }},
        }));
    }
}

test "check: one content-length-range, the right way round, within 5 TiB" {
    var h: Harness = undefined;
    try h.init(testing.allocator, null);
    defer h.deinit();
    const key: types.PostKey = .{ .exact = "o" };
    try testing.expectError(error.InvalidPostPolicyOptions, h.sign("photos", .{
        .expires_in_s = 600,
        .key = key,
        .conditions = &.{.{ .content_length_range = .{ .min = 2, .max = 1 } }},
    }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "above the largest") != null);
    try testing.expectError(error.InvalidPostPolicyOptions, h.sign("photos", .{
        .expires_in_s = 600,
        .key = key,
        .conditions = &.{.{ .content_length_range = .{ .min = 0, .max = max_object_size + 1 } }},
    }));
    try testing.expectError(error.InvalidPostPolicyOptions, h.sign("photos", .{
        .expires_in_s = 600,
        .key = key,
        .conditions = &.{
            .{ .content_length_range = .{ .min = 0, .max = 1 } },
            .{ .content_length_range = .{ .min = 0, .max = 2 } },
        },
    }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "second content-length-range") != null);
    var ok = try h.sign("photos", .{
        .expires_in_s = 600,
        .key = key,
        .conditions = &.{.{ .content_length_range = .{ .min = 0, .max = max_object_size } }},
    });
    ok.deinit();
}

test "check: keys a browser would rewrite, and prefixes that are not text" {
    var h: Harness = undefined;
    try h.init(testing.allocator, null);
    defer h.deinit();
    // A control character is refused here but allowed in an object name:
    // a form's hidden input cannot carry one. The model property found
    // this one, which escaped into the document before the rule existed.
    for ([_][]const u8{ "a/./b", "../b", "a/..", ".", "", "a\x1db", "a\x7fb", "a\x0bb", "a\xffb" }) |bad| {
        errdefer std.debug.print("key: {s}\n", .{bad});
        try testing.expectError(error.InvalidPostPolicyOptions, h.sign("photos", .{
            .expires_in_s = 600,
            .key = .{ .exact = bad },
        }));
    }
    try testing.expectError(error.InvalidPostPolicyOptions, h.sign("photos", .{
        .expires_in_s = 600,
        .key = .{ .starts_with = "a\nb" },
    }));
    // A prefix may be anything else, the empty one included.
    for ([_][]const u8{ "", "a/./b", "caf\xc3\xa9/" }) |good| {
        var policy = try h.sign("photos", .{ .expires_in_s = 600, .key = .{ .starts_with = good } });
        policy.deinit();
    }
}

test "postPolicy: the object names the key, and a bucket needs one" {
    var h: Harness = undefined;
    try h.init(testing.allocator, null);
    defer h.deinit();
    const object = h.client.bucket("photos").object("cats/tom.jpg");
    var policy = try object.postPolicy(h.signer.signer(), .{ .expires_in_s = 600 });
    defer policy.deinit();
    try testing.expectEqualStrings("cats/tom.jpg", policy.value.field("key").?);
    // Setting one there is a contradiction, not a silent override.
    try testing.expectError(error.InvalidPostPolicyOptions, object.postPolicy(h.signer.signer(), .{
        .expires_in_s = 600,
        .key = .{ .exact = "other" },
    }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "only Bucket.postPolicy") != null);
    // And a bucket's policy has no name to fall back on.
    try testing.expectError(error.InvalidPostPolicyOptions, h.client.bucket("photos").postPolicy(h.signer.signer(), .{ .expires_in_s = 600 }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "needs a key") != null);
}

test "postPolicy: names are checked like every other call" {
    var h: Harness = undefined;
    try h.init(testing.allocator, null);
    defer h.deinit();
    try testing.expectError(error.InvalidBucketName, h.client.bucket("has space").postPolicy(h.signer.signer(), .{
        .expires_in_s = 600,
        .key = .{ .exact = "o" },
    }));
    try testing.expectError(error.InvalidObjectName, h.client.bucket("photos").object("a\nb").postPolicy(h.signer.signer(), .{
        .expires_in_s = 600,
    }));
}

test "postPolicy: a signer's failure is the call's, and an empty answer is SigningFailed" {
    var h: Harness = undefined;
    try h.init(testing.allocator, null);
    defer h.deinit();
    const options: types.PostPolicyOptions = .{ .expires_in_s = 600, .key = .{ .exact = "o" } };
    h.signer.fail = error.SigningRejected;
    try testing.expectError(error.SigningRejected, h.sign("photos", options));
    h.signer.fail = null;
    h.signer.account = "";
    try testing.expectError(error.SigningFailed, h.sign("photos", options));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "no service account") != null);
    h.signer.account = "signer@test-project.iam.gserviceaccount.com";
    h.signer.signature = "";
    try testing.expectError(error.SigningFailed, h.sign("photos", options));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "empty signature") != null);
}

test "postPolicy: a clock before 1970 is refused" {
    var h: Harness = undefined;
    try h.init(testing.allocator, null);
    defer h.deinit();
    h.clock.now_ns = -std.time.ns_per_s;
    try testing.expectError(error.InvalidPostPolicyOptions, h.sign("photos", .{
        .expires_in_s = 600,
        .key = .{ .exact = "o" },
    }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "clock") != null);
    try testing.expectEqual(0, h.signer.calls);
}

test "postPolicy: the log names the bucket and key, never the document or the signature" {
    var h: Harness = undefined;
    try h.init(testing.allocator, null);
    defer h.deinit();
    logging.capture.reset();
    var policy = try h.sign("photos", .{
        .expires_in_s = 600,
        .key = .{ .starts_with = "avatars/" },
        .fields = &.{.{ .name = "content-type", .value = "image/png" }},
    });
    defer policy.deinit();
    try testing.expectEqualStrings(
        "debug: signed a POST policy for photos/avatars/${filename}, valid 600 s, 6 conditions\n",
        logging.capture.text(),
    );
    try testing.expect(std.mem.indexOf(u8, logging.capture.text(), "deadbeef") == null);
    try testing.expect(std.mem.indexOf(u8, logging.capture.text(), policy.value.field("policy").?) == null);
}

test "postPolicy: the scratch memory that held the signature is wiped" {
    var checker: core.testing.WipeChecker = .{ .child = testing.allocator };
    var h: Harness = undefined;
    try h.init(checker.allocator(), null);
    defer h.deinit();
    var policy = try h.sign("photos", .{ .expires_in_s = 600, .key = .{ .exact = "o" } });
    try testing.expectEqual(0, checker.unwiped);
    policy.deinit();
}

fn signEveryGolden(gpa: Allocator) !void {
    for (goldens) |golden| {
        var h: Harness = undefined;
        try h.init(gpa, if (golden.endpoint) |e| .{ .url = e, .emulator = true } else null);
        defer h.deinit();
        var policy = try h.sign(golden.bucket, golden.options);
        policy.deinit();
    }
}

test "postPolicy: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, signEveryGolden, .{});
}

// Properties. Each states a rule of the module comment independently of
// the code above, and holds it to arbitrary input.

const field_names = [_][]const u8{
    "acl",                "cache-control", "content-disposition", "content-encoding",
    "content-type",       "x-goog-meta-a", "x-goog-meta-note",    "success_action_redirect",
    "x-goog-custom-time", "x-ignore-me",
};

const Drawn = struct {
    bucket: []const u8,
    key: types.PostKey,
    options: types.PostPolicyOptions,
};

/// Options from the fuzzer's bytes: every field a caller can set, drawn
/// from what a caller could plausibly pass and from what would break the
/// document if it reached it unescaped.
fn drawOptions(arena: Allocator, g: *test_util.ByteGen) !Drawn {
    var buffer: [256]u8 = undefined;
    const key: types.PostKey = switch (g.intRange(u8, 0, 1)) {
        0 => .{ .exact = try arena.dupe(u8, g.utf8(&buffer, 64)) },
        else => .{ .starts_with = try arena.dupe(u8, g.utf8(&buffer, 64)) },
    };
    const field_count = g.intRange(usize, 0, 4);
    const fields = try arena.alloc(types.PostField, field_count);
    for (fields) |*field| field.* = .{
        .name = g.pick([]const u8, &field_names),
        .value = try arena.dupe(u8, g.utf8(&buffer, 48)),
    };
    const condition_count = g.intRange(usize, 0, 3);
    const conditions = try arena.alloc(types.PostCondition, condition_count);
    for (conditions) |*condition| condition.* = switch (g.intRange(u8, 0, 2)) {
        0 => .{ .content_length_range = .{ .min = g.int(u16), .max = g.int(u32) } },
        else => .{ .starts_with = .{
            .field = g.pick([]const u8, &field_names),
            .prefix = try arena.dupe(u8, g.utf8(&buffer, 32)),
        } },
    };
    return .{
        .bucket = g.pick([]const u8, &.{ "photos", "uploads", "a-bucket" }),
        .key = key,
        .options = .{
            .expires_in_s = g.intRange(u32, 1, max_expires_s),
            .key = key,
            .fields = fields,
            .conditions = conditions,
        },
    };
}

/// A `Request` for options that `check` has already accepted.
fn drawnRequest(d: Drawn) Request {
    return .{
        .bucket = d.bucket,
        .key = d.key,
        .email = "signer@test-project.iam.gserviceaccount.com",
        .signed_at = signed_at_text,
        .expires_at = "2025-09-22T16:10:00Z",
        .fields = d.options.fields,
        .conditions = d.options.conditions,
    };
}

fn documentProperty(_: void, bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(bytes);
    const d = try drawOptions(arena, &g);
    check(null, "https://storage.googleapis.com", d.bucket, d.key, d.options, null) catch return;
    const prepared = try prepare(arena, drawnRequest(d));

    // Every byte is ASCII, as Google's library writes it.
    for (prepared.document) |c| try testing.expect(c < 0x80);
    // The base64 is the document, and decodes back to it.
    try testing.expectEqualStrings(prepared.document, try decodeBase64(arena, prepared.policy));
    // It parses, and says what the options said, in the order the module
    // comment gives: the caller's conditions, its fields, then the rest.
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, prepared.document, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(2, root.count());
    try testing.expectEqualStrings("2025-09-22T16:10:00Z", root.get("expiration").?.string);
    const conditions = root.get("conditions").?.array.items;
    try testing.expectEqual(prepared.condition_count, conditions.len);
    var at: usize = 0;
    switch (d.key) {
        .exact => {},
        .starts_with => |prefix| {
            try expectStartsWith(conditions[at], "$key", prefix);
            at += 1;
        },
    }
    for (d.options.conditions) |condition| {
        switch (condition) {
            .starts_with => |s| {
                const name = try std.mem.concat(arena, u8, &.{ "$", s.field });
                try expectStartsWith(conditions[at], name, s.prefix);
            },
            .content_length_range => |r| {
                const items = conditions[at].array.items;
                try testing.expectEqual(3, items.len);
                try testing.expectEqualStrings("content-length-range", items[0].string);
                try testing.expectEqual(r.min, @as(u64, @intCast(items[1].integer)));
                try testing.expectEqual(r.max, @as(u64, @intCast(items[2].integer)));
            },
        }
        at += 1;
    }
    for (d.options.fields) |field| {
        try expectMatch(conditions[at], field.name, field.value);
        at += 1;
    }
    try expectMatch(conditions[at], "bucket", d.bucket);
    at += 1;
    switch (d.key) {
        .exact => |name| {
            try expectMatch(conditions[at], "key", name);
            at += 1;
        },
        .starts_with => {},
    }
    try expectMatch(conditions[at], "x-goog-date", signed_at_text);
    try expectMatch(conditions[at + 1], "x-goog-credential", prepared.credential);
    try expectMatch(conditions[at + 2], "x-goog-algorithm", algorithmOf());
    try testing.expectEqual(conditions.len, at + 3);
}

fn algorithmOf() []const u8 {
    return signing.algorithm;
}

fn expectMatch(value: std.json.Value, name: []const u8, want: []const u8) !void {
    const object = value.object;
    try testing.expectEqual(1, object.count());
    const got = object.get(name) orelse return error.TestConditionMissing;
    try testing.expectEqualStrings(want, got.string);
}

fn expectStartsWith(value: std.json.Value, name: []const u8, prefix: []const u8) !void {
    const items = value.array.items;
    try testing.expectEqual(3, items.len);
    try testing.expectEqualStrings("starts-with", items[0].string);
    try testing.expectEqualStrings(name, items[1].string);
    try testing.expectEqualStrings(prefix, items[2].string);
}

test "fuzz post policy: the document is ASCII, and decodes back to the options" {
    try test_util.fuzzBytes({}, documentProperty, .{ .corpus = &.{
        "",
        "\x00",
        "\x01\x00\x00\x00\x00",
        "\x01\x20caf\xc3\xa9/\x02\x02",
    } });
}

/// The document written a second time, from the module comment's rules,
/// with none of the code above: a plain writer and its own escaping.
fn modelDocument(arena: Allocator, request: Request) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const w = &out;
    try w.appendSlice(arena, "{\"conditions\":[");
    var first = true;
    switch (request.key) {
        .exact => {},
        .starts_with => |prefix| {
            first = false;
            try modelStartsWith(arena, w, "key", prefix);
        },
    }
    for (request.conditions) |condition| {
        if (!first) try w.append(arena, ',');
        first = false;
        switch (condition) {
            .starts_with => |s| try modelStartsWith(arena, w, s.field, s.prefix),
            .content_length_range => |r| try w.print(arena, "[\"content-length-range\",{d},{d}]", .{ r.min, r.max }),
        }
    }
    for (request.fields) |field| {
        if (!first) try w.append(arena, ',');
        first = false;
        try modelMatch(arena, w, field.name, field.value);
    }
    const credential = try std.mem.concat(arena, u8, &.{
        request.email, "/", request.signed_at[0..8], "/auto/storage/goog4_request",
    });
    if (!first) try w.append(arena, ',');
    try modelMatch(arena, w, "bucket", request.bucket);
    switch (request.key) {
        .exact => |name| {
            try w.append(arena, ',');
            try modelMatch(arena, w, "key", name);
        },
        .starts_with => {},
    }
    try w.append(arena, ',');
    try modelMatch(arena, w, "x-goog-date", request.signed_at);
    try w.append(arena, ',');
    try modelMatch(arena, w, "x-goog-credential", credential);
    try w.append(arena, ',');
    try modelMatch(arena, w, "x-goog-algorithm", signing.algorithm);
    try w.appendSlice(arena, "],\"expiration\":");
    try modelString(arena, w, request.expires_at);
    try w.append(arena, '}');
    return out.items;
}

fn modelMatch(arena: Allocator, w: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    try w.append(arena, '{');
    try modelString(arena, w, name);
    try w.append(arena, ':');
    try modelString(arena, w, value);
    try w.append(arena, '}');
}

fn modelStartsWith(arena: Allocator, w: *std.ArrayList(u8), name: []const u8, prefix: []const u8) !void {
    try w.appendSlice(arena, "[\"starts-with\",");
    try modelString(arena, w, try std.mem.concat(arena, u8, &.{ "$", name }));
    try w.append(arena, ',');
    try modelString(arena, w, prefix);
    try w.append(arena, ']');
}

/// A JSON string with every byte above ASCII escaped, as `\uXXXX` and as a
/// surrogate pair above the basic plane. Validation has already refused a
/// control character and invalid UTF-8, so neither appears here.
fn modelString(arena: Allocator, w: *std.ArrayList(u8), text: []const u8) !void {
    try w.append(arena, '"');
    var view = try std.unicode.Utf8View.init(text);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == '"' or cp == '\\') {
            try w.append(arena, '\\');
            try w.append(arena, @intCast(cp));
        } else if (cp < 0x80) {
            try w.append(arena, @intCast(cp));
        } else if (cp <= 0xffff) {
            try w.print(arena, "\\u{x:0>4}", .{cp});
        } else {
            const rest = cp - 0x10000;
            try w.print(arena, "\\u{x:0>4}\\u{x:0>4}", .{ 0xd800 + (rest >> 10), 0xdc00 + (rest & 0x3ff) });
        }
    }
    try w.append(arena, '"');
}

fn modelProperty(_: void, bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(bytes);
    const d = try drawOptions(arena, &g);
    check(null, "https://storage.googleapis.com", d.bucket, d.key, d.options, null) catch return;
    const request = drawnRequest(d);
    const prepared = try prepare(arena, request);
    try testing.expectEqualStrings(try modelDocument(arena, request), prepared.document);
}

test "slow property post policy: the document matches a model written from the rules" {
    try test_util.fuzzBytes({}, modelProperty, .{ .random_runs = 300, .max_len = 1024 });
}

/// Section 5's rules, stated again. Only path style: the style rules are
/// signing.zig's, and its own properties hold them.
fn allowedByRules(d: Drawn) bool {
    const o = d.options;
    if (o.expires_in_s == 0 or o.expires_in_s > max_expires_s) return false;
    switch (d.key) {
        .exact => |name| {
            if (!validate.isObjectName(name)) return false;
            if (!isPolicyText(name)) return false;
            if (signing.hasDotSegment(name)) return false;
        },
        .starts_with => |prefix| {
            if (prefix.len > validate.max_object_name_len) return false;
            if (!isPolicyText(prefix)) return false;
        },
    }
    var ranges: usize = 0;
    for (o.fields, 0..) |field, i| {
        if (field.name.len == 0) return false;
        if (!isPolicyText(field.name) or !isPolicyText(field.value)) return false;
        for (reserved_fields) |name| if (std.ascii.eqlIgnoreCase(field.name, name)) return false;
        for (unconditionable_fields) |name| if (std.ascii.eqlIgnoreCase(field.name, name)) return false;
        if (isIgnored(field.name)) return false;
        for (o.fields[0..i]) |earlier| if (std.ascii.eqlIgnoreCase(earlier.name, field.name)) return false;
        if (std.ascii.eqlIgnoreCase(field.name, "success_action_status") and !isSuccessStatus(field.value)) return false;
    }
    for (o.conditions) |condition| switch (condition) {
        .starts_with => |s| {
            if (s.field.len == 0) return false;
            if (!isPolicyText(s.field) or !isPolicyText(s.prefix)) return false;
            for (unconditionable_fields) |name| if (std.ascii.eqlIgnoreCase(s.field, name)) return false;
            if (isIgnored(s.field)) return false;
        },
        .content_length_range => |r| {
            ranges += 1;
            if (ranges > 1 or r.min > r.max or r.max > max_object_size) return false;
        },
    };
    return true;
}

fn checkProperty(_: void, bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(bytes);
    var d = try drawOptions(arena, &g);
    // The draw keeps to valid UTF-8; splice in what a caller could pass.
    if (g.intRange(u8, 0, 3) == 0) {
        const fields = try arena.dupe(types.PostField, d.options.fields);
        if (fields.len > 0) {
            fields[0].value = g.rest();
            d.options.fields = fields;
        }
    }
    const allowed = allowedByRules(d);
    const result = check(null, "https://storage.googleapis.com", d.bucket, d.key, d.options, null);
    try testing.expectEqual(allowed, result != error.InvalidPostPolicyOptions);
}

test "fuzz post policy: check accepts exactly what the rules allow" {
    try test_util.fuzzBytes({}, checkProperty, .{ .corpus = &.{
        "",
        "\x00\x00\x01\x00",
        "\x00\x10o\x01\x00file",
    } });
}
