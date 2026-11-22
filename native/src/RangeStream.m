#import "RangeStream.h"
#include <limits.h>

static const long long chunkSize = 512 * 1024;

BOOL revivePlexParseContentRange(NSString *value, long long *start, long long *end, long long *total)
{
    if (![value hasPrefix:@"bytes "] || value.length > 96) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:value];
    scanner.charactersToBeSkipped = nil;
    long long a, b, c;
    if (![scanner scanString:@"bytes " intoString:NULL] ||
        ![scanner scanLongLong:&a] || ![scanner scanString:@"-" intoString:NULL] ||
        ![scanner scanLongLong:&b] || ![scanner scanString:@"/" intoString:NULL] ||
        ![scanner scanLongLong:&c] || !scanner.isAtEnd || a < 0 || b < a || c <= b) return NO;
    *start = a;
    *end = b;
    *total = c;
    return YES;
}

@interface RevivePlexRangeChunk : NSObject
@property(nonatomic, strong) AVAssetResourceLoadingRequest *request;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic) long long start;
@property(nonatomic) long long limit;
@property(nonatomic) long long expected;
@property(nonatomic) long long count;
@end
@implementation RevivePlexRangeChunk
@end

@interface RevivePlexRangeStream () <AVAssetResourceLoaderDelegate, NSURLSessionDataDelegate>
@property(nonatomic, copy) NSURLRequest *request;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableDictionary *chunks;
@property(nonatomic) long long total;
@end

@implementation RevivePlexRangeStream

- (instancetype)initWithRequest:(NSURLRequest *)request
{
    if (![[request.URL scheme] isEqual:@"https"]) return nil;
    if ((self = [super init])) {
        _request = [request copy];
        _chunks = [NSMutableDictionary dictionary];
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.HTTPShouldSetCookies = NO;
        config.URLCredentialStorage = nil;
        config.timeoutIntervalForResource = 20;
        config.HTTPMaximumConnectionsPerHost = 3;
        _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:[NSOperationQueue mainQueue]];
    }
    return self;
}

- (AVURLAsset *)asset
{
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL URLWithString:@"reviveplex-media://local/video.mp4"]
                                          options:nil];
    [asset.resourceLoader setDelegate:self queue:dispatch_get_main_queue()];
    return asset;
}

- (void)fail:(AVAssetResourceLoadingRequest *)request
{
    [request finishLoadingWithError:[NSError errorWithDomain:@"org.revivetv.stream" code:1 userInfo:nil]];
}

- (void)fetch:(AVAssetResourceLoadingRequest *)request
{
    if (!self.session) {
        [self fail:request];
        return;
    }
    AVAssetResourceLoadingDataRequest *data = request.dataRequest;
    long long start = data ? MAX(data.currentOffset, data.requestedOffset) : 0;
    if (start < 0 || start > LLONG_MAX - chunkSize) {
        [self fail:request];
        return;
    }
    if (self.total && start >= self.total) {
        [request finishLoading];
        return;
    }
    long long length = data ? chunkSize : 1;
    if (data && !data.requestsAllDataToEndOfResource) {
        if (data.requestedOffset < 0 || data.requestedLength < 0 ||
            data.requestedOffset > LLONG_MAX - data.requestedLength) {
            [self fail:request];
            return;
        }
        length = MIN(length, data.requestedOffset + data.requestedLength - start);
        if (length <= 0) {
            [request finishLoading];
            return;
        }
    }
    if (self.total) length = MIN(length, self.total - start);
    NSMutableURLRequest *http = [self.request mutableCopy];
    [http setValue:@"video/mp4" forHTTPHeaderField:@"Accept"];
    [http setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [http setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", start, start + length - 1]
        forHTTPHeaderField:@"Range"];
    RevivePlexRangeChunk *block = [RevivePlexRangeChunk new];
    block.request = request;
    block.start = start;
    block.limit = length;
    block.task = [self.session dataTaskWithRequest:http];
    self.chunks[@(block.task.taskIdentifier)] = block;
    [block.task resume];
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)loader
shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)request
{
    (void)loader;
    [self fetch:request];
    return YES;
}

- (void)resourceLoader:(AVAssetResourceLoader *)loader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)request
{
    (void)loader;
    for (NSNumber *key in self.chunks.allKeys) {
        RevivePlexRangeChunk *chunk = self.chunks[key];
        if (chunk.request == request) {
            [self.chunks removeObjectForKey:key];
            [chunk.task cancel];
        }
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))complete
{
    (void)session; (void)task; (void)response; (void)request;
    complete(nil);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))complete
{
    (void)session;
    RevivePlexRangeChunk *chunk = self.chunks[@(task.taskIdentifier)];
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    NSString *range = nil;
    for (NSString *key in http.allHeaderFields)
        if ([key caseInsensitiveCompare:@"Content-Range"] == NSOrderedSame) range = http.allHeaderFields[key];
    long long start, end, total;
    if (!chunk || http.statusCode != 206 || !revivePlexParseContentRange(range, &start, &end, &total) ||
        start != chunk.start || end - start + 1 > chunk.limit || (self.total && total != self.total)) {
        complete(NSURLSessionResponseCancel);
        return;
    }

    self.total = total;
    chunk.expected = end - start + 1;
    AVAssetResourceLoadingContentInformationRequest *info = chunk.request.contentInformationRequest;
    info.contentType = @"public.mpeg-4";
    info.contentLength = total;
    info.byteRangeAccessSupported = YES;
    complete(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data
{
    (void)session;
    RevivePlexRangeChunk *chunk = self.chunks[@(task.taskIdentifier)];
    if (!chunk || (long long)data.length > chunk.expected - chunk.count) {
        [task cancel];
        return;
    }
    chunk.count += (long long)data.length;
    [chunk.request.dataRequest respondWithData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    (void)session;
    NSNumber *key = @(task.taskIdentifier);
    RevivePlexRangeChunk *chunk = self.chunks[key];
    [self.chunks removeObjectForKey:key];
    if (!chunk) return;
    if (error || !chunk.expected || chunk.count != chunk.expected) {
        [self fail:chunk.request];
    } else if (!chunk.request.dataRequest) {
        [chunk.request finishLoading];
    } else {
        [self fetch:chunk.request];
    }
}

- (void)stop
{
    [self.chunks removeAllObjects];
    [self.session invalidateAndCancel];
    self.session = nil;
}
@end
