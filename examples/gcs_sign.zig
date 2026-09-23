//! Signs a URL for one object with whatever credentials this machine has,
//! and prints it. Whoever holds that URL can make the one request it
//! describes, until it expires, with no credentials of their own:
//!
//!     zig build example-gcs_sign -- gs://my-bucket/reports/q3.txt
//!     zig build example-gcs_sign -- gs://my-bucket/uploads/photo.png --put image/png --minutes 10
//!     zig build example-gcs_sign -- gs://my-bucket/uploads/ --post-policy --put image/png
//!
//! `--post-policy` prints an HTML form instead of a URL. A form cannot send
//! the headers a signed PUT pins, and the person at the browser picks the
//! file, so its name is not known when the policy is signed; a policy can
//! allow a whole prefix, which a URL cannot. End the target with `/` for
//! one: Cloud Storage puts the browser's file name where `${filename}` is.
//!
//! A service account key file signs here, on this machine. A workload on
//! Google Cloud, or a login that impersonates a service account, signs
//! through the IAM Credentials API, where the key never leaves Google;
//! those URLs may last at most 12 hours, since Google rotates the key it
//! signs them with. A user's own login is no service account and cannot
//! sign at all, which `auth.Credentials.signer` reports by returning null.
//!
//! The URL is a bearer credential until it expires: whoever holds it can
//! make that request, so pass it around no more freely than a password.

const std = @import("std");
const auth = @import("auth");
const storage = @import("storage");

/// Show the library's warnings, such as a retried signing call.
pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .gcp_auth, .level = .warn },
        .{ .scope = .gcp_storage, .level = .warn },
    },
};

const usage = "usage: gcs_sign gs://<bucket>/<object> [--put <content-type>] [--minutes <n>] [--post-policy]\n";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;

    var target: ?Remote = null;
    var content_type: ?[]const u8 = null;
    var minutes: u32 = 15;
    var post_policy = false;
    var bad = false;
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = @min(1, args.len);
    while (i < args.len and !bad) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--put") and i + 1 < args.len) {
            i += 1;
            content_type = args[i];
        } else if (std.mem.eql(u8, arg, "--minutes") and i + 1 < args.len) {
            i += 1;
            minutes = std.fmt.parseInt(u32, args[i], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--post-policy")) {
            post_policy = true;
        } else if (target == null) {
            target = Remote.parse(arg);
            bad = target == null;
        } else {
            bad = true;
        }
    }
    // Only a policy can name a prefix instead of one object.
    if (!bad and target != null and target.?.name.len == 0 and !post_policy) bad = true;
    // Seven days is the longest Cloud Storage accepts.
    if (bad or target == null or minutes == 0 or minutes > 7 * 24 * 60) {
        try out.writeAll(usage);
        return out.flush();
    }

    var diag: storage.Diagnostics = .{};
    var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
    lookup.diagnostics = &diag;
    var creds = auth.findDefault(init.gpa, init.io, lookup, .{}) catch |err| return fail(err, &diag);
    defer creds.deinit();
    const signer = creds.signer() orelse {
        try out.print("cannot sign: {s} names no service account\n", .{creds.source.description()});
        return out.flush();
    };

    var client = storage.Client.init(init.gpa, init.io, .{
        .endpoint = storage.Endpoint.fromEnv(init.environ_map),
        .token_provider = creds.provider(),
        .diagnostics = &diag,
    }) catch |err| return fail(err, &diag);
    defer client.deinit();

    const account = signer.email(init.io, arena) catch |err| return fail(err, &diag);
    if (post_policy) {
        const fields: []const storage.PostField = if (content_type) |media_type|
            &.{.{ .name = "content-type", .value = media_type }}
        else
            &.{};
        const name = target.?.name;
        // A name ending in `/`, or none at all, is a prefix: the browser
        // names the object, under it.
        const exact = name.len != 0 and name[name.len - 1] != '/';
        const made = if (exact)
            client.bucket(target.?.bucket).object(name).postPolicy(signer, .{
                .expires_in_s = minutes * 60,
                .fields = fields,
            })
        else
            client.bucket(target.?.bucket).postPolicy(signer, .{
                .expires_in_s = minutes * 60,
                .key = .{ .starts_with = name },
                .fields = fields,
            });
        var policy = made catch |err| return fail(err, &diag);
        defer policy.deinit();
        try out.print("signed as {s}, good for {d} minutes:\n\n", .{ account, minutes });
        try out.print("<form action=\"{s}\" method=\"post\" enctype=\"multipart/form-data\">\n", .{policy.value.url});
        for (policy.value.fields) |field| {
            try out.writeAll("  <input type=\"hidden\" name=\"");
            try writeHtml(out, field.name);
            try out.writeAll("\" value=\"");
            try writeHtml(out, field.value);
            try out.writeAll("\">\n");
        }
        // `file` goes last: Cloud Storage reads the fields before it.
        try out.writeAll("  <input type=\"file\" name=\"file\">\n");
        try out.writeAll("  <input type=\"submit\" value=\"Upload\">\n</form>\n");
        return out.flush();
    }

    const object = client.bucket(target.?.bucket).object(target.?.name);
    const url = if (content_type) |media_type| object.signedUrl(signer, .{
        .method = .PUT,
        .expires_in_s = minutes * 60,
        .headers = &.{.{ .name = "content-type", .value = media_type }},
    }) else object.signedUrl(signer, .{
        .expires_in_s = minutes * 60,
    });
    var signed = url catch |err| return fail(err, &diag);
    defer signed.deinit();

    try out.print("signed as {s}, good for {d} minutes:\n", .{ account, minutes });
    if (content_type) |media_type| {
        try out.print("curl -X PUT -H 'content-type: {s}' --data-binary @FILE '{s}'\n", .{ media_type, signed.value });
    } else {
        try out.print("curl '{s}'\n", .{signed.value});
    }
    try out.flush();
}

/// `gs://bucket/object`, split. The object name is everything after the
/// bucket's slash, slashes and all.
const Remote = struct {
    bucket: []const u8,
    name: []const u8,

    fn parse(text: []const u8) ?Remote {
        const rest = if (std.mem.startsWith(u8, text, "gs://")) text["gs://".len..] else return null;
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        if (slash == 0) return null;
        // An empty name is a policy's "anywhere in the bucket"; the caller
        // refuses it for anything else.
        return .{ .bucket = rest[0..slash], .name = rest[slash + 1 ..] };
    }
};

/// The four characters that would end an HTML attribute early, or start
/// an entity. An object name may hold any of them.
fn writeHtml(out: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try out.writeAll("&amp;"),
        '<' => try out.writeAll("&lt;"),
        '>' => try out.writeAll("&gt;"),
        '"' => try out.writeAll("&quot;"),
        else => try out.writeByte(c),
    };
}

fn fail(err: anyerror, diag: *const storage.Diagnostics) anyerror {
    std.debug.print("error.{t}", .{err});
    if (diag.http_status != 0) std.debug.print(" (HTTP {d} {s})", .{ diag.http_status, diag.status() });
    if (diag.message().len != 0) std.debug.print(": {s}", .{diag.message()});
    std.debug.print("\n", .{});
    return err;
}
