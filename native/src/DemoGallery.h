// Original synthetic screenshot content. No user library data or external artwork.
// Compiled only with REVIVEPLEX_DEMO_SCREENSHOTS=1; never used by release builds.
#ifdef REVIVEPLEX_DEMO_SCREENSHOTS
static NSArray *revivePlexDemoRows(NSString *screen)
{
    NSArray *names = @[@"Amber Horizon", @"Blue Current", @"Quiet Orbit", @"Paper Mountains",
        @"Morning Geometry", @"Northern Lines", @"Soft Signals", @"Glass Garden",
        @"The Long Way Home", @"Small Worlds", @"After the Rain", @"Open Skies"];
    BOOL home = [screen isEqual:@"home"], continuing = [screen isEqual:@"continue"];
    NSMutableArray *rows = [NSMutableArray array];
    if (home) for (NSString *title in @[@"Search", @"Continue Watching", @"Movies", @"TV Shows", @"Photos", @"More"]) {
        [rows addObject:@{@"title":title, @"homeRail":@0,
            @"route":@{@"kind":[title isEqual:@"Search"] ? @"search" : @"demo", @"title":title, @"path":@""}}];
    }
    NSUInteger count = home ? 8 : continuing ? 4 : names.count;
    for (NSUInteger i = 0; i < count; i++) {
        NSMutableDictionary *card = [@{@"title":names[i], @"cardTitle":names[i], @"shelf":@YES,
            @"mediaType":@"movie", @"catalogCaption":@"2026", @"demoArtwork":@(i + 1),
            @"route":@{@"kind":@"demo", @"title":names[i], @"path":@"catalog"}} mutableCopy];
        if (home) { card[@"homeRail"] = @(i < 4 ? 1 : 2); card[@"railTitle"] = i < 4 ? @"Continue Watching" : @"Recently Added"; card[@"caption"] = @"Demo collection"; }
        if (continuing) card[@"landscapeArtwork"] = @YES;
        [rows addObject:card];
    }
    return rows;
}
#endif
