void revivePlexShowPoster(id menu, id list, id path, id title);
void revivePlexCancelPoster(id menu);
void revivePlexClearShelf(id menu);
long revivePlexShelfColumns(id rows);
signed char revivePlexShowShelf(id menu, id rows, long selection, id title);
void revivePlexShowLinkQR(id menu, id list, id rows);
void revivePlexCaptureMenuIfRequested(id menu);
signed char revivePlexShowHomeRails(id menu, id rows, long selection);
signed char revivePlexConsumeNavigationProbe(void);
void revivePlexClearHomeRails(id menu);
void revivePlexCaptureCatalogForProbe(id menu);
void revivePlexCaptureScreenForProbe(id menu, id filename);
void revivePlexWithoutTransitionAnimation(void (^transition)(void));

signed char revivePlexScrollDescription(id menu, int action, int value);

void revivePlexSetSkipHint(id controller, id title);

void revivePlexShowSeekFeedback(id controller, double delta, double position, double duration);

void revivePlexSetOptionsHint(id controller, signed char visible);
