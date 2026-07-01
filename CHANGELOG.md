# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/sakakibara/yaml-zig/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/sakakibara/yaml-zig/releases/tag/v0.1.0
