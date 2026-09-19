//! Credentials for the other modules: turns "where am I running?" into a
//! bearer token. So far it holds `StaticToken`, and `Cache`, the token cache
//! that providers for the metadata server and gcloud's login will build on.

const core = @import("core");

pub const TokenProvider = core.TokenProvider;
pub const StaticToken = core.StaticToken;
pub const Cache = @import("Cache.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("Cache.zig");
    _ = @import("logging.zig");
}
