# Milk Orbit

A native iPhone and iPad gravity puzzle game: place black holes, collect the beacons, and guide your ship to the dock across 20 sectors. Built with Swift, UIKit, and Core Graphics, with a deterministic game core and no third-party game engine.

## Build and run

Use **Xcode 27.2** with its iOS 27.2 SDK on macOS. The deployment target is **iOS 17.0**, but compiling the current source requires newer UIKit declarations, including iOS 27.1 reserved-region APIs. Runtime availability checks provide fallbacks on older supported iOS versions. The package uses Swift 6.

Select Xcode in its Settings → Locations → Command Line Tools, or use `DEVELOPER_DIR` to select your installation. Install an iOS 17 or later Simulator runtime and Python 3 for the run helper, then run these commands from the checkout root:

```sh
bash scripts/check.sh --core
bash scripts/run-simulator.sh
```

The first command validates the project and runs core tests. The second builds, installs and launches an unsigned app in an iPhone Simulator; pass an optional Simulator UUID to choose a destination. It restarts the app on that destination. Use `bash scripts/build-ios.sh` for a build without device actions, or Xcode for an iPad destination.

You can also open `MilkOrbit.xcodeproj`, select the shared **MilkOrbit** scheme and an installed Simulator, and Run. Simulator builds do not need a development team. For a physical device, copy `Config/Local.xcconfig.example` to the ignored `Config/Local.xcconfig` and supply your own team and bundle identifier.

For core-only development with a Swift 6 toolchain on macOS or Linux:

```sh
swift test
```

There is currently **no automated UI test suite**. Core tests and a successful build do not establish that gameplay, layout, or haptics work correctly; see [CONTRIBUTING.md](CONTRIBUTING.md) for manual checks.

GitHub Actions defines Linux core tests and an unsigned macOS Simulator build. The macOS runner must have Xcode 27.2 or later installed; manual workflow runs accept its `Contents/Developer` path. The build fails with a clear SDK requirement when the runner's default Xcode is older. Hosted CI has not been verified during local preparation.

## Play

- Tap empty board space to place a hole. If controls are open, the first tap closes them.
- Tap a hole to adjust its strength in **0.5 steps**, move it, or remove it. Hold +/− to repeat. Hold and start vertically to adjust strength; start sideways to move on the grid, or use **Move** before dragging.
- **Launch** begins flight. Hold **4×** to speed up simulation; release for 1×. Abort returns to editing. Undo restores edits, and Reset clears the board.
- Collect the diamond beacons, avoid solid obstacles and hole cores, then reach the teal dock. The previous flight trail stays visible while planning a retry.
- Help offers a supplied solution and a haptics mute option. VoiceOver provides placement, adjustment, movement, removal, and flight-speed actions. Portrait and landscape share the same game state.

## Project layout

- `Sources/OrbitCore`: physics, campaign state, layout rules, and bundled sectors.
- `Sources/MilkOrbitApp`: UIKit app, rendering, input, haptics, and artwork.
- `Tests/OrbitCoreTests`: core regression tests and reference fixtures.

## Credits and release status

Milk Orbit adapts [Hole Punch](https://notoriousbfg.com/hole-punch/) by notoriousbfg. This checkout is undergoing local release preparation; **redistribution permission for the adapted upstream material remains pending**.

The [MIT license](LICENSE) covers **Milk-owned contributions only**. Upstream code, levels, fixtures, branding, fonts, and other third-party material are subject to their own rights and terms. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for provenance and licensing scope. The bundled Silkscreen font includes its full SIL Open Font License.
