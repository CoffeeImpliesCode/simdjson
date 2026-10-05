// Implementation of the `extern "C"` bridge declared in `zig/bridge.h`.
//
// Every function here is a validation, at most one upstream call, and a copy
// out.  Nothing in this file knows what a structural index is, what UTF-8 is,
// what an escape sequence is, or what a valid document is: `parser::iterate`
// answers all of that, and this file only carries the answer across.
//
// The `std::bad_alloc` handling is the only exception handling, and it is
// deliberate: upstream allocates real buffers -- the padded copy of the input,
// the parser's stage-1 index, and a `std::string` from `implementation::name`
// -- and an allocation that fails is a real, reportable condition.  No other
// exception is caught, so nothing is silently turned into a success.

#include "bridge.h"

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <new>
#include <string>
#include <string_view>

// The upstream umbrella, which is what upstream's own documentation tells a
// consumer to include (`src/include/simdjson.h:11`).  It reaches, in order:
// the version header (`:41`), `base.h` and with it `error.h`, `portability.h`
// and `compiler_check.h` (`:43`), `implementation.h` (`:47`),
// `padded_string.h` (`:49`), `ondemand.h` (`:56`) and `convert.h` (`:57`).
// `compile_time_json.h` is also included (`:61`) but is inert here: its whole
// body is inside `#if SIMDJSON_STATIC_REFLECTION`
// (`src/include/simdjson/compile_time_json.h:10`), which is off unless a C++26
// reflection compiler is in use, and this translation unit is compiled at the
// `-std=c++17` upstream itself defaults to
// (`src/cmake/developer-options.cmake:125,128`).
#include <simdjson.h>

namespace {

// The two-pass drain, shared by every string-returning entry point.
//
// `cap` is what the caller offered; the string plus its NUL must fit, so the
// buffer is reported too short when `cap <= size`.
simdjson_bridge_status DrainString(const std::string &text, char *buf, size_t cap,
                                   size_t *out_len) {
  if (out_len == nullptr) {
    return SIMDJSON_BRIDGE_INVALID_ARGUMENT;
  }
  *out_len = text.size();
  if (buf == nullptr || cap == 0) {
    return SIMDJSON_BRIDGE_OK;
  }
  if (cap <= text.size()) {
    return SIMDJSON_BRIDGE_BUFFER_TOO_SMALL;
  }
  std::memcpy(buf, text.data(), text.size());
  buf[text.size()] = '\0';
  return SIMDJSON_BRIDGE_OK;
}

// The same contract for a `const char *` literal, which is what
// `SIMDJSON_VERSION` and the builtin-kernel cascade below produce.  A literal
// is never NULL here; the length is a compile-time constant.
simdjson_bridge_status DrainLiteral(const char *text, char *buf, size_t cap,
                                    size_t *out_len) {
  if (out_len == nullptr || text == nullptr) {
    return SIMDJSON_BRIDGE_INVALID_ARGUMENT;
  }
  const size_t size = std::strlen(text);
  *out_len = size;
  if (buf == nullptr || cap == 0) {
    return SIMDJSON_BRIDGE_OK;
  }
  if (cap <= size) {
    return SIMDJSON_BRIDGE_BUFFER_TOO_SMALL;
  }
  std::memcpy(buf, text, size);
  buf[size] = '\0';
  return SIMDJSON_BRIDGE_OK;
}

// The kernel the On-Demand API in this translation unit is bound to.
//
// This mirrors the priority cascade at
// `src/include/simdjson/implementation_detection.h:148-172` exactly: same nine
// arms, same order, same last-resort `fallback`.  It is a preprocessor
// question with a preprocessor answer, so it is answered by a preprocessor
// cascade and not by a call.
//
// It is deliberately *not* `simdjson::builtin_implementation()`
// (`src/include/simdjson/builtin/implementation.h:41`).  That accessor looks
// the name up in the available list and guards the result with a debug-only
// `assert` (`src/implementation.cpp:341-345`), so on a build where the builtin
// kernel was compiled out it dereferences a null pointer in every optimize
// mode except Debug.  A cascade has no such failure mode and costs nothing at
// run time.
#if SIMDJSON_BUILTIN_IMPLEMENTATION_IS(icelake)
#define SIMDJSON_BRIDGE_BUILTIN "icelake"
#elif SIMDJSON_BUILTIN_IMPLEMENTATION_IS(haswell)
#define SIMDJSON_BRIDGE_BUILTIN "haswell"
#elif SIMDJSON_BUILTIN_IMPLEMENTATION_IS(westmere)
#define SIMDJSON_BRIDGE_BUILTIN "westmere"
#elif SIMDJSON_BUILTIN_IMPLEMENTATION_IS(arm64)
#define SIMDJSON_BRIDGE_BUILTIN "arm64"
#elif SIMDJSON_BUILTIN_IMPLEMENTATION_IS(ppc64)
#define SIMDJSON_BRIDGE_BUILTIN "ppc64"
#elif SIMDJSON_BUILTIN_IMPLEMENTATION_IS(lsx)
#define SIMDJSON_BRIDGE_BUILTIN "lsx"
#elif SIMDJSON_BUILTIN_IMPLEMENTATION_IS(lasx)
#define SIMDJSON_BRIDGE_BUILTIN "lasx"
#elif SIMDJSON_BUILTIN_IMPLEMENTATION_IS(rvv_vls)
#define SIMDJSON_BRIDGE_BUILTIN "rvv_vls"
#elif SIMDJSON_BUILTIN_IMPLEMENTATION_IS(fallback)
#define SIMDJSON_BRIDGE_BUILTIN "fallback"
#else
#error "No builtin implementation was selected, so the On-Demand namespace is undefined"
#endif

// The state one `simdjson_br_walk` pass carries.
//
// `sizing` is the whole of the two-pass mechanism: when it is true the walk
// counts and writes nothing, and when it is false every write is bounds-checked
// against the caller's capacity first.  The counts are *required* sizes in both
// modes, which is what lets one pair of out-parameters answer the sizing call
// and the `BUFFER_TOO_SMALL` refusal identically.
//
// The two failure kinds are deliberately separate.  `error` is an upstream
// `simdjson::error_code` and means the document was refused; a buffer that did
// not fit is reported from the two totals, which the walk always completes, as
// `BUFFER_TOO_SMALL`.  Collapsing them would mean either reporting a capacity
// problem as an upstream failure or truncating, and neither is honest.
struct Walker {
  simdjson_bridge_node *nodes;
  size_t node_cap;
  size_t node_count;

  char *blobs;
  size_t blob_cap;
  size_t blob_len;

  bool sizing;

  // False from the first record or blob byte the caller's buffers could not
  // hold.
  //
  // A filling call that runs out of room keeps walking.  The two-pass contract
  // is that a short call reports the sizes the document *requires*, so the
  // caller can size a buffer and retry, and a count that stopped where the
  // buffers stopped would be the wrong number to size from.  Nothing is written
  // once this is false, so the buffers hold only what fitted, and
  // `simdjson_br_walk` answers `BUFFER_TOO_SMALL` from the totals it reports.
  // Sizing mode writes nothing at all, so it never clears the flag.
  bool can_write;

  // `SUCCESS` until an upstream call fails, then the code to report.  Set once
  // and returned immediately by every level of the walk, so a failure deep in
  // the document stops the whole pass rather than producing a partial result.
  simdjson::error_code error;

  // A count or an offset that cannot be represented in the record's `uint32_t`
  // field is a bridge limit, not a document problem, so it is reported as
  // upstream's own `CAPACITY` ("This parser can't support a document that big",
  // `src/include/simdjson/error.h:21`) rather than truncated.
  bool Fail(simdjson::error_code code) {
    error = code;
    return false;
  }

  // Reserves `len` bytes of blob and reports where they land.  In sizing mode
  // the offset is still computed, so the two passes agree on every offset, and
  // so does a filling call that ran out of room.
  //
  // In fill mode the reservation is also the bounds check, and it is here rather
  // than only in `WriteBlob` so that the answer is decided before the offset is
  // used: `WriteBlob` writes at the offset this returned, and an offset past a
  // buffer the caller never offered is exactly the kind of write a two-pass API
  // exists to make impossible.  A reservation that does not fit still advances
  // `blob_len`, because the length the caller needs is the whole document's.
  bool ReserveBlob(size_t len, uint32_t *out_off) {
    const size_t at = blob_len;
    if (at > SIMDJSON_BRIDGE_NO_OFFSET ||
        len > static_cast<size_t>(SIMDJSON_BRIDGE_NO_OFFSET) - at) {
      return Fail(simdjson::CAPACITY);
    }
    *out_off = static_cast<uint32_t>(at);
    if (!sizing && (at > blob_cap || len > blob_cap - at)) {
      can_write = false;
    }
    blob_len = at + len;
    return true;
  }

  // The fill half of `ReserveBlob`.  Never called in sizing mode, and called
  // with a `len` that has already been reserved; it writes nothing at all once
  // a reservation has not fitted.
  void WriteBlob(uint32_t off, const char *src, size_t len) {
    if (can_write && len != 0 && blobs != nullptr) {
      std::memcpy(blobs + off, src, len);
    }
  }

  // Appends one record.  Returns the index it occupies, which the container
  // case needs: a container's `count` is only known once its children have been
  // visited, and the record itself has to come first so the sequence is
  // pre-order.
  bool PushNode(uint32_t depth, uint32_t type, uint32_t number_type,
                uint32_t key_off, uint32_t key_len, uint32_t str_off,
                uint32_t str_len, int64_t i, uint64_t u, double d,
                size_t *out_index) {
    const size_t at = node_count;
    if (at > 0xFFFFFFFFu) {
      return Fail(simdjson::CAPACITY);
    }
    if (!sizing) {
      if (at >= node_cap) {
        // Not an upstream failure and not a truncation: the count still advances,
        // because the number the caller needs is the document's own and not the
        // number of records that happened to fit.
        can_write = false;
      } else {
        simdjson_bridge_node *const n = &nodes[at];
        n->depth = depth;
        n->type = type;
        n->count = 0;
        n->number_type = number_type;
        n->key_off = key_off;
        n->key_len = key_len;
        n->str_off = str_off;
        n->str_len = str_len;
        n->i = i;
        n->u = u;
        n->d = d;
      }
    }
    node_count = at + 1;
    *out_index = at;
    return true;
  }

};

// One non-container value.
//
// A `json_type` is reached through `simdjson::ondemand`, which *is* an alias of
// `SIMDJSON_BUILTIN_IMPLEMENTATION::ondemand`
// (`src/include/simdjson/builtin/ondemand.h:39`,
// `src/include/simdjson/ondemand.h:10`).  Writing it that way rather than naming
// the macro keeps this file identical for all nine kernels.
//
// The array and object arms are unreachable: `WalkValue` below dispatches on
// the same `type()` before it gets here, and this function is declared after it
// only because the walk needs to call it.
//
// Templated on the scalar's source because upstream has two of them and refuses
// to unify them. `document::get_value()` returns `SCALAR_DOCUMENT_AS_VALUE` for
// a document whose root is a scalar ("scalar documents are a special case in
// simdjson and they cannot be safely converted to value instances",
// `document-inl.h:102-104`), so a scalar root has to be read off the `document`
// itself. `ondemand::document` and `ondemand::value` carry the same five scalar
// accessors -- `type()`, `get_number()`, `get_string()`, `get_bool()` and
// `is_null()` -- at `document.h:645,732,213,274,297` and `value.h:608,704,323,
// 391,401`, and every one of them bottoms out in the same `value_iterator`, so
// one body is correct for both and is not duplicated here.
// The two sources differ in three shapes, and only three, so each is named here
// rather than by writing `WalkScalar` twice. `document` is deleted-copyable
// (`document.h:32`), so it is taken by reference; `get_string` takes a defaulted
// `bool allow_replacement` on `document` (`document.h:213`) and nothing on
// `value` (`value.h:323`); and `raw_json_token` returns a bare
// `std::string_view` on `value` (`value.h:731`) against a
// `simdjson_result<std::string_view>` on `document` (`document.h:756`).

// `get_string` on either source, with its error reported rather than dropped.
template <typename Scalar>
simdjson::error_code ReadString(Scalar &v, std::string_view *out) {
  return v.get_string().get(*out);
}

// `raw_json_token` on either source, with its error reported rather than
// dropped. Only the return shape differs; both read the same raw token.
template <typename Scalar>
simdjson::error_code ReadRawToken(Scalar &v, std::string_view *out) {
  if constexpr (std::is_same_v<Scalar, simdjson::ondemand::document>) {
    return v.raw_json_token().get(*out);
  } else {
    *out = v.raw_json_token();
    return simdjson::SUCCESS;
  }
}

// Records a JSON integer that does not fit in 64 bits.
//
// There are two ways to recognise this case and both are upstream's own.  A
// successful `get_number` classifies it as `number_type::big_integer`
// (`src/include/simdjson/base.h:47`), and a refused one answers `BIGINT_ERROR`,
// whose documented meaning is "The integer value exceeds 64 bits"
// (`src/include/simdjson/error.h:30`, restated for the On-Demand surface at
// `src/include/simdjson/generic/ondemand/value.h:689`).  `parse_number` raises it
// from `BIGINT_NUMBER` at its three integer-overflow checks and nowhere else
// (`src/include/simdjson/generic/numberparsing.h:949,953,969`), so a refusal with
// that code is this case and no other.
//
// The three `number` payload accessors are each documented "only valid if" their
// own type is the number's
// (`src/include/simdjson/generic/ondemand/json_type.h:52-58,66-78`), so none of
// them may be called here: the decimal text is the only reading, and it comes from
// the value's own raw token (`value::raw_json_token`, `value.h:731`).
template <typename Scalar>
bool PushBigInteger(Walker &w, Scalar &v, uint32_t depth, uint32_t key_off,
                    uint32_t key_len, size_t *out_index) {
  std::string_view token;
  const simdjson::error_code token_err = ReadRawToken(v, &token);
  if (token_err != simdjson::SUCCESS) {
    return w.Fail(token_err);
  }
  uint32_t str_off = SIMDJSON_BRIDGE_NO_OFFSET;
  if (!w.ReserveBlob(token.size(), &str_off)) {
    return false;
  }
  const uint32_t str_len = static_cast<uint32_t>(token.size());
  if (!w.sizing) {
    w.WriteBlob(str_off, token.data(), token.size());
  }
  return w.PushNode(depth, SIMDJSON_BRIDGE_TYPE_NUMBER,
                    SIMDJSON_BRIDGE_NUMBER_BIG, key_off, key_len, str_off,
                    str_len, 0, 0, 0, out_index);
}

template <typename Scalar>
bool WalkScalar(Walker &w, Scalar &v, uint32_t depth, uint32_t key_off,
                uint32_t key_len) {
  size_t index = 0;
  switch (v.type().value_unsafe()) {
  case simdjson::ondemand::json_type::number: {
    // One parse, then one read of the payload that parse produced.
    // `value::get_number` is `value_iterator::get_number`
    // (`src/include/simdjson/generic/ondemand/value_iterator-inl.h:646-647`),
    // which is `numberparsing::parse_number` over the peeked token
    // (`src/include/simdjson/generic/numberparsing.h:881-919`) -- the entry
    // point that carries the leading-zero guard at `:906`, so `{"a":01}` is
    // refused here with `NUMBER_ERROR` rather than read as 0.
    //
    // `value::get_number_type` is deliberately *not* used to classify first: it
    // is the one number entry point with no leading-zero check at all
    // (`src/include/simdjson/generic/numberparsing.h:1526-1568`), so probing
    // with it would report `signed_integer` for a number this then refuses.
    simdjson::ondemand::number num;
    const simdjson::error_code err = v.get_number().get(num);
    if (err == simdjson::BIGINT_ERROR) {
      // The refusal and the classification are the same case, so the refusal is
      // answered rather than reported: `PushBigInteger` records the decimal text,
      // which is the only reading this case has.
      return PushBigInteger(w, v, depth, key_off, key_len, &index);
    }
    if (err != simdjson::SUCCESS) {
      return w.Fail(err);
    }
    uint32_t number_type = SIMDJSON_BRIDGE_NUMBER_NONE;
    uint32_t str_off = SIMDJSON_BRIDGE_NO_OFFSET;
    uint32_t str_len = 0;
    int64_t as_i = 0;
    uint64_t as_u = 0;
    double as_d = 0;
    switch (num.get_number_type()) {
    case simdjson::ondemand::number_type::unsigned_integer:
      number_type = SIMDJSON_BRIDGE_NUMBER_UNSIGNED;
      as_u = num.get_uint64();
      break;
    case simdjson::ondemand::number_type::signed_integer:
      number_type = SIMDJSON_BRIDGE_NUMBER_SIGNED;
      as_i = num.get_int64();
      break;
    case simdjson::ondemand::number_type::floating_point_number:
      number_type = SIMDJSON_BRIDGE_NUMBER_FLOATING_POINT;
      as_d = num.get_double();
      break;
    default:
      // `parse_number` either wrote one of the three payload types above or
      // refused the token, so `big_integer` is answered by the `BIGINT_ERROR`
      // arm before this switch and nothing else reaches `default`.
      return w.Fail(simdjson::TAPE_ERROR);
    }
    return w.PushNode(depth, SIMDJSON_BRIDGE_TYPE_NUMBER, number_type, key_off,
                      key_len, str_off, str_len, as_i, as_u, as_d, &index);
  }
  case simdjson::ondemand::json_type::string: {
    // `value::get_string` (`value.h:323`) is
    // `value_iterator::get_string`
    // (`value_iterator-inl.h:549-550`): it unescapes in place into the parser's
    // own buffer and returns a view of it, so the bytes are borrowed for this
    // call and have to be copied before the call returns.
    std::string_view text;
    const simdjson::error_code err = ReadString(v, &text);
    if (err != simdjson::SUCCESS) {
      return w.Fail(err);
    }
    uint32_t str_off = SIMDJSON_BRIDGE_NO_OFFSET;
    if (!w.ReserveBlob(text.size(), &str_off)) {
      return false;
    }
    const uint32_t str_len = static_cast<uint32_t>(text.size());
    if (!w.sizing) {
      w.WriteBlob(str_off, text.data(), text.size());
    }
    return w.PushNode(depth, SIMDJSON_BRIDGE_TYPE_STRING,
                      SIMDJSON_BRIDGE_NUMBER_NONE, key_off, key_len, str_off,
                      str_len, 0, 0, 0, &index);
  }
  case simdjson::ondemand::json_type::boolean: {
    // `value::get_bool` (`value.h:391`).
    bool truth = false;
    const simdjson::error_code err = v.get_bool().get(truth);
    if (err != simdjson::SUCCESS) {
      return w.Fail(err);
    }
    return w.PushNode(depth, SIMDJSON_BRIDGE_TYPE_BOOLEAN,
                      SIMDJSON_BRIDGE_NUMBER_NONE, key_off, key_len,
                      SIMDJSON_BRIDGE_NO_OFFSET, 0, truth ? 1 : 0, 0, 0, &index);
  }
  case simdjson::ondemand::json_type::null: {
    // `value::is_null` (`value.h:401`).  Upstream is explicit that `type()`
    // reporting `json_type::null` is not the answer -- "you must still call
    // \"is_null()\" to check that a value is null even if \"type()\" returns
    // json_type::null" (`src/include/simdjson/generic/ondemand/document.h:621`)
    // -- so this is what distinguishes `null` from the four letters `null`.
    //
    // What the call contributes here is its error code, not its boolean:
    // `value_iterator::parse_null` (`value_iterator-inl.h:543-546`) answers
    // `INCORRECT_TYPE` for a token that begins with `n` and is not `null`, so a
    // call that returns `SUCCESS` has already confirmed the literal and the
    // boolean has nothing left to decide.  Reading the code is also what keeps
    // this arm from discarding a result.
    const simdjson::error_code err = v.is_null().error();
    if (err != simdjson::SUCCESS) {
      return w.Fail(err);
    }
    return w.PushNode(depth, SIMDJSON_BRIDGE_TYPE_NULL,
                      SIMDJSON_BRIDGE_NUMBER_NONE, key_off, key_len,
                      SIMDJSON_BRIDGE_NO_OFFSET, 0, 0, 0, 0, &index);
  }
  case simdjson::ondemand::json_type::array:
  case simdjson::ondemand::json_type::object:
    // Not reachable: `WalkValue` handles both before it would call this.
    return w.Fail(simdjson::TAPE_ERROR);
  case simdjson::ondemand::json_type::unknown:
  default:
    // The value's first byte is not a JSON token start at all.
    // `value_iterator::type` answers `json_type::unknown` for exactly that
    // (`src/include/simdjson/generic/ondemand/value_iterator-inl.h:1170-1188`)
    // and there is no accessor that would read such a value.  `TAPE_ERROR` is
    // upstream's own verdict for the same byte on its DOM path
    // (`src/src/generic/stage2/json_iterator.h:363-365`).
    return w.Fail(simdjson::TAPE_ERROR);
  }
}

// The whole recursive walk.
//
// Descending into a child container and consuming it fully before advancing the
// parent iterator is the pattern upstream documents and implements; holding a
// value across a parent's `operator++` is what `OUT_OF_ORDER_ITERATION` exists
// to catch (`src/include/simdjson/error.h:46`,
// `src/include/simdjson/generic/ondemand/document.h:560-569`).  The recursion
// is bounded by upstream's own nesting limit, `DEFAULT_MAX_DEPTH` = 1024
// (`src/include/simdjson/base.h:49`), which the walk checks for itself before it
// descends; the reason it has to is written where the check is.
bool WalkValue(Walker &w, simdjson::ondemand::value v, uint32_t depth,
               uint32_t key_off, uint32_t key_len) {
  const simdjson::ondemand::json_type type = v.type().value_unsafe();

  // The nesting bound, checked before a container is started.  Upstream's limit
  // sizes `parser::start_positions`, a scratch array of `parser::max_depth()`
  // entries (`src/include/simdjson/generic/ondemand/parser-inl.h:36`), and with
  // `SIMDJSON_DEVELOPMENT_CHECKS` -- which this build passes on every target, in
  // every optimize mode -- starting a container asserts that it is inside that
  // array (`value_iterator-inl.h:58-60` and `:472-478` record the position,
  // `json_iterator-inl.h:432-434` assumes it fits, and `SIMDJSON_ASSUME` is
  // `assert` in exactly the builds that keep development checks on,
  // `src/include/simdjson/portability.h:243-246`).  Stage 1 does not bound the
  // depth: it indexes every level it is given, so nothing upstream turns a
  // document this deep into an error before the walk would reach it, and the
  // alternative to this comparison is a process that aborts on a document any
  // caller may hand it.
  //
  // So both the bound and the answer are upstream's own: `DEFAULT_MAX_DEPTH`
  // and `DEPTH_ERROR` ("Your document exceeds the user-specified depth limitation",
  // `src/include/simdjson/error.h:24`).  A container's `value_iterator` descends
  // one level before it records its start position (`value_iterator::
  // start_container` calls `descend_to`), so the assert would fire one level
  // past this refusal: the deepest container this walk may start is the one at
  // `DEFAULT_MAX_DEPTH - 2`.
  if (depth + 1 >= simdjson::DEFAULT_MAX_DEPTH) {
    return w.Fail(simdjson::DEPTH_ERROR);
  }
  if (type == simdjson::ondemand::json_type::array) {
    simdjson::ondemand::array arr;
    const simdjson::error_code arr_err = v.get_array().get(arr);
    if (arr_err != simdjson::SUCCESS) {
      return w.Fail(arr_err);
    }
    size_t index = 0;
    if (!w.PushNode(depth, SIMDJSON_BRIDGE_TYPE_ARRAY,
                    SIMDJSON_BRIDGE_NUMBER_NONE, key_off, key_len,
                    SIMDJSON_BRIDGE_NO_OFFSET, 0, 0, 0, 0, &index)) {
      return false;
    }

    // `array::begin` / `array::end` are the documented iteration pair
    // (`src/include/simdjson/generic/ondemand/array.h:36,49`).  Both return a
    // `simdjson_result<iterator>`, and with `SIMDJSON_EXCEPTIONS=0` that type
    // has no conversion operator to the iterator
    // (`src/include/simdjson/error.h:220-223` is inside `#if
    // SIMDJSON_EXCEPTIONS`), so each is unwrapped explicitly and its error
    // checked rather than discarded.
    simdjson::ondemand::array_iterator begin_it;
    const simdjson::error_code begin_err = arr.begin().get(begin_it);
    if (begin_err != simdjson::SUCCESS) {
      return w.Fail(begin_err);
    }
    simdjson::ondemand::array_iterator end_it;
    const simdjson::error_code end_err = arr.end().get(end_it);
    if (end_err != simdjson::SUCCESS) {
      return w.Fail(end_err);
    }

    // `array_iterator::operator*` is "MUST ONLY BE CALLED ONCE PER ITERATION"
    // (`array_iterator.h:53-54`), which is exactly what this loop does: one
    // dereference, one recursion, one increment.
    uint32_t count = 0;
    while (begin_it != end_it) {
      simdjson::ondemand::value child;
      const simdjson::error_code child_err = (*begin_it).get(child);
      if (child_err != simdjson::SUCCESS) {
        return w.Fail(child_err);
      }
      if (!WalkValue(w, child, depth + 1, SIMDJSON_BRIDGE_NO_OFFSET, 0)) {
        return false;
      }
      ++begin_it;
      count++;
    }
    if (!w.sizing && index < w.node_cap) {
      w.nodes[index].count = count;
    }
    return true;
  }

  if (type == simdjson::ondemand::json_type::object) {
    simdjson::ondemand::object obj;
    const simdjson::error_code obj_err = v.get_object().get(obj);
    if (obj_err != simdjson::SUCCESS) {
      return w.Fail(obj_err);
    }
    size_t index = 0;
    if (!w.PushNode(depth, SIMDJSON_BRIDGE_TYPE_OBJECT,
                    SIMDJSON_BRIDGE_NUMBER_NONE, key_off, key_len,
                    SIMDJSON_BRIDGE_NO_OFFSET, 0, 0, 0, 0, &index)) {
      return false;
    }

    // The same pair as above, from `object::begin` / `object::end`
    // (`src/include/simdjson/generic/ondemand/object.h:150,158`).
    simdjson::ondemand::object_iterator begin_it;
    const simdjson::error_code begin_err = obj.begin().get(begin_it);
    if (begin_err != simdjson::SUCCESS) {
      return w.Fail(begin_err);
    }
    simdjson::ondemand::object_iterator end_it;
    const simdjson::error_code end_err = obj.end().get(end_it);
    if (end_err != simdjson::SUCCESS) {
      return w.Fail(end_err);
    }

    // `object_iterator::operator++` is documented "YOU MUST NOT CALL THIS IF
    // operator* YIELDED AN ERROR" and "WITHOUT A CORRESPONDING operator* CALL"
    // (`object_iterator.h:44-46`), which is why every failure below returns
    // instead of falling through to the increment.
    uint32_t count = 0;
    while (begin_it != end_it) {
      simdjson::ondemand::field field;
      const simdjson::error_code field_err = (*begin_it).get(field);
      if (field_err != simdjson::SUCCESS) {
        return w.Fail(field_err);
      }
      // `field::unescaped_key` consumes the key and forbids any other key
      // accessor after it (`src/include/simdjson/generic/ondemand/field.h:32-40`),
      // so it is called exactly once, here, and its bytes are copied before the
      // recursion into the field's value.
      std::string_view key;
      const simdjson::error_code key_err = field.unescaped_key().get(key);
      if (key_err != simdjson::SUCCESS) {
        return w.Fail(key_err);
      }
      uint32_t child_key_off = SIMDJSON_BRIDGE_NO_OFFSET;
      if (!w.ReserveBlob(key.size(), &child_key_off)) {
        return false;
      }
      const uint32_t child_key_len = static_cast<uint32_t>(key.size());
      if (!w.sizing) {
        w.WriteBlob(child_key_off, key.data(), key.size());
      }
      if (!WalkValue(w, field.value(), depth + 1, child_key_off, child_key_len)) {
        return false;
      }
      ++begin_it;
      count++;
    }
    if (!w.sizing && index < w.node_cap) {
      w.nodes[index].count = count;
    }
    return true;
  }

  return WalkScalar(w, v, depth, key_off, key_len);
}

}  // namespace

// The opaque handle.
//
// Member order is the construction order, and it is the order the ownership
// requires:
//
//   * `input` holds the caller's bytes, copied and padded.  It has to exist
//     before the document, because `parser::iterate` is handed a view of it
//     (`src/include/simdjson/generic/ondemand/parser-inl.h:54,66`) and refuses
//     a view without padding (`:55`, `src/include/simdjson/error.h:47`).
//   * `parser` owns the stage-1 index the document walks.
//   * `doc` is a cursor into that index.  It is default-constructible and
//     move-assignable (`src/include/simdjson/generic/ondemand/document.h:31-35`),
//     so the handle is one object whose construction cannot half-fail: the
//     document is filled in only after `iterate` has succeeded.
//
// A `simdjson_bridge_document` is only ever reached through a fully constructed
// `simdjson_br_open`, so all three members are always present.
struct simdjson_bridge_document {
  simdjson::padded_string input;
  std::unique_ptr<simdjson::ondemand::parser> parser;
  simdjson::ondemand::document doc;
};

extern "C" {

// --- Library-level facts ---------------------------------------------------

simdjson_bridge_status simdjson_br_version(char *buf, size_t cap,
                                          size_t *out_len) {
  // `SIMDJSON_VERSION` is a header constant
  // (`src/include/simdjson/simdjson_version.h:7`), so this needs no upstream
  // call and cannot fail for any reason but a bad argument.
  return DrainLiteral(SIMDJSON_VERSION, buf, cap, out_len);
}

simdjson_bridge_status simdjson_br_builtin_implementation(char *buf, size_t cap,
                                                         size_t *out_len) {
  return DrainLiteral(SIMDJSON_BRIDGE_BUILTIN, buf, cap, out_len);
}

simdjson_bridge_status simdjson_br_active_implementation(char *buf, size_t cap,
                                                        size_t *out_len) {
  try {
    // `get_active_implementation` (`src/include/simdjson/implementation.h:226`)
    // returns a reference to an `atomic_ptr`, so this is a dereference, not a
    // pointer read.  The first such dereference is what performs CPUID detection
    // and memoises the winner
    // (`src/implementation.cpp:321-332,186-207,296-312`).
    //
    // `name()` is `virtual std::string name() const`
    // (`src/include/simdjson/implementation.h:56`), so it returns by value and
    // allocates; that allocation is upstream's, and it is why this call is
    // inside a `try`.
    return DrainString(simdjson::get_active_implementation()->name(), buf, cap,
                       out_len);
  } catch (const std::bad_alloc &) {
    return SIMDJSON_BRIDGE_OUT_OF_MEMORY;
  }
}

simdjson_bridge_status simdjson_br_active_implementation_description(
    char *buf, size_t cap, size_t *out_len) {
  try {
    // `description()` is the same accessor as `name()`
    // (`src/include/simdjson/implementation.h:66`), with the same allocation.
    return DrainString(simdjson::get_active_implementation()->description(), buf,
                       cap, out_len);
  } catch (const std::bad_alloc &) {
    return SIMDJSON_BRIDGE_OUT_OF_MEMORY;
  }
}

size_t simdjson_br_available_implementation_count(void) {
  // `available_implementation_list::size`
  // (`src/include/simdjson/implementation.h:173`,
  // `src/implementation.cpp:277-285`).  A count of pointers cannot fail.
  return simdjson::get_available_implementations().size();
}

simdjson_bridge_status simdjson_br_available_implementation_name(
    size_t index, char *buf, size_t cap, size_t *out_len) {
  if (out_len == nullptr) {
    return SIMDJSON_BRIDGE_INVALID_ARGUMENT;
  }
  *out_len = 0;
  const simdjson::internal::available_implementation_list &list =
      simdjson::get_available_implementations();
  if (index >= list.size()) {
    return SIMDJSON_BRIDGE_INVALID_ARGUMENT;
  }
  try {
    // `begin()` / `end()` are the list's own STL iterators
    // (`src/include/simdjson/implementation.h:174-175`), and the list has no
    // subscript operator of its own, so the index is advanced over them.
    const simdjson::implementation *const impl = *(list.begin() + index);
    return DrainString(impl->name(), buf, cap, out_len);
  } catch (const std::bad_alloc &) {
    return SIMDJSON_BRIDGE_OUT_OF_MEMORY;
  }
}

simdjson_bridge_status simdjson_br_validate_utf8(const char *json, size_t len,
                                                 int *out_ok) {
  if (out_ok == nullptr) {
    return SIMDJSON_BRIDGE_INVALID_ARGUMENT;
  }
  if (json == nullptr && len != 0) {
    return SIMDJSON_BRIDGE_INVALID_ARGUMENT;
  }
  // `validate_utf8(const char *, size_t)` is
  // `src/include/simdjson/implementation.h:18`, a virtual on the active
  // implementation, so it is a total function that cannot fail.  A NULL pointer
  // with a zero length is an empty range, which is valid UTF-8, and it is passed
  // through rather than special-cased.
  *out_ok = simdjson::validate_utf8(json, len) ? 1 : 0;
  return SIMDJSON_BRIDGE_OK;
}

// --- Document --------------------------------------------------------------

simdjson_bridge_status simdjson_br_open(const char *json, size_t len,
                                        simdjson_bridge_document **out,
                                        int32_t *out_error) {
  if (out == nullptr) {
    return SIMDJSON_BRIDGE_INVALID_ARGUMENT;
  }
  // Cleared before anything is validated, so a caller that ignores the status
  // never dereferences a stale handle.
  *out = nullptr;
  if (out_error != nullptr) {
    *out_error = SIMDJSON_BRIDGE_ERROR_NONE;
  }
  if (json == nullptr) {
    return SIMDJSON_BRIDGE_INVALID_ARGUMENT;
  }
  // `padded_string(const char *, size_t)` allocates `len + SIMDJSON_PADDING`
  // (`src/include/simdjson/padded_string-inl.h:66-74`) and `SIMDJSON_PADDING` is
  // 64 (`src/include/simdjson/base.h:42`), so the sum is the first thing that
  // can wrap.
  if (len > SIZE_MAX - simdjson::SIMDJSON_PADDING) {
    return SIMDJSON_BRIDGE_INVALID_ARGUMENT;
  }

  try {
    std::unique_ptr<simdjson_bridge_document> handle(
        new simdjson_bridge_document());
    handle->input = simdjson::padded_string(json, len);
    if (len != 0 && handle->input.data() == nullptr) {
      // `padded_string` leaves `data_ptr` null and zeroes `viable_size` when its
      // own allocation fails (`src/include/simdjson/padded_string-inl.h:67,71-73`).
      // That is an allocation failure, and `MEMALLOC` ("Error allocating
      // memory, most likely out of memory", `src/include/simdjson/error.h:22`)
      // is the code upstream's own parser would have produced, so it is that
      // code and not a bridge-specific one.
      if (out_error != nullptr) {
        *out_error = SIMDJSON_BRIDGE_ERROR_MEMALLOC;
      }
      return SIMDJSON_BRIDGE_UPSTREAM_ERROR;
    }
    // UTF-8 is refused before stage 1 runs, on every target, and the refusal is
    // upstream's own enumerator. `parser::iterate` documents `UTF8_ERROR` as its
    // answer for a document that is not valid UTF-8
    // (`src/include/simdjson/generic/ondemand/parser.h:113`), and the SIMD
    // implementations keep that promise inside stage 1: their indexer runs the
    // checker over every block
    // (`src/generic/stage1/json_structural_indexer.h:241-243`). The scalar
    // `fallback` implementation does not: `validate_utf8_character()` is reached
    // only from `validate_string()`
    // (`src/src/fallback.cpp:198-203`), so a byte `>= 0x80` outside a string
    // becomes part of an atom (`:227-240`) and stage 2 refuses the document as
    // `TAPE_ERROR` instead. Which kernel is compiled in is a property of the
    // target's flags, so the same bytes were refused with two different
    // enumerators depending on the target, and on the fifteen matrix cells whose
    // only compiled kernel is `fallback` a document that is not valid UTF-8 was
    // accepted outright.
    //
    // `simdjson::validate_utf8` is upstream's own validator over the same bytes
    // (`src/include/simdjson/implementation.h:18`) -- the entry point
    // `simdjson_br_validate_utf8` already calls below -- so this is upstream
    // answering, not a second opinion invented here, and it makes `parse` and
    // `validateUtf8` agree by construction. It runs first, so `UTF8_ERROR` takes
    // the same precedence on every target that it takes inside stage 1 on the
    // SIMD ones. An empty document is valid UTF-8, so `EMPTY` is still stage 1's
    // to raise.
    if (!simdjson::validate_utf8(json, len)) {
      if (out_error != nullptr) {
        *out_error = static_cast<int32_t>(simdjson::UTF8_ERROR);
      }
      return SIMDJSON_BRIDGE_UPSTREAM_ERROR;
    }
    handle->parser.reset(new simdjson::ondemand::parser());
    simdjson::ondemand::document parsed;
    // `parser::iterate(padded_string_view)`
    // (`src/include/simdjson/generic/ondemand/parser.h:117`,
    // `parser-inl.h:54-67`) runs stage 1 over the padded input and returns
    // through `SIMDJSON_TRY`
    // (`src/include/simdjson/common_defs.h:302`), so a structural error stage 1
    // itself finds is reported here and no document is produced.  It is not
    // every one, and this comment used to say it was: measured against this
    // tree's own archive, `iterate` returns SUCCESS for `{"a":1,}`,
    // `{"a":01}`, `1e400` and `1 2`, and those are reported later -- from
    // `document::get_value`'s root-container check and from the value accessors
    // during `simdjson_br_walk`.  A caller therefore sees a refusal from
    // whichever of the two entry points upstream raises it in, and both carry
    // the enumerator unchanged.  `padded_string` converts to a
    // `padded_string_view` implicitly
    // (`src/include/simdjson/padded_string.h:119`), which is how the padded
    // capacity travels with the length.
    const simdjson::error_code err = handle->parser->iterate(handle->input).get(parsed);
    if (err != simdjson::SUCCESS) {
      if (out_error != nullptr) {
        *out_error = static_cast<int32_t>(err);
      }
      return SIMDJSON_BRIDGE_UPSTREAM_ERROR;
    }
    handle->doc = std::move(parsed);
    *out = handle.release();
    return SIMDJSON_BRIDGE_OK;
  } catch (const std::bad_alloc &) {
    return SIMDJSON_BRIDGE_OUT_OF_MEMORY;
  }
}
void simdjson_br_destroy(simdjson_bridge_document *doc) {
  // NULL is accepted so a `deinit` after a failed `simdjson_br_open` is safe.
  // `delete` on a null pointer is already a no-op, but the check is written out
  // because the header's promise is a contract rather than an accident of the
  // operator.
  if (doc == nullptr) {
    return;
  }
  delete doc;
}

simdjson_bridge_status simdjson_br_input_size(const simdjson_bridge_document *doc,
                                              size_t *out_len) {
  if (out_len == nullptr || doc == nullptr) {
    return SIMDJSON_BRIDGE_INVALID_ARGUMENT;
  }
  // `padded_string::size()` is the viable length
  // (`src/include/simdjson/padded_string.h:81`), which is what was handed to
  // `simdjson_br_open` and not the padded capacity.
  *out_len = doc->input.size();
  return SIMDJSON_BRIDGE_OK;
}

simdjson_bridge_status simdjson_br_walk(simdjson_bridge_document *doc,
                                        simdjson_bridge_node *nodes,
                                        size_t node_cap, size_t *out_node_count,
                                        char *blobs, size_t blob_cap,
                                        size_t *out_blob_len,
                                        int32_t *out_error) {
  if (doc == nullptr || out_node_count == nullptr || out_blob_len == nullptr) {
    return SIMDJSON_BRIDGE_INVALID_ARGUMENT;
  }
  // Written before anything can fail, so a rejected call still reports what it
  // knows and never leaves the caller's counts uninitialised.
  *out_node_count = 0;
  *out_blob_len = 0;
  if (out_error != nullptr) {
    *out_error = SIMDJSON_BRIDGE_ERROR_NONE;
  }

  // The record array alone decides.  The header says why: a document may have
  // no keys and no strings at all -- `42` is one -- so its required blob length is
  // zero, and a rule that made "blob capacity is zero" mean "sizing call" would
  // make such a document impossible to fill.  A filling call may therefore pass
  // `blobs == nullptr` with `blob_cap == 0`; the walk runs, reports the true
  // required blob length, and refuses with `BUFFER_TOO_SMALL` if that length is
  // non-zero, so nothing is ever written past what the caller offered.
  const bool sizing = (nodes == nullptr || node_cap == 0);

  Walker w;
  w.nodes = nodes;
  w.node_cap = node_cap;
  w.node_count = 0;
  w.blobs = blobs;
  w.blob_cap = blob_cap;
  w.blob_len = 0;
  w.sizing = sizing;
  w.can_write = true;
  w.error = simdjson::SUCCESS;

  try {
    // `document::rewind` (`src/include/simdjson/generic/ondemand/document.h:763`,
    // `document-inl.h:35-36`) is what makes a second pass legal: it resets the
    // cursor to the start of the document, which is the state `iterate` left it
    // in.  Both passes rewind, so the sizing pass and the filling pass cannot
    // disagree about a single offset.
    doc->doc.rewind();
    // A scalar root is read off the `document`, a container root off a `value`.
    // `document::get_value()` answers `SCALAR_DOCUMENT_AS_VALUE` for the former
    // by design (`document-inl.h:102-104`), and `document::is_scalar()`
    // (`document-inl.h:360-366`) is upstream's own predicate for exactly that
    // split, so it is asked rather than re-derived from a `type()` here.
    bool scalar_root = false;
    const simdjson::error_code scalar_err = doc->doc.is_scalar().get(scalar_root);
    if (scalar_err != simdjson::SUCCESS) {
      if (out_error != nullptr) {
        *out_error = static_cast<int32_t>(scalar_err);
      }
      return SIMDJSON_BRIDGE_UPSTREAM_ERROR;
    }
    simdjson::ondemand::value root;
    if (!scalar_root) {
      const simdjson::error_code root_err = doc->doc.get_value().get(root);
      if (root_err != simdjson::SUCCESS) {
        if (out_error != nullptr) {
          *out_error = static_cast<int32_t>(root_err);
        }
        return SIMDJSON_BRIDGE_UPSTREAM_ERROR;
      }
    }
    const bool walked = scalar_root
                            ? WalkScalar(w, doc->doc, 0, SIMDJSON_BRIDGE_NO_OFFSET, 0)
                            : WalkValue(w, root, 0, SIMDJSON_BRIDGE_NO_OFFSET, 0);

    *out_node_count = w.node_count;
    *out_blob_len = w.blob_len;

    if (!walked) {
      if (out_error != nullptr) {
        *out_error = static_cast<int32_t>(w.error);
      }
      return SIMDJSON_BRIDGE_UPSTREAM_ERROR;
    }
    // A JSON text is one value and optional whitespace (RFC 8259 section 2,
    // `JSON-text = ws value ws`), so a walk that stopped while the parser still
    // had a token in front of it has not read the whole document.  Upstream
    // checks this only for a *root scalar*, through the `check_trailing`
    // argument on its `get_root_*` accessors
    // (`src/include/simdjson/generic/ondemand/value_iterator-inl.h:664,735,902,913`);
    // after a container root nothing upstream looks at what follows, and
    // upstream says so at the two container ends: "Users concerned with garbage
    // content should call `at_end()` on the document instance at the end of the
    // processing" (`value_iterator-inl.h:78-80`, `:489-491`).
    //
    // So it is asked here, once, after the root value is consumed and before
    // either pass reports a size.  `document::at_end`
    // (`src/include/simdjson/generic/ondemand/document.h:780-784`) is "true if
    // this document has been fully parsed ... if you have consumed the whole
    // document and at_end() returns false, then there may be trailing content",
    // and `TRAILING_CONTENT` (`src/include/simdjson/error.h:51`) is upstream's
    // own name for that.  Both passes rewind first, so the answer is the same
    // either way.
    if (!doc->doc.at_end()) {
      if (out_error != nullptr) {
        *out_error = static_cast<int32_t>(simdjson::TRAILING_CONTENT);
      }
      return SIMDJSON_BRIDGE_UPSTREAM_ERROR;
    }
    // Nothing above tripped, so the walk completed.  Its totals are checked here
    // so that the refusal is a property of the call rather than of the walk's
    // internal state, and it costs two compares: the walk always finishes, even
    // when the buffers ran out, because the sizes a short call reports are the
    // ones the caller must allocate for.  `>` and not `>=`: a filling call that
    // offered exactly the right number of records finishes with
    // `node_count == node_cap`, which is a success, and treating that as an
    // overflow would refuse every correct call.
    if (!sizing && (w.node_count > node_cap || w.blob_len > blob_cap)) {
      return SIMDJSON_BRIDGE_BUFFER_TOO_SMALL;
    }
    return SIMDJSON_BRIDGE_OK;
  } catch (const std::bad_alloc &) {
    return SIMDJSON_BRIDGE_OUT_OF_MEMORY;
  }
}

}  // extern "C"
static_assert(static_cast<int>(simdjson::NUMBER_OUT_OF_RANGE) ==
                  SIMDJSON_BRIDGE_ERROR_NUMBER_OUT_OF_RANGE,
              "NUMBER_OUT_OF_RANGE");
static_assert(static_cast<int>(simdjson::INDEX_OUT_OF_BOUNDS) ==
                  SIMDJSON_BRIDGE_ERROR_INDEX_OUT_OF_BOUNDS,
              "INDEX_OUT_OF_BOUNDS");
static_assert(static_cast<int>(simdjson::NO_SUCH_FIELD) ==
                  SIMDJSON_BRIDGE_ERROR_NO_SUCH_FIELD,
              "NO_SUCH_FIELD");
static_assert(static_cast<int>(simdjson::IO_ERROR) == SIMDJSON_BRIDGE_ERROR_IO_ERROR,
              "IO_ERROR");
static_assert(static_cast<int>(simdjson::INVALID_JSON_POINTER) ==
                  SIMDJSON_BRIDGE_ERROR_INVALID_JSON_POINTER,
              "INVALID_JSON_POINTER");
static_assert(static_cast<int>(simdjson::INVALID_URI_FRAGMENT) ==
                  SIMDJSON_BRIDGE_ERROR_INVALID_URI_FRAGMENT,
              "INVALID_URI_FRAGMENT");
static_assert(static_cast<int>(simdjson::UNEXPECTED_ERROR) ==
                  SIMDJSON_BRIDGE_ERROR_UNEXPECTED_ERROR,
              "UNEXPECTED_ERROR");
static_assert(static_cast<int>(simdjson::PARSER_IN_USE) ==
                  SIMDJSON_BRIDGE_ERROR_PARSER_IN_USE,
              "PARSER_IN_USE");
static_assert(static_cast<int>(simdjson::OUT_OF_ORDER_ITERATION) ==
                  SIMDJSON_BRIDGE_ERROR_OUT_OF_ORDER_ITERATION,
              "OUT_OF_ORDER_ITERATION");
static_assert(static_cast<int>(simdjson::INSUFFICIENT_PADDING) ==
                  SIMDJSON_BRIDGE_ERROR_INSUFFICIENT_PADDING,
              "INSUFFICIENT_PADDING");
static_assert(static_cast<int>(simdjson::INCOMPLETE_ARRAY_OR_OBJECT) ==
                  SIMDJSON_BRIDGE_ERROR_INCOMPLETE_ARRAY_OR_OBJECT,
              "INCOMPLETE_ARRAY_OR_OBJECT");
static_assert(static_cast<int>(simdjson::SCALAR_DOCUMENT_AS_VALUE) ==
                  SIMDJSON_BRIDGE_ERROR_SCALAR_DOCUMENT_AS_VALUE,
              "SCALAR_DOCUMENT_AS_VALUE");
static_assert(static_cast<int>(simdjson::OUT_OF_BOUNDS) ==
                  SIMDJSON_BRIDGE_ERROR_OUT_OF_BOUNDS,
              "OUT_OF_BOUNDS");
static_assert(static_cast<int>(simdjson::TRAILING_CONTENT) ==
                  SIMDJSON_BRIDGE_ERROR_TRAILING_CONTENT,
              "TRAILING_CONTENT");
static_assert(static_cast<int>(simdjson::OUT_OF_CAPACITY) ==
                  SIMDJSON_BRIDGE_ERROR_OUT_OF_CAPACITY,
              "OUT_OF_CAPACITY");
static_assert(static_cast<int>(simdjson::UNKNOWN_FIELD) ==
                  SIMDJSON_BRIDGE_ERROR_UNKNOWN_FIELD,
              "UNKNOWN_FIELD");
static_assert(static_cast<int>(simdjson::NUM_ERROR_CODES) ==
                  SIMDJSON_BRIDGE_NUM_ERROR_CODES,
              "NUM_ERROR_CODES");

// The numeric values `zig/bridge.h` publishes are upstream's, and this is
// where that claim is made true.  Each of these is checked by the C++ compiler
// every time this file is built, on every target, so a header edit that
// renumbers a mirror without renumbering the enumerator fails the build rather
// than quietly changing what a C caller compares against.
//
// The comparisons are against the real enumerators in the unnamed `simdjson`
// namespace, because `error.h:19` declares `enum error_code` -- an unscoped
// enumeration -- directly inside `namespace simdjson`.
static_assert(static_cast<int>(simdjson::SUCCESS) == SIMDJSON_BRIDGE_ERROR_NONE,
              "simdjson_bridge_error_code::NONE must be simdjson::SUCCESS");
static_assert(static_cast<int>(simdjson::CAPACITY) == SIMDJSON_BRIDGE_ERROR_CAPACITY,
              "CAPACITY");
static_assert(static_cast<int>(simdjson::MEMALLOC) == SIMDJSON_BRIDGE_ERROR_MEMALLOC,
              "MEMALLOC");
static_assert(static_cast<int>(simdjson::TAPE_ERROR) == SIMDJSON_BRIDGE_ERROR_TAPE,
              "TAPE_ERROR");
static_assert(static_cast<int>(simdjson::DEPTH_ERROR) == SIMDJSON_BRIDGE_ERROR_DEPTH,
              "DEPTH_ERROR");
static_assert(static_cast<int>(simdjson::STRING_ERROR) == SIMDJSON_BRIDGE_ERROR_STRING,
              "STRING_ERROR");
static_assert(static_cast<int>(simdjson::T_ATOM_ERROR) == SIMDJSON_BRIDGE_ERROR_T_ATOM,
              "T_ATOM_ERROR");
static_assert(static_cast<int>(simdjson::F_ATOM_ERROR) == SIMDJSON_BRIDGE_ERROR_F_ATOM,
              "F_ATOM_ERROR");
static_assert(static_cast<int>(simdjson::N_ATOM_ERROR) == SIMDJSON_BRIDGE_ERROR_N_ATOM,
              "N_ATOM_ERROR");
static_assert(static_cast<int>(simdjson::NUMBER_ERROR) == SIMDJSON_BRIDGE_ERROR_NUMBER,
              "NUMBER_ERROR");
static_assert(static_cast<int>(simdjson::BIGINT_ERROR) == SIMDJSON_BRIDGE_ERROR_BIGINT,
              "BIGINT_ERROR");
static_assert(static_cast<int>(simdjson::UTF8_ERROR) == SIMDJSON_BRIDGE_ERROR_UTF8,
              "UTF8_ERROR");
static_assert(static_cast<int>(simdjson::UNINITIALIZED) == SIMDJSON_BRIDGE_ERROR_UNINITIALIZED,
              "UNINITIALIZED");
static_assert(static_cast<int>(simdjson::EMPTY) == SIMDJSON_BRIDGE_ERROR_EMPTY,
              "EMPTY");
static_assert(static_cast<int>(simdjson::UNESCAPED_CHARS) == SIMDJSON_BRIDGE_ERROR_UNESCAPED_CHARS,
              "UNESCAPED_CHARS");
static_assert(static_cast<int>(simdjson::UNCLOSED_STRING) == SIMDJSON_BRIDGE_ERROR_UNCLOSED_STRING,
              "UNCLOSED_STRING");
static_assert(static_cast<int>(simdjson::UNSUPPORTED_ARCHITECTURE) == SIMDJSON_BRIDGE_ERROR_UNSUPPORTED_ARCHITECTURE,
              "UNSUPPORTED_ARCHITECTURE");
static_assert(static_cast<int>(simdjson::INCORRECT_TYPE) == SIMDJSON_BRIDGE_ERROR_INCORRECT_TYPE,
              "INCORRECT_TYPE");

// `json_type` is a scoped enumeration with explicit values
// (`src/include/simdjson/generic/ondemand/json_type.h:17-26`).
static_assert(static_cast<int>(simdjson::ondemand::json_type::unknown) ==
                  SIMDJSON_BRIDGE_TYPE_UNKNOWN,
              "json_type::unknown");
static_assert(static_cast<int>(simdjson::ondemand::json_type::array) ==
                  SIMDJSON_BRIDGE_TYPE_ARRAY,
              "json_type::array");
static_assert(static_cast<int>(simdjson::ondemand::json_type::object) ==
                  SIMDJSON_BRIDGE_TYPE_OBJECT,
              "json_type::object");
static_assert(static_cast<int>(simdjson::ondemand::json_type::number) ==
                  SIMDJSON_BRIDGE_TYPE_NUMBER,
              "json_type::number");
static_assert(static_cast<int>(simdjson::ondemand::json_type::string) ==
                  SIMDJSON_BRIDGE_TYPE_STRING,
              "json_type::string");
static_assert(static_cast<int>(simdjson::ondemand::json_type::boolean) ==
                  SIMDJSON_BRIDGE_TYPE_BOOLEAN,
              "json_type::boolean");
static_assert(static_cast<int>(simdjson::ondemand::json_type::null) ==
                  SIMDJSON_BRIDGE_TYPE_NULL,
              "json_type::null");

// `number_type` is a scoped enumeration starting at 1
// (`src/include/simdjson/generic/base.h:43-48`).  `SIMDJSON_BRIDGE_NUMBER_NONE`
// is this fork's addition and has no upstream counterpart to check against.
static_assert(static_cast<int>(simdjson::ondemand::number_type::floating_point_number) ==
                  SIMDJSON_BRIDGE_NUMBER_FLOATING_POINT,
              "number_type::floating_point_number");
static_assert(static_cast<int>(simdjson::ondemand::number_type::signed_integer) ==
                  SIMDJSON_BRIDGE_NUMBER_SIGNED,
              "number_type::signed_integer");
static_assert(static_cast<int>(simdjson::ondemand::number_type::unsigned_integer) ==
                  SIMDJSON_BRIDGE_NUMBER_UNSIGNED,
              "number_type::unsigned_integer");
static_assert(static_cast<int>(simdjson::ondemand::number_type::big_integer) ==
                  SIMDJSON_BRIDGE_NUMBER_BIG,
              "number_type::big_integer");

// The absent-offset marker has to be outside every legal offset, or a real
// offset could be mistaken for "there are no such bytes".
static_assert(SIMDJSON_BRIDGE_NO_OFFSET == 0xFFFFFFFFu,
              "SIMDJSON_BRIDGE_NO_OFFSET is part of the header's contract");