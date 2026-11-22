#import "DirectPlay.h"

NSString *revivePlexCompatiblePart(NSArray *parts)
{
    for (NSDictionary *entry in parts) {
        NSDictionary *media = entry[@"media"];
        NSDictionary *part = entry[@"part"];
        NSString *path = part[@"key"];
        NSString *profile = [media[@"videoProfile"] lowercaseString];
        int width = [media[@"width"] intValue], height = [media[@"height"] intValue];
        int64_t bytes = [part[@"size"] longLongValue];
        if (![media[@"container"] isEqual:@"mp4"] || ![media[@"videoCodec"] isEqual:@"h264"] ||
            ![media[@"audioCodec"] isEqual:@"aac"] || [media[@"audioChannels"] intValue] > 2 ||
            width <= 0 || width > 1920 || height <= 0 || height > 1080 ||
            ![@[@"baseline", @"main", @"high"] containsObject:profile ?: @""] ||
            bytes <= 0 ||
            ![path hasPrefix:@"/library/parts/"]) continue;
        return path;
    }
    return nil;
}
