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
