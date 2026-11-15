# PlezyVision 1.0.2 — Fire TV trailer lifecycle and About screen

## Fixed: audio from hidden Recommended trailers

**Reproduction before the fix:** In Biblioteca → Películas → Recomendados, focus a film (for example Avatar) until its trailer plays. Navigate to Explorar, open the details of a different film, and return to Explorar. The audio of the earlier Recommended trailer could resume in the background.

**Root cause:** Biblioteca uses a `TabBarView` that keeps its Recommended page alive when another tab is selected. The shared Android Media3/ExoPlayer trailer session can survive a Flutter route or platform-view handoff. Stopping playback only on top-level navigation or a kept-alive tab's `didUpdateWidget` was insufficient: the hidden Recommended spotlight could still own a preview surface and reactivate the session.

**Solution:**
- Explicitly stop the shared trailer when changing main navigation sections and on library-tab controller transitions.
- Stop the session when the Recommended tab is deactivated or its library changes.
- Most importantly, pass `allowTrailerPreview: widget.isActive` from `LibraryRecommendedTab` into `TvSpotlightScaffold`. An inactive Recommended tab can no longer create or keep an active preview surface, even while kept alive.
- Preserve uninterrupted playback for the *same title* while moving between its spotlight and detail page; do not change that established handoff.

**Validation:** Tested by the user on Fire TV: the background trailer audio no longer resumes after returning from Explore details.

## Updated: About PlezyVision

- Compact single-screen Fire TV layout; no scrolling required.
- PlezyVision logo, version and short Git commit.
- Short project introduction and four feature summaries: automatic trailers, visual browsing, media badges, and Fire TV navigation.
- Removed three browser-opening links from the TV UI.
- Attribution to the original Plezy project and GPL-3.0 notice remain visible. Full license and source code remain available in this public repository.

## Compatibility

ARM32 Android/Fire TV APK, signed with the same persistent release key. Intended to update PlezyVision 1.0.1 in place, retaining user settings.

## Credits and license

PlezyVision is an independent fork based on [Plezy by edde746](https://github.com/edde746/plezy), licensed under GNU GPL-3.0. See [LICENSE](../LICENSE) and the source tree for licensing and source availability.
