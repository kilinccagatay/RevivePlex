# 0.1.0 validation

Test target: AppleTV3,2 / A1469, firmware build 12H1006. This is the initial
release, not a claim of complete Plex feature parity.

## Synchronization validation scope

Audio/video desynchronization was reported again after the initial checks, including
playback from the beginning. Earlier successful samples do not establish a fix.
The revised seek path below passed targeted device checks and owner observation.
Broader source and output testing is still needed; universal synchronization is not claimed.

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

## Rapid seeking crash fix

A device crash during rapid seeking was traced to `-[UIView active]`: BackRow
traversed a UIView-backed decorative overlay as a native control. Player hints
now render to images on delegate-free CALayers. A 48-press alternating seek
burst passed on the physical device without restarting the player process.
The ARMv7 build and host fixture suite passed. Audio/transcode settings were
not changed. The v0.1.0 package includes this fix.

## Post-seek synchronization fix

The owner reproduced lip-sync loss after seeking with the old native trick-play
path. Directional taps now accumulate in 10-second increments and debounce for
400 ms. Only one sample-accurate AVPlayer seek is in flight; subsequent taps
update its pending target. BackRow's playing/paused state is updated together
with its AVPlayer, so the next Select toggle remains consistent.

The owner confirmed lip sync in one tested series with this revision. Two on-device
samples exercise forward/backward seeks and pause/resume. Target/time and
player-state logs are technical checks, not measurements of physical HDMI
audio/video alignment. Broader source/output validation remains open, and
the v0.1.0 downloadable binary includes this revision.

Both sample runs completed: four queued seeks reached their requested targets
within 1 ms in the completion logs, and subsequent timeline checks returned
normal speed. Both Select pause/resume transitions worked. The second sample
held its paused position for the scheduled three seconds; callbacks in the
first sample were delayed, so it only verifies the toggle, not a timed hold.
No crash exception occurred in this run. These measurements concern the player
time/state and must not be interpreted as 1 ms measured A/V output alignment.

## 0.1.1 regression checks

Host fixtures cover movie resume, series episode resolution, the two-second episode
lead-in, most-recently-viewed selection independent of episode order, and options
return preserving position, media version and queue even before menu rows load.
The ARMv7 build, signature and plist checks pass.

An on-device one-shot regression sent Play/Pause on a detail action, opened the
native playback-options entry point, sent Menu/Back, and verified return to the
native player at the saved position with playback running. This checks controller
flow and timeline position; it does not establish new physical lip-sync measurements.
The existing precise seek and server audio settings remain in use.
