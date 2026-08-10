#import "SBWebRTCSystemAudioDevice.h"

#import <AudioToolbox/AudioToolbox.h>
#import <WebRTC/RTCAudioDevice.h>
#import <mach/mach_time.h>

@interface SBWebRTCSystemAudioDevice () <RTCAudioDevice>

@property(nonatomic, weak, nullable) id<RTCAudioDeviceDelegate> delegate;
@property(nonatomic, strong, readonly) NSLock *stateLock;
@property(nonatomic, assign) BOOL initializedState;
@property(nonatomic, assign) BOOL playoutInitializedState;
@property(nonatomic, assign) BOOL playingState;
@property(nonatomic, assign) BOOL recordingInitializedState;
@property(nonatomic, assign) BOOL recordingState;
@property(nonatomic, assign) uint64_t sampleCursor;
@property(nonatomic, copy, nullable) NSUUID *recordedAudioOwnerToken;

@end

@implementation SBWebRTCSystemAudioDevice

+ (instancetype)sharedDevice {
    static SBWebRTCSystemAudioDevice *sharedDevice = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedDevice = [[self alloc] initPrivate];
    });
    return sharedDevice;
}

- (instancetype)init {
    return [SBWebRTCSystemAudioDevice sharedDevice];
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _stateLock = [[NSLock alloc] init];
    }
    return self;
}

- (double)deviceInputSampleRate {
    return 48000.0;
}

- (NSTimeInterval)inputIOBufferDuration {
    return 0.02;
}

- (NSInteger)inputNumberOfChannels {
    return 2;
}

- (NSTimeInterval)inputLatency {
    return 0;
}

- (double)deviceOutputSampleRate {
    return 48000.0;
}

- (NSTimeInterval)outputIOBufferDuration {
    return 0.02;
}

- (NSInteger)outputNumberOfChannels {
    return 2;
}

- (NSTimeInterval)outputLatency {
    return 0;
}

- (BOOL)isInitialized {
    return self.initializedState;
}

- (BOOL)isPlayoutInitialized {
    return self.playoutInitializedState;
}

- (BOOL)isPlaying {
    return self.playingState;
}

- (BOOL)isRecordingInitialized {
    return self.recordingInitializedState;
}

- (BOOL)isRecording {
    return self.recordingState;
}

- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate {
    [self.stateLock lock];
    self.delegate = delegate;
    self.initializedState = YES;
    self.sampleCursor = 0;
    [self.stateLock unlock];
    [self notifyInputParametersChangedIfPossible];
    [self notifyOutputParametersChangedIfPossible];
    return YES;
}

- (BOOL)terminateDevice {
    [self.stateLock lock];
    self.delegate = nil;
    self.initializedState = NO;
    self.playoutInitializedState = NO;
    self.playingState = NO;
    self.recordingInitializedState = NO;
    self.recordingState = NO;
    self.sampleCursor = 0;
    self.recordedAudioOwnerToken = nil;
    [self.stateLock unlock];
    return YES;
}

- (void)activateRecordedAudioOwnerWithToken:(NSUUID *)ownerToken {
    if (ownerToken == nil) {
        return;
    }
    [self.stateLock lock];
    if (![self.recordedAudioOwnerToken isEqual:ownerToken]) {
        self.recordedAudioOwnerToken = [ownerToken copy];
        self.sampleCursor = 0;
    }
    [self.stateLock unlock];
}

- (void)retireRecordedAudioOwnerWithToken:(NSUUID *)ownerToken {
    if (ownerToken == nil) {
        return;
    }
    [self.stateLock lock];
    if ([self.recordedAudioOwnerToken isEqual:ownerToken]) {
        self.recordedAudioOwnerToken = nil;
        self.sampleCursor = 0;
    }
    [self.stateLock unlock];
}

- (BOOL)initializePlayout {
    [self.stateLock lock];
    self.playoutInitializedState = YES;
    [self.stateLock unlock];
    return YES;
}

- (BOOL)startPlayout {
    [self.stateLock lock];
    self.playingState = YES;
    [self.stateLock unlock];
    return YES;
}

- (BOOL)stopPlayout {
    [self.stateLock lock];
    self.playingState = NO;
    [self.stateLock unlock];
    return YES;
}

- (BOOL)initializeRecording {
    [self.stateLock lock];
    self.recordingInitializedState = YES;
    [self.stateLock unlock];
    [self notifyInputParametersChangedIfPossible];
    return YES;
}

- (BOOL)startRecording {
    [self.stateLock lock];
    self.recordingState = YES;
    [self.stateLock unlock];
    [self notifyInputParametersChangedIfPossible];
    return YES;
}

- (BOOL)stopRecording {
    [self.stateLock lock];
    self.recordingState = NO;
    [self.stateLock unlock];
    return YES;
}

- (void)pushRecordedPCM16InterleavedData:(NSData *)data
                              sampleRate:(NSInteger)sampleRate
                            channelCount:(NSInteger)channelCount
                              frameCount:(NSInteger)frameCount
                              ownerToken:(NSUUID *)ownerToken {
    if (sampleRate != 48000 || channelCount != 2 || frameCount <= 0 || data.length == 0) {
        return;
    }

    [self.stateLock lock];
    id<RTCAudioDeviceDelegate> delegate = self.delegate;
    BOOL shouldDeliver = self.initializedState &&
                         self.recordingState &&
                         delegate != nil &&
                         [self.recordedAudioOwnerToken isEqual:ownerToken];
    uint64_t sampleTime = self.sampleCursor;
    if (shouldDeliver) {
        self.sampleCursor += (uint64_t)frameCount;
    }
    [self.stateLock unlock];

    if (!shouldDeliver) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    [delegate dispatchAsync:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }

        [strongSelf.stateLock lock];
        BOOL stillAuthorized = strongSelf.initializedState &&
                               strongSelf.recordingState &&
                               strongSelf.delegate == delegate &&
                               [strongSelf.recordedAudioOwnerToken isEqual:ownerToken];
        if (!stillAuthorized) {
            [strongSelf.stateLock unlock];
            return;
        }

        AudioBuffer buffer = {
            .mNumberChannels = (UInt32)channelCount,
            .mDataByteSize = (UInt32)data.length,
            .mData = (void *)data.bytes
        };
        AudioBufferList bufferList = {
            .mNumberBuffers = 1,
            .mBuffers = { buffer }
        };
        AudioUnitRenderActionFlags flags = 0;
        AudioTimeStamp timestamp = {
            .mSampleTime = (Float64)sampleTime,
            .mHostTime = mach_absolute_time(),
            .mRateScalar = 0,
            .mWordClockTime = 0,
            .mSMPTETime = { 0 },
            .mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid,
            .mReserved = 0
        };

        delegate.deliverRecordedData(&flags,
                                     &timestamp,
                                     0,
                                     (UInt32)frameCount,
                                     &bufferList,
                                     NULL,
                                     nil);
        [strongSelf.stateLock unlock];
    }];
}

- (void)notifyInputParametersChangedIfPossible {
    [self.stateLock lock];
    id<RTCAudioDeviceDelegate> delegate = self.delegate;
    [self.stateLock unlock];
    if (delegate == nil) {
        return;
    }

    [delegate dispatchAsync:^{
        [delegate notifyAudioInputParametersChange];
    }];
}

- (void)notifyOutputParametersChangedIfPossible {
    [self.stateLock lock];
    id<RTCAudioDeviceDelegate> delegate = self.delegate;
    [self.stateLock unlock];
    if (delegate == nil) {
        return;
    }

    [delegate dispatchAsync:^{
        [delegate notifyAudioOutputParametersChange];
    }];
}

@end
