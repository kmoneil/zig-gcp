//! Credential files: the one `GOOGLE_APPLICATION_CREDENTIALS` names, and the
//! one `gcloud auth application-default login` writes. This version reads
//! files of type `authorized_user`, and refuses every other type by name.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const Diagnostics = core.Diagnostics;

/// The largest credential file read. Real ones are well under 4 KiB.
pub const max_file_bytes = 64 * 1024;

pub const Error = error{
    /// Not JSON, larger than `max_file_bytes`, a required field missing or
    /// empty, or a quota project that is not one.
    InvalidCredentialsFile,
    /// A type other than `authorized_user`, or a universe other than
    /// googleapis.com.
    UnsupportedCredentialType,
    OutOfMemory,
};

/// An `authorized_user` file's fields. They point into the arena passed to
/// `parse` or into the JSON text, and the secrets among them need wiping.
pub const AuthorizedUser = struct {
    client_id: []const u8,
    client_secret: []const u8,
    refresh_token: []const u8,
    /// The project to charge for quota, when the file names one.
    quota_project_id: ?[]const u8,
};

const Wire = struct {
    type: ?[]const u8 = null,
    client_id: ?[]const u8 = null,
    client_secret: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
    quota_project_id: ?[]const u8 = null,
    universe_domain: ?[]const u8 = null,
};

/// Types this version recognizes, and why it refuses them.
const refused = std.StaticStringMap([]const u8).initComptime(.{
    .{ "service_account", "service account keys need RSA signing, which this version does not do" },
    .{ "impersonated_service_account", "impersonated service accounts are not supported yet" },
    .{ "external_account", "workload identity federation is not supported" },
    .{ "external_account_authorized_user", "workforce identity federation is not supported" },
});

/// Reads an `authorized_user` file. Failures say why in `diag`, which never
/// repeats a secret.
pub fn parse(arena: Allocator, json: []const u8, diag: ?*Diagnostics) Error!AuthorizedUser {
    if (json.len > max_file_bytes) return invalid(diag, "the credentials file is larger than 64 KiB", .{});
    const wire = std.json.parseFromSliceLeaky(Wire, arena, json, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
        .allocate = .alloc_if_needed,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalid(diag, "the credentials file is not JSON, or a field that should be a string is not", .{}),
    };
    const kind = wire.type orelse return invalid(diag, "the credentials file has no \"type\"", .{});
    if (!std.mem.eql(u8, kind, "authorized_user")) {
        if (diag) |d| {
            if (refused.get(kind)) |why| {
                d.print("the credentials file has type \"{s}\": {s}", .{ kind, why });
            } else if (isPrintable(kind)) {
                d.print("the credentials file has type \"{s}\", which this version does not know", .{kind});
            } else {
                d.print("the credentials file has a type this version does not know", .{});
            }
        }
        return error.UnsupportedCredentialType;
    }
    if (wire.universe_domain) |universe| if (!std.mem.eql(u8, universe, "googleapis.com")) {
        if (diag) |d| {
            if (isPrintable(universe)) {
                d.print("the credentials file is for universe \"{s}\"; only googleapis.com is supported", .{universe});
            } else {
                d.print("the credentials file is for another universe; only googleapis.com is supported", .{});
            }
        }
        return error.UnsupportedCredentialType;
    };
    const quota = if (wire.quota_project_id) |q| if (q.len == 0) null else q else null;
    // It will travel in a header, so it must not be able to break one.
    if (quota) |q| if (!core.TokenProvider.isValidToken(q)) {
        return invalid(diag, "the credentials file's \"quota_project_id\" is not a project id", .{});
    };
    return .{
        .client_id = try required(wire.client_id, "client_id", diag),
        .client_secret = try required(wire.client_secret, "client_secret", diag),
        .refresh_token = try required(wire.refresh_token, "refresh_token", diag),
        .quota_project_id = quota,
    };
}

fn required(value: ?[]const u8, name: []const u8, diag: ?*Diagnostics) Error![]const u8 {
    const v = value orelse return invalid(diag, "the credentials file lacks \"{s}\"", .{name});
    if (v.len == 0) return invalid(diag, "the credentials file has an empty \"{s}\"", .{name});
    return v;
}

fn invalid(diag: ?*Diagnostics, comptime format: []const u8, args: anytype) Error {
    if (diag) |d| d.print(format, args);
    return error.InvalidCredentialsFile;
}

/// Short, printable ASCII: safe to repeat in a message.
fn isPrintable(text: []const u8) bool {
    if (text.len == 0 or text.len > 64) return false;
    for (text) |c| if (c < ' ' or c >= 0x7f) return false;
    return true;
}

const testing = std.testing;
const test_util = core.testing;

fn expectParse(json: []const u8, want: Error!AuthorizedUser, message: ?[]const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostics = .{};
    const got = parse(arena.allocator(), json, &diag);
    if (want) |w| {
        const g = try got;
        try testing.expectEqualStrings(w.client_id, g.client_id);
        try testing.expectEqualStrings(w.client_secret, g.client_secret);
        try testing.expectEqualStrings(w.refresh_token, g.refresh_token);
        if (w.quota_project_id) |q| try testing.expectEqualStrings(q, g.quota_project_id.?) else try testing.expectEqual(null, g.quota_project_id);
    } else |err| {
        try testing.expectError(err, got);
        if (message) |m| try testing.expectEqualStrings(m, diag.message());
        // Nothing secret is ever repeated.
        try testing.expect(std.mem.indexOf(u8, diag.message(), "SECRET") == null);
    }
}

test "adc_file: an authorized_user file, with the other fields gcloud writes" {
    try expectParse(
        \\{"account": "", "client_id": "123.apps.googleusercontent.com",
        \\ "client_secret": "d-SECRET", "quota_project_id": "my-project",
        \\ "refresh_token": "1//0g-SECRET", "type": "authorized_user",
        \\ "universe_domain": "googleapis.com"}
    , .{
        .client_id = "123.apps.googleusercontent.com",
        .client_secret = "d-SECRET",
        .refresh_token = "1//0g-SECRET",
        .quota_project_id = "my-project",
    }, null);
}

test "adc_file: every other type is refused by name" {
    const base = "\"client_id\":\"c\",\"client_secret\":\"SECRET\",\"refresh_token\":\"SECRET\"";
    try expectParse("{\"type\":\"service_account\"," ++ base ++ "}", error.UnsupportedCredentialType, "the credentials file has type \"service_account\": service account keys need RSA signing, which this version does not do");
    try expectParse("{\"type\":\"impersonated_service_account\"," ++ base ++ "}", error.UnsupportedCredentialType, "the credentials file has type \"impersonated_service_account\": impersonated service accounts are not supported yet");
    try expectParse("{\"type\":\"external_account\"," ++ base ++ "}", error.UnsupportedCredentialType, "the credentials file has type \"external_account\": workload identity federation is not supported");
    try expectParse("{\"type\":\"external_account_authorized_user\"," ++ base ++ "}", error.UnsupportedCredentialType, "the credentials file has type \"external_account_authorized_user\": workforce identity federation is not supported");
    try expectParse("{\"type\":\"banana\"," ++ base ++ "}", error.UnsupportedCredentialType, "the credentials file has type \"banana\", which this version does not know");
    try expectParse("{\"type\":\"a\\nb\"," ++ base ++ "}", error.UnsupportedCredentialType, "the credentials file has a type this version does not know");
    try expectParse("{" ++ base ++ "}", error.InvalidCredentialsFile, "the credentials file has no \"type\"");
}

test "adc_file: a missing or empty required field" {
    try expectParse("{\"type\":\"authorized_user\",\"client_id\":\"c\",\"refresh_token\":\"SECRET\"}", error.InvalidCredentialsFile, "the credentials file lacks \"client_secret\"");
    try expectParse("{\"type\":\"authorized_user\",\"client_id\":\"c\",\"client_secret\":\"SECRET\"}", error.InvalidCredentialsFile, "the credentials file lacks \"refresh_token\"");
    try expectParse("{\"type\":\"authorized_user\",\"client_secret\":\"SECRET\",\"refresh_token\":\"SECRET\"}", error.InvalidCredentialsFile, "the credentials file lacks \"client_id\"");
    try expectParse("{\"type\":\"authorized_user\",\"client_id\":\"c\",\"client_secret\":\"SECRET\",\"refresh_token\":\"\"}", error.InvalidCredentialsFile, "the credentials file has an empty \"refresh_token\"");
}

test "adc_file: not JSON, a field of the wrong type, or too large" {
    const not_json = "the credentials file is not JSON, or a field that should be a string is not";
    try expectParse("", error.InvalidCredentialsFile, not_json);
    try expectParse("not json", error.InvalidCredentialsFile, not_json);
    try expectParse("[]", error.InvalidCredentialsFile, not_json);
    try expectParse("{\"type\":\"authorized_user\",\"client_id\":42}", error.InvalidCredentialsFile, not_json);
    const huge: [max_file_bytes + 1]u8 = @splat(' ');
    try expectParse(&huge, error.InvalidCredentialsFile, "the credentials file is larger than 64 KiB");
}

test "adc_file: another universe is refused" {
    try expectParse(
        "{\"type\":\"authorized_user\",\"client_id\":\"c\",\"client_secret\":\"SECRET\",\"refresh_token\":\"SECRET\",\"universe_domain\":\"example.com\"}",
        error.UnsupportedCredentialType,
        "the credentials file is for universe \"example.com\"; only googleapis.com is supported",
    );
}

test "adc_file: the quota project is optional, and must not be able to break a header" {
    const base = "\"type\":\"authorized_user\",\"client_id\":\"c\",\"client_secret\":\"s\",\"refresh_token\":\"r\"";
    const without: AuthorizedUser = .{ .client_id = "c", .client_secret = "s", .refresh_token = "r", .quota_project_id = null };
    try expectParse("{" ++ base ++ "}", without, null);
    try expectParse("{" ++ base ++ ",\"quota_project_id\":\"\"}", without, null);
    try expectParse("{" ++ base ++ ",\"quota_project_id\":\"p\\r\\nX-Injected: 1\"}", error.InvalidCredentialsFile, "the credentials file's \"quota_project_id\" is not a project id");
}

fn arbitraryProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Total: a value or an error, and a value always has what a refresh needs.
    const got = parse(arena.allocator(), input, null) catch return;
    try testing.expect(got.client_id.len > 0 and got.client_secret.len > 0 and got.refresh_token.len > 0);
    if (got.quota_project_id) |q| try testing.expect(core.TokenProvider.isValidToken(q));
}

test "fuzz adc_file: arbitrary input never crashes" {
    try test_util.fuzzBytes({}, arbitraryProperty, .{ .corpus = &.{
        "{\"type\":\"authorized_user\",\"client_id\":\"c\",\"client_secret\":\"s\",\"refresh_token\":\"r\"}",
        "{\"type\":\"authorized_user\",\"type\":\"service_account\"}",
        "{\"type\":null}",
    } });
}

/// Each field of a generated file: absent, empty, or with a value.
const Presence = enum { absent, empty, value };

fn structuredProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: test_util.ByteGen = .init(input);

    const kind = g.pick([]const u8, &.{ "authorized_user", "authorized_user", "service_account", "external_account", "banana", "" });
    const has_type = g.boolean();
    const fields = [_][]const u8{ "client_id", "client_secret", "refresh_token" };
    var presence: [fields.len]Presence = undefined;
    for (&presence) |*p| p.* = g.pick(Presence, &.{ .absent, .empty, .value, .value });
    const universe = g.pick(?[]const u8, &.{ null, "googleapis.com", "example.com" });
    const quota = g.pick(?[]const u8, &.{ null, "", "my-project", "p\r\nX: y" });
    var value_buf: [48]u8 = undefined;
    const value = g.utf8(&value_buf, 48);

    // The file, written the way std.json writes JSON.
    var out: std.Io.Writer.Allocating = .init(a);
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try json.beginObject();
    if (has_type) {
        try json.objectField("type");
        try json.write(kind);
    }
    for (fields, presence) |name, p| if (p != .absent) {
        try json.objectField(name);
        try json.write(if (p == .empty) "" else if (value.len > 0) value else "v");
    };
    if (universe) |u| {
        try json.objectField("universe_domain");
        try json.write(u);
    }
    if (quota) |q| {
        try json.objectField("quota_project_id");
        try json.write(q);
    }
    try json.endObject();

    // The rules, in the order parse applies them.
    const want: Error!void = if (!has_type)
        error.InvalidCredentialsFile
    else if (!std.mem.eql(u8, kind, "authorized_user"))
        error.UnsupportedCredentialType
    else if (universe != null and !std.mem.eql(u8, universe.?, "googleapis.com"))
        error.UnsupportedCredentialType
    else if (quota != null and quota.?.len > 0 and !core.TokenProvider.isValidToken(quota.?))
        error.InvalidCredentialsFile
    else for (presence) |p| {
        if (p != .value) break error.InvalidCredentialsFile;
    } else {};

    const got = parse(a, out.written(), null);
    if (want) |_| {
        const file = try got;
        try testing.expectEqualStrings(if (value.len > 0) value else "v", file.refresh_token);
    } else |err| {
        try testing.expectError(err, got);
    }
}

test "fuzz adc_file: generated files meet the rules" {
    try test_util.fuzzBytes({}, structuredProperty, .{});
}
