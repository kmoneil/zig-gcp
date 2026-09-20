//! Public data types: version references, configs, results and the checksum
//! mode. Results come wrapped in core's `Owned`, re-exported here.

const std = @import("std");
const names = @import("names.zig");

pub const Owned = @import("core").Owned;

/// Which version of a secret a call acts on.
pub const VersionRef = union(enum) {
    /// The version added most recently, whatever its number.
    latest,
    /// A version number, counting from 1.
    number: u64,
    /// An alias set on the secret, such as `prod`.
    alias: []const u8,
};

/// What to do about the checksum the server sends with a secret's bytes.
pub const ChecksumMode = enum {
    /// Verify it, and fail when the server sends none.
    required,
    /// Verify it when there is one, and report `checksum_verified = false`
    /// when there is not.
    if_present,
    /// Ignore it.
    off,
};

pub const Label = struct {
    key: []const u8,
    value: []const u8,
};

/// Where a global secret's bytes are stored. Immutable after creation, and
/// not sent at all for a regional secret, whose location decides.
pub const Replication = union(enum) {
    /// Google chooses the regions.
    automatic,
    /// Location ids such as `europe-west1`.
    user_managed: []const []const u8,
};

pub const SecretConfig = struct {
    /// Left out when the client has a location: a regional secret takes none.
    replication: Replication = .automatic,
    labels: []const Label = &.{},
};

pub const ListOptions = struct {
    /// Results per page. 0 lets the server choose.
    page_size: u32 = 0,
    /// `next_page_token` from the previous page; null for the first page.
    page_token: ?[]const u8 = null,
    /// A server-side filter such as `labels.team=payments`, passed through
    /// untouched. The library does not model the filter grammar.
    filter: ?[]const u8 = null,
};

/// A version's state. An unrecognized value from the server is `.unknown`,
/// so a new one never breaks parsing.
pub const State = enum { enabled, disabled, destroyed, unknown };

pub const SecretInfo = struct {
    /// Full resource name. Google answers with the project *number*, not the
    /// id the caller passed.
    name: []const u8,
    /// RFC 3339, as sent by the server. `core.timestamp.parse` converts it.
    create_time: []const u8,
    etag: []const u8,
    labels: []const Label,

    /// The value of the label named `key`, or null.
    pub fn label(self: SecretInfo, key: []const u8) ?[]const u8 {
        for (self.labels) |l| {
            if (std.mem.eql(u8, l.key, key)) return l.value;
        }
        return null;
    }

    /// The last segment of `name`: the id the secret was created with.
    pub fn id(self: SecretInfo) []const u8 {
        return names.lastSegment(self.name);
    }
};

pub const SecretPage = struct {
    secrets: []const SecretInfo,
    /// Pass as `page_token` to get the next page. Null on the last page.
    next_page_token: ?[]const u8,
    /// Secrets matching the request, or 0 when the server sends no count.
    total_size: u32,
};

pub const VersionInfo = struct {
    /// Full resource name, ending in `/versions/{number}`.
    name: []const u8,
    create_time: []const u8,
    /// "" unless the version is destroyed.
    destroy_time: []const u8,
    state: State,
    etag: []const u8,
    /// Whether the checksum stored with this version came from the client.
    /// False means the server computed it.
    client_specified_payload_checksum: bool,

    /// The trailing number of `name`, or null if it has none.
    pub fn number(self: VersionInfo) ?u64 {
        return names.versionNumber(self.name);
    }
};

pub const VersionPage = struct {
    versions: []const VersionInfo,
    /// Pass as `page_token` to get the next page. Null on the last page.
    next_page_token: ?[]const u8,
    /// Versions matching the request, or 0 when the server sends no count.
    total_size: u32,
};

const testing = std.testing;

test "SecretInfo.label finds the first match" {
    const info: SecretInfo = .{
        .name = "projects/82150720798/secrets/db-password",
        .create_time = "2026-09-20T10:00:00Z",
        .etag = "\"abc\"",
        .labels = &.{
            .{ .key = "team", .value = "payments" },
            .{ .key = "team", .value = "second" },
        },
    };
    try testing.expectEqualStrings("payments", info.label("team").?);
    try testing.expectEqual(null, info.label("missing"));
    try testing.expectEqualStrings("db-password", info.id());
}

test "VersionInfo.number reads the trailing number" {
    const info: VersionInfo = .{
        .name = "projects/82150720798/secrets/db-password/versions/3",
        .create_time = "",
        .destroy_time = "",
        .state = .enabled,
        .etag = "",
        .client_specified_payload_checksum = true,
    };
    try testing.expectEqual(3, info.number().?);
}
