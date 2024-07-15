# Install Node.js

To develop and test the action, you need to install Node.js. To install
Node.js, use your OS package manager or follow the instruction on the
[Node.js website](https://nodejs.org/en/learn/getting-started/how-to-install-nodejs).

# Install Dependencies

```bash
npm install
```

# Lint Code

```bash
npm run lint-fix
```

# Bundle Action

```bash
npm run build
```

It is important to bundle the action before running it locally or pushing it to
the remote repository.

# Run Local Tests

To run the action locally, set the `RUNNER_TEMP` environment variable to a
temporary directory. Then use the run script to execute the action:

```bash
export RUNNER_TEMP=/tmp/runner_temp 
npm run run
```

To provide input variables to the action, set the environment variables before
running the action:

```bash
INPUT_PLATFORM=macOS INPUT_VERSION=1.23.0 INPUT_ARCHITECTURE=x86_64 npm run run
```
