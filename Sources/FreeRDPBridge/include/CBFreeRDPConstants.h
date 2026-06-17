//
// CBFreeRDPConstants.h
// SkyBridge Compass Pro - FreeRDP 桥接常量定义
//
// 历史说明：
// 本文件曾手写 FreeRDP 设置键 / 像素格式 / 输入标志常量，但其中的设置键值是「伪造」的
// （例如 FreeRDP_DesktopWidth 写成 3，真实值是 129；Port/Username/Password 同样错位），
// 会把连接参数写入错误的设置槽位。现已改为直接包含真实的 FreeRDP/WinPR 3.26.0 头
// （见 CBFreeRDPClient.m 顶部），所有这些常量与结构体偏移均由编译器解析。
//
// 因此本文件不再定义任何 FreeRDP 常量：再 #define FreeRDP_* 会与
// <freerdp/settings_keys.h> 的枚举冲突（宏会破坏枚举定义）。保留空壳仅为兼容历史导入。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// （有意为空）所有 FreeRDP 常量来自真实头文件。

NS_ASSUME_NONNULL_END
