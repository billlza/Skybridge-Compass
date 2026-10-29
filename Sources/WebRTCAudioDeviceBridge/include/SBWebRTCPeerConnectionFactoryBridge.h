#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class RTCPeerConnectionFactory;

@interface SBWebRTCPeerConnectionFactoryBridge : NSObject

+ (RTCPeerConnectionFactory *)makePeerConnectionFactoryWithSystemAudioDevice;

@end

NS_ASSUME_NONNULL_END
