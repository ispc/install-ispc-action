#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Installs an ISPC release and adds its bin directory to $GITHUB_PATH.
#
# Inputs (all optional, whitespace-trimmed, empty means unset):
#   INPUT_VERSION, INPUT_PLATFORM, INPUT_ARCHITECTURE
# Host detection (set by action.yml from runner.os/runner.arch, falls back to uname):
#   ISPC_RUNNER_OS (Linux|macOS|Windows), ISPC_RUNNER_ARCH (X86|X64|ARM|ARM64)
#
# Keep this compatible with bash 3.2 (macOS /bin/bash on self-hosted runners).
#
# Local run:
#   RUNNER_TEMP=/tmp/rt GITHUB_PATH=/tmp/p INPUT_VERSION=1.23.0 bash install.sh

set -euo pipefail

ISPC_API_URL=${ISPC_API_URL:-https://api.github.com/repos/ispc/ispc/releases/latest}
ISPC_GIT_URL=${ISPC_GIT_URL:-https://github.com/ispc/ispc.git}
ISPC_DOWNLOAD_URL=${ISPC_DOWNLOAD_URL:-https://github.com/ispc/ispc/releases/download}

# Prints a GitHub error annotation and exits. Escaping matches @actions/core.
fail() {
  local msg=$1
  msg=${msg//'%'/'%25'}
  msg=${msg//$'\r'/'%0D'}
  msg=${msg//$'\n'/'%0A'}
  printf '::error::%s\n' "$msg"
  exit 1
}

info() {
  printf '%s\n' "$1"
}

require() {
  command -v "$1" >/dev/null 2>&1 || fail "install-ispc-action requires '$1' on PATH"
}

# Sets REPLY to the input value with JavaScript String.trim() whitespace removed.
get_input() {
  local v=$1 before space
  # UTF-8 byte escapes also work in bash 3.2 and with LC_ALL=C. A character
  # class would match individual bytes in that locale, rather than whole
  # Unicode characters. Do not include NEL, U+180E or zero-width space.
  local whitespace=(
    $'\t' $'\n' $'\v' $'\f' $'\r' ' ' $'\xc2\xa0' $'\xe1\x9a\x80'
    $'\xe2\x80\x80' $'\xe2\x80\x81' $'\xe2\x80\x82' $'\xe2\x80\x83'
    $'\xe2\x80\x84' $'\xe2\x80\x85' $'\xe2\x80\x86' $'\xe2\x80\x87'
    $'\xe2\x80\x88' $'\xe2\x80\x89' $'\xe2\x80\x8a' $'\xe2\x80\xa8'
    $'\xe2\x80\xa9' $'\xe2\x80\xaf' $'\xe2\x81\x9f' $'\xe3\x80\x80'
    $'\xef\xbb\xbf'
  )
  while :; do
    before=$v
    for space in "${whitespace[@]}"; do
      v=${v#"$space"}
      v=${v%"$space"}
    done
    [[ $v != "$before" ]] || break
  done
  REPLY=$v
}

# Sets REPLY to the host OS using Node's os.platform() names.
host_platform() {
  case "${ISPC_RUNNER_OS:-}" in
    Linux) REPLY=linux ;;
    macOS) REPLY=darwin ;;
    Windows) REPLY=win32 ;;
    '')
      local s
      s=$(uname -s) || fail "Unable to run uname"
      case "$s" in
        Linux) REPLY=linux ;;
        Darwin) REPLY=darwin ;;
        MINGW* | MSYS* | CYGWIN*) REPLY=win32 ;;
        *) REPLY=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]') ;;
      esac
      ;;
    *) REPLY=$ISPC_RUNNER_OS ;;
  esac
}

# Sets REPLY to the host CPU using Node's os.arch() names.
host_arch() {
  case "${ISPC_RUNNER_ARCH:-}" in
    X64) REPLY=x64 ;;
    ARM64) REPLY=arm64 ;;
    X86) REPLY=ia32 ;;
    ARM) REPLY=arm ;;
    '')
      local m
      m=$(uname -m) || fail "Unable to run uname"
      case "$m" in
        x86_64 | amd64) REPLY=x64 ;;
        aarch64 | arm64) REPLY=arm64 ;;
        i?86) REPLY=ia32 ;;
        arm*) REPLY=arm ;;
        *) REPLY=$m ;;
      esac
      ;;
    *) REPLY=$ISPC_RUNNER_ARCH ;;
  esac
}

is_windows_host() {
  host_platform
  [[ $REPLY == win32 ]]
}

# Converts a native path to one this bash can use (only differs on Windows).
to_unix_path() {
  if is_windows_host && command -v cygpath >/dev/null 2>&1; then
    REPLY=$(cygpath -u "$1") || fail "Unable to convert path $1"
  else
    REPLY=$1
  fi
}

# Sets REPLY to a usable path of the runner's temp directory.
temp_dir() {
  to_unix_path "${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
  mkdir -p "$REPLY" || fail "Unable to create directory $REPLY"
}

# Sets REPLY to a file's content without dropping trailing newlines.
read_file() {
  local content
  content=$(cat "$1" && printf x) || fail "Unable to read $1"
  REPLY=${content%x}
}

# Sets REPLY to the newest tag of the ISPC git repository by commit author date.
latest_version_from_git() {
  local prefix='Unable to get latest version from git repository'
  require git
  local repo
  temp_dir
  repo="$REPLY/ispc-repo"
  rm -rf "$repo"
  git clone -q --depth=1 "$ISPC_GIT_URL" "$repo" \
    || fail "$prefix: Command failed: git clone --depth=1 $ISPC_GIT_URL ispc-repo"

  info 'Fetching latest tags from the repository...'
  git -C "$repo" fetch -q --tags || fail "$prefix: Command failed: git fetch --tags"

  local tags
  tags=$(git -C "$repo" tag) || fail "$prefix: Command failed: git tag"
  local tag dated=''
  while IFS= read -r tag; do
    [[ -z $tag || $tag == trunk-artifacts ]] && continue
    local ts
    ts=$(git -C "$repo" log -1 --format=%at "$tag") || fail "$prefix: Command failed: git log -1 --format=%ai $tag"
    dated+="$ts $tag"$'\n'
  done <<<"$tags"
  [[ -n $dated ]] || fail "$prefix: No valid releases found."

  # Stable sort keeps `git tag` order for equal dates, like Array.prototype.sort.
  local newest
  newest=$(printf '%s' "$dated" | sort -s -k1,1nr | head -n 1) || fail "$prefix: Unable to sort tags"
  REPLY=${newest#* }
  rm -rf "$repo"
}

# Sets REPLY to the latest released version without the leading "v".
latest_version() {
  require curl
  require jq
  local tmp hdr body code text version
  temp_dir
  tmp=$REPLY
  hdr=$(mktemp "$tmp/ispc-api-headers.XXXXXX") || fail "Unable to create temporary file in $tmp"
  body=$(mktemp "$tmp/ispc-api-body.XXXXXX") || fail "Unable to create temporary file in $tmp"
  # HTTP/1.1 so the status line carries a reason phrase, which Node's fetch reported as statusText.
  code=$(curl -sSL --http1.1 --connect-timeout 10 --max-time 300 \
    -D "$hdr" -o "$body" -w '%{http_code}' "$ISPC_API_URL") || fail 'fetch failed'
  if [[ $code != 200 ]]; then
    # The header dump may include proxy and redirect responses; the last status line is the final one.
    text=$(tr -d '\r' <"$hdr" | grep '^HTTP/' | tail -n 1 | cut -s -d ' ' -f 3-) || text=''
    read_file "$body"
    info "Unable to query latest version: $text - $REPLY"
    latest_version_from_git
    version=$REPLY
  else
    version=$(jq -r '.tag_name' "$body") || fail "Unable to parse latest release information"
  fi
  rm -f "$hdr" "$body"

  version=${version#v}
  info "Latest ISPC version is '$version'"
  REPLY=$version
}

# Sets VERSION to the tag of the release to install, e.g. v1.23.0.
resolve_version() {
  get_input "${INPUT_VERSION:-}"
  local version=$REPLY
  if [[ -z $version || $version == latest ]]; then
    latest_version
    version=$REPLY
  fi
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid version $version"
  VERSION="v$version"
}

# Sets PLATFORM.
resolve_platform() {
  get_input "${INPUT_PLATFORM:-}"
  local platform=$REPLY
  if [[ -z $platform ]]; then
    host_platform
    case "$REPLY" in
      linux) platform=linux ;;
      darwin) platform=macOS ;;
      win32) platform=windows ;;
      *) fail "Platform $REPLY is unsupported for autodetection" ;;
    esac
    info "Autodetected platform: '$platform'"
  fi
  case "$platform" in
    linux | macOS | windows) ;;
    *) fail "Platform $platform not in list of supported platforms: linux,macOS,windows" ;;
  esac
  PLATFORM=$platform
}

# Sets ARCH for PLATFORM. An empty ARCH means the archive name has no arch suffix.
resolve_arch() {
  get_input "${INPUT_ARCHITECTURE:-}"
  local arch=$REPLY
  if [[ -z $arch ]]; then
    case "$PLATFORM" in
      linux)
        host_arch
        case "$REPLY" in
          arm64) arch=aarch64 ;;
          # ISPC doesn't have arch suffix for x86_64 linux archives
          x64) arch='' ;;
          *) fail "Architecture $REPLY is unsupported for autodetection" ;;
        esac
        ;;
      macOS) arch=universal ;;
      # ISPC has only x86_64 windows archives
      windows) arch='' ;;
    esac
    info "Autodetected architecture '$arch'"
  fi
  if [[ $arch == x86_64 && ($PLATFORM == linux || $PLATFORM == windows) ]]; then
    # ISPC doesn't have arch suffix for x86_64 linux and windows archives
    arch=''
  fi
  case "$PLATFORM:$arch" in
    linux:oneapi | linux:aarch64 | linux: | macOS:x86_64 | macOS:arm64 | macOS:universal | windows:) ;;
    *) fail "Platform $PLATFORM does not support arch $arch" ;;
  esac
  ARCH=$arch
}

# Waits before the next download attempt. Tests override this to avoid sleeping.
backoff_sleep() {
  sleep "$1"
}

# Downloads $1 to $2 with up to 3 attempts, retrying the same failures as @actions/tool-cache.
download() {
  local url=$1 out=$2 attempt=1 max_attempts=3 code rc
  while :; do
    rm -f "$out"
    # Like the old HTTP client's three-minute socket timeout, bound connection
    # and stalled-transfer time without limiting the duration of a healthy download.
    if code=$(curl -sSL --retry 0 --connect-timeout 180 --speed-limit 1 --speed-time 180 \
      -w '%{http_code}' -o "$out" "$url"); then rc=0; else rc=$?; fi
    if [[ $rc == 0 && $code == 200 ]]; then
      return 0
    fi

    local err
    if [[ $rc != 0 ]]; then
      err="Download failed: curl exited with code $rc"
    else
      err="Unexpected HTTP response: $code"
    fi
    rm -f "$out"
    if [[ $rc == 0 ]] && ((code < 500)) && [[ $code != 408 && $code != 429 ]]; then
      fail "$err"
    fi
    ((attempt < max_attempts)) || fail "$err"

    info "$err"
    local seconds=$((RANDOM % 11 + 10))
    info "Waiting $seconds seconds before trying again"
    backoff_sleep "$seconds"
    attempt=$((attempt + 1))
  done
}

# Extracts archive $1 of type $2 (zip|tar.gz) into directory $3.
extract() {
  local archive=$1 type=$2 dest=$3
  mkdir -p "$dest" || fail "Unable to create directory $dest"
  if [[ $type == tar.gz ]]; then
    require tar
    tar -xzf "$archive" -C "$dest" || fail "Unable to extract $archive"
  elif command -v unzip >/dev/null 2>&1; then
    unzip -o -q "$archive" -d "$dest" || fail "Unable to extract $archive"
  elif is_windows_host; then
    local win_archive win_dest
    # Windows PowerShell 5.1 rejects extensionless paths in Expand-Archive.
    if [[ $archive != *.zip ]]; then
      mv "$archive" "$archive.zip" || fail "Unable to prepare ZIP archive $archive"
      archive+=.zip
    fi
    win_archive=$(cygpath -w "$archive") || fail "Unable to convert path $archive"
    win_dest=$(cygpath -w "$dest") || fail "Unable to convert path $dest"
    # Pass paths through the environment so they're never parsed as PowerShell code.
    # shellcheck disable=SC2016 # $env: is expanded by PowerShell, not bash.
    ISPC_ARCHIVE=$win_archive ISPC_DEST=$win_dest powershell -NoLogo -NoProfile -NonInteractive -Command \
      '$ErrorActionPreference = "Stop"; Expand-Archive -LiteralPath $env:ISPC_ARCHIVE -DestinationPath $env:ISPC_DEST -Force' \
      || fail "Unable to extract $archive"
  else
    require unzip
  fi
}

# Appends $1 to $GITHUB_PATH, like addPath() from @actions/core.
add_path() {
  local dir=$1
  if [[ -z ${GITHUB_PATH:-} ]]; then
    printf '::add-path::%s\n' "$dir"
    return 0
  fi
  [[ -f $GITHUB_PATH ]] || fail "Missing file at path: $GITHUB_PATH"
  if is_windows_host; then
    printf '%s\r\n' "$dir" >>"$GITHUB_PATH" || fail "Unable to write to $GITHUB_PATH"
  else
    printf '%s\n' "$dir" >>"$GITHUB_PATH" || fail "Unable to write to $GITHUB_PATH"
  fi
}

main() {
  # ISPC release naming convention: ispc-${version}-${platform}[.|-]${architecture}.[zip|tar.gz]
  resolve_version
  resolve_platform
  resolve_arch

  local sep=. arch_str='' type=tar.gz
  [[ $ARCH == oneapi ]] && sep=-
  [[ -n $ARCH ]] && arch_str="$sep$ARCH"
  [[ $PLATFORM == windows ]] && type=zip
  local name="ispc-$VERSION-$PLATFORM$arch_str"
  local url="$ISPC_DOWNLOAD_URL/$VERSION/$name.$type"
  local dir=ispc-releases

  info "Downloading ISPC archive $url"
  [[ -n ${RUNNER_TEMP:-} ]] || fail 'Expected RUNNER_TEMP to be defined'
  require curl
  temp_dir
  local archive
  archive=$(mktemp "$REPLY/XXXXXXXXXXXX") || fail "Unable to create temporary file in $REPLY"
  download "$url" "$archive"
  extract "$archive" "$type" "$dir"

  # Node's path.resolve() used the physical cwd: symlinks resolved (/var ->
  # /private/var on macOS) and, on Windows, long rather than 8.3 names.
  local cwd
  cwd=$(pwd -P) || fail "Unable to determine the current directory"
  local bindir="$cwd/$dir/$name/bin"
  if is_windows_host && command -v cygpath >/dev/null 2>&1; then
    bindir=$(cygpath -w -l "$bindir") || fail "Unable to convert path $bindir"
  fi
  info "Adding ISPC binary directory to PATH: $bindir"
  add_path "$bindir"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main
fi
