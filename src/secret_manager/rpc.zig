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

/// How Secret Manager begins its refusal of a write whose etag is not the
/// resource's, measured on 2026-10-02: a 400 `FAILED_PRECONDITION`, the
/// status a disabled version, a destroyed one and a KMS failure also get,
/// so only this message tells it apart.
const stale_etag = "The etag provided in the request does not match";

/// Whether a failed call was refused for a stale etag.
pub fn isStaleEtag(err: anyerror, diag: *const core.Diagnostics) bool {
    return err == error.FailedPrecondition and std.mem.startsWith(u8, diag.message(), stale_etag);
}

/// `execute` for a call sent under an etag: a stale one is `error.Aborted`,
/// as a stale IAM write is on every resource, and every other failure is
/// what it was.
pub fn executeConditional(client: *Client, response: *std.heap.ArenaAllocator, call: Call) Error![]const u8 {
    var local: core.Diagnostics = .{};
    const e = engineWith(client, &local);
    return e.execute(response, call) catch |err| {
        if (isStaleEtag(err, e.diagnostics.?)) return error.Aborted;
        return err;
    };
}

/// `executeConditional` for calls whose response body is not needed.
pub fn executeDiscardConditional(client: *Client, call: Call) Error!void {
    var local: core.Diagnostics = .{};
    const e = engineWith(client, &local);
    return e.executeDiscard(call) catch |err| {
        if (isStaleEtag(err, e.diagnostics.?)) return error.Aborted;
        return err;
    };
}

/// The engine, with `local` standing in for the caller's diagnostics when
/// there are none, so the server's message can still be read.
fn engineWith(client: *Client, local: *core.Diagnostics) Engine {
    var e = engine(client);
    if (e.diagnostics == null) e.diagnostics = local;
    return e;
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
                "invalid version alias: aliases are 1 to {d} characters, a letter and then letters, digits, '-' and '_', and neither \"latest\" nor \"NEW\"",
                .{validate.max_alias_len},
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

/// Checks a secret's configuration before it is encoded: labels,
/// annotations, expiry and the destruction delay as production holds them
/// (and valid UTF-8, because JSON strings are and `std.json.Stringify`
/// does not check), and a user-managed replication must name locations.
pub fn checkConfig(client: *Client, config: types.SecretConfig) Error!void {
    try checkLabels(client, config.labels);
    try checkAnnotations(client, config.annotations);
    if (config.expiry) |expiry| try checkExpiry(client, expiry);
    if (config.version_destroy_delay_s) |s| try checkDestroyDelay(client, s);
    // A regional secret sends no replication at all, so there is nothing
    // there to check.
    if (client.location != null) return;
    switch (config.replication) {
        .automatic => {},
        .user_managed => |locations| {
            if (locations.len == 0) {
                if (client.diagnostics) |d| d.print(
                    "invalid replication: user-managed replication needs at least one location",
                    .{},
                );
                return error.InvalidArgument;
            }
            for (locations) |location| {
                if (validate.isLocation(location)) continue;
                if (client.diagnostics) |d| d.print(
                    "invalid replication location: expected a location id such as \"europe-west1\"",
                    .{},
                );
                return error.InvalidLocation;
            }
        },
    }
}

/// Checks an update before it is encoded: something must change, since
/// production answers an empty mask by changing nothing and still moving
/// the etag and publishing an event; and what changes is checked as on
/// create, aliases included.
pub fn checkUpdate(client: *Client, changes: types.SecretUpdate) Error!void {
    if (changes.isEmpty()) {
        if (client.diagnostics) |d| d.print("an update needs at least one change", .{});
        return error.InvalidArgument;
    }
    switch (changes.labels) {
        .set => |labels| try checkLabels(client, labels),
        .keep, .clear => {},
    }
    switch (changes.annotations) {
        .set => |annotations| try checkAnnotations(client, annotations),
        .keep, .clear => {},
    }
    switch (changes.aliases) {
        .set => |aliases| try checkAliases(client, aliases),
        .keep, .clear => {},
    }
    switch (changes.expiry) {
        .set => |expiry| try checkExpiry(client, expiry),
        .keep, .clear => {},
    }
    switch (changes.version_destroy_delay_s) {
        .set => |s| try checkDestroyDelay(client, s),
        .keep, .clear => {},
    }
    if (changes.etag) |etag| try checkEtag(client, etag);
}

/// An etag to send as a condition. Production takes `""` as no etag at
/// all, which is not what a caller who passed one meant.
pub fn checkEtag(client: *Client, etag: []const u8) Error!void {
    if (etag.len > 0 and std.unicode.utf8ValidateSlice(etag)) return;
    if (client.diagnostics) |d| d.print("an etag to send as a condition is the one a read returned, never empty", .{});
    return error.InvalidArgument;
}

fn checkLabels(client: *Client, labels: []const types.Label) Error!void {
    if (labels.len > validate.max_labels) return refuse(client, "a secret holds at most {d} labels", .{validate.max_labels});
    for (labels, 1..) |label, n| {
        if (validate.labelKeyProblem(label.key)) |problem| return refuse(client, "label {d}: {s}", .{ n, problem });
        if (validate.labelValueProblem(label.value)) |problem| return refuse(client, "label {d}: {s}", .{ n, problem });
        for (labels[0 .. n - 1], 1..) |earlier, m| {
            if (std.mem.eql(u8, earlier.key, label.key)) return refuse(client, "labels {d} and {d} have the same key", .{ m, n });
        }
    }
}

fn checkAnnotations(client: *Client, annotations: []const types.Annotation) Error!void {
    var total: usize = 0;
    for (annotations, 1..) |a, n| {
        if (!validate.isAnnotationKey(a.key)) return refuse(
            client,
            "annotation {d}: a key is 1 to {d} ASCII letters and digits, with '.', '_' and '-' between them",
            .{ n, validate.max_annotation_key_len },
        );
        if (!std.unicode.utf8ValidateSlice(a.value)) return refuse(client, "annotation {d}: values must be valid UTF-8", .{n});
        for (annotations[0 .. n - 1], 1..) |earlier, m| {
            if (std.mem.eql(u8, earlier.key, a.key)) return refuse(client, "annotations {d} and {d} have the same key", .{ m, n });
        }
        total += a.key.len + a.value.len;
    }
    if (total > validate.max_annotation_bytes) return refuse(
        client,
        "a secret's annotations hold at most {d} bytes, keys and values together",
        .{validate.max_annotation_bytes},
    );
}

fn checkAliases(client: *Client, aliases: []const types.Alias) Error!void {
    if (aliases.len > validate.max_aliases) return refuse(client, "a secret holds at most {d} aliases", .{validate.max_aliases});
    for (aliases, 1..) |a, n| {
        if (!validate.isAlias(a.name)) return refuse(
            client,
            "alias {d}: a name is 1 to {d} characters, a letter and then letters, digits, '-' and '_', and neither \"latest\" nor \"NEW\"",
            .{ n, validate.max_alias_len },
        );
        if (a.version == 0) return refuse(client, "alias {d}: versions count from 1", .{n});
        for (aliases[0 .. n - 1], 1..) |earlier, m| {
            if (std.mem.eql(u8, earlier.name, a.name)) return refuse(client, "aliases {d} and {d} have the same name", .{ m, n });
        }
    }
}

fn checkExpiry(client: *Client, expiry: types.Expiry) Error!void {
    switch (expiry) {
        // Whether the time is far enough ahead is the server's to judge:
        // its clock decides.
        .at => |time| _ = core.timestamp.parse(time) catch
            return refuse(client, "an expiry time is RFC 3339, such as 2027-01-01T00:00:00Z", .{}),
        .after_s => |s| if (s < validate.min_expiry_s or s > validate.max_expiry_s) return refuse(
            client,
            "a secret expires {d} to {d} seconds from now",
            .{ validate.min_expiry_s, validate.max_expiry_s },
        ),
    }
}

fn checkDestroyDelay(client: *Client, s: u64) Error!void {
    if (s >= validate.min_destroy_delay_s and s <= validate.max_destroy_delay_s) return;
    return refuse(
        client,
        "a destroyed version waits {d} to {d} seconds (1 to 1,000 days)",
        .{ validate.min_destroy_delay_s, validate.max_destroy_delay_s },
    );
}

fn refuse(client: *Client, comptime fmt: []const u8, args: anytype) Error {
    if (client.diagnostics) |d| d.print(fmt, args);
    return error.InvalidArgument;
}

/// Reports a 2xx body that did not decode.
pub fn decodeFailed(client: *Client, err: codec.DecodeError, what: []const u8) Error {
    if (err == error.InvalidResponse) {
        if (client.diagnostics) |d| d.print("the {s} response could not be decoded", .{what});
    }
    return err;
}
