//! JSON: request bodies out, response bodies in.
//!
//! The wire format has quirks every binding trips over: `size`,
//! `generation` and `metageneration` are decimal integers in JSON strings,
//! though emulators also send plain numbers; `crc32c` is base64 of the four
//! checksum bytes in big-endian order; `md5Hash` is base64 of the digest
//! and missing for composite objects. The private `Wire*` structs mirror
//! the wire exactly and never leave this file. Unknown fields are ignored,
//! so new server fields never break old clients.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const Writer = std.Io.Writer;
const core = @import("core");
const acl = @import("acl.zig");
const types = @import("types.zig");

pub const DecodeError = error{ InvalidResponse, OutOfMemory };

// Requests

/// The object metadata an upload declares: the multipart metadata part and
/// the resumable session's opening body are this same JSON. `crc32c` is
/// the checksum's base64 form, or null to claim none.
pub fn encodeUploadMetadata(
    arena: Allocator,
    object_name: []const u8,
    options: types.UploadOptions,
    crc32c: ?[8]u8,
) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeUploadMetadata(&jw, object_name, options, crc32c) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeUploadMetadata(
    jw: *Stringify,
    object_name: []const u8,
    options: types.UploadOptions,
    crc32c: ?[8]u8,
) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(object_name);
    try jw.objectField("contentType");
    try jw.write(options.content_type);
    if (options.cache_control) |value| {
        try jw.objectField("cacheControl");
        try jw.write(value);
    }
    if (options.content_disposition) |value| {
        try jw.objectField("contentDisposition");
        try jw.write(value);
    }
    if (options.content_encoding) |value| {
        try jw.objectField("contentEncoding");
        try jw.write(value);
    }
    if (options.content_language) |value| {
        try jw.objectField("contentLanguage");
        try jw.write(value);
    }
    if (options.metadata.len > 0) {
        try jw.objectField("metadata");
        try jw.beginObject();
        for (options.metadata) |entry| {
            try jw.objectField(entry.key);
            try jw.write(entry.value);
        }
        try jw.endObject();
    }
    if (crc32c) |checksum| {
        try jw.objectField("crc32c");
        try jw.write(&checksum);
    }
    try writeHolds(jw, options.temporary_hold, options.event_based_hold);
    if (options.retention) |r| try writeRetention(jw, r);
    try jw.endObject();
}

/// An object's own retention, as the JSON API spells its mode.
pub fn writeRetention(jw: *Stringify, retention: types.ObjectRetention) Stringify.Error!void {
    try jw.objectField("retention");
    try jw.beginObject();
    try jw.objectField("mode");
    try jw.write(switch (retention.mode) {
        .unlocked => "Unlocked",
        .locked => "Locked",
        // The checks refuse it before anything is encoded.
        .unknown => unreachable,
    });
    try jw.objectField("retainUntilTime");
    try jw.write(retention.retain_until);
    try jw.endObject();
}

/// What removes an object's retention: both fields null, as measured.
/// `{}` changes nothing.
pub fn writeRetentionRemoved(jw: *Stringify) Stringify.Error!void {
    try jw.objectField("retention");
    try jw.beginObject();
    try jw.objectField("mode");
    try jw.write(null);
    try jw.objectField("retainUntilTime");
    try jw.write(null);
    try jw.endObject();
}

/// A new object's holds: a temporary one only when asked for, and an
/// event-based one when the caller said either way, since `false` also
/// turns away the bucket's default hold.
pub fn writeHolds(jw: *Stringify, temporary: bool, event_based: ?bool) Stringify.Error!void {
    if (temporary) {
        try jw.objectField("temporaryHold");
        try jw.write(true);
    }
    if (event_based) |on| {
        try jw.objectField("eventBasedHold");
        try jw.write(on);
    }
}

// Responses

/// One Object resource.
pub fn decodeObject(arena: Allocator, body: []const u8) DecodeError!types.ObjectInfo {
    return objectFromWire(arena, try parseWire(WireObject, arena, body));
}

/// The service agent's address from `projects.serviceAccount.get`, whose
/// one field is in snake case, unlike the rest of the API.
pub fn decodeServiceAgent(arena: Allocator, body: []const u8) DecodeError![]const u8 {
    const wire = try parseWire(struct { email_address: ?[]const u8 = null }, arena, body);
    return nonEmpty(wire.email_address) orelse error.InvalidResponse;
}

/// The `size` an Object resource names, or null when it names none, which
/// `ObjectInfo` cannot tell from an empty object.
pub fn decodeObjectSize(arena: Allocator, body: []const u8) DecodeError!?u64 {
    const wire = try parseWire(struct { size: ?std.json.Value = null }, arena, body);
    return if (wire.size == null) null else try u64FromValue(wire.size);
}

/// What a copy with changes carries from its source: the generation and
/// metageneration it pins the copy to, and the editable fields as the
/// server sent them. An empty field reads as absent.
pub const CopySource = struct {
    generation: u64,
    metageneration: u64,
    content_type: ?[]const u8,
    cache_control: ?[]const u8,
    content_disposition: ?[]const u8,
    content_encoding: ?[]const u8,
    content_language: ?[]const u8,
    /// RFC 3339. `ObjectInfo` does not report it, but lifecycle rules read
    /// it, so a copy must not drop it.
    custom_time: ?[]const u8,
    metadata: []const types.Metadata,
};

/// The source of a copy with changes. A resource that names no generation
/// or metageneration is `InvalidResponse`: there would be nothing to pin
/// the copy to.
pub fn decodeCopySource(arena: Allocator, body: []const u8) DecodeError!CopySource {
    const wire = try parseWire(WireCopySource, arena, body);
    const generation = try u64FromValue(wire.generation);
    const metageneration = try u64FromValue(wire.metageneration);
    if (generation == 0 or metageneration == 0) return error.InvalidResponse;
    return .{
        .generation = generation,
        .metageneration = metageneration,
        .content_type = nonEmpty(wire.contentType),
        .cache_control = nonEmpty(wire.cacheControl),
        .content_disposition = nonEmpty(wire.contentDisposition),
        .content_encoding = nonEmpty(wire.contentEncoding),
        .content_language = nonEmpty(wire.contentLanguage),
        .custom_time = nonEmpty(wire.customTime),
        .metadata = try metadataFromWire(arena, wire.metadata),
    };
}

const WireCopySource = struct {
    generation: ?std.json.Value = null,
    metageneration: ?std.json.Value = null,
    contentType: ?[]const u8 = null,
    cacheControl: ?[]const u8 = null,
    contentDisposition: ?[]const u8 = null,
    contentEncoding: ?[]const u8 = null,
    contentLanguage: ?[]const u8 = null,
    customTime: ?[]const u8 = null,
    metadata: ?std.json.ArrayHashMap(?[]const u8) = null,
};

/// One page of `objects.list`.
pub fn decodeObjectPage(arena: Allocator, body: []const u8) DecodeError!types.ObjectPage {
    const wire = try parseWire(WireObjectPage, arena, body);
    const listed = wire.items orelse &.{};
    const objects = try arena.alloc(types.ObjectInfo, listed.len);
    for (listed, objects) |w, *info| info.* = try objectFromWire(arena, w);
    const wire_prefixes = wire.prefixes orelse &.{};
    const prefixes = try arena.alloc([]const u8, wire_prefixes.len);
    for (wire_prefixes, prefixes) |w, *p| p.* = w orelse "";
    return .{
        .objects = objects,
        .prefixes = prefixes,
        .next_page_token = nonEmpty(wire.nextPageToken),
    };
}

/// One answer of the rewrite loop behind `copyTo`.
pub const Rewrite = struct {
    done: bool,
    /// Continues an unfinished rewrite. Null once done, or when the server
    /// sent none.
    rewrite_token: ?[]const u8,
    /// The finished object, on the final answer.
    resource: ?types.ObjectInfo,
    total_bytes_rewritten: u64,
    object_size: u64,
};

pub fn decodeRewrite(arena: Allocator, body: []const u8) DecodeError!Rewrite {
    const wire = try parseWire(WireRewrite, arena, body);
    return .{
        .done = wire.done orelse false,
        .rewrite_token = nonEmpty(wire.rewriteToken),
        .resource = if (wire.resource) |w| try objectFromWire(arena, w) else null,
        .total_bytes_rewritten = try u64FromValue(wire.totalBytesRewritten),
        .object_size = try u64FromValue(wire.objectSize),
    };
}

const WireRewrite = struct {
    done: ?bool = null,
    rewriteToken: ?[]const u8 = null,
    totalBytesRewritten: ?std.json.Value = null,
    objectSize: ?std.json.Value = null,
    resource: ?WireObject = null,
};

/// What a bucket or object read with `projection=full` says about its
/// access control lists. A list the resource leaves out is null: not
/// readable by the caller, under uniform access, or, for a default object
/// list, empty, which Cloud Storage answers by leaving it out, as measured
/// 2026-10-05.
pub const AclResource = struct {
    acl: ?[]const types.AclEntry,
    default_object_acl: ?[]const types.AclEntry,
    owner: ?types.AclEntity,
    metageneration: u64,
    generation: ?u64,
    uniform_bucket_level_access: bool,
};

pub fn decodeAclResource(arena: Allocator, body: []const u8) DecodeError!AclResource {
    const wire = try parseWire(struct {
        acl: ?[]const acl.WireEntry = null,
        defaultObjectAcl: ?[]const acl.WireEntry = null,
        owner: ?acl.WireOwner = null,
        metageneration: ?std.json.Value = null,
        generation: ?std.json.Value = null,
        iamConfiguration: ?WireIamConfiguration = null,
    }, arena, body);
    const metageneration = try u64FromValue(wire.metageneration);
    // A guarded write needs it: a resource without one cannot be written.
    if (metageneration == 0) return error.InvalidResponse;
    const iam: WireIamConfiguration = wire.iamConfiguration orelse .{};
    return .{
        .acl = try acl.entriesFromWire(arena, wire.acl),
        .default_object_acl = try acl.entriesFromWire(arena, wire.defaultObjectAcl),
        .owner = acl.ownerFromWire(wire.owner),
        .metageneration = metageneration,
        .generation = try optionalU64FromValue(wire.generation),
        .uniform_bucket_level_access = if (iam.uniformBucketLevelAccess) |u| u.enabled orelse false else false,
    };
}

/// One entry, from a single-entry read.
pub fn decodeAclEntry(arena: Allocator, body: []const u8) DecodeError!types.AclEntry {
    return acl.entryFromWire(try parseWire(acl.WireEntry, arena, body));
}

/// The entries of a whole-list body: what a guarded write sends, each
/// entry's entity and role and nothing else, which the server sets.
pub fn encodeAclBody(arena: Allocator, field: []const u8, entries: []const types.AclEntry) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeAclBody(&jw, arena, field, entries) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeAclBody(jw: *Stringify, arena: Allocator, field: []const u8, entries: []const types.AclEntry) (Stringify.Error || Allocator.Error)!void {
    try jw.beginObject();
    try jw.objectField(field);
    try jw.beginArray();
    for (entries) |entry| {
        try jw.beginObject();
        try jw.objectField("entity");
        try jw.write(try acl.entityText(arena, entry.entity));
        try jw.objectField("role");
        // Checked before encoding: an unknown role is never sent.
        try jw.write(acl.roleName(entry.role).?);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
}

/// One Bucket resource.
pub fn decodeBucket(arena: Allocator, body: []const u8) DecodeError!types.BucketInfo {
    return bucketFromWire(arena, try parseWire(WireBucket, arena, body));
}

/// One page of `buckets.list`.
pub fn decodeBucketPage(arena: Allocator, body: []const u8) DecodeError!types.BucketPage {
    const wire = try parseWire(WireBucketPage, arena, body);
    const listed = wire.items orelse &.{};
    const buckets = try arena.alloc(types.BucketInfo, listed.len);
    for (listed, buckets) |w, *info| info.* = try bucketFromWire(arena, w);
    return .{
        .buckets = buckets,
        .next_page_token = nonEmpty(wire.nextPageToken),
    };
}

const WireObject = struct {
    name: ?[]const u8 = null,
    bucket: ?[]const u8 = null,
    size: ?std.json.Value = null,
    generation: ?std.json.Value = null,
    metageneration: ?std.json.Value = null,
    contentType: ?[]const u8 = null,
    cacheControl: ?[]const u8 = null,
    contentDisposition: ?[]const u8 = null,
    contentEncoding: ?[]const u8 = null,
    contentLanguage: ?[]const u8 = null,
    crc32c: ?[]const u8 = null,
    md5Hash: ?[]const u8 = null,
    componentCount: ?std.json.Value = null,
    etag: ?[]const u8 = null,
    storageClass: ?[]const u8 = null,
    timeCreated: ?[]const u8 = null,
    updated: ?[]const u8 = null,
    metadata: ?std.json.ArrayHashMap(?[]const u8) = null,
    timeDeleted: ?[]const u8 = null,
    softDeleteTime: ?[]const u8 = null,
    hardDeleteTime: ?[]const u8 = null,
    restoreToken: ?[]const u8 = null,
    kmsKeyName: ?[]const u8 = null,
    customerEncryption: ?struct { keySha256: ?[]const u8 = null } = null,
    temporaryHold: ?bool = null,
    eventBasedHold: ?bool = null,
    retentionExpirationTime: ?[]const u8 = null,
    /// `retainUntilTime` is RFC 3339 from the JSON API, and "protocol
    /// buffer Timestamp format" in a notification's payload, its
    /// documentation says, which could be either text or seconds and nanos.
    retention: ?struct { mode: ?[]const u8 = null, retainUntilTime: ?std.json.Value = null } = null,
    /// Only under `projection=full`, and only to a caller who may read it.
    acl: ?[]const acl.WireEntry = null,
    owner: ?acl.WireOwner = null,
};

const WireObjectPage = struct {
    items: ?[]const WireObject = null,
    prefixes: ?[]const ?[]const u8 = null,
    nextPageToken: ?[]const u8 = null,
};

/// One Folder resource. A folder that names no path cannot be addressed,
/// so it is `InvalidResponse`.
pub fn decodeFolder(arena: Allocator, body: []const u8) DecodeError!types.FolderInfo {
    return folderFromWire(try parseWire(WireFolder, arena, body));
}

/// One page of `folders.list`. A list of none has no `items`; there is no
/// `prefixes` side, directory mode or not, as measured.
pub fn decodeFolderPage(arena: Allocator, body: []const u8) DecodeError!types.FolderPage {
    const wire = try parseWire(struct {
        items: ?[]const WireFolder = null,
        nextPageToken: ?[]const u8 = null,
    }, arena, body);
    const listed = wire.items orelse &.{};
    const folders = try arena.alloc(types.FolderInfo, listed.len);
    for (listed, folders) |w, *info| info.* = try folderFromWire(w);
    return .{ .folders = folders, .next_page_token = nonEmpty(wire.nextPageToken) };
}

const WireFolder = struct {
    name: ?[]const u8 = null,
    bucket: ?[]const u8 = null,
    metageneration: ?std.json.Value = null,
    /// `createTime`/`updateTime`, where objects say `timeCreated`/`updated`:
    /// the discovery document is right and the folders overview wrong, as
    /// measured on 2026-10-02.
    createTime: ?[]const u8 = null,
    updateTime: ?[]const u8 = null,
    pendingRenameInfo: ?struct { operationId: ?[]const u8 = null } = null,
};

fn folderFromWire(wire: WireFolder) DecodeError!types.FolderInfo {
    return .{
        .name = nonEmpty(wire.name) orelse return error.InvalidResponse,
        .bucket = wire.bucket orelse "",
        .metageneration = try u64FromValue(wire.metageneration),
        .create_time = wire.createTime orelse "",
        .update_time = wire.updateTime orelse "",
        .pending_rename_operation_id = if (wire.pendingRenameInfo) |p| nonEmpty(p.operationId) else null,
    };
}

/// One ManagedFolder resource: the Folder shape, under its own kind.
pub fn decodeManagedFolder(arena: Allocator, body: []const u8) DecodeError!types.ManagedFolderInfo {
    return managedFolderFromWire(try parseWire(WireFolder, arena, body));
}

/// One page of `managedFolders.list`. A list of none has no `items`.
pub fn decodeManagedFolderPage(arena: Allocator, body: []const u8) DecodeError!types.ManagedFolderPage {
    const wire = try parseWire(struct {
        items: ?[]const WireFolder = null,
        nextPageToken: ?[]const u8 = null,
    }, arena, body);
    const listed = wire.items orelse &.{};
    const managed = try arena.alloc(types.ManagedFolderInfo, listed.len);
    for (listed, managed) |w, *info| info.* = try managedFolderFromWire(w);
    return .{ .managed_folders = managed, .next_page_token = nonEmpty(wire.nextPageToken) };
}

fn managedFolderFromWire(wire: WireFolder) DecodeError!types.ManagedFolderInfo {
    return .{
        .name = nonEmpty(wire.name) orelse return error.InvalidResponse,
        .bucket = wire.bucket orelse "",
        .metageneration = try u64FromValue(wire.metageneration),
        .create_time = wire.createTime orelse "",
        .update_time = wire.updateTime orelse "",
    };
}

/// How a bucket stores names, from `buckets.getStorageLayout`. Cloud
/// Storage leaves `hierarchicalNamespace` out for a flat bucket;
/// fake-gcs-server sends `enabled: false` for every bucket, a bucket made
/// hierarchical included.
pub fn decodeStorageLayout(arena: Allocator, body: []const u8) DecodeError!types.StorageLayout {
    const wire = try parseWire(struct {
        location: ?[]const u8 = null,
        locationType: ?[]const u8 = null,
        hierarchicalNamespace: ?struct { enabled: ?bool = null } = null,
    }, arena, body);
    return .{
        .location = wire.location orelse "",
        .location_type = wire.locationType orelse "",
        .hierarchical_namespace = if (wire.hierarchicalNamespace) |h| h.enabled orelse false else false,
    };
}

const WireBucket = struct {
    name: ?[]const u8 = null,
    location: ?[]const u8 = null,
    storageClass: ?[]const u8 = null,
    timeCreated: ?[]const u8 = null,
    metageneration: ?std.json.Value = null,
    generation: ?std.json.Value = null,
    projectNumber: ?std.json.Value = null,
    locationType: ?[]const u8 = null,
    updated: ?[]const u8 = null,
    versioning: ?struct { enabled: ?bool = null } = null,
    softDeletePolicy: ?WireSoftDeletePolicy = null,
    billing: ?struct { requesterPays: ?bool = null } = null,
    encryption: ?struct { defaultKmsKeyName: ?[]const u8 = null } = null,
    labels: ?std.json.ArrayHashMap(?[]const u8) = null,
    /// Each rule whole, so that what this library does not know about a
    /// rule can be told from what it does.
    lifecycle: ?struct { rule: ?[]const std.json.Value = null } = null,
    iamConfiguration: ?WireIamConfiguration = null,
    softDeleteTime: ?[]const u8 = null,
    hardDeleteTime: ?[]const u8 = null,
    retentionPolicy: ?WireRetentionPolicy = null,
    defaultEventBasedHold: ?bool = null,
    objectRetention: ?struct { mode: ?[]const u8 = null } = null,
    hierarchicalNamespace: ?struct { enabled: ?bool = null } = null,
};

const WireRetentionPolicy = struct {
    retentionPeriod: ?std.json.Value = null,
    effectiveTime: ?[]const u8 = null,
    isLocked: ?bool = null,
};

const WireSoftDeletePolicy = struct {
    retentionDurationSeconds: ?std.json.Value = null,
    effectiveTime: ?[]const u8 = null,
};

const WireIamConfiguration = struct {
    uniformBucketLevelAccess: ?struct { enabled: ?bool = null } = null,
    publicAccessPrevention: ?[]const u8 = null,
};

const WireBucketPage = struct {
    items: ?[]const WireBucket = null,
    nextPageToken: ?[]const u8 = null,
};

fn objectFromWire(arena: Allocator, wire: WireObject) DecodeError!types.ObjectInfo {
    return .{
        .name = wire.name orelse "",
        .bucket = wire.bucket orelse "",
        .size = try u64FromValue(wire.size),
        .generation = try u64FromValue(wire.generation),
        .metageneration = try u64FromValue(wire.metageneration),
        .content_type = wire.contentType orelse "",
        .cache_control = nonEmpty(wire.cacheControl),
        .content_disposition = nonEmpty(wire.contentDisposition),
        .content_encoding = nonEmpty(wire.contentEncoding),
        .content_language = nonEmpty(wire.contentLanguage),
        .crc32c = try crc32cFromWire(wire.crc32c),
        .md5 = try md5FromWire(wire.md5Hash),
        .component_count = if (wire.componentCount == null) null else std.math.cast(
            u32,
            try u64FromValue(wire.componentCount),
        ) orelse return error.InvalidResponse,
        .etag = wire.etag orelse "",
        .storage_class = wire.storageClass orelse "",
        .time_created = wire.timeCreated orelse "",
        .updated = wire.updated orelse "",
        .metadata = try metadataFromWire(arena, wire.metadata),
        .time_deleted = nonEmpty(wire.timeDeleted),
        .soft_delete_time = nonEmpty(wire.softDeleteTime),
        .hard_delete_time = nonEmpty(wire.hardDeleteTime),
        .restore_token = nonEmpty(wire.restoreToken),
        .kms_key_name = nonEmpty(wire.kmsKeyName),
        .encryption_key_sha256 = if (wire.customerEncryption) |c| try sha256FromWire(c.keySha256) else null,
        // Absent until set, `false` once released.
        .temporary_hold = wire.temporaryHold orelse false,
        .event_based_hold = wire.eventBasedHold orelse false,
        .retention_expiration_time = nonEmpty(wire.retentionExpirationTime),
        // A retention names its time; one that does not could not be sent
        // back.
        .retention = if (wire.retention) |r| .{
            .mode = if (std.mem.eql(u8, r.mode orelse "", "Unlocked"))
                .unlocked
            else if (std.mem.eql(u8, r.mode orelse "", "Locked"))
                .locked
            else
                .unknown,
            .retain_until = (try timeOf(arena, r.retainUntilTime)) orelse return error.InvalidResponse,
        } else null,
        .acl = try acl.entriesFromWire(arena, wire.acl),
        .owner = acl.ownerFromWire(wire.owner),
    };
}

fn bucketFromWire(arena: Allocator, wire: WireBucket) DecodeError!types.BucketInfo {
    const policy: WireSoftDeletePolicy = wire.softDeletePolicy orelse .{};
    const retention = try u64FromValue(policy.retentionDurationSeconds);
    const iam: WireIamConfiguration = wire.iamConfiguration orelse .{};
    return .{
        .name = wire.name orelse "",
        .location = wire.location orelse "",
        .storage_class = wire.storageClass orelse "",
        .time_created = wire.timeCreated orelse "",
        .metageneration = try u64FromValue(wire.metageneration),
        .generation = try optionalU64FromValue(wire.generation),
        .project_number = try optionalU64FromValue(wire.projectNumber),
        .location_type = nonEmpty(wire.locationType),
        .updated = nonEmpty(wire.updated),
        .versioning = if (wire.versioning) |v| v.enabled orelse false else false,
        // A retention of 0 is soft delete turned off.
        .soft_delete = if (retention == 0) null else .{
            .retention_s = std.math.cast(u32, retention) orelse return error.InvalidResponse,
            .effective_time = nonEmpty(policy.effectiveTime),
        },
        .requester_pays = if (wire.billing) |b| b.requesterPays orelse false else false,
        .default_kms_key_name = if (wire.encryption) |e| nonEmpty(e.defaultKmsKeyName) else null,
        .labels = try labelsFromWire(arena, wire.labels),
        .lifecycle = try lifecycleFromWire(arena, if (wire.lifecycle) |l| l.rule orelse &.{} else &.{}),
        .uniform_bucket_level_access = if (iam.uniformBucketLevelAccess) |u| u.enabled orelse false else false,
        .public_access_prevention = publicAccessPreventionFromWire(iam.publicAccessPrevention),
        .soft_delete_time = nonEmpty(wire.softDeleteTime),
        .hard_delete_time = nonEmpty(wire.hardDeleteTime),
        .retention_policy = try retentionPolicyFromWire(wire.retentionPolicy),
        .default_event_based_hold = wire.defaultEventBasedHold orelse false,
        .object_retention = if (wire.objectRetention) |o| std.mem.eql(u8, o.mode orelse "", "Enabled") else false,
        .hierarchical_namespace = if (wire.hierarchicalNamespace) |h| h.enabled orelse false else false,
    };
}

/// A policy names a period of at least a second; one that names none
/// could not be sent back, so it is `InvalidResponse`.
fn retentionPolicyFromWire(wire: ?WireRetentionPolicy) DecodeError!?types.RetentionPolicy {
    const policy = wire orelse return null;
    const period = try u64FromValue(policy.retentionPeriod);
    if (period == 0) return error.InvalidResponse;
    return .{
        .period_s = period,
        .effective_time = nonEmpty(policy.effectiveTime),
        .locked = policy.isLocked orelse false,
    };
}

/// One long-running operation, as a bulk restore starts one.
pub fn decodeOperation(arena: Allocator, body: []const u8) DecodeError!types.OperationInfo {
    return operationFromWire(try parseWire(WireOperation, arena, body));
}

/// One page of a bucket's operations.
pub fn decodeOperationPage(arena: Allocator, body: []const u8) DecodeError!types.OperationPage {
    const wire = try parseWire(struct {
        operations: ?[]const WireOperation = null,
        nextPageToken: ?[]const u8 = null,
    }, arena, body);
    const listed = wire.operations orelse &.{};
    const operations = try arena.alloc(types.OperationInfo, listed.len);
    for (listed, operations) |w, *op| op.* = try operationFromWire(w);
    return .{ .operations = operations, .next_page_token = nonEmpty(wire.nextPageToken) };
}

/// One notification configuration. Its multi-word keys are in snake case,
/// unlike the rest of the API, and a field never set is absent.
pub fn decodeNotification(arena: Allocator, body: []const u8) DecodeError!types.Notification {
    return notificationFromWire(arena, try parseWire(WireNotification, arena, body));
}

/// Every notification configuration of a bucket, at most 100 and never
/// paged. A bucket with none answers no `items` at all, as measured.
pub fn decodeNotificationList(arena: Allocator, body: []const u8) DecodeError![]const types.Notification {
    const wire = try parseWire(struct { items: ?[]const WireNotification = null }, arena, body);
    const listed = wire.items orelse &.{};
    const notifications = try arena.alloc(types.Notification, listed.len);
    for (listed, notifications) |w, *n| n.* = try notificationFromWire(arena, w);
    return notifications;
}

const WireNotification = struct {
    id: ?[]const u8 = null,
    topic: ?[]const u8 = null,
    payload_format: ?[]const u8 = null,
    event_types: ?[]const []const u8 = null,
    custom_attributes: ?std.json.ArrayHashMap(?[]const u8) = null,
    object_name_prefix: ?[]const u8 = null,
    etag: ?[]const u8 = null,
};

fn notificationFromWire(arena: Allocator, w: WireNotification) DecodeError!types.Notification {
    const id = nonEmpty(w.id) orelse return error.InvalidResponse;
    const topic = nonEmpty(w.topic) orelse return error.InvalidResponse;
    const names_sent = w.event_types orelse &.{};
    const events = try arena.alloc(types.EventType, names_sent.len);
    for (names_sent, events) |name, *event| event.* = eventTypeOf(name);
    var attributes: []types.Attribute = &.{};
    if (w.custom_attributes) |map| {
        attributes = try arena.alloc(types.Attribute, map.map.count());
        for (map.map.keys(), map.map.values(), attributes) |key, value, *a| a.* = .{ .key = key, .value = value orelse "" };
    }
    return .{
        .id = id,
        .topic = topic,
        .topic_name = topicNameOf(topic),
        .payload = payloadFormatOf(w.payload_format orelse ""),
        .events = events,
        .custom_attributes = attributes,
        .object_name_prefix = w.object_name_prefix,
        .etag = nonEmpty(w.etag),
    };
}

/// The names Cloud Storage gives the event types, on configurations and on
/// messages alike.
pub fn eventTypeName(event: types.EventType) ?[]const u8 {
    return switch (event) {
        .finalize => "OBJECT_FINALIZE",
        .metadata_update => "OBJECT_METADATA_UPDATE",
        .delete => "OBJECT_DELETE",
        .archive => "OBJECT_ARCHIVE",
        .initialize => "OBJECT_INITIALIZE",
        .unknown => null,
    };
}

/// A type this library does not know is `.unknown`, never an error: Cloud
/// Storage added `OBJECT_INITIALIZE` long after the other four.
pub fn eventTypeOf(name: []const u8) types.EventType {
    inline for (@typeInfo(types.EventType).@"enum".field_names) |field_name| {
        const event = @field(types.EventType, field_name);
        if (eventTypeName(event)) |known| if (std.mem.eql(u8, name, known)) return event;
    }
    return .unknown;
}

pub fn payloadFormatName(format: types.PayloadFormat) ?[]const u8 {
    return switch (format) {
        .json => "JSON_API_V1",
        .none => "NONE",
        .unknown => null,
    };
}

pub fn payloadFormatOf(name: []const u8) types.PayloadFormat {
    if (std.mem.eql(u8, name, "JSON_API_V1")) return .json;
    if (std.mem.eql(u8, name, "NONE")) return .none;
    return .unknown;
}

/// `//pubsub.googleapis.com/projects/P/topics/T` taken apart, or null for
/// any other form.
pub fn topicNameOf(topic: []const u8) ?types.TopicName {
    const prefix = "//pubsub.googleapis.com/projects/";
    if (!std.mem.startsWith(u8, topic, prefix)) return null;
    const rest = topic[prefix.len..];
    const cut = std.mem.indexOf(u8, rest, "/topics/") orelse return null;
    const project = rest[0..cut];
    const id = rest[cut + "/topics/".len ..];
    if (project.len == 0 or id.len == 0) return null;
    if (std.mem.indexOfScalar(u8, project, '/') != null or std.mem.indexOfScalar(u8, id, '/') != null) return null;
    return .{ .project = project, .topic = id };
}

const WireOperation = struct {
    /// `projects/_/buckets/{bucket}/operations/{id}`.
    name: ?[]const u8 = null,
    done: ?bool = null,
    @"error": ?struct { code: ?i64 = null, message: ?[]const u8 = null } = null,
    metadata: ?WireOperationMetadata = null,
    response: ?WireOperationResponse = null,
};

/// A bulk restore's `BulkRestoreObjectsMetadata` and a rename's
/// `RenameFolderMetadata`, one struct: the fields the `@type` does not
/// bring stay absent.
const WireOperationMetadata = struct {
    @"@type": ?[]const u8 = null,
    commonMetadata: ?WireCommonMetadata = null,
    succeededCount: ?std.json.Value = null,
    skippedCount: ?std.json.Value = null,
    failedCount: ?std.json.Value = null,
    sourceFolderId: ?[]const u8 = null,
    destinationFolderId: ?[]const u8 = null,
};

/// A finished rename's `response` is the CONTROL-PLANE folder, not
/// `storage#folder`: a long `name` and no bucket or id fields, as measured
/// on 2026-10-02.
const WireOperationResponse = struct {
    @"@type": ?[]const u8 = null,
    name: ?[]const u8 = null,
    metageneration: ?std.json.Value = null,
    createTime: ?[]const u8 = null,
    updateTime: ?[]const u8 = null,
};

const WireCommonMetadata = struct {
    createTime: ?[]const u8 = null,
    updateTime: ?[]const u8 = null,
    endTime: ?[]const u8 = null,
    requestedCancellation: ?bool = null,
    /// -1 while the server cannot say.
    progressPercent: ?i64 = null,
};

/// An operation that names no id cannot be followed, so it is
/// `InvalidResponse`.
fn operationFromWire(wire: WireOperation) DecodeError!types.OperationInfo {
    const name = wire.name orelse return error.InvalidResponse;
    const slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse return error.InvalidResponse;
    const id = name[slash + 1 ..];
    if (id.len == 0) return error.InvalidResponse;
    const metadata: WireOperationMetadata = wire.metadata orelse .{};
    const common: WireCommonMetadata = metadata.commonMetadata orelse .{};
    const progress = common.progressPercent orelse -1;
    const type_name = metadata.@"@type" orelse "";
    const kind: types.OperationKind = if (std.mem.endsWith(u8, type_name, "BulkRestoreObjectsMetadata"))
        .bulk_restore
    else if (std.mem.endsWith(u8, type_name, "RenameFolderMetadata"))
        .rename_folder
    else
        .unknown;
    return .{
        .id = id,
        .done = wire.done orelse false,
        .kind = kind,
        .failure = if (wire.@"error") |e| .{
            .code = std.math.cast(i32, e.code orelse 0) orelse return error.InvalidResponse,
            .message = e.message orelse "",
        } else null,
        .progress_percent = if (progress < 0 or progress > 100) null else @intCast(progress),
        .requested_cancellation = common.requestedCancellation orelse false,
        .succeeded = try u64FromValue(metadata.succeededCount),
        .skipped = try u64FromValue(metadata.skippedCount),
        .failed = try u64FromValue(metadata.failedCount),
        .source_folder = nonEmpty(metadata.sourceFolderId),
        .destination_folder = nonEmpty(metadata.destinationFolderId),
        .folder = try folderFromResponse(wire.response),
        .create_time = nonEmpty(common.createTime),
        .update_time = nonEmpty(common.updateTime),
        .end_time = nonEmpty(common.endTime),
    };
}

/// The control-plane folder a finished rename answers with, read back into
/// the `storage#folder` shape: the path after `/folders/` and the bucket
/// after `/buckets/`, from its one long name.
fn folderFromResponse(wire: ?WireOperationResponse) DecodeError!?types.FolderInfo {
    const response = wire orelse return null;
    if (!std.mem.endsWith(u8, response.@"@type" orelse "", ".Folder")) return null;
    const name = response.name orelse return error.InvalidResponse;
    const folders_at = std.mem.indexOf(u8, name, "/folders/") orelse return error.InvalidResponse;
    const buckets_at = std.mem.indexOf(u8, name, "/buckets/") orelse return error.InvalidResponse;
    const path = name[folders_at + "/folders/".len ..];
    if (path.len == 0) return error.InvalidResponse;
    return .{
        .name = path,
        .bucket = name[buckets_at + "/buckets/".len .. folders_at],
        .metageneration = try u64FromValue(response.metageneration),
        .create_time = response.createTime orelse "",
        .update_time = response.updateTime orelse "",
    };
}

fn labelsFromWire(arena: Allocator, wire: ?std.json.ArrayHashMap(?[]const u8)) Allocator.Error![]const types.Label {
    const map = (wire orelse return &.{}).map;
    const out = try arena.alloc(types.Label, map.count());
    for (map.keys(), map.values(), out) |k, v, *label| label.* = .{ .key = k, .value = v orelse "" };
    return out;
}

/// "unspecified" is the old name of "inherited", which the server still
/// takes, and answers as "inherited".
fn publicAccessPreventionFromWire(text: ?[]const u8) types.PublicAccessPrevention {
    const t = text orelse return .inherited;
    if (std.mem.eql(u8, t, "inherited") or std.mem.eql(u8, t, "unspecified")) return .inherited;
    if (std.mem.eql(u8, t, "enforced")) return .enforced;
    return .unknown;
}

fn lifecycleFromWire(arena: Allocator, rules: []const std.json.Value) DecodeError![]const types.LifecycleRule {
    const out = try arena.alloc(types.LifecycleRule, rules.len);
    for (rules, out) |value, *rule| rule.* = try ruleFromWire(arena, value);
    return out;
}

/// A rule whose action, condition, or anything else about it this library
/// does not know is `unrecognized`: sent back without that part, it would
/// no longer be the rule the bucket has.
fn ruleFromWire(arena: Allocator, value: std.json.Value) DecodeError!types.LifecycleRule {
    const fields = objectOf(value) orelse return error.InvalidResponse;
    var rule: types.LifecycleRule = .{ .action = .unknown, .condition = .{} };
    var it = fields.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "action")) {
            rule.action = try actionFromWire(entry.value_ptr.*, &rule.unrecognized);
        } else if (std.mem.eql(u8, key, "condition")) {
            rule.condition = try conditionFromWire(arena, entry.value_ptr.*, &rule.unrecognized);
        } else {
            rule.unrecognized = true;
        }
    }
    if (rule.action == .unknown) rule.unrecognized = true;
    return rule;
}

fn actionFromWire(value: std.json.Value, unrecognized: *bool) DecodeError!types.LifecycleRule.Action {
    const fields = objectOf(value) orelse return error.InvalidResponse;
    var kind: ?[]const u8 = null;
    var class: ?[]const u8 = null;
    var it = fields.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "type")) {
            kind = try stringFromValue(entry.value_ptr.*);
        } else if (std.mem.eql(u8, key, "storageClass")) {
            class = try stringFromValue(entry.value_ptr.*);
        } else {
            unrecognized.* = true;
        }
    }
    const k = kind orelse return .unknown;
    if (std.mem.eql(u8, k, "Delete")) return .delete;
    if (std.mem.eql(u8, k, "SetStorageClass")) return .{ .set_storage_class = class orelse "" };
    if (std.mem.eql(u8, k, "AbortIncompleteMultipartUpload")) return .abort_incomplete_multipart_upload;
    return .unknown;
}

fn conditionFromWire(
    arena: Allocator,
    value: std.json.Value,
    unrecognized: *bool,
) DecodeError!types.LifecycleRule.Condition {
    const fields = objectOf(value) orelse return error.InvalidResponse;
    var c: types.LifecycleRule.Condition = .{};
    var it = fields.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        // A condition sent as null is a condition not set.
        if (v == .null) continue;
        if (std.mem.eql(u8, key, "age")) {
            c.age_days = try u32FromValue(v);
        } else if (std.mem.eql(u8, key, "createdBefore")) {
            c.created_before = try stringFromValue(v);
        } else if (std.mem.eql(u8, key, "customTimeBefore")) {
            c.custom_time_before = try stringFromValue(v);
        } else if (std.mem.eql(u8, key, "daysSinceCustomTime")) {
            c.days_since_custom_time = try u32FromValue(v);
        } else if (std.mem.eql(u8, key, "daysSinceNoncurrentTime")) {
            c.days_since_noncurrent_time = try u32FromValue(v);
        } else if (std.mem.eql(u8, key, "isLive")) {
            c.is_live = switch (v) {
                .bool => |b| b,
                else => return error.InvalidResponse,
            };
        } else if (std.mem.eql(u8, key, "matchesPrefix")) {
            c.matches_prefix = try stringsFromValue(arena, v);
        } else if (std.mem.eql(u8, key, "matchesSuffix")) {
            c.matches_suffix = try stringsFromValue(arena, v);
        } else if (std.mem.eql(u8, key, "matchesStorageClass")) {
            c.matches_storage_class = try stringsFromValue(arena, v);
        } else if (std.mem.eql(u8, key, "noncurrentTimeBefore")) {
            c.noncurrent_time_before = try stringFromValue(v);
        } else if (std.mem.eql(u8, key, "numNewerVersions")) {
            c.num_newer_versions = try u32FromValue(v);
        } else if (std.mem.eql(u8, key, "sizeAboveBytes")) {
            c.size_above_bytes = try u64FromValue(v);
        } else if (std.mem.eql(u8, key, "sizeBelowBytes")) {
            c.size_below_bytes = try u64FromValue(v);
        } else {
            unrecognized.* = true;
        }
    }
    return c;
}

fn objectOf(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |o| o,
        else => null,
    };
}

fn stringFromValue(value: std.json.Value) DecodeError![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.InvalidResponse,
    };
}

fn stringsFromValue(arena: Allocator, value: std.json.Value) DecodeError![]const []const u8 {
    const items = switch (value) {
        .array => |a| a.items,
        else => return error.InvalidResponse,
    };
    const out = try arena.alloc([]const u8, items.len);
    for (items, out) |item, *text| text.* = try stringFromValue(item);
    return out;
}

fn metadataFromWire(
    arena: Allocator,
    wire: ?std.json.ArrayHashMap(?[]const u8),
) Allocator.Error![]const types.Metadata {
    const map = (wire orelse return &.{}).map;
    const out = try arena.alloc(types.Metadata, map.count());
    for (map.keys(), map.values(), out) |k, v, *entry| entry.* = .{ .key = k, .value = v orelse "" };
    return out;
}

/// A `u64` the API sends as a decimal string, though emulators also send a
/// plain number. Absent reads as 0.
fn u64FromValue(value: ?std.json.Value) DecodeError!u64 {
    return switch (value orelse return 0) {
        .string, .number_string => |text| std.fmt.parseInt(u64, text, 10) catch error.InvalidResponse,
        .integer => |n| if (n >= 0) @intCast(n) else error.InvalidResponse,
        else => error.InvalidResponse,
    };
}

/// `u64FromValue`, but absent reads as null.
fn optionalU64FromValue(value: ?std.json.Value) DecodeError!?u64 {
    if (value == null) return null;
    return try u64FromValue(value);
}

/// An int32 field, which the API sends as a JSON number.
fn u32FromValue(value: std.json.Value) DecodeError!u32 {
    return std.math.cast(u32, try u64FromValue(value)) orelse error.InvalidResponse;
}

fn crc32cFromWire(text: ?[]const u8) DecodeError!?u32 {
    const t = text orelse return null;
    return core.crc32c.fromBase64(t) catch error.InvalidResponse;
}

fn md5FromWire(text: ?[]const u8) DecodeError!?[16]u8 {
    const t = text orelse return null;
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(t) catch return error.InvalidResponse;
    if (len != 16) return error.InvalidResponse;
    var digest: [16]u8 = undefined;
    decoder.decode(&digest, t) catch return error.InvalidResponse;
    return digest;
}

fn sha256FromWire(text: ?[]const u8) DecodeError!?[32]u8 {
    const t = text orelse return null;
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(t) catch return error.InvalidResponse;
    if (len != 32) return error.InvalidResponse;
    var digest: [32]u8 = undefined;
    decoder.decode(&digest, t) catch return error.InvalidResponse;
    return digest;
}

/// A time as text, or as a protocol buffer Timestamp's `seconds` and
/// `nanos` written out in RFC 3339, or null for anything else.
fn timeOf(arena: Allocator, value: ?std.json.Value) Allocator.Error!?[]const u8 {
    const v = value orelse return null;
    switch (v) {
        .string => |s| return nonEmpty(s),
        .object => |o| {
            const seconds = intOf(o.get("seconds") orelse return null) orelse return null;
            const nanos = if (o.get("nanos")) |n| intOf(n) orelse return null else 0;
            if (seconds < 0 or nanos < 0 or nanos >= std.time.ns_per_s) return null;
            const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
            const year_day = epoch.getEpochDay().calculateYearDay();
            if (year_day.year > 9999) return null;
            const month_day = year_day.calculateMonthDay();
            const day = epoch.getDaySeconds();
            const date = try arena.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
                year_day.year,         month_day.month.numeric(), @as(u8, month_day.day_index) + 1,
                day.getHoursIntoDay(), day.getMinutesIntoHour(),  day.getSecondsIntoMinute(),
            });
            if (nanos == 0) return try arena.print("{s}Z", .{date});
            return try arena.print("{s}.{d:0>9}Z", .{ date, @as(u64, @intCast(nanos)) });
        },
        else => return null,
    }
}

/// A JSON integer, or a decimal string of one, as proto3 writes an int64.
fn intOf(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |n| n,
        .string, .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn nonEmpty(text: ?[]const u8) ?[]const u8 {
    const t = text orelse return null;
    return if (t.len == 0) null else t;
}

fn parseWire(comptime T: type, arena: Allocator, body: []const u8) DecodeError!T {
    return std.json.parseFromSliceLeaky(T, arena, body, .{
        .ignore_unknown_fields = true,
        // Proto3 JSON parsers keep the last duplicate rather than failing.
        .duplicate_field_behavior = .use_last,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
}

const testing = std.testing;
const test_util = @import("test_util.zig");

/// The spec's fixture: the object `hello world\n`, whose real CRC-32C is
/// 0xF0FF7292, "8P9ykg==" in the API's encoding.
const fixture_object =
    \\{
    \\  "kind": "storage#object",
    \\  "name": "reports/2026/q3.txt",
    \\  "bucket": "my-bucket",
    \\  "generation": "1758448800123456",
    \\  "metageneration": "1",
    \\  "size": "12",
    \\  "contentType": "text/plain",
    \\  "crc32c": "8P9ykg==",
    \\  "md5Hash": "b1kCrCNwJL3QwXbLkwY9xA==",
    \\  "etag": "CMDQ9t7q4o8DEAE=",
    \\  "storageClass": "STANDARD",
    \\  "timeCreated": "2026-09-21T10:00:00.123Z",
    \\  "updated": "2026-09-21T10:00:00.123Z",
    \\  "metadata": { "origin": "zig" }
    \\}
;

test "decode the spec's object fixture" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const info = try decodeObject(arena.allocator(), fixture_object);
    try testing.expectEqualStrings("reports/2026/q3.txt", info.name);
    try testing.expectEqualStrings("my-bucket", info.bucket);
    try testing.expectEqual(12, info.size);
    try testing.expectEqual(1758448800123456, info.generation);
    try testing.expectEqual(1, info.metageneration);
    try testing.expectEqualStrings("text/plain", info.content_type);
    try testing.expectEqual(0xf0ff7292, info.crc32c.?);
    try testing.expectEqual(core.crc32c.hash("hello world\n"), info.crc32c.?);
    var md5: [16]u8 = undefined;
    std.crypto.hash.Md5.hash("hello world\n", &md5, .{});
    try testing.expectEqualSlices(u8, &md5, &info.md5.?);
    try testing.expectEqualStrings("CMDQ9t7q4o8DEAE=", info.etag);
    try testing.expectEqualStrings("STANDARD", info.storage_class);
    try testing.expectEqualStrings("2026-09-21T10:00:00.123Z", info.time_created);
    try testing.expectEqualStrings("zig", info.metadataValue("origin").?);
}

test "string integers: string, number, above 32 bits, negative, garbage" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Emulators are not consistent: accept a JSON number too.
    const number = try decodeObject(a, "{\"size\": 12, \"generation\": 1758448800123456}");
    try testing.expectEqual(12, number.size);
    try testing.expectEqual(1758448800123456, number.generation);
    // Absent means zero, never a parse failure.
    const absent = try decodeObject(a, "{\"name\":\"x\"}");
    try testing.expectEqual(0, absent.size);
    try testing.expectEqual(null, absent.crc32c);
    try testing.expectEqual(null, absent.md5);
    // A value above 32 bits survives.
    const big = try decodeObject(a, "{\"size\":\"5497558138880\"}");
    try testing.expectEqual(5_497_558_138_880, big.size);
    for ([_][]const u8{
        "{\"size\":\"-1\"}",
        "{\"size\": -1}",
        "{\"size\":\"12abc\"}",
        "{\"size\":\"\"}",
        "{\"size\": true}",
        "{\"size\": 1.5}",
        "{\"size\":\"18446744073709551616\"}",
    }) |body| {
        try testing.expectError(error.InvalidResponse, decodeObject(a, body));
    }
}

test "decodeObjectSize tells an absent size from an empty object" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(12, (try decodeObjectSize(a, "{\"name\":\"x\",\"size\":\"12\"}")).?);
    try testing.expectEqual(0, (try decodeObjectSize(a, "{\"size\":\"0\"}")).?);
    try testing.expectEqual(7, (try decodeObjectSize(a, "{\"size\": 7}")).?);
    try testing.expectEqual(null, try decodeObjectSize(a, "{\"name\":\"x\"}"));
    try testing.expectEqual(null, try decodeObjectSize(a, "{\"size\": null}"));
    try testing.expectError(error.InvalidResponse, decodeObjectSize(a, "{\"size\":\"-1\"}"));
    try testing.expectError(error.InvalidResponse, decodeObjectSize(a, "not json"));
}

test "decodeCopySource: what a copy carries, and what it pins" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try decodeCopySource(a,
        \\{"name":"a","generation":"1758448800123456","metageneration":"3",
        \\ "contentType":"text/plain","cacheControl":"no-cache","contentDisposition":"",
        \\ "contentLanguage":"en","customTime":"2026-09-23T00:00:00Z",
        \\ "storageClass":"NEARLINE","metadata":{"b":"2","a":"1"}}
    );
    try testing.expectEqual(1758448800123456, source.generation);
    try testing.expectEqual(3, source.metageneration);
    try testing.expectEqualStrings("text/plain", source.content_type.?);
    try testing.expectEqualStrings("no-cache", source.cache_control.?);
    // Empty reads as absent, and absent stays absent.
    try testing.expectEqual(null, source.content_disposition);
    try testing.expectEqual(null, source.content_encoding);
    try testing.expectEqualStrings("en", source.content_language.?);
    try testing.expectEqualStrings("2026-09-23T00:00:00Z", source.custom_time.?);
    // The server's order, which the copy keeps.
    try testing.expectEqual(2, source.metadata.len);
    try testing.expectEqualStrings("b", source.metadata[0].key);
    try testing.expectEqualStrings("a", source.metadata[1].key);

    // Emulators send plain numbers.
    const plain = try decodeCopySource(a, "{\"generation\":5,\"metageneration\":1}");
    try testing.expectEqual(5, plain.generation);
    try testing.expectEqual(0, plain.metadata.len);

    // Nothing to pin a copy to is not a source a copy can use.
    try testing.expectError(error.InvalidResponse, decodeCopySource(a, "{\"metageneration\":\"1\"}"));
    try testing.expectError(error.InvalidResponse, decodeCopySource(a, "{\"generation\":\"5\"}"));
    try testing.expectError(error.InvalidResponse, decodeCopySource(a, "{\"generation\":\"x\",\"metageneration\":\"1\"}"));
}

test "checksums: malformed base64 is InvalidResponse, not a wrong value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.InvalidResponse, decodeObject(a, "{\"crc32c\":\"nope\"}"));
    try testing.expectError(error.InvalidResponse, decodeObject(a, "{\"crc32c\":\"AAAAAAAA\"}"));
    try testing.expectError(error.InvalidResponse, decodeObject(a, "{\"md5Hash\":\"8P9ykg==\"}"));
    const ok = try decodeObject(a, "{\"crc32c\":\"4waSgw==\"}");
    try testing.expectEqual(0xe3069283, ok.crc32c.?);
}

test "decode listings: items and prefixes are both optional" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // An empty listing can be nothing but its kind.
    const empty = try decodeObjectPage(a, "{ \"kind\": \"storage#objects\" }");
    try testing.expectEqual(0, empty.objects.len);
    try testing.expectEqual(0, empty.prefixes.len);
    try testing.expectEqual(null, empty.next_page_token);

    const page = try decodeObjectPage(a,
        \\{
        \\  "kind": "storage#objects",
        \\  "items": [ { "name": "reports/2026/q3.txt", "size": "12" } ],
        \\  "prefixes": [ "reports/2026/archive/" ],
        \\  "nextPageToken": "CgtyZXBvcnRzLzIwMjY="
        \\}
    );
    try testing.expectEqual(1, page.objects.len);
    try testing.expectEqualStrings("reports/2026/q3.txt", page.objects[0].name);
    try testing.expectEqual(12, page.objects[0].size);
    try testing.expectEqual(1, page.prefixes.len);
    try testing.expectEqualStrings("reports/2026/archive/", page.prefixes[0]);
    try testing.expectEqualStrings("CgtyZXBvcnRzLzIwMjY=", page.next_page_token.?);
}

test "decode buckets" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bucket = try decodeBucket(a,
        \\{"kind":"storage#bucket","name":"my-bucket","location":"US",
        \\ "storageClass":"STANDARD","timeCreated":"2026-09-21T10:00:00.000Z"}
    );
    try testing.expectEqualStrings("my-bucket", bucket.name);
    try testing.expectEqualStrings("US", bucket.location);
    try testing.expectEqualStrings("STANDARD", bucket.storage_class);

    const page = try decodeBucketPage(a,
        \\{"items":[{"name":"a"},{"name":"b"}],"nextPageToken":"t"}
    );
    try testing.expectEqual(2, page.buckets.len);
    try testing.expectEqualStrings("b", page.buckets[1].name);
    try testing.expectEqualStrings("t", page.next_page_token.?);
    const empty = try decodeBucketPage(a, "{}");
    try testing.expectEqual(0, empty.buckets.len);
    try testing.expectEqual(null, empty.next_page_token);
}

/// Captured from Cloud Storage on 2026-09-29: a bucket made with only a
/// name, a location and a class, as `create(.{})` sends.
const bucket_made_with_defaults =
    \\{
    \\  "kind": "storage#bucket",
    \\  "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-p1-04a2ab-1",
    \\  "id": "zigps-p1-04a2ab-1",
    \\  "name": "zigps-p1-04a2ab-1",
    \\  "projectNumber": "82150720798",
    \\  "generation": "1790690832240124605",
    \\  "metageneration": "1",
    \\  "location": "US",
    \\  "storageClass": "STANDARD",
    \\  "etag": "CAE=",
    \\  "timeCreated": "2026-09-29T14:07:12.505Z",
    \\  "updated": "2026-09-29T14:07:12.505Z",
    \\  "softDeletePolicy": {
    \\    "retentionDurationSeconds": "604800",
    \\    "effectiveTime": "2026-09-29T14:07:12.505Z"
    \\  },
    \\  "iamConfiguration": {
    \\    "bucketPolicyOnly": {
    \\      "enabled": false
    \\    },
    \\    "uniformBucketLevelAccess": {
    \\      "enabled": false
    \\    },
    \\    "publicAccessPrevention": "inherited"
    \\  },
    \\  "locationType": "multi-region",
    \\  "rpo": "DEFAULT"
    \\}
;

/// Captured the same day: a bucket created with every setting this library
/// sends but the default key, which needs Cloud KMS.
const bucket_with_every_setting =
    \\{
    \\  "kind": "storage#bucket",
    \\  "selfLink": "https://www.googleapis.com/storage/v1/b/zigps-p1-04a2ab-15",
    \\  "id": "zigps-p1-04a2ab-15",
    \\  "name": "zigps-p1-04a2ab-15",
    \\  "projectNumber": "82150720798",
    \\  "generation": "1790691121982943269",
    \\  "metageneration": "1",
    \\  "location": "US-CENTRAL1",
    \\  "storageClass": "STANDARD",
    \\  "etag": "CAE=",
    \\  "timeCreated": "2026-09-29T14:12:02.194Z",
    \\  "updated": "2026-09-29T14:12:02.194Z",
    \\  "versioning": {
    \\    "enabled": true
    \\  },
    \\  "lifecycle": {
    \\    "rule": [
    \\      {
    \\        "action": {
    \\          "type": "AbortIncompleteMultipartUpload"
    \\        },
    \\        "condition": {
    \\          "age": 7
    \\        }
    \\      }
    \\    ]
    \\  },
    \\  "labels": {
    \\    "env": "test",
    \\    "team": "zig"
    \\  },
    \\  "softDeletePolicy": {
    \\    "retentionDurationSeconds": "691200",
    \\    "effectiveTime": "2026-09-29T14:12:02.194Z"
    \\  },
    \\  "billing": {
    \\    "requesterPays": true
    \\  },
    \\  "iamConfiguration": {
    \\    "bucketPolicyOnly": {
    \\      "enabled": true,
    \\      "lockedTime": "2026-12-28T14:12:02.194Z"
    \\    },
    \\    "uniformBucketLevelAccess": {
    \\      "enabled": true,
    \\      "lockedTime": "2026-12-28T14:12:02.194Z"
    \\    },
    \\    "publicAccessPrevention": "enforced"
    \\  },
    \\  "locationType": "region",
    \\  "satisfiesPZI": true
    \\}
;

/// Captured the same day: every lifecycle condition, as the server writes
/// them back, on a bucket with soft delete off.
const bucket_with_every_condition =
    \\{
    \\  "kind": "storage#bucket",
    \\  "name": "zigps-p1-04a2ab-13",
    \\  "projectNumber": "82150720798",
    \\  "generation": "1790690974102440408",
    \\  "metageneration": "2",
    \\  "location": "US",
    \\  "storageClass": "STANDARD",
    \\  "etag": "CAI=",
    \\  "timeCreated": "2026-09-29T14:09:34.397Z",
    \\  "updated": "2026-09-29T14:09:35.927Z",
    \\  "lifecycle": {
    \\    "rule": [
    \\      {
    \\        "action": {
    \\          "type": "Delete"
    \\        },
    \\        "condition": {
    \\          "age": 30
    \\        }
    \\      },
    \\      {
    \\        "action": {
    \\          "storageClass": "NEARLINE",
    \\          "type": "SetStorageClass"
    \\        },
    \\        "condition": {
    \\          "age": 60,
    \\          "matchesStorageClass": [
    \\            "STANDARD"
    \\          ]
    \\        }
    \\      },
    \\      {
    \\        "action": {
    \\          "type": "AbortIncompleteMultipartUpload"
    \\        },
    \\        "condition": {
    \\          "age": 7
    \\        }
    \\      },
    \\      {
    \\        "action": {
    \\          "type": "Delete"
    \\        },
    \\        "condition": {
    \\          "createdBefore": "2026-01-01",
    \\          "isLive": false,
    \\          "numNewerVersions": 3,
    \\          "matchesStorageClass": [
    \\            "STANDARD",
    \\            "NEARLINE"
    \\          ],
    \\          "daysSinceCustomTime": 10,
    \\          "customTimeBefore": "2026-01-02",
    \\          "daysSinceNoncurrentTime": 5,
    \\          "noncurrentTimeBefore": "2026-01-03",
    \\          "matchesPrefix": [
    \\            "logs/",
    \\            "tmp/"
    \\          ],
    \\          "matchesSuffix": [
    \\            ".tmp"
    \\          ],
    \\          "sizeAboveBytes": "1000",
    \\          "sizeBelowBytes": "1000000000000"
    \\        }
    \\      }
    \\    ]
    \\  },
    \\  "softDeletePolicy": {
    \\    "retentionDurationSeconds": "0"
    \\  },
    \\  "iamConfiguration": {
    \\    "bucketPolicyOnly": {
    \\      "enabled": false
    \\    },
    \\    "uniformBucketLevelAccess": {
    \\      "enabled": false
    \\    },
    \\    "publicAccessPrevention": "inherited"
    \\  },
    \\  "locationType": "multi-region",
    \\  "rpo": "DEFAULT"
    \\}
;

test "decode a bucket made with defaults, as Cloud Storage sent it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const b = try decodeBucket(arena.allocator(), bucket_made_with_defaults);
    try testing.expectEqualStrings("zigps-p1-04a2ab-1", b.name);
    try testing.expectEqual(1, b.metageneration);
    try testing.expectEqual(1790690832240124605, b.generation.?);
    try testing.expectEqual(82150720798, b.project_number.?);
    try testing.expectEqualStrings("multi-region", b.location_type.?);
    try testing.expectEqualStrings("2026-09-29T14:07:12.505Z", b.updated.?);
    // New buckets get soft delete for 7 days, unasked.
    try testing.expectEqual(604800, b.soft_delete.?.retention_s);
    try testing.expectEqualStrings("2026-09-29T14:07:12.505Z", b.soft_delete.?.effective_time.?);
    try testing.expect(!b.versioning);
    try testing.expect(!b.requester_pays);
    try testing.expectEqual(null, b.default_kms_key_name);
    try testing.expectEqual(0, b.labels.len);
    try testing.expectEqual(0, b.lifecycle.len);
    try testing.expect(!b.uniform_bucket_level_access);
    try testing.expectEqual(.inherited, b.public_access_prevention);
}

test "decode a bucket with every setting, as Cloud Storage sent it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const b = try decodeBucket(arena.allocator(), bucket_with_every_setting);
    try testing.expectEqualStrings("US-CENTRAL1", b.location);
    try testing.expectEqualStrings("region", b.location_type.?);
    try testing.expect(b.versioning);
    try testing.expectEqual(691200, b.soft_delete.?.retention_s);
    try testing.expect(b.requester_pays);
    try testing.expectEqual(2, b.labels.len);
    try testing.expectEqualStrings("test", b.label("env").?);
    try testing.expectEqualStrings("zig", b.label("team").?);
    try testing.expectEqual(null, b.label("missing"));
    try testing.expectEqual(1, b.lifecycle.len);
    try testing.expectEqual(.abort_incomplete_multipart_upload, b.lifecycle[0].action);
    try testing.expectEqual(7, b.lifecycle[0].condition.age_days.?);
    try testing.expect(!b.lifecycle[0].unrecognized);
    try testing.expect(b.uniform_bucket_level_access);
    try testing.expectEqual(.enforced, b.public_access_prevention);
}

test "decode every lifecycle condition, as Cloud Storage sent them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const b = try decodeBucket(arena.allocator(), bucket_with_every_condition);
    // A retention of "0" is soft delete off.
    try testing.expectEqual(null, b.soft_delete);
    try testing.expectEqual(4, b.lifecycle.len);
    for (b.lifecycle) |rule| try testing.expect(!rule.unrecognized);
    try testing.expectEqual(.delete, b.lifecycle[0].action);
    try testing.expectEqual(30, b.lifecycle[0].condition.age_days.?);
    try testing.expectEqualStrings("NEARLINE", b.lifecycle[1].action.set_storage_class);
    try testing.expectEqual(60, b.lifecycle[1].condition.age_days.?);
    try testing.expectEqualStrings("STANDARD", b.lifecycle[1].condition.matches_storage_class[0]);
    try testing.expectEqual(.abort_incomplete_multipart_upload, b.lifecycle[2].action);
    const c = b.lifecycle[3].condition;
    try testing.expectEqual(null, c.age_days);
    try testing.expectEqualStrings("2026-01-01", c.created_before.?);
    try testing.expectEqualStrings("2026-01-02", c.custom_time_before.?);
    try testing.expectEqual(10, c.days_since_custom_time.?);
    try testing.expectEqual(5, c.days_since_noncurrent_time.?);
    try testing.expectEqual(false, c.is_live.?);
    try testing.expectEqual(2, c.matches_prefix.len);
    try testing.expectEqualStrings("tmp/", c.matches_prefix[1]);
    try testing.expectEqualStrings(".tmp", c.matches_suffix[0]);
    try testing.expectEqual(2, c.matches_storage_class.len);
    try testing.expectEqualStrings("2026-01-03", c.noncurrent_time_before.?);
    try testing.expectEqual(3, c.num_newer_versions.?);
    // Sizes come as strings, days as numbers; either decodes.
    try testing.expectEqual(1000, c.size_above_bytes.?);
    try testing.expectEqual(1_000_000_000_000, c.size_below_bytes.?);
}

test "decode lifecycle rules with parts this library does not know" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = try decodeBucket(a,
        \\{"lifecycle":{"rule":[
        \\ {"action":{"type":"Delete"},"condition":{"age":30,"matchesPattern":"tmp/.*"}},
        \\ {"action":{"type":"Archive"},"condition":{"age":1}},
        \\ {"action":{"type":"Delete","fromTheFuture":1},"condition":{"age":2}},
        \\ {"action":{"type":"Delete"},"condition":{"age":3},"enabled":false},
        \\ {"condition":{"age":4}},
        \\ {"action":{"type":"Delete"},"condition":{"age":5,"isLive":null}}
        \\]}}
    );
    try testing.expectEqual(6, b.lifecycle.len);
    // Kept, with what was understood, and marked so it is never sent back.
    try testing.expect(b.lifecycle[0].unrecognized);
    try testing.expectEqual(.delete, b.lifecycle[0].action);
    try testing.expectEqual(30, b.lifecycle[0].condition.age_days.?);
    try testing.expect(b.lifecycle[1].unrecognized);
    try testing.expectEqual(.unknown, b.lifecycle[1].action);
    try testing.expect(b.lifecycle[2].unrecognized);
    try testing.expect(b.lifecycle[3].unrecognized);
    try testing.expect(b.lifecycle[4].unrecognized);
    try testing.expectEqual(.unknown, b.lifecycle[4].action);
    // A condition sent as null is simply not set.
    try testing.expect(!b.lifecycle[5].unrecognized);
    try testing.expectEqual(null, b.lifecycle[5].condition.is_live);
}

test "decode public access prevention: old names, and ones not known yet" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, types.PublicAccessPrevention }{
        .{ "{}", .inherited },
        .{ "{\"iamConfiguration\":{}}", .inherited },
        .{ "{\"iamConfiguration\":{\"publicAccessPrevention\":\"inherited\"}}", .inherited },
        .{ "{\"iamConfiguration\":{\"publicAccessPrevention\":\"unspecified\"}}", .inherited },
        .{ "{\"iamConfiguration\":{\"publicAccessPrevention\":\"enforced\"}}", .enforced },
        .{ "{\"iamConfiguration\":{\"publicAccessPrevention\":\"strict\"}}", .unknown },
    };
    for (cases) |case| {
        errdefer std.debug.print("body: {s}\n", .{case[0]});
        try testing.expectEqual(case[1], (try decodeBucket(a, case[0])).public_access_prevention);
    }
}

test "decode bucket settings that are malformed as InvalidResponse" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "{\"metageneration\":\"x\"}",
        "{\"generation\":-1}",
        "{\"softDeletePolicy\":{\"retentionDurationSeconds\":\"4294967296\"}}",
        "{\"softDeletePolicy\":{\"retentionDurationSeconds\":true}}",
        "{\"lifecycle\":{\"rule\":[1]}}",
        "{\"lifecycle\":{\"rule\":[{\"action\":\"Delete\"}]}}",
        "{\"lifecycle\":{\"rule\":[{\"action\":{\"type\":1}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"condition\":[]}]}}",
        "{\"lifecycle\":{\"rule\":[{\"condition\":{\"age\":-1}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"condition\":{\"age\":4294967296}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"condition\":{\"age\":\"x\"}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"condition\":{\"isLive\":\"true\"}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"condition\":{\"matchesPrefix\":\"a/\"}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"condition\":{\"matchesPrefix\":[1]}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"condition\":{\"createdBefore\":20260101}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"condition\":{\"sizeAboveBytes\":\"-5\"}}]}}",
    }) |body| {
        errdefer std.debug.print("body: {s}\n", .{body});
        try testing.expectError(error.InvalidResponse, decodeBucket(a, body));
    }
    // Emulators send numbers where Google sends strings, and the reverse.
    const loose = try decodeBucket(a,
        \\{"metageneration":3,"softDeletePolicy":{"retentionDurationSeconds":604800},
        \\ "lifecycle":{"rule":[{"action":{"type":"Delete"},"condition":{"age":"7","sizeAboveBytes":10}}]}}
    );
    try testing.expectEqual(3, loose.metageneration);
    try testing.expectEqual(604800, loose.soft_delete.?.retention_s);
    try testing.expectEqual(7, loose.lifecycle[0].condition.age_days.?);
    try testing.expectEqual(10, loose.lifecycle[0].condition.size_above_bytes.?);
}

test "decode operations: progress unknown, counts as strings or numbers, and malformed ones" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const op = try decodeOperation(a,
        \\{"name":"projects/_/buckets/b/operations/abc","done":false,
        \\ "metadata":{"commonMetadata":{"progressPercent":-1,"requestedCancellation":true},
        \\ "succeededCount":"3","skippedCount":13,"failedCount":"0"}}
    );
    try testing.expectEqualStrings("abc", op.id);
    try testing.expectEqual(null, op.progress_percent);
    try testing.expect(op.requested_cancellation);
    try testing.expectEqual(3, op.succeeded);
    try testing.expectEqual(13, op.skipped);
    // A percentage the server does give comes through; one outside 0 to
    // 100 reads as unknown.
    try testing.expectEqual(40, (try decodeOperation(a, "{\"name\":\"x/1\",\"metadata\":{\"commonMetadata\":{\"progressPercent\":40}}}")).progress_percent.?);
    try testing.expectEqual(null, (try decodeOperation(a, "{\"name\":\"x/1\",\"metadata\":{\"commonMetadata\":{\"progressPercent\":101}}}")).progress_percent);
    // Nothing but a name is still an operation, not done.
    const bare = try decodeOperation(a, "{\"name\":\"x/1\"}");
    try testing.expect(!bare.done);
    try testing.expectEqual(null, bare.failure);
    for ([_][]const u8{
        "{}",
        "{\"name\":\"\"}",
        "{\"name\":\"projects/_/buckets/b/operations/\"}",
        "{\"name\":\"x/1\",\"error\":{\"code\":4294967296}}",
        "{\"name\":\"x/1\",\"metadata\":{\"succeededCount\":\"-1\"}}",
        "{\"name\":\"x/1\",\"done\":\"yes\"}",
    }) |body| {
        errdefer std.debug.print("body: {s}\n", .{body});
        try testing.expectError(error.InvalidResponse, decodeOperation(a, body));
    }
    const page = try decodeOperationPage(a, "{\"kind\":\"storage#operations\"}");
    try testing.expectEqual(0, page.operations.len);
    try testing.expectError(error.InvalidResponse, decodeOperationPage(a, "{\"operations\":[{}]}"));
}

test "decode: objects under a customer key and a Cloud KMS key, as production answers them" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A get without the key, measured 2026-09-30: no checksums, the key's
    // SHA-256 always.
    const csek = try decodeObject(arena,
        \\{"kind":"storage#object","name":"c-multi","bucket":"zigps-keys-e7ec9f","generation":"1790770794172372",
        \\ "metageneration":"1","contentType":"application/octet-stream","storageClass":"STANDARD","size":"1000",
        \\ "etag":"CNSfvoillpcDEAE=","timeCreated":"2026-09-30T12:19:54.179Z","updated":"2026-09-30T12:19:54.179Z",
        \\ "customerEncryption":{"encryptionAlgorithm":"AES256","keySha256":"BqNwOZCiaUd/2oFWpDECAXpswNQZdixo0rzhW76HHJ0="}}
    );
    try testing.expectEqual(null, csek.crc32c);
    try testing.expectEqual(null, csek.md5);
    var want: [32]u8 = undefined;
    _ = try std.base64.standard.Decoder.decode(&want, "BqNwOZCiaUd/2oFWpDECAXpswNQZdixo0rzhW76HHJ0=");
    try testing.expectEqualSlices(u8, &want, &csek.encryption_key_sha256.?);
    try testing.expectEqual(null, csek.kms_key_name);

    const cmek = try decodeObject(arena,
        \\{"kind":"storage#object","name":"k-multi","bucket":"zigps-keys-e7ec9f","generation":"1790770810386787",
        \\ "metageneration":"1","contentType":"application/octet-stream","storageClass":"STANDARD","size":"1000",
        \\ "md5Hash":"v+DlQO/2CwP5ix3UzJKA2A==","crc32c":"RPyzdw==","etag":"COPym5CllpcDEAE=",
        \\ "kmsKeyName":"projects/extractctl/locations/us-central1/keyRings/zigps-keys/cryptoKeys/zigps-k1/cryptoKeyVersions/1",
        \\ "timeCreated":"2026-09-30T12:20:10.395Z","updated":"2026-09-30T12:20:10.395Z"}
    );
    try testing.expectEqualStrings("projects/extractctl/locations/us-central1/keyRings/zigps-keys/cryptoKeys/zigps-k1/cryptoKeyVersions/1", cmek.kms_key_name.?);
    try testing.expectEqual(null, cmek.encryption_key_sha256);
    try testing.expect(cmek.crc32c != null);

    // A SHA-256 that is not one is a response this library cannot trust.
    try testing.expectError(error.InvalidResponse, decodeObject(arena, "{\"customerEncryption\":{\"keySha256\":\"AAAA\"}}"));
    // An encryption block naming no hash names none.
    try testing.expectEqual(null, (try decodeObject(arena, "{\"customerEncryption\":{}}")).encryption_key_sha256);

    try testing.expectEqualStrings(
        "service-82150720798@gs-project-accounts.iam.gserviceaccount.com",
        try decodeServiceAgent(arena, "{\"kind\":\"storage#serviceAccount\",\"email_address\":\"service-82150720798@gs-project-accounts.iam.gserviceaccount.com\"}"),
    );
    try testing.expectError(error.InvalidResponse, decodeServiceAgent(arena, "{\"email_address\":\"\"}"));
    try testing.expectError(error.InvalidResponse, decodeServiceAgent(arena, "[]"));
}

fn decodeArbitrary(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Total: any body decodes or fails with InvalidResponse, never a crash.
    _ = decodeObject(a, input) catch |err| try testing.expectEqual(error.InvalidResponse, err);
    _ = decodeObjectPage(a, input) catch |err| try testing.expectEqual(error.InvalidResponse, err);
    _ = decodeBucket(a, input) catch |err| try testing.expectEqual(error.InvalidResponse, err);
    _ = decodeBucketPage(a, input) catch |err| try testing.expectEqual(error.InvalidResponse, err);
    _ = decodeCopySource(a, input) catch |err| try testing.expectEqual(error.InvalidResponse, err);
    _ = decodeOperation(a, input) catch |err| try testing.expectEqual(error.InvalidResponse, err);
    _ = decodeOperationPage(a, input) catch |err| try testing.expectEqual(error.InvalidResponse, err);
}

test "fuzz decoding: arbitrary bodies never crash" {
    try test_util.fuzzBytes({}, decodeArbitrary, .{ .corpus = &.{
        fixture_object,
        "{ \"kind\": \"storage#objects\" }",
        "{\"items\":[{\"size\":\"-1\"}]}",
        "{\"prefixes\":[null]}",
        "{\"metadata\":{\"k\":null}}",
        "<html>502</html>",
        "{\"crc32c\":\"\\u0000\"}",
        bucket_with_every_setting,
        bucket_with_every_condition,
        "{\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"Delete\"},\"condition\":{\"age\":-1}}]}}",
        "{\"labels\":{\"k\":null},\"softDeletePolicy\":{\"retentionDurationSeconds\":\"0\"}}",
        "{\"name\":\"projects/_/buckets/b/operations/abc\",\"done\":true,\"error\":{\"code\":1,\"message\":\"x\"}}",
        "{\"operations\":[{\"name\":\"a/b\",\"metadata\":{\"commonMetadata\":{\"progressPercent\":-1}}}]}",
    } });
}

test "decode rewrite answers: unfinished, finished, and odd ones" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const unfinished = try decodeRewrite(a,
        \\{"kind":"storage#rewriteResponse","totalBytesRewritten":"1048576",
        \\ "objectSize":"20971520","done":false,"rewriteToken":"abc"}
    );
    try testing.expect(!unfinished.done);
    try testing.expectEqualStrings("abc", unfinished.rewrite_token.?);
    try testing.expectEqual(1048576, unfinished.total_bytes_rewritten);
    try testing.expectEqual(null, unfinished.resource);

    const finished = try decodeRewrite(a,
        \\{"done":true,"totalBytesRewritten":20971520,"objectSize":20971520,
        \\ "resource":{"name":"copy.bin","generation":"9","size":"20971520"}}
    );
    try testing.expect(finished.done);
    try testing.expectEqual(null, finished.rewrite_token);
    try testing.expectEqual(9, finished.resource.?.generation);

    const bare = try decodeRewrite(a, "{}");
    try testing.expect(!bare.done);
    try testing.expectEqual(null, bare.rewrite_token);
    try testing.expectError(error.InvalidResponse, decodeRewrite(a, "{\"totalBytesRewritten\":\"x\"}"));
}
