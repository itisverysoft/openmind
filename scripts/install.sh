#!/bin/sh
# install.sh — build, test, and install the OpenMind Rust workspace.
#
#   ./scripts/install.sh                  build release, run tests, install bins to ~/.local/bin, open the app
#   ./scripts/install.sh --prefix DIR     install bins to DIR/bin instead
#   ./scripts/install.sh --no-test        skip `cargo test`
#   ./scripts/install.sh --no-open        install without opening the app
#   ./scripts/install.sh -- file.vsom     open the app with a file after install
#   ./scripts/install.sh --uninstall      remove installed bins, keep the build
#   PREFIX=DIR ./scripts/install.sh       same as --prefix DIR
#
# Today the workspace is libraries only (board + ink), so there is nothing to
# copy or open yet — the script still verifies the full pipeline (sibling
# checkout, toolchain, release build, tests) and installs + opens every binary
# crate the moment one exists (e.g. the future `app` crate with src/main.rs).
# Exit status is non-zero on any failure.
#
# POSIX sh: runs on macOS and Linux. No sudo needed for the default prefix;
# use `--prefix /usr/local` (with sudo) for a system-wide install.

set -eu

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR=""
RUN_TESTS=1
UNINSTALL=0
OPEN_APP=1
OPEN_ARGS=""

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            [ $# -ge 2 ] || { echo "error: --prefix needs a directory" >&2; exit 2; }
            PREFIX="$2"; shift 2 ;;
        --prefix=*)
            PREFIX="${1#--prefix=}"; shift ;;
        --bin-dir)
            [ $# -ge 2 ] || { echo "error: --bin-dir needs a directory" >&2; exit 2; }
            BIN_DIR="$2"; shift 2 ;;
        --bin-dir=*)
            BIN_DIR="${1#--bin-dir=}"; shift ;;
        --no-test) RUN_TESTS=0; shift ;;
        --no-open) OPEN_APP=0; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --) shift; OPEN_ARGS="$*"; break ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown flag $1 (see --help)" >&2; exit 2 ;;
    esac
done

[ -n "$BIN_DIR" ] || BIN_DIR="$PREFIX/bin"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE="$REPO_ROOT/rust"
VECTOR_DIR="$REPO_ROOT/../openmind-vector"

log() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- 1. Preconditions -------------------------------------------------------
command -v cargo >/dev/null 2>&1 || fail "cargo not found — install Rust 1.85+ via https://rustup.rs"

# Toolchain floor: parse `rustc 1.85.0 (...)`; warn (don't fail) if unparsable.
RUSTC_VER="$(rustc --version 2>/dev/null || true)"
VER_NUMS="$(printf '%s' "$RUSTC_VER" | sed -n 's/[^0-9]*\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p')"
if [ -n "$VER_NUMS" ]; then
    # shellcheck disable=SC2086
    set -- $VER_NUMS
    if [ "$1" -lt 1 ] || { [ "$1" -eq 1 ] && [ "$2" -lt 85 ]; }; then
        fail "rustc $RUSTC_VER too old — need 1.85+ (rustup update)"
    fi
else
    log "warn: could not parse rustc version ('$RUSTC_VER'); continuing"
fi

[ -f "$WORKSPACE/Cargo.toml" ] || fail "workspace not found at $WORKSPACE"
# `ink` reuses the vector stack by path, so the sibling checkout must exist.
[ -f "$VECTOR_DIR/Cargo.toml" ] || fail "sibling openmind-vector checkout missing:
  expected $VECTOR_DIR/Cargo.toml
  clone itisverysoft/openmind-vector next to this repo, then retry"

# --- 2. Discover binary crates ----------------------------------------------
# A crate ships a binary if it has src/main.rs (name = [package] name) or
# src/bin/*.rs (name = file stem). Pure libraries (today: board, ink) yield
# an empty list, which is fine.
discover_bins() {
    for manifest in "$WORKSPACE"/crates/*/Cargo.toml; do
        [ -f "$manifest" ] || continue
        crate_dir="$(dirname "$manifest")"
        if [ -f "$crate_dir/src/main.rs" ]; then
            pkg="$(sed -n '/^\[package\]/,/^\[/s/^name[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$manifest" | head -n 1)"
            [ -n "$pkg" ] || pkg="$(basename "$crate_dir")"
            printf '%s\n' "$pkg"
        fi
        for bin_src in "$crate_dir"/src/bin/*.rs; do
            [ -f "$bin_src" ] || continue
            printf '%s\n' "$(basename "$bin_src" .rs)"
        done
    done
}

# --- 3. Uninstall ------------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
    removed=0
    for bin in $(discover_bins); do
        if [ -f "$BIN_DIR/$bin" ]; then
            rm -f "$BIN_DIR/$bin"
            log "removed $BIN_DIR/$bin"
            removed=$((removed + 1))
        fi
    done
    [ "$removed" -gt 0 ] || log "nothing installed in $BIN_DIR"
    exit 0
fi

# --- 4. Build + test ----------------------------------------------------------
log "building release workspace in $WORKSPACE ..."
cargo build --release --manifest-path "$WORKSPACE/Cargo.toml"

if [ "$RUN_TESTS" -eq 1 ]; then
    log "running tests ..."
    cargo test --manifest-path "$WORKSPACE/Cargo.toml"
else
    log "skipping tests (--no-test)"
fi

# --- 5. Install ---------------------------------------------------------------
mkdir -p "$BIN_DIR"
installed=0
INSTALLED_BINS=""
for bin in $(discover_bins); do
    src="$WORKSPACE/target/release/$bin"
    if [ ! -x "$src" ]; then
        log "warn: expected binary missing: $src (skipping)"
        continue
    fi
    cp -f "$src" "$BIN_DIR/$bin"
    chmod 755 "$BIN_DIR/$bin"
    log "installed $BIN_DIR/$bin"
    installed=$((installed + 1))
    INSTALLED_BINS="$INSTALLED_BINS $bin"
done

if [ "$installed" -eq 0 ]; then
    log "ok: build + tests passed — workspace currently ships libraries only,"
    log "ok: nothing to copy or open. Binary crates (src/main.rs) will install"
    log "ok: and open here automatically."
    exit 0
fi

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) log "note: $BIN_DIR is not on PATH — add: export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac
log "done: $installed binary(ies) installed to $BIN_DIR"

# --- 6. Open ------------------------------------------------------------------
if [ "$OPEN_APP" -eq 0 ]; then
    log "leaving the app closed (--no-open)"
    exit 0
fi

# The main binary: prefer `openmind`, then `openmind-app`, else the first one.
MAIN_BIN=""
for b in $INSTALLED_BINS; do
    if [ "$b" = "openmind" ]; then MAIN_BIN="$b"; break; fi
done
if [ -z "$MAIN_BIN" ]; then
    for b in $INSTALLED_BINS; do
        if [ "$b" = "openmind-app" ]; then MAIN_BIN="$b"; break; fi
    done
fi
if [ -z "$MAIN_BIN" ]; then
    for b in $INSTALLED_BINS; do MAIN_BIN="$b"; break; done
fi

log "opening $BIN_DIR/$MAIN_BIN ..."
# Detached (survives this shell): args after `--` are passed to the app,
# e.g. `./scripts/install.sh -- board.vsom`.
# shellcheck disable=SC2086
nohup "$BIN_DIR/$MAIN_BIN" $OPEN_ARGS >/dev/null 2>&1 &
log "launched pid $!"
