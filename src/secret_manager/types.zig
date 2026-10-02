//! Public data types: version references, configs, results and the checksum
//! mode. Results come wrapped in core's `Owned`, re-exported here.

const std = @import("std");
const core = @import("core");
const names = @import("names.zig");

pub const Owned = core.Owned;
pub const Change = core.Change;

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

/// A label: for selecting and billing. Keys are 1 to 63 characters,
/// starting with a lowercase or uncased letter, then lowercase letters,
/// digits, `_` and `-`; values the same, 0 to 63 characters, any first
/// character; each at most 128 bytes. At most 64 on a secret.
pub const Label = struct {
    key: []const u8,
    value: []const u8,
};

/// An annotation: metadata for tools, not for selecting. Keys are 1 to 64
/// characters of ASCII letters and digits, with `.`, `_` and `-` between
/// them; values anything. Keys and values together hold at most 16,384
/// bytes on a secret.
pub const Annotation = struct {
    key: []const u8,
    value: []const u8,
};

/// A version alias: a name that `VersionRef.alias` reads through, such as
/// `prod`. Names are 1 to 63 characters, a letter and then letters, digits,
/// `_` and `-`, and not `latest` or `NEW`; case matters. At most 50 on a
/// secret, each naming a version that exists, destroyed ones included.
pub const Alias = struct {
    name: []const u8,
    version: u64,
};

/// When a secret is deleted, with every version, without a trace.
pub const Expiry = union(enum) {
    /// An RFC 3339 time, such as `2027-01-01T00:00:00Z`: at least 60
    /// seconds and at most 100 years from now, by the server's clock.
    at: []const u8,
    /// Seconds from now: 60 to 3,153,600,000 (100 years).
    after_s: u64,
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
    annotations: []const Annotation = &.{},
    /// Null: the secret never expires.
    expiry: ?Expiry = null,
    /// How long a destroyed version waits, disabled, before its bytes go:
    /// 86,400 to 86,400,000 seconds (1 to 1,000 days). Null: at once.
    version_destroy_delay_s: ?u64 = null,
};

/// What `Secret.update` changes. Every field left at `.keep` stays as it
/// is; at least one must change. A list given with `.set` replaces the
/// whole list on the server, which keeps nothing of the old one: to change
/// one label, read the secret, change the list, and set it.
pub const SecretUpdate = struct {
    /// `.set` replaces every label, `&.{}` or `.clear` removes them all.
    labels: Change([]const Label) = .keep,
    annotations: Change([]const Annotation) = .keep,
    aliases: Change([]const Alias) = .keep,
    /// `.clear`: the secret no longer expires.
    expiry: Change(Expiry) = .keep,
    /// `.clear`: versions destroyed from now on go at once. Versions
    /// already scheduled keep their time.
    version_destroy_delay_s: Change(u64) = .keep,
    /// Change the secret only if its etag is still this one, as read: a
    /// changed secret is `error.Aborted` and nothing changes. Null: no
    /// condition.
    etag: ?[]const u8 = null,

    /// Whether the update changes anything at all.
    pub fn isEmpty(self: SecretUpdate) bool {
        inline for (@typeInfo(SecretUpdate).@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "etag")) continue;
            if (@field(self, field.name) != .keep) return false;
        }
        return true;
    }
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
    /// Pass to `Secret.update` or `Secret.deleteIf` to change the secret
    /// only if nothing else has since. Every change moves it, one that
    /// changes nothing included; a version's changes do not.
    etag: []const u8,
    labels: []const Label,
    annotations: []const Annotation = &.{},
    aliases: []const Alias = &.{},
    /// RFC 3339, in UTC; "" when the secret never expires.
    expire_time: []const u8 = "",
    /// Null: destroyed versions go at once. Whole seconds; a fraction
    /// someone else set is dropped.
    version_destroy_delay_s: ?u64 = null,

    /// The value of the label named `key`, or null.
    pub fn label(self: SecretInfo, key: []const u8) ?[]const u8 {
        for (self.labels) |l| {
            if (std.mem.eql(u8, l.key, key)) return l.value;
        }
        return null;
    }

    /// The value of the annotation named `key`, or null.
    pub fn annotation(self: SecretInfo, key: []const u8) ?[]const u8 {
        for (self.annotations) |a| {
            if (std.mem.eql(u8, a.key, key)) return a.value;
        }
        return null;
    }

    /// The version the alias `name` names, or null. Case matters.
    pub fn alias(self: SecretInfo, name: []const u8) ?u64 {
        for (self.aliases) |a| {
            if (std.mem.eql(u8, a.name, name)) return a.version;
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
    /// A version whose secret delays destruction is `.disabled` until
    /// this time, RFC 3339, and then destroyed; "" when none is scheduled.
    /// Enabling or disabling it cancels the destruction.
    scheduled_destroy_time: []const u8 = "",
    state: State,
    /// Pass to `enableIf`, `disableIf` or `destroyIf` to change the
    /// version only if nothing else has since.
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
