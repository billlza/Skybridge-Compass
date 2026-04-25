#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SBWebRTCSystemAudioDevice : NSObject

+ (instancetype)sharedDevice;

- (void)pushRecordedPCM16InterleavedData:(NSData *)data
                              sampleRate:(NSInteger)sampleRate
                            channelCount:(NSInteger)channelCount
                              frameCount:(NSInteger)frameCount;

@end

NS_ASSUME_NONNULL_END
