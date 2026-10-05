//! Runs one API call: core's request engine builds the URL, attaches
//! credentials, sends through the client's transport, maps failures to
//! errors, retries transient ones with jittered backoff, and keeps
//! `Diagnostics` and the log current. This file binds that engine to a
//! Firestore client and holds the checks its public calls share.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const names = @import("names.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Error = errors.Error;

/// The OAuth scope the client asks its token provider for: Cloud
/// Datastore's, the narrowest that Firestore's API takes.
pub const scope = "https://www.googleapis.com/auth/datastore";

/// The shared engine, logging under this module's scope.
const Engine = core.rpc.Engine(.gcp_firestore);

pub const Call = core.rpc.Call;

fn engine(client: *Client) Engine {
    return .{
        .gpa = client.gpa,
        .io = client.io,
        .transport = client.transport,
        .base_url = client.base_url,
        .auth_scope = scope,
        .token_provider = client.token_provider,
        .send_quota_project = client.send_quota_project,
        .retry = client.retry,
        .request_timeout_ms = client.request_timeout_ms,
        .diagnostics = client.diagnostics,
    };
}

/// Starts a public call: `Diagnostics` describe only the latest call.
pub fn begin(client: *Client) void {
    engine(client).begin();
}

/// Sends `call` and returns the body of the first 2xx response, which
/// lives in `response`.
pub fn execute(client: *Client, response: *std.heap.ArenaAllocator, call: Call) Error![]const u8 {
    return engine(client).execute(response, call);
}

/// `execute` for calls whose response body is not needed.
pub fn executeDiscard(client: *Client, call: Call) Error!void {
    return engine(client).executeDiscard(call);
}

/// A response that could not be decoded, said in the diagnostics.
pub fn decodeFailed(client: *Client, err: codec.DecodeError, what: []const u8) Error {
    if (err == error.InvalidResponse) {
        if (client.diagnostics) |d| d.print("the {s} response could not be decoded", .{what});
    }
    return err;
}

/// A refusal made here, before anything was sent.
pub fn refuse(client: *Client, err: Error, comptime fmt: []const u8, args: anytype) Error {
    if (client.diagnostics) |d| d.print(fmt, args);
    return err;
}

/// The handle's path joined and checked to be a `kind`'s, in `arena`.
pub fn checkedPath(client: *Client, arena: Allocator, path: names.Path, kind: names.Kind) Error![]const u8 {
    if (path.overflow) return refuse(
        client,
        error.InvalidResourceId,
        "the handle was built from more than {d} parts: pass the whole path to Client.doc or Client.collection",
        .{names.max_path_parts},
    );
    const joined = try path.join(arena);
    if (names.pathProblem(joined, kind)) |problem| {
        return refuse(client, error.InvalidResourceId, "invalid {s} path: {s}", .{ kind.noun(), problem });
    }
    if (joined.len + client.name_prefix_len > validate.max_name_bytes) {
        return refuse(client, error.InvalidResourceId, "invalid {s} path: the full name is over 6 KiB", .{kind.noun()});
    }
    return joined;
}

/// Checks the field paths of a mask.
pub fn checkMask(client: *Client, mask: []const []const u8, what: []const u8) Error!void {
    for (mask) |p| if (names.fieldPathProblem(p)) |problem| {
        return refuse(client, error.InvalidResourceId, "invalid field path in the {s}: {s}", .{ what, problem });
    };
}

/// Checks a document's fields as the server would.
pub fn checkFields(client: *Client, fields: []const types.Field) Error!void {
    var where_buf: [160]u8 = undefined;
    if (validate.fieldsProblem(fields, &where_buf)) |problem| {
        return refuse(client, error.InvalidArgument, "invalid field {s}: {s}", .{ problem.where, problem.what });
    }
}

/// Checks a transaction's id, and that a read does not also ask for a
/// read time: a transaction reads at its own.
pub fn checkTransaction(client: *Client, transaction: ?[]const u8, read_time: ?std.Io.Timestamp) Error!void {
    const t = transaction orelse return;
    if (!validate.isTransactionId(t)) return refuse(client, error.InvalidArgument, "invalid transaction id: expected the base64 text beginTransaction returned", .{});
    if (read_time != null) return refuse(client, error.InvalidArgument, "a read takes a transaction or a read time, not both", .{});
}

/// Checks a timestamp before it is written into a request.
pub fn checkTime(client: *Client, ts: std.Io.Timestamp, what: []const u8) Error!void {
    if (!core.timestamp.inRange(ts)) {
        return refuse(client, error.InvalidArgument, "the {s} is outside the years 1 to 9999", .{what});
    }
}

/// Appends `mask.fieldPaths=` once per path, as a read mask travels.
pub fn addMask(params: *core.query.Params, name: []const u8, mask: []const []const u8) Writer.Error!void {
    for (mask) |p| try params.add(name, p);
}

/// `/v1/projects/P/databases/D/documents:commit`.
pub fn commitPath(arena: Allocator, client: *const Client) Writer.Error![]const u8 {
    var out: Writer.Allocating = .init(arena);
    try names.writeDocumentsPath(&out.writer, client.project_id, client.database_id, "");
    try out.writer.writeAll(":commit");
    return out.written();
}

/// Checks a precondition's time.
pub fn checkPrecondition(client: *Client, precondition: ?types.Precondition) Error!void {
    const p = precondition orelse return;
    switch (p) {
        .exists => {},
        .update_time => |t| try checkTime(client, t, "precondition's update time"),
    }
}

/// What a retried write cannot rule out: that its own earlier attempt
/// landed, its answer was lost, and the refusal is its precondition
/// meeting that write.
pub const retried_note = "; if this write was retried after a lost answer, an earlier attempt may have landed, and this is its precondition meeting that write: read the document to see";

/// Whether `err` is what a repeat of a landed write meets under
/// `precondition`: `exists == false` meets `AlreadyExists`, an update time
/// meets `FailedPrecondition`.
pub fn meetsOwnWrite(err: anyerror, precondition: ?types.Precondition) bool {
    const p = precondition orelse return false;
    return switch (p) {
        .exists => |e| !e and err == error.AlreadyExists,
        .update_time => err == error.FailedPrecondition,
    };
}

/// Adds `note` to the failed call's message, keeping its statuses.
pub fn appendNote(client: *Client, note: []const u8) void {
    const d = client.diagnostics orelse return;
    var status_buf: [core.Diagnostics.max_status_len]u8 = undefined;
    const status_text = d.status();
    @memcpy(status_buf[0..status_text.len], status_text);
    var message_buf: [640]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buf, "{s}{s}", .{ d.message(), note }) catch d.message();
    d.set(d.http_status, status_buf[0..status_text.len], message);
}

/// Adds `retried_note` where it applies, when the client retries at all.
pub fn noteRetriedWrite(client: *Client, err: anyerror, precondition: ?types.Precondition) void {
    if (client.retry.max_attempts <= 1) return;
    if (meetsOwnWrite(err, precondition)) appendNote(client, retried_note);
}

/// `execute` for a write held to `precondition`, with the note above.
pub fn executeWrite(client: *Client, response: *std.heap.ArenaAllocator, call: Call, precondition: ?types.Precondition) Error![]const u8 {
    return execute(client, response, call) catch |err| {
        noteRetriedWrite(client, err, precondition);
        return err;
    };
}

/// `listCollectionIds` below `parent`, a document path, or the root when
/// it is empty. The call has begun.
pub fn listCollectionIds(
    self: *Client,
    parent: []const u8,
    options: types.ListCollectionIdsOptions,
) Error!types.Owned(types.CollectionIdPage) {
    if (options.read_time) |t| try checkTime(self, t, "read time");
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    var out: Writer.Allocating = .init(scratch.allocator());
    names.writeDocumentsPath(&out.writer, self.project_id, self.database_id, parent) catch return error.OutOfMemory;
    out.writer.writeAll(":listCollectionIds") catch return error.OutOfMemory;
    const body = try encodeListCollectionIds(scratch.allocator(), options);

    var result: types.Owned(types.CollectionIdPage) = try .init(self.gpa);
    errdefer result.deinit();
    // A read; asking again is harmless.
    const reply = try execute(self, result.arena, .{ .method = .POST, .path = out.written(), .body = body });
    result.value = codec.decodeCollectionIdPage(result.arena.allocator(), reply) catch |err|
        return decodeFailed(self, err, "collection id list");
    return result;
}

fn encodeListCollectionIds(arena: Allocator, options: types.ListCollectionIdsOptions) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    writeListCollectionIds(&jw, options) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeListCollectionIds(jw: *std.json.Stringify, options: types.ListCollectionIdsOptions) std.json.Stringify.Error!void {
    try jw.beginObject();
    if (options.page_size != 0) {
        try jw.objectField("pageSize");
        try jw.write(options.page_size);
    }
    if (options.page_token) |token| if (token.len > 0) {
        try jw.objectField("pageToken");
        try jw.write(token);
    };
    if (options.read_time) |t| {
        try jw.objectField("readTime");
        try codec.writeTimestamp(jw, t);
    }
    try jw.endObject();
}
