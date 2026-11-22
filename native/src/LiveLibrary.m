#include "Localization.h"
#import "PlexClient.h"
#import "LiveLibrary.h"
#import "DirectPlay.h"
#import "PlexLink.h"
#include <stdio.h>
#include <syslog.h>
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dlfcn.h>

#import "DemoGallery.h"

static NSString * const defaultOrigin =
    @"https://localhost:32400";

static NSMutableSet *watchlistKeys;
static NSString *watchlistTitle;

static NSString *cloudKey(id guid)
{
    if (![guid isKindOfClass:[NSString class]] ||
        !([guid hasPrefix:@"plex://movie/"] || [guid hasPrefix:@"plex://show/"])) return nil;
    NSString *key = [guid lastPathComponent];
    return key.length == 24 && ![key rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].length ? key : nil;
}

static NSDictionary *row(NSString *title, NSDictionary *route)
{
    return route ? @{@"title": title, @"route": route} : @{@"title": title};
}

static NSDictionary *route(NSString *title, NSString *kind, NSString *path)
{
    return @{@"title": title, @"kind": kind, @"path": path};
}

static NSArray *exploreRows(void)
{
    return @[
        row(RPText(@"Yeni filmler"), route(RPText(@"Yeni filmler"), @"recentMovie", @"/hubs/home/recentlyAdded")),
        row(RPText(@"Yeni bölümler"), route(RPText(@"Yeni bölümler"), @"recentEpisode", @"/hubs/home/recentlyAdded")),
        row(RPText(@"Tüm kütüphaneler"), route(RPText(@"Kütüphaneler"), @"sections", @"/library/sections"))
    ];
}

id revivePlexLiveHome(void)
{
#ifdef REVIVEPLEX_PRODUCTION
    return @[row(RPText(@"Ayarlar"), route(RPText(@"Ayarlar"), @"settings", @""))];
#else
    NSMutableArray *rows = [NSMutableArray arrayWithObject:
        row(RPText(@"İzlemeye devam et"), route(RPText(@"İzlemeye devam et"), @"media", @"/hubs/home/continueWatching"))];
    [rows addObjectsFromArray:exploreRows()];
    [rows addObject:row(RPText(@"Ayarlar"), route(RPText(@"Ayarlar"), @"settings", @""))];
    return rows;
#endif
}

static NSString *numberKey(id key)
{
    if (![key isKindOfClass:[NSString class]] || ![key length] || [key length] > 18 ||
        [key rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].length)
        return nil;
    return key;
}

static NSArray *mediaRows(NSArray *items, NSString *kind)
{
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *item in items) {
        NSString *title = item[@"title"];
        if (!title.length) continue;
        BOOL section = [kind isEqual:@"sections"];
        NSString *key = numberKey(section ? item[@"key"] : item[@"ratingKey"]);
        if (!key) continue;
        NSString *type = item[@"type"];
        NSString *series = [type isEqual:@"episode"] ? item[@"grandparentTitle"] : nil;
        NSString *episode = nil;
        if (series.length) {
            NSString *name = title;
            int season = [item[@"parentIndex"] intValue], number = [item[@"index"] intValue];
            episode = season > 0 && number > 0 ?
                [NSString stringWithFormat:RPText(@"S%d B%d · %@"), season, number, name] : name;
            title = season > 0 && number > 0 ?
                [NSString stringWithFormat:RPText(@"%@ · S%d B%d"), series, season, number] : series;
        }
        if (section && ![@[@"movie", @"show", @"photo", @"artist"] containsObject:type ?: @""]) continue;
        NSDictionary *next;
        if (section)
            next = route(title, @"media", [NSString stringWithFormat:@"/library/sections/%@/all", key]);
        else if ([@[@"show", @"season", @"artist", @"album"] containsObject:type ?: @""])
            next = route(title, @"series", [NSString stringWithFormat:@"/library/metadata/%@", key]);
        else if ([type isEqual:@"photo"] || [type isEqual:@"photoalbum"])
            next = [item[@"element"] isEqual:@"Directory"] || [type isEqual:@"photoalbum"] ?
                route(title, @"media", [NSString stringWithFormat:@"/library/metadata/%@/children", key]) :
                route(title, @"photo", [NSString stringWithFormat:@"/library/metadata/%@", key]);
        else if ([type isEqual:@"collection"])
            next = route(title, @"media", [NSString stringWithFormat:@"/library/collections/%@/children", key]);
        else if ([type isEqual:@"playlist"])
            next = route(title, @"media", [NSString stringWithFormat:@"/playlists/%@/items", key]);
        else if ([@[@"movie", @"episode", @"clip", @"track"] containsObject:type ?: @""])
            next = route(title, @"detail", [NSString stringWithFormat:@"/library/metadata/%@", key]);
        else
            continue;
        NSMutableDictionary *entry = [row(title, next) mutableCopy];
        if ([item[@"thumb"] hasPrefix:@"/library/"]) entry[@"artwork"] = item[@"thumb"];
        else if ([item[@"composite"] hasPrefix:@"/playlists/"]) entry[@"artwork"] = item[@"composite"];
        else if ([item[@"parentThumb"] hasPrefix:@"/library/"]) entry[@"artwork"] = item[@"parentThumb"];
        if ([item[@"art"] hasPrefix:@"/library/"]) entry[@"backdrop"] = item[@"art"];
        if (!section) {
            if ([type isEqual:@"movie"] && [item[@"year"] length]) entry[@"catalogCaption"] = item[@"year"];
            if (([type isEqual:@"show"] || [type isEqual:@"season"]) && [item[@"leafCount"] intValue] > 0)
                entry[@"catalogCaption"] = [NSString stringWithFormat:RPText(@"%d bölüm"), [item[@"leafCount"] intValue]];
            if (episode.length) entry[@"catalogCaption"] = episode;
            entry[@"shelf"] = @YES;
            entry[@"mediaType"] = type;
        }
        if (series.length && episode.length) {
            entry[@"cardTitle"] = series;
            entry[@"caption"] = episode;
        }
        [rows addObject:entry];
    }
    NSMutableArray *gallery = [NSMutableArray array];
    for (NSDictionary *entry in rows) if ([entry[@"route"][@"kind"] isEqual:@"photo"]) [gallery addObject:entry[@"route"]];
    if (gallery.count > 1) {
        NSUInteger photoIndex = 0;
        for (NSMutableDictionary *entry in rows) if ([entry[@"route"][@"kind"] isEqual:@"photo"]) {
            NSMutableDictionary *photoRoute = [entry[@"route"] mutableCopy];
            photoRoute[@"gallery"] = [gallery copy]; photoRoute[@"photoIndex"] = @(photoIndex++);
            entry[@"route"] = photoRoute;
        }
    }
    return rows.count ? rows : @[row(RPText(@"Sonuç bulunamadı"), nil)];
}

id revivePlexAdjacentPhoto(id source, int direction)
{
    NSArray *gallery = source[@"gallery"];
    NSInteger index = [source[@"photoIndex"] integerValue] + direction;
    if (![source[@"kind"] isEqual:@"photo"] || !gallery.count || index < 0 || index >= (NSInteger)gallery.count) return nil;
    NSMutableDictionary *next = [gallery[index] mutableCopy];
    next[@"gallery"] = gallery; next[@"photoIndex"] = @(index);
    return next;
}

id revivePlexLocalizedMenuTitle(id source)
{
    NSDictionary *titles = @{@"settings":@"Ayarlar", @"about":@"Hakkında", @"language":@"Uygulama dili", @"quality":@"Video kalitesi",
        @"autoplay":@"Sonraki içeriği otomatik oynat", @"skipMarkers":@"Giriş ve jenerik atlama", @"sort":@"Sırala",
        @"filters":@"Filtrele", @"servers":@"Sunucu seç", @"homeUsers":@"Plex Home kullanıcıları",
        @"status":@"Sunucu durumu", @"logout":@"Oturumu kapat", @"playbackOptions":@"Oynatma ayarları"};
    NSString *key = titles[source[@"kind"] ?: @""];
    return key ? RPText(key) : source[@"title"];
}

id revivePlexPrepareFilterRoute(id source)
{
    if (![source isKindOfClass:[NSDictionary class]]) return source;
    NSString *kind = source[@"kind"], *path = source[@"path"];
    if (![@[@"filters", @"filterValues", @"sort"] containsObject:kind ?: @""] &&
        !([kind isEqual:@"media"] && [path hasPrefix:@"/library/sections/"] && [path hasSuffix:@"/all"])) return source;
    NSMutableDictionary *route = [source mutableCopy];
    NSMutableDictionary *state = source[@"filterState"];
    if (![state isKindOfClass:[NSMutableDictionary class]]) state = [NSMutableDictionary dictionaryWithObject:source[@"parameters"] ?: @{} forKey:@"parameters"];
    route[@"filterState"] = state;
    route[@"parameters"] = state[@"parameters"];
    return route;
}

static NSDictionary *filterChoice(NSString *title, NSString *field, NSString *value, NSDictionary *source)
{
    return @{@"title":title, @"baseTitle":title, @"action":@"toggleFilter", @"filterKey":field,
        @"filterValue":value, @"filterState":source[@"filterState"]};
}

static NSArray *refreshFilterChoices(NSArray *rows)
{
    NSMutableArray *updated = [NSMutableArray array];
    for (NSDictionary *entry in rows) {
        NSMutableDictionary *copy = [entry mutableCopy];
        if ([entry[@"action"] isEqual:@"toggleFilter"]) {
            NSString *selected = entry[@"filterState"][@"parameters"][entry[@"filterKey"]];
            NSString *value = entry[@"filterValue"];
            BOOL active = value.length ? [selected isEqual:value] : !selected.length;
            NSString *title = value.length ? entry[@"baseTitle"] : (selected.length ? RPText(@"Filtreyi temizle") : RPText(@"Tümü"));
            copy[@"title"] = active ? [@"✓ " stringByAppendingString:title] : title;
        }
        [updated addObject:copy];
    }
    return updated;
}

id revivePlexToggleFilterRows(id rows, id entry)
{
    NSMutableDictionary *state = entry[@"filterState"];
    if (![state isKindOfClass:[NSMutableDictionary class]]) return rows;
    NSMutableDictionary *parameters = [state[@"parameters"] mutableCopy];
    NSString *field = entry[@"filterKey"], *value = entry[@"filterValue"];
    if ([field isEqual:@"*"]) {
        for (NSString *key in @[@"genre", @"year", @"unwatched", @"actor"]) [parameters removeObjectForKey:key];
    } else if (!value.length || [parameters[field] isEqual:value]) [parameters removeObjectForKey:field];
    else parameters[field] = value;
    state[@"parameters"] = parameters;
    // Preserve positions until this page is opened again.
    return refreshFilterChoices(rows);
}

static NSUInteger activeFilterCount(NSDictionary *parameters)
{
    NSUInteger count = 0;
    for (NSString *key in @[@"genre", @"year", @"unwatched", @"actor"])
        if ([parameters[key] description].length) count++;
    return count;
}

static NSString *catalogSortTitle(NSDictionary *parameters)
{
    NSString *sort = parameters[@"sort"] ?: @"titleSort:asc";
    if ([sort isEqual:@"titleSort:desc"]) return RPText(@"Ada göre Z–A");
    if ([sort isEqual:@"addedAt:desc"]) return RPText(@"Yeni eklenenler");
    if ([sort isEqual:@"year:desc"]) return RPText(@"Yıla göre");
    return RPText(@"Ada göre A–Z");
}

static NSArray *catalogRows(NSArray *rows, NSDictionary *source)
{
    NSString *path = source[@"path"];
    if (![path hasPrefix:@"/library/sections/"] || ![path hasSuffix:@"/all"] || ![rows firstObject][@"shelf"]) return rows;
    NSMutableArray *result = [NSMutableArray array];
    for (NSArray *option in @[@[RPText(@"Sırala"), @"sort"], @[RPText(@"Filtrele"), @"filters"], @[RPText(@"Koleksiyonlar"), @"collections"]]) {
        NSString *targetPath = [option[1] isEqual:@"collections"] ? [[path stringByDeletingLastPathComponent] stringByAppendingString:@"/collections"] : path;
        NSMutableDictionary *next = [route(option[0], [option[1] isEqual:@"collections"] ? @"media" : option[1], targetPath) mutableCopy];
        next[@"catalogPath"] = path;
        next[@"catalogTitle"] = source[@"title"] ?: @"";
        if (source[@"parameters"]) next[@"parameters"] = source[@"parameters"];
        if (source[@"filterState"]) next[@"filterState"] = source[@"filterState"];
        NSMutableDictionary *toolbar = [@{@"title":option[0], @"route":next, @"shelf":@YES} mutableCopy];
        if ([option[1] isEqual:@"filters"]) toolbar[@"filterCount"] = @(activeFilterCount(source[@"parameters"]));
        [result addObject:toolbar];
    }
    NSMutableDictionary *first = [result[0] mutableCopy];
    first[@"toolbarCount"] = @3;
    first[@"sortTitle"] = catalogSortTitle(source[@"parameters"]);
    first[@"mediaType"] = [rows firstObject][@"mediaType"] ?: @"movie";
    result[0] = first;
    [result addObjectsFromArray:rows];
    return result;
}

long revivePlexShelfTarget(id data, long selection, int action, long columns)
{
    NSArray *rows = data;
    long toolbar = [[rows firstObject][@"toolbarCount"] longValue], count = rows.count;
    if (!toolbar || columns < 1 || selection < 0 || selection >= count) return selection;
    if (selection < toolbar) {
        if (action == 6) return MAX(0, selection - 1);
        if (action == 7) return MIN(toolbar - 1, selection + 1);
        if (action == 4 && count > toolbar) return MIN(count - 1, toolbar + selection);
        return selection;
    }
    long index = selection - toolbar, column = columns == 4 ? index % 4 : index % 6;
    if (action == 3) return index < columns ? MIN(toolbar - 1, column) : selection - columns;
    if (action == 4 && selection - column + columns < count) return MIN(count - 1, selection + columns);
    if (action == 6 && column > 0) return selection - 1;
    if (action == 7 && column < columns - 1 && selection + 1 < count) return selection + 1;
    return selection;
}

id revivePlexSearchRoute(id query)
{
    NSString *text = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return text.length ? @{@"title":RPText(@"Arama sonuçları"), @"kind":@"searchResults",
        @"path":@"/library/all", @"query":text} : nil;
}

id revivePlexDiscoverSearchRoute(id query)
{
    NSDictionary *base = revivePlexSearchRoute(query);
    if (!base) return nil;
    NSMutableDictionary *result = [base mutableCopy]; result[@"kind"] = @"discoverResults";
    result[@"path"] = @"/library/search"; return result;
}

id revivePlexSearchKeyboard(id query, int numeric, id matches)
{
    NSString *text = query ?: @"";
    NSArray *results = matches;
    NSMutableArray *keys = [NSMutableArray arrayWithArray:@[
        @{@"title":numeric ? @"ABC" : @"123", @"action":@"searchMode", @"shelf":@YES},
        @{@"title":RPText(@"Sil"), @"action":@"searchKey", @"searchKey":@"", @"shelf":@YES},
        @{@"title":RPText(@"Boşluk"), @"action":@"searchKey", @"searchKey":@" ", @"shelf":@YES}
    ]];
    NSString *characters = numeric ? @"0 1 2 3 4 5 6 7 8 9" :
        ([revivePlexKeyboardLanguage() isEqual:@"tr"] ?
        @"A B C Ç D E F G Ğ H I İ J K L M N O Ö P Q R S Ş T U Ü V W X Y Z" :
        ([revivePlexKeyboardLanguage() isEqual:@"sv"] ?
        @"A B C D E F G H I J K L M N O P Q R S T U V W X Y Z Å Ä Ö" :
        ([revivePlexKeyboardLanguage() isEqual:@"es"] ?
        @"A B C D E F G H I J K L M N Ñ O P Q R S T U V W X Y Z Á É Í Ó Ú Ü" :
        @"A B C D E F G H I J K L M N O P Q R S T U V W X Y Z")));
    for (NSString *key in [characters componentsSeparatedByString:@" "])
        [keys addObject:@{@"title":key, @"action":@"searchKey", @"searchKey":key, @"shelf":@YES}];
    [keys addObject:@{@"title":[revivePlexKeyboardLanguage() uppercaseString],
        @"action":@"keyboardLanguage", @"shelf":@YES}];

    NSMutableDictionary *first = [keys[0] mutableCopy];
    first[@"searchText"] = text;
    first[@"searchNumeric"] = @(numeric);
    first[@"searchKeyCount"] = @(keys.count);
    NSString *status = RPText(@"Film veya dizi adı yaz");
    if (revivePlexSearchRoute(text)) {
        status = results ? RPText(@"Sonuç bulunamadı") : RPText(@"Aranıyor…");
        for (NSDictionary *entry in results) {
            if (entry[@"route"] && entry[@"mediaType"]) [keys addObject:entry];
            else if (!entry[@"route"]) status = entry[@"title"];
        }
    }
    first[@"searchStatus"] = status;
    keys[0] = first;
    return keys;
}

id revivePlexPlaylistNameRows(id source, id query, int numeric)
{
    NSMutableArray *keys = [revivePlexSearchKeyboard(query, numeric, @[]) mutableCopy];
    NSMutableDictionary *save = [source mutableCopy];
    [save removeObjectForKey:@"kind"]; [save removeObjectForKey:@"path"];
    save[@"title"] = RPText(@"Kaydet"); save[@"shelf"] = @YES;
    save[@"action"] = source[@"playlistID"] ? @"renamePlaylist" : @"createPlaylist";
    save[@"playlistTitle"] = query ?: @"";
    if (![[query ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length]) [save removeObjectForKey:@"action"];
    [keys addObject:save];
    NSMutableDictionary *first = [keys[0] mutableCopy];
    first[@"searchKeyCount"] = @(keys.count); first[@"searchStatus"] = RPText(@"Liste adını yaz ve Kaydet'i seç."); keys[0] = first;
    return keys;
}

long revivePlexSearchTarget(id data, long selected, int action)
{
    NSArray *rows = data;
    long keys = [[rows firstObject][@"searchKeyCount"] longValue];
    long count = (long)rows.count;
    if (selected < 0 || selected >= count) return selected;
    if (selected < keys) {
        BOOL lower = selected >= RevivePlexSearchColumns;
        long column = selected - (lower ? RevivePlexSearchColumns : 0);
        if (action == 6 && column > 0) return selected - 1;
        if (action == 7 && column < RevivePlexSearchColumns - 1 && selected + 1 < keys) return selected + 1;
        if (action == 3 && lower) return column;
        if (action == 4 && !lower && keys > RevivePlexSearchColumns)
            return MIN(keys - 1, selected + RevivePlexSearchColumns);
        if (action == 4 && count > keys)
            return MIN(count - 1, keys + MIN(RevivePlexSearchResultColumns - 1, column / 2));
    } else {
        long result = selected - keys;
        BOOL lower = result >= RevivePlexSearchResultColumns;
        long column = result % RevivePlexSearchResultColumns;
        if (action == 6 && column > 0) return selected - 1;
        if (action == 7 && column < RevivePlexSearchResultColumns - 1 && selected + 1 < count) return selected + 1;
        if (action == 3)
            return lower ? selected - RevivePlexSearchResultColumns :
                MIN(keys - 1, (keys > RevivePlexSearchColumns ? RevivePlexSearchColumns : 0) + column * 2);
        if (action == 4 && selected - column + RevivePlexSearchResultColumns < count)
            return MIN(count - 1, selected + RevivePlexSearchResultColumns);
    }
    return selected;
}

id revivePlexEditSearch(id query, id key)
{
    NSString *text = query;
    NSString *letter = key;
    if (!letter.length) {
        if (!text.length) return text;
        NSRange last = [text rangeOfComposedCharacterSequenceAtIndex:text.length - 1];
        return [text substringToIndex:last.location];
    }
    return text.length < 60 ? [text stringByAppendingString:letter] : text;
}

static NSArray *panelRows(NSArray *rows, NSDictionary *details)
{
    if (!rows.count) return rows;
    NSMutableArray *panel = [rows mutableCopy];
    NSMutableDictionary *first = [rows[0] mutableCopy];
    first[@"shelf"] = @YES;
    NSMutableDictionary *layout = [details mutableCopy] ?: [NSMutableDictionary dictionary];
    if (!layout[@"filterGrid"] && !layout[@"artwork"] && !layout[@"photo"] && !layout[@"longText"] && !layout[@"technical"]) {
        layout[@"filterGrid"] = @YES;
        layout[@"gridColumns"] = @2;
    }
    first[@"panel"] = layout;
    panel[0] = first;
    return panel;
}

id revivePlexHomePINRows(id userID, id input)
{
    NSString *pin = [input isKindOfClass:[NSString class]] ? input : @"";
    NSMutableArray *keys = [NSMutableArray array];
    for (NSString *digit in @[@"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9", @"0", @""])
        [keys addObject:@{@"title":digit.length ? digit : RPText(@"Sil"), @"action":@"homePinKey", @"searchKey":digit, @"shelf":@YES}];
    [keys addObject:@{@"title":RPText(@"Devam et"), @"action":@"setHomeUser", @"userID":userID, @"pin":pin, @"shelf":@YES}];
    NSMutableDictionary *first = [keys[0] mutableCopy];
    NSString *masked = @"PIN: ";
    for (NSUInteger index = 0; index < 4; index++) masked = [masked stringByAppendingString:index < pin.length ? @"● " : @"_ "];
    first[@"searchText"] = masked; first[@"searchKeyCount"] = @(keys.count);
    first[@"searchStatus"] = RPText(@"Plex Home PIN kodunu gir"); first[@"pin"] = pin; first[@"userID"] = userID;
    keys[0] = first; return keys;
}

id revivePlexEditHomePIN(id rows, id key)
{
    NSDictionary *first = [rows firstObject];
    NSString *pin = first[@"pin"] ?: @"";
    if (![key length] || (pin.length < 4 && [key length] == 1 && numberKey(key))) pin = revivePlexEditSearch(pin, key);
    return revivePlexHomePINRows(first[@"userID"], pin);
}

long revivePlexPreferredMediaIndex(id parts, id quality)
{
    double target = [quality isEqual:@"1080"] ? 1920 : ([quality isEqual:@"480"] ? 854 : 1280);
    double best = 1e9; long selected = 0;
    for (NSDictionary *part in parts) {
        NSDictionary *media = part[@"media"];
        double width = [media[@"width"] doubleValue];
        if (width <= 0) continue;
        double score = width >= target ? (width - target) / target : (target - width) * 4 / target;
        if (![media[@"videoCodec"] isEqual:@"h264"]) score += 0.2;
        if ([media[@"optimizedForStreaming"] boolValue]) score -= 0.05;
        if (score < best) { best = score; selected = [media[@"mediaIndex"] longValue]; }
    }
    return selected;
}

signed char revivePlexCanPreserveVideo(id part, id quality)
{
    NSDictionary *media = part[@"media"], *video = nil;
    for (NSDictionary *stream in part[@"streams"]) if ([stream[@"streamType"] intValue] == 1) { video = stream; break; }
    double width = [media[@"width"] doubleValue], height = [media[@"height"] doubleValue];
    double limitWidth = [quality isEqual:@"1080"] ? 1920 : ([quality isEqual:@"480"] ? 854 : 1280);
    double limitHeight = [quality isEqual:@"1080"] ? 1080 : ([quality isEqual:@"480"] ? 480 : 720);
    double bitrate = [quality isEqual:@"1080"] ? 8000 : ([quality isEqual:@"480"] ? 1500 : 3500);
    double fps = [video[@"frameRate"] doubleValue], level = [video[@"level"] doubleValue];
    return [media[@"videoCodec"] isEqual:@"h264"] && [video[@"bitDepth"] intValue] == 8 &&
        width > 0 && height > 0 && width <= limitWidth && height <= limitHeight &&
        fps > 0 && fps <= 30 && level > 0 && level <= 40 &&
        [media[@"bitrate"] doubleValue] > 0 && [media[@"bitrate"] doubleValue] <= bitrate;
}

static NSArray *detailRows(NSDictionary *item, NSArray *parts)
{
    if (!item) return @[row(RPText(@"Ayrıntı bulunamadı"), nil)];
    NSMutableArray *rows = [NSMutableArray array];
    int duration = [item[@"duration"] intValue];
    int offset = [item[@"viewOffset"] intValue];
    NSString *ratingKey = numberKey(item[@"ratingKey"]);
    NSString *metadataPath = ratingKey && parts.count ?
        [NSString stringWithFormat:@"/library/metadata/%@", ratingKey] : nil;
    NSString *playPath = metadataPath;
    NSString *kind = @"transcode";
    if (playPath) {
        if (offset > 0 && offset < duration) {
            [rows addObject:row(RPText(@"İzlemeye devam et"), @{@"title":RPText(@"Oynatıcı"), @"kind":kind,
                @"path":playPath, @"resume":@(MAX(0, offset / 1000.0 - ([item[@"type"] isEqual:@"episode"] ? 2.0 : 0)))})];
            [rows addObject:row(RPText(@"Baştan oynat"), route(RPText(@"Oynatıcı"), kind, playPath))];
        } else {
            [rows addObject:row(RPText(@"Oynat"), route(RPText(@"Oynatıcı"), kind, playPath))];
        }
    } else {
        [rows addObject:row(RPText(@"Oynat"), route(RPText(@"Oynatma durumu"), @"incompatible", @""))];
    }
    if (metadataPath) {
        [rows addObject:row(RPText(@"Ses"), @{@"title":RPText(@"Ses"), @"kind":@"streams", @"path":metadataPath, @"streamType":@2})];
        if (![item[@"type"] isEqual:@"track"]) [rows addObject:row(RPText(@"Altyazı"), @{@"title":RPText(@"Altyazı"), @"kind":@"streams", @"path":metadataPath, @"streamType":@3})];
        [rows addObject:@{@"title":[item[@"viewCount"] intValue] > 0 ? RPText(@"İzlenmedi olarak işaretle") : RPText(@"İzlendi olarak işaretle"),
            @"action":@"watched", @"ratingKey":ratingKey, @"watched":@([item[@"viewCount"] intValue] == 0)}];
    }
    if (metadataPath && [item[@"Media"] count] > 1) [rows addObject:row(RPText(@"Sürüm seç"), route(RPText(@"Sürüm seç"), @"versions", metadataPath))];
    if (metadataPath) [rows addObject:row(RPText(@"Çalma listesine ekle"), @{@"title":RPText(@"Çalma listesine ekle"),
        @"kind":@"playlistPicker", @"path":@"/playlists", @"ratingKey":ratingKey,
        @"playlistType":[item[@"type"] isEqual:@"track"] ? @"audio" : @"video", @"itemTitle":item[@"title"] ?: @"Plex"})];
    NSString *watchKey = cloudKey(item[@"guid"]);
    if (watchKey && watchlistKeys) [rows addObject:@{@"title":[watchlistKeys containsObject:watchKey] ? RPText(@"İzleme listesinden çıkar") : RPText(@"İzleme listesine ekle"),
        @"action":@"watchlist", @"cloudKey":watchKey, @"remove":@([watchlistKeys containsObject:watchKey])}];
    if (metadataPath) [rows addObject:row(RPText(@"Puan ver"), @{@"title":RPText(@"Puan ver"), @"kind":@"rating", @"path":metadataPath, @"ratingKey":ratingKey})];
    if ([item[@"Chapter"] count] && metadataPath)
        [rows addObject:row(RPText(@"Sahneler"), route(RPText(@"Sahneler"), @"chapters", metadataPath))];
    if ([item[@"Extras"] count] && metadataPath)
        [rows addObject:row(RPText(@"Ek içerikler"), route(RPText(@"Ek içerikler"), @"extras", metadataPath))];
    if ([item[@"summary"] length] && metadataPath)
        [rows addObject:row(RPText(@"Açıklamanın tamamı"), route(item[@"title"], @"description", metadataPath))];
    if ([item[@"Role"] count] && metadataPath)
        [rows addObject:row(RPText(@"Oyuncular ve ekip"), route(RPText(@"Oyuncular ve ekip"), @"cast", metadataPath))];
    NSMutableDictionary *details = [NSMutableDictionary dictionary];
    details[@"title"] = item[@"grandparentTitle"] ?: item[@"title"];
    if ([item[@"grandparentTitle"] length]) details[@"subtitle"] = item[@"title"];
    details[@"summary"] = item[@"summary"] ?: @"";
    details[@"landscape"] = @([item[@"type"] isEqual:@"episode"]);
    details[@"squareArtwork"] = @([item[@"type"] isEqual:@"track"]);
    details[@"actionGrid"] = @YES;
    details[@"detailActions"] = @YES;
    NSMutableArray *technical = [NSMutableArray array];
    NSDictionary *media = [parts firstObject][@"media"];
    if ([media[@"videoResolution"] length]) [technical addObject:[NSString stringWithFormat:@"%@p", media[@"videoResolution"]]];
    if ([media[@"videoCodec"] length]) [technical addObject:[media[@"videoCodec"] uppercaseString]];
    if ([media[@"audioCodec"] length]) [technical addObject:[media[@"audioCodec"] uppercaseString]];
    NSMutableArray *directors = [NSMutableArray array];
    for (NSDictionary *director in item[@"Director"]) if ([director[@"tag"] length]) [directors addObject:director[@"tag"]];
    if (directors.count) [technical addObject:[directors componentsJoinedByString:@", "]];
    details[@"technical"] = [technical componentsJoinedByString:@"  ·  "];
    if ([item[@"thumb"] hasPrefix:@"/library/"]) details[@"artwork"] = item[@"thumb"];
    else if ([item[@"parentThumb"] hasPrefix:@"/library/"]) details[@"artwork"] = item[@"parentThumb"];
    NSMutableArray *facts = [NSMutableArray array];
    if ([item[@"year"] length]) [facts addObject:item[@"year"]];
    if (duration > 0) [facts addObject:[NSString stringWithFormat:RPText(@"%d dk"), duration / 60000]];
    if ([item[@"contentRating"] length]) [facts addObject:item[@"contentRating"]];
    NSMutableArray *genres = [NSMutableArray array];
    for (NSDictionary *genre in item[@"Genre"]) if ([genre[@"tag"] length]) [genres addObject:genre[@"tag"]];
    if (genres.count) [facts addObject:[genres componentsJoinedByString:@", "]];
    if ([item[@"rating"] doubleValue] > 0) [facts addObject:[NSString stringWithFormat:@"★ %@", item[@"rating"]]];
    if ([item[@"viewCount"] intValue] > 0) [facts addObject:RPText(@"İzlendi")];
    details[@"facts"] = [facts componentsJoinedByString:@"   ·   "];
    NSMutableArray *ratings = [NSMutableArray array];
    for (NSDictionary *rating in item[@"Rating"]) {
        NSString *image = rating[@"image"];
        if ([image hasPrefix:@"imdb:"]) [ratings addObject:[NSString stringWithFormat:@"IMDb %@", rating[@"value"] ?: @""]];
        else if ([image hasPrefix:@"rottentomatoes:"] && [rating[@"type"] isEqual:@"critic"])
            [ratings addObject:[NSString stringWithFormat:@"Rotten Tomatoes %.0f%%", [rating[@"value"] doubleValue] * 10]];
        else if ([image hasPrefix:@"themoviedb:"]) [ratings addObject:[NSString stringWithFormat:@"TMDB %@", rating[@"value"] ?: @""]];
    }
    details[@"ratings"] = [ratings componentsJoinedByString:@"   ·   "];
    return panelRows(rows, details);
}

static NSString *settingsPath(void)
{
    return [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Preferences/org.revivetv.plex.local.plist"];
}

static NSDictionary *localSettings(void)
{
    NSString *path = settingsPath();
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) || !S_ISREG(info.st_mode) ||
        info.st_uid != geteuid() || (info.st_mode & 077) || info.st_size > 16384)
        return nil;
    return [NSDictionary dictionaryWithContentsOfFile:path];
}

static PlexClient *discoverClient(void)
{
#ifdef REVIVEPLEX_TEST
    NSString *testOrigin = NSProcessInfo.processInfo.environment[@"REVIVEPLEX_TEST_ORIGIN"];
    if (testOrigin.length) return [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:testOrigin] token:nil clientID:@"test"];
#endif
    NSDictionary *settings = localSettings();
    NSString *token = settings[@"accountToken"] ?: settings[@"token"];
    return token.length ? [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:@"https://discover.provider.plex.tv"] token:token clientID:@"RevivePlex-AppleTV3"] : nil;
}

static void fetchWatchlist(PlexClient *client, NSMutableArray *items, void (^completion)(NSArray *, NSError *))
{
    [client fetchJSONPath:@"/library/sections/watchlist/all" query:@[
        [NSURLQueryItem queryItemWithName:@"X-Plex-Container-Start" value:@(items.count).stringValue],
        [NSURLQueryItem queryItemWithName:@"X-Plex-Container-Size" value:@"100"]] completion:^(id response, NSError *error) {
        NSDictionary *container = [response isKindOfClass:[NSDictionary class]] ? response[@"MediaContainer"] : nil;
        if (![container isKindOfClass:[NSDictionary class]]) container = nil;
        NSArray *page = [container[@"Metadata"] isKindOfClass:[NSArray class]] ? container[@"Metadata"] : @[];
        if (error || !container) { completion(nil, error ?: [NSError errorWithDomain:@"org.revivetv.plex" code:422 userInfo:nil]); return; }
        [items addObjectsFromArray:page];
        if (page.count && items.count < [container[@"totalSize"] unsignedIntegerValue] && items.count < 10000) {
            fetchWatchlist(client, items, completion); return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            watchlistKeys = [NSMutableSet set];
            for (id item in items) { if (![item isKindOfClass:[NSDictionary class]]) continue; NSString *key = cloudKey(item[@"guid"]); if (key) [watchlistKeys addObject:key]; }
            if ([container[@"librarySectionTitle"] isKindOfClass:[NSString class]]) watchlistTitle = container[@"librarySectionTitle"];
            completion(items, nil);
        });
    }];
}

static NSDictionary *promotedHub(NSArray *hubs, NSString *identifier, NSString *prefix)
{
    for (NSDictionary *hub in hubs) {
        NSString *key = hub[@"hubIdentifier"];
        if ([key isEqual:identifier] || (prefix && [key hasPrefix:prefix])) return hub;
    }
    return nil;
}

static void appendPromotedRail(NSMutableArray *rows, NSDictionary *hub, NSUInteger rail)
{
    NSString *title = hub[@"title"];
    NSArray *items = mediaRows(hub[@"entries"], @"media");
    NSUInteger count = 0;
    for (NSDictionary *item in items) {
        if (!item[@"route"]) continue;
        NSMutableDictionary *card = [item mutableCopy];
        card[@"homeRail"] = @(rail);
        if (title.length) card[@"railTitle"] = title;
        [rows addObject:card];
        if (++count == 4) break;
    }
}

static NSArray *homeRowsWithPlex(NSArray *sections, NSArray *hubs)
{
    NSMutableArray *navigation = [NSMutableArray arrayWithObject:row(RPText(@"Ara"), route(RPText(@"Ara"), @"search", @""))];
    NSDictionary *continuing = promotedHub(hubs, @"home.continue", nil);
    NSString *continueTitle = continuing[@"title"];
    if (continueTitle.length && [continuing[@"key"] isEqual:@"/hubs/home/continueWatching"])
        [navigation addObject:row(continueTitle, route(continueTitle, @"media", continuing[@"key"]))];

    for (NSDictionary *library in mediaRows(sections, @"sections")) {
        if (library[@"route"]) [navigation addObject:library];
    }
    if (watchlistTitle.length) [navigation addObject:row(watchlistTitle, route(watchlistTitle, @"watchlist", @""))];
    [navigation addObject:row(RPText(@"Daha fazla"), route(RPText(@"Daha fazla"), @"more", @""))];

    NSMutableArray *cards = [NSMutableArray array];
    appendPromotedRail(cards, continuing, 1);
    NSInteger nextRail = cards.count ? 2 : 1;
    for (NSDictionary *hub in hubs) {
        if (hub == continuing || ![hub[@"title"] length]) continue;
        NSUInteger before = cards.count;
        appendPromotedRail(cards, hub, nextRail);
        if (cards.count > before) nextRail++;
    }
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:navigation.count + cards.count];
    for (NSDictionary *item in navigation) {
        NSMutableDictionary *tab = [item mutableCopy];
        tab[@"homeRail"] = @0;
        [rows addObject:tab];
    }
    [rows addObjectsFromArray:cards];
    return rows;
}

static NSArray *cloudCards(NSArray *items)
{
    NSMutableArray *rows = [NSMutableArray array];
    for (id raw in items) {
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *item = raw;
        NSString *key = cloudKey(item[@"guid"]), *title = item[@"title"];
        if (!key || ![title isKindOfClass:[NSString class]] || !title.length) continue;
        NSMutableDictionary *card = [row(title, @{@"title":title, @"kind":@"cloudItem", @"path":@"", @"guid":item[@"guid"], @"cloudKey":key}) mutableCopy];
        card[@"shelf"] = @YES; card[@"mediaType"] = [item[@"type"] isEqual:@"show"] ? @"show" : @"movie";
        card[@"catalogCaption"] = item[@"year"] ? [NSString stringWithFormat:@"%@", item[@"year"]] : @"";
        NSString *thumb = [item[@"thumb"] isKindOfClass:[NSString class]] ? item[@"thumb"] : nil;
        if ([thumb hasPrefix:@"https://metadata-static.plex.tv/"] || [thumb hasPrefix:@"https://image.tmdb.org/"]) card[@"artwork"] = thumb;
        [rows addObject:card];
    }
    return rows;
}

static void loadHomeRails(PlexClient *client, NSArray *sections, void (^completion)(NSArray *))
{
    NSArray *query = @[[NSURLQueryItem queryItemWithName:@"count" value:@"4"]];
    [client fetchPath:@"/hubs/promoted" query:query completion:^(NSDictionary *result, NSError *error) {
        void (^finish)(void) = ^{ completion(homeRowsWithPlex(sections, error ? nil : result[@"items"])); };
        PlexClient *cloud = discoverClient();
        if (cloud) fetchWatchlist(cloud, [NSMutableArray array], ^(NSArray *items, NSError *cloudError) {
            (void)items; (void)cloudError; dispatch_async(dispatch_get_main_queue(), finish);
        });
        else dispatch_async(dispatch_get_main_queue(), finish);
    }];
}

id revivePlexSignInRows(id message)
{
    return @[
        @{@"title": RPText(@"Kod oluştur"), @"action": @"beginLink", @"qr": @YES},
        row(message, nil),
        row(RPText(@"Kodu Plex sayfasına gir."), nil)
    ];
}

void revivePlexRefreshHome(void (^completion)(id, id))
{
    NSDictionary *settings = localSettings();
    NSString *origin = settings[@"origin"] ?: defaultOrigin;
    NSString *token = settings[@"token"];
#ifdef REVIVEPLEX_TEST
    origin = NSProcessInfo.processInfo.environment[@"REVIVEPLEX_TEST_ORIGIN"];
    token = nil;
#else
    if (![origin isKindOfClass:[NSString class]] || ![token isKindOfClass:[NSString class]] || !token.length) {
        completion(RPText(@"Plex Oturumu"), revivePlexSignInRows(RPText(@"Kütüphaneyi açmak için önce oturum aç.")));
        return;
    }
#endif
    PlexClient *client = [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:origin]
        token:token clientID:@"RevivePlex-AppleTV3"];
    if (!client) {
        completion(RPText(@"Plex Oturumu"), revivePlexSignInRows(RPText(@"Sunucu yapılandırması geçersiz.")));
        return;
    }
    [client fetchPath:@"/library/sections" query:nil completion:^(NSDictionary *result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (result && !error) {
                loadHomeRails(client, result[@"items"], ^(NSArray *rows) {
                    completion(RPText(@"Plex Kütüphanesi"), rows);
                });
            } else if (error.code == 401 || error.code == 403) {
                completion(RPText(@"Plex Oturumu"), revivePlexSignInRows(RPText(@"Bu oturumun kütüphaneye erişimi yok.")));
            } else {
                completion(RPText(@"Plex Bağlantısı"), @[
                    @{@"title": RPText(@"Yeniden dene"), @"action": @"checkSession"},
                    row(RPText(@"Plex sunucusuna ulaşılamadı."), nil)
                ]);
            }
        });
    }];
}

static BOOL saveSession(NSDictionary *session);

id revivePlexServerGeneration(void)
{
    return @([[NSUserDefaults standardUserDefaults] integerForKey:@"RevivePlexServerGeneration"]);
}

static void selectServer(NSArray *connections, NSUInteger index, NSString *token, NSString *accountToken, NSString *homeOwnerToken, void (^completion)(signed char))
{
    if (index >= connections.count) { dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); }); return; }
    NSString *origin = connections[index];
    NSURL *url = [NSURL URLWithString:origin];
    PlexClient *client = [origin isKindOfClass:[NSString class]] && [url.scheme isEqual:@"https"] && !url.user && !url.password ?
        [[PlexClient alloc] initWithOrigin:url token:token clientID:@"RevivePlex-AppleTV3"] : nil;
    if (!client) { selectServer(connections, index + 1, token, accountToken, homeOwnerToken, completion); return; }
    [client fetchPath:@"/library/sections" query:nil completion:^(NSDictionary *data, NSError *error) {
        if (error || !data) { selectServer(connections, index + 1, token, accountToken, homeOwnerToken, completion); return; }
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL saved = saveSession(@{@"origin":origin, @"token":token, @"accountToken":accountToken, @"homeOwnerToken":homeOwnerToken ?: accountToken});
            if (saved) {
                NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                [defaults setInteger:[defaults integerForKey:@"RevivePlexServerGeneration"] + 1 forKey:@"RevivePlexServerGeneration"];
                [defaults synchronize];
            }
            completion(saved);
        });
    }];
}

static NSArray *serverChoices(id resources, NSString *accountToken, NSString *homeOwnerToken)
{
    NSMutableArray *rows = [NSMutableArray array];
    if (![resources isKindOfClass:[NSArray class]]) return rows;
    for (id value in resources) {
        if (![value isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *server = value;
        if (![server[@"provides"] isKindOfClass:[NSString class]] ||
            ![[server[@"provides"] componentsSeparatedByString:@","] containsObject:@"server"] ||
            ![server[@"accessToken"] isKindOfClass:[NSString class]] || ![server[@"accessToken"] length]) continue;
        NSMutableArray *connections = [NSMutableArray array];
        if ([server[@"connections"] isKindOfClass:[NSArray class]]) for (id connection in server[@"connections"]) {
            if (![connection isKindOfClass:[NSDictionary class]]) continue;
            NSString *uri = connection[@"uri"];
            if (![uri isKindOfClass:[NSString class]]) continue;
            NSURL *url = [NSURL URLWithString:uri];
            if (![url.scheme isEqual:@"https"] || url.user || url.password) continue;
            if ([connection[@"local"] boolValue]) [connections insertObject:uri atIndex:0]; else [connections addObject:uri];
        }
        NSString *name = [server[@"name"] isKindOfClass:[NSString class]] ? server[@"name"] : @"Plex";
        if (connections.count) [rows addObject:@{@"title":name, @"action":@"setServer",
            @"connections":connections, @"serverToken":server[@"accessToken"], @"accountToken":accountToken, @"homeOwnerToken":homeOwnerToken ?: accountToken}];
    }
    return rows;
}

static void selectAvailableServer(NSArray *servers, NSUInteger index, void (^completion)(signed char))
{
    if (index >= servers.count) { completion(NO); return; }
    NSDictionary *server = servers[index];
    selectServer(server[@"connections"], 0, server[@"serverToken"], server[@"accountToken"], server[@"homeOwnerToken"], ^(signed char saved) {
        if (saved) completion(YES); else selectAvailableServer(servers, index + 1, completion);
    });
}

static void discoverPairedServer(NSString *token, NSString *homeOwnerToken, void (^completion)(signed char))
{
    PlexClient *account = [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:@"https://clients.plex.tv"] token:token clientID:@"RevivePlex-AppleTV3"];
    if (!account) { completion(NO); return; }
    [account fetchJSONPath:@"/api/v2/resources" query:@[[NSURLQueryItem queryItemWithName:@"includeHttps" value:@"1"],
        [NSURLQueryItem queryItemWithName:@"includeRelay" value:@"1"]] completion:^(id resources, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) completion(NO); else selectAvailableServer(serverChoices(resources, token, homeOwnerToken), 0, completion);
        });
    }];
}

static NSArray *jsonEntries(id value)
{
    if ([value isKindOfClass:[NSArray class]]) return value;
    if ([value isKindOfClass:[NSDictionary class]]) return @[value];
    return @[];
}

static NSString *stringNumber(id value) { return [value isKindOfClass:[NSNumber class]] ? [value stringValue] : ([value isKindOfClass:[NSString class]] ? value : nil); }
static BOOL validEPGPath(id path)
{
    if (![path isKindOfClass:[NSString class]] || ![path hasPrefix:@"/tv.plex.providers.epg."] || [path containsString:@".."] || [path containsString:@"?"] || [path containsString:@"#"]) return NO;
    return [path rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:_-01"] invertedSet]].length == 0;
}

id revivePlexDVRRows(id response, id dvrID)
{
    NSDictionary *container = [response isKindOfClass:[NSDictionary class]] ? response[@"MediaContainer"] : nil;
    if (![container isKindOfClass:[NSDictionary class]]) return @[];
    NSMutableArray *rows = [NSMutableArray array];
    for (id device in jsonEntries(container[@"Dvr"])) {
        if (![device isKindOfClass:[NSDictionary class]]) continue;
        NSString *key = [device[@"key"] isKindOfClass:[NSNumber class]] ? [device[@"key"] stringValue] : device[@"key"];
        if (!numberKey(key)) continue;
        if (!dvrID) {
            NSString *title = [device[@"name"] isKindOfClass:[NSString class]] ? device[@"name"] : RPText(@"Canlı TV");
            [rows addObject:row(title, @{@"title":title, @"kind":@"tvChannels", @"path":[@"/livetv/dvrs/" stringByAppendingString:key], @"dvrID":key})];
            continue;
        }
        if (![key isEqual:dvrID]) continue;
        for (id channel in jsonEntries(device[@"ChannelMapping"])) {
            if (![channel isKindOfClass:[NSDictionary class]] || ![channel[@"enabled"] boolValue]) continue;
            NSString *channelID = channel[@"deviceIdentifier"];
            if (![channelID isKindOfClass:[NSString class]] || !channelID.length || channelID.length > 128 ||
                [channelID rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-_"] invertedSet]].length) continue;
            NSString *title = [channel[@"title"] isKindOfClass:[NSString class]] ? channel[@"title"] : channelID;
            [rows addObject:row(title, @{@"title":title, @"kind":@"transcode", @"path":@"", @"liveDVR":key, @"liveChannel":channelID})];
        }
    }
    return rows;
}

static void queueWindow(PlexClient *client, NSString *queueID, NSString *center, BOOL before,
                        NSMutableArray *items, NSMutableSet *seen, void (^completion)(NSArray *))
{
    NSArray *query = @[[NSURLQueryItem queryItemWithName:@"center" value:center],
        [NSURLQueryItem queryItemWithName:@"window" value:@"50"],
        [NSURLQueryItem queryItemWithName:@"includeBefore" value:@"1"]];
    [client fetchPath:[@"/playQueues/" stringByAppendingString:queueID] query:query completion:^(NSDictionary *response, NSError *error) {
        if (error || items.count >= 20000) { completion(nil); return; }
        NSMutableArray *fresh = [NSMutableArray array];
        for (NSDictionary *item in response[@"items"]) {
            NSString *key = numberKey(item[@"playQueueItemID"]);
            if (key && ![seen containsObject:key]) { [seen addObject:key]; [fresh addObject:item]; }
        }
        if (before) {
            [fresh addObjectsFromArray:items]; [items removeAllObjects]; [items addObjectsFromArray:fresh];
        } else [items addObjectsFromArray:fresh];
        NSUInteger total = MAX(0, [response[@"attributes"][@"playQueueTotalCount"] integerValue]);
        if (!items.count || (total && items.count >= total)) { completion(items); return; }
        NSString *edge = (before ? [items firstObject] : [items lastObject])[@"playQueueItemID"];
        if (![edge isEqual:center]) { queueWindow(client, queueID, edge, before, items, seen, completion); return; }
        if (before) { queueWindow(client, queueID, [items lastObject][@"playQueueItemID"], NO, items, seen, completion); return; }
        completion(items);
    }];
}

static NSArray *castRows(NSDictionary *item)
{
    NSMutableArray *cast = [NSMutableArray array];
    for (NSDictionary *person in item[@"Role"]) {
        NSString *name = person[@"tag"];
        if (!name.length) continue;
        NSMutableDictionary *card = [@{@"title":name, @"shelf":@YES, @"mediaType":@"person",
            @"catalogCaption":person[@"role"] ?: @""} mutableCopy];
        NSString *personID = numberKey(person[@"id"]);
        if (personID) card[@"route"] = route(name, @"media", [NSString stringWithFormat:@"/library/people/%@/media", personID]);
        if ([person[@"thumb"] hasPrefix:@"/library/"] || [person[@"thumb"] hasPrefix:@"https://metadata-static.plex.tv/"]) card[@"artwork"] = person[@"thumb"];
        [cast addObject:card];
    }
    return cast.count ? cast : panelRows(@[row(RPText(@"İçerik bulunamadı"), nil)], nil);
}

void revivePlexLoadRows(id selectedRoute, void (^completion)(id))
{
    if ([selectedRoute[@"kind"] isEqual:@"about"]) {
        Dl_info location;
        NSDictionary *info = nil;
        if (dladdr(&defaultOrigin, &location) && location.dli_fname) {
            NSString *binary = [NSString stringWithUTF8String:location.dli_fname];
            info = [NSDictionary dictionaryWithContentsOfFile:[binary.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"Info.plist"]];
        }
        NSString *version = [info[@"CFBundleShortVersionString"] isKindOfClass:[NSString class]] ? info[@"CFBundleShortVersionString"] : RPText(@"Kullanılamıyor");
        NSString *build = [info[@"CFBundleVersion"] isKindOfClass:[NSString class]] ? info[@"CFBundleVersion"] : RPText(@"Kullanılamıyor");
        completion(panelRows(@[row(RPText(@"Hakkında"), nil)], @{@"about":@YES, @"version":version, @"build":build}));
        return;
    }

#ifdef REVIVEPLEX_DEMO_SCREENSHOTS
    if ([selectedRoute[@"kind"] isEqual:@"demo"]) { completion(revivePlexDemoRows(selectedRoute[@"path"])); return; }
#endif
    selectedRoute = revivePlexPrepareFilterRoute(selectedRoute);
    NSDictionary *settings = localSettings();
    NSString *origin = settings[@"origin"] ?: defaultOrigin;
    NSString *token = settings[@"token"];
#ifdef REVIVEPLEX_TEST
    origin = NSProcessInfo.processInfo.environment[@"REVIVEPLEX_TEST_ORIGIN"] ?: origin;
    token = nil;
#endif
    if (![origin isKindOfClass:[NSString class]] || (token && ![token isKindOfClass:[NSString class]])) {
        completion(@[row(RPText(@"Plex yapılandırması geçersiz"), nil)]);
        return;
    }
    NSString *kind = selectedRoute[@"kind"];
    NSString *path = selectedRoute[@"path"];
    if ([kind isEqual:@"tvGuideProviders"]) {
        PlexClient *client = [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:origin] token:token clientID:@"RevivePlex-AppleTV3"];
        [client fetchJSONPath:@"/media/providers" query:nil completion:^(id response, NSError *error) {
            NSMutableArray *options = [NSMutableArray array];
            id container = [response isKindOfClass:[NSDictionary class]] ? response[@"MediaContainer"] : nil;
            for (id provider in jsonEntries([container isKindOfClass:[NSDictionary class]] ? container[@"MediaProvider"] : nil)) {
                if (![provider isKindOfClass:[NSDictionary class]]) continue;
                for (id feature in jsonEntries(provider[@"Feature"])) {
                    if (![feature isKindOfClass:[NSDictionary class]] || ![feature[@"type"] isEqual:@"grid"]) continue;
                    NSString *grid = feature[@"key"];
                    if (!validEPGPath(grid) || ![grid hasSuffix:@"/grid"]) continue;
                    NSString *title = [provider[@"title"] isKindOfClass:[NSString class]] ? provider[@"title"] : RPText(@"Program rehberi");
                    [options addObject:row(title, @{@"title":title, @"kind":@"tvGuideChannels", @"path":[grid.stringByDeletingLastPathComponent stringByAppendingString:@"/lineups/dvr/channels"], @"gridPath":grid})];
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{ completion(panelRows(options.count ? options : @[row(error ? RPText(@"Bağlantı kurulamadı") : RPText(@"Program rehberi bulunamadı"), nil)], nil)); });
        }]; return;
    }
    if ([kind isEqual:@"tvGuideChannels"] || [kind isEqual:@"tvGuideDay"]) {
        BOOL day = [kind isEqual:@"tvGuideDay"];
        if (!validEPGPath(path)) { completion(panelRows(@[row(RPText(@"Program rehberi bulunamadı"), nil)], nil)); return; }
        NSDateFormatter *dateFormat = [NSDateFormatter new]; dateFormat.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"]; dateFormat.dateFormat = @"yyyy-MM-dd";
        NSString *date = [selectedRoute[@"date"] isKindOfClass:[NSString class]] ? selectedRoute[@"date"] : [dateFormat stringFromDate:[NSDate date]];
        if (day && (![selectedRoute[@"channelGridKey"] isKindOfClass:[NSString class]] || ![dateFormat dateFromString:date])) { completion(@[]); return; }
        PlexClient *client = [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:origin] token:token clientID:@"RevivePlex-AppleTV3"];
        NSArray *query = day ? @[[NSURLQueryItem queryItemWithName:@"channelGridKey" value:selectedRoute[@"channelGridKey"]], [NSURLQueryItem queryItemWithName:@"date" value:date]] : nil;
        [client fetchJSONPath:path query:query completion:^(id response, NSError *error) {
            NSMutableArray *options = [NSMutableArray array];
            id container = [response isKindOfClass:[NSDictionary class]] ? response[@"MediaContainer"] : nil;
            if (day) {
                for (NSNumber *delta in @[@(-1), @1]) {
                    NSDate *nextDate = [[NSCalendar currentCalendar] dateByAddingUnit:NSCalendarUnitDay value:delta.integerValue toDate:[dateFormat dateFromString:date] options:0];
                    NSMutableDictionary *next = [selectedRoute mutableCopy]; next[@"date"] = [dateFormat stringFromDate:nextDate];
                    [options addObject:row(delta.intValue < 0 ? RPText(@"Önceki gün") : RPText(@"Sonraki gün"), next)];
                }
            }
            for (id entry in jsonEntries([container isKindOfClass:[NSDictionary class]] ? container[day ? @"Metadata" : @"Channel"] : nil)) {
                if (![entry isKindOfClass:[NSDictionary class]]) continue;
                NSString *title = entry[@"grandparentTitle"] ?: entry[@"title"];
                if (![title isKindOfClass:[NSString class]] || !title.length) continue;
                if (!day) {
                    NSString *gridKey = entry[@"gridKey"] ?: entry[@"id"];
                    if (![gridKey isKindOfClass:[NSString class]] || !gridKey.length) continue;
                    [options addObject:row(title, @{@"title":title, @"kind":@"tvGuideDay", @"path":selectedRoute[@"gridPath"], @"channelGridKey":gridKey})];
                } else {
                    for (id airing in jsonEntries(entry[@"Media"])) {
                        if (![airing isKindOfClass:[NSDictionary class]]) continue;
                        double begins = [airing[@"beginsAt"] doubleValue];
                        if (!isfinite(begins) || begins <= 0) continue;
                        NSDateFormatter *time = [NSDateFormatter new]; time.locale = [[NSLocale alloc] initWithLocaleIdentifier:revivePlexLanguage()]; time.timeStyle = NSDateFormatterShortStyle;
                        NSString *when = [time stringFromDate:[NSDate dateWithTimeIntervalSince1970:begins]];
                        [options addObject:row([NSString stringWithFormat:@"%@  ·  %@", when, title], @{@"title":title, @"kind":@"tvAiring", @"path":@"", @"metadata":entry, @"airing":airing})];
                    }
                }
            }
            if (options.count == (day ? 2 : 0)) [options addObject:row(error ? RPText(@"Bağlantı kurulamadı") : RPText(@"Yayın bulunamadı"), nil)];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(panelRows(options, day ? @{@"summary":date} : nil)); });
        }]; return;
    }
    if ([kind isEqual:@"tvAiring"]) {
        NSDictionary *metadata = selectedRoute[@"metadata"], *airing = selectedRoute[@"airing"];
        NSMutableArray *options = [NSMutableArray array];
        NSString *guid = metadata[@"guid"];
        if ([guid isKindOfClass:[NSString class]] && guid.length && [airing[@"endsAt"] doubleValue] > [[NSDate date] timeIntervalSince1970])
            [options addObject:row(RPText(@"Kaydet"), @{@"title":selectedRoute[@"title"], @"kind":@"recordingTemplates", @"path":@"", @"guid":guid})];
        if (!options.count) [options addObject:row(RPText(@"Bu yayın sona erdi"), nil)];
        completion(panelRows(options, @{@"title":selectedRoute[@"title"] ?: @"", @"summary":[NSString stringWithFormat:@"%@\n\n%@", metadata[@"title"] ?: @"", metadata[@"summary"] ?: @""]})); return;
    }
    if ([kind isEqual:@"recordingTemplates"]) {
        NSString *guid = selectedRoute[@"guid"];
        if (![guid isKindOfClass:[NSString class]] || !guid.length) { completion(@[]); return; }
        PlexClient *client = [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:origin] token:token clientID:@"RevivePlex-AppleTV3"];
        [client fetchJSONPath:@"/media/subscriptions/template" query:@[[NSURLQueryItem queryItemWithName:@"guid" value:guid]] completion:^(id response, NSError *error) {
            NSMutableArray *options = [NSMutableArray array];
            id container = [response isKindOfClass:[NSDictionary class]] ? response[@"MediaContainer"] : nil;
            for (id group in jsonEntries([container isKindOfClass:[NSDictionary class]] ? container[@"SubscriptionTemplate"] : nil)) {
                if (![group isKindOfClass:[NSDictionary class]]) continue;
                for (id item in jsonEntries(group[@"MediaSubscription"])) {
                    if (![item isKindOfClass:[NSDictionary class]] || ![item[@"parameters"] isKindOfClass:[NSString class]] || ![item[@"title"] isKindOfClass:[NSString class]]) continue;
                    [options addObject:row(item[@"title"], @{@"title":item[@"title"], @"kind":@"recordingDestination", @"path":@"", @"template":item})];
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{ completion(panelRows(options.count ? options : @[row(error ? RPText(@"Bağlantı kurulamadı") : RPText(@"Kayıt seçeneği bulunamadı"), nil)], nil)); });
        }]; return;
    }
    if ([kind isEqual:@"recordingDestination"]) {
        PlexClient *client = [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:origin] token:token clientID:@"RevivePlex-AppleTV3"];
        NSDictionary *template = selectedRoute[@"template"];
        [client fetchJSONPath:@"/library/sections" query:nil completion:^(id response, NSError *error) {
            NSMutableArray *options = [NSMutableArray array];
            id container = [response isKindOfClass:[NSDictionary class]] ? response[@"MediaContainer"] : nil;
            for (id section in jsonEntries([container isKindOfClass:[NSDictionary class]] ? container[@"Directory"] : nil)) {
                if (![section isKindOfClass:[NSDictionary class]]) continue;
                NSString *type = [template[@"type"] intValue] == 1 ? @"movie" : @"show";
                if (![section[@"type"] isEqual:type]) continue;
                NSString *sectionID = stringNumber(section[@"key"]);
                if (!numberKey(sectionID) || ![section[@"title"] isKindOfClass:[NSString class]]) continue;
                for (id location in jsonEntries(section[@"Location"])) {
                    if (![location isKindOfClass:[NSDictionary class]]) continue;
                    NSString *locationID = stringNumber(location[@"id"]);
                    if (!numberKey(locationID)) continue;
                    NSString *label = [jsonEntries(section[@"Location"]) count] > 1 ? [NSString stringWithFormat:@"%@ · %@", section[@"title"], location[@"path"] ?: locationID] : section[@"title"];
                    [options addObject:row(label, @{@"title":RPText(@"Kaydı planla"), @"kind":@"recordingCreateConfirm", @"path":@"", @"template":template, @"sectionID":sectionID, @"locationID":locationID, @"destination":label})];
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{ completion(panelRows(options.count ? options : @[row(error ? RPText(@"Bağlantı kurulamadı") : RPText(@"Uygun kayıt kütüphanesi bulunamadı"), nil)], @{@"summary":RPText(@"Kaydın saklanacağı kütüphaneyi seç.")})); });
        }]; return;
    }
    if ([kind isEqual:@"recordingCreateConfirm"]) {
        NSMutableDictionary *action = [selectedRoute mutableCopy]; action[@"action"] = @"createRecording"; action[@"title"] = RPText(@"Kaydı planla");
        completion(panelRows(@[action], @{@"summary":[NSString stringWithFormat:@"%@\n%@", selectedRoute[@"template"][@"title"] ?: @"", selectedRoute[@"destination"] ?: @""]})); return;
    }
    if ([kind isEqual:@"recordingSchedule"] || [kind isEqual:@"recordingRules"]) {
        BOOL schedule = [kind isEqual:@"recordingSchedule"];
        PlexClient *client = [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:origin] token:token clientID:@"RevivePlex-AppleTV3"];
        [client fetchJSONPath:schedule ? @"/media/subscriptions/scheduled" : @"/media/subscriptions" query:nil completion:^(id result, NSError *error) {
            NSMutableArray *options = [NSMutableArray array];
            NSDictionary *container = [result isKindOfClass:[NSDictionary class]] ? result[@"MediaContainer"] : nil;
            if ([container isKindOfClass:[NSDictionary class]]) for (id entry in jsonEntries(container[schedule ? @"MediaGrabOperation" : @"MediaSubscription"])) {
                if (![entry isKindOfClass:[NSDictionary class]]) continue;
                if (schedule) {
                    NSDictionary *metadata = [entry[@"Metadata"] isKindOfClass:[NSDictionary class]] ? entry[@"Metadata"] : nil;
                    NSString *title = metadata[@"grandparentTitle"] ?: metadata[@"title"];
                    if (![title isKindOfClass:[NSString class]] || !title.length) continue;
                    NSString *status = [entry[@"status"] isKindOfClass:[NSString class]] ? entry[@"status"] : @"";
                    NSDictionary *media = [jsonEntries(metadata[@"Media"]) firstObject];
                    double begins = [media isKindOfClass:[NSDictionary class]] ? [media[@"beginsAt"] doubleValue] : 0;
                    NSString *when = @"";
                    if (begins > 0) {
                        NSDateFormatter *format = [NSDateFormatter new]; format.locale = [[NSLocale alloc] initWithLocaleIdentifier:revivePlexLanguage()]; format.dateStyle = NSDateFormatterMediumStyle; format.timeStyle = NSDateFormatterShortStyle;
                        when = [format stringFromDate:[NSDate dateWithTimeIntervalSince1970:begins]];
                    }
                    NSString *summary = [NSString stringWithFormat:@"%@\n%@\n%@\n\n%@", metadata[@"title"] ?: @"", when, status, metadata[@"summary"] ?: @""];
                    [options addObject:row(title, @{@"title":title, @"kind":@"recordingInfo", @"path":@"", @"summary":summary})];
                } else {
                    NSString *key = [entry[@"key"] isKindOfClass:[NSNumber class]] ? [entry[@"key"] stringValue] : entry[@"key"];
                    NSString *title = entry[@"title"];
                    if (!numberKey(key) || ![title isKindOfClass:[NSString class]]) continue;
                    [options addObject:row(title, @{@"title":title, @"kind":@"recordingRule", @"path":@"", @"subscriptionID":key, @"settings":jsonEntries(entry[@"Setting"])})];
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{ completion(panelRows(options.count ? options : @[row(error ? RPText(@"Bağlantı kurulamadı") : RPText(@"Planlanmış kayıt bulunamadı"), nil)], nil)); });
        }]; return;
    }
    if ([kind isEqual:@"recordingInfo"]) {
        completion(panelRows(@[row(selectedRoute[@"title"], nil)], @{@"title":selectedRoute[@"title"] ?: @"", @"longText":selectedRoute[@"summary"] ?: @""})); return;
    }
    if ([kind isEqual:@"recordingRule"]) {
        NSMutableArray *options = [NSMutableArray array];
        for (id setting in jsonEntries(selectedRoute[@"settings"])) {
            if (![setting isKindOfClass:[NSDictionary class]] || [setting[@"hidden"] boolValue]) continue;
            NSString *name = setting[@"id"], *label = setting[@"label"];
            if (![name isKindOfClass:[NSString class]] || !name.length || [name rangeOfCharacterFromSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]].length || ![label isKindOfClass:[NSString class]]) continue;
            NSString *enums = setting[@"enumValues"];
            if ([enums isKindOfClass:[NSString class]] && enums.length)
                [options addObject:row(label, @{@"title":label, @"kind":@"recordingPreference", @"path":@"", @"subscriptionID":selectedRoute[@"subscriptionID"], @"preference":name, @"values":enums})];
        }
        [options addObject:row(RPText(@"Kayıt kuralını kaldır"), @{@"title":RPText(@"Kayıt kuralını kaldır"), @"kind":@"recordingDeleteConfirm", @"path":@"", @"subscriptionID":selectedRoute[@"subscriptionID"]})];
        completion(panelRows(options, nil)); return;
    }
    if ([kind isEqual:@"recordingPreference"]) {
        NSMutableArray *options = [NSMutableArray array];
        for (NSString *choice in [selectedRoute[@"values"] componentsSeparatedByString:@"|"]) {
            NSRange separator = [choice rangeOfString:@":"];
            if (separator.location == NSNotFound) continue;
            NSString *value = [choice substringToIndex:separator.location], *label = [choice substringFromIndex:separator.location + 1];
            [options addObject:@{@"title":label, @"action":@"setRecordingPreference", @"subscriptionID":selectedRoute[@"subscriptionID"], @"preference":selectedRoute[@"preference"], @"value":value}];
        }
        completion(panelRows(options.count ? options : @[row(RPText(@"İçerik bulunamadı"), nil)], nil)); return;
    }
    if ([kind isEqual:@"recordingDeleteConfirm"]) {
        completion(panelRows(@[@{@"title":RPText(@"Kayıt kuralını kaldır"), @"action":@"deleteRecordingRule", @"subscriptionID":selectedRoute[@"subscriptionID"]}],
            @{@"summary":RPText(@"Bu kuralın gelecekteki kayıtları iptal edilir. Mevcut kayıt dosyaları korunur. Vazgeçmek için Geri'ye bas.")})); return;
    }
    if ([kind isEqual:@"liveTV"] || [kind isEqual:@"tvChannels"]) {
        PlexClient *client = [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:origin] token:token clientID:@"RevivePlex-AppleTV3"];
        NSString *dvrID = [kind isEqual:@"tvChannels"] ? numberKey(selectedRoute[@"dvrID"]) : nil;
        NSString *requestPath = dvrID ? [@"/livetv/dvrs/" stringByAppendingString:dvrID] : @"/livetv/dvrs";
        [client fetchJSONPath:requestPath query:nil completion:^(id result, NSError *error) {
            NSMutableArray *channels = [revivePlexDVRRows(result, dvrID) mutableCopy];
            BOOL hasChannels = channels.count > 0;
            if (!dvrID && !error) {
                [channels addObject:row(RPText(@"Program rehberi"), route(RPText(@"Program rehberi"), @"tvGuideProviders", @""))];
                [channels addObject:row(RPText(@"Kayıt takvimi"), route(RPText(@"Kayıt takvimi"), @"recordingSchedule", @""))];
                [channels addObject:row(RPText(@"Kayıt kuralları"), route(RPText(@"Kayıt kuralları"), @"recordingRules", @""))];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(panelRows(channels.count ? channels : @[row(error ? RPText(@"Bağlantı kurulamadı") : RPText(@"Kullanılabilir kanal bulunamadı"), nil)],
                    hasChannels || error ? nil : @{@"summary":RPText(@"Plex sunucusunda Live TV ve DVR kurulumu yapılmış bir tuner ve etkin kanallar gerekir.")}));
            });
        }]; return;
    }
    if ([kind isEqual:@"discoverResults"]) {
        PlexClient *cloud = discoverClient();
        if (!cloud) { completion(@[row(RPText(@"Plex kimlik doğrulaması gerekli"), nil)]); return; }
        [cloud fetchJSONPath:@"/library/search" query:@[
            [NSURLQueryItem queryItemWithName:@"query" value:selectedRoute[@"query"] ?: @""],
            [NSURLQueryItem queryItemWithName:@"limit" value:@"100"],
            [NSURLQueryItem queryItemWithName:@"searchTypes" value:@"movies,tv"],
            [NSURLQueryItem queryItemWithName:@"searchProviders" value:@"discover"],
            [NSURLQueryItem queryItemWithName:@"includeMetadata" value:@"1"]] completion:^(id response, NSError *error) {
            NSMutableArray *items = [NSMutableArray array];
            NSDictionary *container = [response isKindOfClass:[NSDictionary class]] ? response[@"MediaContainer"] : nil;
            if ([container isKindOfClass:[NSDictionary class]] && [container[@"SearchResults"] isKindOfClass:[NSArray class]])
                for (id group in container[@"SearchResults"]) {
                    if (![group isKindOfClass:[NSDictionary class]] || ![group[@"id"] isEqual:@"external"] || ![group[@"SearchResult"] isKindOfClass:[NSArray class]]) continue;
                    for (id result in group[@"SearchResult"]) if ([result isKindOfClass:[NSDictionary class]] && [result[@"Metadata"] isKindOfClass:[NSDictionary class]]) [items addObject:result[@"Metadata"]];
                }
            NSArray *cards = cloudCards(items);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(cards.count ? cards : @[row(error ? RPText(@"Bağlantı kurulamadı") : RPText(@"Sonuç bulunamadı"), nil)]); });
        }]; return;
    }
    if ([kind isEqual:@"queueItems"] || [kind isEqual:@"queueEdit"]) {
        NSDictionary *snapshot = selectedRoute[@"queueSnapshot"];
        NSString *queueID = numberKey(snapshot[@"id"]), *itemID = numberKey(snapshot[@"itemID"]);
        if (!queueID || !itemID) { completion(panelRows(@[row(RPText(@"İçerik bulunamadı"), nil)], nil)); return; }
        PlexClient *client = [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:origin] token:token clientID:@"RevivePlex-AppleTV3"];
        queueWindow(client, queueID, itemID, YES, [NSMutableArray array], [NSMutableSet set], ^(NSArray *items) {
            NSMutableArray *cards = [NSMutableArray array];
            for (NSUInteger i = 0; i < items.count; i++) {
                NSDictionary *item = items[i];
                NSDictionary *card = [mediaRows(@[item], @"media") firstObject];
                if (!card || !numberKey(item[@"ratingKey"])) continue;
                NSMutableDictionary *nextSnapshot = [snapshot mutableCopy]; nextSnapshot[@"itemID"] = item[@"playQueueItemID"];
                NSMutableDictionary *copy = [card mutableCopy];
                copy[@"route"] = @{@"title":card[@"title"], @"kind":@"transcode", @"path":[@"/library/metadata/" stringByAppendingString:item[@"ratingKey"]], @"queueSnapshot":nextSnapshot, @"diagnostic":@([selectedRoute[@"diagnostic"] boolValue])};
                if ([kind isEqual:@"queueEdit"]) {
                    NSMutableDictionary *edit = [@{@"title":card[@"title"], @"kind":@"queueItemActions", @"path":@"", @"queueID":queueID, @"queueItemID":item[@"playQueueItemID"], @"currentItemID":itemID} mutableCopy];
                    if (i) edit[@"upAfter"] = i > 1 ? items[i-2][@"playQueueItemID"] : @"";
                    if (i + 1 < items.count) edit[@"downAfter"] = items[i+1][@"playQueueItemID"];
                    copy[@"route"] = edit;
                }
                [cards addObject:copy];
            }
            dispatch_async(dispatch_get_main_queue(), ^{ completion(cards.count ? cards : panelRows(@[row(items ? RPText(@"İçerik bulunamadı") : RPText(@"Bağlantı kurulamadı"), nil)], nil)); });
        }); return;
    }
    if ([kind isEqual:@"queueItemActions"]) {
        NSMutableArray *actions = [NSMutableArray array];
        for (NSArray *move in @[@[@"upAfter", RPText(@"Bir yukarı taşı")], @[@"downAfter", RPText(@"Bir aşağı taşı")]]) {
            if (!selectedRoute[move[0]]) continue;
            [actions addObject:@{@"title":move[1], @"action":@"moveQueueItem", @"queueID":selectedRoute[@"queueID"], @"queueItemID":selectedRoute[@"queueItemID"], @"after":selectedRoute[move[0]]}];
        }
        if (![selectedRoute[@"queueItemID"] isEqual:selectedRoute[@"currentItemID"]])
            [actions addObject:@{@"title":RPText(@"Sıradan çıkar"), @"action":@"removeQueueItem", @"queueID":selectedRoute[@"queueID"], @"queueItemID":selectedRoute[@"queueItemID"], @"currentItemID":selectedRoute[@"currentItemID"]}];
        completion(panelRows(actions.count ? actions : @[row(RPText(@"Şimdi oynatılıyor"), nil)], nil)); return;
    }
    if ([kind isEqual:@"queueModes"]) {
        NSMutableArray *modes = [NSMutableArray array];
        for (NSArray *mode in @[@[RPText(@"Tekrar kapalı"), @NO, @NO], @[RPText(@"Tüm sırayı tekrarla"), @YES, @NO], @[RPText(@"Bu içeriği tekrarla"), @NO, @YES]]) {
            NSMutableDictionary *next = [selectedRoute mutableCopy], *queue = [selectedRoute[@"queueSnapshot"] mutableCopy];
            if (!numberKey(queue[@"id"])) continue;
            queue[@"repeat"] = mode[1]; queue[@"repeatOne"] = mode[2];
            next[@"queueSnapshot"] = queue; next[@"kind"] = @"transcode";
            [modes addObject:row(mode[0], next)];
        }
        completion(panelRows(modes, @{@"summary":RPText(@"Seçimin ardından oynatma kaldığı yerden devam eder.")})); return;
    }
    if ([kind isEqual:@"playbackOptions"]) {
        NSDictionary *resume = revivePlexResumeOptionsRoute(selectedRoute);
        if ([selectedRoute[@"live"] boolValue]) {
            completion(panelRows(@[row(RPText(@"İzlemeye devam et"), resume),
                row(RPText(@"Video kalitesi"), route(RPText(@"Video kalitesi"), @"quality", @""))], @{@"actionGrid":@YES})); return;
        }
        NSMutableArray *options = [NSMutableArray arrayWithArray:@[
            row(selectedRoute[@"playbackError"] ? RPText(@"Yeniden dene") : RPText(@"İzlemeye devam et"), resume),
            row(RPText(@"Ses"), @{@"title":RPText(@"Ses"), @"kind":@"streams", @"path":path, @"streamType":@2, @"mediaIndex":selectedRoute[@"mediaIndex"] ?: @0})]];
        if (![selectedRoute[@"audio"] boolValue]) {
            [options addObject:row(RPText(@"Altyazı"), @{@"title":RPText(@"Altyazı"), @"kind":@"streams", @"path":path, @"streamType":@3, @"mediaIndex":selectedRoute[@"mediaIndex"] ?: @0})];
            [options addObject:row(RPText(@"Video kalitesi"), route(RPText(@"Video kalitesi"), @"quality", @""))];
        }
        if ([selectedRoute[@"versionCount"] intValue] > 1) {
            NSMutableDictionary *versions = [selectedRoute mutableCopy]; versions[@"kind"] = @"versions"; versions[@"title"] = RPText(@"Sürüm seç");
            [options addObject:row(RPText(@"Sürüm seç"), versions)];
        }
        if (numberKey(selectedRoute[@"queueSnapshot"][@"id"])) [options addObject:row(RPText(@"Oynatma sırası"),
            @{@"title":RPText(@"Oynatma sırası"), @"kind":@"queueItems", @"path":@"", @"queueSnapshot":selectedRoute[@"queueSnapshot"], @"diagnostic":@([selectedRoute[@"diagnostic"] boolValue])})];
        if (numberKey(selectedRoute[@"queueSnapshot"][@"id"])) [options addObject:row(RPText(@"Sırayı düzenle"),
            @{@"title":RPText(@"Sırayı düzenle"), @"kind":@"queueEdit", @"path":@"", @"queueSnapshot":selectedRoute[@"queueSnapshot"]})];
        if (numberKey(selectedRoute[@"queueSnapshot"][@"id"])) {
            NSMutableDictionary *modeRoute = [selectedRoute mutableCopy]; modeRoute[@"kind"] = @"queueModes"; modeRoute[@"title"] = RPText(@"Tekrar");
            [options addObject:row(RPText(@"Tekrar"), modeRoute)];
        }
        completion(panelRows(options, @{@"actionGrid":@YES, @"summary":selectedRoute[@"playbackError"] ?: RPText(@"Seçenekleri değiştirdikten sonra kaldığın yerden devam et.")})); return;
    }
    if ([kind isEqual:@"playlistDeleteConfirm"]) {
        completion(panelRows(@[@{@"title":RPText(@"Listeyi sil"), @"action":@"deletePlaylist", @"playlistID":selectedRoute[@"playlistID"]}],
            @{@"summary":RPText(@"Yalnızca çalma listesi silinir; kütüphanedeki dosyalar korunur. Vazgeçmek için Geri'ye bas.")})); return;
    }
    if ([kind isEqual:@"playlistItemActions"]) {
        NSMutableArray *actions = [NSMutableArray array];
        for (NSArray *move in @[@[@"upAfter", RPText(@"Bir yukarı taşı")], @[@"downAfter", RPText(@"Bir aşağı taşı")]]) {
            if (!selectedRoute[move[0]]) continue;
            [actions addObject:@{@"title":move[1], @"action":@"movePlaylistItem", @"playlistID":selectedRoute[@"playlistID"],
                @"playlistItemID":selectedRoute[@"playlistItemID"], @"after":selectedRoute[move[0]]}];
        }
        [actions addObject:@{@"title":RPText(@"Listeden çıkar"), @"action":@"removePlaylistItem", @"playlistID":selectedRoute[@"playlistID"], @"playlistItemID":selectedRoute[@"playlistItemID"]}];
        completion(panelRows(actions, @{@"title":selectedRoute[@"title"] ?: @""})); return;
    }
    if ([kind isEqual:@"playlistManage"] || [kind isEqual:@"playlistEdit"]) {
        PlexClient *client = [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:origin] token:token clientID:@"RevivePlex-AppleTV3"];
        NSString *playlistID = numberKey(selectedRoute[@"playlistID"]);
        if (!playlistID) { completion(panelRows(@[row(RPText(@"İçerik bulunamadı"), nil)], nil)); return; }
        [client fetchCatalogPath:path query:nil completion:^(NSDictionary *data, NSError *error) {
            NSMutableArray *options = [NSMutableArray array];
            if (!error && [kind isEqual:@"playlistManage"]) {
                NSDictionary *playlist = [data[@"items"] firstObject];
                [options addObject:row(RPText(@"Yeniden adlandır"), @{@"title":RPText(@"Yeniden adlandır"), @"kind":@"playlistName", @"path":@"", @"playlistID":playlistID, @"initialTitle":playlist[@"title"] ?: @""})];
                if (![playlist[@"smart"] boolValue]) [options addObject:row(RPText(@"İçerikleri düzenle"), @{@"title":playlist[@"title"] ?: @"", @"kind":@"playlistEdit", @"path":[path stringByAppendingString:@"/items"], @"playlistID":playlistID})];
                [options addObject:row(RPText(@"Listeyi sil"), @{@"title":RPText(@"Listeyi sil"), @"kind":@"playlistDeleteConfirm", @"path":path, @"playlistID":playlistID})];
            } else if (!error) {
                NSArray *items = data[@"items"];
                for (NSUInteger i = 0; i < items.count; i++) {
                    NSDictionary *item = items[i];
                    NSString *itemID = numberKey(item[@"playlistItemID"]);
                    NSDictionary *card = [mediaRows(@[item], @"media") firstObject];
                    if (!itemID || !card) continue;
                    NSMutableDictionary *next = [@{@"title":card[@"title"], @"kind":@"playlistItemActions", @"path":path, @"playlistID":playlistID, @"playlistItemID":itemID} mutableCopy];
                    if (i > 0) next[@"upAfter"] = i > 1 ? items[i-2][@"playlistItemID"] ?: @"" : @"";
                    if (i + 1 < items.count) next[@"downAfter"] = items[i+1][@"playlistItemID"] ?: @"";
                    NSMutableDictionary *copy = [card mutableCopy]; copy[@"route"] = next; [options addObject:copy];
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{ completion(options.count ? ([kind isEqual:@"playlistManage"] ? panelRows(options, nil) : options) : panelRows(@[row(error ? RPText(@"Bağlantı kurulamadı") : RPText(@"İçerik bulunamadı"), nil)], nil)); });
        }]; return;
    }
    if ([kind isEqual:@"playlistName"]) { completion(revivePlexPlaylistNameRows(selectedRoute, selectedRoute[@"initialTitle"] ?: @"", 0)); return; }
    if ([kind isEqual:@"playlistPicker"]) {
        PlexClient *client = [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:origin] token:token clientID:@"RevivePlex-AppleTV3"];
        [client fetchCatalogPath:@"/playlists" query:nil completion:^(NSDictionary *data, NSError *error) {
            NSMutableArray *options = [NSMutableArray array];
            if (!error) {
                [options addObject:row(RPText(@"Yeni liste"), @{@"title":RPText(@"Yeni liste"), @"kind":@"playlistName", @"path":@"",
                    @"initialTitle":selectedRoute[@"itemTitle"] ?: @"", @"ratingKey":selectedRoute[@"ratingKey"], @"playlistType":selectedRoute[@"playlistType"]})];
                for (NSDictionary *item in data[@"items"]) {
                    if ([item[@"smart"] boolValue] || ![item[@"playlistType"] isEqual:selectedRoute[@"playlistType"]] || !numberKey(item[@"ratingKey"])) continue;
                    [options addObject:@{@"title":item[@"title"] ?: @"Plex", @"action":@"addPlaylistItem", @"playlistID":item[@"ratingKey"], @"ratingKey":selectedRoute[@"ratingKey"]}];
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{ completion(panelRows(error ? @[row(RPText(@"Bağlantı kurulamadı"), nil)] : options, nil)); });
        }]; return;
    }
    if ([kind isEqual:@"more"]) {
        completion(panelRows(@[
            row(RPText(@"Keşfet"), route(RPText(@"Keşfet"), @"discoverSearch", @"")),
            row(RPText(@"Çalma listeleri"), route(RPText(@"Çalma listeleri"), @"media", @"/playlists")),
            row(RPText(@"Plex Home kullanıcıları"), route(RPText(@"Plex Home kullanıcıları"), @"homeUsers", @"")),
            row(RPText(@"Canlı TV"), route(RPText(@"Canlı TV"), @"liveTV", @"/livetv/dvrs")),
            row(RPText(@"Ayarlar"), route(RPText(@"Ayarlar"), @"settings", @""))], @{@"actionGrid":@YES})); return;
    }
    if ([kind isEqual:@"watchlist"]) {
        PlexClient *cloud = discoverClient();
        if (!cloud) { completion(panelRows(@[row(RPText(@"Plex kimlik doğrulaması gerekli"), nil)], nil)); return; }
        fetchWatchlist(cloud, [NSMutableArray array], ^(NSArray *items, NSError *error) {
            NSArray *rows = cloudCards(items);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(rows.count ? rows : panelRows(@[row(error ? RPText(@"Bağlantı kurulamadı") : RPText(@"İçerik bulunamadı"), nil)], nil)); });
        }); return;
    }
    if ([kind isEqual:@"cloudItem"]) {
        NSString *key = cloudKey(selectedRoute[@"guid"]);
        if (!key) { completion(panelRows(@[row(RPText(@"Ayrıntı bulunamadı"), nil)], nil)); return; }
        PlexClient *local = [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:origin] token:token clientID:@"RevivePlex-AppleTV3"];
        [local fetchPath:@"/library/all" query:@[[NSURLQueryItem queryItemWithName:@"guid" value:selectedRoute[@"guid"]]] completion:^(NSDictionary *data, NSError *error) {
            NSDictionary *match = [mediaRows(data[@"items"], @"media") firstObject][@"route"];
            if (!error && match) { revivePlexLoadRows(match, completion); return; }
            PlexClient *cloud = discoverClient();
            if (!cloud) { dispatch_async(dispatch_get_main_queue(), ^{ completion(panelRows(@[row(RPText(@"Bağlantı kurulamadı"), nil)], nil)); }); return; }
            [cloud fetchJSONPath:[@"/library/metadata/" stringByAppendingString:key] query:nil completion:^(id info, NSError *cloudError) {
                NSDictionary *item = [info[@"MediaContainer"][@"Metadata"] firstObject];
                NSArray *actions = watchlistKeys ? @[@{@"title":[watchlistKeys containsObject:key] ? RPText(@"İzleme listesinden çıkar") : RPText(@"İzleme listesine ekle"), @"action":@"watchlist", @"cloudKey":key, @"remove":@([watchlistKeys containsObject:key])}] : @[row(RPText(@"Bu içerik seçili sunucuda bulunmuyor"), nil)];
                NSDictionary *details = @{@"title":item[@"title"] ?: selectedRoute[@"title"], @"summary":item[@"summary"] ?: @"",
                    @"facts":RPText(@"Bu içerik seçili sunucuda bulunmuyor"), @"artwork":item[@"thumb"] ?: @""};
                dispatch_async(dispatch_get_main_queue(), ^{ completion(cloudError ? panelRows(@[row(RPText(@"Bağlantı kurulamadı"), nil)], nil) : panelRows(actions, details)); });
            }];
        }]; return;
    }
    if ([kind isEqual:@"rating"]) {
        NSMutableArray *options = [NSMutableArray array];
        NSString *key = numberKey(selectedRoute[@"ratingKey"]);
        if (!key) { completion(panelRows(@[row(RPText(@"Ayrıntı bulunamadı"), nil)], nil)); return; }
        for (int rating = 0; rating <= 5; rating++)
            [options addObject:@{@"title":[NSString stringWithFormat:@"%d / 5", rating], @"action":@"setRating", @"ratingKey":key, @"value":@(rating * 2)}];
        completion(panelRows(options, @{@"actionGrid":@YES})); return;
    }
    if ([kind isEqual:@"homePIN"]) { completion(revivePlexHomePINRows(selectedRoute[@"userID"], @"")); return; }
    if ([kind isEqual:@"homeUsers"]) {
        NSString *accountToken = settings[@"homeOwnerToken"] ?: settings[@"accountToken"] ?: token;
        PlexClient *account = [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:@"https://clients.plex.tv"] token:accountToken clientID:@"RevivePlex-AppleTV3"];
        if (!account || !accountToken.length) { completion(panelRows(@[row(RPText(@"Plex kimlik doğrulaması gerekli"), nil)], nil)); return; }
        [account fetchPath:@"/api/home/users" query:nil completion:^(NSDictionary *result, NSError *error) {
            NSMutableArray *rows = [NSMutableArray array];
            for (NSDictionary *user in result[@"items"]) {
                NSString *key = numberKey(user[@"id"]), *title = user[@"title"] ?: user[@"username"];
                if (!key || !title.length) continue;
                if ([user[@"protected"] boolValue]) [rows addObject:row(title, @{@"title":title, @"kind":@"homePIN", @"path":@"", @"userID":key})];
                else [rows addObject:@{@"title":title, @"action":@"setHomeUser", @"userID":key}];
            }
            syslog(LOG_NOTICE, "RevivePlex: Home profiles count=%lu error=%ld", (unsigned long)rows.count, (long)error.code);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(panelRows(rows.count ? rows : @[row(error ? RPText(@"Bağlantı kurulamadı") : RPText(@"İçerik bulunamadı"), nil)], nil)); });
        }]; return;
    }
    if ([kind isEqual:@"servers"]) {
        NSString *accountToken = settings[@"accountToken"] ?: token;
        PlexClient *account = [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:@"https://clients.plex.tv"] token:accountToken clientID:@"RevivePlex-AppleTV3"];
        if (!account || !accountToken.length) { completion(panelRows(@[row(RPText(@"Plex kimlik doğrulaması gerekli"), nil)], nil)); return; }
        [account fetchJSONPath:@"/api/v2/resources" query:@[[NSURLQueryItem queryItemWithName:@"includeHttps" value:@"1"],
            [NSURLQueryItem queryItemWithName:@"includeRelay" value:@"1"]] completion:^(id resources, NSError *error) {
            NSArray *rows = error ? @[] : serverChoices(resources, accountToken, settings[@"homeOwnerToken"] ?: accountToken);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(panelRows(rows.count ? rows : @[row(error ? RPText(@"Bağlantı kurulamadı") : RPText(@"İçerik bulunamadı"), nil)], nil)); });
        }];
        return;
    }
    if ([kind isEqual:@"filters"]) {
        NSMutableArray *options = [NSMutableArray array];
        NSString *catalog = selectedRoute[@"catalogPath"] ?: path;
        NSString *title = selectedRoute[@"catalogTitle"] ?: @"";
        NSDictionary *parameters = selectedRoute[@"parameters"] ?: @{};
        for (NSArray *field in @[@[RPText(@"Tür"), @"genre"], @[RPText(@"Yıl"), @"year"], @[RPText(@"İzleme durumu"), @"unwatched"]]) {
            [options addObject:row(parameters[field[1]] ? [@"✓ " stringByAppendingString:field[0]] : field[0], @{@"title":field[0], @"kind":@"filterValues", @"filterKey":field[1],
                @"path":[[catalog stringByDeletingLastPathComponent] stringByAppendingPathComponent:field[1]],
                @"catalogPath":catalog, @"catalogTitle":title, @"parameters":parameters, @"filterState":selectedRoute[@"filterState"]})];
        }
        [options addObject:@{@"title":RPText(@"Filtreleri temizle"), @"action":@"clearFilters", @"filterKey":@"*", @"filterValue":@"", @"filterState":selectedRoute[@"filterState"]}];
        completion(panelRows(options, @{@"filterGrid":@YES})); return;
    }
    if ([kind isEqual:@"filterValues"] && [selectedRoute[@"filterKey"] isEqual:@"unwatched"]) {
        NSMutableArray *options = [NSMutableArray array];
        [options addObject:filterChoice(RPText(@"Tümü"), @"unwatched", @"", selectedRoute)];
        NSArray *states = @[@[RPText(@"İzlenmedi"), @"1"], @[RPText(@"İzlendi"), @"0"]];
        NSString *selected = selectedRoute[@"parameters"][@"unwatched"];
        for (NSArray *state in states) if ([selected isEqual:state[1]]) [options addObject:filterChoice(state[0], @"unwatched", state[1], selectedRoute)];
        for (NSArray *state in states) if (![selected isEqual:state[1]]) [options addObject:filterChoice(state[0], @"unwatched", state[1], selectedRoute)];
        completion(panelRows(refreshFilterChoices(options), @{@"filterGrid":@YES})); return;
    }
    if ([kind isEqual:@"sort"]) {
        NSMutableArray *options = [NSMutableArray array];
        for (NSArray *sort in @[@[RPText(@"Ada göre A–Z"), @"titleSort:asc"], @[RPText(@"Ada göre Z–A"), @"titleSort:desc"],
            @[RPText(@"Yeni eklenenler"), @"addedAt:desc"], @[RPText(@"Yıla göre"), @"year:desc"]]) {
            [options addObject:@{@"title":[(selectedRoute[@"parameters"][@"sort"] ?: @"titleSort:asc") isEqual:sort[1]] ? [@"✓ " stringByAppendingString:sort[0]] : sort[0],
                @"action":@"setSort", @"value":sort[1], @"filterState":selectedRoute[@"filterState"]}];
        }
        completion(panelRows(options, nil)); return;
    }
    if ([kind isEqual:@"explore"]) {
        completion(exploreRows());
        return;
    }
    if ([kind isEqual:@"search"] || [kind isEqual:@"discoverSearch"]) {
        completion(revivePlexSearchKeyboard(nil, 0, nil));
        return;
    }
    if ([kind isEqual:@"settings"]) {
        NSMutableArray *rows = [NSMutableArray arrayWithObject:
            row(RPText(@"Sunucu durumu"), route(RPText(@"Sunucu durumu"), @"status", @"/identity"))];
        [rows addObject:row(RPText(@"Sunucu seç"), route(RPText(@"Sunucu seç"), @"servers", @""))];
        [rows addObject:row(RPText(@"Plex Home kullanıcıları"), route(RPText(@"Plex Home kullanıcıları"), @"homeUsers", @""))];
        [rows addObject:row(RPText(@"Çalma listeleri"), route(RPText(@"Çalma listeleri"), @"media", @"/playlists"))];
        [rows addObject:row(RPText(@"Sonraki içeriği otomatik oynat"), route(RPText(@"Sonraki içeriği otomatik oynat"), @"autoplay", @""))];
        [rows addObject:row(RPText(@"Giriş ve jenerik atlama"), route(RPText(@"Giriş ve jenerik atlama"), @"skipMarkers", @""))];
        [rows addObject:row(RPText(@"Video kalitesi"), route(RPText(@"Video kalitesi"), @"quality", @""))];
        [rows addObject:row(RPText(@"Uygulama dili"), route(RPText(@"Uygulama dili"), @"language", @""))];
        [rows addObject:row(RPText(@"Hakkında"), route(RPText(@"Hakkında"), @"about", @""))];
        if (token.length)
            [rows addObject:row(RPText(@"Oturumu kapat"), route(RPText(@"Oturumu kapat"), @"logout", @""))];
        else
            [rows addObject:row(RPText(@"Plex hesabını bağla"), route(RPText(@"Plex etkinleştirme"), @"link", @""))];
        completion(panelRows(rows, @{@"filterGrid":@YES, @"gridColumns":@2}));
        return;
    }
    if ([kind isEqual:@"subtitleLanguages"]) {
        NSMutableArray *languages = [NSMutableArray array];
        for (NSArray *language in @[@[@"tr", @"Türkçe"], @[@"en", @"English"], @[@"sv", @"Svenska"], @[@"de", @"Deutsch"], @[@"fr", @"Français"], @[@"es", @"Español"], @[@"it", @"Italiano"]])
            [languages addObject:row(language[1], @{@"title":language[1], @"kind":@"subtitleSearch", @"path":[path stringByAppendingString:@"/subtitles"], @"language":language[0]})];
        completion(panelRows(languages, nil)); return;
    }
    if ([kind isEqual:@"language"]) {
        NSString *current = [[NSUserDefaults standardUserDefaults] stringForKey:@"RevivePlexLanguage"] ?: @"system";
        NSMutableArray *options = [NSMutableArray array];
        for (NSArray *language in @[@[@"system", RPText(@"Sistem dili")], @[@"en", @"English"], @[@"tr", @"Türkçe"], @[@"sv", @"Svenska"], @[@"es", @"Español"]]) {
            NSString *label = [current isEqual:language[0]] ? [@"✓ " stringByAppendingString:language[1]] : language[1];
            [options addObject:@{@"title":label, @"action":@"setLanguage", @"value":language[0]}];
        }
        completion(panelRows(options, nil));
        return;
    }
    if ([kind isEqual:@"autoplay"]) {
        BOOL enabled = ![[[NSUserDefaults standardUserDefaults] objectForKey:@"RevivePlexAutoplay"] isEqual:@NO];
        completion(panelRows(@[
            @{@"title":enabled ? [@"✓ " stringByAppendingString:RPText(@"Açık")] : RPText(@"Açık"), @"action":@"setAutoplay", @"value":@YES},
            @{@"title":!enabled ? [@"✓ " stringByAppendingString:RPText(@"Kapalı")] : RPText(@"Kapalı"), @"action":@"setAutoplay", @"value":@NO}], nil));
        return;
    }
    if ([kind isEqual:@"skipMarkers"]) {
        NSMutableArray *options = [NSMutableArray array];
        for (NSArray *field in @[@[RPText(@"Girişi otomatik atla"), @"RevivePlexSkipIntro"], @[RPText(@"Jeneriği otomatik atla"), @"RevivePlexSkipCredits"]]) {
            BOOL enabled = [[NSUserDefaults standardUserDefaults] boolForKey:field[1]];
            [options addObject:@{@"title":field[0], @"status":enabled ? RPText(@"Açık") : RPText(@"Kapalı"),
                @"action":@"setSkipMarker", @"preference":field[1], @"value":@(!enabled)}];
        }
        completion(panelRows(options, @{@"summary":RPText(@"Sunucunun sağladığı giriş ve jenerik işaretlerini kullanır.")})); return;
    }
    if ([kind isEqual:@"quality"]) {
        NSString *current = [[NSUserDefaults standardUserDefaults] stringForKey:@"RevivePlexVideoQuality"] ?: @"720";
        NSMutableArray *options = [NSMutableArray array];
        for (NSArray *quality in @[@[@"1080", @"1080p · 8 Mbps"], @[@"720", @"720p · 3,5 Mbps"], @[@"480", @"480p · 1,5 Mbps"]]) {
            NSString *label = [current isEqual:quality[0]] ? [@"✓ " stringByAppendingString:quality[1]] : quality[1];
            [options addObject:@{@"title":label, @"action":@"setQuality", @"value":quality[0]}];
        }
        BOOL preserve = ![[[NSUserDefaults standardUserDefaults] objectForKey:@"RevivePlexPreserveVideo"] isEqual:@NO];
        [options addObject:@{@"title":RPText(@"Uygunsa özgün videoyu koru"), @"status":preserve ? RPText(@"Açık") : RPText(@"Kapalı"), @"action":@"setPreserveVideo", @"value":@(!preserve)}];
        completion(panelRows(options, @{@"summary":RPText(@"Seçilen kalite üst sınırdır. Uyumlu ve sınırın altındaki video özgün çözünürlüğünü korur; gerektiğinde ses veya video dönüştürülür.")}));
        return;
    }
    if ([kind isEqual:@"logout"]) {
        completion(panelRows(@[@{@"title": RPText(@"Oturumu kapat ve onayla"), @"action": @"signOut"}],
            @{@"summary":RPText(@"Yalnızca bu Apple TV’deki oturum kapanır.")}));
        return;
    }
    if ([kind isEqual:@"incompatible"]) {
        completion(panelRows(@[row(RPText(@"Bu içerik oynatılamıyor"), nil)],
            @{@"summary":RPText(@"Plex bu içerik için oynatılabilir dosya bildirmedi.")}));
        return;
    }
    PlexClient *client = [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:origin]
        token:token clientID:@"RevivePlex-AppleTV3"];
    if (!client) {
        completion(@[row(RPText(@"Plex yapılandırması geçersiz"), nil)]);
        return;
    }
    NSMutableArray *query = [NSMutableArray array];
    NSDictionary *parameters = selectedRoute[@"parameters"];
    for (NSString *key in @[@"sort", @"genre", @"year", @"unwatched", @"actor"])
        if (![kind isEqual:@"filterValues"] && [parameters[key] isKindOfClass:[NSString class]]) [query addObject:[NSURLQueryItem queryItemWithName:key value:parameters[key]]];
    if ([kind isEqual:@"cast"]) {
        [client fetchPath:path query:nil completion:^(NSDictionary *metadata, NSError *error) {
            NSDictionary *item = [metadata[@"items"] firstObject];
            NSString *parent = [item[@"type"] isEqual:@"season"] ? numberKey(item[@"parentRatingKey"]) :
                [item[@"type"] isEqual:@"episode"] ? numberKey(item[@"grandparentRatingKey"]) : nil;
            // Seasons commonly omit Role entirely; use their show's cast. Episode
            // guest cast remains authoritative when supplied by the server.
            if (!error && ![item[@"Role"] count] && parent && ![parent isEqual:[path lastPathComponent]]) {
                [client fetchPath:[@"/library/metadata/" stringByAppendingString:parent] query:nil
                    completion:^(NSDictionary *show, NSError *showError) {
                    NSArray *rows = showError ? panelRows(@[row(RPText(@"Bağlantı kurulamadı"), nil)], nil) : castRows([show[@"items"] firstObject]);
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(rows); });
                }];
            } else {
                NSArray *rows = error ? panelRows(@[row(RPText(@"Bağlantı kurulamadı"), nil)], nil) : castRows(item);
                dispatch_async(dispatch_get_main_queue(), ^{ completion(rows); });
            }
        }];
        return;
    }
    if ([kind isEqual:@"series"]) {
        [client fetchPath:path query:nil completion:^(NSDictionary *metadata, NSError *metadataError) {
            if (metadataError) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(panelRows(@[row(RPText(@"Bağlantı kurulamadı"), nil)], nil)); });
                return;
            }
            NSDictionary *item = [metadata[@"items"] firstObject];
            [client fetchCatalogPath:[path stringByAppendingString:@"/children"] query:nil
                completion:^(NSDictionary *children, NSError *childrenError) {
                NSArray *rows = mediaRows(children[@"items"], @"media");
                if ([item[@"type"] isEqual:@"season"]) {
                    NSMutableDictionary *episodes = [NSMutableDictionary dictionary];
                    for (NSDictionary *episode in children[@"items"]) if (numberKey(episode[@"ratingKey"])) episodes[episode[@"ratingKey"]] = episode;
                    NSMutableArray *episodeRows = [NSMutableArray array];
                    for (NSDictionary *entry in rows) {
                        NSMutableDictionary *card = [entry mutableCopy];
                        NSDictionary *episode = episodes[[entry[@"route"][@"path"] lastPathComponent]];
                        if ([episode[@"title"] length]) {
                            card[@"cardTitle"] = episode[@"title"]; card[@"title"] = episode[@"title"];
                            card[@"catalogCaption"] = [NSString stringWithFormat:RPText(@"S%d B%d"), [episode[@"parentIndex"] intValue], [episode[@"index"] intValue]];
                        }
                        [episodeRows addObject:card];
                    }
                    rows = episodeRows;
                }
                if (!childrenError && rows.count && rows[0][@"shelf"]) {
                    NSMutableArray *heroRows = [rows mutableCopy];
                    NSMutableDictionary *first = [rows[0] mutableCopy];
                    first[@"hero"] = item ?: @{};
                    heroRows[0] = first;
                    rows = heroRows;
                } else rows = panelRows(@[row(childrenError ? RPText(@"Bağlantı kurulamadı") : RPText(@"İçerik bulunamadı"), nil)], nil);
                if (!childrenError && rows.count && rows[0][@"shelf"] &&
                    [@[@"show", @"season"] containsObject:item[@"type"] ?: @""]) {
                    NSArray *content = rows;
                    void (^withEpisodes)(NSDictionary *, NSError *) = ^(NSDictionary *leaves, NSError *leafError) {
                        NSDictionary *candidate = revivePlexResumeEpisode(leaves[@"items"]);
                        NSArray *resultRows = content;
                        if (!leafError && candidate) {
                            NSString *playPath = [@"/library/metadata/" stringByAppendingString:candidate[@"ratingKey"]];
                            double offset = MAX(0, [candidate[@"viewOffset"] doubleValue] / 1000.0 - 2.0);
                            NSMutableArray *actions = [NSMutableArray arrayWithArray:@[
                                row(offset > 0 ? RPText(@"İzlemeye devam et") : RPText(@"Oynat"), @{@"title":RPText(@"Oynatıcı"), @"kind":@"transcode", @"path":playPath, @"resume":@(offset)}),
                                row(RPText(@"Oyuncular ve ekip"), route(RPText(@"Oyuncular ve ekip"), @"cast", path)),
                                row(RPText(@"Açıklamanın tamamı"), route(item[@"title"] ?: @"", @"description", path))]];
                            for (NSUInteger index = 0; index < actions.count; index++) {
                                NSMutableDictionary *action = [actions[index] mutableCopy]; action[@"shelf"] = @YES; actions[index] = action;
                            }
                            NSMutableDictionary *first = [actions[0] mutableCopy];
                            first[@"toolbarCount"] = @3;
                    first[@"hero"] = item;
                            first[@"mediaType"] = content[0][@"mediaType"] ?: @"season";
                            actions[0] = first; [actions addObjectsFromArray:content]; resultRows = actions;
                        }
                        dispatch_async(dispatch_get_main_queue(), ^{ completion(resultRows); });
                    };
                    if ([item[@"type"] isEqual:@"season"]) withEpisodes(children, nil);
                    else [client fetchCatalogPath:[path stringByAppendingString:@"/allLeaves"] query:nil completion:withEpisodes];
                } else dispatch_async(dispatch_get_main_queue(), ^{ completion(rows); });
            }];
        }];
        return;
    }
    if ([kind isEqual:@"detail"] || [kind isEqual:@"extras"])
        [query addObject:[NSURLQueryItem queryItemWithName:@"includeExtras" value:@"1"]];
    if ([kind isEqual:@"detail"] || [kind isEqual:@"chapters"])
        [query addObject:[NSURLQueryItem queryItemWithName:@"includeChapters" value:@"1"]];
    if ([kind isEqual:@"subtitleSearch"]) {
        [query addObject:[NSURLQueryItem queryItemWithName:@"language" value:selectedRoute[@"language"] ?: @"en"]];
        [query addObject:[NSURLQueryItem queryItemWithName:@"hearingImpaired" value:@"0"]];
        [query addObject:[NSURLQueryItem queryItemWithName:@"forced" value:@"0"]];
    } else if ([kind isEqual:@"searchResults"]) {
        [query addObject:[NSURLQueryItem queryItemWithName:@"title" value:selectedRoute[@"query"]]];
    } else if (![kind isEqual:@"status"] && ![kind isEqual:@"detail"] && ![kind isEqual:@"streams"]) {
        [query addObject:[NSURLQueryItem queryItemWithName:@"X-Plex-Container-Start" value:@"0"]];
        [query addObject:[NSURLQueryItem queryItemWithName:@"X-Plex-Container-Size" value:@"40"]];
    }
    if ([kind hasPrefix:@"recent"])
        [query addObject:[NSURLQueryItem queryItemWithName:@"type" value:[kind isEqual:@"recentMovie"] ? @"1" : @"4"]];
    void (^loaded)(NSDictionary *, NSError *) = ^(NSDictionary *result, NSError *error) {
        NSArray *rows;
        if (error) {
            NSString *message = error.code == 401 || error.code == 403 ?
                RPText(@"Plex kimlik doğrulaması gerekli") : RPText(@"Plex bağlantısı kurulamadı");
            if (error.code == 401 || error.code == 403)
                rows = [kind isEqual:@"searchResults"] ? @[row(message, nil)] :
                    panelRows(@[row(RPText(@"Plex hesabını bağla"), route(RPText(@"Plex etkinleştirme"), @"link", @""))],
                        @{@"summary":message});
            else
                rows = @[row(message, nil)];
        } else if ([kind isEqual:@"status"]) {
            rows = @[row(RPText(@"Plex sunucusu yanıt verdi"), nil)];
        } else if ([kind isEqual:@"searchResults"]) {
            NSMutableArray *matches = [NSMutableArray array];
            NSMutableSet *seen = [NSMutableSet set];
            for (NSDictionary *entry in result[@"items"]) {
                NSString *key = entry[@"ratingKey"];
                if (key.length && ![seen containsObject:key] &&
                    [@[@"movie", @"show", @"artist", @"album", @"track", @"photo", @"photoalbum"] containsObject:entry[@"type"] ?: @""]) {
                    [seen addObject:key]; [matches addObject:entry];
                }
            }
            rows = mediaRows(matches, @"media");
        } else if ([kind isEqual:@"subtitleSearch"]) {
            NSMutableArray *options = [NSMutableArray array];
            for (NSDictionary *stream in result[@"items"]) {
                NSString *key = stream[@"key"];
                if (![key hasPrefix:@"/library/streams/"] || !numberKey(key.lastPathComponent)) continue;
                NSString *title = stream[@"title"] ?: stream[@"displayTitle"] ?: stream[@"language"];
                if (!title.length) continue;
                [options addObject:@{@"title":title, @"action":@"downloadSubtitle", @"subtitlePath":path, @"subtitleKey":key}];
            }
            rows = panelRows(options.count ? options : @[row(RPText(@"Sonuç bulunamadı"), nil)],
                @{@"summary":RPText(@"Altyazıyı seçerek Plex sunucusuna indir. Ardından altyazı listesinden etkinleştir.")});
        } else if ([kind isEqual:@"versions"]) {
            NSMutableArray *versions = [NSMutableArray array];
            NSDictionary *item = [result[@"items"] firstObject];
            for (NSDictionary *media in item[@"Media"]) {
                NSString *label = [NSString stringWithFormat:@"%@ · %@ · %@", media[@"videoResolution"] ?: @"", [media[@"videoCodec"] uppercaseString] ?: @"", [media[@"audioCodec"] uppercaseString] ?: @""];
                NSMutableDictionary *next = [@{@"title":item[@"title"] ?: @"Plex", @"kind":@"transcode", @"path":path, @"mediaIndex":media[@"mediaIndex"] ?: @0} mutableCopy];
                if (selectedRoute[@"queueSnapshot"]) next[@"queueSnapshot"] = selectedRoute[@"queueSnapshot"];
                if (selectedRoute[@"resume"]) next[@"resume"] = selectedRoute[@"resume"];
                if (selectedRoute[@"diagnostic"]) next[@"diagnostic"] = selectedRoute[@"diagnostic"];
                [versions addObject:row(label, next)];
            }
            rows = panelRows(versions.count ? versions : @[row(RPText(@"İçerik bulunamadı"), nil)], nil);
        } else if ([kind isEqual:@"streams"]) {
            NSMutableArray *options = [NSMutableArray array];
            int type = [selectedRoute[@"streamType"] intValue];
            long index = selectedRoute[@"mediaIndex"] ? [selectedRoute[@"mediaIndex"] longValue] : revivePlexPreferredMediaIndex(result[@"parts"], [[NSUserDefaults standardUserDefaults] stringForKey:@"RevivePlexVideoQuality"]);
            NSDictionary *part = nil;
            for (NSDictionary *candidate in result[@"parts"]) if ([candidate[@"media"][@"mediaIndex"] longValue] == index) { part = candidate; break; }
            NSString *partID = numberKey(part[@"part"][@"id"]);
            if (partID && type == 3)
                [options addObject:@{@"title":RPText(@"Kapalı"), @"action":@"setStream", @"partID":partID,
                    @"streamID":@"0", @"streamType":@3}];
            for (NSDictionary *stream in part[@"streams"]) {
                NSString *streamID = numberKey(stream[@"id"]);
                if (!partID || !streamID || [stream[@"streamType"] intValue] != type) continue;
                NSString *label = stream[@"displayTitle"] ?: stream[@"title"] ?: stream[@"language"] ?: stream[@"codec"] ?: RPText(@"Parça");
                if ([stream[@"selected"] boolValue]) label = [@"✓ " stringByAppendingString:label];
                [options addObject:@{@"title":label, @"action":@"setStream", @"partID":partID,
                    @"streamID":streamID, @"streamType":@(type)}];
            }
            if (type == 3) [options addObject:row(RPText(@"Altyazı ara"), route(RPText(@"Altyazı dili"), @"subtitleLanguages", path))];
            rows = panelRows(options.count ? options : @[row(RPText(@"Kullanılabilir parça yok"), nil)], nil);
        } else if ([kind isEqual:@"filterValues"]) {
            NSMutableArray *options = [NSMutableArray array];
            NSString *field = selectedRoute[@"filterKey"] ?: @"genre";
            [options addObject:filterChoice(RPText(@"Tümü"), field, @"", selectedRoute)];
            NSMutableArray *ordered = [NSMutableArray array], *remaining = [NSMutableArray array];
            for (NSDictionary *value in result[@"items"]) {
                if ([selectedRoute[@"parameters"][field] isEqual:value[@"key"]]) [ordered addObject:value];
                else [remaining addObject:value];
            }
            [ordered addObjectsFromArray:remaining];
            for (NSDictionary *value in ordered) {
                if (![value[@"title"] length] || ![value[@"key"] length]) continue;
                [options addObject:filterChoice(value[@"title"], field, value[@"key"], selectedRoute)];
            }
            rows = panelRows(refreshFilterChoices(options), @{@"filterGrid":@YES});
        } else if ([kind isEqual:@"photo"]) {
            NSDictionary *photo = [result[@"items"] firstObject];
            NSString *thumb = [result[@"parts"] firstObject][@"part"][@"key"] ?: photo[@"thumb"];
            rows = panelRows(@[row(photo[@"title"] ?: @"", nil)],
                @{@"photo":thumb ?: @"", @"title":photo[@"title"] ?: @"", @"gallery":@([selectedRoute[@"gallery"] count] > 1)});
        } else if ([kind isEqual:@"chapters"]) {
            NSMutableArray *chapters = [NSMutableArray array];
            NSUInteger index = 0;
            for (NSDictionary *chapter in [result[@"items"] firstObject][@"Chapter"]) {
                double start = [chapter[@"startTimeOffset"] doubleValue] / 1000.0;
                if (!isfinite(start) || start < 0) continue;
                NSString *title = [chapter[@"title"] length] ? chapter[@"title"] : [NSString stringWithFormat:@"%@ %lu", RPText(@"Sahne"), (unsigned long)++index];
                NSMutableDictionary *entry = [row(title, @{@"title":RPText(@"Oynatıcı"), @"kind":@"transcode", @"path":path, @"resume":@(start)}) mutableCopy];
                entry[@"shelf"] = @YES; entry[@"mediaType"] = @"clip";
                int seconds = (int)MIN(start, 2147483.0);
                entry[@"catalogCaption"] = [NSString stringWithFormat:@"%d:%02d", seconds / 60, seconds % 60];
                if ([chapter[@"thumb"] hasPrefix:@"/library/"]) entry[@"artwork"] = chapter[@"thumb"];
                [chapters addObject:entry];
            }
            rows = chapters.count ? chapters : panelRows(@[row(RPText(@"İçerik bulunamadı"), nil)], nil);
        } else if ([kind isEqual:@"extras"]) {
            rows = mediaRows([result[@"items"] firstObject][@"Extras"], @"media");
        } else if ([kind isEqual:@"description"]) {
            NSDictionary *item = [result[@"items"] firstObject];
            rows = panelRows(@[row(item[@"title"] ?: @"", nil)], @{@"longText":item[@"summary"] ?: @"", @"title":item[@"title"] ?: @""});

        } else if ([kind isEqual:@"detail"]) {
            rows = detailRows([result[@"items"] firstObject], result[@"parts"]);
            if (selectedRoute[@"playlistID"]) {
                NSMutableArray *contextRows = [NSMutableArray array];
                for (NSDictionary *entry in rows) {
                    NSMutableDictionary *copy = [entry mutableCopy];
                    if ([entry[@"route"][@"kind"] isEqual:@"transcode"]) {
                        NSMutableDictionary *play = [entry[@"route"] mutableCopy];
                        play[@"playlistID"] = selectedRoute[@"playlistID"]; play[@"queueType"] = selectedRoute[@"queueType"] ?: @"video";
                        copy[@"route"] = play;
                    }
                    [contextRows addObject:copy];
                }
                rows = contextRows;
            }
        } else {
            rows = mediaRows(result[@"items"], kind);
            if ([path isEqual:@"/hubs/home/continueWatching"]) {
                NSMutableArray *continuing = [NSMutableArray array];
                for (NSDictionary *entry in rows) {
                    NSMutableDictionary *card = [entry mutableCopy];
                    card[@"landscapeArtwork"] = @YES;
                    [continuing addObject:card];
                }
                rows = continuing;
            }
            if ([kind isEqual:@"media"] && [path hasPrefix:@"/playlists/"] && [path hasSuffix:@"/items"] && rows[0][@"shelf"] && ![rows[0][@"mediaType"] isEqual:@"photo"]) {
                NSMutableArray *options = [NSMutableArray array];
                NSDictionary *firstItem = [result[@"items"] firstObject];
                NSString *firstPath = [@"/library/metadata/" stringByAppendingString:firstItem[@"ratingKey"]];
                NSString *playlistID = path.pathComponents[2];
                for (NSArray *mode in @[@[RPText(@"Tümünü oynat"), @NO, @NO], @[RPText(@"Karıştır"), @YES, @NO], @[RPText(@"Listeyi tekrarla"), @NO, @YES]]) {
                    NSMutableDictionary *button = [row(mode[0], @{@"title":RPText(@"Oynatıcı"), @"kind":@"transcode", @"path":firstPath,
                        @"playlistID":playlistID, @"queueType":[firstItem[@"type"] isEqual:@"track"] ? @"audio" : @"video",
                        @"shuffle":mode[1], @"repeat":mode[2]}) mutableCopy];
                    button[@"shelf"] = @YES; [options addObject:button];
                }
                NSMutableDictionary *rename = [row(RPText(@"Listeyi düzenle"), @{@"title":RPText(@"Listeyi düzenle"), @"kind":@"playlistManage", @"path":[@"/playlists/" stringByAppendingString:playlistID], @"playlistID":playlistID}) mutableCopy];
                rename[@"shelf"] = @YES; [options addObject:rename];
                NSMutableDictionary *first = [options[0] mutableCopy]; first[@"toolbarCount"] = @4;
                first[@"mediaType"] = firstItem[@"type"];
                if ([result[@"attributes"][@"title"] isKindOfClass:[NSString class]]) first[@"displayTitle"] = result[@"attributes"][@"title"];
                options[0] = first;
                for (NSDictionary *entry in rows) {
                    NSMutableDictionary *copy = [entry mutableCopy], *next = [entry[@"route"] mutableCopy];
                    next[@"playlistID"] = playlistID; next[@"queueType"] = [firstItem[@"type"] isEqual:@"track"] ? @"audio" : @"video";
                    copy[@"route"] = next; [options addObject:copy];
                }
                rows = options;
            } else if ([kind isEqual:@"media"] && [path hasPrefix:@"/playlists/"] && [path hasSuffix:@"/items"] && numberKey(path.pathComponents[2])) {
                NSString *playlistID = path.pathComponents[2];
                NSMutableDictionary *manage = [row(RPText(@"Listeyi düzenle"), @{@"title":RPText(@"Listeyi düzenle"), @"kind":@"playlistManage", @"path":[@"/playlists/" stringByAppendingString:playlistID], @"playlistID":playlistID}) mutableCopy];
                if ([rows firstObject][@"shelf"]) {
                    manage[@"shelf"] = @YES; manage[@"toolbarCount"] = @1; manage[@"mediaType"] = rows[0][@"mediaType"];
                    NSMutableArray *withManage = [NSMutableArray arrayWithObject:manage]; [withManage addObjectsFromArray:rows]; rows = withManage;
                } else rows = panelRows(@[manage], @{@"summary":RPText(@"Bu liste boş. İçerik ayrıntısından yeni öğeler ekleyebilirsin.")});
            } else if ([kind isEqual:@"media"]) {
                rows = catalogRows(rows, selectedRoute);
                if (![rows firstObject][@"shelf"] && [selectedRoute[@"parameters"] count]) {
                    NSMutableDictionary *filters = [selectedRoute mutableCopy];
                    filters[@"kind"] = @"filters"; filters[@"catalogPath"] = path;
                    filters[@"catalogTitle"] = selectedRoute[@"title"] ?: @"";
                    rows = panelRows(@[row(RPText(@"Filtrele"), filters)], @{@"summary":RPText(@"Sonuç bulunamadı")});
                }
            }
        }
        if ([rows count] && !rows[0][@"shelf"] && ![kind isEqual:@"searchResults"]) {
            NSString *message = [rows[0][@"route"] count] ? nil : rows[0][@"title"];
            rows = panelRows(rows, message ? @{@"summary":message} : nil);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(rows); });
    };
    if ([kind isEqual:@"media"] || [kind isEqual:@"searchResults"] || [kind isEqual:@"filterValues"]) [client fetchCatalogPath:path query:query completion:loaded];
    else [client fetchPath:path query:query completion:loaded];
}

id revivePlexMediaRequest(id path)
{
    if (![path hasPrefix:@"/library/parts/"]) return nil;
    NSDictionary *settings = localSettings();
    NSString *origin = settings[@"origin"];
    NSString *token = settings[@"token"];
    if (![origin isKindOfClass:[NSString class]] || ![token isKindOfClass:[NSString class]]) return nil;
    PlexClient *client = [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:origin]
        token:token clientID:@"RevivePlex-AppleTV3"];
    return [client requestForPath:path query:nil];
}

static PlexClient *transcodeClient(void)
{
#ifdef REVIVEPLEX_TEST
    NSString *testOrigin = NSProcessInfo.processInfo.environment[@"REVIVEPLEX_TEST_ORIGIN"];
    if (testOrigin.length) return [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:testOrigin] token:nil clientID:@"test"];
#endif
    NSDictionary *settings = localSettings();
    NSString *origin = settings[@"origin"];
    NSString *token = settings[@"token"];
    if (![origin isKindOfClass:[NSString class]] || ![token isKindOfClass:[NSString class]] || !token.length)
        return nil;
    return [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:origin] token:token clientID:@"RevivePlex-AppleTV3"];
}

static NSMutableDictionary *playbackPaths;
static NSMutableDictionary *playbackMarkers;
static NSMutableDictionary *playbackMetadata;
static NSMutableDictionary *playbackQueues;

id revivePlexPlaybackMetadata(id session) { return playbackMetadata[session]; }

id revivePlexPlaybackOptionsRoute(id session, double position)
{
    NSString *path = playbackPaths[session];
    if (!path || !isfinite(position) || position < 0) return nil;
    if ([playbackMetadata[session][@"live"] boolValue]) {
        NSMutableDictionary *live = [playbackMetadata[session][@"liveRoute"] mutableCopy];
        live[@"kind"] = @"playbackOptions"; live[@"live"] = @YES; return live;
    }
    NSMutableDictionary *route = [@{@"title":RPText(@"Oynatma ayarları"), @"kind":@"playbackOptions", @"path":path,
        @"resume":@(position), @"audio":@([playbackMetadata[session][@"type"] isEqual:@"track"])} mutableCopy];
    route[@"versionCount"] = @([playbackMetadata[session][@"Media"] count]);
    if (playbackMetadata[session][@"mediaIndex"]) route[@"mediaIndex"] = playbackMetadata[session][@"mediaIndex"];
    if ([playbackMetadata[session][@"diagnostic"] boolValue]) route[@"diagnostic"] = @YES;
    if (playbackQueues[session]) route[@"queueSnapshot"] = [playbackQueues[session] copy];
    return route;
}


double revivePlexMarkerTarget(id markers, double position, id enabledTypes)
{
    if (!isfinite(position) || position < 0) return 0;
    for (NSDictionary *marker in markers) {
        if (![enabledTypes containsObject:marker[@"type"] ?: @""]) continue;
        double start = [marker[@"startTimeOffset"] doubleValue] / 1000.0;
        double end = [marker[@"endTimeOffset"] doubleValue] / 1000.0;
        if (isfinite(start) && isfinite(end) && start >= 0 && end > start && position >= start && position < end) return end;
    }
    return 0;
}

id revivePlexPlaybackSkipAction(id session, double position)
{
    for (NSDictionary *marker in playbackMarkers[session]) {
        double target = revivePlexMarkerTarget(@[marker], position, @[@"intro", @"credits"]);
        if (target > 0) return @{@"target":@(target), @"title":[marker[@"type"] isEqual:@"intro"] ? RPText(@"↑ Girişi atla") : RPText(@"↑ Jeneriği atla")};
    }
    return nil;
}

double revivePlexPlaybackSkipTarget(id session, double position)
{
    if ([playbackMetadata[session][@"diagnosticManualMarker"] boolValue]) return 0;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray *types = [NSMutableArray array];
    if ([defaults boolForKey:@"RevivePlexSkipIntro"]) [types addObject:@"intro"];
    if ([defaults boolForKey:@"RevivePlexSkipCredits"]) [types addObject:@"credits"];
    return revivePlexMarkerTarget(playbackMarkers[session], position, types);
}

static void awaitDownloadedSubtitle(PlexClient *client, NSString *path, NSString *key, NSSet *previous, unsigned attempts, void (^completion)(signed char))
{
    [client fetchPath:path query:nil completion:^(NSDictionary *metadata, NSError *error) {
        BOOL ready = NO;
        for (NSDictionary *part in metadata[@"parts"]) for (NSDictionary *stream in part[@"streams"])
            if ([stream[@"streamType"] intValue] == 3 && ([stream[@"key"] isEqual:key] ||
                (numberKey(stream[@"id"]) && ![previous containsObject:stream[@"id"]]))) ready = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ready) { completion(YES); return; }
            if (error || !attempts) { completion(NO); return; }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                awaitDownloadedSubtitle(client, path, key, previous, attempts - 1, completion);
            });
        });
    }];
}

void revivePlexApplyMediaAction(id entry, void (^completion)(signed char))
{
    if ([entry[@"action"] isEqual:@"setHomeUser"]) {
        NSString *userID = numberKey(entry[@"userID"]), *pin = entry[@"pin"];
        if (!userID || (pin && (![pin isKindOfClass:[NSString class]] || pin.length != 4 || !numberKey(pin)))) { completion(NO); return; }
        NSDictionary *settings = localSettings();
        NSString *token = settings[@"homeOwnerToken"] ?: settings[@"accountToken"] ?: settings[@"token"];
        PlexClient *account = [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:@"https://clients.plex.tv"] token:token clientID:@"RevivePlex-AppleTV3"];
        if (!account || !token.length) { completion(NO); return; }
        [account createPath:[NSString stringWithFormat:@"/api/home/users/%@/switch", userID]
            query:pin ? @[[NSURLQueryItem queryItemWithName:@"pin" value:pin]] : nil completion:^(NSDictionary *result, NSError *error) {
            NSString *nextToken = result[@"attributes"][@"authenticationToken"];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error || ![nextToken isKindOfClass:[NSString class]] || !nextToken.length) { completion(NO); return; }
                discoverPairedServer(nextToken, token, ^(signed char saved) {
                    if (saved) { watchlistKeys = nil; watchlistTitle = nil; }
                    completion(saved);
                });
            });
        }]; return;
    }
    if ([entry[@"action"] isEqual:@"watchlist"]) {
        NSString *key = entry[@"cloudKey"];
        PlexClient *cloud = discoverClient();
        if (!cloud || !cloudKey([@"plex://movie/" stringByAppendingString:key ?: @""])) { completion(NO); return; }
        BOOL remove = [entry[@"remove"] boolValue];
        [cloud updatePath:remove ? @"/actions/removeFromWatchlist" : @"/actions/addToWatchlist"
            query:@[[NSURLQueryItem queryItemWithName:@"ratingKey" value:key]] completion:^(NSData *data, NSError *error) {
            (void)data;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!error) { if (remove) [watchlistKeys removeObject:key]; else [watchlistKeys addObject:key]; }
                completion(!error);
            });
        }]; return;
    }
    if ([entry[@"action"] isEqual:@"setServer"]) {
        selectServer(entry[@"connections"], 0, entry[@"serverToken"], entry[@"accountToken"], entry[@"homeOwnerToken"], completion);
        return;
    }
    if ([entry[@"action"] isEqual:@"setSort"]) {
        NSMutableDictionary *state = entry[@"filterState"];
        NSString *value = entry[@"value"];
        if (![state isKindOfClass:[NSMutableDictionary class]] || ![@[@"titleSort:asc", @"titleSort:desc", @"addedAt:desc", @"year:desc"] containsObject:value ?: @""]) { completion(NO); return; }
        NSMutableDictionary *parameters = [state[@"parameters"] mutableCopy] ?: [NSMutableDictionary dictionary];
        parameters[@"sort"] = value;
        state[@"parameters"] = parameters;
        completion(YES); return;
    }
    if ([entry[@"action"] isEqual:@"setSkipMarker"]) {
        NSString *preference = entry[@"preference"];
        if (![@[@"RevivePlexSkipIntro", @"RevivePlexSkipCredits"] containsObject:preference ?: @""]) { completion(NO); return; }
        [[NSUserDefaults standardUserDefaults] setBool:[entry[@"value"] boolValue] forKey:preference];
        completion([[NSUserDefaults standardUserDefaults] synchronize]); return;
    }
    if ([entry[@"action"] isEqual:@"setAutoplay"]) {
        [[NSUserDefaults standardUserDefaults] setBool:[entry[@"value"] boolValue] forKey:@"RevivePlexAutoplay"];
        completion([[NSUserDefaults standardUserDefaults] synchronize]);
        return;
    }
    if ([entry[@"action"] isEqual:@"setLanguage"]) {
        completion(revivePlexSetLanguage(entry[@"value"]));
        return;
    }
    if ([entry[@"action"] isEqual:@"setPreserveVideo"]) {
        [[NSUserDefaults standardUserDefaults] setBool:[entry[@"value"] boolValue] forKey:@"RevivePlexPreserveVideo"];
        completion([[NSUserDefaults standardUserDefaults] synchronize]); return;
    }
    if ([entry[@"action"] isEqual:@"setQuality"]) {
        NSString *value = entry[@"value"];
        if (![@[@"1080", @"720", @"480"] containsObject:value ?: @""]) { completion(NO); return; }
        [[NSUserDefaults standardUserDefaults] setObject:value forKey:@"RevivePlexVideoQuality"];
        completion([[NSUserDefaults standardUserDefaults] synchronize]);
        return;
    }
    PlexClient *client = transcodeClient();
    if ([entry[@"action"] isEqual:@"createRecording"]) {
        NSDictionary *template = entry[@"template"];
        NSString *section = numberKey(entry[@"sectionID"]), *location = numberKey(entry[@"locationID"]);
        NSString *type = [template isKindOfClass:[NSDictionary class]] ? stringNumber(template[@"type"]) : nil;
        NSString *parameters = template[@"parameters"];
        if (!client || !section || !location || !numberKey(type) || ![parameters isKindOfClass:[NSString class]] || parameters.length > 32768) { completion(NO); return; }
        NSURLComponents *components = [NSURLComponents componentsWithString:[@"https://localhost/?" stringByAppendingString:parameters]];
        NSMutableArray *query = [NSMutableArray array];
        for (NSURLQueryItem *parameter in components.queryItems) {
            NSString *name = parameter.name;
            if (([name hasPrefix:@"hints["] || [name hasPrefix:@"params["] || [name hasPrefix:@"prefs["]) && [name hasSuffix:@"]"] && parameter.value)
                [query addObject:parameter];
        }
        if (!query.count) { completion(NO); return; }
        [query addObject:[NSURLQueryItem queryItemWithName:@"targetLibrarySectionID" value:section]];
        [query addObject:[NSURLQueryItem queryItemWithName:@"targetSectionLocationID" value:location]];
        [query addObject:[NSURLQueryItem queryItemWithName:@"type" value:type]];
        [client createPath:@"/media/subscriptions" query:query completion:^(NSDictionary *result, NSError *error) {
            (void)result; dispatch_async(dispatch_get_main_queue(), ^{ completion(error == nil); });
        }]; return;
    }
    if ([entry[@"action"] isEqual:@"setRecordingPreference"] || [entry[@"action"] isEqual:@"deleteRecordingRule"]) {
        NSString *key = numberKey(entry[@"subscriptionID"]);
        if (!client || !key) { completion(NO); return; }
        NSString *path = [@"/media/subscriptions/" stringByAppendingString:key];
        void (^done)(NSData *, NSError *) = ^(NSData *data, NSError *error) { (void)data; dispatch_async(dispatch_get_main_queue(), ^{ completion(error == nil); }); };
        if ([entry[@"action"] isEqual:@"deleteRecordingRule"]) [client deletePath:path completion:done];
        else {
            NSString *name = entry[@"preference"], *value = entry[@"value"];
            if (![name isKindOfClass:[NSString class]] || !name.length || [name rangeOfCharacterFromSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]].length || ![value isKindOfClass:[NSString class]] || value.length > 128) { completion(NO); return; }
            [client updatePath:path query:@[[NSURLQueryItem queryItemWithName:[NSString stringWithFormat:@"prefs[%@]", name] value:value]] completion:done];
        }
        return;
    }
    if (!client) { completion(NO); return; }
    void (^done)(NSData *, NSError *) = ^(NSData *data, NSError *error) {
        (void)data;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error == nil); });
    };
    if ([@[@"moveQueueItem", @"removeQueueItem"] containsObject:entry[@"action"] ?: @""]) {
        NSString *key = numberKey(entry[@"queueID"]), *item = numberKey(entry[@"queueItemID"]);
        if (!key || !item) { completion(NO); return; }
        NSString *path = [NSString stringWithFormat:@"/playQueues/%@/items/%@", key, item];
        if ([entry[@"action"] isEqual:@"moveQueueItem"]) {
            NSString *after = entry[@"after"];
            if (![after isKindOfClass:[NSString class]] || (after.length && (!numberKey(after) || [after isEqual:item]))) { completion(NO); return; }
            [client updatePath:[path stringByAppendingString:@"/move"] query:after.length ? @[[NSURLQueryItem queryItemWithName:@"after" value:after]] : nil completion:done];
        } else {
            if (!numberKey(entry[@"currentItemID"]) || [item isEqual:entry[@"currentItemID"]]) { completion(NO); return; }
            [client deletePath:path completion:done];
        }
        return;
    }
    if ([@[@"deletePlaylist", @"removePlaylistItem", @"movePlaylistItem"] containsObject:entry[@"action"] ?: @""]) {
        NSString *key = numberKey(entry[@"playlistID"]), *item = numberKey(entry[@"playlistItemID"]);
        BOOL deletingList = [entry[@"action"] isEqual:@"deletePlaylist"];
        if (!key || (!deletingList && !item)) { completion(NO); return; }
        NSString *path = deletingList ? [@"/playlists/" stringByAppendingString:key] : [NSString stringWithFormat:@"/playlists/%@/items/%@", key, item];
        if ([entry[@"action"] isEqual:@"movePlaylistItem"]) {
            NSString *after = entry[@"after"];
            if (![after isKindOfClass:[NSString class]] || (after.length && !numberKey(after))) { completion(NO); return; }
            [client updatePath:[path stringByAppendingString:@"/move"] query:after.length ? @[[NSURLQueryItem queryItemWithName:@"after" value:after]] : nil completion:done];
        } else [client deletePath:path completion:done];
    } else if ([entry[@"action"] isEqual:@"renamePlaylist"]) {
        NSString *key = numberKey(entry[@"playlistID"]);
        NSString *title = [entry[@"playlistTitle"] isKindOfClass:[NSString class]] ? [entry[@"playlistTitle"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
        if (!key || !title.length || title.length > 200) { completion(NO); return; }
        [client updatePath:[@"/playlists/" stringByAppendingString:key] query:@[[NSURLQueryItem queryItemWithName:@"title" value:title]] completion:done];
    } else if ([entry[@"action"] isEqual:@"createPlaylist"] || [entry[@"action"] isEqual:@"addPlaylistItem"]) {
        NSString *ratingKey = numberKey(entry[@"ratingKey"]), *playlistID = numberKey(entry[@"playlistID"]);
        BOOL create = [entry[@"action"] isEqual:@"createPlaylist"];
        NSString *title = [entry[@"playlistTitle"] isKindOfClass:[NSString class]] ? [entry[@"playlistTitle"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
        if (!ratingKey || (!create && !playlistID) || (create && (!title.length || title.length > 200 || ![@[@"audio", @"video", @"photo"] containsObject:entry[@"playlistType"] ?: @""]))) { completion(NO); return; }
        [client fetchPath:@"/identity" query:nil completion:^(NSDictionary *identity, NSError *error) {
            NSString *machine = identity[@"attributes"][@"machineIdentifier"];
            if (error || ![machine isKindOfClass:[NSString class]] || !machine.length || [machine rangeOfCharacterFromSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]].location != NSNotFound) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); }); return;
            }
            NSString *uri = [NSString stringWithFormat:@"server://%@/com.plexapp.plugins.library/library/metadata/%@", machine, ratingKey];
            if (create) [client createPath:@"/playlists" query:@[[NSURLQueryItem queryItemWithName:@"uri" value:uri],
                [NSURLQueryItem queryItemWithName:@"type" value:entry[@"playlistType"]], [NSURLQueryItem queryItemWithName:@"smart" value:@"0"],
                [NSURLQueryItem queryItemWithName:@"title" value:title]] completion:^(NSDictionary *result, NSError *failure) {
                    BOOL success = !failure && numberKey([result[@"items"] firstObject][@"ratingKey"]);
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(success); });
                }];
            else [client updatePath:[NSString stringWithFormat:@"/playlists/%@/items", playlistID]
                query:@[[NSURLQueryItem queryItemWithName:@"uri" value:uri]] completion:done];
        }];
    } else if ([entry[@"action"] isEqual:@"downloadSubtitle"]) {
        NSString *path = entry[@"subtitlePath"], *key = entry[@"subtitleKey"];
        if (![path hasPrefix:@"/library/metadata/"] || ![path hasSuffix:@"/subtitles"] ||
            !numberKey([path stringByDeletingLastPathComponent].lastPathComponent) ||
            ![key hasPrefix:@"/library/streams/"] || !numberKey(key.lastPathComponent)) { completion(NO); return; }
        NSString *metadataPath = [path stringByDeletingLastPathComponent];
        [client fetchPath:metadataPath query:nil completion:^(NSDictionary *metadata, NSError *failure) {
            if (failure) { dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); }); return; }
            NSMutableSet *previous = [NSMutableSet set];
            for (NSDictionary *part in metadata[@"parts"]) for (NSDictionary *stream in part[@"streams"])
                if ([stream[@"streamType"] intValue] == 3 && numberKey(stream[@"id"])) [previous addObject:stream[@"id"]];
            [client updatePath:path query:@[[NSURLQueryItem queryItemWithName:@"key" value:key]] completion:^(NSData *data, NSError *error) {
                (void)data;
                if (error) { dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); }); return; }
                awaitDownloadedSubtitle(client, metadataPath, key, previous, 15, completion);
            }];
        }];
    } else if ([entry[@"action"] isEqual:@"setRating"]) {
        NSString *key = numberKey(entry[@"ratingKey"]);
        double value = [entry[@"value"] doubleValue];
        if (!key || !isfinite(value) || value < 0 || value > 10) { completion(NO); return; }
        [client updatePath:@"/:/rate" query:@[[NSURLQueryItem queryItemWithName:@"identifier" value:@"com.plexapp.plugins.library"],
            [NSURLQueryItem queryItemWithName:@"key" value:key], [NSURLQueryItem queryItemWithName:@"rating" value:[entry[@"value"] stringValue]]] completion:done];
    } else if ([entry[@"action"] isEqual:@"setStream"]) {
        NSString *part = numberKey(entry[@"partID"]), *stream = numberKey(entry[@"streamID"]);
        int type = [entry[@"streamType"] intValue];
        if (!part || !stream || (type != 2 && type != 3)) { completion(NO); return; }
        [client updatePath:[@"/library/parts/" stringByAppendingString:part]
            query:@[[NSURLQueryItem queryItemWithName:type == 2 ? @"audioStreamID" : @"subtitleStreamID" value:stream],
                    [NSURLQueryItem queryItemWithName:@"allParts" value:@"1"]] completion:done];
    } else if ([entry[@"action"] isEqual:@"watched"]) {
        NSString *key = numberKey(entry[@"ratingKey"]);
        if (!key) { completion(NO); return; }
        [client updatePath:[entry[@"watched"] boolValue] ? @"/:/scrobble" : @"/:/unscrobble"
            query:@[[NSURLQueryItem queryItemWithName:@"key" value:key],
                    [NSURLQueryItem queryItemWithName:@"identifier" value:@"com.plexapp.plugins.library"]] completion:done];
    } else completion(NO);
}

id revivePlexFollowingEpisode(id episodes, id currentKey)
{
    NSDictionary *current = nil, *next = nil;
    for (NSDictionary *episode in episodes) if ([episode[@"ratingKey"] isEqual:currentKey]) { current = episode; break; }
    if (!current || ![@[@"episode", @"track"] containsObject:current[@"type"] ?: @""]) return nil;
    NSInteger season = [current[@"parentIndex"] integerValue], number = [current[@"index"] integerValue];
    for (NSDictionary *episode in episodes) {
        if (![episode[@"type"] isEqual:current[@"type"]] || !numberKey(episode[@"ratingKey"])) continue;
        NSInteger candidateSeason = [episode[@"parentIndex"] integerValue], candidateNumber = [episode[@"index"] integerValue];
        if (candidateSeason < season || (candidateSeason == season && candidateNumber <= number)) continue;
        if (!next || candidateSeason < [next[@"parentIndex"] integerValue] ||
            (candidateSeason == [next[@"parentIndex"] integerValue] && candidateNumber < [next[@"index"] integerValue])) next = episode;
    }
    return next ? [NSString stringWithFormat:@"/library/metadata/%@", next[@"ratingKey"]] : nil;
}

void revivePlexContinueQueue(id previousSession, id nextSession)
{
    NSDictionary *queue = playbackQueues[previousSession];
    if (queue) {
        NSMutableDictionary *next = [queue mutableCopy];
        if (numberKey(next[@"nextItemID"])) next[@"itemID"] = next[@"nextItemID"];
        [next removeObjectForKey:@"nextItemID"];
        playbackQueues[nextSession] = next;
    }
}

static void beginCompatibleStream(id path, id session, BOOL audio, PlexClient *client, void (^completion)(id));
static void beginMediaTranscode(id path, id session, BOOL audioProbe, id requestedIndex, void (^completion)(id));

void revivePlexBeginPlaybackRoute(id selectedRoute, id session, void (^completion)(id))
{
#ifdef REVIVEPLEX_SYNC_DIAGNOSTIC
    // Local, explicitly requested control sample. Never part of a release build.
    if ([selectedRoute[@"diagnostic"] boolValue] && [selectedRoute[@"syncControl"] boolValue]) {
        NSString *file = @"/var/mobile/Library/Caches/RevivePlex.sync-control.mp4";
        if (![[NSFileManager defaultManager] fileExistsAtPath:file]) { completion(nil); return; }
        if (!playbackMetadata) playbackMetadata = [NSMutableDictionary dictionary];
        playbackMetadata[session] = [@{@"type":@"movie", @"title":@"Local synchronization control",
            @"diagnostic":@YES, @"localSyncControl":@YES} mutableCopy];
        dispatch_async(dispatch_get_main_queue(), ^{ completion([NSURL fileURLWithPath:file]); });
        return;
    }
#endif
    if ([selectedRoute[@"diagnostic"] boolValue] || [selectedRoute[@"markerProbe"] boolValue]) {
        NSMutableDictionary *clean = [selectedRoute mutableCopy]; [clean removeObjectForKey:@"diagnostic"]; [clean removeObjectForKey:@"markerProbe"];
        revivePlexBeginPlaybackRoute(clean, session, ^(id url) {
            if (playbackMetadata[session]) { NSMutableDictionary *metadata = [playbackMetadata[session] mutableCopy]; metadata[@"diagnostic"] = @YES; playbackMetadata[session] = metadata; }
            if ([selectedRoute[@"markerProbe"] boolValue] && playbackMetadata[session]) {
                playbackMetadata[session][@"diagnosticManualMarker"] = @YES;
                if (!playbackMarkers) playbackMarkers = [NSMutableDictionary dictionary];
                playbackMarkers[session] = @[@{@"type":@"intro", @"startTimeOffset":@0, @"endTimeOffset":@20000}];
            }
            completion(url);
        }); return;
    }
    if (selectedRoute[@"liveDVR"]) {
        NSString *dvrID = numberKey(selectedRoute[@"liveDVR"]), *channel = selectedRoute[@"liveChannel"];
        if (!dvrID || ![channel isKindOfClass:[NSString class]] || !channel.length || channel.length > 128 ||
            [channel rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-_"] invertedSet]].length) { completion(nil); return; }
        PlexClient *client = transcodeClient();
        if (!client) { completion(nil); return; }
        NSString *tune = [NSString stringWithFormat:@"/livetv/dvrs/%@/channels/%@/tune", dvrID, channel];
        if (!playbackPaths) playbackPaths = [NSMutableDictionary dictionary];
        playbackPaths[session] = tune;
        [client createPath:tune query:nil completion:^(NSDictionary *response, NSError *error) {
            NSString *uuid = [response[@"parts"] firstObject][@"media"][@"uuid"];
            NSDictionary *item = [response[@"items"] firstObject];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![playbackPaths[session] isEqual:tune]) { completion(nil); return; }
                if (error || ![uuid isKindOfClass:[NSString class]] || uuid.length != 36 ||
                    [uuid rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF-"] invertedSet]].length || ![item[@"live"] boolValue]) { completion(nil); return; }
                if (!playbackPaths) playbackPaths = [NSMutableDictionary dictionary];
                if (!playbackMetadata) playbackMetadata = [NSMutableDictionary dictionary];
                NSString *livePath = [@"/livetv/sessions/" stringByAppendingString:uuid];
                NSMutableDictionary *metadata = [item mutableCopy];
                metadata[@"title"] = selectedRoute[@"title"] ?: channel;
                metadata[@"liveRoute"] = selectedRoute;
                playbackMetadata[session] = metadata; playbackPaths[session] = livePath;
                beginCompatibleStream(livePath, session, NO, client, completion);
            });
        }]; return;
    }

    if ([selectedRoute[@"audioProbe"] boolValue]) { revivePlexBeginAudioProbe(selectedRoute[@"path"], session, completion); return; }
    NSDictionary *snapshot = selectedRoute[@"queueSnapshot"];
    if ([snapshot isKindOfClass:[NSDictionary class]] && numberKey(snapshot[@"id"]) && numberKey(snapshot[@"itemID"]) && numberKey(snapshot[@"firstID"])) {
        if (!playbackQueues) playbackQueues = [NSMutableDictionary dictionary];
        playbackQueues[session] = [snapshot mutableCopy];
        beginMediaTranscode(selectedRoute[@"path"], session, NO, selectedRoute[@"mediaIndex"], completion); return;
    }
    NSString *playlistID = numberKey(selectedRoute[@"playlistID"]);
    if (!playlistID) { beginMediaTranscode(selectedRoute[@"path"], session, NO, selectedRoute[@"mediaIndex"], completion); return; }
    NSArray *query = @[[NSURLQueryItem queryItemWithName:@"playlistID" value:playlistID],
        [NSURLQueryItem queryItemWithName:@"type" value:[selectedRoute[@"queueType"] isEqual:@"audio"] ? @"audio" : @"video"],
        [NSURLQueryItem queryItemWithName:@"shuffle" value:[selectedRoute[@"shuffle"] boolValue] ? @"1" : @"0"],
        [NSURLQueryItem queryItemWithName:@"repeat" value:[selectedRoute[@"repeat"] boolValue] ? @"1" : @"0"],
        [NSURLQueryItem queryItemWithName:@"key" value:selectedRoute[@"path"]],
        [NSURLQueryItem queryItemWithName:@"includeRelated" value:@"0"]];
    [transcodeClient() createPath:@"/playQueues" query:query completion:^(NSDictionary *result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *queueID = numberKey(result[@"attributes"][@"playQueueID"]);
            NSString *selected = numberKey(result[@"attributes"][@"playQueueSelectedItemID"]);
            NSDictionary *item = nil;
            for (NSDictionary *candidate in result[@"items"]) if ([candidate[@"playQueueItemID"] isEqual:selected]) item = candidate;
            if (!item) item = [result[@"items"] firstObject];
            if (error || !queueID || !numberKey(item[@"ratingKey"]) || !numberKey(item[@"playQueueItemID"])) { completion(nil); return; }
            if (!playbackQueues) playbackQueues = [NSMutableDictionary dictionary];
            playbackQueues[session] = [@{@"id":queueID, @"itemID":item[@"playQueueItemID"], @"firstID":item[@"playQueueItemID"],
                @"repeat":@([selectedRoute[@"repeat"] boolValue])} mutableCopy];
            revivePlexBeginTranscode([@"/library/metadata/" stringByAppendingString:item[@"ratingKey"]], session, completion);
        });
    }];
}

void revivePlexNextEpisode(id session, void (^completion)(id))
{
    NSString *path = playbackPaths[session];
    if ([playbackMetadata[session][@"live"] boolValue]) { completion(nil); return; }
    PlexClient *client = transcodeClient();
    void (^done)(id) = ^(id next) { dispatch_async(dispatch_get_main_queue(), ^{ completion(next); }); };
    NSMutableDictionary *queue = playbackQueues[session];
    if (queue && client) {
        if ([queue[@"repeatOne"] boolValue] && path.length) {
            queue[@"nextItemID"] = queue[@"itemID"];
            done(path); return;
        }
        NSString *queuePath = [@"/playQueues/" stringByAppendingString:queue[@"id"]];
        NSArray *query = @[[NSURLQueryItem queryItemWithName:@"center" value:queue[@"itemID"]],
            [NSURLQueryItem queryItemWithName:@"window" value:@"1"],
            [NSURLQueryItem queryItemWithName:@"includeBefore" value:@"1"],
            [NSURLQueryItem queryItemWithName:@"includeAfter" value:@"1"]];
        [client fetchPath:queuePath query:query completion:^(NSDictionary *result, NSError *error) {
            BOOL found = NO; NSDictionary *next = nil;
            for (NSDictionary *item in result[@"items"]) {
                if (found) { next = item; break; }
                if ([item[@"playQueueItemID"] isEqual:queue[@"itemID"]]) found = YES;
            }
            void (^advance)(NSDictionary *) = ^(NSDictionary *item) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!numberKey(item[@"ratingKey"]) || !numberKey(item[@"playQueueItemID"])) { completion(nil); return; }
                    queue[@"nextItemID"] = item[@"playQueueItemID"];
                    completion([@"/library/metadata/" stringByAppendingString:item[@"ratingKey"]]);
                });
            };
            if (error) { done(nil); return; }
            if (next) { advance(next); return; }
            if (![queue[@"repeat"] boolValue]) { done(nil); return; }
            // The original first item may have been removed or reordered.
            queueWindow(client, queue[@"id"], queue[@"itemID"], YES, [NSMutableArray array], [NSMutableSet set], ^(NSArray *items) {
                advance([items firstObject]);
            });
        }]; return;
    }
    if (!client || !path.length || [[[NSUserDefaults standardUserDefaults] objectForKey:@"RevivePlexAutoplay"] isEqual:@NO]) { done(nil); return; }
    [client fetchPath:path query:nil completion:^(NSDictionary *metadata, NSError *error) {
        NSDictionary *item = [metadata[@"items"] firstObject];
        BOOL music = [item[@"type"] isEqual:@"track"];
        NSString *show = numberKey(item[music ? @"parentRatingKey" : @"grandparentRatingKey"]);
        if (error || (!music && ![item[@"type"] isEqual:@"episode"]) || !show) { done(nil); return; }
        [client fetchCatalogPath:[NSString stringWithFormat:@"/library/metadata/%@/%@", show, music ? @"children" : @"allLeaves"] query:nil
            completion:^(NSDictionary *episodes, NSError *failure) {
            if (failure) { done(nil); return; }
            done(revivePlexFollowingEpisode(episodes[@"items"], item[@"ratingKey"]));
        }];
    }];
}

void revivePlexReportProgress(id session, double position, double duration, id state)
{
    NSString *path = playbackPaths[session];
    if ([playbackMetadata[session][@"diagnostic"] boolValue] || [playbackMetadata[session][@"live"] boolValue]) return;
    if (!path || !isfinite(position) || position < 0 || !isfinite(duration) || duration <= 0) return;
    NSDictionary *values = @{@"ratingKey":path.lastPathComponent, @"key":path,
        @"state":state, @"time":@((int)(MIN(position, 2147483.0) * 1000)).stringValue,
        @"duration":@((int)(MIN(duration, 2147483.0) * 1000)).stringValue};
    NSMutableArray *query = [NSMutableArray array];
    for (NSString *key in values) [query addObject:[NSURLQueryItem queryItemWithName:key value:values[key]]];
    NSDictionary *queue = playbackQueues[session];
    if (numberKey(queue[@"id"]) && numberKey(queue[@"itemID"])) {
        [query addObject:[NSURLQueryItem queryItemWithName:@"playQueueID" value:queue[@"id"]]];
        [query addObject:[NSURLQueryItem queryItemWithName:@"playQueueItemID" value:queue[@"itemID"]]];
        [query addObject:[NSURLQueryItem queryItemWithName:@"containerKey" value:[@"/playQueues/" stringByAppendingString:queue[@"id"]]]];
    }
    [transcodeClient() reportTimeline:query session:session completion:^(NSData *data, NSError *error) {
        (void)data; (void)error;
    }];
}

static void beginCompatibleStream(id path, id session, BOOL audio, PlexClient *client, void (^completion)(id))
{
    NSString *prefix = audio ? @"/audio/:/transcode/universal" : @"/video/:/transcode/universal";
    NSString *start = [prefix stringByAppendingString:@"/start.m3u8"];
    NSString *quality = [[NSUserDefaults standardUserDefaults] stringForKey:@"RevivePlexVideoQuality"];
    NSString *resolution = [quality isEqual:@"1080"] ? @"1920x1080" : ([quality isEqual:@"480"] ? @"854x480" : @"1280x720");
    NSString *bitrate = [quality isEqual:@"1080"] ? @"8000" : ([quality isEqual:@"480"] ? @"1500" : @"3500");
    NSMutableDictionary *parameters = [@{@"path":path, @"session":session, @"protocol":@"hls",
        @"directPlay":@"0", @"directStream":@"0", @"mediaIndex":[NSString stringWithFormat:@"%ld", [playbackMetadata[session][@"mediaIndex"] longValue]], @"partIndex":@"0",
        @"audioChannelCount":@"2", @"advancedSubtitles":@"burn",
        @"X-Plex-Client-Profile-Extra":@"add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264&audioCodec=aac&replace=true)+add-limitation(scope=videoCodec&scopeName=h264&type=upperBound&name=video.level&value=40&isRequired=true)+add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.frameRate&value=30&replace=true)",
        @"videoResolution":resolution, @"maxVideoBitrate":bitrate, @"videoQuality":@"75"} mutableCopy];
    if (!audio && [playbackMetadata[session][@"preserveCompatibleVideo"] boolValue] &&
        ![[[NSUserDefaults standardUserDefaults] objectForKey:@"RevivePlexPreserveVideo"] isEqual:@NO]) {
        parameters[@"directStream"] = @"1";
        syslog(LOG_NOTICE, "RevivePlex: eligible for original-resolution video remux");
    }
    if (audio) {
        parameters[@"X-Plex-Client-Profile-Extra"] = @"add-transcode-target(type=musicProfile&context=streaming&protocol=hls&container=mpegts&audioCodec=aac&replace=true)";
        [parameters removeObjectForKey:@"videoResolution"]; [parameters removeObjectForKey:@"maxVideoBitrate"];
        [parameters removeObjectForKey:@"videoQuality"]; [parameters removeObjectForKey:@"advancedSubtitles"];
    }
    NSMutableArray *query = [NSMutableArray array];
    for (NSString *name in parameters)
        [query addObject:[NSURLQueryItem queryItemWithName:name value:parameters[name]]];

    NSURL *base = [client requestForPath:start query:nil].URL;
    [client fetchDataForPath:start query:query completion:^(NSData *data, NSError *error) {
        NSString *manifest = error ? nil : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSURL *playlist = nil;
        if ([manifest hasPrefix:@"#EXTM3U"]) {
            BOOL hasVariant = NO;
            for (NSString *raw in [manifest componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
                NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if ([line hasPrefix:@"#EXT-X-STREAM-INF:"]) { hasVariant = YES; continue; }
                if (!hasVariant || !line.length || [line hasPrefix:@"#"]) continue;
                NSURL *candidate = [NSURL URLWithString:line relativeToURL:base].absoluteURL;
                if ([candidate.scheme isEqual:@"https"] && [candidate.host isEqual:base.host] &&
                    ((!candidate.port && !base.port) || [candidate.port isEqual:base.port]) &&
                    !candidate.user && !candidate.password && !candidate.query && !candidate.fragment &&
                    [candidate.path hasPrefix:[prefix stringByAppendingString:@"/session/"]] &&
                    [candidate.pathExtension isEqual:@"m3u8"]) playlist = candidate;
                break;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(playlist); });
    }];
}

static void beginMediaTranscode(id path, id session, BOOL audioProbe, id requestedIndex, void (^completion)(id))
{
    PlexClient *client = transcodeClient();
    if (!client || ![path hasPrefix:@"/library/metadata/"] ||
        !numberKey([path lastPathComponent]) || [[path pathComponents] count] != 4) { completion(nil); return; }
    if (!playbackPaths) playbackPaths = [NSMutableDictionary dictionary];
    if (!playbackMarkers) playbackMarkers = [NSMutableDictionary dictionary];
    if (!playbackMetadata) playbackMetadata = [NSMutableDictionary dictionary];
    playbackPaths[session] = path;
    [client fetchPath:path query:@[[NSURLQueryItem queryItemWithName:@"includeMarkers" value:@"1"]] completion:^(NSDictionary *metadata, NSError *error) {
        NSDictionary *item = [metadata[@"items"] firstObject];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !item || ![playbackPaths[session] isEqual:path]) { completion(nil); return; }
            if (audioProbe) {
                NSMutableDictionary *probe = [item mutableCopy];
                probe[@"type"] = @"track"; probe[@"diagnostic"] = @YES; probe[@"title"] = @"Audio compatibility test";
                playbackMetadata[session] = probe;
            } else playbackMetadata[session] = [item mutableCopy];
            long mediaIndex = requestedIndex ? [requestedIndex longValue] : revivePlexPreferredMediaIndex(metadata[@"parts"], [[NSUserDefaults standardUserDefaults] stringForKey:@"RevivePlexVideoQuality"]);
            if (mediaIndex < 0 || (mediaIndex > 0 && (NSUInteger)mediaIndex >= [item[@"Media"] count])) { completion(nil); return; }
            playbackMetadata[session][@"mediaIndex"] = @(mediaIndex);
            for (NSDictionary *part in metadata[@"parts"]) if ([part[@"media"][@"mediaIndex"] longValue] == mediaIndex) {
                playbackMetadata[session][@"preserveCompatibleVideo"] = @(revivePlexCanPreserveVideo(part, [[NSUserDefaults standardUserDefaults] stringForKey:@"RevivePlexVideoQuality"])); break;
            }
            syslog(LOG_NOTICE, "RevivePlex: selected media version=%ld alternatives=%lu", mediaIndex, (unsigned long)[item[@"Media"] count]);
            if (item[@"Marker"]) playbackMarkers[session] = item[@"Marker"];
            beginCompatibleStream(path, session, audioProbe || [item[@"type"] isEqual:@"track"], client, completion);
        });
    }];
}

void revivePlexBeginTranscode(id path, id session, void (^completion)(id))
{
    beginMediaTranscode(path, session, NO, nil, completion);
}
void revivePlexBeginAudioProbe(id path, id session, void (^completion)(id))
{
    beginMediaTranscode(path, session, YES, nil, completion);
}

void revivePlexEndTranscode(id session)
{
    if (!session) return;
    BOOL localControl = [playbackMetadata[session][@"localSyncControl"] boolValue];
    BOOL audio = [playbackMetadata[session][@"type"] isEqual:@"track"];
    [playbackQueues removeObjectForKey:session];
    [playbackPaths removeObjectForKey:session];
    [playbackMarkers removeObjectForKey:session];
    [playbackMetadata removeObjectForKey:session];
    if (localControl) return;
    [transcodeClient() fetchDataForPath:audio ? @"/audio/:/transcode/universal/stop" : @"/video/:/transcode/universal/stop"
        query:@[[NSURLQueryItem queryItemWithName:@"session" value:session]]
        completion:^(NSData *data, NSError *error) { (void)data; (void)error; }];
}

static id imageRequest(id path, BOOL fullSize)
{
    if (![path isKindOfClass:[NSString class]]) return nil;
    NSDictionary *settings = localSettings();
    NSString *origin = settings[@"origin"] ?: defaultOrigin;
    NSString *token = settings[@"token"];
    if (![origin isKindOfClass:[NSString class]] || (token && ![token isKindOfClass:[NSString class]])) return nil;
    PlexClient *client = [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:origin]
        token:token clientID:@"RevivePlex-AppleTV3"];
    NSURLComponents *art = [NSURLComponents componentsWithString:path];
    BOOL local = !art.host && !art.scheme && ([art.path hasPrefix:@"/library/"] || [art.path hasPrefix:@"/playlists/"]);
    BOOL portrait = [art.scheme isEqual:@"https"] && [@[@"metadata-static.plex.tv", @"image.tmdb.org"] containsObject:art.host ?: @""] && !art.port;
    if (!art || art.user || art.password || art.fragment || !(local || portrait) ||
        [art.path.pathComponents containsObject:@".."]) return nil;
    NSArray *query = @[
        [NSURLQueryItem queryItemWithName:@"url" value:path],
        [NSURLQueryItem queryItemWithName:@"width" value:fullSize ? @"1920" : @"560"],
        [NSURLQueryItem queryItemWithName:@"height" value:fullSize ? @"1080" : @"840"],
        [NSURLQueryItem queryItemWithName:@"minSize" value:@"1"],
        [NSURLQueryItem queryItemWithName:@"upscale" value:@"0"]
    ];
    NSMutableURLRequest *request = [[client requestForPath:@"/photo/:/transcode" query:query] mutableCopy];
    [request setValue:@"image/jpeg" forHTTPHeaderField:@"Accept"];
    return request;
}

id revivePlexArtworkRequest(id path) { return imageRequest(path, NO); }
id revivePlexPhotoRequest(id path) { return imageRequest(path, YES); }

signed char revivePlexSignOut(void)
{
    return unlink(settingsPath().fileSystemRepresentation) == 0 || errno == ENOENT;
}

static BOOL saveSession(NSDictionary *session)
{
    NSString *path = settingsPath();
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:session
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    if (!data || data.length > 16384) return NO;
    NSMutableData *name = [NSMutableData dataWithData:
        [[path stringByAppendingString:@".XXXXXX"] dataUsingEncoding:NSUTF8StringEncoding]];
    const char end = 0;
    [name appendBytes:&end length:1];
    char *temporary = name.mutableBytes;
    int fd = mkstemp(temporary);
    if (fd < 0) return NO;
    ssize_t written = write(fd, data.bytes, data.length);
    BOOL closed = close(fd) == 0;
    BOOL saved = written == (ssize_t)data.length && closed && rename(temporary, path.fileSystemRepresentation) == 0;
    if (!saved) unlink(temporary);
    return saved;
}

id revivePlexStartLink(void (^update)(id), void (^linked)(void))
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *clientID = [defaults stringForKey:@"RevivePlexLinkID"];
    if (!clientID.length) {
        clientID = [NSUUID UUID].UUIDString;
        [defaults setObject:clientID forKey:@"RevivePlexLinkID"];
    }
    RevivePlexLink *link = [[RevivePlexLink alloc] initWithClientID:clientID];
    [link startWithCode:^(NSString *code) {
        update(@[@{@"title": RPText(@"Yeni kod oluştur"), @"action": @"beginLink", @"qr": @YES, @"qrCode": code},
                 row(RPText(@"Telefon onayı bekleniyor…"), nil)]);
    } completion:^(NSString *token, NSString *failure) {
        if (!token) {
            update(@[@{@"title": RPText(@"Yeniden dene"), @"action": @"beginLink", @"qr": @YES}, row(failure, nil)]);
            return;
        }
        NSString *origin = localSettings()[@"origin"] ?: defaultOrigin;
        PlexClient *client = [[PlexClient alloc] initWithOrigin:[NSURL URLWithString:origin]
            token:token clientID:clientID];
        if (!client) {
            update(@[row(RPText(@"Plex sunucu adresi geçersiz"), nil)]);
            return;
        }
        [client fetchPath:@"/library/sections" query:nil completion:^(NSDictionary *result, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error || !result) {
                    discoverPairedServer(token, token, ^(signed char saved) {
                        if (saved && linked) linked();
                        else update(@[@{@"title":RPText(@"Yeniden dene"), @"action":@"beginLink", @"qr":@YES},
                            row(RPText(@"Plex hesabının erişilebilir sunucusu bulunamadı"), nil)]);
                    });
                    return;
                }
                BOOL saved = saveSession(@{@"origin":origin, @"token":token, @"accountToken":token, @"homeOwnerToken":token});
                if (saved && linked) linked();
                else update(@[row(saved ? RPText(@"Plex hesabı bağlandı") : RPText(@"Oturum kaydedilemedi"), nil)]);
            });
        }];
    }];
    return link;
}

long revivePlexHomeRailTarget(id data, long selection, int remoteAction)
{
    NSArray *rows = data;
    if (selection < 0 || (NSUInteger)selection >= rows.count) return selection;
    long rail = [rows[(NSUInteger)selection][@"homeRail"] longValue];
    if (remoteAction == 6 || remoteAction == 7) {
        long next = selection + (remoteAction == 6 ? -1 : 1);
        if (next >= 0 && (NSUInteger)next < rows.count &&
            [rows[(NSUInteger)next][@"homeRail"] longValue] == rail) return next;
        return selection;
    }
    if (remoteAction != 3 && remoteAction != 4) return selection;
    NSUInteger start = (NSUInteger)selection;
    while (start && [rows[start - 1][@"homeRail"] longValue] == rail) start--;
    NSUInteger column = (NSUInteger)selection - start;
    if (remoteAction == 3 && !start) return selection;
    NSUInteger adjacent = remoteAction == 3 ? start - 1 : (NSUInteger)selection + 1;
    if (remoteAction == 4) {
        while (adjacent < rows.count && [rows[adjacent][@"homeRail"] longValue] == rail) adjacent++;
        if (adjacent == rows.count) return selection;
    }
    long targetRail = [rows[adjacent][@"homeRail"] longValue];
    while (adjacent && [rows[adjacent - 1][@"homeRail"] longValue] == targetRail) adjacent--;
    while (column && adjacent + 1 < rows.count &&
           [rows[adjacent + 1][@"homeRail"] longValue] == targetRail) {
        adjacent++;
        column--;
    }
    return (long)adjacent;
}

signed char revivePlexDiagnosticScreensOnly(void)
{
    NSArray *routes = [NSArray arrayWithContentsOfFile:@"/var/mobile/Library/Caches/RevivePlex.screens-once.plist"];
    id first = [routes firstObject];
    return [first isKindOfClass:[NSDictionary class]] && [first[@"screensOnly"] boolValue];
}

// One-shot, local diagnostic input. Never loaded by normal navigation.
id revivePlexDiagnosticRoutes(void)
{
    NSString *path = @"/var/mobile/Library/Caches/RevivePlex.screens-once.plist";
    NSArray *routes = [NSArray arrayWithContentsOfFile:path];
    if (!routes) return nil;
    unlink(path.fileSystemRepresentation);
    NSMutableArray *safe = [NSMutableArray array];
    for (id route in routes) {
        if (![route isKindOfClass:[NSDictionary class]] || safe.count >= 12) continue;
        BOOL cloud = [@[@"demo", @"settings", @"about", @"language", @"quality", @"skipMarkers", @"watchlist", @"cloudItem", @"discoverResults", @"more", @"homeUsers", @"playlistName", @"playlistManage", @"playlistEdit", @"liveTV", @"recordingSchedule", @"recordingRules", @"recordingInfo", @"playbackOptions", @"queueItems", @"queueEdit", @"queueItemActions", @"queueModes"] containsObject:route[@"kind"] ?: @""];
        if ((!cloud && ![@[@"media", @"detail", @"cast", @"photo", @"series", @"extras", @"chapters", @"description", @"sort", @"filters", @"filterValues", @"subtitleSearch", @"versions", @"transcode"] containsObject:route[@"kind"] ?: @""]) ||
            ![route[@"path"] isKindOfClass:[NSString class]] || (!cloud && ![route[@"path"] hasPrefix:@"/library/"] && ![route[@"path"] isEqual:@"/hubs/home/continueWatching"]) ||
            ![route[@"title"] isKindOfClass:[NSString class]]) continue;
        [safe addObject:route];
    }
    return safe;
}

// Resolve the same server-backed default action used by a detail/series page.
// A remote Play press bypasses that page without treating Select as Play.
signed char revivePlexCanQuickPlay(id selectedRoute)
{
    return [@[@"detail", @"series", @"transcode", @"play"] containsObject:selectedRoute[@"kind"] ?: @""];
}

void revivePlexQuickPlayRoute(id selectedRoute, void (^completion)(id))
{
    if (!revivePlexCanQuickPlay(selectedRoute)) { completion(nil); return; }
    if ([@[@"transcode", @"play"] containsObject:selectedRoute[@"kind"]]) { completion(selectedRoute); return; }
    revivePlexLoadRows(selectedRoute, ^(NSArray *rows) {
        for (NSDictionary *entry in rows) {
            NSDictionary *next = entry[@"route"];
            if ([@[@"transcode", @"play"] containsObject:next[@"kind"] ?: @""]) { completion(next); return; }
        }
        completion(nil);
    });
}

id revivePlexResumeEpisode(id episodes)
{
    NSDictionary *fallback = nil, *unfinished = nil;
    for (NSDictionary *episode in episodes) {
        if (![episode[@"type"] isEqual:@"episode"] || !numberKey(episode[@"ratingKey"])) continue;
        if (!fallback || ([fallback[@"viewCount"] intValue] > 0 && ![episode[@"viewCount"] intValue])) fallback = episode;
        double offset = [episode[@"viewOffset"] doubleValue];
        if (offset > 0 && offset < [episode[@"duration"] doubleValue] &&
            (!unfinished || [episode[@"lastViewedAt"] doubleValue] > [unfinished[@"lastViewedAt"] doubleValue])) unfinished = episode;
    }
    return unfinished ?: fallback;
}

id revivePlexResumeOptionsRoute(id selectedRoute)
{
    if (![selectedRoute[@"kind"] isEqual:@"playbackOptions"]) return nil;
    NSMutableDictionary *resume = [selectedRoute mutableCopy];
    resume[@"kind"] = @"transcode";
    resume[@"title"] = RPText(@"Oynatıcı");
    [resume removeObjectForKey:@"playbackError"];
    return resume;
}
