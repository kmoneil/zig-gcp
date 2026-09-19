//! What the Google Cloud modules share: the HTTP transport, the retry
//! policy, Google API errors and `Diagnostics`, `Owned` results, the
//! `TokenProvider` seam, and test helpers for code that uses them.
//! Applications rarely import this module directly; each service module
//! re-exports what its callers need.

/// The HTTP seam: implement `transport.Transport` to send requests another
/// way, or to fake the server in tests.
pub const transport = @import("transport.zig");

pub const RetryPolicy = @import("retry.zig").RetryPolicy;
pub const isRetryable = @import("retry.zig").isRetryable;

/// The Google API error body, status mapping and `Diagnostics`.
pub const errors = @import("errors.zig");
pub const ApiError = errors.ApiError;
pub const Diagnostics = errors.Diagnostics;

pub const Owned = @import("owned.zig").Owned;

/// The seam through which service modules get bearer tokens.
pub const TokenProvider = @import("TokenProvider.zig");
pub const StaticToken = @import("StaticToken.zig");

/// Logging under each module's own scope, captured in test builds.
pub const logging = @import("logging.zig");

/// Fakes and property-test helpers, for tests only.
pub const testing = @import("testing.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("StaticToken.zig");
    _ = @import("TokenProvider.zig");
    _ = @import("errors.zig");
    _ = @import("logging.zig");
    _ = @import("owned.zig");
    _ = @import("retry.zig");
    _ = @import("testing.zig");
    _ = @import("transport.zig");
}
