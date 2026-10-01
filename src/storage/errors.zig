//! `Error`: every error a Cloud Storage call can return. The HTTP statuses,
//! their mapping and `Diagnostics` live in core.
//!
//! Storage error bodies carry no canonical status string, so the HTTP code
//! decides the error and `Diagnostics.status` keeps the server's `reason`,
//! such as "notFound". The canonical names apply: a bucket name that is
//! taken, and a bucket that is not empty on delete, are both
//! `error.AlreadyExists` (HTTP 409), and a failed generation precondition is
//! `error.FailedPrecondition` (HTTP 412). One 403 is told apart by its
//! reason and message: an object kept by retention or a hold is
//! `error.ObjectRetained`, not `error.PermissionDenied`.

const core = @import("core");

/// Every error a client call can return. `core.Signer.Error` adds
/// `SigningRejected` and `SigningFailed`, which only `signedUrl` returns.
pub const Error = core.rpc.Error || core.Signer.Error || error{
    /// Upload or download bytes do not match the checksum beside them, or
    /// a compressed upload's bytes do not decompress to its data. On upload
    /// nothing is left stored; on download the data is discarded.
    ChecksumMismatch,
    /// An object whose metadata says `Content-Encoding: gzip` holds stored
    /// bytes that met the stored checksum and do not decompress: Cloud
    /// Storage never checks that an object is what its encoding says.
    /// `DownloadOptions.decompress = false` downloads the bytes as they are.
    DecompressionFailed,
    /// `downloadAlloc` met an object larger than its `max_bytes`, or
    /// `downloadParallel` one larger than the buffer it was given.
    ObjectTooLarge,
    /// The caller's writer failed during a download, with the detail
    /// wherever that concrete writer keeps it. Whatever it holds by then
    /// must be discarded.
    WriteFailed,
    /// Cloud Storage is keeping the object: under its bucket's retention
    /// policy until the time `Diagnostics` names, or under a hold until it
    /// is released. Deleting it, replacing it by upload, compose or copy,
    /// and moving it are refused; its metadata stays editable. HTTP 403,
    /// told apart from a missing permission by the reason and message
    /// Cloud Storage sends. Never retried.
    ObjectRetained,
    /// Cloud Storage cannot publish to a notification configuration's
    /// topic: it does not exist, or the project's Cloud Storage service
    /// agent, which `Client.serviceAgent` names, lacks
    /// `roles/pubsub.publisher` on it. HTTP 403 `forbidden` or 400
    /// `invalid`, told apart from other refusals by Cloud Storage's
    /// message; `Diagnostics` says what to grant. A fresh grant took a few
    /// seconds to apply when measured. Never retried.
    TopicNotPublishable,
    /// A resumable session vanished (HTTP 404 or 410 on its URI) and the
    /// source cannot be replayed. The caller reopens the source and
    /// retries; `upload` starts a new session itself, since its bytes are
    /// still in memory.
    UploadSessionLost,
    /// The caller's reader failed during an upload, with the detail
    /// wherever that concrete reader keeps it (the session was cancelled),
    /// or a resumed transfer could not read back what its file already
    /// held to rebuild the checksums.
    ReadFailed,
    /// `uploadFrom` was given `size`, and the reader ended early.
    UnexpectedEndOfStream,
    /// `uploadFrom` was given `size`, and the reader had more.
    StreamTooLong,
    /// `Options.chunk_size` is zero or not a multiple of 256 KiB.
    InvalidChunkSize,
    /// An object name breaks the rules: empty, over 1,024 bytes, invalid
    /// UTF-8, a carriage return or line feed, or `.` or `..`.
    InvalidObjectName,
    /// A bucket name breaks the rules: empty, a slash, or whitespace.
    InvalidBucketName,
    /// Bucket create or list needs `Options.project_id`.
    MissingProject,
    /// A production endpoint needs `Options.token_provider`; only an
    /// emulator works without one.
    MissingCredentials,
    /// A success response could not be decoded. Never retried.
    InvalidResponse,
    /// `Client.Options` holds an invalid retry policy or user agent.
    InvalidOptions,
    /// A signed URL's options break a rule: an expiry out of range, a
    /// header or query parameter that cannot be signed, a style the bucket
    /// or endpoint cannot use, or an object name a browser would rewrite.
    /// `Diagnostics` says which. Nothing was signed.
    InvalidSignedUrlOptions,
    /// A POST policy's options break a rule: an expiry out of range, a
    /// field the policy sets itself or that is never a condition, a
    /// repeated field, a size range that cannot hold, a value a form
    /// cannot send, or a style the bucket or endpoint cannot use.
    /// `Diagnostics` says which. Nothing was signed.
    InvalidPostPolicyOptions,
    /// A metadata update breaks a rule: a custom key that is empty or
    /// repeated, or a value a header cannot carry. `Diagnostics` says
    /// which. Nothing was sent.
    InvalidMetadataUpdate,
    /// A bucket's settings break a rule Cloud Storage holds them to: a
    /// label, a soft delete retention, a lifecycle rule, a Cloud KMS key
    /// name, a value read from the server that cannot be sent back, or an
    /// update that changes nothing. `Diagnostics` says which. Nothing was
    /// sent.
    InvalidBucketSettings,
    /// A notification configuration breaks a rule Cloud Storage holds it
    /// to, or one it would silently get wrong: a topic Pub/Sub would not
    /// name, an empty or repeated event type, more than 5 custom
    /// attributes, a key or value out of bounds, a key twice, named like
    /// an attribute every message carries or beginning with goog, or a
    /// type or format this library does not know. `Diagnostics` says
    /// which. Nothing was sent.
    InvalidNotificationConfig,
    /// A compose breaks a rule: fewer than 1 or more than 32 sources, a
    /// name Cloud Storage would refuse, a source named twice at the same
    /// generation, or a source whose generation and precondition
    /// contradict each other. `Diagnostics` says which. Nothing was sent.
    InvalidComposeSources,
    /// A parallel upload's options break a rule: a part size outside 5 MiB
    /// to 5 GiB, a concurrency outside 1 to 64, a source over 5 TiB, a
    /// value or custom metadata key a header cannot carry faithfully,
    /// custom metadata over 8 KiB, or an object name with a `.` or `..`
    /// segment, which the XML API's paths cannot name. `Diagnostics` says
    /// which. Nothing was sent.
    InvalidParallelUploadOptions,
    /// A parallel download's options break a rule: a part size under 1 MiB,
    /// a concurrency outside 1 to 64, or a checkpoint on a buffer
    /// destination, which no later process could hold. `Diagnostics` says
    /// which. Nothing was sent.
    InvalidParallelDownloadOptions,
    /// A checkpoint could not be read, parsed or saved, or it belongs to
    /// another transfer: another kind, bucket or object. Whatever it holds
    /// is kept, so the transfer it does belong to loses nothing; a transfer
    /// whose own save fails mid-run fails with this rather than carry on
    /// without what the caller asked to resume by. `Diagnostics` says
    /// which.
    CheckpointFailed,
};
