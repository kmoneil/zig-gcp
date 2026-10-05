//! Buckets for `FakeMultipart`: create, get, patch and delete, keeping the
//! settings Cloud Storage keeps and refusing what it refuses, as measured
//! on 2026-09-29. fake-gcs-server keeps almost none of them and checks
//! nothing, so this is what `Bucket.create` and `Bucket.update` are held
//! to. It is written from what Cloud Storage did, not from this library's
//! encoder, so a body the encoder gets wrong is refused or misapplied here
//! as production would. Test code only.
//!
//! What it models:
//!
//! - A patch merges: a field left out stays, a nested object merges field
//!   by field, a list replaces the list, and null removes.
//! - `labels: {}` removes every label, as `labels: null` does, and a label
//!   count is judged after the patch.
//! - `softDeletePolicy: null` puts the 7-day default back; a retention of
//!   0 turns soft delete off.
//! - `lifecycle: {}` and `softDeletePolicy: {}` change nothing, and a
//!   patch of `{}` leaves even the metageneration alone, where any other
//!   patch moves it, a value set to what it was included.
//! - A stale `ifMetagenerationMatch` is 412, and an `ifMetagenerationNotMatch`
//!   that matches is 304 with no body.
//! - Labels, soft delete retentions, lifecycle rules, storage classes,
//!   public access prevention and key names are held to Cloud Storage's
//!   rules, and a refused patch leaves the bucket as it was.
//! - A retention policy (2026-09-30): a period of 1 to 3,155,760,000 s,
//!   as a string or a number; `retentionPolicy: null` removes it and `{}`
//!   changes nothing; `effectiveTime` stays where it was when the period
//!   changes, and `isLocked` or `effectiveTime` in a patch are ignored.
//!   `FakeMultipart` holds objects to it, and to `defaultEventBasedHold`.
//! - A lock needs `ifMetagenerationMatch` (400 `required`), finds an
//!   unlocked policy or answers 400 `invalid` "does not have an unlocked
//!   retention policy" (a repeat included), checks the metageneration
//!   (412), then locks and moves it. A locked period may grow; shrinking
//!   it is 403 `forbidden`, removing it 403 `retentionPolicyNotMet`.
//! - `enableObjectRetention=true` on a create gives `objectRetention`
//!   `Enabled`; a patch of `objectRetention` is taken and ignored.
//!
//! - Notification configurations (2026-10-01): an ID is the bucket's
//!   metageneration, which every create and delete moves; `payload_format`
//!   is required; a topic is taken as `//pubsub.googleapis.com/projects/P/
//!   topics/T` or `projects/P/topics/T` and answered in the first form; at
//!   most 5 custom attributes, keys of 1 to 256 bytes and values of up
//!   to 1,024 (the refusals say characters); unknown event types and empty lists dropped, the rest in
//!   Cloud Storage's order; at most 10 configurations overlapping on any
//!   event type, one with none overlapping every type; a list of none has
//!   no `items`; and the two refusals of a topic Cloud Storage cannot
//!   publish to, for the topics `setTopic` names. Whether prefixes keep
//!   configurations from overlapping was not measured: here they do not.
//!
//! - Hierarchical namespace and folders (2026-10-02): the setting is
//!   create-time only, needs uniform bucket-level access and excludes
//!   versioning, retention policies and object retention, each refused 400
//!   `invalid` in production's words; a PATCH naming it answers 200,
//!   silently drops the field, and still moves the metageneration, as
//!   measured. The folder state lives here per bucket; the semantics (409
//!   conflicts, listing, implicit creation) are served by `FakeMultipart`,
//!   which also knows the objects.
//!
//! IAM, as measured on 2026-10-01: a new bucket's policy holds the legacy
//! bindings to `projectOwner:`, `projectEditor:` and `projectViewer:` its
//! project (four with uniform access, two without); the etag is the
//! metageneration as Cloud Storage writes it, so any bucket update makes
//! an older one stale; a write under a stale etag is 412 "At least one of
//! the pre-conditions you specified did not hold.", a condition without
//! uniform access and a public member under public access prevention are
//! 412 too, each in its own words; only Cloud Storage's roles and custom
//! ones are taken; addresses are stored lowercased, members merged into
//! one binding per role and condition, empty bindings dropped, and a
//! write without `bindings` removes them all; a version 1 read renames a
//! conditional role `_withcond_`; `testIamPermissions` takes at most 84,
//! none twice, Cloud Storage's own, and answers every one held. Whether a
//! principal exists is not modelled: every well-formed one is taken.
//!
//! Letters beyond ASCII pass in labels, since this fake has no Unicode
//! tables; Cloud Storage refuses the uppercase ones. Fields this library
//! never sends are refused, so a misspelled one fails the test.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const core = @import("core");
const fake_acl = @import("fake_acl.zig");
const Method = core.transport.Method;

pub const FakeBuckets = struct {
    /// Every bucket and every value in it. Replaced values are left here
    /// until `deinit`: a test makes few.
    arena: std.heap.ArenaAllocator,
    buckets: std.StringArrayHashMapUnmanaged(Stored) = .empty,
    next_generation: u64 = 1_790_690_832_240_124_605,
    counts: Counts = .{},
    /// Why the latest refusal refused, and how.
    refusal: []const u8 = "",
    refusal_status: u16 = 400,
    refusal_reason: []const u8 = "invalid",
    /// Topics a notification configuration cannot publish to, by their
    /// `//pubsub.googleapis.com/` name. Every other topic exists, and Cloud
    /// Storage's service agent may publish to it.
    topics: std.StringHashMapUnmanaged(TopicState) = .empty,
    /// Every rename ever started, done ones included: operations stay
    /// listable. `FakeMultipart` runs them; the state lives here with the
    /// folders they move.
    renames: std.ArrayListUnmanaged(RenameOp) = .empty,
    next_operation: u32 = 1,

    pub const TopicState = enum {
        /// No such topic.
        missing,
        /// The service agent lacks `roles/pubsub.publisher` on it.
        ungranted,
    };

    pub const Counts = struct {
        creates: u32 = 0,
        reads: u32 = 0,
        patches: u32 = 0,
        deletes: u32 = 0,
        locks: u32 = 0,
        notification_creates: u32 = 0,
        notification_reads: u32 = 0,
        notification_deletes: u32 = 0,
        iam_reads: u32 = 0,
        iam_writes: u32 = 0,
        iam_tests: u32 = 0,
    };

    const Stored = struct {
        resource: ObjectMap,
        metageneration: u64,
        /// Its notification configurations, oldest first.
        notifications: std.ArrayListUnmanaged(ObjectMap) = .empty,
        /// The project it was created in, which its legacy bindings name.
        project: []const u8 = "extractctl",
        /// Its IAM bindings as Cloud Storage keeps them, or null until the
        /// first write, while the legacy ones stand.
        bindings: ?[]const core.iam.Binding = null,
        /// Folders are real resources here. Create-time only.
        hns: bool = false,
        /// Its access control list and default object list, kept under
        /// uniform access too, as production keeps them, but neither shown
        /// nor changed then.
        acl: []const fake_acl.Entry = fake_acl.project_private,
        default_acl: []const fake_acl.Entry = fake_acl.project_private,
        /// The folders, by their full path with the trailing slash, in
        /// creation order; listing sorts.
        folders: std.StringArrayHashMapUnmanaged(FolderState) = .empty,
        /// The managed folders, by their full path, each with a policy of
        /// its own.
        managed: std.StringArrayHashMapUnmanaged(ManagedState) = .empty,
    };

    pub const ManagedState = struct {
        metageneration: u64 = 1,
        create_time: []const u8 = "2026-10-02T19:13:41.557Z",
        /// The policy's own etag counter: CAA= fresh, moved only by policy
        /// writes, never by the bucket, as measured.
        policy_writes: u64 = 0,
        /// Null until the first write: a fresh policy has no bindings at
        /// all, as measured.
        bindings: ?[]const core.iam.Binding = null,
    };

    pub const FolderState = struct {
        metageneration: u64 = 1,
        create_time: []const u8 = "2026-10-02T19:10:28.285Z",
    };

    /// One folder rename, as an operation: pending for `pending` touches (a
    /// poll of the operation, or a write it blocks), then performed. The
    /// renamed folders keep their create times and metagenerations, as
    /// measured.
    pub const RenameOp = struct {
        bucket: []const u8,
        id: []const u8,
        source: []const u8,
        destination: []const u8,
        pending: u32,
        done: bool = false,
        requested_cancellation: bool = false,
    };

    /// Records a started rename and returns its index in `renames`.
    pub fn startRenameOp(self: *FakeBuckets, bucket: []const u8, source: []const u8, destination: []const u8, pending: u32) Allocator.Error!usize {
        const a = self.arena.allocator();
        const id = try a.print("CiRmYWtlcmVuYW1l{d}QAQ", .{self.next_operation});
        self.next_operation += 1;
        try self.renames.append(a, .{
            .bucket = try a.dupe(u8, bucket),
            .id = id,
            .source = try a.dupe(u8, source),
            .destination = try a.dupe(u8, destination),
            .pending = pending,
        });
        return self.renames.items.len - 1;
    }

    /// The bucket's rename of this id, or null.
    pub fn renameOp(self: *FakeBuckets, bucket: []const u8, id: []const u8) ?*RenameOp {
        for (self.renames.items) |*op| {
            if (std.mem.eql(u8, op.bucket, bucket) and std.mem.eql(u8, op.id, id)) return op;
        }
        return null;
    }

    /// Moves every folder under `source` to `destination`, states kept.
    pub fn renameFolders(self: *FakeBuckets, bucket: []const u8, source: []const u8, destination: []const u8) Allocator.Error!void {
        const stored = self.buckets.getPtr(bucket) orelse return;
        const a = self.arena.allocator();
        var moved: std.StringArrayHashMapUnmanaged(FolderState) = .empty;
        for (stored.folders.keys(), stored.folders.values()) |name, state| {
            const kept = if (std.mem.startsWith(u8, name, source))
                try std.mem.concat(a, u8, &.{ destination, name[source.len..] })
            else
                name;
            try moved.put(a, kept, state);
        }
        stored.folders = moved;
    }

    /// What a bucket URL names.
    pub const Target = struct {
        /// Null for the collection, `/storage/v1/b`, which a create posts to.
        name: ?[]const u8,
        project: ?[]const u8 = null,
        if_metageneration_match: ?u64 = null,
        if_metageneration_not_match: ?u64 = null,
        /// `.../lockRetentionPolicy`.
        lock: bool = false,
        /// `enableObjectRetention=true`, on a create.
        object_retention: bool = false,
        /// `.../notificationConfigs`, or one of them.
        notification: ?NotificationTarget = null,
        /// `.../iam` or `.../iam/testPermissions`.
        iam: ?IamTarget = null,
        /// `projection=full`: the lists and the owner too.
        full: bool = false,
        /// A canned list, by its JSON name, on a create or a patch.
        predefined_acl: ?[]const u8 = null,
        predefined_default_object_acl: ?[]const u8 = null,
        /// `.../acl` or `.../defaultObjectAcl`, or one entry of either.
        acl: ?AclTarget = null,
    };

    pub const AclList = enum { bucket, default_object };

    pub const AclTarget = struct {
        list: AclList,
        /// One entry's entity, as the path spells it; null for the list.
        entity: ?[]const u8 = null,
    };

    pub const IamTarget = union(enum) {
        /// `.../iam`, with the version a read asks for.
        policy: ?u32,
        /// `.../iam/testPermissions`, with the permissions asked.
        test_permissions: []const []const u8,
    };

    pub const NotificationTarget = union(enum) {
        collection,
        id: []const u8,
    };

    pub const Reply = struct {
        status: u16,
        body: []const u8 = "",
    };

    pub const Error = error{ HttpProtocolError, OutOfMemory };

    pub fn init(gpa: Allocator) FakeBuckets {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *FakeBuckets) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The bucket's resource as the fake keeps it, or null.
    pub fn resource(self: *const FakeBuckets, name: []const u8) ?ObjectMap {
        const stored = self.buckets.get(name) orelse return null;
        return stored.resource;
    }

    /// One request. A method this fake does not serve fails the test.
    pub fn serve(self: *FakeBuckets, method: Method, target: Target, body: []const u8, arena: Allocator) Error!Reply {
        const name = target.name orelse {
            if (method != .POST or target.project == null) return error.HttpProtocolError;
            self.counts.creates += 1;
            return self.create(body, target, arena);
        };
        if (target.notification) |n| return self.serveNotification(method, name, n, body, arena);
        if (target.acl) |t| return self.serveAcl(method, name, t, arena);
        if (target.iam) |iam| return self.serveIam(method, name, iam, body, arena);
        if (target.lock) {
            if (method != .POST) return error.HttpProtocolError;
            self.counts.locks += 1;
            return self.lock(name, target, arena);
        }
        switch (method) {
            .GET => {
                self.counts.reads += 1;
                const stored = self.buckets.getPtr(name) orelse return notFound();
                return .{ .status = 200, .body = try renderStored(arena, stored, target.full) };
            },
            .PATCH => {
                self.counts.patches += 1;
                return self.patch(name, target, body, arena);
            },
            .DELETE => {
                self.counts.deletes += 1;
                if (!self.buckets.orderedRemove(name)) return notFound();
                return .{ .status = 204 };
            },
            else => return error.HttpProtocolError,
        }
    }

    fn create(self: *FakeBuckets, body: []const u8, target: Target, arena: Allocator) Error!Reply {
        const object_retention = target.object_retention;
        const project = target.project.?;
        const a = self.arena.allocator();
        const parsed = std.json.parseFromSliceLeaky(Value, arena, body, .{}) catch return self.invalid(arena, "Parse Error");
        const fields = objectOf(parsed) orelse return self.invalid(arena, "the body is not an object");
        const name_value = fields.get("name") orelse return self.invalid(arena, "Required: name");
        const name = stringOf(name_value) orelse return self.invalid(arena, "name is not a string");
        if (self.buckets.contains(name)) return .{ .status = 409, .body =
        \\{"error":{"code":409,"message":"Your previous request to create the named bucket succeeded and you already own it.","errors":[{"message":"Your previous request to create the named bucket succeeded and you already own it.","domain":"global","reason":"conflict"}]}}
        };
        const location = if (fields.get("location")) |v| stringOf(v) orelse return self.invalid(arena, "location is not a string") else "US";
        const class_text = if (fields.get("storageClass")) |v| stringOf(v) orelse return self.invalid(arena, "storageClass is not a string") else "STANDARD";
        const class = storageClass(class_text) orelse return self.invalidFmt(arena, "Invalid storage class \"{s}\"", .{class_text});

        var next: ObjectMap = .empty;
        const owned_name = try a.dupe(u8, name);
        try next.put(a, "kind", .{ .string = "storage#bucket" });
        try next.put(a, "name", .{ .string = owned_name });
        try next.put(a, "projectNumber", .{ .string = "82150720798" });
        try next.put(a, "generation", .{ .string = try a.print("{d}", .{self.next_generation}) });
        try next.put(a, "metageneration", .{ .string = "1" });
        try next.put(a, "location", .{ .string = try std.ascii.allocUpperString(a, location) });
        try next.put(a, "storageClass", .{ .string = class });
        try next.put(a, "timeCreated", .{ .string = "2026-09-29T14:07:12.505Z" });
        try next.put(a, "updated", .{ .string = "2026-09-29T14:07:12.505Z" });
        try next.put(a, "softDeletePolicy", try defaultSoftDelete(a));
        var iam: ObjectMap = .empty;
        try iam.put(a, "uniformBucketLevelAccess", try flagObject(a, "enabled", false));
        try iam.put(a, "publicAccessPrevention", .{ .string = "inherited" });
        try next.put(a, "iamConfiguration", .{ .object = iam });
        const regional = std.mem.indexOfScalar(u8, location, '-') != null;
        try next.put(a, "locationType", .{ .string = if (regional) "region" else "multi-region" });
        if (object_retention) {
            var mode: ObjectMap = .empty;
            try mode.put(a, "mode", .{ .string = "Enabled" });
            try next.put(a, "objectRetention", .{ .object = mode });
        }

        var it = fields.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key, "name") or std.mem.eql(u8, key, "location") or std.mem.eql(u8, key, "storageClass")) continue;
            if (std.mem.eql(u8, key, "hierarchicalNamespace")) continue; // judged below, against the whole body
            self.apply(&next, key, entry.value_ptr.*, true) catch |err| switch (err) {
                error.Invalid => return self.refused(arena),
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
        // A hierarchical namespace, judged against what the rest of the
        // body asked for, each refusal in production's words (2026-10-02).
        const hns = hnsAsked(fields);
        if (hns) {
            if (!uniformAccess(next)) return self.invalid(arena, "Hierarchical namespace buckets must use uniform bucket-level access.");
            if (versioningOn(next)) return self.invalid(arena, "Versioning is not supported for hierarchical namespace buckets.");
            if (next.get("retentionPolicy") != null) return self.invalid(arena, "Retention policy is not supported for hierarchical namespace buckets.");
            if (object_retention) return self.invalid(arena, "Object retention config is not supported for hierarchical namespace buckets.");
            try next.put(a, "hierarchicalNamespace", try flagObject(a, "enabled", true));
        }
        // The canned lists, or `projectPrivate`; uniform access keeps none.
        var lists: [2][]const fake_acl.Entry = .{ fake_acl.project_private, fake_acl.project_private };
        for ([_]?[]const u8{ target.predefined_acl, target.predefined_default_object_acl }, &lists, 0..) |name_param, *list, i| {
            const canned = name_param orelse continue;
            if (uniformAccess(next)) return refusalReply(try fake_acl.uniformRefusal(arena, .write_bucket));
            list.* = (if (i == 0) fake_acl.bucketList(canned) else fake_acl.objectList(canned)) orelse return self.invalidFmt(arena, "Invalid predefined ACL \"{s}\"", .{canned});
            if (publicAccessPrevented(next) and fake_acl.isPublic(list.*)) return refusalReply(fake_acl.prevention_refusal);
        }
        try self.buckets.put(a, owned_name, .{
            .resource = next,
            .metageneration = 1,
            .project = try a.dupe(u8, project),
            .hns = hns,
            .acl = lists[0],
            .default_acl = lists[1],
        });
        self.next_generation += 1;
        return .{ .status = 200, .body = try renderStored(arena, self.buckets.getPtr(owned_name).?, target.full) };
    }

    /// Whether a create's body asks for a hierarchical namespace.
    fn hnsAsked(fields: ObjectMap) bool {
        const value = fields.get("hierarchicalNamespace") orelse return false;
        const inner = objectOf(value) orelse return false;
        const enabled = inner.get("enabled") orelse return false;
        return enabled == .bool and enabled.bool;
    }

    fn versioningOn(bucket_resource: ObjectMap) bool {
        const value = bucket_resource.get("versioning") orelse return false;
        const inner = objectOf(value) orelse return false;
        const enabled = inner.get("enabled") orelse return false;
        return enabled == .bool and enabled.bool;
    }

    fn patch(self: *FakeBuckets, name: []const u8, target: Target, body: []const u8, arena: Allocator) Error!Reply {
        const stored = self.buckets.getPtr(name) orelse return notFound();
        if (target.if_metageneration_match) |m| if (m != stored.metageneration) return .{ .status = 412, .body =
        \\{"error":{"code":412,"message":"At least one of the pre-conditions you specified did not hold.","errors":[{"message":"At least one of the pre-conditions you specified did not hold.","domain":"global","reason":"conditionNotMet"}]}}
        };
        if (target.if_metageneration_not_match) |m| if (m == stored.metageneration) return .{ .status = 304 };
        const parsed = std.json.parseFromSliceLeaky(Value, arena, body, .{}) catch return self.invalid(arena, "Parse Error");
        const fields = objectOf(parsed) orelse return self.invalid(arena, "the body is not an object");
        // Measured: an empty patch changes nothing, the metageneration
        // included.
        if (fields.count() == 0 and target.predefined_acl == null and target.predefined_default_object_acl == null) {
            return .{ .status = 200, .body = try renderStored(arena, stored, target.full) };
        }

        const a = self.arena.allocator();
        var next = try cloneObject(a, stored.resource);
        // The lists, before anything changes: a refused one leaves the
        // bucket as it was.
        var lists: [2][]const fake_acl.Entry = .{ stored.acl, stored.default_acl };
        for ([_][]const u8{ "acl", "defaultObjectAcl" }, [_]?[]const u8{ target.predefined_acl, target.predefined_default_object_acl }, &lists, 0..) |field, canned_name, *list, i| {
            const kind: fake_acl.Kind = if (i == 0) .bucket else .default_object;
            const given = fields.get(field);
            const given_items = if (given) |g| (if (g == .array) g.array.items.len else 1) else 0;
            if ((given != null or canned_name != null) and uniformAccess(stored.resource)) {
                return refusalReply(try fake_acl.uniformRefusal(arena, .write_bucket));
            }
            if (canned_name) |canned| {
                if (given_items > 0) return refusalReply(fake_acl.both_refusal);
                list.* = (if (i == 0) fake_acl.bucketList(canned) else fake_acl.objectList(canned)) orelse return self.invalidFmt(arena, "Invalid predefined ACL \"{s}\"", .{canned});
                if (publicAccessPrevented(stored.resource) and fake_acl.isPublic(list.*)) return refusalReply(fake_acl.prevention_refusal);
            } else if (given_items > 0) {
                // An empty list is ignored, as measured.
                switch (try fake_acl.fromBody(a, given.?, kind, if (i == 0) fake_acl.owners else null, publicAccessPrevented(stored.resource))) {
                    .list => |l| list.* = l,
                    .refused => |r| return refusalReply(r),
                }
            }
        }
        var it = fields.iterator();
        while (it.next()) |entry| {
            // Measured: a patch naming hierarchicalNamespace answers 200,
            // drops the field silently, and still moves the metageneration.
            if (std.mem.eql(u8, entry.key_ptr.*, "hierarchicalNamespace")) continue;
            if (std.mem.eql(u8, entry.key_ptr.*, "acl") or std.mem.eql(u8, entry.key_ptr.*, "defaultObjectAcl")) continue;
            self.apply(&next, entry.key_ptr.*, entry.value_ptr.*, false) catch |err| switch (err) {
                error.Invalid => return self.refused(arena),
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
        stored.metageneration += 1;
        try next.put(a, "metageneration", .{ .string = try a.print("{d}", .{stored.metageneration}) });
        try next.put(a, "updated", .{ .string = "2026-09-29T14:07:47.529Z" });
        stored.resource = next;
        stored.acl = lists[0];
        stored.default_acl = lists[1];
        return .{ .status = 200, .body = try renderStored(arena, stored, target.full) };
    }

    /// `lockRetentionPolicy`, as measured.
    fn lock(self: *FakeBuckets, name: []const u8, target: Target, arena: Allocator) Error!Reply {
        const stored = self.buckets.getPtr(name) orelse return notFound();
        const wanted = target.if_metageneration_match orelse return .{ .status = 400, .body =
            \\{"error":{"code":400,"message":"Required parameter: ifMetagenerationMatch","errors":[{"message":"Required parameter: ifMetagenerationMatch","domain":"global","reason":"required"}]}}
        };
        const policy = stored.resource.get("retentionPolicy");
        const unlocked = if (policy) |p| p.object.get("isLocked") == null else false;
        if (!unlocked) return self.invalidFmt(arena, "Bucket '{s}' does not have an unlocked retention policy.", .{name});
        if (wanted != stored.metageneration) return .{ .status = 412, .body =
        \\{"error":{"code":412,"message":"At least one of the pre-conditions you specified did not hold.","errors":[{"message":"At least one of the pre-conditions you specified did not hold.","domain":"global","reason":"conditionNotMet"}]}}
        };
        const a = self.arena.allocator();
        var next = try cloneObject(a, stored.resource);
        var locked = try cloneObject(a, policy.?.object);
        try locked.put(a, "isLocked", .{ .bool = true });
        try next.put(a, "retentionPolicy", .{ .object = locked });
        stored.metageneration += 1;
        try next.put(a, "metageneration", .{ .string = try a.print("{d}", .{stored.metageneration}) });
        stored.resource = next;
        return .{ .status = 200, .body = try render(arena, next) };
    }

    /// A list's single-entry reads. Its writes this library never sends,
    /// so they fail the test.
    fn serveAcl(self: *FakeBuckets, method: Method, name: []const u8, target: AclTarget, arena: Allocator) Error!Reply {
        if (method != .GET) return error.HttpProtocolError;
        self.counts.reads += 1;
        const stored = self.buckets.getPtr(name) orelse return notFound();
        if (uniformAccess(stored.resource)) return refusalReply(try fake_acl.uniformRefusal(arena, .read_bucket));
        const list = if (target.list == .bucket) stored.acl else stored.default_acl;
        const entity = target.entity orelse return .{ .status = 200, .body = try fake_acl.listBody(arena, list, if (target.list == .bucket) .bucket else .default_object) };
        return refusalReply(try fake_acl.entryBody(arena, list, entity));
    }

    /// The default object list new objects in `bucket` get.
    pub fn defaultAcl(self: *const FakeBuckets, bucket: []const u8) []const fake_acl.Entry {
        const stored = self.buckets.getPtr(bucket) orelse return fake_acl.project_private;
        return stored.default_acl;
    }

    /// The bucket's own list, as kept.
    pub fn bucketAcl(self: *const FakeBuckets, bucket: []const u8) []const fake_acl.Entry {
        const stored = self.buckets.getPtr(bucket) orelse return &.{};
        return stored.acl;
    }

    /// Whether public access prevention is enforced on `bucket`.
    pub fn isPrevented(self: *const FakeBuckets, bucket: []const u8) bool {
        const stored = self.buckets.getPtr(bucket) orelse return false;
        return publicAccessPrevented(stored.resource);
    }

    /// The arena lists are kept in, which lives as long as the fake.
    pub fn listArena(self: *FakeBuckets) Allocator {
        return self.arena.allocator();
    }

    /// Makes `topic`, a `//pubsub.googleapis.com/` name, refuse the
    /// configurations that name it.
    pub fn setTopic(self: *FakeBuckets, topic: []const u8, state: TopicState) Allocator.Error!void {
        const a = self.arena.allocator();
        try self.topics.put(a, try a.dupe(u8, topic), state);
    }

    /// The bucket's notification configurations as kept, oldest first.
    pub fn notifications(self: *const FakeBuckets, bucket: []const u8) []const ObjectMap {
        const stored = self.buckets.getPtr(bucket) orelse return &.{};
        return stored.notifications.items;
    }

    /// Whether the bucket has a hierarchical namespace. A missing bucket
    /// has none.
    pub fn isHns(self: *const FakeBuckets, bucket: []const u8) bool {
        const stored = self.buckets.getPtr(bucket) orelse return false;
        return stored.hns;
    }

    /// The folder's state, or null.
    pub fn folderState(self: *const FakeBuckets, bucket: []const u8, folder: []const u8) ?FolderState {
        const stored = self.buckets.getPtr(bucket) orelse return null;
        return stored.folders.get(folder);
    }

    /// Adds the folder, returning false when it was already there.
    pub fn putFolder(self: *FakeBuckets, bucket: []const u8, folder: []const u8) Allocator.Error!bool {
        const stored = self.buckets.getPtr(bucket) orelse return false;
        if (stored.folders.contains(folder)) return false;
        const a = self.arena.allocator();
        try stored.folders.put(a, try a.dupe(u8, folder), .{});
        return true;
    }

    /// Removes the folder, returning whether it was there.
    pub fn dropFolder(self: *FakeBuckets, bucket: []const u8, folder: []const u8) bool {
        const stored = self.buckets.getPtr(bucket) orelse return false;
        return stored.folders.orderedRemove(folder);
    }

    /// The bucket's folder paths, sorted, in `arena`'s memory.
    pub fn folderPaths(self: *const FakeBuckets, bucket: []const u8, arena: Allocator) Allocator.Error![]const []const u8 {
        const stored = self.buckets.getPtr(bucket) orelse return &.{};
        const out = try arena.dupe([]const u8, stored.folders.keys());
        std.mem.sort([]const u8, out, {}, stringLess);
        return out;
    }

    fn stringLess(_: void, left: []const u8, right: []const u8) bool {
        return std.mem.lessThan(u8, left, right);
    }

    /// Whether the bucket has uniform bucket-level access, which managed
    /// folders require.
    pub fn isUniform(self: *const FakeBuckets, bucket: []const u8) bool {
        const stored = self.buckets.getPtr(bucket) orelse return false;
        return uniformAccess(stored.resource);
    }

    /// The managed folder's state, or null.
    pub fn managedState(self: *const FakeBuckets, bucket: []const u8, folder: []const u8) ?*ManagedState {
        const stored = self.buckets.getPtr(bucket) orelse return null;
        return stored.managed.getPtr(folder);
    }

    /// Adds the managed folder, returning false when it was already there.
    pub fn putManaged(self: *FakeBuckets, bucket: []const u8, folder: []const u8) Allocator.Error!bool {
        const stored = self.buckets.getPtr(bucket) orelse return false;
        if (stored.managed.contains(folder)) return false;
        const a = self.arena.allocator();
        try stored.managed.put(a, try a.dupe(u8, folder), .{});
        return true;
    }

    /// Removes the managed folder, returning whether it was there.
    pub fn dropManaged(self: *FakeBuckets, bucket: []const u8, folder: []const u8) bool {
        const stored = self.buckets.getPtr(bucket) orelse return false;
        return stored.managed.orderedRemove(folder);
    }

    /// The bucket's managed folder paths, sorted, in `arena`'s memory.
    pub fn managedPaths(self: *const FakeBuckets, bucket: []const u8, arena: Allocator) Allocator.Error![]const []const u8 {
        const stored = self.buckets.getPtr(bucket) orelse return &.{};
        const out = try arena.dupe([]const u8, stored.managed.keys());
        std.mem.sort([]const u8, out, {}, stringLess);
        return out;
    }

    /// Keeps a managed folder's written bindings, in this arena's memory.
    pub fn keepManagedBindings(self: *FakeBuckets, state: *ManagedState, bindings: []const core.iam.Binding) Allocator.Error!void {
        const a = self.arena.allocator();
        const kept = try a.alloc(core.iam.Binding, bindings.len);
        for (bindings, kept) |from, *to| {
            const members = try a.alloc([]const u8, from.members.len);
            for (from.members, members) |m, *out| out.* = try a.dupe(u8, m);
            to.* = .{
                .role = try a.dupe(u8, from.role),
                .members = members,
                .condition = if (from.condition) |c| try a.dupe(u8, c) else null,
            };
        }
        state.bindings = kept;
        state.policy_writes += 1;
    }

    fn serveNotification(self: *FakeBuckets, method: Method, bucket: []const u8, target: NotificationTarget, body: []const u8, arena: Allocator) Error!Reply {
        const stored = self.buckets.getPtr(bucket) orelse return notFound();
        switch (target) {
            .collection => switch (method) {
                .POST => {
                    self.counts.notification_creates += 1;
                    return self.createNotification(bucket, stored, body, arena);
                },
                .GET => {
                    self.counts.notification_reads += 1;
                    return .{ .status = 200, .body = try renderNotifications(arena, stored.notifications.items) };
                },
                else => return error.HttpProtocolError,
            },
            .id => |id| {
                const index = for (stored.notifications.items, 0..) |n, i| {
                    if (std.mem.eql(u8, stringOf(n.get("id").?).?, id)) break i;
                } else null;
                switch (method) {
                    .GET => {
                        self.counts.notification_reads += 1;
                        const i = index orelse return notificationMissing();
                        return .{ .status = 200, .body = try render(arena, stored.notifications.items[i]) };
                    },
                    .DELETE => {
                        self.counts.notification_deletes += 1;
                        const i = index orelse return notificationMissing();
                        _ = stored.notifications.orderedRemove(i);
                        try self.bump(stored);
                        return .{ .status = 204 };
                    },
                    else => return error.HttpProtocolError,
                }
            },
        }
    }

    fn serveIam(self: *FakeBuckets, method: Method, bucket: []const u8, target: IamTarget, body: []const u8, arena: Allocator) Error!Reply {
        const stored = self.buckets.getPtr(bucket) orelse return notFound();
        switch (target) {
            .policy => |requested| switch (method) {
                .GET => {
                    self.counts.iam_reads += 1;
                    return .{ .status = 200, .body = try renderPolicy(arena, bucket, stored, requested orelse 1) };
                },
                .PUT => {
                    self.counts.iam_writes += 1;
                    return self.setPolicy(bucket, stored, body, arena);
                },
                else => return error.HttpProtocolError,
            },
            .test_permissions => |permissions| {
                if (method != .GET) return error.HttpProtocolError;
                self.counts.iam_tests += 1;
                return testPermissions(arena, permissions);
            },
        }
    }

    /// A policy written whole, refused as Cloud Storage refused each case.
    fn setPolicy(self: *FakeBuckets, bucket: []const u8, stored: *Stored, body: []const u8, arena: Allocator) Error!Reply {
        const policy = core.iam.decode(arena, body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidResponse => return answer(arena, 400, "invalid", "The role name must be in the form \"roles/{role}\", \"organizations/{organization_id}/roles/{role}\", or \"projects/{project_id}/roles/{role}\"."),
        };
        if (policy.etag) |etag| if (etag.len > 0) {
            var raw: [16]u8 = undefined;
            const size = std.base64.standard.Decoder.calcSizeForSlice(etag) catch return answer(arena, 400, "invalid", try arena.print("Invalid value for ByteString: {s}", .{etag}));
            if (size > raw.len) return answer(arena, 400, "invalid", "Invalid etag - must use etag from GetPolicy response.");
            std.base64.standard.Decoder.decode(raw[0..size], etag) catch return answer(arena, 400, "invalid", try arena.print("Invalid value for ByteString: {s}", .{etag}));
            const meta = metagenerationOfEtag(raw[0..size]) orelse return answer(arena, 400, "invalid", "Invalid etag - must use etag from GetPolicy response.");
            if (meta > stored.metageneration) return answer(arena, 400, "invalid", "Invalid etag - must use etag from GetPolicy response.");
            if (meta != stored.metageneration) return answer(arena, 412, "conditionNotMet", "At least one of the pre-conditions you specified did not hold.");
        };
        const uniform = uniformAccess(stored.resource);
        const prevention = publicAccessPrevented(stored.resource);
        for (policy.bindings) |b| {
            if (core.iam.roleProblem(b.role) != null) return answer(arena, 400, "invalid", "The role name must be in the form \"roles/{role}\", \"organizations/{organization_id}/roles/{role}\", or \"projects/{project_id}/roles/{role}\".");
            if (std.mem.startsWith(u8, b.role, "roles/") and !std.mem.startsWith(u8, b.role, "roles/storage.")) {
                return answer(arena, 400, "invalid", try arena.print("Role {s} is not supported for this resource.", .{b.role}));
            }
            for (b.members) |m| {
                if (std.mem.eql(u8, m, "allUsers") or std.mem.eql(u8, m, "allAuthenticatedUsers")) {
                    if (prevention) return answer(arena, 412, "conditionNotMet", "The member bindings allUsers and allAuthenticatedUsers are not allowed since public access prevention is enforced.");
                    continue;
                }
                if (std.mem.eql(u8, m, "user:")) return answer(arena, 400, "invalid", "The email address of a user in the IAM policy is empty.");
                for ([_][]const u8{ "projectOwner:", "projectEditor:", "projectViewer:" }) |prefix| {
                    if (!std.mem.startsWith(u8, m, prefix)) continue;
                    const project = m[prefix.len..];
                    if (!std.mem.eql(u8, project, stored.project)) return answer(arena, 400, "invalid", try arena.print("Project {s} does not exist.", .{project}));
                }
                if (core.iam.memberProblem(m, .{ .project_values = true, .deleted = true }) != null) {
                    return answer(arena, 400, "invalid", try arena.print("The member {s} is of an unknown type. Please set a valid type prefix for the member.", .{m}));
                }
            }
        }
        if (policy.hasConditions()) {
            if (!uniform) return answer(arena, 412, "conditionNotMet", "To set IAM conditions in this bucket, enable uniform bucket-level access. This ensures that all object access is controlled uniformly at the bucket-level without individual, object-level permissions. Learn more at https://cloud.google.com/storage/docs/uniform-bucket-level-access");
            if (policy.version < 3) return answer(arena, 400, "invalid", try arena.print("Specified policy version ({d}) must be at least 3 based on the policy's contents. For more information, please refer to https://cloud.google.com/iam/help/allow-policies/versions.", .{policy.version}));
        }
        stored.bindings = try storedBindings(self.arena.allocator(), policy.bindings);
        try self.bump(stored);
        return .{ .status = 200, .body = try renderPolicy(arena, bucket, stored, 3) };
    }

    /// A configuration's create or delete moves the bucket's metageneration.
    fn bump(self: *FakeBuckets, stored: *Stored) Allocator.Error!void {
        const a = self.arena.allocator();
        stored.metageneration += 1;
        var next = try cloneObject(a, stored.resource);
        try next.put(a, "metageneration", .{ .string = try a.print("{d}", .{stored.metageneration}) });
        stored.resource = next;
    }

    /// Cloud Storage's order: it answers with the event types in this one,
    /// whatever the order sent.
    const event_order = [_][]const u8{ "OBJECT_FINALIZE", "OBJECT_METADATA_UPDATE", "OBJECT_DELETE", "OBJECT_ARCHIVE", "OBJECT_INITIALIZE" };
    const max_overlapping = 10;

    fn createNotification(self: *FakeBuckets, bucket: []const u8, stored: *Stored, body: []const u8, arena: Allocator) Error!Reply {
        const a = self.arena.allocator();
        const parsed = std.json.parseFromSliceLeaky(Value, arena, body, .{}) catch return self.invalid(arena, "Parse Error");
        const fields = objectOf(parsed) orelse return self.invalid(arena, "the body is not an object");
        var it = fields.iterator();
        while (it.next()) |entry| {
            // A field this library never sends fails the test.
            if (!isOneOf(entry.key_ptr.*, &.{ "topic", "payload_format", "event_types", "custom_attributes", "object_name_prefix" })) return error.HttpProtocolError;
        }
        const format = if (fields.get("payload_format")) |v| stringOf(v) orelse "" else "";
        if (!isOneOf(format, &.{ "JSON_API_V1", "NONE" })) return answer(arena, 400, "required", "You must specify a payload format in the 'payload_format' field.");
        const sent_topic = if (fields.get("topic")) |v| stringOf(v) orelse "" else "";
        const topic = try normalTopic(arena, sent_topic) orelse
            return self.invalid(arena, "Invalid Google Cloud Pub/Sub topic. It should look like '//pubsub.googleapis.com/projects/*/topics/*.'");
        if (self.topics.get(topic)) |state| switch (state) {
            .missing => return self.invalidFmt(arena, "Cloud Pub/Sub topic '{s}' not found, or user '{s}' does not have permission to it.", .{ topic, service_agent }),
            .ungranted => return answer(arena, 403, "forbidden", try arena.print(
                "The service account '{s}' does not have permission to publish messages to to the Cloud Pub/Sub topic '{s}', or that topic does not exist.",
                .{ service_agent, topic },
            )),
        };

        var attributes: ObjectMap = .empty;
        if (fields.get("custom_attributes")) |v| {
            const map = objectOf(v) orelse return error.HttpProtocolError;
            if (map.count() > 5) return self.invalidFmt(arena, "Maximum of 5 custom attributes, notification config had {d}", .{map.count()});
            var attribute_it = map.iterator();
            while (attribute_it.next()) |entry| {
                const key = entry.key_ptr.*;
                const value = stringOf(entry.value_ptr.*) orelse return error.HttpProtocolError;
                if (key.len == 0) return self.invalid(arena, "Custom attribute keys may not be empty");
                const key_chars = characters(key);
                if (key_chars > 256) return self.invalidFmt(arena, "Notification keys may not be longer than 256 characters, but key '{s}' contains {d} characters.", .{ key, key_chars });
                const value_chars = characters(value);
                if (value_chars > 1024) return self.invalidFmt(arena, "Notification values may not be longer than 1024 characters, but value '{s}' contains {d} characters.", .{ value, value_chars });
                try attributes.put(a, try a.dupe(u8, key), .{ .string = try a.dupe(u8, value) });
            }
        }

        // The types Cloud Storage knows, in its order; the rest dropped.
        var events: [event_order.len]bool = @splat(false);
        if (fields.get("event_types")) |v| {
            for (arrayOf(v) orelse return error.HttpProtocolError) |item| {
                const name = stringOf(item) orelse return error.HttpProtocolError;
                for (event_order, &events) |known, *on| if (std.mem.eql(u8, name, known)) {
                    on.* = true;
                };
            }
        }
        const every = std.mem.indexOfScalar(bool, &events, true) == null;
        for (event_order, events) |name, on| {
            if (!every and !on) continue;
            var overlapping: usize = 0;
            for (stored.notifications.items) |n| {
                if (covers(n, name)) overlapping += 1;
            }
            if (overlapping >= max_overlapping) return self.invalid(arena, "Too many overlapping notifications. The maximum is 10.");
        }

        const id = try a.print("{d}", .{stored.metageneration});
        var next: ObjectMap = .empty;
        try next.put(a, "kind", .{ .string = "storage#notification" });
        try next.put(a, "selfLink", .{ .string = try a.print("https://www.googleapis.com/storage/v1/b/{s}/notificationConfigs/{s}", .{ bucket, id }) });
        try next.put(a, "id", .{ .string = id });
        try next.put(a, "topic", .{ .string = try a.dupe(u8, topic) });
        if (!every) {
            var list: std.json.Array = .init(a);
            for (event_order, events) |name, on| if (on) try list.append(.{ .string = name });
            try next.put(a, "event_types", .{ .array = list });
        }
        if (attributes.count() > 0) try next.put(a, "custom_attributes", .{ .object = attributes });
        try next.put(a, "etag", .{ .string = id });
        if (fields.get("object_name_prefix")) |v| {
            try next.put(a, "object_name_prefix", .{ .string = try a.dupe(u8, stringOf(v) orelse return error.HttpProtocolError) });
        }
        try next.put(a, "payload_format", .{ .string = if (std.mem.eql(u8, format, "NONE")) "NONE" else "JSON_API_V1" });
        try stored.notifications.append(a, next);
        try self.bump(stored);
        return .{ .status = 200, .body = try render(arena, next) };
    }

    /// Whether objects in the bucket may carry a retention of their own.
    pub fn objectRetention(self: *const FakeBuckets, name: []const u8) bool {
        const r = self.resource(name) orelse return false;
        return r.get("objectRetention") != null;
    }

    const ApplyError = error{ Invalid, OutOfMemory };

    /// One field of a create or a patch, applied to `next`.
    fn apply(self: *FakeBuckets, next: *ObjectMap, key: []const u8, value: Value, creating: bool) ApplyError!void {
        if (std.mem.eql(u8, key, "labels")) return self.applyLabels(next, value, creating);
        if (std.mem.eql(u8, key, "lifecycle")) return self.applyLifecycle(next, value);
        if (std.mem.eql(u8, key, "softDeletePolicy")) return self.applySoftDelete(next, value);
        if (std.mem.eql(u8, key, "versioning")) return self.applyFlag(next, "versioning", "enabled", value);
        if (std.mem.eql(u8, key, "billing")) return self.applyFlag(next, "billing", "requesterPays", value);
        if (std.mem.eql(u8, key, "encryption")) return self.applyEncryption(next, value);
        if (std.mem.eql(u8, key, "iamConfiguration")) return self.applyIam(next, value);
        if (std.mem.eql(u8, key, "retentionPolicy")) return self.applyRetention(next, value);
        // Measured: taken, and ignored. Only a create's parameter turns it
        // on.
        if (std.mem.eql(u8, key, "objectRetention")) return;
        if (std.mem.eql(u8, key, "defaultEventBasedHold")) {
            if (value != .bool) return self.fail("defaultEventBasedHold is not a boolean");
            return next.put(self.arena.allocator(), "defaultEventBasedHold", value);
        }
        if (!creating and std.mem.eql(u8, key, "storageClass")) {
            const text = stringOf(value) orelse return self.fail("storageClass is not a string");
            const class = storageClass(text) orelse return self.failFmt("Invalid storage class \"{s}\"", .{text});
            return next.put(self.arena.allocator(), "storageClass", .{ .string = class });
        }
        return self.failFmt("this fake does not take the field \"{s}\"", .{key});
    }

    fn applyLabels(self: *FakeBuckets, next: *ObjectMap, value: Value, creating: bool) ApplyError!void {
        const a = self.arena.allocator();
        const changes = switch (value) {
            .null => {
                _ = next.orderedRemove("labels");
                return;
            },
            .object => |o| o,
            else => return self.fail("labels is not an object"),
        };
        // Measured: an empty object removes every label.
        if (changes.count() == 0) {
            _ = next.orderedRemove("labels");
            return;
        }
        var labels: ObjectMap = if (next.get("labels")) |current| try cloneObject(a, current.object) else .empty;
        var it = changes.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            // Checked for a removal too.
            if (!labelTextOk(key, true)) return self.failFmt("Invalid user label: {s}", .{key});
            switch (entry.value_ptr.*) {
                .null => {
                    if (creating) return self.failFmt("Invalid user label: {s} with no value", .{key});
                    _ = labels.orderedRemove(key);
                },
                .string => |text| {
                    if (!labelTextOk(text, false)) return self.failFmt("Invalid user label: {s} with value {s}", .{ key, text });
                    try labels.put(a, try a.dupe(u8, key), .{ .string = try a.dupe(u8, text) });
                },
                else => return self.fail("a label value is not a string"),
            }
        }
        if (labels.count() > 64) return self.failFmt("Attempt to create a bucket with {d} labels, maximum is 64", .{labels.count()});
        if (labels.count() == 0) {
            _ = next.orderedRemove("labels");
        } else {
            try next.put(a, "labels", .{ .object = labels });
        }
    }

    fn applyLifecycle(self: *FakeBuckets, next: *ObjectMap, value: Value) ApplyError!void {
        const a = self.arena.allocator();
        const fields = switch (value) {
            .null => {
                _ = next.orderedRemove("lifecycle");
                return;
            },
            .object => |o| o,
            else => return self.fail("lifecycle is not an object"),
        };
        // Measured: `{}` changes nothing.
        const rules_value = fields.get("rule") orelse return;
        const rules = switch (rules_value) {
            .array => |list| list.items,
            else => return self.fail("lifecycle.rule is not a list"),
        };
        if (rules.len == 0) {
            _ = next.orderedRemove("lifecycle");
            return;
        }
        var out: std.json.Array = .init(a);
        var affixes: usize = 0;
        for (rules) |rule| try out.append(try self.normalizedRule(rule, &affixes));
        if (affixes > 1000) return self.fail("Lifecycle matches_suffix and matches_prefix cannot specify more than 1000 rules per config.");
        var lifecycle: ObjectMap = .empty;
        try lifecycle.put(a, "rule", .{ .array = out });
        try next.put(a, "lifecycle", .{ .object = lifecycle });
    }

    /// A rule as Cloud Storage keeps it: days as numbers, sizes as
    /// strings, classes uppercased, empty lists dropped.
    fn normalizedRule(self: *FakeBuckets, rule: Value, affixes: *usize) ApplyError!Value {
        const a = self.arena.allocator();
        const fields = objectOf(rule) orelse return self.fail("a rule is not an object");
        var it = fields.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (!std.mem.eql(u8, key, "action") and !std.mem.eql(u8, key, "condition")) {
                return self.failFmt("this fake does not take the rule field \"{s}\"", .{key});
            }
        }
        const action = objectOf(fields.get("action") orelse return self.fail("a rule has no action")) orelse
            return self.fail("action is not an object");
        const kind = stringOf(action.get("type") orelse return self.fail("an action has no type")) orelse
            return self.fail("an action's type is not a string");
        var out_action: ObjectMap = .empty;
        const abort = std.mem.eql(u8, kind, "AbortIncompleteMultipartUpload");
        if (std.mem.eql(u8, kind, "SetStorageClass")) {
            const class_value = action.get("storageClass") orelse
                return self.fail("Lifecycle storage class rules must specify the destination storage class.");
            const text = stringOf(class_value) orelse return self.fail("storageClass is not a string");
            const class = storageClass(text) orelse
                return self.failFmt("Unknown storage class '{s}' is not a valid option for SET_STORAGE_CLASS actions.", .{text});
            try out_action.put(a, "storageClass", .{ .string = class });
        } else if (std.mem.eql(u8, kind, "Delete") or abort) {
            if (action.get("storageClass") != null) return self.fail("Storage class can only be specified for SET_STORAGE_CLASS actions");
        } else return self.failFmt("Invalid value for: {s} is not a valid value", .{kind});
        if (action.count() > 1 + @as(usize, @intFromBool(out_action.count() > 0))) {
            return self.fail("this fake does not take that action field");
        }
        try out_action.put(a, "type", .{ .string = try a.dupe(u8, kind) });

        const condition = objectOf(fields.get("condition") orelse return self.fail("Lifecycle rules must have a condition.")) orelse
            return self.fail("condition is not an object");
        var out: ObjectMap = .empty;
        var cit = condition.iterator();
        while (cit.next()) |entry| {
            const key = entry.key_ptr.*;
            const v = entry.value_ptr.*;
            if (v == .null) continue;
            if (isOneOf(key, &.{ "age", "daysSinceCustomTime", "daysSinceNoncurrentTime", "numNewerVersions" })) {
                const n = integerOf(v) orelse return self.failFmt("{s} is not a number", .{key});
                if (n < 0) return self.failFmt("Lifecycle {s} condition must be greater than or equal to 0, but was {d}", .{ key, n });
                if (n > std.math.maxInt(i32)) return self.failFmt("Parse Error: Invalid value for TYPE_INT32 field: '{d}'.", .{n});
                try out.put(a, try a.dupe(u8, key), .{ .integer = n });
            } else if (isOneOf(key, &.{ "createdBefore", "customTimeBefore", "noncurrentTimeBefore" })) {
                const text = stringOf(v) orelse return self.failFmt("{s} is not a string", .{key});
                if (!dateOk(text)) return self.failFmt("Invalid value for: Invalid format: \"{s}\"", .{text});
                try out.put(a, try a.dupe(u8, key), .{ .string = try a.dupe(u8, text) });
            } else if (std.mem.eql(u8, key, "isLive")) {
                if (v != .bool) return self.fail("isLive is not a boolean");
                try out.put(a, "isLive", v);
            } else if (isOneOf(key, &.{ "matchesPrefix", "matchesSuffix" })) {
                const items = arrayOf(v) orelse return self.failFmt("{s} is not a list", .{key});
                if (items.len == 0) continue;
                var list: std.json.Array = .init(a);
                for (items) |item| {
                    const text = stringOf(item) orelse return self.failFmt("{s} holds a non-string", .{key});
                    if (text.len == 0 or text.len > 1024) {
                        return self.failFmt("Lifecycle {s} cannot contain a string that is empty or longer than 1024.", .{key});
                    }
                    try list.append(.{ .string = try a.dupe(u8, text) });
                }
                affixes.* += items.len;
                try out.put(a, try a.dupe(u8, key), .{ .array = list });
            } else if (std.mem.eql(u8, key, "matchesStorageClass")) {
                const items = arrayOf(v) orelse return self.fail("matchesStorageClass is not a list");
                if (items.len == 0) continue;
                var list: std.json.Array = .init(a);
                for (items) |item| {
                    const text = stringOf(item) orelse return self.fail("matchesStorageClass holds a non-string");
                    const class = storageClass(text) orelse return self.failFmt("Invalid storage class \"{s}\"", .{text});
                    try list.append(.{ .string = class });
                }
                try out.put(a, "matchesStorageClass", .{ .array = list });
            } else if (isOneOf(key, &.{ "sizeAboveBytes", "sizeBelowBytes" })) {
                const n = integerOf(v) orelse return self.failFmt("Parse Error: Invalid value for TYPE_SFIXED64 field: {s}", .{key});
                if (n < 0 or n > 5 << 40) {
                    return self.failFmt("Lifecycle {s} condition cannot exceed GCS maximum object size limit: 5 TiB, but was {d}.", .{ key, n });
                }
                try out.put(a, try a.dupe(u8, key), .{ .string = try a.print("{d}", .{n}) });
            } else if (std.mem.eql(u8, key, "matchesPattern")) {
                return self.fail("MatchesPattern is not available for this project 82150720798");
            } else return self.failFmt("this fake does not take the condition \"{s}\"", .{key});
        }
        if (out.count() == 0) return self.fail("Lifecycle rules must have a condition.");
        if (abort) {
            var oit = out.iterator();
            while (oit.next()) |entry| {
                if (!isOneOf(entry.key_ptr.*, &.{ "age", "matchesPrefix", "matchesSuffix" })) return self.fail(
                    "Lifecycle age_days, matches_prefix, and matches_suffix conditions are the only ones allowed for a ABORT_INCOMPLETE_MULTIPART_UPLOAD rule.",
                );
            }
        }
        var normalized: ObjectMap = .empty;
        try normalized.put(a, "action", .{ .object = out_action });
        try normalized.put(a, "condition", .{ .object = out });
        return .{ .object = normalized };
    }

    fn applySoftDelete(self: *FakeBuckets, next: *ObjectMap, value: Value) ApplyError!void {
        const a = self.arena.allocator();
        const fields = switch (value) {
            // Measured: null puts the default back rather than turning
            // soft delete off.
            .null => return next.put(a, "softDeletePolicy", try defaultSoftDelete(a)),
            .object => |o| o,
            else => return self.fail("softDeletePolicy is not an object"),
        };
        const retention = fields.get("retentionDurationSeconds") orelse return;
        const seconds = integerOf(retention) orelse return self.fail("retentionDurationSeconds is not a number");
        if (seconds != 0 and (seconds < 604_800 or seconds > 7_776_000)) {
            return self.fail("Soft delete policy must have a retention duration between 7 days and 90 days.");
        }
        var policy: ObjectMap = .empty;
        try policy.put(a, "retentionDurationSeconds", .{ .string = try a.print("{d}", .{seconds}) });
        if (seconds != 0) try policy.put(a, "effectiveTime", .{ .string = "2026-09-29T14:08:48.987Z" });
        try next.put(a, "softDeletePolicy", .{ .object = policy });
    }

    fn applyRetention(self: *FakeBuckets, next: *ObjectMap, value: Value) ApplyError!void {
        const a = self.arena.allocator();
        const old = next.get("retentionPolicy");
        const locked = if (old) |p| p.object.get("isLocked") != null else false;
        const name = next.get("name").?.string;
        const fields = switch (value) {
            .null => {
                if (locked) return self.forbid("retentionPolicyNotMet", try a.print("Bucket '{s}' has a locked Retention Policy which cannot be removed.", .{name}));
                _ = next.orderedRemove("retentionPolicy");
                return;
            },
            .object => |o| o,
            else => return self.fail("retentionPolicy is not an object"),
        };
        // Measured: `{}`, `isLocked` and `effectiveTime` change nothing.
        const period_value = fields.get("retentionPeriod") orelse return;
        const period: i64 = switch (period_value) {
            .integer => |n| n,
            .string => |text| std.fmt.parseInt(i64, text, 10) catch
                return self.failFmt("Parse Error: Invalid value for TYPE_INT64 field: '\"{s}\"'.", .{text}),
            else => return self.fail("Parse Error: Invalid value for TYPE_INT64 field"),
        };
        if (period < 1 or period > 3_155_760_000) {
            return self.fail("Retention policy must have a retention period greater than 0 and less than 100 years.");
        }
        if (locked) {
            const current = std.fmt.parseInt(i64, old.?.object.get("retentionPeriod").?.string, 10) catch unreachable;
            if (period < current) return self.forbid("forbidden", try a.print("Cannot reduce retention duration of a locked Retention Policy for bucket '{s}'.", .{name}));
        }
        const effective = if (old) |p| p.object.get("effectiveTime").? else Value{ .string = "2026-09-30T21:57:51.487Z" };
        var policy: ObjectMap = .empty;
        try policy.put(a, "retentionPeriod", .{ .string = try a.print("{d}", .{period}) });
        try policy.put(a, "effectiveTime", effective);
        if (locked) try policy.put(a, "isLocked", .{ .bool = true });
        try next.put(a, "retentionPolicy", .{ .object = policy });
    }

    /// The bucket's retention period, or null for none or no such bucket.
    pub fn retentionPeriod(self: *const FakeBuckets, name: []const u8) ?u64 {
        const r = self.resource(name) orelse return null;
        const policy = r.get("retentionPolicy") orelse return null;
        return std.fmt.parseInt(u64, policy.object.get("retentionPeriod").?.string, 10) catch unreachable;
    }

    /// Whether new objects in the bucket get an event-based hold.
    pub fn defaultEventBasedHold(self: *const FakeBuckets, name: []const u8) bool {
        const r = self.resource(name) orelse return false;
        const on = r.get("defaultEventBasedHold") orelse return false;
        return on.bool;
    }

    /// `versioning` and `billing`: one flag each.
    fn applyFlag(self: *FakeBuckets, next: *ObjectMap, field: []const u8, flag: []const u8, value: Value) ApplyError!void {
        const a = self.arena.allocator();
        const fields = switch (value) {
            .null => {
                _ = next.orderedRemove(field);
                return;
            },
            .object => |o| o,
            else => return self.failFmt("{s} is not an object", .{field}),
        };
        if (fields.count() != 1) return self.failFmt("this fake takes {s} with {s} alone", .{ field, flag });
        const on = fields.get(flag) orelse return self.failFmt("{s} has no {s}", .{ field, flag });
        if (on != .bool) return self.failFmt("{s}.{s} is not a boolean", .{ field, flag });
        try next.put(a, field, try flagObject(a, flag, on.bool));
    }

    fn applyEncryption(self: *FakeBuckets, next: *ObjectMap, value: Value) ApplyError!void {
        const a = self.arena.allocator();
        const fields = switch (value) {
            .null => {
                _ = next.orderedRemove("encryption");
                return;
            },
            .object => |o| o,
            else => return self.fail("encryption is not an object"),
        };
        if (fields.count() != 1) return self.fail("this fake takes encryption with defaultKmsKeyName alone");
        const key = fields.get("defaultKmsKeyName") orelse return self.fail("encryption has no defaultKmsKeyName");
        switch (key) {
            .null => _ = next.orderedRemove("encryption"),
            .string => |name| {
                if (!keyNameOk(name)) return self.failFmt("Malformed Cloud KMS crypto key: {s}", .{name});
                var encryption: ObjectMap = .empty;
                try encryption.put(a, "defaultKmsKeyName", .{ .string = try a.dupe(u8, name) });
                try next.put(a, "encryption", .{ .object = encryption });
            },
            else => return self.fail("defaultKmsKeyName is not a string"),
        }
    }

    fn applyIam(self: *FakeBuckets, next: *ObjectMap, value: Value) ApplyError!void {
        const a = self.arena.allocator();
        const fields = objectOf(value) orelse return self.fail("iamConfiguration is not an object");
        var iam = try cloneObject(a, next.get("iamConfiguration").?.object);
        var it = fields.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const v = entry.value_ptr.*;
            if (std.mem.eql(u8, key, "uniformBucketLevelAccess")) {
                const inner = objectOf(v) orelse return self.fail("uniformBucketLevelAccess is not an object");
                const on = inner.get("enabled") orelse return self.fail("uniformBucketLevelAccess has no enabled");
                if (on != .bool or inner.count() != 1) return self.fail("this fake takes uniformBucketLevelAccess with enabled alone");
                try iam.put(a, "uniformBucketLevelAccess", try flagObject(a, "enabled", on.bool));
            } else if (std.mem.eql(u8, key, "publicAccessPrevention")) {
                const text = stringOf(v) orelse return self.fail("publicAccessPrevention is not a string");
                const stored: []const u8 = if (std.mem.eql(u8, text, "inherited") or std.mem.eql(u8, text, "unspecified"))
                    "inherited"
                else if (std.mem.eql(u8, text, "enforced"))
                    "enforced"
                else
                    return self.failFmt("Invalid value for: {s} is not a valid value", .{text});
                try iam.put(a, "publicAccessPrevention", .{ .string = stored });
            } else return self.failFmt("this fake does not take iamConfiguration.{s}", .{key});
        }
        try next.put(a, "iamConfiguration", .{ .object = iam });
    }

    fn fail(self: *FakeBuckets, message: []const u8) error{Invalid} {
        self.refusal = message;
        self.refusal_status = 400;
        self.refusal_reason = "invalid";
        return error.Invalid;
    }

    /// A 403 refusal, as a locked policy's.
    fn forbid(self: *FakeBuckets, reason: []const u8, message: []const u8) error{Invalid} {
        self.refusal = message;
        self.refusal_status = 403;
        self.refusal_reason = reason;
        return error.Invalid;
    }

    fn failFmt(self: *FakeBuckets, comptime format: []const u8, args: anytype) ApplyError {
        return self.fail(try self.arena.allocator().print(format, args));
    }

    /// The latest refusal's answer.
    fn refused(self: *FakeBuckets, arena: Allocator) Allocator.Error!Reply {
        if (self.refusal_status == 400) return self.invalid(arena, self.refusal);
        const body = try std.json.Stringify.valueAlloc(arena, .{ .@"error" = .{
            .code = self.refusal_status,
            .message = self.refusal,
            .errors = .{.{ .message = self.refusal, .domain = "global", .reason = self.refusal_reason }},
        } }, .{});
        return .{ .status = self.refusal_status, .body = body };
    }

    fn invalid(self: *FakeBuckets, arena: Allocator, message: []const u8) Allocator.Error!Reply {
        self.refusal = message;
        const body = try std.json.Stringify.valueAlloc(arena, .{ .@"error" = .{
            .code = 400,
            .message = message,
            .errors = .{.{ .message = message, .domain = "global", .reason = "invalid" }},
        } }, .{});
        return .{ .status = 400, .body = body };
    }

    fn invalidFmt(self: *FakeBuckets, arena: Allocator, comptime format: []const u8, args: anytype) Allocator.Error!Reply {
        return self.invalid(arena, try arena.print(format, args));
    }
};

fn notFound() FakeBuckets.Reply {
    return .{ .status = 404, .body =
    \\{"error":{"code":404,"message":"The specified bucket does not exist.","errors":[{"message":"The specified bucket does not exist.","domain":"global","reason":"notFound"}]}}
    };
}

/// The project's Cloud Storage service agent, as production names it in
/// the refusals of a topic.
const service_agent = "service-82150720798@gs-project-accounts.iam.gserviceaccount.com";

fn notificationMissing() FakeBuckets.Reply {
    return .{ .status = 404, .body =
    \\{"error":{"code":404,"message":"The requested resource was not found.","errors":[{"message":"The requested resource was not found.","domain":"global","reason":"notFound"}]}}
    };
}

/// A refusal with `status`, `reason` and `message`, in Cloud Storage's shape.
fn answer(arena: Allocator, status: u16, reason: []const u8, message: []const u8) Allocator.Error!FakeBuckets.Reply {
    const body = try std.json.Stringify.valueAlloc(arena, .{ .@"error" = .{
        .code = status,
        .message = message,
        .errors = .{.{ .message = message, .domain = "global", .reason = reason }},
    } }, .{});
    return .{ .status = status, .body = body };
}

/// The etag Cloud Storage gives a bucket's policy: its metageneration, as
/// a protocol buffer's first field (`CAE=` for 1), in base64.
pub fn etagOf(buf: *[24]u8, metageneration: u64) []const u8 {
    var raw: [11]u8 = undefined;
    raw[0] = 0x08;
    var n: usize = 1;
    var m = metageneration;
    while (m >= 0x80) : (m >>= 7) {
        raw[n] = @as(u8, @truncate(m)) | 0x80;
        n += 1;
    }
    raw[n] = @truncate(m);
    n += 1;
    return std.base64.standard.Encoder.encode(buf, raw[0..n]);
}

/// The metageneration an etag names, or null for bytes that are no etag.
pub fn metagenerationOfEtag(raw: []const u8) ?u64 {
    if (raw.len < 2 or raw[0] != 0x08) return null;
    var value: u64 = 0;
    var shift: u6 = 0;
    for (raw[1..], 1..) |byte, i| {
        value |= @as(u64, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return if (i == raw.len - 1) value else null;
        if (shift >= 56) return null;
        shift += 7;
    }
    return null;
}

fn uniformAccess(resource: ObjectMap) bool {
    const iam = objectOf(resource.get("iamConfiguration") orelse return false) orelse return false;
    const ubla = objectOf(iam.get("uniformBucketLevelAccess") orelse return false) orelse return false;
    const on = ubla.get("enabled") orelse return false;
    return on == .bool and on.bool;
}

fn publicAccessPrevented(resource: ObjectMap) bool {
    const iam = objectOf(resource.get("iamConfiguration") orelse return false) orelse return false;
    const pap = stringOf(iam.get("publicAccessPrevention") orelse return false) orelse return false;
    return std.mem.eql(u8, pap, "enforced");
}

/// The legacy bindings a bucket starts with, as measured: with uniform
/// access, the object roles too.
fn legacyBindings(arena: Allocator, stored: *const FakeBuckets.Stored) Allocator.Error![]const core.iam.Binding {
    const owners = try arena.dupe([]const u8, &.{
        try arena.print("projectEditor:{s}", .{stored.project}),
        try arena.print("projectOwner:{s}", .{stored.project}),
    });
    const viewers = try arena.dupe([]const u8, &.{try arena.print("projectViewer:{s}", .{stored.project})});
    if (uniformAccess(stored.resource)) return arena.dupe(core.iam.Binding, &.{
        .{ .role = "roles/storage.legacyBucketOwner", .members = owners },
        .{ .role = "roles/storage.legacyBucketReader", .members = viewers },
        .{ .role = "roles/storage.legacyObjectOwner", .members = owners },
        .{ .role = "roles/storage.legacyObjectReader", .members = viewers },
    });
    return arena.dupe(core.iam.Binding, &.{
        .{ .role = "roles/storage.legacyBucketOwner", .members = owners },
        .{ .role = "roles/storage.legacyBucketReader", .members = viewers },
    });
}

/// `bindings` as Cloud Storage stores them: addresses lowercased, one
/// binding per role and condition, members once, empty bindings dropped.
fn storedBindings(a: Allocator, bindings: []const core.iam.Binding) Allocator.Error![]const core.iam.Binding {
    var out: std.ArrayList(core.iam.Binding) = .empty;
    var members: std.ArrayList(std.ArrayList([]const u8)) = .empty;
    for (bindings) |b| {
        const index = for (out.items, 0..) |o, i| {
            const same_condition = if (o.condition) |c| (if (b.condition) |d| std.mem.eql(u8, c, d) else false) else b.condition == null;
            if (std.mem.eql(u8, o.role, b.role) and same_condition) break i;
        } else blk: {
            try out.append(a, .{ .role = try a.dupe(u8, b.role), .members = &.{}, .condition = if (b.condition) |c| try a.dupe(u8, c) else null });
            try members.append(a, .empty);
            break :blk out.items.len - 1;
        };
        for (b.members) |m| {
            const stored_form = try lowercasedAddress(a, m);
            for (members.items[index].items) |kept| {
                if (std.mem.eql(u8, kept, stored_form)) break;
            } else try members.items[index].append(a, stored_form);
        }
    }
    var kept: std.ArrayList(core.iam.Binding) = .empty;
    for (out.items, members.items) |b, list| {
        if (list.items.len == 0) continue;
        try kept.append(a, .{ .role = b.role, .members = list.items, .condition = b.condition });
    }
    return kept.items;
}

fn lowercasedAddress(a: Allocator, member: []const u8) Allocator.Error![]const u8 {
    for ([_][]const u8{ "user:", "serviceAccount:", "group:", "domain:" }) |prefix| {
        if (!std.mem.startsWith(u8, member, prefix)) continue;
        const out = try a.dupe(u8, member);
        _ = std.ascii.lowerString(out[prefix.len..], member[prefix.len..]);
        return out;
    }
    return a.dupe(u8, member);
}

/// The policy as a read answers it: version 3 with its conditions when
/// asked for 3, else version 1 with each conditional role renamed.
fn renderPolicy(arena: Allocator, bucket: []const u8, stored: *const FakeBuckets.Stored, requested: u32) Allocator.Error![]const u8 {
    const bindings = stored.bindings orelse try legacyBindings(arena, stored);
    var conditional = false;
    for (bindings) |b| conditional = conditional or b.condition != null;
    const version: u32 = if (conditional and requested >= 3) 3 else 1;
    var etag_buf: [24]u8 = undefined;
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    writePolicy(&jw, bucket, version, etagOf(&etag_buf, stored.metageneration), bindings) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writePolicy(jw: *std.json.Stringify, bucket: []const u8, version: u32, etag: []const u8, bindings: []const core.iam.Binding) !void {
    try jw.beginObject();
    try jw.objectField("kind");
    try jw.write("storage#policy");
    try jw.objectField("resourceId");
    try jw.print("\"projects/_/buckets/{s}\"", .{bucket});
    try jw.objectField("version");
    try jw.write(version);
    try jw.objectField("etag");
    try jw.write(etag);
    if (bindings.len > 0) {
        try jw.objectField("bindings");
        try jw.beginArray();
        for (bindings) |b| {
            try jw.beginObject();
            try jw.objectField("role");
            if (b.condition != null and version < 3) {
                try jw.print("\"{s}_withcond_4e0bd94b67e008e72efb\"", .{b.role});
            } else try jw.write(b.role);
            try jw.objectField("members");
            try jw.write(b.members);
            if (b.condition) |condition| if (version >= 3) {
                try jw.objectField("condition");
                try jw.beginWriteRaw();
                try jw.writer.writeAll(condition);
                jw.endWriteRaw();
            };
            try jw.endObject();
        }
        try jw.endArray();
    }
    try jw.endObject();
}

/// `testIamPermissions`, refused as Cloud Storage refused each case, and
/// every permission held.
fn testPermissions(arena: Allocator, permissions: []const []const u8) Allocator.Error!FakeBuckets.Reply {
    if (permissions.len == 0) return answer(arena, 400, "required", "Required parameter: permissions");
    if (permissions.len > 84) return answer(arena, 400, "invalid", "Must specify <= 84 permissions.");
    for (permissions, 0..) |p, i| {
        for (permissions[0..i]) |q| if (std.mem.eql(u8, p, q)) return answer(arena, 400, "invalid", "Duplicate permissions must not be specified.");
    }
    for (permissions) |p| {
        if (std.mem.eql(u8, p, "storage.buckets.list") or std.mem.eql(u8, p, "storage.buckets.create")) return answer(arena, 400, "invalid", "Invalid argument.");
        if (!std.mem.startsWith(u8, p, "storage.") or std.mem.indexOfScalar(u8, p, '*') != null) {
            return answer(arena, 400, "invalid", try arena.print("{s} is not a valid Google Cloud Storage permission.", .{p}));
        }
    }
    const body = try std.json.Stringify.valueAlloc(arena, .{ .kind = "storage#testIamPermissionsResponse", .permissions = permissions }, .{});
    return .{ .status = 200, .body = body };
}

/// `topic` in the form Cloud Storage keeps, or null for one it refuses.
fn normalTopic(arena: Allocator, topic: []const u8) Allocator.Error!?[]const u8 {
    const full = "//pubsub.googleapis.com/";
    const rest = if (std.mem.startsWith(u8, topic, full)) topic[full.len..] else topic;
    if (!std.mem.startsWith(u8, rest, "projects/")) return null;
    var parts = std.mem.splitScalar(u8, rest["projects/".len..], '/');
    const project = parts.next() orelse return null;
    const word = parts.next() orelse return null;
    const id = parts.next() orelse return null;
    if (parts.next() != null or project.len == 0 or id.len == 0 or !std.mem.eql(u8, word, "topics")) return null;
    return try arena.print("//pubsub.googleapis.com/projects/{s}/topics/{s}", .{ project, id });
}

/// What Cloud Storage's limits call characters: bytes, as measured.
fn characters(text: []const u8) usize {
    return text.len;
}

/// Whether a kept configuration publishes `event`: one that names no types
/// publishes every type.
fn covers(n: ObjectMap, event: []const u8) bool {
    const listed = n.get("event_types") orelse return true;
    for (listed.array.items) |item| {
        if (std.mem.eql(u8, item.string, event)) return true;
    }
    return false;
}

fn renderNotifications(arena: Allocator, items: []const ObjectMap) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    jw.beginObject() catch return error.OutOfMemory;
    jw.objectField("kind") catch return error.OutOfMemory;
    jw.write("storage#notifications") catch return error.OutOfMemory;
    // A list of none has no `items` at all, as measured.
    if (items.len > 0) {
        jw.objectField("items") catch return error.OutOfMemory;
        jw.beginArray() catch return error.OutOfMemory;
        for (items) |item| jw.write(Value{ .object = item }) catch return error.OutOfMemory;
        jw.endArray() catch return error.OutOfMemory;
    }
    jw.endObject() catch return error.OutOfMemory;
    return out.written();
}

fn render(arena: Allocator, object: ObjectMap) Allocator.Error![]const u8 {
    return std.json.Stringify.valueAlloc(arena, Value{ .object = object }, .{});
}

/// The bucket as a read answers it: under `projection=full`, with its
/// lists and owner, unless uniform access hides them. An empty default
/// object list is left out, as measured.
fn renderStored(arena: Allocator, stored: *const FakeBuckets.Stored, full: bool) Allocator.Error![]const u8 {
    if (!full or uniformAccess(stored.resource)) return render(arena, stored.resource);
    var shown = try cloneObject(arena, stored.resource);
    try shown.put(arena, "acl", try entriesValue(arena, stored.acl));
    if (stored.default_acl.len > 0) try shown.put(arena, "defaultObjectAcl", try entriesValue(arena, stored.default_acl));
    var owner: ObjectMap = .empty;
    try owner.put(arena, "entity", .{ .string = fake_acl.owners });
    try shown.put(arena, "owner", .{ .object = owner });
    return render(arena, shown);
}

fn entriesValue(arena: Allocator, list: []const fake_acl.Entry) Allocator.Error!Value {
    var items: std.json.Array = .init(arena);
    for (list) |e| {
        var entry: ObjectMap = .empty;
        try entry.put(arena, "entity", .{ .string = e.entity });
        try entry.put(arena, "role", .{ .string = e.role });
        try items.append(.{ .object = entry });
    }
    return .{ .array = items };
}

fn refusalReply(r: fake_acl.Refusal) FakeBuckets.Reply {
    return .{ .status = r.status, .body = r.body };
}

fn defaultSoftDelete(a: Allocator) Allocator.Error!Value {
    var policy: ObjectMap = .empty;
    try policy.put(a, "retentionDurationSeconds", .{ .string = "604800" });
    try policy.put(a, "effectiveTime", .{ .string = "2026-09-29T14:07:12.505Z" });
    return .{ .object = policy };
}

fn flagObject(a: Allocator, flag: []const u8, on: bool) Allocator.Error!Value {
    var object: ObjectMap = .empty;
    try object.put(a, flag, .{ .bool = on });
    return .{ .object = object };
}

fn cloneObject(a: Allocator, object: ObjectMap) Allocator.Error!ObjectMap {
    var out: ObjectMap = .empty;
    var it = object.iterator();
    while (it.next()) |entry| try out.put(a, try a.dupe(u8, entry.key_ptr.*), try cloneValue(a, entry.value_ptr.*));
    return out;
}

fn cloneValue(a: Allocator, value: Value) Allocator.Error!Value {
    return switch (value) {
        .null, .bool, .integer, .float => value,
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .array => |list| array: {
            var out: std.json.Array = .init(a);
            for (list.items) |item| try out.append(try cloneValue(a, item));
            break :array .{ .array = out };
        },
        .object => |object| .{ .object = try cloneObject(a, object) },
    };
}

fn objectOf(value: Value) ?ObjectMap {
    return switch (value) {
        .object => |o| o,
        else => null,
    };
}

fn arrayOf(value: Value) ?[]const Value {
    return switch (value) {
        .array => |list| list.items,
        else => null,
    };
}

fn stringOf(value: Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

/// A number, or a string of one, as Cloud Storage takes either.
fn integerOf(value: Value) ?i64 {
    return switch (value) {
        .integer => |n| n,
        .string, .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn isOneOf(text: []const u8, options: []const []const u8) bool {
    for (options) |option| if (std.mem.eql(u8, text, option)) return true;
    return false;
}

/// Cloud Storage's classes, whatever the case, as it writes them back.
fn storageClass(text: []const u8) ?[]const u8 {
    const classes = [_][]const u8{ "STANDARD", "NEARLINE", "COLDLINE", "ARCHIVE", "MULTI_REGIONAL", "REGIONAL", "DURABLE_REDUCED_AVAILABILITY" };
    for (classes) |class| if (std.ascii.eqlIgnoreCase(text, class)) return class;
    return null;
}

/// Google's label expressions for ASCII, `[a-z][a-z0-9_-]{0,62}` for a key
/// and `[a-z0-9_-]{0,63}` for a value, at most 128 bytes. Every code point
/// beyond ASCII passes as a lowercase letter.
fn labelTextOk(text: []const u8, is_key: bool) bool {
    if (text.len > 128) return false;
    const view = std.unicode.Utf8View.init(text) catch return false;
    var it = view.iterator();
    var n: usize = 0;
    while (it.nextCodepoint()) |cp| : (n += 1) {
        const ok = switch (cp) {
            'a'...'z' => true,
            '0'...'9', '_', '-' => !(is_key and n == 0),
            0x80...0x10ffff => true,
            else => false,
        };
        if (!ok) return false;
    }
    if (is_key and n == 0) return false;
    return n <= 63;
}

/// `YYYY-MM-DD` and a day that exists.
fn dateOk(text: []const u8) bool {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return false;
    const year = std.fmt.parseUnsigned(u16, text[0..4], 10) catch return false;
    const month = std.fmt.parseUnsigned(u8, text[5..7], 10) catch return false;
    const day = std.fmt.parseUnsigned(u8, text[8..10], 10) catch return false;
    for (text, 0..) |c, i| if (i != 4 and i != 7 and !std.ascii.isDigit(c)) return false;
    const leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
    const days = [_]u8{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return month >= 1 and month <= 12 and day >= 1 and day <= days[month - 1];
}

/// `projects/P/locations/L/keyRings/R/cryptoKeys/K`.
fn keyNameOk(name: []const u8) bool {
    var parts: [9][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |part| : (n += 1) {
        if (n == parts.len) return false;
        parts[n] = part;
    }
    if (n != 8) return false;
    for (parts[0..8]) |part| if (part.len == 0) return false;
    return std.mem.eql(u8, parts[0], "projects") and std.mem.eql(u8, parts[2], "locations") and
        std.mem.eql(u8, parts[4], "keyRings") and std.mem.eql(u8, parts[6], "cryptoKeys");
}

const testing = std.testing;

/// A request straight to the fake, as JSON, the way the P1 probes sent
/// them to Cloud Storage.
fn patchRaw(fake: *FakeBuckets, arena: Allocator, body: []const u8) !FakeBuckets.Reply {
    return fake.serve(.PATCH, .{ .name = "b" }, body, arena);
}

fn metagenerationOf(fake: *FakeBuckets) []const u8 {
    return fake.resource("b").?.get("metageneration").?.string;
}

test "the fake refuses what Cloud Storage refused on 2026-09-29, and leaves the bucket as it was" {
    var fake: FakeBuckets = .init(testing.allocator);
    defer fake.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqual(200, (try fake.serve(.POST, .{ .name = null, .project = "p" }, "{\"name\":\"b\"}", a)).status);

    var many_prefixes: std.ArrayList(u8) = .empty;
    try many_prefixes.appendSlice(a, "{\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"Delete\"},\"condition\":{\"matchesPrefix\":[");
    for (0..1001) |i| try many_prefixes.print(a, "{s}\"p{d}/\"", .{ if (i == 0) "" else ",", i });
    try many_prefixes.appendSlice(a, "]}}]}}");

    const refused = [_][]const u8{
        "{\"softDeletePolicy\":{\"retentionDurationSeconds\":\"604799\"}}",
        "{\"softDeletePolicy\":{\"retentionDurationSeconds\":\"7776001\"}}",
        "{\"labels\":{\"Env\":\"x\"}}",
        "{\"labels\":{\"k\":\"" ++ core.testing.repeat("v", 64) ++ "\"}}",
        "{\"labels\":{\"k\":\"" ++ core.testing.repeat("日", 43) ++ "\"}}",
        "{\"labels\":{\"1k\":\"v\"}}",
        "{\"labels\":{\"k\":1}}",
        // Removing a key that could never exist.
        "{\"labels\":{\"Bad\":null}}",
        "{\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"Delete\"}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"Delete\"},\"condition\":{}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"Delete\"},\"condition\":{\"matchesPrefix\":[]}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"AbortIncompleteMultipartUpload\"},\"condition\":{\"isLive\":true}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"SetStorageClass\"},\"condition\":{\"age\":1}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"SetStorageClass\",\"storageClass\":\"BOGUS\"},\"condition\":{\"age\":1}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"Delete\",\"storageClass\":\"NEARLINE\"},\"condition\":{\"age\":1}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"Frobnicate\"},\"condition\":{\"age\":1}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"delete\"},\"condition\":{\"age\":1}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"Delete\"},\"condition\":{\"createdBefore\":\"2026-02-29\"}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"Delete\"},\"condition\":{\"createdBefore\":\"2026-01-01T00:00:00Z\"}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"Delete\"},\"condition\":{\"age\":-1}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"Delete\"},\"condition\":{\"numNewerVersions\":2147483648}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"Delete\"},\"condition\":{\"sizeBelowBytes\":\"5497558138881\"}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"Delete\"},\"condition\":{\"matchesSuffix\":[\"\"]}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"Delete\"},\"condition\":{\"matchesPrefix\":[\"" ++ core.testing.repeat("p", 1025) ++ "\"]}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"Delete\"},\"condition\":{\"matchesStorageClass\":[\"BOGUS\"]}}]}}",
        "{\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"Delete\"},\"condition\":{\"matchesPattern\":\"tmp/.*\"}}]}}",
        many_prefixes.items,
        "{\"iamConfiguration\":{\"publicAccessPrevention\":\"bogus\"}}",
        "{\"storageClass\":\"BOGUS\"}",
        "{\"encryption\":{\"defaultKmsKeyName\":\"not-a-key\"}}",
        // Fields this library never sends, which the fake refuses so a
        // misspelled one fails its test.
        "{\"location\":\"EU\"}",
        "{\"versioning\":{\"enabled\":true,\"extra\":1}}",
    };
    for (refused) |body| {
        errdefer std.debug.print("body: {s}\n", .{body[0..@min(body.len, 200)]});
        const reply = try patchRaw(&fake, a, body);
        try testing.expectEqual(400, reply.status);
        try testing.expectEqualStrings("1", metagenerationOf(&fake));
    }

    // Labels are counted after the patch.
    var labels: std.ArrayList(u8) = .empty;
    try labels.appendSlice(a, "{\"labels\":{");
    for (0..64) |i| try labels.print(a, "{s}\"k{d}\":\"\"", .{ if (i == 0) "" else ",", i });
    try labels.appendSlice(a, "}}");
    try testing.expectEqual(200, (try patchRaw(&fake, a, labels.items)).status);
    const full = try patchRaw(&fake, a, "{\"labels\":{\"k64\":\"\"}}");
    try testing.expectEqual(400, full.status);
    try testing.expect(std.mem.indexOf(u8, full.body, "65 labels") != null);
    try testing.expectEqual(200, (try patchRaw(&fake, a, "{\"labels\":{\"k0\":null,\"k64\":\"\"}}")).status);
}

test "the fake keeps what Cloud Storage kept on 2026-09-29" {
    var fake: FakeBuckets = .init(testing.allocator);
    defer fake.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const created = try fake.serve(.POST, .{ .name = null, .project = "p" }, "{\"name\":\"b\",\"location\":\"us-central1\",\"storageClass\":\"standard\"}", a);
    try testing.expectEqual(200, created.status);
    try testing.expectEqualStrings("US-CENTRAL1", fake.resource("b").?.get("location").?.string);
    try testing.expectEqualStrings("STANDARD", fake.resource("b").?.get("storageClass").?.string);
    try testing.expectEqualStrings("region", fake.resource("b").?.get("locationType").?.string);
    // A name taken is 409, and the collection takes only a create.
    try testing.expectEqual(409, (try fake.serve(.POST, .{ .name = null, .project = "p" }, "{\"name\":\"b\"}", a)).status);
    try testing.expectError(error.HttpProtocolError, fake.serve(.GET, .{ .name = null, .project = "p" }, "", a));
    try testing.expectError(error.HttpProtocolError, fake.serve(.PUT, .{ .name = "b" }, "{}", a));

    // New buckets get 7 days of soft delete; 0 turns it off, and null puts
    // the default back.
    try testing.expectEqualStrings("604800", fake.resource("b").?.get("softDeletePolicy").?.object.get("retentionDurationSeconds").?.string);
    _ = try patchRaw(&fake, a, "{\"softDeletePolicy\":{\"retentionDurationSeconds\":\"0\"}}");
    try testing.expectEqual(null, fake.resource("b").?.get("softDeletePolicy").?.object.get("effectiveTime"));
    _ = try patchRaw(&fake, a, "{\"softDeletePolicy\":null}");
    try testing.expectEqualStrings("604800", fake.resource("b").?.get("softDeletePolicy").?.object.get("retentionDurationSeconds").?.string);

    // `{}` inside a setting changes nothing; `{}` as the patch leaves even
    // the metageneration.
    const before = metagenerationOf(&fake);
    try testing.expectEqual(200, (try patchRaw(&fake, a, "{}")).status);
    try testing.expectEqualStrings(before, metagenerationOf(&fake));
    _ = try patchRaw(&fake, a, "{\"softDeletePolicy\":{},\"lifecycle\":{}}");
    try testing.expectEqualStrings("604800", fake.resource("b").?.get("softDeletePolicy").?.object.get("retentionDurationSeconds").?.string);

    // Labels: `{}` removes them all, as null does.
    _ = try patchRaw(&fake, a, "{\"labels\":{\"a\":\"1\",\"b\":\"2\"}}");
    _ = try patchRaw(&fake, a, "{\"labels\":{}}");
    try testing.expectEqual(null, fake.resource("b").?.get("labels"));
    _ = try patchRaw(&fake, a, "{\"labels\":{\"a\":\"1\"}}");
    _ = try patchRaw(&fake, a, "{\"labels\":null}");
    try testing.expectEqual(null, fake.resource("b").?.get("labels"));

    // Flags and the key: null takes them away.
    _ = try patchRaw(&fake, a, "{\"versioning\":{\"enabled\":true},\"billing\":{\"requesterPays\":true}," ++
        "\"encryption\":{\"defaultKmsKeyName\":\"projects/p/locations/l/keyRings/r/cryptoKeys/k\"}}");
    try testing.expect(fake.resource("b").?.get("versioning").?.object.get("enabled").?.bool);
    _ = try patchRaw(&fake, a, "{\"versioning\":null,\"billing\":null,\"encryption\":null}");
    try testing.expectEqual(null, fake.resource("b").?.get("versioning"));
    try testing.expectEqual(null, fake.resource("b").?.get("billing"));
    try testing.expectEqual(null, fake.resource("b").?.get("encryption"));
    _ = try patchRaw(&fake, a, "{\"encryption\":{\"defaultKmsKeyName\":\"projects/p/locations/l/keyRings/r/cryptoKeys/k\"}}");
    _ = try patchRaw(&fake, a, "{\"encryption\":{\"defaultKmsKeyName\":null}}");
    try testing.expectEqual(null, fake.resource("b").?.get("encryption"));

    // Rules kept as the server writes them: days as numbers, sizes as
    // strings, classes uppercased, empty lists and null conditions dropped.
    _ = try patchRaw(&fake, a, "{\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"SetStorageClass\",\"storageClass\":\"nearline\"}," ++
        "\"condition\":{\"age\":\"30\",\"sizeAboveBytes\":1000,\"isLive\":null,\"matchesPrefix\":[],\"matchesStorageClass\":[\"standard\"]}}]}}");
    const rule = fake.resource("b").?.get("lifecycle").?.object.get("rule").?.array.items[0].object;
    try testing.expectEqualStrings("NEARLINE", rule.get("action").?.object.get("storageClass").?.string);
    const condition = rule.get("condition").?.object;
    try testing.expectEqual(30, condition.get("age").?.integer);
    try testing.expectEqualStrings("1000", condition.get("sizeAboveBytes").?.string);
    try testing.expectEqualStrings("STANDARD", condition.get("matchesStorageClass").?.array.items[0].string);
    try testing.expectEqual(null, condition.get("isLive"));
    try testing.expectEqual(null, condition.get("matchesPrefix"));
    _ = try patchRaw(&fake, a, "{\"lifecycle\":null}");
    try testing.expectEqual(null, fake.resource("b").?.get("lifecycle"));

    // Nested settings merge; the old name of "inherited" is taken.
    _ = try patchRaw(&fake, a, "{\"iamConfiguration\":{\"uniformBucketLevelAccess\":{\"enabled\":true}}}");
    _ = try patchRaw(&fake, a, "{\"iamConfiguration\":{\"publicAccessPrevention\":\"unspecified\"}}");
    const iam = fake.resource("b").?.get("iamConfiguration").?.object;
    try testing.expect(iam.get("uniformBucketLevelAccess").?.object.get("enabled").?.bool);
    try testing.expectEqualStrings("inherited", iam.get("publicAccessPrevention").?.string);
    _ = try patchRaw(&fake, a, "{\"storageClass\":\"nearline\"}");
    try testing.expectEqualStrings("NEARLINE", fake.resource("b").?.get("storageClass").?.string);

    // Conditions, then the bucket gone.
    const at = try std.fmt.parseInt(u64, metagenerationOf(&fake), 10);
    try testing.expectEqual(412, (try fake.serve(.PATCH, .{ .name = "b", .if_metageneration_match = at - 1 }, "{\"storageClass\":\"STANDARD\"}", a)).status);
    const not_modified = try fake.serve(.PATCH, .{ .name = "b", .if_metageneration_not_match = at }, "{\"storageClass\":\"STANDARD\"}", a);
    try testing.expectEqual(304, not_modified.status);
    try testing.expectEqualStrings("", not_modified.body);
    try testing.expectEqual(204, (try fake.serve(.DELETE, .{ .name = "b" }, "", a)).status);
    try testing.expectEqual(404, (try fake.serve(.DELETE, .{ .name = "b" }, "", a)).status);
    try testing.expectEqual(404, (try fake.serve(.GET, .{ .name = "b" }, "", a)).status);
    try testing.expectEqual(404, (try patchRaw(&fake, a, "{\"storageClass\":\"STANDARD\"}")).status);
    // The create, and the one refused with 409.
    try testing.expectEqual(2, fake.counts.creates);
}

test "the fake keeps a retention policy as Cloud Storage did on 2026-09-30" {
    var fake: FakeBuckets = .init(testing.allocator);
    defer fake.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const target: FakeBuckets.Target = .{ .name = "b" };
    try testing.expectEqual(200, (try fake.serve(.POST, .{ .name = null, .project = "p" }, "{\"name\":\"b\",\"retentionPolicy\":{\"retentionPeriod\":\"3600\"}}", a)).status);
    try testing.expectEqual(3600, fake.retentionPeriod("b").?);
    const effective = fake.resource("b").?.get("retentionPolicy").?.object.get("effectiveTime").?.string;
    // A number is taken; the effective time stays.
    try testing.expectEqual(200, (try fake.serve(.PATCH, target, "{\"retentionPolicy\":{\"retentionPeriod\":7200}}", a)).status);
    try testing.expectEqual(7200, fake.retentionPeriod("b").?);
    try testing.expectEqualStrings(effective, fake.resource("b").?.get("retentionPolicy").?.object.get("effectiveTime").?.string);
    // `{}`, `isLocked` and `effectiveTime` change nothing.
    for ([_][]const u8{
        "{\"retentionPolicy\":{}}",
        "{\"retentionPolicy\":{\"isLocked\":false,\"effectiveTime\":\"2020-01-01T00:00:00Z\"}}",
    }) |body| {
        try testing.expectEqual(200, (try fake.serve(.PATCH, target, body, a)).status);
        try testing.expectEqual(7200, fake.retentionPeriod("b").?);
    }
    // Out of range or not an integer: 400, and nothing changes.
    for ([_][]const u8{
        "{\"retentionPolicy\":{\"retentionPeriod\":\"0\"}}",
        "{\"retentionPolicy\":{\"retentionPeriod\":\"3155760001\"}}",
        "{\"retentionPolicy\":{\"retentionPeriod\":\"1.5\"}}",
    }) |body| {
        try testing.expectEqual(400, (try fake.serve(.PATCH, target, body, a)).status);
        try testing.expectEqual(7200, fake.retentionPeriod("b").?);
    }
    try testing.expectEqual(200, (try fake.serve(.PATCH, target, "{\"retentionPolicy\":{\"retentionPeriod\":\"3155760000\"}}", a)).status);
    // Null removes it.
    try testing.expectEqual(200, (try fake.serve(.PATCH, target, "{\"retentionPolicy\":null}", a)).status);
    try testing.expectEqual(null, fake.retentionPeriod("b"));
    try testing.expect(!fake.defaultEventBasedHold("b"));
    try testing.expectEqual(200, (try fake.serve(.PATCH, target, "{\"defaultEventBasedHold\":true}", a)).status);
    try testing.expect(fake.defaultEventBasedHold("b"));
}
