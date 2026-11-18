#import "OVRealtimeIO.h"
#import "OVEngines.h"
#import "OVLocale.h"
#import <AudioToolbox/AudioToolbox.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

// Frame format of cns_rt_proto: "CNS1" | type u8 | seq u32 | n u32 | payload, little endian.
enum { kHeader = 13, kTypeAudio = 1, kTypeReply = 2, kTypeCtl = 3, kMaxN = OV_RT_MAX_BLOCK };
enum { kStampSlots = 64 };                        // blocks in flight (the engine holds at most 2 + 1)
static const uint32_t kCushionFrames = 1920;      // 40 ms of silence ahead of the first reply and after every underrun

/// Everything the real-time threads touch. Allocated once; no Objective-C objects inside.
typedef struct OVRtShared {
    OVRtAssembler *assembler;
    OVRtRing *outRing, *monRing;
    OVRtLatencyStats stats;
    uint32_t blockFrame, maxFill, target;
    _Atomic uint32_t levelBits;
    _Atomic bool monitorOn, needPrime, live;
    _Atomic uint64_t serverDropped, replies, heartbeat;
    _Atomic int32_t captureError;   // OSStatus of a failed AudioUnitRender, 0 = none
    dispatch_semaphore_t blockReady;
    // seq -> capture time (sender writes, receiver reads); stored as seq + 1 so 0 means empty
    _Atomic uint64_t capSeq[kStampSlots], capNs[kStampSlots];
    // reply start index in the output ring -> capture time (receiver writes, render reads)
    struct { uint64_t start, capNs; float blockMs; } stamps[kStampSlots];
    _Atomic uint64_t stHead, stTail;
    float monTmp[16384];
    // capture
    AudioUnit au;
    AudioBufferList *abl;          // non-interleaved, `channels` buffers of maxFrames floats
    float *mono, *conv;
    uint32_t maxFrames, channels, convCapacity;
    double deviceRate;
    AudioConverterRef converter;
    UInt32 convInFrames; float *convInPtr; BOOL convFed;
} OVRtShared;

static inline void AtomicMaxLevel(OVRtShared *c, float peak) {
    uint32_t old = atomic_load_explicit(&c->levelBits, memory_order_relaxed), nb;
    float cur; memcpy(&cur, &old, 4);
    if (peak <= cur) return;
    memcpy(&nb, &peak, 4);
    atomic_store_explicit(&c->levelBits, nb, memory_order_relaxed);
}

static OSStatus ConverterInput(AudioConverterRef conv, UInt32 *ioPackets, AudioBufferList *ioData, AudioStreamPacketDescription **desc, void *user) {
    OVRtShared *c = user;
    if (c->convFed || !c->convInFrames) { *ioPackets = 0; ioData->mBuffers[0].mDataByteSize = 0; return noErr; }
    c->convFed = YES;
    *ioPackets = c->convInFrames;
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = 1;
    ioData->mBuffers[0].mData = c->convInPtr;
    ioData->mBuffers[0].mDataByteSize = c->convInFrames * sizeof(float);
    return noErr;
}

/// Real-time thread: the input AUHAL has samples. No locks, no allocation, no Objective-C.
static OSStatus CaptureProc(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus, UInt32 frames, AudioBufferList *unused) {
    OVRtShared *c = ref;
    atomic_fetch_add_explicit(&c->heartbeat, 1, memory_order_relaxed);
    if (!atomic_load_explicit(&c->live, memory_order_relaxed) || frames > c->maxFrames) return noErr;
    for (UInt32 i = 0; i < c->channels; i++) c->abl->mBuffers[i].mDataByteSize = frames * sizeof(float);
    OSStatus st = AudioUnitRender(c->au, flags, ts, bus, frames, c->abl);
    if (st != noErr) { atomic_store_explicit(&c->captureError, (int32_t)st, memory_order_relaxed); return st; }
    float *mono = c->mono;
    if (c->channels == 1) {
        memcpy(mono, c->abl->mBuffers[0].mData, frames * sizeof(float));
    } else {
        UInt32 use = c->channels > 2 ? 2 : c->channels;
        const float *a = c->abl->mBuffers[0].mData, *b = c->abl->mBuffers[1].mData;
        if (use == 2) for (UInt32 i = 0; i < frames; i++) mono[i] = 0.5f * (a[i] + b[i]);
        else memcpy(mono, a, frames * sizeof(float));
    }
    uint64_t hostNs = (ts && (ts->mFlags & kAudioTimeStampHostTimeValid)) ? OVRtTicksToNs(ts->mHostTime) : OVRtNowNs();
    const float *pcm = mono;
    uint32_t n = frames;
    if (c->converter) {
        c->convInPtr = mono; c->convInFrames = frames; c->convFed = NO;
        UInt32 want = c->convCapacity;
        AudioBufferList out = {1, {{1, want * (UInt32)sizeof(float), c->conv}}};
        UInt32 got = want;
        AudioConverterFillComplexBuffer(c->converter, ConverterInput, c, &got, &out, NULL);
        pcm = c->conv; n = got;
    }
    if (!n) return noErr;
    float peak = 0;
    for (uint32_t i = 0; i < n; i++) { float v = fabsf(pcm[i]); if (v > peak) peak = v; }
    AtomicMaxLevel(c, peak);
    if (atomic_load_explicit(&c->monitorOn, memory_order_relaxed)) OVRtRingWrite(c->monRing, pcm, n);
    if (OVRtAssemblerPush(c->assembler, pcm, n, hostNs)) dispatch_semaphore_signal(c->blockReady);
    return noErr;
}

/// Real-time thread: the output wants `frames` samples.
static OSStatus RenderOut(OVRtShared *c, AudioBufferList *abl, AVAudioFrameCount frames) {
    float *out = abl->mBuffers[0].mData;
    OVRtRingTrim(c->outRing, c->maxFill, c->target);
    uint64_t before = atomic_load_explicit(&c->outRing->rd, memory_order_relaxed);
    uint32_t under = (uint32_t)atomic_load_explicit(&c->outRing->underruns, memory_order_relaxed);
    OVRtRingRead(c->outRing, out, frames);
    if ((uint32_t)atomic_load_explicit(&c->outRing->underruns, memory_order_relaxed) != under) atomic_store_explicit(&c->needPrime, true, memory_order_relaxed);
    uint64_t after = atomic_load_explicit(&c->outRing->rd, memory_order_relaxed);
    if (atomic_load_explicit(&c->monitorOn, memory_order_relaxed)) {
        OVRtRingTrim(c->monRing, 4800, 960);
        uint32_t m = frames < 16384 ? frames : 16384;
        OVRtRingRead(c->monRing, c->monTmp, m);
        for (uint32_t i = 0; i < m; i++) out[i] += c->monTmp[i];
    }
    // latency: the block whose first sample was just handed to the device
    uint64_t now = OVRtNowNs();
    uint64_t head = atomic_load_explicit(&c->stHead, memory_order_acquire), tail = atomic_load_explicit(&c->stTail, memory_order_relaxed);
    while (tail != head) {
        typeof(c->stamps[0]) *s = &c->stamps[tail % kStampSlots];
        if (s->start >= after) break;                    // not played yet
        if (s->start >= before) {
            uint64_t playNs = now + (s->start - before) * 1000000000ull / OV_RT_RATE;
            if (playNs > s->capNs) OVRtLatencyStatsAdd(&c->stats, (float)((double)(playNs - s->capNs) / 1e6 + s->blockMs));
        }                                                // else: trimmed away, counted in `trimmed`
        tail++;
    }
    atomic_store_explicit(&c->stTail, tail, memory_order_release);
    return noErr;
}

#pragma mark - Socket helpers (not real-time)

static BOOL SendAll(int fd, const void *buf, size_t n) {
    const uint8_t *p = buf;
    while (n) {
        ssize_t k = send(fd, p, n, 0);
        if (k < 0) { if (errno == EINTR) continue; return NO; }
        if (k == 0) return NO;
        p += k; n -= (size_t)k;
    }
    return YES;
}
static BOOL RecvAll(int fd, void *buf, size_t n) {
    uint8_t *p = buf;
    while (n) {
        ssize_t k = recv(fd, p, n, 0);
        if (k < 0) { if (errno == EINTR) continue; return NO; }
        if (k == 0) return NO;
        p += k; n -= (size_t)k;
    }
    return YES;
}
static void PutHeader(uint8_t *h, uint8_t type, uint32_t seq, uint32_t n) {
    memcpy(h, "CNS1", 4); h[4] = type;
    for (int i = 0; i < 4; i++) { h[5 + i] = (uint8_t)(seq >> (8 * i)); h[9 + i] = (uint8_t)(n >> (8 * i)); }
}
static uint32_t Get32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

#pragma mark - OVRealtimeIO

@interface OVRealtimeIO () {
    OVRtShared *_c;
    int _fd;
    AVAudioEngine *_outEngine;
    AVAudioSourceNode *_sourceNode;
    NSThread *_sender, *_receiver;
    dispatch_semaphore_t _senderDone, _receiverDone;
    id _inWatch, _outWatch;
    id _configObserver;
    BOOL _leak;                  // a thread did not end in time: the shared state is never freed
    BOOL _retriedOutput;
    NSDate *_startedAt;
    uint64_t _lastBeat; NSDate *_lastBeatAt;
    id _rateListener; AudioObjectPropertyAddress _rateAddr[2];
    NSLock *_sendLock;      // one writer on the socket at a time: audio frames and control frames never interleave
    _Atomic bool _stopping, _failed;
}
@property (nonatomic) OVAudioDevice *input, *output;
@property (readwrite) double inputHardwareMs, outputHardwareMs;
@property (readwrite) BOOL running;
@end

@implementation OVRealtimeIO

+ (AVAuthorizationStatus)microphoneStatus { return [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]; }

+ (void)requestMicrophoneAccess:(void (^)(BOOL))done {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(granted); });
    }];
}

- (instancetype)initWithInput:(OVAudioDevice *)input output:(OVAudioDevice *)output blockSeconds:(double)blockSeconds {
    if ((self = [super init])) {
        _input = input; _output = output; _fd = -1;
        _sendLock = [NSLock new];
        OVRtNowNs(); OVRtTicksToNs(1);   // the first call sets up the mach timebase: not on the audio thread
        _inputHardwareMs = [input latencyMsForInput:YES];
        _outputHardwareMs = [output latencyMsForInput:NO];
        _c = calloc(1, sizeof(OVRtShared));
        _c->blockFrame = OVRtBlockFrames(blockSeconds);
        _c->assembler = OVRtAssemblerCreate(_c->blockFrame, 6);
        _c->outRing = OVRtRingCreate(_c->blockFrame * 8 + 4 * kCushionFrames);
        _c->monRing = OVRtRingCreate(16384);
        _c->maxFill = _c->blockFrame * 3 + kCushionFrames;
        _c->target = _c->blockFrame + kCushionFrames;
        _c->blockReady = dispatch_semaphore_create(0);
        atomic_store(&_c->needPrime, true);
        if (!_c->assembler || !_c->outRing || !_c->monRing) return nil;
    }
    return self;
}

- (uint32_t)blockFrame { return _c->blockFrame; }
- (void)setMonitorOwnVoice:(BOOL)on { _monitorOwnVoice = on; atomic_store(&_c->monitorOn, on); }

- (void)dealloc {
    [self stopNow];
    if (_c && _leak) { NSLog(@"Realtime: a worker thread did not end in time; its buffers are left allocated."); }
    else if (_c) {
        OVRtAssemblerFree(_c->assembler); OVRtRingFree(_c->outRing); OVRtRingFree(_c->monRing);
        free(_c);
    }
}

#pragma mark Failure

- (void)failWith:(NSString *)message {
    if (atomic_exchange(&_failed, true) || atomic_load(&_stopping)) return;
    void (^cb)(NSString *) = self.onError;
    dispatch_async(dispatch_get_main_queue(), ^{ if (cb) cb(message); });
}

#pragma mark Connect

- (void)connectToSocket:(NSString *)path timeout:(NSTimeInterval)timeout completion:(void (^)(NSString *))done {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDate *end = [NSDate dateWithTimeIntervalSinceNow:timeout];
        int fd = -1;
        while (!atomic_load(&self->_stopping)) {
            fd = OVEnginesConnectSocket(path);
            if (fd >= 0 || [end timeIntervalSinceNow] <= 0) break;
            usleep(250 * 1000);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (fd < 0) { done(L(@"The voice engine did not answer in time. Try again; if it keeps failing, close other apps first.")); return; }
            if (atomic_load(&self->_stopping)) { close(fd); done(L(@"Stopped.")); return; }
            int one = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
            self->_fd = fd;
            done(nil);
        });
    });
}

#pragma mark Start

- (BOOL)setupCapture:(NSString **)error {
    OVRtShared *c = _c;
    AudioComponentDescription d = {kAudioUnitType_Output, kAudioUnitSubType_HALOutput, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent comp = AudioComponentFindNext(NULL, &d);
    if (!comp || AudioComponentInstanceNew(comp, &c->au) != noErr) { *error = L(@"The microphone could not be opened."); return NO; }
    UInt32 on = 1, off = 0;
    AudioDeviceID dev = _input.deviceID;
    OSStatus st = AudioUnitSetProperty(c->au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, sizeof on);
    st |= AudioUnitSetProperty(c->au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, sizeof off);
    st |= AudioUnitSetProperty(c->au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, sizeof dev);
    if (st != noErr) { *error = L(@"The microphone could not be opened. Choose another input."); return NO; }
    AudioStreamBasicDescription hw = {0};
    UInt32 sz = sizeof hw;
    if (AudioUnitGetProperty(c->au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &sz) != noErr || hw.mSampleRate <= 0 || hw.mChannelsPerFrame == 0) {
        *error = L(@"The microphone did not report its format. Choose another input."); return NO;
    }
    c->deviceRate = hw.mSampleRate;
    c->channels = hw.mChannelsPerFrame > 8 ? 8 : hw.mChannelsPerFrame;
    AudioStreamBasicDescription cl = {hw.mSampleRate, kAudioFormatLinearPCM,
        kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, c->channels, 32, 0};
    if (AudioUnitSetProperty(c->au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &cl, sizeof cl) != noErr) {
        *error = L(@"The microphone format is not supported. Choose another input."); return NO;
    }
    UInt32 maxF = 4096;
    AudioUnitSetProperty(c->au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxF, sizeof maxF);
    c->maxFrames = maxF;
    c->abl = calloc(1, sizeof(AudioBufferList) + (c->channels - 1) * sizeof(AudioBuffer));
    c->abl->mNumberBuffers = c->channels;
    for (UInt32 i = 0; i < c->channels; i++) {
        c->abl->mBuffers[i].mNumberChannels = 1;
        c->abl->mBuffers[i].mDataByteSize = maxF * sizeof(float);
        c->abl->mBuffers[i].mData = calloc(maxF, sizeof(float));
    }
    c->mono = calloc(maxF, sizeof(float));
    if (fabs(hw.mSampleRate - OV_RT_RATE) > 0.5) {   // a sample-rate converter, built here so the callback never allocates
        AudioStreamBasicDescription src = {hw.mSampleRate, kAudioFormatLinearPCM, kAudioFormatFlagsNativeFloatPacked, 4, 1, 4, 1, 32, 0};
        AudioStreamBasicDescription dst = {OV_RT_RATE, kAudioFormatLinearPCM, kAudioFormatFlagsNativeFloatPacked, 4, 1, 4, 1, 32, 0};
        if (AudioConverterNew(&src, &dst, &c->converter) != noErr) { *error = L(@"The microphone sample rate is not supported."); return NO; }
        UInt32 q = kAudioConverterQuality_High;
        AudioConverterSetProperty(c->converter, kAudioConverterSampleRateConverterQuality, sizeof q, &q);
        c->convCapacity = (uint32_t)(maxF * (double)OV_RT_RATE / hw.mSampleRate) + 64;
        c->conv = calloc(c->convCapacity, sizeof(float));
    }
    AURenderCallbackStruct cb = {CaptureProc, c};
    if (AudioUnitSetProperty(c->au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, sizeof cb) != noErr ||
        AudioUnitInitialize(c->au) != noErr) { *error = L(@"The microphone could not be opened. Choose another input."); return NO; }
    return YES;
}

- (BOOL)setupOutput:(NSString **)error {
    OVRtShared *c = _c;
    _outEngine = [AVAudioEngine new];
    AudioUnit au = _outEngine.outputNode.audioUnit;
    AudioDeviceID dev = _output.deviceID;
    if (!au || AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, sizeof dev) != noErr) {
        *error = L(@"The output device could not be opened. Choose another output."); return NO;
    }
    AVAudioFormat *fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:OV_RT_RATE channels:1];
    _sourceNode = [[AVAudioSourceNode alloc] initWithFormat:fmt renderBlock:^OSStatus(BOOL *isSilence, const AudioTimeStamp *ts, AVAudioFrameCount frames, AudioBufferList *abl) {
        return RenderOut(c, abl, frames);
    }];
    [_outEngine attachNode:_sourceNode];
    [_outEngine connect:_sourceNode to:_outEngine.mainMixerNode format:fmt];
    NSError *e = nil;
    if (![_outEngine startAndReturnError:&e]) {
        *error = [NSString stringWithFormat:L(@"The output device could not be started (%@). Choose another output."), e.localizedDescription ?: @""];
        return NO;
    }
    __weak typeof(self) w = self;
    _configObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVAudioEngineConfigurationChangeNotification object:_outEngine queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        [w outputConfigurationChanged];
    }];
    return YES;
}

/// A configuration change right after start is the Bluetooth profile switch (AirPods): rebuild the output once. Later ones end the session.
- (void)outputConfigurationChanged {
    if (atomic_load(&_stopping) || !_outEngine) return;
    if (!_retriedOutput && _startedAt && -[_startedAt timeIntervalSinceNow] < 2.0) {
        _retriedOutput = YES;
        if (_configObserver) { [NSNotificationCenter.defaultCenter removeObserver:_configObserver]; _configObserver = nil; }
        [_outEngine stop];
        _outEngine = nil; _sourceNode = nil;
        NSString *err = nil;
        if (![self setupOutput:&err]) [self failWith:err ?: L(@"The output device changed. Press Start again.")];
        return;
    }
    [self failWith:L(@"The output device changed. Press Start again.")];
}

/// Called by the page's poll timer: a dead microphone, a failed capture or revoked permission ends the session with a reason.
- (void)checkHealth {
    if (!self.running || atomic_load(&_stopping)) return;
    OVRtShared *c = _c;
    int32_t ce = atomic_load(&c->captureError);
    if (ce) { [self failWith:[NSString stringWithFormat:L(@"The microphone stopped delivering sound (error %d). Press Start again."), ce]]; return; }
    uint64_t beat = atomic_load(&c->heartbeat);
    NSDate *now = [NSDate date];
    if (!_lastBeatAt || beat != _lastBeat) { _lastBeat = beat; _lastBeatAt = now; }
    else if ([now timeIntervalSinceDate:_lastBeatAt] > 2.0) {
        AVAuthorizationStatus st = OVRealtimeIO.microphoneStatus;
        if (st == AVAuthorizationStatusDenied || st == AVAuthorizationStatusRestricted)
            [self failWith:L(@"Microphone access was turned off. Allow it in Privacy settings and press Start.")];
        else [self failWith:L(@"No sound from the microphone for 2 s. Check the microphone and press Start again.")];
    }
}

- (void)watchInputFormat {
    __weak typeof(self) w = self;
    AudioObjectPropertyListenerBlock b = ^(UInt32 n, const AudioObjectPropertyAddress *a) {
        [w failWith:L(@"The microphone changed its format. Press Start again.")];
    };
    _rateAddr[0] = (AudioObjectPropertyAddress){kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    _rateAddr[1] = (AudioObjectPropertyAddress){kAudioDevicePropertyStreamFormat, kAudioDevicePropertyScopeInput, kAudioObjectPropertyElementMain};
    for (int i = 0; i < 2; i++) AudioObjectAddPropertyListenerBlock(_input.deviceID, &_rateAddr[i], dispatch_get_main_queue(), b);
    _rateListener = [b copy];
}

- (BOOL)startAudio:(NSString **)error {
    if (_fd < 0) { if (error) *error = L(@"Not connected to the voice engine."); return NO; }
    NSString *err = nil;
    if (![self setupCapture:&err] || ![self setupOutput:&err]) { if (error) *error = err; [self stopNow]; return NO; }
    OVRtShared *c = _c;
    atomic_store(&c->live, true);
    if (AudioOutputUnitStart(c->au) != noErr) {
        if (error) *error = L(@"The microphone could not be started. Check Privacy settings or choose another input.");
        [self stopNow]; return NO;
    }
    _startedAt = [NSDate date];
    [self watchInputFormat];
    __weak typeof(self) w = self;
    _inWatch = [OVAudioDevices watchDevice:_input.deviceID onGone:^{ [w failWith:L(@"The microphone was unplugged. Plug it back in and press Start.")]; }];
    _outWatch = [OVAudioDevices watchDevice:_output.deviceID onGone:^{ [w failWith:L(@"The output device was disconnected. Choose another output and press Start.")]; }];
    _senderDone = dispatch_semaphore_create(0);
    _receiverDone = dispatch_semaphore_create(0);
    _sender = [[NSThread alloc] initWithTarget:self selector:@selector(senderLoop) object:nil];
    _sender.name = @"Clone'n'Speak realtime send";
    _sender.qualityOfService = NSQualityOfServiceUserInteractive;
    _receiver = [[NSThread alloc] initWithTarget:self selector:@selector(receiverLoop) object:nil];
    _receiver.name = @"Clone'n'Speak realtime receive";
    _receiver.qualityOfService = NSQualityOfServiceUserInteractive;
    [_sender start]; [_receiver start];
    self.running = YES;
    return YES;
}

#pragma mark Threads

- (void)senderLoop {
    OVRtShared *c = _c;
    uint32_t n = c->blockFrame;
    uint8_t *frame = malloc(kHeader + n * sizeof(float));
    float *blk = (float *)(frame + kHeader);
    uint32_t seq = 0;
    uint64_t lastNs = 0;
    while (!atomic_load(&_stopping)) {
        dispatch_semaphore_wait(c->blockReady, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC));
        while (!atomic_load(&_stopping) && OVRtAssemblerPop(c->assembler, blk, &lastNs)) {
            atomic_store_explicit(&c->capNs[seq % kStampSlots], lastNs, memory_order_relaxed);
            atomic_store_explicit(&c->capSeq[seq % kStampSlots], (uint64_t)seq + 1, memory_order_release);
            PutHeader(frame, kTypeAudio, seq, n);
            seq++;
            [_sendLock lock];
            BOOL sent = SendAll(_fd, frame, kHeader + n * sizeof(float));
            [_sendLock unlock];
            if (!sent) {
                [self failWith:L(@"The voice engine stopped. Press Start to run it again.")];
                goto done;
            }
        }
    }
done:
    free(frame);
    dispatch_semaphore_signal(_senderDone);
}

- (void)receiverLoop {
    OVRtShared *c = _c;
    uint8_t hdr[kHeader];
    float *samples = malloc(sizeof(float) * kMaxN);
    float *zeros = calloc(kCushionFrames, sizeof(float));
    double blockMs = (double)c->blockFrame * 1000.0 / OV_RT_RATE;
    while (!atomic_load(&_stopping)) {
        if (!RecvAll(_fd, hdr, kHeader)) { [self failWith:L(@"The voice engine stopped. Press Start to run it again.")]; break; }
        if (memcmp(hdr, "CNS1", 4) != 0) { [self failWith:L(@"The voice engine sent something unexpected. Press Start to run it again.")]; break; }
        uint8_t type = hdr[4];
        uint32_t seq = Get32(hdr + 5), n = Get32(hdr + 9);
        if (type == kTypeReply) {
            if (n > kMaxN) { [self failWith:L(@"The voice engine sent something unexpected. Press Start to run it again.")]; break; }
            float procMs;
            if (!RecvAll(_fd, &procMs, 4) || (n && !RecvAll(_fd, samples, n * sizeof(float)))) { [self failWith:L(@"The voice engine stopped. Press Start to run it again.")]; break; }
            atomic_fetch_add(&c->replies, 1);
            if (n == 0) { atomic_fetch_add(&c->serverDropped, 1); continue; }
            if (atomic_exchange_explicit(&c->needPrime, false, memory_order_relaxed)) OVRtRingWrite(c->outRing, zeros, kCushionFrames);
            uint64_t start = atomic_load_explicit(&c->outRing->wr, memory_order_relaxed);
            OVRtRingWrite(c->outRing, samples, n);
            uint32_t slot = seq % kStampSlots;
            if (atomic_load_explicit(&c->capSeq[slot], memory_order_acquire) == (uint64_t)seq + 1) {
                uint64_t h = atomic_load_explicit(&c->stHead, memory_order_relaxed), t = atomic_load_explicit(&c->stTail, memory_order_acquire);
                if (h - t < kStampSlots) {
                    c->stamps[h % kStampSlots].start = start;
                    c->stamps[h % kStampSlots].capNs = atomic_load_explicit(&c->capNs[slot], memory_order_relaxed);
                    c->stamps[h % kStampSlots].blockMs = (float)blockMs;
                    atomic_store_explicit(&c->stHead, h + 1, memory_order_release);
                }
            }
        } else {
            // not expected from the engine: skip the payload
            uint32_t len = n > 4096 ? 0 : n;
            if (len) { uint8_t skip[4096]; if (!RecvAll(_fd, skip, len)) break; }
        }
    }
    free(samples); free(zeros);
    dispatch_semaphore_signal(_receiverDone);
}

#pragma mark Control and stats

- (void)sendSet:(NSDictionary<NSString *, NSNumber *> *)changes {
    if (atomic_load(&_stopping) || !self.running || !changes.count) return;
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"set": changes} options:0 error:nil];
    if (!json || json.length > 4096) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        uint8_t h[kHeader];
        PutHeader(h, kTypeCtl, 0, (uint32_t)json.length);
        NSMutableData *all = [NSMutableData dataWithBytes:h length:kHeader];
        [all appendData:json];
        [self->_sendLock lock];
        int fd = self->_fd;   // read under the lock: stopNow clears it under the same lock before close()
        if (fd >= 0 && !atomic_load(&self->_stopping)) SendAll(fd, all.bytes, all.length);
        [self->_sendLock unlock];
    });
}

- (float)takeInputLevel {
    uint32_t b = atomic_exchange_explicit(&_c->levelBits, 0, memory_order_relaxed);
    float v; memcpy(&v, &b, 4);
    return v;
}

- (void)getP50:(double *)p50 p95:(double *)p95 count:(uint64_t *)count dropped:(uint64_t *)dropped underruns:(uint64_t *)underruns {
    OVRtLatencyStatsPercentiles(&_c->stats, p50, p95);
    if (count) *count = OVRtLatencyStatsCount(&_c->stats);
    if (dropped) *dropped = atomic_load(&_c->assembler->dropped) + atomic_load(&_c->serverDropped);
    if (underruns) *underruns = atomic_load(&_c->outRing->underruns);
}

#pragma mark Stop

- (void)stop {
    if (atomic_load(&_stopping)) return;
    [self stopNow];
}

- (void)stopNow {
    if (atomic_exchange(&_stopping, true)) return;
    OVRtShared *c = _c;
    if (_inWatch) [OVAudioDevices stopWatching:_inWatch];
    if (_outWatch) [OVAudioDevices stopWatching:_outWatch];
    _inWatch = _outWatch = nil;
    if (_configObserver) { [NSNotificationCenter.defaultCenter removeObserver:_configObserver]; _configObserver = nil; }
    if (_rateListener) {
        for (int i = 0; i < 2; i++) AudioObjectRemovePropertyListenerBlock(_input.deviceID, &_rateAddr[i], dispatch_get_main_queue(), _rateListener);
        _rateListener = nil;
    }
    if (c) atomic_store(&c->live, false);
    if (c && c->au) {
        AudioOutputUnitStop(c->au);
        AudioUnitUninitialize(c->au);
        AudioComponentInstanceDispose(c->au);
        c->au = NULL;
    }
    [_outEngine stop];
    _outEngine = nil; _sourceNode = nil;
    [_sendLock lock];
    int fd = _fd;
    [_sendLock unlock];
    if (fd >= 0) {
        // quit control frame first: the engine ends the session cleanly (result with stats) instead of by SIGTERM
        NSData *q = [@"{\"cmd\":\"quit\"}" dataUsingEncoding:NSUTF8StringEncoding];
        uint8_t h[kHeader];
        PutHeader(h, kTypeCtl, 0, (uint32_t)q.length);
        NSMutableData *all = [NSMutableData dataWithBytes:h length:kHeader];
        [all appendData:q];
        // If the sender is stuck in send() (a full socket buffer) tryLock fails and the quit frame is skipped on purpose:
        // shutdown() below still ends the session (the engine sees the client leave and returns its stats).
        if (self.running && [_sendLock tryLock]) { SendAll(fd, all.bytes, all.length); [_sendLock unlock]; }
        shutdown(fd, SHUT_RDWR);
    }
    if (c) dispatch_semaphore_signal(c->blockReady);
    if (_sender && dispatch_semaphore_wait(_senderDone, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) != 0) _leak = YES;
    if (_receiver && dispatch_semaphore_wait(_receiverDone, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) != 0) _leak = YES;
    if (_leak) NSLog(@"Realtime: a worker thread did not stop within 2 s; leaving its buffers allocated instead of freeing them.");
    [_sendLock lock];
    _fd = -1;
    if (fd >= 0) close(fd);
    [_sendLock unlock];
    if (c && !_leak) {
        if (c->converter) { AudioConverterDispose(c->converter); c->converter = NULL; }
        if (c->abl) { for (UInt32 i = 0; i < c->channels; i++) free(c->abl->mBuffers[i].mData); free(c->abl); c->abl = NULL; }
        free(c->mono); c->mono = NULL; free(c->conv); c->conv = NULL;
    }
    self.running = NO;
}

@end
