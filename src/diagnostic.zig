//! Multi-error diagnostics for the YAML parse pipeline.
//!
//! `Diagnostic` is one collected parse error: a message, the source span
//! it points at, and an optional "did you mean" suggestion. `Sink` is the
//! shared error funnel: every parse failure routes through `fail` /
//! `failFmt`, which record a `Diagnostic` when an error list is set and
//! always return `error.YamlParseError`. The composer owns one `Sink` per
//! parse and threads a pointer to it into the parser, so scanner-level
//! `.invalid` tokens and parser grammar errors record at the point of
//! failure with the span they already carry.

const std = @import("std");
const Span = @import("value.zig").Span;

/// One collected parse error: what went wrong and where.
///
/// The span stores byte offsets only; 1-indexed line/col are derived on
/// demand from the span and the original source at render time. Line/col and
/// the `renderRich` caret alignment count bytes, not codepoints or display
/// columns: tabs and multi-byte UTF-8 characters earlier on the line shift the
/// caret relative to what a terminal renders.
pub const Diagnostic = struct {
    /// Arena-allocated. Lifetime: the parse arena.
    message: []const u8,
    /// Source byte range of the offending token. Zero-length (start ==
    /// end) when the error site has no token, e.g. unexpected EOF.
    span: Span,
    /// "Did you mean X?" suggestion. Set when a typo'd key or value is
    /// rejected with a close-enough candidate. Arena-allocated.
    suggestion: ?[]const u8 = null,

    /// Single-line summary. Line/col are derived from the span offset against
    /// `src` (the original parsed bytes). Not named `format`: std.fmt treats a
    /// `format` decl as the `{f}` formatter and requires the
    /// `(self, *Io.Writer)` signature, which cannot carry `src`.
    pub fn render(self: Diagnostic, writer: *std.Io.Writer, src: []const u8) !void {
        const lc = self.span.lineCol(src);
        try writer.print("YAML parse error at {d}:{d}: {s}", .{ lc.line, lc.col, self.message });
    }

    /// Multi-line rich form. Emits a rustc-style block: header, source
    /// line with caret underline, suggestion. Caller provides the
    /// original source bytes (the same slice passed to `parse`).
    /// ASCII only -- no terminal color escapes.
    pub fn renderRich(self: Diagnostic, w: *std.Io.Writer, source: []const u8) !void {
        const lc = self.span.lineCol(source);
        try w.print("error at {d}:{d}: {s}\n", .{ lc.line, lc.col, self.message });

        // Source snippet (only if line/col and source bounds match).
        blk: {
            var line_start: usize = 0;
            var lineno: u32 = 1;
            var i: usize = 0;
            while (i < source.len and lineno < lc.line) : (i += 1) {
                if (source[i] == '\n') {
                    lineno += 1;
                    line_start = i + 1;
                }
            }
            if (lineno != lc.line) break :blk;
            var line_end = line_start;
            while (line_end < source.len and source[line_end] != '\n') line_end += 1;

            const line_text = source[line_start..line_end];
            try w.print("  |\n{d:>3} | {s}\n  | ", .{ lc.line, line_text });

            // Caret column and width, both clamped to the line end (an
            // EOF span lands one column past the last byte).
            const start: usize = @intCast(self.span.start);
            const col0 = if (start >= line_start) @min(start - line_start, line_text.len) else 0;
            const end = @min(@as(usize, @intCast(self.span.end)), line_end);
            const carets = if (end > start) end - start else 1;
            var c: usize = 0;
            while (c < col0) : (c += 1) try w.writeByte(' ');
            var k: usize = 0;
            while (k < carets) : (k += 1) try w.writeByte('^');
            try w.writeByte('\n');
        }

        if (self.suggestion) |s| {
            try w.print("  = help: did you mean `{s}`?\n", .{s});
        }
    }
};

/// Cap on diagnostics recorded by recovery in one parse. Past this the
/// funnel stops being recoverable and the parse aborts.
pub const MAX_RECOVERY_ERRORS: usize = 100;

/// The shared error funnel. Carries the optional caller error list and a
/// per-parse `error_count`. The caller's list may hold entries from an
/// earlier parse, so both the end-of-parse "any errors?" decision and the
/// recovery cap count `error_count`, not the list length -- that lets a
/// reused, already-non-empty list still drive a clean parse to success.
pub const Sink = struct {
    arena: std.mem.Allocator,
    errors: ?*std.ArrayList(Diagnostic),
    /// Errors recorded during THIS parse (not the caller list length).
    error_count: usize = 0,

    pub fn init(arena: std.mem.Allocator, errors: ?*std.ArrayList(Diagnostic)) Sink {
        return .{ .arena = arena, .errors = errors };
    }

    /// Every parse failure routes through here (or `failFmt`): records a
    /// Diagnostic when an error list is set, then returns
    /// `error.YamlParseError`. With no list this is allocation-free.
    pub fn fail(self: *Sink, span: Span, message: []const u8) error{ YamlParseError, OutOfMemory } {
        self.error_count += 1;
        if (self.errors) |list| {
            const owned = self.arena.dupe(u8, message) catch return error.OutOfMemory;
            list.append(self.arena, .{ .message = owned, .span = span }) catch return error.OutOfMemory;
        }
        return error.YamlParseError;
    }

    pub fn failFmt(self: *Sink, span: Span, comptime fmt: []const u8, args: anytype) error{ YamlParseError, OutOfMemory } {
        self.error_count += 1;
        if (self.errors) |list| {
            const msg = std.fmt.allocPrint(self.arena, fmt, args) catch return error.OutOfMemory;
            list.append(self.arena, .{ .message = msg, .span = span }) catch return error.OutOfMemory;
        }
        return error.YamlParseError;
    }

    /// True when an error sink is set and the cap has room: a recorded
    /// error may be recovered from rather than aborting the parse.
    pub fn recoverable(self: *Sink) bool {
        return self.errors != null and self.error_count < MAX_RECOVERY_ERRORS;
    }
};
