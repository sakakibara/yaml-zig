# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `emitKyaml`, `emitKyamlStream`, and `emitKyamlTyped` write KYAML. Output
  matches `sigs.k8s.io/yaml/kyaml` v1.6.0. `KyamlOptions.compact` selects
  the one-line form. The block emitter is unchanged. Comments are not kept.

## [0.6.0] - 2026-10-22

### Breaking

- Requires Zig 0.17.0 (`minimum_zig_version`). On Zig 0.16, stay on 0.5.x:
  `zig fetch --save git+https://github.com/sakakibara/yaml-zig#v0.5.1`.
  0.5.x takes fixes on the `zig-0.16` branch; the README's Compatibility
  section gives the dates.

## [0.5.1] - 2026-10-19

### Added

- `isPlainSafe(s, context)` and `PlainContext`: whether `s` can be written
  as a plain scalar - a value or an implicit key (at most 1024 characters),
  in block or flow context - and read back as this string under the core
  schema, the YAML 1.1 types, and the YAML 1.1 readers in common use (false
  for bytes that are not UTF-8). For a block value `emit` writes a string
  plain exactly when this holds, so a program writing YAML text itself can
  decide the same way. A release that does not break may only make it
  return false for more strings.

## [0.5.0] - 2026-10-18

### Breaking

- Emitted YAML changes: strings a YAML 1.1 reader would read as another
  type are quoted (`yes`, `y`, `0123`, `1st`), characters YAML does not
  allow raw are escaped, keys over 1024 characters are written as `? key`,
  and scientific floats carry a dot and signed exponent (`1e21` ->
  `1.0e+21`). Output compared byte for byte: regenerate expected output.
- `Schema` has a new member `.yaml11`: an exhaustive `switch` on `Schema`
  needs a `.yaml11` arm.
- `InvalidReason` has new members `.invalid_utf8` and `.truncated_utf8`: an
  exhaustive `switch` on a token's `invalid_reason` needs both arms.
- `EmitError` has a new error `InvalidUtf8`: emitting a string that is not
  valid UTF-8 fails instead of writing its bytes; handle the error, or
  validate strings before emitting.
- Input that is not valid UTF-8 fails to parse with `error.YamlParseError`:
  validate or transcode input before parsing.
- `Document.setLiteral` inside a flow collection refuses a literal that
  spans lines, holds a comment, or adds members: use `set`, or edit the
  collection in block style.

### Added

- `Schema.yaml11`: resolve plain scalars by the YAML 1.1 types -- the
  booleans `y`, `yes`, `on` and their negatives in each case form, integers
  in base 2, 8, 10, 16 and 60 with `_` separators, 1.1 floats (an exponent
  takes a sign; a fraction may hold `_`, as the type's own `685.230_15e+03`
  writes it), nulls. Explicit `!!int`, `!!float`, `!!bool` and `!!null`
  tags follow it under that schema. A timestamp, a merge key (`<<`), a value
  key (`=`) and a 1.1 float spelling that names no number (`1.2.3`) have no
  `Value` variant and resolve to their text.
- `tagOf(schema, plain)` and `Tag`: the type a schema's grammar gives a
  plain scalar, including the 1.1 types the `Value` model cannot hold.
- `EmitError.InvalidUtf8`, for a string that is not valid UTF-8, and the
  scanner's `InvalidReason.invalid_utf8` and `.truncated_utf8` (the input
  ends inside a multi-byte sequence).

### Fixed

- The emitter quotes every string that the core schema, the YAML 1.1 types,
  or a YAML 1.1 reader in common use (PyYAML, SnakeYAML, go-yaml v2, Psych,
  js-yaml) would read as another type. Such strings were emitted plain
  whenever the core schema read them as strings, so a YAML 1.1 reader turned
  `"yes"` into `true` and `"0123"` into 83. A string starting with `---` or
  `...` is quoted too: js-yaml 3 reads either as a document marker whatever
  follows it.
- The emitter escapes every character YAML does not let a scalar hold as it
  is -- C1 control characters, U+FFFE and U+FFFF -- and U+FEFF, which a
  reader strips as a byte order mark, and the YAML 1.1 line breaks U+0085,
  U+2028 and U+2029 (`\N`, `\L`, `\P`). These were written raw, which
  readers reject or alter. A string that is not valid UTF-8 is refused
  instead of written as bytes no reader accepts.
- A mapping key longer than the 1024 characters YAML allows an implicit key
  is written as an explicit `? key` entry, by the emitter and by the
  document model, which can now also append after an explicit-key member.
- A string set inside a flow collection through the document model is
  double-quoted: `set("m.a", "x, y")` on `m: {a: 1, b: 2}` wrote
  `{a: x, y, b: 2}`, adding a key `y`. `setLiteral` there accepts only a
  literal that stays one member of that collection, on one line and without
  a comment.
- A value set on a mapping member with no `:` (`{a, b: 2}`, or an explicit
  `? a` with no value) gets its `:`, on a line indented to the `?` under a
  block explicit key; it was appended to the key, so `set("m.a", "1")` made
  the key `a "1"`. An explicit key with an empty `:` (`{? a :}`) takes the
  value after its colon, not before it.
- A value set on an empty block sequence entry (`-` alone) lands after its
  `-`; it was spliced at the start of the sequence, so `set("[0]", 1)` on
  `- \n- 2` wrote ` 1- `.
- The document model never adds a key that is already there: a block scalar
  key (`? >-`) matches by its text with its chomping applied, and an alias
  key (`*x`) by the text of its anchor, so `set` edits that member.
- A member added to a flow mapping is written in flow syntax -- `, key:
  value` after the last member, or first inside `{}`, keys double-quoted and
  a created chain nested as `{key: ...}` -- instead of as block lines, which
  were valid only in some layouts. A created container is still refused
  there.
- An anchor or tag on the line of a mapping key that follows an empty value
  (`x:\n&a k: v`) decorates that key, as YAML defines it and other readers
  read it; the parser gave it to the empty value, so `*a` read as null.
  After an empty value that has properties of its own (`k1: &a\n!!str k3:
  v`), such a key was read as the first key of a nested mapping; it is a
  sibling. After an explicit key with no value (`? k1\n&a k3: v`) it was
  refused. yaml-test-suite case ZWK4 now matches the reference event stream:
  294 cases match and 20 are documented divergences, 310 round-trip.
- Replacing a block sequence that holds empty entries (`k:\n  -`) replaces
  all of it; the new value was written in front of its `-`.
- A value set on an empty value that carries only an anchor or a tag
  (`a: &x`, `- !!str`) lands after them; it was spliced onto the next line,
  joining the next key or entry.
- The parser refuses input that is not valid UTF-8, reporting the first bad
  byte of each document (or a grammar error the byte causes, where that is
  found first), instead of returning strings that are not text. With an
  `errors` sink, recovery resumes at the next document as after any other
  error; the reader-backed stream reports the byte without reading past the
  document that holds it.
- A float the emitter writes in scientific form carries a dot and a signed
  exponent (`1.0e+21`, `-1.5e+300`): `1e21` and `-1.5e300` read back as
  strings under YAML 1.1 and in PyYAML and Psych.
- A core integer beyond i128 written in hex or octal resolves to the float
  nearest it, as a decimal one does, instead of to a string.

## [0.4.0] - 2026-07-22

### Added

- `Document.setValueSegments` / `Document.setSegments` now accept a `.map`
  or `.seq` `Value`, not just scalars: a non-empty container renders as a
  nested YAML block collection (reusing the same block emitter `emit`
  already uses), indented one step under the target key -- replacing an
  existing key's value region losslessly, or following a freshly
  appended/created `key:` line -- and re-parses back to the exact tree,
  recursively for arbitrarily nested containers. An empty `.map`/`.seq`
  renders inline as `{}`/`[]`, identical to how `emit` represents an empty
  collection. Indentation reuses the same document-sampled indent-step
  inference a created intermediate mapping chain already uses. `setValue`
  / `set` (the dotted-string scalar setters) are unchanged and still
  reject containers.

## [0.3.0] - 2026-07-21

### Added

- `Document.setValueSegments` / `Document.setSegments` /
  `Document.removeSegments`: segment-taking twins of `setValue` / `set` /
  `remove` that address a path as pre-split key segments (e.g.
  `&.{ "host", "example.com" }`) instead of a dotted string, so a key
  containing a literal `.` is addressed unambiguously: each segment is a
  literal key, never re-split, and (per the key-quoting fix below) a
  created key always round-trips back to that exact string. The
  string-path methods now split into segments the same way internally, so
  dot-free paths behave identically either way.
- `Document.empty`: bootstrap a document with no source bytes (the "file
  doesn't exist yet" case). The first `set` (or any segment variant)
  splices the root mapping and the whole requested path in as one edit;
  `Document.parse` still requires well-formed YAML and keeps its existing
  behavior for empty input.

### Changed

- `Document.set` / `setValue` / `setLiteral` / the new segment setters now
  create missing intermediate mappings along a path, not just the final
  leaf: `set("a.b.c", v)` on a document lacking `a` or `a.b` now creates
  them as a block-mapping chain, indented one level deeper per nesting
  level, instead of returning `error.PathNotFound`. Sequence elements are
  still never created, only replaced: a `[N]` anywhere in a missing path,
  including as the leaf, is still `error.PathNotFound`. Each created
  level's indent step is sampled from an existing nesting level in the
  document when there is one (falling back to 2 spaces otherwise), so a
  chain created in a 4-space document uses 4 spaces, not always 2.

### Fixed

- A created mapping key (via intermediate-mapping creation, the new
  segment setters, or a plain single-level append) is now rendered through
  the same round-trip-safe scalar quoting `set` already applies to values,
  instead of splicing the key bytes verbatim. Previously an unquoted
  leading `- ` key could silently fabricate a SEQUENCE instead of the
  requested mapping member (`set` returned success while the requested key
  never existed), and an unquoted `true`/`123`/`null`-shaped key composed
  as a non-string key that `has`/`getT` could never read back. Both now
  quote correctly; existing bare-key creates that need no quoting stay
  byte-identical.

## [0.2.0] - 2026-07-05

### Fixed

- Line breaks normalize per YAML 1.2.2 section 5.4: a lone `\r` (classic-Mac)
  and `\r\n` are recognized as one line break everywhere, so CR-only documents
  parse and CR bytes no longer leak into scalar content. A CRLF-terminated
  block scalar (`|`/`>`) no longer gains a spurious leading blank line.

### Added

- `EmitOptions.sort_keys`: emit mapping entries (and, via `emitTyped`,
  struct fields) in ascending byte-lexicographic key order, recursively
  into nested mappings. Default `false` preserves insertion / declaration
  order, so existing output is byte-for-byte unchanged unless the flag is
  set. Only mappings whose keys are all scalar strings are reordered; a
  mapping with any non-string key keeps insertion order. Byte-lexicographic
  ordering, not JCS or any other canonicalization scheme.

## [0.1.1] - 2026-07-05

### Fixed

- 32-bit targets now compile. `u64` span offsets are cast to `usize` at
  slice-indexing and loop-index sites that failed to build where `usize`
  is 32-bit (e.g. `wasm32-wasi`). No API or behavior change on 64-bit
  targets.

## [0.1.0] - 2026-07-03

Initial release. YAML 1.2.2 parser, typed codec, block emitter, lossless
document model, reader-backed streaming reader, and tooling.

### Added

- YAML 1.2.2 parser: block and flow collections, anchors and aliases, merge
  keys (`<<`), multi-document streams, tags, and all scalar styles (plain,
  single/double quoted, literal and folded block scalars).
- Dynamic `Value` tree with dotted-path lookup (`get`, `getT`, `locate`) and
  `[N]` sequence indices. Mappings preserve the full YAML data model as an
  ordered list of entries, so any node (not only a string) can be a key.
- Typed decoding via comptime reflection (`parseInto`, `parseIntoReader`,
  `decode`): defaults, optionals, nested structs, enums, tagged unions
  (`yaml_tag`), the `yaml_rename` / `yaml_skip` / `yaml_flatten` annotations,
  and `fromYaml` / `toYaml` custom hooks.
- Single-pass typed decode: `parseInto` streams parser events straight
  into the target type (no intermediate `Value` tree) for types without
  `Value` fields, `fromYaml` hooks, or tagged unions, when the document
  uses no anchors, aliases, or merge keys; on any error or unsupported
  construct it re-decodes through the tree path so diagnostics are
  identical either way.
- Block-style emitter (`emit`, `emitStream`, `emitTyped`) with
  round-trip-safe scalar quoting.
- Schema selection: `failsafe`, `json`, and `core` (default) scalar
  resolution.
- Lossless document model (`Document`): parse keeps the source bytes
  alongside a byte-range node tree; `set` / `setValue` / `setLiteral` /
  `remove` / `setTrailingComment` / `addCommentBefore` / `removeCommentBefore`
  edit in place, and `emit` is byte-identical when unmodified and minimal-diff
  when edited (comments, formatting, indentation, anchors, and quoting are
  preserved). Batched edits (`beginBatch` / `commitBatch`) apply many changes
  with a single reparse. All 311 parseable yaml-test-suite cases round-trip
  byte-for-byte.
- Incremental reader variants (`parseReader`, `parseStreamReader`,
  `parseIntoReader`) over any `std.Io.Reader`.
- Reader-backed, document-at-a-time streaming API: `EventReader` and
  `ValueStream` (and the `StreamError` error set), all exported from the
  top-level `yaml` module. `EventReader.fromReader` / `next` / `materialize`
  walk a `std.Io.Reader` event-by-event, framing one complete YAML document
  at a time and re-basing spans to absolute stream offsets. `ValueStream`
  composes one `Value` per document per `next(item_arena)` call; the caller
  resets `item_arena` between calls to bound memory to a single document.
  Memory is bounded to one document plus a small pull buffer (4 KiB chunks),
  regardless of stream length. The per-document error recovery policy matches
  `parseStream`: with `options.errors` set, a bad document surfaces an error
  from `next()` but the stream continues to the following document; without an
  errors sink, the first compose error is terminal. `EventReader.materialize()`
  (valid only immediately after `document_start`) composes the whole current
  document via the Composer in one call, honoring all `ParseOptions`.
  `EventReader.bufCapacity()` exposes the internal buffer capacity for
  bounded-memory benchmarks and tests.
- Byte-precise source spans (opt-in via `ParseOptions.spans`): each span is
  a `{ start, end }` pair of `u64` byte offsets addressing inputs of any
  size. Derive 1-indexed line/column on demand with `Span.lineCol(src)`;
  `Diagnostic.render` takes the source bytes to derive location.
- Large inputs: all internal scanner/parser offsets and stored spans are
  `u64`, so plain `parse` / `parseStream` / `parseInto` (and their reader
  variants), streaming, the spans map, and the document model handle inputs
  of any size with no 4 GiB cap.
- Rustc-style multi-error diagnostics with source excerpts and "did you
  mean" suggestions.
- Bounded resource use: configurable nesting-depth and alias-expansion
  budgets guard against deeply nested and billion-laughs inputs, and error
  recovery is guaranteed to terminate on malformed input.
- SIMD (`@Vector`) string scanning on the hot path; arena allocation with
  zero-copy scalars where possible; no dependencies.
- Conformance: the yaml-test-suite corpus is vendored and run in
  `zig build test` - a documented subset matches the reference event stream
  exactly, most error-marked cases are rejected, and parseable cases
  round-trip through the emitter; remaining divergences are pinned and
  policy-documented.
- Bounded-memory streaming bench (`zig build bench`): streams 100 000 small
  documents via `ValueStream`, asserts the internal buffer peak capacity stays
  below 64 KiB (a few pull chunks), and prints peak capacity alongside
  throughput.
- Tooling: random-input fuzzer (`zig build fuzz`), microbenchmarks
  (`zig build bench`), generated reference docs (`zig build docs`), and
  runnable examples (`basic`, `typed`, `stream`, `emit`, `spans`, `edit`,
  `event_stream`).

[Unreleased]: https://github.com/sakakibara/yaml-zig/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/sakakibara/yaml-zig/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/sakakibara/yaml-zig/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/sakakibara/yaml-zig/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/sakakibara/yaml-zig/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/sakakibara/yaml-zig/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/sakakibara/yaml-zig/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/sakakibara/yaml-zig/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/sakakibara/yaml-zig/releases/tag/v0.1.0
