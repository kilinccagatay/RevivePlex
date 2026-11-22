#import <Foundation/Foundation.h>

@interface PlexClient : NSObject
- (instancetype)initWithOrigin:(NSURL *)origin token:(NSString *)token
                      clientID:(NSString *)clientID;
- (NSURLRequest *)requestForPath:(NSString *)path query:(NSArray *)query;
- (void)fetchPath:(NSString *)path query:(NSArray *)query
       completion:(void (^)(NSDictionary *, NSError *))completion;
- (void)fetchCatalogPath:(NSString *)path query:(NSArray *)query
             completion:(void (^)(NSDictionary *, NSError *))completion;
- (void)fetchDataForPath:(NSString *)path query:(NSArray *)query
             completion:(void (^)(NSData *, NSError *))completion;
- (NSURLRequest *)artworkRequestForPath:(NSString *)path;
- (void)updatePath:(NSString *)path query:(NSArray *)query
       completion:(void (^)(NSData *, NSError *))completion;
- (void)fetchJSONPath:(NSString *)path query:(NSArray *)query completion:(void (^)(id, NSError *))completion;
- (void)createPath:(NSString *)path query:(NSArray *)query completion:(void (^)(NSDictionary *, NSError *))completion;
- (void)deletePath:(NSString *)path completion:(void (^)(NSData *, NSError *))completion;
- (void)reportTimeline:(NSArray *)query session:(NSString *)session completion:(void (^)(NSData *, NSError *))completion;
@end
