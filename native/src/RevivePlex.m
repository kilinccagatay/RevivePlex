#include "Localization.h"
// First-screen Front Row appliance. BackRow names are checked on the host at load.
#include <syslog.h>
#ifdef REVIVEPLEX_AUTOSTART
#include <dispatch/dispatch.h>
#endif

@class NSString;
#include "MockLibrary.h"
#ifdef REVIVEPLEX_LIVE
#include "LiveLibrary.h"
#ifdef REVIVEPLEX_PLAYBACK
@class NSURL;
typedef signed char BOOL;
#include "Playback.h"
#ifdef REVIVEPLEX_ARTWORK
#include "Artwork.h"
#endif

#endif
#endif

typedef id (*MenuIMP)(id, SEL, ...);
typedef struct objc_method *Method;
struct objc_super { id receiver; Class super_class; };

extern Class objc_getClass(const char *);
extern void objc_setAssociatedObject(id, const void *, id, __UINTPTR_TYPE__);
extern id objc_getAssociatedObject(id, const void *);
extern Protocol *objc_getProtocol(const char *);
extern signed char class_conformsToProtocol(Class, Protocol *);
extern Class objc_allocateClassPair(Class, const char *, __SIZE_TYPE__);
extern void objc_registerClassPair(Class);
extern void objc_disposeClassPair(Class);
extern SEL sel_registerName(const char *);
extern Method class_getInstanceMethod(Class, SEL);
extern Method class_getClassMethod(Class, SEL);
extern const char *class_getName(Class);
extern signed char class_addMethod(Class, SEL, MenuIMP, const char *);
extern MenuIMP method_setImplementation(Method, MenuIMP);
extern MenuIMP method_getImplementation(Method);
extern const char *method_getTypeEncoding(Method);
extern id objc_msgSend(id, SEL, ...);
extern id objc_msgSendSuper(struct objc_super *, SEL, ...);

#define SELECTOR(name) sel_registerName(name)
#define SEND(result, ...) ((result (*)(id, SEL, ##__VA_ARGS__))objc_msgSend)

static Class menuClass;
static Class baseAppliance;
#ifdef REVIVEPLEX_PLAYBACK
static Class baseMenuClass;
#endif
static Class categoryClass;
static Class menuItemClass;
static Class themeClass;
#ifdef REVIVEPLEX_PRODUCTION
static id registeredAppliance;
#endif

static void stage(const char *message)
{
    syslog(LOG_NOTICE, "RevivePlex: %s", message);
}

static id makeObject(Class class)
{
    id object = SEND(id)((id)class, SELECTOR("alloc"));
    return SEND(id)(object, SELECTOR("init"));
}

static id applianceInit(id self, SEL command, id info)
{
    stage("appliance init entered");
    struct objc_super super = {self, baseAppliance};
    id appliance = ((id (*)(struct objc_super *, SEL, id))objc_msgSendSuper)(&super, command, info);
#ifdef REVIVEPLEX_PRODUCTION
    registeredAppliance = appliance;
#endif
    stage(appliance ? "appliance initialized" : "appliance init returned nil");
    return appliance;
}

static id categories(id self, SEL command)
{
    (void)self;
    (void)command;
    stage("categories requested");
    id category = SEND(id, id, id, float)((id)categoryClass,
        SELECTOR("categoryWithName:identifier:preferredOrder:"), @"Plex", @"reviveplex.home", 0.0f);
    if (!category) {
        stage("category factory returned nil");
        return 0;
    }
    if (SEND(signed char, SEL)(category, SELECTOR("respondsToSelector:"), SELECTOR("setIsDefaultCategory:")))
        SEND(void, signed char)(category, SELECTOR("setIsDefaultCategory:"), 1);
    if (SEND(signed char, SEL)(category, SELECTOR("respondsToSelector:"), SELECTOR("setShouldDisplayOnStartup:")))
        SEND(void, signed char)(category, SELECTOR("setShouldDisplayOnStartup:"), 1);
    return SEND(id, id)((id)objc_getClass("NSArray"), SELECTOR("arrayWithObject:"), category);
}

static char screenKey;
#ifdef REVIVEPLEX_LIVE
static char liveRowsKey, linkTaskKey;
#ifdef REVIVEPLEX_PLAYBACK
static char searchTicketKey;
#endif
#ifdef REVIVEPLEX_PRODUCTION
static char sessionRootKey, sessionPendingKey, displayedLanguageKey, displayedServerKey;
static void checkPlexSession(id menu);
#endif
#ifdef REVIVEPLEX_AUTOSTART
static int autoOpened;
#endif

static id valueForKey(id object, id key)
{
    return SEND(id, id)(object, SELECTOR("objectForKey:"), key);
}

static id liveRow(id menu, long row)
{
    id rows = objc_getAssociatedObject(menu, &liveRowsKey);
    if (row < 0 || (__SIZE_TYPE__)row >= SEND(__SIZE_TYPE__)(rows, SELECTOR("count"))) return 0;
    return SEND(id, __SIZE_TYPE__)(rows, SELECTOR("objectAtIndex:"), row);
}
#endif

static const MenuScreen *screenForMenu(id menu)
{
    id number = objc_getAssociatedObject(menu, &screenKey);
    return &mockScreens[SEND(unsigned int)(number, SELECTOR("unsignedIntValue"))];
}

static id makeMenu(Screen screen)
{
    id menu = makeObject(menuClass);
    if (!menu) {
        stage("home controller init returned nil");
        return 0;
    }
    id list = SEND(id)(menu, SELECTOR("list"));
    if (!SEND(signed char, SEL)(list, SELECTOR("respondsToSelector:"), SELECTOR("setDatasource:"))) {
        stage("list datasource setter unavailable");
        SEND(void)(menu, SELECTOR("release"));
        return 0;
    }
    id number = SEND(id, unsigned int)((id)objc_getClass("NSNumber"),
        SELECTOR("numberWithUnsignedInt:"), screen);
    objc_setAssociatedObject(menu, &screenKey, number, 1);
    SEND(void, id)(menu, SELECTOR("setListTitle:"), mockScreens[screen].title);
    SEND(void, id)(list, SELECTOR("setDatasource:"), menu);
    return SEND(id)(menu, SELECTOR("autorelease"));
}

#ifdef REVIVEPLEX_LIVE
static id loadingRows(id title);
static void setLiveRows(id menu, id rows);
static char menuRouteKey;
#ifdef REVIVEPLEX_PLAYBACK
static char playerRouteKey, restoredSelectionKey, transcodeSessionKey, menuPoppedKey, slideshowKey;

static id playbackRow(id title, id action)
{
    return SEND(id, id, id, id, id, id)((id)objc_getClass("NSDictionary"),
        SELECTOR("dictionaryWithObjectsAndKeys:"), title, @"title", action, @"action", 0);
}

static id makePlayerMenu(id route)
{
    id menu = makeMenu(NoScreen);
    if (!menu) return 0;
    if (SEND(signed char, id)(valueForKey(route, @"kind"), SELECTOR("isEqual:"), @"transcode")) {
        objc_setAssociatedObject(menu, &playerRouteKey, route, 1);
        SEND(void, id)(menu, SELECTOR("setListTitle:"), RPText(@"Oynatıcı"));
        setLiveRows(menu, loadingRows(RPText(@"Plex sunucusunda hazırlanıyor…")));
        return menu;
    }
    id rows = SEND(id, id, id, id, id, id, id, id)((id)objc_getClass("NSArray"),
        SELECTOR("arrayWithObjects:"),
        playbackRow(RPText(@"Duraklat / devam et"), @"toggle"),
        playbackRow(RPText(@"15 saniye geri"), @"back"),
        playbackRow(RPText(@"30 saniye ileri"), @"forward"),
        playbackRow(RPText(@"Altyazı parçası"), @"subtitles"),
        playbackRow(RPText(@"Ses parçası"), @"audio"),
        playbackRow(RPText(@"Ekranı doldur / sığdır"), @"videoFit"), 0);
    objc_setAssociatedObject(menu, &playerRouteKey, route, 1);
    objc_setAssociatedObject(menu, &liveRowsKey, rows, 1);
    SEND(void, id)(menu, SELECTOR("setListTitle:"), RPText(@"Oynatıcı"));
    id list = SEND(id)(menu, SELECTOR("list"));
    if (SEND(signed char, SEL)(list, SELECTOR("respondsToSelector:"), SELECTOR("reload")))
        SEND(void)(list, SELECTOR("reload"));
    return menu;
}

static void playerWasPushed(id self, SEL command)
{
    objc_setAssociatedObject(self, &menuPoppedKey, 0, 1);
    struct objc_super super = {self, baseMenuClass};
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&super, command);
    id route = objc_getAssociatedObject(self, &playerRouteKey);
    if (!route) {
#ifdef REVIVEPLEX_PRODUCTION
        if (objc_getAssociatedObject(self, &sessionPendingKey)) {
            objc_setAssociatedObject(self, &sessionPendingKey, 0, 1);
#ifdef REVIVEPLEX_AUTOSTART
            autoOpened = 1;
#endif
            checkPlexSession(self);
        }
#endif
        return;
    }
    if (SEND(signed char, id)(valueForKey(route, @"kind"), SELECTOR("isEqual:"), @"fixture")) {
        revivePlexStartPlayback(self, revivePlexPlaybackFixture());
        return;
    }
    id offset = valueForKey(route, @"resume");
    double resumeAt = SEND(double)(offset, SELECTOR("doubleValue"));
    id path = valueForKey(route, @"path");
    if (SEND(signed char, id)(valueForKey(route, @"kind"), SELECTOR("isEqual:"), @"transcode")) {
        id uuid = SEND(id)((id)objc_getClass("NSUUID"), SELECTOR("UUID"));
        id session = SEND(id)(uuid, SELECTOR("UUIDString"));
        if (!session) return;
        objc_setAssociatedObject(self, &transcodeSessionKey, session, 1);
        SEND(void, id)(self, SELECTOR("setListTitle:"), RPText(@"Plex sunucusunda hazırlanıyor…"));
        revivePlexBeginPlaybackRoute(route, session, ^(id url) {
            if (objc_getAssociatedObject(self, &transcodeSessionKey) != session) {
                revivePlexEndTranscode(session);
                return;
            }
            if (url) {
                objc_setAssociatedObject(self, &transcodeSessionKey, 0, 1);
                id playbackURL = url;
                double startPosition = resumeAt;
                if (SEND(signed char)(valueForKey(route, @"diagnostic"), SELECTOR("boolValue")) &&
                    SEND(signed char)(valueForKey(route, @"localComparison"), SELECTOR("boolValue"))) {
                    playbackURL = SEND(id, id)((id)objc_getClass("NSURL"), SELECTOR("fileURLWithPath:"), @"/var/mobile/Library/Caches/RevivePlex.sync-comparison.mp4");
                    startPosition = 0;
                }
                if (revivePlexStartSystemHLS(self, playbackURL, startPosition, session)) return;
            }
            objc_setAssociatedObject(self, &transcodeSessionKey, 0, 1);
            revivePlexEndTranscode(session);
            setLiveRows(self, loadingRows(url ? RPText(@"Sistem oynatıcısı açılamadı. Geri dönüp yeniden deneyebilirsin.")
                : RPText(@"Plex uyumlu akışı hazırlayamadı. Sunucu bağlantısını ve dönüştürme ayarını kontrol et.")));
        });
        return;
    }
    revivePlexStartStream(self, revivePlexMediaRequest(path), resumeAt);
}

#ifdef REVIVEPLEX_ARTWORK
static void itemSelected(id self, SEL command, long row);
static id makeLiveMenu(id route);
static char quickPlayPendingKey;
static char posterRefreshPendingKey;
static unsigned long posterRefreshSequence;

static signed char updateMediaLayout(id menu, id list)
{
    if (!SEND(signed char, SEL)(list, SELECTOR("respondsToSelector:"), SELECTOR("selection"))) return 0;
    long selected = SEND(long)(list, SELECTOR("selection"));
    if (selected < 0) selected = 0;
    id first = liveRow(menu, 0);
    if (valueForKey(first, @"homeRail"))
        return revivePlexShowHomeRails(menu, objc_getAssociatedObject(menu, &liveRowsKey), selected);
    revivePlexClearHomeRails(menu);
    if (valueForKey(first, @"qr")) {
        revivePlexShowLinkQR(menu, list, objc_getAssociatedObject(menu, &liveRowsKey));
        return 0;
    }
    id entry = liveRow(menu, selected);
#ifdef REVIVEPLEX_SHELVES
    if ((valueForKey(first, @"panel") || valueForKey(entry, @"shelf")) && revivePlexShowShelf(menu,
            objc_getAssociatedObject(menu, &liveRowsKey), selected,
            SEND(id)(menu, SELECTOR("listTitle")))) return 1;
#endif
    revivePlexClearShelf(menu);
    revivePlexShowPoster(menu, list, valueForKey(entry, @"artwork"), valueForKey(entry, @"title"));
    return 0;
}

static long portraitColumn(long selection)
{
    // Exact division by six for a nonnegative 32-bit row index, using a fixed-point reciprocal.
    unsigned long quotient = ((unsigned long long)(unsigned int)selection * 0xaaaaaaabULL) >> 34;
    return selection - (long)(quotient * 6);
}

static void schedulePhotoSlide(id menu, id ticket)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (objc_getAssociatedObject(menu, &slideshowKey) != ticket || objc_getAssociatedObject(menu, &menuPoppedKey)) return;
        id stack = SEND(id)(menu, SELECTOR("stack"));
        if (SEND(id)(stack, SELECTOR("peekController")) != menu) { objc_setAssociatedObject(menu, &slideshowKey, 0, 1); return; }
        id current = objc_getAssociatedObject(menu, &menuRouteKey);
        id next = revivePlexAdjacentPhoto(current, 1);
        if (!next) next = revivePlexAdjacentPhoto(current, -SEND(int)(valueForKey(current, @"photoIndex"), SELECTOR("intValue")));
        if (!next) { objc_setAssociatedObject(menu, &slideshowKey, 0, 1); return; }
        objc_setAssociatedObject(menu, &menuRouteKey, next, 1);
        revivePlexLoadRows(next, ^(id rows) {
            if (objc_getAssociatedObject(menu, &slideshowKey) != ticket || objc_getAssociatedObject(menu, &menuRouteKey) != next || objc_getAssociatedObject(menu, &menuPoppedKey)) return;
            SEND(void, id)(menu, SELECTOR("setListTitle:"), valueForKey(next, @"title"));
            setLiveRows(menu, rows);
            schedulePhotoSlide(menu, ticket);
        });
    });
}

static signed char eventWithPoster(id self, SEL command, id event)
{
    int player = objc_getAssociatedObject(self, &playerRouteKey) != 0;
    id stack = SEND(id)(self, SELECTOR("stack"));
    if (SEND(signed char, SEL)(event, SELECTOR("respondsToSelector:"), SELECTOR("remoteAction")) &&
        SEND(int)(event, SELECTOR("remoteAction")) == 1 &&
        SEND(signed char, SEL)(event, SELECTOR("respondsToSelector:"), SELECTOR("value")) &&
        SEND(signed char, SEL)(stack, SELECTOR("respondsToSelector:"), SELECTOR("peekController")) &&
        SEND(signed char, SEL)(stack, SELECTOR("respondsToSelector:"), SELECTOR("popController")) &&
        SEND(id)(stack, SELECTOR("peekController")) == self) {
        if (SEND(int)(event, SELECTOR("value")) == 1) {
            id currentRoute = objc_getAssociatedObject(self, &menuRouteKey);
            if (SEND(signed char, id)(valueForKey(currentRoute, @"kind"), SELECTOR("isEqual:"), @"playbackOptions") &&
                !valueForKey(currentRoute, @"playbackError")) {
                // Options replace the player. Back means resume, not pop to details.
                id next = makeLiveMenu(revivePlexResumeOptionsRoute(currentRoute));
                if (next) SEND(void, id)(stack, SELECTOR("swapController:"), next);
                return 1;
            }
            id homeList = SEND(id)(self, SELECTOR("list"));
            // Home Back first returns focus to Search; only a second press there exits.
            // Consume the release too, so one press cannot perform both actions.
            if (!player && valueForKey(liveRow(self, 0), @"homeRail") &&
                SEND(signed char, id)(valueForKey(valueForKey(liveRow(self, 0), @"route"), @"kind"),
                    SELECTOR("isEqual:"), @"search") &&
                SEND(long)(homeList, SELECTOR("selection")) != 0) {
                SEND(void, long)(homeList, SELECTOR("setSelection:"), 0);
                updateMediaLayout(self, homeList);
                return 1;
            }
            revivePlexWithoutTransitionAnimation(^{ SEND(void)(stack, SELECTOR("popController")); });
        }
        return 1;
    }
    id list = SEND(id)(self, SELECTOR("list"));
    if (!player && SEND(signed char, SEL)(event, SELECTOR("respondsToSelector:"), SELECTOR("remoteAction")) &&
        SEND(signed char, SEL)(event, SELECTOR("respondsToSelector:"), SELECTOR("value")) &&
        SEND(int)(event, SELECTOR("remoteAction")) == 10) {
        id selectedRoute = valueForKey(liveRow(self, SEND(long)(list, SELECTOR("selection"))), @"route");
        if (revivePlexCanQuickPlay(selectedRoute)) {
            if (SEND(int)(event, SELECTOR("value")) == 1 && !objc_getAssociatedObject(self, &quickPlayPendingKey)) {
                objc_setAssociatedObject(self, &quickPlayPendingKey, selectedRoute, 1);
                revivePlexQuickPlayRoute(selectedRoute, ^(id route) {
                    if (objc_getAssociatedObject(self, &quickPlayPendingKey) != selectedRoute) return;
                    objc_setAssociatedObject(self, &quickPlayPendingKey, 0, 1);
                    if (objc_getAssociatedObject(self, &menuPoppedKey) || SEND(id)(stack, SELECTOR("peekController")) != self) return;
                    id next = route ? makeLiveMenu(route) : 0;
                    if (next) SEND(void, id)(stack, SELECTOR("pushController:"), next);
                });
            }
            return 1;
        }
    }
    if (valueForKey(liveRow(self, 0), @"qr") &&
        SEND(signed char, SEL)(event, SELECTOR("respondsToSelector:"), SELECTOR("remoteAction")) &&
        SEND(signed char, SEL)(event, SELECTOR("respondsToSelector:"), SELECTOR("value"))) {
        int action = SEND(int)(event, SELECTOR("remoteAction"));
        if (action == 5 && SEND(int)(event, SELECTOR("value")) == 1)
            itemSelected(self, SELECTOR("itemSelected:"), 0);
        if (action >= 3 && action <= 7) return 1;
    }
    if (!player && SEND(signed char, SEL)(event, SELECTOR("respondsToSelector:"), SELECTOR("remoteAction")) &&
        SEND(signed char, SEL)(event, SELECTOR("respondsToSelector:"), SELECTOR("value")) &&
        revivePlexScrollDescription(self, SEND(int)(event, SELECTOR("remoteAction")), SEND(int)(event, SELECTOR("value")))) return 1;
    id photoRoute = objc_getAssociatedObject(self, &menuRouteKey);
    if (!player && SEND(signed char, id)(valueForKey(photoRoute, @"kind"), SELECTOR("isEqual:"), @"photo")) {
        int action = SEND(int)(event, SELECTOR("remoteAction"));
        if (action == 5) {
            if (SEND(int)(event, SELECTOR("value")) != 1) return 1;
            if (objc_getAssociatedObject(self, &slideshowKey)) objc_setAssociatedObject(self, &slideshowKey, 0, 1);
            else if (SEND(unsigned long)(valueForKey(photoRoute, @"gallery"), SELECTOR("count")) > 1) {
                id ticket = SEND(id)((id)objc_getClass("NSObject"), SELECTOR("new"));
                objc_setAssociatedObject(self, &slideshowKey, ticket, 1);
                schedulePhotoSlide(self, ticket); SEND(void)(ticket, SELECTOR("release"));
            }
            return 1;
        }
        if (action == 6 || action == 7) {
            if (SEND(int)(event, SELECTOR("value")) != 1) return 1;
            objc_setAssociatedObject(self, &slideshowKey, 0, 1);
            id nextPhoto = revivePlexAdjacentPhoto(photoRoute, action == 6 ? -1 : 1);
            if (!nextPhoto) return 1;
            objc_setAssociatedObject(self, &menuRouteKey, nextPhoto, 1);
            revivePlexLoadRows(nextPhoto, ^(id rows) {
                if (objc_getAssociatedObject(self, &menuRouteKey) != nextPhoto || objc_getAssociatedObject(self, &menuPoppedKey)) return;
                SEND(void, id)(self, SELECTOR("setListTitle:"), valueForKey(nextPhoto, @"title"));
                setLiveRows(self, rows);
            });
            return 1;
        }
    }
    int homeRails = valueForKey(liveRow(self, 0), @"homeRail") != 0;
#ifdef REVIVEPLEX_SHELVES
    int visualMenu = 1;
#else
    int visualMenu = homeRails;
#endif
    if (!player && visualMenu && updateMediaLayout(self, list) &&
        SEND(signed char, SEL)(list, SELECTOR("respondsToSelector:"), SELECTOR("setSelection:")) &&
        SEND(signed char, SEL)(event, SELECTOR("respondsToSelector:"), SELECTOR("remoteAction")) &&
        SEND(signed char, SEL)(event, SELECTOR("respondsToSelector:"), SELECTOR("value"))) {
        // BackRow directional constants are corroborated by the 12H1006 BREvent mask.
        int action = SEND(int)(event, SELECTOR("remoteAction"));
        long selected = SEND(long)(list, SELECTOR("selection"));
        if (selected < 0) selected = 0;
        long target = selected;
        long columns = 4;
#ifdef REVIVEPLEX_SHELVES
        if (!homeRails) columns = revivePlexShelfColumns(objc_getAssociatedObject(self, &liveRowsKey));
#endif
        long column = columns == 1 ? 0 : (columns == 2 ? selected % 2 : (columns == 6 ? portraitColumn(selected) : selected % 4));
        switch (action) {
            case 3: target -= columns; break;
            case 4: target += columns; break;
            case 6: if (column > 0) target--; break;
            case 7: if (column < columns - 1) target++; break;
            case 5:
                if (SEND(int)(event, SELECTOR("value")) == 1)
                    itemSelected(self, SELECTOR("itemSelected:"), selected);
                return 1;
        }
        if (action == 3 || action == 4 || action == 6 || action == 7) {
            if (valueForKey(liveRow(self, 0), @"searchKeyCount"))
                target = revivePlexSearchTarget(objc_getAssociatedObject(self, &liveRowsKey), selected, action);
            else if (valueForKey(liveRow(self, 0), @"toolbarCount")) target = revivePlexShelfTarget(
                objc_getAssociatedObject(self, &liveRowsKey), selected, action, columns);
            else if (homeRails) target = revivePlexHomeRailTarget(
                objc_getAssociatedObject(self, &liveRowsKey), selected, action);
            if (target != selected && SEND(int)(event, SELECTOR("value")) == 1 && liveRow(self, target)) {
                if (valueForKey(liveRow(self, 0), @"panel") &&
                    !SEND(signed char, long)(self, SELECTOR("rowSelectable:"), target)) return 1;
                SEND(void, long)(list, SELECTOR("setSelection:"), target);
                updateMediaLayout(self, list);
            }
            return 1;
        }
    }
#ifdef REVIVEPLEX_AUTOSTART
    if (!player && !homeRails &&
        SEND(signed char, SEL)(event, SELECTOR("respondsToSelector:"), SELECTOR("isDirectionalEvent")) &&
        SEND(signed char)(event, SELECTOR("isDirectionalEvent"))) {
        id ticket = SEND(id, unsigned long)((id)objc_getClass("NSNumber"),
            SELECTOR("numberWithUnsignedLong:"), ++posterRefreshSequence);
        objc_setAssociatedObject(self, &posterRefreshPendingKey, ticket, 1);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * (int64_t)NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{
            if (objc_getAssociatedObject(self, &posterRefreshPendingKey) != ticket) return;
            objc_setAssociatedObject(self, &posterRefreshPendingKey, 0, 1);
            id stack = SEND(id)(self, SELECTOR("stack"));
            if (SEND(signed char, SEL)(stack, SELECTOR("respondsToSelector:"), SELECTOR("peekController")) &&
                SEND(id)(stack, SELECTOR("peekController")) == self)
                updateMediaLayout(self, SEND(id)(self, SELECTOR("list")));
        });
    }
#endif
    struct objc_super super = {self, baseMenuClass};
    return ((signed char (*)(struct objc_super *, SEL, id))objc_msgSendSuper)(&super, command, event);
}
#endif

static void menuControlActivated(id self, SEL command)
{
    struct objc_super super = {self, baseMenuClass};
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&super, command);
    id previous = objc_getAssociatedObject(self, &restoredSelectionKey);
    long row = SEND(long)(previous, SELECTOR("longValue"));
    objc_setAssociatedObject(self, &restoredSelectionKey, 0, 1);
    id list = SEND(id)(self, SELECTOR("list"));
    if (previous && liveRow(self, row) && SEND(signed char, SEL)(list, SELECTOR("respondsToSelector:"), SELECTOR("setSelection:")))
        SEND(void, long)(list, SELECTOR("setSelection:"), row);
#ifdef REVIVEPLEX_ARTWORK
    updateMediaLayout(self, list);
#endif
    id source = objc_getAssociatedObject(self, &menuRouteKey);
    int languageChanged = 0;
#ifdef REVIVEPLEX_PRODUCTION
    id oldLanguage = objc_getAssociatedObject(self, &displayedLanguageKey);
    languageChanged = source && oldLanguage && !SEND(signed char, id)(oldLanguage, SELECTOR("isEqual:"), revivePlexLanguage());
    if (languageChanged) SEND(void, id)(self, SELECTOR("setListTitle:"), revivePlexLocalizedMenuTitle(source));
#endif
    if ((previous || languageChanged) && (languageChanged || valueForKey(source, @"filterState") || SEND(signed char, id)(valueForKey(source, @"kind"), SELECTOR("isEqual:"), @"detail") ||
        SEND(signed char, id)(valueForKey(source, @"kind"), SELECTOR("isEqual:"), @"watchlist") ||
        (SEND(signed char, id)(valueForKey(source, @"kind"), SELECTOR("isEqual:"), @"media") && SEND(signed char, id)(valueForKey(source, @"path"), SELECTOR("hasPrefix:"), @"/playlists")) ||
        SEND(signed char, id)(valueForKey(source, @"kind"), SELECTOR("isEqual:"), @"recordingRules") ||
        SEND(signed char, id)(valueForKey(source, @"kind"), SELECTOR("isEqual:"), @"recordingSchedule") ||
        SEND(signed char, id)(valueForKey(source, @"kind"), SELECTOR("isEqual:"), @"playlistEdit") ||
        SEND(signed char, id)(valueForKey(source, @"kind"), SELECTOR("isEqual:"), @"queueEdit") ||
        SEND(signed char, id)(valueForKey(source, @"kind"), SELECTOR("isEqual:"), @"queueItems") ||
        SEND(signed char, id)(valueForKey(source, @"kind"), SELECTOR("isEqual:"), @"playlistManage") ||
        SEND(signed char, id)(valueForKey(source, @"kind"), SELECTOR("isEqual:"), @"playlistPicker") ||
        SEND(signed char, id)(valueForKey(source, @"kind"), SELECTOR("isEqual:"), @"streams") ||
        SEND(signed char, id)(valueForKey(source, @"kind"), SELECTOR("isEqual:"), @"cloudItem"))) {
        id focusedTitle = valueForKey(liveRow(self, row), @"title");
        revivePlexLoadRows(source, ^(id rows) {
            id stack = SEND(id)(self, SELECTOR("stack"));
            if (objc_getAssociatedObject(self, &menuPoppedKey) || SEND(id)(stack, SELECTOR("peekController")) != self) return;
            setLiveRows(self, rows);
            long target = languageChanged && liveRow(self, row) ? row : 0;
            for (long index = 0; !languageChanged && liveRow(self, index); index++)
                if (SEND(signed char, id)(valueForKey(liveRow(self, index), @"title"), SELECTOR("isEqual:"), focusedTitle)) { target = index; break; }
            SEND(void, long)(list, SELECTOR("setSelection:"), target);
#ifdef REVIVEPLEX_ARTWORK
            updateMediaLayout(self, list);
#endif
        });
    }
#ifdef REVIVEPLEX_PRODUCTION
    id language = objc_getAssociatedObject(self, &displayedLanguageKey);
    if (objc_getAssociatedObject(self, &sessionRootKey) && language &&
        (!SEND(signed char, id)(language, SELECTOR("isEqual:"), revivePlexLanguage()) ||
         !SEND(signed char, id)(objc_getAssociatedObject(self, &displayedServerKey), SELECTOR("isEqual:"), revivePlexServerGeneration())))
        checkPlexSession(self);
#endif
}

static void playerWasPopped(id self, SEL command)
{
    objc_setAssociatedObject(self, &menuPoppedKey, @"popped", 1);
    objc_setAssociatedObject(self, &searchTicketKey, 0, 1);
    SEND(void)(objc_getAssociatedObject(self, &linkTaskKey), SELECTOR("cancel"));
    objc_setAssociatedObject(self, &linkTaskKey, 0, 1);
#ifdef REVIVEPLEX_ARTWORK
    revivePlexCancelPoster(self);
    revivePlexClearShelf(self);
    revivePlexClearHomeRails(self);
#endif
    if (objc_getAssociatedObject(self, &playerRouteKey)) {
        objc_setAssociatedObject(self, &playerRouteKey, 0, 1);
        revivePlexStopPlayback(self);
        revivePlexEndTranscode(objc_getAssociatedObject(self, &transcodeSessionKey));
        objc_setAssociatedObject(self, &transcodeSessionKey, 0, 1);
    }
    struct objc_super super = {self, baseMenuClass};
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&super, command);
}
#endif

static id loadingRows(id title)
{
    id objects[] = {title, @"yes", @"yes"};
    id keys[] = {@"title", @"shelf", @"shelfLoading"};
    id entry = SEND(id, const id *, const id *, unsigned long)((id)objc_getClass("NSDictionary"),
        SELECTOR("dictionaryWithObjects:forKeys:count:"), objects, keys, 3);
    return SEND(id, id)((id)objc_getClass("NSArray"), SELECTOR("arrayWithObject:"), entry);
}

static void setLiveRows(id menu, id rows)
{
#ifdef REVIVEPLEX_PLAYBACK
    if (objc_getAssociatedObject(menu, &menuPoppedKey)) return;
#endif
    objc_setAssociatedObject(menu, &liveRowsKey, rows, 1);
#ifdef REVIVEPLEX_PRODUCTION
    if (!objc_getAssociatedObject(menu, &sessionRootKey)) objc_setAssociatedObject(menu, &displayedLanguageKey, revivePlexLanguage(), 1);
#endif
    id list = SEND(id)(menu, SELECTOR("list"));
    if (SEND(signed char, SEL)(list, SELECTOR("respondsToSelector:"), SELECTOR("reload"))) {
        SEND(void)(list, SELECTOR("reload"));
        long toolbar = SEND(long)(valueForKey(liveRow(menu, 0), @"toolbarCount"), SELECTOR("longValue"));
        if (toolbar > 0 && SEND(signed char, SEL)(list, SELECTOR("respondsToSelector:"), SELECTOR("setSelection:")))
            SEND(void, long)(list, SELECTOR("setSelection:"), toolbar);
#ifdef REVIVEPLEX_ARTWORK
        updateMediaLayout(menu, list);
        if (valueForKey(liveRow(menu, 0), @"shelf"))
            revivePlexCaptureMenuIfRequested(menu);
#endif
    }
}

#ifdef REVIVEPLEX_PRODUCTION
static void applyPlexSession(id menu, id title, id rows)
{
    if (objc_getAssociatedObject(menu, &menuPoppedKey)) return;
    objc_setAssociatedObject(menu, &displayedLanguageKey, revivePlexLanguage(), 1);
    objc_setAssociatedObject(menu, &displayedServerKey, revivePlexServerGeneration(), 1);
    if (SEND(signed char, id)(title, SELECTOR("isEqual:"), RPText(@"Plex Kütüphanesi")))
        stage("startup session verified");
    else if (SEND(signed char, id)(title, SELECTOR("isEqual:"), RPText(@"Plex Oturumu")))
        stage("startup awaiting Plex sign-in");
    else
        stage("startup Plex connection unavailable");
    SEND(void, id)(menu, SELECTOR("setListTitle:"), title);
    setLiveRows(menu, rows);
#ifdef REVIVEPLEX_ARTWORK
#ifdef REVIVEPLEX_AUTOSTART
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * (int64_t)NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{
        id stack = SEND(id)(menu, SELECTOR("stack"));
        if (!objc_getAssociatedObject(menu, &menuPoppedKey) &&
            SEND(id)(stack, SELECTOR("peekController")) == menu)
            updateMediaLayout(menu, SEND(id)(menu, SELECTOR("list")));
    });
#endif
    revivePlexCaptureMenuIfRequested(menu);
#endif
}

static void checkPlexSession(id menu)
{
    revivePlexRefreshHome(^(id title, id rows) {
        applyPlexSession(menu, title, rows);
    });
}

static void returnToSessionHome(id menu)
{
    id stack = SEND(id)(menu, SELECTOR("stack"));
    if (SEND(signed char, SEL)(stack, SELECTOR("respondsToSelector:"), SELECTOR("controllers")) &&
        SEND(signed char, SEL)(stack, SELECTOR("respondsToSelector:"), SELECTOR("popToController:"))) {
        id list = SEND(id)(stack, SELECTOR("controllers"));
        __SIZE_TYPE__ count = SEND(__SIZE_TYPE__)(list, SELECTOR("count"));
        for (__SIZE_TYPE__ index = 0; index < count; index++) {
            id root = SEND(id, __SIZE_TYPE__)(list, SELECTOR("objectAtIndex:"), index);
            if (objc_getAssociatedObject(root, &sessionRootKey)) {
                setLiveRows(root, loadingRows(RPText(@"Oturum doğrulanıyor…")));
                revivePlexWithoutTransitionAnimation(^{ SEND(void, id)(stack, SELECTOR("popToController:"), root); });
                checkPlexSession(root);
                return;
            }
        }
    }
    checkPlexSession(menu);
}

static void signOutAndReturn(id menu)
{
    if (!revivePlexSignOut()) { setLiveRows(menu, loadingRows(RPText(@"Oturum kapatılamadı"))); return; }
    returnToSessionHome(menu);
}
#endif

static void startPlexLink(id menu)
{
    SEND(void)(objc_getAssociatedObject(menu, &linkTaskKey), SELECTOR("cancel"));
    SEND(void, id)(menu, SELECTOR("setListTitle:"), RPText(@"Plex Etkinleştirme"));
    setLiveRows(menu, loadingRows(RPText(@"Etkinleştirme kodu alınıyor…")));
    id task = revivePlexStartLink(^(id rows) {
        setLiveRows(menu, rows);
    }, ^{
#ifdef REVIVEPLEX_PRODUCTION
        checkPlexSession(menu);
#else
        setLiveRows(menu, revivePlexLiveHome());
#endif
    });
    objc_setAssociatedObject(menu, &linkTaskKey, task, 1);
}

static id makeLiveMenu(id route)
{
    route = revivePlexPrepareFilterRoute(route);
#ifdef REVIVEPLEX_PLAYBACK
    id kind = valueForKey(route, @"kind");
    if (SEND(signed char, id)(kind, SELECTOR("isEqual:"), @"play") ||
        SEND(signed char, id)(kind, SELECTOR("isEqual:"), @"transcode") ||
        SEND(signed char, id)(kind, SELECTOR("isEqual:"), @"fixture"))
        return makePlayerMenu(route);
#endif
    id menu = makeMenu(NoScreen);
    if (!menu) return 0;
    objc_setAssociatedObject(menu, &menuRouteKey, route, 1);
    id title = route ? revivePlexLocalizedMenuTitle(route) : RPText(@"Plex Kütüphanesi");
    SEND(void, id)(menu, SELECTOR("setListTitle:"), title);
    if (!route) {
#ifdef REVIVEPLEX_PRODUCTION
        objc_setAssociatedObject(menu, &sessionRootKey, @"root", 1);
        objc_setAssociatedObject(menu, &sessionPendingKey, @"pending", 1);
        setLiveRows(menu, loadingRows(RPText(@"Oturum doğrulanıyor…")));
#else
        setLiveRows(menu, revivePlexLiveHome());
#endif
    } else if (SEND(signed char, id)(valueForKey(route, @"kind"), SELECTOR("isEqual:"), @"link")) {
        startPlexLink(menu);
    } else {
        setLiveRows(menu, loadingRows(RPText(@"Yükleniyor…")));
        revivePlexLoadRows(route, ^(id rows) { setLiveRows(menu, rows); });
    }
    return menu;
}
#endif

signed char revivePlexOpenPlaybackOptions(id player, id route)
{
#ifdef REVIVEPLEX_LIVE
    if (!route) return 0;
    id stack = SEND(id)(player, SELECTOR("stack"));
    if (!SEND(signed char, SEL)(stack, SELECTOR("respondsToSelector:"), SELECTOR("swapController:")) ||
        SEND(id)(stack, SELECTOR("peekController")) != player) return 0;
    id menu = makeLiveMenu(route);
    if (!menu) return 0;
#ifdef REVIVEPLEX_ARTWORK
    revivePlexWithoutTransitionAnimation(^{ SEND(void, id)(stack, SELECTOR("swapController:"), menu); });
#else
    SEND(void, id)(stack, SELECTOR("swapController:"), menu);
#endif
    return 1;
#else
    (void)player; (void)route; return 0;
#endif
}

static id controller(id self, SEL command, id identifier, id args)
{
    (void)self;
    (void)command;
    (void)args;
    if (!SEND(signed char, id)(identifier, SELECTOR("isEqual:"), @"reviveplex.home")) return 0;
#ifdef REVIVEPLEX_PRODUCTION
#ifdef REVIVEPLEX_AUTOSTART
    autoOpened = 1;
#endif
    return makeLiveMenu(0);
#else
    return makeMenu(Home);
#endif
}

#ifdef REVIVEPLEX_PRODUCTION
static id applianceController(id self, SEL command)
{
    (void)self;
    (void)command;
    stage("direct appliance controller requested");
    return makeLiveMenu(0);
}

static signed char isPlexMerchant(id merchant)
{
    if (SEND(signed char, SEL)(merchant, SELECTOR("respondsToSelector:"), SELECTOR("legacyApplianceClass")) &&
        SEND(Class)(merchant, SELECTOR("legacyApplianceClass")) == objc_getClass("RevivePlexAppliance")) return 1;
    id instance = SEND(id)(merchant, SELECTOR("applianceInstance"));
    return instance && SEND(signed char, Class)(instance, SELECTOR("isKindOfClass:"), objc_getClass("RevivePlexAppliance"));
}
static MenuIMP originalLegacyRoot;
static id legacyRootController(id self, SEL command)
{
    if (isPlexMerchant(self)) {
        stage("legacy launcher opened Plex directly");
        return makeLiveMenu(0);
    }
    return originalLegacyRoot ? originalLegacyRoot(self, command) : 0;
}

static void installLegacyEntryBridge(void)
{
    Class legacy = objc_getClass("BLAppLegacyMerchant");
    Method method = legacy ? class_getInstanceMethod(legacy, SELECTOR("rootController")) : 0;
    if (method && class_getInstanceMethod(legacy, SELECTOR("applianceInstance")) && !originalLegacyRoot) {
        originalLegacyRoot = method_getImplementation(method);
        if (!class_addMethod(legacy, SELECTOR("rootController"), (MenuIMP)legacyRootController,
                method_getTypeEncoding(method)))
            method_setImplementation(method, (MenuIMP)legacyRootController);
        stage("Plex legacy entry bridge installed");
    }
}
#endif

static long itemCount(id self, SEL command)
{
    (void)command;
    const MenuScreen *screen = screenForMenu(self);
#ifdef REVIVEPLEX_LIVE
    id rows = objc_getAssociatedObject(self, &liveRowsKey);
    if (rows) return SEND(long)(rows, SELECTOR("count"));
    if (screen == &mockScreens[Home]) return screen->count + 1;
#endif
    return screen->count;
}

static signed char rowSelectable(id self, SEL command, long row)
{
    (void)command;
    const MenuScreen *screen = screenForMenu(self);
#ifdef REVIVEPLEX_LIVE
    if (objc_getAssociatedObject(self, &liveRowsKey)) {
        id entry = liveRow(self, row);
        return valueForKey(entry, @"route") || valueForKey(entry, @"action");
    }
    if (screen == &mockScreens[Home] && row == screen->count) return 1;
#endif
    return row >= 0 && row < screen->count && screen->rows[row].destination != NoScreen;
}

static float heightForRow(id self, SEL command, long row)
{
    return row >= 0 && row < itemCount(self, command) ? 48.0f : 0.0f;
}

static id titleForRow(id self, SEL command, long row)
{
    if (row < 0 || row >= itemCount(self, command)) return 0;
    const MenuScreen *screen = screenForMenu(self);
#ifdef REVIVEPLEX_LIVE
    if (objc_getAssociatedObject(self, &liveRowsKey)) return valueForKey(liveRow(self, row), @"title");
    if (screen == &mockScreens[Home] && row == screen->count) return RPText(@"Plex Sunucusu");
#endif
    return screen->rows[row].title;
}

static id itemForRow(id self, SEL command, long row)
{
    id title = titleForRow(self, command, row);
    if (!title) return 0;
    id item = makeObject(menuItemClass);
    id theme = SEND(id)((id)themeClass, SELECTOR("sharedTheme"));
    id attributes = SEND(id)(theme, SELECTOR("menuItemTextAttributes"));
    SEND(void, id, id)(item, SELECTOR("setText:withAttributes:"),
        title, attributes);
    return SEND(id)(item, SELECTOR("autorelease"));
}

static id controlAtIndex(id self, SEL command, long row, id requester)
{
    (void)requester;
    return itemForRow(self, command, row);
}

#ifdef REVIVEPLEX_PLAYBACK
static void setSearchRows(id menu, id query, int numeric, id matches, long selection)
{
    setLiveRows(menu, revivePlexSearchKeyboard(query, numeric, matches));
    id list = SEND(id)(menu, SELECTOR("list"));
    if (SEND(signed char, SEL)(list, SELECTOR("respondsToSelector:"), SELECTOR("setSelection:")))
        SEND(void, long)(list, SELECTOR("setSelection:"), selection);
#ifdef REVIVEPLEX_ARTWORK
    updateMediaLayout(menu, list);
#endif
}

static void refreshSearch(id menu, id query, int numeric, long selection)
{
    id editorSource = objc_getAssociatedObject(menu, &menuRouteKey);
    if (SEND(signed char, id)(valueForKey(editorSource, @"kind"), SELECTOR("isEqual:"), @"playlistName")) {
        setLiveRows(menu, revivePlexPlaylistNameRows(editorSource, query, numeric));
        id list = SEND(id)(menu, SELECTOR("list")); SEND(void, long)(list, SELECTOR("setSelection:"), selection);
#ifdef REVIVEPLEX_ARTWORK
        updateMediaLayout(menu, list);
#endif
        return;
    }
    id ticket = SEND(id)((id)objc_getClass("NSObject"), SELECTOR("new"));
    objc_setAssociatedObject(menu, &searchTicketKey, ticket, 1);
    SEND(void)(ticket, SELECTOR("autorelease"));
    setSearchRows(menu, query, numeric, 0, selection);
    id source = objc_getAssociatedObject(menu, &menuRouteKey);
    id route = SEND(signed char, id)(valueForKey(source, @"kind"), SELECTOR("isEqual:"), @"discoverSearch") ? revivePlexDiscoverSearchRoute(query) : revivePlexSearchRoute(query);
    if (!route) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * (int64_t)NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{
        if (objc_getAssociatedObject(menu, &searchTicketKey) != ticket) return;
        revivePlexLoadRows(route, ^(id matches) {
            if (objc_getAssociatedObject(menu, &searchTicketKey) != ticket) return;
            objc_setAssociatedObject(menu, &searchTicketKey, 0, 1);
            long focus = SEND(long)(SEND(id)(menu, SELECTOR("list")), SELECTOR("selection"));
            setSearchRows(menu, query, numeric, matches, focus < 0 ? selection : focus);
        });
    });
}
#endif

static void itemSelected(id self, SEL command, long row)
{
    if (!rowSelectable(self, command, row)) return;
#ifdef REVIVEPLEX_PLAYBACK
    id action = valueForKey(liveRow(self, row), @"action");
    if (action) {
        if (SEND(signed char, id)(action, SELECTOR("isEqual:"), @"clearFilters")) {
            revivePlexToggleFilterRows(objc_getAssociatedObject(self, &liveRowsKey), liveRow(self, row));
            revivePlexLoadRows(objc_getAssociatedObject(self, &menuRouteKey), ^(id rows) {
                if (objc_getAssociatedObject(self, &menuPoppedKey)) return;
                setLiveRows(self, rows);
                id list = SEND(id)(self, SELECTOR("list"));
                SEND(void, long)(list, SELECTOR("setSelection:"), row);
#ifdef REVIVEPLEX_ARTWORK
                updateMediaLayout(self, list);
#endif
            }); return;
        }
        if (SEND(signed char, id)(action, SELECTOR("isEqual:"), @"toggleFilter")) {
            id rows = revivePlexToggleFilterRows(objc_getAssociatedObject(self, &liveRowsKey), liveRow(self, row));
            setLiveRows(self, rows);
            id list = SEND(id)(self, SELECTOR("list"));
            SEND(void, long)(list, SELECTOR("setSelection:"), row);
#ifdef REVIVEPLEX_ARTWORK
            updateMediaLayout(self, list);
#endif
            return;
        }
        if (SEND(signed char, id)(action, SELECTOR("isEqual:"), @"homePinKey")) {
            id rows = revivePlexEditHomePIN(objc_getAssociatedObject(self, &liveRowsKey), valueForKey(liveRow(self, row), @"searchKey"));
            setLiveRows(self, rows);
            id list = SEND(id)(self, SELECTOR("list")); SEND(void, long)(list, SELECTOR("setSelection:"), row);
#ifdef REVIVEPLEX_ARTWORK
            updateMediaLayout(self, list);
#endif
            return;
        }
        if (SEND(signed char, id)(action, SELECTOR("isEqual:"), @"setSort") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"setRecordingPreference") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"deleteRecordingRule") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"createRecording") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"deletePlaylist") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"removePlaylistItem") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"movePlaylistItem") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"moveQueueItem") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"removeQueueItem") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"renamePlaylist") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"createPlaylist") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"addPlaylistItem") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"setHomeUser") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"downloadSubtitle") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"setStream") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"setQuality") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"setLanguage") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"setAutoplay") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"setPreserveVideo") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"setSkipMarker") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"setServer") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"setRating") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"watchlist") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"watched")) {
            id selectedAction = SEND(id)(SEND(id)(liveRow(self, row), SELECTOR("retain")), SELECTOR("autorelease"));
            if (SEND(signed char, id)(action, SELECTOR("isEqual:"), @"setServer"))
                setLiveRows(self, loadingRows(RPText(@"Sunucuya bağlanılıyor…")));
            if (SEND(signed char, id)(action, SELECTOR("isEqual:"), @"downloadSubtitle"))
                setLiveRows(self, loadingRows(RPText(@"Altyazı indiriliyor…")));
            if (SEND(signed char, id)(action, SELECTOR("isEqual:"), @"setSort") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"setRecordingPreference") ||
                SEND(signed char, id)(action, SELECTOR("isEqual:"), @"deleteRecordingRule") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"createRecording") ||
                SEND(signed char, id)(action, SELECTOR("isEqual:"), @"deletePlaylist") ||
                SEND(signed char, id)(action, SELECTOR("isEqual:"), @"removePlaylistItem") ||
                SEND(signed char, id)(action, SELECTOR("isEqual:"), @"movePlaylistItem") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"moveQueueItem") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"removeQueueItem") ||
                SEND(signed char, id)(action, SELECTOR("isEqual:"), @"setHomeUser") ||
                SEND(signed char, id)(action, SELECTOR("isEqual:"), @"createPlaylist") ||
                SEND(signed char, id)(action, SELECTOR("isEqual:"), @"addPlaylistItem") ||
                SEND(signed char, id)(action, SELECTOR("isEqual:"), @"renamePlaylist"))
                setLiveRows(self, loadingRows(RPText(@"Kaydediliyor…")));
            revivePlexApplyMediaAction(selectedAction, ^(signed char success) {
                id stack = SEND(id)(self, SELECTOR("stack"));
                if (SEND(id)(stack, SELECTOR("peekController")) != self) return;
#ifdef REVIVEPLEX_PRODUCTION
                if (success && SEND(signed char, id)(action, SELECTOR("isEqual:"), @"setHomeUser")) { returnToSessionHome(self); return; }
#endif
                if (success && (SEND(signed char, id)(action, SELECTOR("isEqual:"), @"setLanguage") ||
                    SEND(signed char, id)(action, SELECTOR("isEqual:"), @"setPreserveVideo") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"setSkipMarker") ||
                    SEND(signed char, id)(action, SELECTOR("isEqual:"), @"setAutoplay"))) {
                    id source = objc_getAssociatedObject(self, &menuRouteKey);
                    SEND(void, id)(self, SELECTOR("setListTitle:"), revivePlexLocalizedMenuTitle(source));
                    revivePlexLoadRows(source, ^(id rows) {
                        if (objc_getAssociatedObject(self, &menuPoppedKey) || SEND(id)(stack, SELECTOR("peekController")) != self) return;
                        setLiveRows(self, rows);
                        id list = SEND(id)(self, SELECTOR("list"));
                        SEND(void, long)(list, SELECTOR("setSelection:"), row);
#ifdef REVIVEPLEX_ARTWORK
                        updateMediaLayout(self, list);
#endif
                    });
                } else if (success && (SEND(signed char, id)(action, SELECTOR("isEqual:"), @"watched") ||
                    SEND(signed char, id)(action, SELECTOR("isEqual:"), @"watchlist"))) {
                    id source = objc_getAssociatedObject(self, &menuRouteKey);
                    revivePlexLoadRows(source, ^(id rows) {
                        if (objc_getAssociatedObject(self, &menuPoppedKey) || SEND(id)(stack, SELECTOR("peekController")) != self) return;
                        setLiveRows(self, rows);
                        id list = SEND(id)(self, SELECTOR("list"));
                        if (liveRow(self, row)) SEND(void, long)(list, SELECTOR("setSelection:"), row);
#ifdef REVIVEPLEX_ARTWORK
                        updateMediaLayout(self, list);
#endif
                    });
                } else if (success) revivePlexWithoutTransitionAnimation(^{
                    SEND(void)(stack, SELECTOR("popController"));
                    if (SEND(signed char, id)(action, SELECTOR("isEqual:"), @"downloadSubtitle")) SEND(void)(stack, SELECTOR("popController"));
                    if (SEND(signed char, id)(action, SELECTOR("isEqual:"), @"deleteRecordingRule")) SEND(void)(stack, SELECTOR("popController"));
                    if (SEND(signed char, id)(action, SELECTOR("isEqual:"), @"deletePlaylist")) { SEND(void)(stack, SELECTOR("popController")); SEND(void)(stack, SELECTOR("popController")); }
                });
                else setLiveRows(self, loadingRows(RPText(@"Değişiklik kaydedilemedi. Geri dönüp yeniden deneyebilirsin.")));
            });
            return;
        }
        int mode = SEND(signed char, id)(action, SELECTOR("isEqual:"), @"searchMode");
        if (SEND(signed char, id)(action, SELECTOR("isEqual:"), @"keyboardLanguage")) {
            revivePlexToggleKeyboardLanguage();
            id first = liveRow(self, 0);
            refreshSearch(self, valueForKey(first, @"searchText"),
                SEND(int)(valueForKey(first, @"searchNumeric"), SELECTOR("intValue")), 0);
            return;
        }
        if (mode || SEND(signed char, id)(action, SELECTOR("isEqual:"), @"searchKey")) {
            id first = liveRow(self, 0);
            id query = valueForKey(first, @"searchText");
            int numeric = SEND(int)(valueForKey(first, @"searchNumeric"), SELECTOR("intValue"));
            if (!mode) query = revivePlexEditSearch(query, valueForKey(liveRow(self, row), @"searchKey"));
            refreshSearch(self, query, mode ? !numeric : numeric, row);
            return;
        }
        if (SEND(signed char, id)(action, SELECTOR("isEqual:"), @"beginLink")) {
            startPlexLink(self);
            return;
        }
#ifdef REVIVEPLEX_PRODUCTION
        if (SEND(signed char, id)(action, SELECTOR("isEqual:"), @"signOut")) {
            signOutAndReturn(self);
            return;
        }
        if (SEND(signed char, id)(action, SELECTOR("isEqual:"), @"checkSession")) {
            checkPlexSession(self);
            return;
        }
#endif
        if (revivePlexRevealPlaybackControls(self)) return;
        if (SEND(signed char, id)(action, SELECTOR("isEqual:"), @"subtitles") ||
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"audio")) {
            revivePlexCycleTrack(self, SEND(signed char, id)(action, SELECTOR("isEqual:"), @"subtitles"));
            return;
        }
        if (SEND(signed char, id)(action, SELECTOR("isEqual:"), @"videoFit"))
            revivePlexToggleVideoFit(self);
        else if (SEND(signed char, id)(action, SELECTOR("isEqual:"), @"toggle")) revivePlexTogglePlayback(self);
        else revivePlexSeekPlayback(self,
            SEND(signed char, id)(action, SELECTOR("isEqual:"), @"back") ? -15.0 : 30.0);
        return;
    }
#endif
    id stack = SEND(id)(self, SELECTOR("stack"));
    if (!SEND(signed char, SEL)(stack, SELECTOR("respondsToSelector:"), SELECTOR("pushController:"))) {
        stage("controller stack unavailable");
        return;
    }
    const MenuScreen *screen = screenForMenu(self);
    id next;
#ifdef REVIVEPLEX_LIVE
    if (objc_getAssociatedObject(self, &liveRowsKey))
        next = makeLiveMenu(valueForKey(liveRow(self, row), @"route"));
    else if (screen == &mockScreens[Home] && row == screen->count)
        next = makeLiveMenu(0);
    else
#endif
        next = makeMenu(screen->rows[row].destination);
    if (next) {
#ifdef REVIVEPLEX_PLAYBACK
        id currentKind = valueForKey(objc_getAssociatedObject(self, &menuRouteKey), @"kind");
        if ((SEND(signed char, id)(currentKind, SELECTOR("isEqual:"), @"queueItems") ||
             SEND(signed char, id)(currentKind, SELECTOR("isEqual:"), @"queueModes") ||
             (SEND(signed char, id)(currentKind, SELECTOR("isEqual:"), @"versions") && valueForKey(objc_getAssociatedObject(self, &menuRouteKey), @"resume"))) &&
            objc_getAssociatedObject(next, &playerRouteKey)) {
            revivePlexWithoutTransitionAnimation(^{
                SEND(void)(stack, SELECTOR("popController"));
                SEND(void, id)(stack, SELECTOR("swapController:"), next);
            }); return;
        }
        if (SEND(signed char, id)(valueForKey(objc_getAssociatedObject(self, &menuRouteKey), @"kind"), SELECTOR("isEqual:"), @"playbackOptions") &&
            objc_getAssociatedObject(next, &playerRouteKey)) {
            SEND(void, id)(stack, SELECTOR("swapController:"), next); return;
        }
#endif
#ifdef REVIVEPLEX_PLAYBACK
        if (objc_getAssociatedObject(self, &liveRowsKey)) {
            id selected = SEND(id, long)((id)objc_getClass("NSNumber"), SELECTOR("numberWithLong:"), row);
            objc_setAssociatedObject(self, &restoredSelectionKey, selected, 1);
        }
#endif
#ifdef REVIVEPLEX_ARTWORK
        if (objc_getAssociatedObject(self, &liveRowsKey) && !objc_getAssociatedObject(next, &playerRouteKey)) {
            revivePlexWithoutTransitionAnimation(^{ SEND(void, id)(stack, SELECTOR("pushController:"), next); });
            return;
        }
#endif
        SEND(void, id)(stack, SELECTOR("pushController:"), next);
    }
}

static int installMethod(Class target, Class parent, const char *name, MenuIMP imp, const char *fallback)
{
    SEL selector = SELECTOR(name);
    Method method = class_getInstanceMethod(parent, selector);
    return class_addMethod(target, selector, imp, method ? method_getTypeEncoding(method) : fallback);
}

#ifdef REVIVEPLEX_AUTOSTART
static void sendProbeEvent(id stack, int action)
{
    Class eventClass = objc_getClass("BREvent");
    if (!eventClass || !class_getClassMethod(eventClass, SELECTOR("eventWithAction:value:")) ||
        !SEND(signed char, SEL)(stack, SELECTOR("respondsToSelector:"), SELECTOR("brEventAction:"))) return;
    for (int value = 1; value >= 0; value--) {
        id event = SEND(id, int, int)((id)eventClass, SELECTOR("eventWithAction:value:"), action, value);
        SEND(signed char, id)(stack, SELECTOR("brEventAction:"), event);
    }
}

static long probeSelection(id menu)
{
    return SEND(long)(SEND(id)(menu, SELECTOR("list")), SELECTOR("selection"));
}

static void runScreenProbes(id home, id stack, id routes, unsigned long index);

// One-shot device regression: remote Play, options, Back, resumed position.
static void runOptionsReturnProbe(id home, id stack, id screen, int phase, double expected, int attempts)
{
    if (!attempts) { stage("options return probe timed out"); return; }
    id current = SEND(id)(stack, SELECTOR("peekController"));
    int native = SEND(signed char, Class)(current, SELECTOR("isKindOfClass:"), objc_getClass("RevivePlexSystemPlayerController"));
    if (phase == 0 && current == screen && revivePlexCanQuickPlay(valueForKey(liveRow(screen, 0), @"route"))) {
        sendProbeEvent(stack, 10); phase = 1;
    } else if ((phase == 1 || phase == 3) && native) {
        id player = SEND(id)(current, SELECTOR("player"));
        double position = SEND(double)(player, SELECTOR("elapsedTime"));
        if (SEND(double)(player, SELECTOR("rate")) == 1 && position > 0) {
            if (phase == 3) {
                syslog(LOG_NOTICE, "RevivePlex: options return probe PASS native=1 resumed=%d", position >= expected - 2);
                sendProbeEvent(stack, 1); return;
            }
            expected = position;
            SEND(void)(current, SELECTOR("_enterChaptersSubtitlesAndAlternateAudioPickingState")); phase = 2;
        }
    } else if (phase == 2 && SEND(signed char, id)(valueForKey(objc_getAssociatedObject(current, &menuRouteKey), @"kind"), SELECTOR("isEqual:"), @"playbackOptions")) {
        sendProbeEvent(stack, 1); phase = 3;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        runOptionsReturnProbe(home, stack, screen, phase, expected, attempts - 1);
    });
}

static void runSyncSeekProbe(id home, id stack, id routes, unsigned long index, unsigned int attempts)
{
    if (!attempts) { stage("sync seek probe readiness timed out"); return; }
    id current = SEND(id)(stack, SELECTOR("peekController"));
    if (current == home) return;
    id route = SEND(id, unsigned long)(routes, SELECTOR("objectAtIndex:"), index);
    int ready = 0;
    if (SEND(signed char, Class)(current, SELECTOR("isKindOfClass:"), objc_getClass("RevivePlexSystemPlayerController"))) {
        id player = SEND(id)(current, SELECTOR("player"));
        double requested = SEND(double)(valueForKey(route, @"resume"), SELECTOR("doubleValue"));
        ready = SEND(double)(player, SELECTOR("rate")) == 1 && SEND(double)(player, SELECTOR("elapsedTime")) > requested + 0.2;
    }
    if (!ready) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * (int64_t)NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            runSyncSeekProbe(home, stack, routes, index, attempts - 1);
        }); return;
    }
    syslog(LOG_NOTICE, "RevivePlex: sync seek probe ready sample=%lu", index);
        // Exercise the real remote path, then leave time for playback to settle.
        for (int step = 0; step < 12; step++) {
            int action = step < 8 ? 7 : 6;
            int milliseconds = step < 8 ? 15000 + step * 300 : 45000 + (step - 8) * 300;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, milliseconds * (int64_t)NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                id current = SEND(id)(stack, SELECTOR("peekController"));
                if (SEND(signed char, Class)(current, SELECTOR("isKindOfClass:"), objc_getClass("RevivePlexSystemPlayerController"))) sendProbeEvent(stack, action);
            });
        }
        const int checkpoints[] = {22, 30, 52, 60, 70, 73, 85, 100};
        for (unsigned int check = 0; check < sizeof(checkpoints) / sizeof(checkpoints[0]); check++) {
            int second = checkpoints[check];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, second * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                id current = SEND(id)(stack, SELECTOR("peekController"));
                if (!SEND(signed char, Class)(current, SELECTOR("isKindOfClass:"), objc_getClass("RevivePlexSystemPlayerController"))) return;
                id player = SEND(id)(current, SELECTOR("player"));
                double rate = SEND(double)(player, SELECTOR("rate"));
                syslog(LOG_NOTICE, "RevivePlex: sync seek checkpoint=%d sample=%lu position=%.3f rate=%.2f", second, index,
                    SEND(double)(player, SELECTOR("elapsedTime")), rate);
                if (second == 73 && rate != 1) sendProbeEvent(stack, 5);
                if (second == 70 && rate == 1) sendProbeEvent(stack, 5);
            });
        }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 110 * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        id active = SEND(id)(stack, SELECTOR("peekController"));
        if (SEND(signed char, Class)(active, SELECTOR("isKindOfClass:"), objc_getClass("RevivePlexSystemPlayerController"))) {
            id player = SEND(id)(active, SELECTOR("player"));
            syslog(LOG_NOTICE, "RevivePlex: sync seek probe finished sample=%lu position=%.3f rate=%.2f", index,
                SEND(double)(player, SELECTOR("elapsedTime")), SEND(double)(player, SELECTOR("rate")));
            sendProbeEvent(stack, 1);
        }
        runScreenProbes(home, stack, routes, index + 1);
    });
}

static void runScreenProbes(id home, id stack, id routes, unsigned long index)
{
    revivePlexSetDiagnosticLanguage(0);
    if (SEND(id)(stack, SELECTOR("peekController")) != home || index >= SEND(unsigned long)(routes, SELECTOR("count"))) return;
    id route = SEND(id, unsigned long)(routes, SELECTOR("objectAtIndex:"), index);
    revivePlexSetDiagnosticLanguage(valueForKey(route, @"probeLanguage"));
    id screen = makeLiveMenu(route);
    if (!screen) return;
    SEND(void, id)(stack, SELECTOR("pushController:"), screen);
    if (SEND(signed char)(valueForKey(route, @"optionsReturnProbe"), SELECTOR("boolValue"))) {
        runOptionsReturnProbe(home, stack, screen, 0, 0, 120); return;
    }
    if (SEND(signed char)(valueForKey(route, @"sortStackProbe"), SELECTOR("boolValue"))) {
        for (int iteration = 0; iteration < 2; iteration++) {
            int choice = iteration ? 2 : 3;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (3 + iteration * 2) * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (SEND(id)(stack, SELECTOR("peekController")) != screen) return;
                itemSelected(screen, SELECTOR("itemSelected:"), 0);
                id sort = SEND(id)(stack, SELECTOR("peekController"));
                if (sort == screen) return;
                itemSelected(sort, SELECTOR("itemSelected:"), choice);
                syslog(LOG_NOTICE, "RevivePlex: sort stack choice=%d returnedToSameCatalog=%d", choice, SEND(id)(stack, SELECTOR("peekController")) == screen);
            });
        }
    }
    int galleryProbe = SEND(signed char, id)(valueForKey(route, @"kind"), SELECTOR("isEqual:"), @"photo") &&
        SEND(unsigned long)(valueForKey(route, @"gallery"), SELECTOR("count")) > 1;
    if (galleryProbe) sendProbeEvent(stack, 5);
    int queueJumpProbe = SEND(signed char)(valueForKey(route, @"queueJumpProbe"), SELECTOR("boolValue"));
    if (queueJumpProbe) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (SEND(id)(stack, SELECTOR("peekController")) != screen) return;
            long selected = 0;
            while (liveRow(screen, selected) && !SEND(signed char, id)(valueForKey(valueForKey(liveRow(screen, selected), @"route"), @"kind"), SELECTOR("isEqual:"), @"queueItems")) selected++;
            if (!liveRow(screen, selected)) return;
            itemSelected(screen, SELECTOR("itemSelected:"), selected);
            id queue = SEND(id)(stack, SELECTOR("peekController"));
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (SEND(id)(stack, SELECTOR("peekController")) != queue || queue == screen) return;
                revivePlexCaptureScreenForProbe(queue, @"RevivePlex.queue.png");
                itemSelected(queue, SELECTOR("itemSelected:"), 1);
            });
        });
    }
    int markerProbe = SEND(signed char)(valueForKey(route, @"markerProbe"), SELECTOR("boolValue"));
    if (markerProbe) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 7 * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            id native = SEND(id)(stack, SELECTOR("peekController"));
            if (!SEND(signed char, Class)(native, SELECTOR("isKindOfClass:"), objc_getClass("RevivePlexSystemPlayerController"))) return;
            revivePlexCaptureScreenForProbe(native, @"RevivePlex.marker.png");
            sendProbeEvent(stack, 3);
        });
    }
    if (SEND(signed char)(valueForKey(route, @"failureProbe"), SELECTOR("boolValue"))) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            id native = SEND(id)(stack, SELECTOR("peekController"));
            if (SEND(signed char, Class)(native, SELECTOR("isKindOfClass:"), objc_getClass("RevivePlexSystemPlayerController"))) revivePlexFailPlaybackForProbe(native);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 22 * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            id current = SEND(id)(stack, SELECTOR("peekController"));
            id recovery = objc_getAssociatedObject(current, &menuRouteKey);
            syslog(LOG_NOTICE, "RevivePlex: playback failure recovery visible=%d", valueForKey(recovery, @"playbackError") != 0);
            revivePlexCaptureScreenForProbe(current, @"RevivePlex.failure.png");
            if (current != home) sendProbeEvent(stack, 1);
            runScreenProbes(home, stack, routes, index + 1);
        }); return;
    }
    int formatProbe = SEND(signed char)(valueForKey(route, @"formatProbe"), SELECTOR("boolValue"));
    if (SEND(signed char)(valueForKey(route, @"syncSeekProbe"), SELECTOR("boolValue"))) {
        runSyncSeekProbe(home, stack, routes, index, 180); return;
    }
    if (SEND(signed char)(valueForKey(route, @"seekBurstProbe"), SELECTOR("boolValue"))) {
        for (int step = 0; step < 48; step++) {
            int action = (step / 8) % 2 ? 6 : 7;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (10 * NSEC_PER_SEC) + step * 150 * (int64_t)NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                id current = SEND(id)(stack, SELECTOR("peekController"));
                if (SEND(signed char, Class)(current, SELECTOR("isKindOfClass:"), objc_getClass("RevivePlexSystemPlayerController"))) sendProbeEvent(stack, action);
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 19 * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            id current = SEND(id)(stack, SELECTOR("peekController"));
            if (SEND(signed char, Class)(current, SELECTOR("isKindOfClass:"), objc_getClass("RevivePlexSystemPlayerController"))) {
                stage("seek burst survived 48 directional presses");
                revivePlexCaptureScreenForProbe(current, @"RevivePlex.seek-burst.png");
                sendProbeEvent(stack, 5);
            }
        });
    }
    if (SEND(signed char)(valueForKey(route, @"transportProbe"), SELECTOR("boolValue"))) {
        for (int check = 0; check < 2; check++) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (22 + check * 13) * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            id current = SEND(id)(stack, SELECTOR("peekController"));
            if (SEND(signed char, Class)(current, SELECTOR("isKindOfClass:"), objc_getClass("RevivePlexSystemPlayerController")))
                revivePlexCaptureScreenForProbe(current, check ? @"RevivePlex.hint-hidden.png" : @"RevivePlex.hint-visible.png");
        });
        for (int step = 0; step < 2; step++) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (20 + step * 3) * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            id current = SEND(id)(stack, SELECTOR("peekController"));
            if (SEND(signed char, Class)(current, SELECTOR("isKindOfClass:"), objc_getClass("RevivePlexSystemPlayerController"))) sendProbeEvent(stack, 5);
        });
    }

    if (queueJumpProbe || markerProbe || formatProbe || SEND(signed char)(valueForKey(route, @"audioProbe"), SELECTOR("boolValue"))) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (formatProbe ? 45 : 14) * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            id current = SEND(id)(stack, SELECTOR("peekController"));
            if (SEND(signed char, Class)(current, SELECTOR("isKindOfClass:"), objc_getClass("RevivePlexSystemPlayerController"))) {
                id player = SEND(id)(current, SELECTOR("player"));
                double elapsed = SEND(double)(player, SELECTOR("elapsedTime"));
                syslog(LOG_NOTICE, "RevivePlex: media probe queue=%d player=%s position=%.2f", queueJumpProbe, class_getName(SEND(Class)(player, SELECTOR("class"))), elapsed);
                if (markerProbe) syslog(LOG_NOTICE, "RevivePlex: manual marker skipped=%d position=%.2f", elapsed >= 20, elapsed);
                if (formatProbe) syslog(LOG_NOTICE, "RevivePlex: format probe index=%lu progressing=%d position=%.2f", index, elapsed > 5, elapsed);
                revivePlexCaptureScreenForProbe(current, @"RevivePlex.audio.png");
                sendProbeEvent(stack, 1);
            } else if (current == screen) { stage("audio probe did not reach native player"); sendProbeEvent(stack, 1); }
            if (queueJumpProbe) syslog(LOG_NOTICE, "RevivePlex: queue jump back home=%d", SEND(id)(stack, SELECTOR("peekController")) == home);
            runScreenProbes(home, stack, routes, index + 1);
        });
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 7 * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (SEND(id)(stack, SELECTOR("peekController")) != screen) { revivePlexSetDiagnosticLanguage(0); return; }
        id filename = SEND(id, id, unsigned long)((id)objc_getClass("NSString"), SELECTOR("stringWithFormat:"), @"RevivePlex.screen-%lu.png", index);
        if (galleryProbe) {
            id currentRoute = objc_getAssociatedObject(screen, &menuRouteKey);
            syslog(LOG_NOTICE, "RevivePlex: slideshow advanced=%d", SEND(long)(valueForKey(currentRoute, @"photoIndex"), SELECTOR("longValue")) == 1);
            sendProbeEvent(stack, 5);
        }
        if (SEND(signed char)(valueForKey(route, @"languageChangeProbe"), SELECTOR("boolValue"))) {
            id preference = SEND(id)(SEND(id)(revivePlexLanguagePreference(), SELECTOR("retain")), SELECTOR("autorelease"));
            int wasEnglish = SEND(signed char, id)(revivePlexLanguage(), SELECTOR("isEqual:"), @"en");
            itemSelected(screen, SELECTOR("itemSelected:"), wasEnglish ? 2 : 1);
            int stays = SEND(id)(stack, SELECTOR("peekController")) == screen;
            int english = SEND(signed char, id)(revivePlexLanguage(), SELECTOR("isEqual:"), wasEnglish ? @"tr" : @"en");
            syslog(LOG_NOTICE, "RevivePlex: language applied immediately=%d stayedOnPage=%d", english, stays);
            revivePlexCaptureScreenForProbe(screen, @"RevivePlex.language-immediate.png");
            revivePlexSetLanguage(preference);
            SEND(void, id)(screen, SELECTOR("setListTitle:"), revivePlexLocalizedMenuTitle(objc_getAssociatedObject(screen, &menuRouteKey)));
            revivePlexLoadRows(objc_getAssociatedObject(screen, &menuRouteKey), ^(id rows) { setLiveRows(screen, rows); });
        }
        if (SEND(signed char)(valueForKey(route, @"markerSettingsProbe"), SELECTOR("boolValue"))) {
            id before = SEND(id)(SEND(id)(valueForKey(liveRow(screen, 0), @"status"), SELECTOR("retain")), SELECTOR("autorelease"));
            itemSelected(screen, SELECTOR("itemSelected:"), 0);
            int stayed = SEND(id)(stack, SELECTOR("peekController")) == screen;
            int changed = !SEND(signed char, id)(valueForKey(liveRow(screen, 0), @"status"), SELECTOR("isEqual:"), before);
            if (stayed) itemSelected(screen, SELECTOR("itemSelected:"), 0);
            syslog(LOG_NOTICE, "RevivePlex: marker settings stayed=%d changed=%d restored=%d", stayed, changed,
                SEND(signed char, id)(valueForKey(liveRow(screen, 0), @"status"), SELECTOR("isEqual:"), before));
        }
        if (SEND(signed char)(valueForKey(route, @"filterProbe"), SELECTOR("boolValue"))) {
            sendProbeEvent(stack, 7);
            id before = valueForKey(liveRow(screen, 1), @"baseTitle");
            sendProbeEvent(stack, 5);
            int removed = !SEND(signed char, id)(valueForKey(liveRow(screen, 1), @"title"), SELECTOR("hasPrefix:"), @"✓ ");
            int stable = SEND(signed char, id)(valueForKey(liveRow(screen, 1), @"baseTitle"), SELECTOR("isEqual:"), before);
            sendProbeEvent(stack, 5);
            syslog(LOG_NOTICE, "RevivePlex: filter toggle removed=%d stable=%d selectedAgain=%d", removed, stable,
                SEND(signed char, id)(valueForKey(liveRow(screen, 1), @"title"), SELECTOR("hasPrefix:"), @"✓ "));
        }
        if (SEND(signed char)(valueForKey(route, @"descriptionProbe"), SELECTOR("boolValue"))) {
            revivePlexCaptureScreenForProbe(screen, @"RevivePlex.description-first.png");
            sendProbeEvent(stack, 4);
        }
        unsigned long scrollSteps = SEND(unsigned long)(valueForKey(route, @"scrollSteps"), SELECTOR("unsignedIntegerValue"));
        for (unsigned long step = 0; step < scrollSteps && step < 50; step++) sendProbeEvent(stack, 4);
        revivePlexCaptureScreenForProbe(screen, filename);
        syslog(LOG_NOTICE, "RevivePlex: additional screen probe %lu loaded=%d", index,
            !valueForKey(liveRow(screen, 0), @"shelfLoading"));
        revivePlexSetDiagnosticLanguage(0);
        sendProbeEvent(stack, 1);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            runScreenProbes(home, stack, routes, index + 1);
        });
    });
}

static void runApplianceReentryProbe(id menu, id stack)
{
    if (SEND(id)(stack, SELECTOR("peekController")) != menu) return;
    sendProbeEvent(stack, 1);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        id home = SEND(id)(stack, SELECTOR("peekController"));
        if (home == menu || !registeredAppliance ||
            !SEND(signed char, SEL)(home, SELECTOR("respondsToSelector:"),
                SELECTOR("_pushControllerForAppliance:"))) {
            stage("appliance reentry probe: system home unavailable");
            return;
        }
        if (!SEND(signed char, SEL)(home, SELECTOR("respondsToSelector:"),
                SELECTOR("focusApplianceWithIdentifier:"))) return;
        id identifier = @"org.revivetv.frontrow.appliance.reviveplex";
        Class legacyManager = objc_getClass("ATVMerchantCoordinator");
        if (legacyManager && class_getClassMethod(legacyManager, SELECTOR("sharedInstance"))) {
            id manager = SEND(id)((id)legacyManager, SELECTOR("sharedInstance"));
            id entries = SEND(id)(manager, SELECTOR("allMerchants"));
            unsigned long count = SEND(unsigned long)(entries, SELECTOR("count"));
            for (unsigned long index = 0; index < count; index++) {
                id merchant = SEND(id, unsigned long)(entries, SELECTOR("objectAtIndex:"), index);
                syslog(LOG_NOTICE, "RevivePlex: launcher merchant class=%s", class_getName(SEND(Class)(merchant, SELECTOR("class"))));
                if (!SEND(signed char, SEL)(merchant, SELECTOR("respondsToSelector:"), SELECTOR("applianceInstance"))) continue;
                id instance = SEND(id)(merchant, SELECTOR("applianceInstance"));
                syslog(LOG_NOTICE, "RevivePlex: legacy instance=%s classMatch=%d", class_getName(SEND(Class)(instance, SELECTOR("class"))), isPlexMerchant(merchant));
                if (isPlexMerchant(merchant)) {
                    identifier = SEND(id)(merchant, SELECTOR("identifier"));
                    if (SEND(signed char, SEL)(merchant, SELECTOR("respondsToSelector:"), SELECTOR("rootController"))) {
                        id root = SEND(id)(merchant, SELECTOR("rootController"));
                        if (!root) return;
                        SEND(void, id)(stack, SELECTOR("pushController:"), root);
                        id reopened = SEND(id)(stack, SELECTOR("peekController"));
                        syslog(LOG_NOTICE, "RevivePlex: legacy merchant reentry direct=%d",
                            SEND(signed char, Class)(reopened, SELECTOR("isKindOfClass:"), menuClass));
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                            if (SEND(id)(stack, SELECTOR("peekController")) == reopened)
                                revivePlexCaptureScreenForProbe(reopened, @"RevivePlex.reentry.png");
                            runScreenProbes(reopened, stack, revivePlexDiagnosticRoutes(), 0);
                        });
                        return;
                    }
                    break;
                }
            }
        }
        SEND(void, id)(home, SELECTOR("focusApplianceWithIdentifier:"), identifier);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (SEND(id)(stack, SELECTOR("peekController")) != home) return;
        id focused = SEND(id)(home, SELECTOR("focusedGridAppliance"));
        syslog(LOG_NOTICE, "RevivePlex: focused grid appliance class=%s",
            class_getName(SEND(Class)(focused, SELECTOR("class"))));
        if (!focused || !SEND(signed char, SEL)(focused, SELECTOR("respondsToSelector:"), SELECTOR("applianceInstance")) ||
            !SEND(signed char, Class)(SEND(id)(focused, SELECTOR("applianceInstance")),
                SELECTOR("isKindOfClass:"), objc_getClass("RevivePlexAppliance"))) {
            stage("reentry probe: Plex not focused; Select withheld");
            return;
        }
        sendProbeEvent(stack, 5);
        id reopened = SEND(id)(stack, SELECTOR("peekController"));
        int direct = reopened != home &&
            SEND(signed char, Class)(reopened, SELECTOR("isKindOfClass:"), menuClass);
        syslog(LOG_NOTICE, "RevivePlex: remote appliance reentry direct=%d class=%s", direct,
            class_getName(SEND(Class)(reopened, SELECTOR("class"))));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * (int64_t)NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{
            if (SEND(id)(stack, SELECTOR("peekController")) != reopened) return;
            revivePlexCaptureScreenForProbe(reopened, @"RevivePlex.reentry.png");
        });
        });
    });
}

static void runNavigationProbe(id menu, id stack)
{
    if (SEND(id)(stack, SELECTOR("peekController")) != menu ||
        !updateMediaLayout(menu, SEND(id)(menu, SELECTOR("list")))) {
        stage("navigation probe skipped: artwork navigation not ready");
        return;
    }
    id rows = objc_getAssociatedObject(menu, &liveRowsKey);
    long initial = probeSelection(menu);
    long movies = revivePlexHomeRailTarget(rows, initial, 7);
    sendProbeEvent(stack, 7);
    long right = probeSelection(menu);
    sendProbeEvent(stack, 6);
    long left = probeSelection(menu);
    sendProbeEvent(stack, 7);
    long expectedDown = revivePlexHomeRailTarget(rows, movies, 4);
    sendProbeEvent(stack, 4);
    long down = probeSelection(menu);
    sendProbeEvent(stack, 3);
    long up = probeSelection(menu);
    int directions = movies != initial && right == movies && left == initial &&
        expectedDown != movies && down == expectedDown && up == movies;
    id expectedTitle = valueForKey(liveRow(menu, movies), @"title");
    if (!directions || !SEND(signed char, id)(expectedTitle, SELECTOR("isEqual:"), @"Movies")) {
        syslog(LOG_NOTICE, "RevivePlex: navigation probe right=%d left=%d down=%d up=%d; Movies unavailable",
            right == movies, left == initial, down == expectedDown, up == movies);
        return;
    }
    sendProbeEvent(stack, 5);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * (int64_t)NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
        id child = SEND(id)(stack, SELECTOR("peekController"));
        id entry = child != menu ? liveRow(child, probeSelection(child)) : 0;
        int direct = child != menu &&
            SEND(signed char, id)(SEND(id)(child, SELECTOR("listTitle")), SELECTOR("isEqual:"), expectedTitle) &&
            SEND(signed char, id)(valueForKey(valueForKey(entry, @"route"), @"kind"), SELECTOR("isEqual:"), @"detail");
        int grid = direct && updateMediaLayout(child, SEND(id)(child, SELECTOR("list")));
        int gridRight = 0, gridVertical = 0;
        if (grid) {
            long first = probeSelection(child);
            sendProbeEvent(stack, 7);
            gridRight = probeSelection(child) == first + 1;
            long column = probeSelection(child);
            long columns = revivePlexShelfColumns(objc_getAssociatedObject(child, &liveRowsKey));
            sendProbeEvent(stack, 4);
            int gridDown = probeSelection(child) == column + columns;
            sendProbeEvent(stack, 3);
            gridVertical = gridDown && probeSelection(child) == column;
            revivePlexCaptureCatalogForProbe(child);
        }
        if (child != menu) sendProbeEvent(stack, 1);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * (int64_t)NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{
            int back = SEND(id)(stack, SELECTOR("peekController")) == menu;
            int focus = back && probeSelection(menu) == movies;
            syslog(LOG_NOTICE, "RevivePlex: navigation probe right=1 left=1 down=1 up=1 directMovies=%d catalogGrid=%d catalogRight=%d catalogVertical=%d back=%d focusRestored=%d",
                direct, grid, gridRight, gridVertical, back, focus);
            if (back && focus) runApplianceReentryProbe(menu, stack);
        });
    });
}

static void finishSearchProbe(id menu, id stack, id search)
{
    if (SEND(id)(stack, SELECTOR("peekController")) != search) return;
    sendProbeEvent(stack, 1);
    if (SEND(id)(stack, SELECTOR("peekController")) == menu) {
        sendProbeEvent(stack, 7);
        runNavigationProbe(menu, stack);
    }
}

static void waitForOptionsResumeProbe(id menu, id stack, id search, id detail, id loading, double expected, int attempts)
{
    id current = SEND(id)(stack, SELECTOR("peekController"));
    int native = SEND(signed char, Class)(current, SELECTOR("isKindOfClass:"), objc_getClass("RevivePlexSystemPlayerController"));
    id player = native ? SEND(id)(current, SELECTOR("player")) : 0;
    double position = native ? SEND(double)(player, SELECTOR("elapsedTime")) : 0;
    if ((native || current == loading) && position < expected - 2 && attempts > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            waitForOptionsResumeProbe(menu, stack, search, detail, loading, expected, attempts - 1);
        }); return;
    }
    syslog(LOG_NOTICE, "RevivePlex: playback options resume native=%d preserved=%d position=%.2f", native, position >= expected - 2, position);
    if (native || current == loading) sendProbeEvent(stack, 1);
    if (SEND(id)(stack, SELECTOR("peekController")) == detail) sendProbeEvent(stack, 1);
    finishSearchProbe(menu, stack, search);
}

static void waitForPlaybackProbe(id menu, id stack, id search, id detail, id loading, int attempts)
{
    id current = SEND(id)(stack, SELECTOR("peekController"));
    int native = SEND(signed char, Class)(current, SELECTOR("isKindOfClass:"), objc_getClass("RevivePlexSystemPlayerController"));
    id player = native ? SEND(id)(current, SELECTOR("player")) : 0;
    if ((!native || SEND(double)(player, SELECTOR("elapsedTime")) <= 0) && attempts > 0 && (native || current == loading)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            waitForPlaybackProbe(menu, stack, search, detail, loading, attempts - 1);
        }); return;
    }
    if (!native) {
        stage("playback probe did not reach native playback");
        if (current == loading) sendProbeEvent(stack, 1);
        if (SEND(id)(stack, SELECTOR("peekController")) == detail) sendProbeEvent(stack, 1);
        finishSearchProbe(menu, stack, search); return;
    }
    syslog(LOG_NOTICE, "RevivePlex: remote probe ready position=%.2f", SEND(double)(player, SELECTOR("elapsedTime")));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (SEND(id)(stack, SELECTOR("peekController")) == current) sendProbeEvent(stack, 5);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (SEND(id)(stack, SELECTOR("peekController")) != current) return;
        sendProbeEvent(stack, 7); sendProbeEvent(stack, 5);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * (int64_t)NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (SEND(id)(stack, SELECTOR("peekController")) == current) revivePlexCaptureScreenForProbe(current, @"RevivePlex.seek.png");
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 13 * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (SEND(id)(stack, SELECTOR("peekController")) != current) return;
        syslog(LOG_NOTICE, "RevivePlex: remote seek probe state=%d position=%.2f",
            SEND(int)(player, SELECTOR("playerState")), SEND(double)(player, SELECTOR("elapsedTime")));
        revivePlexCaptureScreenForProbe(current, @"RevivePlex.player.png");
        double position = SEND(double)(player, SELECTOR("elapsedTime"));
        SEND(void)(current, SELECTOR("_enterChaptersSubtitlesAndAlternateAudioPickingState"));
        id options = SEND(id)(stack, SELECTOR("peekController"));
        if (options == current) { stage("playback options did not open"); sendProbeEvent(stack, 1); if (SEND(id)(stack, SELECTOR("peekController")) == detail) sendProbeEvent(stack, 1); finishSearchProbe(menu, stack, search); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (SEND(id)(stack, SELECTOR("peekController")) != options) return;
            revivePlexCaptureScreenForProbe(options, @"RevivePlex.playback-options.png");
            sendProbeEvent(stack, 5);
            waitForOptionsResumeProbe(menu, stack, search, detail, SEND(id)(stack, SELECTOR("peekController")), position, 45);
        });
    });
}

static void runPlaybackProbe(id menu, id stack, id search, long firstResult)
{
    long movie = firstResult;
    id row;
    while ((row = liveRow(search, movie)) &&
        !SEND(signed char, id)(valueForKey(row, @"mediaType"), SELECTOR("isEqual:"), @"movie")) movie++;
    if (!row) { finishSearchProbe(menu, stack, search); return; }
    itemSelected(search, SELECTOR("itemSelected:"), movie);
    id detail = SEND(id)(stack, SELECTOR("peekController"));
    if (detail == search) { finishSearchProbe(menu, stack, search); return; }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * (int64_t)NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
        if (SEND(id)(stack, SELECTOR("peekController")) != detail) return;
        long index = 0;
        id entry;
        while ((entry = liveRow(detail, index)) && !SEND(signed char, id)(
            valueForKey(valueForKey(entry, @"route"), @"kind"), SELECTOR("isEqual:"), @"transcode")) index++;
        syslog(LOG_NOTICE, "RevivePlex: detail probe redesigned=%d transcodeRoute=%d",
            valueForKey(liveRow(detail, 0), @"panel") != 0, entry != 0);
        revivePlexCaptureScreenForProbe(detail, @"RevivePlex.detail.png");
        if (!entry) {
            sendProbeEvent(stack, 1);
            finishSearchProbe(menu, stack, search);
            return;
        }
        id diagnosticRoute = SEND(id)(valueForKey(entry, @"route"), SELECTOR("mutableCopy"));
        SEND(void, id, id)(diagnosticRoute, SELECTOR("setObject:forKey:"), @"1", @"diagnostic");
        id diagnosticEntry = SEND(id)(entry, SELECTOR("mutableCopy"));
        SEND(void, id, id)(diagnosticEntry, SELECTOR("setObject:forKey:"), diagnosticRoute, @"route");
        id diagnosticRows = SEND(id)(objc_getAssociatedObject(detail, &liveRowsKey), SELECTOR("mutableCopy"));
        SEND(void, unsigned long, id)(diagnosticRows, SELECTOR("replaceObjectAtIndex:withObject:"), index, diagnosticEntry);
        setLiveRows(detail, diagnosticRows);
        itemSelected(detail, SELECTOR("itemSelected:"), index);
        waitForPlaybackProbe(menu, stack, search, detail, SEND(id)(stack, SELECTOR("peekController")), 45);
    });
}

static void runSearchProbe(id menu, id stack)
{
    if (SEND(id)(stack, SELECTOR("peekController")) != menu || probeSelection(menu) != 0 ||
        !SEND(signed char, id)(valueForKey(valueForKey(liveRow(menu, 0), @"route"), @"kind"),
            SELECTOR("isEqual:"), @"search")) return;
    sendProbeEvent(stack, 5);
    id search = SEND(id)(stack, SELECTOR("peekController"));
    if (search == menu || !valueForKey(liveRow(search, 0), @"searchKeyCount")) return;
    id letters[] = {@"A", @"N"};
    for (int letter = 0; letter < 2; letter++) {
        long target = 0;
        while (liveRow(search, target) && !SEND(signed char, id)(
            valueForKey(liveRow(search, target), @"searchKey"), SELECTOR("isEqual:"), letters[letter])) target++;
        if (!liveRow(search, target)) return;
        for (int step = 0; step < 40 && probeSelection(search) != target; step++) {
            long current = probeSelection(search);
            if (current < RevivePlexSearchColumns && target >= RevivePlexSearchColumns) sendProbeEvent(stack, 4);
            else if (current >= RevivePlexSearchColumns && target < RevivePlexSearchColumns) sendProbeEvent(stack, 3);
            else sendProbeEvent(stack, current < target ? 7 : 6);
        }
        sendProbeEvent(stack, 5);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * (int64_t)NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
        if (SEND(id)(stack, SELECTOR("peekController")) != search) return;
        id first = liveRow(search, 0);
        long keys = SEND(long)(valueForKey(first, @"searchKeyCount"), SELECTOR("longValue"));
        int typed = SEND(signed char, id)(valueForKey(first, @"searchText"), SELECTOR("isEqual:"), @"AN");
        int results = valueForKey(liveRow(search, keys), @"route") != 0;
        sendProbeEvent(stack, 4);
        int focused = probeSelection(search) >= keys;
        revivePlexCaptureScreenForProbe(search, @"RevivePlex.search.png");
        syslog(LOG_NOTICE, "RevivePlex: live search probe typed=%d results=%d resultFocus=%d",
            typed, results, focused);
        if (typed && results && focused) runPlaybackProbe(menu, stack, search, keys);
        else finishSearchProbe(menu, stack, search);
    });
}

static void runStartupProbe(id menu, id stack)
{
    int screensOnly = revivePlexDiagnosticScreensOnly();
    id probes = screensOnly ? revivePlexDiagnosticRoutes() : 0;
    if (SEND(unsigned long)(probes, SELECTOR("count")) &&
        valueForKey(SEND(id, unsigned long)(probes, SELECTOR("objectAtIndex:"), 0), @"homeBackProbe")) {
        id list = SEND(id)(menu, SELECTOR("list"));
        long previous = probeSelection(menu);
        SEND(void, long)(list, SELECTOR("setSelection:"), 1);
        sendProbeEvent(stack, 1);
        int tabReturned = SEND(id)(stack, SELECTOR("peekController")) == menu && probeSelection(menu) == 0;
        long poster = 1;
        while (liveRow(menu, poster) && !SEND(int)(valueForKey(liveRow(menu, poster), @"homeRail"), SELECTOR("intValue"))) poster++;
        int posterReturned = 0;
        if (liveRow(menu, poster)) {
            SEND(void, long)(list, SELECTOR("setSelection:"), poster);
            sendProbeEvent(stack, 1);
            posterReturned = SEND(id)(stack, SELECTOR("peekController")) == menu && probeSelection(menu) == 0;
        }
        syslog(LOG_NOTICE, "RevivePlex: home Back probe tab=%d poster=%d", tabReturned, posterReturned);
        SEND(void, long)(list, SELECTOR("setSelection:"), previous);
        updateMediaLayout(menu, list);
    }
    if (screensOnly) runScreenProbes(menu, stack, probes, 0);
    else runSearchProbe(menu, stack);
}

static void autostart(unsigned int remaining)
{
    if (autoOpened) return;
    Class managerClass = objc_getClass("BRApplicationStackManager");
    Class homeClass = objc_getClass("ATVMainMenuController");
    if (!homeClass || !managerClass ||
        !class_getClassMethod(managerClass, SELECTOR("singleton"))) return;
    id manager = SEND(id)((id)managerClass, SELECTOR("singleton"));
    id stack = SEND(signed char, SEL)(manager, SELECTOR("respondsToSelector:"), SELECTOR("stack")) ?
        SEND(id)(manager, SELECTOR("stack")) : 0;
    id top = SEND(signed char, SEL)(stack, SELECTOR("respondsToSelector:"), SELECTOR("peekController")) ?
        SEND(id)(stack, SELECTOR("peekController")) : 0;
    if (SEND(signed char, Class)(top, SELECTOR("isKindOfClass:"), homeClass) &&
        SEND(signed char, SEL)(stack, SELECTOR("respondsToSelector:"), SELECTOR("pushController:"))) {
        revivePlexRefreshHome(^(id title, id rows) {
            if (autoOpened || SEND(id)(stack, SELECTOR("peekController")) != top) return;
            if (registeredAppliance && SEND(signed char, SEL)(top, SELECTOR("respondsToSelector:"),
                SELECTOR("_pushControllerForAppliance:"))) {
                SEND(void, id)(top, SELECTOR("_pushControllerForAppliance:"), registeredAppliance);
                id direct = SEND(id)(stack, SELECTOR("peekController"));
                if (SEND(signed char, Class)(direct, SELECTOR("isKindOfClass:"), menuClass)) {
                    autoOpened = 1;
                    stage("native appliance entry opened Plex directly");
                    if (revivePlexConsumeNavigationProbe())
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * (int64_t)NSEC_PER_SEC),
                            dispatch_get_main_queue(), ^{ runStartupProbe(direct, stack); });
                    return;
                }
                if (direct != top) {
                    stage("native appliance entry returned an unexpected screen");
                    return;
                }
            }
            id menu = makeMenu(NoScreen);
            if (!menu) return;
            objc_setAssociatedObject(menu, &sessionRootKey, @"root", 1);
            applyPlexSession(menu, title, rows);
            autoOpened = 1;
            stage("opening verified Plex screen from main menu");
            SEND(void, id)(stack, SELECTOR("pushController:"), menu);
            if (revivePlexConsumeNavigationProbe())
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * (int64_t)NSEC_PER_SEC),
                    dispatch_get_main_queue(), ^{ runStartupProbe(menu, stack); });
        });
        return;
    }
    if (remaining) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            autostart(remaining - 1);
        });
    } else {
        stage("automatic open skipped; main menu not ready");
    }
}
#endif

__attribute__((constructor))
static void registerRevivePlex(void)
{
    stage("bundle initializer entered");
    baseAppliance = objc_getClass("BRBaseAppliance");
    Class baseMenu = objc_getClass("BRMediaMenuController");
#ifdef REVIVEPLEX_PLAYBACK
    baseMenuClass = baseMenu;
#endif
    categoryClass = objc_getClass("BRApplianceCategory");
    menuItemClass = objc_getClass("BRMenuItem");
    themeClass = objc_getClass("BRThemeInfo");
    if (!baseAppliance || !baseMenu || !categoryClass || !menuItemClass || !themeClass) {
        stage("required BackRow class unavailable");
        return;
    }
    Protocol *protocol = objc_getProtocol("BRAppliance");
    if (!protocol || !class_conformsToProtocol(baseAppliance, protocol)) {
        stage("BRBaseAppliance does not declare BRAppliance");
        return;
    }
    if (!class_getInstanceMethod(baseAppliance, SELECTOR("initWithApplianceInfo:")) ||
        !class_getInstanceMethod(baseMenu, SELECTOR("list")) ||
        !class_getInstanceMethod(baseMenu, SELECTOR("stack")) ||
        !class_getInstanceMethod(baseMenu, SELECTOR("setListTitle:")) ||
        !class_getInstanceMethod(menuItemClass, SELECTOR("setText:withAttributes:")) ||
        !class_getInstanceMethod(themeClass, SELECTOR("menuItemTextAttributes")) ||
        !class_getClassMethod(themeClass, SELECTOR("sharedTheme")) ||
        !class_getClassMethod(categoryClass, SELECTOR("categoryWithName:identifier:preferredOrder:"))) {
        stage("required BackRow selector unavailable");
        return;
    }

    menuClass = objc_allocateClassPair(baseMenu, "RevivePlexLibraryMenu", 0);
    Class appliance = objc_allocateClassPair(baseAppliance, "RevivePlexAppliance", 0);
    if (menuClass && appliance &&
#ifdef REVIVEPLEX_PLAYBACK
        class_getInstanceMethod(baseMenu, SELECTOR("wasPushed")) &&
        class_getInstanceMethod(baseMenu, SELECTOR("wasPopped")) &&
        class_getInstanceMethod(baseMenu, SELECTOR("controlWasActivated")) &&
        installMethod(menuClass, baseMenu, "controlWasActivated", (MenuIMP)menuControlActivated, "v@:") &&
#ifdef REVIVEPLEX_ARTWORK
        class_getInstanceMethod(baseMenu, SELECTOR("brEventAction:")) &&
        installMethod(menuClass, baseMenu, "brEventAction:", (MenuIMP)eventWithPoster, "c@:@") &&
#endif
        installMethod(menuClass, baseMenu, "wasPushed", (MenuIMP)playerWasPushed, "v@:") &&
        installMethod(menuClass, baseMenu, "wasPopped", (MenuIMP)playerWasPopped, "v@:") &&
#endif
        installMethod(menuClass, baseMenu, "itemCount", (MenuIMP)itemCount, "l@:") &&
        installMethod(menuClass, baseMenu, "heightForRow:", (MenuIMP)heightForRow, "f@:l") &&
        installMethod(menuClass, baseMenu, "rowSelectable:", (MenuIMP)rowSelectable, "c@:l") &&
        installMethod(menuClass, baseMenu, "titleForRow:", (MenuIMP)titleForRow, "@@:l") &&
        installMethod(menuClass, baseMenu, "itemForRow:", (MenuIMP)itemForRow, "@@:l") &&
        installMethod(menuClass, baseMenu, "controlCount", (MenuIMP)itemCount, "l@:") &&
        installMethod(menuClass, baseMenu, "controlAtIndex:requestedBy:", (MenuIMP)controlAtIndex, "@@:l@") &&
        installMethod(menuClass, baseMenu, "itemSelected:", (MenuIMP)itemSelected, "v@:l") &&
        installMethod(appliance, baseAppliance, "initWithApplianceInfo:", (MenuIMP)applianceInit, "@@:@") &&
#ifdef REVIVEPLEX_PRODUCTION
        installMethod(appliance, baseAppliance, "applianceController", (MenuIMP)applianceController, "@@:") &&
#endif
        installMethod(appliance, baseAppliance, "applianceCategories", (MenuIMP)categories, "@@:") &&
        installMethod(appliance, baseAppliance, "controllerForIdentifier:args:", (MenuIMP)controller, "@@:@@")) {
        objc_registerClassPair(menuClass);
        objc_registerClassPair(appliance);
        stage("principal class registered");
#ifdef REVIVEPLEX_PRODUCTION
        installLegacyEntryBridge();
#endif
#ifdef REVIVEPLEX_AUTOSTART
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * (int64_t)NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{ autostart(20); });
#endif
    } else {
        stage("principal or menu class registration failed");
        if (menuClass) objc_disposeClassPair(menuClass);
        if (appliance) objc_disposeClassPair(appliance);
        menuClass = 0;
    }
}
