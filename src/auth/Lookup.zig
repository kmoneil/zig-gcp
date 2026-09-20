//! Where to look for credentials, as the environment describes it. This is
//! the only place that knows variable names and per-OS paths.
//!
//! It holds plain strings rather than the environment itself, so tests fill
//! it by hand and `findDefault` never reads a variable of its own.

const Lookup = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const core = @import("core");

/// `GOOGLE_APPLICATION_CREDENTIALS`: a credentials file to use, and the
/// first thing tried. Naming a file that cannot be used is an error, never
/// a reason to fall through to another source.
credentials_path: ?[]const u8 = null,
/// The directory holding `application_default_credentials.json`, which
/// `gcloud auth application-default login` writes.
gcloud_config_dir: ?[]const u8 = null,
/// `GCE_METADATA_HOST`: where the metadata server is, for hosts whose DNS
/// does not resolve the usual name.
metadata_host: ?[]const u8 = null,
/// `GOOGLE_CLOUD_QUOTA_PROJECT`: the project to charge for quota, whatever
/// the credentials themselves name.
quota_project: ?[]const u8 = null,
/// Filled with what was tried, and why each source was skipped.
diagnostics: ?*core.Diagnostics = null,

/// The file gcloud's login writes, inside `gcloud_config_dir`.
pub const adc_file_name = "application_default_credentials.json";

/// The environment variables this reads. Which ones matter, and what they
/// mean, is the same everywhere; only the fallback path differs.
pub const Vars = struct {
    google_application_credentials: ?[]const u8 = null,
    /// Moves the whole gcloud configuration, including the login file.
    cloudsdk_config: ?[]const u8 = null,
    home: ?[]const u8 = null,
    appdata: ?[]const u8 = null,
    gce_metadata_host: ?[]const u8 = null,
    google_cloud_quota_project: ?[]const u8 = null,
};

/// Which platform's paths to use. `fromEnv` uses the host's, and tests use
/// both on whichever machine they run on.
pub const Platform = enum {
    posix,
    windows,

    pub const host: Platform = if (builtin.os.tag == .windows) .windows else .posix;

    fn sep(p: Platform) u8 {
        return switch (p) {
            .posix => '/',
            .windows => '\\',
        };
    }
};

/// Reads the variables from the environment `main` received, the same
/// shape `pubsub.Endpoint.fromEnv` takes. Every string it keeps is copied
/// into `arena`, which must outlive the lookup.
pub fn fromEnv(environ: *const std.process.Environ.Map, arena: Allocator) Allocator.Error!Lookup {
    return fromVars(.{
        .google_application_credentials = environ.get("GOOGLE_APPLICATION_CREDENTIALS"),
        .cloudsdk_config = environ.get("CLOUDSDK_CONFIG"),
        .home = environ.get("HOME"),
        .appdata = environ.get("APPDATA"),
        .gce_metadata_host = environ.get("GCE_METADATA_HOST"),
        .google_cloud_quota_project = environ.get("GOOGLE_CLOUD_QUOTA_PROJECT"),
    }, .host, arena);
}

/// The lookup a process with these variables would use. An empty variable
/// counts as unset, as it does in Google's own libraries: an exported but
/// empty `GOOGLE_APPLICATION_CREDENTIALS` should not stop a program dead.
pub fn fromVars(vars: Vars, platform: Platform, arena: Allocator) Allocator.Error!Lookup {
    return .{
        .credentials_path = try dupeIfSet(arena, vars.google_application_credentials),
        .gcloud_config_dir = try gcloudConfigDir(vars, platform, arena),
        .metadata_host = try dupeIfSet(arena, vars.gce_metadata_host),
        .quota_project = try dupeIfSet(arena, vars.google_cloud_quota_project),
    };
}

/// The path of the file gcloud's login writes, or null when there is no
/// directory to look in. Caller owns the result.
pub fn gcloudAdcPath(self: Lookup, gpa: Allocator) Allocator.Error!?[]u8 {
    const dir = self.gcloud_config_dir orelse return null;
    return try join(gpa, dir, adc_file_name, Platform.host);
}

fn gcloudConfigDir(vars: Vars, platform: Platform, arena: Allocator) Allocator.Error!?[]const u8 {
    // An explicit CLOUDSDK_CONFIG moves the whole configuration, file included.
    if (try dupeIfSet(arena, vars.cloudsdk_config)) |dir| return dir;
    return switch (platform) {
        .windows => if (nonEmpty(vars.appdata)) |appdata|
            try join(arena, appdata, "gcloud", platform)
        else
            null,
        .posix => if (nonEmpty(vars.home)) |home|
            try join(arena, home, ".config" ++ [_]u8{Platform.posix.sep()} ++ "gcloud", platform)
        else
            null,
    };
}

/// `dir` and `name`, with exactly one separator between them: a directory
/// that already ends in one, `/` included, does not get a second.
fn join(arena: Allocator, dir: []const u8, name: []const u8, platform: Platform) Allocator.Error![]u8 {
    const ends_in_sep = dir.len > 0 and (dir[dir.len - 1] == '/' or dir[dir.len - 1] == '\\');
    const sep: []const u8 = if (ends_in_sep) "" else &.{platform.sep()};
    const buf = try arena.alloc(u8, dir.len + sep.len + name.len);
    @memcpy(buf[0..dir.len], dir);
    @memcpy(buf[dir.len..][0..sep.len], sep);
    @memcpy(buf[dir.len + sep.len ..], name);
    return buf;
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

fn dupeIfSet(arena: Allocator, value: ?[]const u8) Allocator.Error!?[]const u8 {
    const v = nonEmpty(value) orelse return null;
    return try arena.dupe(u8, v);
}

const testing = std.testing;
const test_util = core.testing;

test "Lookup: the gcloud file lives under HOME on posix and APPDATA on Windows" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const posix = try fromVars(.{ .home = "/home/kevin" }, .posix, a);
    try testing.expectEqualStrings("/home/kevin/.config/gcloud", posix.gcloud_config_dir.?);
    try testing.expectEqualStrings(
        "/home/kevin/.config/gcloud" ++ [_]u8{std.fs.path.sep} ++ "application_default_credentials.json",
        (try posix.gcloudAdcPath(a)).?,
    );

    const windows = try fromVars(.{ .appdata = "C:\\Users\\kevin\\AppData\\Roaming" }, .windows, a);
    try testing.expectEqualStrings("C:\\Users\\kevin\\AppData\\Roaming\\gcloud", windows.gcloud_config_dir.?);

    // Each platform reads only its own variable.
    try testing.expectEqual(null, (try fromVars(.{ .appdata = "C:\\x" }, .posix, a)).gcloud_config_dir);
    try testing.expectEqual(null, (try fromVars(.{ .home = "/home/kevin" }, .windows, a)).gcloud_config_dir);
    // With neither, there is nowhere to look.
    try testing.expectEqual(null, (try fromVars(.{}, .posix, a)).gcloud_config_dir);
    try testing.expectEqual(null, (try fromVars(.{}, .windows, a)).gcloudAdcPath(a));
}

test "Lookup: CLOUDSDK_CONFIG moves the gcloud directory on either platform" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const vars: Vars = .{ .cloudsdk_config = "/opt/gcloud-config", .home = "/home/kevin", .appdata = "C:\\x" };
    try testing.expectEqualStrings("/opt/gcloud-config", (try fromVars(vars, .posix, a)).gcloud_config_dir.?);
    try testing.expectEqualStrings("/opt/gcloud-config", (try fromVars(vars, .windows, a)).gcloud_config_dir.?);
}

test "Lookup: a trailing separator does not double up" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/home/kevin/.config/gcloud", (try fromVars(.{ .home = "/home/kevin/" }, .posix, a)).gcloud_config_dir.?);
    try testing.expectEqualStrings("C:\\Roaming\\gcloud", (try fromVars(.{ .appdata = "C:\\Roaming\\" }, .windows, a)).gcloud_config_dir.?);
    // A lone root keeps its separator: "/" is not "".
    try testing.expectEqualStrings("/.config/gcloud", (try fromVars(.{ .home = "/" }, .posix, a)).gcloud_config_dir.?);
}

test "Lookup: an empty variable counts as unset" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try fromVars(.{
        .google_application_credentials = "",
        .cloudsdk_config = "",
        .home = "",
        .gce_metadata_host = "",
        .google_cloud_quota_project = "",
    }, .posix, a);
    try testing.expectEqual(null, l.credentials_path);
    try testing.expectEqual(null, l.gcloud_config_dir);
    try testing.expectEqual(null, l.metadata_host);
    try testing.expectEqual(null, l.quota_project);
}

test "Lookup: every variable it reads" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try fromVars(.{
        .google_application_credentials = "/keys/adc.json",
        .home = "/home/kevin",
        .gce_metadata_host = "169.254.169.254",
        .google_cloud_quota_project = "billing-project",
    }, .posix, a);
    try testing.expectEqualStrings("/keys/adc.json", l.credentials_path.?);
    try testing.expectEqualStrings("/home/kevin/.config/gcloud", l.gcloud_config_dir.?);
    try testing.expectEqualStrings("169.254.169.254", l.metadata_host.?);
    try testing.expectEqualStrings("billing-project", l.quota_project.?);
}

test "Lookup: the strings are copies, not views of the environment" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var home: [11]u8 = "/home/kevin".*;
    const l = try fromVars(.{ .home = &home }, .posix, arena.allocator());
    @memset(&home, 'x');
    try testing.expectEqualStrings("/home/kevin/.config/gcloud", l.gcloud_config_dir.?);
}

test "Lookup: fromEnv reads this process's environment" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var map = try testing.environ.createMap(testing.allocator);
    defer map.deinit();
    const l = try fromEnv(&map, a);

    if (map.get("GOOGLE_APPLICATION_CREDENTIALS")) |path| {
        if (path.len > 0) try testing.expectEqualStrings(path, l.credentials_path.?);
    } else {
        try testing.expectEqual(null, l.credentials_path);
    }
    const home_var = if (Platform.host == .windows) "APPDATA" else "HOME";
    if (map.get(home_var)) |home| {
        if (home.len > 0) {
            try testing.expect(std.mem.startsWith(u8, l.gcloud_config_dir.?, home));
            try testing.expect(std.mem.endsWith(u8, l.gcloud_config_dir.?, "gcloud"));
        }
    }
}

test "Lookup: every allocation failure while reading the environment is OutOfMemory" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var map = try testing.environ.createMap(gpa);
            defer map.deinit();
            _ = try fromEnv(&map, arena.allocator());
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{});
}

fn varsProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: test_util.ByteGen = .init(input);
    const platform = g.pick(Platform, &.{ .posix, .windows });
    const home = g.slice(64);
    const l = try fromVars(.{ .home = home, .appdata = home }, platform, a);
    // Whatever the variable holds, the directory stays under it and ends in
    // the gcloud one: no input can send the lookup somewhere else.
    if (l.gcloud_config_dir) |dir| {
        try testing.expect(std.mem.startsWith(u8, dir, std.mem.trimEnd(u8, home, "/\\")));
        try testing.expect(std.mem.endsWith(u8, dir, "gcloud"));
        const path = (try l.gcloudAdcPath(a)).?;
        try testing.expect(std.mem.startsWith(u8, path, dir));
        try testing.expect(std.mem.endsWith(u8, path, adc_file_name));
    } else {
        try testing.expectEqual(0, home.len);
    }
}

test "fuzz Lookup: the gcloud path stays under the directory it was given" {
    try test_util.fuzzBytes({}, varsProperty, .{ .corpus = &.{
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x0b/home/kevin",
        "\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x03C:\\",
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
    } });
}
