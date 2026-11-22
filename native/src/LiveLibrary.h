// Implemented in the Foundation module. Results are delivered on the main queue.
id revivePlexLiveHome(void);
id revivePlexSignInRows(id message);
void revivePlexLoadRows(id route, void (^completion)(id rows));
id revivePlexMediaRequest(id path);
id revivePlexArtworkRequest(id path);
id revivePlexPhotoRequest(id path);
id revivePlexStartLink(void (^update)(id), void (^linked)(void));
void revivePlexRefreshHome(void (^completion)(id title, id rows));
signed char revivePlexSignOut(void);
long revivePlexHomeRailTarget(id rows, long selection, int remoteAction);
enum { RevivePlexSearchColumns = 19, RevivePlexSearchResultColumns = 8 };
id revivePlexSearchKeyboard(id query, int numeric, id matches);
id revivePlexSearchRoute(id query);
long revivePlexSearchTarget(id rows, long selected, int action);
id revivePlexEditSearch(id query, id key);
void revivePlexBeginTranscode(id path, id session, void (^completion)(id url));
void revivePlexEndTranscode(id session);
void revivePlexReportProgress(id session, double position, double duration, id state);
void revivePlexApplyMediaAction(id entry, void (^completion)(signed char success));

id revivePlexDiagnosticRoutes(void);

void revivePlexNextEpisode(id session, void (^completion)(id path));

long revivePlexShelfTarget(id rows, long selection, int action, long columns);

id revivePlexAdjacentPhoto(id route, int direction);

id revivePlexServerGeneration(void);

id revivePlexFollowingEpisode(id episodes, id currentKey);

double revivePlexMarkerTarget(id markers, double position, id enabledTypes);
double revivePlexPlaybackSkipTarget(id session, double position);

id revivePlexPlaybackMetadata(id session);

void revivePlexBeginAudioProbe(id path, id session, void (^completion)(id url));

void revivePlexBeginPlaybackRoute(id route, id session, void (^completion)(id url));
void revivePlexContinueQueue(id previousSession, id nextSession);

id revivePlexHomePINRows(id userID, id pin);
id revivePlexEditHomePIN(id rows, id key);

id revivePlexDiscoverSearchRoute(id query);

id revivePlexPlaybackOptionsRoute(id session, double position);

id revivePlexPlaylistNameRows(id source, id query, int numeric);

id revivePlexPlaybackSkipAction(id session, double position);

id revivePlexDVRRows(id response, id dvrID);
long revivePlexPreferredMediaIndex(id parts, id quality);

id revivePlexPrepareFilterRoute(id route);
id revivePlexToggleFilterRows(id rows, id entry);

id revivePlexLocalizedMenuTitle(id route);

signed char revivePlexDiagnosticScreensOnly(void);
