//
// CBFreeRDPClient.h
// SkyBridge FreeRDP Bridge
//
// 说明：
// - FreeRDP 3.x 客户端桥接接口
// - 分开验证并动态加载 FreeRDP core/client 库
// - 软件 GDI BGRA 渲染与鼠标/键盘输入
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - 客户端状态枚举

typedef NS_ENUM(NSInteger, CBFreeRDPClientState) {
    CBFreeRDPClientStateIdle = 0,           // 空闲
    CBFreeRDPClientStateConnecting,         // 正在连接
    CBFreeRDPClientStateConnected,          // 已连接
    CBFreeRDPClientStateDisconnecting,      // 正在断开
    CBFreeRDPClientStateDisconnected,       // 已断开
    CBFreeRDPClientStateFailed              // 连接失败
};

// MARK: - 帧类型枚举

typedef NS_ENUM(NSInteger, CBFreeRDPFrameType) {
    CBFreeRDPFrameTypeBGRA = 0,            // BGRA 格式
    CBFreeRDPFrameTypeBGRX,                // BGRX 格式
    CBFreeRDPFrameTypeYUV                  // YUV 格式
};

// MARK: - 回调块定义

/// 帧数据回调
/// @param frameData 帧数据 (BGRA32 格式)
/// @param width 宽度
/// @param height 高度
/// @param stride 行字节数
/// @param frameType 帧类型
typedef void (^CBFreeRDPFrameCallback)(NSData *frameData,
                                        uint32_t width,
                                        uint32_t height,
                                        uint32_t stride,
                                        CBFreeRDPFrameType frameType);

/// 状态变化回调
/// @param status 状态描述字符串
typedef void (^CBFreeRDPStateCallback)(NSString *status);

// MARK: - CBFreeRDPClient 接口

@interface CBFreeRDPClient : NSObject

// MARK: - 属性

/// 当前连接状态 (只读)
@property (atomic, readonly) CBFreeRDPClientState state;

/// 目标主机地址 (只读)
@property (atomic, readonly, copy) NSString *targetHost;

/// 目标端口 (只读)
@property (atomic, readonly) uint16_t targetPort;

/// 帧数据回调
@property (atomic, copy, nullable) CBFreeRDPFrameCallback frameCallback;

/// 状态变化回调
@property (atomic, copy, nullable) CBFreeRDPStateCallback stateCallback;

// MARK: - 初始化

/// 初始化 FreeRDP 客户端
/// @param host 目标主机地址
/// @param port 目标端口 (通常为 3389)
/// @param username 用户名
/// @param password 密码
/// @param domain 域名 (可选)
- (instancetype)initWithHost:(NSString *)host
                        port:(uint16_t)port
                    username:(NSString *)username
                    password:(NSString *)password
                      domain:(NSString * _Nullable)domain NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

// MARK: - 连接管理

/// 建立连接
/// @param error 错误信息 (输出参数)
/// @return 是否成功启动连接
- (BOOL)connectWithError:(NSError * _Nullable * _Nullable)error;

/// 断开连接
- (void)disconnect;

// MARK: - 输入事件

/// 发送鼠标事件
/// @param x X 坐标
/// @param y Y 坐标
/// @param buttonMask 按键掩码 (使用 PTR_FLAGS_* 常量)
- (void)submitPointerEventWithX:(uint16_t)x
                              y:(uint16_t)y
                      buttonMask:(uint16_t)buttonMask NS_SWIFT_NAME(submitPointerEvent(with:y:buttonMask:));

/// 发送键盘事件
/// @param code 扫描码
/// @param down 是否按下 (YES=按下, NO=释放)
- (void)submitKeyboardEventWithCode:(uint16_t)code
                               down:(BOOL)down;

// MARK: - 连接期设置

/// 校验并暂存必须在 FreeRDP connect 前应用的设置。
///
/// 只支持已接线且能验证写入结果的字段：
/// - displaySettings.width + displaySettings.height
/// - displaySettings.colorDepth (8/16/24/32)
/// - networkSettings.connectionType
///
/// 未接线字段、错误类型、超界值或活跃会话中改参都会显式失败。
/// 已暂存设置在 context ready 后、freerdp_connect 前严格写入。
- (BOOL)applyAllSettings:(NSDictionary<NSString *, id> *)allSettings
                   error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
