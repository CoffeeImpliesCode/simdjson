/* The simdjson bridge: a real `extern "C"` surface over the upstream On-Demand
 * API.
 *
 * Every declaration here is a thin, named wrapper around one upstream call on
 * one real simdjson type.  Nothing in this file computes a structural index,
 * validates a UTF-8 sequence, unescapes a string, rounds a number or decides
 * what a valid document is: `parser::iterate`, `document::get_value`,
 * `value::type`, `value::get_object`, `value::get_array`,
 * `field::unescaped_key`, `value::get_string`, `value::get_number`,
 * `value::get_bool`, `value::is_null`, `simdjson::validate_utf8`,
 * `simdjson::get_active_implementation` and every other answer this package
 * publishes come from the compiled upstream C++ in `src/src/simdjson.cpp`,
 * reached through `zig/bridge.cc`.
 *
 * Why a bridge at all: `addTranslateC` translates C, and the upstream library
 * is C++17 with class hierarchies, namespace aliases bound to a
 * compile-time-selected kernel, and `simdjson_result<T>` return types.  Zig
 * 0.17.0 does not translate a C++ header, so the C surface a Zig caller needs is
 * written once, here, as a header the translator can read and a translation
 * unit the compiler can compile.  This header is therefore plain C99 with
 * `extern "C"` guards: it must stay parseable by a C translator, not only by a
 * C++ compiler.
 *
 * Conventions
 * -----------
 *  * Status.  Every entry point returns `simdjson_bridge_status`.
 *    `SIMDJSON_BRIDGE_OK` is zero, and no other value is a success.
 *  * Validation.  Arguments are checked here, before the upstream call, with
 *    ordinary comparisons, and a rejected argument is
 *    `SIMDJSON_BRIDGE_INVALID_ARGUMENT`.  Nothing is `assert`ed: an `assert` is
 *    removed in ReleaseFast, so a bound check that vanishes is a bound check
 *    that lies.  This is not hypothetical here -- upstream itself has a
 *    debug-only `assert(builtin_impl)` in `builtin_implementation`
 *    (`src/implementation.cpp:341-345`) that dereferences a null pointer in an
 *    optimized build, which is one reason the builtin kernel is named below
 *    from a preprocessor cascade rather than by calling that accessor.
 *  * Upstream errors.  simdjson has exactly one error taxonomy and it is
 *    `simdjson::error_code` (`src/include/simdjson/error.h:19-55`), an unscoped
 *    enumeration whose members are `SUCCESS`, `TAPE_ERROR`, `EMPTY` and so on.
 *    There is no `SIMDJSON_ERR_*` spelling anywhere in the tree, and this
 *    header does not invent one.  When an upstream call reports one, the status
 *    is `SIMDJSON_BRIDGE_UPSTREAM_ERROR` and the enumerator's integer value is
 *    written to `out_error` unchanged.  The mirror enumeration below exists so a
 *    C caller can spell the value in source; `zig/bridge.cc` static-asserts
 *    every member of it against the real enumerator on every target that builds
 *    the bridge, so the two cannot drift.
 *  * Exceptions.  The bridge is compiled with `SIMDJSON_EXCEPTIONS=0` and
 *    `-fno-exceptions`, which is upstream's own supported configuration
 *    (`src/cmake/exception-flags.cmake:5,27`).  Upstream's On-Demand accessors
 *    are declared `noexcept` and report through `simdjson_result<T>::error()`
 *    (`src/include/simdjson/error.h:162-164`), so nothing in the paths below can
 *    throw.  `std::bad_alloc` is still caught and reported as
 *    `SIMDJSON_BRIDGE_OUT_OF_MEMORY`; nothing else is caught, because nothing
 *    else can be raised on a `-fno-exceptions` translation unit.
 *  * Buffers.  Every output buffer belongs to the caller and is borrowed for
 *    the duration of the call.  A list-returning entry point is two-pass: pass
 *    `NULL` -- or a buffer with `cap == 0` -- to learn the required size in
 *    `*out_len` or `*out_count`, write nothing, and get `SIMDJSON_BRIDGE_OK`.
 *    That is the sizing call, and it is the only one that succeeds without room:
 *    a positive `cap` too short for the result is
 *    `SIMDJSON_BRIDGE_BUFFER_TOO_SMALL`, with the required length still in the
 *    out-parameter and the buffer itself untouched.  `simdjson_br_walk` states
 *    its own, coarser version of this rule because it has two buffers and one of
 *    them may legitimately be zero-length; see that entry point.
 *  * Owned objects.  `simdjson_bridge_document` is an opaque handle whose
 *    storage is allocated and freed by C++ here, never by a caller and never by
 *    Zig.  `simdjson_br_destroy` is the matching free; the Zig facade's `deinit`
 *    calls exactly that, and it accepts NULL so `deinit` after a failed
 *    construction is safe.
 *
 * ## On-Demand, and what that forces on the surface
 * -------------------------------------------------
 * simdjson 5.0.2's On-Demand API is a one-shot, forward-only walk over a single
 * shared cursor.  Every `value`, `object` and `array` a caller obtains is a
 * position in the parser's own token stream, and upstream states the rules
 * directly: "You must consume the fields on an object one at a time.  A
 * request for a new key invalidates previous field values" and "You are
 * expected to access keys only once"
 * (`src/include/simdjson/generic/ondemand/document.h:560-569`, repeated for
 * `find_field_unordered` at `:595-604`); the compiler-visible form of the same
 * rule is `error_code OUT_OF_ORDER_ITERATION` "checked when
 * SIMDJSON_DEVELOPMENT_CHECKS=1" (`src/include/simdjson/error.h:46`); and
 * `document::find_field` refuses outright when the document is not at its root
 * (`src/include/simdjson/generic/ondemand/document-inl.h:77-79`).  An
 * `array_iterator`'s and `object_iterator`'s `operator*` is documented "MUST
 * ONLY BE CALLED ONCE PER ITERATION"
 * (`src/include/simdjson/generic/ondemand/array_iterator.h:53-54`,
 * `object_iterator.h:38`), and an `object_iterator`'s `operator++` "MUST NOT
 * CALL THIS IF operator* YIELDED AN ERROR" and "MUST NOT CALL THIS WITHOUT A
 * CORRESPONDING operator* CALL" (`object_iterator.h:44-46`).
 *
 * Two consequences follow, and this header is shaped by both of them.
 *
 * 1.  No iterator, cursor or borrowed value of any kind crosses this boundary.  A
 *     C or Zig caller cannot hold a `value` across two calls, because there is
 *     nothing to hold: the only thing a caller can hold is a
 *     `simdjson_bridge_document`, and the only thing it can ask that document for
 *     is a finished, self-contained copy of everything the document contains.
 *     `simdjson_br_walk` is that copy, produced in one call.
 * 2.  A document is consumed by being walked.  Walking it twice is possible and
 *     is what the two-pass contract above depends on, because upstream provides
 *     the rewind: `document::rewind()`
 *     (`src/include/simdjson/generic/ondemand/document.h:763`,
 *     `document-inl.h:35-36`) resets the cursor to the start of the document.
 *     `simdjson_br_walk` calls it before every pass, which is why the sizing
 *     pass and the filling pass see the same document.
 *
 * What that costs, stated plainly: the caller chooses two buffers and pays for
 * one pass over the document, and the answer is a flat pre-order sequence of
 * fixed-width records rather than a tape of pointers into the input.  No DOM is
 * built, no `value` ever outlives the call that produced it, and nothing in the
 * walk holds two live iterators at once.
 *
 * ## Line references
 * -----------------
 * Line references are to files under `src/` of this repository at the pinned
 * upstream tag, and name the file each time so a reader never has to guess.
 */

#ifndef SIMDJSON_BRIDGE_H
#define SIMDJSON_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Result of every entry point. */
typedef enum simdjson_bridge_status {
  /* The call succeeded. */
  SIMDJSON_BRIDGE_OK = 0,
  /* An argument was out of range, NULL, or a count this bridge cannot hold.  No
   * usable result was produced, which is not the same promise as every output
   * being left byte-for-byte alone: a count request initialises `*out_count`
   * before it validates anything, and a constructor clears its handle to NULL
   * before it allocates.  What a particular entry point does with its own
   * outputs on this status is stated there. */
  SIMDJSON_BRIDGE_INVALID_ARGUMENT = 1,
  /* A caller-owned output buffer was too small.  The required length, where the
   * entry point has one, is left in the out-parameter and the buffer is
   * untouched. */
  SIMDJSON_BRIDGE_BUFFER_TOO_SMALL = 2,
  /* An upstream C++ allocation failed. */
  SIMDJSON_BRIDGE_OUT_OF_MEMORY = 3,
  /* An upstream call reported a `simdjson::error_code`; its integer value is in
   * `out_error`.  That enumeration is declared in this header as
   * `simdjson_bridge_error_code`, but the value written is the upstream
   * enumerator's own. */
  SIMDJSON_BRIDGE_UPSTREAM_ERROR = 4
} simdjson_bridge_status;

/* The bridge's spelling of `simdjson::error_code`
 * (`src/include/simdjson/error.h:19-55`).
 *
 * The names are this fork's; the *values* are upstream's, and `zig/bridge.cc`
 * static-asserts each one against the real enumerator on every target that
 * builds the bridge.  Upstream declares no `SIMDJSON_ERR_*` spelling, so none
 * appears here.
 *
 * Every member of upstream's enumeration is named, not only the ones this bridge
 * has been seen to produce.  The reason is that one of them is reachable without
 * this bridge doing anything unusual: `INCOMPLETE_ARRAY_OR_OBJECT` comes out of
 * `document::get_value()` itself
 * (`src/include/simdjson/generic/ondemand/document-inl.h:94`,
 * `value_iterator-inl.h:84`), so a walk of a truncated document reports it and a
 * header that stopped at 17 would leave a caller with an unnamed integer.
 * `NUM_ERROR_CODES` is upstream's own end-of-list placeholder
 * (`error.h:54`) and is carried so the enumeration has the same length upstream's
 * does.
 *
 * `SIMDJSON_BRIDGE_ERROR_NONE` is the one member with a comment of its own: it is
 * `simdjson::SUCCESS` (0), and it is also what a successful call writes to
 * `out_error`, so the two can never disagree.
 */
typedef enum simdjson_bridge_error_code {
  /* `SUCCESS` (`error.h:20`).  Also what a successful call writes to
   * `out_error`. */
  SIMDJSON_BRIDGE_ERROR_NONE = 0,
  /* `CAPACITY` (`error.h:21`). */
  SIMDJSON_BRIDGE_ERROR_CAPACITY = 1,
  /* `MEMALLOC` (`error.h:22`). */
  SIMDJSON_BRIDGE_ERROR_MEMALLOC = 2,
  /* `TAPE_ERROR` (`error.h:23`): "Something went wrong, this is a generic
   * error."  This is also what a value whose first byte is not a JSON token start
   * produces here; see `simdjson_br_walk`. */
  SIMDJSON_BRIDGE_ERROR_TAPE = 3,
  /* `DEPTH_ERROR` (`error.h:24`). */
  SIMDJSON_BRIDGE_ERROR_DEPTH = 4,
  /* `STRING_ERROR` (`error.h:25`): a bad escape sequence. */
  SIMDJSON_BRIDGE_ERROR_STRING = 5,
  /* `T_ATOM_ERROR` (`error.h:26`). */
  SIMDJSON_BRIDGE_ERROR_T_ATOM = 6,
  /* `F_ATOM_ERROR` (`error.h:27`). */
  SIMDJSON_BRIDGE_ERROR_F_ATOM = 7,
  /* `N_ATOM_ERROR` (`error.h:28`). */
  SIMDJSON_BRIDGE_ERROR_N_ATOM = 8,
  /* `NUMBER_ERROR` (`error.h:29`): a JSON number that violates RFC 8259 section 6,
   * such as a leading zero. */
  SIMDJSON_BRIDGE_ERROR_NUMBER = 9,
  /* `BIGINT_ERROR` (`error.h:30`). */
  SIMDJSON_BRIDGE_ERROR_BIGINT = 10,
  /* `UTF8_ERROR` (`error.h:31`). */
  SIMDJSON_BRIDGE_ERROR_UTF8 = 11,
  /* `UNINITIALIZED` (`error.h:32`). */
  SIMDJSON_BRIDGE_ERROR_UNINITIALIZED = 12,
  /* `EMPTY` (`error.h:33`): "no structural element found". */
  SIMDJSON_BRIDGE_ERROR_EMPTY = 13,
  /* `UNESCAPED_CHARS` (`error.h:34`). */
  SIMDJSON_BRIDGE_ERROR_UNESCAPED_CHARS = 14,
  /* `UNCLOSED_STRING` (`error.h:35`). */
  SIMDJSON_BRIDGE_ERROR_UNCLOSED_STRING = 15,
  /* `UNSUPPORTED_ARCHITECTURE` (`error.h:36`). */
  SIMDJSON_BRIDGE_ERROR_UNSUPPORTED_ARCHITECTURE = 16,
  /* `INCORRECT_TYPE` (`error.h:37`). */
  SIMDJSON_BRIDGE_ERROR_INCORRECT_TYPE = 17,
  /* `NUMBER_OUT_OF_RANGE` (`error.h:38`). */
  SIMDJSON_BRIDGE_ERROR_NUMBER_OUT_OF_RANGE = 18,
  /* `INDEX_OUT_OF_BOUNDS` (`error.h:39`). */
  SIMDJSON_BRIDGE_ERROR_INDEX_OUT_OF_BOUNDS = 19,
  /* `NO_SUCH_FIELD` (`error.h:40`). */
  SIMDJSON_BRIDGE_ERROR_NO_SUCH_FIELD = 20,
  /* `IO_ERROR` (`error.h:41`). */
  SIMDJSON_BRIDGE_ERROR_IO_ERROR = 21,
  /* `INVALID_JSON_POINTER` (`error.h:42`). */
  SIMDJSON_BRIDGE_ERROR_INVALID_JSON_POINTER = 22,
  /* `INVALID_URI_FRAGMENT` (`error.h:43`). */
  SIMDJSON_BRIDGE_ERROR_INVALID_URI_FRAGMENT = 23,
  /* `UNEXPECTED_ERROR` (`error.h:44`). */
  SIMDJSON_BRIDGE_ERROR_UNEXPECTED_ERROR = 24,
  /* `PARSER_IN_USE` (`error.h:45`). */
  SIMDJSON_BRIDGE_ERROR_PARSER_IN_USE = 25,
  /* `OUT_OF_ORDER_ITERATION` (`error.h:46`): "tried to iterate an array or
   * object out of order (checked when SIMDJSON_DEVELOPMENT_CHECKS=1)".  This
   * build compiles that check in on every target; see the On-Demand section at
   * the top of this file for why the walk cannot raise it anyway. */
  SIMDJSON_BRIDGE_ERROR_OUT_OF_ORDER_ITERATION = 26,
  /* `INSUFFICIENT_PADDING` (`error.h:47`).  Unreachable through this bridge:
   * every `simdjson_bridge_document` owns a padded copy of its input, so
   * `parser::iterate` never sees the unpadded view that would produce it
   * (`src/include/simdjson/generic/ondemand/parser-inl.h:55`).  It is named
   * because a caller reading `out_error` must not have to guess whether an
   * unnamed integer is possible. */
  SIMDJSON_BRIDGE_ERROR_INSUFFICIENT_PADDING = 27,
  /* `INCOMPLETE_ARRAY_OR_OBJECT` (`error.h:48`): "The document ends early." */
  SIMDJSON_BRIDGE_ERROR_INCOMPLETE_ARRAY_OR_OBJECT = 28,
  /* `SCALAR_DOCUMENT_AS_VALUE` (`error.h:49`). */
  SIMDJSON_BRIDGE_ERROR_SCALAR_DOCUMENT_AS_VALUE = 29,
  /* `OUT_OF_BOUNDS` (`error.h:50`). */
  SIMDJSON_BRIDGE_ERROR_OUT_OF_BOUNDS = 30,
  /* `TRAILING_CONTENT` (`error.h:51`). */
  SIMDJSON_BRIDGE_ERROR_TRAILING_CONTENT = 31,
  /* `OUT_OF_CAPACITY` (`error.h:52`). */
  SIMDJSON_BRIDGE_ERROR_OUT_OF_CAPACITY = 32,
  /* `UNKNOWN_FIELD` (`error.h:53`). */
  SIMDJSON_BRIDGE_ERROR_UNKNOWN_FIELD = 33,
  /* `NUM_ERROR_CODES` (`error.h:54`): upstream's end-of-list placeholder, not a
   * failure.  Carried so this enumeration has the same length upstream's does;
   * `zig/bridge.cc` static-asserts that it does. */
  SIMDJSON_BRIDGE_NUM_ERROR_CODES = 34
} simdjson_bridge_error_code;

/* The bridge's spelling of `simdjson::ondemand::json_type`
 * (`src/include/simdjson/generic/ondemand/json_type.h:17-26`).
 *
 * The values are upstream's, in upstream's order, and `zig/bridge.cc`
 * static-asserts each one.  `SIMDJSON_BRIDGE_TYPE_UNKNOWN` is not a spare value:
 * it is what upstream returns for a value whose first byte is not a JSON token
 * start (`src/include/simdjson/generic/ondemand/value_iterator-inl.h:1187`), so a
 * caller that sees it is looking at malformed input, not at a value with no
 * answer.
 */
typedef enum simdjson_bridge_type {
  SIMDJSON_BRIDGE_TYPE_UNKNOWN = 0,
  SIMDJSON_BRIDGE_TYPE_ARRAY = 1,
  SIMDJSON_BRIDGE_TYPE_OBJECT = 2,
  SIMDJSON_BRIDGE_TYPE_NUMBER = 3,
  SIMDJSON_BRIDGE_TYPE_STRING = 4,
  SIMDJSON_BRIDGE_TYPE_BOOLEAN = 5,
  SIMDJSON_BRIDGE_TYPE_NULL = 6
} simdjson_bridge_type;

/* The bridge's spelling of `simdjson::number_type`
 * (`src/include/simdjson/generic/base.h:43-48`), which `value::get_number`
 * reports for a JSON number (`src/include/simdjson/generic/ondemand/value.h:704`).
 *
 * `SIMDJSON_BRIDGE_NUMBER_NONE` is this fork's addition: it is the value on a
 * record whose `type` is not `SIMDJSON_BRIDGE_TYPE_NUMBER`, where upstream has no
 * `number_type` at all.  The other four are upstream's, in upstream's order.
 */
typedef enum simdjson_bridge_number_type {
  SIMDJSON_BRIDGE_NUMBER_NONE = 0,
  /* `number_type::floating_point_number` (`base.h:44`). */
  SIMDJSON_BRIDGE_NUMBER_FLOATING_POINT = 1,
  /* `number_type::signed_integer` (`base.h:45`). */
  SIMDJSON_BRIDGE_NUMBER_SIGNED = 2,
  /* `number_type::unsigned_integer` (`base.h:46`). */
  SIMDJSON_BRIDGE_NUMBER_UNSIGNED = 3,
  /* `number_type::big_integer` (`base.h:47`). */
  SIMDJSON_BRIDGE_NUMBER_BIG = 4
} simdjson_bridge_number_type;

/* The `key_off` / `str_off` value for a record that has no such bytes.
 *
 * A byte offset into the caller's blob buffer, and 0xFFFFFFFFu is not a legal
 * one for a buffer the sizing call could have described, so it is used as the
 * absent marker.  A `key_len` of 0 is *not* the absent marker: a JSON member may
 * genuinely have a zero-length key, and `{"":1}` is such a document.
 */
#define SIMDJSON_BRIDGE_NO_OFFSET 0xFFFFFFFFu

/* One value in a walked document.
 *
 * `simdjson_br_walk` produces these in pre-order: a container's own record comes
 * before every record beneath it, and within a container the records appear in
 * document order, keys and all.  `depth` is 0 for the root and increases by one
 * per level of nesting, so a caller's own tree is the records grouped by `depth`.
 *
 * The struct is fixed width on purpose.  Two passes with the same output layout
 * means the sizing call can say exactly how many records and exactly how many
 * blob bytes the filling call needs, with no second format to keep in step, and
 * the caller can size both allocations before either is made.
 */
typedef struct simdjson_bridge_node {
  /* Nesting level, 0 at the root.  Upstream's own bound is
   * `DEFAULT_MAX_DEPTH` (`src/include/simdjson/base.h:49`), which is what
   * `ondemand::parser` uses unless a caller changes it
   * (`src/include/simdjson/generic/ondemand/parser.h:453`); this bridge never
   * changes it. */
  uint32_t depth;
  /* A `simdjson_bridge_type`. */
  uint32_t type;
  /* The number of direct children: elements for an array, fields for an object,
   * and 0 for every other type.  This is counted while the container is
   * iterated rather than asked for separately, so the walk never calls
   * `array::count_elements` or `object::count_fields` -- both of which document
   * that they scan the container a second time
   * (`src/include/simdjson/generic/ondemand/array.h:63-75`,
   * `object.h:456-471`). */
  uint32_t count;
  /* A `simdjson_bridge_number_type`, and `SIMDJSON_BRIDGE_NUMBER_NONE` for every
   * type other than `SIMDJSON_BRIDGE_TYPE_NUMBER`. */
  uint32_t number_type;
  /* Byte offset of this record's key in the caller's blob buffer, or
   * `SIMDJSON_BRIDGE_NO_OFFSET` when there is none -- which is every record that
   * is not a direct member of an object. */
  uint32_t key_off;
  /* Length in bytes of that key. */
  uint32_t key_len;
  /* Byte offset of this record's string bytes in the caller's blob buffer, or
   * `SIMDJSON_BRIDGE_NO_OFFSET` when the record is not a string.  The bytes are
   * the *unescaped* string, exactly as `value::get_string` returns them
   * (`src/include/simdjson/generic/ondemand/value.h:323`), and they are not
   * NUL-terminated. */
  uint32_t str_off;
  /* Length in bytes of that string. */
  uint32_t str_len;
  /* The value of a `SIMDJSON_BRIDGE_TYPE_BOOLEAN` record, as 0 or 1, from
   * `value::get_bool` (`value.h:391`); and the value of a
   * `SIMDJSON_BRIDGE_NUMBER_SIGNED` record, from `number::get_int64`
   * (`src/include/simdjson/generic/ondemand/json_type.h:72`).  0 for every other
   * type. */
  int64_t i;
  /* The value of a `SIMDJSON_BRIDGE_NUMBER_UNSIGNED` record, from
   * `number::get_uint64` (`src/include/simdjson/generic/ondemand/json_type.h:56`).
   * 0 for every other type. */
  uint64_t u;
  /* The value of a `SIMDJSON_BRIDGE_NUMBER_FLOATING_POINT` record, from
   * `number::get_double` (`json_type.h:78`).  0 for every other type.  Note that
   * this is a binary64 read straight out of upstream's number parser; for the
   * integers in a document it is the binary64 nearest to them, not the integer. */
  double d;
} simdjson_bridge_node;

/* An opaque, C++-owned On-Demand document.
 *
 * The handle owns three things and the order between them is the point: the
 * caller's input bytes, copied into a `simdjson::padded_string`
 * (`src/include/simdjson/padded_string.h:41`, which allocates
 * `length + SIMDJSON_PADDING` through `allocate_padded_buffer`
 * (`src/include/simdjson/padded_string-inl.h:66-74`)); the
 * `simdjson::ondemand::parser` whose buffers back the document; and the
 * `simdjson::ondemand::document` itself.
 *
 * The copy is not optional.  `parser::iterate` refuses an input without padding
 * before it reads a single byte
 * (`src/include/simdjson/generic/ondemand/parser-inl.h:55`,
 * `src/include/simdjson/error.h:47` `INSUFFICIENT_PADDING`), and the reason is
 * that stage 2's `stringparsing::parse_string` takes no end pointer and scans
 * until it finds a closing quote
 * (`src/src/generic/stage2/stringparsing.h:151-159`).  A caller that handed
 * upstream its own unpadded buffer would be trusting an unbounded read to stay in
 * bounds.
 *
 * Declare a pointer, never the object.
 */
typedef struct simdjson_bridge_document simdjson_bridge_document;

/* ---------------------------------------------------------------------------
 * Library-level facts
 *
 * These six entry points need no document and no input.  They exist so the SIMD
 * boundary this package compiles is observable from outside instead of asserted in
 * a comment, and so a caller can tell what it is bound to.
 * ------------------------------------------------------------------------- */

/* `SIMDJSON_VERSION` (`src/include/simdjson/simdjson_version.h:7`), the release
 * string upstream's own `release.py` writes into that header.
 *
 * Two-pass: `*out_len` always receives the length excluding the NUL, so a NULL
 * buffer sizes the call, and a positive `cap` too short for the string plus its
 * NUL is `SIMDJSON_BRIDGE_BUFFER_TOO_SMALL`.  This is a compile-time constant of
 * the header rather than a symbol a provider can disagree with, which is why it
 * is reported this way at all.
 */
simdjson_bridge_status simdjson_br_version(char *buf, size_t cap, size_t *out_len);

/* The kernel the On-Demand API in this artifact is bound to, by name.
 *
 * `#include <simdjson/ondemand.h>` does not reach a runtime-dispatched kernel.  It
 * includes `simdjson/builtin/ondemand.h`, which selects exactly one
 * `simdjson/<arch>/ondemand.h` with `SIMDJSON_BUILTIN_IMPLEMENTATION_IS` and then
 * aliases `simdjson::ondemand` to that architecture's namespace
 * (`src/include/simdjson/builtin/ondemand.h:11-31,39`,
 * `src/include/simdjson/ondemand.h:4,10`).  The token itself is chosen by a
 * priority cascade at compile time
 * (`src/include/simdjson/implementation_detection.h:148-172`), preferring
 * icelake, then haswell, westmere, arm64, ppc64, lsx, lasx, rvv_vls, and finally
 * `fallback` -- a cascade keyed on `SIMDJSON_CAN_ALWAYS_RUN_*`, so the answer is
 * the *lowest* instruction set guaranteed present for the target this artifact
 * was compiled for.
 *
 * The value is a pure preprocessor decision, reported by a cascade that mirrors
 * that one.  It is not `simdjson::builtin_implementation()`
 * (`src/include/simdjson/builtin/implementation.h:41`) on purpose: that accessor
 * looks the name up in the available list and its only guard is a debug-only
 * `assert` that is absent in an optimized build
 * (`src/implementation.cpp:341-345`), so a name compiled out would be a null
 * dereference rather than an answer.
 *
 * It therefore does not change with the machine the binary runs on, and it is not
 * the same fact as `simdjson_br_active_implementation` below.  Two-pass, as
 * above.
 */
simdjson_bridge_status simdjson_br_builtin_implementation(char *buf, size_t cap,
                                                        size_t *out_len);

/* `simdjson::get_active_implementation()->name()`
 * (`src/include/simdjson/implementation.h:226,56`).
 *
 * This is the kernel the runtime dispatcher selected, and it is a property of the
 * machine the binary is *executing on*, not of the artifact: the selection walks
 * the compiled-in kernels in priority order and takes the first whose required
 * instruction sets the host reports
 * (`src/implementation.cpp:286-294`, with the priority list built at `:211-232`),
 * and the host features come from CPUID on x86-64, `getauxval` on aarch64, no
 * detection at all on ppc64, and a constant on every other architecture
 * (`src/src/internal/isadetection.h:141,79,321`).
 *
 * Three further things make the answer host- and environment-dependent, and all
 * three are why no test in this package compares it against a literal:
 *
 *   * `SIMDJSON_FORCE_IMPLEMENTATION` overrides the whole choice.  If it names a
 *     kernel that is not compiled in, upstream does not fall back to detection --
 *     it latches onto an implementation whose name is `"unsupported"` and every
 *     later parse fails with `UNSUPPORTED_ARCHITECTURE`
 *     (`src/implementation.cpp:296-312`).
 *   * With more than one kernel compiled in, the first call to any of these
 *     accessors is what performs the detection and memoises the result
 *     (`src/implementation.cpp:321-332,188-190`); with exactly one, the answer is
 *     that kernel without any detection (`src/implementation.cpp:141-145,323-327`).
 *   * Before that first call the installed value is a proxy object whose own name
 *     is `"best_supported_detector"`
 *     (`src/implementation.cpp:186-207,204`); this entry point always dereferences
 *     it once to get the real answer, so the proxy's own name is never returned.
 *
 * This is also *not* a statement about which kernel parsed a document through this
 * bridge: the On-Demand surface is statically bound to the builtin kernel above,
 * while this is the DOM-side dispatcher's choice.  The two are separate upstream
 * decisions and this bridge reports both rather than implying one from the other.
 * Two-pass, as above.
 */
simdjson_bridge_status simdjson_br_active_implementation(char *buf, size_t cap,
                                                         size_t *out_len);

/* `simdjson::get_active_implementation()->description()`
 * (`src/include/simdjson/implementation.h:66`), under the same rules and the same
 * caveats as `simdjson_br_active_implementation`.  Two-pass, as above. */
simdjson_bridge_status simdjson_br_active_implementation_description(
    char *buf, size_t cap, size_t *out_len);

/* `simdjson::get_available_implementations().size()`
 * (`src/include/simdjson/implementation.h:219,168-171`,
 * `src/implementation.cpp:277-285`): how many kernels were compiled into this
 * artifact.
 *
 * This is at least 1.  It is not always more: the `fallback` kernel is compiled
 * only when nothing else can always run
 * (`src/include/simdjson/implementation_detection.h:136-145`), and each
 * architecture kernel is compiled only when its own `SIMDJSON_IS_*` macro holds
 * (`src/include/simdjson/portability.h:42-59`,
 * `implementation_detection.h:28-29`).  So a baseline x86-64 build compiles
 * icelake, haswell, westmere and fallback; an aarch64 build compiles arm64 and
 * fallback; and a target that matches no architecture macro compiles fallback
 * alone.  Total function: it cannot fail, so it returns the count rather than a
 * status.
 */
size_t simdjson_br_available_implementation_count(void);

/* The `name()` of the `index`-th kernel in that list.
 *
 * `index` is compared against the list's own `size()`
 * (`src/include/simdjson/implementation.h:168-171`) and an index at or past it is
 * `SIMDJSON_BRIDGE_INVALID_ARGUMENT` with `*out_len` set to 0.  The names are the
 * same strings `simdjson_br_active_implementation` can return.  Two-pass, as
 * above.
 */
simdjson_bridge_status simdjson_br_available_implementation_name(
    size_t index, char *buf, size_t cap, size_t *out_len);

/* `simdjson::validate_utf8(const char *, size_t)`
 * (`src/include/simdjson/implementation.h:18`): whether the byte range is valid
 * UTF-8.
 *
 * This is the only entry point that answers about a buffer without parsing
 * anything, and it is the one place where an answer is a function of the bytes
 * alone rather than of how they parse.  `*out_ok` is written 1 or 0 and is
 * written on every status this call can return; it is left alone on
 * `SIMDJSON_BRIDGE_INVALID_ARGUMENT`.  A NULL `json` with a non-zero `len` is
 * invalid; a NULL `json` with `len == 0` is an empty range, which upstream
 * accepts, and answers valid.
 */
simdjson_bridge_status simdjson_br_validate_utf8(const char *json, size_t len,
                                                 int *out_ok);

/* ---------------------------------------------------------------------------
 * Document
 * ------------------------------------------------------------------------- */

/* Parses `json[0 .. len)` and returns a handle to the On-Demand document.
 *
 * The bytes are copied into the handle, not borrowed; see
 * `simdjson_bridge_document` above for why.  A caller may free or reuse its own
 * buffer the instant this returns.
 *
 * The parse itself is `simdjson::ondemand::parser::iterate`
 * (`src/include/simdjson/generic/ondemand/parser.h:117`,
 * `parser-inl.h:54-67`), which runs stage 1 over the whole padded input and
 * returns its error through the `simdjson_result` rather than producing a
 * document at all (`src/include/simdjson/common_defs.h:302` `SIMDJSON_TRY`).  So
 * every structural error -- `EMPTY`, `UNESCAPED_CHARS`, `UNCLOSED_STRING`,
 * `UTF8_ERROR` -- is reported here and not by a later call, and no handle is
 * produced.
 *
 * `len` must be a length this bridge can count and copy: the input is copied into
 * a `padded_string` whose allocation is `len + SIMDJSON_PADDING`
 * (`src/include/simdjson/padded_string-inl.h:66-74`), and `SIMDJSON_PADDING` is
 * 64 (`src/include/simdjson/base.h:42`), so a `len` within `SIZE_MAX - 64` is
 * required and anything larger is `SIMDJSON_BRIDGE_INVALID_ARGUMENT`, refused
 * before anything is allocated.  A NULL `json` is invalid whatever `len` is, so a
 * null-pointer call cannot be confused with the empty document.
 *
 * On success `*out` is the handle and `*out_error` is
 * `SIMDJSON_BRIDGE_ERROR_NONE`.  On `SIMDJSON_BRIDGE_UPSTREAM_ERROR` `*out` is
 * NULL and `*out_error` is upstream's enumerator.  On every other status `*out`
 * is NULL.  `out_error` may be NULL, in which case the upstream code is discarded
 * and the caller learns only that there was one.
 */
simdjson_bridge_status simdjson_br_open(const char *json, size_t len,
                                        simdjson_bridge_document **out,
                                        int32_t *out_error);

/* Frees a handle from `simdjson_br_open`.  NULL is accepted and does nothing, so
 * `deinit` after a failed open is safe.  There is no other free: the parser, the
 * padded copy of the input and the document are all inside the handle and all
 * released here. */
void simdjson_br_destroy(simdjson_bridge_document *doc);

/* The number of input bytes this handle holds: what `simdjson_br_open` was given,
 * which is a fact about the call rather than about the document. */
simdjson_bridge_status simdjson_br_input_size(const simdjson_bridge_document *doc,
                                              size_t *out_len);

/* Walks the whole document in one call and copies it out.
 *
 * This is the only way to read a document through this bridge, and the shape is
 * forced by the one-shot rule stated at the top of this file.  Two things are
 * produced: a pre-order array of `simdjson_bridge_node` records, and one byte
 * buffer holding every object key and every string value, in the order the
 * records reference them.  Every value the walk records comes from an upstream
 * accessor named in that record's own comment.
 *
 * ## The two-pass rule, and its one asymmetry
 *
 * The record array is what decides.  A call is the *sizing* call exactly when
 * `nodes == NULL` or `node_cap == 0`; it then writes nothing at all, leaves the
 * true sizes in `*out_node_count` and `*out_blob_len`, and returns
 * `SIMDJSON_BRIDGE_OK`.  Any other call is the *filling* call and it must offer
 * `node_cap` records and `blob_cap` bytes.  Either buffer being too small for
 * what the document needs is `SIMDJSON_BRIDGE_BUFFER_TOO_SMALL`, with both
 * required sizes still written and neither buffer written past what it was
 * offered.
 *
 * A filling call whose buffers ran out runs the walk to its end and writes
 * nothing further: the sizes it reports are the ones the caller must allocate
 * for, so they are the whole document's rather than the count that happened to
 * fit.
 *
 * The blob buffer is the asymmetry, and it is deliberate.  A document may
 * legitimately contain no keys and no strings at all -- `42` is one -- so its
 * required blob length is zero, and a rule that made "blob capacity is zero"
 * mean "sizing call" would make such a document impossible to fill.  So a filling
 * call may pass `blobs == NULL` with `blob_cap == 0`: the walk still runs and
 * still reports the true required blob length, and if that length is non-zero the
 * answer is `SIMDJSON_BRIDGE_BUFFER_TOO_SMALL` with the length the caller needs to
 * allocate.  A document with no strings therefore fills with a zero-length blob
 * buffer, and a document with strings cannot be half-read.
 *
 * The two passes see the same document because the walk rewinds before each of
 * them (`src/include/simdjson/generic/ondemand/document.h:763`).
 *
 * A document whose root value is consumed while more of the input remains is
 * refused with `SIMDJSON_BRIDGE_UPSTREAM_ERROR` and `TRAILING_CONTENT` in
 * `*out_error`.  RFC 8259 section 2's `JSON-text = ws value ws` is one value
 * between optional whitespace, and `document::at_end`
 * (`src/include/simdjson/generic/ondemand/document.h:780-784`) is upstream's own
 * answer to whether the whole text was read -- upstream asks the caller to ask
 * it, at both container ends
 * (`src/include/simdjson/generic/ondemand/value_iterator-inl.h:78-80`, `:489-491`),
 * and this walk asks it for them.  It is asked after the root value and before
 * either size is reported, so a refused document reports no counts a caller could
 * mistake for a walk of what it holds.
 *
 * A document nested past `DEFAULT_MAX_DEPTH` (1024,
 * `src/include/simdjson/base.h:49`) is refused with
 * `SIMDJSON_BRIDGE_UPSTREAM_ERROR` and `DEPTH_ERROR` in `*out_error`, before
 * the walk starts a container that deep.  Upstream's limit sizes
 * `parser::start_positions` and nothing else
 * (`src/include/simdjson/generic/ondemand/parser-inl.h:36`) and stage 1 indexes
 * every depth it is given, so nothing upstream reports it; with
 * `SIMDJSON_DEVELOPMENT_CHECKS` the bound instead reaches
 * `json_iterator::set_start_position`'s `SIMDJSON_ASSUME`
 * (`src/include/simdjson/generic/ondemand/json_iterator-inl.h:432-434`,
 * `src/include/simdjson/portability.h:243-246`), which is an assertion a process
 * aborts on.  Both the bound and the answer are upstream's own, and an ordinary
 * comparison is the difference between a refusal a caller can read and an
 * abort.
 *
 * A NULL `doc`, a NULL `out_node_count` or a NULL `out_blob_len` is
 * `SIMDJSON_BRIDGE_INVALID_ARGUMENT`; `out_error` may be NULL, as above.
 *
 * ## What a value becomes
 *
 * A record's `type` is `value::type()`
 * (`src/include/simdjson/generic/ondemand/value.h:608`), which upstream documents
 * as not consuming the value
 * (`src/include/simdjson/generic/ondemand/document.h:619`), so the same `value` can
 * then be read with the accessor its type selects.  A type of
 * `SIMDJSON_BRIDGE_TYPE_UNKNOWN` means the value's first byte is not a JSON token
 * start at all -- upstream's `value_iterator::type` returns `json_type::unknown`
 * for exactly that case
 * (`src/include/simdjson/generic/ondemand/value_iterator-inl.h:1170-1188`) -- and
 * there is no accessor that would read such a value, so the walk stops with
 * `SIMDJSON_BRIDGE_ERROR_TAPE` rather than inventing a reading for it.
 * `TAPE_ERROR` is upstream's own verdict for the same situation on its DOM path,
 * where a byte that is neither a digit, `-` nor a token start falls to `default:`
 * and logs "Non-value found when value was expected!"
 * (`src/src/generic/stage2/json_iterator.h:363-365`), so this is upstream's
 * classification carried across rather than a code invented here.
 *
 * An array's and an object's `count` is the number of children the walk actually
 * visited under that record, not a count asked for in advance.
 *
 * A number's `number_type` is `number::get_number_type` on the value from
 * `value::get_number` (`src/include/simdjson/generic/ondemand/value.h:670,704`,
 * `src/include/simdjson/generic/ondemand/json_type.h:46`), and the payload comes
 * from the matching `number` accessor.  The classification deliberately comes from
 * `get_number` and *not* from `value::get_number_type`: `numberparsing`'s
 * `get_number_type` (`src/include/simdjson/generic/numberparsing.h:1526-1568`) has
 * no leading-zero check, so it would report `signed_integer` for `{"a":01}`, a
 * number that `parse_number` then refuses with `NUMBER_ERROR`
 * (`src/include/simdjson/generic/numberparsing.h:906,919`).  A
 * `SIMDJSON_BRIDGE_NUMBER_BIG` number is a JSON integer too large for 64 bits,
 * which upstream reports through `number_type::big_integer`
 * (`src/include/simdjson/generic/base.h:47`); its decimal text is in the blob at
 * `str_off`/`str_len` and `i`, `u` and `d` are 0, because `number::get_uint64`,
 * `get_int64` and `get_double` are each documented "only valid if" their own type
 * is the number's
 * (`src/include/simdjson/generic/ondemand/json_type.h:52-58,66-72,74-78`).
 * The same case arrives as a refusal rather than as a classification: `get_number`
 * has no `number` to report for it and answers `BIGINT_ERROR`, whose documented
 * meaning is "The integer value exceeds 64 bits" (`src/include/simdjson/error.h:30`,
 * and `src/include/simdjson/generic/ondemand/value.h:689` for the On-Demand
 * surface), which `parse_number` raises at its three integer-overflow checks and
 * nowhere else
 * (`src/include/simdjson/generic/numberparsing.h:949,953,969`).  Both answers are
 * this bridge's `SIMDJSON_BRIDGE_NUMBER_BIG`.
 *
 * A string's bytes are `value::get_string`
 * (`src/include/simdjson/generic/ondemand/value.h:323`): unescaped, borrowed from
 * the parser's own buffer, and copied here before the call returns.  A null value
 * contributes `SIMDJSON_BRIDGE_TYPE_NULL` and nothing else, from `value::is_null`
 * (`value.h:401`); upstream is explicit that `type()` reporting `json_type::null`
 * still requires `is_null()` to confirm it
 * (`src/include/simdjson/generic/ondemand/document.h:619-621`).
 *
 * An object key is `field::unescaped_key`
 * (`src/include/simdjson/generic/ondemand/field.h:39-40`), which upstream documents
 * as consuming the key: it may be called once per field and no other key accessor
 * may follow it (`:32-38`).  The walk calls it exactly once.
 */
simdjson_bridge_status simdjson_br_walk(simdjson_bridge_document *doc,
                                        simdjson_bridge_node *nodes,
                                        size_t node_cap, size_t *out_node_count,
                                        char *blobs, size_t blob_cap,
                                        size_t *out_blob_len, int32_t *out_error);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* SIMDJSON_BRIDGE_H */