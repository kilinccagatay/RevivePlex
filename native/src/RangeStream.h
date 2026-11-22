#import <AVFoundation/AVFoundation.h>

BOOL revivePlexParseContentRange(NSString *value, long long *start, long long *end, long long *total);

@interface RevivePlexRangeStream : NSObject
- (instancetype)initWithRequest:(NSURLRequest *)request;
- (AVURLAsset *)asset;
- (void)stop;
@end
