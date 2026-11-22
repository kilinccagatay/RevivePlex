#include "Localization.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <syslog.h>
#import "Playback.h"
#import "RangeStream.h"
#import "LiveLibrary.h"
#import "Artwork.h"

@interface RevivePlexPlaybackSession : NSObject
@property(nonatomic, strong) AVPlayer *player;
@property(nonatomic, strong) RevivePlexRangeStream *stream;
@property(nonatomic, strong) AVPlayerLayer *layer;
@property(nonatomic, strong) id endObserver;
@property(nonatomic, strong) id failureObserver;
@property(nonatomic) BOOL wantsPlayback;
@property(nonatomic, weak) CALayer *controls;
@property(nonatomic) float originalOpacity;
@property(nonatomic) NSUInteger controlsRevision;
@end

@implementation RevivePlexPlaybackSession
- (void)dealloc
{
    if (_endObserver) [[NSNotificationCenter defaultCenter] removeObserver:_endObserver];
    if (_failureObserver) [[NSNotificationCenter defaultCenter] removeObserver:_failureObserver];
    if (_controls) _controls.opacity = _originalOpacity;
    [_player pause];
    [_stream stop];
    [_layer removeFromSuperlayer];
}
@end

static char playbackKey;
static char systemSessionKey, systemEndedKey, systemSkipKey, systemStartedKey, systemFailureKey, systemTransportTouchedKey;
static char systemSeekKey, systemOptionsPendingKey;

@interface RevivePlexSeekState : NSObject
@property(nonatomic) double target;
@property(nonatomic) double origin;
@property(nonatomic) BOOL wantsPlayback;
@property(nonatomic) BOOL inFlight;
@property(nonatomic) NSUInteger revision;
@property(nonatomic) NSUInteger interruptions;
@property(nonatomic) BOOL showsFeedback;
@property(nonatomic) BOOL priming;
@end
@implementation RevivePlexSeekState
@end

static AVPlayer *underlyingSystemPlayer(id player)
{
    Ivar ivar = class_getInstanceVariable([player class], "_player");
    id value = ivar ? object_getIvar(player, ivar) : nil;
    return [value isKindOfClass:[AVPlayer class]] ? value : nil;
}

static void setSystemPlaybackRunning(id player, BOOL running)
{
    // Keep BackRow's state machine in agreement with its AVPlayer. Updating
    // AVPlayer.rate alone leaves the next native Select toggle out of phase.
    SEL state = NSSelectorFromString(@"setState:error:");
    NSError *error = nil;
    if ([player respondsToSelector:state] &&
        ((BOOL (*)(id, SEL, int, NSError **))objc_msgSend)(player, state, running ? 3 : 1, &error)) return;
    AVPlayer *native = underlyingSystemPlayer(player);
    if (running) [native play]; else [native pause];
}

static void finishQueuedSeek(id controller, RevivePlexSeekState *state);

static void completePreparedSeek(id controller, id player, AVPlayer *native,
                                 RevivePlexSeekState *state, double requested, BOOL prepared)
{
    if (!controller || objc_getAssociatedObject(controller, &systemSeekKey) != state ||
        !objc_getAssociatedObject(controller, &systemSessionKey)) return;
    state.inFlight = NO; state.priming = NO;
    if (fabs(state.target - requested) > 0.001 || (!prepared && state.interruptions++ < 2)) {
        finishQueuedSeek(controller, state); return;
    }
    double actual = CMTimeGetSeconds(native.currentTime);
    syslog(LOG_NOTICE, "RevivePlex: prepared seek requested=%.3f actual=%.3f prepared=%d resume=%d", requested, actual, prepared, state.wantsPlayback);
    if (state.showsFeedback) revivePlexShowSeekFeedback(controller, actual - state.origin, actual, CMTimeGetSeconds(native.currentItem.duration));
    // Let the native pause notification finish before restoring BackRow state.
    NSUInteger revision = state.revision;
    __weak id weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * (int64_t)NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        id active = weakController;
        if (!active || !objc_getAssociatedObject(active, &systemSessionKey) ||
            objc_getAssociatedObject(active, &systemSeekKey) != state || state.revision != revision) return;
        objc_setAssociatedObject(active, &systemSeekKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        setSystemPlaybackRunning(player, state.wantsPlayback);
    });
}

static void finishQueuedSeek(id controller, RevivePlexSeekState *state)
{
    if (objc_getAssociatedObject(controller, &systemSeekKey) != state ||
        !objc_getAssociatedObject(controller, &systemSessionKey) || state.inFlight) return;
    id player = ((id (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"player"));
    AVPlayer *native = underlyingSystemPlayer(player);
    if (native.currentItem.status != AVPlayerItemStatusReadyToPlay) {
        objc_setAssociatedObject(controller, &systemSeekKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    state.inFlight = YES;
    double requested = state.target;
    setSystemPlaybackRunning(player, NO);
    __weak id weakController = controller;
    [native seekToTime:CMTimeMakeWithSeconds(requested, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            id active = weakController;
            if (!active || objc_getAssociatedObject(active, &systemSeekKey) != state ||
                !objc_getAssociatedObject(active, &systemSessionKey)) return;
            state.inFlight = NO;
            if (fabs(state.target - requested) > 0.001) {
                finishQueuedSeek(active, state); return;
            }
            if (!finished && state.interruptions++ < 2) {
                // Native startup/state changes can interrupt an AVFoundation seek.
                // Retry within the same queue instead of losing the playback intent.
                finishQueuedSeek(active, state); return;
            }
            double actual = CMTimeGetSeconds(native.currentTime);
            syslog(LOG_NOTICE, "RevivePlex: queued precise seek requested=%.3f actual=%.3f completed=%d resume=%d", requested, actual, finished, state.wantsPlayback);
            if (finished && state.wantsPlayback && native.status == AVPlayerStatusReadyToPlay) {
                // Seek completion selects the time; preroll prepares both media
                // pipelines at that time before the clock is allowed to advance.
                state.inFlight = YES; state.priming = YES;
                [native prerollAtRate:1 completionHandler:^(BOOL prepared) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completePreparedSeek(weakController, player, native, state, requested, prepared);
                    });
                }];
            } else completePreparedSeek(active, player, native, state, requested, finished);
        });
    }];
}

static void queueSystemPosition(id controller, double value, BOOL relative, BOOL feedback)
{
    id player = ((id (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"player"));
    AVPlayer *native = underlyingSystemPlayer(player);
    double position = CMTimeGetSeconds(native.currentTime), duration = CMTimeGetSeconds(native.currentItem.duration);
    if (native.currentItem.status != AVPlayerItemStatusReadyToPlay || !isfinite(position) ||
        !isfinite(duration) || duration <= 0) return;
    RevivePlexSeekState *state = objc_getAssociatedObject(controller, &systemSeekKey);
    if (!state) {
        state = [RevivePlexSeekState new];
        state.origin = position; state.target = position; state.wantsPlayback = native.rate > 0;
        objc_setAssociatedObject(controller, &systemSeekKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        setSystemPlaybackRunning(player, NO);
    }
    state.target = MAX(0, MIN(MAX(0, duration - 0.05), relative ? state.target + value : value));
    if (state.priming) [native cancelPendingPrerolls];
    state.showsFeedback = feedback;
    state.interruptions = 0;
    NSUInteger revision = ++state.revision;
    if (feedback) revivePlexShowSeekFeedback(controller, state.target - state.origin, state.target, duration);
    __weak id weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (relative ? 400 : 0) * (int64_t)NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (weakController && state.revision == revision) finishQueuedSeek(weakController, state);
    });
}

// Start a precise resume through the shared queue once playback is ready.
// A user transport action takes priority over a delayed resume.
static void alignResumePosition(id controller, double target, NSUInteger attempts)
{
    if (!attempts || !objc_getAssociatedObject(controller, &systemSessionKey) ||
        objc_getAssociatedObject(controller, &systemTransportTouchedKey)) return;
    id player = ((id (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"player"));
    AVPlayer *native = underlyingSystemPlayer(player);
    if (native.currentItem.status != AVPlayerItemStatusReadyToPlay || native.rate <= 0) {
        __weak id weakController = controller;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * (int64_t)NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (weakController) alignResumePosition(weakController, target, attempts - 1);
        });
        return;
    }
    double before = CMTimeGetSeconds(native.currentTime);
    if (isfinite(before) && fabs(before - target) < 0.15) return;
    queueSystemPosition(controller, target, NO, NO);
}

void revivePlexFailPlaybackForProbe(id controller)
{
    id session = objc_getAssociatedObject(controller, &systemSessionKey);
    if (![revivePlexPlaybackMetadata(session)[@"diagnostic"] boolValue]) return;
    id player = ((id (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"player"));
    AVPlayer *native = underlyingSystemPlayer(player);
    if (!native) return;
    [native replaceCurrentItemWithPlayerItem:[AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:@"/var/mobile/Library/Caches/RevivePlex.missing-diagnostic-video"]]];
    [native play];
}

static BOOL handleSystemFailure(id controller, BOOL allowTimeout, BOOL forced)
{
    id session = objc_getAssociatedObject(controller, &systemSessionKey);
    if (!session) return NO;
    if (objc_getAssociatedObject(controller, &systemFailureKey)) return YES;
    id player = ((id (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"player"));
    AVPlayer *native = underlyingSystemPlayer(player);
    AVPlayerItem *item = native.currentItem;
    BOOL failed = forced || native.status == AVPlayerStatusFailed || item.status == AVPlayerItemStatusFailed;
    NSDate *started = objc_getAssociatedObject(controller, &systemStartedKey);
    BOOL timeout = allowTimeout && started && -[started timeIntervalSinceNow] >= 90 && item.status != AVPlayerItemStatusReadyToPlay;
    if (!failed && !timeout) return NO;
    SEL elapsed = NSSelectorFromString(@"elapsedTime");
    double position = [player respondsToSelector:elapsed] ? ((double (*)(id, SEL))objc_msgSend)(player, elapsed) : 0;
    if (!isfinite(position) || position < 0) position = 0;
    NSMutableDictionary *route = [revivePlexPlaybackOptionsRoute(session, position) mutableCopy];
    if (!route) return NO;
    route[@"playbackError"] = failed ? RPText(@"Video akışı oynatılamadı. Yeniden deneyebilir veya video kalitesini düşürebilirsin.") : RPText(@"Sunucu videoyu zamanında hazırlayamadı. Daha düşük kaliteyle yeniden deneyebilirsin.");
    objc_setAssociatedObject(controller, &systemFailureKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    syslog(LOG_NOTICE, "RevivePlex: native playback recovery failed=%d timeout=%d", failed, timeout);
    return revivePlexOpenPlaybackOptions(controller, route);
}

static void reportSystemProgress(id controller, NSString *override)
{
    id session = objc_getAssociatedObject(controller, &systemSessionKey);
    if (!session) return;
    id player = ((id (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"player"));
    SEL elapsed = NSSelectorFromString(@"elapsedTime"), duration = NSSelectorFromString(@"duration");
    SEL rate = NSSelectorFromString(@"rate");
    if (![player respondsToSelector:elapsed] || ![player respondsToSelector:duration] ||
        ![player respondsToSelector:rate]) return;
    double position = ((double (*)(id, SEL))objc_msgSend)(player, elapsed);
    if (!override && !objc_getAssociatedObject(controller, &systemSeekKey)) {
        double target = revivePlexPlaybackSkipTarget(session, position);
        revivePlexSetSkipHint(controller, target > 0 ? nil : revivePlexPlaybackSkipAction(session, position)[@"title"]);
        if (target > 0 &&
            [objc_getAssociatedObject(controller, &systemSkipKey) doubleValue] != target) {
            objc_setAssociatedObject(controller, &systemSkipKey, @(target), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            queueSystemPosition(controller, target, NO, YES);
        }
    }
    revivePlexReportProgress(session, position,
        ((double (*)(id, SEL))objc_msgSend)(player, duration),
        override ?: (((double (*)(id, SEL))objc_msgSend)(player, rate) > 0 ? @"playing" : @"paused"));
}

static void followTransportVisibility(id controller)
{
    __weak id weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * (int64_t)NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        id active = weakController;
        if (!active || !objc_getAssociatedObject(active, &systemSessionKey)) return;
        Ivar ivar = class_getInstanceVariable([active class], "_transport");
        id transport = ivar ? object_getIvar(active, ivar) : nil;
        BOOL visible = [transport isKindOfClass:[UIView class]] && [(UIView *)transport superview] != nil;
        for (UIView *view = visible ? transport : nil; view; view = view.superview) {
            if (view.hidden || view.alpha < 0.05 || view.layer.opacity < 0.05) visible = NO;
        }
        revivePlexSetOptionsHint(active, visible);
        followTransportVisibility(active);
    });
}

static void scheduleSystemProgress(id controller)
{
    __weak id weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        id active = weakController;
        if (!active || !objc_getAssociatedObject(active, &systemSessionKey)) return;
        if (handleSystemFailure(active, YES, NO)) return;
        reportSystemProgress(active, nil);
        scheduleSystemProgress(active);
    });
}

static void systemPlayerPopped(id self, SEL command)
{
    objc_setAssociatedObject(self, &systemSeekKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    revivePlexSetSkipHint(self, nil);
    revivePlexSetOptionsHint(self, NO);
    id session = objc_getAssociatedObject(self, &systemSessionKey);
    reportSystemProgress(self, @"stopped");
    objc_setAssociatedObject(self, &systemSessionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    struct objc_super parent = {self, NSClassFromString(@"BRMediaPlayerController")};
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&parent, command);
    revivePlexEndTranscode(session);
    syslog(LOG_NOTICE, "RevivePlex: system player closed");
}

static void systemPlayerEnded(id self, SEL command, id notification)
{
    if (handleSystemFailure(self, NO, NO)) return;
    id session = objc_getAssociatedObject(self, &systemSessionKey);
    if (!session || objc_getAssociatedObject(self, &systemEndedKey)) return;
    objc_setAssociatedObject(self, &systemEndedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    reportSystemProgress(self, @"stopped");
    void (^finish)(void) = ^{
        if (![objc_getAssociatedObject(self, &systemSessionKey) isEqual:session]) return;
        struct objc_super parent = {self, NSClassFromString(@"BRMediaPlayerController")};
        ((void (*)(struct objc_super *, SEL, id))objc_msgSendSuper)(&parent, command, notification);
    };
    revivePlexNextEpisode(session, ^(id path) {
        if (![objc_getAssociatedObject(self, &systemSessionKey) isEqual:session]) return;
        if (!path) { finish(); return; }
        id nextSession = [[NSUUID UUID] UUIDString];
        revivePlexContinueQueue(session, nextSession);
        revivePlexBeginTranscode(path, nextSession, ^(id url) {
            if (![objc_getAssociatedObject(self, &systemSessionKey) isEqual:session]) {
                revivePlexEndTranscode(nextSession); return;
            }
            id stack = ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"stack"));
            SEL peek = NSSelectorFromString(@"peekController");
            if (![stack respondsToSelector:peek] || ((id (*)(id, SEL))objc_msgSend)(stack, peek) != self) {
                revivePlexEndTranscode(nextSession); return;
            }
            if (url && revivePlexStartSystemHLS(self, url, 0, nextSession)) {
                syslog(LOG_NOTICE, "RevivePlex: autoplay advanced to next episode"); return;
            }
            revivePlexEndTranscode(nextSession);
            finish();
        });
    });
}

static void systemPlayerError(id self, SEL command, id notification)
{
    if (handleSystemFailure(self, NO, YES)) return;
    struct objc_super parent = {self, NSClassFromString(@"BRMediaPlayerController")};
    ((void (*)(struct objc_super *, SEL, id))objc_msgSendSuper)(&parent, command, notification);
}

static BOOL systemPlayerEvent(id self, SEL command, id event)
{
    SEL actionSelector = NSSelectorFromString(@"remoteAction"), valueSelector = NSSelectorFromString(@"value");
    if ([event respondsToSelector:actionSelector] && [event respondsToSelector:valueSelector]) {
        int action = ((int (*)(id, SEL))objc_msgSend)(event, actionSelector);
        id eventPlayer = ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"player"));
        AVPlayer *eventNative = underlyingSystemPlayer(eventPlayer);
        int eventValue = ((int (*)(id, SEL))objc_msgSend)(event, valueSelector);
        if (action == 1) objc_setAssociatedObject(self, &systemSeekKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (eventValue == 1) objc_setAssociatedObject(self, &systemTransportTouchedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        double eventTime = CMTimeGetSeconds(eventNative.currentTime);
        syslog(LOG_NOTICE, "RevivePlex: transport action=%d value=%d time=%.3f rate=%.2f", action, eventValue, eventTime, (double)eventNative.rate);
        if (eventValue == 1) {
            __weak id weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (!weakSelf || !objc_getAssociatedObject(weakSelf, &systemSessionKey)) return;
                AVPlayerItemAccessLogEvent *log = eventNative.currentItem.accessLog.events.lastObject;
                syslog(LOG_NOTICE, "RevivePlex: transport settled action=%d time=%.3f rate=%.2f dropped=%ld stalls=%ld", action,
                    CMTimeGetSeconds(eventNative.currentTime), (double)eventNative.rate, (long)log.numberOfDroppedVideoFrames, (long)log.numberOfStalls);
            });
        }

        if (action == 3) {
            id player = ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"player"));
            SEL elapsed = NSSelectorFromString(@"elapsedTime");
            if ([player respondsToSelector:elapsed]) {
                double position = ((double (*)(id, SEL))objc_msgSend)(player, elapsed);
                double target = [revivePlexPlaybackSkipAction(objc_getAssociatedObject(self, &systemSessionKey), position)[@"target"] doubleValue];
                if (target > 0) {
                    if (eventValue == 1) {
                        queueSystemPosition(self, target, NO, YES);
                        revivePlexSetSkipHint(self, nil);
                    }
                    return YES;
                }
            }
        }
        if (action == 6 || action == 7) {
            // Do not enter BackRow's trick-play path for HLS. Coalesce repeated
            // taps into serialized, sample-accurate seeks on the shared A/V player.
            if (eventValue == 1) queueSystemPosition(self, action == 7 ? 10 : -10, YES, YES);
            return YES;
        }
        RevivePlexSeekState *pending = objc_getAssociatedObject(self, &systemSeekKey);
        if ((action == 5 || action == 10) && pending) {
            if (eventValue == 1) pending.wantsPlayback = !pending.wantsPlayback;
            return YES;
        }
    }
    struct objc_super parent = {self, NSClassFromString(@"BRMediaPlayerController")};
    return ((BOOL (*)(struct objc_super *, SEL, id))objc_msgSendSuper)(&parent, command, event);
}

static void systemPlayerOptions(id self, SEL command)
{
    id player = ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"player"));
    SEL elapsed = NSSelectorFromString(@"elapsedTime");
    double position = [player respondsToSelector:elapsed] ? ((double (*)(id, SEL))objc_msgSend)(player, elapsed) : 0;
    id route = revivePlexPlaybackOptionsRoute(objc_getAssociatedObject(self, &systemSessionKey), position);
    if (route) {
        if (objc_getAssociatedObject(self, &systemOptionsPendingKey)) return;
        objc_setAssociatedObject(self, &systemOptionsPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Finish BackRow's held-Select event before replacing its controller.
        // Otherwise its remaining state transition can pop the new options page.
        dispatch_async(dispatch_get_main_queue(), ^{
            objc_setAssociatedObject(self, &systemOptionsPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (objc_getAssociatedObject(self, &systemSessionKey)) revivePlexOpenPlaybackOptions(self, route);
        });
        return;
    }
    struct objc_super parent = {self, NSClassFromString(@"BRMediaPlayerController")};
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&parent, command);
}

static char assetMetadataKey;
static id audioAssetType(id self, SEL command)
{
    (void)self; (void)command;
    return ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"BRMediaType"), NSSelectorFromString(@"song"));
}
static BOOL audioAssetHasVideo(id self, SEL command) { (void)self; (void)command; return NO; }
static id assetTitle(id self, SEL command) { (void)command; return objc_getAssociatedObject(self, &assetMetadataKey)[@"title"]; }
static id assetArtist(id self, SEL command) { (void)command; return objc_getAssociatedObject(self, &assetMetadataKey)[@"grandparentTitle"]; }
static id assetAlbum(id self, SEL command) { (void)command; return objc_getAssociatedObject(self, &assetMetadataKey)[@"parentTitle"]; }

BOOL revivePlexStartSystemHLS(id controller, id url, double resumeAt, id session)
{
    // Signatures and URL asset constructor verified in the device's 12H1006 binary.
    Class assetClass = NSClassFromString(@"RUIRetailMovieAsset");
    Class managerClass = NSClassFromString(@"BRMediaPlayerManager");
    Class base = NSClassFromString(@"BRMediaPlayerController");
    SEL initAsset = NSSelectorFromString(@"initWithMediaURL:");
    SEL singleton = NSSelectorFromString(@"singleton");
    SEL factory = NSSelectorFromString(@"playerForMediaAsset:error:");
    SEL initPlayer = NSSelectorFromString(@"initWithPlayer:");
    SEL swap = NSSelectorFromString(@"swapController:");
    if (!url || ![assetClass instancesRespondToSelector:initAsset] ||
        ![managerClass respondsToSelector:singleton] || ![base instancesRespondToSelector:initPlayer] ||
        ![controller respondsToSelector:NSSelectorFromString(@"stack")]) return NO;
    id stack = ((id (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"stack"));
    id manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, singleton);
    if (![stack respondsToSelector:swap] || ![manager respondsToSelector:factory]) return NO;
    Class playerControllerClass = NSClassFromString(@"RevivePlexSystemPlayerController");
    if (!playerControllerClass) {
        Method popped = class_getInstanceMethod(base, NSSelectorFromString(@"wasPopped"));
        if (!popped) return NO;
        playerControllerClass = objc_allocateClassPair(base, "RevivePlexSystemPlayerController", 0);
        if (!playerControllerClass) return NO;
        class_addMethod(playerControllerClass, NSSelectorFromString(@"wasPopped"),
            (IMP)systemPlayerPopped, method_getTypeEncoding(popped));
        Method ended = class_getInstanceMethod(base, NSSelectorFromString(@"_playerPlaybackEnded:"));
        if (ended) class_addMethod(playerControllerClass, NSSelectorFromString(@"_playerPlaybackEnded:"),
            (IMP)systemPlayerEnded, method_getTypeEncoding(ended));
        for (NSString *name in @[@"_playerError:", @"_enterErrorStateWithError:", @"stopWithError:"]) {
            SEL selector = NSSelectorFromString(name);
            Method failure = class_getInstanceMethod(base, selector);
            if (failure) class_addMethod(playerControllerClass, selector,
                (IMP)systemPlayerError, method_getTypeEncoding(failure));
        }
        SEL optionsSelector = NSSelectorFromString(@"_enterChaptersSubtitlesAndAlternateAudioPickingState");
        Method optionsMethod = class_getInstanceMethod(base, optionsSelector);
        if (optionsMethod) class_addMethod(playerControllerClass, optionsSelector, (IMP)systemPlayerOptions, method_getTypeEncoding(optionsMethod));
        Method event = class_getInstanceMethod(base, NSSelectorFromString(@"brEventAction:"));
        if (event) class_addMethod(playerControllerClass, NSSelectorFromString(@"brEventAction:"),
            (IMP)systemPlayerEvent, method_getTypeEncoding(event));
        objc_registerClassPair(playerControllerClass);
    }
    NSDictionary *metadata = revivePlexPlaybackMetadata(session);
    if ([metadata[@"type"] isEqual:@"track"]) {
        Class audioAsset = NSClassFromString(@"RevivePlexAudioAsset");
        if (!audioAsset) {
            Class mediaType = NSClassFromString(@"BRMediaType");
            if (![mediaType respondsToSelector:NSSelectorFromString(@"song")]) return NO;
            audioAsset = objc_allocateClassPair(assetClass, "RevivePlexAudioAsset", 0);
            if (!audioAsset) return NO;
            class_addMethod(audioAsset, NSSelectorFromString(@"mediaType"), (IMP)audioAssetType, "@@:");
            class_addMethod(audioAsset, NSSelectorFromString(@"hasVideoContent"), (IMP)audioAssetHasVideo, "c@:");
            class_addMethod(audioAsset, NSSelectorFromString(@"title"), (IMP)assetTitle, "@@:");
            class_addMethod(audioAsset, NSSelectorFromString(@"artist"), (IMP)assetArtist, "@@:");
            class_addMethod(audioAsset, NSSelectorFromString(@"album"), (IMP)assetAlbum, "@@:");
            objc_registerClassPair(audioAsset);
        }
        assetClass = audioAsset;
    }
    else {
        Class videoAsset = NSClassFromString(@"RevivePlexVideoAsset");
        if (!videoAsset) {
            videoAsset = objc_allocateClassPair(assetClass, "RevivePlexVideoAsset", 0);
            if (!videoAsset) return NO;
            class_addMethod(videoAsset, NSSelectorFromString(@"title"), (IMP)assetTitle, "@@:");
            objc_registerClassPair(videoAsset);
        }
        assetClass = videoAsset;
    }
    id asset = ((id (*)(id, SEL, id))objc_msgSend)([assetClass alloc], initAsset, url);
    objc_setAssociatedObject(asset, &assetMetadataKey, metadata, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSError *error = nil;
    id player = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(manager, factory, asset, &error);
    if (!player || error) {
        syslog(LOG_NOTICE, "RevivePlex: system player unavailable error=%ld", (long)error.code);
        return NO;
    }
    id native = ((id (*)(id, SEL, id))objc_msgSend)([playerControllerClass alloc], initPlayer, player);
    if (!native) return NO;
    // Resume uses the same serialized AVPlayer seek as transport and markers.
    // Do not also schedule BackRow's independent startup seek.
    SEL stop = NSSelectorFromString(@"setAlwaysStopPlaybackWhenPopped:");
    if ([native respondsToSelector:stop]) ((void (*)(id, SEL, BOOL))objc_msgSend)(native, stop, YES);
    objc_setAssociatedObject(native, &systemSessionKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(native, &systemStartedKey, [NSDate date], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, id))objc_msgSend)(stack, swap, native);
    if (resumeAt > 0 && isfinite(resumeAt)) alignResumePosition(native, resumeAt, 600);
    scheduleSystemProgress(native);
    followTransportVisibility(native);
    syslog(LOG_NOTICE, "RevivePlex: system player presented");
    __weak id weakNative = native;
    for (NSNumber *delayValue in @[@3, @9, @30]) {
        int delay = [delayValue intValue];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            id active = weakNative;
            if (!active || !objc_getAssociatedObject(active, &systemSessionKey)) return;
            SEL elapsed = NSSelectorFromString(@"elapsedTime");
            SEL state = NSSelectorFromString(@"playerState");
            if ([player respondsToSelector:elapsed] && [player respondsToSelector:state])
                syslog(LOG_NOTICE, "RevivePlex: system player state=%d position=%.2f",
                    ((int (*)(id, SEL))objc_msgSend)(player, state),
                    ((double (*)(id, SEL))objc_msgSend)(player, elapsed));
            Ivar playerIvar = class_getInstanceVariable([player class], "_player");
            id underlying = playerIvar ? object_getIvar(player, playerIvar) : nil;
            if ([underlying isKindOfClass:[AVPlayer class]]) {
                AVPlayerItem *item = [(AVPlayer *)underlying currentItem];
                syslog(LOG_NOTICE, "RevivePlex: native AV item status=%ld error=%ld rate=%.2f",
                    (long)item.status, (long)item.error.code, (double)[(AVPlayer *)underlying rate]);
                AVAudioSession *audio = [NSClassFromString(@"AVAudioSession") sharedInstance];
                NSMutableArray *ports = [NSMutableArray array];
                for (AVAudioSessionPortDescription *port in audio.currentRoute.outputs) [ports addObject:port.portType ?: @"unknown"];
                syslog(LOG_NOTICE, "RevivePlex: native audio route=%s sampleRate=%.0f outputLatency=%.4f ioBuffer=%.4f channels=%lu",
                    [[ports componentsJoinedByString:@","] UTF8String], audio.sampleRate, audio.outputLatency,
                    audio.IOBufferDuration, (unsigned long)audio.outputNumberOfChannels);
                AVPlayerItemAccessLogEvent *access = item.accessLog.events.lastObject;
                syslog(LOG_NOTICE, "RevivePlex: native playback health dropped=%ld stalls=%ld observedBitrate=%.0f indicatedBitrate=%.0f",
                    (long)access.numberOfDroppedVideoFrames, (long)access.numberOfStalls,
                    access.observedBitrate, access.indicatedBitrate);
            }
            SEL visualsSelector = NSSelectorFromString(@"visuals");
            if ([player respondsToSelector:visualsSelector]) {
                id visuals = ((id (*)(id, SEL))objc_msgSend)(player, visualsSelector);
                syslog(LOG_NOTICE, "RevivePlex: system video surface class=%s", class_getName([visuals class]));
                if ([visuals isKindOfClass:[UIView class]]) {
                    UIView *surface = visuals;
                    syslog(LOG_NOTICE, "RevivePlex: system video surface width=%.0f height=%.0f attached=%d hidden=%d",
                        (double)surface.bounds.size.width, (double)surface.bounds.size.height,
                        surface.window != nil, surface.hidden);
                }
            }
        });
    }
    return YES;
}

static void status(id controller, NSString *text)
{
    if ([controller respondsToSelector:@selector(setListTitle:)])
        ((void (*)(id, SEL, id))objc_msgSend)(controller, @selector(setListTitle:), text);
}

static void showControls(RevivePlexPlaybackSession *session)
{
    if (!session.controls) return;
    NSUInteger revision = ++session.controlsRevision;
    session.controls.opacity = session.originalOpacity;
    __weak RevivePlexPlaybackSession *weakSession = session;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * (int64_t)NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
        RevivePlexPlaybackSession *active = weakSession;
        if (active && active.controlsRevision == revision && active.wantsPlayback)
            active.controls.opacity = 0.0f;
    });
}

BOOL revivePlexRevealPlaybackControls(id controller)
{
    RevivePlexPlaybackSession *session = objc_getAssociatedObject(controller, &playbackKey);
    BOOL wasHidden = session.controls && session.controls.opacity == 0.0f;
    showControls(session);
    return wasHidden;
}

NSURL *revivePlexPlaybackFixture(void)
{
    Dl_info info;
    if (!dladdr(&playbackKey, &info) || !info.dli_fname) return nil;
    NSString *binary = [NSString stringWithUTF8String:info.dli_fname];
    NSString *path = [[binary stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"PlaybackTest.mp4"];
    return [[NSFileManager defaultManager] isReadableFileAtPath:path] ? [NSURL fileURLWithPath:path] : nil;
}

static BOOL startAsset(id controller, AVPlayerItem *item, RevivePlexRangeStream *stream, double resumeAt)
{
    if (!item || ![controller respondsToSelector:@selector(layer)]) {
        status(controller, RPText(@"Video kaynağı açılamadı"));
        return NO;
    }
    CALayer *surface = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(layer));
    if (!surface) return NO;
    UIView *host = [controller isKindOfClass:[UIView class]] ? controller : nil;
    UIWindow *window = host.window;
    CGRect bounds = window ? [surface convertRect:window.layer.bounds fromLayer:window.layer] : surface.bounds;
    if (CGRectGetWidth(bounds) < 100 || CGRectGetHeight(bounds) < 100) {
        status(controller, RPText(@"Video alanı hazır değil"));
        return NO;
    }

    revivePlexStopPlayback(controller);
    RevivePlexPlaybackSession *session = [RevivePlexPlaybackSession new];
    session.stream = stream;
    session.player = [AVPlayer playerWithPlayerItem:item];
    session.layer = [AVPlayerLayer playerLayerWithPlayer:session.player];
    session.layer.videoGravity = AVLayerVideoGravityResizeAspect;
    session.layer.backgroundColor = [UIColor blackColor].CGColor;
    session.layer.frame = bounds;
    id list = [controller respondsToSelector:@selector(list)] ?
        ((id (*)(id, SEL))objc_msgSend)(controller, @selector(list)) : nil;
    CALayer *controls = [list respondsToSelector:@selector(layer)] ?
        ((id (*)(id, SEL))objc_msgSend)(list, @selector(layer)) : nil;
    CALayer *anchor = controls;
    while (anchor.superlayer && anchor.superlayer != surface) anchor = anchor.superlayer;
    if (anchor.superlayer == surface) {
        session.controls = controls;
        session.originalOpacity = controls.opacity;
        [surface insertSublayer:session.layer below:anchor];
    } else {
        [surface addSublayer:session.layer];
    }

    __weak id menu = controller;
    __weak RevivePlexPlaybackSession *attached = session;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    session.endObserver = [center addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
        object:session.player.currentItem queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        (void)note;
        attached.wantsPlayback = NO;
        showControls(attached);
        status(menu, RPText(@"Video bitti"));
        syslog(LOG_NOTICE, "RevivePlex: native playback reached end");
    }];
    session.failureObserver = [center addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification
        object:session.player.currentItem queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        (void)note;
        attached.wantsPlayback = NO;
        showControls(attached);
        status(menu, RPText(@"Video oynatılamadı"));
        syslog(LOG_NOTICE, "RevivePlex: native playback failed");
    }];
    objc_setAssociatedObject(controller, &playbackKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    session.wantsPlayback = YES;
    if (resumeAt > 0 && isfinite(resumeAt))
        [session.player seekToTime:CMTimeMakeWithSeconds(resumeAt, 600)];
    [session.player play];
    showControls(session);
    status(controller, RPText(@"Oynatılıyor"));
    syslog(LOG_NOTICE, "RevivePlex: native playback requested, surface=%.0fx%.0f window=%d",
        CGRectGetWidth(bounds), CGRectGetHeight(bounds), window != nil);
    for (int delay = 2; delay <= 6; delay += 4) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay * NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{
            RevivePlexPlaybackSession *active = attached;
            id currentMenu = menu;
            if (!active || !currentMenu) return;
            AVPlayerItem *item = active.player.currentItem;
            double current = CMTimeGetSeconds(active.player.currentTime);
            double duration = CMTimeGetSeconds(item.duration);
            syslog(LOG_NOTICE, "RevivePlex: player item=%ld error=%ld position=%.2f duration=%.2f video=%d",
                (long)item.status, (long)item.error.code, current, duration, active.layer.readyForDisplay);
            if (item.status == AVPlayerItemStatusFailed) status(currentMenu, RPText(@"Video oynatılamadı"));
        });
    }
    return YES;
}

BOOL revivePlexStartPlayback(id controller, NSURL *file)
{
    return startAsset(controller, file.isFileURL ? [AVPlayerItem playerItemWithURL:file] : nil, nil, 0);
}

BOOL revivePlexStartStream(id controller, id request, double resumeAt)
{
    RevivePlexRangeStream *stream = [[RevivePlexRangeStream alloc] initWithRequest:request];
    AVPlayerItem *item = stream ? [AVPlayerItem playerItemWithAsset:stream.asset] : nil;
    BOOL started = startAsset(controller, item, stream, resumeAt);
    if (!started) [stream stop];
    return started;
}

BOOL revivePlexStartHLS(id controller, id url, double resumeAt)
{
    NSURL *playlist = url;
    return startAsset(controller, playlist ? [AVPlayerItem playerItemWithURL:playlist] : nil, nil, resumeAt);
}

void revivePlexToggleVideoFit(id controller)
{
    RevivePlexPlaybackSession *session = objc_getAssociatedObject(controller, &playbackKey);
    if (!session) return;
    BOOL fill = [session.layer.videoGravity isEqual:AVLayerVideoGravityResizeAspect];
    session.layer.videoGravity = fill ? AVLayerVideoGravityResizeAspectFill : AVLayerVideoGravityResizeAspect;
    status(controller, fill ? RPText(@"Ekranı doldur") : RPText(@"Görüntüyü sığdır"));
    showControls(session);
}

void revivePlexTogglePlayback(id controller)
{
    RevivePlexPlaybackSession *session = objc_getAssociatedObject(controller, &playbackKey);
    if (!session) return;
    session.wantsPlayback = !session.wantsPlayback;
    if (session.wantsPlayback) {
        double position = CMTimeGetSeconds(session.player.currentTime);
        double duration = CMTimeGetSeconds(session.player.currentItem.duration);
        if (duration > 0 && position >= duration) [session.player seekToTime:kCMTimeZero];
        [session.player play];
    } else {
        [session.player pause];
    }
    showControls(session);
    status(controller, session.wantsPlayback ? RPText(@"Oynatılıyor") : RPText(@"Duraklatıldı"));
}

void revivePlexSeekPlayback(id controller, double seconds)
{
    RevivePlexPlaybackSession *session = objc_getAssociatedObject(controller, &playbackKey);
    if (!session) return;
    double position = CMTimeGetSeconds(session.player.currentTime);
    double duration = CMTimeGetSeconds(session.player.currentItem.duration);
    if (!(position >= 0) || !(duration > 0) || !isfinite(duration)) return;
    [session.player seekToTime:CMTimeMakeWithSeconds(MAX(0, MIN(duration, position + seconds)), 600)];
}

void revivePlexStopPlayback(id controller)
{
    objc_setAssociatedObject(controller, &playbackKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void revivePlexCycleTrack(id controller, BOOL subtitles)
{
    RevivePlexPlaybackSession *session = objc_getAssociatedObject(controller, &playbackKey);
    AVPlayerItem *item = session.player.currentItem;
    if (!item) return;
    NSString *kind = subtitles ? AVMediaCharacteristicLegible : AVMediaCharacteristicAudible;
    __weak id menu = controller;
    __weak RevivePlexPlaybackSession *expected = session;
    [item.asset loadValuesAsynchronouslyForKeys:@[@"availableMediaCharacteristicsWithMediaSelectionOptions"]
        completionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            id current = menu;
            RevivePlexPlaybackSession *active = expected;
            if (!current || !active || objc_getAssociatedObject(current, &playbackKey) != active) return;
            AVMediaSelectionGroup *group = [item.asset mediaSelectionGroupForMediaCharacteristic:kind];
            NSArray *options = group.options;
            if (!options.count) {
                status(current, subtitles ? RPText(@"Gömülü altyazı yok") : RPText(@"Ek ses parçası yok"));
                return;
            }
            AVMediaSelectionOption *previous = [item selectedMediaOptionInMediaSelectionGroup:group];
            NSUInteger index = [options indexOfObjectIdenticalTo:previous];
            AVMediaSelectionOption *next = nil;
            if (index == NSNotFound) next = options.firstObject;
            else if (index + 1 < options.count) next = options[index + 1];
            else if (!group.allowsEmptySelection || !subtitles) next = options.firstObject;
            [item selectMediaOption:next inMediaSelectionGroup:group];
            status(current, next.displayName ?: RPText(@"Altyazı kapalı"));
        });
    }];
}
