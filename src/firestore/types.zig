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
};

pub const SetOptions = struct {
    precondition: ?Precondition = null,
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
