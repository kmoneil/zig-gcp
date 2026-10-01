//! Runs one API call: core's request engine builds the URL, attaches
//! credentials, sends through the client's transport, maps failures to
//! errors, retries transient ones with jittered backoff, and keeps
//! `Diagnostics` and the log current. This file binds that engine to a
//! Cloud Storage client and holds the checks its public calls share.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const retention = @import("retention.zig");
const validate = @import("validate.zig");
const Error = errors.Error;

/// The OAuth scopes a client can ask its token provider for.
pub const Scope = enum {
    /// Read and write objects and buckets. The default.
    read_write,
    /// Read objects and buckets only.
    read_only,
    /// The broad scope, for credentials already fixed to it.
    cloud_platform,

    pub fn url(self: Scope) []const u8 {
        return switch (self) {
            .read_write => "https://www.googleapis.com/auth/devstorage.read_write",
            .read_only => "https://www.googleapis.com/auth/devstorage.read_only",
            .cloud_platform => "https://www.googleapis.com/auth/cloud-platform",
        };
    }
};

/// The shared engine, logging under this module's scope.
const Engine = core.rpc.Engine(.gcp_storage);

pub const Call = core.rpc.Call;

/// The engine, filled in from one client's settings. An emulator endpoint
/// never receives credentials.
fn engine(client: *Client) Engine {
    return .{
        .gpa = client.gpa,
        .io = client.io,
        .transport = client.transport,
        .base_url = client.base_url,
        .auth_scope = client.scope.url(),
        .token_provider = client.token_provider,
        .unauthenticated = client.unauthenticated,
        .send_quota_project = client.send_quota_project,
        .retry = client.retry,
        .request_timeout_ms = client.request_timeout_ms,
        .diagnostics = client.diagnostics,
    };
}

/// The engine for one request, with diagnostics of its own when the client
/// keeps none: whether a refusal is `ObjectRetained` is read from them.
fn engineWith(client: *Client, local: *core.Diagnostics) Engine {
    var e = engine(client);
    if (e.diagnostics == null) e.diagnostics = local;
    return e;
}

/// Whether a failed request was refused for a retained or held object.
fn retained(e: Engine, err: anyerror) bool {
    return retention.isRetained(err, e.diagnostics.?);
}

/// What became of an object a failed upload deleted again, for the
/// diagnostics that report the failure.
pub const Cleanup = enum {
    deleted,
    /// Cloud Storage keeps it: its bucket's retention policy, or a hold.
    kept,
    /// The delete failed any other way.
    left,
    /// Nothing was deleted: there was no generation to pin a delete to,
    /// and one without could take another writer's newer object.
    unpinned,

    pub fn of(result: Error!void) Cleanup {
        _ = result catch |err| return if (err == error.ObjectRetained) .kept else .left;
        return .deleted;
    }

    /// How the report of the failure ends.
    pub fn words(self: Cleanup) []const u8 {
        return switch (self) {
            .deleted => "; the object was deleted again",
            .kept => "; the object stays, kept by its bucket's retention policy or a hold",
            .left => "; the object could not be deleted again",
            .unpinned => "; the answer named no generation to pin a delete to, so the object was left alone",
        };
    }
};

/// Starts a public call: `Diagnostics` describe only the latest call.
pub fn begin(client: *Client) void {
    engine(client).begin();
}

/// A copy of `client` that bills `project` for one call. Every request the
/// call makes through this module then carries it: a JSON API request as
/// the `userProject` parameter and the `x-goog-user-project` header, an XML
/// API request as the header, one value in both, so they never disagree
/// (Cloud Storage goes by the parameter where they do). The copy owns
/// nothing, must not outlive `client`, and is never deinited.
pub fn billed(client: *const Client, project: ?[]const u8) Client {
    var copy = client.*;
    copy.billing_project = project;
    return copy;
}

/// Checks a handle's billing project before any request.
pub fn checkBillingProject(client: *Client, project: ?[]const u8) Error!void {
    const p = project orelse return;
    if (core.names.isProjectId(p)) return;
    if (client.diagnostics) |d| d.print("the billing project is not a project id or number", .{});
    return error.InvalidArgument;
}

/// `path` with the call's billing project appended as `userProject`, in
/// `gpa`'s memory for the caller to free, or null without one. No path
/// sent through here names one already: a resumable session's URL, which
/// does, goes to the transport directly, with no credentials and no
/// header.
fn billedPath(client: *Client, path: []const u8) Allocator.Error!?[]u8 {
    const project = client.billing_project orelse return null;
    var out: Writer.Allocating = .init(client.gpa);
    errdefer out.deinit();
    const w = &out.writer;
    w.writeAll(path) catch return error.OutOfMemory;
    w.writeByte(if (std.mem.indexOfScalar(u8, path, '?') == null) '?' else '&') catch return error.OutOfMemory;
    w.writeAll("userProject=") catch return error.OutOfMemory;
    core.query.writeValue(w, project) catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

/// A requester pays refusal of a call that named no project to bill says
/// how to name one.
fn hintBilling(client: *Client, err: anyerror) void {
    if (err != error.InvalidArgument or client.billing_project != null) return;
    const d = client.diagnostics orelse return;
    if (std.ascii.indexOfIgnoreCase(d.message(), "requester pays") == null) return;
    var status_buf: [core.Diagnostics.max_status_len]u8 = undefined;
    const status_text = d.status();
    @memcpy(status_buf[0..status_text.len], status_text);
    d.set(d.http_status, status_buf[0..status_text.len], "the bucket has requester pays on and this request named no project to bill: Bucket.withBillingProject or Object.withBillingProject names one");
}

/// A refusal that a customer-supplied key, or a grant on a Cloud KMS key,
/// would have avoided says so. An object under a customer key refuses a
/// request that carries none with 400, "The target object is encrypted by
/// a customer-supplied encryption key." (the XML API: "The resource is
/// encrypted with a customer encryption key."); a write under a KMS key
/// whose grant is missing, or that does not exist, is 403 "Permission
/// denied on Cloud KMS key".
fn hintKeys(client: *Client, err: anyerror) void {
    const d = client.diagnostics orelse return;
    const message = d.message();
    const keyless = err == error.InvalidArgument and client.encryption_key == null and
        (std.ascii.indexOfIgnoreCase(message, "is encrypted by a customer-supplied") != null or
            std.ascii.indexOfIgnoreCase(message, "is encrypted with a customer encryption key") != null);
    const ungranted = err == error.PermissionDenied and std.ascii.indexOfIgnoreCase(message, "Cloud KMS key") != null;
    const message_hint = if (keyless)
        "the object is encrypted with a customer-supplied key, and this request carried none: Object.withEncryptionKey gives it"
    else if (ungranted)
        "permission denied on the Cloud KMS key: it must exist in the bucket's location, and the project's Cloud Storage service agent, which Client.serviceAgent names, needs roles/cloudkms.cryptoKeyEncrypterDecrypter on it"
    else
        return;
    var status_buf: [core.Diagnostics.max_status_len]u8 = undefined;
    const status_text = d.status();
    @memcpy(status_buf[0..status_text.len], status_text);
    d.set(d.http_status, status_buf[0..status_text.len], message_hint);
}

/// What a failed call's diagnostics add: how to bill a project, or which
/// key was missing.
fn hint(client: *Client, err: anyerror) void {
    hintBilling(client, err);
    hintKeys(client, err);
}

/// Sends a JSON API call and returns the body of the first 2xx response,
/// which lives in `response`.
pub fn execute(client: *Client, response: *std.heap.ArenaAllocator, call: Call) Error![]const u8 {
    const path = try billedPath(client, call.path);
    defer if (path) |p| client.gpa.free(p);
    var billed_call = call;
    if (path) |p| billed_call.path = p;
    if (billed_call.quota_project == null) billed_call.quota_project = client.billing_project;
    var local: core.Diagnostics = .{};
    const e = engineWith(client, &local);
    return e.execute(response, billed_call) catch |err| {
        hint(client, err);
        if (retained(e, err)) return error.ObjectRetained;
        return err;
    };
}

/// `execute` for calls whose response body is not needed.
pub fn executeDiscard(client: *Client, call: Call) Error!void {
    const path = try billedPath(client, call.path);
    defer if (path) |p| client.gpa.free(p);
    var billed_call = call;
    if (path) |p| billed_call.path = p;
    if (billed_call.quota_project == null) billed_call.quota_project = client.billing_project;
    var local: core.Diagnostics = .{};
    const e = engineWith(client, &local);
    return e.executeDiscard(billed_call) catch |err| {
        hint(client, err);
        if (retained(e, err)) return error.ObjectRetained;
        return err;
    };
}

pub const StreamCall = core.rpc.StreamCall;
pub const StreamCallError = core.rpc.StreamCallError || error{ObjectRetained};
pub const StreamBodyError = core.rpc.StreamBodyError || error{ObjectRetained};

/// Sends a streaming JSON API call and returns the first 2xx response
/// whole: status, headers, and the body, buffered or delivered to the sink.
pub fn executeStream(
    client: *Client,
    response: *std.heap.ArenaAllocator,
    call: StreamCall,
) StreamCallError!core.transport.StreamResponse {
    const path = try billedPath(client, call.path);
    defer if (path) |p| client.gpa.free(p);
    var billed_call = call;
    if (path) |p| billed_call.path = p;
    if (billed_call.quota_project == null) billed_call.quota_project = client.billing_project;
    var local: core.Diagnostics = .{};
    const e = engineWith(client, &local);
    return e.executeStream(response, billed_call) catch |err| {
        hint(client, err);
        if (retained(e, err)) return error.ObjectRetained;
        return err;
    };
}

/// `executeStream` for the XML API, which takes the billing project as the
/// header alone.
pub fn executeXml(
    client: *Client,
    response: *std.heap.ArenaAllocator,
    call: StreamCall,
) StreamCallError!core.transport.StreamResponse {
    var billed_call = call;
    if (billed_call.quota_project == null) billed_call.quota_project = client.billing_project;
    var local: core.Diagnostics = .{};
    const e = engineWith(client, &local);
    return e.executeStream(response, billed_call) catch |err| {
        hint(client, err);
        if (retained(e, err)) return error.ObjectRetained;
        return err;
    };
}

/// `executeXml` with the body read once from a stream: a transient failure
/// comes back for the caller to try again with a fresh reader.
pub fn executeXmlBody(
    client: *Client,
    response: *std.heap.ArenaAllocator,
    call: StreamCall,
    body: core.rpc.StreamBody,
) StreamBodyError!core.transport.StreamResponse {
    var billed_call = call;
    if (billed_call.quota_project == null) billed_call.quota_project = client.billing_project;
    var local: core.Diagnostics = .{};
    const e = engineWith(client, &local);
    return e.executeStreamBody(response, billed_call, body) catch |err| {
        hint(client, err);
        if (retained(e, err)) return error.ObjectRetained;
        return err;
    };
}

/// The wait before an attempt this module retries itself, such as a
/// download restarted from scratch. The engine's own retries are its
/// business.
pub fn backoffMs(client: *Client, attempt: u32) u32 {
    return client.retry.backoffMs(attempt, core.rpc.entropy(client.io));
}

/// Checks a bucket name before any request.
pub fn checkBucketName(client: *Client, name: []const u8) Error!void {
    if (validate.isBucketName(name)) return;
    if (client.diagnostics) |d| d.print("invalid bucket name: names are not empty and carry no slash and no whitespace", .{});
    return error.InvalidBucketName;
}

/// Checks an object name before any request.
pub fn checkObjectName(client: *Client, name: []const u8) Error!void {
    if (validate.isObjectName(name)) return;
    if (client.diagnostics) |d| d.print(
        "invalid object name: names are 1 to {d} bytes of UTF-8 without CR or LF, and are not \".\" or \"..\"",
        .{validate.max_object_name_len},
    );
    return error.InvalidObjectName;
}

/// The project for bucket create and list, and the service agent, which
/// address no bucket.
pub fn requireProject(client: *Client) Error![]const u8 {
    return client.project_id orelse {
        if (client.diagnostics) |d| d.print("bucket create and list, and the service agent, need Options.project_id", .{});
        return error.MissingProject;
    };
}

/// A 412 on a call that may have been retried is ambiguous: an earlier
/// attempt may have landed, and the repeat then failed its own
/// precondition against the object it just created. The diagnostics say
/// so, so the caller can `get` the object and compare checksums.
pub fn ambiguous412(client: *Client, retried: bool) Error {
    if (retried) replace412(client, "the precondition failed; if this call was a retry, an earlier attempt may have succeeded: get the object and compare checksums");
    return error.FailedPrecondition;
}

/// Replaces a 412's message with `message`, keeping the server's status.
/// `Diagnostics.set` forbids pointers into its own buffer, so the status
/// is copied out first.
pub fn replace412(client: *Client, message: []const u8) void {
    const d = client.diagnostics orelse return;
    var status_buf: [core.Diagnostics.max_status_len]u8 = undefined;
    const status_text = d.status();
    @memcpy(status_buf[0..status_text.len], status_text);
    d.set(412, status_buf[0..status_text.len], message);
}

/// Reports a 2xx body that did not decode.
pub fn decodeFailed(client: *Client, err: codec.DecodeError, what: []const u8) Error {
    if (err == error.InvalidResponse) {
        if (client.diagnostics) |d| d.print("the {s} response could not be decoded", .{what});
    }
    return err;
}
