//! Credentials for the other modules: turns "where am I running?" into a
//! bearer token. `MetadataServer` for a workload on Google Cloud,
//! `AuthorizedUser` for the login `gcloud` saves, `ServiceAccount` for a
//! service account key file, `ExternalAccount` for workload identity
//! federation, `ImpersonatedServiceAccount` for a login that acts as a
//! service account, `StaticToken` for a token from somewhere else, and
//! `Cache`, which the providers share. For signed URLs, a key file, an
//! impersonating login and the metadata server can also sign, and
//! `IamSigner` signs through IAM with any token allowed to.

const core = @import("core");

pub const TokenProvider = core.TokenProvider;
pub const Signer = core.Signer;
pub const StaticToken = core.StaticToken;
pub const Diagnostics = core.Diagnostics;
pub const RetryPolicy = core.RetryPolicy;
pub const Cache = @import("Cache.zig");
pub const AuthorizedUser = @import("AuthorizedUser.zig");
pub const ServiceAccount = @import("ServiceAccount.zig");
pub const ExternalAccount = @import("ExternalAccount.zig");
pub const ImpersonatedServiceAccount = @import("ImpersonatedServiceAccount.zig");
pub const IamSigner = @import("IamSigner.zig");
pub const MetadataServer = @import("MetadataServer.zig");
pub const Lookup = @import("Lookup.zig");
pub const Credentials = @import("Credentials.zig");
/// The credentials this environment points at: the file
/// `GOOGLE_APPLICATION_CREDENTIALS` names, the file gcloud's login wrote,
/// or the metadata server, in that order.
pub const findDefault = Credentials.find;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("AuthorizedUser.zig");
    _ = @import("ServiceAccount.zig");
    _ = @import("ExternalAccount.zig");
    _ = @import("ImpersonatedServiceAccount.zig");
    _ = @import("IamSigner.zig");
    _ = @import("MetadataServer.zig");
    _ = @import("rsa.zig");
    _ = @import("Lookup.zig");
    _ = @import("Credentials.zig");
    _ = @import("Cache.zig");
    _ = @import("adc_file.zig");
    _ = @import("form.zig");
    _ = @import("iam_credentials.zig");
    _ = @import("logging.zig");
    _ = @import("token_response.zig");
}
