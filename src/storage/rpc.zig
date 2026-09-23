//! Runs one API call: core's request engine builds the URL, attaches
//! credentials, sends through the client's transport, maps failures to
//! errors, retries transient ones with jittered backoff, and keeps
//! `Diagnostics` and the log current. This file binds that engine to a
//! Cloud Storage client and holds the checks its public calls share.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
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

/// Starts a public call: `Diagnostics` describe only the latest call.
pub fn begin(client: *Client) void {
    engine(client).begin();
}

/// Sends `call` and returns the body of the first 2xx response, which lives
/// in `response`.
pub fn execute(client: *Client, response: *std.heap.ArenaAllocator, call: Call) Error![]const u8 {
    return engine(client).execute(response, call);
}

/// `execute` for calls whose response body is not needed.
pub fn executeDiscard(client: *Client, call: Call) Error!void {
    return engine(client).executeDiscard(call);
}

pub const StreamCall = core.rpc.StreamCall;

/// Sends a streaming call and returns the first 2xx response whole:
/// status, headers, and the body, buffered or delivered to the sink.
pub fn executeStream(
    client: *Client,
    response: *std.heap.ArenaAllocator,
    call: StreamCall,
) core.rpc.StreamCallError!core.transport.StreamResponse {
    return engine(client).executeStream(response, call);
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

/// The project for bucket create and list, which address no bucket yet.
pub fn requireProject(client: *Client) Error![]const u8 {
    return client.project_id orelse {
        if (client.diagnostics) |d| d.print("bucket create and list need Options.project_id", .{});
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
