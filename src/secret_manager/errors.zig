//! `Error`: every error a Secret Manager call can return. The API statuses,
//! their mapping and `Diagnostics` live in core.

const core = @import("core");

/// Every error a client call can return.
pub const Error = core.rpc.Error || error{
    /// The bytes received do not match the checksum received with them,
    /// after every retry. The bytes are wiped, never returned.
    ChecksumMismatch,
    /// `verify_checksum` is `.required` and the version has no checksum.
    MissingChecksum,
    /// `enable`, `disable` or `destroy` was asked for `.latest` or an alias.
    /// These are irreversible or lasting, so they take a version number.
    ExplicitVersionRequired,
    /// `addVersion` was given more than `limits.max_payload_bytes`.
    PayloadTooLarge,
    /// `addVersion` was given nothing to store.
    EmptyPayload,
    /// A secret id or version alias breaks the naming rules.
    InvalidResourceId,
    /// `Options.location` is not a Google Cloud location id.
    InvalidLocation,
    /// A success response could not be decoded. Never retried.
    InvalidResponse,
    /// There is no unauthenticated mode: set `Options.token_provider`.
    MissingCredentials,
    /// `Client.Options` holds an invalid retry policy or user agent.
    InvalidOptions,
};
