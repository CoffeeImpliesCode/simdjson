# Changelog

## Unreleased

- Forward `SIMDJSON_PROVIDER` through the nested consumer build for runtime loading with static or dynamic delivery.
- Fix runtime provider validation to use the translated document handle with static or dynamic delivery.
- Fix dynamic and runtime builds by filtering static-only check targets, retaining library checks in runtime mode, and correcting a reserved identifier in provider validation.
- Port to Zig 0.17.0.
- Consumer builds no longer use optional third-party executors; cross-target builds install to the SDK prefix.
- Validate UTF-8 before stage 1 so invalid input returns `UTF8_ERROR` on every kernel.
- Resolve thread and AVX-512 settings from the target, fixing WASI and baseline x86-64 cross-builds.
- Bounded walks finish on short output buffers and report the required record count.
- Return `DEPTH_ERROR` for input beyond `DEFAULT_MAX_DEPTH` instead of aborting.
- Reject trailing non-JSON content after a container root.
- Classify out-of-range integer tokens as `big_integer` instead of refusing them.
- Make the smoke example fail when its checked results mismatch.
- Add a Zig SDK for simdjson 5.0.2 with an On-Demand facade, C ABI bridge, library artifact, static or dynamic linkage, and optional runtime loading.
