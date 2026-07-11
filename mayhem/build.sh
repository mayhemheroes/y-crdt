#!/usr/bin/env bash
#
# y-crdt/mayhem/build.sh — build the yrs CRDT crate's cargo-fuzz targets as sanitized libFuzzer
# binaries, replicating OSS-Fuzz's Rust path (cargo-fuzz + ASan via RUSTFLAGS).
#
# Upstream y-crdt ships NO fuzz/ directory, so the harnesses live in an ADDITIVE crate under
# mayhem/fuzz/ (leaving the upstream tree untouched) — see mayhem/fuzz/Cargo.toml. cargo-fuzz
# drives the build:
#   - it ships its own libFuzzer runtime (the produced binary IS a libFuzzer target — Mayhem runs
#     it directly via `libfuzzer: true`);
#   - ASan is enabled the Rust way, through RUSTFLAGS `-Zsanitizer=address` (NOT clang's
#     $SANITIZER_FLAGS / CFLAGS — those don't apply to rustc). nightly is required for `-Zsanitizer`.
#
# Targets (mayhem/fuzz/fuzz_targets/*.rs):
#   merge_v1 — fuzzes yrs::merge_updates_v1 over a Vec of lib0 v1 update byte slices.
#   merge_v2 — fuzzes yrs::merge_updates_v2 over a Vec of lib0 v2 update byte slices.
# Each produced binary is copied to /mayhem/<target> to match its Mayhemfile.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE. This first build
# (in CI, online) populates the cargo registry under $CARGO_HOME=/opt/toolchains/rust/cargo; the
# re-run resolves crates from that cache (with a committed Cargo.lock so resolution is pinned).
# Do NOT hard-code `--offline` — it would break this first, online build.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (kept for parity even though
# the Rust build doesn't invoke clang directly; cargo's cc-built deps might).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

# DWARF < 4 debug-info contract (§6.2 item 10). Force DWARF version 2 so Mayhem triage / gdb can
# resolve project source lines. The rlenv runtime may export RUST_DEBUG_FLAGS before re-running
# build.sh offline; the `:-` default only applies when the variable is unset or empty.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=--dwarf-version=2}"

cd "$SRC"

FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"
FUZZ_TARGETS=(merge_v1 merge_v2)

# ── DWARF < 4 enforcement (§6.2 item 10) ────────────────────────────────────────────────────────
# Rust's ASan runtime (librustc-nightly_rt.asan.a) is compiled with the nightly's bundled LLVM,
# which defaults to DWARF 5, and is linked BEFORE the project code — so without intervention the
# first CU in .debug_info would be DWARF 5, failing the verify-repo check. Strip the ASan archive's
# debug sections once so it contributes no debug info; our project code (DWARF 2 via RUST_DEBUG_FLAGS)
# then appears first. The stripped .a is baked into the image, so the offline re-run reproduces it.
ASAN_RT="$(find "$RUSTUP_HOME/toolchains" -name "librustc-nightly_rt.asan.a" 2>/dev/null | head -1)"
if [ -n "$ASAN_RT" ] && [ -f "$ASAN_RT" ]; then
    echo "Stripping debug info from Rust ASan runtime to enforce DWARF < 4: $ASAN_RT"
    objcopy --strip-debug "$ASAN_RT" || true
fi

# libfuzzer-sys compiles libFuzzer from C++ via the cc crate; force DWARF 3 so those CUs also
# satisfy the check (the cc crate respects CFLAGS/CXXFLAGS). On the re-run these flags are the same,
# so cargo uses the cached libfuzzer.a without recompiling (fingerprint stable).
export CFLAGS="${CFLAGS:+$CFLAGS }-gdwarf-3"
export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-gdwarf-3"

# Replicate OSS-Fuzz `compile` RUSTFLAGS for a libFuzzer+ASan Rust build. cargo-fuzz sets the ASan
# flag itself by default, but we set it explicitly so the behavior is pinned and visible. `--cfg
# fuzzing` matches what libfuzzer-sys expects. RUST_DEBUG_FLAGS adds DWARF < 4 debug info.
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address ${RUST_DEBUG_FLAGS}"

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# `-O` (release w/ opt) + `--debug-assertions` mirrors OSS-Fuzz's build.sh. Build per-target so a
# single bad target doesn't mask the others. Use the image's DEFAULT toolchain (Dockerfile pins it);
# a `+toolchain` override would make rustup try to install another channel into the locked /opt.
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
done

# Resolve the cargo target dir robustly via `cargo metadata`.
TARGET_DIR="$(cargo metadata --no-deps --format-version 1 --manifest-path "$FUZZ_DIR/Cargo.toml" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["target_directory"])')"
echo "fuzz target_directory: $TARGET_DIR"

REL="$TARGET_DIR/$TRIPLE/release"
for t in "${FUZZ_TARGETS[@]}"; do
  bin="$REL/$t"
  if [ ! -x "$bin" ]; then
    echo "ERROR: expected fuzz binary not found at $bin" >&2
    ls -la "$REL" >&2 || true
    exit 1
  fi
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

echo "build.sh complete:"
ls -la /mayhem/merge_v1 /mayhem/merge_v2 2>&1 || true
