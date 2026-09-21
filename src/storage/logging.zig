//! Cloud Storage logs under the scope `.gcp_storage`: methods, bucket and
//! object names, statuses, byte counts and timings. Never a bearer token, a
//! resumable session URI, or an object's bytes. core's logging module says
//! how tests capture what would have been logged.

const scoped = @import("core").logging.Scoped(.gcp_storage);

pub const debug = scoped.debug;
pub const warn = scoped.warn;
pub const capture = scoped.capture;
