//! What the Google Cloud modules share: the HTTP transport, the retry
//! policy, and test helpers for code that uses them. Applications rarely
//! import this module directly; each service module re-exports what its
//! callers need.

/// The HTTP seam: implement `transport.Transport` to send requests another
/// way, or to fake the server in tests.
pub const transport = @import("transport.zig");

pub const RetryPolicy = @import("retry.zig").RetryPolicy;
pub const isRetryable = @import("retry.zig").isRetryable;

/// Fakes and property-test helpers, for tests only.
pub const testing = @import("testing.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("retry.zig");
    _ = @import("testing.zig");
    _ = @import("transport.zig");
}
