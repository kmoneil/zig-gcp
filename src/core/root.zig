//! What the Google Cloud modules share: the HTTP transport, and test helpers
//! for code that uses it. Applications rarely import this module directly;
//! each service module re-exports what its callers need.

/// The HTTP seam: implement `transport.Transport` to send requests another
/// way, or to fake the server in tests.
pub const transport = @import("transport.zig");

/// Fakes and property-test helpers, for tests only.
pub const testing = @import("testing.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("testing.zig");
    _ = @import("transport.zig");
}
