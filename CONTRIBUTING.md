# Contributing

Read the setup in [README.md](README.md). Keep contributions focused and include any license text required by new dependencies or assets.

## Make a change

Keep changes focused and describe the behavior they fix or add. Keep deterministic game logic in `Sources/OrbitCore` and UIKit presentation in `Sources/MilkOrbitApp`. Preserve the bundled sector data, test fixtures, asset catalogs, font, and accompanying license unless the change specifically requires updating them.

Use the Xcode 27.2 setup described in the README. From the checkout root:

```sh
bash scripts/check.sh --core
bash scripts/build-ios.sh
bash scripts/run-simulator.sh
```

Pass a Simulator UUID to `run-simulator.sh` when selecting a particular destination. For core-only work with Swift 6 on macOS or Linux, use `swift test`. Add a focused regression test when changing physics, persistence, or another core behavior; do not update expected fixtures simply to make a failure disappear.

## Check gameplay changes

The shared Xcode scheme is app-only; there is no active automated UI test suite. For relevant UI or interaction changes, manually check:

- Placement, 0.5-step strength changes and held +/− repeat, movement, removal, Undo, and Reset.
- Launch, held 4× and release to 1×, Abort/retry, and sector completion.
- Portrait and both landscape directions, menus, larger text, and VoiceOver actions.
- Background/foreground transitions, saved-game restoration, and campaign restart confirmation.
- Haptics and mute on a physical device when those behaviors change; a Simulator cannot verify tactile feedback.

Report the checks actually performed, the device model or Simulator type, and OS/Xcode versions. Include useful screenshots for visible changes. State any untested behavior without treating a launch or passing core tests as a full gameplay pass.

## Keep submissions portable

Keep signing settings in ignored `Config/Local.xcconfig`. Do not commit credentials, account identifiers, device UUIDs, absolute machine paths, generated builds, local logs, or historical work files. Review screenshots and logs before sharing them. Add new artwork or dependencies only with documented provenance and applicable license terms.

In a pull request, explain the problem, the resulting behavior, and relevant validation. Call out changes to saved-game compatibility, physics results, supported platforms, or third-party material.
