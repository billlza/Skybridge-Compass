#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SBWebRTCSystemAudioDevice : NSObject

+ (instancetype)sharedDevice;

/// Claims exclusive ownership of recorded system audio.
///
/// Returns YES when @c ownerToken owns capture after the call (either it just claimed a free
/// device, or it already owned it). Returns NO when a DIFFERENT owner is already active: the
/// incumbent is preserved and the caller must not assume its audio is being captured.
/// The device is a process-wide singleton with a single capture cursor, so a silent takeover
/// would kill the incumbent session's audio with no error anywhere.
- (BOOL)activateRecordedAudioOwnerWithToken:(NSUUID *)ownerToken NS_SWIFT_NAME(activateRecordedAudioOwner(withToken:));
- (void)retireRecordedAudioOwnerWithToken:(NSUUID *)ownerToken;

- (void)pushRecordedPCM16InterleavedData:(NSData *)data
                              sampleRate:(NSInteger)sampleRate
                            channelCount:(NSInteger)channelCount
                              frameCount:(NSInteger)frameCount
                              ownerToken:(NSUUID *)ownerToken;

@end

NS_ASSUME_NONNULL_END
