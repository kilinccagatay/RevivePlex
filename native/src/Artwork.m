#include "Localization.h"
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#include <syslog.h>
#include <dlfcn.h>
#import "Artwork.h"
#import "LiveLibrary.h"

static char posterTaskKey, posterViewKey, posterPathKey, posterTitleKey;
static char posterPanelKey, posterImageKey, posterLabelKey, imageRequestKey;
static const NSUInteger responseLimit = 8 * 1024 * 1024;

#ifdef REVIVEPLEX_DEMO_SCREENSHOTS
static UIImage *demoArtwork(NSNumber *seed)
{
    if (!seed) return nil;
    CGFloat phase = seed.floatValue * 0.071;
    UIView *canvas = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 560, 840)];
    canvas.backgroundColor = [UIColor colorWithHue:phase saturation:0.50 brightness:0.32 alpha:1];
    for (int i = 0; i < 5; i++) {
        UIView *shape = [[UIView alloc] initWithFrame:CGRectMake(35 + i * 85, 140 + i * 90, 290, 290)];
        shape.backgroundColor = [UIColor colorWithHue:phase + i * 0.035 saturation:0.46 brightness:0.90 alpha:0.72];
        shape.layer.cornerRadius = 145;
        [canvas addSubview:shape];
    }
    UIGraphicsBeginImageContextWithOptions(canvas.bounds.size, YES, 1);
    [canvas.layer renderInContext:UIGraphicsGetCurrentContext()];
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}
#endif

static void setArtworkImage(UIImageView *view, UIImage *image)
{
    if (view.contentMode == UIViewContentModeScaleAspectFit && view.tag != 901 && image.size.width > 0 && image.size.height > 0) {
        CGRect bounds = view.superview.bounds;
        CGFloat scale = MIN(bounds.size.width / image.size.width, bounds.size.height / image.size.height);
        CGFloat width = image.size.width * scale, height = image.size.height * scale;
        view.frame = CGRectMake((bounds.size.width - width) / 2, (bounds.size.height - height) / 2, width, height);
    }
    view.image = image;
}

@interface RevivePlexPosterTransfer : NSObject <NSURLSessionDataDelegate>
@property(nonatomic, strong) NSMutableData *data;
@property(nonatomic, weak) UIImageView *view;
@property(nonatomic, strong) NSCache *cache;
@property(nonatomic, strong) NSURL *key;
@property(nonatomic) NSUInteger maximumPixels;
@end

@implementation RevivePlexPosterTransfer
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
    (void)session; (void)task;
    BOOL accepted = [(NSHTTPURLResponse *)response statusCode] == 200 &&
        response.expectedContentLength <= (int64_t)responseLimit;
    complete(accepted ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data
{
    (void)session;
    if (data.length > responseLimit - self.data.length) [task cancel];
    else [self.data appendData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    (void)task;
    if (!error && self.view && self.data.length) {
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)self.data, NULL);
        if (source) {
            NSDictionary *limits = @{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                                     (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(self.maximumPixels),
                                     (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES};
            CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)limits);
            if (thumbnail) {
                UIImage *image = [UIImage imageWithCGImage:thumbnail];
                syslog(LOG_NOTICE, "RevivePlex: Plex poster decoded");
                [self.cache setObject:image forKey:self.key cost:CGImageGetBytesPerRow(thumbnail) * CGImageGetHeight(thumbnail)];
                __weak UIImageView *view = self.view;
                NSURL *key = self.key;
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIImageView *target = view;
                    if (target && [objc_getAssociatedObject(target, &imageRequestKey) isEqual:key])
                        setArtworkImage(target, image);
                });
                CGImageRelease(thumbnail);
            }
            CFRelease(source);
        }
    }
    [session finishTasksAndInvalidate];
}
@end

static NSURLSessionTask *loadImage(NSURLRequest *request, UIImageView *imageView)
{
    static NSCache *cache;
    if (!cache) {
        cache = [NSCache new];
        cache.countLimit = 16;
        cache.totalCostLimit = 4 * 1024 * 1024;
    }
    objc_setAssociatedObject(imageView, &imageRequestKey, request.URL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIImage *cached = [cache objectForKey:request.URL];
    if (cached) {
        setArtworkImage(imageView, cached);
        return nil;
    }
    RevivePlexPosterTransfer *transfer = [RevivePlexPosterTransfer new];
    transfer.view = imageView;
    transfer.maximumPixels = MIN(1920, MAX(384, MAX(imageView.bounds.size.width, imageView.bounds.size.height)));
    transfer.data = [NSMutableData data];
    transfer.cache = cache;
    transfer.key = request.URL;
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForResource = 10;
    config.HTTPShouldSetCookies = NO;
    config.URLCredentialStorage = nil;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:transfer delegateQueue:nil];
    NSURLSessionTask *task = [session dataTaskWithRequest:request];
    [task resume];
    return task;
}

void revivePlexCancelPoster(id menu)
{
    [objc_getAssociatedObject(menu, &posterTaskKey) cancel];
    objc_setAssociatedObject(menu, &posterTaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [objc_getAssociatedObject(menu, &posterViewKey) removeFromSuperview];
    objc_setAssociatedObject(menu, &posterViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(menu, &posterPathKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(menu, &posterTitleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(menu, &posterPanelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(menu, &posterImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(menu, &posterLabelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CGRect visualFrame(CGFloat height, CGFloat x, CGFloat y, CGFloat width, CGFloat itemHeight)
{
    return CGRectMake(x, height - y - itemHeight, width, itemHeight);
}

static UIImageView *renderedText(CGRect frame, NSString *text, CGFloat size, BOOL bold, NSInteger centered, UIColor *color, BOOL wrap)
{
    UIImageView *view = [[UIImageView alloc] initWithFrame:frame];
    size_t width = (size_t)MAX(1.0, ceil(CGRectGetWidth(frame)));
    size_t height = (size_t)MAX(1.0, ceil(CGRectGetHeight(frame)));
    if (!text.length || width > 2048 || height > 1080 || width * height > 2211840) return view;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return view;

    CTFontRef font = CTFontCreateWithName(bold ? CFSTR("HelveticaNeue-Medium") : CFSTR("HelveticaNeue"),
                                         size, NULL);
    UIColor *ink = color ?: [UIColor colorWithWhite:0.94 alpha:1];
    NSDictionary *attributes = @{(__bridge NSString *)kCTFontAttributeName: (__bridge id)font,
        (__bridge NSString *)kCTForegroundColorAttributeName: (__bridge id)ink.CGColor};
    NSAttributedString *styled = [[NSAttributedString alloc] initWithString:text attributes:attributes];
    NSAttributedString *ellipsis = [[NSAttributedString alloc] initWithString:@"…" attributes:attributes];
    CTTypesetterRef typesetter = wrap ? CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)styled) : NULL;
    // Measure actual font ascenders/descenders; point size is not a line box.
    CTLineRef metrics = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)styled);
    CGFloat fontAscent = 0, fontDescent = 0, leading = 0;
    CTLineGetTypographicBounds(metrics, &fontAscent, &fontDescent, &leading);
    CFRelease(metrics);
    CGFloat lineHeight = ceilf(fontAscent + fontDescent + MAX(leading, size * 0.08));
    CGFloat padding = 1;
    NSUInteger lines = wrap ? MAX(1, (NSUInteger)MAX(0, (1 + (height - 2 * padding - fontAscent - fontDescent) / lineHeight))) : 1;
    CFIndex start = 0;
    CTLineRef token = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)ellipsis);
    for (NSUInteger index = 0; index < lines && start < (CFIndex)styled.length; index++) {
        CFIndex length = typesetter ? CTTypesetterSuggestLineBreak(typesetter, start, width) : (CFIndex)styled.length;
        if (length <= 0) break;
        BOOL last = index + 1 == lines;
        NSRange range = NSMakeRange(start, last ? styled.length - start : length);
        NSAttributedString *portion = [styled attributedSubstringFromRange:range];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)portion);
        CTLineRef truncated = last ? CTLineCreateTruncatedLine(line, (double)width, kCTLineTruncationEnd, token) : NULL;
        CTLineRef draw = truncated ?: line;
        CGFloat ascent = 0, descent = 0;
        double textWidth = CTLineGetTypographicBounds(draw, &ascent, &descent, NULL);
        if (centered) textWidth -= CTLineGetTrailingWhitespaceWidth(draw);
        CGFloat baseline = wrap ? height - padding - fontAscent - index * lineHeight
            : MAX(0, (height - ascent - descent) / 2) + descent;
        baseline = MAX(descent + padding, MIN(height - ascent - padding, baseline));
        CGContextSetTextPosition(context, centered ? MAX(0, (width - textWidth) / (centered == 2 ? 1 : 2)) : 0, baseline);
        CTLineDraw(draw, context);
        if (truncated) CFRelease(truncated);
        CFRelease(line);
        start += length;
    }
    if (typesetter) CFRelease(typesetter);
    CGImageRef image = CGBitmapContextCreateImage(context);
    if (image) {
        view.image = [UIImage imageWithCGImage:image];
        CGImageRelease(image);
    }
    CFRelease(token);
    CFRelease(font);
    CGContextRelease(context);
    return view;
}

static UIImageView *renderedLabel(CGRect frame, NSString *text, CGFloat size, BOOL bold, BOOL centered, UIColor *color)
{
    return renderedText(frame, text, size, bold, centered, color, NO);
}

static UIImageView *buttonText(CGRect frame, NSString *text, CGFloat size)
{
    CTFontRef font = CTFontCreateWithName(CFSTR("HelveticaNeue-Medium"), size, NULL);
    NSAttributedString *styled = [[NSAttributedString alloc] initWithString:text ?: @"" attributes:@{(__bridge NSString *)kCTFontAttributeName:(__bridge id)font}];
    CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)styled);
    CFIndex first = CTTypesetterSuggestLineBreak(typesetter, 0, frame.size.width);
    CGFloat textHeight = frame.size.height;
    frame.origin.y += (frame.size.height - textHeight) / 2;
    frame.size.height = textHeight;
    CFRelease(typesetter); CFRelease(font);
    return renderedText(frame, text, size, YES, NO, nil, first < (CFIndex)styled.length);
}

// A UIView-backed layer still exposes its UIView delegate to BackRow's
// control traversal, even when attached with addSublayer:. Rasterize temporary
// views and attach only a delegate-free layer to the native player.
static CALayer *playerOverlay(UIView *drawing)
{
    UIGraphicsBeginImageContextWithOptions(drawing.bounds.size, NO, 1);
    [drawing.layer renderInContext:UIGraphicsGetCurrentContext()];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!image) return nil;
    CALayer *layer = [NSClassFromString(@"CALayer") layer];
    layer.frame = drawing.frame;
    layer.contents = (__bridge id)image.CGImage;
    layer.zPosition = drawing.layer.zPosition;
    return layer;
}

static char skipHintKey, skipHintTitleKey;
void revivePlexSetSkipHint(id controller, id title)
{
    if (![controller isKindOfClass:[UIView class]]) return;
    UIView *host = controller;
    id previousTitle = objc_getAssociatedObject(controller, &skipHintTitleKey);
    if ((!previousTitle && !title) || [previousTitle isEqual:title]) return;
    objc_setAssociatedObject(controller, &skipHintTitleKey, title, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CALayer *previous = objc_getAssociatedObject(controller, &skipHintKey);
    [previous removeFromSuperlayer];
    objc_setAssociatedObject(controller, &skipHintKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (![title length] || host.bounds.size.width < 400) return;
    CGFloat width = host.bounds.size.width, height = host.bounds.size.height;
    UIView *hint = [[UIView alloc] initWithFrame:visualFrame(height, width * 0.72, height * 0.83, width * 0.23, height * 0.065)];
    hint.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
    hint.layer.cornerRadius = 8; hint.layer.zPosition = 1100;
    [hint addSubview:renderedLabel(hint.bounds, title, height * 0.025, YES, YES, nil)];
    CALayer *overlay = playerOverlay(hint);
    if (overlay) [host.layer addSublayer:overlay];
    objc_setAssociatedObject(controller, &skipHintKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static char optionsHintKey;
void revivePlexSetOptionsHint(id controller, signed char visible)
{
    if (![controller isKindOfClass:[UIView class]]) return;
    UIView *host = controller;
    CALayer *existing = objc_getAssociatedObject(controller, &optionsHintKey);
    if (!visible) {
        [existing removeFromSuperlayer];
        objc_setAssociatedObject(controller, &optionsHintKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (existing || host.bounds.size.width < 400) return;
    CGFloat w = host.bounds.size.width, h = host.bounds.size.height;
    UIView *bubble = [[UIView alloc] initWithFrame:visualFrame(h, w * 0.60, h * 0.065, w * 0.345, h * 0.09)];
    bubble.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
    bubble.layer.cornerRadius = 12; bubble.layer.zPosition = 1100;
    [bubble addSubview:renderedLabel(CGRectMake(h * 0.015, h * 0.01, w * 0.345 - h * 0.03, h * 0.07),
        RPText(@"Seçenekler için “Select”i basılı tut"), h * 0.024, YES, YES, nil)];
    CALayer *overlay = playerOverlay(bubble);
    if (overlay) [host.layer addSublayer:overlay];
    objc_setAssociatedObject(controller, &optionsHintKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static char seekFeedbackKey;
static NSString *playbackClock(double value)
{
    long seconds = (long)MAX(0, value);
    return seconds >= 3600 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", seconds / 3600, (seconds / 60) % 60, seconds % 60]
        : [NSString stringWithFormat:@"%02ld:%02ld", seconds / 60, seconds % 60];
}

void revivePlexShowSeekFeedback(id controller, double delta, double position, double duration)
{
    if (![controller isKindOfClass:[UIView class]] || !isfinite(position) || !isfinite(duration) || duration <= 0) return;
    UIView *host = controller;
    CALayer *previous = objc_getAssociatedObject(controller, &seekFeedbackKey);
    [previous removeFromSuperlayer];
    CGFloat width = host.bounds.size.width, height = host.bounds.size.height;
    UIView *hud = [[UIView alloc] initWithFrame:visualFrame(height, width * 0.30, height * 0.70, width * 0.40, height * 0.09)];
    hud.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.94];
    hud.layer.cornerRadius = 10; hud.layer.zPosition = 1101;
    NSString *label = [NSString stringWithFormat:@"%@%@   ·   %@ / %@", delta < 0 ? @"−" : @"+", playbackClock(fabs(delta)), playbackClock(position), playbackClock(duration)];
    [hud addSubview:renderedLabel(hud.bounds, label, height * 0.028, YES, YES, nil)];
    CALayer *overlay = playerOverlay(hud);
    if (overlay) [host.layer addSublayer:overlay];
    objc_setAssociatedObject(controller, &seekFeedbackKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (objc_getAssociatedObject(controller, &seekFeedbackKey) != overlay) return;
        [overlay removeFromSuperlayer];
        objc_setAssociatedObject(controller, &seekFeedbackKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

void revivePlexWithoutTransitionAnimation(void (^transition)(void))
{
    // BRControllerStack checks CATransaction's disable-actions flag before
    // building its own snapshot transition; UIKit's flag alone is insufficient.
    Class transaction = NSClassFromString(@"CATransaction");
    [transaction begin];
    [transaction setDisableActions:YES];
    [UIView performWithoutAnimation:transition];
    [transaction commit];
}

static CGFloat previewRightEdge(UIView *host, UIView *list)
{
    CGFloat width = CGRectGetWidth(host.bounds);
    CGFloat right = CGRectGetMinX(host.bounds) + width * 0.44;
    if (list.window && list.window == host.window) {
        CGRect rect = [host convertRect:list.bounds fromView:list];
        CGFloat measured = CGRectGetMinX(rect) - width * 0.035;
        // BRListControl can report an outer frame spanning both preview and list.
        if (measured > CGRectGetMinX(host.bounds) + width * 0.25)
            right = MIN(right, measured);
    }
    return right;
}

void revivePlexShowPoster(id menu, id list, id path, id title)
{
    if ([objc_getAssociatedObject(menu, &posterPathKey) isEqual:path] &&
        [objc_getAssociatedObject(menu, &posterTitleKey) isEqual:title]) return;

    if (![menu isKindOfClass:[UIView class]] || ![list isKindOfClass:[UIView class]]) return;
    UIView *host = menu;
    UIView *listView = list;
    if (!host.window) return;
    CGRect bounds = host.bounds;
    CGFloat width = CGRectGetWidth(bounds), height = CGRectGetHeight(bounds);
    CGFloat leading = CGRectGetMinX(bounds) + width * 0.055;
    CGFloat trailing = previewRightEdge(host, listView);
    CGFloat gutter = width * 0.016;
    if (height < 100 || trailing - leading < 120) return;

    UIView *panel = objc_getAssociatedObject(menu, &posterPanelKey);
    UIImageView *imageView = objc_getAssociatedObject(menu, &posterImageKey);
    if (!panel) {
        if (!path) {
            revivePlexCancelPoster(menu);
            return;
        }
        revivePlexCancelPoster(menu);
        UIView *backdrop = [[UIView alloc] initWithFrame:CGRectMake(CGRectGetMinX(bounds), CGRectGetMinY(bounds),
            trailing - CGRectGetMinX(bounds), height)];
        backdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:1];
        backdrop.userInteractionEnabled = NO;
        backdrop.layer.zPosition = 50;
        panel = [[UIView alloc] initWithFrame:CGRectMake(leading - CGRectGetMinX(bounds), height * 0.12,
            trailing - leading, height * 0.76)];
        panel.backgroundColor = [UIColor colorWithWhite:0.075 alpha:1];
        panel.clipsToBounds = YES;
        panel.layer.cornerRadius = 14;
        CGFloat panelHeight = CGRectGetHeight(panel.bounds);
        UIView *imageArea = [[UIView alloc] initWithFrame:visualFrame(panelHeight,
            gutter, gutter, CGRectGetWidth(panel.bounds) - 2 * gutter, panelHeight * 0.82 - gutter)];
        imageView = [[UIImageView alloc] initWithFrame:imageArea.bounds];
        imageView.clipsToBounds = YES;
        imageView.layer.cornerRadius = 10;
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        [imageArea addSubview:imageView];
        [panel addSubview:imageArea];
        [backdrop addSubview:panel];
        [host addSubview:backdrop];
        objc_setAssociatedObject(menu, &posterViewKey, backdrop, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(menu, &posterPanelKey, panel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(menu, &posterImageKey, imageView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [objc_getAssociatedObject(menu, &posterLabelKey) removeFromSuperview];
    CGFloat panelHeight = CGRectGetHeight(panel.bounds);
    UIImageView *caption = renderedLabel(visualFrame(panelHeight, gutter, panelHeight * 0.84,
        CGRectGetWidth(panel.bounds) - 2 * gutter, panelHeight * 0.12),
        title, MAX(16, height * 0.032), YES, YES, nil);
    [panel addSubview:caption];
    objc_setAssociatedObject(menu, &posterLabelKey, caption, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(menu, &posterTitleKey, title, OBJC_ASSOCIATION_COPY_NONATOMIC);

    if (![objc_getAssociatedObject(menu, &posterPathKey) isEqual:path]) {
        [objc_getAssociatedObject(menu, &posterTaskKey) cancel];
        NSURLRequest *request = path ? revivePlexArtworkRequest(path) : nil;
        imageView.image = nil;
        objc_setAssociatedObject(imageView, &imageRequestKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(menu, &posterPathKey, path, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(menu, &posterTaskKey,
            request ? loadImage(request, imageView) : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}


@interface RevivePlexShelf : NSObject
@property(nonatomic, strong) UIView *view;
@property(nonatomic, strong) NSArray *rows;
@property(nonatomic, strong) UIImageView *focusedTitle;
@property(nonatomic) CGRect focusedTitleFrame;
@property(nonatomic) long selection;
@property(nonatomic, strong) NSMutableArray *cards;
@property(nonatomic, strong) NSMutableArray *tasks;
@property(nonatomic) NSInteger page;
@property(nonatomic, strong) NSArray *textPages;
@property(nonatomic) NSInteger textPage;
@end

@implementation RevivePlexShelf
- (void)dealloc
{
    for (NSURLSessionTask *task in _tasks) [task cancel];
    [_view removeFromSuperview];
}
@end

static char shelfKey;

void revivePlexClearShelf(id menu)
{
    objc_setAssociatedObject(menu, &shelfKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}


long revivePlexShelfColumns(id data)
{
    NSArray *rows = data;
    if ([[rows firstObject][@"panel"][@"detailActions"] boolValue]) return 4;
    if ([rows firstObject][@"panel"]) return [[rows firstObject][@"panel"][@"filterGrid"] boolValue] ? ([[rows firstObject][@"panel"][@"gridColumns"] intValue] == 2 ? 2 : 4) : ([[rows firstObject][@"panel"][@"actionGrid"] boolValue] ? 2 : 1);
    if ([[rows firstObject][@"landscapeArtwork"] boolValue]) return 4;
    NSString *type = [rows firstObject][@"mediaType"];
    return [type isEqual:@"episode"] || [type isEqual:@"clip"] ? 4 : 6;
}

static NSArray *descriptionPages(NSString *text, CGFloat width, CGFloat height, CGFloat size)
{
    if (!text.length) return @[@""];
    CTFontRef font = CTFontCreateWithName(CFSTR("HelveticaNeue"), size, NULL);
    NSAttributedString *styled = [[NSAttributedString alloc] initWithString:text attributes:@{(__bridge NSString *)kCTFontAttributeName:(__bridge id)font}];
    CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)styled);
    NSMutableArray *pages = [NSMutableArray array];
    NSUInteger lines = MAX(1, (NSUInteger)((height - size * 0.10) / (size * 1.10)));
    CFIndex start = 0;
    while (start < (CFIndex)text.length) {
        CFIndex end = start;
        for (NSUInteger line = 0; line < lines && end < (CFIndex)text.length; line++) {
            CFIndex length = CTTypesetterSuggestLineBreak(typesetter, end, width);
            if (length <= 0) length = 1;
            end += length;
        }
        [pages addObject:[text substringWithRange:NSMakeRange(start, end - start)]];
        start = end;
    }
    CFRelease(typesetter); CFRelease(font);
    return pages;
}

static void drawDescriptionPage(RevivePlexShelf *shelf)
{
    [[shelf.view viewWithTag:930] removeFromSuperview];
    [[shelf.view viewWithTag:931] removeFromSuperview];
    CGFloat width = shelf.view.bounds.size.width, height = shelf.view.bounds.size.height, margin = width * 0.067;
    UIImageView *body = renderedText(visualFrame(height, margin, height * 0.24, width - margin * 2, height * 0.65),
        shelf.textPages[shelf.textPage], height * 0.029, NO, NO, nil, YES);
    body.tag = 930; [shelf.view addSubview:body];
    if (shelf.textPages.count > 1) {
        UIImageView *footer = renderedLabel(visualFrame(height, margin, height * 0.93, width - margin * 2, height * 0.04),
            [NSString stringWithFormat:@"↑ ↓    %ld / %lu", (long)shelf.textPage + 1, (unsigned long)shelf.textPages.count], height * 0.023, NO, YES, nil);
        footer.tag = 931; [shelf.view addSubview:footer];
    }
}

signed char revivePlexScrollDescription(id menu, int action, int value)
{
    RevivePlexShelf *shelf = objc_getAssociatedObject(menu, &shelfKey);
    if (!shelf.textPages || action < 3 || action > 7) return NO;
    if (value == 1) {
        NSInteger page = shelf.textPage;
        if (action == 3 || action == 6) page--;
        if (action == 4 || action == 7) page++;
        if (page >= 0 && page < (NSInteger)shelf.textPages.count && page != shelf.textPage) {
            shelf.textPage = page; drawDescriptionPage(shelf);
        }
    }
    return YES;
}

static void populatePanel(RevivePlexShelf *shelf, NSArray *rows, NSString *title, CGFloat width, CGFloat height)
{
    NSDictionary *details = rows[0][@"panel"];
    CGFloat margin = width * 0.067;
    BOOL detailActions = [details[@"detailActions"] boolValue];
    if ([details[@"photo"] length]) {
        UIImageView *photo = [[UIImageView alloc] initWithFrame:CGRectMake(width * 0.035, height * 0.07, width * 0.93, height * 0.86)];
        photo.contentMode = UIViewContentModeScaleAspectFit;
        photo.tag = 901;
        photo.clipsToBounds = YES;
        photo.layer.cornerRadius = 12;
        [shelf.view addSubview:photo];
        NSURLRequest *request = revivePlexPhotoRequest(details[@"photo"]);
        if (request) { NSURLSessionTask *task = loadImage(request, photo); if (task) [shelf.tasks addObject:task]; }
        [shelf.view addSubview:renderedLabel(visualFrame(height, margin, height * 0.93, width - margin * 2, height * 0.04),
            details[@"title"], height * 0.025, NO, YES, nil)];
        if ([details[@"gallery"] boolValue]) [shelf.view addSubview:renderedLabel(visualFrame(height, margin, height * 0.025,
            width - margin * 2, height * 0.035), RPText(@"Sol/sağ: Fotoğraf · Seç: Slayt gösterisini başlat/durdur"), height * 0.020, NO, YES, nil)];
        return;
    }
    if (details[@"longText"]) {
        [shelf.view addSubview:renderedText(visualFrame(height, margin, height * 0.08, width - margin * 2, height * 0.12),
            details[@"title"], height * 0.045, YES, NO, nil, YES)];
        shelf.textPages = descriptionPages(details[@"longText"], width - margin * 2, height * 0.65, height * 0.029);
        drawDescriptionPage(shelf);
        return;
    }
    CGFloat textX = margin;
    if (details[@"artwork"]) {
        BOOL landscape = [details[@"landscape"] boolValue];
        CGFloat imageHeight = height * (detailActions ? 0.32 : (landscape ? 0.34 : 0.71)), imageWidth = landscape ? width * 0.34 : imageHeight * 2 / 3;
        if ([details[@"squareArtwork"] boolValue]) imageWidth = imageHeight = MIN(width * 0.34, height * (detailActions ? 0.32 : 0.60));
        UIImageView *cover = [[UIImageView alloc] initWithFrame:visualFrame(height, margin, height * 0.14, imageWidth, imageHeight)];
        cover.contentMode = UIViewContentModeScaleAspectFill;
        cover.clipsToBounds = YES;
        cover.layer.cornerRadius = 12;
        [shelf.view addSubview:cover];
        NSURLRequest *request = revivePlexArtworkRequest(details[@"artwork"]);
        if (request) {
            NSURLSessionTask *task = loadImage(request, cover);
            if (task) [shelf.tasks addObject:task];
        }
        textX += imageWidth + width * 0.045;
    }
    CGFloat textWidth = width - textX - margin;
    UIColor *muted = [UIColor colorWithWhite:0.72 alpha:1];
    [shelf.view addSubview:renderedText(visualFrame(height, textX, height * 0.12, textWidth, height * 0.11),
        details[@"title"] ?: title, height * 0.052, YES, NO, nil, YES)];
    NSString *subtitle = details[@"subtitle"], *facts = details[@"facts"];
    NSString *metadata = subtitle.length && facts.length ? [NSString stringWithFormat:@"%@   ·   %@", subtitle, facts] : (subtitle ?: facts);
    BOOL episodeHeading = detailActions && subtitle.length;
    if (episodeHeading) {
        [shelf.view addSubview:renderedText(visualFrame(height, textX, height * 0.23, textWidth, height * 0.075),
            subtitle, height * 0.027, NO, NO, muted, YES)];
        [shelf.view addSubview:renderedLabel(visualFrame(height, textX, height * 0.31, textWidth, height * 0.035),
            facts, height * 0.023, NO, NO, muted)];
    } else [shelf.view addSubview:renderedLabel(visualFrame(height, textX, height * 0.24, textWidth, height * 0.052),
        metadata, height * 0.027, NO, NO, muted)];
    BOOL hasRatings = [details[@"ratings"] length] > 0;
    if (hasRatings) [shelf.view addSubview:renderedLabel(visualFrame(height, textX, height * (episodeHeading ? 0.35 : 0.30), textWidth, height * 0.04),
        details[@"ratings"], height * 0.023, YES, NO, muted)];
    [shelf.view addSubview:renderedText(visualFrame(height, textX, height * (episodeHeading ? 0.395 : (hasRatings ? 0.36 : 0.31)), textWidth, height * 0.105),
        details[@"summary"], height * 0.028, NO, NO, nil, YES)];

    CGFloat top = [details[@"summary"] length] ? height * (hasRatings ? 0.50 : 0.47) : height * 0.34;
    BOOL filterGrid = [details[@"filterGrid"] boolValue];
    BOOL actionGrid = filterGrid || [details[@"actionGrid"] boolValue];
    NSUInteger actionColumns = detailActions ? 4 : filterGrid && [details[@"gridColumns"] intValue] != 2 ? 4 : 2;
    BOOL compactPair = filterGrid && actionColumns == 2;
    BOOL summaryPair = compactPair && [details[@"summary"] length];
    if (filterGrid && !summaryPair) top = height * 0.25;
    if ([details[@"technical"] length])
        [shelf.view addSubview:renderedText(visualFrame(height, textX, height * (detailActions ? 0.505 : 0.83), textWidth, height * (detailActions ? 0.04 : 0.08)),
            details[@"technical"], height * 0.024, NO, NO, muted, YES)];
    if (detailActions) { textX = margin; textWidth = width - margin * 2; top = height * 0.565; }
    NSUInteger actionIndex = 0;
    for (NSUInteger index = 0; index < rows.count; index++) {
        NSDictionary *entry = rows[index];
        if (!entry[@"route"] && !entry[@"action"]) continue;
        NSUInteger slot = detailActions ? actionIndex % 16 : (filterGrid ? (compactPair ? (summaryPair ? actionIndex % 8 : actionIndex % 12) : actionIndex % 28) : (actionGrid ? actionIndex % 6 : actionIndex % 4));
        NSUInteger actionPage = detailActions ? actionIndex / 16 : (filterGrid ? (compactPair ? (summaryPair ? actionIndex / 8 : actionIndex / 12) : actionIndex / 28) : (actionGrid ? actionIndex / 6 : actionIndex / 4));
        actionIndex++;
        if (actionPage != (NSUInteger)shelf.page) continue;
        CGFloat buttonWidth = actionGrid ? (textWidth - width * 0.015 * (actionColumns - 1)) / actionColumns : textWidth;
        CGFloat buttonX = textX + (actionGrid ? (actionColumns == 4 ? slot % 4 : slot % 2) * (buttonWidth + width * 0.015) : 0);
        CGFloat buttonTop = actionGrid ? top + (actionColumns == 4 ? slot / 4 : slot / 2) * height * (detailActions ? 0.09 : (filterGrid ? 0.09 : 0.106)) : top;
        UIView *button = [[UIView alloc] initWithFrame:visualFrame(height, buttonX, buttonTop,
            buttonWidth, height * ((filterGrid || detailActions) ? 0.075 : 0.087))];
        button.tag = (NSInteger)index;
        button.backgroundColor = [UIColor colorWithRed:0.105 green:0.116 blue:0.147 alpha:1];
        button.layer.cornerRadius = 8;
        button.layer.borderColor = [UIColor colorWithRed:1 green:0.73 blue:0.24 alpha:1].CGColor;
        CGFloat contentWidth = button.bounds.size.width - height * 0.046;
        CGFloat statusWidth = [entry[@"status"] length] ? contentWidth * 0.25 : 0;
        [button addSubview:buttonText(CGRectMake(height * 0.023, height * 0.008, contentWidth - statusWidth - (statusWidth ? height * 0.02 : 0), button.bounds.size.height - height * 0.016),
            entry[@"title"], height * ((filterGrid || detailActions) ? 0.024 : 0.029))];
        if (statusWidth) [button addSubview:renderedText(CGRectMake(button.bounds.size.width - height * 0.023 - statusWidth,
            height * 0.008, statusWidth, button.bounds.size.height - height * 0.016), entry[@"status"], height * 0.024, NO, 2, muted, NO)];
        [shelf.cards addObject:button];
        [shelf.view addSubview:button];
        if (!actionGrid) top += height * 0.094;
    }
    if (!actionIndex && ![details[@"summary"] length]) {
        [shelf.view addSubview:renderedText(visualFrame(height, textX, height * 0.34, textWidth, height * 0.20),
            rows[0][@"title"], height * 0.031, NO, NO, muted, YES)];
    }
    NSUInteger pageCount = detailActions ? (actionIndex + 15) / 16 : (filterGrid ? (compactPair ? (summaryPair ? (actionIndex + 7) / 8 : (actionIndex + 11) / 12) : (actionIndex + 27) / 28) : (actionGrid ? (actionIndex + 5) / 6 : (actionIndex + 3) / 4));
    if (pageCount > 1) [shelf.view addSubview:renderedLabel(visualFrame(height, width * 0.82, height * 0.92, width * 0.12, height * 0.04),
        [NSString stringWithFormat:@"%ld / %lu", (long)shelf.page + 1, (unsigned long)pageCount], height * 0.024, NO, YES, muted)];
}

signed char revivePlexShowShelf(id menu, id data, long selection, id title)
{
    NSArray *rows = data;
    if (![menu isKindOfClass:[UIView class]] || !rows.count || selection < 0 ||
        (NSUInteger)selection >= rows.count) return NO;
    UIView *host = menu;
    CGRect bounds = host.bounds;
    CGFloat width = CGRectGetWidth(bounds), height = CGRectGetHeight(bounds);
    if (width < 400 || height < 240) return NO;
    NSString *searchText = rows[0][@"searchText"];
    BOOL panel = rows[0][@"panel"] != nil;
    NSDictionary *hero = rows[0][@"hero"];
    NSUInteger keyCount = [rows[0][@"searchKeyCount"] unsignedIntegerValue];
    NSUInteger toolbarCount = [rows[0][@"toolbarCount"] unsignedIntegerValue];
    NSUInteger columns = searchText ? RevivePlexSearchResultColumns : revivePlexShelfColumns(rows);
    NSUInteger pageSize = searchText ? rows.count : columns * 2;
    if (hero) pageSize = columns;
    NSInteger page = searchText || panel ? 0 : (columns == 4 ? selection / 8 : selection / 12);
    if (toolbarCount) {
        long gridSelection = MAX(0, selection - (long)toolbarCount);
        page = columns == 4 ? gridSelection / 8 : gridSelection / 12;
    }
    if (hero) { long gridSelection = MAX(0, selection - (long)toolbarCount); page = columns == 4 ? gridSelection / 4 : gridSelection / 6; }
    if (searchText && (NSUInteger)selection >= keyCount) page = ((NSUInteger)selection - keyCount) / (RevivePlexSearchResultColumns * 2);
    if (panel) {
        NSUInteger preceding = 0;
        for (NSUInteger index = 0; index < (NSUInteger)selection; index++)
            if (rows[index][@"route"] || rows[index][@"action"]) preceding++;
        page = [rows[0][@"panel"][@"detailActions"] boolValue] ? preceding / 16 : [rows[0][@"panel"][@"filterGrid"] boolValue] ? ([rows[0][@"panel"][@"gridColumns"] intValue] == 2 ? ([rows[0][@"panel"][@"summary"] length] ? preceding / 8 : preceding / 12) : preceding / 28) : ([rows[0][@"panel"][@"actionGrid"] boolValue] ? preceding / 6 : preceding / 4);
    }
    RevivePlexShelf *shelf = objc_getAssociatedObject(menu, &shelfKey);
    if (!shelf || shelf.page != page || shelf.rows != rows) {
        revivePlexCancelPoster(menu);
        shelf = [RevivePlexShelf new];
        shelf.rows = rows;
        shelf.page = page;
        shelf.selection = -1;
        shelf.cards = [NSMutableArray array];
        shelf.tasks = [NSMutableArray array];
        shelf.view = [[UIView alloc] initWithFrame:bounds];
        shelf.view.backgroundColor = [UIColor colorWithRed:0.055 green:0.060 blue:0.079 alpha:1];
        shelf.view.userInteractionEnabled = NO;
        shelf.view.layer.zPosition = 100;

        if (panel) {
            populatePanel(shelf, rows, title, width, height);
        } else {
            CGFloat margin = width * 0.055, gap = height * 0.023;
            CGFloat cardWidth = (width - margin * 2 - gap * (columns - 1)) / columns;
            CGFloat top = height * 0.18, spacing = gap;
            // Card geometry depends on the viewport, never on the number of results.
            // Sparse libraries and the last page keep the same two-row grid metrics.
            CGFloat cardHeight = (height * 0.65 - spacing) / 2;
            if (toolbarCount) top = height * 0.24;
            BOOL landscape = columns == 4;
            BOOL square = [@[@"artist", @"album", @"track", @"playlist", @"person"] containsObject:rows[0][@"mediaType"] ?: @""];
            if (hero) top = height * (toolbarCount ? 0.49 : 0.44);
            CGFloat inset = height * 0.011;
            CGFloat titleFont = MAX(13, height * 0.024);
            CGFloat metadataFont = MAX(11, height * 0.018);
            CGFloat captionHeight = titleFont * 2.9 + metadataFont * 1.5;
            CGFloat coverHeight = cardHeight - captionHeight - inset * 4;
            CGFloat coverWidth = MIN(cardWidth - 2 * inset, coverHeight * (square ? 1 : (landscape ? 16.0 / 9.0 : 2.0 / 3.0)));
            if (searchText) {
                top = height * 0.34;
                cardHeight = height * 0.29;
                coverHeight = cardHeight - captionHeight - inset * 4;
                coverWidth = MIN(cardWidth - 2 * inset, coverHeight * 2 / 3);
            }
            coverHeight = coverWidth * (square ? 1 : (landscape && !searchText ? 9.0 / 16.0 : 1.5));
            CGFloat gridWidth = columns * cardWidth + (columns - 1) * gap;
            margin = searchText ? width * 0.055 : (width - gridWidth) / 2;
            shelf.focusedTitleFrame = visualFrame(height, margin + gridWidth * 0.36, height * 0.064, gridWidth * 0.64, height * 0.072);
            if (searchText) shelf.focusedTitleFrame = visualFrame(height, width * 0.25, height * 0.275,
                width * 0.69, height * 0.055);
            CGFloat headingWidth = searchText ? width * 0.14 : gridWidth * 0.33;
            UIImageView *heading = renderedText(visualFrame(height, margin, height * 0.055, headingWidth, height * 0.088),
                                          rows[0][@"displayTitle"] ?: title, height * 0.039, YES, NO, nil, YES);
            [shelf.view addSubview:heading];
            UIView *rule = [[UIView alloc] initWithFrame:visualFrame(height, margin, height * 0.15, width * 0.105, 3)];
            rule.backgroundColor = [UIColor colorWithRed:1 green:0.73 blue:0.24 alpha:1];
            if (!searchText && !toolbarCount) [shelf.view addSubview:rule];
            if (hero) {
                NSString *heroTitle = [hero[@"parentTitle"] length] ? hero[@"parentTitle"] : hero[@"title"];
                NSString *heroSummary = hero[@"summary"] ?: @"";
                [shelf.view addSubview:renderedLabel(visualFrame(height, margin, height * 0.19,
                    width - margin * 2, height * 0.075), heroTitle, height * 0.043, YES, NO, nil)];
                [shelf.view addSubview:renderedText(visualFrame(height, margin, height * 0.28,
                    width - margin * 2, height * 0.10), heroSummary, height * 0.026, NO, NO,
                    [UIColor colorWithWhite:0.75 alpha:1], YES)];
            }
            CGFloat keyGap = height * 0.008, keyHeight = height * 0.058;
            CGFloat keyWidth = (width - 2 * margin - keyGap * (RevivePlexSearchColumns - 1)) / RevivePlexSearchColumns;
            if (searchText) {
                [shelf.view addSubview:renderedLabel(visualFrame(height, width * 0.24, height * 0.054,
                    width * 0.705, height * 0.075), searchText.length ? searchText : RPText(@"Başlık yaz"),
                    height * 0.031, YES, NO, nil)];
                NSString *status = rows.count > keyCount ? [NSString stringWithFormat:@"%@ · %lu", RPText(@"Sonuçlar"), (unsigned long)(rows.count - keyCount)] : rows[0][@"searchStatus"];
                [shelf.view addSubview:renderedLabel(visualFrame(height, margin, height * 0.28,
                    width * 0.88, height * 0.05), status, height * 0.027, YES, NO, nil)];
            }

            for (NSUInteger index = 0; index < toolbarCount; index++) {
                CGFloat buttonWidth = width * 0.16;
                UIView *button = [[UIView alloc] initWithFrame:visualFrame(height, margin + index * (buttonWidth + gap),
                    height * (hero ? 0.40 : 0.15), buttonWidth, height * 0.06)];
                button.tag = index;
                button.backgroundColor = [UIColor colorWithRed:0.105 green:0.116 blue:0.147 alpha:1];
                button.layer.cornerRadius = 8;
                button.layer.borderColor = [UIColor colorWithRed:1 green:0.73 blue:0.24 alpha:1].CGColor;
                NSUInteger filterCount = [rows[index][@"filterCount"] unsignedIntegerValue];
                CGRect labelFrame = button.bounds;
                if (filterCount) labelFrame.size.width -= height * 0.047;
                [button addSubview:renderedLabel(labelFrame, rows[index][@"title"], height * 0.025, YES, YES, nil)];
                if (filterCount) {
                    CGFloat diameter = height * 0.034;
                    UIView *badge = [[UIView alloc] initWithFrame:CGRectMake(buttonWidth - diameter - height * 0.009,
                        (button.bounds.size.height - diameter) / 2, diameter, diameter)];
                    badge.backgroundColor = [UIColor colorWithRed:1 green:0.73 blue:0.24 alpha:1];
                    badge.layer.cornerRadius = diameter / 2;
                    [badge addSubview:renderedLabel(badge.bounds, [NSString stringWithFormat:@"%lu", (unsigned long)filterCount],
                        height * 0.020, YES, YES, [UIColor blackColor])];
                    [button addSubview:badge];
                }
                [shelf.cards addObject:button]; [shelf.view addSubview:button];
            }
            if (toolbarCount && [rows[0][@"sortTitle"] length]) {
                [shelf.view addSubview:renderedLabel(visualFrame(height, width * 0.66,
                    height * (hero ? 0.40 : 0.15), width * 0.285, height * 0.06),
                    rows[0][@"sortTitle"], height * 0.024, NO, YES, [UIColor colorWithWhite:0.62 alpha:1])];
            }
            NSUInteger first = searchText ? 0 : toolbarCount + (NSUInteger)page * pageSize;
            for (NSUInteger index = first; index < MIN(first + pageSize, rows.count); index++) {
                NSUInteger slot = index - first;
                NSDictionary *entry = rows[index];
                if (entry[@"shelfLoading"]) {
                    [shelf.view addSubview:renderedLabel(visualFrame(height, margin, top, width - 2 * margin, height * 0.08),
                        entry[@"title"], height * 0.028, NO, NO, nil)];
                    break;
                }
                BOOL key = searchText && index < keyCount;
                if (searchText && !key) {
                    NSUInteger resultStart = keyCount + page * columns * 2;
                    if (index < resultStart || index >= resultStart + columns * 2) continue;
                    slot = index - resultStart;
                }
                NSUInteger layoutColumns = key ? RevivePlexSearchColumns : columns;
                NSUInteger row = slot >= layoutColumns;
                NSUInteger column = slot - row * layoutColumns;
                CGRect frame = key ?
                    visualFrame(height, margin + column * (keyWidth + keyGap),
                        height * 0.133 + row * (keyHeight + keyGap), keyWidth, keyHeight) :
                    visualFrame(height, margin + column * (cardWidth + gap),
                        top + row * (cardHeight + spacing), cardWidth, cardHeight);
                UIView *card = [[UIView alloc] initWithFrame:frame];
                card.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1];
                card.tag = (NSInteger)index;
                card.layer.cornerRadius = 12;
                card.layer.borderColor = [UIColor colorWithRed:1 green:0.73 blue:0.24 alpha:1].CGColor;
                card.clipsToBounds = YES;
                if (key) {
                    card.backgroundColor = [UIColor colorWithRed:0.105 green:0.116 blue:0.147 alpha:1];
                    card.layer.cornerRadius = 6;
                    [card addSubview:renderedLabel(card.bounds, entry[@"title"], height * 0.022, YES, YES, nil)];
                    [shelf.view addSubview:card];
                    [shelf.cards addObject:card];
                    continue;
                }
                UIImageView *cover = [[UIImageView alloc] initWithFrame:visualFrame(cardHeight,
                    (cardWidth - coverWidth) / 2, inset, coverWidth, coverHeight)];
                cover.tag = 9001;
                cover.backgroundColor = [UIColor colorWithRed:0.14 green:0.16 blue:0.20 alpha:1];
                cover.layer.borderColor = [UIColor colorWithRed:1 green:0.73 blue:0.24 alpha:1].CGColor;
                cover.contentMode = UIViewContentModeScaleAspectFill;
                cover.clipsToBounds = YES;
                cover.layer.cornerRadius = 8;
                if ([entry[@"mediaType"] isEqual:@"person"]) {
                    CGFloat diameter = MIN(coverWidth, coverHeight);
                    cover.frame = visualFrame(cardHeight, (cardWidth - diameter) / 2, inset, diameter, diameter);
                    cover.layer.cornerRadius = diameter / 2;
                }
#ifdef REVIVEPLEX_DEMO_SCREENSHOTS
                if (entry[@"demoArtwork"]) cover.image = demoArtwork(entry[@"demoArtwork"]);
#endif
                [card addSubview:cover];
                NSString *metadata = entry[@"catalogCaption"];
                CGFloat titleHeight = titleFont * 2.9;
                UIImageView *caption = renderedText(visualFrame(cardHeight, inset,
                    coverHeight + inset * 2, cardWidth - 2 * inset, titleHeight),
                    entry[@"cardTitle"] ?: entry[@"title"], titleFont, YES, YES, nil, YES);
                if (metadata.length)
                    [card addSubview:renderedLabel(visualFrame(cardHeight, inset,
                        coverHeight + inset * 2 + titleHeight, cardWidth - 2 * inset, captionHeight - titleHeight),
                        metadata, metadataFont, NO, YES, [UIColor colorWithWhite:0.72 alpha:1])];
                [card addSubview:caption];
                [shelf.view addSubview:card];
                [shelf.cards addObject:card];

                NSString *path = [entry[@"landscapeArtwork"] boolValue] ? (entry[@"backdrop"] ?: entry[@"artwork"]) : (entry[@"artwork"] ?: entry[@"backdrop"]);
                NSURLRequest *request = revivePlexArtworkRequest(path);
                if (request) {
                    NSURLSessionTask *task = loadImage(request, cover);
                    if (task) [shelf.tasks addObject:task];
                }
            }
        }
        [host addSubview:shelf.view];
        objc_setAssociatedObject(menu, &shelfKey, shelf, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!panel && shelf.selection != selection && !rows[selection][@"shelfLoading"]) {
        [shelf.focusedTitle removeFromSuperview];
        shelf.focusedTitle = renderedLabel(shelf.focusedTitleFrame,
            (searchText && (NSUInteger)selection < keyCount) || (NSUInteger)selection < toolbarCount ? @"" : rows[selection][@"title"],
            height * 0.031, YES, NO, nil);
        [shelf.view addSubview:shelf.focusedTitle];
        shelf.selection = selection;
    }
    for (UIView *card in shelf.cards) {
        UIView *cover = [card viewWithTag:9001];
        card.layer.borderWidth = card.tag == selection ? 4 : 0;
        cover.layer.borderWidth = 0;
    }
    [host bringSubviewToFront:shelf.view];
    return YES;
}


void revivePlexShowLinkQR(id menu, id list, id data)
{
    NSArray *rows = data;
    NSDictionary *first = [rows firstObject];
    NSString *code = first[@"qrCode"];
    NSString *status = rows.count > 1 ? rows[1][@"title"] : @"";
    NSString *marker = [NSString stringWithFormat:@"plex-link-qr-%@-%@", code ?: @"", status];
    if ([objc_getAssociatedObject(menu, &posterPathKey) isEqual:marker]) return;
    revivePlexCancelPoster(menu);
    revivePlexClearShelf(menu);
    if (![menu isKindOfClass:[UIView class]] || ![list isKindOfClass:[UIView class]]) return;
    UIView *host = menu;
    if (!host.window) return;
    Dl_info info;
    if (!dladdr(&posterViewKey, &info) || !info.dli_fname) return;
    NSString *binary = [NSString stringWithUTF8String:info.dli_fname];
    UIImage *image = [UIImage imageWithContentsOfFile:
        [[binary stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"LinkQR.png"]];
    CGFloat width = host.bounds.size.width, height = host.bounds.size.height;
    UIView *backdrop = [[UIView alloc] initWithFrame:host.bounds];
    backdrop.backgroundColor = [UIColor colorWithRed:0.055 green:0.060 blue:0.079 alpha:1];
    backdrop.userInteractionEnabled = NO;
    backdrop.layer.zPosition = 100;
    UIColor *amber = [UIColor colorWithRed:1 green:0.73 blue:0.24 alpha:1];
    CGFloat qrSize = height * 0.40;
    UIView *tile = [[UIView alloc] initWithFrame:visualFrame(height, width * 0.10,
        height * 0.24, qrSize + 32, qrSize + 32)];
    tile.backgroundColor = [UIColor whiteColor];
    tile.layer.cornerRadius = 16;
    UIImageView *qr = [[UIImageView alloc] initWithFrame:CGRectMake(16, 16, qrSize, qrSize)];
    qr.image = image;
    qr.contentMode = UIViewContentModeScaleAspectFit;
    [tile addSubview:qr];
    [backdrop addSubview:tile];
    CGFloat x = width * 0.47, textWidth = width * 0.45;
    [backdrop addSubview:renderedLabel(visualFrame(height, width * 0.065, height * 0.07,
        width * 0.3, height * 0.07), @"Plex", height * 0.050, YES, NO, nil)];
    [backdrop addSubview:renderedText(visualFrame(height, x, height * 0.23,
        textWidth, height * 0.10), RPText(@"Plex hesabını bağla"), height * 0.046, YES, NO, nil, YES)];
    [backdrop addSubview:renderedText(visualFrame(height, x, height * 0.36,
        textWidth, height * 0.10), RPText(@"Telefonunla QR kodu tara veya plex.tv/link adresini aç."),
        height * 0.029, NO, NO, nil, YES)];
    [backdrop addSubview:renderedLabel(visualFrame(height, x, height * 0.50,
        textWidth, height * 0.09), code ?: RPText(@"Kod oluşturmak için seç"), height * (code ? 0.065 : 0.032), YES, NO, amber)];
    [backdrop addSubview:renderedText(visualFrame(height, x, height * 0.62,
        textWidth, height * 0.08), status, height * 0.025, NO, NO,
        [UIColor colorWithWhite:0.72 alpha:1], YES)];
    UIView *button = [[UIView alloc] initWithFrame:visualFrame(height, x, height * 0.76,
        textWidth, height * 0.085)];
    button.backgroundColor = [UIColor colorWithRed:0.105 green:0.116 blue:0.147 alpha:1];
    button.layer.cornerRadius = 10;
    button.layer.borderColor = amber.CGColor;
    button.layer.borderWidth = 3;
    [button addSubview:renderedLabel(button.bounds, first[@"title"], height * 0.030, YES, YES, nil)];
    [backdrop addSubview:button];
    [host addSubview:backdrop];
    objc_setAssociatedObject(menu, &posterViewKey, backdrop, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(menu, &posterPathKey, marker, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static void captureCurrentMenu(UIView *host, NSString *filename)
{
    if (!host.window || CGRectIsEmpty(host.bounds)) return;
    UIView *surface = host.window;
    CGFloat width = CGRectGetWidth(surface.bounds);
    CGFloat scale = width > 1280 ? 1280.0 / width : 1.0;
    UIGraphicsBeginImageContextWithOptions(surface.bounds.size, YES, scale);
    if (![surface drawViewHierarchyInRect:surface.bounds afterScreenUpdates:YES]) {
        CGContextRef context = UIGraphicsGetCurrentContext();
        if (context) [surface.layer renderInContext:context];
    }
    UIImage *capture = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    NSData *png = capture ? UIImagePNGRepresentation(capture) : nil;
    NSString *cache = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"];
    NSString *path = [cache stringByAppendingPathComponent:filename];
    NSFileManager *files = [NSFileManager defaultManager];
    if (png && ![files fileExistsAtPath:path] &&
        [files createFileAtPath:path contents:png attributes:@{NSFilePosixPermissions: @0600}]) {
        syslog(LOG_NOTICE, "RevivePlex: diagnostic menu image captured");
    }
}

void revivePlexCaptureMenuIfRequested(id menu)
{
    if (![menu isKindOfClass:[UIView class]]) return;
    NSString *cache = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"];
    NSString *trigger = [cache stringByAppendingPathComponent:@"RevivePlex.capture-once"];
    NSFileManager *files = [NSFileManager defaultManager];
    if (![files fileExistsAtPath:trigger] || ![files removeItemAtPath:trigger error:NULL]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3500 * (int64_t)NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        captureCurrentMenu(menu, @"RevivePlex.capture.png");
    });
}

void revivePlexCaptureCatalogForProbe(id menu)
{
    if ([menu isKindOfClass:[UIView class]]) captureCurrentMenu(menu, @"RevivePlex.catalog.png");
}

void revivePlexCaptureScreenForProbe(id menu, id filename)
{
    if ([menu isKindOfClass:[UIView class]] && [filename hasPrefix:@"RevivePlex."] &&
        [[filename lastPathComponent] isEqual:filename]) captureCurrentMenu(menu, filename);
}

@interface RevivePlexHomeRails : NSObject
@property(nonatomic) NSInteger page;
@property(nonatomic, strong) NSArray *textPages;
@property(nonatomic) NSInteger textPage;
@property(nonatomic, strong) UIView *view;
@property(nonatomic, strong) NSArray *rows;
@property(nonatomic, strong) NSMutableArray *cards;
@property(nonatomic, strong) NSMutableArray *tasks;
@end

@implementation RevivePlexHomeRails
- (void)dealloc
{
    for (NSURLSessionTask *task in _tasks) [task cancel];
    [_view removeFromSuperview];
}
@end

static char homeRailsKey;

void revivePlexClearHomeRails(id menu)
{
    objc_setAssociatedObject(menu, &homeRailsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL isSearchTab(NSDictionary *entry)
{
    return [entry[@"route"][@"kind"] isEqual:@"search"];
}

static void addSearchIcon(UIView *card)
{
    CGFloat size = CGRectGetHeight(card.bounds) * 0.46;
    CGRect bounds = card.bounds;
    UIColor *ink = [UIColor colorWithWhite:0.94 alpha:1];
    UIView *icon = [[UIView alloc] initWithFrame:CGRectMake((bounds.size.width - size) / 2,
        (bounds.size.height - size) / 2, size, size)];
    CGFloat diameter = size * 0.72, stroke = MAX(1.5, size * 0.10);
    UIView *ring = [[UIView alloc] initWithFrame:CGRectMake(0, size - diameter, diameter, diameter)];
    ring.layer.cornerRadius = diameter / 2;
    ring.layer.borderWidth = stroke;
    ring.layer.borderColor = ink.CGColor;
    [icon addSubview:ring];

    UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(size * 0.58, size * 0.20, size * 0.44, stroke)];
    handle.transform = (CGAffineTransform){0.7071, -0.7071, 0.7071, 0.7071, 0, 0};
    handle.backgroundColor = ink;
    handle.layer.cornerRadius = stroke / 2;
    [icon addSubview:handle];
    [card addSubview:icon];
    card.isAccessibilityElement = YES;
    card.accessibilityLabel = RPText(@"Ara");
}

signed char revivePlexShowHomeRails(id menu, id data, long selection)
{
    NSArray *rows = data;
    if (![menu isKindOfClass:[UIView class]] || selection < 0 || (NSUInteger)selection >= rows.count) return NO;
    UIView *host = menu;
    CGRect bounds = host.bounds;
    CGFloat width = CGRectGetWidth(bounds), height = CGRectGetHeight(bounds);
    if (!host.window || width < 600 || height < 360) return NO;
    RevivePlexHomeRails *home = objc_getAssociatedObject(menu, &homeRailsKey);
    NSInteger selectedRail = [rows[selection][@"homeRail"] integerValue];
    NSInteger page = selectedRail > 0 ? (selectedRail - 1) / 2 : 0;
    if (!home || home.rows != rows || home.page != page) {
        revivePlexClearHomeRails(menu);
        revivePlexCancelPoster(menu);
        home = [RevivePlexHomeRails new];
        home.rows = rows;
        home.page = page;
        home.cards = [NSMutableArray array];
        home.tasks = [NSMutableArray array];
        home.view = [[UIView alloc] initWithFrame:bounds];
        home.view.backgroundColor = [UIColor colorWithRed:0.047 green:0.052 blue:0.071 alpha:1];
        home.view.userInteractionEnabled = NO;
        home.view.layer.zPosition = 100;
        home.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        UIColor *highlight = [UIColor colorWithRed:1 green:0.73 blue:0.24 alpha:1];
        CGFloat margin = width * 0.055, contentWidth = width - 2 * margin;
        CGFloat gap = width * 0.016;
        [home.view addSubview:renderedLabel(visualFrame(height, margin, height * 0.045, width * 0.105, height * 0.065),
            @"Plex", height * 0.037, YES, NO, highlight)];

        CGFloat tabStart = width * 0.11;
        CGFloat tabGap = height * 0.012, tabHeight = height * 0.063;
        CGFloat tabPadding = height * 0.022, tabFontSize = height * 0.023;
        NSMutableArray<NSNumber *> *tabWidths = [NSMutableArray array];
        CTFontRef font = CTFontCreateWithName(CFSTR("HelveticaNeue-Medium"), tabFontSize, NULL);
        NSDictionary *attributes = @{(__bridge NSString *)kCTFontAttributeName: (__bridge id)font};
        CGFloat totalTextWidth = 0;
        NSUInteger searchCount = 0;
        for (NSDictionary *entry in rows) {
            if ([entry[@"homeRail"] intValue] != 0) continue;
            if (isSearchTab(entry)) {
                [tabWidths addObject:@(tabHeight)];
                searchCount++;
                continue;
            }
            NSAttributedString *title = [[NSAttributedString alloc] initWithString:entry[@"title"] attributes:attributes];
            CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)title);
            CGFloat measured = ceilf(CTLineGetTypographicBounds(line, NULL, NULL, NULL));
            CFRelease(line);
            totalTextWidth += measured;
            [tabWidths addObject:@(measured)];
        }
        CFRelease(font);
        NSUInteger textTabCount = tabWidths.count - searchCount;
        CGFloat availableText = contentWidth - tabStart - tabGap * MAX(0, (NSInteger)tabWidths.count - 1)
            - searchCount * tabHeight - textTabCount * tabPadding;
        CGFloat textScale = MIN(1, MAX(0, availableText) / MAX(1, totalTextWidth));
        CGFloat tabsWidth = totalTextWidth * textScale + searchCount * tabHeight
            + textTabCount * tabPadding + tabGap * MAX(0, (NSInteger)tabWidths.count - 1);
        CGFloat tabX = MAX(margin + tabStart, (width - tabsWidth) * 0.5);
        CGFloat cardWidth = (contentWidth - gap * 3) / 4;
        long lastRail = -1;
        NSUInteger column = 0, mediaRailIndex = 0;
        CGFloat railTop = 0;
        for (NSDictionary *entry in rows) {
            long rail = [entry[@"homeRail"] longValue];
            if (rail > 0 && (rail - 1) / 2 != page) continue;
            if (rail != lastRail) {
                column = 0;
                lastRail = rail;
                if (rail > 0) {
                    railTop = height * (0.176 + 0.389 * mediaRailIndex++);
                    [home.view addSubview:renderedLabel(visualFrame(height, margin, railTop, MIN(contentWidth, width * 0.60), height * 0.047),
                        entry[@"railTitle"], height * 0.032, YES, NO, nil)];
                }
            }
            BOOL search = rail == 0 && isSearchTab(entry);
            CGFloat tabWidth = rail == 0 ? (search ? tabHeight : tabWidths[column].doubleValue * textScale + tabPadding) : 0;
            CGRect frame = rail == 0 ?
                visualFrame(height, tabX, height * 0.048, tabWidth, tabHeight) :
                visualFrame(height, margin + column * (cardWidth + gap), railTop + height * 0.057, cardWidth, height * 0.285);
            column++;
            if (rail == 0) tabX += tabWidth + tabGap;
            UIView *card = [[UIView alloc] initWithFrame:frame];
            card.tag = [rows indexOfObjectIdenticalTo:entry];
            card.backgroundColor = [UIColor colorWithRed:0.101 green:0.112 blue:0.139 alpha:1];
            card.layer.cornerRadius = rail == 0 ? 8 : 12;
            card.layer.borderColor = highlight.CGColor;
            card.clipsToBounds = YES;
            CGFloat w = CGRectGetWidth(frame), h = CGRectGetHeight(frame);
            if (rail > 0) {
                UIImageView *cover = [[UIImageView alloc] initWithFrame:visualFrame(h, 4, 4, w - 8, h * 0.66 - 4)];
                cover.contentMode = UIViewContentModeScaleAspectFill;
                cover.clipsToBounds = YES;
                cover.layer.cornerRadius = 8;
#ifdef REVIVEPLEX_DEMO_SCREENSHOTS
                if (entry[@"demoArtwork"]) cover.image = demoArtwork(entry[@"demoArtwork"]);
#endif
                [card addSubview:cover];
                NSURLRequest *request = revivePlexArtworkRequest(entry[@"backdrop"] ?: entry[@"artwork"]);
                if (request) {
                    NSURLSessionTask *task = loadImage(request, cover);
                    if (task) [home.tasks addObject:task];
                }
            }
            CGRect textFrame = rail == 0 ? CGRectMake(4, 0, w - 8, h)
                : visualFrame(h, 10, h * 0.68, w - 20, h * 0.27);
            NSString *caption = entry[@"caption"];
            if (search) {
                addSearchIcon(card);
            } else if (caption.length && rail > 0) {
                [card addSubview:renderedText(visualFrame(h, 10, h * 0.68, w - 20, h * 0.19),
                    entry[@"cardTitle"] ?: entry[@"title"], height * 0.022, YES, YES, nil, YES)];
                [card addSubview:renderedLabel(visualFrame(h, 10, h * 0.87, w - 20, h * 0.09),
                    caption, height * 0.018, NO, YES, [UIColor colorWithWhite:0.73 alpha:1])];
            } else if (rail == 0) {
                [card addSubview:renderedLabel(textFrame, entry[@"title"],
                    tabFontSize * textScale, YES, YES, nil)];
            } else {
                [card addSubview:renderedText(textFrame, entry[@"title"],
                    rail == 0 ? tabFontSize : height * 0.026, YES, YES, nil, YES)];
            }
            [home.view addSubview:card];
            [home.cards addObject:card];
        }
        [host addSubview:home.view];
        objc_setAssociatedObject(menu, &homeRailsKey, home, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        syslog(LOG_NOTICE, "RevivePlex: home artwork rails visible");
    }
    [home.cards enumerateObjectsUsingBlock:^(UIView *card, NSUInteger index, BOOL *stop) {
        (void)stop;
        (void)index;
        card.layer.borderWidth = card.tag == selection ? 3 : 0;
    }];
    return YES;
}

signed char revivePlexConsumeNavigationProbe(void)
{
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/RevivePlex.navigation-once"];
    NSFileManager *files = [NSFileManager defaultManager];
    return [files fileExistsAtPath:path] && [files removeItemAtPath:path error:NULL];
}
