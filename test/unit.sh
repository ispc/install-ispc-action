#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Unit tests for install.sh. They need no network: curl is replaced by a stub
# that replays a scripted sequence of responses and serves local fixtures.
#
# Usage: bash test/unit.sh
#
# Keep this compatible with bash 3.2 (macOS /bin/bash), like install.sh.

# The script is sourced from a variable path, test inputs are literal on
# purpose, and each case runs in a subshell that sets its own environment.
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031,SC2329

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/install.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0

pass() {
  passed=$((passed + 1))
  printf 'ok   %s\n' "$1"
}

flunk() {
  failed=$((failed + 1))
  printf 'FAIL %s\n' "$1"
  shift
  printf '     %s\n' "$@"
}

# check NAME EXPECTED ACTUAL
check() {
  if [[ $2 == "$3" ]]; then
    pass "$1"
  else
    flunk "$1" "expected: $(printf '%q' "$2")" "actual:   $(printf '%q' "$3")"
  fi
}

# Replays the next line of $STUB_SEQ: "<exit code> <http code> [fixture file]".
stub_curl() {
  local out='' hdr='' url=''
  while (($#)); do
    case "$1" in
      -o) out=$2; shift ;;
      -D) hdr=$2; shift ;;
      -w) shift ;;
      --retry | --connect-timeout | --speed-limit | --speed-time) shift ;;
      -*) ;;
      *) url=$1 ;;
    esac
    shift
  done
  printf '%s\n' "$url" >>"$STUB_LOG"
  # Pure bash, so it also works with the limited PATHs used below. An
  # exhausted sequence answers 404.
  local lines=() line rc code fixture
  while IFS= read -r line; do lines+=("$line"); done <"$STUB_SEQ"
  read -r rc code fixture <<<"${lines[0]:-0 404}"
  if ((${#lines[@]} > 1)); then printf '%s\n' "${lines[@]:1}" >"$STUB_SEQ"; else : >"$STUB_SEQ"; fi
  [[ -n $hdr ]] && printf 'HTTP/1.1 200 Connection established\r\n\r\nHTTP/1.1 %s Reason For %s\r\n\r\n' "$code" "$code" >"$hdr"
  if [[ -n $out ]]; then
    if [[ -n ${fixture:-} ]]; then
      cat "$fixture" >"$out"
    else
      printf 'partial' >"$out"
    fi
  fi
  printf '%s' "$code"
  return "$rc"
}

# Runs install.sh's main in a fresh workspace with the curl stub replaying
# PENDING_SEQ. Arguments are VAR=value assignments. Sets OUT, RC and CASE_DIR.
PENDING_SEQ=()
run_main() {
  CASE_DIR=$(mktemp -d "$WORK/case.XXXXXX")
  printf '%s\n' ${PENDING_SEQ[@]+"${PENDING_SEQ[@]}"} >"$CASE_DIR/seq"
  PENDING_SEQ=()
  mkdir -p "$CASE_DIR/ws" "$CASE_DIR/rt"
  : >"$CASE_DIR/github_path"
  : >"$CASE_DIR/curl.log"
  : >"$CASE_DIR/sleep.log"
  OUT=$(
    cd "$CASE_DIR/ws" || exit 99
    export RUNNER_TEMP="$CASE_DIR/rt" GITHUB_PATH="$CASE_DIR/github_path"
    export ISPC_RUNNER_OS=Linux ISPC_RUNNER_ARCH=X64
    export STUB_SEQ="$CASE_DIR/seq" STUB_LOG="$CASE_DIR/curl.log" SLEEP_LOG="$CASE_DIR/sleep.log"
    unset INPUT_VERSION INPUT_PLATFORM INPUT_ARCHITECTURE
    for a in "$@"; do export "${a?}"; done
    source "$SCRIPT"
    curl() { stub_curl "$@"; }
    backoff_sleep() { printf '%s\n' "$1" >>"$SLEEP_LOG"; }
    main
  )
  RC=$?
}

count_lines() {
  local n
  n=$(wc -l <"$1")
  printf '%s' "$((n))"
}

error_line() {
  printf '%s\n' "$OUT" | grep '^::' || true
}

# Fixtures: fake release archives with an executable bin/ispc.
make_fixture() {
  local name=$1 type=$2
  local src="$WORK/src/$name"
  mkdir -p "$src/bin"
  printf '#!/bin/sh\necho fake ispc\n' >"$src/bin/ispc"
  chmod +x "$src/bin/ispc"
  if [[ $type == tar.gz ]]; then
    tar -czf "$WORK/$name.tar.gz" -C "$WORK/src" "$name"
  else
    (cd "$WORK/src" && zip -q -r "$WORK/$name.zip" "$name")
  fi
}
make_fixture ispc-v1.23.0-linux tar.gz
TGZ="$WORK/ispc-v1.23.0-linux.tar.gz"
if command -v zip >/dev/null 2>&1; then
  make_fixture ispc-v1.23.0-windows zip
  ZIP="$WORK/ispc-v1.23.0-windows.zip"
fi

URL_123=https://github.com/ispc/ispc/releases/download/v1.23.0/ispc-v1.23.0-linux.tar.gz

# --- error escaping (D5) ---------------------------------------------------

msg_out=$(source "$SCRIPT"; fail $'100% done\r\nnext %0A line\n::warning::injected')
check "fail escapes %, CR and LF" '::error::100%25 done%0D%0Anext %250A line%0A::warning::injected' "$msg_out"
check "fail emits exactly one line" 1 "$(printf '%s\n' "$msg_out" | wc -l | tr -d ' ')"
msg_out=$(source "$SCRIPT"; fail '%s %d \x41')
check "fail doesn't interpret format strings" '::error::%25s %25d \x41' "$msg_out"
(source "$SCRIPT"; fail x >/dev/null)
check "fail exits 1" 1 $?

# --- input trimming --------------------------------------------------------

trim_out=$(source "$SCRIPT"; get_input $' \t 1.23.0 \n'; printf '[%s]' "$REPLY")
check "get_input trims whitespace" '[1.23.0]' "$trim_out"

unicode_space=$'\xc2\xa0\xef\xbb\xbf\xe1\x9a\x80\xe2\x80\x83\xe2\x80\xa8\xe2\x80\xa9\xe2\x80\xaf\xe2\x81\x9f\xe3\x80\x80'
for trim_locale in C "${LC_ALL:-${LANG:-C}}"; do
  trim_out=$(export LC_ALL=$trim_locale; source "$SCRIPT"; get_input "$unicode_space 1.23.0 $unicode_space"; printf '[%s]' "$REPLY")
  check "get_input trims Unicode whitespace in $trim_locale" '[1.23.0]' "$trim_out"
  trim_out=$(export LC_ALL=$trim_locale; source "$SCRIPT"; get_input "$unicode_space"; printf '[%s]' "$REPLY")
  check "get_input trims Unicode-only input in $trim_locale" '[]' "$trim_out"
done
for non_space in $'\xc2\x85' $'\xe1\xa0\x8e' $'\xe2\x80\x8b'; do
  trim_out=$(source "$SCRIPT"; get_input "$non_space 1.23.0 $non_space"; printf '%s' "$REPLY")
  check "get_input preserves non-JavaScript whitespace $(printf '%q' "$non_space")" "$non_space 1.23.0 $non_space" "$trim_out"
done
trim_out=$(source "$SCRIPT"; get_input " ${unicode_space}1${unicode_space}2 "; printf '%s' "$REPLY")
check "get_input preserves internal Unicode whitespace" "1${unicode_space}2" "$trim_out"

PENDING_SEQ=("0 200 $TGZ")
run_main "INPUT_VERSION=${unicode_space}1.23.0${unicode_space}" \
  "INPUT_PLATFORM=${unicode_space}linux${unicode_space}" "INPUT_ARCHITECTURE=${unicode_space}x86_64${unicode_space}"
check "all inputs accept surrounding Unicode whitespace" "0|$URL_123" "$RC|$(head -n 1 "$CASE_DIR/curl.log")"

# --- validation (no network) -----------------------------------------------

for v in v1.23.0 1.23 1.23.0rc1 '$(id)' '1.2.3;id' "1.2.3'" '1.2.3"' $'1.2.3\nid'; do
  run_main "INPUT_VERSION=$v"
  esc=${v//$'\n'/%0A}
  check "version '$v' rejected" "1|::error::Invalid version $esc|0" "$RC|$(error_line)|$(count_lines "$CASE_DIR/curl.log")"
done

for p in macos freebsd Linux '$(id)'; do
  run_main INPUT_VERSION=1.23.0 "INPUT_PLATFORM=$p"
  check "platform '$p' rejected" "1|::error::Platform $p not in list of supported platforms: linux,macOS,windows" "$RC|$(error_line)"
done

for combo in windows:aarch64 macOS:oneapi linux:arm64 linux:foo macOS:'$(id)'; do
  p=${combo%%:*} a=${combo#*:}
  run_main INPUT_VERSION=1.23.0 "INPUT_PLATFORM=$p" "INPUT_ARCHITECTURE=$a"
  check "arch '$a' on $p rejected" "1|::error::Platform $p does not support arch $a" "$RC|$(error_line)"
done

run_main INPUT_VERSION=1.23.0 ISPC_RUNNER_OS=FreeBSD
check "unknown runner OS" "1|::error::Platform FreeBSD is unsupported for autodetection" "$RC|$(error_line)"
run_main INPUT_VERSION=1.23.0 ISPC_RUNNER_ARCH=ARM
check "unsupported linux runner arch" "1|::error::Architecture arm is unsupported for autodetection" "$RC|$(error_line)"
run_main INPUT_VERSION=1.23.0 ISPC_RUNNER_ARCH=X86
check "ia32 linux runner arch" "1|::error::Architecture ia32 is unsupported for autodetection" "$RC|$(error_line)"

# --- URL construction ------------------------------------------------------

base=https://github.com/ispc/ispc/releases/download/v1.23.0
url_case() {
  local expected=$1 log=$2
  shift 2
  PENDING_SEQ=('0 404')
  run_main INPUT_VERSION=1.23.0 "$@"
  check "url for $*" "$expected|$log" "$(head -n 1 "$CASE_DIR/curl.log")|$(printf '%s\n' "$OUT" | grep -E '^Autodetected' | tr '\n' '|')"
}
url_case "$base/ispc-v1.23.0-linux.tar.gz" "Autodetected platform: 'linux'|Autodetected architecture ''|"
url_case "$base/ispc-v1.23.0-linux.aarch64.tar.gz" "Autodetected platform: 'linux'|Autodetected architecture 'aarch64'|" ISPC_RUNNER_ARCH=ARM64
url_case "$base/ispc-v1.23.0-macOS.universal.tar.gz" "Autodetected platform: 'macOS'|Autodetected architecture 'universal'|" ISPC_RUNNER_OS=macOS ISPC_RUNNER_ARCH=ARM64
url_case "$base/ispc-v1.23.0-macOS.universal.tar.gz" "Autodetected architecture 'universal'|" INPUT_PLATFORM=macOS
url_case "$base/ispc-v1.23.0-windows.zip" "Autodetected platform: 'windows'|Autodetected architecture ''|" ISPC_RUNNER_OS=Windows
url_case "$base/ispc-v1.23.0-linux-oneapi.tar.gz" "" INPUT_PLATFORM=linux INPUT_ARCHITECTURE=oneapi
url_case "$base/ispc-v1.23.0-linux.tar.gz" "Autodetected platform: 'linux'|" INPUT_ARCHITECTURE=x86_64
url_case "$base/ispc-v1.23.0-windows.zip" "" INPUT_PLATFORM=windows INPUT_ARCHITECTURE=x86_64
url_case "$base/ispc-v1.23.0-macOS.x86_64.tar.gz" "" INPUT_PLATFORM=macOS INPUT_ARCHITECTURE=x86_64
url_case "$base/ispc-v1.23.0-macOS.arm64.tar.gz" "" "INPUT_PLATFORM= macOS " "INPUT_ARCHITECTURE= arm64 "

# --- download retries (D2) -------------------------------------------------

retry_case() {
  local name=$1 rc=$2 attempts=$3 err=$4
  shift 4
  PENDING_SEQ=("$@")
  run_main INPUT_VERSION=1.23.0
  check "$name" "$rc|$attempts|$err" "$RC|$(count_lines "$CASE_DIR/curl.log")|$(error_line)"
}
retry_case "503/503/200 succeeds" 0 3 "" '0 503' '0 503' "0 200 $TGZ"
retry_case "501/501/200 succeeds" 0 3 "" '0 501' '0 501' "0 200 $TGZ"
retry_case "408/408/200 succeeds" 0 3 "" '0 408' '0 408' "0 200 $TGZ"
retry_case "429/429/200 succeeds" 0 3 "" '0 429' '0 429' "0 200 $TGZ"
retry_case "persistent 503 stops after 3" 1 3 "::error::Unexpected HTTP response: 503" '0 503' '0 503' '0 503' "0 200 $TGZ"
retry_case "404 isn't retried" 1 1 "::error::Unexpected HTTP response: 404" '0 404' "0 200 $TGZ"
retry_case "204 isn't retried" 1 1 "::error::Unexpected HTTP response: 204" '0 204' "0 200 $TGZ"
retry_case "DNS failure is retried" 0 2 "" '6 000' "0 200 $TGZ"
retry_case "connection refusal is retried" 0 2 "" '7 000' "0 200 $TGZ"
retry_case "stalled transfer timeout is retried" 0 2 "" '28 200' "0 200 $TGZ"
retry_case "interrupted transfer is retried" 0 3 "" '18 200' '56 200' "0 200 $TGZ"
retry_case "persistent transport failure stops after 3" 1 3 "::error::Download failed: curl exited with code 7" '7 000' '7 000' '7 000'
retry_case "persistent timeout stops after 3" 1 3 "::error::Download failed: curl exited with code 28" '28 000' '28 000' '28 000'

PENDING_SEQ=('18 200' '0 503' "0 200 $TGZ")
run_main INPUT_VERSION=1.23.0
archive=$(find "$CASE_DIR/rt" -type f)
check "partial download is replaced by the complete archive" "0|1" "$RC|$(cmp -s "$archive" "$TGZ" && echo 1)"
bad_sleep=$(awk '$1 < 10 || $1 > 20 || $1 != int($1)' "$CASE_DIR/sleep.log")
check "backoff waits twice, 10-20 s each" "2|" "$(count_lines "$CASE_DIR/sleep.log")|$bad_sleep"
check "retry logs the reason and the wait" 2 "$(printf '%s\n' "$OUT" | grep -c '^Waiting [0-9]* seconds before trying again$')"

# Over many draws every backoff stays within 10-20 s.
draws=$(source "$SCRIPT"; for _ in $(seq 200); do printf '%s\n' $((RANDOM % 11 + 10)); done | sort -n | uniq | tr '\n' ' ')
check "backoff range covers exactly 10..20" "10 11 12 13 14 15 16 17 18 19 20 " "$draws"

# --- successful install ----------------------------------------------------

PENDING_SEQ=("0 200 $TGZ")
run_main INPUT_VERSION=1.23.0
bindir="$CASE_DIR/ws/ispc-releases/ispc-v1.23.0-linux/bin"
check "install succeeds" 0 "$RC"
check "GITHUB_PATH gets the bin dir with LF" "$bindir"$'\nx' "$(cat "$CASE_DIR/github_path"; printf x)"
check "ispc is extracted and executable" "fake ispc" "$("$bindir/ispc")"
check "log lines" "Autodetected platform: 'linux'|Autodetected architecture ''|Downloading ISPC archive $URL_123|Adding ISPC binary directory to PATH: $bindir|" "$(printf '%s\n' "$OUT" | tr '\n' '|')"
check "workspace has only ispc-releases" "ispc-releases" "$(ls -A "$CASE_DIR/ws")"

# Second install over the first overwrites files (C4).
OUT=$(
  cd "$CASE_DIR/ws" || exit 99
  printf '%s\n' "0 200 $TGZ" >"$CASE_DIR/seq"
  export RUNNER_TEMP="$CASE_DIR/rt" GITHUB_PATH="$CASE_DIR/github_path" INPUT_VERSION=1.23.0
  export ISPC_RUNNER_OS=Linux ISPC_RUNNER_ARCH=X64 STUB_SEQ="$CASE_DIR/seq" STUB_LOG="$CASE_DIR/curl.log"
  source "$SCRIPT"
  curl() { stub_curl "$@"; }
  main
)
check "second install into the same workspace succeeds" "0|2" "$?|$(count_lines "$CASE_DIR/github_path")"

if [[ -n ${ZIP:-} ]] && command -v unzip >/dev/null 2>&1; then
  PENDING_SEQ=("0 200 $ZIP")
  run_main INPUT_VERSION=1.23.0 INPUT_PLATFORM=windows
  check "windows zip extracts with unzip on a non-Windows host" "0|fake ispc" \
    "$RC|$("$CASE_DIR/ws/ispc-releases/ispc-v1.23.0-windows/bin/ispc")"
fi

PENDING_SEQ=("0 200 $TGZ")
run_main INPUT_VERSION=1.23.0 RUNNER_TEMP=
check "missing RUNNER_TEMP" "1|::error::Expected RUNNER_TEMP to be defined" "$RC|$(error_line)"

PENDING_SEQ=("0 200 $TGZ")
run_main INPUT_VERSION=1.23.0 GITHUB_PATH=
check "no GITHUB_PATH falls back to add-path command" "0|::add-path::$CASE_DIR/ws/ispc-releases/ispc-v1.23.0-linux/bin" "$RC|$(error_line)"

# --- latest version via the API --------------------------------------------

printf '{"tag_name": "v1.31.0"}' >"$WORK/latest.json"
PENDING_SEQ=("0 200 $WORK/latest.json" "0 200 $TGZ")
run_main INPUT_VERSION=' latest '
check "latest via API" "Latest ISPC version is '1.31.0'|https://github.com/ispc/ispc/releases/download/v1.31.0/ispc-v1.31.0-linux.tar.gz" \
  "$(printf '%s\n' "$OUT" | grep '^Latest')|$(sed -n 2p "$CASE_DIR/curl.log")"

PENDING_SEQ=("0 200 $WORK/latest.json" "0 404")
run_main INPUT_VERSION=
check "empty version means latest" "Latest ISPC version is '1.31.0'" "$(printf '%s\n' "$OUT" | grep '^Latest')"

PENDING_SEQ=('7 000')
run_main INPUT_VERSION=latest
check "API transport failure" "1|::error::fetch failed" "$RC|$(error_line)"

# --- git fallback (D1) -----------------------------------------------------

make_repo() {
  local repo="$WORK/upstream"
  rm -rf "$repo"
  git init -q "$repo"
  local n=0
  commit_at() {
    n=$((n + 1))
    GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git -C "$repo" -c user.name=t -c user.email=t@t \
      commit -q --allow-empty -m "c$n"
  }
  commit_at '2024-01-01T00:00:00+0000'
  git -C "$repo" tag v1.22.0
  commit_at '2024-02-01T00:00:00+0000'
  git -C "$repo" tag -a -m rel v1.23.0
  # Same instant as v1.23.0, different time zone: ties keep alphabetical tag order.
  commit_at '2024-02-01T05:00:00+0500'
  git -C "$repo" tag v1.23.1
  commit_at '2024-03-01T00:00:00+0000'
  git -C "$repo" tag trunk-artifacts
  commit_at '2023-12-01T00:00:00+0000'
  git -C "$repo" tag v1.24.0-older-date
  printf 'file://%s' "$repo"
}
if command -v git >/dev/null 2>&1; then
  repo_url=$(make_repo)
  PENDING_SEQ=("0 403 $WORK/latest.json")
  run_main INPUT_VERSION=latest "ISPC_GIT_URL=$repo_url"
  check "git fallback picks newest tag, skips trunk-artifacts, keeps tie order" \
    "Unable to query latest version: Reason For 403 - {\"tag_name\": \"v1.31.0\"}|Fetching latest tags from the repository...|Latest ISPC version is '1.23.0'" \
    "$(printf '%s\n' "$OUT" | grep -E '^(Unable|Fetching|Latest)' | tr '\n' '|' | sed 's/|$//')"
  check "git fallback leaves no clone behind" "" "$(ls -A "$CASE_DIR/ws"; find "$CASE_DIR/rt" -name ispc-repo)"

  PENDING_SEQ=("0 403 $WORK/latest.json")
  run_main INPUT_VERSION=latest "ISPC_GIT_URL=file://$WORK/does-not-exist"
  check "git fallback clone failure" \
    "1|::error::Unable to get latest version from git repository: Command failed: git clone --depth=1 file://$WORK/does-not-exist ispc-repo" \
    "$RC|$(error_line)"
fi

# --- lazy tool checks (C10) ------------------------------------------------

# A PATH with only the listed tools.
limited_path() {
  local dir="$WORK/bin-$1"
  shift
  mkdir -p "$dir"
  local t
  for t in "$@"; do
    ln -sf "$(command -v "$t")" "$dir/$t"
  done
  printf '%s' "$dir"
}
BASE_TOOLS=(bash cat mkdir mktemp rm tr cut grep tail head sort uname gzip)
nojq=$(limited_path nojq "${BASE_TOOLS[@]}" tar)
PENDING_SEQ=("0 200 $TGZ")
run_main INPUT_VERSION=1.23.0 "PATH=$nojq"
check "pinned version needs neither jq nor git" "0|" "$RC|$(error_line)"

PENDING_SEQ=("0 200 $WORK/latest.json")
run_main INPUT_VERSION=latest "PATH=$nojq"
check "latest without jq fails clearly" "1|::error::install-ispc-action requires 'jq' on PATH" "$RC|$(error_line)"

notar=$(limited_path notar "${BASE_TOOLS[@]}")
PENDING_SEQ=("0 200 $TGZ")
run_main INPUT_VERSION=1.23.0 "PATH=$notar"
check "missing tar fails clearly" "1|::error::install-ispc-action requires 'tar' on PATH" "$RC|$(error_line)"

PENDING_SEQ=("0 200 $TGZ")
run_main INPUT_VERSION=1.23.0 INPUT_PLATFORM=windows "PATH=$notar"
check "zip without unzip on a non-Windows host fails clearly" "1|::error::install-ispc-action requires 'unzip' on PATH" "$RC|$(error_line)"

nocurl=$(limited_path nocurl "${BASE_TOOLS[@]}" tar)
(
  cd "$WORK" || exit 99
  export PATH=$nocurl RUNNER_TEMP="$WORK/rt-nocurl" INPUT_VERSION=1.23.0 ISPC_RUNNER_OS=Linux ISPC_RUNNER_ARCH=X64
  bash "$SCRIPT"
) >"$WORK/nocurl.out"
check "missing curl fails clearly" "1|::error::install-ispc-action requires 'curl' on PATH" "$?|$(grep '^::' "$WORK/nocurl.out")"

# --- summary ---------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
