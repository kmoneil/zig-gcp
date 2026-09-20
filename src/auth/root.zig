//! Credentials for the other modules: turns "where am I running?" into a
//! bearer token. `MetadataServer` for a workload on Google Cloud,
//! `AuthorizedUser` for the login `gcloud` saves, `StaticToken` for a token
//! from somewhere else, and `Cache`, which the first two share.

const core = @import("core");

pub const TokenProvider = core.TokenProvider;
pub const StaticToken = core.StaticToken;
pub const Diagnostics = core.Diagnostics;
pub const RetryPolicy = core.RetryPolicy;
pub const Cache = @import("Cache.zig");
pub const AuthorizedUser = @import("AuthorizedUser.zig");
pub const MetadataServer = @import("MetadataServer.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("AuthorizedUser.zig");
    _ = @import("MetadataServer.zig");
    _ = @import("Cache.zig");
    _ = @import("adc_file.zig");
    _ = @import("form.zig");
    _ = @import("logging.zig");
    _ = @import("token_response.zig");
}
