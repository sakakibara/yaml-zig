//! YAML 1.2 parser, typed codec, and emitter.
//!
//! Parse to a dynamic `Value` tree or straight into a Zig type via
//! `parseInto`; emit block-style YAML (`emit`, `emitTyped`); stream
//! reader-backed input document-at-a-time (`EventReader`, `ValueStream`).
//! Everything allocates into a caller-owned arena, and parsed strings may
//! be zero-copy slices into the source -- keep `src` alive as long as the
//! result is in use. The README holds worked examples for each entry point.

const std = @import("std");

const value = @import("value.zig");
const schema = @import("schema.zig");
const scanner = @import("scanner.zig");
const parser = @import("parser.zig");
const composer = @import("composer.zig");
const diagnostic = @import("diagnostic.zig");
const levenshtein = @import("levenshtein.zig");
const decode_mod = @import("decode.zig");
const emitter = @import("emitter.zig");
const document = @import("document.zig");
const stream = @import("stream.zig");

/// Dynamic YAML value tree: a tagged union over null, bool, int, float,
/// string, seq, and map. See `value.zig` for the memory model, the
/// dotted-path lookup helpers (`get`, `getT`, `locate`), and deep
/// structural equality (`eql`).
pub const Value = value.Value;

/// A single key/value pair in a mapping. Mappings are ordered slices of
/// `Entry`, so any `Value` may serve as a key.
pub const Entry = value.Entry;

/// Byte-offset source range for a value, recorded by the parser when span
/// tracking is enabled; line/col are derived on demand via `Span.lineCol`.
pub const Span = value.Span;

/// Map from dotted path to source `Span`. Paired with `Value.locate`.
pub const Spans = value.Spans;

/// Scalar resolution schema: `failsafe` (all strings), `json` (the JSON
/// data model), or `core` (YAML 1.2.2 Core, the usual default). Selects
/// how a plain scalar's text is decoded into a typed `Value`.
pub const Schema = schema.Schema;

/// Indentation-aware streaming tokenizer over block-context YAML. Emits a
/// flat token stream with explicit block-collection structure; see
/// `scanner.zig`.
pub const Scanner = scanner.Scanner;

/// A scanner token: a kind, the source `Span` it covers, and (for
/// scalars) the scalar style.
pub const Token = scanner.Token;

/// The kind of a scanner `Token`: stream/document markers, block and flow
/// collection structure, entry/key/value indicators, and scalars.
pub const TokenKind = scanner.TokenKind;

/// Presentation style of a scalar token: plain, single/double quoted, or
/// literal/folded block.
pub const ScalarStyle = scanner.ScalarStyle;

/// Event-stream parser over the scanner: turns the token stream into the
/// YAML event sequence (the test-suite ground-truth representation). See
/// `parser.zig`.
pub const Parser = parser.Parser;

/// A parser event: stream/document framing, collection start/end, scalar,
/// or alias, with anchor/tag/style/value attached.
pub const Event = parser.Event;

/// The kind of a parser `Event`.
pub const EventKind = parser.EventKind;

/// Compose options: the resolution schema, merge-key handling, and the
/// depth/alias budgets that bound composition. See `composer.zig`.
pub const ParseOptions = composer.ParseOptions;

/// Errors from composing an event stream into a `Value` tree, plus the
/// allocator error set. Spans carry u64 byte offsets, so any in-memory input
/// is addressable without a size cap.
pub const Error = composer.Error;

/// One collected parse error: message, source span, and an optional
/// "did you mean" suggestion. Collect every error in one pass via
/// `ParseOptions.errors`:
///
/// ```zig
/// var errs: std.ArrayList(yaml.Diagnostic) = .empty;
/// defer errs.deinit(arena.allocator());
///
/// _ = yaml.parse(arena.allocator(), src, .{ .errors = &errs }) catch {
///     for (errs.items) |d| {
///         try d.render(writer, src);            // one-line form
///         try d.renderRich(writer, src);        // rustc-style excerpt
///     }
/// };
/// ```
///
/// Messages and suggestions are arena-allocated; they live as long as
/// the parse arena. With `errors` left null, parsing bails on the first
/// error with no diagnostic captured and zero allocation overhead.
pub const Diagnostic = diagnostic.Diagnostic;

/// Parse exactly one YAML document from `src` into a `Value`, allocating
/// into the caller-owned `arena`. Zero or more than one document is an
/// error; use `parseStream` for a multi-document stream.
///
/// Zero-copy contract: plain scalars that need no cooking are returned as
/// slices into `src`, so `src` must outlive the returned tree.
///
/// Any in-memory input is addressable: spans and the value tree carry u64
/// byte offsets, so there is no input-size cap.
pub const parse = composer.parse;

/// Parse every document in `src` (zero or more) into a slice of `Value`,
/// allocating into the caller-owned `arena`.
pub const parseStream = composer.parseStream;

/// Cook a single scalar `Event` to its presentation text (unescape /
/// fold / chomp), matching what `parse` would store. A plain scalar
/// passes through; quoted and block scalars are cooked. Intended for
/// event-stream serialization and round-trip tooling.
pub const cookScalarText = composer.cookScalarText;

/// Reader-input variants additionally surface the reader's allocation
/// failure path.
pub const ReaderError = composer.ReaderError;

/// Reader-input variant of `parse`. Pulls the full input into arena memory
/// first, then calls `parse` over it. A complete contiguous buffer is
/// required: zero-copy plain scalars slice into the drained buffer, and a
/// document is only valid once its final token is seen.
pub const parseReader = composer.parseReader;

/// Reader-input variant of `parseStream`. Pulls the full input into arena
/// memory first, then calls `parseStream` over it.
pub const parseStreamReader = composer.parseStreamReader;

/// Error set for typed decoding: type mismatch, missing/unknown field,
/// invalid enum value, integer overflow, and allocation failure. See
/// `decode.zig`.
pub const DecodeError = decode_mod.DecodeError;

/// Decode an already-parsed `Value` tree into a native Zig type `T` via
/// comptime reflection. Honors the `yaml_rename`/`yaml_skip`/`yaml_flatten`
/// annotations, the `yaml_tag` tagged-union discriminator, and a `fromYaml`
/// custom-decode hook. See `decode.zig` for the full decoding rules.
///
/// Zero-copy contract: decoded strings may alias the tree's string slices,
/// which themselves may point into the original parse input; keep that
/// input alive as long as the decoded result is in use.
pub const decode = decode_mod.decode;

/// Parse one document from `src` and decode it into `T` in one call.
/// Types without `Value` fields, `fromYaml` hooks, or tagged unions decode
/// in a single streaming pass over parser events with no intermediate
/// `Value` tree, provided the document uses no anchors, aliases, or merge
/// keys; anything else falls back to parse + decode with identical
/// accept/reject behavior and diagnostics.
///
/// Zero-copy contract: decoded strings may be slices into `src`, so `src`
/// must outlive the decoded result.
pub const parseInto = decode_mod.parseInto;

/// Reader-input variant of `parseInto`.
pub const parseIntoReader = decode_mod.parseIntoReader;

/// Block-style emitter options: spaces of indentation per nesting level.
pub const EmitOptions = emitter.EmitOptions;

/// Errors from emitting a `Value` tree: writer failures, plus
/// `NestingTooDeep` and the reserved `UnrepresentableScalar`. See
/// `emitter.zig`.
pub const EmitError = emitter.EmitError;

/// Emit a single `Value` as block-style YAML to `w`, terminated by a
/// trailing newline. Scalars take the narrowest round-trip-safe style;
/// empty collections emit flow-empty `{}`/`[]`. See `emitter.zig`.
pub const emit = emitter.emit;

/// Emit a slice of `Value` documents to `w`, separated by `---` markers
/// (the conventional `doc1\n---\ndoc2\n` form). A single document needs
/// no marker.
pub const emitStream = emitter.emitStream;

/// Emit a typed Zig value as block-style YAML, honoring the same
/// `yaml_rename`/`yaml_skip`/`yaml_flatten`/`yaml_tag` annotations and a
/// `toYaml` custom-encode hook that typed decoding consults, so output
/// decodes back via `parseInto(T, ...)`. Builds the `Value` in `arena`.
pub const emitTyped = emitter.emitTyped;

/// Lossless document model: parse keeping the source bytes and a byte-range
/// node tree, read through values by path, edit with minimal diffs, and emit
/// byte-identically when unmodified. See `document.zig`.
pub const Document = document.Document;

/// Errors from the lossless document model: a missing path, an invalid value
/// or splice, excessive nesting, plus the allocator error set.
pub const DocumentError = document.Error;

/// Reader-backed, document-at-a-time streaming event reader. Pulls bytes from
/// a `std.Io.Reader`, frames one complete YAML document at a time (using the
/// scanner as the boundary oracle), and hands out the parser's events with
/// spans re-based to absolute stream offsets. Bounded to one document of
/// buffered memory regardless of stream length. See `stream.zig`.
pub const EventReader = stream.EventReader;

/// Reader-backed, document-at-a-time YAML value stream. Composes one Value
/// per document per next() call, reusing the EventReader's framing and the
/// existing Composer for full anchor/alias/merge/schema support. The caller
/// supplies a per-item allocator to next() and resets it between calls to
/// bound memory to a single document at a time. See `stream.zig`.
pub const ValueStream = stream.ValueStream;

/// Error set for a streaming parse: the parser's grammar/nesting errors,
/// reader and allocator failures, plus `UnexpectedEndOfInput`.
pub const StreamError = stream.StreamError;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(emitter);
    std.testing.refAllDecls(diagnostic);
    std.testing.refAllDecls(levenshtein);
    std.testing.refAllDecls(decode_mod);
    std.testing.refAllDecls(document);
    std.testing.refAllDecls(stream);
}
