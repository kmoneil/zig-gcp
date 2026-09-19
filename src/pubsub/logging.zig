//! Pub/Sub logs under the scope `.gcp_pubsub`. core's logging module says
//! what may and may not be logged, and how tests capture it.

const scoped = @import("core").logging.Scoped(.gcp_pubsub);

pub const debug = scoped.debug;
pub const warn = scoped.warn;
pub const capture = scoped.capture;
