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

/// When Secret Manager tells a secret's topics it is time to rotate it,
/// with a `SECRET_ROTATE` message. It changes nothing itself: a
/// subscriber adds the new version. A secret with a rotation needs topics.
pub const Rotation = struct {
    /// The first time, RFC 3339: at least 5 minutes and at most 100 years
    /// from now, by the server's clock.
    next_time: []const u8,
    /// Seconds from one rotation to the next: 3,600 to 3,153,600,000 (1
    /// hour to 100 years). Null: the rotation happens once, and is then
    /// gone from the secret.
    period_s: ?u64 = null,
};

/// When a secret is deleted, with every version, without a trace.
pub const Expiry = union(enum) {
    /// An RFC 3339 time, such as `2027-01-01T00:00:00Z`: at least 60
    /// seconds and at most 100 years from now, by the server's clock.
    at: []const u8,
    /// Seconds from now: 60 to 3,153,600,000 (100 years).
    after_s: u64,
};

/// Where a global secret's bytes are stored. Immutable after creation,
/// but for its keys, and not sent at all for a regional secret, whose
/// location decides.
pub const Replication = union(enum) {
    /// Google chooses the regions. `SecretConfig.kms_key` names its key.
    automatic,
    /// The locations, each with its own key or none.
    user_managed: []const Replica,
};

/// One location a user-managed secret is stored in.
pub const Replica = struct {
    /// A location id, such as `europe-west1`.
    location: []const u8,
    /// The Cloud KMS key that encrypts the secret here,
    /// `projects/P/locations/L/keyRings/R/cryptoKeys/K`, in this location;
    /// null for Google's own encryption. Every replica has one, or none
    /// does.
    kms_key: ?[]const u8 = null,
};

/// The Cloud KMS key version that wrapped a version's bytes, where.
pub const KeyVersion = struct {
    /// The replica's location, or null for an automatic or regional
    /// secret.
    location: ?[]const u8 = null,
    /// `projects/P/locations/L/keyRings/R/cryptoKeys/K/cryptoKeyVersions/N`.
    name: []const u8,
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
    /// Pub/Sub topics told of every change, `projects/P/topics/T`: at most
    /// 10. Secret Manager's service agent, which `Client.serviceAgent`
    /// names, needs `roles/pubsub.publisher` on each first, or the create
    /// is `error.TopicNotPublishable`.
    topics: []const []const u8 = &.{},
    /// Needs topics.
    rotation: ?Rotation = null,
    /// The Cloud KMS key that encrypts the secret's versions: in `global`
    /// for automatic replication, or in the client's location for a
    /// regional secret. User-managed replication names its keys per
    /// replica instead. The service agent `Client.serviceAgent` names
    /// needs `roles/cloudkms.cryptoKeyEncrypterDecrypter` on it, or the
    /// create is `error.KeyUnavailable`.
    kms_key: ?[]const u8 = null,
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
    /// `.set` replaces every topic, and Secret Manager checks it can
    /// publish to each (`error.TopicNotPublishable`); `.clear` removes
    /// them, which a secret with a rotation cannot do.
    topics: Change([]const []const u8) = .keep,
    /// `.set` replaces the rotation, time and period; `.clear` removes it.
    rotation: Change(Rotation) = .keep,
    /// The key of an automatic or regional secret: `.set` makes versions
    /// added from now on use it, `.clear` Google's encryption. Versions
    /// already stored keep the key that wrapped them.
    kms_key: Change([]const u8) = .keep,
    /// The keys of a user-managed secret: every replica, in the locations
    /// it has, which cannot change, each with its new key or null.
    replica_keys: ?[]const Replica = null,
    /// Change the secret only if its etag is still this one, as read: a
    /// changed secret is `error.Aborted` and nothing changes. Null: no
    /// condition.
    etag: ?[]const u8 = null,

    /// Whether the update changes anything at all.
    pub fn isEmpty(self: SecretUpdate) bool {
        inline for (@typeInfo(SecretUpdate).@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "etag")) continue;
            if (comptime std.mem.eql(u8, field.name, "replica_keys")) {
                if (self.replica_keys != null) return false;
                continue;
            }
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
    /// Full names, `projects/P/topics/T`, as set.
    topics: []const []const u8 = &.{},
    /// Null when the secret has none. `next_time` advances by the period
    /// each time a rotation fires; a rotation without a period is gone
    /// once it has fired.
    rotation: ?Rotation = null,
    /// The key of an automatic or regional secret, or null.
    kms_key: ?[]const u8 = null,
    /// A user-managed secret's locations and keys; empty for automatic
    /// replication and for a regional secret.
    replicas: []const Replica = &.{},

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

/// What a Secret Manager message on a secret's topic says happened.
/// Secret Manager adds event types; one this library does not know is
/// `.unknown`, never refused.
pub const EventKind = enum {
    /// Sent to every topic whenever a create or update sets topics, as a
    /// check that it can publish, even for a create then refused for
    /// another reason. It names no secret.
    topic_configured,
    secret_create,
    /// Every update, one that changes nothing included.
    secret_update,
    secret_delete,
    /// It is time to rotate the secret: add a version. The secret, as
    /// sent, already has its next rotation time, or none for a rotation
    /// that happened once.
    secret_rotate,
    version_add,
    version_enable,
    version_disable,
    version_destroy,
    /// A destroy under a destruction delay: the version is disabled until
    /// its `scheduled_destroy_time`.
    version_destroy_scheduled,
    unknown,
};

/// Why a secret was deleted.
pub const DeleteType = enum { requested, expiration, unknown };

/// One message from a secret's topic, decoded by `decodeEvent`.
pub const SecretEvent = struct {
    kind: EventKind,
    /// The `eventType` attribute as sent, such as `SECRET_ROTATE`.
    event_type: []const u8,
    /// The secret's full name, with the project number and, for a
    /// regional secret, `/locations/L`; "" for `.topic_configured`.
    secret: []const u8,
    /// The secret's location, or null for a global secret.
    location: ?[]const u8,
    /// The version a version event concerns.
    version: ?u64,
    /// For `.secret_delete` only.
    delete_type: ?DeleteType,
    /// When the change happened, RFC 3339 as sent: Secret Manager writes it
    /// in Pacific time with an offset and up to six fraction digits, such
    /// as `2026-10-02T06:03:33.65825-07:00`; "" for `.topic_configured`.
    time: []const u8,
    /// The secret as the change left it (as it was, for a delete), for the
    /// secret events.
    info: ?SecretInfo,
    /// The version as the change left it, for the version events.
    version_info: ?VersionInfo,
    /// The change's identity, for telling a repeat delivery from a new
    /// change: event type, name and time. Pub/Sub delivers at least once,
    /// each repeat under a new message ID, and a global secret's events
    /// arrive late and out of order, so order them by `time`, not by
    /// arrival.
    key: []const u8,

    /// The secret's id, the last segment of `secret`.
    pub fn secretId(self: SecretEvent) []const u8 {
        return names.lastSegment(self.secret);
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
    /// The key versions that wrapped its bytes, one per replica, or one
    /// for an automatic or regional secret; empty under Google's own
    /// encryption. A key changed later leaves these as they were.
    kms_key_versions: []const KeyVersion = &.{},

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
