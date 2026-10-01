# Contributing

NotchPerch is an early native macOS prototype. Small, focused contributions with clear reproduction steps are welcome.

## Report a bug

Open a GitHub issue with your macOS version, Mac architecture, display/notch setup, steps to reproduce, and expected and observed behavior. Include whether the problem occurred in a fixture test or an actual Finder interaction. Use generic filenames and redact personal paths from logs and screenshots. Never attach personal documents or credentials.

For transfer problems, report whether the source, destination, and recovery file still exist. Avoid repeating operations on the only copy of an important file; reproduce with disposable fixtures.

## Propose a change

1. Describe the problem or feature before starting a large change.
2. Keep the pull request focused and follow the existing Swift/AppKit style.
3. Build the app on macOS and run the fixture suite when changing transfer or persistence behavior.
4. Add a regression fixture for a reproducible transfer defect.
5. Explain the checks performed and which interactive cases remain unverified.

Follow the [development guide](docs/development.md). Do not commit generated app bundles, temporary files, personal paths, or machine preferences. Preserve existing shelf references and the distinction between removing a reference and moving a file.
