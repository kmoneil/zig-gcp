//! Bucket settings: what `Bucket.create` sends beside the name, the
//! location and the class, and what `Bucket.update` changes, through the
//! JSON API's `patch`.
//!
//! A patch merges, as an object's does: a field left out keeps its value,
//! a nested object merges field by field, a list replaces the whole list,
//! and null removes. Measured against Cloud Storage on 2026-09-29:
//!
//! - `{"labels":{"k":null}}` removes one label and `{"labels":null}` every
//!   label, and so does `{"labels":{}}`, so an empty change is never sent.
//! - `{"lifecycle":{"rule":[]}}` and `{"lifecycle":null}` both remove every
//!   rule.
//! - `{"softDeletePolicy":{"retentionDurationSeconds":"0"}}` turns soft
//!   delete off, where `{"softDeletePolicy":null}` puts the 7-day default
//!   back.
//! - `{"iamConfiguration":{"publicAccessPrevention":"enforced"}}` leaves
//!   uniform bucket-level access as it was, and the other way round.
//! - `{"retentionPolicy":null}` removes a retention policy, where
//!   `{"retentionPolicy":{}}` changes nothing (2026-09-30). A period of 0
//!   is refused, so a policy is set or removed, never emptied.
//!
//! The emulator neither checks nor keeps these settings, so what Cloud
//! Storage refuses is refused here first: code tested against the
//! emulator must not then fail in production.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Stringify = std.json.Stringify;
const core = @import("core");

const Client = @import("Client.zig");
const codec = @import("codec.zig");
const idempotency = @import("idempotency.zig");
const names = @import("names.zig");
const rpc = @import("rpc.zig");
const types = @import("types.zig");
const limits = @import("validate.zig");
const Error = @import("errors.zig").Error;

pub const CheckError = error{InvalidBucketSettings};

/// Patches the bucket with what `changes` names. The caller has begun the
/// call and checked the name.
pub fn update(client: *Client, bucket: []const u8, changes: types.BucketUpdate) Error!types.Owned(types.BucketInfo) {
    try checkUpdate(client.diagnostics, changes);
    var scratch: std.heap.ArenaAllocator = .init(client.gpa);
    defer scratch.deinit();
    const path = try names.bucketPatchPath(scratch.allocator(), bucket, .{
        .if_metageneration_match = changes.if_metageneration_match,
        .if_metageneration_not_match = changes.if_metageneration_not_match,
    });
    const body = try encodeUpdate(scratch.allocator(), changes);
    // A repeated bucket patch runs again, as measured: the token changes no
    // retry here.
    var token: idempotency.Token = undefined;
    token.init(client);

    var result: types.Owned(types.BucketInfo) = try .init(client.gpa);
    errdefer result.deinit();
    const response = try rpc.execute(client, result.arena, .{
        .method = .PATCH,
        .path = path,
        .body = body,
        .headers = token.slice(),
        // A patch that landed and lost its answer has moved the
        // metageneration, so its repeat under that condition fails rather
        // than overwrite what another writer changed in between.
        .retry = changes.if_metageneration_match != null or client.retry_unconditional_writes,
    });
    result.value = codec.decodeBucket(result.arena.allocator(), response) catch |err|
        return rpc.decodeFailed(client, err, "bucket");
    return result;
}

// Checks

/// Every setting of a new bucket, before anything is sent.
pub fn checkConfig(diag: ?*core.Diagnostics, config: types.BucketConfig) CheckError!void {
    if (config.soft_delete_retention_s) |seconds| try checkSoftDelete(diag, seconds);
    if (config.retention_period_s) |seconds| try checkRetentionPeriod(diag, seconds);
    if (config.default_kms_key_name) |key| try checkKmsKey(diag, key);
    try checkLabels(diag, config.labels);
    try checkLifecycle(diag, config.lifecycle);
    if (config.public_access_prevention) |value| try checkPublicAccessPrevention(diag, value);
}

/// An update: something to change, and every new value valid.
pub fn checkUpdate(diag: ?*core.Diagnostics, changes: types.BucketUpdate) CheckError!void {
    if (changes.soft_delete_retention_s) |seconds| try checkSoftDelete(diag, seconds);
    switch (changes.retention_period_s) {
        .set => |seconds| try checkRetentionPeriod(diag, seconds),
        .keep, .clear => {},
    }
    switch (changes.default_kms_key_name) {
        .set => |key| try checkKmsKey(diag, key),
        .keep, .clear => {},
    }
    switch (changes.labels) {
        .change => |list| try checkLabelChanges(diag, list),
        .keep, .clear => {},
    }
    if (changes.lifecycle) |rules| try checkLifecycle(diag, rules);
    if (changes.public_access_prevention) |value| try checkPublicAccessPrevention(diag, value);
    if (changes.storage_class) |class| if (class.len == 0) {
        return refuse(diag, "storage_class is empty; null leaves the class as it is", .{});
    };
    if (!changesSomething(changes)) return refuse(diag, "the update changes nothing", .{});
}

/// Whether the update sends anything at all.
fn changesSomething(changes: types.BucketUpdate) bool {
    const labels = switch (changes.labels) {
        .keep => false,
        .clear => true,
        .change => |list| list.len > 0,
    };
    return labels or changes.versioning != null or changes.soft_delete_retention_s != null or
        changes.requester_pays != null or changes.default_kms_key_name != .keep or
        changes.lifecycle != null or changes.uniform_bucket_level_access != null or
        changes.public_access_prevention != null or changes.storage_class != null or
        changes.retention_period_s != .keep or changes.default_event_based_hold != null;
}

fn checkLabels(diag: ?*core.Diagnostics, labels: []const types.Label) CheckError!void {
    if (labels.len > limits.max_labels) {
        return refuse(diag, "{d} labels; a bucket holds at most {d}", .{ labels.len, limits.max_labels });
    }
    for (labels, 0..) |label, i| {
        try checkLabelText(diag, "label", i, label.key, .key);
        try checkLabelText(diag, "label", i, label.value, .value);
        for (labels[0..i]) |earlier| if (std.mem.eql(u8, earlier.key, label.key)) {
            return refuse(diag, "label {d}: the key repeats an earlier label's", .{i});
        };
    }
}

/// The count a bucket holds is of the labels after the edit, which only
/// the server knows, so only an edit that sets more than that on its own
/// is refused here.
fn checkLabelChanges(diag: ?*core.Diagnostics, changes: []const types.LabelChange) CheckError!void {
    var sets: usize = 0;
    for (changes, 0..) |change, i| {
        // Cloud Storage refuses to remove a key it could never hold.
        try checkLabelText(diag, "label change", i, change.key, .key);
        if (change.value) |value| {
            try checkLabelText(diag, "label change", i, value, .value);
            sets += 1;
        }
        for (changes[0..i]) |earlier| if (std.mem.eql(u8, earlier.key, change.key)) {
            return refuse(diag, "label change {d}: the key appears twice; one edit gives a key one fate", .{i});
        };
    }
    if (sets > limits.max_labels) {
        return refuse(diag, "the edit sets {d} labels; a bucket holds at most {d}", .{ sets, limits.max_labels });
    }
}

const LabelPart = enum { key, value };

/// A label key or value as Cloud Storage takes it: lowercase letters,
/// digits, `_` and `-`, with a key starting with a letter. Letters beyond
/// ASCII count too, uppercase ones excepted, and which is which only the
/// server knows, so bytes beyond ASCII go to it to judge.
fn checkLabelText(
    diag: ?*core.Diagnostics,
    what: []const u8,
    index: usize,
    text: []const u8,
    part: LabelPart,
) CheckError!void {
    const name = @tagName(part);
    const chars = std.unicode.utf8CountCodepoints(text) catch {
        return refuse(diag, "{s} {d}: the {s} is not valid UTF-8", .{ what, index, name });
    };
    if (part == .key and chars == 0) return refuse(diag, "{s} {d}: the key is empty", .{ what, index });
    if (chars > limits.max_label_chars) {
        return refuse(diag, "{s} {d}: the {s} has {d} characters; the limit is {d}", .{ what, index, name, chars, limits.max_label_chars });
    }
    if (text.len > limits.max_label_bytes) {
        return refuse(diag, "{s} {d}: the {s} has {d} bytes; the limit is {d}", .{ what, index, name, text.len, limits.max_label_bytes });
    }
    for (text, 0..) |c, j| switch (c) {
        'a'...'z', 0x80...0xff => {},
        '0'...'9', '_', '-' => if (part == .key and j == 0) {
            return refuse(diag, "{s} {d}: a key starts with a lowercase letter", .{ what, index });
        },
        else => return refuse(
            diag,
            "{s} {d}: the {s} holds byte 0x{x:0>2}; labels take lowercase letters, digits, '_' and '-'",
            .{ what, index, name, c },
        ),
    };
}

fn checkSoftDelete(diag: ?*core.Diagnostics, seconds: u32) CheckError!void {
    if (seconds == 0) return;
    if (seconds >= limits.min_soft_delete_retention_s and seconds <= limits.max_soft_delete_retention_s) return;
    return refuse(diag, "a soft delete retention of {d} s is neither 0 nor {d} to {d} s (7 to 90 days)", .{
        seconds,
        limits.min_soft_delete_retention_s,
        limits.max_soft_delete_retention_s,
    });
}

fn checkRetentionPeriod(diag: ?*core.Diagnostics, seconds: u64) CheckError!void {
    if (seconds >= limits.min_retention_period_s and seconds <= limits.max_retention_period_s) return;
    return refuse(diag, "a retention period of {d} s is not {d} to {d} s (100 years)", .{
        seconds,
        limits.min_retention_period_s,
        limits.max_retention_period_s,
    });
}

fn checkKmsKey(diag: ?*core.Diagnostics, name: []const u8) CheckError!void {
    if (isKmsKeyName(name)) return;
    if (std.mem.indexOf(u8, name, "/cryptoKeyVersions/") != null) {
        return refuse(diag, "the default KMS key names one of a key's versions; name the key itself, projects/{{p}}/locations/{{l}}/keyRings/{{r}}/cryptoKeys/{{k}}", .{});
    }
    return refuse(diag, "the default KMS key is not projects/{{p}}/locations/{{l}}/keyRings/{{r}}/cryptoKeys/{{k}}", .{});
}

/// `projects/P/locations/L/keyRings/R/cryptoKeys/K` with no part empty: a
/// Cloud KMS key's name, which a bucket's default key must be.
pub fn isKmsKeyName(name: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(name)) return false;
    var parts = std.mem.splitScalar(u8, name, '/');
    for ([_]?[]const u8{ "projects", null, "locations", null, "keyRings", null, "cryptoKeys", null }) |want| {
        const part = parts.next() orelse return false;
        if (part.len == 0) return false;
        if (want) |literal| if (!std.mem.eql(u8, part, literal)) return false;
    }
    return parts.next() == null;
}

fn checkPublicAccessPrevention(diag: ?*core.Diagnostics, value: types.PublicAccessPrevention) CheckError!void {
    if (value != .unknown) return;
    return refuse(diag, "public access prevention .unknown stands for a value the server sent that this library does not know, and cannot be sent", .{});
}

fn checkLifecycle(diag: ?*core.Diagnostics, rules: []const types.LifecycleRule) CheckError!void {
    var affixes: usize = 0;
    for (rules, 0..) |rule, i| {
        try checkRule(diag, i, rule);
        affixes += rule.condition.matches_prefix.len + rule.condition.matches_suffix.len;
    }
    if (affixes > limits.max_lifecycle_affixes) {
        return refuse(diag, "the lifecycle rules name {d} prefixes and suffixes; the limit is {d}", .{ affixes, limits.max_lifecycle_affixes });
    }
}

fn checkRule(diag: ?*core.Diagnostics, i: usize, rule: types.LifecycleRule) CheckError!void {
    if (rule.unrecognized or rule.action == .unknown) {
        return refuse(diag, "lifecycle rule {d} was read with an action or a condition this library does not know; sent back without it, the rule would act on objects it leaves alone", .{i});
    }
    const c = rule.condition;
    switch (rule.action) {
        .set_storage_class => |class| if (class.len == 0) {
            return refuse(diag, "lifecycle rule {d} sets no storage class", .{i});
        },
        .abort_incomplete_multipart_upload => if (c.created_before != null or c.custom_time_before != null or
            c.days_since_custom_time != null or c.days_since_noncurrent_time != null or c.is_live != null or
            c.matches_storage_class.len > 0 or c.noncurrent_time_before != null or c.num_newer_versions != null or
            c.size_above_bytes != null or c.size_below_bytes != null)
        {
            return refuse(diag, "lifecycle rule {d}: abort_incomplete_multipart_upload takes only age_days, matches_prefix and matches_suffix", .{i});
        },
        .delete, .unknown => {},
    }
    if (!hasCondition(c)) return refuse(diag, "lifecycle rule {d} has no condition; Cloud Storage needs at least one", .{i});

    const counts = [_]struct { []const u8, ?u32 }{
        .{ "age_days", c.age_days },
        .{ "days_since_custom_time", c.days_since_custom_time },
        .{ "days_since_noncurrent_time", c.days_since_noncurrent_time },
        .{ "num_newer_versions", c.num_newer_versions },
    };
    for (counts) |field| if (field[1]) |n| if (n > limits.max_lifecycle_days) {
        return refuse(diag, "lifecycle rule {d}: {s} is {d}; the limit is {d}", .{ i, field[0], n, limits.max_lifecycle_days });
    };
    const sizes = [_]struct { []const u8, ?u64 }{
        .{ "size_above_bytes", c.size_above_bytes },
        .{ "size_below_bytes", c.size_below_bytes },
    };
    for (sizes) |field| if (field[1]) |n| if (n > limits.max_lifecycle_size_bytes) {
        return refuse(diag, "lifecycle rule {d}: {s} is {d}; the limit is 5 TiB, {d}", .{ i, field[0], n, limits.max_lifecycle_size_bytes });
    };
    const dates = [_]struct { []const u8, ?[]const u8 }{
        .{ "created_before", c.created_before },
        .{ "custom_time_before", c.custom_time_before },
        .{ "noncurrent_time_before", c.noncurrent_time_before },
    };
    for (dates) |field| if (field[1]) |text| if (!isDate(text)) {
        return refuse(diag, "lifecycle rule {d}: {s} is not a YYYY-MM-DD date that exists", .{ i, field[0] });
    };
    const affixes = [_]struct { []const u8, []const []const u8 }{
        .{ "matches_prefix", c.matches_prefix },
        .{ "matches_suffix", c.matches_suffix },
    };
    for (affixes) |field| for (field[1], 0..) |text, j| {
        if (text.len == 0 or text.len > limits.max_lifecycle_affix_bytes) {
            return refuse(diag, "lifecycle rule {d}: {s} {d} is empty or over {d} bytes", .{ i, field[0], j, limits.max_lifecycle_affix_bytes });
        }
    };
    for (c.matches_storage_class, 0..) |class, j| if (class.len == 0) {
        return refuse(diag, "lifecycle rule {d}: matches_storage_class {d} is empty", .{ i, j });
    };
}

/// Whether any condition is set. An empty list is not: Cloud Storage
/// drops it, and refuses a rule left with nothing.
fn hasCondition(c: types.LifecycleRule.Condition) bool {
    return c.age_days != null or c.created_before != null or c.custom_time_before != null or
        c.days_since_custom_time != null or c.days_since_noncurrent_time != null or c.is_live != null or
        c.matches_prefix.len > 0 or c.matches_suffix.len > 0 or c.matches_storage_class.len > 0 or
        c.noncurrent_time_before != null or c.num_newer_versions != null or
        c.size_above_bytes != null or c.size_below_bytes != null;
}

/// `YYYY-MM-DD`, naming a day that exists, as Cloud Storage reads a
/// lifecycle date. It also takes a month or day without its leading zero,
/// and writes it back with one; this library sends the form it reads.
pub fn isDate(text: []const u8) bool {
    if (text.len != 10) return false;
    for (text, 0..) |c, i| switch (i) {
        4, 7 => if (c != '-') return false,
        else => if (c < '0' or c > '9') return false,
    };
    const year: u16 = digitsValue(text[0..4]);
    const month: u16 = digitsValue(text[5..7]);
    const day: u16 = digitsValue(text[8..10]);
    if (month < 1 or month > 12 or day < 1) return false;
    return day <= std.time.epoch.getDaysInMonth(year, @enumFromInt(month));
}

fn digitsValue(digits: []const u8) u16 {
    var value: u16 = 0;
    for (digits) |d| value = value * 10 + (d - '0');
    return value;
}

fn refuse(diag: ?*core.Diagnostics, comptime format: []const u8, args: anytype) CheckError {
    if (diag) |d| d.print(format, args);
    return error.InvalidBucketSettings;
}

// Encoding

/// The `buckets.insert` body: the name, the location and the class, then
/// only the settings that differ from Cloud Storage's defaults.
pub fn encodeConfig(arena: Allocator, name: []const u8, config: types.BucketConfig) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeConfig(&jw, name, config) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeConfig(jw: *Stringify, name: []const u8, config: types.BucketConfig) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(name);
    try jw.objectField("location");
    try jw.write(config.location);
    try jw.objectField("storageClass");
    try jw.write(config.storage_class);
    if (config.versioning) try writeVersioning(jw, true);
    if (config.soft_delete_retention_s) |seconds| try writeSoftDelete(jw, seconds);
    if (config.requester_pays) try writeBilling(jw, true);
    if (config.default_kms_key_name) |key| try writeEncryption(jw, key);
    if (config.labels.len > 0) {
        try jw.objectField("labels");
        try jw.beginObject();
        for (config.labels) |label| {
            try jw.objectField(label.key);
            try jw.write(label.value);
        }
        try jw.endObject();
    }
    if (config.lifecycle.len > 0) try writeLifecycle(jw, config.lifecycle);
    try writeIamConfiguration(jw, config.uniform_bucket_level_access, config.public_access_prevention);
    if (config.retention_period_s) |seconds| try writeRetentionPolicy(jw, seconds);
    if (config.default_event_based_hold) try writeDefaultHold(jw, true);
    try jw.endObject();
}

/// The `buckets.patch` body: only what the update changes.
pub fn encodeUpdate(arena: Allocator, changes: types.BucketUpdate) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    var jw: Stringify = .{ .writer = &out.writer };
    writeUpdate(&jw, changes) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeUpdate(jw: *Stringify, changes: types.BucketUpdate) Stringify.Error!void {
    try jw.beginObject();
    if (changes.versioning) |on| try writeVersioning(jw, on);
    if (changes.soft_delete_retention_s) |seconds| try writeSoftDelete(jw, seconds);
    if (changes.requester_pays) |on| try writeBilling(jw, on);
    switch (changes.default_kms_key_name) {
        .keep => {},
        .set => |key| try writeEncryption(jw, key),
        .clear => try writeEncryption(jw, null),
    }
    switch (changes.labels) {
        .keep => {},
        .clear => {
            try jw.objectField("labels");
            try jw.write(null);
        },
        // Never `{}`, which would remove every label.
        .change => |list| if (list.len > 0) {
            try jw.objectField("labels");
            try jw.beginObject();
            for (list) |change| {
                try jw.objectField(change.key);
                // Null is how Cloud Storage is told to remove the label.
                if (change.value) |value| try jw.write(value) else try jw.write(null);
            }
            try jw.endObject();
        },
    }
    if (changes.lifecycle) |rules| try writeLifecycle(jw, rules);
    try writeIamConfiguration(jw, changes.uniform_bucket_level_access, changes.public_access_prevention);
    if (changes.storage_class) |class| {
        try jw.objectField("storageClass");
        try jw.write(class);
    }
    switch (changes.retention_period_s) {
        .keep => {},
        .set => |seconds| try writeRetentionPolicy(jw, seconds),
        .clear => try writeRetentionPolicy(jw, null),
    }
    if (changes.default_event_based_hold) |on| try writeDefaultHold(jw, on);
    try jw.endObject();
}

fn writeVersioning(jw: *Stringify, on: bool) Stringify.Error!void {
    try jw.objectField("versioning");
    try jw.beginObject();
    try jw.objectField("enabled");
    try jw.write(on);
    try jw.endObject();
}

fn writeSoftDelete(jw: *Stringify, seconds: u32) Stringify.Error!void {
    try jw.objectField("softDeletePolicy");
    try jw.beginObject();
    try jw.objectField("retentionDurationSeconds");
    try writeDecimalString(jw, seconds);
    try jw.endObject();
}

/// Null removes the policy.
fn writeRetentionPolicy(jw: *Stringify, seconds: ?u64) Stringify.Error!void {
    try jw.objectField("retentionPolicy");
    const period = seconds orelse return jw.write(null);
    try jw.beginObject();
    try jw.objectField("retentionPeriod");
    try writeDecimalString(jw, period);
    try jw.endObject();
}

fn writeDefaultHold(jw: *Stringify, on: bool) Stringify.Error!void {
    try jw.objectField("defaultEventBasedHold");
    try jw.write(on);
}

fn writeBilling(jw: *Stringify, requester_pays: bool) Stringify.Error!void {
    try jw.objectField("billing");
    try jw.beginObject();
    try jw.objectField("requesterPays");
    try jw.write(requester_pays);
    try jw.endObject();
}

/// Null clears the default key.
fn writeEncryption(jw: *Stringify, key: ?[]const u8) Stringify.Error!void {
    try jw.objectField("encryption");
    try jw.beginObject();
    try jw.objectField("defaultKmsKeyName");
    try jw.write(key);
    try jw.endObject();
}

fn writeIamConfiguration(
    jw: *Stringify,
    uniform: ?bool,
    prevention: ?types.PublicAccessPrevention,
) Stringify.Error!void {
    if (uniform == null and prevention == null) return;
    try jw.objectField("iamConfiguration");
    try jw.beginObject();
    if (uniform) |on| {
        try jw.objectField("uniformBucketLevelAccess");
        try jw.beginObject();
        try jw.objectField("enabled");
        try jw.write(on);
        try jw.endObject();
    }
    if (prevention) |value| {
        try jw.objectField("publicAccessPrevention");
        try jw.write(switch (value) {
            .inherited => "inherited",
            .enforced => "enforced",
            // The checks refuse it before anything is encoded.
            .unknown => unreachable,
        });
    }
    try jw.endObject();
}

fn writeLifecycle(jw: *Stringify, rules: []const types.LifecycleRule) Stringify.Error!void {
    try jw.objectField("lifecycle");
    try jw.beginObject();
    try jw.objectField("rule");
    try jw.beginArray();
    for (rules) |rule| try writeRule(jw, rule);
    try jw.endArray();
    try jw.endObject();
}

fn writeRule(jw: *Stringify, rule: types.LifecycleRule) Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("action");
    try jw.beginObject();
    try jw.objectField("type");
    switch (rule.action) {
        .delete => try jw.write("Delete"),
        .set_storage_class => |class| {
            try jw.write("SetStorageClass");
            try jw.objectField("storageClass");
            try jw.write(class);
        },
        .abort_incomplete_multipart_upload => try jw.write("AbortIncompleteMultipartUpload"),
        // The checks refuse it before anything is encoded.
        .unknown => unreachable,
    }
    try jw.endObject();
    try jw.objectField("condition");
    try writeCondition(jw, rule.condition);
    try jw.endObject();
}

/// Days and counts go as JSON numbers and sizes as decimal strings, as
/// the API's int32 and int64 fields do; an empty list goes not at all.
fn writeCondition(jw: *Stringify, c: types.LifecycleRule.Condition) Stringify.Error!void {
    try jw.beginObject();
    if (c.age_days) |n| {
        try jw.objectField("age");
        try jw.write(n);
    }
    if (c.created_before) |date| {
        try jw.objectField("createdBefore");
        try jw.write(date);
    }
    if (c.custom_time_before) |date| {
        try jw.objectField("customTimeBefore");
        try jw.write(date);
    }
    if (c.days_since_custom_time) |n| {
        try jw.objectField("daysSinceCustomTime");
        try jw.write(n);
    }
    if (c.days_since_noncurrent_time) |n| {
        try jw.objectField("daysSinceNoncurrentTime");
        try jw.write(n);
    }
    if (c.is_live) |live| {
        try jw.objectField("isLive");
        try jw.write(live);
    }
    try writeList(jw, "matchesPrefix", c.matches_prefix);
    try writeList(jw, "matchesSuffix", c.matches_suffix);
    try writeList(jw, "matchesStorageClass", c.matches_storage_class);
    if (c.noncurrent_time_before) |date| {
        try jw.objectField("noncurrentTimeBefore");
        try jw.write(date);
    }
    if (c.num_newer_versions) |n| {
        try jw.objectField("numNewerVersions");
        try jw.write(n);
    }
    if (c.size_above_bytes) |n| {
        try jw.objectField("sizeAboveBytes");
        try writeDecimalString(jw, n);
    }
    if (c.size_below_bytes) |n| {
        try jw.objectField("sizeBelowBytes");
        try writeDecimalString(jw, n);
    }
    try jw.endObject();
}

fn writeList(jw: *Stringify, field: []const u8, items: []const []const u8) Stringify.Error!void {
    if (items.len == 0) return;
    try jw.objectField(field);
    try jw.beginArray();
    for (items) |item| try jw.write(item);
    try jw.endArray();
}

/// An int64 field, which Google's JSON writes as a string.
fn writeDecimalString(jw: *Stringify, n: u64) Stringify.Error!void {
    var buffer: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{n}) catch unreachable;
    try jw.write(text);
}

const testing = std.testing;
const test_util = @import("test_util.zig");

const kms_key = "projects/p/locations/us/keyRings/r/cryptoKeys/k";

// Goldens: each body written out by hand from the rules in the module
// comment and the wire's own shapes.

/// What `create(.{})` has always sent, before any setting.
const create_start = "{\"name\":\"b\",\"location\":\"US\",\"storageClass\":\"STANDARD\"";

const ConfigGolden = struct {
    label: []const u8,
    config: types.BucketConfig,
    body: []const u8,
};

const config_goldens = [_]ConfigGolden{
    .{
        .label = "every default sends what create always sent, byte for byte",
        .config = .{},
        .body = create_start ++ "}",
    },
    .{
        .label = "versioning",
        .config = .{ .versioning = true },
        .body = create_start ++ ",\"versioning\":{\"enabled\":true}}",
    },
    .{
        .label = "soft delete off",
        .config = .{ .soft_delete_retention_s = 0 },
        .body = create_start ++ ",\"softDeletePolicy\":{\"retentionDurationSeconds\":\"0\"}}",
    },
    .{
        .label = "soft delete for 90 days, the int64 as a string",
        .config = .{ .soft_delete_retention_s = 7_776_000 },
        .body = create_start ++ ",\"softDeletePolicy\":{\"retentionDurationSeconds\":\"7776000\"}}",
    },
    .{
        .label = "requester pays",
        .config = .{ .requester_pays = true },
        .body = create_start ++ ",\"billing\":{\"requesterPays\":true}}",
    },
    .{
        .label = "a default key",
        .config = .{ .default_kms_key_name = kms_key },
        .body = create_start ++ ",\"encryption\":{\"defaultKmsKeyName\":\"" ++ kms_key ++ "\"}}",
    },
    .{
        .label = "labels, in the order given, an empty value included",
        .config = .{ .labels = &.{ .{ .key = "team", .value = "zig" }, .{ .key = "env", .value = "" } } },
        .body = create_start ++ ",\"labels\":{\"team\":\"zig\",\"env\":\"\"}}",
    },
    .{
        .label = "a lifecycle rule",
        .config = .{ .lifecycle = &.{.{ .action = .delete, .condition = .{ .age_days = 30 } }} },
        .body = create_start ++ ",\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"Delete\"},\"condition\":{\"age\":30}}]}}",
    },
    .{
        .label = "uniform access off, said out loud",
        .config = .{ .uniform_bucket_level_access = false },
        .body = create_start ++ ",\"iamConfiguration\":{\"uniformBucketLevelAccess\":{\"enabled\":false}}}",
    },
    .{
        .label = "public access prevention alone",
        .config = .{ .public_access_prevention = .enforced },
        .body = create_start ++ ",\"iamConfiguration\":{\"publicAccessPrevention\":\"enforced\"}}",
    },
    .{
        .label = "both IAM settings share one object",
        .config = .{ .uniform_bucket_level_access = true, .public_access_prevention = .inherited },
        .body = create_start ++ ",\"iamConfiguration\":{\"uniformBucketLevelAccess\":{\"enabled\":true}," ++
            "\"publicAccessPrevention\":\"inherited\"}}",
    },
    .{
        .label = "everything, in the order of the struct",
        .config = .{
            .location = "us-central1",
            .storage_class = "NEARLINE",
            .versioning = true,
            .soft_delete_retention_s = 604_800,
            .requester_pays = true,
            .default_kms_key_name = kms_key,
            .labels = &.{.{ .key = "env", .value = "test" }},
            .lifecycle = &.{.{ .action = .abort_incomplete_multipart_upload, .condition = .{ .age_days = 7 } }},
            .uniform_bucket_level_access = true,
            .public_access_prevention = .enforced,
            .retention_period_s = 86_400,
            .default_event_based_hold = true,
        },
        .body = "{\"name\":\"b\",\"location\":\"us-central1\",\"storageClass\":\"NEARLINE\"," ++
            "\"versioning\":{\"enabled\":true}," ++
            "\"softDeletePolicy\":{\"retentionDurationSeconds\":\"604800\"}," ++
            "\"billing\":{\"requesterPays\":true}," ++
            "\"encryption\":{\"defaultKmsKeyName\":\"" ++ kms_key ++ "\"}," ++
            "\"labels\":{\"env\":\"test\"}," ++
            "\"lifecycle\":{\"rule\":[{\"action\":{\"type\":\"AbortIncompleteMultipartUpload\"},\"condition\":{\"age\":7}}]}," ++
            "\"iamConfiguration\":{\"uniformBucketLevelAccess\":{\"enabled\":true},\"publicAccessPrevention\":\"enforced\"}," ++
            "\"retentionPolicy\":{\"retentionPeriod\":\"86400\"},\"defaultEventBasedHold\":true}",
    },
    .{
        .label = "a retention policy, the int64 as a string, at both ends of its range",
        .config = .{ .retention_period_s = 3_155_760_000 },
        .body = create_start ++ ",\"retentionPolicy\":{\"retentionPeriod\":\"3155760000\"}}",
    },
    .{
        .label = "a retention policy of one second",
        .config = .{ .retention_period_s = 1 },
        .body = create_start ++ ",\"retentionPolicy\":{\"retentionPeriod\":\"1\"}}",
    },
    .{
        .label = "the default event-based hold",
        .config = .{ .default_event_based_hold = true },
        .body = create_start ++ ",\"defaultEventBasedHold\":true}",
    },
};

test "golden: the create body, written from the rules by hand" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    for (config_goldens) |golden| {
        errdefer std.debug.print("golden: {s}\n", .{golden.label});
        try checkConfig(null, golden.config);
        try testing.expectEqualStrings(golden.body, try encodeConfig(arena_state.allocator(), "b", golden.config));
    }
}

/// Every action, and every condition, in one list: the rules the first
/// production run set.
const every_rule = [_]types.LifecycleRule{
    .{ .action = .delete, .condition = .{ .age_days = 30 } },
    .{
        .action = .{ .set_storage_class = "NEARLINE" },
        .condition = .{ .age_days = 60, .matches_storage_class = &.{"STANDARD"} },
    },
    .{
        .action = .abort_incomplete_multipart_upload,
        .condition = .{ .age_days = 7, .matches_prefix = &.{"uploads/"}, .matches_suffix = &.{".part"} },
    },
    .{ .action = .delete, .condition = .{
        .created_before = "2026-01-01",
        .custom_time_before = "2026-01-02",
        .days_since_custom_time = 10,
        .days_since_noncurrent_time = 5,
        .is_live = false,
        .matches_prefix = &.{ "logs/", "tmp/" },
        .matches_suffix = &.{".tmp"},
        .matches_storage_class = &.{ "STANDARD", "NEARLINE" },
        .noncurrent_time_before = "2026-01-03",
        .num_newer_versions = 3,
        .size_above_bytes = 1000,
        .size_below_bytes = 1_000_000_000_000,
    } },
};

/// Days and counts as numbers, sizes as strings, as Cloud Storage writes
/// them back.
const every_rule_body = "{\"lifecycle\":{\"rule\":[" ++
    "{\"action\":{\"type\":\"Delete\"},\"condition\":{\"age\":30}}," ++
    "{\"action\":{\"type\":\"SetStorageClass\",\"storageClass\":\"NEARLINE\"}," ++
    "\"condition\":{\"age\":60,\"matchesStorageClass\":[\"STANDARD\"]}}," ++
    "{\"action\":{\"type\":\"AbortIncompleteMultipartUpload\"}," ++
    "\"condition\":{\"age\":7,\"matchesPrefix\":[\"uploads/\"],\"matchesSuffix\":[\".part\"]}}," ++
    "{\"action\":{\"type\":\"Delete\"},\"condition\":{\"createdBefore\":\"2026-01-01\"," ++
    "\"customTimeBefore\":\"2026-01-02\",\"daysSinceCustomTime\":10,\"daysSinceNoncurrentTime\":5," ++
    "\"isLive\":false,\"matchesPrefix\":[\"logs/\",\"tmp/\"],\"matchesSuffix\":[\".tmp\"]," ++
    "\"matchesStorageClass\":[\"STANDARD\",\"NEARLINE\"],\"noncurrentTimeBefore\":\"2026-01-03\"," ++
    "\"numNewerVersions\":3,\"sizeAboveBytes\":\"1000\",\"sizeBelowBytes\":\"1000000000000\"}}" ++
    "]}}";

const UpdateGolden = struct {
    label: []const u8,
    update: types.BucketUpdate,
    body: []const u8,
};

const update_goldens = [_]UpdateGolden{
    .{
        .label = "versioning off",
        .update = .{ .versioning = false },
        .body = "{\"versioning\":{\"enabled\":false}}",
    },
    .{
        .label = "soft delete off is \"0\", never null, which puts the 7-day default back",
        .update = .{ .soft_delete_retention_s = 0 },
        .body = "{\"softDeletePolicy\":{\"retentionDurationSeconds\":\"0\"}}",
    },
    .{
        .label = "requester pays off",
        .update = .{ .requester_pays = false },
        .body = "{\"billing\":{\"requesterPays\":false}}",
    },
    .{
        .label = "a default key set",
        .update = .{ .default_kms_key_name = .{ .set = kms_key } },
        .body = "{\"encryption\":{\"defaultKmsKeyName\":\"" ++ kms_key ++ "\"}}",
    },
    .{
        .label = "the default key cleared",
        .update = .{ .default_kms_key_name = .clear },
        .body = "{\"encryption\":{\"defaultKmsKeyName\":null}}",
    },
    .{
        .label = "labels set and removed, and the rest left alone",
        .update = .{ .labels = .{ .change = &.{
            .{ .key = "env", .value = "prod" },
            .{ .key = "draft", .value = null },
        } } },
        .body = "{\"labels\":{\"env\":\"prod\",\"draft\":null}}",
    },
    .{
        .label = "every label removed",
        .update = .{ .labels = .clear },
        .body = "{\"labels\":null}",
    },
    .{
        .label = "an empty label change sends no labels, since {} would remove them all",
        .update = .{ .versioning = true, .labels = .{ .change = &.{} } },
        .body = "{\"versioning\":{\"enabled\":true}}",
    },
    .{
        .label = "every rule removed",
        .update = .{ .lifecycle = &.{} },
        .body = "{\"lifecycle\":{\"rule\":[]}}",
    },
    .{
        .label = "every action and every condition, in the wire's own shapes",
        .update = .{ .lifecycle = &every_rule },
        .body = every_rule_body,
    },
    .{
        .label = "uniform access alone",
        .update = .{ .uniform_bucket_level_access = true },
        .body = "{\"iamConfiguration\":{\"uniformBucketLevelAccess\":{\"enabled\":true}}}",
    },
    .{
        .label = "public access prevention alone, which leaves uniform access as it is",
        .update = .{ .public_access_prevention = .inherited },
        .body = "{\"iamConfiguration\":{\"publicAccessPrevention\":\"inherited\"}}",
    },
    .{
        .label = "the default storage class",
        .update = .{ .storage_class = "COLDLINE" },
        .body = "{\"storageClass\":\"COLDLINE\"}",
    },
    .{
        .label = "conditions go in the query, never the body",
        .update = .{ .versioning = true, .if_metageneration_match = 3, .if_metageneration_not_match = 2 },
        .body = "{\"versioning\":{\"enabled\":true}}",
    },
    .{
        .label = "everything, in the order of the struct",
        .update = .{
            .versioning = true,
            .soft_delete_retention_s = 691_200,
            .requester_pays = true,
            .default_kms_key_name = .clear,
            .labels = .{ .change = &.{.{ .key = "env", .value = "test" }} },
            .lifecycle = &.{},
            .uniform_bucket_level_access = false,
            .public_access_prevention = .enforced,
            .storage_class = "STANDARD",
            .retention_period_s = .{ .set = 3600 },
            .default_event_based_hold = false,
        },
        .body = "{\"versioning\":{\"enabled\":true}," ++
            "\"softDeletePolicy\":{\"retentionDurationSeconds\":\"691200\"}," ++
            "\"billing\":{\"requesterPays\":true}," ++
            "\"encryption\":{\"defaultKmsKeyName\":null}," ++
            "\"labels\":{\"env\":\"test\"}," ++
            "\"lifecycle\":{\"rule\":[]}," ++
            "\"iamConfiguration\":{\"uniformBucketLevelAccess\":{\"enabled\":false},\"publicAccessPrevention\":\"enforced\"}," ++
            "\"storageClass\":\"STANDARD\"," ++
            "\"retentionPolicy\":{\"retentionPeriod\":\"3600\"},\"defaultEventBasedHold\":false}",
    },
    .{
        .label = "a retention policy's period changed",
        .update = .{ .retention_period_s = .{ .set = 7200 } },
        .body = "{\"retentionPolicy\":{\"retentionPeriod\":\"7200\"}}",
    },
    .{
        .label = "a retention policy removed: null, never {}, which changes nothing",
        .update = .{ .retention_period_s = .clear },
        .body = "{\"retentionPolicy\":null}",
    },
    .{
        .label = "the default event-based hold on",
        .update = .{ .default_event_based_hold = true },
        .body = "{\"defaultEventBasedHold\":true}",
    },
};

test "golden: the patch body, written from the rules by hand" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    for (update_goldens) |golden| {
        errdefer std.debug.print("golden: {s}\n", .{golden.label});
        try checkUpdate(null, golden.update);
        try testing.expectEqualStrings(golden.body, try encodeUpdate(arena_state.allocator(), golden.update));
    }
}

test "golden: the rules sent come back from the decoder as they were" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const info = try codec.decodeBucket(arena_state.allocator(), every_rule_body);
    try expectRulesEqual(&every_rule, info.lifecycle);
}

/// A bucket as a patch answers with it: the settings the tests set.
const patched_bucket =
    \\{"kind":"storage#bucket","name":"zigps-b","metageneration":"2","generation":"1790690832240124605",
    \\ "location":"US","storageClass":"STANDARD","versioning":{"enabled":true},
    \\ "labels":{"env":"prod","team":"zig"},
    \\ "softDeletePolicy":{"retentionDurationSeconds":"0"},
    \\ "lifecycle":{"rule":[{"action":{"type":"Delete"},"condition":{"age":30,"matchesPrefix":["tmp/"]}}]},
    \\ "iamConfiguration":{"uniformBucketLevelAccess":{"enabled":true},"publicAccessPrevention":"enforced"}}
;

/// Cloud Storage's answer to a stale `ifMetagenerationMatch` on a bucket
/// patch, captured on 2026-09-29.
const stale_metageneration =
    \\{
    \\  "error": {
    \\    "code": 412,
    \\    "message": "At least one of the pre-conditions you specified did not hold.",
    \\    "errors": [
    \\      {
    \\        "message": "At least one of the pre-conditions you specified did not hold.",
    \\        "domain": "global",
    \\        "reason": "conditionNotMet"
    \\      }
    \\    ]
    \\  }
    \\}
;

test "update: the request, and the bucket it answers with" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = patched_bucket } }}, .{});
    defer h.deinit();
    var info = try h.client.bucket("zigps-b").update(.{
        .versioning = true,
        .labels = .{ .change = &.{.{ .key = "env", .value = "prod" }} },
    });
    defer info.deinit();
    try h.expectRequest(
        0,
        .PATCH,
        "https://storage.googleapis.com/storage/v1/b/zigps-b?projection=noAcl",
        "{\"versioning\":{\"enabled\":true},\"labels\":{\"env\":\"prod\"}}",
    );
    try testing.expectEqual(2, info.value.metageneration);
    try testing.expect(info.value.versioning);
    try testing.expectEqualStrings("prod", info.value.label("env").?);
    try testing.expectEqualStrings("zig", info.value.label("team").?);
    try testing.expectEqual(null, info.value.soft_delete);
    try testing.expectEqualStrings("tmp/", info.value.lifecycle[0].condition.matches_prefix[0]);
    try testing.expect(info.value.uniform_bucket_level_access);
    try testing.expectEqual(.enforced, info.value.public_access_prevention);
}

test "update: a stale condition is FailedPrecondition, and a current not-match NotModified" {
    var h: test_util.Harness = undefined;
    try h.init(&.{
        .{ .respond = .{ .status = 412, .body = stale_metageneration } },
        .{ .respond = .{ .status = 304, .body = "" } },
    }, .{});
    defer h.deinit();
    const b = h.client.bucket("zigps-b");
    try testing.expectError(error.FailedPrecondition, b.update(.{ .versioning = true, .if_metageneration_match = 1 }));
    try h.expectRequest(
        0,
        .PATCH,
        "https://storage.googleapis.com/storage/v1/b/zigps-b?projection=noAcl&ifMetagenerationMatch=1",
        "{\"versioning\":{\"enabled\":true}}",
    );
    try testing.expectEqualStrings("conditionNotMet", h.diag.status());
    // Measured: Cloud Storage answers such a patch 304, and changes nothing.
    try testing.expectError(error.NotModified, b.update(.{ .versioning = true, .if_metageneration_not_match = 2 }));
    try h.expectRequest(
        1,
        .PATCH,
        "https://storage.googleapis.com/storage/v1/b/zigps-b?projection=noAcl&ifMetagenerationNotMatch=2",
        "{\"versioning\":{\"enabled\":true}}",
    );
    // Neither is retried.
    try h.expectRequestCount(2);
}

test "update: retried only under if_metageneration_match, or when asked" {
    // Unconditional: one 503 ends the call, since a repeat of a patch that
    // landed would undo whatever changed in between.
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .status = 503, .body = "{}" } }}, .{});
    defer h.deinit();
    try testing.expectError(error.Unavailable, h.client.bucket("b").update(.{ .versioning = true }));
    try h.expectRequestCount(1);

    // A not-match condition does not make a repeat safe either.
    var not_match: test_util.Harness = undefined;
    try not_match.init(&.{.{ .respond = .{ .status = 503, .body = "{}" } }}, .{});
    defer not_match.deinit();
    try testing.expectError(error.Unavailable, not_match.client.bucket("b").update(.{
        .versioning = true,
        .if_metageneration_not_match = 1,
    }));
    try not_match.expectRequestCount(1);

    // Under if_metageneration_match, a repeat cannot apply twice.
    var conditional: test_util.Harness = undefined;
    try conditional.init(&.{
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .body = patched_bucket } },
    }, .{});
    defer conditional.deinit();
    var info = try conditional.client.bucket("b").update(.{ .versioning = true, .if_metageneration_match = 1 });
    info.deinit();
    try conditional.expectRequestCount(2);

    var opted_in: test_util.Harness = undefined;
    try opted_in.init(&.{
        .{ .respond = .{ .status = 503, .body = "{}" } },
        .{ .respond = .{ .body = patched_bucket } },
    }, .{ .retry_unconditional_writes = true });
    defer opted_in.deinit();
    var again = try opted_in.client.bucket("b").update(.{ .versioning = true });
    again.deinit();
    try opted_in.expectRequestCount(2);
}

test "create: the settings reach the body, and the bucket comes back with them" {
    var h: test_util.Harness = undefined;
    try h.init(&.{.{ .respond = .{ .body = patched_bucket } }}, .{});
    defer h.deinit();
    var info = try h.client.bucket("zigps-b").create(.{
        .versioning = true,
        .soft_delete_retention_s = 0,
        .labels = &.{.{ .key = "env", .value = "prod" }},
    });
    defer info.deinit();
    try h.expectRequest(
        0,
        .POST,
        "https://storage.googleapis.com/storage/v1/b?project=extractctl",
        "{\"name\":\"zigps-b\",\"location\":\"US\",\"storageClass\":\"STANDARD\"," ++
            "\"versioning\":{\"enabled\":true},\"softDeletePolicy\":{\"retentionDurationSeconds\":\"0\"}," ++
            "\"labels\":{\"env\":\"prod\"}}",
    );
    try testing.expect(info.value.versioning);
    try testing.expectEqual(1790690832240124605, info.value.generation.?);
}

test "settings Cloud Storage would refuse are refused before sending" {
    var h: test_util.Harness = undefined;
    try h.init(&.{}, .{});
    defer h.deinit();
    const b = h.client.bucket("zigps-b");
    try testing.expectError(error.InvalidBucketSettings, b.create(.{ .labels = &.{.{ .key = "Env", .value = "x" }} }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "byte 0x45") != null);
    try testing.expectError(error.InvalidBucketSettings, b.create(.{ .soft_delete_retention_s = 60 }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "7 to 90 days") != null);
    try testing.expectError(error.InvalidBucketSettings, b.update(.{}));
    try testing.expectEqualStrings("the update changes nothing", h.diag.message());
    try testing.expectError(error.InvalidBucketSettings, b.update(.{ .lifecycle = &.{.{ .action = .delete, .condition = .{} }} }));
    try testing.expect(std.mem.indexOf(u8, h.diag.message(), "no condition") != null);
    // A bad name is still what is reported first.
    try testing.expectError(error.InvalidBucketName, h.client.bucket("a b").update(.{}));
    try h.expectRequestCount(0);
}

// Checks, each at its boundaries, each with a case only it refuses.

fn expectRefused(result: CheckError!void, d: *const core.Diagnostics, fragment: []const u8) !void {
    try testing.expectError(error.InvalidBucketSettings, result);
    if (std.mem.indexOf(u8, d.message(), fragment) == null) {
        std.debug.print("message \"{s}\" lacks \"{s}\"\n", .{ d.message(), fragment });
        return error.TestUnexpectedMessage;
    }
}

test "labels: the rules at their boundaries, as Cloud Storage enforced them" {
    var d: core.Diagnostics = .{};
    const ok = [_][]const types.Label{
        &.{},
        &.{.{ .key = "a", .value = "" }},
        &.{.{ .key = "team", .value = "zig-gcp_1" }},
        &.{.{ .key = "k", .value = "-x" }},
        &.{.{ .key = "k" ++ "x" ** 62, .value = "v" ** 63 }},
        // Letters beyond ASCII go to the server to judge.
        &.{.{ .key = "clé", .value = "été" }},
        &.{.{ .key = "日k", .value = "語" }},
        // 63 characters of two bytes, 126 bytes: both limits hold.
        &.{.{ .key = "k", .value = "é" ** 63 }},
        &.{.{ .key = "k", .value = "日" ** 42 }},
    };
    for (ok) |labels| try checkConfig(&d, .{ .labels = labels });
    const refused = [_]struct { []const types.Label, []const u8 }{
        .{ &.{.{ .key = "", .value = "v" }}, "the key is empty" },
        .{ &.{.{ .key = "Team", .value = "v" }}, "byte 0x54" },
        .{ &.{.{ .key = "team", .value = "Prod" }}, "byte 0x50" },
        .{ &.{.{ .key = "1team", .value = "v" }}, "starts with a lowercase letter" },
        .{ &.{.{ .key = "_team", .value = "v" }}, "starts with a lowercase letter" },
        .{ &.{.{ .key = "-team", .value = "v" }}, "starts with a lowercase letter" },
        .{ &.{.{ .key = "a.b", .value = "v" }}, "byte 0x2e" },
        .{ &.{.{ .key = "k", .value = "a b" }}, "byte 0x20" },
        .{ &.{.{ .key = "k" ++ "x" ** 63, .value = "v" }}, "64 characters" },
        .{ &.{.{ .key = "k", .value = "v" ** 64 }}, "64 characters" },
        // 43 characters of three bytes: within 63 characters, over 128 bytes.
        .{ &.{.{ .key = "k", .value = "日" ** 43 }}, "129 bytes" },
        .{ &.{.{ .key = "日" ** 43, .value = "v" }}, "129 bytes" },
        .{ &.{.{ .key = "k", .value = "\xc0" }}, "not valid UTF-8" },
        .{ &.{ .{ .key = "k", .value = "1" }, .{ .key = "k", .value = "2" } }, "repeats" },
    };
    for (refused) |case| {
        errdefer std.debug.print("labels: {any}\n", .{case[0]});
        try expectRefused(checkConfig(&d, .{ .labels = case[0] }), &d, case[1]);
    }
    var many: [limits.max_labels + 1]types.Label = undefined;
    var keys: [limits.max_labels + 1][4]u8 = undefined;
    for (&many, &keys, 0..) |*l, *k, i| l.* = .{ .key = std.fmt.bufPrint(k, "k{d}", .{i}) catch unreachable, .value = "" };
    try checkConfig(&d, .{ .labels = many[0..limits.max_labels] });
    try expectRefused(checkConfig(&d, .{ .labels = &many }), &d, "65 labels");
}

test "label changes: removals, repeats, and how many one edit may set" {
    var d: core.Diagnostics = .{};
    try checkUpdate(&d, .{ .labels = .{ .change = &.{.{ .key = "gone", .value = null }} } });
    // An empty value sets the label to nothing; it does not remove it.
    try checkUpdate(&d, .{ .labels = .{ .change = &.{.{ .key = "k", .value = "" }} } });
    // Cloud Storage refuses to remove a key it could never hold.
    try expectRefused(checkUpdate(&d, .{ .labels = .{ .change = &.{.{ .key = "Bad", .value = null }} } }), &d, "label change 0: the key holds byte 0x42");
    try expectRefused(checkUpdate(&d, .{ .labels = .{ .change = &.{.{ .key = "", .value = null }} } }), &d, "the key is empty");
    try expectRefused(checkUpdate(&d, .{ .labels = .{ .change = &.{.{ .key = "k", .value = "V" }} } }), &d, "the value holds byte 0x56");
    try expectRefused(checkUpdate(&d, .{ .labels = .{ .change = &.{
        .{ .key = "k", .value = "1" },
        .{ .key = "k", .value = null },
    } } }), &d, "appears twice");

    // 64 set, however many removed: the server counts what is left.
    var changes: [limits.max_labels + 11]types.LabelChange = undefined;
    var keys: [limits.max_labels + 11][4]u8 = undefined;
    for (&changes, &keys, 0..) |*c, *k, i| c.* = .{
        .key = std.fmt.bufPrint(k, "k{d}", .{i}) catch unreachable,
        .value = if (i < limits.max_labels) "v" else null,
    };
    try checkUpdate(&d, .{ .labels = .{ .change = &changes } });
    changes[limits.max_labels].value = "v";
    try expectRefused(checkUpdate(&d, .{ .labels = .{ .change = &changes } }), &d, "sets 65 labels");
}

test "soft delete: 0, or 7 to 90 days, both ends included" {
    var d: core.Diagnostics = .{};
    for ([_]u32{ 0, 604_800, 691_200, 7_775_999, 7_776_000 }) |s| {
        try checkConfig(&d, .{ .soft_delete_retention_s = s });
        try checkUpdate(&d, .{ .soft_delete_retention_s = s });
    }
    for ([_]u32{ 1, 604_799, 7_776_001, 31_536_000, std.math.maxInt(u32) }) |s| {
        errdefer std.debug.print("retention: {d}\n", .{s});
        try expectRefused(checkConfig(&d, .{ .soft_delete_retention_s = s }), &d, "7 to 90 days");
        try expectRefused(checkUpdate(&d, .{ .soft_delete_retention_s = s }), &d, "7 to 90 days");
    }
}

test "retention period: 1 to 3,155,760,000 seconds, both ends included, as measured" {
    var d: core.Diagnostics = .{};
    for ([_]u64{ 1, 60, 86_400, 3_155_759_999, 3_155_760_000 }) |s| {
        try checkConfig(&d, .{ .retention_period_s = s });
        try checkUpdate(&d, .{ .retention_period_s = .{ .set = s } });
    }
    for ([_]u64{ 0, 3_155_760_001, std.math.maxInt(u64) }) |s| {
        errdefer std.debug.print("period: {d}\n", .{s});
        try expectRefused(checkConfig(&d, .{ .retention_period_s = s }), &d, "(100 years)");
        try expectRefused(checkUpdate(&d, .{ .retention_period_s = .{ .set = s } }), &d, "(100 years)");
    }
    // Removal and the default hold change something, and need no period.
    try checkUpdate(&d, .{ .retention_period_s = .clear });
    try checkUpdate(&d, .{ .default_event_based_hold = false });
}

test "the default key: a key's name, never a version's, with no part empty" {
    var d: core.Diagnostics = .{};
    try checkConfig(&d, .{ .default_kms_key_name = kms_key });
    try checkUpdate(&d, .{ .default_kms_key_name = .{ .set = kms_key } });
    // Clearing needs no name at all.
    try checkUpdate(&d, .{ .default_kms_key_name = .clear });
    try expectRefused(checkUpdate(&d, .{ .default_kms_key_name = .{ .set = kms_key ++ "/cryptoKeyVersions/1" } }), &d, "one of a key's versions");
    for ([_][]const u8{
        "",
        "not-a-key",
        "projects/p/locations/us/keyRings/r/cryptoKeys/",
        "projects//locations/us/keyRings/r/cryptoKeys/k",
        "project/p/locations/us/keyRings/r/cryptoKeys/k",
        "projects/p/locations/us/keyRings/r/keys/k",
        "projects/p/locations/us/keyRings/r",
        "/projects/p/locations/us/keyRings/r/cryptoKeys/k",
        "projects/p/locations/us/keyRings/r/cryptoKeys/k/",
        "projects/p/locations/us/keyRings/r/cryptoKeys/\xff",
    }) |name| {
        errdefer std.debug.print("name: {s}\n", .{name});
        try expectRefused(checkConfig(&d, .{ .default_kms_key_name = name }), &d, "is not projects/");
    }
}

test "public access prevention: .unknown is read, never sent" {
    var d: core.Diagnostics = .{};
    try checkConfig(&d, .{ .public_access_prevention = .enforced });
    try checkUpdate(&d, .{ .public_access_prevention = .inherited });
    try expectRefused(checkConfig(&d, .{ .public_access_prevention = .unknown }), &d, "cannot be sent");
    try expectRefused(checkUpdate(&d, .{ .public_access_prevention = .unknown }), &d, "cannot be sent");
}

test "an update must change something, and name a class if it names one" {
    var d: core.Diagnostics = .{};
    try expectRefused(checkUpdate(&d, .{}), &d, "changes nothing");
    // An empty label change sends nothing, so it changes nothing.
    try expectRefused(checkUpdate(&d, .{ .labels = .{ .change = &.{} } }), &d, "changes nothing");
    // Conditions alone change nothing.
    try expectRefused(checkUpdate(&d, .{ .if_metageneration_match = 3 }), &d, "changes nothing");
    try expectRefused(checkUpdate(&d, .{ .storage_class = "" }), &d, "storage_class is empty");
    // Each setting alone is enough.
    const each = [_]types.BucketUpdate{
        .{ .versioning = false },
        .{ .soft_delete_retention_s = 0 },
        .{ .requester_pays = false },
        .{ .default_kms_key_name = .clear },
        .{ .labels = .clear },
        .{ .labels = .{ .change = &.{.{ .key = "k", .value = null }} } },
        .{ .lifecycle = &.{} },
        .{ .uniform_bucket_level_access = false },
        .{ .public_access_prevention = .inherited },
        .{ .storage_class = "STANDARD" },
    };
    for (each) |changes| try checkUpdate(&d, changes);
}

fn oneRule(action: types.LifecycleRule.Action, condition: types.LifecycleRule.Condition) [1]types.LifecycleRule {
    return .{.{ .action = action, .condition = condition }};
}

test "lifecycle: a rule needs a condition, and abort takes three kinds" {
    var d: core.Diagnostics = .{};
    try expectRefused(checkUpdate(&d, .{ .lifecycle = &oneRule(.delete, .{}) }), &d, "no condition");
    // Empty lists are no condition either: the server drops them.
    try expectRefused(checkUpdate(&d, .{ .lifecycle = &oneRule(.delete, .{ .matches_prefix = &.{} }) }), &d, "no condition");
    // A lone is_live is a condition, even false.
    try checkUpdate(&d, .{ .lifecycle = &oneRule(.delete, .{ .is_live = false }) });

    const abort: types.LifecycleRule.Action = .abort_incomplete_multipart_upload;
    try checkUpdate(&d, .{ .lifecycle = &oneRule(abort, .{ .age_days = 1 }) });
    try checkUpdate(&d, .{ .lifecycle = &oneRule(abort, .{ .matches_prefix = &.{"a/"} }) });
    try checkUpdate(&d, .{ .lifecycle = &oneRule(abort, .{ .matches_suffix = &.{".x"} }) });
    const others = [_]types.LifecycleRule.Condition{
        .{ .age_days = 1, .created_before = "2026-01-01" },
        .{ .age_days = 1, .custom_time_before = "2026-01-01" },
        .{ .age_days = 1, .days_since_custom_time = 1 },
        .{ .age_days = 1, .days_since_noncurrent_time = 1 },
        .{ .age_days = 1, .is_live = true },
        .{ .age_days = 1, .matches_storage_class = &.{"STANDARD"} },
        .{ .age_days = 1, .noncurrent_time_before = "2026-01-01" },
        .{ .age_days = 1, .num_newer_versions = 1 },
        .{ .age_days = 1, .size_above_bytes = 1 },
        .{ .age_days = 1, .size_below_bytes = 1 },
    };
    for (others) |condition| {
        try expectRefused(checkUpdate(&d, .{ .lifecycle = &oneRule(abort, condition) }), &d, "takes only age_days");
        // The same condition is fine under another action.
        try checkUpdate(&d, .{ .lifecycle = &oneRule(.delete, condition) });
    }
    try expectRefused(checkUpdate(&d, .{ .lifecycle = &oneRule(.{ .set_storage_class = "" }, .{ .age_days = 1 }) }), &d, "sets no storage class");
    try checkUpdate(&d, .{ .lifecycle = &oneRule(.{ .set_storage_class = "nearline" }, .{ .age_days = 1 }) });
}

test "lifecycle: numbers, sizes, dates, prefixes and classes at their limits" {
    var d: core.Diagnostics = .{};
    const top = limits.max_lifecycle_days;
    const days = [_][2]types.LifecycleRule.Condition{
        .{ .{ .age_days = top }, .{ .age_days = top + 1 } },
        .{ .{ .days_since_custom_time = top }, .{ .days_since_custom_time = top + 1 } },
        .{ .{ .days_since_noncurrent_time = top }, .{ .days_since_noncurrent_time = top + 1 } },
        .{ .{ .num_newer_versions = top }, .{ .num_newer_versions = top + 1 } },
        .{ .{ .age_days = 0 }, .{ .age_days = std.math.maxInt(u32) } },
    };
    for (days) |pair| {
        try checkUpdate(&d, .{ .lifecycle = &oneRule(.delete, pair[0]) });
        try expectRefused(checkUpdate(&d, .{ .lifecycle = &oneRule(.delete, pair[1]) }), &d, "the limit is 2147483647");
    }
    const tib5 = limits.max_lifecycle_size_bytes;
    const sizes = [_][2]types.LifecycleRule.Condition{
        .{ .{ .size_above_bytes = tib5 }, .{ .size_above_bytes = tib5 + 1 } },
        .{ .{ .size_below_bytes = tib5 }, .{ .size_below_bytes = tib5 + 1 } },
        .{ .{ .size_below_bytes = 0 }, .{ .size_below_bytes = std.math.maxInt(u64) } },
    };
    for (sizes) |pair| {
        try checkUpdate(&d, .{ .lifecycle = &oneRule(.delete, pair[0]) });
        try expectRefused(checkUpdate(&d, .{ .lifecycle = &oneRule(.delete, pair[1]) }), &d, "the limit is 5 TiB");
    }
    const dates = [_]types.LifecycleRule.Condition{
        .{ .created_before = "2026-02-29" },
        .{ .custom_time_before = "2026-13-01" },
        .{ .noncurrent_time_before = "2026-01-01T00:00:00Z" },
    };
    for (dates) |condition| {
        try expectRefused(checkUpdate(&d, .{ .lifecycle = &oneRule(.delete, condition) }), &d, "is not a YYYY-MM-DD date");
    }
    try checkUpdate(&d, .{ .lifecycle = &oneRule(.delete, .{ .created_before = "2024-02-29" }) });

    const long = "p" ** limits.max_lifecycle_affix_bytes;
    try checkUpdate(&d, .{ .lifecycle = &oneRule(.delete, .{ .matches_prefix = &.{long}, .matches_suffix = &.{long} }) });
    try expectRefused(checkUpdate(&d, .{ .lifecycle = &oneRule(.delete, .{ .matches_prefix = &.{long ++ "p"} }) }), &d, "matches_prefix 0 is empty or over 1024 bytes");
    try expectRefused(checkUpdate(&d, .{ .lifecycle = &oneRule(.delete, .{ .matches_suffix = &.{ "a", "" } }) }), &d, "matches_suffix 1 is empty");
    // 1,024 bytes, not characters: 600 two-byte letters are too many.
    try expectRefused(checkUpdate(&d, .{ .lifecycle = &oneRule(.delete, .{ .matches_prefix = &.{"é" ** 600} }) }), &d, "over 1024 bytes");
    try expectRefused(checkUpdate(&d, .{ .lifecycle = &oneRule(.delete, .{ .matches_storage_class = &.{""} }) }), &d, "matches_storage_class 0 is empty");
}

test "lifecycle: at most 1,000 prefixes and suffixes, counted across the rules" {
    var d: core.Diagnostics = .{};
    const prefixes: [600][]const u8 = @splat("a/");
    const suffixes: [400][]const u8 = @splat(".b");
    var rules = [_]types.LifecycleRule{
        .{ .action = .delete, .condition = .{ .matches_prefix = &prefixes } },
        .{ .action = .delete, .condition = .{ .matches_suffix = &suffixes } },
    };
    try checkUpdate(&d, .{ .lifecycle = &rules });
    rules[1].condition.matches_prefix = &.{"c/"};
    try expectRefused(checkUpdate(&d, .{ .lifecycle = &rules }), &d, "1001 prefixes and suffixes");
    // The documented 100 rules is no limit: Cloud Storage took 2,000.
    const many: [2000]types.LifecycleRule = @splat(.{ .action = .delete, .condition = .{ .age_days = 1 } });
    try checkUpdate(&d, .{ .lifecycle = &many });
}

test "lifecycle: a rule read with parts this library does not know is never sent" {
    var d: core.Diagnostics = .{};
    const unrecognized = [_]types.LifecycleRule{.{ .action = .delete, .condition = .{ .age_days = 30 }, .unrecognized = true }};
    try expectRefused(checkConfig(&d, .{ .lifecycle = &unrecognized }), &d, "does not know");
    try expectRefused(checkUpdate(&d, .{ .lifecycle = &unrecognized }), &d, "does not know");
    try expectRefused(checkUpdate(&d, .{ .lifecycle = &oneRule(.unknown, .{ .age_days = 1 }) }), &d, "does not know");
}

test "isDate: the form, and days that exist" {
    for ([_][]const u8{ "2026-01-01", "2024-02-29", "2000-02-29", "1969-12-31", "0001-01-01", "9999-12-31", "2026-04-30" }) |date| {
        errdefer std.debug.print("date: {s}\n", .{date});
        try testing.expect(isDate(date));
    }
    for ([_][]const u8{
        "",                     "2026-02-29",  "1900-02-29",  "2026-04-31", "2026-13-01", "2026-00-10",
        "2026-01-00",           "2026-1-5",    "20260101",    "2026/01/01", "+026-01-01", "2026-01-0a",
        "2026-01-01T00:00:00Z", "2026-01-01 ", "10000-01-01", "2026-01_01", "2026-0+-01",
    }) |date| {
        errdefer std.debug.print("date: {s}\n", .{date});
        try testing.expect(!isDate(date));
    }
}

test "isKmsKeyName: eight parts, four of them fixed, none empty" {
    try testing.expect(isKmsKeyName(kms_key));
    try testing.expect(isKmsKeyName("projects/my-project/locations/europe-west3/keyRings/ring-1/cryptoKeys/key_1"));
    try testing.expect(!isKmsKeyName(kms_key ++ "/cryptoKeyVersions/3"));
    try testing.expect(!isKmsKeyName("projects/p/locations/us/keyRings/r/cryptoKeys"));
}

/// Two lists of rules alike field by field.
fn expectRulesEqual(want: []const types.LifecycleRule, got: []const types.LifecycleRule) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqual(w.unrecognized, g.unrecognized);
        try testing.expectEqual(std.meta.activeTag(w.action), std.meta.activeTag(g.action));
        if (w.action == .set_storage_class) try testing.expectEqualStrings(w.action.set_storage_class, g.action.set_storage_class);
        const wc = w.condition;
        const gc = g.condition;
        try testing.expectEqual(wc.age_days, gc.age_days);
        try expectOptionalString(wc.created_before, gc.created_before);
        try expectOptionalString(wc.custom_time_before, gc.custom_time_before);
        try testing.expectEqual(wc.days_since_custom_time, gc.days_since_custom_time);
        try testing.expectEqual(wc.days_since_noncurrent_time, gc.days_since_noncurrent_time);
        try testing.expectEqual(wc.is_live, gc.is_live);
        try expectStrings(wc.matches_prefix, gc.matches_prefix);
        try expectStrings(wc.matches_suffix, gc.matches_suffix);
        try expectStrings(wc.matches_storage_class, gc.matches_storage_class);
        try expectOptionalString(wc.noncurrent_time_before, gc.noncurrent_time_before);
        try testing.expectEqual(wc.num_newer_versions, gc.num_newer_versions);
        try testing.expectEqual(wc.size_above_bytes, gc.size_above_bytes);
        try testing.expectEqual(wc.size_below_bytes, gc.size_below_bytes);
    }
}

fn expectOptionalString(want: ?[]const u8, got: ?[]const u8) !void {
    if (want) |w| {
        try testing.expectEqualStrings(w, got orelse return error.TestExpectedValue);
    } else {
        try testing.expectEqual(null, got);
    }
}

fn expectStrings(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

// Allocation failures: every one is OutOfMemory, and nothing leaks.

fn updateEverything(gpa: Allocator) !void {
    // Built by hand rather than through `Harness`, whose `deinit` frees
    // both halves: here the transport must outlive a client that may
    // never have been built.
    var fake: test_util.FakeTransport = .init(gpa, &.{.{ .respond = .{ .body = patched_bucket } }});
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var token: test_util.FakeTokenProvider = .{ .token = "ya29.test-token" };
    var client: Client = try .init(gpa, clock.io(), .{
        .project_id = "extractctl",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    var info = try client.bucket("zigps-b").update(.{
        .versioning = true,
        .soft_delete_retention_s = 0,
        .default_kms_key_name = .clear,
        .labels = .{ .change = &.{ .{ .key = "env", .value = "prod" }, .{ .key = "draft", .value = null } } },
        .lifecycle = &every_rule,
        .public_access_prevention = .enforced,
        .if_metageneration_match = 1,
    });
    info.deinit();
}

test "update: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, updateEverything, .{});
}

fn createEverything(gpa: Allocator) !void {
    var fake: test_util.FakeTransport = .init(gpa, &.{.{ .respond = .{ .body = patched_bucket } }});
    defer fake.deinit();
    var clock: test_util.FakeClock = .{};
    var token: test_util.FakeTokenProvider = .{ .token = "ya29.test-token" };
    var client: Client = try .init(gpa, clock.io(), .{
        .project_id = "extractctl",
        .token_provider = token.provider(),
        .transport = fake.transport(),
    });
    defer client.deinit();
    var info = try client.bucket("zigps-b").create(.{
        .versioning = true,
        .soft_delete_retention_s = 604_800,
        .requester_pays = true,
        .default_kms_key_name = kms_key,
        .labels = &.{.{ .key = "env", .value = "prod" }},
        .lifecycle = &every_rule,
        .uniform_bucket_level_access = true,
    });
    info.deinit();
}

test "create with settings: every allocation failure is OutOfMemory, and nothing leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, createEverything, .{});
}

// Properties. Each states a rule again, independently of the code above,
// and holds the code to it on arbitrary input.

/// Label text from pieces chosen to sit on every boundary: the ASCII
/// classes the rules name, letters of two and three bytes, an uppercase
/// letter beyond ASCII, bytes that are not UTF-8, and runs long enough to
/// cross 63 characters or 128 bytes.
fn drawLabelText(arena: Allocator, g: *test_util.ByteGen) ![]const u8 {
    const pieces = [_][]const u8{ "a", "k", "z", "0", "9", "_", "-", "A", " ", ".", "é", "日", "É", "\xff", "\xc3" };
    var out: std.ArrayList(u8) = .empty;
    const runs = g.intRange(u8, 0, 3);
    for (0..runs) |_| {
        const piece = g.pick([]const u8, &pieces);
        const count = g.pick(usize, &.{ 1, 2, 21, 42, 43, 62, 63, 64 });
        for (0..count) |_| try out.appendSlice(arena, piece);
    }
    return out.items;
}

/// The label rules, stated as Google's regular expressions state them for
/// ASCII (`[a-z][a-z0-9_-]{0,62}` for a key, `[a-z0-9_-]{0,63}` for a
/// value), walked a code point at a time: any code point beyond ASCII goes
/// to the server, and the whole is valid UTF-8 of at most 128 bytes.
fn labelTextAllowed(text: []const u8, is_key: bool) bool {
    if (!std.unicode.utf8ValidateSlice(text) or text.len > 128) return false;
    var view = std.unicode.Utf8View.initUnchecked(text).iterator();
    var chars: usize = 0;
    while (view.nextCodepoint()) |cp| : (chars += 1) {
        if (cp >= 0x80) continue;
        const letter = cp >= 'a' and cp <= 'z';
        const other = (cp >= '0' and cp <= '9') or cp == '_' or cp == '-';
        if (!letter and !(other and !(is_key and chars == 0))) return false;
    }
    return chars <= 63 and !(is_key and chars == 0);
}

fn labelsProperty(_: void, bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(bytes);
    // Mostly a few labels; sometimes more than a bucket holds.
    const count = if (g.intRange(u8, 0, 7) == 0) g.intRange(usize, 60, 66) else g.intRange(usize, 0, 3);
    const labels = try arena.alloc(types.Label, count);
    for (labels, 0..) |*label, i| {
        // Distinct keys when the draw is about the count.
        label.* = if (count > 3)
            .{ .key = try std.fmt.allocPrint(arena, "k{d}", .{i}), .value = "" }
        else
            .{ .key = try drawLabelText(arena, &g), .value = try drawLabelText(arena, &g) };
    }
    var allowed = count <= 64;
    for (labels, 0..) |label, i| {
        allowed = allowed and labelTextAllowed(label.key, true) and labelTextAllowed(label.value, false);
        for (labels[0..i]) |earlier| allowed = allowed and !std.mem.eql(u8, earlier.key, label.key);
    }
    const result = checkConfig(null, .{ .labels = labels });
    if (allowed != (result != error.InvalidBucketSettings)) {
        std.debug.print("allowed {} but check said {any}: {any}\n", .{ allowed, result, labels });
        return error.TestCheckDisagrees;
    }
}

test "fuzz bucket labels: the check accepts exactly what the rules allow" {
    // Seeds made by _tmp/storage-next/m1/seeds.py, which reads bytes as
    // ByteGen does.
    try test_util.fuzzBytes({}, labelsProperty, .{
        .corpus = &.{
            "",
            // One label: key "a", value 63 x é (126 bytes).
            "\x01\x00\x00\x00\x00\x00\x00\x00\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x0a\x00\x00\x00\x00\x00\x00\x00\x06",
            // A value of 43 x 日: 43 characters, 129 bytes.
            "\x01\x00\x00\x00\x00\x00\x00\x00\x01\x01\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x0b\x00\x00\x00\x00\x00\x00\x00\x04",
            // A key of 64 characters.
            "\x01\x00\x00\x00\x00\x00\x00\x00\x01\x01\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x07\x00",
            // A key starting with a digit.
            "\x01\x00\x00\x00\x00\x00\x00\x00\x01\x02\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00",
            // Two labels with the same key.
            "\x01\x00\x00\x00\x00\x00\x00\x00\x02\x01\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
            // 65 labels, then 64.
            "\x00\x00\x00\x00\x00\x00\x00\x00\x05",
            "\x00\x00\x00\x00\x00\x00\x00\x00\x04",
        },
    });
}

/// A rule drawn with every field at or next to a boundary, mostly valid.
fn drawRule(arena: Allocator, g: *test_util.ByteGen) !types.LifecycleRule {
    var rule: types.LifecycleRule = .{
        .action = switch (g.intRange(u8, 0, 9)) {
            0, 1, 2, 3 => .delete,
            4, 5 => .{ .set_storage_class = g.pick([]const u8, &.{ "NEARLINE", "COLDLINE", "" }) },
            6, 7, 8 => .abort_incomplete_multipart_upload,
            else => .unknown,
        },
        .condition = .{},
        .unrecognized = g.intRange(u8, 0, 15) == 0,
    };
    const c = &rule.condition;
    const days = [_]u32{ 0, 1, 30, limits.max_lifecycle_days, limits.max_lifecycle_days + 1 };
    const sizes = [_]u64{ 0, 1, limits.max_lifecycle_size_bytes, limits.max_lifecycle_size_bytes + 1 };
    const dates = [_][]const u8{ "2026-01-01", "2024-02-29", "2026-02-29", "2026-1-5", "" };
    // Each field set about one time in three, so rules with none happen.
    if (g.intRange(u8, 0, 2) == 0) c.age_days = g.pick(u32, &days);
    if (g.intRange(u8, 0, 5) == 0) c.created_before = g.pick([]const u8, &dates);
    if (g.intRange(u8, 0, 5) == 0) c.custom_time_before = g.pick([]const u8, &dates);
    if (g.intRange(u8, 0, 5) == 0) c.days_since_custom_time = g.pick(u32, &days);
    if (g.intRange(u8, 0, 5) == 0) c.days_since_noncurrent_time = g.pick(u32, &days);
    if (g.intRange(u8, 0, 5) == 0) c.is_live = g.boolean();
    if (g.intRange(u8, 0, 2) == 0) c.matches_prefix = try drawAffixes(arena, g);
    if (g.intRange(u8, 0, 2) == 0) c.matches_suffix = try drawAffixes(arena, g);
    if (g.intRange(u8, 0, 5) == 0) c.matches_storage_class = g.pick([]const []const u8, &.{ &.{}, &.{"STANDARD"}, &.{""} });
    if (g.intRange(u8, 0, 5) == 0) c.noncurrent_time_before = g.pick([]const u8, &dates);
    if (g.intRange(u8, 0, 5) == 0) c.num_newer_versions = g.pick(u32, &days);
    if (g.intRange(u8, 0, 5) == 0) c.size_above_bytes = g.pick(u64, &sizes);
    if (g.intRange(u8, 0, 5) == 0) c.size_below_bytes = g.pick(u64, &sizes);
    return rule;
}

fn drawAffixes(arena: Allocator, g: *test_util.ByteGen) ![]const []const u8 {
    const long = "p" ** limits.max_lifecycle_affix_bytes;
    const count: usize = g.pick(usize, &.{ 0, 1, 2, 500, 501 });
    const out = try arena.alloc([]const u8, count);
    for (out) |*text| text.* = g.pick([]const u8, &.{ "logs/", ".tmp", "", long, long ++ "p", "é" ** 512, "é" ** 513 });
    return out;
}

/// Whether Cloud Storage takes these rules, stated from what it refused on
/// 2026-09-29: a condition in every rule, only age and names under the
/// abort action, a class to set, days under 2^31, sizes up to 5 TiB, real
/// dates, names 1 to 1,024 bytes, at most 1,000 of them, and nothing this
/// library could not read.
fn rulesAllowed(rules: []const types.LifecycleRule) bool {
    var names_total: usize = 0;
    for (rules) |rule| {
        if (rule.unrecognized) return false;
        const c = rule.condition;
        const set = [_]bool{
            c.age_days != null,               c.created_before != null,             c.custom_time_before != null,
            c.days_since_custom_time != null, c.days_since_noncurrent_time != null, c.is_live != null,
            c.matches_prefix.len > 0,         c.matches_suffix.len > 0,             c.matches_storage_class.len > 0,
            c.noncurrent_time_before != null, c.num_newer_versions != null,         c.size_above_bytes != null,
            c.size_below_bytes != null,
        };
        // Age and the two name lists: positions 0, 6 and 7 above.
        const abort_may = [_]bool{ true, false, false, false, false, false, true, true, false, false, false, false, false };
        if (std.mem.indexOfScalar(bool, &set, true) == null) return false;
        switch (rule.action) {
            .unknown => return false,
            .set_storage_class => |class| if (class.len == 0) return false,
            .abort_incomplete_multipart_upload => for (set, abort_may) |s, may| if (s and !may) return false,
            .delete => {},
        }
        for ([_]?u32{ c.age_days, c.days_since_custom_time, c.days_since_noncurrent_time, c.num_newer_versions }) |n| {
            if (n) |v| if (v >= 1 << 31) return false;
        }
        for ([_]?u64{ c.size_above_bytes, c.size_below_bytes }) |n| {
            if (n) |v| if (v > 5 << 40) return false;
        }
        // The drawn dates, and whether each exists.
        for ([_]?[]const u8{ c.created_before, c.custom_time_before, c.noncurrent_time_before }) |date| {
            const d = date orelse continue;
            if (!(std.mem.eql(u8, d, "2026-01-01") or std.mem.eql(u8, d, "2024-02-29"))) return false;
        }
        for ([_][]const []const u8{ c.matches_prefix, c.matches_suffix }) |list| for (list) |text| {
            if (text.len < 1 or text.len > 1024) return false;
        };
        for (c.matches_storage_class) |class| if (class.len == 0) return false;
        names_total += c.matches_prefix.len + c.matches_suffix.len;
    }
    return names_total <= 1000;
}

fn lifecycleCheckProperty(_: void, bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(bytes);
    const rules = try arena.alloc(types.LifecycleRule, g.intRange(usize, 0, 3));
    for (rules) |*rule| rule.* = try drawRule(arena, &g);
    const allowed = rulesAllowed(rules);
    const result = checkUpdate(null, .{ .lifecycle = rules });
    if (allowed != (result != error.InvalidBucketSettings)) {
        std.debug.print("allowed {} but check said {any}: {any}\n", .{ allowed, result, rules });
        return error.TestCheckDisagrees;
    }
}

test "fuzz lifecycle rules: the check accepts exactly what Cloud Storage takes" {
    try test_util.fuzzBytes({}, lifecycleCheckProperty, .{ .corpus = &.{
        "",
        "\x00" ** 8 ++ "\x01",
    } });
}

/// An update drawn over every field, with values valid far more often than
/// not, so most draws reach the encoder.
fn drawUpdate(arena: Allocator, g: *test_util.ByteGen) !types.BucketUpdate {
    var u: types.BucketUpdate = .{};
    if (g.boolean()) u.versioning = g.boolean();
    if (g.boolean()) u.soft_delete_retention_s = g.pick(u32, &.{ 0, 604_800, 7_776_000 });
    if (g.boolean()) u.requester_pays = g.boolean();
    u.default_kms_key_name = switch (g.intRange(u8, 0, 2)) {
        0 => .keep,
        1 => .{ .set = kms_key },
        else => .clear,
    };
    u.labels = switch (g.intRange(u8, 0, 3)) {
        0 => .keep,
        1 => .clear,
        else => edit: {
            const changes = try arena.alloc(types.LabelChange, g.intRange(usize, 0, 3));
            for (changes, 0..) |*change, i| change.* = .{
                .key = try std.fmt.allocPrint(arena, "k{d}", .{i}),
                .value = if (g.boolean()) null else g.pick([]const u8, &.{ "", "v", "été" }),
            };
            break :edit .{ .change = changes };
        },
    };
    if (g.boolean()) {
        const rules = try arena.alloc(types.LifecycleRule, g.intRange(usize, 0, 3));
        for (rules) |*rule| rule.* = try drawRule(arena, g);
        u.lifecycle = rules;
    }
    if (g.boolean()) u.uniform_bucket_level_access = g.boolean();
    if (g.boolean()) u.public_access_prevention = g.pick(types.PublicAccessPrevention, &.{ .inherited, .enforced });
    if (g.intRange(u8, 0, 3) == 0) u.storage_class = "NEARLINE";
    u.retention_period_s = switch (g.intRange(u8, 0, 3)) {
        0, 1 => .keep,
        2 => .{ .set = g.pick(u64, &.{ 1, 3600, 3_155_760_000, 0, 3_155_760_001 }) },
        else => .clear,
    };
    if (g.boolean()) u.default_event_based_hold = g.boolean();
    if (g.boolean()) u.if_metageneration_match = g.int(u8);
    return u;
}

fn updateBodyProperty(_: void, bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(bytes);
    const u = try drawUpdate(arena, &g);
    checkUpdate(null, u) catch return;
    const body = try encodeUpdate(arena, u);
    const root = (try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{})).object;

    // Every field the update names, and no key it does not.
    var expected: usize = 0;
    if (u.versioning) |on| {
        expected += 1;
        try testing.expectEqual(on, root.get("versioning").?.object.get("enabled").?.bool);
    }
    if (u.soft_delete_retention_s) |s| {
        expected += 1;
        const text = root.get("softDeletePolicy").?.object.get("retentionDurationSeconds").?.string;
        try testing.expectEqual(s, try std.fmt.parseInt(u32, text, 10));
    }
    if (u.requester_pays) |on| {
        expected += 1;
        try testing.expectEqual(on, root.get("billing").?.object.get("requesterPays").?.bool);
    }
    switch (u.default_kms_key_name) {
        .keep => {},
        .set => |key| {
            expected += 1;
            try testing.expectEqualStrings(key, root.get("encryption").?.object.get("defaultKmsKeyName").?.string);
        },
        .clear => {
            expected += 1;
            try testing.expectEqual(std.json.Value.null, root.get("encryption").?.object.get("defaultKmsKeyName").?);
        },
    }
    switch (u.labels) {
        .keep => try testing.expectEqual(null, root.get("labels")),
        .clear => {
            expected += 1;
            try testing.expectEqual(std.json.Value.null, root.get("labels").?);
        },
        .change => |changes| if (changes.len == 0) {
            try testing.expectEqual(null, root.get("labels"));
        } else {
            expected += 1;
            const sent = root.get("labels").?.object;
            try testing.expectEqual(changes.len, sent.count());
            for (changes) |change| {
                const value = sent.get(change.key).?;
                if (change.value) |v| try testing.expectEqualStrings(v, value.string) else try testing.expectEqual(std.json.Value.null, value);
            }
        },
    }
    if (u.lifecycle) |rules| {
        expected += 1;
        // Back through the decoder: the rules as they went out.
        const info = try codec.decodeBucket(arena, body);
        try expectRulesEqual(rules, info.lifecycle);
    } else try testing.expectEqual(null, root.get("lifecycle"));
    if (u.uniform_bucket_level_access != null or u.public_access_prevention != null) {
        expected += 1;
        const iam = root.get("iamConfiguration").?.object;
        try testing.expectEqual(@intFromBool(u.uniform_bucket_level_access != null) + @as(usize, @intFromBool(u.public_access_prevention != null)), iam.count());
        if (u.uniform_bucket_level_access) |on| try testing.expectEqual(on, iam.get("uniformBucketLevelAccess").?.object.get("enabled").?.bool);
        if (u.public_access_prevention) |p| try testing.expectEqualStrings(@tagName(p), iam.get("publicAccessPrevention").?.string);
    }
    if (u.storage_class) |class| {
        expected += 1;
        try testing.expectEqualStrings(class, root.get("storageClass").?.string);
    }
    switch (u.retention_period_s) {
        .keep => try testing.expectEqual(null, root.get("retentionPolicy")),
        .set => |period| {
            expected += 1;
            const policy = root.get("retentionPolicy").?.object;
            try testing.expectEqual(1, policy.count());
            try testing.expectEqual(period, try std.fmt.parseInt(u64, policy.get("retentionPeriod").?.string, 10));
        },
        .clear => {
            expected += 1;
            try testing.expectEqual(std.json.Value.null, root.get("retentionPolicy").?);
        },
    }
    if (u.default_event_based_hold) |on| {
        expected += 1;
        try testing.expectEqual(on, root.get("defaultEventBasedHold").?.bool);
    }
    try testing.expectEqual(expected, root.count());
}

test "fuzz bucket updates: the patch body says what the update said, and no more" {
    try test_util.fuzzBytes({}, updateBodyProperty, .{ .corpus = &.{ "", "\x01" ** 64, "\xff" ** 64 } });
}

fn configRoundTripProperty(_: void, bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(bytes);
    const u = try drawUpdate(arena, &g);
    // The same settings, as a new bucket's.
    const labels: []const types.Label = switch (u.labels) {
        .change => |changes| labels: {
            const out = try arena.alloc(types.Label, changes.len);
            for (changes, out) |change, *label| label.* = .{ .key = change.key, .value = change.value orelse "" };
            break :labels out;
        },
        .keep, .clear => &.{},
    };
    const config: types.BucketConfig = .{
        .location = g.pick([]const u8, &.{ "US", "europe-west3" }),
        .versioning = u.versioning orelse false,
        .soft_delete_retention_s = u.soft_delete_retention_s,
        .requester_pays = u.requester_pays orelse false,
        .default_kms_key_name = if (u.default_kms_key_name == .set) kms_key else null,
        .labels = labels,
        .lifecycle = u.lifecycle orelse &.{},
        .uniform_bucket_level_access = u.uniform_bucket_level_access,
        .public_access_prevention = u.public_access_prevention,
        .retention_period_s = if (u.retention_period_s == .set) u.retention_period_s.set else null,
        .default_event_based_hold = u.default_event_based_hold orelse false,
    };
    checkConfig(null, config) catch return;
    // The create body is a bucket resource, so the decoder reads it back.
    const info = try codec.decodeBucket(arena, try encodeConfig(arena, "zigps-b", config));
    try testing.expectEqualStrings("zigps-b", info.name);
    try testing.expectEqualStrings(config.location, info.location);
    try testing.expectEqualStrings(config.storage_class, info.storage_class);
    try testing.expectEqual(config.versioning, info.versioning);
    const retention = config.soft_delete_retention_s orelse 0;
    try testing.expectEqual(if (retention == 0) null else retention, if (info.soft_delete) |s| s.retention_s else null);
    try testing.expectEqual(config.requester_pays, info.requester_pays);
    try expectOptionalString(config.default_kms_key_name, info.default_kms_key_name);
    try testing.expectEqual(config.labels.len, info.labels.len);
    for (config.labels, info.labels) |want, got| {
        try testing.expectEqualStrings(want.key, got.key);
        try testing.expectEqualStrings(want.value, got.value);
    }
    try expectRulesEqual(config.lifecycle, info.lifecycle);
    try testing.expectEqual(config.uniform_bucket_level_access orelse false, info.uniform_bucket_level_access);
    try testing.expectEqual(config.public_access_prevention orelse .inherited, info.public_access_prevention);
    try testing.expectEqual(config.retention_period_s, if (info.retention_policy) |p| p.period_s else null);
    try testing.expectEqual(config.default_event_based_hold, info.default_event_based_hold);
}

test "fuzz bucket configs: a config goes out and comes back as it was" {
    try test_util.fuzzBytes({}, configRoundTripProperty, .{ .corpus = &.{ "", "\x01" ** 64, "\xff" ** 64 } });
}

// Against `FakeMultipart`'s buckets, which hold Cloud Storage's rules as
// measured, written apart from the encoder above.

fn clientOnFake(fake: *test_util.FakeMultipart, token: *core.StaticToken, diag: *core.Diagnostics) !Client {
    return .init(testing.allocator, fake.io, .{
        .project_id = "extractctl",
        .token_provider = token.provider(),
        .transport = fake.transport(),
        .diagnostics = diag,
        .retry = .{ .max_attempts = 3, .initial_backoff_ms = 1, .max_backoff_ms = 2 },
    });
}

test "against production's rules: settings created, each changed alone, and read back" {
    var fake: test_util.FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: core.Diagnostics = .{};
    var client = try clientOnFake(&fake, &token, &diag);
    defer client.deinit();
    const b = client.bucket("zigps-model");

    var created = try b.create(.{
        .versioning = true,
        .soft_delete_retention_s = 0,
        .labels = &.{ .{ .key = "env", .value = "test" }, .{ .key = "team", .value = "zig" } },
        .lifecycle = &every_rule,
        .uniform_bucket_level_access = true,
        .public_access_prevention = .enforced,
    });
    defer created.deinit();
    try testing.expectEqual(1, created.value.metageneration);
    try testing.expect(created.value.versioning);
    try testing.expectEqual(null, created.value.soft_delete);
    try expectRulesEqual(&every_rule, created.value.lifecycle);

    // Each setting alone leaves the others as they were.
    var one = try b.update(.{ .public_access_prevention = .inherited });
    defer one.deinit();
    try testing.expectEqual(.inherited, one.value.public_access_prevention);
    try testing.expect(one.value.uniform_bucket_level_access);
    try testing.expect(one.value.versioning);
    try testing.expectEqualStrings("test", one.value.label("env").?);
    try testing.expectEqual(2, one.value.metageneration);

    // Labels merge: one set, one removed, one left alone.
    var labels = try b.update(.{ .labels = .{ .change = &.{
        .{ .key = "env", .value = "prod" },
        .{ .key = "team", .value = null },
        .{ .key = "tier", .value = "" },
    } } });
    defer labels.deinit();
    try testing.expectEqual(2, labels.value.labels.len);
    try testing.expectEqualStrings("prod", labels.value.label("env").?);
    try testing.expectEqualStrings("", labels.value.label("tier").?);
    try testing.expectEqual(null, labels.value.label("team"));

    // An empty change beside another setting leaves every label.
    var versioning = try b.update(.{ .versioning = false, .labels = .{ .change = &.{} } });
    defer versioning.deinit();
    try testing.expect(!versioning.value.versioning);
    try testing.expectEqual(2, versioning.value.labels.len);

    // Soft delete back on, then the rules replaced by one.
    var soft = try b.update(.{ .soft_delete_retention_s = 691_200, .lifecycle = &.{.{ .action = .delete, .condition = .{ .age_days = 1 } }} });
    defer soft.deinit();
    try testing.expectEqual(691_200, soft.value.soft_delete.?.retention_s);
    try testing.expectEqual(1, soft.value.lifecycle.len);

    // Everything taken away.
    var cleared = try b.update(.{ .labels = .clear, .lifecycle = &.{}, .soft_delete_retention_s = 0, .default_kms_key_name = .clear });
    defer cleared.deinit();
    try testing.expectEqual(0, cleared.value.labels.len);
    try testing.expectEqual(0, cleared.value.lifecycle.len);
    try testing.expectEqual(null, cleared.value.soft_delete);
    try testing.expectEqual(null, cleared.value.default_kms_key_name);
    try testing.expectEqual(6, cleared.value.metageneration);

    var read = try b.get();
    defer read.deinit();
    try testing.expectEqual(6, read.value.metageneration);
    try testing.expectEqual(.inherited, read.value.public_access_prevention);
}

test "against production's rules: conditions, and what only the server can refuse" {
    var fake: test_util.FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: core.Diagnostics = .{};
    var client = try clientOnFake(&fake, &token, &diag);
    defer client.deinit();
    const b = client.bucket("zigps-model");

    // 63 labels: an edit that sets two more passes here, where only the
    // count after the edit matters, and the server refuses it.
    var many: [63]types.Label = undefined;
    var keys: [63][4]u8 = undefined;
    for (&many, &keys, 0..) |*l, *k, i| l.* = .{ .key = std.fmt.bufPrint(k, "l{d}", .{i}) catch unreachable, .value = "" };
    var created = try b.create(.{ .labels = &many });
    created.deinit();
    try testing.expectError(error.InvalidArgument, b.update(.{ .labels = .{ .change = &.{
        .{ .key = "a", .value = "1" },
        .{ .key = "b", .value = "2" },
    } } }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "65 labels") != null);
    // Removing one while adding one stays at 64, and is taken.
    var swapped = try b.update(.{ .labels = .{ .change = &.{
        .{ .key = "l0", .value = null },
        .{ .key = "a", .value = "1" },
        .{ .key = "b", .value = "2" },
    } } });
    defer swapped.deinit();
    try testing.expectEqual(64, swapped.value.labels.len);
    try testing.expectEqual(2, swapped.value.metageneration);

    // A stale condition changes nothing; a current one goes through.
    try testing.expectError(error.FailedPrecondition, b.update(.{ .versioning = true, .if_metageneration_match = 1 }));
    try testing.expectError(error.NotModified, b.update(.{ .versioning = true, .if_metageneration_not_match = 2 }));
    var current = try b.update(.{ .versioning = true, .if_metageneration_match = 2 });
    defer current.deinit();
    try testing.expect(current.value.versioning);
    try testing.expectEqual(3, current.value.metageneration);

    try testing.expectError(error.NotFound, client.bucket("zigps-missing").update(.{ .versioning = true }));
    try testing.expectError(error.AlreadyExists, b.create(.{}));
    // Every refusal above cost a request; the ones refused here none.
    const patches = fake.buckets.counts.patches;
    try testing.expectError(error.InvalidBucketSettings, b.update(.{ .soft_delete_retention_s = 60 }));
    try testing.expectEqual(patches, fake.buckets.counts.patches);
}

/// Loses the answer of the next bucket request once armed: the change
/// lands, and the client never hears.
const LoseNext = struct {
    armed: bool = false,

    fn plan(self: *LoseNext) test_util.FakeMultipart.FaultPlan {
        return .{ .ctx = self, .decide = decide };
    }

    fn decide(ctx: ?*anyopaque, kind: test_util.FakeMultipart.Kind, _: u32) test_util.FakeMultipart.Fault {
        const self: *LoseNext = @ptrCast(@alignCast(ctx.?));
        if (kind != .bucket or !self.armed) return .none;
        self.armed = false;
        return .lose_answer;
    }
};

/// What a bucket's settings are after a series of updates, worked out
/// from what each field of an update means, with none of the code above.
const Model = struct {
    versioning: bool,
    soft_delete: u32,
    requester_pays: bool,
    kms: ?[]const u8,
    labels: std.StringArrayHashMapUnmanaged([]const u8),
    lifecycle: []const types.LifecycleRule,
    uniform: bool,
    prevention: types.PublicAccessPrevention,
    class: []const u8,
    retention: ?u64,
    default_hold: bool,
    metageneration: u64 = 1,

    fn init(arena: Allocator, config: types.BucketConfig) !Model {
        var labels: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        for (config.labels) |label| try labels.put(arena, label.key, label.value);
        return .{
            .versioning = config.versioning,
            .soft_delete = config.soft_delete_retention_s orelse 604_800,
            .requester_pays = config.requester_pays,
            .kms = config.default_kms_key_name,
            .labels = labels,
            .lifecycle = config.lifecycle,
            .uniform = config.uniform_bucket_level_access orelse false,
            .prevention = config.public_access_prevention orelse .inherited,
            .class = config.storage_class,
            .retention = config.retention_period_s,
            .default_hold = config.default_event_based_hold,
        };
    }

    /// Applies `u`, or returns false where Cloud Storage refuses it: a
    /// bucket left holding more than 64 labels.
    fn apply(m: *Model, arena: Allocator, u: types.BucketUpdate) !bool {
        var labels = try m.labels.clone(arena);
        switch (u.labels) {
            .keep => {},
            .clear => labels.clearRetainingCapacity(),
            .change => |changes| for (changes) |change| {
                if (change.value) |value| try labels.put(arena, change.key, value) else _ = labels.orderedRemove(change.key);
            },
        }
        if (labels.count() > 64) return false;
        m.labels = labels;
        if (u.versioning) |on| m.versioning = on;
        if (u.soft_delete_retention_s) |s| m.soft_delete = s;
        if (u.requester_pays) |on| m.requester_pays = on;
        switch (u.default_kms_key_name) {
            .keep => {},
            .set => |key| m.kms = key,
            .clear => m.kms = null,
        }
        if (u.lifecycle) |rules| m.lifecycle = rules;
        if (u.uniform_bucket_level_access) |on| m.uniform = on;
        if (u.public_access_prevention) |p| m.prevention = p;
        if (u.storage_class) |class| m.class = class;
        switch (u.retention_period_s) {
            .keep => {},
            .set => |period| m.retention = period,
            .clear => m.retention = null,
        }
        if (u.default_event_based_hold) |on| m.default_hold = on;
        m.metageneration += 1;
        return true;
    }

    fn expectMatches(m: Model, info: types.BucketInfo) !void {
        try testing.expectEqual(m.metageneration, info.metageneration);
        try testing.expectEqual(m.versioning, info.versioning);
        try testing.expectEqual(if (m.soft_delete == 0) null else m.soft_delete, if (info.soft_delete) |s| s.retention_s else null);
        try testing.expectEqual(m.requester_pays, info.requester_pays);
        try expectOptionalString(m.kms, info.default_kms_key_name);
        try testing.expectEqual(m.labels.count(), info.labels.len);
        var it = m.labels.iterator();
        while (it.next()) |entry| try testing.expectEqualStrings(entry.value_ptr.*, info.label(entry.key_ptr.*) orelse return error.TestLabelMissing);
        try expectRulesEqual(m.lifecycle, info.lifecycle);
        try testing.expectEqual(m.uniform, info.uniform_bucket_level_access);
        try testing.expectEqual(m.prevention, info.public_access_prevention);
        try testing.expectEqualStrings(m.class, info.storage_class);
        try testing.expectEqual(m.retention, if (info.retention_policy) |p| p.period_s else null);
        try testing.expectEqual(m.default_hold, info.default_event_based_hold);
    }
};

fn modelProperty(_: void, bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: test_util.ByteGen = .init(bytes);

    var fake: test_util.FakeMultipart = .init(testing.allocator, testing.io);
    defer fake.deinit();
    var lose: LoseNext = .{};
    fake.faults = lose.plan();
    var token: core.StaticToken = .{ .token = "ya29.t" };
    var diag: core.Diagnostics = .{};
    var client = try clientOnFake(&fake, &token, &diag);
    defer client.deinit();
    const b = client.bucket("zigps-model");

    // A bucket from drawn settings, sometimes one label short of full.
    const first = try drawUpdate(arena, &g);
    var labels: std.ArrayList(types.Label) = .empty;
    if (g.intRange(u8, 0, 3) == 0) for (0..63) |i| try labels.append(arena, .{ .key = try std.fmt.allocPrint(arena, "l{d}", .{i}), .value = "" });
    const config: types.BucketConfig = .{
        .versioning = first.versioning orelse false,
        .soft_delete_retention_s = first.soft_delete_retention_s,
        .requester_pays = first.requester_pays orelse false,
        .default_kms_key_name = if (first.default_kms_key_name == .set) kms_key else null,
        .labels = labels.items,
        .lifecycle = first.lifecycle orelse &.{},
        .uniform_bucket_level_access = first.uniform_bucket_level_access,
        .public_access_prevention = first.public_access_prevention,
        .retention_period_s = if (first.retention_period_s == .set) first.retention_period_s.set else null,
        .default_event_based_hold = first.default_event_based_hold orelse false,
    };
    checkConfig(null, config) catch return;
    var created = try b.create(config);
    defer created.deinit();
    var model: Model = try .init(arena, config);
    try model.expectMatches(created.value);

    for (0..g.intRange(u8, 1, 6)) |_| {
        var u = try drawUpdate(arena, &g);
        u.if_metageneration_match = switch (g.intRange(u8, 0, 3)) {
            0 => model.metageneration,
            1 => model.metageneration - 1,
            else => null,
        };
        const stale = if (u.if_metageneration_match) |m| m != model.metageneration else false;
        const lost = g.intRange(u8, 0, 3) == 0;
        const patches = fake.buckets.counts.patches;
        const valid = if (checkUpdate(null, u)) |_| true else |_| false;
        lose.armed = lost and valid and !stale;
        const result = b.update(u);
        lose.armed = false;
        if (!valid) {
            try testing.expectError(error.InvalidBucketSettings, result);
            try testing.expectEqual(patches, fake.buckets.counts.patches);
        } else if (stale) {
            try testing.expectError(error.FailedPrecondition, result);
        } else {
            const taken = try model.apply(arena, u);
            const repeated = u.if_metageneration_match != null;
            if (!taken) {
                // Refused; a lost refusal is refused again when repeated.
                if (lost and !repeated) {
                    if (result) |ok| {
                        var owned = ok;
                        owned.deinit();
                        return error.TestExpectedError;
                    } else |_| {}
                } else try testing.expectError(error.InvalidArgument, result);
            } else if (lost and repeated) {
                // Landed, answer lost, and the repeat found the
                // metageneration moved.
                try testing.expectError(error.FailedPrecondition, result);
            } else if (lost) {
                // Landed, answer lost, and never repeated.
                if (result) |ok| {
                    var owned = ok;
                    owned.deinit();
                    return error.TestExpectedError;
                } else |_| {}
            } else {
                var info = try result;
                defer info.deinit();
                try model.expectMatches(info.value);
            }
        }
        var read = try b.get();
        defer read.deinit();
        try model.expectMatches(read.value);
    }
}

test "heavy property bucket updates against production's rules: every change lands once, as a model says" {
    try test_util.fuzzBytes({}, modelProperty, .{ .corpus = &.{ "", "\x01" ** 96, "\x00\x01\x02\x03" ** 32 } });
}
