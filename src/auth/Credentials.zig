//! Whichever credentials the environment points at, and where they came
//! from. `findDefault` checks the three places Google documents, in order,
//! and the first one that has something decides the outcome.
//!
//! A credential that is named but unusable stops the search. Falling
//! through would run the program as somebody else, quietly, which is worse
//! than an error that says what went wrong.

const Credentials = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const core = @import("core");
const TokenProvider = core.TokenProvider;
const Diagnostics = core.Diagnostics;
const Transport = core.transport.Transport;
const AuthorizedUser = @import("AuthorizedUser.zig");
const Cache = @import("Cache.zig");
const Lookup = @import("Lookup.zig");
const MetadataServer = @import("MetadataServer.zig");
const ExternalAccount = @import("ExternalAccount.zig");
const ImpersonatedServiceAccount = @import("ImpersonatedServiceAccount.zig");
const ServiceAccount = @import("ServiceAccount.zig");
const adc_file = @import("adc_file.zig");
const logging = @import("logging.zig");

gpa: Allocator,
/// Where these credentials came from, which is the first question in any
/// authentication bug. Worth logging at startup.
source: Source,
/// The provider lives on the heap, so this struct can be moved.
held: *Held,

pub const Source = enum {
    /// The file `GOOGLE_APPLICATION_CREDENTIALS` names.
    env_file,
    /// The file `gcloud auth application-default login` writes.
    gcloud_file,
    /// The service account attached to this workload.
    metadata_server,

    pub fn description(self: Source) []const u8 {
        return switch (self) {
            .env_file => "the file GOOGLE_APPLICATION_CREDENTIALS names",
            .gcloud_file => "gcloud's application-default login",
            .metadata_server => "the metadata server",
        };
    }
};

pub const Options = struct {
    cache: Cache.Options = .{},
    retry: core.RetryPolicy = .{ .max_attempts = 3 },
    /// How long one request for a token may take before it is
    /// `error.TimedOut`. 0 removes the limit.
    request_timeout_ms: u32 = 30_000,
    /// Printable ASCII.
    user_agent: []const u8 = "zig-gcp-auth/0.12",
    /// How long to wait for a metadata server before deciding there is
    /// none. One attempt, not three: a machine without one should reach
    /// `NoCredentialsFound` in about a second.
    probe_timeout_ms: u32 = 500,
    /// Sends every request through this instead of `std.http.Client`.
    transport: ?Transport = null,
};

pub const Error = error{
    /// Nothing named a credential, and no metadata server answered.
    NoCredentialsFound,
    /// A named credentials file is missing or cannot be read.
    CredentialsFileNotFound,
    InvalidCredentialsFile,
    UnsupportedCredentialType,
    /// A quota project, user agent, retry policy or cache setting that
    /// cannot be used.
    InvalidOptions,
    Canceled,
    OutOfMemory,
};

/// The credentials this environment points at. In order: the file
/// `GOOGLE_APPLICATION_CREDENTIALS` names, the file gcloud's login writes,
/// then the metadata server.
pub fn find(gpa: Allocator, io: std.Io, lookup: Lookup, options: Options) Error!Credentials {
    const diag = lookup.diagnostics;
    if (diag) |d| d.clear();
    if (lookup.quota_project) |q| if (!TokenProvider.isValidToken(q)) {
        if (diag) |d| d.print("invalid quota project: it is sent as a header, so it must be visible ASCII", .{});
        return error.InvalidOptions;
    };

    // 1. The file the environment names, if it names one.
    if (lookup.credentials_path) |path| {
        logging.debug("credentials: GOOGLE_APPLICATION_CREDENTIALS names {s}", .{path});
        var impl = try fromFile(gpa, io, path, lookup, options);
        errdefer implDeinit(&impl);
        return hold(gpa, .env_file, impl, lookup);
    }

    // 2. The file gcloud's login writes, if it is there.
    var no_gcloud_file: []const u8 = "neither CLOUDSDK_CONFIG nor HOME is set";
    const gcloud_path = try lookup.gcloudAdcPath(gpa);
    defer if (gcloud_path) |p| gpa.free(p);
    if (gcloud_path) |path| {
        if (std.Io.Dir.cwd().access(io, path, .{})) {
            logging.debug("credentials: reading {s}", .{path});
            var impl = try fromFile(gpa, io, path, lookup, options);
            errdefer implDeinit(&impl);
            return hold(gpa, .gcloud_file, impl, lookup);
        } else |err| switch (err) {
            error.FileNotFound => no_gcloud_file = "no file from gcloud's login",
            error.Canceled => return error.Canceled,
            else => {
                // The file is there and cannot be read. Carrying on as
                // whoever else the machine offers would be worse.
                if (diag) |d| d.print("cannot read {s}: {t}", .{ path, err });
                return error.CredentialsFileNotFound;
            },
        }
    }

    // 3. The metadata server, if one answers.
    const metadata_options = metadataOptions(lookup, options);
    var metadata: MetadataServer = try .init(gpa, io, metadata_options);
    // Running out of memory or being canceled says nothing about where
    // this is running, so neither turns into "no credentials".
    const answered = metadata.probeChecked(io) catch |err| {
        metadata.deinit();
        return err;
    };
    if (answered) {
        errdefer metadata.deinit();
        return hold(gpa, .metadata_server, .{ .metadata = metadata }, lookup);
    }
    metadata.deinit();

    if (diag) |d| d.print("no credentials: GOOGLE_APPLICATION_CREDENTIALS is not set, {s}, and no metadata server answered on {s}", .{
        no_gcloud_file, metadata_options.host,
    });
    logging.warn("no credentials found in any of the three places", .{});
    return error.NoCredentialsFound;
}

/// A token from whichever source was found. The provider points into the
/// heap, so it stays valid when this struct is moved or copied.
pub fn provider(self: Credentials) TokenProvider {
    return self.held.provider();
}

/// The project to charge for quota: `GOOGLE_CLOUD_QUOTA_PROJECT` if it was
/// set, otherwise whatever the credentials name.
pub fn quotaProjectId(self: Credentials) ?[]const u8 {
    return self.held.provider().quotaProject();
}

/// The project this workload runs in, when the credentials can say: the
/// metadata server knows, and a service account key file names the project
/// it belongs to; a user login does not. Copied into `arena`. This saves a
/// program from being told where it is running.
pub fn projectId(self: Credentials, io: std.Io, arena: Allocator) MetadataServer.ProjectIdError!?[]const u8 {
    return switch (self.held.impl) {
        .user, .external_account, .impersonated => null,
        .service_account => |*account| if (account.projectId()) |p| try arena.dupe(u8, p) else null,
        .metadata => |*metadata| try metadata.projectId(io, arena),
    };
}

pub fn deinit(self: *Credentials) void {
    self.held.deinit(self.gpa);
    self.gpa.destroy(self.held);
    self.* = undefined;
}

/// The provider `find` built, on the heap so `Credentials` stays movable,
/// with the quota project the environment asked for.
const Held = struct {
    impl: Impl,
    /// `GOOGLE_CLOUD_QUOTA_PROJECT`, which wins over the credential's own.
    quota_project: ?[]u8,

    const Impl = union(enum) {
        user: AuthorizedUser,
        service_account: ServiceAccount,
        external_account: ExternalAccount,
        impersonated: ImpersonatedServiceAccount,
        metadata: MetadataServer,
    };

    fn provider(self: *Held) TokenProvider {
        return .{ .ptr = self, .vtable = &.{
            .getToken = getToken,
            .invalidate = invalidate,
            .quotaProject = quotaProject,
        } };
    }

    fn inner(self: *Held) TokenProvider {
        return switch (self.impl) {
            .user => |*u| u.provider(),
            .service_account => |*s| s.provider(),
            .external_account => |*e| e.provider(),
            .impersonated => |*i| i.provider(),
            .metadata => |*m| m.provider(),
        };
    }

    fn deinit(self: *Held, gpa: Allocator) void {
        switch (self.impl) {
            .user => |*u| u.deinit(),
            .service_account => |*s| s.deinit(),
            .external_account => |*e| e.deinit(),
            .impersonated => |*i| i.deinit(),
            .metadata => |*m| m.deinit(),
        }
        if (self.quota_project) |q| gpa.free(q);
        self.* = undefined;
    }

    fn fromPtr(ptr: *anyopaque) *Held {
        return @ptrCast(@alignCast(ptr));
    }

    fn getToken(ptr: *anyopaque, io: std.Io, arena: Allocator, scopes: []const []const u8) TokenProvider.Error![]const u8 {
        return fromPtr(ptr).inner().getToken(io, arena, scopes);
    }

    fn invalidate(ptr: *anyopaque) void {
        fromPtr(ptr).inner().invalidate();
    }

    fn quotaProject(ptr: *anyopaque) ?[]const u8 {
        const self = fromPtr(ptr);
        if (self.quota_project) |q| return q;
        return self.inner().quotaProject();
    }
};

fn hold(gpa: Allocator, source: Source, impl: Held.Impl, lookup: Lookup) Allocator.Error!Credentials {
    const held = try gpa.create(Held);
    errdefer gpa.destroy(held);
    held.* = .{
        .impl = impl,
        .quota_project = if (lookup.quota_project) |q| try gpa.dupe(u8, q) else null,
    };
    logging.debug("credentials: using {s}", .{source.description()});
    return .{ .gpa = gpa, .source = source, .held = held };
}

/// Reads the credentials file at `path` and builds the provider its
/// declared type calls for.
fn fromFile(gpa: Allocator, io: std.Io, path: []const u8, lookup: Lookup, options: Options) Error!Held.Impl {
    const diag = lookup.diagnostics;
    // The file holds a secret whichever type it is; the parse here only
    // decides the type, and the provider's own init reads `json` again.
    var wiping: core.WipingAllocator = .init(gpa);
    var scratch: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer scratch.deinit();
    const json = try adc_file.readFile(io, scratch.allocator(), path, diag);
    return switch (try adc_file.parse(scratch.allocator(), json, diag)) {
        .authorized_user => .{ .user = try AuthorizedUser.initFromJson(gpa, io, json, userOptions(lookup, options)) },
        .service_account => .{ .service_account = try ServiceAccount.initFromJson(gpa, io, json, serviceOptions(lookup, options)) },
        .external_account => .{ .external_account = try ExternalAccount.initFromJson(gpa, io, json, externalOptions(lookup, options)) },
        .impersonated_service_account => .{ .impersonated = try ImpersonatedServiceAccount.initFromJson(gpa, io, json, impersonatedOptions(lookup, options)) },
    };
}

fn implDeinit(impl: *Held.Impl) void {
    switch (impl.*) {
        .user => |*u| u.deinit(),
        .service_account => |*s| s.deinit(),
        .external_account => |*e| e.deinit(),
        .impersonated => |*i| i.deinit(),
        .metadata => |*m| m.deinit(),
    }
}

fn impersonatedOptions(lookup: Lookup, options: Options) ImpersonatedServiceAccount.Options {
    return .{
        .retry = options.retry,
        .cache = options.cache,
        .user_agent = options.user_agent,
        .request_timeout_ms = options.request_timeout_ms,
        .diagnostics = lookup.diagnostics,
        .transport = options.transport,
    };
}

fn userOptions(lookup: Lookup, options: Options) AuthorizedUser.Options {
    return .{
        .retry = options.retry,
        .cache = options.cache,
        .user_agent = options.user_agent,
        .request_timeout_ms = options.request_timeout_ms,
        .diagnostics = lookup.diagnostics,
        .transport = options.transport,
    };
}

fn externalOptions(lookup: Lookup, options: Options) ExternalAccount.Options {
    return .{
        .retry = options.retry,
        .cache = options.cache,
        .user_agent = options.user_agent,
        .request_timeout_ms = options.request_timeout_ms,
        .diagnostics = lookup.diagnostics,
        .transport = options.transport,
    };
}

fn serviceOptions(lookup: Lookup, options: Options) ServiceAccount.Options {
    return .{
        .retry = options.retry,
        .cache = options.cache,
        .user_agent = options.user_agent,
        .request_timeout_ms = options.request_timeout_ms,
        .diagnostics = lookup.diagnostics,
        .transport = options.transport,
    };
}

fn metadataOptions(lookup: Lookup, options: Options) MetadataServer.Options {
    var opts: MetadataServer.Options = .{
        .probe_timeout_ms = options.probe_timeout_ms,
        .request_timeout_ms = options.request_timeout_ms,
        .retry = options.retry,
        .cache = options.cache,
        .user_agent = options.user_agent,
        .diagnostics = lookup.diagnostics,
        .transport = options.transport,
    };
    if (lookup.metadata_host) |host| opts.host = host;
    return opts;
}

const testing = std.testing;
const test_util = core.testing;
const Reply = test_util.FakeTransport.Reply;

const gcloud_json =
    \\{"type": "authorized_user", "client_id": "gcloud.apps.googleusercontent.com",
    \\ "client_secret": "SECRET-gcloud", "refresh_token": "1//SECRET-gcloud",
    \\ "quota_project_id": "gcloud-project"}
;
const env_json =
    \\{"type": "authorized_user", "client_id": "env.apps.googleusercontent.com",
    \\ "client_secret": "SECRET-env", "refresh_token": "1//SECRET-env",
    \\ "quota_project_id": "env-project"}
;
const flavor: []const core.transport.Header = &.{.{ .name = "Metadata-Flavor", .value = "Google" }};
const metadata_listing: Reply = .{ .respond = .{ .body = "computeMetadata/\n", .headers = flavor } };
const metadata_token: Reply = .{ .respond = .{
    .body = "{\"access_token\":\"ya29.from-metadata\",\"expires_in\":3599}",
    .headers = flavor,
} };
const user_token: Reply = .{ .respond = .{ .body = "{\"access_token\":\"ya29.from-file\",\"expires_in\":3599}" } };
const no_metadata: Reply = .{ .fail = error.ConnectionRefused };
const test_scopes: []const []const u8 = &.{"https://www.googleapis.com/auth/cloud-platform"};

/// A temporary directory standing in for the gcloud configuration one.
/// Fixed in place: `dir` points into the struct.
const TmpConfig = struct {
    tmp: testing.TmpDir,
    buf: [128]u8 = undefined,
    dir: []const u8 = "",

    fn init(self: *TmpConfig) !void {
        self.tmp = testing.tmpDir(.{});
        self.dir = try std.fmt.bufPrint(&self.buf, ".zig-cache/tmp/{s}", .{&self.tmp.sub_path});
    }

    /// Writes `contents` as `name`, and returns the path to it.
    fn write(self: *TmpConfig, buf: []u8, name: []const u8, contents: []const u8) ![]const u8 {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = contents });
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.dir, name });
    }

    fn deinit(self: *TmpConfig) void {
        self.tmp.cleanup();
    }
};

test "findDefault: the file GOOGLE_APPLICATION_CREDENTIALS names wins over everything" {
    var config: TmpConfig = undefined;
    try config.init();
    defer config.deinit();
    var env_buf: [160]u8 = undefined;
    const env_path = try config.write(&env_buf, "named.json", env_json);
    // The gcloud file is there too, and a metadata server would answer.
    var gcloud_buf: [160]u8 = undefined;
    _ = try config.write(&gcloud_buf, Lookup.adc_file_name, gcloud_json);
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{ metadata_listing, metadata_token });
    defer fake.deinit();

    var creds = try find(testing.allocator, testing.io, .{
        .credentials_path = env_path,
        .gcloud_config_dir = config.dir,
    }, .{ .transport = fake.transport() });
    defer creds.deinit();
    try testing.expectEqual(.env_file, creds.source);
    try testing.expectEqualStrings("env-project", creds.quotaProjectId().?);
    // Neither the gcloud file nor the metadata server was consulted.
    try testing.expectEqual(0, fake.requests.items.len);
}

test "findDefault: an impersonated file acts as its service account" {
    var config: TmpConfig = undefined;
    try config.init();
    defer config.deinit();
    var env_buf: [160]u8 = undefined;
    const env_path = try config.write(&env_buf, "impersonated.json",
        \\{"type": "impersonated_service_account",
        \\ "service_account_impersonation_url": "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/sa@p.iam.gserviceaccount.com:generateAccessToken",
        \\ "source_credentials": {"type": "authorized_user", "client_id": "c", "client_secret": "SECRET", "refresh_token": "SECRET-refresh"},
        \\ "quota_project_id": "impersonated-billing"}
    );
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        .{ .respond = .{ .body = "{\"access_token\":\"ya29.SOURCE\",\"expires_in\":3599}" } },
        .{ .respond = .{ .body = "{\"accessToken\":\"ya29.AS-THE-ACCOUNT\",\"expireTime\":\"2100-01-01T00:00:00Z\"}" } },
    });
    defer fake.deinit();

    var creds = try find(testing.allocator, testing.io, .{ .credentials_path = env_path }, .{ .transport = fake.transport() });
    defer creds.deinit();
    try testing.expectEqual(.env_file, creds.source);
    try testing.expectEqualStrings("impersonated-billing", creds.quotaProjectId().?);
    // A user login's source knows no project to run in, and neither does this.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(null, try creds.projectId(testing.io, arena.allocator()));
    try testing.expectEqualStrings("ya29.AS-THE-ACCOUNT", try creds.provider().getToken(testing.io, arena.allocator(), &.{"https://www.googleapis.com/auth/pubsub"}));
    try testing.expectEqualStrings("ya29.SOURCE", (try fake.request(1)).bearer.?);
}

test "findDefault: a file the environment names must work, or nothing does" {
    var config: TmpConfig = undefined;
    try config.init();
    defer config.deinit();
    var path_buf: [160]u8 = undefined;
    // The other two sources are available, and must not be reached.
    _ = try config.write(&path_buf, Lookup.adc_file_name, gcloud_json);
    var external_buf: [160]u8 = undefined;
    const external_path = try config.write(&external_buf, "external.json", "{\"type\":\"external_account_authorized_user\"}");
    var partial_buf: [160]u8 = undefined;
    const partial_path = try config.write(&partial_buf, "partial.json", "{\"type\":\"service_account\",\"client_email\":\"e@p\"}");
    var junk_buf: [160]u8 = undefined;
    const junk_path = try config.write(&junk_buf, "junk.json", "not json at all");
    var missing_buf: [160]u8 = undefined;
    const missing_path = try std.fmt.bufPrint(&missing_buf, "{s}/missing.json", .{config.dir});

    const cases: []const struct { path: []const u8, want: anyerror } = &.{
        .{ .path = missing_path, .want = error.CredentialsFileNotFound },
        .{ .path = external_path, .want = error.UnsupportedCredentialType },
        .{ .path = partial_path, .want = error.InvalidCredentialsFile },
        .{ .path = junk_path, .want = error.InvalidCredentialsFile },
    };
    for (cases) |case| {
        var fake: test_util.FakeTransport = .init(testing.allocator, &.{ metadata_listing, metadata_token });
        defer fake.deinit();
        var diag: Diagnostics = .{};
        try testing.expectError(case.want, find(testing.allocator, testing.io, .{
            .credentials_path = case.path,
            .gcloud_config_dir = config.dir,
            .diagnostics = &diag,
        }, .{ .transport = fake.transport() }));
        try testing.expect(diag.message().len > 0);
        try testing.expectEqual(0, fake.requests.items.len);
    }
}

/// A service account key file around one of rsa.zig's test keys, with the
/// PEM's newlines as JSON escapes, the way Google writes one.
fn serviceAccountJson(arena: Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try json.beginObject();
    inline for (.{
        .{ "type", "service_account" },
        .{ "project_id", "sa-project" },
        .{ "private_key_id", "kid-1" },
        .{ "private_key", @import("rsa.zig").test_key_1024 },
        .{ "client_email", "robot@sa-project.iam.gserviceaccount.com" },
        .{ "token_uri", "https://oauth2.googleapis.com/token" },
    }) |field| {
        try json.objectField(field[0]);
        try json.write(field[1]);
    }
    try json.endObject();
    return out.written();
}

test "findDefault: a service account key file works from either file source" {
    var config: TmpConfig = undefined;
    try config.init();
    defer config.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sa_json = try serviceAccountJson(arena.allocator());

    // Named by the environment.
    var env_buf: [160]u8 = undefined;
    const env_path = try config.write(&env_buf, "sa.json", sa_json);
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{user_token});
    defer fake.deinit();
    var creds = try find(testing.allocator, testing.io, .{ .credentials_path = env_path }, .{
        .transport = fake.transport(),
    });
    defer creds.deinit();
    try testing.expectEqual(.env_file, creds.source);
    // The key file says which project it belongs to, with no request.
    try testing.expectEqualStrings("sa-project", (try creds.projectId(testing.io, arena.allocator())).?);
    try testing.expectEqual(null, creds.quotaProjectId());
    // Its token comes from a signed JWT at the token endpoint.
    try testing.expectEqualStrings("ya29.from-file", try creds.provider().getToken(testing.io, arena.allocator(), test_scopes));
    const sent = try fake.request(0);
    try testing.expectEqualStrings("https://oauth2.googleapis.com/token", sent.url);
    try testing.expect(std.mem.startsWith(u8, sent.body.?, "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion="));

    // As gcloud's file, the same key is found second.
    var gcloud_buf: [160]u8 = undefined;
    _ = try config.write(&gcloud_buf, Lookup.adc_file_name, sa_json);
    var second_fake: test_util.FakeTransport = .init(testing.allocator, &.{});
    defer second_fake.deinit();
    var second = try find(testing.allocator, testing.io, .{ .gcloud_config_dir = config.dir }, .{
        .transport = second_fake.transport(),
    });
    defer second.deinit();
    try testing.expectEqual(.gcloud_file, second.source);
}

test "findDefault: a workload identity federation file works from the environment" {
    var config: TmpConfig = undefined;
    try config.init();
    defer config.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // The subject token, where the file's credential source points.
    var subject_buf: [160]u8 = undefined;
    _ = try config.write(&subject_buf, "subject", "external-subject-token");
    const external_json = try std.fmt.allocPrint(arena.allocator(),
        \\{{"type": "external_account",
        \\ "audience": "//iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/providers/x",
        \\ "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
        \\ "token_url": "https://sts.googleapis.com/v1/token",
        \\ "credential_source": {{"file": "{s}/subject"}}}}
    , .{config.dir});
    var env_buf: [160]u8 = undefined;
    const env_path = try config.write(&env_buf, "external.json", external_json);

    var fake: test_util.FakeTransport = .init(testing.allocator, &.{user_token});
    defer fake.deinit();
    var creds = try find(testing.allocator, testing.io, .{ .credentials_path = env_path }, .{
        .transport = fake.transport(),
    });
    defer creds.deinit();
    try testing.expectEqual(.env_file, creds.source);
    try testing.expectEqual(null, try creds.projectId(testing.io, arena.allocator()));
    try testing.expectEqualStrings("ya29.from-file", try creds.provider().getToken(testing.io, arena.allocator(), test_scopes));
    const sent = try fake.request(0);
    try testing.expectEqualStrings("https://sts.googleapis.com/v1/token", sent.url);
    try testing.expect(std.mem.indexOf(u8, sent.body.?, "subject_token=external-subject-token") != null);
}

test "findDefault: gcloud's login file is next, and its token comes from it" {
    var config: TmpConfig = undefined;
    try config.init();
    defer config.deinit();
    var path_buf: [160]u8 = undefined;
    _ = try config.write(&path_buf, Lookup.adc_file_name, gcloud_json);
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{user_token});
    defer fake.deinit();

    var creds = try find(testing.allocator, testing.io, .{ .gcloud_config_dir = config.dir }, .{
        .transport = fake.transport(),
    });
    defer creds.deinit();
    try testing.expectEqual(.gcloud_file, creds.source);
    try testing.expectEqualStrings("gcloud-project", creds.quotaProjectId().?);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("ya29.from-file", try creds.provider().getToken(testing.io, arena.allocator(), test_scopes));
    // A refresh, not a metadata request.
    try testing.expectEqualStrings("https://oauth2.googleapis.com/token", (try fake.request(0)).url);
}

test "findDefault: a gcloud file that is there but broken stops the search" {
    var config: TmpConfig = undefined;
    try config.init();
    defer config.deinit();
    var path_buf: [160]u8 = undefined;
    _ = try config.write(&path_buf, Lookup.adc_file_name, "{\"type\":\"external_account_authorized_user\"}");
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{ metadata_listing, metadata_token });
    defer fake.deinit();
    var diag: Diagnostics = .{};

    try testing.expectError(error.UnsupportedCredentialType, find(testing.allocator, testing.io, .{
        .gcloud_config_dir = config.dir,
        .diagnostics = &diag,
    }, .{ .transport = fake.transport() }));
    try testing.expectEqual(0, fake.requests.items.len);
}

test "findDefault: a gcloud path that is there but unreadable is an error" {
    var config: TmpConfig = undefined;
    try config.init();
    defer config.deinit();
    // A directory where the file should be: it exists, and reading it fails.
    try config.tmp.dir.createDirPath(testing.io, Lookup.adc_file_name);
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{ metadata_listing, metadata_token });
    defer fake.deinit();
    var diag: Diagnostics = .{};

    try testing.expectError(error.CredentialsFileNotFound, find(testing.allocator, testing.io, .{
        .gcloud_config_dir = config.dir,
        .diagnostics = &diag,
    }, .{ .transport = fake.transport() }));
    try testing.expect(diag.message().len > 0);
    try testing.expectEqual(0, fake.requests.items.len);
}

test "findDefault: a gcloud path that cannot even be checked is an error" {
    // Looking for the file fails with something other than "it is not
    // there", and that must not be read as "it is not there". Each
    // platform refuses a different path: Windows reports one that is
    // merely too long as absent, which it is, but refuses one it cannot
    // encode, and posix is the other way round.
    const unusable_dir = if (builtin.os.tag == .windows) "bad\xffname" else "x" ** 5000;
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{ metadata_listing, metadata_token });
    defer fake.deinit();
    var diag: Diagnostics = .{};
    try testing.expectError(error.CredentialsFileNotFound, find(testing.allocator, testing.io, .{
        .gcloud_config_dir = unusable_dir,
        .diagnostics = &diag,
    }, .{ .transport = fake.transport() }));
    try testing.expect(std.mem.startsWith(u8, diag.message(), "cannot read"));
    try testing.expectEqual(0, fake.requests.items.len);
}

test "findDefault: the metadata server is the last resort" {
    var config: TmpConfig = undefined;
    try config.init();
    defer config.deinit();
    // The directory exists, the file does not.
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{ metadata_listing, metadata_token });
    defer fake.deinit();

    var creds = try find(testing.allocator, testing.io, .{
        .gcloud_config_dir = config.dir,
        .metadata_host = "169.254.169.254",
    }, .{ .transport = fake.transport() });
    defer creds.deinit();
    try testing.expectEqual(.metadata_server, creds.source);
    // A service account bills its own project, and nothing overrode it.
    try testing.expectEqual(null, creds.quotaProjectId());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("ya29.from-metadata", try creds.provider().getToken(testing.io, arena.allocator(), test_scopes));
    try testing.expectEqualStrings("http://169.254.169.254/", (try fake.request(0)).url);
    try testing.expect(std.mem.startsWith(u8, (try fake.request(1)).url, "http://169.254.169.254/computeMetadata/"));
}

test "findDefault: the metadata server says which project this runs in" {
    var config: TmpConfig = undefined;
    try config.init();
    defer config.deinit();
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        metadata_listing,
        .{ .respond = .{ .body = "my-project-123", .headers = flavor } },
    });
    defer fake.deinit();

    var creds = try find(testing.allocator, testing.io, .{ .gcloud_config_dir = config.dir }, .{
        .transport = fake.transport(),
    });
    defer creds.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("my-project-123", (try creds.projectId(testing.io, arena.allocator())).?);
}

test "findDefault: a credentials file does not know the project, and says so without asking" {
    var config: TmpConfig = undefined;
    try config.init();
    defer config.deinit();
    var path_buf: [160]u8 = undefined;
    _ = try config.write(&path_buf, Lookup.adc_file_name, gcloud_json);
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{});
    defer fake.deinit();

    var creds = try find(testing.allocator, testing.io, .{ .gcloud_config_dir = config.dir }, .{
        .transport = fake.transport(),
    });
    defer creds.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(null, try creds.projectId(testing.io, arena.allocator()));
    try testing.expectEqual(0, fake.requests.items.len);
}

test "findDefault: with nothing anywhere, it says what it tried" {
    var config: TmpConfig = undefined;
    try config.init();
    defer config.deinit();
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{no_metadata});
    defer fake.deinit();
    var diag: Diagnostics = .{};

    try testing.expectError(error.NoCredentialsFound, find(testing.allocator, testing.io, .{
        .gcloud_config_dir = config.dir,
        .diagnostics = &diag,
    }, .{ .transport = fake.transport() }));
    const message = diag.message();
    try testing.expect(std.mem.indexOf(u8, message, "GOOGLE_APPLICATION_CREDENTIALS") != null);
    try testing.expect(std.mem.indexOf(u8, message, "gcloud") != null);
    try testing.expect(std.mem.indexOf(u8, message, "metadata.google.internal") != null);
}

test "findDefault: with no directory to look in either" {
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{no_metadata});
    defer fake.deinit();
    var diag: Diagnostics = .{};
    try testing.expectError(error.NoCredentialsFound, find(testing.allocator, testing.io, .{
        .diagnostics = &diag,
    }, .{ .transport = fake.transport() }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "CLOUDSDK_CONFIG") != null);
}

test "findDefault: GOOGLE_CLOUD_QUOTA_PROJECT wins over the file's own project" {
    var config: TmpConfig = undefined;
    try config.init();
    defer config.deinit();
    var path_buf: [160]u8 = undefined;
    _ = try config.write(&path_buf, Lookup.adc_file_name, gcloud_json);
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{});
    defer fake.deinit();

    var creds = try find(testing.allocator, testing.io, .{
        .gcloud_config_dir = config.dir,
        .quota_project = "billing-elsewhere",
    }, .{ .transport = fake.transport() });
    defer creds.deinit();
    try testing.expectEqualStrings("billing-elsewhere", creds.quotaProjectId().?);
    // Which is also what a service asks the provider for.
    try testing.expectEqualStrings("billing-elsewhere", creds.provider().quotaProject().?);
}

test "findDefault: a quota project that could break a header is refused" {
    var diag: Diagnostics = .{};
    try testing.expectError(error.InvalidOptions, find(testing.allocator, testing.io, .{
        .quota_project = "billing\r\nX-Injected: 1",
        .diagnostics = &diag,
    }, .{}));
    try testing.expect(std.mem.startsWith(u8, diag.message(), "invalid quota project"));
}

test "findDefault: an unusable metadata host is reported, not ignored" {
    var diag: Diagnostics = .{};
    try testing.expectError(error.InvalidOptions, find(testing.allocator, testing.io, .{
        .metadata_host = "http://169.254.169.254",
        .diagnostics = &diag,
    }, .{}));
    try testing.expect(std.mem.startsWith(u8, diag.message(), "invalid metadata host"));
}

test "findDefault: what it found can be moved, and its provider still works" {
    var config: TmpConfig = undefined;
    try config.init();
    defer config.deinit();
    var path_buf: [160]u8 = undefined;
    _ = try config.write(&path_buf, Lookup.adc_file_name, gcloud_json);
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{user_token});
    defer fake.deinit();

    var found = try find(testing.allocator, testing.io, .{
        .gcloud_config_dir = config.dir,
        .quota_project = "billing-elsewhere",
    }, .{ .transport = fake.transport() });
    // The provider lives on the heap, so this copy is as good as the original.
    var moved = found;
    found = undefined;
    defer moved.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("ya29.from-file", try moved.provider().getToken(testing.io, arena.allocator(), test_scopes));
    try testing.expectEqualStrings("billing-elsewhere", moved.provider().quotaProject().?);
    moved.provider().invalidate();
}

test "findDefault: the file's secrets reach neither the log nor Diagnostics" {
    logging.capture.reset();
    var config: TmpConfig = undefined;
    try config.init();
    defer config.deinit();
    var path_buf: [160]u8 = undefined;
    _ = try config.write(&path_buf, Lookup.adc_file_name, gcloud_json);
    var fake: test_util.FakeTransport = .init(testing.allocator, &.{
        .{ .respond = .{ .status = 400, .body = "{\"error\":\"invalid_grant\"}" } },
    });
    defer fake.deinit();
    var diag: Diagnostics = .{};

    var creds = try find(testing.allocator, testing.io, .{
        .gcloud_config_dir = config.dir,
        .diagnostics = &diag,
    }, .{ .transport = fake.transport() });
    defer creds.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.RefreshTokenInvalid, creds.provider().getToken(testing.io, arena.allocator(), test_scopes));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "SECRET") == null);
    try testing.expect(std.mem.indexOf(u8, logging.capture.text(), "SECRET") == null);
    // It does say where the credentials came from.
    try testing.expect(std.mem.indexOf(u8, logging.capture.text(), "gcloud") != null);
}

test "findDefault: every allocation failure is OutOfMemory without leaks" {
    const Run = struct {
        fn fromFile(gpa: Allocator, dir: []const u8) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{user_token});
            defer fake.deinit();
            var creds = try find(gpa, testing.io, .{
                .gcloud_config_dir = dir,
                .quota_project = "billing-elsewhere",
            }, .{ .transport = fake.transport() });
            defer creds.deinit();
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            _ = try creds.provider().getToken(testing.io, arena.allocator(), test_scopes);
        }

        fn fromNamedFile(gpa: Allocator, path: []const u8) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{user_token});
            defer fake.deinit();
            var creds = try find(gpa, testing.io, .{ .credentials_path = path }, .{ .transport = fake.transport() });
            defer creds.deinit();
        }

        fn fromMetadata(gpa: Allocator, dir: []const u8) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{ metadata_listing, metadata_token });
            defer fake.deinit();
            var creds = try find(gpa, testing.io, .{ .gcloud_config_dir = dir }, .{ .transport = fake.transport() });
            defer creds.deinit();
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            _ = try creds.provider().getToken(testing.io, arena.allocator(), test_scopes);
        }

        fn nothing(gpa: Allocator, dir: []const u8) !void {
            var fake: test_util.FakeTransport = .init(testing.allocator, &.{no_metadata});
            defer fake.deinit();
            var creds = find(gpa, testing.io, .{ .gcloud_config_dir = dir }, .{ .transport = fake.transport() }) catch |err| switch (err) {
                error.NoCredentialsFound => return,
                else => return err,
            };
            creds.deinit();
            return error.TestExpectedNoCredentials;
        }
    };
    var with_file: TmpConfig = undefined;
    try with_file.init();
    defer with_file.deinit();
    var path_buf: [160]u8 = undefined;
    _ = try with_file.write(&path_buf, Lookup.adc_file_name, gcloud_json);
    try testing.checkAllAllocationFailures(testing.allocator, Run.fromFile, .{with_file.dir});
    var named_buf: [160]u8 = undefined;
    const named = try std.fmt.bufPrint(&named_buf, "{s}/{s}", .{ with_file.dir, Lookup.adc_file_name });
    try testing.checkAllAllocationFailures(testing.allocator, Run.fromNamedFile, .{named});

    var empty: TmpConfig = undefined;
    try empty.init();
    defer empty.deinit();
    try testing.checkAllAllocationFailures(testing.allocator, Run.fromMetadata, .{empty.dir});
    try testing.checkAllAllocationFailures(testing.allocator, Run.nothing, .{empty.dir});
}
