# cross-test settings profile for the simdjson SDK.
#
# `cross-test` looks for this file at the root of the project it is run from
# (or names it with --profile; --no-profile ignores it). It is trusted Bash that
# the harness `source`s, so this file is *settings only*: ordinary variable
# assignments and nothing else. No command runs, no compiler is probed, and no
# path in here names a host.
#
# There is deliberately no CROSS_MATRIX. The published 53-platform Zig 0.16
# Tier 1/2 table is the matrix this package is checked against, and a matrix
# named here would replace it. There is no TARGETS array either, for the same
# reason: a subset selected here would narrow the run rather than add to it.
# Both belong on the command line, where --targets selects from the active
# matrix and never adds to it.
#
# CROSS_BUILD_STEP stays the standard `test` step, which is what this profile
# states explicitly. There are no `cross_build_command` / `cross_artifact` hooks
# here, so the harness keeps its standard Zig-build mode and runs
# `zig build test -Dtarget=TARGET` per target with a fresh cache. What that means
# for a given target is the harness's decision, not this package's: a host target
# runs, a foreign target runs under whatever executor the harness detects (QEMU
# user mode, Wine, wasmtime), and a foreign target with no executor is reported as
# build-only coverage -- compiled, never executed, and never counted as a pass.
# `build.zig` gives the test binary a Run step for every target, which is what
# leaves that choice open.
#
# A target graph compiles upstream's own single translation unit
# (`src/src/simdjson.cpp`, which pulls in every per-architecture kernel the
# target's flags select), this package's `zig/bridge.cc` at the same flags, runs
# `translate-c` over `zig/translate.h`, and links the facade and the test root.
# Two jobs are held back rather than four: one `simdjson.cpp` compile is a large
# amount of template expansion and each matrix cell does one.
#
# Nothing here narrows the gate to what is expected to work. Which kernels a
# target's flags select is decided by the compile line -- and that is the one
# answer that legitimately differs between two cells, since
# `-Dtarget=aarch64-linux-gnu` gives NEON while `-Dtarget=x86_64-linux-gnu` at
# the same CPU model gives the scalar fallback. It is a build fact, not a test
# assertion, and no test in `tests.zig` compares a kernel name against a literal.
# A cell that fails is a fact to record and diagnose; it is not a reason to drop
# the cell, sample the tests or remap Debug to an optimized mode to make it pass.

CROSS_BUILD_STEP=test
CROSS_BUILD_JOBS=2
CROSS_BUILD_TIMEOUT=3600
CROSS_TIMEOUT=1800