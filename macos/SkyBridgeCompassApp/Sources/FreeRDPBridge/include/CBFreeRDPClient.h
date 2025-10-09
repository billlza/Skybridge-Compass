#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, CBFreeRDPFrameType) {
    CBFreeRDPFrameTypeBGRA = 0,
    CBFreeRDPFrameTypeH264 = 1,
    CBFreeRDPFrameTypeHEVC = 2
};

typedef void (^CBFreeRDPFrameCallback)(NSData *frameData,
                                       uint32_t width,
                                       uint32_t height,
                                       uint32_t stride,
                                       CBFreeRDPFrameType frameType);

typedef void (^CBFreeRDPStateCallback)(NSString *stateDescription);

typedef NS_ENUM(NSUInteger, CBFreeRDPClientState) {
    CBFreeRDPClientStateIdle,
    CBFreeRDPClientStateConnecting,
    CBFreeRDPClientStateConnected,
    CBFreeRDPClientStateFailed,
    CBFreeRDPClientStateDisconnected
};

@interface CBFreeRDPClient : NSObject

@property (atomic, readonly) CBFreeRDPClientState state;
@property (atomic, copy, nullable) CBFreeRDPFrameCallback frameCallback;
@property (atomic, copy, nullable) CBFreeRDPStateCallback stateCallback;
@property (atomic, readonly) NSString *targetHost;
@property (atomic, readonly) uint16_t targetPort;

- (instancetype)initWithHost:(NSString *)host
                         port:(uint16_t)port
                     username:(NSString *)username
                     password:(NSString *)password
                       domain:(nullable NSString *)domain;

- (BOOL)connectWithError:(NSError * _Nullable * _Nullable)error;
- (void)disconnect;
- (void)submitPointerEventWithX:(uint16_t)x
                               y:(uint16_t)y
                       buttonMask:(uint16_t)mask;
- (void)submitKeyboardEventWithCode:(uint16_t)code
                                down:(BOOL)down;

@end

NS_ASSUME_NONNULL_END
