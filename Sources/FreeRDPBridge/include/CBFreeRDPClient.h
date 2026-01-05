//
// CBFreeRDPClient.h
// SkyBridge FreeRDP Bridge
//
// 说明：
// - FreeRDP 3.x 客户端桥接接口
// - 支持动态加载 FreeRDP 库
// - Apple Silicon 硬件加速支持
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

// MARK: - 配置设置

/// 配置显示设置
/// @param displaySettings 显示设置字典
/// 支持的键：
/// - width (NSNumber): 桌面宽度
/// - height (NSNumber): 桌面高度
/// - colorDepth (NSNumber): 色深 (8/16/24/32)
/// - fullScreenMode (NSNumber/BOOL): 是否全屏
/// - multiMonitorSupport (NSNumber/BOOL): 是否支持多显示器
/// - preferredCodec (NSNumber): 首选编解码器 (0=H.264, 1=HEVC)
- (void)configureDisplaySettings:(NSDictionary<NSString *, id> *)displaySettings;

/// 配置交互设置
/// @param interactionSettings 交互设置字典
/// 支持的键：
/// - enableClipboardSync (NSNumber/BOOL): 启用剪贴板同步
/// - enableAudioRedirection (NSNumber/BOOL): 启用音频重定向
/// - enablePrinterRedirection (NSNumber/BOOL): 启用打印机重定向
/// - enableFileTransfer (NSNumber/BOOL): 启用文件传输
- (void)configureInteractionSettings:(NSDictionary<NSString *, id> *)interactionSettings;

/// 配置网络设置
/// @param networkSettings 网络设置字典
/// 支持的键：
/// - connectionType (NSNumber): 连接类型 (0-7)
/// - enableEncryption (NSNumber/BOOL): 启用加密
/// - enableUDPTransport (NSNumber/BOOL): 启用 UDP 传输
/// - connectionTimeout (NSNumber): 连接超时 (毫秒)
- (void)configureNetworkSettings:(NSDictionary<NSString *, id> *)networkSettings;

/// 应用所有设置
/// @param allSettings 包含 displaySettings, interactionSettings, networkSettings 的字典
- (void)applyAllSettings:(NSDictionary<NSString *, id> *)allSettings;

// MARK: - Apple Silicon 支持

/// 检测是否为 Apple Silicon
- (BOOL)detectAppleSilicon;

/// 初始化 Apple Silicon 解码器
- (void)initializeAppleSiliconDecoder;

/// 配置 Apple Silicon 相关设置
- (void)configureAppleSiliconSettings;

@end

NS_ASSUME_NONNULL_END
