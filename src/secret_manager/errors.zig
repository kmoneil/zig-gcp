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
    /// Secret Manager cannot publish to a topic a create or update names:
    /// the topic does not exist, its message storage policy is enforced in
    /// transit, or the project's Secret Manager service agent, which
    /// `Client.serviceAgent` names, lacks `roles/pubsub.publisher` on it.
    /// HTTP 400 `FAILED_PRECONDITION` or 404 `NOT_FOUND`, told apart from
    /// other refusals by production's message; `Diagnostics` keeps it,
    /// and it says what to grant. A grant took effect within a second when
    /// measured; a deleted topic was still taken for a few minutes, from
    /// Pub/Sub's cache. Never retried.
    TopicNotPublishable,
    /// `Options.location` is not a Google Cloud location id.
    InvalidLocation,
    /// A success response could not be decoded. Never retried.
    InvalidResponse,
    /// There is no unauthenticated mode: set `Options.token_provider`.
    MissingCredentials,
    /// `Client.Options` holds an invalid retry policy or user agent.
    InvalidOptions,
};
