#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
output=${1:-"$here/../build/native/RevivePlex.frappliance"}
work=$(mktemp -d)
trap 'rm "$work/Localization.o" "$work/CoreText.tbd" "$work/PlexLink.o" "$work/Artwork.o" "$work/UIKit.tbd" "$work/ImageIO.tbd" "$work/Playback.o" "$work/RangeStream.o" "$work/DirectPlay.o" "$work/AVFoundation.tbd" "$work/CoreGraphics.tbd" "$work/CoreMedia.tbd" "$work/RevivePlex.o" "$work/PlexClient.o" "$work/LiveLibrary.o" "$work/RevivePlex" "$work/libSystem.tbd" "$work/libobjc.tbd" "$work/CoreFoundation.tbd" "$work/Foundation.tbd" 2>/dev/null || :; rmdir "$work"' EXIT

stub() {
    cat >"$work/$1.tbd" <<STUB
--- !tapi-tbd-v3
archs: [ armv7 ]
platform: ios
install-name: $2
exports:
  - archs: [ armv7 ]
    symbols: [ $3 ]
...
STUB
}

stub libSystem /usr/lib/libSystem.B.dylib 'dyld_stub_binder, _syslog, _ceilf, __NSConcreteStackBlock, __NSConcreteGlobalBlock, __Block_object_assign, __Block_object_dispose, __dispatch_main_q, _dispatch_async, _dispatch_group_create, _dispatch_group_enter, _dispatch_group_leave, _dispatch_group_notify, _dispatch_after, _dispatch_time, _geteuid, _lstat, _memchr, _dladdr, _close, _mkstemp, _rename, _unlink, _write, ___error'
stub libobjc /usr/lib/libobjc.A.dylib \
    '_class_getInstanceVariable, _object_getIvar, _method_getImplementation, _method_setImplementation, _class_addMethod, _class_conformsToProtocol, _class_getClassMethod, _class_getInstanceMethod, _class_getName, _method_getTypeEncoding, _objc_allocateClassPair, _objc_disposeClassPair, _objc_getAssociatedObject, _objc_getClass, _objc_getProtocol, _objc_msgSend, _objc_msgSendSuper, _objc_registerClassPair, _objc_setAssociatedObject, _sel_registerName, __objc_empty_cache, _objc_autoreleaseReturnValue, _objc_enumerationMutation, _objc_msgSendSuper2, _objc_msgSend_stret, _objc_release, _objc_retain, _objc_retainAutorelease, _objc_retainAutoreleaseReturnValue, _objc_retainAutoreleasedReturnValue, _objc_setProperty_nonatomic_copy, _objc_storeStrong, _objc_copyWeak, _objc_retainBlock, _objc_destroyWeak, _objc_initWeak, _objc_loadWeakRetained, _objc_storeWeak'
stub CoreFoundation /System/Library/Frameworks/CoreFoundation.framework/CoreFoundation \
    '___CFConstantStringClassReference, _CFRelease'

stub Foundation /System/Library/Frameworks/Foundation.framework/Foundation \
    '_NSSelectorFromString, _NSHomeDirectory, _NSFilePosixPermissions, _NSClassFromString, _OBJC_CLASS_$_NSCache, _OBJC_CLASS_$_NSMutableDictionary, _OBJC_CLASS_$_NSScanner, _OBJC_CLASS_$_NSDate, _OBJC_CLASS_$_NSDateFormatter, _OBJC_CLASS_$_NSCalendar, _OBJC_CLASS_$_NSLocale, _OBJC_CLASS_$_NSAttributedString, _OBJC_CLASS_$_NSJSONSerialization, _OBJC_CLASS_$_NSUserDefaults, _OBJC_CLASS_$_NSPropertyListSerialization, _OBJC_CLASS_$_NSNumber, _NSTemporaryDirectory, _OBJC_CLASS_$_NSFileManager, _OBJC_CLASS_$_NSNotificationCenter, _OBJC_CLASS_$_NSOperationQueue, _OBJC_CLASS_$_NSUUID, _OBJC_CLASS_$_NSObject, _OBJC_METACLASS_$_NSObject, _OBJC_CLASS_$_NSArray, _OBJC_CLASS_$_NSCharacterSet, _OBJC_CLASS_$_NSDictionary, _OBJC_CLASS_$_NSError, _OBJC_CLASS_$_NSMutableArray, _OBJC_CLASS_$_NSMutableSet, _OBJC_CLASS_$_NSNull, _OBJC_CLASS_$_NSMutableData, _OBJC_CLASS_$_NSMutableURLRequest, _OBJC_CLASS_$_NSString, _OBJC_CLASS_$_NSURL, _OBJC_CLASS_$_NSURLComponents, _OBJC_CLASS_$_NSURLQueryItem, _OBJC_CLASS_$_NSURLSession, _OBJC_CLASS_$_NSURLSessionConfiguration, _OBJC_CLASS_$_NSXMLParser'

stub AVFoundation /System/Library/Frameworks/AVFoundation.framework/AVFoundation \
    '_OBJC_CLASS_$_AVPlayer, _OBJC_CLASS_$_AVPlayerItem, _OBJC_CLASS_$_AVURLAsset, _OBJC_CLASS_$_AVPlayerLayer, _AVLayerVideoGravityResizeAspect, _AVLayerVideoGravityResizeAspectFill, _AVMediaCharacteristicLegible, _AVMediaCharacteristicAudible, _AVPlayerItemDidPlayToEndTimeNotification, _AVPlayerItemFailedToPlayToEndTimeNotification'
stub CoreMedia /System/Library/Frameworks/CoreMedia.framework/CoreMedia \
    '_CMTimeGetSeconds, _CMTimeMakeWithSeconds, _kCMTimeZero'
stub CoreGraphics /System/Library/Frameworks/CoreGraphics.framework/CoreGraphics \
    '_CGRectGetHeight, _CGRectGetMinX, _CGRectGetMinY, _CGRectGetMidY, _CGRectGetMaxY, _CGRectOffset, _CGRectGetWidth, _CGRectEqualToRect, _CGRectIsEmpty, _CGImageGetBytesPerRow, _CGImageGetHeight, _CGImageRelease, _CGBitmapContextCreate, _CGBitmapContextCreateImage, _CGColorSpaceCreateDeviceRGB, _CGColorSpaceRelease, _CGContextRelease, _CGContextSetTextPosition'

stub CoreText /System/Library/Frameworks/CoreText.framework/CoreText \
    '_CTFontCreateWithName, _CTLineCreateTruncatedLine, _CTLineCreateWithAttributedString, _CTLineDraw, _CTLineGetTypographicBounds, _CTLineGetTrailingWhitespaceWidth, _CTTypesetterCreateWithAttributedString, _CTTypesetterSuggestLineBreak, _kCTFontAttributeName, _kCTForegroundColorAttributeName'
stub UIKit /System/Library/Frameworks/UIKit.framework/UIKit \
    '_OBJC_CLASS_$_UIImage, _OBJC_CLASS_$_UIImageView, _OBJC_CLASS_$_UIView, _OBJC_CLASS_$_UILabel, _OBJC_CLASS_$_UIFont, _OBJC_CLASS_$_UIColor, _UIGraphicsBeginImageContextWithOptions, _UIGraphicsEndImageContext, _UIGraphicsGetCurrentContext, _UIGraphicsGetImageFromCurrentImageContext, _UIImagePNGRepresentation'
stub ImageIO /System/Library/Frameworks/ImageIO.framework/ImageIO \
    '_CGImageSourceCreateThumbnailAtIndex, _CGImageSourceCreateWithData, _kCGImageSourceCreateThumbnailFromImageAlways, _kCGImageSourceCreateThumbnailWithTransform, _kCGImageSourceThumbnailMaxPixelSize'

demo_flags=()
if [[ ${REVIVEPLEX_DEMO_SCREENSHOTS:-0} == 1 ]]; then demo_flags=(-DREVIVEPLEX_DEMO_SCREENSHOTS); fi
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
for source in Localization PlexClient LiveLibrary Playback RangeStream DirectPlay Artwork PlexLink; do
    xcrun --sdk iphoneos clang -target armv7-apple-ios8.0 -isysroot "$sdk" -marm \
        ${demo_flags[@]+"${demo_flags[@]}"} -DREVIVEPLEX_PRODUCTION -fobjc-arc -fblocks -fno-exceptions -fno-objc-exceptions -Xclang -fno-objc-convert-messages-to-runtime-calls \
        -fno-stack-protector -Wall -Wextra -Werror -O2 \
        -c "$here/src/$source.m" -o "$work/$source.o"
done

shelf_flags=()
if [[ ${REVIVEPLEX_ENABLE_SHELVES:-1} == 1 ]]; then shelf_flags=(-DREVIVEPLEX_SHELVES); fi
xcrun --sdk iphoneos clang -target armv7-apple-ios8.0 -marm ${shelf_flags[@]+"${shelf_flags[@]}"} -DREVIVEPLEX_LIVE -DREVIVEPLEX_PLAYBACK -DREVIVEPLEX_ARTWORK -DREVIVEPLEX_AUTOSTART -DREVIVEPLEX_PRODUCTION -fblocks -fno-objc-arc -fno-stack-protector \
    -Wall -Wextra -Werror -Wno-cast-function-type-mismatch -Oz \
    -c "$here/src/RevivePlex.m" -o "$work/RevivePlex.o"
xcrun ld -bundle -arch armv7 -platform_version ios 8.0 8.0 -no_uuid \
    -o "$work/RevivePlex" "$work/RevivePlex.o" "$work/Localization.o" "$work/LiveLibrary.o" "$work/PlexClient.o" "$work/Playback.o" "$work/RangeStream.o" "$work/DirectPlay.o" "$work/Artwork.o" "$work/PlexLink.o" \
    "$work/libSystem.tbd" "$work/libobjc.tbd" "$work/CoreFoundation.tbd" "$work/Foundation.tbd" \
    "$work/AVFoundation.tbd" "$work/CoreMedia.tbd" "$work/CoreGraphics.tbd" "$work/UIKit.tbd" "$work/ImageIO.tbd" "$work/CoreText.tbd"
codesign --force --sign - --digest-algorithm=sha1,sha256 "$work/RevivePlex"
codesign --verify --verbose=2 "$work/RevivePlex"
plutil -lint "$here/resources/Info.plist"
mkdir -p "$output"
install -m 755 "$work/RevivePlex" "$output/RevivePlex"
install -m 644 "$here/resources/Info.plist" "$output/Info.plist"
printf '%s\n' "$output"
