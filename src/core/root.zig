//! What the Google Cloud modules share: the HTTP transport, the retry
//! policy, Google API errors and `Diagnostics`, `Owned` results, the
//! `TokenProvider` seam, and test helpers for code that uses them.
//! Applications rarely import this module directly; each service module
//! re-exports what its callers need.

/// The HTTP seam: implement `transport.Transport` to send requests another
/// way, or to fake the server in tests.
pub const transport = @import("transport.zig");

/// The request loop every service module runs: credentials, retries, error
/// mapping and diagnostics.
pub const rpc = @import("rpc.zig");

/// Resource-name rules more than one service needs.
pub const names = @import("names.zig");

/// Turning a configured endpoint into the base URL of every request.
pub const endpoint = @import("endpoint.zig");

/// Base64, as Google's JSON APIs carry `bytes` fields.
pub const base64 = @import("base64.zig");

/// `std.Io.Condition`, except that a canceled wait always reports the
/// cancel. std's can lose it, and then the task never ends.
pub const Condition = @import("Condition.zig");

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

/// An allocator that wipes memory before freeing it, for secrets.
pub const WipingAllocator = @import("WipingAllocator.zig");

/// A writer that counts what passes through it to another writer.
pub const CountingWriter = @import("CountingWriter.zig");

/// CRC-32C, the checksum Google sends beside payload bytes.
pub const crc32c = @import("crc32c.zig");

/// Percent-encoding for request paths, and a query-string builder.
pub const query = @import("query.zig");

/// Logging under each module's own scope, captured in test builds.
pub const logging = @import("logging.zig");

/// RFC 3339 timestamps, as Google's APIs send them.
pub const timestamp = @import("timestamp.zig");

/// Fakes and property-test helpers, for tests only.
pub const testing = @import("testing.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("CountingWriter.zig");
    _ = @import("StaticToken.zig");
    _ = @import("TokenProvider.zig");
    _ = @import("WipingAllocator.zig");
    _ = @import("base64.zig");
    _ = @import("crc32c.zig");
    _ = @import("endpoint.zig");
    _ = @import("errors.zig");
    _ = @import("logging.zig");
    _ = @import("names.zig");
    _ = @import("owned.zig");
    _ = @import("query.zig");
    _ = @import("rpc.zig");
    _ = @import("retry.zig");
    _ = @import("testing.zig");
    _ = @import("timestamp.zig");
    _ = @import("transport.zig");
}
