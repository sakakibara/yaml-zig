# yaml

A YAML 1.2.2 parser, decoder, and emitter for Zig.

- **YAML 1.2.2 parsing** - block and flow collections, anchors and aliases,
  merge keys (`<<`), multi-document streams, tags, and every scalar style:
  plain, single- and double-quoted, and literal (`|`) / folded (`>`) block
  scalars.
- **Typed decoding** - `parseInto(Config, arena, src, .{})` deserializes
  straight into your Zig struct via comptime reflection, in a single
  streaming pass with no intermediate value tree for documents without
  anchors, aliases, or merge keys. Field renames,
  flatten/skip, tagged unions, and `fromYaml`/`toYaml` hooks are all
  supported. No codegen.
- **Byte-precise spans** - every value (top-level or deeply nested) carries
  an exact `u64` byte range; 1-indexed line/col are derived on demand via
  `Span.lineCol`. No input-size cap.
- **Multi-error diagnostics** - one pass collects every parse error, with
  rustc-style rendering: source excerpt, caret underline, and "did you
  mean" suggestions.
- **Round-trip-safe emitter** - a block-style emitter that picks the
  narrowest safe scalar style and quotes anything that would otherwise
  re-resolve to the wrong type (`"true"` stays a string, not a bool).
- **Lossless document model** - parse, edit, and emit byte-identical when
  unmodified and minimal-diff when edited; comments, formatting, anchors,
  and quoting are preserved. Validated round-tripping all 309 parseable
  yaml-test-suite cases byte-for-byte.
- **Schema selection** - resolve plain scalars under the `failsafe`, `json`,
  or `core` (default) schema.
- **Conformance, honestly measured** - validated against the
  [yaml-test-suite](https://github.com/yaml/yaml-test-suite): 291 cases
  match the reference event stream byte-for-byte, and of 94 error-marked
  cases 82 are correctly rejected (the other 12 are not yet rejected and are
  policy-documented). 309 cases survive a parse -> emit -> parse round-trip.
  In total 21 cases are explicitly policy-documented as known divergences
  (see [Conformance](#conformance)). This passes the common real-world
  subset; full conformance is ongoing.
- **Fast** - single-pass, arena-allocated, zero-copy scalars where possible,
  SIMD string scanning. Run `zig build bench` to measure on your hardware.
- **Portable** - builds on every target Zig supports (cross-compiled in CI).
  No global state.
- **No dependencies** - pure Zig, libc-free.

```zig
const yaml = @import("yaml");

const Config = struct {
    name: []const u8,
    port: u16 = 8080,
    server: struct {
        host: []const u8,
        tls: bool = false,
    },
};

var arena_state = std.heap.ArenaAllocator.init(gpa);
defer arena_state.deinit();
const arena = arena_state.allocator();

const cfg = try yaml.parseInto(Config, arena, src, .{});
```

## Install

Requires Zig 0.16.0 or newer.

```sh
zig fetch --save git+https://github.com/sakakibara/yaml-zig
```

In `build.zig`:

```zig
const yaml = b.dependency("yaml", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("yaml", yaml.module("yaml"));
```

## Quickstart

### Parse a single document

```zig
const std = @import("std");
const yaml = @import("yaml");

var arena_state = std.heap.ArenaAllocator.init(gpa);
defer arena_state.deinit();
const arena = arena_state.allocator();

const v = try yaml.parse(arena,
    \\server:
    \\  host: localhost
    \\  port: 8080
, .{});

const port = v.getT(i64, "server.port") orelse 8080;
```

`getT` walks dotted paths with `[N]` sequence indices (`tags[0]`) and
returns `null` on a missing path or type mismatch. `parse` requires exactly
one document; zero or more than one is an error.

### Parse a multi-document stream

```zig
const docs = try yaml.parseStream(arena,
    \\name: alice
    \\---
    \\name: bob
, .{});

for (docs) |doc| {
    const name = doc.getT([]const u8, "name") orelse "?";
    std.debug.print("{s}\n", .{name});
}
```

`parseStream` returns a slice with one `Value` per document (zero or more).

### Typed decoding

Decode straight into a struct. Field defaults are honored; optionals become
`null` when absent; unknown YAML keys raise `error.UnknownField` (opt out
with `.ignore_unknown_fields = true`).

```zig
const Config = struct {
    name: []const u8,
    port: u16 = 8080,
    nick: ?[]const u8 = null,
    tags: []const []const u8,
    server: struct {
        host: []const u8,
        tls: bool = false,
    },
};

const cfg = try yaml.parseInto(Config, arena, src, .{});
```

Supported types: `bool`, all int/float widths (overflow-checked),
`[]const u8`, slices, fixed-size arrays, optionals, nested structs, enums
(string name or integer tag), and `union(enum)` (tagged-union via the
`yaml_tag` annotation -- see below). Embed a raw `yaml.Value` to keep a
dynamic substructure.

Decode honors these `pub const` annotations on the target type:

```zig
const Server = struct {
    pub const yaml_rename = .{ .listen_addr = "listen-addr" };
    pub const yaml_flatten = .{"common"};
    pub const yaml_skip = .{"runtime"};

    listen_addr: []const u8,
    common: CommonConfig, // sub-keys decode from the parent mapping
    runtime: u32 = 0,     // excluded from decode/encode
};
```

A typo'd annotation entry fails the build. For custom (de)serialization of a
type, provide either or both hooks on the type:

```zig
pub fn fromYaml(arena: Allocator, value: Value, options: ParseOptions) DecodeError!Self;
pub fn toYaml(self: Self, arena: Allocator) Allocator.Error!Value;
```

Tagged unions decode by a discriminator key:

```zig
const Plugin = union(enum) {
    pub const yaml_tag = "kind";

    http: HttpConfig,
    grpc: GrpcConfig,
};
```

`kind: http` in the mapping picks the `.http` variant; the remaining keys
decode as `HttpConfig`. For variant-name overrides, use `yaml_rename` on the
union itself.

### Emit (block-style)

```zig
const v = try yaml.parse(arena,
    \\title: config
    \\flag_word: "true"
, .{});

var aw: std.Io.Writer.Allocating = .init(arena);
defer aw.deinit();
try yaml.emit(&aw.writer, v, .{});
```

`emit` writes one `Value` as block YAML; `emitStream` writes a slice of
documents separated by `---`. The emitter chooses the narrowest
round-trip-safe scalar style: `flag_word: "true"` stays double-quoted so it
re-parses as the string `"true"`, not the boolean `true`. Empty collections
emit flow-empty `{}` / `[]`.

To emit a typed value (consulting the same annotations and the `toYaml`
hook), use `emitTyped`:

```zig
const cfg: Config = .{ .name = "svc", .server = .{ .host = "localhost" } };
try yaml.emitTyped(&aw.writer, cfg, arena, .{});
```

The value's own type drives annotation lookup, so pass a typed value as
above: an anonymous struct literal carries no declarations, and the
annotations would silently not apply.

For tagged unions (`yaml_tag`), the discriminator key is emitted first with
the payload's fields inline, so the output decodes back via `parseInto`.

### Document model (lossless editing)

Parse a YAML file, edit values in place, and emit byte-identical output
when unmodified or minimal-diff output when edited. Comments, formatting,
indentation, anchors, and the original quoting are all preserved.

```zig
var doc = try yaml.Document.parse(arena, src, .{});

const port = doc.getT(u16, "server.port") orelse 8080;

// `set` is comptime-dispatched on the Zig type (bool, int, float,
// []const u8, null), rendered with the emitter's round-trip-safe quoting.
try doc.set("server.port", @as(u16, 9443));
try doc.set("server.tls", true);
try doc.set("server.host", "0.0.0.0");

// Escape hatch: splice in a verbatim YAML value (a scalar or a
// flow/block collection), no scalar normalization.
try doc.setLiteral("tags", "[alpha, beta]");

// Add, replace, or remove the trailing `# comment` on a line.
try doc.setTrailingComment("server.port", "listen port");

// Delete a key (and its whole line, including any trailing comment).
try doc.remove("debug");

var aw: std.Io.Writer.Allocating = .init(gpa);
defer aw.deinit();
try doc.emit(&aw.writer);
```

`set` on an existing path replaces only the value's bytes; the key, the
`:`, comments, indentation, and siblings stay put. `set` on a missing leaf
appends a new member to its enclosing block mapping, matching the
indentation of the last sibling. The emitted document differs from the
input only where edits were applied. See `examples/edit.zig` for a
runnable walk-through.

`setValue` writes a dynamic `Value` directly instead of a comptime Zig
type; `addCommentBefore` / `removeCommentBefore` manage a line's leading
`# comment`. For many edits, wrap them in `beginBatch` / `commitBatch` to
apply the whole group with a single reparse instead of one reparse per
edit.

### Reader-backed streaming

Parse a `std.Io.Reader` document-at-a-time without buffering the whole stream
into memory. Memory is bounded to ONE document plus a small pull buffer,
regardless of total stream length.

```zig
// ValueStream: one Value per document, per-item arena reset between docs.
var r: std.Io.Reader = .fixed(src);
var vs = yaml.ValueStream.fromReader(gpa, &r, .{});
defer vs.deinit();

var item_arena = std.heap.ArenaAllocator.init(gpa);
defer item_arena.deinit();

while (try vs.next(item_arena.allocator())) |v| {
    const name = v.getT([]const u8, "name") orelse "?";
    std.debug.print("{s}\n", .{name});
    _ = item_arena.reset(.retain_capacity); // free previous doc, keep capacity
}
```

For event-level access, use `EventReader`:

```zig
// EventReader: one parser event at a time across the whole stream.
var r: std.Io.Reader = .fixed(src);
var er = yaml.EventReader.fromReader(gpa, &r, .{});
defer er.deinit();

while (try er.next()) |ev| {
    if (ev.kind == .scalar) std.debug.print("{s}\n", .{ev.value});
}
```

To switch from event-walking to composing at a document boundary, call
`materialize()` immediately after `next()` returns a `document_start` event:

```zig
var item_arena = std.heap.ArenaAllocator.init(gpa);
defer item_arena.deinit();

while (try er.next()) |ev| {
    if (ev.kind != .document_start) continue;
    const v = try er.materialize(item_arena.allocator());
    // use v; then reset item_arena
    _ = item_arena.reset(.retain_capacity);
}
```

#### Event kinds

The streaming `Event` type is the parser's event verbatim, with spans
re-based to absolute stream byte offsets. The kinds are:

| Kind | Meaning |
| --- | --- |
| `stream_start` / `stream_end` | Outer stream framing (one per stream). |
| `document_start` / `document_end` | One per document; `explicit` is true when `---` is present. |
| `mapping_start` / `mapping_end` | Block or flow mapping open/close. |
| `sequence_start` / `sequence_end` | Block or flow sequence open/close. |
| `scalar` | A scalar value; `value` holds the text, `scalar_style` the presentation. |
| `alias` | An alias (`*name`); `alias_name` holds the anchor name. |

#### Borrow contract

Event payload slices (`value`, `anchor`, `tag`, `alias_name`) borrow the
internal document buffer and the per-document parser's arena. They remain
valid for all events within ONE document. Crossing a document boundary (the
`next()` call that returns the NEXT document's `document_start`, or a call to
`materialize()`) recycles the buffer; copy any slice you need past that point.

#### Aliases and anchor scoping

Anchors are document-scoped. An alias in document N that references an anchor
defined in document N-1 raises `error.YamlParseError`. Assign a fresh
`item_arena` per document and reset it between calls to enforce the natural
scope.

#### Error / recovery policy

`ValueStream` mirrors `parseStream`'s per-document recovery:

- `options.errors == null` (default): a compose error on one document
  terminates the stream. The error is returned from `next()` and subsequent
  calls return null.
- `options.errors != null`: a compose error on one document is surfaced from
  `next()` (the diagnostic is appended to errors), but the stream advances
  past the bad document. Subsequent `next()` calls continue with the following
  documents.

`EventReader` is fail-fast and terminal: once `next()` has returned an error,
every subsequent call returns null, with or without an errors sink. There is
no event-level recovery; `diagnostic()` still reports the captured failure.

#### Memory bound

The internal buffer grows to hold at most ONE document plus a small pull
chunk (4 KiB). A 100 000-document stream uses the same peak buffer as a
10-document stream, provided each document fits in memory.

**Honest caveat:** a single document larger than RAM still buffers fully --
the document boundary (the `---` or `...` marker, or stream end) must be seen
before the document can be handed to the parser. YAML's anchors are
document-scoped and aliases deep-copy at resolution time, so the document is
the smallest unit that can be soundly bounded. True sub-document byte
streaming is not possible for YAML. This is the same bound libyaml has.

See `examples/event_stream.zig` for a runnable walk-through of all three
entry points.

### Source spans

```zig
var spans: yaml.Spans = .empty;
const v = try yaml.parse(arena, src, .{ .spans = &spans });

if (v.locate(spans, "server.port")) |hit| {
    // Spans store u64 byte offsets; derive line/col on demand.
    const lc = hit.span.lineCol(src);
    std.debug.print("port {d} at line {d} col {d}  bytes [{d}..{d}]\n",
        .{ hit.value.int, lc.line, lc.col, hit.span.start, hit.span.end });
}
```

Spans are only recorded when `.spans` is set, and only by buffered parses:
the reader-backed streaming value paths (`ValueStream.next`,
`EventReader.materialize`) ignore `.spans`, because their entries would live
in the per-document arena the caller resets between documents. Sequence
elements use `[N]` index segments, e.g. `users[0].name`. Byte offsets are
`u64`, so any in-memory input is addressable without a size cap.

### Diagnostics on parse error

```zig
var errs: std.ArrayList(yaml.Diagnostic) = .empty;
defer errs.deinit(arena);

var aw: std.Io.Writer.Allocating = .init(arena);
defer aw.deinit();

_ = yaml.parse(arena, src, .{ .errors = &errs }) catch {
    if (errs.items.len > 0) try errs.items[0].render(&aw.writer, src);
};
```

For rustc-style multi-line output with source-line excerpts, caret
underlines, and "did you mean" suggestions:

```zig
for (errs.items) |d| try d.renderRich(&aw.writer, src);
```

With `.errors` set, the parser collects diagnostics in one pass. Leave it
`null` for single-error mode: parsing bails on the first error with no
diagnostic captured and zero allocation overhead.

The diagnostics are parse-arena-owned: the entries, their messages, and the
list's backing buffer are all allocated from the arena passed to `parse`.
Deinit the list with that arena's allocator (as above), or simply drop it
when the arena is freed -- never deinit it with a different allocator, and
do not use the entries after the parse arena is gone.

### Schema selection

A plain (untagged) scalar's text is resolved to a typed `Value` under the
chosen schema. The three form a ladder of strictness:

```zig
// failsafe: every scalar stays a string.
const a1 = try yaml.parse(arena, "value: yes", .{ .schema = .failsafe });
// json: the JSON data model (null/true/false/number), strict grammar.
const a2 = try yaml.parse(arena, "value: 10", .{ .schema = .json });
// core (default): JSON plus YAML conveniences (~, hex/octal, .inf/.nan).
const a3 = try yaml.parse(arena, "value: 0x10", .{ .schema = .core });
```

A `!!str`-tagged scalar always stays a string regardless of schema;
`!!int` / `!!float` / `!!bool` / `!!null` resolve via the schema predicate
and error on mismatch.

### Merge keys

```zig
const v = try yaml.parse(arena,
    \\defaults: &d
    \\  timeout: 30
    \\  retries: 3
    \\service:
    \\  <<: *d
    \\  retries: 5
, .{ .merge_keys = true });

const timeout = v.getT(i64, "service.timeout"); // 30, inherited
const retries = v.getT(i64, "service.retries"); // 5, overrides the merge
```

Merge keys are on by default. The `<<` entry pulls in the referenced
mapping's keys; keys already present in the local mapping win. Set
`.merge_keys = false` to keep `<<` as an ordinary literal key.

## Number policy

- A plain scalar that resolves as a number becomes `.int` (`i128`) when it
  has no fractional or exponent part, else `.float` (`f64`). A whole-number
  literal outside the i128 range falls back to `.float`, so resolution never
  fails on a grammatically valid number.
- Integer decode targets do not accept `.float` values: a literal that
  resolved as `.float` stays one. Every literal in [-2^127, 2^127 - 1]
  parses as `.int`, so all fixed-width integer fields up to `u64`/`i128`
  receive exact values. Only literals beyond that range (e.g. a `u128`
  value above i128 max) resolve as `.float` and fail decode with
  `error.TypeMismatch`.
- A quoted scalar is never schema-resolved: `"true"`, `'123'`, and `"~"`
  stay strings. This is what keeps the emitter's round-trip quoting honest.

## API surface

### Functions

| Function | Purpose |
| --- | --- |
| `parse(arena, src, options)` | Parse exactly one document to a `Value`. |
| `parseStream(arena, src, options)` | Parse every document to a slice of `Value`. |
| `parseReader(arena, reader, options)` | Reader-input variant of `parse`. |
| `parseStreamReader(arena, reader, options)` | Reader-input variant of `parseStream`. |
| `parseInto(T, arena, src, options)` | Parse one document and decode it into `T`. |
| `parseIntoReader(T, arena, reader, options)` | Reader-input variant of `parseInto`. |
| `decode(T, arena, value, options)` | Decode an existing `Value` into `T`. |
| `emit(w, value, options)` | Emit one `Value` as block YAML. |
| `emitStream(w, values, options)` | Emit a slice of documents, `---`-separated. |
| `emitTyped(w, value, arena, options)` | Emit a typed value, honoring annotations and hooks. |
| `cookScalarText(arena, src, event)` | Cook a scalar event to its presentation text. |

#### Streaming (reader-backed, document-at-a-time)

| Type / method | Purpose |
| --- | --- |
| `EventReader.fromReader(gpa, reader, options)` | Create a reader-backed streaming event reader. |
| `er.next()` | Return the next `Event`, or null at stream end. |
| `er.materialize(arena)` | At `document_start`: compose the whole current document into a `Value`. |
| `er.diagnostic()` | Return the most recent error diagnostic, if any. |
| `er.bufCapacity()` | Return the internal buffer's allocated capacity (bytes); for benchmarks and tests. |
| `ValueStream.fromReader(gpa, reader, options)` | Create a reader-backed document value stream. |
| `vs.next(item_arena)` | Compose and return the next document as a `Value`, or null at stream end. |

### Document model

| Method | Purpose |
| --- | --- |
| `Document.parse(arena, src, options)` | Lossless parse: keeps source bytes alongside a byte-range node tree. |
| `doc.get(path)` / `doc.getT(T, path)` | Read a value (or typed value) by dotted path through the first document. |
| `doc.set(path, value)` | Replace a value's bytes (comptime-dispatched on the Zig type), or append a missing leaf. |
| `doc.setValue(path, value)` | Replace a value's bytes with a dynamic `Value`. |
| `doc.setLiteral(path, raw)` | Splice a verbatim YAML value string (validated by reparse). |
| `doc.setTrailingComment(path, text)` | Add, replace (`text`), or remove (`null`) a line's trailing `# comment`. |
| `doc.addCommentBefore(path, text)` / `doc.removeCommentBefore(path)` | Add or remove a line's leading `# comment`. |
| `doc.remove(path)` | Delete a mapping member or sequence element, whole line. |
| `doc.beginBatch()` / `doc.commitBatch()` | Group many edits into a single reparse instead of one per edit. |
| `doc.emit(w)` | Write the (possibly edited) document to a `*std.Io.Writer`. |

### Types

`Value`, `Entry`, `Span`, `Spans`, `Schema`, `Scanner`, `Token`,
`TokenKind`, `ScalarStyle`, `Parser`, `Event`, `EventKind`, `ParseOptions`,
`EmitOptions`, `Diagnostic`, `Error`, `ReaderError`, `DecodeError`,
`EmitError`, `Document`, `DocumentError`, `EventReader`, `ValueStream`,
`StreamError`.

The low-level `Scanner` / `Parser` emit the tokenizer and event streams
directly, for tooling that walks the source without building a `Value` tree.

Generated reference docs (Zig's docs viewer is WASM-based and must be served
over HTTP, not opened as a `file://` URL):

```sh
zig build docs
cd zig-out/docs && python3 -m http.server 8000
# then visit http://localhost:8000/
```

## Build commands

```sh
zig build test           # unit + conformance tests
zig build fuzz           # random-input fuzzer (zig build fuzz -- [seed] [iterations])
zig build bench          # microbenchmarks (ReleaseFast)
zig build docs           # generate reference docs
zig build examples       # build all examples
zig build example-basic  # build and run one example
                         # (basic, typed, stream, emit, spans, edit, event_stream)
```

## Conformance

Validated against the [yaml-test-suite](https://github.com/yaml/yaml-test-suite),
vendored under `tests/corpus/yaml-test-suite/` alongside its upstream
`LICENSE`. Of 405 corpus cases:

```
event stream matches reference:   291 cases, byte-for-byte
error cases correctly rejected:    82 of 94 error-marked cases
policy-documented divergences:     23 cases (incl. 12 not-yet-rejected errors)
```

The primary check is the **event stream**: each input is parsed, its event
sequence serialized to the suite's `test.event` text format, and required to
match byte-for-byte. Where the suite also ships an `in.json` projection, the
composed `Value` is cross-checked against it.

The 23 policy-documented cases are an explicit, pinned list in
`src/conformance.zig`, each tagged with a reason. The remaining divergences
cluster into two groups:

- **Flow-context edge cases (6):** a multi-token flow collection used as a
  key inside a flow collection (`[[a]: b]`), where the already-emitted key
  node would need retroactive wrapping in a single-pair; and a flow-mapping
  key that wraps onto the line before its `:`, entangled with comma-omission
  and flow-in-block indentation rules the scanner does not cleanly separate.
- **Accepted-invalid inputs (12+1):** inputs the suite expects to FAIL that
  the parser still accepts. The well-defined rejections (extra `%YAML`
  fields, block collections on the `---` line, inline nested mappings, bare
  flow indicators, directives after content) are enforced; what remains needs
  deeper context than is worth a fragile lookahead check that risks
  miscategorizing valid documents. Each is enumerated in the `policy` table
  with its reason.

No hidden compromises: every divergence is listed. The set is pinned so
corpus drift -- a lost or newly-added case -- forces a conscious decision
rather than silently inflating or deflating the pass count.

Separately, the suite asserts emitter round-trip safety: every corpus case
whose input composes cleanly (309 of them) survives parse -> emit -> parse
to a deeply-equal `Value` tree, with no skips.

Reproduce with:

```sh
zig build test --summary all
```

## Performance

Run the bench yourself on your hardware with your inputs:

```sh
zig build bench
```

The harness reports min/p50/p99/max latency and throughput across 100 samples
with explicit warmup. On aarch64 (ReleaseFast), p50 lands at roughly:

| Benchmark | small (970 B) | medium (22 KB) | large (291 KB) |
| --- | --- | --- | --- |
| parse | 8.25 us, 112 MB/s | -- | 2.99 ms, 95 MB/s |
| parseStream | 8.46 us, 109 MB/s | 176.7 us, 123 MB/s | 2.93 ms, 97 MB/s |
| emit | 2.42 us, 383 MB/s | 48.3 us, 480 MB/s | 826 us, 373 MB/s |

(`parse` requires a single document, so the multi-document medium fixture is
measured only under `parseStream`. Emit throughput is against the bytes
produced, which differs slightly from the input.) The scalar scan uses a
16-wide SIMD (`@Vector(16, u8)`) fast-path to bulk-skip runs of non-terminator
bytes in plain and quoted scalars, falling back to the per-byte loop at each
candidate stop byte; the win scales with scalar length (e.g. long double-quoted
content scans roughly 2x faster). The fixtures are a config-like document (small),
a multi-document manifest (medium), and a large record collection (large);
see `bench/fixtures/`. Run `zig build bench` to get numbers for your machine.

## Memory model

`parse` and friends take an `Allocator` (the parse arena). All values,
mapping keys, and any non-zero-copy scalars live in that arena. To free
everything, deinit the arena -- no need to walk the tree.

Plain scalars that need no unescaping, folding, or chomping are zero-copy
slices into the source buffer; quoted and block scalars are cooked into
arena-allocated copies. Either way, keep the input alive as long as the parse
tree is in use.

Aliases (`*name`) are resolved by deep-copying the anchored node into each
referencing site. Each copied node spends one unit of the
`max_alias_nodes` budget (`ParseOptions`, default 1,000,000), bounding
billion-laughs-style alias amplification. Collection nesting is bounded by
`max_depth` (default 128).

The document model also takes an arena. It owns the source string, the
node tree, and any edits. Each edit retains a new source/tree generation in
the arena, so memory grows with edit count; for long-lived many-edit
sessions, periodically emit and re-parse into a fresh arena.

## Examples

See `examples/` for runnable samples:

- `basic.zig` - dynamic parse and dotted-path access
- `typed.zig` - decode straight into a Zig struct
- `stream.zig` - multi-document stream parsing
- `emit.zig` - emit a value as YAML with round-trip-safe quoting
- `spans.zig` - source spans and rich diagnostics
- `edit.zig` - lossless document edit (set/setLiteral/setTrailingComment/remove) + emit
- `event_stream.zig` - reader-backed streaming: EventReader, ValueStream, and materialize
