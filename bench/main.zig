//! Microbenchmarks. Always built ReleaseFast (see build.zig).
//!
//! Each benchmark runs `warmup_count` untimed iterations, then
//! `sample_count` timed ones, and reports min/p50/p99/max latency plus
//! throughput (MB/s at the median). Per-iteration allocations go into an
//! arena that is reset (capacity retained) between iterations, so steady
//! state timing excludes page-faulting fresh memory.
//!
//! Fixtures live in `bench/fixtures/`; the path is injected by build.zig
//! as the `bench_options.fixtures_path` build option, so the bench runs
//! from any cwd.

const std = @import("std");
const Io = std.Io;
const yaml = @import("yaml");
const bench_options = @import("bench_options");

const warmup_count: usize = 10;
const sample_count: usize = 100;
const max_fixture_bytes: usize = 4 << 20;

const fixture_names = [_][]const u8{ "small.yaml", "medium.yaml", "large.yaml" };

/// Typed mirror of small.yaml for the parseInto benchmark.
const Config = struct {
    name: []const u8,
    version: []const u8,
    debug: bool,
    max_connections: u32,
    timeout_ms: f64,
    tags: []const []const u8,
    server: struct {
        host: []const u8,
        port: u16,
        tls: struct {
            enabled: bool,
            cert_path: []const u8,
            key_path: []const u8,
            min_version: []const u8,
        },
    },
    upstream: struct {
        endpoints: []const []const u8,
        retry: struct {
            max_attempts: u32,
            backoff_base_ms: u32,
            backoff_factor: f64,
            jitter: bool,
        },
    },
    limits: struct {
        queue_depth: u32,
        batch_size: u32,
        flush_interval_ms: u32,
        max_payload_bytes: u64,
        drop_on_overflow: bool,
    },
    log: struct {
        level: []const u8,
        format: []const u8,
        path: []const u8,
        rotate_mb: u32,
    },
    features: struct {
        compression: []const u8,
        dedupe: bool,
        sampling_rate: f64,
        histogram_buckets: []const f64,
    },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const static = init.arena.allocator();

    var dir = try Io.Dir.openDirAbsolute(io, bench_options.fixtures_path, .{});
    defer dir.close(io);

    var fixtures: [fixture_names.len][]u8 = undefined;
    for (fixture_names, 0..) |name, i| {
        fixtures[i] = try dir.readFileAlloc(io, name, static, .limited(max_fixture_bytes));
    }

    std.debug.print(
        "{s:<34} {s:>9} {s:>10} {s:>10} {s:>10} {s:>10} {s:>9}\n",
        .{ "benchmark", "size", "min", "p50", "p99", "max", "MB/s" },
    );

    // parse: exactly one document. Only single-document fixtures qualify;
    // the medium manifest is multi-document, so it is skipped here.
    for (fixture_names, fixtures) |name, src| {
        if (std.mem.indexOf(u8, src, "\n---\n") != null) continue;
        try benchParse(io, gpa, "parse", name, src);
    }
    for (fixture_names, fixtures) |name, src| {
        try benchParseStream(io, gpa, "parseStream", name, src);
    }
    for (fixture_names, fixtures) |name, src| {
        try benchEmit(io, gpa, static, "emit", name, src);
    }
    try benchParseInto(io, gpa, "parseInto (typed)", "small.yaml", fixtures[0]);
    try benchParseIntoBig(io, gpa, static);

    // Bounded-memory streaming bench: 100 000 small documents in one buffer,
    // streamed via ValueStream with a per-item arena reset. The doc_buf peak
    // capacity must stay proportional to ONE document, not to the total stream
    // length -- that is the bounded-memory guarantee. The bench prints peak
    // doc_buf capacity alongside throughput so regressions are visible.
    try benchValueStreamBounded(io, gpa, static);
}

fn benchParse(io: Io, gpa: std.mem.Allocator, label: []const u8, fixture: []const u8, src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var samples: [sample_count]u64 = undefined;

    var i: usize = 0;
    while (i < warmup_count + sample_count) : (i += 1) {
        _ = arena.reset(.retain_capacity);
        const t0: Io.Timestamp = .now(io, .awake);
        const v = try yaml.parse(arena.allocator(), src, .{});
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
        std.mem.doNotOptimizeAway(&v);
        if (i >= warmup_count) samples[i - warmup_count] = ns;
    }
    report(label, fixture, src.len, &samples);
}

fn benchParseStream(io: Io, gpa: std.mem.Allocator, label: []const u8, fixture: []const u8, src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var samples: [sample_count]u64 = undefined;

    var i: usize = 0;
    while (i < warmup_count + sample_count) : (i += 1) {
        _ = arena.reset(.retain_capacity);
        const t0: Io.Timestamp = .now(io, .awake);
        const docs = try yaml.parseStream(arena.allocator(), src, .{});
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
        std.mem.doNotOptimizeAway(&docs);
        if (i >= warmup_count) samples[i - warmup_count] = ns;
    }
    report(label, fixture, src.len, &samples);
}

fn benchEmit(io: Io, gpa: std.mem.Allocator, static: std.mem.Allocator, label: []const u8, fixture: []const u8, src: []const u8) !void {
    // Parse once outside the timed region; only emitting is measured.
    const docs = try yaml.parseStream(static, src, .{});

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var samples: [sample_count]u64 = undefined;
    var out_len: usize = 0;

    var i: usize = 0;
    while (i < warmup_count + sample_count) : (i += 1) {
        aw.clearRetainingCapacity();
        const t0: Io.Timestamp = .now(io, .awake);
        try yaml.emitStream(&aw.writer, docs, .{});
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
        out_len = aw.written().len;
        if (i >= warmup_count) samples[i - warmup_count] = ns;
    }
    // Throughput is measured against the bytes produced, not the fixture
    // size: re-emitted YAML differs slightly in length from the input.
    report(label, fixture, out_len, &samples);
}

fn benchParseInto(io: Io, gpa: std.mem.Allocator, label: []const u8, fixture: []const u8, src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var samples: [sample_count]u64 = undefined;

    var i: usize = 0;
    while (i < warmup_count + sample_count) : (i += 1) {
        _ = arena.reset(.retain_capacity);
        const t0: Io.Timestamp = .now(io, .awake);
        const cfg = try yaml.parseInto(Config, arena.allocator(), src, .{});
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
        std.mem.doNotOptimizeAway(&cfg);
        if (i >= warmup_count) samples[i - warmup_count] = ns;
    }
    report(label, fixture, src.len, &samples);
}

/// Large typed-decode bench: a multi-MB block sequence of uniform records
/// decoded into a slice of structs. This is the workload where typed decode
/// throughput matters most (config files are small; data files are not).
fn benchParseIntoBig(io: Io, gpa: std.mem.Allocator, static: std.mem.Allocator) !void {
    const Rec = struct {
        id: u64,
        name: []const u8,
        active: bool,
        score: f64,
        tags: []const []const u8,
    };
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < 30_000) : (i += 1) {
        try buf.print(
            static,
            "- id: {d}\n  name: record-{d}-with-some-name\n  active: {}\n  score: {d}.5\n  tags: [alpha, beta-{d}]\n",
            .{ i, i, i % 2 == 0, i % 100, i % 97 },
        );
    }
    const src = buf.items;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var samples: [sample_count]u64 = undefined;

    var it: usize = 0;
    while (it < warmup_count + sample_count) : (it += 1) {
        _ = arena.reset(.retain_capacity);
        const t0: Io.Timestamp = .now(io, .awake);
        const recs = try yaml.parseInto([]const Rec, arena.allocator(), src, .{});
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
        std.mem.doNotOptimizeAway(&recs);
        if (it >= warmup_count) samples[it - warmup_count] = ns;
    }
    report("parseInto (typed big)", "records (gen)", src.len, &samples);
}

/// Bounded-memory streaming bench. Builds a large synthetic N-document YAML
/// stream (100 000 small documents, each ~40 bytes), then streams it via
/// ValueStream with a per-item arena reset between documents.
///
/// The key property under test: the EventReader's internal doc_buf grows to
/// roughly ONE document's size and stays there, regardless of how many
/// documents the stream contains. The reported peak capacity is the regression
/// guard: it must not grow with N.
fn benchValueStreamBounded(io: Io, gpa: std.mem.Allocator, static: std.mem.Allocator) !void {
    const n_docs = 100_000;

    // Build the synthetic stream: N documents separated by `---`.
    // Each document: "host: host-NNNNN\nport: NNNNN\n" (~25-30 bytes).
    var buf: std.Io.Writer.Allocating = .init(static);
    defer buf.deinit();
    for (0..n_docs) |i| {
        if (i > 0) _ = try buf.writer.write("---\n");
        try buf.writer.print("host: host-{d}\nport: {d}\n", .{ i, i });
    }
    const stream_src = buf.written();
    const stream_bytes = stream_src.len;

    // Single document's byte length (rough reference for the cap assertion).
    const one_doc_approx: usize = stream_bytes / n_docs + 8;

    var samples: [sample_count]u64 = undefined;
    var peak_cap: usize = 0;

    var i: usize = 0;
    while (i < warmup_count + sample_count) : (i += 1) {
        var item_arena = std.heap.ArenaAllocator.init(gpa);
        defer item_arena.deinit();

        var r: std.Io.Reader = .fixed(stream_src);
        var vs = yaml.ValueStream.fromReader(gpa, &r, .{});
        defer vs.deinit();

        const t0: Io.Timestamp = .now(io, .awake);
        var count: usize = 0;
        while (try vs.next(item_arena.allocator())) |v| {
            std.mem.doNotOptimizeAway(&v);
            count += 1;
            _ = item_arena.reset(.retain_capacity);
        }
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);

        const cap = vs.inner.bufCapacity();
        if (i >= warmup_count) {
            samples[i - warmup_count] = ns;
            if (cap > peak_cap) peak_cap = cap;
        }
    }

    report("ValueStream 100k docs", "(synthetic)", stream_bytes, &samples);

    // The peak doc_buf capacity must stay bounded to roughly one document's
    // size plus a pull chunk (4 KiB). The EventReader's chunk size is 4 KiB,
    // so the steady-state capacity is at most a few pull chunks, regardless of
    // how many documents the stream contains. We set the limit at 64 KiB --
    // 16x the pull chunk -- as a generous regression guard. A capacity near the
    // full stream size (3+ MB) would indicate the bounded-memory guarantee has
    // regressed. If this fires, the reader is buffering the whole stream.
    const cap_limit = 64 * 1024;
    if (peak_cap > cap_limit) {
        std.debug.print(
            "BOUNDED-MEMORY FAIL: peak doc_buf capacity {d} B exceeds limit {d} B (one_doc_approx={d} B)\n",
            .{ peak_cap, cap_limit, one_doc_approx },
        );
        std.process.exit(1);
    }

    std.debug.print(
        "  bounded-memory: peak doc_buf capacity = {d} B  (one_doc_approx = {d} B, n_docs = {d})\n",
        .{ peak_cap, one_doc_approx, n_docs },
    );
}

fn report(label: []const u8, fixture: []const u8, bytes: usize, samples: []u64) void {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const min = samples[0];
    const p50 = samples[samples.len / 2];
    // Nearest-rank p99: ceil(0.99 * n)-th order statistic.
    const p99 = samples[(samples.len * 99 - 1) / 100];
    const max = samples[samples.len - 1];

    const mbps = (@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)) /
        (@as(f64, @floatFromInt(p50)) / std.time.ns_per_s);

    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s} {s}", .{ label, fixture }) catch label;

    var size_buf: [16]u8 = undefined;
    const size = std.fmt.bufPrint(&size_buf, "{Bi:.1}", .{bytes}) catch "?";

    std.debug.print("{s:<34} {s:>9} {s:>10} {s:>10} {s:>10} {s:>10} {d:>9.1}\n", .{
        name, size, fmtNs(min), fmtNs(p50), fmtNs(p99), fmtNs(max), mbps,
    });
}

/// Format a nanosecond count with a unit suffix into a static buffer.
/// Each call reuses one of four rotating buffers so a single print
/// statement can hold up to four formatted values at once.
var ns_bufs: [4][16]u8 = undefined;
var ns_buf_idx: usize = 0;
fn fmtNs(ns: u64) []const u8 {
    const buf = &ns_bufs[ns_buf_idx];
    ns_buf_idx = (ns_buf_idx + 1) % ns_bufs.len;
    const f = @as(f64, @floatFromInt(ns));
    return if (ns < 1_000)
        std.fmt.bufPrint(buf, "{d} ns", .{ns}) catch "?"
    else if (ns < 1_000_000)
        std.fmt.bufPrint(buf, "{d:.2} us", .{f / 1_000.0}) catch "?"
    else
        std.fmt.bufPrint(buf, "{d:.2} ms", .{f / 1_000_000.0}) catch "?";
}
