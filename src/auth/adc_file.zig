//! Credential files: the one `GOOGLE_APPLICATION_CREDENTIALS` names, and the
//! one `gcloud auth application-default login` writes. This version reads
//! files of type `authorized_user`, `service_account`, `external_account`
//! and `impersonated_service_account`, and refuses every other type by name.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const Diagnostics = core.Diagnostics;
const iam_credentials = @import("iam_credentials.zig");

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
    external_account: ExternalAccount,
    impersonated_service_account: Impersonated,
};

/// An `impersonated_service_account` file's fields, as
/// `gcloud auth application-default login --impersonate-service-account`
/// writes them: source credentials, and the service account they may act as.
pub const Impersonated = struct {
    /// The service account's email or unique id, from the file's
    /// `service_account_impersonation_url`. Only this is taken from the URL:
    /// the request goes to Google's endpoint, as Google's libraries do, so a
    /// crafted file cannot send the source token to another host.
    target: []const u8,
    /// Accounts between the source and the target, each as
    /// `projects/-/serviceAccounts/EMAIL`, passed through. Usually none.
    delegates: []const []const u8,
    /// The source credentials as JSON of their own, for their provider's
    /// `initFromJson`. Secret: it holds a refresh token or a private key.
    source_json: []const u8,
    source_type: SourceType,
    /// The project to charge for quota: the file's own, not the source's.
    quota_project_id: ?[]const u8,

    pub const SourceType = enum { authorized_user, service_account };
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

/// An `external_account` file's fields: workload identity federation, where
/// a third-party token is traded at Google's STS for an access token.
pub const ExternalAccount = struct {
    /// The workload identity pool provider, `//iam.googleapis.com/...`.
    audience: []const u8,
    /// What the subject token is, such as
    /// `urn:ietf:params:oauth:token-type:jwt`.
    subject_token_type: []const u8,
    /// The STS endpoint the file names, or null for Google's.
    token_url: ?[]const u8,
    credential_source: CredentialSource,
    /// When set, the STS token then impersonates this service account.
    impersonation_url: ?[]const u8,
    /// Seconds the impersonated token asks to live, when the file says.
    impersonation_lifetime_s: ?u32,
    quota_project_id: ?[]const u8,
};

/// Where an external account's subject token comes from.
pub const CredentialSource = union(enum) {
    /// A file holding the token, as Kubernetes and GitHub Actions write.
    file: SourceTarget,
    /// A URL answering with the token, as Azure's metadata service does.
    url: SourceTarget,
};

pub const SourceTarget = struct {
    /// The path, or the URL.
    where: []const u8,
    /// Sent with the GET of a url source; empty for a file.
    headers: []const core.transport.Header,
    format: SourceFormat,
};

pub const SourceFormat = union(enum) {
    /// The whole document, trimmed, is the token.
    text,
    /// The document is JSON, and the token is this field of it.
    json_field: []const u8,
};

const WireFormat = struct {
    type: ?[]const u8 = null,
    subject_token_field_name: ?[]const u8 = null,
};

const WireSource = struct {
    file: ?[]const u8 = null,
    url: ?[]const u8 = null,
    headers: ?std.json.ArrayHashMap([]const u8) = null,
    format: ?WireFormat = null,
    environment_id: ?[]const u8 = null,
    executable: ?std.json.Value = null,
};

const WireImpersonation = struct {
    token_lifetime_seconds: ?u32 = null,
};

/// An impersonated file's `source_credentials`: flat, so a crafted file
/// cannot nest objects to any depth here, and only the fields the two
/// source types read.
const WireSourceCredentials = struct {
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
    audience: ?[]const u8 = null,
    subject_token_type: ?[]const u8 = null,
    token_url: ?[]const u8 = null,
    credential_source: ?WireSource = null,
    service_account_impersonation_url: ?[]const u8 = null,
    service_account_impersonation: ?WireImpersonation = null,
    workforce_pool_user_project: ?[]const u8 = null,
    quota_project_id: ?[]const u8 = null,
    universe_domain: ?[]const u8 = null,
    source_credentials: ?WireSourceCredentials = null,
    delegates: ?[]const []const u8 = null,
};

/// Types this version recognizes, and why it refuses them.
const refused = std.StaticStringMap([]const u8).initComptime(.{
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
    const known = std.mem.eql(u8, kind, "authorized_user") or
        std.mem.eql(u8, kind, "service_account") or
        std.mem.eql(u8, kind, "external_account") or
        std.mem.eql(u8, kind, "impersonated_service_account");
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
    if (std.mem.eql(u8, kind, "impersonated_service_account")) {
        return .{ .impersonated_service_account = try parseImpersonated(arena, wire, quota, diag) };
    }
    if (std.mem.eql(u8, kind, "external_account")) return .{ .external_account = .{
        .audience = try required(wire.audience, "audience", diag),
        .subject_token_type = try required(wire.subject_token_type, "subject_token_type", diag),
        .token_url = emptyToNull(wire.token_url),
        .credential_source = try parseSource(arena, wire.credential_source, diag),
        .impersonation_url = emptyToNull(wire.service_account_impersonation_url),
        .impersonation_lifetime_s = if (wire.service_account_impersonation) |i| i.token_lifetime_seconds else null,
        .quota_project_id = if (emptyToNull(wire.workforce_pool_user_project) != null)
            return unsupported(diag, "workforce identity federation is not supported yet")
        else
            quota,
    } };
    return .{ .authorized_user = .{
        .client_id = try required(wire.client_id, "client_id", diag),
        .client_secret = try required(wire.client_secret, "client_secret", diag),
        .refresh_token = try required(wire.refresh_token, "refresh_token", diag),
        .quota_project_id = quota,
    } };
}

/// An impersonated file: the account to act as, and source credentials this
/// version can read on their own.
fn parseImpersonated(arena: Allocator, wire: Wire, quota: ?[]const u8, diag: ?*Diagnostics) Error!Impersonated {
    const url = try required(wire.service_account_impersonation_url, "service_account_impersonation_url", diag);
    const target = iam_credentials.principalFromUrl(url) orelse return invalid(
        diag,
        "the credentials file's \"service_account_impersonation_url\" does not end in serviceAccounts/ACCOUNT:generateAccessToken",
        .{},
    );
    const delegates = wire.delegates orelse &.{};
    for (delegates) |delegate| {
        // Each travels inside the request's JSON body.
        if (delegate.len == 0 or !isPrintable(delegate)) {
            return invalid(diag, "the credentials file has a \"delegates\" entry that is empty or not printable ASCII", .{});
        }
    }

    const source = wire.source_credentials orelse return invalid(diag, "the credentials file lacks \"source_credentials\"", .{});
    const source_kind = source.type orelse return invalid(diag, "the credentials file's \"source_credentials\" has no \"type\"", .{});
    const source_type: Impersonated.SourceType = if (std.mem.eql(u8, source_kind, "authorized_user"))
        .authorized_user
    else if (std.mem.eql(u8, source_kind, "service_account"))
        .service_account
    else {
        if (diag) |d| {
            if (isPrintable(source_kind)) {
                d.print("the credentials file impersonates from \"source_credentials\" of type \"{s}\"; only authorized_user and service_account are supported", .{source_kind});
            } else {
                d.print("the credentials file impersonates from \"source_credentials\" of a type this version does not know", .{});
            }
        }
        return error.UnsupportedCredentialType;
    };

    // The source's provider reads JSON, so the source gets JSON of its own,
    // checked here with the same rules a file of that type meets.
    const source_json = std.json.Stringify.valueAlloc(arena, source, .{ .emit_null_optional_fields = false }) catch
        return error.OutOfMemory;
    _ = parse(arena, source_json, diag) catch |err| return nested(diag, err);
    return .{
        .target = target,
        .delegates = delegates,
        .source_json = source_json,
        .source_type = source_type,
        .quota_project_id = quota,
    };
}

/// Says that a failure was inside `source_credentials`, keeping what the
/// inner parse said about it.
fn nested(diag: ?*Diagnostics, err: Error) Error {
    if (diag) |d| {
        var buf: @FieldType(Diagnostics, "buffer") = undefined;
        const message = d.message();
        const copy = buf[0..@min(message.len, buf.len)];
        @memcpy(copy, message[0..copy.len]);
        d.print("in \"source_credentials\": {s}", .{copy});
    }
    return err;
}

/// Where an external account's subject token comes from, with everything
/// this version cannot fetch refused by name.
fn parseSource(arena: Allocator, source: ?WireSource, diag: ?*Diagnostics) Error!CredentialSource {
    const wire = source orelse return invalid(diag, "the credentials file lacks \"credential_source\"", .{});
    if (wire.environment_id != null) {
        return unsupported(diag, "AWS credential sources need request signing, which this version does not do");
    }
    if (wire.executable != null) {
        return unsupported(diag, "executable credential sources are not run");
    }

    const format: SourceFormat = format: {
        const f = wire.format orelse break :format .text;
        const format_type = f.type orelse break :format .text;
        if (std.mem.eql(u8, format_type, "text")) break :format .text;
        if (std.mem.eql(u8, format_type, "json")) {
            const field = emptyToNull(f.subject_token_field_name) orelse
                return invalid(diag, "a json credential_source needs \"subject_token_field_name\"", .{});
            break :format .{ .json_field = field };
        }
        return invalid(diag, "the credential_source format must be \"text\" or \"json\"", .{});
    };

    const file = emptyToNull(wire.file);
    const url = emptyToNull(wire.url);
    if (file != null and url != null) {
        return invalid(diag, "the credential_source names both a file and a url", .{});
    }
    if (file) |path| {
        return .{ .file = .{ .where = path, .headers = &.{}, .format = format } };
    }
    const where = url orelse return invalid(diag, "the credential_source names neither a file nor a url", .{});

    var headers: std.ArrayList(core.transport.Header) = .empty;
    if (wire.headers) |map| {
        var it = map.map.iterator();
        while (it.next()) |entry| {
            // They travel as HTTP headers, so they must not be able to
            // break one.
            if (!core.transport.isValidHeaderName(entry.key_ptr.*) or
                !core.transport.isValidHeaderValue(entry.value_ptr.*))
            {
                return invalid(diag, "a credential_source header has a name or value HTTP cannot carry", .{});
            }
            try headers.append(arena, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
        }
    }
    return .{ .url = .{ .where = where, .headers = headers.items, .format = format } };
}

fn unsupported(diag: ?*Diagnostics, message: []const u8) Error {
    if (diag) |d| d.print("the credentials file has type \"external_account\": {s}", .{message});
    return error.UnsupportedCredentialType;
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
            else => return error.TestWrongCredentialType,
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
            else => return error.TestWrongCredentialType,
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

fn expectExternalAccount(json: []const u8, want: Error!ExternalAccount, message: ?[]const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostics = .{};
    const got = parse(arena.allocator(), json, &diag);
    if (want) |w| {
        const g = switch (try got) {
            .external_account => |e| e,
            else => return error.TestWrongCredentialType,
        };
        try testing.expectEqualStrings(w.audience, g.audience);
        try testing.expectEqualStrings(w.subject_token_type, g.subject_token_type);
        try expectOptional(w.token_url, g.token_url);
        try expectOptional(w.impersonation_url, g.impersonation_url);
        try testing.expectEqual(w.impersonation_lifetime_s, g.impersonation_lifetime_s);
        try expectOptional(w.quota_project_id, g.quota_project_id);
        try testing.expectEqualStrings(@tagName(w.credential_source), @tagName(g.credential_source));
        const want_target = switch (w.credential_source) {
            inline else => |t| t,
        };
        const got_target = switch (g.credential_source) {
            inline else => |t| t,
        };
        try testing.expectEqualStrings(want_target.where, got_target.where);
        try testing.expectEqual(want_target.headers.len, got_target.headers.len);
        try testing.expectEqualStrings(@tagName(want_target.format), @tagName(got_target.format));
    } else |err| {
        try testing.expectError(err, got);
        if (message) |m| try testing.expectEqualStrings(m, diag.message());
        try testing.expect(std.mem.indexOf(u8, diag.message(), "SECRET") == null);
    }
}

test "adc_file: an external_account file, as GitHub Actions or GKE writes one" {
    try expectExternalAccount(
        \\{"type": "external_account",
        \\ "audience": "//iam.googleapis.com/projects/12345/locations/global/workloadIdentityPools/pool/providers/gha",
        \\ "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
        \\ "token_url": "https://sts.googleapis.com/v1/token",
        \\ "credential_source": {"file": "/var/run/secrets/token"},
        \\ "service_account_impersonation_url": "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/sa@p.iam.gserviceaccount.com:generateAccessToken",
        \\ "service_account_impersonation": {"token_lifetime_seconds": 600},
        \\ "universe_domain": "googleapis.com"}
    , .{
        .audience = "//iam.googleapis.com/projects/12345/locations/global/workloadIdentityPools/pool/providers/gha",
        .subject_token_type = "urn:ietf:params:oauth:token-type:jwt",
        .token_url = "https://sts.googleapis.com/v1/token",
        .credential_source = .{ .file = .{ .where = "/var/run/secrets/token", .headers = &.{}, .format = .text } },
        .impersonation_url = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/sa@p.iam.gserviceaccount.com:generateAccessToken",
        .impersonation_lifetime_s = 600,
        .quota_project_id = null,
    }, null);
}

test "adc_file: a url credential source, with headers and a json format" {
    const json =
        \\{"type": "external_account", "audience": "//iam.googleapis.com/x",
        \\ "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
        \\ "credential_source": {"url": "http://169.254.169.254/token",
        \\   "headers": {"Metadata": "True"},
        \\   "format": {"type": "json", "subject_token_field_name": "access_token"}}}
    ;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = switch (try parse(arena.allocator(), json, null)) {
        .external_account => |e| e,
        else => return error.TestWrongCredentialType,
    };
    const url = got.credential_source.url;
    try testing.expectEqualStrings("http://169.254.169.254/token", url.where);
    try testing.expectEqual(1, url.headers.len);
    try testing.expectEqualStrings("Metadata", url.headers[0].name);
    try testing.expectEqualStrings("True", url.headers[0].value);
    try testing.expectEqualStrings("access_token", url.format.json_field);
    try testing.expectEqual(null, got.token_url);
    try testing.expectEqual(null, got.impersonation_url);
}

test "adc_file: the external_account shapes this version cannot fetch are refused by name" {
    const head = "\"type\":\"external_account\",\"audience\":\"//iam.googleapis.com/x\",\"subject_token_type\":\"urn:ietf:params:oauth:token-type:jwt\"";
    try expectExternalAccount("{" ++ head ++ ",\"credential_source\":{\"environment_id\":\"aws1\",\"url\":\"u\"}}", error.UnsupportedCredentialType, "the credentials file has type \"external_account\": AWS credential sources need request signing, which this version does not do");
    try expectExternalAccount("{" ++ head ++ ",\"credential_source\":{\"executable\":{\"command\":\"/bin/evil\"}}}", error.UnsupportedCredentialType, "the credentials file has type \"external_account\": executable credential sources are not run");
    try expectExternalAccount("{" ++ head ++ ",\"credential_source\":{\"file\":\"/t\"},\"workforce_pool_user_project\":\"p\"}", error.UnsupportedCredentialType, "the credentials file has type \"external_account\": workforce identity federation is not supported yet");
}

test "adc_file: an external_account file that cannot work says what is wrong" {
    const head = "\"type\":\"external_account\",\"audience\":\"//iam.googleapis.com/x\",\"subject_token_type\":\"urn:ietf:params:oauth:token-type:jwt\"";
    try expectExternalAccount("{" ++ head ++ "}", error.InvalidCredentialsFile, "the credentials file lacks \"credential_source\"");
    try expectExternalAccount("{" ++ head ++ ",\"credential_source\":{}}", error.InvalidCredentialsFile, "the credential_source names neither a file nor a url");
    try expectExternalAccount("{" ++ head ++ ",\"credential_source\":{\"file\":\"/t\",\"url\":\"u\"}}", error.InvalidCredentialsFile, "the credential_source names both a file and a url");
    try expectExternalAccount("{" ++ head ++ ",\"credential_source\":{\"file\":\"/t\",\"format\":{\"type\":\"json\"}}}", error.InvalidCredentialsFile, "a json credential_source needs \"subject_token_field_name\"");
    try expectExternalAccount("{" ++ head ++ ",\"credential_source\":{\"file\":\"/t\",\"format\":{\"type\":\"xml\"}}}", error.InvalidCredentialsFile, "the credential_source format must be \"text\" or \"json\"");
    try expectExternalAccount("{" ++ head ++ ",\"credential_source\":{\"url\":\"u\",\"headers\":{\"X-Evil\":\"1\\r\\nX-Injected: 2\"}}}", error.InvalidCredentialsFile, "a credential_source header has a name or value HTTP cannot carry");
    try expectExternalAccount("{\"type\":\"external_account\",\"subject_token_type\":\"t\",\"credential_source\":{\"file\":\"/t\"}}", error.InvalidCredentialsFile, "the credentials file lacks \"audience\"");
}

test "adc_file: every other type is refused by name" {
    const base = "\"client_id\":\"c\",\"client_secret\":\"SECRET\",\"refresh_token\":\"SECRET\"";
    try expectParse("{\"type\":\"external_account_authorized_user\"," ++ base ++ "}", error.UnsupportedCredentialType, "the credentials file has type \"external_account_authorized_user\": workforce identity federation is not supported");
    try expectParse("{\"type\":\"banana\"," ++ base ++ "}", error.UnsupportedCredentialType, "the credentials file has type \"banana\", which this version does not know");
    try expectParse("{\"type\":\"a\\nb\"," ++ base ++ "}", error.UnsupportedCredentialType, "the credentials file has a type this version does not know");
    try expectParse("{" ++ base ++ "}", error.InvalidCredentialsFile, "the credentials file has no \"type\"");
}

const impersonation_url = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/sa@p.iam.gserviceaccount.com:generateAccessToken";
const user_source = "{\"type\":\"authorized_user\",\"client_id\":\"c\",\"client_secret\":\"SECRET\",\"refresh_token\":\"SECRET-refresh\"}";

fn impersonated(comptime url: []const u8, comptime source: []const u8, comptime extra: []const u8) []const u8 {
    return "{\"type\":\"impersonated_service_account\",\"service_account_impersonation_url\":\"" ++ url ++
        "\",\"source_credentials\":" ++ source ++ extra ++ "}";
}

test "adc_file: an impersonated file, as gcloud writes it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Field for field what `gcloud auth application-default login
    // --impersonate-service-account` writes.
    const got = try parse(a,
        \\{
        \\  "delegates": [],
        \\  "service_account_impersonation_url": "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/sa@p.iam.gserviceaccount.com:generateAccessToken",
        \\  "source_credentials": {
        \\    "account": "",
        \\    "client_id": "c.apps.googleusercontent.com",
        \\    "client_secret": "SECRET",
        \\    "refresh_token": "1//SECRET-refresh",
        \\    "type": "authorized_user",
        \\    "universe_domain": "googleapis.com"
        \\  },
        \\  "type": "impersonated_service_account"
        \\}
    , null);
    const i = got.impersonated_service_account;
    try testing.expectEqualStrings("sa@p.iam.gserviceaccount.com", i.target);
    try testing.expectEqual(0, i.delegates.len);
    try testing.expectEqual(.authorized_user, i.source_type);
    try testing.expectEqual(null, i.quota_project_id);
    // The source is a file of its own now, read by its provider's rules.
    const source = (try parse(a, i.source_json, null)).authorized_user;
    try testing.expectEqualStrings("1//SECRET-refresh", source.refresh_token);
    try testing.expectEqualStrings("c.apps.googleusercontent.com", source.client_id);
}

test "adc_file: an impersonated file with a key as its source, delegates and a quota project" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try parse(a, impersonated(
        impersonation_url,
        "{\"type\":\"service_account\",\"client_email\":\"source@p.iam.gserviceaccount.com\",\"private_key\":\"-----BEGIN PRIVATE KEY-----\"}",
        ",\"delegates\":[\"projects/-/serviceAccounts/middle@p.iam.gserviceaccount.com\"],\"quota_project_id\":\"billing\"",
    ), null);
    const i = got.impersonated_service_account;
    try testing.expectEqual(.service_account, i.source_type);
    try testing.expectEqual(1, i.delegates.len);
    try testing.expectEqualStrings("projects/-/serviceAccounts/middle@p.iam.gserviceaccount.com", i.delegates[0]);
    // The file's own quota project, not the source's.
    try testing.expectEqualStrings("billing", i.quota_project_id.?);
    try testing.expectEqualStrings("source@p.iam.gserviceaccount.com", (try parse(a, i.source_json, null)).service_account.client_email);
}

fn expectImpersonatedError(json: []const u8, want: Error, message: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostics = .{};
    try testing.expectError(want, parse(arena.allocator(), json, &diag));
    try testing.expectEqualStrings(message, diag.message());
    // Nothing secret is ever repeated, the source's secrets included.
    try testing.expect(std.mem.indexOf(u8, diag.message(), "SECRET") == null);
}

test "adc_file: what an impersonated file must have" {
    try expectImpersonatedError(
        "{\"type\":\"impersonated_service_account\",\"source_credentials\":" ++ user_source ++ "}",
        error.InvalidCredentialsFile,
        "the credentials file lacks \"service_account_impersonation_url\"",
    );
    try expectImpersonatedError(
        impersonated("https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/sa@p:signJwt", user_source, ""),
        error.InvalidCredentialsFile,
        "the credentials file's \"service_account_impersonation_url\" does not end in serviceAccounts/ACCOUNT:generateAccessToken",
    );
    try expectImpersonatedError(
        "{\"type\":\"impersonated_service_account\",\"service_account_impersonation_url\":\"" ++ impersonation_url ++ "\"}",
        error.InvalidCredentialsFile,
        "the credentials file lacks \"source_credentials\"",
    );
    try expectImpersonatedError(
        impersonated(impersonation_url, "{\"refresh_token\":\"SECRET\"}", ""),
        error.InvalidCredentialsFile,
        "the credentials file's \"source_credentials\" has no \"type\"",
    );
    // A source this version cannot read on its own, named.
    try expectImpersonatedError(
        impersonated(impersonation_url, "{\"type\":\"impersonated_service_account\"}", ""),
        error.UnsupportedCredentialType,
        "the credentials file impersonates from \"source_credentials\" of type \"impersonated_service_account\"; only authorized_user and service_account are supported",
    );
    // A source that is missing something says it is the source.
    try expectImpersonatedError(
        impersonated(impersonation_url, "{\"type\":\"authorized_user\",\"client_id\":\"c\",\"client_secret\":\"SECRET\"}", ""),
        error.InvalidCredentialsFile,
        "in \"source_credentials\": the credentials file lacks \"refresh_token\"",
    );
    try expectImpersonatedError(
        impersonated(impersonation_url, user_source, ",\"delegates\":[\"\"]"),
        error.InvalidCredentialsFile,
        "the credentials file has a \"delegates\" entry that is empty or not printable ASCII",
    );
    // A nested object where a string belongs is refused, never walked.
    try expectImpersonatedError(
        impersonated(impersonation_url, "{\"type\":{\"deeper\":{\"still\":[[[1]]]}}}", ""),
        error.InvalidCredentialsFile,
        "the credentials file is not JSON, or a field that should be a string is not",
    );
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
        .external_account => |e| {
            try testing.expect(e.audience.len > 0 and e.subject_token_type.len > 0);
            if (e.quota_project_id) |q| try testing.expect(core.TokenProvider.isValidToken(q));
        },
        .impersonated_service_account => |i| {
            // The account can go into Google's URL as it is, the delegates
            // into the body, and the source is a file its provider reads.
            try testing.expect(iam_credentials.isPrincipal(i.target));
            for (i.delegates) |delegate| try testing.expect(isPrintable(delegate));
            if (i.quota_project_id) |q| try testing.expect(core.TokenProvider.isValidToken(q));
            const source = try parse(arena.allocator(), i.source_json, null);
            try testing.expectEqualStrings(@tagName(i.source_type), @tagName(source));
        },
    }
}

test "fuzz adc_file: arbitrary input never crashes" {
    try test_util.fuzzBytes({}, arbitraryProperty, .{ .corpus = &.{
        "{\"type\":\"authorized_user\",\"client_id\":\"c\",\"client_secret\":\"s\",\"refresh_token\":\"r\"}",
        "{\"type\":\"authorized_user\",\"type\":\"service_account\"}",
        "{\"type\":null}",
        "{\"type\":\"impersonated_service_account\",\"service_account_impersonation_url\":\"https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/sa@p.iam.gserviceaccount.com:generateAccessToken\",\"source_credentials\":{\"type\":\"authorized_user\",\"client_id\":\"c\",\"client_secret\":\"s\",\"refresh_token\":\"r\"},\"delegates\":[]}",
        "{\"type\":\"impersonated_service_account\",\"service_account_impersonation_url\":\"x/a:generateAccessToken\",\"source_credentials\":{\"type\":\"impersonated_service_account\"}}",
    } });
}

/// Each field of a generated file: absent, empty, or with a value.
const Presence = enum { absent, empty, value };

fn structuredProperty(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g: test_util.ByteGen = .init(input);

    const kind = g.pick([]const u8, &.{ "authorized_user", "authorized_user", "service_account", "service_account", "external_account", "external_account", "banana", "" });
    const has_type = g.boolean();
    const user_fields = [_][]const u8{ "client_id", "client_secret", "refresh_token" };
    const sa_fields = [_][]const u8{ "client_email", "private_key" };
    const ea_fields = [_][]const u8{ "audience", "subject_token_type" };
    const external = std.mem.eql(u8, kind, "external_account");
    const fields: []const []const u8 = if (external)
        &ea_fields
    else if (std.mem.eql(u8, kind, "service_account"))
        &sa_fields
    else
        &user_fields;
    const has_source = g.boolean();
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
    if (external and has_source) {
        try json.objectField("credential_source");
        try json.beginObject();
        try json.objectField("file");
        try json.write("/token");
        try json.endObject();
    }
    try json.endObject();

    // The rules, in the order parse applies them.
    const known = std.mem.eql(u8, kind, "authorized_user") or std.mem.eql(u8, kind, "service_account") or external;
    const want: Error!void = if (!has_type)
        error.InvalidCredentialsFile
    else if (!known)
        error.UnsupportedCredentialType
    else if (universe != null and !std.mem.eql(u8, universe.?, "googleapis.com"))
        error.UnsupportedCredentialType
    else if (quota != null and quota.?.len > 0 and !core.TokenProvider.isValidToken(quota.?))
        error.InvalidCredentialsFile
    else if (for (presence) |p| {
        if (p != .value) break true;
    } else false)
        error.InvalidCredentialsFile
    else if (external and !has_source)
        error.InvalidCredentialsFile
    else {};

    const got = parse(a, out.written(), null);
    if (want) |_| {
        const file = try got;
        try testing.expectEqualStrings(kind, @tagName(file));
        const secret = switch (file) {
            .authorized_user => |u| u.refresh_token,
            .service_account => |sa| sa.private_key,
            .external_account => |e| e.audience,
            .impersonated_service_account => |i| i.source_json,
        };
        try testing.expectEqualStrings(if (value.len > 0) value else "v", secret);
    } else |err| {
        try testing.expectError(err, got);
    }
}

test "fuzz adc_file: generated files meet the rules" {
    try test_util.fuzzBytes({}, structuredProperty, .{});
}
