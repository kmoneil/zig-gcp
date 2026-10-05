//! Request paths. Bucket and object names travel as single path segments in
//! the strict percent-encoded form, so a name with slashes, spaces or `%`
//! addresses exactly the object it names. Query values go through the same
//! builder every module uses.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const query = @import("core").query;
const acl = @import("acl.zig");
const types = @import("types.zig");

/// `/storage/v1/b?project=...` with paging, for bucket create and list.
pub fn bucketsPath(arena: Allocator, project: []const u8, page: types.PageOptions) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, .{ .project = project, .page_size = page.page_size, .page_token = page.page_token }) catch
        return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `path` with one more query parameter, `name=value` with the value
/// encoded, after whatever query it already has.
pub fn withParam(arena: Allocator, path: []const u8, name: []const u8, value: []const u8) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll(path) catch return error.OutOfMemory;
    w.writeByte(if (std.mem.indexOfScalar(u8, path, '?') == null) '?' else '&') catch return error.OutOfMemory;
    w.print("{s}=", .{name}) catch return error.OutOfMemory;
    query.writeValue(w, value) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `/storage/v1/projects/{project}/serviceAccount`: the project's Cloud
/// Storage service agent.
pub fn serviceAgentPath(arena: Allocator, project: []const u8) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("/storage/v1/projects/") catch return error.OutOfMemory;
    query.writeStrictSegment(w, project) catch return error.OutOfMemory;
    w.writeAll("/serviceAccount") catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `/storage/v1/b/{bucket}`.
pub fn bucketPath(arena: Allocator, bucket: []const u8) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, .{ .bucket = bucket }) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `/storage/v1/b/{bucket}?projection=noAcl` with metageneration
/// conditions: a bucket patch. The ACLs stay out of the answer, since
/// reading them takes more than changing the settings does.
pub fn bucketPatchPath(arena: Allocator, bucket: []const u8, preconditions: types.Preconditions) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, .{ .bucket = bucket, .no_acl = true, .preconditions = preconditions }) catch
        return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `/storage/v1/b?project=...&softDeleted=true` with paging: the project's
/// soft-deleted buckets.
pub fn softDeletedBucketsPath(arena: Allocator, project: []const u8, page: types.PageOptions) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, .{
        .project = project,
        .soft_deleted = true,
        .page_size = page.page_size,
        .page_token = page.page_token,
    }) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `/storage/v1/b/{bucket}/restore?projection=noAcl&generation=N`: brings
/// one soft-deleted bucket back.
pub fn bucketRestorePath(arena: Allocator, bucket: []const u8, generation: u64) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, .{ .bucket = bucket, .suffix = "/restore", .no_acl = true, .generation = generation }) catch
        return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `/storage/v1/b/{bucket}/o/{object}/restore`, with the generation, the
/// conditions on the live object, and the restore's options.
pub fn objectRestorePath(arena: Allocator, bucket: []const u8, object: []const u8, options: types.RestoreOptions) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, .{
        .bucket = bucket,
        .object = object,
        .suffix = "/restore",
        .no_acl = true,
        .generation = options.generation,
        .preconditions = options.preconditions,
        .copy_source_acl = options.copy_source_acl,
        .restore_token = options.restore_token,
    }) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `/storage/v1/b/{bucket}/o/bulkRestore`.
pub fn bulkRestorePath(arena: Allocator, bucket: []const u8) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, .{ .bucket = bucket, .list_objects = true, .suffix = "/bulkRestore" }) catch
        return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// What an operations path asks for.
pub const OperationRequest = union(enum) {
    /// `/operations` with paging.
    list: types.PageOptions,
    /// `/operations/{id}`.
    get: []const u8,
    /// `/operations/{id}/cancel`.
    cancel: []const u8,
};

/// `/storage/v1/b/{bucket}/operations`, one operation, or its cancel.
pub fn operationsPath(arena: Allocator, bucket: []const u8, request: OperationRequest) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeOperations(&out.writer, bucket, request) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeOperations(w: *Writer, bucket: []const u8, request: OperationRequest) Writer.Error!void {
    try w.writeAll("/storage/v1/b/");
    try query.writeStrictSegment(w, bucket);
    try w.writeAll("/operations");
    switch (request) {
        .list => |page| {
            var params: query.Params = .init(w);
            try params.addNonZero("maxResults", page.page_size);
            try params.addOptional("pageToken", page.page_token);
        },
        .get => |id| {
            try w.writeByte('/');
            try query.writeStrictSegment(w, id);
        },
        .cancel => |id| {
            try w.writeByte('/');
            try query.writeStrictSegment(w, id);
            try w.writeAll("/cancel");
        },
    }
}

/// What a folder request asks beside the bucket. The folder travels as one
/// strictly encoded segment, slashes included, as its selfLink spells it.
pub const FolderRequest = union(enum) {
    /// `/folders`, with `recursive=true` when asked: missing parents are
    /// created along the way.
    insert: bool,
    /// `/folders/{folder}`, with its metageneration conditions: a get or a
    /// delete.
    item: struct { folder: []const u8, preconditions: types.Preconditions = .{} },
    /// `/folders` with the listing's query.
    list: types.FolderListOptions,
};

/// `/storage/v1/b/{bucket}/folders`, one folder, or the listing.
pub fn foldersPath(arena: Allocator, bucket: []const u8, request: FolderRequest) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeFolders(&out.writer, bucket, request) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeFolders(w: *Writer, bucket: []const u8, request: FolderRequest) Writer.Error!void {
    try w.writeAll("/storage/v1/b/");
    try query.writeStrictSegment(w, bucket);
    try w.writeAll("/folders");
    switch (request) {
        .insert => |recursive| if (recursive) {
            var params: query.Params = .init(w);
            try params.add("recursive", "true");
        },
        .item => |item| {
            try w.writeByte('/');
            try query.writeStrictSegment(w, item.folder);
            var params: query.Params = .init(w);
            try writePreconditions(&params, item.preconditions);
        },
        .list => |options| {
            var params: query.Params = .init(w);
            try params.addOptional("prefix", options.prefix);
            if (options.directory_mode) try params.add("delimiter", "/");
            try params.addOptional("startOffset", options.start_offset);
            try params.addOptional("endOffset", options.end_offset);
            try params.addNonZero("pageSize", options.page_size);
            try params.addOptional("pageToken", options.page_token);
        },
    }
}

/// What a managed folder request asks beside the bucket.
pub const ManagedFolderRequest = union(enum) {
    /// `/managedFolders`: a create, whose body names the path.
    insert,
    /// `/managedFolders/{managedFolder}`: a get or a delete, the delete
    /// with `allowNonEmpty` when asked.
    item: struct {
        folder: []const u8,
        preconditions: types.Preconditions = .{},
        allow_non_empty: bool = false,
    },
    /// `/managedFolders` with the listing's query.
    list: types.ManagedFolderListOptions,
};

/// `/storage/v1/b/{bucket}/managedFolders`, one of them, or the listing.
pub fn managedFoldersPath(arena: Allocator, bucket: []const u8, request: ManagedFolderRequest) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeManagedFolders(&out.writer, bucket, request) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeManagedFolders(w: *Writer, bucket: []const u8, request: ManagedFolderRequest) Writer.Error!void {
    try w.writeAll("/storage/v1/b/");
    try query.writeStrictSegment(w, bucket);
    try w.writeAll("/managedFolders");
    switch (request) {
        .insert => {},
        .item => |item| {
            try w.writeByte('/');
            try query.writeStrictSegment(w, item.folder);
            var params: query.Params = .init(w);
            if (item.allow_non_empty) try params.add("allowNonEmpty", "true");
            try writePreconditions(&params, item.preconditions);
        },
        .list => |options| {
            var params: query.Params = .init(w);
            try params.addOptional("prefix", options.prefix);
            try params.addNonZero("pageSize", options.page_size);
            try params.addOptional("pageToken", options.page_token);
        },
    }
}

/// `/storage/v1/b/{bucket}/managedFolders/{managedFolder}/iam`, asking for
/// policy version 3 on a read, as the bucket's path does.
pub fn managedFolderIamPath(arena: Allocator, bucket: []const u8, folder: []const u8, read: bool) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    writeManagedFolders(w, bucket, .{ .item = .{ .folder = folder } }) catch return error.OutOfMemory;
    w.writeAll("/iam") catch return error.OutOfMemory;
    if (read) {
        var params: query.Params = .init(w);
        params.add("optionsRequestedPolicyVersion", "3") catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

/// `.../managedFolders/{managedFolder}/iam/testPermissions`, one
/// `permissions` parameter for each name.
pub fn managedFolderTestPermissionsPath(arena: Allocator, bucket: []const u8, folder: []const u8, permissions: []const []const u8) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    writeManagedFolders(w, bucket, .{ .item = .{ .folder = folder } }) catch return error.OutOfMemory;
    w.writeAll("/iam/testPermissions") catch return error.OutOfMemory;
    var params: query.Params = .init(w);
    for (permissions) |permission| params.add("permissions", permission) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `/storage/v1/b/{bucket}/folders/{source}/renameTo/folders/{destination}`:
/// an atomic rename of the folder and everything under it. The condition is
/// `ifSourceMetagenerationMatch`, the one production honors: the reference
/// page's `ifMetagenerationMatch` is silently ignored and must never be
/// sent, as measured on 2026-10-02.
pub fn renameFolderPath(
    arena: Allocator,
    bucket: []const u8,
    source: []const u8,
    destination: []const u8,
    if_source_metageneration_match: ?u64,
) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeRenameFolder(&out.writer, bucket, source, destination, if_source_metageneration_match) catch
        return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeRenameFolder(
    w: *Writer,
    bucket: []const u8,
    source: []const u8,
    destination: []const u8,
    if_source_metageneration_match: ?u64,
) Writer.Error!void {
    try w.writeAll("/storage/v1/b/");
    try query.writeStrictSegment(w, bucket);
    try w.writeAll("/folders/");
    try query.writeStrictSegment(w, source);
    try w.writeAll("/renameTo/folders/");
    try query.writeStrictSegment(w, destination);
    var params: query.Params = .init(w);
    if (if_source_metageneration_match) |m| try params.addInt("ifSourceMetagenerationMatch", m);
}

/// `/storage/v1/b/{bucket}/storageLayout`.
pub fn storageLayoutPath(arena: Allocator, bucket: []const u8) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("/storage/v1/b/") catch return error.OutOfMemory;
    query.writeStrictSegment(w, bucket) catch return error.OutOfMemory;
    w.writeAll("/storageLayout") catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `/storage/v1/b/{bucket}/notificationConfigs`, or one of them by `id`.
pub fn notificationsPath(arena: Allocator, bucket: []const u8, id: ?[]const u8) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeNotifications(&out.writer, bucket, id) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeNotifications(w: *Writer, bucket: []const u8, id: ?[]const u8) Writer.Error!void {
    try w.writeAll("/storage/v1/b/");
    try query.writeStrictSegment(w, bucket);
    try w.writeAll("/notificationConfigs");
    if (id) |i| {
        try w.writeByte('/');
        try query.writeStrictSegment(w, i);
    }
}

/// `/storage/v1/b/{bucket}/iam`, asking for policy version 3 when `read`:
/// the only version that shows conditions as they are, and a bucket answers
/// an unconditioned policy as version 1 whatever was asked.
pub fn bucketIamPath(arena: Allocator, bucket: []const u8, read: bool) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeBucketIam(&out.writer, bucket, read) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeBucketIam(w: *Writer, bucket: []const u8, read: bool) Writer.Error!void {
    try w.writeAll("/storage/v1/b/");
    try query.writeStrictSegment(w, bucket);
    try w.writeAll("/iam");
    if (read) {
        var params: query.Params = .init(w);
        try params.add("optionsRequestedPolicyVersion", "3");
    }
}

/// `/storage/v1/b/{bucket}/iam/testPermissions`, one `permissions`
/// parameter for each name.
pub fn bucketTestPermissionsPath(arena: Allocator, bucket: []const u8, permissions: []const []const u8) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeBucketTestPermissions(&out.writer, bucket, permissions) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeBucketTestPermissions(w: *Writer, bucket: []const u8, permissions: []const []const u8) Writer.Error!void {
    try w.writeAll("/storage/v1/b/");
    try query.writeStrictSegment(w, bucket);
    try w.writeAll("/iam/testPermissions");
    var params: query.Params = .init(w);
    for (permissions) |permission| try params.add("permissions", permission);
}

/// `/storage/v1/b/{bucket}` or `/storage/v1/b/{bucket}/o/{object}` with
/// `projection=full` and a whole-list write's conditions: where an access
/// control list is read with what guards its write, and written.
pub fn aclResourcePath(arena: Allocator, bucket: []const u8, object: ?[]const u8, guard: types.AclGuard) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, .{
        .bucket = bucket,
        .object = object,
        .full_acl = true,
        .preconditions = .{
            .if_generation_match = guard.if_generation_match,
            .if_metageneration_match = guard.if_metageneration_match,
        },
    }) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// What an HMAC key collection path asks.
pub const HmacKeysQuery = union(enum) {
    /// A create, for this account.
    create: []const u8,
    list: types.HmacListOptions,
};

/// `/storage/v1/projects/{project}/hmacKeys` with a create's or a list's
/// query.
pub fn hmacKeysPath(arena: Allocator, project: []const u8, request: HmacKeysQuery) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeHmacKeys(&out.writer, project, request) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeHmacKeys(w: *Writer, project: []const u8, request: HmacKeysQuery) Writer.Error!void {
    try w.writeAll("/storage/v1/projects/");
    try query.writeStrictSegment(w, project);
    try w.writeAll("/hmacKeys");
    var params: query.Params = .init(w);
    switch (request) {
        .create => |email| try params.add("serviceAccountEmail", email),
        .list => |options| {
            try params.addOptional("serviceAccountEmail", options.service_account_email);
            if (options.show_deleted) try params.add("showDeletedKeys", "true");
            try params.addNonZero("maxResults", options.page_size);
            try params.addOptional("pageToken", options.page_token);
        },
    }
}

/// `/storage/v1/projects/{project}/hmacKeys/{accessId}`.
pub fn hmacKeyPath(arena: Allocator, project: []const u8, access_id: []const u8) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("/storage/v1/projects/") catch return error.OutOfMemory;
    query.writeStrictSegment(w, project) catch return error.OutOfMemory;
    w.writeAll("/hmacKeys/") catch return error.OutOfMemory;
    query.writeStrictSegment(w, access_id) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Which list a single-entry path names.
pub const AclTarget = enum { bucket, default_object, object };

/// `.../acl`, `.../defaultObjectAcl` or `.../o/{object}/acl`, and one
/// entry of it when `entity` names one, as one strictly encoded segment.
pub fn aclEntryPath(arena: Allocator, bucket: []const u8, object: ?[]const u8, target: AclTarget, entity: ?[]const u8) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeAclEntry(&out.writer, bucket, object, target, entity) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeAclEntry(w: *Writer, bucket: []const u8, object: ?[]const u8, target: AclTarget, entity: ?[]const u8) Writer.Error!void {
    try w.writeAll("/storage/v1/b/");
    try query.writeStrictSegment(w, bucket);
    switch (target) {
        .bucket => try w.writeAll("/acl"),
        .default_object => try w.writeAll("/defaultObjectAcl"),
        .object => {
            try w.writeAll("/o/");
            try query.writeStrictSegment(w, object.?);
            try w.writeAll("/acl");
        },
    }
    if (entity) |e| {
        try w.writeByte('/');
        try query.writeStrictSegment(w, e);
    }
}

/// `/storage/v1/b/{bucket}/o` with listing options.
pub fn objectsPath(arena: Allocator, bucket: []const u8, options: types.ListOptions) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, .{
        .bucket = bucket,
        .list_objects = true,
        .prefix = options.prefix,
        .delimiter = options.delimiter,
        .match_glob = options.match_glob,
        .versions = options.versions,
        .soft_deleted = options.soft_deleted,
        .folders_as_prefixes = options.include_folders_as_prefixes,
        .full_acl = options.with_acl,
        .page_size = options.page_size,
        .page_token = options.page_token,
    }) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `/storage/v1/b/{bucket}/o/{object}` as a metadata read addresses it:
/// the live generation or one named, soft-deleted or not.
pub fn objectGetPath(arena: Allocator, bucket: []const u8, object: []const u8, options: types.GetOptions) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, .{
        .bucket = bucket,
        .object = object,
        .generation = options.generation,
        .preconditions = options.preconditions,
        .soft_deleted = options.soft_deleted,
        .restore_token = options.restore_token,
        .full_acl = options.with_acl,
    }) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `/storage/v1/b/{bucket}/o/{object}`, optionally pinned to a generation.
pub fn objectPath(
    arena: Allocator,
    bucket: []const u8,
    object: []const u8,
    generation: ?u64,
    preconditions: types.Preconditions,
) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, .{
        .bucket = bucket,
        .object = object,
        .generation = generation,
        .preconditions = preconditions,
    }) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `/storage/v1/b/{bucket}/o/{object}/compose`: writes the destination
/// from its sources. Compose has no `generation`; it always writes the
/// live object.
pub fn composePath(
    arena: Allocator,
    bucket: []const u8,
    object: []const u8,
    preconditions: types.Preconditions,
    kms_key_name: ?[]const u8,
    predefined_acl: ?types.PredefinedAcl,
) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, .{
        .bucket = bucket,
        .object = object,
        .compose = true,
        .preconditions = preconditions,
        .kms_key_name = kms_key_name,
        .destination_predefined_acl = predefined_acl,
    }) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `/storage/v1/b/{bucket}/o/{object}?alt=media`: the object's bytes.
pub fn objectMediaPath(
    arena: Allocator,
    bucket: []const u8,
    object: []const u8,
    generation: ?u64,
    preconditions: types.Preconditions,
) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    write(&out.writer, .{
        .bucket = bucket,
        .object = object,
        .alt_media = true,
        .generation = generation,
        .preconditions = preconditions,
    }) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// What one call of the rewrite loop says beside the two names.
pub const RewriteParams = struct {
    /// Which generation of the source to copy.
    source_generation: ?u64 = null,
    /// Copy only while the source's metadata is still at this
    /// metageneration: how a copy that read the source is pinned to it.
    if_source_metageneration_match: ?u64 = null,
    /// Conditions on the destination.
    preconditions: types.Preconditions = .{},
    /// The Cloud KMS key that encrypts the copy.
    destination_kms_key_name: ?[]const u8 = null,
    /// The copy's canned access control list.
    destination_predefined_acl: ?types.PredefinedAcl = null,
    /// Continues an earlier call's work.
    rewrite_token: ?[]const u8 = null,
};

/// `/storage/v1/b/{src}/o/{srcObj}/rewriteTo/b/{dst}/o/{dstObj}`: one call
/// of the server-side copy loop.
pub fn rewritePath(
    arena: Allocator,
    source_bucket: []const u8,
    source_object: []const u8,
    dest_bucket: []const u8,
    dest_object: []const u8,
    params: RewriteParams,
) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeRewrite(&out.writer, source_bucket, source_object, dest_bucket, dest_object, params) catch
        return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeRewrite(
    w: *Writer,
    source_bucket: []const u8,
    source_object: []const u8,
    dest_bucket: []const u8,
    dest_object: []const u8,
    rewrite: RewriteParams,
) Writer.Error!void {
    try w.writeAll("/storage/v1/b/");
    try query.writeStrictSegment(w, source_bucket);
    try w.writeAll("/o/");
    try query.writeStrictSegment(w, source_object);
    try w.writeAll("/rewriteTo/b/");
    try query.writeStrictSegment(w, dest_bucket);
    try w.writeAll("/o/");
    try query.writeStrictSegment(w, dest_object);
    var params: query.Params = .init(w);
    if (rewrite.source_generation) |g| try params.addInt("sourceGeneration", g);
    if (rewrite.if_source_metageneration_match) |m| try params.addInt("ifSourceMetagenerationMatch", m);
    try writePreconditions(&params, rewrite.preconditions);
    try params.addOptional("destinationKmsKeyName", rewrite.destination_kms_key_name);
    if (rewrite.destination_predefined_acl) |p| try params.add("destinationPredefinedAcl", acl.predefinedName(p));
    try params.addOptional("rewriteToken", rewrite.rewrite_token);
}

/// `/storage/v1/b/{bucket}/o/{source}/moveTo/o/{destination}`: an atomic
/// rename within one bucket, pinned to the source's generation, under the
/// conditions on the destination.
pub fn movePath(
    arena: Allocator,
    bucket: []const u8,
    source: []const u8,
    destination: []const u8,
    source_generation: u64,
    preconditions: types.Preconditions,
) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeMove(&out.writer, bucket, source, destination, source_generation, preconditions) catch
        return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeMove(
    w: *Writer,
    bucket: []const u8,
    source: []const u8,
    destination: []const u8,
    source_generation: u64,
    preconditions: types.Preconditions,
) Writer.Error!void {
    try w.writeAll("/storage/v1/b/");
    try query.writeStrictSegment(w, bucket);
    try w.writeAll("/o/");
    try query.writeStrictSegment(w, source);
    try w.writeAll("/moveTo/o/");
    try query.writeStrictSegment(w, destination);
    var params: query.Params = .init(w);
    try params.addInt("ifSourceGenerationMatch", source_generation);
    try writePreconditions(&params, preconditions);
}

/// What an upload's path says beside the bucket: the conditions, the
/// Cloud KMS key to encrypt under, and the canned access control list.
pub const UploadParams = struct {
    preconditions: types.Preconditions = .{},
    kms_key_name: ?[]const u8 = null,
    predefined_acl: ?types.PredefinedAcl = null,
};

/// `/upload/storage/v1/b/{bucket}/o?uploadType=multipart`. The object name
/// travels in the metadata part, not here.
pub fn uploadMultipartPath(arena: Allocator, bucket: []const u8, upload: UploadParams) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeUpload(&out.writer, bucket, "multipart", upload) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `/upload/storage/v1/b/{bucket}/o?uploadType=resumable`, which opens a
/// session. The object name travels in the metadata body.
pub fn uploadResumablePath(arena: Allocator, bucket: []const u8, upload: UploadParams) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeUpload(&out.writer, bucket, "resumable", upload) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeUpload(w: *Writer, bucket: []const u8, upload_type: []const u8, upload: UploadParams) Writer.Error!void {
    try w.writeAll("/upload/storage/v1/b/");
    try query.writeStrictSegment(w, bucket);
    try w.print("/o?uploadType={s}", .{upload_type});
    var params: query.Params = .init(w);
    params.separator = '&';
    try writePreconditions(&params, upload.preconditions);
    try params.addOptional("kmsKeyName", upload.kms_key_name);
    if (upload.predefined_acl) |p| try params.add("predefinedAcl", acl.predefinedName(p));
}

/// Writes a bucket or object name into an XML API path, as signed URLs and
/// multipart uploads name objects: `/` and the unreserved characters stay,
/// every other byte becomes `%XX`.
pub fn writeXmlPath(w: *Writer, text: []const u8) Writer.Error!void {
    return std.Uri.Component.percentEncode(w, text, isXmlPathByte);
}

fn isXmlPathByte(c: u8) bool {
    return c == '/' or query.isUnreserved(c);
}

/// What an XML API multipart upload request says after the object.
pub const XmlQuery = union(enum) {
    /// `?uploads`: start an upload.
    uploads,
    /// `?partNumber=N&uploadId=ID`: send one part.
    part: struct { number: u32, upload_id: []const u8 },
    /// `?uploadId=ID`: finish or abort an upload.
    upload: []const u8,
    /// `?uploadId=ID&max-parts=M[&part-number-marker=N]`: one page of the
    /// parts an upload holds.
    list: struct { upload_id: []const u8, max_parts: u32, marker: u32 = 0 },
};

/// `/{bucket}/{object}` and a multipart upload's query, the XML API's path
/// style: the object name's slashes kept, the rest percent-encoded.
pub fn xmlPath(arena: Allocator, bucket: []const u8, object: []const u8, xml_query: XmlQuery) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    writeXml(&out.writer, bucket, object, xml_query) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeXml(w: *Writer, bucket: []const u8, object: []const u8, xml_query: XmlQuery) Writer.Error!void {
    try w.writeByte('/');
    try writeXmlPath(w, bucket);
    try w.writeByte('/');
    try writeXmlPath(w, object);
    switch (xml_query) {
        .uploads => try w.writeAll("?uploads"),
        .part => |part| {
            try w.print("?partNumber={d}&uploadId=", .{part.number});
            try query.writeValue(w, part.upload_id);
        },
        .upload => |id| {
            try w.writeAll("?uploadId=");
            try query.writeValue(w, id);
        },
        .list => |list| {
            try w.writeAll("?uploadId=");
            try query.writeValue(w, list.upload_id);
            try w.print("&max-parts={d}", .{list.max_parts});
            if (list.marker > 0) try w.print("&part-number-marker={d}", .{list.marker});
        },
    }
}

const Parts = struct {
    bucket: ?[]const u8 = null,
    object: ?[]const u8 = null,
    list_objects: bool = false,
    alt_media: bool = false,
    /// `projection=noAcl`.
    no_acl: bool = false,
    /// `projection=full`: the access control lists and owner too.
    full_acl: bool = false,
    project: ?[]const u8 = null,
    generation: ?u64 = null,
    preconditions: types.Preconditions = .{},
    /// Appends `/compose` after the object, before the query.
    compose: bool = false,
    /// Appended after the bucket, the object or `/o`, before the query.
    suffix: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    delimiter: ?[]const u8 = null,
    match_glob: ?[]const u8 = null,
    versions: bool = false,
    soft_deleted: bool = false,
    folders_as_prefixes: bool = false,
    copy_source_acl: bool = false,
    restore_token: ?[]const u8 = null,
    kms_key_name: ?[]const u8 = null,
    destination_predefined_acl: ?types.PredefinedAcl = null,
    page_size: u32 = 0,
    page_token: ?[]const u8 = null,
};

fn write(w: *Writer, parts: Parts) Writer.Error!void {
    try w.writeAll("/storage/v1/b");
    if (parts.bucket) |bucket| {
        try w.writeByte('/');
        try query.writeStrictSegment(w, bucket);
    }
    if (parts.list_objects) try w.writeAll("/o");
    if (parts.object) |object| {
        try w.writeAll("/o/");
        try query.writeStrictSegment(w, object);
        if (parts.compose) try w.writeAll("/compose");
    }
    if (parts.suffix) |suffix| try w.writeAll(suffix);
    var params: query.Params = .init(w);
    if (parts.alt_media) try params.add("alt", "media");
    if (parts.no_acl) try params.add("projection", "noAcl");
    if (parts.full_acl) try params.add("projection", "full");
    try params.addOptional("project", parts.project);
    if (parts.generation) |g| try params.addInt("generation", g);
    try writePreconditions(&params, parts.preconditions);
    try params.addOptional("kmsKeyName", parts.kms_key_name);
    if (parts.destination_predefined_acl) |p| try params.add("destinationPredefinedAcl", acl.predefinedName(p));
    try params.addOptional("prefix", parts.prefix);
    try params.addOptional("delimiter", parts.delimiter);
    try params.addOptional("matchGlob", parts.match_glob);
    if (parts.versions) try params.add("versions", "true");
    if (parts.soft_deleted) try params.add("softDeleted", "true");
    if (parts.folders_as_prefixes) try params.add("includeFoldersAsPrefixes", "true");
    if (parts.copy_source_acl) try params.add("copySourceAcl", "true");
    try params.addOptional("restoreToken", parts.restore_token);
    try params.addNonZero("maxResults", parts.page_size);
    try params.addOptional("pageToken", parts.page_token);
}

fn writePreconditions(params: *query.Params, preconditions: types.Preconditions) Writer.Error!void {
    if (preconditions.if_generation_match) |g| try params.addInt("ifGenerationMatch", g);
    if (preconditions.if_generation_not_match) |g| try params.addInt("ifGenerationNotMatch", g);
    if (preconditions.if_metageneration_match) |g| try params.addInt("ifMetagenerationMatch", g);
    if (preconditions.if_metageneration_not_match) |g| try params.addInt("ifMetagenerationNotMatch", g);
}

const testing = std.testing;

fn expectPath(expected: []const u8, actual: []u8) !void {
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "bucket paths" {
    const gpa = testing.allocator;
    try expectPath("/storage/v1/b?project=extractctl", try bucketsPath(gpa, "extractctl", .{}));
    try expectPath(
        "/storage/v1/b?project=extractctl&maxResults=2&pageToken=a%2Bb%3D",
        try bucketsPath(gpa, "extractctl", .{ .page_size = 2, .page_token = "a+b=" }),
    );
    try expectPath("/storage/v1/b/my-bucket", try bucketPath(gpa, "my-bucket"));
    try expectPath("/storage/v1/b/b%25c", try bucketPath(gpa, "b%c"));
    try expectPath("/storage/v1/b/my-bucket?projection=noAcl", try bucketPatchPath(gpa, "my-bucket", .{}));
    try expectPath(
        "/storage/v1/b?project=extractctl&softDeleted=true&maxResults=5&pageToken=t",
        try softDeletedBucketsPath(gpa, "extractctl", .{ .page_size = 5, .page_token = "t" }),
    );
    try expectPath("/storage/v1/b/b%25c/restore?projection=noAcl&generation=17", try bucketRestorePath(gpa, "b%c", 17));
    try expectPath(
        "/storage/v1/b/b/o/a%2Fb/restore?projection=noAcl&generation=7&ifGenerationMatch=0&copySourceAcl=true&restoreToken=r%2Bt",
        try objectRestorePath(gpa, "b", "a/b", .{
            .generation = 7,
            .preconditions = .does_not_exist,
            .copy_source_acl = true,
            .restore_token = "r+t",
        }),
    );
    try expectPath("/storage/v1/b/b/o/bulkRestore", try bulkRestorePath(gpa, "b"));
    try expectPath("/storage/v1/b/b/operations?maxResults=1&pageToken=p", try operationsPath(gpa, "b", .{ .list = .{ .page_size = 1, .page_token = "p" } }));
    try expectPath("/storage/v1/b/b/operations", try operationsPath(gpa, "b", .{ .list = .{} }));
    try expectPath("/storage/v1/b/b/operations/CiRl%2Bx", try operationsPath(gpa, "b", .{ .get = "CiRl+x" }));
    try expectPath("/storage/v1/b/b/operations/CiRl/cancel", try operationsPath(gpa, "b", .{ .cancel = "CiRl" }));
    try expectPath(
        "/storage/v1/b/b%25c?projection=noAcl&ifMetagenerationMatch=3&ifMetagenerationNotMatch=4",
        try bucketPatchPath(gpa, "b%c", .{ .if_metageneration_match = 3, .if_metageneration_not_match = 4 }),
    );
}

test "object paths encode the name as one segment" {
    const gpa = testing.allocator;
    try expectPath(
        "/storage/v1/b/my-bucket/o/reports%2F2026%2Fq3.txt",
        try objectPath(gpa, "my-bucket", "reports/2026/q3.txt", null, .{}),
    );
    try expectPath(
        "/storage/v1/b/my-bucket/o/a%20b%2Bc%3F%23?generation=1758448800123456",
        try objectPath(gpa, "my-bucket", "a b+c?#", 1758448800123456, .{}),
    );
    try expectPath("/storage/v1/b/b/o/caf%C3%A9", try objectPath(gpa, "b", "caf\xc3\xa9", null, .{}));
    // A name that is only slashes stays addressable.
    try expectPath("/storage/v1/b/b/o/%2F%2F%2F", try objectPath(gpa, "b", "///", null, .{}));
}

test "media and upload paths" {
    const gpa = testing.allocator;
    try expectPath(
        "/storage/v1/b/my-bucket/o/backup.tar?alt=media",
        try objectMediaPath(gpa, "my-bucket", "backup.tar", null, .{}),
    );
    try expectPath(
        "/storage/v1/b/my-bucket/o/a%2Fb?alt=media&generation=7",
        try objectMediaPath(gpa, "my-bucket", "a/b", 7, .{}),
    );
    try expectPath(
        "/upload/storage/v1/b/my-bucket/o?uploadType=multipart",
        try uploadMultipartPath(gpa, "my-bucket", .{}),
    );
}

test "folder and layout paths encode the folder as one segment" {
    const gpa = testing.allocator;
    try expectPath("/storage/v1/b/b/folders", try foldersPath(gpa, "b", .{ .insert = false }));
    try expectPath("/storage/v1/b/b/folders?recursive=true", try foldersPath(gpa, "b", .{ .insert = true }));
    try expectPath("/storage/v1/b/b/folders/a%2Fb%2F", try foldersPath(gpa, "b", .{ .item = .{ .folder = "a/b/" } }));
    try expectPath(
        "/storage/v1/b/b%25c/folders/caf%C3%A9%2F?ifMetagenerationMatch=3",
        try foldersPath(gpa, "b%c", .{ .item = .{ .folder = "caf\xc3\xa9/", .preconditions = .{ .if_metageneration_match = 3 } } }),
    );
    try expectPath("/storage/v1/b/b/folders", try foldersPath(gpa, "b", .{ .list = .{} }));
    try expectPath(
        "/storage/v1/b/b/folders?prefix=n1%2F&delimiter=%2F&startOffset=a&endOffset=z&pageSize=1&pageToken=t%2B",
        try foldersPath(gpa, "b", .{ .list = .{
            .prefix = "n1/",
            .directory_mode = true,
            .start_offset = "a",
            .end_offset = "z",
            .page_size = 1,
            .page_token = "t+",
        } }),
    );
    try expectPath("/storage/v1/b/my-bucket/storageLayout", try storageLayoutPath(gpa, "my-bucket"));
    try expectPath(
        "/storage/v1/b/b/folders/ra%2F/renameTo/folders/rb%2F",
        try renameFolderPath(gpa, "b", "ra/", "rb/", null),
    );
    try expectPath(
        "/storage/v1/b/b%25c/folders/a%2Fb%2F/renameTo/folders/c%20d%2F?ifSourceMetagenerationMatch=7",
        try renameFolderPath(gpa, "b%c", "a/b/", "c d/", 7),
    );
}

test "managed folder paths encode the folder as one segment, IAM included" {
    const gpa = testing.allocator;
    try expectPath("/storage/v1/b/b/managedFolders", try managedFoldersPath(gpa, "b", .insert));
    try expectPath("/storage/v1/b/b/managedFolders/m1%2F", try managedFoldersPath(gpa, "b", .{ .item = .{ .folder = "m1/" } }));
    try expectPath(
        "/storage/v1/b/b/managedFolders/teams%2Fdata%2F?allowNonEmpty=true&ifMetagenerationMatch=2",
        try managedFoldersPath(gpa, "b", .{ .item = .{
            .folder = "teams/data/",
            .allow_non_empty = true,
            .preconditions = .{ .if_metageneration_match = 2 },
        } }),
    );
    try expectPath("/storage/v1/b/b/managedFolders", try managedFoldersPath(gpa, "b", .{ .list = .{} }));
    try expectPath(
        "/storage/v1/b/b/managedFolders?prefix=teams%2F&pageSize=2&pageToken=t%2B",
        try managedFoldersPath(gpa, "b", .{ .list = .{ .prefix = "teams/", .page_size = 2, .page_token = "t+" } }),
    );
    try expectPath("/storage/v1/b/b/managedFolders/m1%2F/iam?optionsRequestedPolicyVersion=3", try managedFolderIamPath(gpa, "b", "m1/", true));
    try expectPath("/storage/v1/b/b/managedFolders/m1%2F/iam", try managedFolderIamPath(gpa, "b", "m1/", false));
    try expectPath(
        "/storage/v1/b/b/managedFolders/m1%2F/iam/testPermissions?permissions=storage.objects.get&permissions=storage.managedFolders.get",
        try managedFolderTestPermissionsPath(gpa, "b", "m1/", &.{ "storage.objects.get", "storage.managedFolders.get" }),
    );
}

test "object listing paths" {
    const gpa = testing.allocator;
    try expectPath("/storage/v1/b/my-bucket/o", try objectsPath(gpa, "my-bucket", .{}));
    try expectPath(
        "/storage/v1/b/my-bucket/o?prefix=reports%2F&delimiter=%2F&maxResults=2&pageToken=t",
        try objectsPath(gpa, "my-bucket", .{
            .prefix = "reports/",
            .delimiter = "/",
            .page_size = 2,
            .page_token = "t",
        }),
    );
}

test "preconditions become their query parameters, in every position" {
    const gpa = testing.allocator;
    try expectPath(
        "/storage/v1/b/b/o/a?ifGenerationMatch=0",
        try objectPath(gpa, "b", "a", null, .does_not_exist),
    );
    try expectPath(
        "/storage/v1/b/b/o/a?generation=7&ifGenerationMatch=7&ifGenerationNotMatch=6&ifMetagenerationMatch=1&ifMetagenerationNotMatch=2",
        try objectPath(gpa, "b", "a", 7, .{
            .if_generation_match = 7,
            .if_generation_not_match = 6,
            .if_metageneration_match = 1,
            .if_metageneration_not_match = 2,
        }),
    );
    try expectPath(
        "/storage/v1/b/b/o/a?alt=media&ifGenerationNotMatch=9",
        try objectMediaPath(gpa, "b", "a", null, .{ .if_generation_not_match = 9 }),
    );
    // Upload paths already carry a query; conditions append to it.
    try expectPath(
        "/upload/storage/v1/b/b/o?uploadType=multipart&ifGenerationMatch=0",
        try uploadMultipartPath(gpa, "b", .{ .preconditions = .does_not_exist }),
    );
    try expectPath(
        "/upload/storage/v1/b/b/o?uploadType=resumable&ifGenerationMatch=12",
        try uploadResumablePath(gpa, "b", .{ .preconditions = .{ .if_generation_match = 12 } }),
    );
    try expectPath("/upload/storage/v1/b/b/o?uploadType=resumable", try uploadResumablePath(gpa, "b", .{}));
    // A Cloud KMS key rides along as a strict query value.
    try expectPath(
        "/upload/storage/v1/b/b/o?uploadType=resumable&ifGenerationMatch=0&kmsKeyName=projects%2Fp%2Flocations%2Fus%2FkeyRings%2Fr%2FcryptoKeys%2Fk",
        try uploadResumablePath(gpa, "b", .{ .preconditions = .does_not_exist, .kms_key_name = "projects/p/locations/us/keyRings/r/cryptoKeys/k" }),
    );
    try expectPath(
        "/upload/storage/v1/b/b/o?uploadType=multipart&kmsKeyName=k%20%26x",
        try uploadMultipartPath(gpa, "b", .{ .kms_key_name = "k &x" }),
    );
    // A canned access control list goes last, under its JSON name.
    try expectPath(
        "/upload/storage/v1/b/b/o?uploadType=multipart&ifGenerationMatch=0&predefinedAcl=bucketOwnerFullControl",
        try uploadMultipartPath(gpa, "b", .{ .preconditions = .does_not_exist, .predefined_acl = .bucket_owner_full_control }),
    );
    try expectPath(
        "/upload/storage/v1/b/b/o?uploadType=resumable&predefinedAcl=projectPrivate",
        try uploadResumablePath(gpa, "b", .{ .predefined_acl = .project_private }),
    );
    try expectPath(
        "/storage/v1/b/b/o/c/compose?ifGenerationMatch=0&destinationPredefinedAcl=private",
        try composePath(gpa, "b", "c", .does_not_exist, null, .private),
    );
    try expectPath("/storage/v1/b/b?projection=noAcl&predefinedAcl=private", try withParam(gpa, "/storage/v1/b/b?projection=noAcl", "predefinedAcl", "private"));
    try expectPath("/storage/v1/b/b/o/a?x=a%20b", try withParam(gpa, "/storage/v1/b/b/o/a", "x", "a b"));
    try expectPath("/storage/v1/projects/my-project/serviceAccount", try serviceAgentPath(gpa, "my-project"));
}

test "access control list paths: the guarded resource, and each list and entry" {
    const gpa = testing.allocator;
    try expectPath("/storage/v1/b/b?projection=full", try aclResourcePath(gpa, "b", null, .{}));
    try expectPath(
        "/storage/v1/b/b/o/a%2Fb?projection=full&ifGenerationMatch=7&ifMetagenerationMatch=2",
        try aclResourcePath(gpa, "b", "a/b", .{ .if_generation_match = 7, .if_metageneration_match = 2 }),
    );
    try expectPath("/storage/v1/b/b/acl", try aclEntryPath(gpa, "b", null, .bucket, null));
    try expectPath("/storage/v1/b/b/defaultObjectAcl/allUsers", try aclEntryPath(gpa, "b", null, .default_object, "allUsers"));
    // An entity is one segment: its `@` and `+` encoded, as Node's client
    // encodes them.
    try expectPath(
        "/storage/v1/b/b/o/a%2Fb/acl/user-a%2Bb%40example.com",
        try aclEntryPath(gpa, "b", "a/b", .object, "user-a+b@example.com"),
    );
}

test "HMAC key paths: a create, a list, and one key" {
    const gpa = testing.allocator;
    try expectPath(
        "/storage/v1/projects/extractctl/hmacKeys?serviceAccountEmail=zig-gcp%40extractctl.iam.gserviceaccount.com",
        try hmacKeysPath(gpa, "extractctl", .{ .create = "zig-gcp@extractctl.iam.gserviceaccount.com" }),
    );
    try expectPath("/storage/v1/projects/extractctl/hmacKeys", try hmacKeysPath(gpa, "extractctl", .{ .list = .{} }));
    try expectPath(
        "/storage/v1/projects/p/hmacKeys?serviceAccountEmail=a%40b&showDeletedKeys=true&maxResults=3&pageToken=t%2B",
        try hmacKeysPath(gpa, "p", .{ .list = .{ .service_account_email = "a@b", .show_deleted = true, .page_size = 3, .page_token = "t+" } }),
    );
    // The testbench's access IDs hold `@` and `:`: one segment either way.
    try expectPath("/storage/v1/projects/p/hmacKeys/sa%40p%3Akey-1", try hmacKeyPath(gpa, "p", "sa@p:key-1"));
}

test "XML API paths keep the name's slashes and encode the rest" {
    const gpa = testing.allocator;
    try expectPath("/my-bucket/backups/2026/db.tar?uploads", try xmlPath(gpa, "my-bucket", "backups/2026/db.tar", .uploads));
    try expectPath(
        "/b/a%20b%2Bc%3F%23caf%C3%A9?partNumber=3&uploadId=VXBs%2Bb2Fk%3D",
        try xmlPath(gpa, "b", "a b+c?#caf\xc3\xa9", .{ .part = .{ .number = 3, .upload_id = "VXBs+b2Fk=" } }),
    );
    try expectPath("/b/x?uploadId=id", try xmlPath(gpa, "b", "x", .{ .upload = "id" }));
    try expectPath("/b///?partNumber=10000&uploadId=u", try xmlPath(gpa, "b", "//", .{ .part = .{ .number = 10000, .upload_id = "u" } }));
}

test "move paths name both objects, pin the source, and carry the destination's conditions" {
    const gpa = testing.allocator;
    try expectPath(
        "/storage/v1/b/my-bucket/o/zig-gcp-tmp%2F0a1b/moveTo/o/backups%2Fdb.tar?ifSourceGenerationMatch=17",
        try movePath(gpa, "my-bucket", "zig-gcp-tmp/0a1b", "backups/db.tar", 17, .{}),
    );
    try expectPath(
        "/storage/v1/b/b/o/t/moveTo/o/a%20b?ifSourceGenerationMatch=1&ifGenerationMatch=0",
        try movePath(gpa, "b", "t", "a b", 1, .does_not_exist),
    );
    try expectPath(
        "/storage/v1/b/b/o/t/moveTo/o/d?ifSourceGenerationMatch=2&ifGenerationNotMatch=3&ifMetagenerationMatch=4&ifMetagenerationNotMatch=5",
        try movePath(gpa, "b", "t", "d", 2, .{
            .if_generation_not_match = 3,
            .if_metageneration_match = 4,
            .if_metageneration_not_match = 5,
        }),
    );
}

test "rewrite paths name both objects and carry the loop's state" {
    const gpa = testing.allocator;
    try expectPath(
        "/storage/v1/b/src-b/o/reports%2Fq3.txt/rewriteTo/b/dst-b/o/copy%2Fq3.txt",
        try rewritePath(gpa, "src-b", "reports/q3.txt", "dst-b", "copy/q3.txt", .{}),
    );
    try expectPath(
        "/storage/v1/b/s/o/a/rewriteTo/b/d/o/b?sourceGeneration=5&ifGenerationMatch=0&rewriteToken=t%2B1",
        try rewritePath(gpa, "s", "a", "d", "b", .{
            .source_generation = 5,
            .preconditions = .does_not_exist,
            .rewrite_token = "t+1",
        }),
    );
    // A copy that read its source is pinned to what it read: the bytes by
    // generation, the metadata by metageneration.
    try expectPath(
        "/storage/v1/b/s/o/a/rewriteTo/b/d/o/b?sourceGeneration=7&ifSourceMetagenerationMatch=3&ifGenerationMatch=0",
        try rewritePath(gpa, "s", "a", "d", "b", .{
            .source_generation = 7,
            .if_source_metageneration_match = 3,
            .preconditions = .does_not_exist,
        }),
    );
    // The copy's canned list, before the loop's token.
    try expectPath(
        "/storage/v1/b/s/o/a/rewriteTo/b/d/o/b?destinationPredefinedAcl=bucketOwnerRead&rewriteToken=t",
        try rewritePath(gpa, "s", "a", "d", "b", .{ .destination_predefined_acl = .bucket_owner_read, .rewrite_token = "t" }),
    );
}
