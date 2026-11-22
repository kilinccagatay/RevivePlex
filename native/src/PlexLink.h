#import <Foundation/Foundation.h>

@interface RevivePlexLink : NSObject
- (instancetype)initWithClientID:(NSString *)clientID;
- (void)startWithCode:(void (^)(NSString *code))display
          completion:(void (^)(NSString *token, NSString *failure))completion;
- (void)cancel;
@end
