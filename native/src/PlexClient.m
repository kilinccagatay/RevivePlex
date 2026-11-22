#import "PlexClient.h"
#import "Localization.h"
#include <string.h>

static const NSUInteger responseLimit = 1024 * 1024;

@interface PlexXML : NSObject <NSXMLParserDelegate>
@property(nonatomic) NSUInteger depth;
@property(nonatomic) BOOL includeParts;
@property(nonatomic, copy) NSDictionary *root;
@property(nonatomic, strong) NSMutableArray *items;
@property(nonatomic, strong) NSMutableArray *parts;
@property(nonatomic, copy) NSDictionary *media;
@property(nonatomic, strong) NSMutableDictionary *hub;
@property(nonatomic, strong) NSMutableDictionary *currentItem;
@property(nonatomic, strong) NSMutableDictionary *currentPart;
@property(nonatomic) NSUInteger mediaIndex;
@end

@implementation PlexXML
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)name
  namespaceURI:(NSString *)uri qualifiedName:(NSString *)qualified
    attributes:(NSDictionary *)attributes
{
    ++self.depth;
    if (self.depth == 1 && ( [name isEqualToString:@"MediaContainer"] || [name isEqualToString:@"user"] || [name isEqualToString:@"User"] )) self.root = attributes;
    if (self.includeParts && self.depth == 3 && [name isEqualToString:@"Media"]) {
        NSMutableDictionary *media = [attributes mutableCopy];
        media[@"mediaIndex"] = @(self.mediaIndex++);
        self.media = media;
        if (!self.currentItem[@"Media"]) self.currentItem[@"Media"] = [NSMutableArray array];
        [self.currentItem[@"Media"] addObject:media];
    }
    if (self.depth == 4 && self.media && [name isEqualToString:@"Part"]) {
        if (self.parts.count < 32) {
            self.currentPart = [@{@"media": self.media, @"part": attributes,
                @"streams":[NSMutableArray array]} mutableCopy];
            [self.parts addObject:self.currentPart];
        }
    }
    if (self.depth == 5 && self.currentPart && [name isEqual:@"Stream"])
        [self.currentPart[@"streams"] addObject:attributes];
    if (self.depth == 3 && self.currentItem && [name isEqual:@"Extras"])
        self.currentItem[@"Extras"] = [NSMutableArray array];
    if (self.depth == 4 && self.currentItem[@"Extras"] && [name isEqual:@"Video"])
        [self.currentItem[@"Extras"] addObject:attributes];
    if (self.depth == 3 && self.currentItem &&
        [@[@"Role", @"Genre", @"Director", @"Writer", @"Rating", @"Marker", @"Chapter"] containsObject:name]) {
        if (!self.currentItem[name]) self.currentItem[name] = [NSMutableArray array];
        [self.currentItem[name] addObject:attributes];
    }
    if (self.depth == 2 && self.root && self.items.count < 200) {
        if ([name isEqualToString:@"Hub"]) {
            self.hub = [attributes mutableCopy];
            self.hub[@"entries"] = [NSMutableArray array];
            [self.items addObject:self.hub];
        } else if ([@[@"Directory", @"Video", @"Metadata", @"Photo", @"Track", @"Playlist", @"Stream", @"User"] containsObject:name]) {
            self.currentItem = [attributes mutableCopy];
            self.mediaIndex = 0;
            self.currentItem[@"element"] = name;
            [self.items addObject:self.currentItem];
        }
    } else if (self.depth == 3 && self.hub &&
               [@[@"Directory", @"Video", @"Metadata", @"Photo", @"Track", @"Playlist", @"Stream", @"User"] containsObject:name]) {
        NSMutableArray *entries = self.hub[@"entries"];
        if (entries.count < 100) {
            NSMutableDictionary *entry = [attributes mutableCopy];
            entry[@"element"] = name;
            [entries addObject:entry];
        }
    }
}
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)name
  namespaceURI:(NSString *)uri qualifiedName:(NSString *)qualified
{
    if (self.depth == 3 && [name isEqualToString:@"Media"]) self.media = nil;
    if (self.depth == 4 && [name isEqualToString:@"Part"]) self.currentPart = nil;
    if (self.depth == 2) { self.hub = nil; self.currentItem = nil; }
    --self.depth;
}
@end

static NSError *plexError(NSInteger code)
{
    return [NSError errorWithDomain:@"org.revivetv.plex" code:code userInfo:nil];
}

@interface PlexTransfer : NSObject <NSURLSessionDataDelegate>
@property(nonatomic) BOOL includeParts;
@property(nonatomic, strong) NSMutableData *data;
@property(nonatomic, strong) NSError *failure;
@property(nonatomic, copy) void (^completion)(NSDictionary *, NSError *);
@property(nonatomic, copy) void (^dataCompletion)(NSData *, NSError *);
@end

@implementation PlexTransfer
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))complete
{
    complete(nil);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))complete
{
    NSInteger code = [(NSHTTPURLResponse *)response statusCode];
    if (code < 200 || code >= 300 || response.expectedContentLength > (int64_t)responseLimit) {
        self.failure = plexError(code >= 200 && code < 300 ? 413 : code);
        complete(NSURLSessionResponseCancel);
        return;
    }
    complete(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data
{
    if (self.failure) return;
    if (data.length > responseLimit - self.data.length) {
        self.failure = plexError(413);
        [task cancel];
        return;
    }
    [self.data appendData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    NSError *failure = self.failure ?: (error ? plexError(error.code) : nil);
    if (self.dataCompletion) {
        self.dataCompletion(failure ? nil : self.data, failure);
        [session finishTasksAndInvalidate];
        return;
    }
    NSDictionary *result = nil;
    if (!failure) {
        NSString *xml = [[NSString alloc] initWithData:self.data encoding:NSUTF8StringEncoding];
        if (xml && self.data.length && !memchr(self.data.bytes, 0, self.data.length) &&
            [xml rangeOfString:@"<!DOCTYPE" options:NSCaseInsensitiveSearch].location == NSNotFound &&
            [xml rangeOfString:@"<!ENTITY" options:NSCaseInsensitiveSearch].location == NSNotFound) {
            NSXMLParser *parser = [[NSXMLParser alloc] initWithData:self.data];
            PlexXML *delegate = [PlexXML new];
            delegate.includeParts = self.includeParts;
            delegate.items = [NSMutableArray array];
            delegate.parts = [NSMutableArray array];
            parser.delegate = delegate;
            parser.shouldResolveExternalEntities = NO;
            if ([parser parse] && delegate.root) {
                result = @{@"attributes": delegate.root, @"items": [delegate.items copy],
                    @"parts": [delegate.parts copy]};
            }
        }
        if (!result) failure = plexError(422);
    }
    self.completion(result, failure);
    [session finishTasksAndInvalidate];
}
@end

@implementation PlexClient {
    NSURL *_origin;
    NSString *_token;
    NSString *_clientID;
}

- (instancetype)initWithOrigin:(NSURL *)origin token:(NSString *)token clientID:(NSString *)clientID
{
    NSURLComponents *parts = [NSURLComponents componentsWithURL:origin resolvingAgainstBaseURL:NO];
    NSString *scheme = parts.scheme.lowercaseString;
    BOOL https = [scheme isEqualToString:@"https"];
    if (!parts.host.length || parts.user || parts.password || parts.query || parts.fragment ||
        (parts.path.length && ![parts.path isEqualToString:@"/"]) ||
        (!https && (![scheme isEqualToString:@"http"] || token.length)) || !clientID.length ||
        (token.length && [token rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].length) ||
        [clientID rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].length) return nil;
    if ((self = [super init])) {
        _origin = parts.URL;
        _token = [token copy];
        _clientID = [clientID copy];
    }
    return self;
}

- (NSURLRequest *)requestForPath:(NSString *)path query:(NSArray *)query
{
    if (![path hasPrefix:@"/"] || [path hasPrefix:@"//"] ||
        [path rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\\?#"]].length ||
        [path rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].length) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithURL:_origin resolvingAgainstBaseURL:NO];
    parts.path = path;
    parts.queryItems = query.count ? query : nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:parts.URL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8.0];
    [request setValue:@"application/xml" forHTTPHeaderField:@"Accept"];
    [request setValue:revivePlexLanguage() forHTTPHeaderField:@"Accept-Language"];
    for (NSURLQueryItem *item in query) {
        if ([@[@"X-Plex-Container-Start", @"X-Plex-Container-Size"] containsObject:item.name])
            [request setValue:item.value forHTTPHeaderField:item.name];
    }
    [request setValue:_clientID forHTTPHeaderField:@"X-Plex-Client-Identifier"];
    [request setValue:@"RevivePlex" forHTTPHeaderField:@"X-Plex-Product"];
    if (_token.length) [request setValue:_token forHTTPHeaderField:@"X-Plex-Token"];
    return request;
}

- (NSURLRequest *)artworkRequestForPath:(NSString *)path
{
    if (![path hasPrefix:@"/library/"]) return nil;
    NSURLComponents *artwork = [NSURLComponents componentsWithString:path];
    if (!artwork || artwork.fragment) return nil;
    NSMutableURLRequest *request = [[self requestForPath:artwork.path query:artwork.queryItems] mutableCopy];
    [request setValue:@"image/*" forHTTPHeaderField:@"Accept"];
    return request;
}

- (void)fetchPath:(NSString *)path query:(NSArray *)query
       completion:(void (^)(NSDictionary *, NSError *))completion
{
    NSURLRequest *request = [self requestForPath:path query:query];
    if (!request) {
        completion(nil, plexError(400));
        return;
    }
    PlexTransfer *transfer = [PlexTransfer new];
    transfer.includeParts = [path hasPrefix:@"/library/metadata/"] && path.pathComponents.count == 4;
    transfer.completion = completion;
    [self startTransfer:transfer request:request];
}

- (void)createPath:(NSString *)path query:(NSArray *)query completion:(void (^)(NSDictionary *, NSError *))completion
{
    NSMutableURLRequest *request = [[self requestForPath:path query:query] mutableCopy];
    if (!request) { completion(nil, plexError(400)); return; }
    request.HTTPMethod = @"POST";
    PlexTransfer *transfer = [PlexTransfer new];
    transfer.includeParts = [path hasPrefix:@"/livetv/dvrs/"] && [path hasSuffix:@"/tune"];
    if (transfer.includeParts) request.timeoutInterval = 30.0;
    transfer.completion = completion;
    [self startTransfer:transfer request:request];
}

- (void)fetchDataForPath:(NSString *)path query:(NSArray *)query
             completion:(void (^)(NSData *, NSError *))completion
{
    NSMutableURLRequest *request = [[self requestForPath:path query:query] mutableCopy];
    if (!request) {
        completion(nil, plexError(400));
        return;
    }
    if ([path hasSuffix:@"/start.m3u8"]) request.timeoutInterval = 30.0;
    [request setValue:@"application/vnd.apple.mpegurl" forHTTPHeaderField:@"Accept"];
    [request setValue:@"iOS" forHTTPHeaderField:@"X-Plex-Platform"];
    PlexTransfer *transfer = [PlexTransfer new];
    transfer.dataCompletion = completion;
    [self startTransfer:transfer request:request];
}

- (void)fetchJSONPath:(NSString *)path query:(NSArray *)query completion:(void (^)(id, NSError *))completion
{
    NSMutableURLRequest *request = [[self requestForPath:path query:query] mutableCopy];
    if (!request) { completion(nil, plexError(400)); return; }
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    PlexTransfer *transfer = [PlexTransfer new];
    transfer.dataCompletion = ^(NSData *data, NSError *error) {
        id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        completion(value, error ?: (value ? nil : plexError(422)));
    };
    [self startTransfer:transfer request:request];
}

- (void)fetchCatalogPath:(NSString *)path query:(NSArray *)query
             completion:(void (^)(NSDictionary *, NSError *))completion
{
    NSMutableArray *parameters = [NSMutableArray array];
    for (NSURLQueryItem *item in query)
        if (![@[@"X-Plex-Container-Start", @"X-Plex-Container-Size"] containsObject:item.name])
            [parameters addObject:item];
    [self fetchCatalogPage:path query:parameters items:[NSMutableArray array] completion:completion];
}

- (void)fetchCatalogPage:(NSString *)path query:(NSArray *)query items:(NSMutableArray *)items
             completion:(void (^)(NSDictionary *, NSError *))completion
{
    NSMutableArray *page = [query mutableCopy];
    [page addObject:[NSURLQueryItem queryItemWithName:@"X-Plex-Container-Start" value:@(items.count).stringValue]];
    [page addObject:[NSURLQueryItem queryItemWithName:@"X-Plex-Container-Size" value:@"100"]];
    [self fetchPath:path query:page completion:^(NSDictionary *result, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSDictionary *attributes = result[@"attributes"];
        NSArray *received = result[@"items"];
        if (items.count && (!attributes[@"offset"] || (NSUInteger)[attributes[@"offset"] integerValue] != items.count)) {
            completion(nil, plexError(422)); return;
        }
        [items addObjectsFromArray:received];
        NSUInteger total = (NSUInteger)[attributes[@"totalSize"] integerValue];
        if (!attributes[@"totalSize"] || items.count >= total) {
            NSMutableDictionary *complete = [result mutableCopy];
            complete[@"items"] = [items copy];
            completion(complete, nil);
        } else if (!received.count || items.count >= 20000) {
            // Report malformed/oversized catalogs explicitly instead of silently losing titles.
            completion(nil, plexError(413));
        } else {
            [self fetchCatalogPage:path query:query items:items completion:completion];
        }
    }];
}

- (void)startTransfer:(PlexTransfer *)transfer request:(NSURLRequest *)request
{
    transfer.data = [NSMutableData data];
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForResource = MAX(12.0, request.timeoutInterval + 2.0);
    configuration.HTTPShouldSetCookies = NO;
    configuration.URLCredentialStorage = nil;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:transfer delegateQueue:nil];
    [[session dataTaskWithRequest:request] resume];
}

- (void)updatePath:(NSString *)path query:(NSArray *)query
       completion:(void (^)(NSData *, NSError *))completion
{
    NSMutableURLRequest *request = [[self requestForPath:path query:query] mutableCopy];
    if (!request) { completion(nil, plexError(400)); return; }
    request.HTTPMethod = @"PUT";
    PlexTransfer *transfer = [PlexTransfer new];
    transfer.dataCompletion = completion;
    [self startTransfer:transfer request:request];
}
- (void)deletePath:(NSString *)path completion:(void (^)(NSData *, NSError *))completion
{
    NSMutableURLRequest *request = [[self requestForPath:path query:nil] mutableCopy];
    if (!request) { completion(nil, plexError(400)); return; }
    request.HTTPMethod = @"DELETE";
    PlexTransfer *transfer = [PlexTransfer new]; transfer.dataCompletion = completion;
    [self startTransfer:transfer request:request];
}
- (void)reportTimeline:(NSArray *)query session:(NSString *)session completion:(void (^)(NSData *, NSError *))completion
{
    NSMutableURLRequest *request = [[self requestForPath:@"/:/timeline" query:query] mutableCopy];
    if (!request || !session.length) { completion(nil, plexError(400)); return; }
    request.HTTPMethod = @"POST";
    [request setValue:session forHTTPHeaderField:@"X-Plex-Session-Identifier"];
    PlexTransfer *transfer = [PlexTransfer new]; transfer.dataCompletion = completion;
    [self startTransfer:transfer request:request];
}
@end
