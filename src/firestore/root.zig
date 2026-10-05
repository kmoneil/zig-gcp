//! Cloud Firestore v1 REST client.
//!
//! `Client` holds the configuration and the connection pool, for one
//! database; `Collection` and `Document` are cheap handles on it. Values
//! are a `Value` union and documents slices of `Field`, with integers kept
//! exactly. The emulator works through `Endpoint.fromEnv`, which reads
//! `FIRESTORE_EMULATOR_HOST`.

const core = @import("core");

pub const Client = @import("Client.zig");
pub const Collection = @import("Collection.zig");
pub const Document = @import("Document.zig");
pub const Endpoint = @import("Endpoint.zig");

pub const TokenProvider = core.TokenProvider;
pub const StaticToken = core.StaticToken;
/// The OAuth scope the client requests from its `TokenProvider`.
pub const auth_scope = @import("rpc.zig").scope;

pub const RetryPolicy = core.RetryPolicy;
pub const Diagnostics = core.Diagnostics;
pub const Error = @import("errors.zig").Error;
pub const ApiError = core.ApiError;

pub const Owned = @import("types.zig").Owned;
pub const Value = @import("types.zig").Value;
pub const GeoPoint = @import("types.zig").GeoPoint;
pub const Field = @import("types.zig").Field;
pub const getField = @import("types.zig").getField;
pub const Snapshot = @import("types.zig").Snapshot;
pub const Precondition = @import("types.zig").Precondition;
pub const GetOptions = @import("types.zig").GetOptions;
pub const SetOptions = @import("types.zig").SetOptions;
pub const UpdateOptions = @import("types.zig").UpdateOptions;
pub const DeleteOptions = @import("types.zig").DeleteOptions;
pub const CreateOptions = @import("types.zig").CreateOptions;
pub const WriteResult = @import("types.zig").WriteResult;
pub const Numeric = @import("types.zig").Numeric;
pub const Transform = @import("types.zig").Transform;
pub const Write = @import("types.zig").Write;
pub const CommitOptions = @import("types.zig").CommitOptions;
pub const CommittedWrite = @import("types.zig").CommittedWrite;
pub const CommitResult = @import("types.zig").CommitResult;
pub const Query = @import("types.zig").Query;
pub const Operator = @import("types.zig").Operator;
pub const Condition = @import("types.zig").Condition;
pub const Filter = @import("types.zig").Filter;
pub const Cursor = @import("types.zig").Cursor;
pub const QueryOptions = @import("types.zig").QueryOptions;
pub const QueryResult = @import("types.zig").QueryResult;
pub const QueryStreamOptions = @import("types.zig").QueryStreamOptions;
pub const default_stream_timeout_ms = @import("types.zig").default_stream_timeout_ms;
pub const DocumentHandler = @import("types.zig").DocumentHandler;
pub const QueryStreamEnd = @import("types.zig").QueryStreamEnd;
pub const Aggregation = @import("types.zig").Aggregation;
pub const AggregationResult = @import("types.zig").AggregationResult;
pub const BatchGetOptions = @import("types.zig").BatchGetOptions;
pub const BatchGetResult = @import("types.zig").BatchGetResult;
pub const BatchGetStreamOptions = @import("types.zig").BatchGetStreamOptions;
pub const BatchGetItem = @import("types.zig").BatchGetItem;
pub const BatchGetHandler = @import("types.zig").BatchGetHandler;
pub const BatchGetStreamEnd = @import("types.zig").BatchGetStreamEnd;
pub const TransactionOptions = @import("types.zig").TransactionOptions;
pub const RunTransactionOptions = @import("types.zig").RunTransactionOptions;
pub const Transaction = @import("Transaction.zig");
pub const TransactionHandler = @import("Transaction.zig").Handler;
pub const Direction = @import("types.zig").Direction;
pub const Order = @import("types.zig").Order;
pub const ListOptions = @import("types.zig").ListOptions;
pub const SnapshotPage = @import("types.zig").SnapshotPage;
pub const ListCollectionIdsOptions = @import("types.zig").ListCollectionIdsOptions;
pub const CollectionIdPage = @import("types.zig").CollectionIdPage;

/// The naming rules and limits the client checks before sending.
pub const limits = @import("validate.zig");

/// Field paths: how a field name becomes a path segment, quoted in
/// backticks when it is not a simple identifier, and how a path splits
/// back into names.
pub const field_path = struct {
    pub const isSimpleSegment = @import("names.zig").isSimpleSegment;
    pub const writeSegment = @import("names.zig").writeFieldSegment;
    pub const ofName = @import("names.zig").fieldPathOf;
    pub const Iterator = @import("names.zig").FieldPathIterator;
};

/// The HTTP seam: implement `transport.Transport` to send requests another
/// way, or to fake the server in your own tests.
pub const transport = core.transport;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("Client.zig");
    _ = @import("Collection.zig");
    _ = @import("Document.zig");
    _ = @import("Endpoint.zig");
    _ = @import("batch_get.zig");
    _ = @import("codec.zig");
    _ = @import("emulator_diff.zig");
    _ = @import("errors.zig");
    _ = @import("fake_firestore.zig");
    _ = @import("logging.zig");
    _ = @import("names.zig");
    _ = @import("query.zig");
    _ = @import("rpc.zig");
    _ = @import("stream.zig");
    _ = @import("test_util.zig");
    _ = @import("Transaction.zig");
    _ = @import("types.zig");
    _ = @import("validate.zig");
    _ = @import("writes.zig");
}

test "every public declaration of types.zig is public here too" {
    inline for (@typeInfo(@import("types.zig")).@"struct".decl_names) |name| {
        if (!@hasDecl(@This(), name)) @compileError("not exported: types." ++ name);
    }
}
