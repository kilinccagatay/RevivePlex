#import "../src/PlexClient.h"

static void verify(BOOL assertion, NSString *message)
{
    if (!assertion) {
        fprintf(stderr, "%s\n", message.UTF8String);
        exit(1);
    }
}

int main(int argc, const char **argv)
{
    @autoreleasepool {
        verify(argc == 2, @"Fixture URL missing");
        NSURL *origin = [NSURL URLWithString:@(argv[1])];
        verify(![[PlexClient alloc] initWithOrigin:origin token:@"fixture" clientID:@"test"],
               @"Accepted token over HTTP");
        PlexClient *client = [[PlexClient alloc] initWithOrigin:origin token:nil clientID:@"test"];
        verify(client != nil, @"Rejected the fixture origin");
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        id previousLanguage = [defaults objectForKey:@"RevivePlexLanguage"];
        for (NSString *language in @[@"en", @"tr"]) {
            [defaults setObject:language forKey:@"RevivePlexLanguage"];
            verify([[[client requestForPath:@"/hubs" query:nil] valueForHTTPHeaderField:@"Accept-Language"] isEqual:language],
                   @"Server language did not follow independent app language");
        }
        if (previousLanguage) [defaults setObject:previousLanguage forKey:@"RevivePlexLanguage"];
        else [defaults removeObjectForKey:@"RevivePlexLanguage"];
        verify(![client requestForPath:@"//example.com" query:nil], @"Accepted foreign origin");
        verify(![client artworkRequestForPath:@"https://example.com/image"], @"Accepted external artwork");
        NSURL *secure = [NSURL URLWithString:@"https://plex.example"];
        PlexClient *authenticated = [[PlexClient alloc] initWithOrigin:secure token:@"fixture" clientID:@"test"];
        NSURLRequest *artwork = [authenticated artworkRequestForPath:@"/library/metadata/1/thumb/2"];
        verify([[artwork valueForHTTPHeaderField:@"X-Plex-Token"] isEqual:@"fixture"] &&
               ![artwork.URL.absoluteString containsString:@"fixture"], @"Unsafe token placement");

        NSDictionary *cases = @{@"/identity": @0, @"/library/sections": @0,
                                @"/library/metadata/99": @0,
                                @"/redirect": @302, @"/oversized": @413, @"/doctype": @422};
        for (NSString *path in cases) {
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            [client fetchPath:path query:nil completion:^(NSDictionary *data, NSError *error) {
                NSInteger expected = [cases[path] integerValue];
                verify(error.code == expected, path);
                if ([path isEqual:@"/identity"]) {
                    verify([data[@"attributes"][@"version"] isEqual:@"1.2.3"], @"Identity missing");
                } else if ([path isEqual:@"/library/sections"]) {
                    verify([data[@"items"][0][@"viewOffset"] isEqual:@"42000"], @"Progress missing");
                    verify([data[@"items"][0][@"viewCount"] isEqual:@"1"], @"Watched state missing");
                } else if ([path isEqual:@"/library/metadata/99"]) {
                    verify([data[@"items"][0][@"Chapter"][0][@"startTimeOffset"] isEqual:@"62500"], @"Chapter timing missing");
                    verify([data[@"items"][0][@"Extras"][0][@"ratingKey"] isEqual:@"98"], @"Nested extras missing");
                    verify([data[@"items"] count] == 1, @"Nested extra leaked into top-level metadata");
                    verify([data[@"parts"][0][@"streams"] count] == 2, @"Audio/subtitle streams missing");
                    verify([data[@"items"][0][@"Role"][0][@"tag"] isEqual:@"An Actor"], @"Cast metadata missing");
                }
                dispatch_semaphore_signal(done);
            }];
            verify(!dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)),
                   @"Fixture timed out");
        }
        dispatch_semaphore_t tuneDone = dispatch_semaphore_create(0);
        [client createPath:@"/livetv/dvrs/1/channels/2.1/tune" query:nil completion:^(NSDictionary *data, NSError *error) {
            verify(!error && [data[@"items"][0][@"live"] boolValue], @"Live channel tune POST failed");
            verify([data[@"parts"][0][@"media"][@"uuid"] isEqual:@"dc30f95e-6379-44f7-8168-172ffc820496"], @"Tuner media session identity missing");
            verify([data[@"parts"][0][@"streams"][0][@"codec"] isEqual:@"mpeg2video"], @"Tuner stream metadata missing");
            dispatch_semaphore_signal(tuneDone);
        }];
        verify(!dispatch_semaphore_wait(tuneDone, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)), @"Tune fixture timed out");
        dispatch_semaphore_t queueDone = dispatch_semaphore_create(0);
        [client createPath:@"/playQueues" query:@[[NSURLQueryItem queryItemWithName:@"playlistID" value:@"55"]]
            completion:^(NSDictionary *data, NSError *error) {
                verify(!error && [data[@"attributes"][@"playQueueID"] isEqual:@"55"], @"Queue creation POST failed");
                verify([data[@"items"][1][@"playQueueItemID"] isEqual:@"702"], @"Queue item identity lost");
                dispatch_semaphore_signal(queueDone);
            }];
        verify(!dispatch_semaphore_wait(queueDone, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)), @"Queue creation timed out");
        dispatch_semaphore_t timelineDone = dispatch_semaphore_create(0);
        [client reportTimeline:@[[NSURLQueryItem queryItemWithName:@"state" value:@"paused"]] session:@"timeline-fixture" completion:^(NSData *data, NSError *error) {
            (void)data; verify(!error, @"Timeline POST or session header failed"); dispatch_semaphore_signal(timelineDone);
        }];
        verify(!dispatch_semaphore_wait(timelineDone, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)), @"Timeline report timed out");
        dispatch_semaphore_t catalogDone = dispatch_semaphore_create(0);
        dispatch_semaphore_t updateDone = dispatch_semaphore_create(0);
        [client updatePath:@"/library/parts/991" query:@[
            [NSURLQueryItem queryItemWithName:@"subtitleStreamID" value:@"993"],
            [NSURLQueryItem queryItemWithName:@"allParts" value:@"1"]]
            completion:^(NSData *data, NSError *error) {
                (void)data;
                verify(!error, @"Stream selection PUT failed");
                dispatch_semaphore_signal(updateDone);
            }];
        verify(!dispatch_semaphore_wait(updateDone, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)),
            @"Stream update timed out");
        [client fetchCatalogPath:@"/catalog-pages" query:nil completion:^(NSDictionary *data, NSError *error) {
            verify(!error && [data[@"items"] count] == 243, @"Catalog pagination lost items");
            verify([data[@"items"][242][@"title"] isEqual:@"Movie 242"], @"Last catalog page missing");
            dispatch_semaphore_signal(catalogDone);
        }];
        verify(!dispatch_semaphore_wait(catalogDone, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)),
               @"Catalog pagination timed out");
        puts("Plex fixture passed identity, library XML, pagination, progress, redirects and response bounds.");
    }
    return 0;
}
