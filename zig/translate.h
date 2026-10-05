/* The one header this package translates.
 *
 * `zig build` runs translate-c over this file, and what that translation
 * becomes is the `c` module the Zig facade in zig/root.zig imports. Its whole
 * job is to name the one public header of this build: this fork's own C ABI.
 *
 * Which header that is, and why it is not upstream's
 * -------------------------------------------------
 * Upstream's public interface is `src/include/simdjson.h`, which is C++ --
 * namespaces, class templates and `simdjson_result<T>`, none of which
 * translate-c can parse and none of which names a symbol a C or Zig caller
 * could spell. `#include <simdjson/ondemand.h>` binds
 * `simdjson::ondemand` to exactly one compile-time-selected kernel through
 * `src/include/simdjson/builtin/ondemand.h:39`, so there is no
 * runtime-dispatched name to bind to either.
 *
 * So the translated surface is `zig/bridge.h`: plain C99, `extern "C"` guards at
 * `:126-128` and `:679-681`, eleven entry points, and an include set of exactly
 * `<stddef.h>` and `<stdint.h>` (`:123-124`). It is included here whole, with
 * its own include guard, so this wrapper cannot disagree with the real header by
 * omission and cannot re-declare a prototype with a different type.
 *
 * The include is quoted, not angled
 * ---------------------------------
 * `#include "bridge.h"` resolves against the directory of this file, `zig/`,
 * which is where `bridge.h` is, so the translation needs no include path to find
 * it. That is deliberate and it is what makes the two routes agree: the same
 * bytes are reached here in this repository and, by any other name, by an
 * installed consumer of `include/simdjson_bridge.h`. The build still puts `zig/`
 * on the translation's include path (see `addTranslate` in
 * `build_support/graph.zig`) so a future aggregate header that reached it by
 * angle brackets would be covered on the same route the C++ units use.
 *
 * Why the upstream header tree is not named here
 * ----------------------------------------------
 * The installed `include/simdjson/` tree is a C++ interface and stays one.
 * `zig build` installs all 234 of its files unmodified and complete beside this
 * package's artifact, so a C++ consumer of the delivered `libsimdjson` has the
 * whole of upstream's API -- the DOM parser, `document_stream`, the minifier,
 * compile-time JSON -- without going through this binding at all. Putting any
 * of it on a translate-c line would be a C++ construct in a C translation, and
 * `zig/root.zig` says the same thing in prose.
 *
 * What is deliberately not here
 * -----------------------------
 * A copy of any declaration, and no macro of this build's own.
 *
 * The four C++ configuration macros -- `SIMDJSON_DEVELOPMENT_CHECKS=1`,
 * `SIMDJSON_THREADS_ENABLED=1`, `SIMDJSON_ENABLE_NAN_INF=0` and
 * `SIMDJSON_EXCEPTIONS=0` -- are on the compile line of the two C++ translation
 * units, not here, because they describe *this* build's configuration rather than
 * what the interface is. `zig/bridge.h` reads none of them: its one macro,
 * `SIMDJSON_BRIDGE_NO_OFFSET` (`:311`), is defined in the header itself, so the
 * translation gets that constant from the header rather than from a compile line
 * that could disagree with it. That is the same reason upstream keeps
 * `SIMDJSON_PADDING` in `src/include/simdjson/base.h:42` rather than in a build
 * file.
 *
 * A reader who wants to know which configuration the compiled core was built
 * under reads `build_support/graph.zig`, where each of the four names the
 * upstream line it comes from.
 */

#ifndef SIMDJSON_TRANSLATE_H
#define SIMDJSON_TRANSLATE_H

#include "bridge.h"

#endif /* SIMDJSON_TRANSLATE_H */