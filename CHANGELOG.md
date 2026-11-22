# Changelog

## 0.1.3

- Add Settings > About with installed version/build, platform, license and project/support address in all four interface languages.

- Serialize resume, remote seeking and intro/credits skips through one AVPlayer seek queue.
- Remove the independent BackRow startup seek so it cannot overlap the precise resume.
- Retry interrupted seeks with a bounded retry count and retain play/pause intent.

## 0.1.2

- Show a persistent right-hand scroll indicator when content spans multiple screens, including seasons, libraries, cast, search results, settings and home rails.
- Keep card sizes and remote focus behavior unchanged; hide the indicator when all content fits.
- Fall back to the show cast when season or episode metadata has no cast, while preserving episode-specific cast when present.

## 0.1.1

- Resume playback when leaving playback options with Menu/Back, retaining position, selected version and queue.
- Defer the options transition until the native held-Select handler finishes.
- Handle the separate Play/Pause button on movie, episode and series cards; Select still opens details.
- Choose the most recently viewed unfinished episode when several episodes have saved progress.
- Preserve Play/Pause intent during a queued precise seek.


## 0.1.0

- Fix rapid-seek crashes by keeping decorative overlays outside BackRow control traversal.
- Serialize precise 10-second seeks and coalesce rapid taps.
- Keep native play/pause state consistent after seeking.
- Include the device-tested player binary; preserve existing audio and quality preferences.


## 0.1.0-preview.1

Initial private preview: native Apple TV 3 Plex browsing and playback, four
interface languages, compact search, filters, playlists, native player controls,
resume and compatible-source preservation. Includes stable card dimensions,
matching Continue Watching artwork and the Select-hold playback hint.

See `docs/VALIDATION.md` for tested behavior and outstanding limitations.
