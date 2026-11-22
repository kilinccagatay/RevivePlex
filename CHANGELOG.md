# Changelog

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
