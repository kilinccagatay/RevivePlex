// BackRow owns the controller. These functions own and release its player session.
BOOL revivePlexStartPlayback(id controller, NSURL *file);
void revivePlexTogglePlayback(id controller);
void revivePlexSeekPlayback(id controller, double seconds);
void revivePlexStopPlayback(id controller);
NSURL *revivePlexPlaybackFixture(void);
BOOL revivePlexRevealPlaybackControls(id controller);
void revivePlexCycleTrack(id controller, BOOL subtitles);
BOOL revivePlexStartStream(id controller, id request, double resumeAt);
BOOL revivePlexStartHLS(id controller, id url, double resumeAt);
BOOL revivePlexStartSystemHLS(id controller, id url, double resumeAt, id session);
void revivePlexToggleVideoFit(id controller);

signed char revivePlexOpenPlaybackOptions(id player, id route);

// Only acts on sessions explicitly marked as local diagnostics.
void revivePlexFailPlaybackForProbe(id controller);
