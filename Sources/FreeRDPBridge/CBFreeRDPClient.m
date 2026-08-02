#import "CBFreeRDPClient.h"
#import "CBFreeRDPConstants.h"
#import "CBRDPSystemTrust.h"
#import <dlfcn.h>
#import <os/log.h>

// CoreFoundation's CFPlugInCOM compatibility header publishes a Windows-style
// HRESULT macro namespace. FreeRDP's WinPR headers publish the same names with
// their own authoritative types and definitions. This implementation is the
// WinPR ABI boundary, so clear only the colliding macros after Foundation is
// imported and before FreeRDP is parsed. Keeping this local to one translation
// unit avoids both warning suppression and public-header side effects.
#if defined(__APPLE__)
#undef E_UNEXPECTED
#undef E_ACCESSDENIED
#undef E_HANDLE
#undef E_OUTOFMEMORY
#undef E_INVALIDARG
#undef E_NOTIMPL
#undef E_NOINTERFACE
#undef E_POINTER
#undef E_ABORT
#undef E_FAIL
#undef HRESULT_CODE
#undef HRESULT_FACILITY
#undef SUCCEEDED
#undef FAILED
#undef IS_ERROR
#undef MAKE_HRESULT
#undef S_OK
#undef S_FALSE
#endif

// 真实 FreeRDP/WinPR 3.30.0 头（与 Sources/Vendor/FreeRDPDylibs 的 dylib 同版本）。
// 结构体布局、设置枚举值、像素格式、输入标志均由编译器解析，取代旧的占位 opaque 类型 +
// 硬编码指针 slot + 伪造设置常量（曾把 DesktopWidth/Port/Username/Password 写入错误槽位）。
// dylib 仍按需 dlopen；这些头只提供类型与函数签名，不引入链接期硬依赖。
// 关键：必须在 Apple 媒体框架之前包含 —— winpr 的 IID/REFIID typedef 与 CoreFoundation
// 的 CFPlugInCOM 同名冲突，先定义者胜（winpr 无重定义守卫，CoreFoundation 有）。
#include <freerdp/freerdp.h>
#include <freerdp/version.h>
#include <freerdp/settings.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/update.h>
#include <freerdp/codec/color.h>

#import <CoreGraphics/CoreGraphics.h>
#import <math.h>
#import <string.h>

// FreeRDP 函数指针类型定义（签名匹配真实 3.x 导出符号；类型来自上面的真实头）
typedef const char *(*freerdp_version_string_fn)(void);
typedef freerdp *(*freerdp_new_fn)(void);
typedef void (*freerdp_free_fn)(freerdp *instance);
typedef BOOL (*freerdp_context_new_fn)(freerdp *instance);
typedef void (*freerdp_context_free_fn)(freerdp *instance);
typedef BOOL (*freerdp_connect_fn)(freerdp *instance);
typedef BOOL (*freerdp_disconnect_fn)(freerdp *instance);
typedef BOOL (*freerdp_input_send_mouse_event_fn)(rdpInput *input, uint16_t flags, uint16_t x, uint16_t y);
typedef BOOL (*freerdp_input_send_keyboard_event_fn)(rdpInput *input, uint16_t flags, uint8_t code);

// FreeRDP 3.x 设置 API
typedef BOOL (*freerdp_settings_set_uint32_fn)(rdpSettings *settings, size_t id, uint32_t value);
typedef BOOL (*freerdp_settings_set_string_fn)(rdpSettings *settings, size_t id, const char *value);
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

static os_log_t CBFreeRDPLogger;
static NSString * const CBFreeRDPRequiredVersionString = @"3.30.0";
static NSString * const CBFreeRDPErrorDomain = @"com.skybridge.compass.freerdp";
static void *CBFreeRDPWorkerQueueSpecificKey = &CBFreeRDPWorkerQueueSpecificKey;

typedef struct {
    BOOL hasDesktopSize;
    uint32_t desktopWidth;
    uint32_t desktopHeight;
    BOOL hasColorDepth;
    uint32_t colorDepth;
    BOOL hasConnectionType;
    uint32_t connectionType;
} CBFreeRDPPendingConfiguration;

static NSError *CBFreeRDPError(NSInteger code, NSString *description, NSString *reason) {
    return [NSError errorWithDomain:CBFreeRDPErrorDomain
                               code:code
                           userInfo:@{
        NSLocalizedDescriptionKey: description,
        NSLocalizedFailureReasonErrorKey: reason
    }];
}

static BOOL CBFreeRDPVersionMatchesRequired(NSString *versionString) {
    return [versionString isEqualToString:CBFreeRDPRequiredVersionString];
}

static BOOL CBValidateRDPTextField(
    NSString *value,
    NSString *fieldDescription,
    NSUInteger maximumUTF8Length,
    BOOL allowsEmpty,
    NSError **error
) {
    if (![value isKindOfClass:[NSString class]] || (!allowsEmpty && value.length == 0)) {
        if (error) {
            *error = CBFreeRDPError(-110, @"RDP 连接参数无效",
                                    [NSString stringWithFormat:@"%@不能为空。", fieldDescription]);
        }
        return NO;
    }

    NSCharacterSet *forbiddenCharacters = [NSCharacterSet controlCharacterSet];
    if ([value rangeOfCharacterFromSet:forbiddenCharacters].location != NSNotFound) {
        if (error) {
            *error = CBFreeRDPError(-111, @"RDP 连接参数无效",
                                    [NSString stringWithFormat:@"%@包含控制字符。", fieldDescription]);
        }
        return NO;
    }

    NSUInteger byteLength = [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (byteLength > maximumUTF8Length) {
        if (error) {
            *error = CBFreeRDPError(-112, @"RDP 连接参数过长",
                                    [NSString stringWithFormat:@"%@超过协议允许的 UTF-8 长度。", fieldDescription]);
        }
        return NO;
    }
    return YES;
}

static BOOL CBParseBoundedUInt32(
    id value,
    NSString *fieldDescription,
    uint32_t minimum,
    uint32_t maximum,
    uint32_t *result,
    NSError **error
) {
    if (![value isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        if (error) {
            *error = CBFreeRDPError(-120, @"RDP 设置无效",
                                    [NSString stringWithFormat:@"%@必须是整数。", fieldDescription]);
        }
        return NO;
    }
    double numericValue = [(NSNumber *)value doubleValue];
    if (!isfinite(numericValue) || floor(numericValue) != numericValue ||
        numericValue < minimum || numericValue > maximum) {
        if (error) {
            *error = CBFreeRDPError(-121, @"RDP 设置超出范围",
                                    [NSString stringWithFormat:@"%@不在允许范围内。", fieldDescription]);
        }
        return NO;
    }
    *result = (uint32_t)numericValue;
    return YES;
}

static BOOL CBValidateOnlyKeys(
    NSDictionary *dictionary,
    NSSet<NSString *> *allowedKeys,
    NSString *sectionDescription,
    NSError **error
) {
    for (id key in dictionary) {
        if (![key isKindOfClass:[NSString class]] || ![allowedKeys containsObject:key]) {
            if (error) {
                *error = CBFreeRDPError(-122, @"RDP 设置包含未支持字段",
                                        [NSString stringWithFormat:@"%@包含未接线的设置。", sectionDescription]);
            }
            return NO;
        }
    }
    return YES;
}

static BOOL CBParseConnectionType(id value, uint32_t *result, NSError **error) {
    if ([value isKindOfClass:[NSNumber class]]) {
        return CBParseBoundedUInt32(value, @"连接类型", CONNECTION_TYPE_MODEM,
                                    CONNECTION_TYPE_AUTODETECT, result, error);
    }
    if (![value isKindOfClass:[NSString class]]) {
        if (error) {
            *error = CBFreeRDPError(-123, @"RDP 连接类型无效", @"连接类型必须是受支持的枚举值。");
        }
        return NO;
    }
    NSDictionary<NSString *, NSNumber *> *mapping = @{
        @"modem": @(CONNECTION_TYPE_MODEM),
        @"broadband_low": @(CONNECTION_TYPE_BROADBAND_LOW),
        @"mobile": @(CONNECTION_TYPE_BROADBAND_LOW),
        @"satellite": @(CONNECTION_TYPE_SATELLITE),
        @"broadband_high": @(CONNECTION_TYPE_BROADBAND_HIGH),
        @"wan": @(CONNECTION_TYPE_WAN),
        @"lan": @(CONNECTION_TYPE_LAN),
        @"auto": @(CONNECTION_TYPE_AUTODETECT)
    };
    NSNumber *mapped = mapping[(NSString *)value];
    if (!mapped) {
        if (error) {
            *error = CBFreeRDPError(-123, @"RDP 连接类型无效", @"连接类型不在受支持的枚举集合中。");
        }
        return NO;
    }
    *result = mapped.unsignedIntValue;
    return YES;
}

static NSString *CBCanonicalPath(NSString *path) {
    return path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
}

static BOOL CBPathIsStrictlyInsideDirectory(NSString *path, NSString *directory) {
    NSString *canonicalPath = CBCanonicalPath(path);
    NSString *canonicalDirectory = CBCanonicalPath(directory);
    if (canonicalPath.length == 0 || canonicalDirectory.length == 0) {
        return NO;
    }
    NSString *prefix = [canonicalDirectory stringByAppendingString:@"/"];
    return [canonicalPath hasPrefix:prefix];
}

static BOOL CBSymbolOriginMatchesImage(void *symbol, NSString *expectedImagePath) {
    if (!symbol || expectedImagePath.length == 0) {
        return NO;
    }
    Dl_info info = {0};
    if (dladdr(symbol, &info) == 0 || !info.dli_fname) {
        return NO;
    }
    NSString *actualPath = [NSString stringWithUTF8String:info.dli_fname];
    return [CBCanonicalPath(actualPath) isEqualToString:CBCanonicalPath(expectedImagePath)];
}

static int CBVerifySystemCertificateChain(
    freerdp *instance,
    const BYTE *data,
    size_t length,
    const char *hostname,
    UINT16 port,
    DWORD flags
) {
    (void)instance;
    (void)port;
    return CBRDPVerifySystemCertificateChain(data, length, hostname, (uint32_t)flags);
}

/// Complete-chain validation is owned by `CBVerifySystemCertificateChain`. These fallback
/// callbacks must never add a second trust source through FreeRDP known_hosts, TOFU, or an
/// implicit fingerprint store, so unknown and changed certificates remain fail-closed.
static DWORD CBRejectUnknownCertificate(
    freerdp *instance,
    const char *host,
    UINT16 port,
    const char *commonName,
    const char *subject,
    const char *issuer,
    const char *fingerprint,
    DWORD flags
) {
    (void)instance;
    (void)host;
    (void)port;
    (void)commonName;
    (void)subject;
    (void)issuer;
    (void)fingerprint;
    (void)flags;
    os_log_error(CBFreeRDPLogger, "⛔️ RDP 证书未通过系统信任回调，已拒绝");
    return 0;
}

static DWORD CBRejectChangedCertificate(
    freerdp *instance,
    const char *host,
    UINT16 port,
    const char *commonName,
    const char *subject,
    const char *issuer,
    const char *newFingerprint,
    const char *oldSubject,
    const char *oldIssuer,
    const char *oldFingerprint,
    DWORD flags
) {
    (void)instance;
    (void)host;
    (void)port;
    (void)commonName;
    (void)subject;
    (void)issuer;
    (void)newFingerprint;
    (void)oldSubject;
    (void)oldIssuer;
    (void)oldFingerprint;
    (void)flags;
    os_log_error(CBFreeRDPLogger, "⛔️ 已变化的 RDP 证书已拒绝");
    return 0;
}

@interface CBFreeRDPClient ()
{
    void *_libraryHandle;
    
 // FreeRDP 基础函数指针
    freerdp_version_string_fn _versionString;
    freerdp_new_fn _clientNew;
    freerdp_free_fn _clientFree;
    freerdp_context_new_fn _contextNew;
    freerdp_context_free_fn _contextFree;
    freerdp_connect_fn _clientConnect;
    freerdp_disconnect_fn _clientDisconnect;
    freerdp_input_send_mouse_event_fn _sendMouseEvent;
    freerdp_input_send_keyboard_event_fn _sendKeyboardEvent;
    
 // FreeRDP 3.x 设置 API
    freerdp_settings_set_uint32_fn _settingsSetUint32;
    freerdp_settings_set_string_fn _settingsSetString;
    freerdp_settings_set_bool_fn _settingsSetBool;

 // 渲染 / 事件泵
    cb_gdi_init_fn _gdiInit;
    cb_gdi_free_fn _gdiFree;
    cb_check_event_handles_fn _checkEventHandles;
    pEndPaint _originalEndPaint;   // GDI 原始 EndPaint（链接调用，保留失效区域维护）
    BOOL _pumpActive;
    BOOL _gdiInitialized;
    BOOL _connectAttempted;
    BOOL _connectionEstablished;
    uint64_t _connectionGeneration;
    uint64_t _emittedFrameCount;   // 已上抛帧数（诊断：区分「连上无帧」与「帧已流动」）
    BOOL _loggedEmptyEndPaint;     // 「EndPaint 触发但帧缓冲不可用」只记录一次，避免刷屏

    CBFreeRDPPendingConfiguration _pendingConfiguration;
}

// 内部可写属性（重新声明为 readwrite）
@property (atomic, readwrite) CBFreeRDPClientState state;
@property (atomic, readwrite) NSString *targetHost;
@property (atomic, readwrite) uint16_t targetPort;

// 内部私有属性
@property (nonatomic, strong) dispatch_queue_t workerQueue;
@property (nonatomic, strong) NSLock *configurationLock;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *password;
@property (nonatomic, copy, nullable) NSString *domain;
@property (nonatomic) freerdp *connectionRef;
@property (nonatomic, strong) NSTimer * _Nullable keepAliveTimer;

// 渲染 / 事件泵（均在 workerQueue 上串行执行，避免与输入发送争用单线程 FreeRDP 上下文）
- (BOOL)startGraphicsAndPump;
- (void)pumpEventsOnce;
- (BOOL)handleEndPaint:(rdpContext *)context;
- (void)teardownConnectionResources;
- (void)unloadLibraries;
- (BOOL)applyConnectionType:(UINT32)type toSettings:(rdpSettings *)settings;
- (BOOL)applyPendingConfiguration;
- (BOOL)validateConnectionParameters:(NSError **)error;

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
        dispatch_queue_set_specific(
            _workerQueue,
            CBFreeRDPWorkerQueueSpecificKey,
            (__bridge void *)self,
            NULL
        );
        _configurationLock = [[NSLock alloc] init];
        memset(&_pendingConfiguration, 0, sizeof(_pendingConfiguration));

        // 主机名、用户名和域名可能包含个人或组织信息，运行日志只记录端口。
        os_log_info(CBFreeRDPLogger, "FreeRDP 客户端已初始化，目标端口: %hu", port);
    }
    return self;
}

- (void)dealloc
{
    // dealloc 必须等待 workerQueue 中所有 FreeRDP 调用结束，再释放实例并
    // dlclose。异步 disconnect 会让已入队的函数指针访问已卸载 image。
    __unsafe_unretained CBFreeRDPClient *unsafeSelf = self;
    dispatch_block_t teardown = ^{
        [unsafeSelf teardownConnectionResources];
        [unsafeSelf unloadLibraries];
    };
    if (dispatch_get_specific(CBFreeRDPWorkerQueueSpecificKey) == (__bridge void *)self) {
        teardown();
    } else {
        dispatch_sync(_workerQueue, teardown);
    }
}

- (BOOL)connectWithError:(NSError *__autoreleasing  _Nullable * _Nullable)error
{
    [_configurationLock lock];
    CBFreeRDPClientState currentState = self.state;
    if (currentState == CBFreeRDPClientStateConnecting ||
        currentState == CBFreeRDPClientStateConnected ||
        currentState == CBFreeRDPClientStateDisconnecting) {
        [_configurationLock unlock];
        if (error) {
            *error = CBFreeRDPError(-105, @"RDP 会话已在运行",
                                    @"必须先完成或断开当前会话。");
        }
        return NO;
    }
    self.state = CBFreeRDPClientStateConnecting;
    [_configurationLock unlock];
    if (![self validateConnectionParameters:error]) {
        self.password = @"";
        [_configurationLock lock];
        if (self.state == CBFreeRDPClientStateConnecting) {
            self.state = CBFreeRDPClientStateFailed;
        }
        [_configurationLock unlock];
        return NO;
    }
    if (![self loadLibrary:error]) {
        self.password = @"";
        [_configurationLock lock];
        if (self.state == CBFreeRDPClientStateConnecting) {
            self.state = CBFreeRDPClientStateFailed;
        }
        [_configurationLock unlock];
        return NO;
    }

    __weak typeof(self) weakSelf = self;
    [_configurationLock lock];
    if (self.state != CBFreeRDPClientStateConnecting) {
        [_configurationLock unlock];
        if (error) {
            *error = CBFreeRDPError(-107, @"RDP 连接已取消", @"会话在运行库准备期间被断开。");
        }
        return NO;
    }
    dispatch_async(self.workerQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf notifyState:@"正在建立 FreeRDP 会话..."];
        [strongSelf notifyState:[NSString stringWithFormat:@"RDP 目标端口: %hu", strongSelf.targetPort]];

        strongSelf.connectionRef = strongSelf->_clientNew();

        if (!strongSelf.connectionRef) {
            [strongSelf teardownConnectionResources];
            strongSelf.state = CBFreeRDPClientStateFailed;
            [strongSelf notifyState:@"无法创建 FreeRDP 客户端上下文"];
            return;
        }

        // This bridge deliberately does not register FreeRDP channel plugins. Keep the
        // callback explicit so a future upstream default or initializer change cannot
        // silently widen the runtime capability surface.
        strongSelf.connectionRef->LoadChannels = NULL;

        strongSelf.connectionRef->VerifyX509Certificate = CBVerifySystemCertificateChain;
        strongSelf.connectionRef->VerifyCertificateEx = CBRejectUnknownCertificate;
        strongSelf.connectionRef->VerifyChangedCertificateEx = CBRejectChangedCertificate;

        if (![strongSelf ensureContextReady]) {
            [strongSelf teardownConnectionResources];
            strongSelf.state = CBFreeRDPClientStateFailed;
            [strongSelf notifyState:@"FreeRDP 上下文初始化失败"];
            return;
        }

        // Connection-type defaults may enable codecs that this reviewed runtime intentionally
        // excludes. Apply them first, then let the fail-closed identity/codec policy be the final
        // writer before connect so AUTODETECT cannot silently re-enable GFX or RemoteFX.
        if (![strongSelf applyPendingConfiguration]) {
            [strongSelf teardownConnectionResources];
            strongSelf.state = CBFreeRDPClientStateFailed;
            [strongSelf notifyState:@"FreeRDP 连接期设置应用失败"];
            return;
        }

        if (![strongSelf applyConnectionIdentitySettings]) {
            [strongSelf teardownConnectionResources];
            strongSelf.state = CBFreeRDPClientStateFailed;
            [strongSelf notifyState:@"FreeRDP 连接参数写入失败"];
            return;
        }

        const char *version = strongSelf->_versionString();
        os_log_info(CBFreeRDPLogger, "Loaded FreeRDP version: %{public}s", version);
        [strongSelf notifyState:[NSString stringWithFormat:@"FreeRDP 库版本 %s", version]];

        strongSelf->_connectAttempted = YES;
        const BOOL didConnect = strongSelf->_clientConnect(strongSelf.connectionRef);
        strongSelf.password = @"";
        if (!didConnect) {
            [strongSelf teardownConnectionResources];
            strongSelf.state = CBFreeRDPClientStateFailed;
            [strongSelf notifyState:@"FreeRDP 会话连接失败"];
            return;
        }
        strongSelf->_connectionEstablished = YES;

        if (![strongSelf startGraphicsAndPump]) {
            [strongSelf teardownConnectionResources];
            strongSelf.state = CBFreeRDPClientStateFailed;
            [strongSelf notifyState:@"FreeRDP 渲染或输入管线初始化失败"];
            return;
        }

        [strongSelf notifyState:@"FreeRDP 传输已建立，正在等待首帧"];
        [strongSelf pumpEventsOnce];
    });
    [_configurationLock unlock];

    return YES;
}

- (void)disconnect
{
    [_configurationLock lock];
    self.state = CBFreeRDPClientStateDisconnecting;
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.workerQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf teardownConnectionResources];
        strongSelf.state = CBFreeRDPClientStateDisconnected;
        [strongSelf notifyState:@"FreeRDP 会话已断开"];
    });
    [_configurationLock unlock];
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

    if (code > UINT8_MAX) {
        os_log_error(CBFreeRDPLogger, "❌ 键盘扫描码超出 FreeRDP BYTE 协议范围");
        return;
    }
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
        if (!strongSelf->_sendKeyboardEvent(input, flags, (uint8_t)code)) {
            os_log_error(CBFreeRDPLogger, "❌ Keyboard event send failed");
        }
    });
}

#pragma mark - Helpers

- (BOOL)validateConnectionParameters:(NSError **)error
{
    if (self.targetPort == 0) {
        if (error) {
            *error = CBFreeRDPError(-113, @"RDP 连接端口无效", @"端口必须在 1...65535 范围内。");
        }
        return NO;
    }
    if (!CBValidateRDPTextField(self.targetHost, @"主机名", 255, NO, error)) {
        return NO;
    }
    if ([self.targetHost rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound) {
        if (error) {
            *error = CBFreeRDPError(-114, @"RDP 主机名无效", @"主机名不能包含空白字符。");
        }
        return NO;
    }
    if (!CBValidateRDPTextField(self.username, @"用户名", 256, NO, error)) {
        return NO;
    }
    if (!CBValidateRDPTextField(self.domain ?: @"", @"域名", 255, YES, error)) {
        return NO;
    }
    return YES;
}

- (void)teardownConnectionResources
{
    _pumpActive = NO;
    _connectionGeneration += 1;
    freerdp *instance = self.connectionRef;
    if (instance) {
        [CBClientRegistryLock() lock];
        [CBClientRegistry() removeObjectForKey:@((uintptr_t)instance)];
        [CBClientRegistryLock() unlock];

        rdpContext *context = CBGetContextFromInstance(instance);
        if (context && context->update && context->update->EndPaint == CBEndPaintCallback) {
            context->update->EndPaint = _originalEndPaint;
        }
        _originalEndPaint = NULL;

        if (_gdiInitialized && _gdiFree) {
            _gdiFree(instance);
        }

        if ((_connectAttempted || _connectionEstablished) && _clientDisconnect) {
            if (!_clientDisconnect(instance)) {
                os_log_error(CBFreeRDPLogger, "FreeRDP disconnect 报告失败，继续确定性释放本地资源");
            }
        }

        // freerdp_free() releases only the outer instance. The context owns settings,
        // transport, channel manager, codecs, metrics and handles and must be released first.
        if (_contextFree) {
            _contextFree(instance);
        }

        if (_clientFree) {
            _clientFree(instance);
        }
    }
    self.connectionRef = NULL;
    _originalEndPaint = NULL;
    _gdiInitialized = NO;
    _connectAttempted = NO;
    _connectionEstablished = NO;
    self.password = @"";
    [self.keepAliveTimer invalidate];
    self.keepAliveTimer = nil;
    _emittedFrameCount = 0;
    _loggedEmptyEndPaint = NO;
}

- (void)unloadLibraries
{
    _versionString = NULL;
    _clientNew = NULL;
    _clientFree = NULL;
    _contextNew = NULL;
    _contextFree = NULL;
    _clientConnect = NULL;
    _clientDisconnect = NULL;
    _sendMouseEvent = NULL;
    _sendKeyboardEvent = NULL;
    _settingsSetUint32 = NULL;
    _settingsSetString = NULL;
    _settingsSetBool = NULL;
    _gdiInit = NULL;
    _gdiFree = NULL;
    _checkEventHandles = NULL;

    if (_libraryHandle) {
        dlclose(_libraryHandle);
        _libraryHandle = NULL;
    }
}

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
    if (!_settingsSetString || !_settingsSetUint32 || !_settingsSetBool) {
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

    // Certificate, codec and channel policy are security-critical. The setter is a required
    // symbol and every result is checked; a library that cannot enforce any setting is rejected.
    ok = _settingsSetBool(settings, FreeRDP_SoftwareGdi, TRUE) && ok;
    // 关闭需要 ffmpeg 的 GFX / H.264 路径
    ok = _settingsSetBool(settings, FreeRDP_SupportGraphicsPipeline, FALSE) && ok;
    ok = _settingsSetBool(settings, FreeRDP_GfxH264, FALSE) && ok;
    ok = _settingsSetBool(settings, FreeRDP_GfxAVC444, FALSE) && ok;
    ok = _settingsSetBool(settings, FreeRDP_GfxAVC444v2, FALSE) && ok;
    // RemoteFX remains disabled until the upgraded 3.30 binary and decoder path are reviewed.
    ok = _settingsSetBool(settings, FreeRDP_RemoteFxCodec, FALSE) && ok;
    ok = _settingsSetBool(settings, FreeRDP_NSCodec, TRUE) && ok;

    // No FreeRDP channel plugin is built or registered in this runtime. Explicitly override
    // core defaults as well, notably RedirectClipboard and SupportDisplayControl, so adding a
    // callback later cannot activate an unreviewed redirection surface by accident.
    static const FreeRDP_Settings_Keys_Bool disabledChannelSettings[] = {
        FreeRDP_DeviceRedirection,
        FreeRDP_RedirectDrives,
        FreeRDP_RedirectHomeDrive,
        FreeRDP_RedirectSmartCards,
        FreeRDP_RedirectWebAuthN,
        FreeRDP_RedirectPrinters,
        FreeRDP_RedirectSerialPorts,
        FreeRDP_RedirectParallelPorts,
        FreeRDP_RedirectClipboard,
        FreeRDP_AudioPlayback,
        FreeRDP_AudioCapture,
        FreeRDP_RemoteApplicationMode,
        FreeRDP_SupportDisplayControl
    };
    for (size_t index = 0;
         index < sizeof(disabledChannelSettings) / sizeof(disabledChannelSettings[0]);
         index++) {
        ok = _settingsSetBool(settings, disabledChannelSettings[index], FALSE) && ok;
    }

    ok = _settingsSetBool(settings, FreeRDP_IgnoreCertificate, FALSE) && ok;
    ok = _settingsSetBool(settings, FreeRDP_AutoAcceptCertificate, FALSE) && ok;
    ok = _settingsSetBool(settings, FreeRDP_AutoDenyCertificate, TRUE) && ok;
    ok = _settingsSetBool(settings, FreeRDP_ExternalCertificateManagement, TRUE) && ok;

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
    [self unloadLibraries];

    NSString *headerVersion = [NSString stringWithUTF8String:FREERDP_VERSION_FULL];
    if (!CBFreeRDPVersionMatchesRequired(headerVersion)) {
        os_log_error(
            CBFreeRDPLogger,
            "⛔️ FreeRDP bridge headers are %{public}@; required verified headers are %{public}@",
            headerVersion,
            CBFreeRDPRequiredVersionString
        );
        if (error) {
            *error = [NSError errorWithDomain:CBFreeRDPErrorDomain
                                         code:-104
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"RDP 运行时已安全停用",
                NSLocalizedFailureReasonErrorKey: [NSString stringWithFormat:
                    @"桥接头文件版本为 %@，需要与受验证的 %@ 运行时同步升级。",
                    headerVersion,
                    CBFreeRDPRequiredVersionString
                ],
                NSLocalizedRecoverySuggestionErrorKey: @"请安装包含同步 FreeRDP 3.30.0 二进制、头文件和来源证明的完整 SkyBridge 版本。"
            }];
        }
        return NO;
    }

    NSString *frameworksPath = NSBundle.mainBundle.privateFrameworksPath ?: @"";
    NSString *coreLibraryPath = CBCanonicalPath(
        [frameworksPath stringByAppendingPathComponent:@"libfreerdp3.dylib"]
    );
    if (frameworksPath.length == 0 ||
        !CBPathIsStrictlyInsideDirectory(coreLibraryPath, frameworksPath)) {
        os_log_error(CBFreeRDPLogger, "⛔️ FreeRDP 运行库路径未受应用包边界约束");
        if (error) {
            *error = CBFreeRDPError(-106, @"FreeRDP 运行库路径验证失败",
                                    @"应用包未提供安全的 Frameworks 边界。");
        }
        return NO;
    }

    _libraryHandle = dlopen(coreLibraryPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!_libraryHandle) {
        os_log_error(CBFreeRDPLogger, "❌ 无法加载完整的 FreeRDP core 运行库闭包");
        if (error) {
            *error = [NSError errorWithDomain:CBFreeRDPErrorDomain
                                         code:-100
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"RDP 远程桌面功能暂不可用",
                NSLocalizedRecoverySuggestionErrorKey: @"请安装包含受验证 FreeRDP 3.30.0 core 运行库的完整 SkyBridge 版本。",
                NSLocalizedFailureReasonErrorKey: @"应用包内缺少必需的 FreeRDP 运行库",
                @"AlternativeFeatures": @[@"VNC", @"SSH", @"UltraStream"]
            }];
        }
        [self unloadLibraries];
        return NO;
    }

    _versionString = (freerdp_version_string_fn)dlsym(_libraryHandle, "freerdp_get_version_string");
    _clientNew = (freerdp_new_fn)dlsym(_libraryHandle, "freerdp_new");
    _clientFree = (freerdp_free_fn)dlsym(_libraryHandle, "freerdp_free");
    _contextNew = (freerdp_context_new_fn)dlsym(_libraryHandle, "freerdp_context_new");
    _contextFree = (freerdp_context_free_fn)dlsym(_libraryHandle, "freerdp_context_free");
    _clientConnect = (freerdp_connect_fn)dlsym(_libraryHandle, "freerdp_connect");
    _clientDisconnect = (freerdp_disconnect_fn)dlsym(_libraryHandle, "freerdp_disconnect");
    
 // FreeRDP 3.x 新增设置 API
    _settingsSetUint32 = (freerdp_settings_set_uint32_fn)dlsym(_libraryHandle, "freerdp_settings_set_uint32");
    _settingsSetString = (freerdp_settings_set_string_fn)dlsym(_libraryHandle, "freerdp_settings_set_string");
    
    _sendMouseEvent = (freerdp_input_send_mouse_event_fn)dlsym(_libraryHandle, "freerdp_input_send_mouse_event");
    _sendKeyboardEvent = (freerdp_input_send_keyboard_event_fn)dlsym(_libraryHandle, "freerdp_input_send_keyboard_event");

    // 画面、事件泵与输入都是发布级 RDP 功能的必要部分。
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
    if (!_contextFree) [missingSymbols addObject:@"freerdp_context_free"];
    if (!_clientConnect) [missingSymbols addObject:@"freerdp_connect"];
    if (!_clientDisconnect) [missingSymbols addObject:@"freerdp_disconnect"];
    if (!_settingsSetUint32) [missingSymbols addObject:@"freerdp_settings_set_uint32"];
    if (!_settingsSetString) [missingSymbols addObject:@"freerdp_settings_set_string"];
    if (!_settingsSetBool) [missingSymbols addObject:@"freerdp_settings_set_bool"];
    if (!_sendMouseEvent) [missingSymbols addObject:@"freerdp_input_send_mouse_event"];
    if (!_sendKeyboardEvent) [missingSymbols addObject:@"freerdp_input_send_keyboard_event"];
    if (!_gdiInit) [missingSymbols addObject:@"gdi_init"];
    if (!_gdiFree) [missingSymbols addObject:@"gdi_free"];
    if (!_checkEventHandles) [missingSymbols addObject:@"freerdp_check_event_handles"];
    
    if (missingSymbols.count > 0) {
        os_log_error(CBFreeRDPLogger, "❌ FreeRDP 基础函数符号缺失: %{public}@", [missingSymbols componentsJoinedByString:@", "]);
        if (error) {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"FreeRDP 动态库缺少必要的导出符号: %@", [missingSymbols componentsJoinedByString:@", "]],
                @"MissingSymbols": missingSymbols
            };
            *error = [NSError errorWithDomain:CBFreeRDPErrorDomain
                                         code:-101
                                     userInfo:userInfo];
        }
        [self unloadLibraries];
        return NO;
    }

    NSDictionary<NSString *, NSValue *> *criticalCoreSymbols = @{
        @"freerdp_get_version_string": [NSValue valueWithPointer:(void *)_versionString],
        @"freerdp_new": [NSValue valueWithPointer:(void *)_clientNew],
        @"freerdp_free": [NSValue valueWithPointer:(void *)_clientFree],
        @"freerdp_context_new": [NSValue valueWithPointer:(void *)_contextNew],
        @"freerdp_context_free": [NSValue valueWithPointer:(void *)_contextFree],
        @"freerdp_connect": [NSValue valueWithPointer:(void *)_clientConnect],
        @"freerdp_disconnect": [NSValue valueWithPointer:(void *)_clientDisconnect],
        @"freerdp_settings_set_uint32": [NSValue valueWithPointer:(void *)_settingsSetUint32],
        @"freerdp_settings_set_string": [NSValue valueWithPointer:(void *)_settingsSetString],
        @"freerdp_settings_set_bool": [NSValue valueWithPointer:(void *)_settingsSetBool],
        @"freerdp_input_send_mouse_event": [NSValue valueWithPointer:(void *)_sendMouseEvent],
        @"freerdp_input_send_keyboard_event": [NSValue valueWithPointer:(void *)_sendKeyboardEvent],
        @"gdi_init": [NSValue valueWithPointer:(void *)_gdiInit],
        @"gdi_free": [NSValue valueWithPointer:(void *)_gdiFree],
        @"freerdp_check_event_handles": [NSValue valueWithPointer:(void *)_checkEventHandles]
    };
    NSMutableArray<NSString *> *originMismatches = [NSMutableArray array];
    [criticalCoreSymbols enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSValue *value, BOOL *stop) {
        (void)stop;
        if (!CBSymbolOriginMatchesImage(value.pointerValue, coreLibraryPath)) {
            [originMismatches addObject:name];
        }
    }];
    if (originMismatches.count > 0) {
        os_log_error(
            CBFreeRDPLogger,
            "⛔️ FreeRDP 关键符号并非来自已选择的包内 image: %{public}@",
            [originMismatches componentsJoinedByString:@", "]
        );
        if (error) {
            *error = [NSError errorWithDomain:CBFreeRDPErrorDomain
                                         code:-103
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"FreeRDP 运行库来源验证失败",
                @"MismatchedSymbols": originMismatches
            }];
        }
        [self unloadLibraries];
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
    if (!versionStr || !CBFreeRDPVersionMatchesRequired(versionStr)) {
        os_log_error(
            CBFreeRDPLogger,
            "❌ FreeRDP 版本不匹配或无法识别: %{public}@，要求 %{public}@",
            versionStr ?: @"(unknown)",
            CBFreeRDPRequiredVersionString
        );
        if (error) {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: @"FreeRDP 版本不满足安全要求",
                NSLocalizedFailureReasonErrorKey: [NSString stringWithFormat:@"检测到版本 %@，要求经过验证的 %@。", versionStr ?: @"unknown", CBFreeRDPRequiredVersionString],
                NSLocalizedRecoverySuggestionErrorKey: @"请安装包含受验证 FreeRDP 3.30.0 运行库的完整 SkyBridge 版本。"
            };
            *error = [NSError errorWithDomain:CBFreeRDPErrorDomain
                                         code:-102
                                     userInfo:userInfo];
        }
        [self unloadLibraries];
        return NO;
    }
    os_log_info(CBFreeRDPLogger, "✅ FreeRDP 版本与受验证运行时要求一致");

    os_log_info(CBFreeRDPLogger, "✅ FreeRDP core-only 动态库与必需功能符号验证通过");
    return YES;
}

- (BOOL)startGraphicsAndPump
{
    // 运行在 workerQueue（由 connect 的 worker 块调用）。
    if (!self.connectionRef) {
        os_log_error(CBFreeRDPLogger, "❌ FreeRDP 实例不存在，无法初始化渲染");
        return NO;
    }
    rdpContext *context = CBGetContextFromInstance(self.connectionRef);
    if (!context) {
        os_log_error(CBFreeRDPLogger, "❌ FreeRDP 上下文不存在，无法初始化渲染");
        return NO;
    }
    if (!context->input || !context->update || !self.frameCallback) {
        os_log_error(CBFreeRDPLogger, "❌ FreeRDP 渲染/输入上下文或帧回调不完整");
        return NO;
    }

    // 初始化软件 GDI：分配 BGRA32 帧缓冲，经典位图/SurfaceBits 更新会绘制进 primary_buffer。
    BOOL gdiReady = _gdiInit(self.connectionRef, PIXEL_FORMAT_BGRA32);
    _gdiInitialized = gdiReady || context->gdi != NULL;
    if (!gdiReady || !context->gdi || !context->update->EndPaint) {
        os_log_error(CBFreeRDPLogger, "❌ FreeRDP 软件 GDI 或 EndPaint 回调初始化失败");
        return NO;
    }

    // 链接 GDI 原 EndPaint（保留失效区域维护），叠加本客户端的整帧发射。
    _originalEndPaint = context->update->EndPaint;
    context->update->EndPaint = CBEndPaintCallback;

    // 只在完整的 GDI/输入管线建立后注册非保留回调目标。
    [CBClientRegistryLock() lock];
    CBClientRegistry()[@((uintptr_t)self.connectionRef)] = [NSValue valueWithNonretainedObject:self];
    [CBClientRegistryLock() unlock];

    _pumpActive = YES;
    _connectionGeneration += 1;
    uint64_t generation = _connectionGeneration;
    [self notifyState:@"🖼️ 远程画面渲染已启用"];

    // TCP/RDP 握手成功但长期没有首帧不是可发布的「连接成功」。
    // generation 防止旧会话超时块影响后续重连。
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                   self.workerQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_pumpActive ||
            strongSelf->_connectionGeneration != generation ||
            strongSelf->_emittedFrameCount > 0) {
            return;
        }
        os_log_error(CBFreeRDPLogger, "❌ FreeRDP 首帧在发布级时限内未到达");
        [strongSelf teardownConnectionResources];
        strongSelf.state = CBFreeRDPClientStateFailed;
        [strongSelf notifyState:@"FreeRDP 会话因首帧超时已终止"];
    });
    return YES;
}

- (void)pumpEventsOnce
{
    if (!_pumpActive || !self.connectionRef) {
        return;
    }
    rdpContext *context = CBGetContextFromInstance(self.connectionRef);
    if (!context) {
        [self teardownConnectionResources];
        self.state = CBFreeRDPClientStateFailed;
        [self notifyState:@"FreeRDP 事件泵丢失上下文"];
        return;
    }
    if (!_checkEventHandles(context)) {
        // 连接关闭或出错：立即释放 context/GDI/instance，不保留半断开状态。
        [self teardownConnectionResources];
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
    BOOL originalResult = TRUE;
    if (_originalEndPaint) {
        originalResult = _originalEndPaint(context);
    }
    if (!originalResult) {
        os_log_error(CBFreeRDPLogger, "❌ FreeRDP GDI EndPaint 报告失败");
        return FALSE;
    }
    rdpGdi *gdi = context ? context->gdi : NULL;
    CBFreeRDPFrameCallback callback = self.frameCallback;
    if (callback && gdi && gdi->primary_buffer &&
        gdi->width > 0 && gdi->height > 0 && gdi->stride > 0) {
        NSUInteger stride = (NSUInteger)gdi->stride;
        NSUInteger height = (NSUInteger)gdi->height;
        static const NSUInteger maximumFrameBytes = 512u * 1024u * 1024u;
        if (height > NSUIntegerMax / stride || stride * height > maximumFrameBytes) {
            os_log_error(CBFreeRDPLogger, "❌ FreeRDP 帧缓冲尺寸超过有界资源策略");
            return FALSE;
        }
        NSData *frame = [NSData dataWithBytes:gdi->primary_buffer
                                       length:stride * height];
        callback(frame,
                 (uint32_t)gdi->width,
                 (uint32_t)gdi->height,
                 (uint32_t)gdi->stride,
                 CBFreeRDPFrameTypeBGRA);
        _emittedFrameCount += 1;
        if (_emittedFrameCount == 1) {
            self.state = CBFreeRDPClientStateConnected;
            os_log_info(CBFreeRDPLogger,
                        "🖼️ RDP 首帧已渲染并上抛: %dx%d stride=%d (软件 GDI 路径)",
                        gdi->width, gdi->height, (int)gdi->stride);
            [self notifyState:[NSString stringWithFormat:@"✅ FreeRDP 会话已连接，首帧 %dx%d 已到达",
                               gdi->width, gdi->height]];
        } else if ((_emittedFrameCount % 120) == 0) {
            os_log_debug(CBFreeRDPLogger, "🖼️ RDP 已渲染 %llu 帧", _emittedFrameCount);
        }
    } else if (!_loggedEmptyEndPaint && _emittedFrameCount == 0) {
        // EndPaint 触发但帧缓冲不可用：记录一次，便于诊断「连上但黑屏」(例如服务端仍用了无法解码的编解码)。
        _loggedEmptyEndPaint = YES;
        os_log_error(CBFreeRDPLogger,
                     "⚠️ EndPaint 触发但首帧缓冲不可用: callback=%d gdi=%d buffer=%d %dx%d stride=%d",
                     callback != nil, gdi != NULL, gdi && gdi->primary_buffer != NULL,
                     gdi ? gdi->width : -1, gdi ? gdi->height : -1,
                     gdi ? (int)gdi->stride : -1);
    }
    return originalResult;
}

#pragma mark - 设置配置方法

- (BOOL)applyAllSettings:(NSDictionary<NSString *, id> *)allSettings
                   error:(NSError *__autoreleasing  _Nullable * _Nullable)error
{
    CBFreeRDPClientState currentState = self.state;
    if (currentState == CBFreeRDPClientStateConnecting ||
        currentState == CBFreeRDPClientStateConnected ||
        currentState == CBFreeRDPClientStateDisconnecting) {
        if (error) {
            *error = CBFreeRDPError(-124, @"RDP 设置需要重新连接",
                                    @"连接期设置只能在会话启动前下发。");
        }
        return NO;
    }
    if (![allSettings isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = CBFreeRDPError(-125, @"RDP 设置无效", @"设置根对象必须是字典。");
        }
        return NO;
    }
    if (!CBValidateOnlyKeys(allSettings,
                            [NSSet setWithObjects:@"displaySettings", @"networkSettings", nil],
                            @"设置根对象", error)) {
        return NO;
    }

    [_configurationLock lock];
    CBFreeRDPPendingConfiguration configuration = _pendingConfiguration;
    [_configurationLock unlock];
    BOOL stagedAnySetting = NO;

    id displayValue = allSettings[@"displaySettings"];
    if (displayValue) {
        if (![displayValue isKindOfClass:[NSDictionary class]]) {
            if (error) {
                *error = CBFreeRDPError(-126, @"RDP 显示设置无效", @"显示设置必须是字典。");
            }
            return NO;
        }
        NSDictionary *display = displayValue;
        if (!CBValidateOnlyKeys(display,
                                [NSSet setWithObjects:@"width", @"height", @"colorDepth", nil],
                                @"显示设置", error)) {
            return NO;
        }
        id widthValue = display[@"width"];
        id heightValue = display[@"height"];
        if ((widthValue == nil) != (heightValue == nil)) {
            if (error) {
                *error = CBFreeRDPError(-127, @"RDP 分辨率无效", @"宽度和高度必须成对提供。");
            }
            return NO;
        }
        if (widthValue) {
            if (!CBParseBoundedUInt32(widthValue, @"桌面宽度", 64, 8192,
                                      &configuration.desktopWidth, error) ||
                !CBParseBoundedUInt32(heightValue, @"桌面高度", 64, 8192,
                                      &configuration.desktopHeight, error)) {
                return NO;
            }
            configuration.hasDesktopSize = YES;
            stagedAnySetting = YES;
        }
        id colorDepthValue = display[@"colorDepth"];
        if (colorDepthValue) {
            uint32_t colorDepth = 0;
            if (!CBParseBoundedUInt32(colorDepthValue, @"颜色深度", 8, 32, &colorDepth, error)) {
                return NO;
            }
            NSSet<NSNumber *> *supportedDepths = [NSSet setWithObjects:@8, @16, @24, @32, nil];
            if (![supportedDepths containsObject:@(colorDepth)]) {
                if (error) {
                    *error = CBFreeRDPError(-128, @"RDP 颜色深度无效", @"只支持 8、16、24 或 32 位颜色。");
                }
                return NO;
            }
            configuration.hasColorDepth = YES;
            configuration.colorDepth = colorDepth;
            stagedAnySetting = YES;
        }
    }

    id networkValue = allSettings[@"networkSettings"];
    if (networkValue) {
        if (![networkValue isKindOfClass:[NSDictionary class]]) {
            if (error) {
                *error = CBFreeRDPError(-129, @"RDP 网络设置无效", @"网络设置必须是字典。");
            }
            return NO;
        }
        NSDictionary *network = networkValue;
        if (!CBValidateOnlyKeys(network, [NSSet setWithObject:@"connectionType"],
                                @"网络设置", error)) {
            return NO;
        }
        id connectionTypeValue = network[@"connectionType"];
        if (connectionTypeValue) {
            if (!CBParseConnectionType(connectionTypeValue, &configuration.connectionType, error)) {
                return NO;
            }
            configuration.hasConnectionType = YES;
            stagedAnySetting = YES;
        }
    }

    if (!stagedAnySetting) {
        if (error) {
            *error = CBFreeRDPError(-130, @"RDP 设置为空", @"至少需要提供一个已接线的连接期设置。");
        }
        return NO;
    }

    [_configurationLock lock];
    currentState = self.state;
    if (currentState == CBFreeRDPClientStateConnecting ||
        currentState == CBFreeRDPClientStateConnected ||
        currentState == CBFreeRDPClientStateDisconnecting) {
        [_configurationLock unlock];
        if (error) {
            *error = CBFreeRDPError(-124, @"RDP 设置需要重新连接",
                                    @"连接期设置只能在会话启动前下发。");
        }
        return NO;
    }
    _pendingConfiguration = configuration;
    [_configurationLock unlock];
    os_log_info(CBFreeRDPLogger, "RDP 强类型连接期设置已暂存，将在 context ready 后严格应用");
    return YES;
}

- (BOOL)applyConnectionType:(UINT32)type toSettings:(rdpSettings *)settings
{
    typedef struct {
        FreeRDP_Settings_Keys_Bool key;
        BOOL values[7];
    } CBFreeRDPNetworkSetting;

    static const CBFreeRDPNetworkSetting networkSettings[] = {
        { FreeRDP_DisableWallpaper, { TRUE, TRUE, TRUE, TRUE, FALSE, FALSE, FALSE } },
        { FreeRDP_AllowFontSmoothing, { FALSE, FALSE, FALSE, FALSE, TRUE, TRUE, TRUE } },
        { FreeRDP_AllowDesktopComposition, { FALSE, FALSE, TRUE, TRUE, TRUE, TRUE, TRUE } },
        { FreeRDP_DisableFullWindowDrag, { TRUE, TRUE, TRUE, TRUE, FALSE, FALSE, FALSE } },
        { FreeRDP_DisableMenuAnims, { TRUE, TRUE, TRUE, TRUE, FALSE, FALSE, FALSE } },
        { FreeRDP_DisableThemes, { TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE } }
    };

    NSUInteger profileIndex;
    switch (type) {
        case CONNECTION_TYPE_MODEM: profileIndex = 0; break;
        case CONNECTION_TYPE_BROADBAND_LOW: profileIndex = 1; break;
        case CONNECTION_TYPE_SATELLITE: profileIndex = 2; break;
        case CONNECTION_TYPE_BROADBAND_HIGH: profileIndex = 3; break;
        case CONNECTION_TYPE_WAN: profileIndex = 4; break;
        case CONNECTION_TYPE_LAN: profileIndex = 5; break;
        case CONNECTION_TYPE_AUTODETECT: profileIndex = 6; break;
        default:
            os_log_error(CBFreeRDPLogger, "FreeRDP connection type is outside the supported profile set");
            return NO;
    }

    if (!_settingsSetUint32(settings, FreeRDP_ConnectionType, type)) {
        return NO;
    }
    for (size_t index = 0; index < sizeof(networkSettings) / sizeof(networkSettings[0]); index++) {
        const CBFreeRDPNetworkSetting setting = networkSettings[index];
        if (!_settingsSetBool(settings, setting.key, setting.values[profileIndex])) {
            return NO;
        }
    }
    return YES;
}

- (BOOL)applyPendingConfiguration
{
    rdpSettings *settings = [self currentSettings];
    if (!settings) {
        os_log_error(CBFreeRDPLogger, "❌ FreeRDP context ready 后仍无 settings");
        return NO;
    }

    [_configurationLock lock];
    CBFreeRDPPendingConfiguration configuration = _pendingConfiguration;
    [_configurationLock unlock];

    BOOL ok = TRUE;
    if (configuration.hasDesktopSize) {
        ok = _settingsSetUint32(settings, FreeRDP_DesktopWidth, configuration.desktopWidth) && ok;
        ok = _settingsSetUint32(settings, FreeRDP_DesktopHeight, configuration.desktopHeight) && ok;
    }
    if (configuration.hasColorDepth) {
        ok = _settingsSetUint32(settings, FreeRDP_ColorDepth, configuration.colorDepth) && ok;
    }
    if (configuration.hasConnectionType) {
        ok = [self applyConnectionType:configuration.connectionType toSettings:settings] && ok;
    }
    ok = _settingsSetBool(settings, FreeRDP_BitmapCacheEnabled, TRUE) && ok;
    if (!ok) {
        os_log_error(CBFreeRDPLogger, "❌ FreeRDP 拒绝了一个或多个强类型连接期设置");
        return NO;
    }
    os_log_info(CBFreeRDPLogger, "FreeRDP 强类型连接期设置已在 connect 前应用");
    return YES;
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
