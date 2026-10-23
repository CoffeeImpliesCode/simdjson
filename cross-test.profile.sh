# Settings-only profile for simdjson's 53-platform cross-test matrix.
# The harness runs targets when possible and records build-only coverage otherwise.

CROSS_BUILD_STEP=test
CROSS_BUILD_JOBS=2
CROSS_BUILD_TIMEOUT=3600
CROSS_TIMEOUT=1800