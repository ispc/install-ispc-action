#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Differential test: runs the Node implementation (build/main.cjs) and
# install.sh on the same inputs and compares what users can observe
# (TRANSITION.md §4.B, B1-B8, and the D5 escaping check).
#
# Usage: bash test/parity.sh [full|host]
#   full  every case; explicit platform/arch cases don't depend on the host (default)
#   host  only cases whose result depends on the host OS/arch
#
# Environment:
#   OLD_IMPL  path to the Node bundle (default: build/main.cjs)
#   NODE      node binary (default: node)
#   KEEP      set to keep the scratch directory

# Inputs with shell metacharacters are literal on purpose.
# shellcheck disable=SC2016

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODE=${1:-full}
OLD_IMPL=${OLD_IMPL:-$ROOT/build/main.cjs}
NEW_IMPL=$ROOT/install.sh
NODE=${NODE:-node}
WORK=$(mktemp -d)
[[ -n ${KEEP:-} ]] || trap 'rm -rf "$WORK"' EXIT

# install.sh autodetects from runner.os/runner.arch; outside Actions it uses uname.
export ISPC_RUNNER_OS=${RUNNER_OS:-} ISPC_RUNNER_ARCH=${RUNNER_ARCH:-}

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) HOST=windows ;;
  Darwin) HOST=macOS ;;
  *) HOST=linux ;;
esac

passed=0
failed=0

# Runs implementation $1 (old|new) in $WORK/ws, then moves its results to $WORK/$1.
run_impl() {
  local impl=$1
  rm -rf "${WORK:?}/ws" "${WORK:?}/rt" "${WORK:?}/$impl"
  mkdir -p "$WORK/ws" "$WORK/rt" "$WORK/$impl"
  : >"$WORK/github_path"
  local rc
  (
    cd "$WORK/ws" || exit 99
    export RUNNER_TEMP="$WORK/rt" GITHUB_PATH="$WORK/github_path"
    export INPUT_VERSION=$CASE_VERSION INPUT_PLATFORM=$CASE_PLATFORM INPUT_ARCHITECTURE=$CASE_ARCH
    if [[ $impl == old ]]; then
      "$NODE" "$OLD_IMPL"
    else
      bash --noprofile --norc "$NEW_IMPL"
    fi
  ) >"$WORK/$impl/stdout" 2>"$WORK/$impl/stderr"
  rc=$?
  printf '%s\n' "$rc" >"$WORK/$impl/B1-exit-code"
  # ::debug:: lines only show with step debug logging and aren't part of the contract.
  grep -a '^::' "$WORK/$impl/stdout" | grep -av '^::debug::' >"$WORK/$impl/B2-workflow-commands"
  cp "$WORK/github_path" "$WORK/$impl/B3-github-path"
  grep -a '^Downloading ISPC archive ' "$WORK/$impl/stdout" >"$WORK/$impl/B4-url"
  grep -aE "^(Autodetected |Latest ISPC version is |Adding ISPC binary directory to PATH: )" \
    "$WORK/$impl/stdout" >"$WORK/$impl/B5-info"
  (
    cd "$WORK/ws" || exit 99
    [[ -d ispc-releases ]] || exit 0
    find ispc-releases \( -type f -o -type l \) | LC_ALL=C sort | while IFS= read -r f; do
      if [[ -L $f ]]; then
        printf '%s link\n' "$f"
      else
        x=-
        [[ $HOST != windows && -x $f ]] && x=x
        printf '%s %s %s\n' "$f" "$(wc -c <"$f" | tr -d ' ')" "$x"
      fi
    done
  ) >"$WORK/$impl/B6-tree"
  (cd "$WORK/ws" && find . -path ./ispc-releases -prune -o -print | LC_ALL=C sort) >"$WORK/$impl/B7-workspace"
  # B8: run the installed compiler when it can execute on this host.
  : >"$WORK/$impl/B8-ispc-version"
  if [[ $rc == 0 && ${CASE_PLATFORM:-$HOST} == "$HOST" ]]; then
    local bindir
    bindir=$(tr -d '\r' <"$WORK/github_path" | tail -n 1)
    [[ $HOST == windows ]] && bindir=$(cygpath -u "$bindir")
    "$bindir/ispc" --version >"$WORK/$impl/B8-ispc-version" 2>&1 || echo "exit $?" >>"$WORK/$impl/B8-ispc-version"
  fi
}

# check_case NAME VERSION PLATFORM ARCH [--expect-fail]
check_case() {
  local name=$1
  CASE_VERSION=$2 CASE_PLATFORM=$3 CASE_ARCH=$4
  local expect=${5:-}
  run_impl old
  run_impl new

  local diffs='' f
  for f in B1-exit-code B2-workflow-commands B3-github-path B4-url B5-info B6-tree B7-workspace B8-ispc-version; do
    cmp -s "$WORK/old/$f" "$WORK/new/$f" || diffs+=" $f"
  done
  local rc
  rc=$(cat "$WORK/new/B1-exit-code")
  if [[ $expect == --expect-fail && $rc == 0 ]]; then
    diffs+=" expected-failure"
  elif [[ $expect != --expect-fail && $rc != 0 ]]; then
    diffs+=" expected-success"
  fi
  # D5: a failure emits exactly one workflow command.
  if [[ $rc != 0 && $(wc -l <"$WORK/new/B2-workflow-commands") -ne 1 ]]; then
    diffs+=" one-workflow-command"
  fi

  if [[ -z $diffs ]]; then
    passed=$((passed + 1))
    printf 'ok   %s\n' "$name"
  else
    failed=$((failed + 1))
    printf 'FAIL %s:%s\n' "$name" "$diffs"
    for f in $diffs; do
      [[ -f $WORK/old/$f ]] || continue
      diff -u --label "old/$f" --label "new/$f" "$WORK/old/$f" "$WORK/new/$f" | head -n 40 | sed 's/^/     /'
    done
    printf '     --- old stdout\n'
    sed 's/^/     /' "$WORK/old/stdout" | head -n 20
    printf '     --- new stdout\n'
    sed 's/^/     /' "$WORK/new/stdout" | head -n 20
    printf '     --- new stderr\n'
    sed 's/^/     /' "$WORK/new/stderr" | head -n 20
  fi
}

# --- host-dependent cases (autodetection, cross-platform extraction) -------

check_case "autodetect, latest" '' '' ''
check_case "autodetect, 1.23.0" 1.23.0 '' ''
check_case "host platform, autodetect arch" 1.23.0 "$HOST" ''
case "$HOST" in
  macOS) check_case "linux archive on macOS" 1.23.0 linux '' ;;
  linux) check_case "windows archive on Linux" 1.23.0 windows '' ;;
esac

if [[ $MODE == full ]]; then
  # --- version -------------------------------------------------------------
  check_case "version latest" latest linux ''
  check_case "version '  latest  '" '  latest  ' linux ''
  check_case "version ' 1.23.0 '" ' 1.23.0 ' linux ''
  # Use validation failures to compare Unicode trimming without extra downloads.
  check_case "trim NBSP in version" $'\xc2\xa01.23.0\xc2\xa0' foo '' --expect-fail
  check_case "trim BOM in version" $'\xef\xbb\xbf1.23.0\xef\xbb\xbf' foo '' --expect-fail
  check_case "trim Unicode in platform" 1.23.0 $'\xc2\xa0foo\xef\xbb\xbf' '' --expect-fail
  check_case "trim Unicode in arch" 1.23.0 linux $'\xef\xbb\xbffoo\xc2\xa0' --expect-fail
  for v in v1.23.0 1.23 1.23.0rc1; do
    check_case "version '$v'" "$v" linux '' --expect-fail
  done
  check_case "version 9.9.9 (404)" 9.9.9 linux '' --expect-fail

  # --- platform ------------------------------------------------------------
  for p in macos freebsd; do
    check_case "platform '$p'" 1.23.0 "$p" '' --expect-fail
  done
  check_case "platform macOS, autodetect arch" 1.23.0 macOS ''
  check_case "platform windows, autodetect arch" 1.23.0 windows ''

  # --- architecture --------------------------------------------------------
  for combo in linux:oneapi linux:aarch64 linux:x86_64 macOS:x86_64 macOS:arm64 macOS:universal windows:x86_64; do
    check_case "$combo" 1.23.0 "${combo%%:*}" "${combo#*:}"
  done
  for combo in windows:aarch64 macOS:oneapi linux:arm64 linux:foo; do
    check_case "$combo" 1.23.0 "${combo%%:*}" "${combo#*:}" --expect-fail
  done

  # --- shell metacharacters (D3) and escaping (D5) -------------------------
  for v in '$(id)' '1.2.3;id' "1'2" '1"2' '`id`'; do
    check_case "version $v" "$v" linux '' --expect-fail
  done
  check_case "platform \$(touch pwned)" 1.23.0 '$(touch pwned)' '' --expect-fail
  check_case "arch ;touch pwned" 1.23.0 linux ';touch pwned' --expect-fail
  check_case "escaping %" '100%' linux '' --expect-fail
  check_case "escaping literal %0A" '1%0A2' linux '' --expect-fail
  check_case "escaping CR/LF" $'1\r2\n3' linux '' --expect-fail
  check_case "escaping injected command" $'1\n::warning::injected' linux '' --expect-fail
  check_case "escaping in platform" 1.23.0 $'a%b\r\n::warning::x' '' --expect-fail
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
