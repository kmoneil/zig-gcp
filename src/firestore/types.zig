//! The values calls take and return, and `Owned`, re-exported here.
//!
//! Documents and maps are slices of `Field`, in the order the server sent
//! them; decoded ones live in their `Owned` result's arena. Nothing here
//! hides a write inside the data: transforms, when they come, are a list
//! of their own beside it.

const std = @import("std");
const core = @import("core");

pub const Owned = core.Owned;

/// One Firestore value. Integers are exactly `i64`, as on the wire, and
/// never turn into doubles on the way. A timestamp keeps nanoseconds here,
/// but the server keeps microseconds: measured on the emulator, it stored
/// `.123456789` as `.123456`.
pub const Value = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    /// NaN and the infinities travel too.
    double: f64,
    /// Years 1 to 9999, as `core.timestamp.inRange` says.
    timestamp: std.Io.Timestamp,
    /// Valid UTF-8, at most 1,048,487 bytes. Queries see only the first
    /// 1,500.
    string: []const u8,
    /// At most 1,048,487 bytes.
    bytes: []const u8,
    /// A full document name: `projects/P/databases/D/documents/PATH`, which
    /// `Client.documentName` builds.
    reference: []const u8,
    geo_point: GeoPoint,
    /// May not directly hold another array.
    array: []const Value,
    map: []const Field,

    /// The field `name` of a map, or null when this is no map or has no
    /// such field.
    pub fn get(self: Value, name: []const u8) ?Value {
        return switch (self) {
            .map => |fields| getField(fields, name),
            else => null,
        };
    }
};

pub const GeoPoint = struct {
    /// -90 to 90.
    latitude: f64,
    /// -180 to 180.
    longitude: f64,
};

/// One named value in a document or a map. Names are any UTF-8 of 1 to
/// 1,500 bytes but the reserved `__x__` ones; a name that is not a simple
/// identifier is quoted wherever it becomes a field path, which this
/// library does.
pub const Field = struct {
    name: []const u8,
    value: Value,
};

/// The value of the field `name` among `fields`, or null.
pub fn getField(fields: []const Field, name: []const u8) ?Value {
    for (fields) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
    return null;
}

/// A document as read: its name, fields and times.
pub const Snapshot = struct {
    /// `projects/P/databases/D/documents/PATH`.
    name: []const u8,
    /// Empty for a document with none, or when a read mask matched none.
    fields: []const Field = &.{},
    create_time: std.Io.Timestamp,
    /// Moves with every write. A write's `Precondition.update_time` takes
    /// it, so the write fails if anyone wrote the document in between.
    update_time: std.Io.Timestamp,

    /// The top-level field `name`, or null.
    pub fn get(self: Snapshot, name: []const u8) ?Value {
        return getField(self.fields, name);
    }

    /// The document's own id: the last segment of its name.
    pub fn id(self: Snapshot) []const u8 {
        const slash = std.mem.lastIndexOfScalar(u8, self.name, '/') orelse return self.name;
        return self.name[slash + 1 ..];
    }

    /// Its path below the database's documents, such as `cities/LA`, which
    /// `Client.doc` takes.
    pub fn path(self: Snapshot) []const u8 {
        return @import("names.zig").relativePath(self.name) orelse self.name;
    }
};

/// A condition a write holds the document to; the server refuses the
/// write when it does not hold.
pub const Precondition = union(enum) {
    /// True: the document must exist, or the write is `error.NotFound`.
    /// False: it must not, or the write is `error.AlreadyExists`.
    exists: bool,
    /// The document must exist and have been written last at exactly this
    /// time, as a read or a write returned it, or the write is
    /// `error.FailedPrecondition`.
    update_time: std.Io.Timestamp,
};

pub const GetOptions = struct {
    /// Field paths to return, such as `name` or `address.city`; null
    /// returns every field. `__name__` alone returns none.
    mask: ?[]const []const u8 = null,
    /// Read the document as it was then, to the microsecond, within the
    /// last hour (or a whole minute within the last 7 days where
    /// point-in-time recovery is on). A document missing then is
    /// `error.NotFound`. The read goes through `batchGet`, which takes
    /// the time in its body.
    read_time: ?std.Io.Timestamp = null,
};

pub const SetOptions = struct {
    precondition: ?Precondition = null,
    /// Applied after the fields are written, in order; see `Transform`.
    /// With any, the write is retried after a lost answer only under a
    /// precondition a repeat fails, or `retry_unconditional_writes`.
    transforms: []const Transform = &.{},
};

pub const UpdateOptions = struct {
    /// The field paths to change. A path with no value in the fields
    /// given deletes that field; one that names a field inside a map
    /// changes only that field. Null means the top-level names of the
    /// fields given, each replaced whole. Every field given must be in the
    /// mask, and no path in it may overlap another.
    mask: ?[]const []const u8 = null,
    /// By default the document must exist, as Google's clients have it.
    /// Null writes it either way, creating it when missing.
    precondition: ?Precondition = .{ .exists = true },
    /// As `SetOptions.transforms`. With transforms, the fields and mask
    /// may be empty: the update then changes only what the transforms do.
    transforms: []const Transform = &.{},
};

pub const DeleteOptions = struct {
    /// Without one, deleting a missing document succeeds.
    precondition: ?Precondition = null,
};

pub const CreateOptions = struct {
    /// The new document's id. Null lets the server choose a random one of
    /// 20 letters and digits.
    document_id: ?[]const u8 = null,
};

/// What a write returns.
pub const WriteResult = struct {
    /// The document's new update time, for the next write's precondition.
    update_time: std.Io.Timestamp,
};

/// A number a transform takes. Integer arithmetic stays integer; a double
/// on either side makes the result a double.
pub const Numeric = union(enum) {
    integer: i64,
    double: f64,
};

/// A change the server makes to a field from its current value, after a
/// write's fields are written, so concurrent writers cannot lose each
/// other's changes. A document takes at most 500 per commit.
pub const Transform = struct {
    /// The field to change, such as `visits` or `stats.views`; maps on
    /// the way are made as needed. Two transforms may name one field,
    /// applied in turn, but not a field and one inside it.
    field_path: []const u8,
    op: Op,

    pub const Op = union(enum) {
        /// The time the server takes the write, to the millisecond, the
        /// same for every such field of one commit.
        server_time,
        /// Adds to the field's number; a field that is missing or no
        /// number is set to the operand. Integers saturate at the ends of
        /// `i64` rather than wrap.
        increment: Numeric,
        /// Keeps the larger of the field and the operand, setting a
        /// missing or non-numeric field to it. `3` and `3.0` count as
        /// equal and leave the field as it was; NaN wins.
        maximum: Numeric,
        /// As `maximum`, keeping the smaller.
        minimum: Numeric,
        /// Appends each value the array does not hold yet, in order; a
        /// field that is missing or no array becomes one. Numbers compare
        /// across integer and double, NaN equals NaN, and maps compare
        /// field by field. No value may itself be an array.
        append_missing: []const Value,
        /// Removes every element equal to any value, comparing as
        /// `append_missing` does; a field that is missing or no array
        /// becomes an empty one.
        remove_all: []const Value,
    };
};

/// One write in a commit.
pub const Write = union(enum) {
    update: Update,
    delete: Delete,

    pub const Update = struct {
        /// A document path, such as `cities/LA`.
        path: []const u8,
        fields: []const Field = &.{},
        /// Null replaces the whole document with `fields`, as
        /// `Document.set` does. A mask changes only the paths it names, as
        /// `UpdateOptions.mask` describes; an empty one, with transforms,
        /// changes only what they change.
        mask: ?[]const []const u8 = null,
        transforms: []const Transform = &.{},
        /// None by default: a missing document is created.
        precondition: ?Precondition = null,
    };

    pub const Delete = struct {
        path: []const u8,
        precondition: ?Precondition = null,
    };
};

pub const CommitOptions = struct {};

/// What one write of a commit did.
pub const CommittedWrite = struct {
    /// The document's new update time; null for a delete.
    update_time: ?std.Io.Timestamp,
    /// One per transform, in order: the field's new value for
    /// `server_time`, `increment`, `maximum` and `minimum`, and null for
    /// the array transforms.
    transform_results: []const Value = &.{},
};

pub const CommitResult = struct {
    /// One per write, in the order given.
    writes: []const CommittedWrite,
    commit_time: std.Io.Timestamp,
};

/// A query over one collection, or over every collection of one id at any
/// depth (a collection group), read with `Client.runQuery`.
pub const Query = struct {
    from: From,
    /// The document below which to look, such as `cities/LA`; empty for
    /// the whole database. A collection query reads the collection
    /// directly below it, a group query every collection of that id
    /// anywhere below it.
    parent: []const u8 = "",
    /// Conditions that must all hold. For OR, or AND nested in it, use
    /// `filter` instead; the two cannot be set together.
    where: []const Condition = &.{},
    filter: ?Filter = null,
    /// A document without a field ordered by is left out. After these,
    /// the server orders by the fields of any inequality not ordered by
    /// already, then by name, in the last order's direction; ties break
    /// the same way.
    order_by: []const Order = &.{},
    /// Field paths to return; null returns whole documents, and an empty
    /// list only their names.
    select: ?[]const []const u8 = null,
    /// Where the results begin and end, in `order_by`'s terms.
    start_at: ?Cursor = null,
    end_at: ?Cursor = null,
    /// Results to skip.
    offset: u32 = 0,
    /// Null for no limit.
    limit: ?u32 = null,

    pub const From = union(enum) {
        /// A collection id, such as `cities`.
        collection: []const u8,
        /// A collection id, such as `landmarks`: every collection so named.
        group: []const u8,
    };
};

pub const Operator = enum {
    less_than,
    less_than_or_equal,
    greater_than,
    greater_than_or_equal,
    /// Against null or NaN, sent as the server's own test for them: an
    /// equality with either never matches on the wire.
    equal,
    /// Against null or NaN, likewise. Leaves out documents whose field is
    /// null or missing.
    not_equal,
    array_contains,
    /// The value is an array of at most 30 values to match any of.
    in,
    /// The value is an array of at most 30 values, any of which the
    /// field's array holds.
    array_contains_any,
    /// The value is an array of at most 10 values to match none of. Leaves
    /// out documents whose field is null or missing.
    not_in,
    is_null,
    is_nan,
    is_not_null,
    /// Leaves out null too.
    is_not_nan,
};

/// One test of one field. A range only matches values of its operand's
/// kind: `greater_than` 1 matches numbers, never strings.
pub const Condition = struct {
    /// A field path, or `__name__`, whose values are references, which
    /// `Client.documentName` builds.
    field: []const u8,
    op: Operator,
    /// Unused by the four `is_*` operators.
    value: Value = .null,
};

/// A tree of conditions.
pub const Filter = union(enum) {
    condition: Condition,
    /// Every one holds; at least one.
    all: []const Filter,
    /// Any one holds; at least one.
    any: []const Filter,
};

/// A position in a query's order: one value per `order_by` entry, at most
/// as many as there are. A `__name__` position is a reference.
pub const Cursor = struct {
    values: []const Value,
    /// For `start_at`, whether documents at the position are included or
    /// the results start after them; for `end_at`, whether they are
    /// included or the results end before them.
    inclusive: bool = true,
};

pub const QueryOptions = struct {
    /// Read as of then; see `GetOptions.read_time`.
    read_time: ?std.Io.Timestamp = null,
};

pub const QueryResult = struct {
    documents: []const Snapshot,
    /// When the results were read.
    read_time: std.Io.Timestamp,
    /// How many results the offset skipped, where the server says.
    skipped_results: u64 = 0,
};

/// One figure over a query's results; at most five per query.
pub const Aggregation = union(enum) {
    /// How many documents; with `up_to`, counting stops there.
    count: struct { up_to: ?u63 = null },
    /// The sum of a field's numbers, other values left out: an integer
    /// while every number is one and the sum fits, a double otherwise.
    sum: []const u8,
    /// The mean of a field's numbers as a double, null when there are
    /// none.
    avg: []const u8,
};

pub const AggregationResult = struct {
    /// One per aggregation, in the order asked.
    values: []const Value,
    read_time: std.Io.Timestamp,
};

pub const BatchGetOptions = struct {
    /// As `GetOptions.mask`, for every document.
    mask: ?[]const []const u8 = null,
    /// As `GetOptions.read_time`.
    read_time: ?std.Io.Timestamp = null,
};

pub const BatchGetResult = struct {
    /// One per path asked for, in the order asked, a path asked twice
    /// included twice: the document, or null where it does not exist.
    documents: []const ?Snapshot,
    /// When the documents were read; null only when none were asked for.
    read_time: ?std.Io.Timestamp,
};

pub const Direction = enum { ascending, descending };

/// One field to order by.
pub const Order = struct {
    /// A field path, or `__name__` for the document's name.
    field: []const u8,
    direction: Direction = .ascending,
};

pub const ListOptions = struct {
    /// 0 lets the server choose.
    page_size: u32 = 0,
    /// A previous page's `next_page_token`.
    page_token: ?[]const u8 = null,
    /// Empty orders by name. A document without a field ordered by is left
    /// out. Descending by `__name__` alone is refused: "Firestore does not
    /// support descending key scans".
    order_by: []const Order = &.{},
    /// As `GetOptions.mask`.
    mask: ?[]const []const u8 = null,
};

pub const SnapshotPage = struct {
    documents: []const Snapshot = &.{},
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
};

pub const ListCollectionIdsOptions = struct {
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
    read_time: ?std.Io.Timestamp = null,
};

pub const CollectionIdPage = struct {
    /// In ascending order.
    collection_ids: []const []const u8 = &.{},
    /// Null on the last page.
    next_page_token: ?[]const u8 = null,
};

const testing = std.testing;

test "Snapshot: id, path and fields by name" {
    const s: Snapshot = .{
        .name = "projects/p/databases/(default)/documents/cities/LA/landmarks/tower",
        .fields = &.{
            .{ .name = "height", .value = .{ .integer = 300 } },
            .{ .name = "address", .value = .{ .map = &.{.{ .name = "city", .value = .{ .string = "LA" } }} } },
        },
        .create_time = .{ .nanoseconds = 0 },
        .update_time = .{ .nanoseconds = 0 },
    };
    try testing.expectEqualStrings("tower", s.id());
    try testing.expectEqualStrings("cities/LA/landmarks/tower", s.path());
    try testing.expectEqual(300, s.get("height").?.integer);
    try testing.expectEqualStrings("LA", s.get("address").?.get("city").?.string);
    try testing.expectEqual(null, s.get("missing"));
    try testing.expectEqual(null, s.get("height").?.get("x"));
    try testing.expectEqual(null, s.get("address").?.get("zip"));
}
