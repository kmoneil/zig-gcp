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

/// Every error a client call can return.
pub const Error = core.rpc.Error || error{
    /// Upload or download bytes do not match the checksum beside them. On
    /// upload nothing was sent; on download the data is discarded.
    ChecksumMismatch,
    /// `downloadAlloc` met an object larger than its `max_bytes`.
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
    /// wherever that concrete reader keeps it. The session was cancelled.
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
};
