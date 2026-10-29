#import "SBWebRTCPeerConnectionFactoryBridge.h"

#import <WebRTC/RTCAudioDevice.h>
#import <WebRTC/RTCDefaultVideoDecoderFactory.h>
#import <WebRTC/RTCDefaultVideoEncoderFactory.h>
#import <WebRTC/RTCPeerConnectionFactory.h>

#import "SBWebRTCSystemAudioDevice.h"

@implementation SBWebRTCPeerConnectionFactoryBridge

+ (RTCPeerConnectionFactory *)makePeerConnectionFactoryWithSystemAudioDevice {
    RTCDefaultVideoEncoderFactory *encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
    RTCDefaultVideoDecoderFactory *decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];
    return [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                     decoderFactory:decoderFactory
                                                        audioDevice:(id<RTCAudioDevice>)[SBWebRTCSystemAudioDevice sharedDevice]];
}

@end
