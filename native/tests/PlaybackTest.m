#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "../src/Playback.h"
#import "../src/DirectPlay.h"
#import "../src/RangeStream.h"

@interface PlaybackHost : NSObject
@property(nonatomic, strong) CALayer *layer;
@property(nonatomic, copy) NSString *listTitle;
@end
@implementation PlaybackHost
@end

int main(int argc, const char **argv)
{
    @autoreleasepool {
        if (argc != 2) return 1;
        long long start, end, total;
        if (!revivePlexParseContentRange(@"bytes 512-1023/4294967296", &start, &end, &total) ||
            start != 512 || end != 1023 || total != 4294967296LL ||
            revivePlexParseContentRange(@"bytes 1024-1023/2048", &start, &end, &total) ||
            revivePlexParseContentRange(@"bytes 0-2048/2048", &start, &end, &total)) return 8;
        NSDictionary *media = @{@"container": @"mp4", @"videoCodec": @"h264", @"videoProfile": @"main",
            @"audioCodec": @"aac", @"audioChannels": @"2", @"width": @"1280", @"height": @"720"};
        NSDictionary *part = @{@"key": @"/library/parts/1/file.mp4", @"size": @"1608809646"};
        if (![revivePlexCompatiblePart(@[@{@"media": media, @"part": part}]) isEqual:part[@"key"]]) return 2;
        NSMutableDictionary *unsupported = [media mutableCopy];
        unsupported[@"videoCodec"] = @"hevc";
        if (revivePlexCompatiblePart(@[@{@"media": unsupported, @"part": part}])) return 3;

        PlaybackHost *host = [PlaybackHost new];
        host.layer = [CALayer layer];
        host.layer.bounds = CGRectMake(0, 0, 1280, 720);
        NSURL *video = [NSURL fileURLWithPath:@(argv[1])];
        if (!revivePlexStartPlayback(host, video) || host.layer.sublayers.count != 1) return 4;
        revivePlexTogglePlayback(host);
        if (![host.listTitle isEqual:@"Duraklatıldı"]) return 5;
        revivePlexTogglePlayback(host);
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
        while ([host.listTitle isEqual:@"Oynatılıyor"] && [deadline timeIntervalSinceNow] > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        if (![host.listTitle isEqual:@"Video bitti"]) return 6;
        revivePlexStopPlayback(host);
        if (host.layer.sublayers.count) return 7;
        puts("AVPlayer played the H.264 fixture through end; pause, resume and teardown passed.");
    }
    return 0;
}
