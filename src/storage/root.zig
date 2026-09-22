//! Cloud Storage JSON API client.
//!
//! `Client` holds the configuration and the connection pool; `Bucket` and
//! `Object` are cheap handles on it: buckets and object metadata, uploads
//! from memory or any reader, downloads that stream into any writer with
//! checksums verified, ranges, and mid-body resume pinned to one
//! generation, and signed URLs for clients that have no credentials.
//!
//! Against the `fake-gcs-server` emulator no credentials are needed: pass
//! `Endpoint.fromEnv(environ)` to honor `STORAGE_EMULATOR_HOST`.

const core = @import("core");

pub const Client = @import("Client.zig");
pub const Bucket = @import("Bucket.zig");
pub const Object = @import("Object.zig");
pub const Endpoint = @import("Endpoint.zig");

pub const TokenProvider = core.TokenProvider;
pub const StaticToken = core.StaticToken;
/// The OAuth scopes a client can request from its `TokenProvider`.
pub const Scope = @import("rpc.zig").Scope;

pub const RetryPolicy = core.RetryPolicy;
pub const Diagnostics = core.Diagnostics;
pub const Error = @import("errors.zig").Error;
pub const ApiError = core.ApiError;

pub const Owned = @import("types.zig").Owned;
pub const BucketConfig = @import("types.zig").BucketConfig;
pub const BucketInfo = @import("types.zig").BucketInfo;
pub const BucketPage = @import("types.zig").BucketPage;
pub const CopyOptions = @import("types.zig").CopyOptions;
pub const DeleteOptions = @import("types.zig").DeleteOptions;
pub const DownloadOptions = @import("types.zig").DownloadOptions;
pub const DownloadResult = @import("types.zig").DownloadResult;
pub const Downloaded = @import("types.zig").Downloaded;
pub const GetOptions = @import("types.zig").GetOptions;
pub const ListOptions = @import("types.zig").ListOptions;
pub const Metadata = @import("types.zig").Metadata;
pub const ObjectInfo = @import("types.zig").ObjectInfo;
pub const ObjectPage = @import("types.zig").ObjectPage;
pub const PageOptions = @import("types.zig").PageOptions;
pub const Preconditions = @import("types.zig").Preconditions;
pub const Range = @import("types.zig").Range;
pub const UploadOptions = @import("types.zig").UploadOptions;
pub const SignedUrlOptions = @import("types.zig").SignedUrlOptions;
pub const SignedMethod = @import("types.zig").SignedMethod;
pub const UrlStyle = @import("types.zig").UrlStyle;
pub const BucketBound = @import("types.zig").BucketBound;
pub const QueryParam = @import("types.zig").QueryParam;
pub const Header = @import("types.zig").Header;

/// What signs a signed URL as a service account: `auth.Credentials.signer()`
/// for whatever the environment has, `auth.ServiceAccount.signer()` for a key
/// file, or `auth.IamSigner` for any account a token may sign as.
pub const Signer = core.Signer;

/// Parses a `time_created` (RFC 3339) to nanoseconds since the Unix epoch.
pub const parseTimestamp = core.timestamp.parse;

/// The naming rules the client checks before sending.
pub const limits = @import("validate.zig");

/// The HTTP seam: implement `transport.Transport` to send requests another
/// way, or to fake the server in your own tests.
pub const transport = core.transport;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("Bucket.zig");
    _ = @import("Client.zig");
    _ = @import("Endpoint.zig");
    _ = @import("Object.zig");
    _ = @import("codec.zig");
    _ = @import("download.zig");
    _ = @import("errors.zig");
    _ = @import("multipart.zig");
    _ = @import("logging.zig");
    _ = @import("names.zig");
    _ = @import("resumable.zig");
    _ = @import("rpc.zig");
    _ = @import("signing.zig");
    _ = @import("test_util.zig");
    _ = @import("types.zig");
    _ = @import("validate.zig");
}
