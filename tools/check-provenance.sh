#!/usr/bin/env bash
# Source-integrity check for the simdjson SDK.
#
# Four questions, all answerable without a compiler:
#
#   1. Do the 771 upstream files and the 22 fixtures still hash to the digests
#      UPSTREAM.sha256 records?
#   2. Is the file set exactly that set -- no missing, extra or renamed file
#      under src/ or testdata/?  A plain checksum run cannot see an addition.
#   3. Are the three generated amalgamation files still absent, and is
#      README.upstream.md still byte-identical to the imported src/README.md?
#   4. Do UPSTREAM.md and UPSTREAM.sha256 name the same release digest, and is
#      upstream's own Apache-2.0/MIT dual grant still where the records say it
#      is?
#
# This is a provenance gate, not a build gate. Nothing here compiles, links or
# runs a target binary; it is the check that an edit to the canonical native
# source cannot pass as a routine change. `AGENTS.md` §4 requires an intentional
# change to that source to carry an observed failure, a small causal patch, an
# explicit per-file deviation record, updated digests and a fresh gate -- and
# this script is what makes the "updated digests" half checkable.
#
# Usage: tools/check-provenance.sh   (run from anywhere in the repository)
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
    echo "check-provenance: $1" >&2
    exit 1
}

# Where the tree puts things, named once so the checks below cannot disagree
# about it. `src` is upstream's vendored release tree; `testdata` is this
# package's own fixtures. Both are covered by the same manifest, and the two
# groups are counted separately below because their provenance is different.
SRC_DIR=src
DATA_DIR=testdata
MANIFEST=UPSTREAM.sha256
DOC=UPSTREAM.md

# ---------------------------------------------------------------------------
# 1. Bytes.
# ---------------------------------------------------------------------------
# `--quiet` so a passing run prints only this script's own lines. `-c` reads the
# two-space separator GNU coreutils writes and needs nothing else: every
# non-comment line of the manifest is `<64 hex digits><two spaces><path>`.
sha256sum -c --quiet "$MANIFEST" || fail "a recorded file no longer matches $MANIFEST"

src_count=$(awk '/^[0-9a-f]{64}  / { print $2 }' "$MANIFEST" | grep -c "^$SRC_DIR/" || true)
data_count=$(awk '/^[0-9a-f]{64}  / { print $2 }' "$MANIFEST" | grep -c "^$DATA_DIR/" || true)
echo "all $((src_count + data_count)) recorded files match $MANIFEST ($src_count under $SRC_DIR/, $data_count under $DATA_DIR/)"

# ---------------------------------------------------------------------------
# 2. File set.
# ---------------------------------------------------------------------------
# A checksum run cannot see a file that is *not* in the manifest, and it cannot
# see a file that was renamed out from under a recorded path. Comparing the two
# sorted lists does see both, and it is the check that catches "someone added a
# source file" and "someone deleted a header" -- neither of which any digest
# would notice.
expected_tree=$(awk '/^[0-9a-f]{64}  / { print $2 }' "$MANIFEST" | LC_ALL=C sort)
# `$DATA_DIR/README.md` is the per-fixture *record* -- this script requires it to
# exist at `:201` and reads it at `:208-214` -- and it is deliberately not a
# fixture, so it has no digest in the manifest. Excluding it here is what makes
# the two statements the same statement; digesting it would put a fork-authored
# document into a manifest that records what was imported.
actual_tree=$(find "$SRC_DIR" "$DATA_DIR" -type f ! -path "$DATA_DIR/README.md" | LC_ALL=C sort)
if [ "$expected_tree" != "$actual_tree" ]; then
    echo "the vendored file set differs from the recorded one:" >&2
    diff -u <(echo "$expected_tree") <(echo "$actual_tree") >&2 || true
    echo >&2
    echo "An intentional change to the native source needs an observed failure, a" >&2
    echo "small causal patch, an explicit per-file deviation record in NOTICE.md," >&2
    echo "updated digests here, and a CHANGELOG.md entry in the same change." >&2
    echo "A file under $SRC_DIR/ that is upstream's must never be edited: the" >&2
    echo "re-synchronisation procedure in AGENTS.md §9 replaces it and re-records" >&2
    echo "the digest." >&2
    exit 1
fi
echo "the vendored file set is exactly the recorded $src_count + $data_count files"

# ---------------------------------------------------------------------------
# 3. The three deliberately-absent generated files.
# ---------------------------------------------------------------------------
# Upstream's single-header amalgamation is the output of
# src/singleheader/amalgamate.py, which IS carried. This build compiles
# upstream's own src/src/simdjson.cpp directly, so an amalgamated copy of the
# same sources beside it would be a second, buildable, drifting copy of the core
# with nothing keeping the two in step. Their absence is the package's point, so
# their reappearance is a failure rather than an addition.
for generated in \
    "$SRC_DIR/singleheader/simdjson.h" \
    "$SRC_DIR/singleheader/simdjson.cpp" \
    "$SRC_DIR/singleheader/singleheader.zip"
do
    [ -e "$generated" ] &&
        fail "$generated is present; it is a generated copy of sources this package compiles directly. See $DOC, \"The generated amalgamation is deliberately not shipped\"."
done
# And the generator that makes them must still be there, or "reproducible on
# demand" is an empty claim.
[ -f "$SRC_DIR/singleheader/amalgamate.py" ] ||
    fail "$SRC_DIR/singleheader/amalgamate.py is missing; the amalgamation would no longer be reproducible"
echo "the three generated amalgamation files are absent and their generator is present"

# ---------------------------------------------------------------------------
# 4a. The release digest must be recorded identically in both records.
# ---------------------------------------------------------------------------
# `-m1` rather than a pipe into `head -1`: with `pipefail` a `head` that closes
# the pipe early sends SIGPIPE to grep and turns a successful match into a
# failed pipeline.
digest_md=$(grep -m1 -oE '[0-9a-f]{64}' "$DOC" || true)
digest_list=$(grep -m1 -oE '[0-9a-f]{64}' "$MANIFEST" || true)
[ -n "$digest_md" ] || fail "$DOC records no sha256 digest"
[ -n "$digest_list" ] || fail "$MANIFEST records no sha256 digest"
[ "$digest_md" = "$digest_list" ] ||
    fail "$DOC and $MANIFEST name different release digests"
echo "the release digest is recorded consistently: $digest_md"

# 4b. The tag and its commit must agree between the two records too, because a
#     digest alone does not say *which* release the bytes are.
for fact in 'v5\.0\.2' 'c9030726ebbf5f9fe9f9facb4a401f6d3ccd77a2' '8331647'; do
    grep -q "$fact" "$DOC" || fail "$DOC does not record $fact"
    grep -q "$fact" "$MANIFEST" || fail "$MANIFEST does not record $fact"
done
echo "the tag, tag commit and tarball size are recorded consistently"

# ---------------------------------------------------------------------------
# 4c. The preserved upstream README.
# ---------------------------------------------------------------------------
# README.upstream.md is the byte-preserved copy at the package root;
# src/README.md is the imported original from the tarball. They must be the
# same bytes, or one of the two has been edited.
cmp -s README.upstream.md "$SRC_DIR/README.md" ||
    fail "README.upstream.md and $SRC_DIR/README.md are no longer byte-identical"
echo "README.upstream.md is byte-identical to the imported $SRC_DIR/README.md"

# ---------------------------------------------------------------------------
# 4d. Upstream's own dual grant, in the files that carry it and in the records.
# ---------------------------------------------------------------------------
# simdjson is dual Apache-2.0 / MIT, and $SRC_DIR/README.md:269 says so in
# upstream's own words: "This code is made available under the Apache License 2.0
# as well as under the MIT License. As a user, you can pick the license you
# prefer." Both texts ship unaltered. Reducing that to one label is the mistake
# AGENTS.md §8 warns about, so each of the three checks below is a check that the
# *dual* grant is still visible where a consumer looks.
for file in "$SRC_DIR/LICENSE" "$SRC_DIR/LICENSE-MIT"; do
    [ -f "$file" ] || fail "$file is missing; upstream's grant ships unaltered"
done
grep -q 'Apache License' "$SRC_DIR/LICENSE" ||
    fail "the Apache License text is missing from $SRC_DIR/LICENSE"
# Upstream's MIT text carries no title line -- it is the copyright notice and
# the permission grant itself -- so the check is for the grant's own wording and
# not for the string "MIT License", which that file does not contain.
grep -q 'Permission is hereby granted, free of charge, to any person obtaining a copy of' "$SRC_DIR/LICENSE-MIT" ||
    fail "the MIT permission grant is missing from $SRC_DIR/LICENSE-MIT"
grep -q 'Copyright 2018-2025 The simdjson authors' "$SRC_DIR/LICENSE" ||
    fail "the upstream copyright notice is missing from $SRC_DIR/LICENSE"
grep -q 'as well as under the MIT License' "$SRC_DIR/README.md" ||
    fail "$SRC_DIR/README.md no longer states the dual Apache-2.0 / MIT grant"
for file in NOTICE.md FORK-LICENSE.md UPSTREAM.md README.md; do
    [ -f "$file" ] || fail "$file is missing from this package"
done
grep -q 'Apache License, Version 2.0' NOTICE.md ||
    fail "NOTICE.md does not reproduce the Apache-2.0 grant"
grep -q 'END OF TERMS AND CONDITIONS' NOTICE.md ||
    fail "NOTICE.md does not carry the Apache-2.0 patent-grant termination text"
grep -q 'MIT License' NOTICE.md ||
    fail "NOTICE.md does not name the MIT alternative upstream offers"
echo "upstream's dual Apache-2.0 / MIT grant is present in $SRC_DIR/ and in the records"

# ---------------------------------------------------------------------------
# 4e. The patent-grant termination clause, in the Apache text itself.
# ---------------------------------------------------------------------------
# AGENTS.md §8 requires Apache-2.0 material to carry the patent-grant
# termination clause. The clause lives in $SRC_DIR/LICENSE §3; this checks it is
# still in the file that ships it, so the shipped text and the obligation cannot
# drift apart.
grep -q 'shall terminate' "$SRC_DIR/LICENSE" ||
    fail "the Apache-2.0 patent-grant termination clause is missing from $SRC_DIR/LICENSE"
echo "the Apache-2.0 patent-grant termination clause is present in $SRC_DIR/LICENSE"

# ---------------------------------------------------------------------------
# 4f. The fork's own records must exist, and the licence grant must be there.
# ---------------------------------------------------------------------------
# These are this package's files, not upstream's, but a build that shipped
# without them would ship a binary with no notice of the terms covering it --
# which is the one thing a redistributable cannot recover from. Their absence is
# a failure here rather than something for a reader to notice later.
for record in FORK-LICENSE.md NOTICE.md UPSTREAM.md FORK-NOTES.md CHANGELOG.md README.md README.zig.md; do
    [ -f "$record" ] || fail "$record is missing from this package"
done
grep -q 'SPDX-License-Identifier: Apache-2.0' FORK-LICENSE.md ||
    fail "FORK-LICENSE.md does not record the SPDX identifier it grants"
echo "the fork's own licence and provenance records are present"

# ---------------------------------------------------------------------------
# 4g. The fixture manifest and its record must agree on the count.
# ---------------------------------------------------------------------------
# testdata/README.md is the authoritative per-fixture record. A fixture added
# without a row there is a fixture nobody knows the provenance of, which is the
# one thing this directory exists to prevent.
[ -f "$DATA_DIR/README.md" ] ||
    fail "$DATA_DIR/README.md is missing; no fixture has a recorded origin"
# The tick is held in a variable rather than written into the pattern inline: a
# backtick inside a double-quoted shell string is a command substitution, and a
# reader of this line should not have to know that to know what it greps for.
tick='`'
for group in rfc8259 large malformed values; do
    files=$(find "$DATA_DIR/$group" -type f -name '*.json' | wc -l)
    mentions=$(grep -c -- "$tick$DATA_DIR/$group/" "$DATA_DIR/README.md" || true)
    [ "$mentions" -ge 1 ] ||
        fail "$DATA_DIR/README.md never mentions a $DATA_DIR/$group/ fixture"
    echo "  $DATA_DIR/$group: $files fixture(s), $mentions mention(s) in $DATA_DIR/README.md"
done
echo "$DATA_DIR/README.md names every fixture group"

echo "provenance checks passed"