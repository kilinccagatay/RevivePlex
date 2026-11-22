#include "Localization.h"
#import "PlexLink.h"

@interface RevivePlexLink () <NSURLSessionTaskDelegate>
@property(nonatomic, copy) NSString *clientID;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSDate *expires;
@property(nonatomic, copy) void (^display)(NSString *);
@property(nonatomic, copy) void (^finished)(NSString *, NSString *);
@end

@implementation RevivePlexLink
- (instancetype)initWithClientID:(NSString *)clientID
{
    if ((self = [super init])) _clientID = [clientID copy];
    return self;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))complete
{
    (void)session; (void)task; (void)response; (void)request;
    complete(nil);
}

- (void)cancel
{
    [self.session invalidateAndCancel];
    self.session = nil;
    self.finished = nil;
    self.display = nil;
}

- (void)finish:(NSString *)token failure:(NSString *)failure
{
    void (^callback)(NSString *, NSString *) = self.finished;
    [self cancel];
    if (callback) callback(token, failure);
}

- (void)request:(NSString *)suffix method:(NSString *)method
       callback:(void (^)(NSDictionary *, NSInteger))callback
{
    NSURL *url = [NSURL URLWithString:[@"https://clients.plex.tv/api/v2/pins" stringByAppendingString:suffix]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"RevivePlex" forHTTPHeaderField:@"X-Plex-Product"];
    [request setValue:self.clientID forHTTPHeaderField:@"X-Plex-Client-Identifier"];
    __weak RevivePlexLink *weakSelf = self;
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger code = error ? error.code : [(NSHTTPURLResponse *)response statusCode];
        id object = nil;
        if (!error && data.length && data.length <= 16384 && code >= 200 && code < 300)
            object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.session) callback([object isKindOfClass:[NSDictionary class]] ? object : nil, code);
        });
    }] resume];
}

- (void)poll:(NSNumber *)pin
{
    if (!self.session) return;
    if ([self.expires timeIntervalSinceNow] <= 0) {
        [self finish:nil failure:RPText(@"Kodun süresi doldu")];
        return;
    }
    __weak RevivePlexLink *weakSelf = self;
    [self request:[NSString stringWithFormat:@"/%@", pin] method:@"GET" callback:^(NSDictionary *result, NSInteger code) {
        RevivePlexLink *active = weakSelf;
        if (!active) return;
        NSString *token = result[@"authToken"];
        if ([token isKindOfClass:[NSString class]] && token.length && token.length <= 4096) {
            [active finish:token failure:nil];
            return;
        }
        if (!result && (code == 404 || code == 410)) {
            [active finish:nil failure:RPText(@"Kodun süresi doldu")];
            return;
        }
        if (!result && code >= 400 && code != 429) {
            [active finish:nil failure:RPText(@"Plex etkinleştirmeyi reddetti")];
            return;
        }
        int64_t delay = code == 429 || !result ? 5 : 2;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [weakSelf poll:pin];
        });
    }];
}

- (void)startWithCode:(void (^)(NSString *))display
          completion:(void (^)(NSString *, NSString *))completion
{
    [self cancel];
    self.display = display;
    self.finished = completion;
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.HTTPShouldSetCookies = NO;
    configuration.URLCredentialStorage = nil;
    configuration.timeoutIntervalForResource = 12.0;
    self.session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    __weak RevivePlexLink *weakSelf = self;
    [self request:@"?strong=false" method:@"POST" callback:^(NSDictionary *result, NSInteger code) {
        RevivePlexLink *active = weakSelf;
        if (!active) return;
        NSString *pinCode = result[@"code"];
        NSNumber *pinID = result[@"id"];
        if (![pinCode isKindOfClass:[NSString class]] || pinCode.length != 4 ||
            [pinCode rangeOfCharacterFromSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]].length ||
            ![pinID isKindOfClass:[NSNumber class]] || pinID.longLongValue <= 0) {
            NSString *message = [NSString stringWithFormat:RPText(@"Plex kodu alınamadı (%ld)"), (long)code];
            [active finish:nil failure:message];
            return;
        }
        id expiresIn = result[@"expiresIn"];
        double lifetime = [expiresIn respondsToSelector:@selector(doubleValue)] ? [expiresIn doubleValue] : 180;
        active.expires = [NSDate dateWithTimeIntervalSinceNow:MIN(MAX(1, lifetime), 900)];
        active.display(pinCode);
        [active poll:pinID];
    }];
}
@end
