# NotchPerch 0.1.0 — Prototype

A little perch for your files: a native macOS shelf that opens from the camera notch.

## Download and launch

Download **NotchPerch-0.1.0-macOS-arm64.zip** from the release assets, unzip it, and move **NotchPerch.app** to Applications. Launch the app to access its menu bar item. The automatically generated GitHub source archives contain source code, not the compiled app.

Requires **macOS 13 or later on an Apple silicon Mac**. Intel Macs are not supported by this binary. No backend, account, or API key is required.

This is an **ad hoc signed development build**, without Apple Developer ID signing or notarization. macOS may block opening it; consult Apple's guidance for opening apps from identified and unidentified developers and assess the download before allowing it. This is not a notarized consumer release.

## Included

- Notch-triggered shelf with a short expansion animation and Reduce Motion support.
- Persistent file references and Remove controls that only clear references.
- Drag-out to Finder using a file promise and source/destination verification.
- Menu bar controls for showing the shelf, launch at login, and quitting.

## Prototype limitations

Drag-out supports regular files, not folders or symbolic links. Real Finder transfers, cross-volume moves, hover/animation, and launch at login still require end-to-end validation. Evaluate with disposable files. Failed transfers may leave a destination copy or recovery file; read the notice before retrying.

The release workflow builds this app on macOS, verifies its ad hoc signature and bundle metadata, and runs the file-transfer fixture suite before publishing. These checks do not exercise actual Finder drag-and-drop or the interactive UI.

Bundle version: **0.1 (2)**. Internal bundle identifier: **dev.local.drop**, retained for existing preferences. The public release tag uses **v0.1.0**.

**SHA256SUMS.txt** provides a SHA-256 checksum for the downloadable app archive.

Source code and project assets are distributed under the MIT license.
