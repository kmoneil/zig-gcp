//! `Error`: every error a Pub/Sub call can return. The API statuses, their
//! mapping and `Diagnostics` live in core.

const core = @import("core");
const TokenError = core.TokenProvider.Error;

/// Every error a client call can return.
pub const Error = core.ApiError || core.transport.Error || TokenError || error{
    /// A message breaks a documented limit or rule. `Diagnostics` says which.
    InvalidMessage,
    /// A topic, subscription or project id breaks the naming rules.
    InvalidResourceId,
    /// A success response could not be decoded. Never retried.
    InvalidResponse,
    /// The endpoint needs credentials and no token provider was set.
    MissingCredentials,
    /// `Client.Options` holds an invalid retry policy or user agent.
    InvalidOptions,
};
