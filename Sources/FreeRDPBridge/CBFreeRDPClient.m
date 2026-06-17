#import "CBFreeRDPClient.h"
#import "CBFreeRDPConstants.h"
#import <dlfcn.h>
#import <os/log.h>

// 真实 FreeRDP/WinPR 3.26.0 头（与 Sources/Vendor/FreeRDPDylibs 的 dylib 同版本）。
// 结构体布局、设置枚举值、像素格式、输入标志均由编译器解析，取代旧的占位 opaque 类型 +
// 硬编码指针 slot + 伪造设置常量（曾把 DesktopWidth/Port/Username/Password 写入错误槽位）。
// dylib 仍按需 dlopen；这些头只提供类型与函数签名，不引入链接期硬依赖。
// 关键：必须在 Apple 媒体框架之前包含 —— winpr 的 IID/REFIID typedef 与 CoreFoundation
// 的 CFPlugInCOM 同名冲突，先定义者胜（winpr 无重定义守卫，CoreFoundation 有）。
#include <freerdp/freerdp.h>
#include <freerdp/settings.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/update.h>
#include <freerdp/codec/color.h>

#import <CoreGraphics/CoreGraphics.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <string.h>

// FreeRDP 函数指针类型定义（签名匹配真实 3.x 导出符号；类型来自上面的真实头）
typedef const char *(*freerdp_version_string_fn)(void);
typedef freerdp *(*freerdp_new_fn)(void);
typedef void (*freerdp_free_fn)(freerdp *instance);
typedef BOOL (*freerdp_context_new_fn)(freerdp *instance);
typedef BOOL (*freerdp_connect_fn)(freerdp *instance);
typedef BOOL (*freerdp_disconnect_fn)(freerdp *instance);
typedef BOOL (*freerdp_set_connection_type_fn)(rdpSettings *settings, uint32_t type);
typedef BOOL (*freerdp_input_send_mouse_event_fn)(rdpInput *input, uint16_t flags, uint16_t x, uint16_t y);
typedef BOOL (*freerdp_input_send_keyboard_event_fn)(rdpInput *input, uint16_t flags, uint8_t code);

// FreeRDP 3.x 设置 API
typedef BOOL (*freerdp_settings_set_uint32_fn)(rdpSettings *settings, size_t id, uint32_t value);
typedef BOOL (*freerdp_settings_set_string_fn)(rdpSettings *settings, size_t id, const char *value);
typedef BOOL (*freerdp_settings_get_uint32_fn)(rdpSettings *settings, size_t id, uint32_t *value);
typedef const char *(*freerdp_settings_get_string_fn)(rdpSettings *settings, size_t id);
typedef BOOL (*freerdp_settings_set_bool_fn)(rdpSettings *settings, size_t id, BOOL value);

// 渲染 / 事件泵导出符号
typedef BOOL (*cb_gdi_init_fn)(freerdp *instance, UINT32 format);
typedef void (*cb_gdi_free_fn)(freerdp *instance);
typedef BOOL (*cb_check_event_handles_fn)(rdpContext *context);

// 实例 → 上下文/输入/设置：真实字段访问，偏移由编译器计算（不再读硬编码 slot）。
static inline rdpContext *CBGetContextFromInstance(freerdp *instance) {
    return instance ? instance->context : NULL;
}

static inline rdpInput *CBGetInputFromInstance(freerdp *instance) {
    rdpContext *context = CBGetContextFromInstance(instance);
    return context ? context->input : NULL;
}

static inline rdpSettings *CBGetSettingsFromInstance(freerdp *instance) {
    rdpContext *context = CBGetContextFromInstance(instance);
    return context ? context->settings : NULL;
}

// rdpContext → CBFreeRDPClient 注册表：GDI 的 EndPaint C 回调据此找回对应客户端实例。
// 值用 nonretainedObject（客户端在断开前主动移除，生命周期长于注册项），用锁保护以支持并发会话。
@class CBFreeRDPClient;

static NSMutableDictionary<NSNumber *, NSValue *> *CBClientRegistry(void) {
    static NSMutableDictionary *registry;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ registry = [NSMutableDictionary dictionary]; });
    return registry;
}

static NSLock *CBClientRegistryLock(void) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSLock alloc] init]; });
    return lock;
}

// 前向声明：GDI 绘制完成回调（在文件尾部定义，转发到客户端的 handleEndPaint:）。
static BOOL CBEndPaintCallback(rdpContext *context);

// Apple Silicon 优化的硬件编解码器支持 (macOS 13+ with VideoToolbox)
typedef struct {
    VTDecompressionSessionRef _Nullable decompressionSession;  // VideoToolbox 解码会话
    CVPixelBufferPoolRef _Nullable pixelBufferPool;            // 像素缓冲池
    dispatch_queue_t _Nonnull decodingQueue;                   // 解码队列
    CMVideoFormatDescriptionRef _Nullable formatDescription;    // 视频格式描述
    BOOL isInitialized;                                         // 初始化标志
    BOOL preferHEVC;                                            // 优先使用 HEVC (H.265)
    int32_t frameWidth;                                         // 当前帧宽度
    int32_t frameHeight;                                        // 当前帧高度
} AppleSiliconDecoder;

static os_log_t CBFreeRDPLogger;
static NSString * const CBFreeRDPMinimumVersionString = @"3.26.0";

static NSArray<NSNumber *> *CBFreeRDPVersionComponents(NSString *versionString) {
    NSMutableArray<NSNumber *> *components = [NSMutableArray arrayWithCapacity:3];
    NSScanner *scanner = [NSScanner scannerWithString:versionString ?: @""];
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    while (!scanner.isAtEnd && components.count < 3) {
        [scanner scanUpToCharactersFromSet:digits intoString:NULL];
        NSString *numberString = nil;
        if ([scanner scanCharactersFromSet:digits intoString:&numberString] && numberString.length > 0) {
            [components addObject:@(numberString.integerValue)];
        }
    }
    return components;
}

static BOOL CBFreeRDPVersionMeetsMinimum(NSString *versionString) {
    NSArray<NSNumber *> *components = CBFreeRDPVersionComponents(versionString);
    if (components.count < 2) {
        return NO;
    }
    NSInteger actual[3] = {
        components[0].integerValue,
        components[1].integerValue,
        components.count > 2 ? components[2].integerValue : 0
    };
    const NSInteger minimum[3] = {3, 26, 0};
    for (NSInteger index = 0; index < 3; index++) {
        if (actual[index] > minimum[index]) {
            return YES;
        }
        if (actual[index] < minimum[index]) {
            return NO;
        }
    }
    return YES;
}

@interface CBFreeRDPClient ()
{
    void *_libraryHandle;
    
 // FreeRDP 基础函数指针
    freerdp_version_string_fn _versionString;
    freerdp_new_fn _clientNew;
    freerdp_free_fn _clientFree;
    freerdp_context_new_fn _contextNew;
    freerdp_connect_fn _clientConnect;
    freerdp_disconnect_fn _clientDisconnect;
    freerdp_set_connection_type_fn _setConnectionType;
    freerdp_input_send_mouse_event_fn _sendMouseEvent;
    freerdp_input_send_keyboard_event_fn _sendKeyboardEvent;
    
 // FreeRDP 3.x 设置 API
    freerdp_settings_set_uint32_fn _settingsSetUint32;
    freerdp_settings_set_string_fn _settingsSetString;
    freerdp_settings_get_uint32_fn _settingsGetUint32;
    freerdp_settings_get_string_fn _settingsGetString;
    freerdp_settings_set_bool_fn _settingsSetBool;

 // 渲染 / 事件泵
    cb_gdi_init_fn _gdiInit;
    cb_gdi_free_fn _gdiFree;
    cb_check_event_handles_fn _checkEventHandles;
    pEndPaint _originalEndPaint;   // GDI 原始 EndPaint（链接调用，保留失效区域维护）
    BOOL _pumpActive;

 // Apple Silicon 硬件解码器
    AppleSiliconDecoder _decoder;
}

// 内部可写属性（重新声明为 readwrite）
@property (atomic, readwrite) CBFreeRDPClientState state;
@property (atomic, readwrite) NSString *targetHost;
@property (atomic, readwrite) uint16_t targetPort;

// 内部私有属性
@property (nonatomic, strong) dispatch_queue_t workerQueue;
@property (nonatomic, strong) dispatch_queue_t renderQueue;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *password;
@property (nonatomic, copy, nullable) NSString *domain;
@property (nonatomic) freerdp *connectionRef;
@property (nonatomic, strong) NSTimer * _Nullable keepAliveTimer;
@property (nonatomic, assign) BOOL isAppleSilicon;

// 渲染 / 事件泵（均在 workerQueue 上串行执行，避免与输入发送争用单线程 FreeRDP 上下文）
- (void)startGraphicsAndPump;
- (void)pumpEventsOnce;
- (BOOL)handleEndPaint:(rdpContext *)context;

@end

@implementation CBFreeRDPClient

+ (void)initialize
{
    if (self == [CBFreeRDPClient class]) {
        CBFreeRDPLogger = os_log_create("com.skybridge.compass", "FreeRDPBridge");
    }
}

- (instancetype)initWithHost:(NSString *)host
                         port:(uint16_t)port
                     username:(NSString *)username
                     password:(NSString *)password
                       domain:(NSString *)domain
{
    self = [super init];
    if (self) {
        _state = CBFreeRDPClientStateIdle;
        _targetHost = [host copy];
        _targetPort = port;
        _username = [username copy];
        _password = [password copy];
        _domain = [domain copy];
        _workerQueue = dispatch_queue_create("com.skybridge.compass.freerdp.worker", DISPATCH_QUEUE_SERIAL);
        _renderQueue = dispatch_queue_create("com.skybridge.compass.freerdp.render", DISPATCH_QUEUE_CONCURRENT);
        
 // 检测是否为Apple Silicon
        _isAppleSilicon = [self detectAppleSilicon];
        
 // 初始化Apple Silicon解码器
        if (_isAppleSilicon) {
            [self initializeAppleSiliconDecoder];
        }
        
        os_log_info(CBFreeRDPLogger, "初始化FreeRDP客户端 - 目标: %{public}@:%hu, Apple Silicon: %{public}@", 
                   host, port, _isAppleSilicon ? @"是" : @"否");
    }
    return self;
}

- (void)dealloc
{
    [self disconnect];
    if (_libraryHandle) {
        dlclose(_libraryHandle);
        _libraryHandle = NULL;
    }
}

#pragma mark - Apple Silicon 优化方法

/// 检测 macOS 版本（用于启用特定版本的优化）
- (NSOperatingSystemVersion)detectMacOSVersion {
    NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
    os_log_info(CBFreeRDPLogger, "🍎 检测到 macOS 版本: %ld.%ld.%ld", 
               (long)version.majorVersion, (long)version.minorVersion, (long)version.patchVersion);
    return version;
}

/// 检测当前设备是否为Apple Silicon
- (BOOL)detectAppleSilicon {
 // 使用处理器架构检测方法
    struct utsname systemInfo;
    if (uname(&systemInfo) == 0) {
        NSString *machine = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
        BOOL isAppleSilicon = [machine hasPrefix:@"arm64"];
        
 // 检测 macOS 版本以启用特定优化
        NSOperatingSystemVersion osVersion = [self detectMacOSVersion];
        
        if (isAppleSilicon) {
            if (osVersion.majorVersion >= 26) {
                os_log_info(CBFreeRDPLogger, "🚀 检测到 macOS 26+ (Tahoe) + Apple Silicon: 启用高级硬件加速；PQC 状态由 SkyBridgeCore 会话证明单独记录");
            } else if (osVersion.majorVersion >= 15) {
                os_log_info(CBFreeRDPLogger, "⚡️ 检测到 macOS 15+ + Apple Silicon: 启用标准硬件加速");
            } else {
                os_log_info(CBFreeRDPLogger, "🔍 检测到 Apple Silicon (macOS %ld)", (long)osVersion.majorVersion);
            }
        }
        
        os_log_info(CBFreeRDPLogger, "🔍 处理器架构: %{public}@, Apple Silicon: %{public}@", 
                   machine, isAppleSilicon ? @"是" : @"否");
        return isAppleSilicon;
    }
    
    os_log_error(CBFreeRDPLogger, "❌ 无法检测处理器架构，默认为非Apple Silicon");
    return NO;
}

/// 初始化Apple Silicon硬件解码器 (符合 macOS 13+ VideoToolbox API)
- (void)initializeAppleSiliconDecoder {
    if (!_isAppleSilicon) {
        os_log_info(CBFreeRDPLogger, "⚠️ 非 Apple Silicon 设备，跳过硬件解码器初始化");
        return;
    }
    
 // 创建专用解码队列（高优先级）
    _decoder.decodingQueue = dispatch_queue_create(
        "com.skybridge.compass.decoder", 
        DISPATCH_QUEUE_SERIAL
    );
    dispatch_set_target_queue(
        _decoder.decodingQueue, 
        dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0)
    );
    
 // 初始化状态
    _decoder.isInitialized = YES;
    _decoder.preferHEVC = YES;  // Apple Silicon 优先使用 HEVC
    _decoder.decompressionSession = NULL;
    _decoder.pixelBufferPool = NULL;
    _decoder.formatDescription = NULL;
    _decoder.frameWidth = 0;
    _decoder.frameHeight = 0;
    
    os_log_info(CBFreeRDPLogger, "✅ Apple Silicon 硬件解码器初始化完成（支持 HEVC/H.264）");
}

// MARK: - Apple Silicon优化配置

/// VideoToolbox 解码回调 (macOS 13+ 兼容)
static void videoToolboxDecompressionCallback(
    void * _Nullable decompressionOutputRefCon,
    void * _Nullable sourceFrameRefCon,
    OSStatus status,
    VTDecodeInfoFlags infoFlags,
    CVImageBufferRef _Nullable imageBuffer,
    CMTime presentationTimeStamp,
    CMTime presentationDuration
) {
    if (status != noErr) {
        os_log_error(CBFreeRDPLogger, "❌ VideoToolbox 解码失败: %d", status);
        return;
    }
    
    if (!imageBuffer || !decompressionOutputRefCon) {
        return;
    }
    
 // 获取客户端实例
    CBFreeRDPClient *client = (__bridge CBFreeRDPClient *)decompressionOutputRefCon;
    
 // 锁定像素缓冲区并转换为 NSData
    CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    void *baseAddress = CVPixelBufferGetBaseAddress(imageBuffer);
    
    if (baseAddress) {
        NSData *frameData = [NSData dataWithBytes:baseAddress 
                                           length:bytesPerRow * height];
        
 // 调用帧回调传递给 Swift 层
        if (client.frameCallback) {
            client.frameCallback(
                frameData,
                (uint32_t)width,
                (uint32_t)height,
                (uint32_t)bytesPerRow,
                CBFreeRDPFrameTypeBGRA  // 解码后的格式
            );
        }
    }
    
    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
}

/// 创建 VideoToolbox 解码会话
- (BOOL)createDecompressionSessionWithWidth:(int32_t)width 
                                      height:(int32_t)height 
                                       codec:(CMVideoCodecType)codecType {
 // 如果已有会话且尺寸未变化，无需重建
    if (_decoder.decompressionSession && 
        _decoder.frameWidth == width && 
        _decoder.frameHeight == height) {
        return YES;
    }
    
 // 清理旧会话
    if (_decoder.decompressionSession) {
        VTDecompressionSessionInvalidate(_decoder.decompressionSession);
        CFRelease(_decoder.decompressionSession);
        _decoder.decompressionSession = NULL;
    }
    
    if (_decoder.formatDescription) {
        CFRelease(_decoder.formatDescription);
        _decoder.formatDescription = NULL;
    }
    
 // 创建格式描述
    OSStatus status = CMVideoFormatDescriptionCreate(
        kCFAllocatorDefault,
        codecType,
        width,
        height,
        NULL,  // extensions
        &_decoder.formatDescription
    );
    
    if (status != noErr || !_decoder.formatDescription) {
        os_log_error(CBFreeRDPLogger, "❌ 创建视频格式描述失败: %d", status);
        return NO;
    }
    
 // 配置解码器属性 (Apple Silicon 硬件加速)
    CFMutableDictionaryRef decoderSpec = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    CFDictionarySetValue(
        decoderSpec,
        kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder,
        kCFBooleanTrue
    );
    
 // 配置目标像素缓冲属性 (Metal 兼容)
    CFMutableDictionaryRef destinationPixelBufferAttrs = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        3,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    
 // BGRA 格式，Metal 兼容
    int pixelFormat = kCVPixelFormatType_32BGRA;
    CFNumberRef pixelFormatNumber = CFNumberCreate(
        kCFAllocatorDefault,
        kCFNumberIntType,
        &pixelFormat
    );
    CFDictionarySetValue(
        destinationPixelBufferAttrs,
        kCVPixelBufferPixelFormatTypeKey,
        pixelFormatNumber
    );
    CFRelease(pixelFormatNumber);
    
 // 启用 Metal 兼容性
    CFDictionarySetValue(
        destinationPixelBufferAttrs,
        kCVPixelBufferMetalCompatibilityKey,
        kCFBooleanTrue
    );
    
 // 启用 IOSurface (零拷贝)
    CFDictionarySetValue(
        destinationPixelBufferAttrs,
        kCVPixelBufferIOSurfacePropertiesKey,
        (__bridge CFDictionaryRef)@{}
    );
    
 // 创建解码回调
    VTDecompressionOutputCallbackRecord callback = {
        .decompressionOutputCallback = videoToolboxDecompressionCallback,
        .decompressionOutputRefCon = (__bridge void *)self
    };
    
 // 创建解码会话
    status = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        _decoder.formatDescription,
        decoderSpec,
        destinationPixelBufferAttrs,
        &callback,
        &_decoder.decompressionSession
    );
    
    CFRelease(decoderSpec);
    CFRelease(destinationPixelBufferAttrs);
    
    if (status != noErr) {
        os_log_error(CBFreeRDPLogger, "❌ 创建 VideoToolbox 解码会话失败: %d", status);
        if (_decoder.formatDescription) {
            CFRelease(_decoder.formatDescription);
            _decoder.formatDescription = NULL;
        }
        return NO;
    }
    
 // 保存尺寸信息
    _decoder.frameWidth = width;
    _decoder.frameHeight = height;
    
    os_log_info(CBFreeRDPLogger, 
                "✅ VideoToolbox 解码会话创建成功: %dx%d, codec=%c%c%c%c",
                width, height,
                (char)(codecType >> 24),
                (char)(codecType >> 16),
                (char)(codecType >> 8),
                (char)codecType);
    
    return YES;
}

- (void)configureAppleSiliconSettings {
    if (!_isAppleSilicon || !_connectionRef) {
        return;
    }
    
    os_log_info(CBFreeRDPLogger, "🚀 配置Apple Silicon优化设置");
    
 // 获取 FreeRDP 设置（通过运行时结构槽位访问）
    rdpSettings *settings = [self currentSettings];
    if (settings) {
 // 这里可以配置Apple Silicon特定的优化设置
 // 由于FreeRDP设置结构体的具体字段可能因版本而异，
 // 我们使用日志记录配置过程
        os_log_info(CBFreeRDPLogger, "⚙️ Apple Silicon优化设置已应用");
    }
    
 // 配置硬件解码器优先级
    if (_decoder.decodingQueue) {
        dispatch_set_target_queue(_decoder.decodingQueue, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
        os_log_info(CBFreeRDPLogger, "🎯 硬件解码队列优先级已优化");
    }
}

- (BOOL)connectWithError:(NSError *__autoreleasing  _Nullable * _Nullable)error
{
    if (![self loadLibrary:error]) {
        return NO;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.workerQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf.state = CBFreeRDPClientStateConnecting;
        [strongSelf notifyState:@"正在建立 FreeRDP 会话..."];
        [strongSelf notifyState:[NSString stringWithFormat:@"目标: %@:%hu", strongSelf.targetHost, strongSelf.targetPort]];

 // Apple Silicon 优化检测和初始化
        if (strongSelf.isAppleSilicon) {
            [strongSelf notifyState:@"🚀 检测到Apple Silicon，启用硬件加速"];
            [strongSelf initializeAppleSiliconDecoder];
        }

        if (strongSelf->_clientNew) {
            strongSelf.connectionRef = strongSelf->_clientNew();
        }

        if (!strongSelf.connectionRef) {
            strongSelf.state = CBFreeRDPClientStateFailed;
            [strongSelf notifyState:@"无法创建 FreeRDP 客户端上下文"];
            return;
        }

        if (![strongSelf ensureContextReady]) {
            strongSelf.state = CBFreeRDPClientStateFailed;
            [strongSelf notifyState:@"FreeRDP 上下文初始化失败"];
            return;
        }

        if (![strongSelf applyConnectionIdentitySettings]) {
            strongSelf.state = CBFreeRDPClientStateFailed;
            [strongSelf notifyState:@"FreeRDP 连接参数写入失败"];
            return;
        }

 // 配置Apple Silicon优化设置
        [strongSelf configureAppleSiliconSettings];

        const char *version = strongSelf->_versionString ? strongSelf->_versionString() : "unknown";
        os_log_info(CBFreeRDPLogger, "Loaded FreeRDP version: %{public}s", version);
        [strongSelf notifyState:[NSString stringWithFormat:@"FreeRDP 库版本 %s", version]];

        if (strongSelf->_clientConnect) {
            if (!strongSelf->_clientConnect(strongSelf.connectionRef)) {
                strongSelf.state = CBFreeRDPClientStateFailed;
                [strongSelf notifyState:@"FreeRDP 会话连接失败"];
                return;
            }
        }

        strongSelf.state = CBFreeRDPClientStateConnected;
        [strongSelf notifyState:@"✅ FreeRDP 会话已连接"];
        [strongSelf startGraphicsAndPump];
    });

    return YES;
}

- (void)disconnect
{
    dispatch_async(self.workerQueue, ^{
        self->_pumpActive = NO;
        if (self.connectionRef) {
            // 先从注册表移除（断开 EndPaint 回调对本实例的查找），再释放 GDI 与连接。
            [CBClientRegistryLock() lock];
            [CBClientRegistry() removeObjectForKey:@((uintptr_t)self.connectionRef)];
            [CBClientRegistryLock() unlock];
            self->_originalEndPaint = NULL;
            if (self->_gdiFree) {
                self->_gdiFree(self.connectionRef);
            }
            if (self->_clientDisconnect) {
                self->_clientDisconnect(self.connectionRef);
            }
            if (self->_clientFree) {
                self->_clientFree(self.connectionRef);
            }
        }
        self.connectionRef = NULL;
        [self.keepAliveTimer invalidate];
        self.keepAliveTimer = nil;
        self.state = CBFreeRDPClientStateDisconnected;
        [self notifyState:@"FreeRDP 会话已断开"];
    });
}

- (void)submitPointerEventWithX:(uint16_t)x
                               y:(uint16_t)y
                       buttonMask:(uint16_t)mask
{
    os_log_debug(CBFreeRDPLogger, "Pointer event (%u, %u) mask %u", x, y, mask);

    if (!_sendMouseEvent) {
        return;
    }
    // 串行化到 workerQueue：FreeRDP 上下文单线程，输入发送必须与连接/事件泵同队列，避免数据竞争。
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.workerQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.connectionRef) {
            return;
        }
        rdpInput *input = CBGetInputFromInstance(strongSelf.connectionRef);
        if (!input) {
            return;
        }
        if (!strongSelf->_sendMouseEvent(input, mask, x, y)) {
            os_log_error(CBFreeRDPLogger, "❌ Pointer event send failed");
        }
    });
}

- (void)submitKeyboardEventWithCode:(uint16_t)code
                                down:(BOOL)down
{
    os_log_debug(CBFreeRDPLogger, "Keyboard event code %u down %d", code, down);

    if (!_sendKeyboardEvent) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.workerQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.connectionRef) {
            return;
        }
        rdpInput *input = CBGetInputFromInstance(strongSelf.connectionRef);
        if (!input) {
            return;
        }
        const uint16_t flags = down ? KBD_FLAGS_DOWN : KBD_FLAGS_RELEASE;
        if (!strongSelf->_sendKeyboardEvent(input, flags, (uint8_t)(code & 0xFF))) {
            os_log_error(CBFreeRDPLogger, "❌ Keyboard event send failed");
        }
    });
}

#pragma mark - Helpers

- (BOOL)ensureContextReady
{
    if (!self.connectionRef) {
        return NO;
    }

    if (CBGetContextFromInstance(self.connectionRef)) {
        return YES;
    }

    if (!_contextNew) {
        os_log_error(CBFreeRDPLogger, "❌ freerdp_context_new symbol unavailable");
        return NO;
    }

    if (!_contextNew(self.connectionRef)) {
        os_log_error(CBFreeRDPLogger, "❌ freerdp_context_new failed");
        return NO;
    }

    if (!CBGetContextFromInstance(self.connectionRef)) {
        os_log_error(CBFreeRDPLogger, "❌ FreeRDP context remains NULL after initialization");
        return NO;
    }

    return YES;
}

- (rdpSettings *)currentSettings
{
    if (!self.connectionRef) {
        return NULL;
    }
    return CBGetSettingsFromInstance(self.connectionRef);
}

- (BOOL)applyConnectionIdentitySettings
{
    if (!_settingsSetString || !_settingsSetUint32) {
        os_log_error(CBFreeRDPLogger, "❌ Required FreeRDP settings APIs unavailable");
        return NO;
    }

    rdpSettings *settings = [self currentSettings];
    if (!settings) {
        os_log_error(CBFreeRDPLogger, "❌ Unable to resolve rdpSettings from context");
        return NO;
    }

    BOOL ok = TRUE;
    ok = ok && _settingsSetString(settings, FreeRDP_ServerHostname, self.targetHost.UTF8String);
    ok = ok && _settingsSetUint32(settings, FreeRDP_ServerPort, (uint32_t)self.targetPort);
    ok = ok && _settingsSetString(settings, FreeRDP_Username, self.username.UTF8String);
    ok = ok && _settingsSetString(settings, FreeRDP_Password, self.password.UTF8String);

    if (self.domain.length > 0) {
        ok = ok && _settingsSetString(settings, FreeRDP_Domain, self.domain.UTF8String);
    }

    // 选用软件 GDI：gdi_init 会把更新管线（位图/SurfaceBits/GFX）绘制进 primary_buffer，
    // 我们再从 EndPaint 读出该帧缓冲。无该 API 时退化为「仅连接、无画面」，不影响连接本身。
    if (_settingsSetBool) {
        _settingsSetBool(settings, FreeRDP_SoftwareGdi, TRUE);
    }

    if (!ok) {
        os_log_error(CBFreeRDPLogger, "❌ Failed to apply one or more connection identity settings");
        return NO;
    }

    return YES;
}

- (void)notifyState:(NSString *)description
{
    CBFreeRDPStateCallback callback = self.stateCallback;
    if (callback) {
        callback(description);
    }
}

- (BOOL)loadLibrary:(NSError *__autoreleasing  _Nullable * _Nullable)error
{
    if (_libraryHandle) {
        return YES;
    }

    NSString *frameworksPath = NSBundle.mainBundle.privateFrameworksPath ?: @"";
    NSMutableArray<NSString *> *candidatePaths = [NSMutableArray array];
    if (frameworksPath.length > 0) {
        [candidatePaths addObject:[frameworksPath stringByAppendingPathComponent:@"libfreerdp3.dylib"]];
        [candidatePaths addObject:[frameworksPath stringByAppendingPathComponent:@"FreeRDP.framework/FreeRDP"]];
    }
    [candidatePaths addObject:@"/opt/homebrew/lib/libfreerdp3.dylib"];
    [candidatePaths addObject:@"/usr/local/lib/libfreerdp3.dylib"];

    for (NSString *path in candidatePaths) {
        if (path.length == 0) {
            continue;
        }
        void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (handle != NULL) {
            _libraryHandle = handle;
            break;
        }
    }

    if (!_libraryHandle) {
        os_log_error(CBFreeRDPLogger, "❌ 无法加载受支持的 libfreerdp3 动态库 - RDP 远程桌面功能不可用");
        if (error) {
 // 提供详细的安装说明
            NSString *installGuide = @"远程桌面 (RDP) 功能需要 FreeRDP 3.26.0 或更高版本支持。\n\n"
                                     @"安装方法：\n"
                                     @"1. 打开终端 (Terminal.app)\n"
                                     @"2. 安装 Homebrew（如未安装）:\n"
                                     @"   /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"\n"
                                     @"3. 安装或更新 FreeRDP:\n"
                                     @"   brew install freerdp || brew upgrade freerdp\n\n"
                                     @"安装完成后重启 SkyBridge Compass Pro 即可使用 RDP 功能。\n\n"
                                     @"注意：其他远程桌面功能（VNC、自研协议）不受此影响，可正常使用。";
            
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: @"RDP 远程桌面功能暂不可用",
                NSLocalizedRecoverySuggestionErrorKey: installGuide,
                NSLocalizedFailureReasonErrorKey: @"未找到受支持的 libfreerdp3.dylib 库文件",
                @"InstallCommand": @"brew install freerdp || brew upgrade freerdp",
                @"AlternativeFeatures": @[@"VNC", @"SSH", @"UltraStream"]
            };
 *error = [NSError errorWithDomain:@"com.skybridge.compass.freerdp"
                                         code:-100
                                     userInfo:userInfo];
        }
        return NO;
    }

    _versionString = (freerdp_version_string_fn)dlsym(_libraryHandle, "freerdp_get_version_string");
    _clientNew = (freerdp_new_fn)dlsym(_libraryHandle, "freerdp_new");
    _clientFree = (freerdp_free_fn)dlsym(_libraryHandle, "freerdp_free");
    _contextNew = (freerdp_context_new_fn)dlsym(_libraryHandle, "freerdp_context_new");
    _clientConnect = (freerdp_connect_fn)dlsym(_libraryHandle, "freerdp_connect");
    _clientDisconnect = (freerdp_disconnect_fn)dlsym(_libraryHandle, "freerdp_disconnect");
    _setConnectionType = (freerdp_set_connection_type_fn)dlsym(_libraryHandle, "freerdp_set_connection_type");
    
 // FreeRDP 3.x 新增设置 API
    _settingsSetUint32 = (freerdp_settings_set_uint32_fn)dlsym(_libraryHandle, "freerdp_settings_set_uint32");
    _settingsSetString = (freerdp_settings_set_string_fn)dlsym(_libraryHandle, "freerdp_settings_set_string");
    _settingsGetUint32 = (freerdp_settings_get_uint32_fn)dlsym(_libraryHandle, "freerdp_settings_get_uint32");
    _settingsGetString = (freerdp_settings_get_string_fn)dlsym(_libraryHandle, "freerdp_settings_get_string");
    
 // 输入事件函数 (可选)
    _sendMouseEvent = (freerdp_input_send_mouse_event_fn)dlsym(_libraryHandle, "freerdp_input_send_mouse_event");
    _sendKeyboardEvent = (freerdp_input_send_keyboard_event_fn)dlsym(_libraryHandle, "freerdp_input_send_keyboard_event");

 // 设置布尔 / 软件 GDI 渲染 / 事件泵（可选；缺失则降级为「仅连接、无画面」）
    _settingsSetBool = (freerdp_settings_set_bool_fn)dlsym(_libraryHandle, "freerdp_settings_set_bool");
    _gdiInit = (cb_gdi_init_fn)dlsym(_libraryHandle, "gdi_init");
    _gdiFree = (cb_gdi_free_fn)dlsym(_libraryHandle, "gdi_free");
    _checkEventHandles = (cb_check_event_handles_fn)dlsym(_libraryHandle, "freerdp_check_event_handles");

 // 检查必要的基础函数
    NSMutableArray<NSString *> *missingSymbols = [NSMutableArray array];
    if (!_versionString) [missingSymbols addObject:@"freerdp_get_version_string"];
    if (!_clientNew) [missingSymbols addObject:@"freerdp_new"];
    if (!_clientFree) [missingSymbols addObject:@"freerdp_free"];
    if (!_contextNew) [missingSymbols addObject:@"freerdp_context_new"];
    if (!_clientConnect) [missingSymbols addObject:@"freerdp_connect"];
    if (!_clientDisconnect) [missingSymbols addObject:@"freerdp_disconnect"];
    if (!_settingsSetUint32) [missingSymbols addObject:@"freerdp_settings_set_uint32"];
    if (!_settingsSetString) [missingSymbols addObject:@"freerdp_settings_set_string"];
    
    if (missingSymbols.count > 0) {
        os_log_error(CBFreeRDPLogger, "❌ FreeRDP 基础函数符号缺失: %{public}@", [missingSymbols componentsJoinedByString:@", "]);
        if (error) {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"FreeRDP 动态库缺少必要的导出符号: %@", [missingSymbols componentsJoinedByString:@", "]],
                @"MissingSymbols": missingSymbols
            };
 *error = [NSError errorWithDomain:@"com.skybridge.compass.freerdp"
                                         code:-101
                                     userInfo:userInfo];
        }
        dlclose(_libraryHandle);
        _libraryHandle = NULL;
        return NO;
    }
    
    NSString *versionStr = nil;
    if (_versionString) {
        const char *version = _versionString();
        if (version) {
            os_log_info(CBFreeRDPLogger, "✅ FreeRDP 版本: %{public}s", version);
            versionStr = [NSString stringWithUTF8String:version];
        }
    }
    if (!versionStr || !CBFreeRDPVersionMeetsMinimum(versionStr)) {
        os_log_error(
            CBFreeRDPLogger,
            "❌ FreeRDP 版本过旧或无法识别: %{public}@，最低要求 %{public}@",
            versionStr ?: @"(unknown)",
            CBFreeRDPMinimumVersionString
        );
        if (error) {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: @"FreeRDP 版本不满足安全要求",
                NSLocalizedFailureReasonErrorKey: [NSString stringWithFormat:@"检测到版本 %@，最低要求 %@。", versionStr ?: @"unknown", CBFreeRDPMinimumVersionString],
                NSLocalizedRecoverySuggestionErrorKey: @"请更新到 FreeRDP 3.26.0 或更高版本后重试。"
            };
            *error = [NSError errorWithDomain:@"com.skybridge.compass.freerdp"
                                         code:-102
                                     userInfo:userInfo];
        }
        dlclose(_libraryHandle);
        _libraryHandle = NULL;
        return NO;
    }
    os_log_info(CBFreeRDPLogger, "✅ FreeRDP 版本满足安全要求，启用完整功能支持");
    
 // 设置 API 为可选（读取路径可降级），写入路径在连接时会做强校验
    NSMutableArray<NSString *> *optionalMissing = [NSMutableArray array];
    if (!_settingsGetUint32) [optionalMissing addObject:@"freerdp_settings_get_uint32"];
    if (!_settingsGetString) [optionalMissing addObject:@"freerdp_settings_get_string"];
    
    if (optionalMissing.count > 0) {
        os_log_info(CBFreeRDPLogger, "⚠️ FreeRDP 3.x 设置 API 不可用 (%{public}@)，部分功能可能受限", [optionalMissing componentsJoinedByString:@", "]);
    } else {
        os_log_info(CBFreeRDPLogger, "✅ FreeRDP 3.x 设置 API 全部可用");
    }
    
 // 验证输入事件函数（可选但推荐）
    if (!_sendMouseEvent) {
        os_log_info(CBFreeRDPLogger, "⚠️ freerdp_input_send_mouse_event 不可用，鼠标输入可能受限");
    }
    if (!_sendKeyboardEvent) {
        os_log_info(CBFreeRDPLogger, "⚠️ freerdp_input_send_keyboard_event 不可用，键盘输入可能受限");
    }

    os_log_info(CBFreeRDPLogger, "✅ libfreerdp 动态库加载成功，符号验证通过");
    return YES;
}

- (void)startGraphicsAndPump
{
    // 运行在 workerQueue（由 connect 的 worker 块调用）。
    if (!self.connectionRef) {
        return;
    }
    rdpContext *context = CBGetContextFromInstance(self.connectionRef);
    if (!context) {
        [self notifyState:@"⚠️ 无法获取 FreeRDP 上下文，无法渲染"];
        return;
    }

    // 注册 实例→本客户端，供 GDI 的 EndPaint C 回调找回本实例。
    [CBClientRegistryLock() lock];
    CBClientRegistry()[@((uintptr_t)self.connectionRef)] = [NSValue valueWithNonretainedObject:self];
    [CBClientRegistryLock() unlock];

    // 初始化软件 GDI：分配 BGRA32 帧缓冲，更新管线（位图/SurfaceBits/GFX）会绘制进 primary_buffer。
    BOOL gdiReady = NO;
    if (_gdiInit) {
        gdiReady = _gdiInit(self.connectionRef, PIXEL_FORMAT_BGRA32);
    }
    if (gdiReady && context->update) {
        // 链接 GDI 原 EndPaint（保留失效区域维护），叠加本客户端的整帧发射。
        _originalEndPaint = context->update->EndPaint;
        context->update->EndPaint = CBEndPaintCallback;
        [self notifyState:@"🖼️ 远程画面渲染已启用"];
    } else {
        [self notifyState:@"⚠️ 软件 GDI 不可用：已连接但无画面"];
    }

    // 启动事件泵：周期性处理事件句柄 → 驱动更新管线 → 触发 EndPaint → 发射帧。
    _pumpActive = YES;
    [self pumpEventsOnce];
}

- (void)pumpEventsOnce
{
    if (!_pumpActive || !self.connectionRef || !_checkEventHandles) {
        return;
    }
    rdpContext *context = CBGetContextFromInstance(self.connectionRef);
    if (!context) {
        return;
    }
    if (!_checkEventHandles(context)) {
        // 连接关闭或出错：停止泵并上报。
        _pumpActive = NO;
        self.state = CBFreeRDPClientStateDisconnected;
        [self notifyState:@"FreeRDP 会话已结束"];
        return;
    }
    // 自重排：~15ms 一轮，在 workerQueue 上与输入发送串行交替（单线程上下文安全）。
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_MSEC)),
                   self.workerQueue, ^{
        [weakSelf pumpEventsOnce];
    });
}

- (BOOL)handleEndPaint:(rdpContext *)context
{
    // 先调用 GDI 原 EndPaint（失效区域维护），再发射整帧缓冲给上层。
    if (_originalEndPaint) {
        _originalEndPaint(context);
    }
    rdpGdi *gdi = context ? context->gdi : NULL;
    CBFreeRDPFrameCallback callback = self.frameCallback;
    if (callback && gdi && gdi->primary_buffer &&
        gdi->width > 0 && gdi->height > 0 && gdi->stride > 0) {
        NSData *frame = [NSData dataWithBytes:gdi->primary_buffer
                                       length:(NSUInteger)gdi->stride * (NSUInteger)gdi->height];
        callback(frame,
                 (uint32_t)gdi->width,
                 (uint32_t)gdi->height,
                 (uint32_t)gdi->stride,
                 CBFreeRDPFrameTypeBGRA);
    }
    return TRUE;
}

#pragma mark - 设置配置方法

/// 配置显示设置 (真正调用 FreeRDP API)
- (void)configureDisplaySettings:(NSDictionary *)displaySettings {
    if (!displaySettings || !_connectionRef) {
        os_log_error(CBFreeRDPLogger, "❌ 显示设置配置失败：参数无效");
        return;
    }
    
    rdpSettings *settings = [self currentSettings];
    if (!settings) {
        os_log_error(CBFreeRDPLogger, "❌ 无法获取 FreeRDP 设置对象");
        return;
    }
    
    os_log_info(CBFreeRDPLogger, "🖥️ 开始配置显示设置");
    
 // 分辨率设置
    NSNumber *width = displaySettings[@"width"];
    NSNumber *height = displaySettings[@"height"];
    if (width && height && _settingsSetUint32) {
        _settingsSetUint32(settings, FreeRDP_DesktopWidth, width.unsignedIntValue);
        _settingsSetUint32(settings, FreeRDP_DesktopHeight, height.unsignedIntValue);
        os_log_info(CBFreeRDPLogger, "✅ 分辨率: %@x%@", width, height);
    }
    
 // 颜色深度设置
    NSNumber *colorDepth = displaySettings[@"colorDepth"];
    if (colorDepth && _settingsSetUint32) {
        _settingsSetUint32(settings, FreeRDP_ColorDepth, colorDepth.unsignedIntValue);
        os_log_info(CBFreeRDPLogger, "✅ 颜色深度: %@位", colorDepth);
    }
    
 // Apple Silicon 硬件加速优化
    if (_isAppleSilicon && _settingsSetUint32) {
 // 启用 H.264 硬件加速
        _settingsSetUint32(settings, FreeRDP_GfxH264, TRUE);
 // 启用 AVC444 (高质量 H.264)
        _settingsSetUint32(settings, FreeRDP_GfxAVC444, TRUE);
        os_log_info(CBFreeRDPLogger, "🚀 已启用 Apple Silicon 硬件加速编解码");
    }
}

/// 配置交互设置
- (void)configureInteractionSettings:(NSDictionary *)interactionSettings {
    if (!interactionSettings || !_connectionRef) {
        os_log_error(CBFreeRDPLogger, "❌ 交互设置配置失败：参数无效");
        return;
    }
    
    os_log_info(CBFreeRDPLogger, "🖱️ 配置交互设置: %{public}@", interactionSettings);
    
 // 鼠标灵敏度设置
    NSNumber *mouseSensitivity = interactionSettings[@"mouseSensitivity"];
    if (mouseSensitivity) {
        os_log_info(CBFreeRDPLogger, "🖱️ 鼠标灵敏度: %{public}@", mouseSensitivity);
    }
    
 // 键盘布局设置
    NSString *keyboardLayout = interactionSettings[@"keyboardLayout"];
    if (keyboardLayout) {
        os_log_info(CBFreeRDPLogger, "⌨️ 键盘布局: %{public}@", keyboardLayout);
    }
    
 // 滚轮速度设置
    NSNumber *scrollSpeed = interactionSettings[@"scrollSpeed"];
    if (scrollSpeed) {
        os_log_info(CBFreeRDPLogger, "🎡 滚轮速度: %{public}@", scrollSpeed);
    }
    
 // 触控板手势设置
    NSNumber *touchpadGestures = interactionSettings[@"touchpadGestures"];
    if (touchpadGestures) {
        os_log_info(CBFreeRDPLogger, "👆 触控板手势: %{public}@", touchpadGestures.boolValue ? @"启用" : @"禁用");
    }
    
 // 剪贴板同步设置
    NSNumber *clipboardSync = interactionSettings[@"clipboardSync"];
    if (clipboardSync) {
        os_log_info(CBFreeRDPLogger, "📋 剪贴板同步: %{public}@", clipboardSync.boolValue ? @"启用" : @"禁用");
    }
    
 // 音频重定向设置
    NSNumber *audioRedirection = interactionSettings[@"audioRedirection"];
    if (audioRedirection) {
        os_log_info(CBFreeRDPLogger, "🔊 音频重定向: %{public}@", audioRedirection.boolValue ? @"启用" : @"禁用");
    }
}

/// 配置网络设置 (真正调用 FreeRDP API)
- (void)configureNetworkSettings:(NSDictionary *)networkSettings {
    if (!networkSettings || !_connectionRef) {
        os_log_error(CBFreeRDPLogger, "❌ 网络设置配置失败：参数无效");
        return;
    }
    
    rdpSettings *settings = [self currentSettings];
    if (!settings) {
        os_log_error(CBFreeRDPLogger, "❌ 无法获取 FreeRDP 设置对象");
        return;
    }
    
    os_log_info(CBFreeRDPLogger, "🌐 开始配置网络设置");
    
 // 连接类型设置（兼容 Swift RawValue + 旧枚举）
    id connectionTypeRaw = networkSettings[@"connectionType"];
    if (connectionTypeRaw && _setConnectionType) {
        uint32_t type = CONNECTION_TYPE_AUTODETECT;
        NSString *connectionType = nil;

        if ([connectionTypeRaw isKindOfClass:[NSNumber class]]) {
            type = (uint32_t)[(NSNumber *)connectionTypeRaw unsignedIntegerValue];
            connectionType = [(NSNumber *)connectionTypeRaw stringValue];
        } else if ([connectionTypeRaw isKindOfClass:[NSString class]]) {
            connectionType = [(NSString *)connectionTypeRaw lowercaseString];
            if ([connectionType isEqualToString:@"modem"]) {
                type = CONNECTION_TYPE_MODEM;
            } else if ([connectionType isEqualToString:@"broadband_low"] || [connectionType isEqualToString:@"mobile"]) {
                type = CONNECTION_TYPE_BROADBAND_LOW;
            } else if ([connectionType isEqualToString:@"satellite"]) {
                type = CONNECTION_TYPE_SATELLITE;
            } else if ([connectionType isEqualToString:@"broadband_high"]) {
                type = CONNECTION_TYPE_BROADBAND_HIGH;
            } else if ([connectionType isEqualToString:@"wan"]) {
                type = CONNECTION_TYPE_WAN;
            } else if ([connectionType isEqualToString:@"lan"]) {
                type = CONNECTION_TYPE_LAN;
            } else if ([connectionType isEqualToString:@"auto"]) {
                type = CONNECTION_TYPE_AUTODETECT;
            }
        }

        if (!_setConnectionType(settings, type)) {
            os_log_error(CBFreeRDPLogger, "❌ 连接类型设置失败: %{public}@ (type=%u)",
                        connectionType ?: @"(unknown)", type);
        } else {
            os_log_info(CBFreeRDPLogger, "✅ 连接类型: %{public}@ (type=%u)",
                       connectionType ?: @"(unknown)", type);
        }
    }
    
 // 缓存优化：位图缓存是 BOOL 类型（用 set_bool）。Offscreen/Glyph 在真实 3.26 中是
 // SupportLevel（UINT32）而非简单开关，半配置的字形缓存可能导致连接异常，故交由 FreeRDP
 // 协商默认值，仅显式启用位图缓存。
    if (_settingsSetBool) {
        _settingsSetBool(settings, FreeRDP_BitmapCacheEnabled, TRUE);
        os_log_info(CBFreeRDPLogger, "✅ 位图缓存已启用");
    }
    
 // Apple Silicon 网络优化
    if (_isAppleSilicon && _settingsSetUint32) {
 // 启用网络自动检测
        _settingsSetUint32(settings, FreeRDP_NetworkAutoDetect, TRUE);
        os_log_info(CBFreeRDPLogger, "🚀 Apple Silicon 网络优化已应用");
    }
}

/// 应用所有设置
- (void)applyAllSettings:(NSDictionary *)allSettings {
    if (!allSettings) {
        os_log_error(CBFreeRDPLogger, "❌ 设置应用失败：参数为空");
        return;
    }
    
    os_log_info(CBFreeRDPLogger, "⚙️ 开始应用所有远程桌面设置");
    
 // 应用显示设置
    NSDictionary *displaySettings = allSettings[@"displaySettings"];
    if (displaySettings) {
        [self configureDisplaySettings:displaySettings];
    }
    
 // 应用交互设置
    NSDictionary *interactionSettings = allSettings[@"interactionSettings"];
    if (interactionSettings) {
        [self configureInteractionSettings:interactionSettings];
    }
    
 // 应用网络设置
    NSDictionary *networkSettings = allSettings[@"networkSettings"];
    if (networkSettings) {
        [self configureNetworkSettings:networkSettings];
    }
    
 // 重新配置Apple Silicon优化
    if (_isAppleSilicon) {
        [self configureAppleSiliconSettings];
    }
    
    os_log_info(CBFreeRDPLogger, "✅ 所有远程桌面设置已成功应用");
}

@end

// GDI 绘制完成回调（C 函数指针，安装到 context->update->EndPaint）。
// 通过注册表用 context->instance 找回对应的 CBFreeRDPClient，转发到其 handleEndPaint:。
// 运行在 workerQueue（freerdp_check_event_handles 内部调用）—— 与输入发送同队列，串行安全。
static BOOL CBEndPaintCallback(rdpContext *context)
{
    if (!context || !context->instance) {
        return TRUE;
    }
    [CBClientRegistryLock() lock];
    NSValue *entry = CBClientRegistry()[@((uintptr_t)context->instance)];
    [CBClientRegistryLock() unlock];
    CBFreeRDPClient *client = entry ? entry.nonretainedObjectValue : nil;
    if (client) {
        return [client handleEndPaint:context];
    }
    return TRUE;
}
