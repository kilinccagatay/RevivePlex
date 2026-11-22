# 0.1.0-preview.1 validation

Test target: AppleTV3,2 / A1469, firmware build 12H1006. This is an initial
preview release, not a claim of complete Plex feature parity.

## Reopened blocker

Audio/video desynchronization was reported again after the initial checks, including
playback from the beginning. Earlier successful samples do not establish a fix.
Public-release readiness is blocked pending diagnosis and repeatable validation.

## Passed

- ARMv7 build, ad-hoc signature verification and plist validation.
- Host fixture suite: incompatible host handling, Plex XML/JSON, pagination,
  search filtering, localization, filters/sorting, queue/playlist operations,
  resume decisions and compatible-video preservation.
- Device navigation, direct appliance entry and return focus. Owner confirmed
  old-screen flashing and reopening dismissed sorting menus no longer occur.
- Native full-screen HLS playback. Owner confirmed synchronization in two series,
  both fresh start and selected resume positions. No playback-quality or audio
  preference was changed by the final UI work.
- Continue Watching uses the same backdrop preference as Home and a stable
  landscape grid. Sparse pages no longer stretch cards vertically.
- Native transport controls show a localized Select-hold reminder; it disappears
  when the transport controls hide. Final text uses quotation marks around Select.
- Original synthetic screenshot generation on hardware; images visually reviewed.

## Limits / not claimed as verified

- Long-duration synchronization across every source file and every HDMI/audio
  setup is not guaranteed by the short interactive tests.
- The server prepared HLS samples for 57 format combinations. This is not 57
  complete videos watched on hardware. Very heavy sources may transcode slower
  than real time; optimized versions are preferred when available.
- Real reauthorization after signing out was not repeated, to preserve the active
  user's session. PIN creation/QR and session retention were tested separately.
- No real music library, additional Home profile or TV tuner was available for
  all end-to-end scenarios. Those features remain conditional/experimental.
- Native playback-failure recovery still needs stronger failure-path validation.
- DVR recording completion, offline downloads and Plex Companion are not part
  of the verified first-release scope. Rating UI polish is deferred.
- The app uses private BackRow APIs and is tested only on the stated firmware.

The repository intentionally excludes raw device logs, personal library captures,
credentials, proprietary Apple binaries/SDKs and jailbreak distributions.

## Installer validation

The documented Python installer was exercised on the target device: prerequisite
check, bundle upload, binary SHA256 readback, existing-bundle backup, install and
interface restart passed. The Plex session remained valid. The clean exported
source tree also passed its own host tests and ARMv7 build.
