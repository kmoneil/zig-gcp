//! auth logs under the scope `.gcp_auth`: where a token came from, its size
//! and lifetime, and failures. Never a token or any other secret. core's
//! logging module says how tests capture it.

const scoped = @import("core").logging.Scoped(.gcp_auth);

pub const debug = scoped.debug;
pub const warn = scoped.warn;
pub const capture = scoped.capture;
