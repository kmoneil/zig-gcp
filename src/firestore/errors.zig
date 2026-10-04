//! `Error`: every error a Firestore call can return. The API statuses,
//! their mapping and `Diagnostics` live in core.

const core = @import("core");

/// Every error a client call can return.
pub const Error = core.rpc.Error || error{
    /// A path, id, database id or field path breaks Firestore's naming
    /// rules, or a handle was derived past `names.max_path_parts`.
    InvalidResourceId,
    /// The endpoint is not plain `http` or `https` with a host, or one that
    /// would receive credentials is not `https`.
    InvalidEndpoint,
    /// A success response could not be decoded. Never retried.
    InvalidResponse,
    /// Only an emulator endpoint works without `Options.token_provider`.
    MissingCredentials,
    /// `Client.Options` holds an invalid retry policy or user agent.
    InvalidOptions,
};
