# Requirements

The action is a single Bash script, `install.sh`. To run it locally you need
`bash`, `curl` and `tar`, plus `jq` and `git` to resolve the latest version and
`unzip` to extract Windows releases on Linux or macOS. Linting needs
[ShellCheck](https://www.shellcheck.net/).

# Lint Code

```bash
shellcheck install.sh test/*.sh
```

# Run Local Tests

```bash
bash test/unit.sh
python3 test/download-timeout.py
```

# Run the Action Locally

Set `RUNNER_TEMP` to a temporary directory and `GITHUB_PATH` to a file that
receives the ISPC `bin` directory, then run the script:

```bash
RUNNER_TEMP=/tmp/rt GITHUB_PATH=/tmp/p INPUT_VERSION=1.23.0 bash install.sh
```

To provide input variables to the action, set the environment variables before
running the script:

```bash
RUNNER_TEMP=/tmp/rt GITHUB_PATH=/tmp/p INPUT_PLATFORM=macOS INPUT_VERSION=1.23.0 INPUT_ARCHITECTURE=x86_64 bash install.sh
```
