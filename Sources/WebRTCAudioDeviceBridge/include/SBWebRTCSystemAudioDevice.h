#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SBWebRTCSystemAudioDevice : NSObject

+ (instancetype)sharedDevice;

- (void)activateRecordedAudioOwnerWithToken:(NSUUID *)ownerToken;
- (void)retireRecordedAudioOwnerWithToken:(NSUUID *)ownerToken;

- (void)pushRecordedPCM16InterleavedData:(NSData *)data
                              sampleRate:(NSInteger)sampleRate
                            channelCount:(NSInteger)channelCount
                              frameCount:(NSInteger)frameCount
                              ownerToken:(NSUUID *)ownerToken;

@end

NS_ASSUME_NONNULL_END
