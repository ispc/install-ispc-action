[![Build status](https://github.com/ispc/install-ispc-action/actions/workflows/build.yml/badge.svg)](https://github.com/ispc/install-ispc-action/actions/workflows/build.yml)

# Install ISPC GitHub Action

Github Action to install ISPC compiler.

## Input Variables

- `version`: Release version of `ispc` to install (optional).
- `platform`: Platform to download release of `ispc` for (optional); one of
`linux`, `windows` or `macOS`.
- `architecture`: Architecture to download release of `ispc` for (optional).

## Examples

### Quickstart

Single platform installation of latest ISPC release:

```yaml
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    name: build
    steps:
    - name: install ISPC
      uses: ispc/install-ispc-action@main
```

To install specific version of ISPC, provide the `version` variable:

```yaml
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    name: build
    steps:
    - name: install ISPC
      uses: ispc/install-ispc-action@main
      with:
        version: 1.22.0
```

### Platform Build Matrix

To install ISPC across platforms, add the `platform` variable to your build matrix:

```yaml
jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        include:
        - os: ubuntu-latest
          platform: linux

        - os: windows-latest
          platform: windows

        - os: macos-latest
          platform: macOS

    runs-on: ${{ matrix.os }}
    name: build
    steps:
    - name: install ISPC
      uses: ispc/install-ispc-action@main
      with:
        platform: ${{ matrix.platform }}
```

## Self-hosted Runners and Containers

The action is a composite action that runs a Bash script, so it needs these
tools on `PATH`. All of them are preinstalled on GitHub-hosted runners.

- Always: `bash`, `curl` and `tar`.
- When `version` is empty or `latest`: `jq`, and `git` as a fallback if the
  GitHub API is unavailable or rate limited.
- When installing a `windows` release on Linux or macOS: `unzip`.
- On Windows: Git for Windows, which provides `bash`.

A missing tool fails the step with `install-ispc-action requires '<tool>' on PATH`.
For example, a job running in a slim `ubuntu:24.04` container needs these first:

```yaml
    - run: apt-get update && apt-get install -y curl ca-certificates jq git
```

If you can't install these tools, pin the previous Node.js-based version of
the action:

```yaml
    - name: install ISPC
      uses: ispc/install-ispc-action@v1-node
```
