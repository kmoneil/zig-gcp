//! Secret Manager logs under the scope `.gcp_secret_manager`: methods,
//! resource names, statuses and timings. Never a secret's bytes, their
//! length or their checksum, and never a bearer token. core's logging module
//! says how tests capture what would have been logged.

const scoped = @import("core").logging.Scoped(.gcp_secret_manager);

pub const debug = scoped.debug;
pub const warn = scoped.warn;
pub const capture = scoped.capture;
