//! Secret Manager v1 REST client.
//!
//! `Client` holds the configuration and the connection pool; `Secret` and
//! `Version` are cheap handles on it. The headline call is `access`, which
//! fetches a version's bytes, verifies their checksum and hands them over in
//! memory that is wiped on release. Everything else is basic management of
//! secrets and their versions.
//!
//! There is no emulator and no unauthenticated mode: every client needs a
//! `TokenProvider`, which the `auth` module supplies.

const core = @import("core");

pub const Client = @import("Client.zig");
pub const Secret = @import("Secret.zig");
pub const Version = @import("Version.zig");
pub const SecretValue = @import("SecretValue.zig");

pub const TokenProvider = core.TokenProvider;
pub const StaticToken = core.StaticToken;
/// The OAuth scope the client requests from its `TokenProvider`. It is the
/// only scope the API accepts.
pub const auth_scope = @import("rpc.zig").scope;

pub const RetryPolicy = core.RetryPolicy;
pub const Diagnostics = core.Diagnostics;
pub const Error = @import("errors.zig").Error;
pub const ApiError = core.ApiError;

pub const Owned = @import("types.zig").Owned;
pub const ChecksumMode = @import("types.zig").ChecksumMode;
pub const Label = @import("types.zig").Label;
pub const ListOptions = @import("types.zig").ListOptions;
pub const Replication = @import("types.zig").Replication;
pub const SecretConfig = @import("types.zig").SecretConfig;
pub const SecretInfo = @import("types.zig").SecretInfo;
pub const SecretPage = @import("types.zig").SecretPage;
pub const State = @import("types.zig").State;
pub const VersionInfo = @import("types.zig").VersionInfo;
pub const VersionPage = @import("types.zig").VersionPage;
pub const VersionRef = @import("types.zig").VersionRef;

/// Parses a `create_time` (RFC 3339) to nanoseconds since the Unix epoch.
pub const parseTimestamp = core.timestamp.parse;

/// The fixed API limits and naming rules the client checks before sending.
pub const limits = @import("validate.zig");

/// The HTTP seam: implement `transport.Transport` to send requests another
/// way, or to fake the server in your own tests.
pub const transport = core.transport;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("Client.zig");
    _ = @import("SecretValue.zig");
    _ = @import("Version.zig");
    _ = @import("codec.zig");
    _ = @import("errors.zig");
    _ = @import("faults.zig");
    _ = @import("logging.zig");
    _ = @import("names.zig");
    _ = @import("rpc.zig");
    _ = @import("test_util.zig");
    _ = @import("types.zig");
    _ = @import("validate.zig");
}
