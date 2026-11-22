#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdlib.h>

#ifndef WITHOUT_APPLIANCE_PROTOCOL
@protocol BRAppliance <NSObject>
- (id)initWithApplianceInfo:(id)info;
@end
@interface BRBaseAppliance : NSObject <BRAppliance>
#else
@interface BRBaseAppliance : NSObject
#endif
- (id)initWithApplianceInfo:(id)info;
@end
@implementation BRBaseAppliance
- (id)initWithApplianceInfo:(id)info { return [self init]; }
@end

@interface BRApplianceCategory : NSObject
+ (id)categoryWithName:(id)name identifier:(id)identifier preferredOrder:(float)order;
@end
@implementation BRApplianceCategory
+ (id)categoryWithName:(id)name identifier:(id)identifier preferredOrder:(float)order
{
    return [NSDictionary dictionaryWithObjectsAndKeys:name, @"name", identifier, @"id",
            [NSNumber numberWithFloat:order], @"order", nil];
}
@end

@interface BRControllerStack : NSObject
@property (retain) id top;
- (void)pushController:(id)controller;
@end
@implementation BRControllerStack
- (void)pushController:(id)controller { self.top = controller; }
- (void)dealloc { [_top release]; [super dealloc]; }
@end

@interface BRMediaMenuController : NSObject
@property (retain) BRControllerStack *stack;
@property (copy) NSString *listTitle;
@property (assign) id datasource;
- (id)list;
- (void)reload;
- (void)itemSelected:(long)row;
@end
@implementation BRMediaMenuController
- (id)list { return self; }
- (void)reload {}
- (void)dealloc { [_stack release]; [_listTitle release]; [super dealloc]; }
- (void)itemSelected:(long)row { abort(); }
@end

@interface BRThemeInfo : NSObject
+ (id)sharedTheme;
- (id)menuItemTextAttributes;
@end
@implementation BRThemeInfo
+ (id)sharedTheme { return [[[self alloc] init] autorelease]; }
- (id)menuItemTextAttributes { return [NSDictionary dictionary]; }
@end

@interface BRMenuItem : NSObject
@property (copy) NSString *text;
- (void)setText:(id)text withAttributes:(id)attributes;
@end
@implementation BRMenuItem
- (void)setText:(id)text withAttributes:(id)attributes { self.text = text; }
@end

@interface NSObject (FixtureSelectors)
- (id)applianceCategories;
- (id)controllerForIdentifier:(id)identifier args:(id)args;
- (long)itemCount;
- (id)itemForRow:(long)row;
- (id)titleForRow:(long)row;
- (float)heightForRow:(long)row;
- (signed char)rowSelectable:(long)row;
@end

static void verify(BOOL assertion, const char *message)
{
    if (!assertion) {
        fprintf(stderr, "%s\n", message);
        exit(1);
    }
}

static void waitForRows(BRMediaMenuController *menu)
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while ([[menu titleForRow:0] isEqual:@"Yükleniyor…"] && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"RevivePlexLanguage":@"tr"}];
        verify(argc == 2, "fixture requires a bundle path");
        void *bundle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!bundle) {
            fprintf(stderr, "%s\n", dlerror());
            return 1;
        }
        Class principal = NSClassFromString(@"RevivePlexAppliance");
#ifdef WITHOUT_APPLIANCE_PROTOCOL
        verify(principal == Nil, "principal class registered on incompatible host");
        puts("Bundle mapped without registering a principal on an incompatible host.");
        return 0;
#endif
        verify(principal != Nil, "principal class not registered");
        id appliance = [[[principal alloc] initWithApplianceInfo:nil] autorelease];
        NSArray *categories = [appliance applianceCategories];
        verify([categories count] == 1, "expected one category");
        id category = [categories objectAtIndex:0];
        verify([[category objectForKey:@"name"] isEqual:@"Plex"], "category name mismatch");
        id identifier = [category objectForKey:@"id"];
        verify([appliance controllerForIdentifier:@"unknown" args:nil] == nil, "unknown category accepted");
        BRMediaMenuController *menu = [appliance controllerForIdentifier:identifier args:nil];
        verify(menu.datasource == menu, "list datasource missing");
        verify([menu itemCount] == 6 && [menu itemForRow:6] == nil, "home bounds mismatch");
        verify([[menu titleForRow:0] isEqual:@"Filmler"], "first preview title mismatch");
        verify([menu titleForRow:-1] == nil, "negative preview index accepted");
        verify([menu heightForRow:0] > 0 && [menu heightForRow:6] == 0, "row heights mismatch");
        verify([menu rowSelectable:0] && ![menu rowSelectable:-1], "home row selectability mismatch");
        verify([[[menu itemForRow:0] text] isEqual:[menu titleForRow:0]], "item and preview titles differ");

        BRControllerStack *stack = [[[BRControllerStack alloc] init] autorelease];
        menu.stack = stack;
        NSArray *titles = @[@"Filmler", @"Diziler", @"İzlemeye devam et", @"Ara", @"Ayarlar"];
        NSArray *childTitles = @[@"Kıyı", @"Gece Hattı", @"Kıyı", @"Arama sonuçları · Kıyı",
                                 @"Sunucu bağlantısı"];
        for (NSUInteger index = 0; index < titles.count; index++) {
            [menu itemSelected:(long)index];
            BRMediaMenuController *section = stack.top;
            verify([section.listTitle isEqual:titles[index]], "wrong Home destination");
            section.stack = stack;
            [section itemSelected:0];
            BRMediaMenuController *child = stack.top;
            verify([child.listTitle isEqual:childTitles[index]], "wrong child destination");
            if (index == 1) {
                child.stack = stack;
                [child itemSelected:0];
                BRMediaMenuController *season = stack.top;
                verify([season.listTitle isEqual:@"1. Sezon"], "season unavailable");
                season.stack = stack;
                [season itemSelected:0];
                verify([[stack.top listTitle] isEqual:@"Son Sefer"], "episode unavailable");
                season.stack = nil;
                child.stack = nil;
            } else if (index == 4) {
                verify(![child rowSelectable:0] && [child heightForRow:0] > 0,
                       "information row should be visible and nonselectable");
            }
            section.stack = nil;
            stack.top = nil;
        }
        [menu itemSelected:6];
        verify(stack.top == nil, "invalid selection pushed a controller");
        [menu itemSelected:5];
        BRMediaMenuController *live = stack.top;
        verify([live.listTitle isEqual:@"Plex Kütüphanesi"], "live menu missing");
        live.stack = stack;
        [live itemSelected:3];
        BRMediaMenuController *sections = stack.top;
        verify([[sections titleForRow:0] isEqual:@"Yükleniyor…"], "loading state missing");
        waitForRows(sections);
        verify([[sections titleForRow:0] isEqual:@"Movies"] && [sections rowSelectable:0],
               "live library section unavailable");
        sections.stack = stack;
        [sections itemSelected:0];
        BRMediaMenuController *movies = stack.top;
        waitForRows(movies);
        verify([[movies titleForRow:3] isEqual:@"Fixture Movie"], "fixture movie missing");
        movies.stack = stack;
        [movies itemSelected:3];
        BRMediaMenuController *detail = stack.top;
        waitForRows(detail);
        verify([[detail titleForRow:0] isEqual:@"Oynat"] && [detail rowSelectable:0] &&
               [detail itemCount] == 1, "detail mixed static metadata into action navigation");
        void (*refreshHome)(void (^)(id, id)) = dlsym(bundle, "revivePlexRefreshHome");
        long (*nextFocus)(id, long, int) = dlsym(bundle, "revivePlexHomeRailTarget");
        verify(refreshHome && nextFocus, "Plex home test entry points missing");
        __block BOOL homeVerified = NO;
        refreshHome(^(id title, id home) {
            (void)title;
            verify([home[1][@"title"] isEqual:@"Plex Continue"], "Plex hub title replaced");
            verify([home[2][@"title"] isEqual:@"Movies"] &&
                [home[2][@"route"][@"path"] isEqual:@"/library/sections/1/all"], "Movies has an intermediate menu");
            verify([home[3][@"title"] isEqual:@"TV Shows"], "TV Shows title replaced");
            verify([home[0][@"title"] isEqual:@"Ara"], "Search missing from top menu");
            verify([home[6][@"cardTitle"] isEqual:@"Fixture Series"] &&
                [home[6][@"railTitle"] isEqual:@"Plex Continue"], "Series or rail title lost");
            verify([home[7][@"railTitle"] isEqual:@"Fresh from Plex"], "Recent hub title replaced");
            verify(nextFocus(home, 0, 7) == 1 && nextFocus(home, 1, 6) == 0 &&
                nextFocus(home, 1, 4) == 6 && nextFocus(home, 6, 3) == 0, "direction mapping mismatch");
            verify([home[4][@"title"] isEqual:@"Fixture Watchlist"], "Watchlist title not supplied by Plex");
            homeVerified = YES;
        });
        NSDate *homeDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!homeVerified && [homeDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(homeVerified, "Plex home refresh timed out");
        id (*dvrRows)(id, id) = dlsym(bundle, "revivePlexDVRRows");
        verify(dvrRows != NULL, "DVR route parser missing");
        NSDictionary *dvr = @{@"MediaContainer":@{@"Dvr":@[@{@"key":@1, @"name":@"Antenna", @"ChannelMapping":@[
            @{@"deviceIdentifier":@"2.1", @"title":@"Fixture TV", @"enabled":@1},
            @{@"deviceIdentifier":@"2.2", @"enabled":@0},
            @{@"deviceIdentifier":@"../invalid", @"enabled":@1}, [NSNull null]]}]}};
        NSArray *tuners = dvrRows(dvr, nil), *channels = dvrRows(dvr, @"1");
        verify(tuners.count == 1 && [tuners[0][@"route"][@"dvrID"] isEqual:@"1"], "DVR numeric identity lost");
        verify(channels.count == 1 && [channels[0][@"title"] isEqual:@"Fixture TV"] &&
            [channels[0][@"route"][@"liveChannel"] isEqual:@"2.1"], "Disabled/invalid channels were not excluded");
        verify([dvrRows(@{@"MediaContainer":[NSNull null]}, nil) count] == 0 &&
            [dvrRows(dvr, @"2") count] == 0, "Malformed or wrong DVR data accepted");
        id (*searchKeyboard)(id, int, id) = dlsym(bundle, "revivePlexSearchKeyboard");
        id (*searchRoute)(id) = dlsym(bundle, "revivePlexSearchRoute");
        long (*searchTarget)(id, long, int) = dlsym(bundle, "revivePlexSearchTarget");
        id (*editSearch)(id, id) = dlsym(bundle, "revivePlexEditSearch");
        void (*loadRows)(id, void (^)(id)) = dlsym(bundle, "revivePlexLoadRows");
        verify(searchKeyboard && searchRoute && searchTarget && editSearch && loadRows, "search test entry points missing");
        id (*resumeEpisode)(id) = dlsym(bundle, "revivePlexResumeEpisode");
        void (*quickPlay)(id, void (^)(id)) = dlsym(bundle, "revivePlexQuickPlayRoute");
        signed char (*canQuickPlay)(id) = dlsym(bundle, "revivePlexCanQuickPlay");
        verify(resumeEpisode && quickPlay && canQuickPlay, "Quick Play entry points missing");
        id (*resumeOptions)(id) = dlsym(bundle, "revivePlexResumeOptionsRoute");
        NSDictionary *returnOptionsRoute = @{@"kind":@"playbackOptions", @"path":@"/library/metadata/71", @"resume":@123.5, @"mediaIndex":@1, @"queueSnapshot":@{@"id":@"55"}};
        NSDictionary *backRoute = resumeOptions(returnOptionsRoute);
        verify([backRoute[@"kind"] isEqual:@"transcode"] && [backRoute[@"resume"] doubleValue] == 123.5 && [backRoute[@"path"] isEqual:returnOptionsRoute[@"path"]] && [backRoute[@"queueSnapshot"] isEqual:returnOptionsRoute[@"queueSnapshot"]] && [backRoute[@"mediaIndex"] intValue] == 1, "Options Back must resume with position, version and queue intact even before rows load");
        NSDictionary *older = @{@"type":@"episode", @"ratingKey":@"1", @"viewOffset":@10000, @"duration":@60000, @"lastViewedAt":@100};
        NSDictionary *recent = @{@"type":@"episode", @"ratingKey":@"2", @"viewOffset":@20000, @"duration":@60000, @"lastViewedAt":@200};
        verify([resumeEpisode(@[older, recent]) isEqual:recent] && [resumeEpisode(@[recent, older]) isEqual:recent], "Series Play must resume most recently viewed unfinished episode");
        verify(!canQuickPlay(@{@"kind":@"settings"}), "Play must not activate unrelated menu items");
        __block BOOL quickVerified = NO;
        quickPlay(@{@"kind":@"series", @"path":@"/library/metadata/61"}, ^(NSDictionary *route) {
            verify([route[@"kind"] isEqual:@"transcode"] && [route[@"path"] isEqual:@"/library/metadata/63"] && [route[@"resume"] doubleValue] == 40, "Series Play lost episode or two-second resume allowance");
            quickVerified = YES;
        });
        NSDate *quickDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!quickVerified && [quickDeadline timeIntervalSinceNow] > 0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(quickVerified, "Quick Play resolution timed out");
        __block BOOL movieQuickVerified = NO;
        quickPlay(@{@"kind":@"detail", @"path":@"/library/metadata/71"}, ^(NSDictionary *route) {
            verify([route[@"kind"] isEqual:@"transcode"] && [route[@"path"] isEqual:@"/library/metadata/71"] && [route[@"resume"] doubleValue] == 12, "Movie Play lost saved position");
            movieQuickVerified = YES;
        });
        NSDate *movieQuickDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!movieQuickVerified && [movieQuickDeadline timeIntervalSinceNow] > 0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(movieQuickVerified, "Movie Quick Play timed out");
        long (*shelfTarget)(id, long, int, long) = dlsym(bundle, "revivePlexShelfTarget");
        __block BOOL catalogVerified = NO;
        loadRows(@{@"kind":@"media", @"path":@"/library/sections/1/all", @"title":@"Movies"}, ^(NSArray *rows) {
            verify([rows[0][@"toolbarCount"] intValue] == 3 && rows.count == 4 &&
                shelfTarget(rows, 3, 3, 6) == 0 && shelfTarget(rows, 0, 4, 6) == 3 &&
                shelfTarget(rows, 2, 7, 6) == 2 && shelfTarget(rows, 3, 4, 6) == 3,
                "Catalog toolbar trapped focus or replaced content");
            catalogVerified = YES;
        });
        NSDate *catalogDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!catalogVerified && [catalogDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(catalogVerified, "Catalog toolbar timed out");
        signed char (*preserveVideo)(id, id) = dlsym(bundle, "revivePlexCanPreserveVideo");
        NSMutableDictionary *sourceMedia = [@{@"width":@1280, @"height":@720, @"videoCodec":@"h264", @"bitrate":@2500} mutableCopy];
        NSMutableDictionary *videoStream = [@{@"streamType":@1, @"frameRate":@23.976, @"level":@40, @"bitDepth":@8} mutableCopy];
        NSDictionary *videoPart = @{@"media":sourceMedia, @"streams":@[videoStream]};
        verify(preserveVideo(videoPart, @"1080") && preserveVideo(videoPart, @"720") && !preserveVideo(videoPart, @"480"), "Original video eligibility ignores the selected quality ceiling");
        videoStream[@"bitDepth"] = @10;
        verify(!preserveVideo(videoPart, @"1080"), "Unsupported H264 10-bit must transcode");
        videoStream[@"bitDepth"] = @8; videoStream[@"frameRate"] = @60;
        verify(!preserveVideo(videoPart, @"1080"), "Unsupported frame rate must transcode");
        videoStream[@"frameRate"] = @24; sourceMedia[@"videoCodec"] = @"hevc";
        verify(!preserveVideo(videoPart, @"1080"), "HEVC must transcode on Apple TV 3");
        __block BOOL sortVerified = NO;
        NSMutableDictionary *sortState = [@{@"parameters":@{@"genre":@"7"}} mutableCopy];
        loadRows(@{@"kind":@"sort", @"path":@"/library/sections/1/all", @"title":@"Sort", @"filterState":sortState}, ^(NSArray *sorts) {
            verify(!sorts[3][@"route"] && [sorts[3][@"action"] isEqual:@"setSort"], "Sorting must update the current catalog, not push another catalog");
            void (*applySortAction)(id, void (^)(signed char)) = dlsym(bundle, "revivePlexApplyMediaAction");
            applySortAction(sorts[3], ^(signed char success) {
                verify(success && [sortState[@"parameters"][@"sort"] isEqual:@"year:desc"] && [sortState[@"parameters"][@"genre"] isEqual:@"7"], "Sorting lost shared filters");
                loadRows(@{@"kind":@"sort", @"path":@"/library/sections/1/all", @"title":@"Sort", @"filterState":sortState}, ^(NSArray *again) {
                    verify([again[3][@"title"] hasPrefix:@"✓ "], "Sorting selection not preserved on reopen");
                    sortVerified = YES;
                });
            });
        });
        NSDate *sortDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!sortVerified && [sortDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(sortVerified, "Sort round trip timed out");
        __block BOOL filterVerified = NO;
        NSDictionary *filterSource = @{@"kind":@"media", @"path":@"/library/sections/1/all", @"title":@"Movies",
            @"parameters":@{@"genre":@"7", @"unwatched":@"0", @"sort":@"year:desc"}};
        loadRows(filterSource, ^(NSArray *rows) {
            verify([rows[1][@"filterCount"] intValue] == 2 && [rows[0][@"sortTitle"] isEqual:@"Yıla göre"], "Filter badge or active sorting label missing");
            loadRows(rows[1][@"route"], ^(NSArray *filters) {
                verify([filters[0][@"title"] hasPrefix:@"✓ "] && [filters[0][@"panel"][@"filterGrid"] boolValue], "Active filter category/grid missing");
                loadRows(filters[0][@"route"], ^(NSArray *values) {
                    verify(values.count == 3 && [values[1][@"title"] isEqual:@"✓ Drama"] &&
                        ![values[2][@"title"] hasPrefix:@"✓ "] && [values[0][@"panel"][@"filterGrid"] boolValue], "Selected genre not marked in grid");
                    id (*toggleFilter)(id, id) = dlsym(bundle, "revivePlexToggleFilterRows");
                    NSArray *changed = toggleFilter(values, values[2]);
                    verify([changed[2][@"title"] isEqual:@"✓ Comedy"] && [changed[1][@"title"] isEqual:@"Drama"], "Filter toggling reordered or failed to update rows");
                    verify([changed[2][@"filterState"][@"parameters"][@"unwatched"] isEqual:@"0"], "Changing genre dropped another filter");
                    NSArray *cleared = toggleFilter(changed, changed[2]);
                    verify(!cleared[2][@"filterState"][@"parameters"][@"genre"] && [cleared[2][@"title"] isEqual:@"Comedy"], "Selected filter cannot be removed in place");
                    toggleFilter(cleared, cleared[2]);
                    loadRows(filters[0][@"route"], ^(NSArray *reopened) {
                        verify([reopened[1][@"title"] isEqual:@"✓ Comedy"] && [reopened[2][@"title"] isEqual:@"Drama"], "Selected filter not first on reopen");
                        toggleFilter(filters, [filters lastObject]);
                        NSDictionary *state = reopened[1][@"filterState"];
                        verify([state[@"parameters"] count] == 1 && [state[@"parameters"][@"sort"] isEqual:@"year:desc"], "Clear filters changed sorting or retained a filter");
                        loadRows(@{@"kind":@"media", @"path":@"/library/sections/1/all", @"title":@"Movies", @"filterState":state}, ^(NSArray *catalog) {
                            verify([catalog[1][@"filterCount"] intValue] == 0 && [catalog[0][@"sortTitle"] isEqual:@"Yıla göre"], "Catalog did not reflect shared filter state on return");
                            filterVerified = YES;
                        });
                    });
                });
            });
        });
        NSDate *filterDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!filterVerified && [filterDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(filterVerified, "Filter round trip timed out");
        verify([editSearch(@"Ç A", @"") isEqual:@"Ç "], "search deletion failed");
        verify(!searchRoute(@"   "), "empty text should not trigger Plex requests");
        __block BOOL searchVerified = NO;
        loadRows(searchRoute(@"Ç A"), ^(NSArray *matches) {
            verify(matches.count == 2 && [matches[0][@"title"] isEqual:@"Fixture Movie"] &&
                [matches[1][@"title"] isEqual:@"Fixture Series"], "server-wide search lost matches");
            NSArray *screen = searchKeyboard(@"Ç A", 0, matches);
            long keys = [screen[0][@"searchKeyCount"] longValue];
            verify(keys > 19 && keys <= 38 && screen.count == keys + 2 &&
                searchTarget(screen, 0, 4) == 19 && searchTarget(screen, 19, 4) == keys &&
                searchTarget(screen, keys, 3) == 19 && searchTarget(screen, keys, 7) == keys + 1,
                "keyboard and result focus did not connect");
            NSMutableArray *many = [NSMutableArray array];
            for (int n = 0; n < 843; n++) [many addObject:matches[0]];
            NSArray *paged = searchKeyboard(@"Ç A", 0, many);
            verify(paged.count == keys + 843 && searchTarget(paged, keys + 8, 4) == keys + 16 &&
                searchTarget(paged, keys + 16, 3) == keys + 8 && searchTarget(paged, keys + 842, 4) == keys + 842,
                "Search truncated results or broke page boundary focus");
            NSArray *numeric = searchKeyboard(@"Ç A", 1, matches);
            verify([numeric[0][@"title"] isEqual:@"ABC"] &&
                searchTarget(numeric, 0, 4) == [numeric[0][@"searchKeyCount"] longValue],
                "number keyboard result target mismatch");
            searchVerified = YES;
        });
        NSDate *searchDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!searchVerified && [searchDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(searchVerified, "search timed out");
        for (NSString *kind in @[@"media", @"photo", @"cast", @"chapters", @"extras"]) {
            __block BOOL verified = NO;
            NSString *path = [kind isEqual:@"media"] ? @"/library/metadata/100/children" :
                ([kind isEqual:@"photo"] ? @"/library/metadata/101" : @"/library/metadata/99");
            loadRows(@{@"kind":kind, @"path":path, @"title":@"Fixture"}, ^(NSArray *rows) {
                if ([kind isEqual:@"media"])
                    verify([rows[0][@"route"][@"kind"] isEqual:@"photo"], "Photo became a folder or disappeared");
                else if ([kind isEqual:@"photo"])
                    verify([rows[0][@"panel"][@"photo"] isEqual:@"/library/metadata/101/thumb/1"], "Photo viewer missing image");
                else if ([kind isEqual:@"chapters"]) verify([rows[0][@"title"] isEqual:@"Opening"] &&
                    [rows[0][@"route"][@"resume"] doubleValue] == 62.5, "Chapter seek position lost");
                else if ([kind isEqual:@"extras"]) verify([rows[0][@"route"][@"path"] isEqual:@"/library/metadata/98"], "Extra route missing");
                else verify([rows[0][@"title"] isEqual:@"An Actor"] &&
                    [rows[0][@"catalogCaption"] isEqual:@"A role"] && [rows[0][@"route"][@"path"] isEqual:@"/library/people/123/media"], "Cast lost actor, role or library route");
                verified = YES;
            });
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
            while (!verified && [deadline timeIntervalSinceNow] > 0)
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            verify(verified, "Photo/cast timed out");
        }
        for (NSString *key in @[@"61", @"64", @"65", @"66"]) {
            __block BOOL finished = NO;
            loadRows(@{@"kind":@"cast", @"path":[@"/library/metadata/" stringByAppendingString:key], @"title":@"Cast"}, ^(NSArray *rows) {
                if ([key isEqual:@"65"]) verify(rows[0][@"panel"] != nil, "Missing cast should show an empty-state panel");
                else verify([rows[0][@"title"] isEqual:[key isEqual:@"66"] ? @"Guest Actor" : @"An Actor"], "Cast fallback lost show cast or replaced episode guest cast");
                finished = YES;
            });
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
            while (!finished && [deadline timeIntervalSinceNow] > 0)
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            verify(finished, "Cast fallback timed out");
        }
        __block BOOL watchlistVerified = NO;
        loadRows(@{@"kind":@"watchlist", @"path":@"", @"title":@"Watchlist"}, ^(NSArray *rows) {
            verify(rows.count == 1 && [rows[0][@"catalogCaption"] isEqual:@"2024"], "Cloud Watchlist metadata lost");
            loadRows(rows[0][@"route"], ^(NSArray *detailRows) {
                verify([detailRows[0][@"panel"][@"title"] isEqual:@"Fixture Movie"], "Watchlist did not resolve local library item");
                watchlistVerified = YES;
            });
        });
        NSDate *watchlistDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!watchlistVerified && [watchlistDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(watchlistVerified, "Watchlist verification timed out");
        for (NSString *kind in @[@"discoverResults", @"subtitleSearch"]) {
            __block BOOL ready = NO;
            loadRows(@{@"kind":kind, @"path":@"/library/metadata/99/subtitles", @"query":@"Fixture", @"language":@"tr", @"title":@"Search"}, ^(NSArray *rows) {
                if ([kind isEqual:@"discoverResults"])
                    verify(rows.count == 1 && [rows[0][@"route"][@"kind"] isEqual:@"cloudItem"], "Discover failed to discard malformed cloud results");
                else verify(rows.count == 1 && [rows[0][@"subtitleKey"] isEqual:@"/library/streams/994"] && [rows[0][@"action"] isEqual:@"downloadSubtitle"], "Online subtitle route lost validated stream");
                ready = YES;
            });
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
            while (!ready && [deadline timeIntervalSinceNow] > 0)
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            verify(ready, "Cloud/subtitle fixture timed out");
        }
        void (*applyAction)(id, void (^)(signed char)) = dlsym(bundle, "revivePlexApplyMediaAction");
        __block BOOL recordingReady = NO;
        loadRows(@{@"kind":@"recordingRules", @"path":@""}, ^(NSArray *rules) {
            verify([rules[0][@"title"] isEqual:@"Fixture recording"], "Recording rule title missing");
            loadRows(rules[0][@"route"], ^(NSArray *settings) {
                loadRows(settings[0][@"route"], ^(NSArray *choices) {
                    verify([choices[1][@"title"] isEqual:@"New episodes"], "Server recording preference labels lost");
                    applyAction(choices[1], ^(signed char saved) {
                        verify(saved, "Recording preference PUT failed");
                        loadRows([settings lastObject][@"route"], ^(NSArray *confirmation) {
                            applyAction(confirmation[0], ^(signed char removed) { verify(removed, "Recording rule deletion failed"); recordingReady = YES; });
                        });
                    });
                });
            });
        });
        NSDate *recordingDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!recordingReady && [recordingDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(recordingReady, "Recording rule editing timed out");
        __block BOOL scheduleReady = NO;
        loadRows(@{@"kind":@"recordingSchedule", @"path":@""}, ^(NSArray *rows) {
            verify([rows[0][@"title"] isEqual:@"Fixture Series"], "Schedule lost series name");
            loadRows(rows[0][@"route"], ^(NSArray *info) {
                verify([info[0][@"panel"][@"longText"] rangeOfString:@"Next episode"].location != NSNotFound, "Schedule details missing"); scheduleReady = YES;
            });
        });
        NSDate *scheduleDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!scheduleReady && [scheduleDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(scheduleReady, "Recording schedule timed out");
        __block BOOL pickerReady = NO;
        loadRows(@{@"kind":@"playlistPicker", @"path":@"/playlists", @"ratingKey":@"99", @"playlistType":@"video", @"itemTitle":@"Fixture list"}, ^(NSArray *rows) {
            verify(rows.count == 2 && [rows[1][@"playlistID"] isEqual:@"55"], "Playlist picker allowed smart or wrong media type");
            id (*nameRows)(id, id, int) = dlsym(bundle, "revivePlexPlaylistNameRows");
            NSArray *editor = nameRows(rows[0][@"route"], @"Fixture list", 0);
            verify([editor[0][@"searchKeyCount"] unsignedIntegerValue] == editor.count && editor.count <= 40, "Playlist name keyboard escaped two rows");
            applyAction([editor lastObject], ^(signed char created) {
                verify(created, "Playlist creation failed");
                applyAction(rows[1], ^(signed char added) {
                    verify(added, "Playlist item addition failed");
                    NSArray *rename = nameRows(@{@"playlistID":@"55"}, @"Renamed fixture", 0);
                    applyAction([rename lastObject], ^(signed char renamed) { verify(renamed, "Playlist rename failed"); pickerReady = YES; });
                });
            });
        });
        NSDate *pickerDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!pickerReady && [pickerDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(pickerReady, "Playlist editing timed out");
        __block BOOL editReady = NO;
        loadRows(@{@"kind":@"playlistEdit", @"path":@"/playlists/55/items", @"playlistID":@"55"}, ^(NSArray *rows) {
            verify(rows.count == 2 && [rows[0][@"route"][@"downAfter"] isEqual:@"702"] && !rows[0][@"route"][@"upAfter"], "Playlist reorder boundaries wrong");
            loadRows(rows[0][@"route"], ^(NSArray *actions) {
                applyAction(actions[0], ^(signed char moved) {
                    verify(moved, "Playlist item move failed");
                    applyAction([actions lastObject], ^(signed char removed) { verify(removed, "Playlist item removal failed"); editReady = YES; });
                });
            });
        });
        NSDate *editDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!editReady && [editDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(editReady, "Playlist item editing timed out");
        __block BOOL emptyReady = NO;
        loadRows(@{@"kind":@"media", @"path":@"/playlists/56/items", @"title":@"Empty"}, ^(NSArray *rows) {
            verify([rows[0][@"route"][@"kind"] isEqual:@"playlistManage"], "Empty playlist lost management access"); emptyReady = YES;
        });
        NSDate *emptyDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!emptyReady && [emptyDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(emptyReady, "Empty playlist timed out");
        __block BOOL subtitleReady = NO;
        NSDate *subtitleStarted = [NSDate date];
        applyAction(@{@"action":@"downloadSubtitle", @"subtitlePath":@"/library/metadata/99/subtitles", @"subtitleKey":@"/library/streams/994"}, ^(signed char success) {
            verify(success && -[subtitleStarted timeIntervalSinceNow] >= 1.8, "Subtitle completion reported before downloaded stream appeared");
            subtitleReady = YES;
        });
        NSDate *subtitleDeadline = [NSDate dateWithTimeIntervalSinceNow:8];
        while (!subtitleReady && [subtitleDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(subtitleReady, "Asynchronous subtitle download timed out");
        id (*pinRows)(id, id) = dlsym(bundle, "revivePlexHomePINRows");
        id (*editPin)(id, id) = dlsym(bundle, "revivePlexEditHomePIN");
        NSArray *pinScreen = pinRows(@"7", @"");
        for (NSString *digit in @[@"0", @"1", @"2", @"3", @"4", @"A"]) pinScreen = editPin(pinScreen, digit);
        verify([pinScreen[0][@"pin"] isEqual:@"0123"] && ![pinScreen[0][@"searchText"] containsString:@"0123"], "Home PIN length or masking failed");
        pinScreen = editPin(pinScreen, @"");
        verify([pinScreen[0][@"pin"] isEqual:@"012"] && [[pinScreen lastObject][@"userID"] isEqual:@"7"], "Home PIN deletion lost user context");
        __block BOOL playlistVerified = NO;
        loadRows(@{@"kind":@"media", @"path":@"/playlists/55/items", @"title":@"Playlist"}, ^(NSArray *rows) {
            verify(rows.count == 6 && [rows[0][@"toolbarCount"] intValue] == 4, "Playlist controls replaced content");
            verify([rows[1][@"route"][@"shuffle"] boolValue] && [rows[2][@"route"][@"repeat"] boolValue], "Playlist modes missing");
            verify([rows[4][@"route"][@"playlistID"] isEqual:@"55"], "Playlist context lost entering detail");
            playlistVerified = YES;
        });
        NSDate *playlistDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!playlistVerified && [playlistDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(playlistVerified, "Playlist verification timed out");
        void (*beginQueue)(id, id, void (^)(id)) = dlsym(bundle, "revivePlexBeginPlaybackRoute");
        void (*nextQueueItem)(id, void (^)(id)) = dlsym(bundle, "revivePlexNextEpisode");
        id (*skipAction)(id, double) = dlsym(bundle, "revivePlexPlaybackSkipAction");
        void (*continueQueue)(id, id) = dlsym(bundle, "revivePlexContinueQueue");
        long (*preferredMedia)(id, id) = dlsym(bundle, "revivePlexPreferredMediaIndex");
        verify(preferredMedia(@[@{@"media":@{@"width":@3840, @"videoCodec":@"hevc", @"mediaIndex":@0}}, @{@"media":@{@"width":@1920, @"videoCodec":@"h264", @"mediaIndex":@1}}], @"1080") == 1, "Heavy 4K source chosen over compatible 1080p version");
        __block BOOL versionReady = NO;
        beginQueue(@{@"path":@"/library/metadata/100"}, @"version-fixture", ^(NSURL *url) {
            verify([url.path containsString:@"version-fixture"], "Preferred version not passed to transcoder");
            id (*optionsRoute)(id, double) = dlsym(bundle, "revivePlexPlaybackOptionsRoute");
            verify([optionsRoute(@"version-fixture", 12)[@"mediaIndex"] intValue] == 1, "Playback resume lost selected version");
            NSMutableDictionary *recovery = [optionsRoute(@"version-fixture", 12) mutableCopy]; recovery[@"playbackError"] = @"Fixture playback failure";
            loadRows(recovery, ^(NSArray *options) {
                verify([options[0][@"route"][@"resume"] doubleValue] == 12 && [options[0][@"panel"][@"summary"] isEqual:@"Fixture playback failure"], "Recovery lost position or error message");
                BOOL foundVersion = NO;
                for (NSDictionary *option in options) if ([option[@"route"][@"kind"] isEqual:@"versions"]) foundVersion = YES;
                verify(foundVersion, "Playback recovery cannot choose another version");
            });
            loadRows(@{@"kind":@"versions", @"path":@"/library/metadata/100"}, ^(NSArray *rows) {
                verify(rows.count == 2 && [rows[1][@"route"][@"mediaIndex"] intValue] == 1, "Manual version chooser missing");
                loadRows(@{@"kind":@"streams", @"path":@"/library/metadata/100", @"streamType":@2}, ^(NSArray *streams) {
                    verify([streams[0][@"partID"] isEqual:@"1001"] && [streams[0][@"streamID"] isEqual:@"1002"], "Stream selection targeted wrong media version");
                    versionReady = YES;
                });
            });
        });
        NSDate *versionDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!versionReady && [versionDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(versionReady, "Version selection timed out");
        __block BOOL liveReady = NO;
        beginQueue(@{@"liveDVR":@"1", @"liveChannel":@"2.1", @"title":@"Fixture TV", @"path":@""}, @"live-fixture", ^(NSURL *url) {
            verify([url.path isEqual:@"/video/:/transcode/universal/session/live-fixture/index.m3u8"], "Live tune did not start compatible HLS");
            id (*metadata)(id) = dlsym(bundle, "revivePlexPlaybackMetadata");
            verify([metadata(@"live-fixture")[@"title"] isEqual:@"Fixture TV"], "Live title lost");
            id (*optionsRoute)(id, double) = dlsym(bundle, "revivePlexPlaybackOptionsRoute");
            verify([optionsRoute(@"live-fixture", 3)[@"liveDVR"] isEqual:@"1"], "Live settings lost retune context");
            nextQueueItem(@"live-fixture", ^(id next) { verify(!next, "Live TV attempted library autoplay"); });
            liveReady = YES;
        });
        NSDate *liveDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!liveReady && [liveDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(liveReady, "Live TV fixture timed out");
        for (NSNumber *repeat in @[@NO, @YES]) {
            __block BOOL queueReady = NO;
            NSString *session = [repeat boolValue] ? @"repeat-fixture" : @"queue-fixture";
            beginQueue(@{@"playlistID":@"55", @"queueType":@"video", @"path":@"/library/metadata/42", @"repeat":repeat}, session, ^(id ignored) {
                (void)ignored;
                id (*optionsRoute)(id, double) = dlsym(bundle, "revivePlexPlaybackOptionsRoute");
                NSDictionary *options = optionsRoute(session, 123.5);
                verify([options[@"resume"] doubleValue] == 123.5 && [options[@"queueSnapshot"][@"itemID"] isEqual:@"701"], "Playback options lost position or queue");
                loadRows(options, ^(NSArray *rows) {
                    verify([rows[0][@"route"][@"resume"] doubleValue] == 123.5 && [rows[0][@"route"][@"kind"] isEqual:@"transcode"], "Resume option lost playback context");
                });
                nextQueueItem(session, ^(id next) {
                    verify([next isEqual:@"/library/metadata/99"], "Queue did not advance to the next item");
                    verify([optionsRoute(session, 125)[@"queueSnapshot"][@"itemID"] isEqual:@"701"], "Next selection changed the old session's progress identity");
                    continueQueue(session, @"continued-fixture");
                    nextQueueItem(@"continued-fixture", ^(id last) {
                        verify([repeat boolValue] ? [last isEqual:@"/library/metadata/42"] : last == nil, "Queue repeat/end or session handoff failed");
                        queueReady = YES;
                    });
                });
            });
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
            while (!queueReady && [deadline timeIntervalSinceNow] > 0)
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            verify(queueReady, "Queue end/repeat timed out");
        }
        __block BOOL guideReady = NO;
        loadRows(@{@"kind":@"tvGuideProviders", @"path":@""}, ^(NSArray *providers) {
            verify(providers.count == 1 && [providers[0][@"title"] isEqual:@"Fixture Guide"], "Guide provider path validation failed");
            loadRows(providers[0][@"route"], ^(NSArray *channels) {
                loadRows(channels[0][@"route"], ^(NSArray *day) {
                    verify(day.count == 3 && [day[2][@"title"] containsString:@"Fixture Show"], "Guide airing or day navigation missing");
                    loadRows(day[2][@"route"], ^(NSArray *airing) {
                        loadRows(airing[0][@"route"], ^(NSArray *templates) {
                            loadRows(templates[0][@"route"], ^(NSArray *destinations) {
                                verify(destinations.count == 1 && [destinations[0][@"title"] isEqual:@"TV Shows"], "Recording offered wrong library type");
                                loadRows(destinations[0][@"route"], ^(NSArray *confirm) {
                                    applyAction(confirm[0], ^(signed char success) { verify(success, "Recording template parameters were not preserved"); guideReady = YES; });
                                });
                            });
                        });
                    });
                });
            });
        });
        NSDate *guideDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!guideReady && [guideDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(guideReady, "Guide to recording flow timed out");
        __block BOOL repeatOneReady = NO;
        NSDictionary *repeatContext = @{@"kind":@"queueModes", @"path":@"/library/metadata/42", @"resume":@12.5, @"queueSnapshot":@{@"id":@"66", @"itemID":@"701", @"firstID":@"701"}};
        loadRows(repeatContext, ^(NSArray *modes) {
            verify(modes.count == 3 && [modes[2][@"route"][@"resume"] doubleValue] == 12.5, "Repeat options lost resume position");
            beginQueue(modes[2][@"route"], @"repeat-one-fixture", ^(id url) {
                verify(url != nil, "Repeat one failed to start");
                nextQueueItem(@"repeat-one-fixture", ^(id next) {
                    verify([next isEqual:@"/library/metadata/42"], "Repeat one advanced instead of replaying current item");
                    repeatOneReady = YES;
                });
            });
        });
        NSDate *repeatOneDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!repeatOneReady && [repeatOneDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(repeatOneReady, "Repeat one timed out");
        __block BOOL queueBrowseReady = NO;
        loadRows(@{@"kind":@"queueItems", @"path":@"", @"queueSnapshot":@{@"id":@"77", @"itemID":@"1121", @"firstID":@"1000"}}, ^(NSArray *rows) {
            verify(rows.count == 243 && [rows[0][@"title"] isEqual:@"Queue movie 0"] && [[rows lastObject][@"title"] isEqual:@"Queue movie 242"], "Queue windows dropped, duplicated or reordered items");
            verify([rows[242][@"route"][@"queueSnapshot"][@"itemID"] isEqual:@"1242"] && [rows[242][@"route"][@"path"] isEqual:@"/library/metadata/5242"], "Queue jump lost item identity");
            queueBrowseReady = YES;
        });
        NSDate *queueBrowseDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!queueBrowseReady && [queueBrowseDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(queueBrowseReady, "Queue browser timed out");
        __block BOOL queueEditReady = NO;
        loadRows(@{@"kind":@"queueEdit", @"path":@"", @"queueSnapshot":@{@"id":@"77", @"itemID":@"1121"}}, ^(NSArray *rows) {
            verify(rows.count == 243 && !rows[0][@"route"][@"upAfter"] && [rows[0][@"route"][@"downAfter"] isEqual:@"1001"], "Queue editing boundaries incorrect");
            loadRows(rows[121][@"route"], ^(NSArray *currentActions) {
                for (NSDictionary *action in currentActions) verify(![action[@"action"] isEqual:@"removeQueueItem"], "Current queue item can be removed");
                loadRows(rows[0][@"route"], ^(NSArray *actions) {
                    applyAction(actions[0], ^(signed char moved) {
                        verify(moved, "Queue move failed");
                        applyAction([actions lastObject], ^(signed char removed) {
                            verify(removed, "Queue remove failed"); queueEditReady = YES;
                        });
                    });
                });
            });
        });
        NSDate *queueEditDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!queueEditReady && [queueEditDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(queueEditReady, "Queue edit timed out");
        __block BOOL manualSkipReady = NO;
        beginQueue(@{@"path":@"/library/metadata/99"}, @"marker-fixture", ^(id ignored) {
            (void)ignored;
            verify([skipAction(@"marker-fixture", 2)[@"target"] doubleValue] == 15 && skipAction(@"marker-fixture", 16) == nil, "Manual skip did not respect marker bounds");
            manualSkipReady = YES;
        });
        NSDate *manualSkipDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!manualSkipReady && [manualSkipDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(manualSkipReady, "Manual skip metadata timed out");
        __block BOOL seasonVerified = NO;
        loadRows(@{@"kind":@"series", @"path":@"/library/metadata/61", @"title":@"Season 1"}, ^(NSArray *rows) {
            verify([rows[0][@"toolbarCount"] intValue] == 3 && [rows[0][@"hero"][@"parentTitle"] isEqual:@"Fixture Series"], "Season hero/actions missing");
            verify([rows[0][@"route"][@"path"] isEqual:@"/library/metadata/63"] && [rows[0][@"route"][@"resume"] doubleValue] == 40, "Season resume must start two seconds before saved progress");
            verify([rows[3][@"route"][@"path"] isEqual:@"/library/metadata/62"], "Season content lost behind toolbar");
            seasonVerified = YES;
        });
        NSDate *seasonDeadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!seasonVerified && [seasonDeadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        verify(seasonVerified, "Season verification timed out");
        double (*markerTarget)(id, double, id) = dlsym(bundle, "revivePlexMarkerTarget");
        NSArray *markers = @[@{@"type":@"intro", @"startTimeOffset":@1000, @"endTimeOffset":@15000},
            @{@"type":@"credits", @"startTimeOffset":@30000, @"endTimeOffset":@45000}];
        verify(markerTarget && markerTarget(markers, 5, @[@"intro"]) == 15 &&
            markerTarget(markers, 15, @[@"intro"]) == 0 && markerTarget(markers, 35, @[@"intro"]) == 0 &&
            markerTarget(markers, 35, @[@"credits"]) == 45, "Marker boundaries or preferences ignored");
        id (*followingEpisode)(id, id) = dlsym(bundle, "revivePlexFollowingEpisode");
        NSArray *episodes = @[
            @{@"type":@"episode", @"ratingKey":@"3", @"parentIndex":@"2", @"index":@"1"},
            @{@"type":@"episode", @"ratingKey":@"1", @"parentIndex":@"1", @"index":@"20"},
            @{@"type":@"episode", @"ratingKey":@"2", @"parentIndex":@"1", @"index":@"21"}];
        verify(followingEpisode && [followingEpisode(episodes, @"1") isEqual:@"/library/metadata/2"] &&
            [followingEpisode(episodes, @"2") isEqual:@"/library/metadata/3"] && !followingEpisode(episodes, @"3") &&
            !followingEpisode(episodes, @"999"), "Autoplay chose wrong episode or failed season boundary");
        id (*localize)(id) = dlsym(bundle, "revivePlexText");
        signed char (*setLanguage)(id) = dlsym(bundle, "revivePlexSetLanguage");
        void (*toggleKeyboard)(void) = dlsym(bundle, "revivePlexToggleKeyboardLanguage");
        verify(localize && setLanguage && toggleKeyboard, "language entry points missing");
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        id previousLanguage = [[defaults objectForKey:@"RevivePlexLanguage"] retain];
        id previousKeyboard = [[defaults objectForKey:@"RevivePlexKeyboardLanguage"] retain];
        [defaults setObject:@"tr" forKey:@"RevivePlexKeyboardLanguage"];
        verify(setLanguage(@"en") && [localize(@"Oynat") isEqual:@"Play"], "English app preference failed");
        NSArray *turkishKeyboard = searchKeyboard(@"Ç A", 0, nil);
        verify([turkishKeyboard[0][@"searchText"] isEqual:@"Ç A"] &&
            [turkishKeyboard[1][@"title"] isEqual:@"Delete"] &&
            [[turkishKeyboard lastObject][@"title"] isEqual:@"TR"], "keyboard language was coupled to app language");
        toggleKeyboard();
        NSArray *englishKeyboard = searchKeyboard(@"Ç A", 0, nil);
        verify([englishKeyboard[0][@"searchText"] isEqual:@"Ç A"] &&
            [[englishKeyboard lastObject][@"title"] isEqual:@"EN"] &&
            [englishKeyboard[0][@"searchKeyCount"] intValue] <= 36,
            "keyboard language switch lost query or exceeded two rows");
        id (*resolveLanguage)(id, id) = dlsym(bundle, "revivePlexResolveLanguage");
        verify(resolveLanguage && [resolveLanguage(@"system", @[@"sv-SE"]) isEqual:@"sv"] && [resolveLanguage(@"system", @[@"es_MX"]) isEqual:@"es"] && [resolveLanguage(nil, @[@"de-DE"]) isEqual:@"en"] && [resolveLanguage(@"en", @[@"tr-TR"]) isEqual:@"en"] && [resolveLanguage(nil, nil) isEqual:@"en"], "System language normalization or English fallback failed");
        verify(setLanguage(@"sv") && [localize(@"Oynat") isEqual:@"Spela"], "Swedish UI translation missing");
        toggleKeyboard();
        NSArray *swedishKeyboard = searchKeyboard(@"Ö", 0, nil);
        verify([[[swedishKeyboard lastObject] objectForKey:@"title"] isEqual:@"SV"] && [[swedishKeyboard valueForKey:@"title"] containsObject:@"Å"], "Swedish keyboard missing letters");
        verify(setLanguage(@"es") && [localize(@"Oynat") isEqual:@"Reproducir"], "Spanish UI translation missing");
        toggleKeyboard();
        NSArray *spanishKeyboard = searchKeyboard(@"Ñ", 0, nil);
        verify([spanishKeyboard[0][@"searchKeyCount"] intValue] <= 38 && [[spanishKeyboard valueForKey:@"title"] containsObject:@"Ñ"] && [[spanishKeyboard valueForKey:@"title"] containsObject:@"Á"], "Spanish keyboard missing accents or exceeds two rows");
        verify([localize(@"Fixture Movie") isEqual:@"Fixture Movie"], "media title changed during localization");
        if (previousLanguage) [defaults setObject:previousLanguage forKey:@"RevivePlexLanguage"];
        else [defaults removeObjectForKey:@"RevivePlexLanguage"];
        if (previousKeyboard) [defaults setObject:previousKeyboard forKey:@"RevivePlexKeyboardLanguage"];
        else [defaults removeObjectForKey:@"RevivePlexKeyboardLanguage"];
        [defaults synchronize];
        [previousLanguage release]; [previousKeyboard release];
        movies.stack = nil;
        sections.stack = nil;
        live.stack = nil;
        stack.top = nil;
        puts("Mock Lowtide exercised all five Home destinations, details, seasons and episodes.");
    }
    return 0;
}
