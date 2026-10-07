# Design: Rewrite install-ispc-action without JavaScript

Status: proposal · Date: 2026-10-07

## 1. Goal

Replace the Node.js action (`runs.using: node24`, `src/main.js` bundled into
`build/main.cjs`) with an implementation that needs no JavaScript, no npm, no
bundle and no Dependabot npm churn. Users should notice no change: same
`uses:` reference, same inputs, same result in the job.

## 2. Current behavior (the contract to preserve)

Interface (`action.yml`):

| Item | Value |
|---|---|
| `name` / `description` / `author` | `Install ispc` / `Install Intel ispc.` / `Indy Ray` |
| inputs | `version`, `platform`, `architecture`: all optional, no defaults |
| outputs | none |
| side effects | ISPC `bin` dir appended to `$GITHUB_PATH`; archive extracted to `./ispc-releases/` in the workspace |
| ref used by users | `ispc/install-ispc-action@main` (the repo has **no tags**) |

Logic:

1. **Input reading**: `INPUT_*`, whitespace-trimmed, empty means unset.
2. **Version**: if empty or `latest`:
   - `GET https://api.github.com/repos/ispc/ispc/releases/latest` (no token) and use `tag_name`.
   - If the status isn't 200, log `Unable to query latest version: <statusText> - <body>` and fall back to git:
     shallow clone `https://github.com/ispc/ispc.git` into `./ispc-repo`, `fetch --tags`, drop `trunk-artifacts`,
     pick the tag whose commit has the newest author date (`%ai`), then delete `ispc-repo`.
   - Strip a leading `v`, then log `Latest ISPC version is '<v>'`.

   Validate against `^[0-9]+\.[0-9]+\.[0-9]+$` (a user-given `v1.23.0` is **rejected**) and prefix with `v`.
3. **Platform**: from the input, or autodetected from the OS (`linux`→`linux`, `darwin`→`macOS`,
   `win32`→`windows`, otherwise `Platform <p> is unsupported for autodetection`). When autodetected,
   log `Autodetected platform: '<p>'`. Must be one of `linux,macOS,windows` (case-sensitive), otherwise
   `Platform <p> not in list of supported platforms: linux,macOS,windows`.
4. **Architecture**: from the input, or autodetected **based on the resolved platform**:
   - linux: `arm64`→`aarch64`, `x64`→`''`, otherwise `Architecture <a> is unsupported for autodetection`
   - macOS: always `universal`
   - windows: always `''`

   When autodetected, log `Autodetected architecture '<a>'`. Input `x86_64` on linux/windows becomes `''`.
   Allowed values: linux `{oneapi, aarch64, ''}`, macOS `{x86_64, arm64, universal}`, windows `{''}`.
   Otherwise `Platform <p> does not support arch <a>`.
5. **Download**: `https://github.com/ispc/ispc/releases/download/<vX>/ispc-<vX>-<platform><sep><arch><ext>`
   - `sep` is `-` for `oneapi` and `.` otherwise. It's omitted when arch is `''`.
   - `ext` is `.zip` for windows and `.tar.gz` otherwise.
   - Logs `Downloading ISPC archive <url>`.
   - Saved to `$RUNNER_TEMP/<uuid>`. Up to 3 attempts, 10–20 s backoff, retried only on 5xx/408/429/network errors.
     Any other non-200 fails with `Unexpected HTTP response: <code>`.
6. **Extract** into `./ispc-releases` (created if missing, existing files overwritten):
   - tar: `tar xz [--overwrite]`
   - zip on Windows: pwsh/powershell `ZipFile.ExtractToDirectory` / `Expand-Archive`
   - zip elsewhere: `unzip -o -q`
7. **PATH**: log `Adding ISPC binary directory to PATH: <abs>`. `<abs>` is
   `path.resolve('ispc-releases', archiveName, 'bin')`, so it's a native path (`D:\a\...\bin` on Windows).
   Append it to `$GITHUB_PATH`.
8. **Failure**: any error → `::error::<message>` and exit code 1. In the emitted workflow command,
   escape `%`, CR and LF as `%25`, `%0D` and `%0A`, respectively, matching `@actions/core`.

Note that a user can pick a platform different from the runner (e.g. `platform: windows` on Linux). That
still works because extraction is chosen by the archive type, not by the host.

## 3. Technology evaluation

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Composite action + one Bash script** | No build step, no deps. Runs on every hosted OS (Windows uses Git Bash). Locally testable, `shellcheck`-able. Works on older runners and GHES, which don't need node24 support. | Windows self-hosted runners **must have bash** (Git for Windows). Windows paths need `cygpath`. | **Recommended** |
| Composite + Bash on *nix, Windows PowerShell 5.1 on Windows | Uses only OS built-ins everywhere | Two implementations of the same logic → drift and double the tests | Fallback only if bash on Windows is a real problem for users |
| Composite + `pwsh` everywhere | One script | `pwsh` isn't guaranteed on self-hosted Linux/macOS | No |
| Docker container action | Isolated | Linux only, slow, breaks macOS/Windows | No |
| Compiled binary (Go/Rust) | Fast, typed | Still a build artifact to commit/release, so not simpler | No |
| Pure YAML (inline `run:` only) | One file | ~100 lines of bash inside YAML: hard to lint and test locally | Fold into the recommended option: keep `action.yml` thin and the logic in `install.sh` |

"GitHub workflows" in the narrow sense (reusable workflows, `workflow_call`) **can't** replace the
action. Users call it as a *step* (`uses:` under `steps:`), and a reusable workflow can only be called
as a whole *job*. A **composite action** is the "workflow-YAML" form of an action and keeps the step
interface.

### Recommended shape

There are two thin launcher steps, one per OS family. Both run the same `install.sh`. This follows
`taiki-e/install-action` (see §7).

```yaml
# action.yml: name/description/author/inputs byte-identical to today
runs:
  using: composite
  steps:
    - name: Install ispc
      if: runner.os != 'Windows'
      # Clean the env before bash starts: the caller's BASH_ENV/ENV/SHELLOPTS must not alter the script.
      shell: /usr/bin/env -u ENV -u BASH_ENV -u CDPATH -u SHELLOPTS -u BASHOPTS /bin/sh -eu {0}
      working-directory: ${{ github.workspace }}   # node actions ran with cwd = workspace
      env:                                          # pass inputs via env: no expression injection
        INPUT_VERSION: ${{ inputs.version }}
        INPUT_PLATFORM: ${{ inputs.platform }}
        INPUT_ARCHITECTURE: ${{ inputs.architecture }}
        ISPC_RUNNER_OS: ${{ runner.os }}            # Linux | macOS | Windows
        ISPC_RUNNER_ARCH: ${{ runner.arch }}        # X86 | X64 | ARM | ARM64
      run: exec bash --noprofile --norc "${GITHUB_ACTION_PATH:?}/install.sh"

    - name: Install ispc
      if: runner.os == 'Windows'
      # Windows PowerShell 5.1 is always present on Windows (pwsh is not), so it's used as the launcher.
      shell: powershell
      working-directory: ${{ github.workspace }}
      env:                                          # same block as above, kept in sync by hand
        INPUT_VERSION: ${{ inputs.version }}
        INPUT_PLATFORM: ${{ inputs.platform }}
        INPUT_ARCHITECTURE: ${{ inputs.architecture }}
        ISPC_RUNNER_OS: ${{ runner.os }}
        ISPC_RUNNER_ARCH: ${{ runner.arch }}
      run: |
        foreach ($n in 'ENV','BASH_ENV','CDPATH','SHELLOPTS','BASHOPTS') { Remove-Item "Env:$n" -ErrorAction Ignore }
        & bash --noprofile --norc "$env:GITHUB_ACTION_PATH\install.sh"
        exit $LASTEXITCODE
```

**`windows-11-arm` Bash start-up bug.** `taiki-e/install-action` says in a code comment that Bash sometimes
fails to start on `windows-11-arm` runners (it cites `actions/partner-runner-images#169`). Its workaround
is to retry starting Bash up to 10 times from PowerShell. I couldn't confirm whether the bug is still
there: that repo has issues disabled. Plan:
- Phase 1 starts with a spike that runs the launcher about 50 times on `windows-11-arm`.
- If the failure reproduces, add a retry loop to the Windows launcher only. `install.sh` writes a marker
  file in `$RUNNER_TEMP` as its first action, and the launcher retries **only if that marker is missing**,
  so a real failure (e.g. an invalid version) isn't re-run.
- If it doesn't reproduce, keep the launcher as above.

Key implementation decisions in `install.sh`:

- **Structure**: `set -euo pipefail`, plus a `fail()` that escapes the message before printing
  `::error::<msg>` and exiting 1. Replace `%` with `%25` first, then CR with `%0D` and LF with `%0A`,
  matching `@actions/core`; use a fixed `printf` format so message content is never interpreted as a
  format string. Every external command is guarded with `|| fail ...` so failures always surface as an
  annotation. The script is written as functions with a `main` guard
  (`[[ "${BASH_SOURCE[0]}" == "$0" ]] && main`) so tests can source it.
- **Inputs**: trim the exact JavaScript `String.trim()` whitespace set, including NBSP and BOM, with
  parameter expansion over complete UTF-8 sequences. This must work in Bash 3.2 and non-UTF-8 locales.
  Keep the same `INPUT_*` names as today, so local runs work the same as
  `INPUT_VERSION=... node src/main.js` did.
- **OS/arch detection**: use `runner.os`/`runner.arch`, mapped to Node's names (`X64→x64`, `ARM64→arm64`,
  `X86→ia32`, `ARM→arm`) so the error messages match. `uname -m` isn't used because it reports `x86_64`
  under emulation on Windows/macOS ARM. `runner.arch` is the arch of the runner's own Node binary, which
  is exactly what `os.arch()` returned.
- **Latest version**: `curl -sS -w '%{http_code}'` against the API, then `jq -r .tag_name`. `jq` is
  preinstalled on all GitHub-hosted images; self-hosted runners need it (§5.3). The non-200 log line takes
  the body as-is and the status text from the HTTP status line, to match
  `Unable to query latest version: <statusText> - <body>`.
- **Git fallback**: same algorithm as today. Clone, `fetch --tags`, list tags without `trunk-artifacts`,
  then print `git log -1 --format=%at <tag>` for each and stable-sort numerically, newest first
  (`sort -s -k1,1nr`). Ties keep `git tag` (alphabetical) order, which matches the stable JS `Array.sort`.
- **Download**: an explicit loop with at most 3 attempts, using
  `curl -sSL --retry 0 --connect-timeout 180 --speed-limit 1 --speed-time 180 -w '%{http_code}' -o "$archive" "$url"`
  per attempt, where
  `archive="$RUNNER_TEMP/<random>"`. Capture the curl exit code and HTTP status separately: success
  requires both exit code 0 and HTTP 200. Retry transport failures (including DNS failures, connection
  refusal and interrupted transfers), every HTTP 5xx, and HTTP 408/429. Any other non-200 status fails
  immediately with `Unexpected HTTP response: <code>`. Discard partial downloads before retrying, and
  wait a random integer 10–20 seconds between attempts, matching tool-cache. Curl's built-in retry
  policy is narrower; `--retry-all-errors` with `--fail` would also retry 404, so neither is used.
  Connection and stalled-transfer timeouts are three minutes, comparable to the old HTTP client's
  socket timeout; a healthy download may take longer than three minutes.
- **Extract**: `mkdir -p ispc-releases`, then:
  - tar: `tar -xzf <file> -C ispc-releases`
  - zip: `unzip -o -q <file> -d ispc-releases` if `unzip` exists, otherwise
    `powershell -NoProfile -Command "Expand-Archive -LiteralPath ... -DestinationPath ... -Force"`
    (always present on Windows). Rename extensionless temporary ZIP archives to `.zip` before calling
    Windows PowerShell 5.1, which validates the filename extension.
- **PATH**: `bindir="$PWD/ispc-releases/$name/bin"`. On Windows, convert with `cygpath -w` so `$GITHUB_PATH`
  gets the same `D:\...\bin` string as before. Append with `printf '%s\r\n' "$bindir" >> "$GITHUB_PATH"`
  on Windows and `printf '%s\n' "$bindir" >> "$GITHUB_PATH"` elsewhere. This preserves Node's native
  line endings as well as the path text.

## 4. Regression / no-external-change criteria

Phase 2 requires **all** the criteria below except E2 to pass. E2 is a Phase 3 completion criterion,
since the Node implementation is retained through the soak period. Each has a check, preferably automated.

### A. Interface (static)

| # | Criterion | Check |
|---|---|---|
| A1 | `name`, `description`, `author` unchanged | `yq` diff of `action.yml` against `main@11452bc` (only `runs:` may differ) |
| A2 | Input names, `required: false`, and the absence of defaults unchanged. Descriptions unchanged. | same diff |
| A3 | No outputs added or removed | same diff |
| A4 | Users' `uses: ispc/install-ispc-action@main` keeps working with no `with:` changes | CI test calls the action with every README example verbatim |
| A5 | No new required permissions, secrets, tokens or env vars | review + README examples run with `permissions: read-all` |

### B. Functional parity (differential: old vs new on the same input)

Each case runs **both** implementations: old = `node build/main.cjs` from the frozen commit, new =
`install.sh`. Both get identical `INPUT_*`, a fresh `GITHUB_PATH` temp file and a fresh workspace. Then
compare:

| # | Compared artifact | Rule |
|---|---|---|
| B1 | Exit code | identical |
| B2 | `::error::` line | identical text (only exception: transport-level download errors, see D2) |
| B3 | Contents of `$GITHUB_PATH` | byte-identical, including native line endings (CRLF on Windows, LF elsewhere) |
| B4 | Downloaded URL (`Downloading ISPC archive ...` line) | identical |
| B5 | Informational log lines (`Autodetected ...`, `Latest ISPC version ...`, `Adding ...`) | identical in text and order |
| B6 | Tree of `ispc-releases/` (`find ... -type f` + sizes + exec bits) | identical |
| B7 | Workspace after the run, excluding `ispc-releases` | identical (no stray files) |
| B8 | `ispc --version` from the PATH entry, in the next step | identical |

Input matrix (explicit platform + arch don't depend on the host, so they run on Linux in one job):

- **version**: `''`, `latest`, `  latest  `, `1.23.0`, ` 1.23.0 `, `v1.23.0` (must fail), `1.23` (fail),
  `1.23.0rc1` (fail), `9.9.9` (404 → fail)
- **platform**: `''`, `linux`, `macOS`, `windows`, `macos` (fail, case-sensitive), `freebsd` (fail)
- **architecture**:
  - per platform: every allowed value, plus `x86_64` (normalized on linux/windows, kept on macOS)
  - invalid combos: `aarch64` on windows, `oneapi` on macOS, `arm64` on linux, `foo` → each must fail

  Download-requiring cases use only the valid combos that actually exist for 1.23.0. Validation-failure
  cases don't hit the network.
- **cross-platform**: `platform: windows` on a Linux runner (zip extracted with `unzip`) and
  `platform: linux` on macOS. Both must still work.

### C. Hosted-runner coverage (end-to-end through `uses: ./`)

| # | Criterion |
|---|---|
| C1 | `latest` and `1.23.0` install and run `ispc --version` / `--support-matrix` on: `ubuntu-22.04`, `ubuntu-24.04`, `ubuntu-24.04-arm` (aarch64 autodetect, currently **untested**), `windows-2022`, `windows-2025`, `windows-11-arm`, `macos-15`, `macos-latest`, `macos-15-intel`. `macos-13` from today's `test.yml` is retired; `macos-15-intel` replaces it. Pinned image versions are used on purpose, so a `-latest` image switch doesn't hide a regression. |
| C2 | The installed version matches the request (existing pwsh check in `test.yml`) |
| C3 | The step's `bin` dir is first in `PATH` in the next step, in both `bash` and `pwsh` shells, and on Windows also in `cmd` |
| C4 | Calling the action twice in one job (same and different versions) succeeds, matching the old overwrite behavior |
| C5 | Works when the caller job sets `defaults.run.working-directory` or `shell:`. Composite steps must not inherit them; the extraction dir is still `$GITHUB_WORKSPACE/ispc-releases`. |
| C6 | Negative cases (`continue-on-error: true`) end with `steps.<id>.outcome == 'failure'` and an error annotation |
| C7 | The caller's environment doesn't leak in: a job with `env: { BASH_ENV: <script that breaks PATH/exits>, SHELLOPTS: xtrace, CDPATH: /tmp }` still installs correctly. Covered on Linux, macOS and Windows. |
| C8 | Works inside a Linux `container:` job that has the §5.3 tools installed (e.g. `ubuntu:24.04` plus `curl`, `jq`, `git`). In a bare `ubuntu:24.04`, it fails with the `requires 'curl'` error, the accepted deviation from §5.3. |
| C10 | Lazy tool checks: with `version: 1.23.0` and `jq`/`git` removed from `PATH`, installation succeeds. With `latest` and no `jq`, the step fails with the `requires 'jq'` message. |
| C9 | `windows-11-arm` stability: the spike's ~50 repeated runs succeed with the final launcher. A smaller repeat count (e.g. 5) stays in CI. |

### D. Robustness parity

| # | Criterion | Check |
|---|---|---|
| D1 | Git fallback picks the same tag as the old code | Unit test: source `install.sh` and call the fallback function directly, then compare with the old JS on the same clone |
| D2 | Download retries: transport failures, every 5xx and 408/429 get at most 3 attempts; other non-200 statuses aren't retried | Stub sequences: 503/503/200, 501/501/200, 408/408/200 and 429/429/200; persistent 503 stops after 3 attempts; 404 and 204 fail after 1. Simulate DNS failure, connection refusal and an interrupted transfer before a successful attempt; confirm partial output is discarded and the completed archive matches. Stub the wait function to check the 10–20 s backoff without sleeping. Log wording of transport errors may differ; that's the one accepted text deviation. |
| D3 | Inputs containing shell metacharacters (`$(id)`, `;`, quotes) are rejected by validation and never executed | Negative tests |
| D4 | `shellcheck` clean | Lint job (replaces `npm run lint`) |
| D5 | Error annotations preserve the baseline's workflow-command escaping | Compare old/new errors for invalid inputs containing `%`, literal `%0A`, CR and LF, including an embedded `::warning::injected` line. Require one error command with identical encoded text and no additional workflow command. |

### E. Non-functional

- E1: Runtime is no slower than today's median per OS. Taken from Actions run timings, ±10%.
- E2 (Phase 3 completion): No committed build artifacts and no package manager files in the repo.

## 5. Intentional deviations (need explicit sign-off)

Keep this list as short as possible. Anything not listed here is a regression.

1. **Git-fallback clone location**: today it's `./ispc-repo` in the user's workspace, and it's left behind
   if the fallback fails. **Decided**: move it to `$RUNNER_TEMP/ispc-repo`. The user-visible effect is
   only "no stray directory on failure", and a leftover folder isn't something users can rely on.
2. **Wording of low-level download/extract errors** (D2): the messages come from curl/tar instead of Node.
   The `::error::` annotation and the failure itself are preserved.
3. **Runner requirements change**:
   - **No longer needed**: a runner new enough for `node24`, so older and GHES runners gain support.
   - **Newly needed on all self-hosted runners**: `bash`, `curl`, `jq`, `tar`, plus `unzip` when
     extracting zip archives on Linux/macOS. `git` is also needed, but only for the latest-version fallback.
   - **Windows self-hosted** specifically needs Git for Windows (for `bash`), and `jq` on `PATH`.
   - All of these are present on GitHub-hosted images.
   - Compared with today, the Node action already required `tar`, `unzip` (zip on Linux/macOS), PowerShell
     (zip on Windows) and `git` (fallback). What's **new**: `bash` (Windows only, since Linux/macOS always
     have it), `curl`, and `jq`.
   - **Checks are lazy**: `install.sh` checks for a tool only on the code path that uses it. `jq` and `git`
     are needed only when resolving `latest`; `unzip` only for zip archives on Linux/macOS. A missing tool
     fails with `::error::install-ispc-action requires '<tool>' on PATH`. Users who pin `version:` need
     only `bash`, `curl` and `tar`.

   **Decided: accepted.**
   - Who's affected: GitHub-hosted runners, no one. Self-hosted VMs, rarely (mostly a missing `jq`).
   - **Highest risk: `container:` jobs on slim images** (e.g. `ubuntu:24.04` has no `curl`). The old action
     downloaded through the runner's Node, so it didn't need any tools in the container.
   - Mitigations: the clear error message, a "Self-hosted runners and containers" README section, and the
     `@v1-node` tag (§6, Phase 0).
   - If users report problems, follow `taiki-e/install-action`: auto-install missing tools via the
     container's package manager. If Windows without Git Bash turns out to matter, switch Windows to the
     PowerShell variant from §3.

Out of scope for parity, but worth considering afterwards: using `github.token` for the API call to avoid
the 60 req/h limit. It's left out because on GHES the token is for the wrong host, and it would change
behavior.

## 6. Transition plan

**Phase 0: Freeze the baseline.**
- Record the current commit (`11452bc`) as the reference implementation for the differential tests.
- **Decided**: create tag `v1-node` at that commit, so anyone hurt by the switch can pin
  `ispc/install-ispc-action@v1-node` with a one-line change (the repo has no tags today). Push it right
  before Phase 2 merges, with a final confirmation since it's public. Mention it in the README and in the
  Phase 2 PR description.

**Phase 1: Build the new implementation side by side** (PR 1, no user impact).
- Spike first: repeat the Windows launcher on `windows-11-arm` (C9) to decide whether the retry loop
  from §3 is needed.
- Add `install.sh`.
- Add `test/parity.sh`. It runs the old (`node build/main.cjs`) and new implementations over the §4.B
  matrix and diffs B1–B7.
- Add `.github/workflows/parity.yml`. It runs `parity.sh` on Linux/macOS/Windows and also runs §4.C/D
  against `install.sh` invoked via a temporary `test/composite/action.yml`.
- The root `action.yml` stays `node24`, so users on `@main` aren't affected yet.

**Phase 2: Switch** (PR 2, small and easy to revert).
- Change `runs:` in `action.yml` to `composite`. That's the only change to `action.yml`.
- Update `test.yml`: add the C1 matrix (pinned Ubuntu/Windows/macOS images, ARM, Intel mac) plus the
  C3–C9 cases.
- Merge only after every §4 criterion except the Phase 3 cleanup criterion E2 is green and the §5
  deviations are approved.

**Phase 3: Cleanup** (PR 3, after a soak period of about 2 weeks with no issues).
- Delete `src/`, `build/`, `package.json`, `package-lock.json`, and `node_modules` from `.gitignore`.
  Also delete `parity.sh` and the old-vs-new parts of `parity.yml`, keeping the self-tests.
- `build.yml`: replace npm lint/build/diff with `shellcheck install.sh`.
- `codeql.yml`: upgrade the pinned `github/codeql-action/init` and `analyze` SHAs together to a
  supported release whose bundled CLI supports the `actions` language; the current v3.25.12 pins
  predate that support. Change language `javascript` → `actions` (CodeQL analyzes workflow/composite
  YAML), remove the unnecessary `autobuild` step, and drop `paths-ignore: build/`. Verify in CI that
  initialization recognizes `actions` and analysis completes successfully.
- `dependabot.yml`: ecosystem `npm` → `github-actions`, to keep the pinned SHAs of
  checkout/harden-runner/codeql fresh.
- `DEVELOPMENT.md`: replace the Node instructions with
  `RUNNER_TEMP=/tmp/rt GITHUB_PATH=/tmp/p INPUT_VERSION=1.23.0 bash install.sh`.
- `README.md`: inputs and examples unchanged. Add a short "Self-hosted runners and containers" section
  listing the required tools from §5.3 and the `@v1-node` fallback. This part ships with Phase 2, not
  Phase 3.
- Complete Phase 3 only after E2 passes and the replacement lint, self-tests and CodeQL analysis are green.

**Rollback**: revert the Phase 2 commit on `main`. Users on `@main` get the Node version back immediately.
Phase 3 happens only after the soak, so the revert stays trivial during the risky window.

## 7. Prior art

I checked the `action.yml` of 30 popular install/setup actions (2026-10-07):

| Approach | Count | Examples |
|---|---|---|
| JS/TS (`node20`/`node24`) | 21 | `actions/setup-{node,python,go,java}`, `KyleMayes/install-llvm-action`, `aminya/setup-cpp`, `mlugg/setup-zig`, `lukka/get-cmake`, `Jimver/cuda-toolkit`, `ilammy/msvc-dev-cmd`, `astral-sh/setup-uv`, `ruby/setup-ruby` |
| Composite + Bash | 5 | `dtolnay/rust-toolchain`, `taiki-e/install-action`, `fortran-lang/setup-fortran`, `jiro4989/setup-nim-action`, `rui314/setup-mold` |
| Composite + sh on Linux/macOS, PowerShell on Windows | 1 | `cargo-bins/cargo-binstall` |
| Composite + pwsh only | 3 | `egor-tensin/setup-{clang,gcc,mingw}` |
| Reusable workflow | 0 | (can't be used as a step, see §3) |

Most JS actions are JS because they use `@actions/tool-cache` caching, problem matchers or pre/post
hooks. This action uses none of these.

The closest match is **`taiki-e/install-action`**: it downloads release archives, extracts them and adds
them to `PATH` on every OS. This design copies its patterns:
- a thin `action.yml` running one `main.sh` from `$GITHUB_ACTION_PATH`
- inputs passed via `env:`
- `RUNNER_OS`/`RUNNER_ARCH` taken from expressions
- `printf '::error::...'; exit 1` for failures, with `@actions/core`-compatible message escaping
- `curl` for HTTPS downloads, with the explicit retry policy in §3
- `jq` for JSON
- converting the Windows path before writing `$GITHUB_PATH`
- stripping `BASH_ENV`/`ENV`/`SHELLOPTS` before starting bash
- the PowerShell launcher on Windows, with the `windows-11-arm` retry workaround
- a broad pinned-image test matrix

`dtolnay/rust-toolchain` shows that `shell: bash` on Windows hosted runners is a widely used,
low-friction choice. `cargo-binstall` is the reference for the separate-PowerShell fallback in §3.
