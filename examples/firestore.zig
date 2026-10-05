//! Reads and writes Firestore documents from the command line.
//!
//!     zig build example-firestore -- set cities/LA name=Los\ Angeles population=3900000
//!     ... -- add cities name=Somewhere
//!     ... -- get cities/LA
//!     ... -- update cities/LA population=4000000 --delete nickname
//!     ... -- incr cities/LA visits 1
//!     ... -- getall cities/LA cities/SF
//!     ... -- query cities population '>' 1000000 --order population:desc --limit 2
//!     ... -- count cities state == CA
//!     ... -- transfer accounts/alice accounts/bob balance 25
//!     ... -- ls cities
//!     ... -- collections [cities/LA]
//!     ... -- rm cities/LA
//!
//! A value that reads as an integer is one, likewise a double, `true`,
//! `false` and `null`; anything else is a string. `update` changes only
//! the fields named and must find the document; `set` replaces it whole.
//! `incr` adds to a number on the server, creating the field (and the
//! document) when missing, so concurrent increments never lose one;
//! `getall` reads several documents in one request. `query` and `count`
//! take conditions as FIELD OP VALUE triples, OP one of `==`, `!=`, `<`,
//! `<=`, `>`, `>=` and `contains` (an array holding the value), and
//! `--group` reads every collection of that id at any depth. `transfer`
//! moves an amount from one document's field to another's in a
//! transaction: both read, both written, or neither, and refused when the
//! first holds too little; contention runs it again.
//! `--project` names the project, by default GOOGLE_CLOUD_PROJECT, or
//! `test` against the emulator; `--database` a named database.
//!
//! With FIRESTORE_EMULATOR_HOST set, this talks to the emulator and needs
//! no credentials; otherwise they come from `auth.findDefault`.

const std = @import("std");
const auth = @import("auth");
const firestore = @import("firestore");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .gcp_firestore, .level = .warn }},
};

const usage =
    \\usage: firestore set DOC_PATH FIELD=VALUE...
    \\       firestore add COLLECTION_PATH FIELD=VALUE...
    \\       firestore get DOC_PATH
    \\       firestore update DOC_PATH FIELD=VALUE... [--delete FIELD]...
    \\       firestore incr DOC_PATH FIELD AMOUNT
    \\       firestore getall DOC_PATH...
    \\       firestore query COLLECTION [FIELD OP VALUE]... [--order FIELD[:desc]] [--limit N] [--group]
    \\       firestore count COLLECTION [FIELD OP VALUE]... [--group]
    \\       firestore transfer FROM_DOC TO_DOC FIELD AMOUNT
    \\       firestore ls COLLECTION_PATH
    \\       firestore collections [DOC_PATH]
    \\       firestore rm DOC_PATH
    \\options: --project PROJECT  --database DATABASE
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var positional: std.ArrayList([]const u8) = .empty;
    var deletes: std.ArrayList([]const u8) = .empty;
    var project: ?[]const u8 = init.environ_map.get("GOOGLE_CLOUD_PROJECT");
    var database: []const u8 = "(default)";
    var orders: std.ArrayList(firestore.Order) = .empty;
    var limit: ?u32 = null;
    var group = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--group")) {
            group = true;
        } else if (std.mem.eql(u8, arg, "--delete") or std.mem.eql(u8, arg, "--project") or std.mem.eql(u8, arg, "--database") or
            std.mem.eql(u8, arg, "--order") or std.mem.eql(u8, arg, "--limit"))
        {
            i += 1;
            if (i == args.len) return badUsage(out);
            if (std.mem.eql(u8, arg, "--delete")) {
                try deletes.append(arena, args[i]);
            } else if (std.mem.eql(u8, arg, "--project")) {
                project = args[i];
            } else if (std.mem.eql(u8, arg, "--order")) {
                const desc = std.mem.endsWith(u8, args[i], ":desc");
                const field = if (desc) args[i][0 .. args[i].len - ":desc".len] else args[i];
                try orders.append(arena, .{ .field = field, .direction = if (desc) .descending else .ascending });
            } else if (std.mem.eql(u8, arg, "--limit")) {
                limit = std.fmt.parseInt(u32, args[i], 10) catch return badUsage(out);
            } else database = args[i];
        } else try positional.append(arena, arg);
    }
    const p = positional.items;
    if (p.len < 1) return badUsage(out);

    const endpoint = firestore.Endpoint.fromEnv(init.environ_map);
    var diag: firestore.Diagnostics = .{};
    var creds: ?auth.Credentials = null;
    defer if (creds) |*c| c.deinit();
    if (endpoint == null) {
        var lookup = try auth.Lookup.fromEnv(init.environ_map, arena);
        lookup.diagnostics = &diag;
        creds = auth.findDefault(init.gpa, init.io, lookup, .{}) catch |err| return fail(err, &diag);
        if (project == null) project = creds.?.projectId(init.io, arena) catch null;
    }
    var client = firestore.Client.init(init.gpa, init.io, .{
        .project_id = project orelse if (endpoint != null) "test" else {
            std.debug.print("error: no project: pass --project or set GOOGLE_CLOUD_PROJECT\n", .{});
            return error.BadUsage;
        },
        .database_id = database,
        .endpoint = endpoint,
        .token_provider = if (creds) |c| c.provider() else null,
        .diagnostics = &diag,
    }) catch |err| return fail(err, &diag);
    defer client.deinit();

    const command = p[0];
    if (std.mem.eql(u8, command, "set") or std.mem.eql(u8, command, "update") or std.mem.eql(u8, command, "add")) {
        if (p.len < 2) return badUsage(out);
        const fields = try parseFields(arena, p[2..]);
        if (std.mem.eql(u8, command, "add")) {
            var made = client.collection(p[1]).create(fields, .{}) catch |err| return fail(err, &diag);
            defer made.deinit();
            try out.print("created {s}\n", .{made.value.path()});
            return;
        }
        const doc = client.doc(p[1]);
        const written = if (std.mem.eql(u8, command, "set"))
            doc.set(fields, .{}) catch |err| return fail(err, &diag)
        else written: {
            // The fields given, each replaced whole, and the deletes.
            const mask = try arena.alloc([]const u8, fields.len + deletes.items.len);
            for (fields, 0..) |f, n| mask[n] = try firestore.field_path.ofName(arena, f.name);
            for (deletes.items, fields.len..) |d, n| mask[n] = try firestore.field_path.ofName(arena, d);
            break :written doc.update(fields, .{ .mask = mask }) catch |err| return fail(err, &diag);
        };
        try out.print("written at {d} ns\n", .{written.update_time.nanoseconds});
    } else if (std.mem.eql(u8, command, "incr")) {
        if (p.len != 4) return badUsage(out);
        const amount: firestore.Numeric = if (std.fmt.parseInt(i64, p[3], 10)) |n| .{ .integer = n } else |_| .{
            .double = std.fmt.parseFloat(f64, p[3]) catch return badUsage(out),
        };
        // A commit, for the transform's result: the field's new value.
        var result = client.commit(&.{.{ .update = .{
            .path = p[1],
            .mask = &.{},
            .transforms = &.{.{ .field_path = try firestore.field_path.ofName(arena, p[2]), .op = .{ .increment = amount } }},
        } }}, .{}) catch |err| return fail(err, &diag);
        defer result.deinit();
        try out.print("{s} is now ", .{p[2]});
        try printValue(out, result.value.writes[0].transform_results[0]);
        try out.writeAll("\n");
    } else if (std.mem.eql(u8, command, "getall")) {
        if (p.len < 2) return badUsage(out);
        var r = client.batchGet(p[1..], .{}) catch |err| return fail(err, &diag);
        defer r.deinit();
        for (p[1..], r.value.documents) |path, d| {
            if (d) |doc| try printDoc(out, doc) else try out.print("{s}: missing\n", .{path});
        }
    } else if (std.mem.eql(u8, command, "query") or std.mem.eql(u8, command, "count")) {
        if (p.len < 2 or (p.len - 2) % 3 != 0) return badUsage(out);
        const where = try arena.alloc(firestore.Condition, (p.len - 2) / 3);
        for (where, 0..) |*c, n| {
            const t = p[2 + 3 * n ..][0..3];
            c.* = .{ .field = t[0], .op = parseOp(t[1]) orelse return badUsage(out), .value = parseValue(t[2]) };
        }
        const query: firestore.Query = .{
            .from = if (group) .{ .group = p[1] } else .{ .collection = p[1] },
            .where = where,
            .order_by = orders.items,
            .limit = limit,
        };
        if (std.mem.eql(u8, command, "count")) {
            var r = client.runAggregationQuery(query, &.{.{ .count = .{} }}, .{}) catch |err| return fail(err, &diag);
            defer r.deinit();
            try out.print("{d}\n", .{r.value.values[0].integer});
        } else {
            var r = client.runQuery(query, .{}) catch |err| return fail(err, &diag);
            defer r.deinit();
            for (r.value.documents) |d| try printDoc(out, d);
        }
    } else if (std.mem.eql(u8, command, "transfer")) {
        if (p.len != 5) return badUsage(out);
        var transfer: Transfer = .{
            .from = p[1],
            .to = p[2],
            .field = p[3],
            .amount = std.fmt.parseInt(i64, p[4], 10) catch return badUsage(out),
        };
        client.runTransaction(transfer.handler(), .{}) catch |err| {
            if (err == error.InsufficientFunds) {
                std.debug.print("error: {s} holds {d}, less than {d}\n", .{ transfer.from, transfer.balance, transfer.amount });
                return err;
            }
            return fail(err, &diag);
        };
        try out.print("moved {d}: {s} now holds {d}, {s} {d}\n", .{ transfer.amount, transfer.from, transfer.balance - transfer.amount, transfer.to, transfer.received + transfer.amount });
    } else if (std.mem.eql(u8, command, "get")) {
        if (p.len != 2) return badUsage(out);
        var got = client.doc(p[1]).get(.{}) catch |err| return fail(err, &diag);
        defer got.deinit();
        try printDoc(out, got.value);
    } else if (std.mem.eql(u8, command, "ls")) {
        if (p.len != 2) return badUsage(out);
        var token: ?[]const u8 = null;
        while (true) {
            var page = client.collection(p[1]).list(.{ .page_token = token }) catch |err| return fail(err, &diag);
            defer page.deinit();
            for (page.value.documents) |d| try printDoc(out, d);
            token = try arena.dupe(u8, page.value.next_page_token orelse break);
        }
    } else if (std.mem.eql(u8, command, "collections")) {
        if (p.len > 2) return badUsage(out);
        var token: ?[]const u8 = null;
        while (true) {
            const options: firestore.ListCollectionIdsOptions = .{ .page_token = token };
            var page = (if (p.len == 2) client.doc(p[1]).listCollectionIds(options) else client.listCollectionIds(options)) catch |err|
                return fail(err, &diag);
            defer page.deinit();
            for (page.value.collection_ids) |id| try out.print("{s}\n", .{id});
            token = try arena.dupe(u8, page.value.next_page_token orelse break);
        }
    } else if (std.mem.eql(u8, command, "rm")) {
        if (p.len != 2) return badUsage(out);
        client.doc(p[1]).delete(.{}) catch |err| return fail(err, &diag);
        try out.print("deleted {s}\n", .{p[1]});
    } else return badUsage(out);
}

/// `name=value` pairs as fields.
fn parseFields(arena: std.mem.Allocator, pairs: []const []const u8) ![]const firestore.Field {
    const fields = try arena.alloc(firestore.Field, pairs.len);
    for (pairs, fields) |pair, *f| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
            std.debug.print("error: expected FIELD=VALUE, got {s}\n", .{pair});
            return error.BadUsage;
        };
        f.* = .{ .name = pair[0..eq], .value = parseValue(pair[eq + 1 ..]) };
    }
    return fields;
}

/// Moves `amount` of `field` from one document to another, as a
/// transaction's handler: run again from the start whenever the server
/// aborts the transaction, so it only reads and writes through `txn`.
const Transfer = struct {
    from: []const u8,
    to: []const u8,
    field: []const u8,
    amount: i64,
    /// What the documents held when last read.
    balance: i64 = 0,
    received: i64 = 0,

    fn handler(self: *Transfer) firestore.TransactionHandler {
        return .{ .ptr = self, .vtable = &.{ .run = run } };
    }

    fn run(ptr: *anyopaque, txn: *firestore.Transaction) anyerror!void {
        const self: *Transfer = @ptrCast(@alignCast(ptr));
        var both = try txn.batchGet(&.{ self.from, self.to }, .{});
        defer both.deinit();
        self.balance = number(both.value.documents[0], self.field);
        self.received = number(both.value.documents[1], self.field);
        if (self.balance < self.amount) return error.InsufficientFunds;
        try txn.set(self.from, &.{.{ .name = self.field, .value = .{ .integer = self.balance - self.amount } }}, .{});
        try txn.set(self.to, &.{.{ .name = self.field, .value = .{ .integer = self.received + self.amount } }}, .{});
    }

    /// The document's integer `field`, 0 when it or the field is missing.
    fn number(doc: ?firestore.Snapshot, field: []const u8) i64 {
        const d = doc orelse return 0;
        const v = d.get(field) orelse return 0;
        return if (v == .integer) v.integer else 0;
    }
};

fn parseOp(text: []const u8) ?firestore.Operator {
    const ops = std.StaticStringMap(firestore.Operator).initComptime(.{
        .{ "==", .equal },                .{ "!=", .not_equal },   .{ "<", .less_than },
        .{ "<=", .less_than_or_equal },   .{ ">", .greater_than }, .{ ">=", .greater_than_or_equal },
        .{ "contains", .array_contains },
    });
    return ops.get(text);
}

fn parseValue(text: []const u8) firestore.Value {
    if (std.mem.eql(u8, text, "null")) return .null;
    if (std.mem.eql(u8, text, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, text, "false")) return .{ .boolean = false };
    if (std.fmt.parseInt(i64, text, 10)) |n| return .{ .integer = n } else |_| {}
    if (text.len > 0 and (std.ascii.isDigit(text[0]) or text[0] == '-')) {
        if (std.fmt.parseFloat(f64, text)) |d| return .{ .double = d } else |_| {}
    }
    return .{ .string = text };
}

fn printDoc(out: *std.Io.Writer, doc: firestore.Snapshot) !void {
    try out.print("{s}\n", .{doc.path()});
    try printFields(out, doc.fields, 1);
}

fn printFields(out: *std.Io.Writer, fields: []const firestore.Field, depth: usize) !void {
    for (fields) |f| {
        try out.splatByteAll(' ', depth * 2);
        try out.print("{s}: ", .{f.name});
        switch (f.value) {
            .map => |m| {
                try out.writeAll("\n");
                try printFields(out, m, depth + 1);
            },
            else => {
                try printValue(out, f.value);
                try out.writeAll("\n");
            },
        }
    }
}

fn printValue(out: *std.Io.Writer, v: firestore.Value) !void {
    switch (v) {
        .null => try out.writeAll("null"),
        .boolean => |b| try out.print("{}", .{b}),
        .integer => |n| try out.print("{d}", .{n}),
        .double => |d| try out.print("{d}", .{d}),
        .timestamp => |t| try out.print("{d} ns", .{t.nanoseconds}),
        .string => |s| try out.print("\"{s}\"", .{s}),
        .bytes => |b| try out.print("{d} bytes", .{b.len}),
        .reference => |r| try out.print("-> {s}", .{r}),
        .geo_point => |g| try out.print("({d}, {d})", .{ g.latitude, g.longitude }),
        .array => |items| {
            try out.writeAll("[");
            for (items, 0..) |item, n| {
                if (n > 0) try out.writeAll(", ");
                try printValue(out, item);
            }
            try out.writeAll("]");
        },
        .map => |m| try out.print("{{{d} fields}}", .{m.len}),
    }
}

fn badUsage(out: *std.Io.Writer) !void {
    try out.writeAll(usage);
    try out.flush();
    return error.BadUsage;
}

fn fail(err: anyerror, diag: *const firestore.Diagnostics) anyerror {
    if (diag.message().len > 0) {
        std.debug.print("error: {t}: {s}\n", .{ err, diag.message() });
    } else {
        std.debug.print("error: {t}\n", .{err});
    }
    return err;
}
