//! Credential files: the one `GOOGLE_APPLICATION_CREDENTIALS` names, and the
//! one `gcloud auth application-default login` writes. This version reads
//! files of type `authorized_user` and `service_account`, and refuses every
//! other type by name.

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
    /// A type other than `authorized_user` or `service_account`, or a
    /// universe other than googleapis.com.
    UnsupportedCredentialType,
    OutOfMemory,
};

/// Whichever credential the file holds. Fields point into the arena passed
/// to `parse` or into the JSON text, and the secrets among them need wiping.
pub const Credential = union(enum) {
    authorized_user: AuthorizedUser,
    service_account: ServiceAccount,
};

/// An `authorized_user` file's fields.
pub const AuthorizedUser = struct {
    client_id: []const u8,
    client_secret: []const u8,
    refresh_token: []const u8,
    /// The project to charge for quota, when the file names one.
    quota_project_id: ?[]const u8,
};

/// A `service_account` key file's fields.
pub const ServiceAccount = struct {
    client_email: []const u8,
    /// The PEM private key, exactly as the file carries it. Secret.
    private_key: []const u8,
    /// Names the key among the account's keys; sent as the JWT's `kid`.
    private_key_id: ?[]const u8,
    /// The token endpoint the file names, or null for Google's default.
    token_uri: ?[]const u8,
    /// The project the service account lives in.
    project_id: ?[]const u8,
    quota_project_id: ?[]const u8,
};

const Wire = struct {
    type: ?[]const u8 = null,
    client_id: ?[]const u8 = null,
    client_secret: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
    client_email: ?[]const u8 = null,
    private_key: ?[]const u8 = null,
    private_key_id: ?[]const u8 = null,
    token_uri: ?[]const u8 = null,
    project_id: ?[]const u8 = null,
    quota_project_id: ?[]const u8 = null,
    universe_domain: ?[]const u8 = null,
};

/// Types this version recognizes, and why it refuses them.
const refused = std.StaticStringMap([]const u8).initComptime(.{
    .{ "impersonated_service_account", "impersonated service accounts are not supported yet" },
    .{ "external_account", "workload identity federation is not supported" },
    .{ "external_account_authorized_user", "workforce identity federation is not supported" },
});

/// Reads an `authorized_user` or `service_account` file. Failures say why
/// in `diag`, which never repeats a secret.
pub fn parse(arena: Allocator, json: []const u8, diag: ?*Diagnostics) Error!Credential {
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
    const known = std.mem.eql(u8, kind, "authorized_user") or std.mem.eql(u8, kind, "service_account");
    if (!known) {
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
    if (std.mem.eql(u8, kind, "service_account")) return .{ .service_account = .{
        .client_email = try required(wire.client_email, "client_email", diag),
        .private_key = try required(wire.private_key, "private_key", diag),
        .private_key_id = emptyToNull(wire.private_key_id),
        .token_uri = emptyToNull(wire.token_uri),
        .project_id = emptyToNull(wire.project_id),
        .quota_project_id = quota,
    } };
    return .{ .authorized_user = .{
        .client_id = try required(wire.client_id, "client_id", diag),
        .client_secret = try required(wire.client_secret, "client_secret", diag),
        .refresh_token = try required(wire.refresh_token, "refresh_token", diag),
        .quota_project_id = quota,
    } };
}

fn emptyToNull(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

pub const ReadError = error{ CredentialsFileNotFound, InvalidCredentialsFile, Canceled, OutOfMemory };

/// Reads the credentials file at `path` into `arena`, which should wipe:
/// the contents hold a secret whichever type the file is.
pub fn readFile(io: std.Io, arena: Allocator, path: []const u8, diag: ?*Diagnostics) ReadError![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        error.StreamTooLong => {
            if (diag) |d| d.print("the credentials file is larger than 64 KiB", .{});
            return error.InvalidCredentialsFile;
        },
        else => {
            if (diag) |d| d.print("cannot read the credentials file {s}: {t}", .{ path, err });
            return error.CredentialsFileNotFound;
        },
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
        const g = switch (try got) {
            .authorized_user => |u| u,
            .service_account => return error.TestWrongCredentialType,
        };
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

fn expectOptional(want: ?[]const u8, got: ?[]const u8) !void {
    if (want) |w| try testing.expectEqualStrings(w, got.?) else try testing.expectEqual(null, got);
}

fn expectServiceAccount(json: []const u8, want: Error!ServiceAccount, message: ?[]const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostics = .{};
    const got = parse(arena.allocator(), json, &diag);
    if (want) |w| {
        const g = switch (try got) {
            .service_account => |sa| sa,
            .authorized_user => return error.TestWrongCredentialType,
        };
        try testing.expectEqualStrings(w.client_email, g.client_email);
        try testing.expectEqualStrings(w.private_key, g.private_key);
        try expectOptional(w.private_key_id, g.private_key_id);
        try expectOptional(w.token_uri, g.token_uri);
        try expectOptional(w.project_id, g.project_id);
        try expectOptional(w.quota_project_id, g.quota_project_id);
    } else |err| {
        try testing.expectError(err, got);
        if (message) |m| try testing.expectEqualStrings(m, diag.message());
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

test "adc_file: a service_account key file, with the fields Google writes" {
    try expectServiceAccount(
        \\{"type": "service_account", "project_id": "my-project",
        \\ "private_key_id": "1b2f3a", "private_key": "-----BEGIN PRIVATE KEY-----\nSECRET\n-----END PRIVATE KEY-----\n",
        \\ "client_email": "robot@my-project.iam.gserviceaccount.com", "client_id": "1234",
        \\ "auth_uri": "https://accounts.google.com/o/oauth2/auth",
        \\ "token_uri": "https://oauth2.googleapis.com/token",
        \\ "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
        \\ "universe_domain": "googleapis.com"}
    , .{
        .client_email = "robot@my-project.iam.gserviceaccount.com",
        .private_key = "-----BEGIN PRIVATE KEY-----\nSECRET\n-----END PRIVATE KEY-----\n",
        .private_key_id = "1b2f3a",
        .token_uri = "https://oauth2.googleapis.com/token",
        .project_id = "my-project",
        .quota_project_id = null,
    }, null);
}

test "adc_file: a service_account file needs only its email and key" {
    const base = "\"client_email\":\"e@p.iam.gserviceaccount.com\",\"private_key\":\"SECRET-pem\"";
    try expectServiceAccount("{\"type\":\"service_account\"," ++ base ++ "}", .{
        .client_email = "e@p.iam.gserviceaccount.com",
        .private_key = "SECRET-pem",
        .private_key_id = null,
        .token_uri = null,
        .project_id = null,
        .quota_project_id = null,
    }, null);
    // Empty optional fields mean the same as absent ones.
    try expectServiceAccount("{\"type\":\"service_account\"," ++ base ++ ",\"private_key_id\":\"\",\"token_uri\":\"\",\"project_id\":\"\",\"quota_project_id\":\"\"}", .{
        .client_email = "e@p.iam.gserviceaccount.com",
        .private_key = "SECRET-pem",
        .private_key_id = null,
        .token_uri = null,
        .project_id = null,
        .quota_project_id = null,
    }, null);
    try expectServiceAccount("{\"type\":\"service_account\",\"private_key\":\"SECRET-pem\"}", error.InvalidCredentialsFile, "the credentials file lacks \"client_email\"");
    try expectServiceAccount("{\"type\":\"service_account\",\"client_email\":\"e@p\"}", error.InvalidCredentialsFile, "the credentials file lacks \"private_key\"");
    try expectServiceAccount("{\"type\":\"service_account\",\"client_email\":\"e@p\",\"private_key\":\"\"}", error.InvalidCredentialsFile, "the credentials file has an empty \"private_key\"");
}

test "adc_file: every other type is refused by name" {
    const base = "\"client_id\":\"c\",\"client_secret\":\"SECRET\",\"refresh_token\":\"SECRET\"";
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
    // Total: a value or an error, and a value always has what its provider needs.
    const got = parse(arena.allocator(), input, null) catch return;
    switch (got) {
        .authorized_user => |u| {
            try testing.expect(u.client_id.len > 0 and u.client_secret.len > 0 and u.refresh_token.len > 0);
            if (u.quota_project_id) |q| try testing.expect(core.TokenProvider.isValidToken(q));
        },
        .service_account => |sa| {
            try testing.expect(sa.client_email.len > 0 and sa.private_key.len > 0);
            if (sa.quota_project_id) |q| try testing.expect(core.TokenProvider.isValidToken(q));
        },
    }
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

    const kind = g.pick([]const u8, &.{ "authorized_user", "authorized_user", "service_account", "service_account", "external_account", "banana", "" });
    const has_type = g.boolean();
    const user_fields = [_][]const u8{ "client_id", "client_secret", "refresh_token" };
    const sa_fields = [_][]const u8{ "client_email", "private_key" };
    const fields: []const []const u8 = if (std.mem.eql(u8, kind, "service_account")) &sa_fields else &user_fields;
    var presence_buf: [user_fields.len]Presence = undefined;
    const presence = presence_buf[0..fields.len];
    for (presence) |*p| p.* = g.pick(Presence, &.{ .absent, .empty, .value, .value });
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
    const known = std.mem.eql(u8, kind, "authorized_user") or std.mem.eql(u8, kind, "service_account");
    const want: Error!void = if (!has_type)
        error.InvalidCredentialsFile
    else if (!known)
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
        try testing.expectEqualStrings(kind, @tagName(file));
        const secret = switch (file) {
            .authorized_user => |u| u.refresh_token,
            .service_account => |sa| sa.private_key,
        };
        try testing.expectEqualStrings(if (value.len > 0) value else "v", secret);
    } else |err| {
        try testing.expectError(err, got);
    }
}

test "fuzz adc_file: generated files meet the rules" {
    try test_util.fuzzBytes({}, structuredProperty, .{});
}
