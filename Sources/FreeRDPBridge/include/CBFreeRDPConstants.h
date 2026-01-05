//
// CBFreeRDPConstants.h
// SkyBridge Compass Pro - FreeRDP 桥接常量定义
//
// 基于 FreeRDP 3.x API 标准
// 符合 Swift 6.2 严格并发和类型安全
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - FreeRDP 设置常量 (基于 FreeRDP 3.x API)
// 这些常量对应 FreeRDP 的 freerdp_settings_set_* API

// 显示设置
#define FreeRDP_DesktopWidth         3
#define FreeRDP_DesktopHeight        4
#define FreeRDP_ColorDepth          10

// 连接设置
#define FreeRDP_ServerHostname      20
#define FreeRDP_ServerPort          21
#define FreeRDP_Username            22
#define FreeRDP_Password            23
#define FreeRDP_Domain              24

// 性能优化设置
#define FreeRDP_NetworkAutoDetect   80
#define FreeRDP_BitmapCacheEnabled  81
#define FreeRDP_OffscreenCacheEnabled 82
#define FreeRDP_GlyphCacheEnabled   83

// 硬件加速编解码 (Apple Silicon 优化)
#define FreeRDP_GfxH264             100
#define FreeRDP_GfxAVC444           101
#define FreeRDP_GfxProgressive      102
#define FreeRDP_NSCodec             103
#define FreeRDP_RemoteFxCodec       104

// 连接类型 (用于带宽优化)
#define CONNECTION_TYPE_MODEM          1
#define CONNECTION_TYPE_BROADBAND_LOW  2
#define CONNECTION_TYPE_SATELLITE      3
#define CONNECTION_TYPE_BROADBAND_HIGH 4
#define CONNECTION_TYPE_WAN            5
#define CONNECTION_TYPE_LAN            6
#define CONNECTION_TYPE_AUTODETECT     7

// 鼠标事件标志 (RDP 协议)
#define PTR_FLAGS_HWHEEL            0x0400
#define PTR_FLAGS_WHEEL             0x0200
#define PTR_FLAGS_WHEEL_NEGATIVE    0x0100
#define PTR_FLAGS_MOVE              0x0800
#define PTR_FLAGS_DOWN              0x8000
#define PTR_FLAGS_BUTTON1           0x1000  // 左键
#define PTR_FLAGS_BUTTON2           0x2000  // 右键
#define PTR_FLAGS_BUTTON3           0x4000  // 中键

// 键盘事件标志
#define KBD_FLAGS_RELEASE           0x8000
#define KBD_FLAGS_DOWN              0x4000
#define KBD_FLAGS_EXTENDED          0x0100

// 视频格式
#define PIXEL_FORMAT_BGRX32         0x00000000
#define PIXEL_FORMAT_BGRA32         0x00000001

NS_ASSUME_NONNULL_END
