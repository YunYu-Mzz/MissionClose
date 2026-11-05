# Contributing

This fork is based on [beqaabu/MissionClose](https://github.com/beqaabu/MissionClose), commit `ac2fef9`, under the MIT license. Keep the original license and attribution.

## Build and test

Requires macOS 13+ and Xcode Command Line Tools. There is no Xcode project or external dependency.

```sh
./tools/test.sh
./build-local.sh                         # native architecture, build only
ADHOC=1 NO_INSTALL=1 ./build.sh            # upstream universal build used by CI
```

`build-local.sh` defaults to ad-hoc signing. To install, quit the running app first and use `INSTALL=1 ./build-local.sh`. Set `SIGN_IDENTITY` and optionally `SIGN_KEYCHAIN` to use an existing signing identity. The script does not configure certificate trust or grant Accessibility access. Do not commit certificates, private keys, keychains, logs, or application backups.

## Code layout

- `MissionControl.swift`: overview discovery and thumbnails.
- `WindowIndex.swift`: AX window enumeration, CG thumbnail identities and AX matching.
- `WindowMatching.swift`: pure matching rules and ambiguity handling.
- `AX.swift`, `AXActionResult.swift`: AX access and conservative action-result handling.
- `Controller.swift`, `WindowButtons.swift`: polling, event taps, actions and overlays.
- `Probe.swift`, `Diagnostics.swift`: local diagnostics; review output before sharing.
- `Tests/main.swift`: assertion-based matching, action-result and version-comparison tests.

## Compatibility

Do not replace an unresolved known window ID with a same-title guess. Preserve the distinction between closing a window and quitting its app. Do not tap the Dock's private event type 30: upstream found it interferes with Dock hover reveal.

Keep polling and event handling quiet when Mission Control is closed. Tests cannot substitute for live verification on each macOS version. See `LOCAL_FIXES.md` for the current limits, including the unresolved Notes accessibility issue.

## Publishing

CI builds and tests the app. This fork does not carry the upstream website deployment or release/Homebrew update workflows. A future release must explicitly choose its signing identity, version and compatibility claims. The `site/` directory is retained as upstream reference/demo material and is not automatically deployed.
