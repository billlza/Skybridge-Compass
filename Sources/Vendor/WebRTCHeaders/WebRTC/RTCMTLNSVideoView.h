/*
 * Minimal shim for RTCMTLNSVideoView (macOS).
 *
 * Some WebRTC XCFramework distributions omit this header from the macOS slice's
 * `WebRTC.framework/Headers/`, yet the umbrella header still imports it.
 *
 * This declaration is intentionally minimal: it exists to let the WebRTC module
 * import successfully under SwiftPM on macOS. If you rely on additional APIs,
 * prefer updating the underlying WebRTC binary or replacing this shim with the
 * upstream header.
 */
 
#pragma once

#import <Foundation/Foundation.h>

#import "RTCVideoRenderer.h"
#import "sdk/objc/base/RTCMacros.h"

#if __has_include(<AppKit/AppKit.h>)
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

RTC_OBJC_EXPORT
@interface RTC_OBJC_TYPE(RTCMTLNSVideoView) : NSView <RTC_OBJC_TYPE(RTCVideoRenderer)>

@property(nonatomic, weak) id<RTC_OBJC_TYPE(RTCVideoViewDelegate)> delegate;
@property(nonatomic, getter=isEnabled) BOOL enabled;
@property(nonatomic, nullable) NSValue *rotationOverride;

@end

NS_ASSUME_NONNULL_END

#endif

