# Dependency and build audit

Audit date: 2026-07-28

## Decisions

| Project | License | BuFi decision |
| --- | --- | --- |
| [SwiftSonic 0.8.3](https://github.com/CassetteLab/swiftsonic) | MIT | Keep and pin. It is a dependency-free, actor-based OpenSubsonic client, and BuFi uses it for authenticated media URLs. |
| [Nuke 13.0.6](https://github.com/kean/Nuke/releases/tag/13.0.6) | MIT | Keep and pin the `Nuke` core product. Remove the unused `NukeUI` product to reduce the build and link graph. |
| [Zstandard 1.5.7](https://github.com/facebook/zstd/releases/tag/v1.5.7) | BSD 3-Clause | Keep and pin. It provides the `libzstd` SwiftPM product used by BuFi's bounded HTTP content decoder. |
| [Amperfy](https://github.com/BLeeEZ/amperfy) | GPLv3 | Continue using selected compatibility and audio-session patterns with attribution. Do not add the complete app as a package. |
| [Cassette](https://github.com/CassetteLab/cassette) | MPL-2.0 for current source | Continue as an architectural reference only. It is an application, not a reusable package required by BuFi. |

The linked packages fit BuFi's iOS 17 floor: SwiftSonic supports iOS 16 and
Swift 5.9+, Nuke 13 supports iOS 15 and is validated for Xcode 26, and zstd's
manifest supports iOS 9. Cassette currently requires iOS 18 and is therefore
not a suitable source-level dependency for BuFi's supported range.

No additional playback framework was added. Replacing the working AVPlayer-based
engine with Cassette's AudioStreaming stack would be a high-risk architectural
migration, not a stabilization change. BuFi already has native format routing,
background playback, route recovery, and compatibility fallback paths.

## Reproducibility

The three linked packages use `exactVersion` constraints in `project.yml`.
XcodeGen generates a new project in CI, so unconstrained `from` requirements
would otherwise allow a new dependency release to enter a build without a BuFi
source change. Updates should be deliberate and validated by both CI jobs.

## Distribution notices

`BuFi/Resources/ThirdPartyLicenses.txt` bundles the verbatim license files from
the pinned SwiftSonic 0.8.3, Nuke 13.0.6, and Zstandard 1.5.7 tags. The
open-source settings screen opens this resource inside the app, satisfying the
linked packages' requirement to reproduce their copyright, permission,
condition, and disclaimer text with a binary distribution.

Cassette remains an architectural reference with no linked or copied source,
and Amperfy is not linked as a third-party binary. Their attribution and
official license links remain in `OPEN_SOURCE_NOTICES.md`; they are intentionally
outside the bundled linked-dependency license file. Amperfy-related GPL
obligations are handled by BuFi's GPLv3-or-later distribution and corresponding
public source. XcodeGen is also excluded from the app bundle because it is only
a build-time project generator.

## Swift and release settings

- The project requires the current stable
  [XcodeGen 2.46.0](https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0).
  It uses the documented `xcode16_3` project format (already present in the
  [2.45.4 ProjectSpec](https://github.com/yonaskolb/XcodeGen/blob/2.45.4/Docs/ProjectSpec.md))
  while recording Xcode 26.6 as the last-upgrade version. Xcode 27 can open and
  build this format without a source migration.
- `SWIFT_VERSION` is `5.0`, which selects the Swift 5 language mode supported by
  current Xcode toolchains. `5.10` is a compiler release number, not a valid
  Xcode language-mode value.
- `SWIFT_STRICT_CONCURRENCY` is `complete`. In Swift 5 mode this surfaces
  potential data races as migration warnings without turning them into Swift 6
  errors.
- Release retains speed optimization, whole-module compilation, documented
  LLVM link-time optimization, dead-code stripping, dSYMs, and disabled
  testability.
- The undocumented user-defined `SWIFT_LTO` setting and the C-only
  `GCC_OPTIMIZATION_LEVEL` override were removed. The app target is Swift, while
  the zstd C target is owned by SwiftPM.
- Release asset catalogs optimize for space.

Apple documents these settings in the
[Xcode build settings reference](https://developer.apple.com/documentation/xcode/build-settings-reference)
and recommends enabling complete concurrency checking before moving a target to
Swift 6 in
[Updating an app to use strict concurrency](https://developer.apple.com/documentation/swift/updating-an-app-to-use-strict-concurrency).

## CI toolchain policy

- The required build uses GitHub's `macos-26` Arm64 runner and Xcode 26.6.
- The Xcode 27 beta build uses GitHub's official `xcode-27` preview label. It is
  advisory because GitHub explicitly warns that preview software and capacity
  can be unstable.
- Xcode 27 logs are uploaded on every run to retain new SDK and compiler
  warnings.
- Pull requests run only the verification workflow; the artifact workflow runs
  after changes reach `main`, avoiding duplicate builds.

Runner availability and installed toolchains are verified against GitHub's
[macOS 26 image manifest](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md),
[Xcode 27 image manifest](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-Readme.md),
and [Xcode 27 public preview announcement](https://github.com/actions/runner-images/issues/14404).

## Energy note

There is no build flag that by itself guarantees lower battery use. Apple's
guidance is to reduce work, redraws, networking, and optional activity, then
measure on a physical device with Power Profiler. Build optimization complements
those runtime changes but does not replace measurement. See
[Reducing your app's battery use](https://developer.apple.com/documentation/xcode/reducing-your-app-s-battery-use)
and
[Analyzing your app's battery use](https://developer.apple.com/documentation/xcode/analyzing-your-app-s-battery-use).
