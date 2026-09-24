//! `Error`: every error a Cloud Storage call can return. The HTTP statuses,
//! their mapping and `Diagnostics` live in core.
//!
//! Storage error bodies carry no canonical status string, so the HTTP code
//! decides the error and `Diagnostics.status` keeps the server's `reason`,
//! such as "notFound". The canonical names apply: a bucket name that is
//! taken, and a bucket that is not empty on delete, are both
//! `error.AlreadyExists` (HTTP 409), and a failed generation precondition is
//! `error.FailedPrecondition` (HTTP 412).

const core = @import("core");

/// Every error a client call can return. `core.Signer.Error` adds
/// `SigningRejected` and `SigningFailed`, which only `signedUrl` returns.
pub const Error = core.rpc.Error || core.Signer.Error || error{
    /// Upload or download bytes do not match the checksum beside them. On
    /// upload nothing was sent; on download the data is discarded.
    ChecksumMismatch,
    /// `downloadAlloc` met an object larger than its `max_bytes`, or
    /// `downloadParallel` one larger than the buffer it was given.
    ObjectTooLarge,
    /// The caller's writer failed during a download, with the detail
    /// wherever that concrete writer keeps it. Whatever it holds by then
    /// must be discarded.
    WriteFailed,
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
