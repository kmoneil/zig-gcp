//! Runs one API call: core's request engine builds the URL, attaches
//! credentials, sends through the client's transport, maps failures to
//! errors, retries transient ones with jittered backoff, and keeps
//! `Diagnostics` and the log current. This file binds that engine to a
//! Secret Manager client and holds the checks its public calls share.

const std = @import("std");
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const errors = @import("errors.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const Error = errors.Error;

/// The OAuth scope the client asks its token provider for. It is the only
/// scope the API accepts.
pub const scope = "https://www.googleapis.com/auth/cloud-platform";

/// The shared engine, logging under this module's scope.
const Engine = core.rpc.Engine(.gcp_secret_manager);

pub const Call = core.rpc.Call;

/// The engine, filled in from one client's settings. There is no
/// unauthenticated mode: Secret Manager has no emulator.
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

/// Sends `call` and returns the body of the first 2xx response, which lives
/// in `response`.
pub fn execute(client: *Client, response: *std.heap.ArenaAllocator, call: Call) Error![]const u8 {
    return engine(client).execute(response, call);
}

/// `execute` for calls whose response body is not needed.
pub fn executeDiscard(client: *Client, call: Call) Error!void {
    return engine(client).executeDiscard(call);
}

/// The wait before an attempt this module retries itself, such as after a
/// checksum mismatch. The engine's own retries are its business.
pub fn backoffMs(client: *Client, attempt: u32) u32 {
    return client.retry.backoffMs(attempt, core.rpc.entropy(client.io));
}

/// Checks a secret id before any request.
pub fn checkSecretId(client: *Client, id: []const u8) Error!void {
    if (validate.isSecretId(id)) return;
    if (client.diagnostics) |d| d.print(
        "invalid secret id: ids are 1 to {d} characters from [A-Za-z0-9-_]",
        .{validate.max_id_len},
    );
    return error.InvalidResourceId;
}

/// Checks a version reference before any request.
pub fn checkRef(client: *Client, ref: types.VersionRef) Error!void {
    switch (ref) {
        .latest => {},
        .number => |n| if (n == 0) {
            if (client.diagnostics) |d| d.print("invalid version number: versions count from 1", .{});
            return error.InvalidResourceId;
        },
        .alias => |alias| if (!validate.isAlias(alias)) {
            if (client.diagnostics) |d| d.print(
                "invalid version alias: aliases are 1 to {d} characters from [A-Za-z0-9-_], and are neither a number nor \"latest\"",
                .{validate.max_id_len},
            );
            return error.InvalidResourceId;
        },
    }
}

/// Refuses `.latest` and aliases where only a number will do. Destroying is
/// irreversible, and production refuses `latest` for these three calls
/// anyway, with INVALID_ARGUMENT.
pub fn requireNumber(client: *Client, ref: types.VersionRef, what: []const u8) Error!u64 {
    switch (ref) {
        .number => |n| {
            try checkRef(client, ref);
            return n;
        },
        else => {
            if (client.diagnostics) |d| d.print(
                "{s} needs an explicit version number: \"whatever is latest right now\" is the wrong target for a lasting change",
                .{what},
            );
            return error.ExplicitVersionRequired;
        },
    }
}

/// Reports a 2xx body that did not decode.
pub fn decodeFailed(client: *Client, err: codec.DecodeError, what: []const u8) Error {
    if (err == error.InvalidResponse) {
        if (client.diagnostics) |d| d.print("the {s} response could not be decoded", .{what});
    }
    return err;
}
