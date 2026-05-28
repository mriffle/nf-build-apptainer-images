#!/usr/bin/env bash
#
# Self-contained test harness for nf-build-apptainer-images.
#
# Runs the workflow's scenario matrix via `nextflow -stub-run` against pinned
# Nextflow versions. Each version is fetched on demand into tests/.nf using a
# LOCAL NXF_HOME, so the user's ~/.nextflow is never touched. The tests
# themselves need no network and no Apptainer (the process stub does the work);
# only fetching the Nextflow distributions the first time needs internet.
#
# All run artifacts (work dirs, logs, configs, caches) live under tests/.work,
# so the repository's main directory stays clean.
#
# Usage:
#   tests/run_tests.sh                          # all scenarios on all pinned versions
#   NF_VERSIONS="25.04.0 26.04.3" tests/run_tests.sh   # override the version list
#   tests/run_tests.sh -k naming                # only tests whose name contains "naming"
#
# Exit status: 0 if every scenario passes on every version, 1 otherwise.

set -uo pipefail

# --- locations -------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MAIN_NF="$REPO_DIR/main.nf"

NF_DIR="$SCRIPT_DIR/.nf"                 # launcher + version cache (git-ignored)
NF_LAUNCHER="$NF_DIR/nextflow"
export NXF_HOME="$NF_DIR/home"           # keep version JARs local, not in ~/.nextflow
WORK_ROOT="$SCRIPT_DIR/.work"            # per-test scratch (git-ignored)

# This project uses the new (strict) Nextflow language. It is the DEFAULT on
# Nextflow 26+, but on Nextflow 25 (25.10+) the strict parser must be requested
# explicitly. Setting it here makes the same code run identically on both lines.
export NXF_SYNTAX_PARSER=v2

# Pinned versions: the lowest supported (25.10 — the first 25 release with the
# strict parser) and the latest of the next major line (26). Override with
# NF_VERSIONS="..." to test others.
NF_VERSIONS="${NF_VERSIONS:-25.10.0 26.04.3}"

# optional substring filter on test name
FILTER=""
[ "${1:-}" = "-k" ] && FILTER="${2:-}"

mkdir -p "$NF_DIR" "$NXF_HOME"
rm -rf "$WORK_ROOT"; mkdir -p "$WORK_ROOT"

# --- get the Nextflow launcher once ----------------------------------------
if [ ! -x "$NF_LAUNCHER" ]; then
    echo "Downloading the Nextflow launcher into $NF_DIR ..."
    curl -fsSL https://get.nextflow.io -o "$NF_LAUNCHER" \
        || { echo "FATAL: could not download the nextflow launcher"; exit 2; }
    chmod +x "$NF_LAUNCHER"
fi

# --- state -----------------------------------------------------------------
PASS=0; FAIL=0; FAILED_NAMES=()
CURVER=""        # current Nextflow version under test
TDIR=""; CACHE=""; TMP=""
RC=0; OUT=""; ERRMSG=""

# Run the workflow (always with -stub-run) inside the current test dir.
# Usage: nf_run <args...>  ; sets RC and OUT.
nf_run() {
    OUT="$TDIR/run.log"
    ( cd "$TDIR" && NXF_VER="$CURVER" "$NF_LAUNCHER" -log "$TDIR/nextflow.log" \
        run "$MAIN_NF" -stub-run -ansi-log false -work-dir "$TDIR/work" "$@" ) >"$OUT" 2>&1
    RC=$?
}

# --- assertions (set ERRMSG and return 1 on failure) -----------------------
assert_ok()     { [ "$RC" -eq 0 ] || { ERRMSG="expected success, rc=$RC | $(tail -n2 "$OUT" | tr '\n' ' ')"; return 1; }; }
assert_fail()   { [ "$RC" -ne 0 ] || { ERRMSG="expected failure, rc=0"; return 1; }; }
assert_log()    { grep -qiE -- "$1" "$OUT" || { ERRMSG="log missing /$1/ | $(tail -n2 "$OUT" | tr '\n' ' ')"; return 1; }; }
assert_nolog()  { ! grep -qiE -- "$1" "$OUT" || { ERRMSG="log unexpectedly matched /$1/"; return 1; }; }
assert_file()   { [ -f "$1" ] || { ERRMSG="missing expected file: $1"; return 1; }; }
assert_nofile() { [ ! -f "$1" ] || { ERRMSG="unexpected file present: $1"; return 1; }; }
assert_ncache() { local n; n=$(find "$CACHE" -maxdepth 1 -name '*.img' 2>/dev/null | wc -l | tr -d ' ')
                  [ "$n" -eq "$1" ] || { ERRMSG="expected $1 .img in cache, found $n"; return 1; }; }
# Per-task console output goes to .command.out (not the main Nextflow log).
assert_taskout(){ grep -rqiE --include='.command.out' -- "$1" "$TDIR/work" 2>/dev/null \
                  || { ERRMSG="no task .command.out matched /$1/"; return 1; }; }

mkcfg() { printf '%s\n' "$2" > "$TDIR/$1"; }   # mkcfg <filename> <contents>

# =============================== scenarios =================================
# Each _t_<name> sets up inputs, calls nf_run, and asserts. Return 0 = pass.

# -- main.nf required-param guards (fail before any process) ----------------
_t_guard_missing_images_file() {
    nf_run --apptainer_cache_dir "$CACHE" --apptainer_tmp_dir "$TMP"
    assert_fail || return 1; assert_log 'docker_images_file is not set' || return 1
}
_t_guard_missing_cache_dir() {
    mkcfg i.config "params { images = [ ubuntu: 'ubuntu:22.04' ] }"
    nf_run --docker_images_file "$TDIR/i.config" --apptainer_tmp_dir "$TMP"
    assert_fail || return 1; assert_log 'apptainer_cache_dir is not set' || return 1
}
_t_guard_missing_tmp_dir() {
    mkcfg i.config "params { images = [ ubuntu: 'ubuntu:22.04' ] }"
    nf_run --docker_images_file "$TDIR/i.config" --apptainer_cache_dir "$CACHE"
    assert_fail || return 1; assert_log 'apptainer_tmp_dir is not set' || return 1
}

# -- base config loading ----------------------------------------------------
_t_base_local_file() {
    mkcfg i.config "params { images = [ ubuntu: 'ubuntu:22.04', diann: 'quay.io/protio/diann:1.8.1' ] }"
    nf_run --docker_images_file "$TDIR/i.config" --apptainer_cache_dir "$CACHE" --apptainer_tmp_dir "$TMP"
    assert_ok || return 1
    assert_file "$CACHE/ubuntu-22.04.img" || return 1
    assert_file "$CACHE/quay.io-protio-diann-1.8.1.img" || return 1
    assert_ncache 2 || return 1
}
_t_base_file_url() {
    mkcfg url.config "params { images = [ ubuntu: 'ubuntu:22.04' ] }"
    nf_run --docker_images_file "file://$TDIR/url.config" --apptainer_cache_dir "$CACHE" --apptainer_tmp_dir "$TMP"
    assert_ok || return 1; assert_file "$CACHE/ubuntu-22.04.img" || return 1
}
_t_base_nonexistent() {
    nf_run --docker_images_file "$TDIR/does-not-exist.config" --apptainer_cache_dir "$CACHE" --apptainer_tmp_dir "$TMP"
    assert_fail || return 1; assert_log 'Config file not found' || return 1
}
_t_base_no_images_key() {
    mkcfg i.config "params { foo = 'bar' }"
    nf_run --docker_images_file "$TDIR/i.config" --apptainer_cache_dir "$CACHE" --apptainer_tmp_dir "$TMP"
    assert_fail || return 1; assert_log 'No images to build' || return 1
}
_t_base_empty_images() {
    mkcfg i.config "params { images = [:] }"
    nf_run --docker_images_file "$TDIR/i.config" --apptainer_cache_dir "$CACHE" --apptainer_tmp_dir "$TMP"
    assert_fail || return 1; assert_log 'No images to build' || return 1
}
_t_base_images_not_map() {
    mkcfg i.config "params { images = 'not-a-map' }"
    nf_run --docker_images_file "$TDIR/i.config" --apptainer_cache_dir "$CACHE" --apptainer_tmp_dir "$TMP"
    assert_fail || return 1; assert_log 'Expected params.images Map' || return 1
}

# -- override merge ---------------------------------------------------------
_t_override_disjoint() {
    mkcfg base.config "params { images = [ ubuntu: 'ubuntu:22.04' ] }"
    mkcfg over.config "params { images = [ diann: 'quay.io/protio/diann:1.8.1' ] }"
    nf_run --docker_images_file "$TDIR/base.config" --docker_images_override_file "$TDIR/over.config" \
           --apptainer_cache_dir "$CACHE" --apptainer_tmp_dir "$TMP"
    assert_ok || return 1; assert_ncache 2 || return 1
    assert_file "$CACHE/ubuntu-22.04.img" || return 1
    assert_file "$CACHE/quay.io-protio-diann-1.8.1.img" || return 1
}
_t_override_overlap() {
    mkcfg base.config "params { images = [ tool: 'quay.io/x/tool:1.0' ] }"
    mkcfg over.config "params { images = [ tool: 'quay.io/x/tool:2.0' ] }"
    nf_run --docker_images_file "$TDIR/base.config" --docker_images_override_file "$TDIR/over.config" \
           --apptainer_cache_dir "$CACHE" --apptainer_tmp_dir "$TMP"
    assert_ok || return 1; assert_ncache 1 || return 1
    assert_file   "$CACHE/quay.io-x-tool-2.0.img" || return 1   # override wins
    assert_nofile "$CACHE/quay.io-x-tool-1.0.img" || return 1
}

# -- image-name transform (the critical invariant) --------------------------
_t_naming_transforms() {
    mkcfg i.config "params { images = [
        bare:    'ubuntu:22.04',
        reg:     'quay.io/protio/diann:1.8.1',
        prefixed:'docker://quay.io/protio/carafe:2.0.0-3',
        untagged:'alpine',
        ported:  'myreg.io:5000/team/img:1.2'
    ] }"
    nf_run --docker_images_file "$TDIR/i.config" --apptainer_cache_dir "$CACHE" --apptainer_tmp_dir "$TMP"
    assert_ok || return 1
    assert_file   "$CACHE/ubuntu-22.04.img" || return 1
    assert_file   "$CACHE/quay.io-protio-diann-1.8.1.img" || return 1
    assert_file   "$CACHE/quay.io-protio-carafe-2.0.0-3.img" || return 1          # docker:// stripped
    assert_nofile "$CACHE/docker---quay.io-protio-carafe-2.0.0-3.img" || return 1 # not doubled
    assert_file   "$CACHE/alpine.img" || return 1                                  # untagged
    assert_file   "$CACHE/myreg.io-5000-team-img-1.2.img" || return 1              # registry port colon -> '-'
    assert_ncache 5 || return 1
}

# -- fan-out ----------------------------------------------------------------
_t_fanout_many() {
    mkcfg i.config "params { images = [
        a: 'r/a:1', b: 'r/b:1', c: 'r/c:1', d: 'r/d:1', e: 'r/e:1', f: 'r/f:1'
    ] }"
    nf_run --docker_images_file "$TDIR/i.config" --apptainer_cache_dir "$CACHE" --apptainer_tmp_dir "$TMP"
    assert_ok || return 1; assert_ncache 6 || return 1
}

# -- directory option combinations ------------------------------------------
_t_dirs_shared_basename() {
    # cache and tmp share the basename 'scratch' (regression for the old `path`
    # input collision; must work now that they are `val`).
    local c="$TDIR/A/scratch" t="$TDIR/B/scratch"; mkdir -p "$c" "$t"
    mkcfg i.config "params { images = [ ubuntu: 'ubuntu:22.04', diann: 'quay.io/protio/diann:1.8.1' ] }"
    nf_run --docker_images_file "$TDIR/i.config" --apptainer_cache_dir "$c" --apptainer_tmp_dir "$t"
    assert_ok || return 1
    assert_file "$c/ubuntu-22.04.img" || return 1
    assert_file "$c/quay.io-protio-diann-1.8.1.img" || return 1
}
_t_dir_missing_cache() {
    mkcfg i.config "params { images = [ ubuntu: 'ubuntu:22.04' ] }"
    nf_run --docker_images_file "$TDIR/i.config" --apptainer_cache_dir "$TDIR/no_such_dir" --apptainer_tmp_dir "$TMP"
    assert_fail || return 1; assert_log 'Apptainer cache directory does not exist' || return 1
}

# -- cache-skip vs build ----------------------------------------------------
_t_cache_skip() {
    mkcfg i.config "params { images = [ ubuntu: 'ubuntu:22.04', diann: 'quay.io/protio/diann:1.8.1' ] }"
    touch "$CACHE/ubuntu-22.04.img"   # pre-seed one image
    nf_run --docker_images_file "$TDIR/i.config" --apptainer_cache_dir "$CACHE" --apptainer_tmp_dir "$TMP"
    assert_ok || return 1
    assert_taskout 'already exists in cache, skipping' || return 1
    assert_taskout 'building placeholder quay.io-protio-diann' || return 1
    assert_ncache 2 || return 1
}

TESTS=(
    guard_missing_images_file guard_missing_cache_dir guard_missing_tmp_dir
    base_local_file base_file_url base_nonexistent base_no_images_key
    base_empty_images base_images_not_map
    override_disjoint override_overlap
    naming_transforms fanout_many
    dirs_shared_basename dir_missing_cache cache_skip
)

# --- driver ----------------------------------------------------------------
run_test() {
    local name="$1"
    [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]] && return 0
    TDIR="$WORK_ROOT/$CURVER/$name"; CACHE="$TDIR/cache"; TMP="$TDIR/tmp"
    mkdir -p "$CACHE" "$TMP"
    ERRMSG=""
    if "_t_$name"; then
        PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$name"
    else
        FAIL=$((FAIL+1)); FAILED_NAMES+=("[$CURVER] $name"); printf '  \033[31mFAIL\033[0m %s\n       %s\n' "$name" "$ERRMSG"
    fi
}

echo "Repo:        $REPO_DIR"
echo "NXF_HOME:    $NXF_HOME"
echo "Work dir:    $WORK_ROOT"
echo "Versions:    $NF_VERSIONS"
echo

for v in $NF_VERSIONS; do
    CURVER="$v"
    printf 'Preparing Nextflow %s ...\n' "$v"
    if ! NXF_VER="$v" "$NF_LAUNCHER" -version >/dev/null 2>&1; then
        FAIL=$((FAIL+1)); FAILED_NAMES+=("[$v] could not download/launch Nextflow $v")
        printf '  \033[31mFAIL\033[0m could not prepare Nextflow %s\n' "$v"; echo; continue
    fi
    printf '==== Nextflow %s ====\n' "$v"
    for t in "${TESTS[@]}"; do run_test "$t"; done
    echo
done

echo "================ SUMMARY ================"
echo "PASS=$PASS  FAIL=$FAIL  (versions: $NF_VERSIONS)"
if [ "$FAIL" -gt 0 ]; then
    printf 'Failures:\n'; printf '  - %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
echo "ALL TESTS PASSED"
