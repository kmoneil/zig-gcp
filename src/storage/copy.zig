//! Server-side copies: the rewrite loop behind `copyTo`, and the metadata a
//! copy carries.
//!
//! A rewrite that sends a destination resource gives the copy exactly what
//! that resource says, and nothing of the source's. Google's JSON reference
//! states only the empty case. Its v2 API definition states the rest ("If
//! `destination` is present it is used to construct the destination
//! object's metadata; otherwise the destination object's metadata is copied
//! from the source object"), and tests against the real service in Google's
//! Ruby and Node libraries show it. A copy that sent only what changed would
//! lose everything else: `{"storageClass":"NEARLINE"}` keeps the bytes and
//! drops the content type and every custom entry. Both emulators merge
//! field by field instead, so nothing here relies on how a server fills a
//! gap. What that means:
//!
//! - A copy with no change sends `{}`, which inherits the source's editable
//!   metadata. ACLs, holds and retention never carry over.
//! - A copy with any change reads the source first and sends its editable
//!   fields back, as the server sent them, with the change applied, as
//!   gcloud does. `contentType` is always sent, so the resource is never
//!   empty: an empty one means "inherit everything".
//! - That copy is pinned to what was read: `sourceGeneration` fixes the
//!   bytes and `ifSourceMetagenerationMatch` the metadata, so a change to
//!   the source in between fails the copy with a 412 instead of mixing two
//!   versions.
//! - Every call of the loop sends the same resource and parameters, which
//!   the API requires of calls that carry a rewrite token.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Stringify = std.json.Stringify;
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const logging = @import("logging.zig");
const metadata = @import("metadata.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const Error = @import("errors.zig").Error;

/// What a changed copy's content type is when neither the caller nor the
/// source names one: what Cloud Storage gives an upload that names none.
pub const default_content_type = "application/octet-stream";

/// The longest storage class accepted. The longest real one,
/// DURABLE_REDUCED_AVAILABILITY, is 28 bytes.
pub const max_storage_class_len = 64;

/// Progress is the server's promise; a loop this long has none.
const max_rounds = 100_000;

/// Copies `source_object` to `dest_object`, looping over rewrite calls
/// until the service reports done. The caller has begun the call and
/// checked all four names.
pub fn copy(
    client: *Client,
    source_bucket: []const u8,
    source_object: []const u8,
    dest_bucket: []const u8,
    dest_object: []const u8,
    options: types.CopyOptions,
) Error!types.Owned(types.ObjectInfo) {
    try check(client.diagnostics, options);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    var response: std.heap.ArenaAllocator = .init(client.gpa);
    defer response.deinit();

    var params: names.RewriteParams = .{
        .source_generation = options.source_generation,
        .preconditions = options.preconditions,
    };
    var body: []const u8 = "{}";
    if (changes(options)) {
        const path = try names.objectPath(scratch.allocator(), source_bucket, source_object, options.source_generation, .{});
        const read = try rpc.execute(client, &response, .{ .method = .GET, .path = path });
        const source = codec.decodeCopySource(scratch.allocator(), read) catch |err| {
            if (err == error.InvalidResponse) {
                if (client.diagnostics) |d| d.print("the source's metadata did not decode, or named no generation and metageneration to pin the copy to", .{});
            }
            return err;
        };
        body = try encodeResource(scratch.allocator(), source, options);
        params.source_generation = source.generation;
        params.if_source_metageneration_match = source.metageneration;
    }

    const first_retries = options.preconditions.makesWriteSafe() or client.retry_unconditional_writes;
    var rounds: u32 = 0;
    while (true) {
        rounds += 1;
        if (rounds > max_rounds) {
            if (client.diagnostics) |d| d.print("the rewrite loop never reported done", .{});
            return error.InvalidResponse;
        }
        _ = response.reset(.retain_capacity);
        const path = try names.rewritePath(scratch.allocator(), source_bucket, source_object, dest_bucket, dest_object, params);
        // A call that carries a token repeats earlier work, which is safe;
        // the first call is safe only under a destination condition.
        const retried = params.rewrite_token != null or first_retries;
        const reply = rpc.execute(client, &response, .{
            .method = .POST,
            .path = path,
            .body = body,
            .retry = retried,
        }) catch |err| switch (err) {
            error.FailedPrecondition => {
                if (params.if_source_metageneration_match) |read_at| return pinned412(client, retried, read_at);
                return rpc.ambiguous412(client, retried);
            },
            else => |e| return e,
        };
        const rewrite = codec.decodeRewrite(response.allocator(), reply) catch |err|
            return rpc.decodeFailed(client, err, "rewrite");
        if (rewrite.done) {
            var result: types.Owned(types.ObjectInfo) = try .init(client.gpa);
            errdefer result.deinit();
            // Decoded again into the result's arena, which outlives this loop.
            const kept = codec.decodeRewrite(result.arena.allocator(), reply) catch |err|
                return rpc.decodeFailed(client, err, "rewrite");
            result.value = kept.resource orelse {
                if (client.diagnostics) |d| d.print("the final rewrite response carried no object resource", .{});
                return error.InvalidResponse;
            };
            return result;
        }
        const next = rewrite.rewrite_token orelse {
            if (client.diagnostics) |d| d.print("the rewrite is not done, but the response carried no token to continue with", .{});
            return error.InvalidResponse;
        };
        // The token must outlive the response arena it was decoded into.
        params.rewrite_token = try scratch.allocator().dupe(u8, next);
        logging.debug("rewrite of {s}: {d} bytes so far, continuing", .{ source_object, rewrite.total_bytes_rewritten });
    }
}

/// A 412 on a copy pinned to its source has two causes the server does
/// not tell apart: the destination's condition, or the source's metadata
/// moving after it was read. The diagnostics name both.
fn pinned412(client: *Client, retried: bool, read_at: u64) Error {
    var buf: [320]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buf,
        "the precondition failed: either the destination's condition did not hold, or the source's metadata changed after the copy read it at metageneration {d}{s}",
        .{ read_at, if (retried) "; if this call was a retry, an earlier attempt may have succeeded: get the object and compare checksums" else "" },
    ) catch unreachable;
    rpc.replace412(client, message);
    return error.FailedPrecondition;
}

/// Whether `options` change anything on the way, which is what makes a
/// copy read its source first.
pub fn changes(options: types.CopyOptions) bool {
    return options.content_type != null or
        options.cache_control != null or
        options.content_disposition != null or
        options.content_encoding != null or
        options.content_language != null or
        std.meta.activeTag(options.edit) != .keep or
        options.storage_class != null;
}

/// Refuses what a changed copy could not send, and says why in `diag`: the
/// rules `updateMetadata` applies, plus two of a copy's own.
pub fn check(diag: ?*core.Diagnostics, options: types.CopyOptions) error{InvalidMetadataUpdate}!void {
    try metadata.checkFields(diag, .{
        options.content_type,
        options.cache_control,
        options.content_disposition,
        options.content_encoding,
        options.content_language,
    });
    try metadata.checkEdit(diag, options.edit);
    if (options.content_type) |value| if (value.len == 0) {
        if (diag) |d| d.print("content_type: a changed copy always carries one; leave it null to keep the source's", .{});
        return error.InvalidMetadataUpdate;
    };
    if (options.storage_class) |class| if (!isStorageClass(class)) {
        if (diag) |d| d.print("storage_class: 1 to {d} capital letters and underscores, such as NEARLINE", .{max_storage_class_len});
        return error.InvalidMetadataUpdate;
    };
}

/// What could be a storage class. Which ones exist is the server's call.
fn isStorageClass(text: []const u8) bool {
    if (text.len == 0 or text.len > max_storage_class_len) return false;
    for (text) |c| if (!std.ascii.isUpper(c) and c != '_') return false;
    return true;
}

/// The destination resource of a copy with changes: the source's editable
/// fields with `options` applied, in a fixed order. `options` has passed
/// `check`.
pub fn encodeResource(arena: Allocator, source: codec.CopySource, options: types.CopyOptions) Allocator.Error![]u8 {
    const entries = try mergedMetadata(arena, source.metadata, options.edit);
    var out: Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeResource(&jw, source, options, entries) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeResource(
    jw: *Stringify,
    source: codec.CopySource,
    options: types.CopyOptions,
    entries: []const types.Metadata,
) Stringify.Error!void {
    const fields = [_]struct { name: []const u8, value: ?[]const u8 }{
        .{ .name = "contentType", .value = options.content_type orelse source.content_type orelse default_content_type },
        .{ .name = "cacheControl", .value = changed(options.cache_control, source.cache_control) },
        .{ .name = "contentDisposition", .value = changed(options.content_disposition, source.content_disposition) },
        .{ .name = "contentEncoding", .value = changed(options.content_encoding, source.content_encoding) },
        .{ .name = "contentLanguage", .value = changed(options.content_language, source.content_language) },
        // Lifecycle rules read it, so a copy that dropped it would age
        // differently. The caller cannot change it here.
        .{ .name = "customTime", .value = source.custom_time },
    };
    try jw.beginObject();
    for (fields) |field| {
        const value = field.value orelse continue;
        try jw.objectField(field.name);
        try jw.write(value);
    }
    if (entries.len > 0) {
        try jw.objectField("metadata");
        try jw.beginObject();
        for (entries) |entry| {
            try jw.objectField(entry.key);
            try jw.write(entry.value);
        }
        try jw.endObject();
    }
    if (options.storage_class) |class| {
        try jw.objectField("storageClass");
        try jw.write(class);
    }
    try jw.endObject();
}

/// A field after the change: the caller's value, or the source's when the
/// caller left it null. An empty string clears it, which in a resource
/// that replaces everything means leaving it out.
fn changed(change: ?[]const u8, carried: ?[]const u8) ?[]const u8 {
    const value = change orelse return carried;
    return if (value.len == 0) null else value;
}

/// The source's custom metadata after `edit`, in the source's order, with
/// new keys after it in the order the edit names them. A removal is an
/// absence: the resource replaces the copy's whole map, so it needs no
/// null.
fn mergedMetadata(
    arena: Allocator,
    source: []const types.Metadata,
    edit: types.MetadataEdit,
) Allocator.Error![]const types.Metadata {
    const list = switch (edit) {
        .keep => return source,
        .clear => return &.{},
        .change => |list| list,
    };
    var merged: std.ArrayList(types.Metadata) = .empty;
    try merged.appendSlice(arena, source);
    for (list) |change| {
        const at: ?usize = for (merged.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.key, change.key)) break i;
        } else null;
        if (change.value) |value| {
            if (at) |i| {
                merged.items[i].value = value;
            } else {
                try merged.append(arena, .{ .key = change.key, .value = value });
            }
        } else if (at) |i| {
            _ = merged.orderedRemove(i);
        }
    }
    return merged.items;
}

const testing = std.testing;
const test_util = @import("test_util.zig");

/// A source with every carried field set, as `decodeCopySource` reads one.
const full_source: codec.CopySource = .{
    .generation = 7,
    .metageneration = 3,
    .content_type = "text/plain",
    .cache_control = "no-cache",
    .content_disposition = "attachment",
    .content_encoding = "gzip",
    .content_language = "en",
    .custom_time = "2026-09-23T00:00:00Z",
    .metadata = &.{
        .{ .key = "b", .value = "2" },
        .{ .key = "a", .value = "1" },
    },
};

/// The same source on the wire.
const full_source_json =
    \\{"name":"a","bucket":"s","generation":"7","metageneration":"3",
    \\ "contentType":"text/plain","cacheControl":"no-cache","contentDisposition":"attachment",
    \\ "contentEncoding":"gzip","contentLanguage":"en","customTime":"2026-09-23T00:00:00Z",
    \\ "storageClass":"STANDARD","metadata":{"b":"2","a":"1"}}
;

const bare_source: codec.CopySource = .{
    .generation = 1,
    .metageneration = 1,
    .content_type = null,
    .cache_control = null,
    .content_disposition = null,
    .content_encoding = null,
    .content_language = null,
    .custom_time = null,
    .metadata = &.{},
};

/// The options beside the resource they must produce from a source,
/// written out by hand from the rules in the module comment.
const Golden = struct {
    label: []const u8,
    source: codec.CopySource,
    options: types.CopyOptions,
    resource: []const u8,
};

const carried_fields =
    "\"cacheControl\":\"no-cache\",\"contentDisposition\":\"attachment\"," ++
    "\"contentEncoding\":\"gzip\",\"contentLanguage\":\"en\",\"customTime\":\"2026-09-23T00:00:00Z\"";

const goldens = [_]Golden{
    .{
        .label = "a new content type carries everything else, custom time included",
        .source = full_source,
        .options = .{ .content_type = "application/json" },
        .resource = "{\"contentType\":\"application/json\"," ++ carried_fields ++
            ",\"metadata\":{\"b\":\"2\",\"a\":\"1\"}}",
    },
    .{
        .label = "a storage class alone still sends every field, which is the point",
        .source = full_source,
        .options = .{ .storage_class = "NEARLINE" },
        .resource = "{\"contentType\":\"text/plain\"," ++ carried_fields ++
            ",\"metadata\":{\"b\":\"2\",\"a\":\"1\"},\"storageClass\":\"NEARLINE\"}",
    },
    .{
        .label = "an empty string clears a field by leaving it out",
        .source = full_source,
        .options = .{ .cache_control = "", .content_language = "" },
        .resource = "{\"contentType\":\"text/plain\",\"contentDisposition\":\"attachment\"," ++
            "\"contentEncoding\":\"gzip\",\"customTime\":\"2026-09-23T00:00:00Z\"," ++
            "\"metadata\":{\"b\":\"2\",\"a\":\"1\"}}",
    },
    .{
        .label = "a change replaces in place, appends new keys, and removes by leaving out",
        .source = full_source,
        .options = .{ .edit = .{ .change = &.{
            .{ .key = "c", .value = "3" },
            .{ .key = "b", .value = null },
            .{ .key = "a", .value = "one" },
            .{ .key = "missing", .value = null },
        } } },
        .resource = "{\"contentType\":\"text/plain\"," ++ carried_fields ++
            ",\"metadata\":{\"a\":\"one\",\"c\":\"3\"}}",
    },
    .{
        .label = "clear sends no metadata at all",
        .source = full_source,
        .options = .{ .edit = .clear },
        .resource = "{\"contentType\":\"text/plain\"," ++ carried_fields ++ "}",
    },
    .{
        .label = "removing every key is the same as clearing",
        .source = full_source,
        .options = .{ .edit = .{ .change = &.{
            .{ .key = "a", .value = null },
            .{ .key = "b", .value = null },
        } } },
        .resource = "{\"contentType\":\"text/plain\"," ++ carried_fields ++ "}",
    },
    .{
        .label = "a source with no content type gets the default, so the resource is never empty",
        .source = bare_source,
        .options = .{ .edit = .clear },
        .resource = "{\"contentType\":\"application/octet-stream\"}",
    },
    .{
        .label = "a bare source takes the new fields and nothing else",
        .source = bare_source,
        .options = .{
            .cache_control = "public, max-age=60",
            .edit = .{ .change = &.{.{ .key = "origin", .value = "zig" }} },
            .storage_class = "COLDLINE",
        },
        .resource = "{\"contentType\":\"application/octet-stream\",\"cacheControl\":\"public, max-age=60\"," ++
            "\"metadata\":{\"origin\":\"zig\"},\"storageClass\":\"COLDLINE\"}",
    },
};

test "golden: the copy resource, written from the rules by hand" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    for (goldens) |golden| {
        errdefer std.debug.print("golden: {s}\n", .{golden.label});
        try check(null, golden.options);
        try testing.expect(changes(golden.options));
        try testing.expectEqualStrings(golden.resource, try encodeResource(arena_state.allocator(), golden.source, golden.options));
    }
}

test "changes: only the defaults are no change" {
    try testing.expect(!changes(.{}));
    try testing.expect(!changes(.{ .source_generation = 5, .preconditions = .does_not_exist }));
    try testing.expect(changes(.{ .content_type = "text/plain" }));
    try testing.expect(changes(.{ .cache_control = "" }));
    try testing.expect(changes(.{ .content_disposition = "inline" }));
    try testing.expect(changes(.{ .content_encoding = "gzip" }));
    try testing.expect(changes(.{ .content_language = "en" }));
    try testing.expect(changes(.{ .edit = .clear }));
    try testing.expect(changes(.{ .edit = .{ .change = &.{} } }));
    try testing.expect(changes(.{ .storage_class = "NEARLINE" }));
}

test "copyTo with a change reads the source, then sends it back changed and pinned" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = full_source_json } },
        .{ .respond = .{ .body = "{\"done\":false,\"rewriteToken\":\"t+1\"}" } },
        .{ .respond = .{ .body =
        \\{"done":true,"resource":{"name":"copy.txt","bucket":"d","generation":"9","contentType":"application/json"}}
        } },
    }, .{});
    defer h.deinit();
    const src = h.client.bucket("s").object("dir/a.txt");
    const dest = h.client.bucket("d").object("copy.txt");

    var copied = try src.copyTo(dest, .{
        .content_type = "application/json",
        .preconditions = .does_not_exist,
    });
    defer copied.deinit();
    try testing.expectEqual(9, copied.value.generation);

    // The read names the live generation: none was asked for.
    try h.expectRequest(0, .GET, "https://storage.googleapis.com/storage/v1/b/s/o/dir%2Fa.txt", null);
    const resource = "{\"contentType\":\"application/json\"," ++ carried_fields ++ ",\"metadata\":{\"b\":\"2\",\"a\":\"1\"}}";
    try h.expectRequest(
        1,
        .POST,
        "https://storage.googleapis.com/storage/v1/b/s/o/dir%2Fa.txt/rewriteTo/b/d/o/copy.txt?sourceGeneration=7&ifSourceMetagenerationMatch=3&ifGenerationMatch=0",
        resource,
    );
    // The token call repeats the same resource and parameters, as the API
    // requires of calls that carry one.
    try h.expectRequest(
        2,
        .POST,
        "https://storage.googleapis.com/storage/v1/b/s/o/dir%2Fa.txt/rewriteTo/b/d/o/copy.txt?sourceGeneration=7&ifSourceMetagenerationMatch=3&ifGenerationMatch=0&rewriteToken=t%2B1",
        resource,
    );
    try h.expectRequestCount(3);
}

test "copyTo with a change reads the generation it was asked to copy" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"generation\":\"5\",\"metageneration\":\"2\",\"contentType\":\"text/csv\"}" } },
        .{ .respond = .{ .body = "{\"done\":true,\"resource\":{\"name\":\"c\"}}" } },
    }, .{});
    defer h.deinit();
    const src = h.client.bucket("s").object("a");
    var copied = try src.copyTo(src, .{ .source_generation = 5, .storage_class = "ARCHIVE" });
    defer copied.deinit();
    try h.expectRequest(0, .GET, "https://storage.googleapis.com/storage/v1/b/s/o/a?generation=5", null);
    try h.expectRequest(
        1,
        .POST,
        "https://storage.googleapis.com/storage/v1/b/s/o/a/rewriteTo/b/s/o/a?sourceGeneration=5&ifSourceMetagenerationMatch=2",
        "{\"contentType\":\"text/csv\",\"storageClass\":\"ARCHIVE\"}",
    );
}

test "copyTo with no change sends {} and reads nothing" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{\"done\":true,\"resource\":{\"name\":\"c\"}}" } }}, .{});
    defer h.deinit();
    var copied = try h.client.bucket("s").object("a").copyTo(h.client.bucket("d").object("c"), .{});
    defer copied.deinit();
    try h.expectRequest(0, .POST, "https://storage.googleapis.com/storage/v1/b/s/o/a/rewriteTo/b/d/o/c", "{}");
    try h.expectRequestCount(1);
}

test "copyTo: the read retries like any read, the unconditioned write still does not" {
    const unavailable: test_util.FakeTransport.Reply = .{ .respond = .{ .status = 503, .body = "{}" } };
    var h: test_util.Harness = undefined;
    try h.init(&.{
        unavailable,
        .{ .respond = .{ .body = full_source_json } },
        unavailable,
    }, .{ .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1 } });
    defer h.deinit();
    try testing.expectError(error.Unavailable, h.client.bucket("s").object("a").copyTo(
        h.client.bucket("d").object("c"),
        .{ .content_type = "text/html" },
    ));
    // Two reads, then one write, which a lost answer could have landed.
    try h.expectRequestCount(3);
}

test "copyTo: a 412 on a pinned copy names both causes" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = full_source_json } },
        .{ .respond = .{ .status = 412, .body =
        \\{"error":{"code":412,"message":"At least one of the pre-conditions you specified did not hold.","errors":[{"reason":"conditionNotMet"}]}}
        } },
    }, .{});
    defer h.deinit();
    try testing.expectError(error.FailedPrecondition, h.client.bucket("s").object("a").copyTo(
        h.client.bucket("d").object("c"),
        .{ .storage_class = "NEARLINE" },
    ));
    try testing.expectEqual(412, h.diag.http_status);
    try testing.expectEqualStrings("conditionNotMet", h.diag.status());
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "destination's condition") != null);
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "metageneration 3") != null);
    // Not retried, so no ambiguity to mention.
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "retry") == null);
}

test "copyTo: a 412 after a token call may follow an attempt that landed" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .body = "{\"done\":false,\"rewriteToken\":\"t\"}" } },
        .{ .respond = .{ .status = 412, .body = "{\"error\":{\"code\":412,\"message\":\"no\"}}" } },
    }, .{});
    defer h.deinit();
    try testing.expectError(error.FailedPrecondition, h.client.bucket("s").object("a").copyTo(
        h.client.bucket("d").object("c"),
        .{},
    ));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "earlier attempt may have succeeded") != null);
}

test "copyTo: a source with nothing to pin to sends nothing" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = "{\"name\":\"a\",\"contentType\":\"text/plain\"}" } }}, .{});
    defer h.deinit();
    try testing.expectError(error.InvalidResponse, h.client.bucket("s").object("a").copyTo(
        h.client.bucket("d").object("c"),
        .{ .content_type = "text/html" },
    ));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "pin") != null);
    try h.expectRequestCount(1);
}

test "check: what a changed copy refuses, before anything is sent" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const src = h.client.bucket("s").object("a");
    const dest = h.client.bucket("d").object("c");
    const refused = [_]struct { options: types.CopyOptions, says: []const u8 }{
        .{ .options = .{ .content_type = "" }, .says = "always carries one" },
        .{ .options = .{ .content_type = "text/plain\r\nx: y" }, .says = "content_type" },
        .{ .options = .{ .cache_control = "caf\xc3\xa9" }, .says = "cache_control" },
        .{ .options = .{ .storage_class = "" }, .says = "storage_class" },
        .{ .options = .{ .storage_class = "nearline" }, .says = "storage_class" },
        .{ .options = .{ .storage_class = "NEAR LINE" }, .says = "storage_class" },
        .{ .options = .{ .storage_class = "A" ** 65 }, .says = "storage_class" },
        .{ .options = .{ .edit = .{ .change = &.{.{ .key = "", .value = "v" }} } }, .says = "no key" },
        .{ .options = .{ .edit = .{ .change = &.{
            .{ .key = "k", .value = "1" },
            .{ .key = "k", .value = null },
        } } }, .says = "twice" },
        .{ .options = .{ .edit = .{ .change = &.{.{ .key = "k", .value = "a\nb" }} } }, .says = "printable" },
    };
    for (refused) |case| {
        errdefer std.debug.print("expected refusal: {s}\n", .{case.says});
        try testing.expectError(error.InvalidMetadataUpdate, src.copyTo(dest, case.options));
        try testing.expect(std.mem.indexOf(u8, h.diag.message(), case.says) != null);
    }
    try h.expectRequestCount(0);
    // The longest real class, and a made-up one the server will judge.
    try check(null, .{ .storage_class = "DURABLE_REDUCED_AVAILABILITY" });
    try check(null, .{ .storage_class = "A" ** max_storage_class_len });
}

fn copyWithChanges(gpa: Allocator) !void {
    // Built by hand rather than through `Harness`, whose `deinit` frees
    // both halves: here the transport must outlive a client that may
    // never have been built.
    var fake: test_util.FakeTransport = .init(gpa, &.{
        .{ .respond = .{ .body = full_source_json } },
        .{ .respond = .{ .body = "{\"done\":false,\"rewriteToken\":\"t\"}" } },
        .{ .respond = .{ .body = "{\"done\":true,\"resource\":{\"name\":\"c\",\"metadata\":{\"a\":\"one\"}}}" } },
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
    var copied = try client.bucket("s").object("a").copyTo(client.bucket("d").object("c"), .{
        .content_type = "text/html",
        .edit = .{ .change = &.{ .{ .key = "a", .value = "one" }, .{ .key = "b", .value = null } } },
        .storage_class = "NEARLINE",
    });
    copied.deinit();
}

test "copyTo with changes: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, copyWithChanges, .{});
}

// Properties. Each states a rule of the module comment independently of
// the code above, and holds it to arbitrary input.

const wire_fields = [_][]const u8{ "contentType", "cacheControl", "contentDisposition", "contentEncoding", "contentLanguage" };

fn drawText(arena: Allocator, g: *test_util.ByteGen, max_len: usize) ![]const u8 {
    var buffer: [64]u8 = undefined;
    return arena.dupe(u8, g.utf8(&buffer, max_len));
}

/// Keys from a small alphabet, so a change often names a key the source
/// has, which is where merging goes wrong.
fn drawKey(arena: Allocator, g: *test_util.ByteGen) ![]const u8 {
    const len = g.intRange(usize, 1, 2);
    const key = try arena.alloc(u8, len);
    for (key) |*c| c.* = g.pick(u8, "abc");
    return key;
}

fn drawSource(arena: Allocator, g: *test_util.ByteGen) !codec.CopySource {
    var source = bare_source;
    const slots = [_]*?[]const u8{
        &source.content_type,     &source.cache_control,    &source.content_disposition,
        &source.content_encoding, &source.content_language, &source.custom_time,
    };
    for (slots) |slot| slot.* = if (g.boolean()) try drawText(arena, g, 20) else null;
    // Unique keys, as a JSON object gives them.
    var entries: std.ArrayList(types.Metadata) = .empty;
    for (0..g.intRange(usize, 0, 4)) |_| {
        const key = try drawKey(arena, g);
        const taken = for (entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) break true;
        } else false;
        if (!taken) try entries.append(arena, .{ .key = key, .value = try drawText(arena, g, 20) });
    }
    source.metadata = entries.items;
    return source;
}

fn drawOptions(arena: Allocator, g: *test_util.ByteGen) !types.CopyOptions {
    var options: types.CopyOptions = .{};
    const slots = [_]*?[]const u8{
        &options.content_type,     &options.cache_control,    &options.content_disposition,
        &options.content_encoding, &options.content_language,
    };
    // Absent, empty, or drawn, as a caller might pass.
    for (slots) |slot| slot.* = switch (g.intRange(u8, 0, 2)) {
        0 => null,
        1 => "",
        else => try drawText(arena, g, 20),
    };
    options.edit = switch (g.intRange(u8, 0, 3)) {
        0 => .keep,
        1 => .clear,
        else => edit: {
            const list = try arena.alloc(types.MetadataChange, g.intRange(usize, 0, 4));
            for (list) |*change| change.* = .{
                .key = try drawKey(arena, g),
                .value = if (g.boolean()) null else try drawText(arena, g, 20),
            };
            break :edit .{ .change = list };
        },
    };
    options.storage_class = if (g.boolean()) g.pick([]const u8, &.{ "NEARLINE", "COLDLINE", "ARCHIVE", "STANDARD" }) else null;
    return options;
}

/// Section 3 of the spec, stated as a map from wire field to value, with
/// none of the code above: what the copy's resource must say.
fn expectedFields(arena: Allocator, source: codec.CopySource, options: types.CopyOptions) !std.StringArrayHashMapUnmanaged([]const u8) {
    var want: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    const changes_to = [_]?[]const u8{
        options.content_type,     options.cache_control,    options.content_disposition,
        options.content_encoding, options.content_language,
    };
    const carried = [_]?[]const u8{
        source.content_type,     source.cache_control,    source.content_disposition,
        source.content_encoding, source.content_language,
    };
    for (wire_fields, changes_to, carried, 0..) |name, change, from_source, i| {
        if (change) |value| {
            if (value.len > 0) try want.put(arena, name, value);
        } else if (from_source) |value| {
            try want.put(arena, name, value);
        } else if (i == 0) {
            try want.put(arena, name, default_content_type);
        }
    }
    if (source.custom_time) |value| try want.put(arena, "customTime", value);
    if (options.storage_class) |value| try want.put(arena, "storageClass", value);
    return want;
}

/// The custom metadata after the edit, as a map.
fn expectedMetadata(arena: Allocator, source: codec.CopySource, edit: types.MetadataEdit) !std.StringArrayHashMapUnmanaged([]const u8) {
    var want: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    if (edit == .clear) return want;
    for (source.metadata) |entry| try want.put(arena, entry.key, entry.value);
    if (edit == .change) for (edit.change) |change| {
        if (change.value) |value| try want.put(arena, change.key, value) else _ = want.orderedRemove(change.key);
    };
    return want;
}

fn resourceProperty(_: void, bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(bytes);
    const source = try drawSource(arena, &g);
    const options = try drawOptions(arena, &g);
    check(null, options) catch return;
    const resource = try encodeResource(arena, source, options);

    // Strict JSON: a repeated key would be an error here.
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, resource, .{ .duplicate_field_behavior = .@"error" });
    const root = parsed.value.object;
    // Never empty, which Cloud Storage would read as "inherit everything".
    try testing.expect(root.get("contentType") != null);

    const want = try expectedFields(arena, source, options);
    var wanted_keys = want.count();
    for (want.keys(), want.values()) |name, value| {
        const got = root.get(name) orelse return error.TestFieldMissing;
        try testing.expectEqualStrings(value, got.string);
    }
    const want_metadata = try expectedMetadata(arena, source, options.edit);
    if (want_metadata.count() == 0) {
        try testing.expectEqual(null, root.get("metadata"));
    } else {
        wanted_keys += 1;
        const got = (root.get("metadata") orelse return error.TestNoMetadata).object;
        try testing.expectEqual(want_metadata.count(), got.count());
        // Same entries, in the same order: the source's, then new keys.
        for (want_metadata.keys(), want_metadata.values(), got.keys(), got.values()) |wk, wv, gk, gv| {
            try testing.expectEqualStrings(wk, gk);
            try testing.expectEqualStrings(wv, gv.string);
        }
    }
    // And no field the rules did not ask for.
    try testing.expectEqual(wanted_keys, root.count());
}

test "fuzz copy: the resource is the source's fields with the change applied, and nothing else" {
    try test_util.fuzzBytes({}, resourceProperty, .{ .corpus = &.{
        "",
        "\x01\x05text/\x01\x02ab\x00\x00\x00\x00\x02\x01a\x01\x01\x02",
        "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff",
    } });
}

/// The resource written a second time, byte for byte, from the rules, with
/// none of the code above. std's JSON writer escapes only what JSON demands,
/// which `metadata.zig`'s model already states.
fn modelResource(arena: Allocator, source: codec.CopySource, options: types.CopyOptions) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '{');
    const want = try expectedFields(arena, source, options);
    const order = wire_fields ++ [_][]const u8{"customTime"};
    var first = true;
    for (order) |name| {
        const value = want.get(name) orelse continue;
        if (!first) try out.append(arena, ',');
        first = false;
        try out.print(arena, "\"{s}\":", .{name});
        try modelString(arena, &out, value);
    }
    const entries = try expectedMetadata(arena, source, options.edit);
    if (entries.count() > 0) {
        try out.appendSlice(arena, ",\"metadata\":{");
        for (entries.keys(), entries.values(), 0..) |key, value, i| {
            if (i > 0) try out.append(arena, ',');
            try modelString(arena, &out, key);
            try out.append(arena, ':');
            try modelString(arena, &out, value);
        }
        try out.append(arena, '}');
    }
    if (want.get("storageClass")) |class| {
        try out.appendSlice(arena, ",\"storageClass\":");
        try modelString(arena, &out, class);
    }
    try out.append(arena, '}');
    return out.items;
}

fn modelString(arena: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(arena, '"');
    for (text) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        0x08 => try out.appendSlice(arena, "\\b"),
        0x09 => try out.appendSlice(arena, "\\t"),
        0x0a => try out.appendSlice(arena, "\\n"),
        0x0c => try out.appendSlice(arena, "\\f"),
        0x0d => try out.appendSlice(arena, "\\r"),
        0x00...0x07, 0x0b, 0x0e...0x1f => try out.print(arena, "\\u{x:0>4}", .{c}),
        else => try out.append(arena, c),
    };
    try out.append(arena, '"');
}

fn modelProperty(_: void, bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(bytes);
    const source = try drawSource(arena, &g);
    const options = try drawOptions(arena, &g);
    check(null, options) catch return;
    try testing.expectEqualStrings(try modelResource(arena, source, options), try encodeResource(arena, source, options));
}

test "slow property copy: the resource matches a model written from the rules" {
    try test_util.fuzzBytes({}, modelProperty, .{ .random_runs = 300, .max_len = 512 });
}

/// The rules `check` enforces, stated again.
fn allowedByRules(options: types.CopyOptions) bool {
    const values = [_]?[]const u8{
        options.content_type,     options.cache_control,    options.content_disposition,
        options.content_encoding, options.content_language,
    };
    for (values) |value| {
        const text = value orelse continue;
        for (text) |c| if (c < ' ' or c == 0x7f or c >= 0x80) return false;
    }
    if (options.content_type) |text| if (text.len == 0) return false;
    if (options.storage_class) |class| {
        if (class.len == 0 or class.len > 64) return false;
        for (class) |c| if (!(c >= 'A' and c <= 'Z') and c != '_') return false;
    }
    switch (options.edit) {
        .keep, .clear => {},
        .change => |list| for (list, 0..) |change, i| {
            if (change.key.len == 0) return false;
            for (change.key) |c| if (c < ' ' or c >= 0x7f) return false;
            if (change.value) |value| for (value) |c| if (c < ' ' or c >= 0x7f) return false;
            for (list[0..i]) |earlier| if (std.mem.eql(u8, earlier.key, change.key)) return false;
        },
    }
    return true;
}

fn checkProperty(_: void, bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(bytes);
    var options = try drawOptions(arena, &g);
    // The draws keep to valid UTF-8 and real classes; splice in what a
    // caller could pass.
    switch (g.intRange(u8, 0, 3)) {
        0 => options.storage_class = g.slice(70),
        1 => options.content_language = g.slice(8),
        else => {},
    }
    const allowed = allowedByRules(options);
    const result = check(null, options);
    try testing.expectEqual(allowed, result != error.InvalidMetadataUpdate);
}

test "fuzz copy: check accepts exactly what the rules allow" {
    try test_util.fuzzBytes({}, checkProperty, .{ .corpus = &.{
        "",
        "\x00\x00\x00\x00\x00\x00\x00\x00",
        "\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
    } });
}
