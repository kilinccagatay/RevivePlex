# Screenshot provenance

The three images in `docs/images` were captured on Apple TV hardware from the
real RevivePlex renderer using an isolated demo build on 22 November 2026.
They are demonstration screens, not a real Plex user's library.

- Titles, dates and collection labels come exclusively from `native/src/DemoGallery.h`.
- Original geometric artwork is drawn by `demoArtwork` in `native/src/Artwork.m`.
- No film/TV imagery, photographs, remote image downloads, personal account
  information, Plex tokens, server names or library metadata were used in these images.
- The normal release binary does not include the demo data or artwork generator.

The original geometric illustrations are dedicated to the public domain under
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/).
To the extent possible under law, the contributors waive copyright and related
rights in those illustrations. This dedication does not extend to third-party
trademarks, operating-system components or fonts. Application code is MIT licensed.

Reproduction: set `REVIVEPLEX_DEMO_SCREENSHOTS=1` when running `native/build.sh`.
The local diagnostic route kind `demo`, with paths `home`, `catalog`, and
`continue`, supplies synthetic rows. Use the existing one-shot screenshot route
mechanism on a development device. Restore a normal build afterwards. Never
capture a personal library for repository documentation.
