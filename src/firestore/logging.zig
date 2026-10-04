//! Firestore logs under the scope `.gcp_firestore`: methods, paths,
//! statuses and timings, never field values or a bearer token. core's
//! logging module says how tests capture what would have been logged.

const scoped = @import("core").logging.Scoped(.gcp_firestore);

pub const debug = scoped.debug;
pub const warn = scoped.warn;
pub const capture = scoped.capture;
