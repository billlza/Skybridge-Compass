#import "CBFreeRDPClient.h"
#import <dlfcn.h>
#import <os/log.h>

typedef void *freerdp_context_ref;
typedef void *freerdp_connection_ref;

typedef const char *(*freerdp_version_string_fn)(void);
typedef freerdp_connection_ref (*freerdp_new_fn)(void);
typedef void (*freerdp_free_fn)(freerdp_connection_ref instance);
typedef BOOL (*freerdp_connect_fn)(freerdp_connection_ref instance);
typedef void (*freerdp_disconnect_fn)(freerdp_connection_ref instance);

static os_log_t CBFreeRDPLogger;

@interface CBFreeRDPClient ()
{
    void *_libraryHandle;
    freerdp_version_string_fn _versionString;
    freerdp_new_fn _clientNew;
    freerdp_free_fn _clientFree;
    freerdp_connect_fn _clientConnect;
    freerdp_disconnect_fn _clientDisconnect;
}

@property (atomic) CBFreeRDPClientState state;
@property (nonatomic, strong) dispatch_queue_t workerQueue;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *password;
@property (nonatomic, copy, nullable) NSString *domain;
@property (nonatomic) freerdp_connection_ref connectionRef;
@property (nonatomic, strong) NSTimer * _Nullable keepAliveTimer;

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

#pragma mark - Connection lifecycle

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

        if (strongSelf->_clientNew) {
            strongSelf.connectionRef = strongSelf->_clientNew();
        }

        if (!strongSelf.connectionRef) {
            strongSelf.state = CBFreeRDPClientStateFailed;
            [strongSelf notifyState:@"无法创建 FreeRDP 客户端上下文"];
            return;
        }

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
        [strongSelf notifyState:@"FreeRDP 会话已连接"];
        [strongSelf startKeepAlive];
    });

    return YES;
}

- (void)disconnect
{
    dispatch_async(self.workerQueue, ^{
        if (self.connectionRef && self->_clientDisconnect) {
            self->_clientDisconnect(self.connectionRef);
        }
        if (self.connectionRef && self->_clientFree) {
            self->_clientFree(self.connectionRef);
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
}

- (void)submitKeyboardEventWithCode:(uint16_t)code
                                down:(BOOL)down
{
    os_log_debug(CBFreeRDPLogger, "Keyboard event code %u down %d", code, down);
}

#pragma mark - Helpers

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

    NSArray<NSString *> *candidatePaths = @[
        @"/usr/local/lib/libfreerdp2.dylib",
        @"/opt/homebrew/lib/libfreerdp2.dylib",
        @"/usr/lib/libfreerdp2.dylib",
        @"libfreerdp2.dylib"
    ];

    for (NSString *path in candidatePaths) {
        void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (handle != NULL) {
            _libraryHandle = handle;
            break;
        }
    }

    if (!_libraryHandle) {
        if (error) {
            NSDictionary *userInfo = @{NSLocalizedDescriptionKey: @"无法加载 libfreerdp2.dylib，请确认已经正确安装"};
            *error = [NSError errorWithDomain:@"com.skybridge.compass.freerdp"
                                         code:-100
                                     userInfo:userInfo];
        }
        return NO;
    }

    _versionString = (freerdp_version_string_fn)dlsym(_libraryHandle, "freerdp_get_version_string");
    _clientNew = (freerdp_new_fn)dlsym(_libraryHandle, "freerdp_new");
    _clientFree = (freerdp_free_fn)dlsym(_libraryHandle, "freerdp_free");
    _clientConnect = (freerdp_connect_fn)dlsym(_libraryHandle, "freerdp_connect");
    _clientDisconnect = (freerdp_disconnect_fn)dlsym(_libraryHandle, "freerdp_disconnect");

    if (!_versionString || !_clientNew || !_clientFree || !_clientConnect || !_clientDisconnect) {
        os_log_error(CBFreeRDPLogger, "FreeRDP symbols are missing from the dynamic library");
        if (error) {
            NSDictionary *userInfo = @{NSLocalizedDescriptionKey: @"libfreerdp2.dylib 缺少必要的导出符号"};
            *error = [NSError errorWithDomain:@"com.skybridge.compass.freerdp"
                                         code:-101
                                     userInfo:userInfo];
        }
        dlclose(_libraryHandle);
        _libraryHandle = NULL;
        return NO;
    }

    os_log_info(CBFreeRDPLogger, "libfreerdp2.dylib loaded successfully");
    return YES;
}

- (void)startKeepAlive
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self.keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:15.0
                                                                repeats:YES
                                                                  block:^(__unused NSTimer * _Nonnull timer) {
            os_log_debug(CBFreeRDPLogger, "Issuing FreeRDP keep-alive ping");
        }];
    });
}

@end
