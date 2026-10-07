#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Exercises the real Windows PowerShell 5.1 fallback with unzip unavailable.
# shellcheck disable=SC1090,SC1091

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export ISPC_RUNNER_OS=Windows
source "$ROOT/install.sh"

mkdir -p "$WORK/src/bin"
printf 'fixture compiler\n' >"$WORK/src/bin/ispc.exe"
export ISPC_SOURCE ISPC_ARCHIVE
ISPC_SOURCE=$(cygpath -w "$WORK/src")
ISPC_ARCHIVE=$(cygpath -w "$WORK/release")
# shellcheck disable=SC2016
powershell -NoLogo -NoProfile -NonInteractive -Command \
  '$ErrorActionPreference = "Stop"; Add-Type -AssemblyName System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::CreateFromDirectory($env:ISPC_SOURCE, $env:ISPC_ARCHIVE)'

# Hide unzip only from tool discovery; keep the real cygpath and PowerShell.
command() {
  if [[ ${1:-} == -v && ${2:-} == unzip ]]; then return 1; fi
  builtin command "$@"
}
if command -v unzip >/dev/null 2>&1; then
  echo 'unzip was not hidden'
  exit 1
fi

dest="$WORK/destination with space's"
extract "$WORK/release" zip "$dest"
[[ $(cat "$dest/bin/ispc.exe") == 'fixture compiler' ]]
[[ -f $WORK/release.zip ]]

printf 'stale compiler\n' >"$dest/bin/ispc.exe"
extract "$WORK/release.zip" zip "$dest"
[[ $(cat "$dest/bin/ispc.exe") == 'fixture compiler' ]]
echo 'PowerShell extracts extensionless ZIP downloads and overwrites existing files'
