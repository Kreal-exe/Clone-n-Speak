#import "OVAudioDevices.h"

NSNotificationName const OVAudioDevicesDidChangeNotification = @"OVAudioDevicesDidChange";

static AudioObjectPropertyAddress Addr(AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
    return (AudioObjectPropertyAddress){sel, scope, kAudioObjectPropertyElementMain};
}

static NSString *StringProp(AudioObjectID obj, AudioObjectPropertySelector sel) {
    AudioObjectPropertyAddress a = Addr(sel, kAudioObjectPropertyScopeGlobal);
    CFStringRef s = NULL;
    UInt32 size = sizeof s;
    if (AudioObjectGetPropertyData(obj, &a, 0, NULL, &size, &s) != noErr || !s) return @"";
    return CFBridgingRelease(s);
}

static UInt32 U32Prop(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope, UInt32 fallback) {
    AudioObjectPropertyAddress a = Addr(sel, scope);
    UInt32 v = 0, size = sizeof v;
    if (AudioObjectGetPropertyData(obj, &a, 0, NULL, &size, &v) != noErr) return fallback;
    return v;
}

/// Channels of the scope (0 = the device has no stream there).
static UInt32 ChannelCount(AudioObjectID dev, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = Addr(kAudioDevicePropertyStreamConfiguration, scope);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &size) != noErr || size < sizeof(AudioBufferList)) return 0;
    AudioBufferList *list = malloc(size);
    UInt32 n = 0;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, list) == noErr)
        for (UInt32 i = 0; i < list->mNumberBuffers; i++) n += list->mBuffers[i].mNumberChannels;
    free(list);
    return n;
}

@interface OVAudioDevice ()
@property AudioDeviceID deviceID;
@property (copy) NSString *uid, *name;
@property OVAudioTransport transport;
@property uint32_t transportCode;
@property BOOL hasInput, hasOutput, isBuiltInSpeaker;
@property double sampleRate;
@end

@implementation OVAudioDevice

+ (instancetype)deviceWithID:(AudioDeviceID)dev {
    OVAudioDevice *d = [OVAudioDevice new];
    d.deviceID = dev;
    d.uid = StringProp(dev, kAudioDevicePropertyDeviceUID);
    d.name = StringProp(dev, kAudioObjectPropertyName);
    if (!d.name.length) d.name = d.uid;
    d.transportCode = U32Prop(dev, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, 0);
    d.transport = [OVAudioDevices transportForCode:d.transportCode];
    d.hasInput = ChannelCount(dev, kAudioDevicePropertyScopeInput) > 0;
    d.hasOutput = ChannelCount(dev, kAudioDevicePropertyScopeOutput) > 0;
    AudioObjectPropertyAddress ra = Addr(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal);
    Float64 sr = 0; UInt32 sz = sizeof sr;
    d.sampleRate = AudioObjectGetPropertyData(dev, &ra, 0, NULL, &sz, &sr) == noErr && sr > 0 ? sr : 48000;
    if (d.hasOutput && d.transport == OVAudioTransportBuiltIn) {
        // the data source of the built-in output: 'ispk' = internal speaker, 'hdpn' = headphone jack
        UInt32 src = U32Prop(dev, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput, 0);
        d.isBuiltInSpeaker = src != 'hdpn';
    }
    return d;
}

- (uint32_t)latencyFramesForInput:(BOOL)input {
    AudioObjectPropertyScope sc = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput;
    UInt32 total = U32Prop(_deviceID, kAudioDevicePropertyLatency, sc, 0) + U32Prop(_deviceID, kAudioDevicePropertySafetyOffset, sc, 0)
                 + U32Prop(_deviceID, kAudioDevicePropertyBufferFrameSize, sc, 0);
    // the first stream's own latency
    AudioObjectPropertyAddress a = Addr(kAudioDevicePropertyStreams, sc);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(_deviceID, &a, 0, NULL, &size) == noErr && size >= sizeof(AudioStreamID)) {
        AudioStreamID *ids = malloc(size);
        if (AudioObjectGetPropertyData(_deviceID, &a, 0, NULL, &size, ids) == noErr)
            total += U32Prop(ids[0], kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, 0);
        free(ids);
    }
    return total;
}

- (double)latencyMsForInput:(BOOL)input {
    double sr = _sampleRate > 0 ? _sampleRate : 48000;
    return [self latencyFramesForInput:input] * 1000.0 / sr;
}

- (uint32_t)setBufferFrames:(uint32_t)frames {
    AudioObjectPropertyScope sc = self.hasOutput && !self.hasInput ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput;
    AudioObjectPropertyAddress a = Addr(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal);
    UInt32 v = frames;
    AudioObjectSetPropertyData(_deviceID, &a, 0, NULL, sizeof v, &v);
    return U32Prop(_deviceID, kAudioDevicePropertyBufferFrameSize, sc, frames);
}

@end

#pragma mark - OVAudioDevices

static NSArray<OVAudioDevice *> *AllDevices(void) {
    AudioObjectPropertyAddress a = Addr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size) != noErr || !size) return @[];
    AudioDeviceID *ids = malloc(size);
    NSMutableArray *out = [NSMutableArray array];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, ids) == noErr)
        for (UInt32 i = 0; i < size / sizeof(AudioDeviceID); i++) [out addObject:[OVAudioDevice deviceWithID:ids[i]]];
    free(ids);
    return out;
}

static AudioDeviceID DefaultID(AudioObjectPropertySelector sel) {
    AudioObjectPropertyAddress a = Addr(sel, kAudioObjectPropertyScopeGlobal);
    AudioDeviceID d = kAudioObjectUnknown;
    UInt32 size = sizeof d;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &d);
    return d;
}

@implementation OVAudioDevices

+ (NSArray<OVAudioDevice *> *)inputDevices {
    NSMutableArray *a = [NSMutableArray array];
    for (OVAudioDevice *d in AllDevices()) if (d.hasInput) [a addObject:d];
    return a;
}
+ (NSArray<OVAudioDevice *> *)outputDevices {
    NSMutableArray *a = [NSMutableArray array];
    for (OVAudioDevice *d in AllDevices()) if (d.hasOutput) [a addObject:d];
    return a;
}
+ (OVAudioDevice *)defaultInput {
    AudioDeviceID i = DefaultID(kAudioHardwarePropertyDefaultInputDevice);
    return i == kAudioObjectUnknown ? nil : [OVAudioDevice deviceWithID:i];
}
+ (OVAudioDevice *)defaultOutput {
    AudioDeviceID i = DefaultID(kAudioHardwarePropertyDefaultOutputDevice);
    return i == kAudioObjectUnknown ? nil : [OVAudioDevice deviceWithID:i];
}
+ (OVAudioDevice *)deviceWithUID:(NSString *)uid {
    for (OVAudioDevice *d in AllDevices()) if ([d.uid isEqualToString:uid]) return d;
    return nil;
}
+ (OVAudioDevice *)deviceWithID:(AudioDeviceID)deviceID {
    for (OVAudioDevice *d in AllDevices()) if (d.deviceID == deviceID) return d;
    return nil;
}

+ (OVAudioTransport)transportForCode:(uint32_t)code {
    switch (code) {
        case kAudioDeviceTransportTypeBuiltIn: return OVAudioTransportBuiltIn;
        case kAudioDeviceTransportTypeUSB: return OVAudioTransportUSB;
        case kAudioDeviceTransportTypeBluetooth: case kAudioDeviceTransportTypeBluetoothLE: return OVAudioTransportBluetooth;
        case kAudioDeviceTransportTypeVirtual: return OVAudioTransportVirtual;
        case kAudioDeviceTransportTypeHDMI: case kAudioDeviceTransportTypeDisplayPort: return OVAudioTransportHDMI;
        case kAudioDeviceTransportTypeAggregate: return OVAudioTransportAggregate;
        default: return OVAudioTransportOther;
    }
}
+ (NSString *)transportName:(OVAudioTransport)t {
    switch (t) {
        case OVAudioTransportBuiltIn: return @"Built-in";
        case OVAudioTransportUSB: return @"USB";
        case OVAudioTransportBluetooth: return @"Bluetooth";
        case OVAudioTransportVirtual: return @"Virtual";
        case OVAudioTransportHDMI: return @"HDMI";
        case OVAudioTransportAggregate: return @"Aggregate";
        default: return @"Other";
    }
}
+ (BOOL)isBlackHoleName:(NSString *)name { return [name rangeOfString:@"BlackHole" options:NSCaseInsensitiveSearch].location != NSNotFound; }

static OSStatus HardwareChanged(AudioObjectID obj, UInt32 n, const AudioObjectPropertyAddress *addrs, void *ctx) {
    dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:OVAudioDevicesDidChangeNotification object:nil]; });
    return noErr;
}

+ (void)startObserving {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AudioObjectPropertySelector sels[] = {kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice};
        for (int i = 0; i < 3; i++) {
            AudioObjectPropertyAddress a = Addr(sels[i], kAudioObjectPropertyScopeGlobal);
            AudioObjectAddPropertyListener(kAudioObjectSystemObject, &a, HardwareChanged, NULL);
        }
    });
}

@end

#pragma mark - Watching a device

@interface OVDeviceWatch : NSObject
@property AudioDeviceID deviceID;
@property (copy) void (^onGone)(void);
@property BOOL fired, stopped;
@property AudioObjectPropertyListenerBlock block;
@end
@implementation OVDeviceWatch @end

@implementation OVAudioDevices (Watch)

+ (id)watchDevice:(AudioDeviceID)deviceID onGone:(void (^)(void))onGone {
    OVDeviceWatch *w = [OVDeviceWatch new];
    w.deviceID = deviceID;
    w.onGone = onGone;
    __weak OVDeviceWatch *weak = w;
    w.block = ^(UInt32 n, const AudioObjectPropertyAddress *addrs) {
        OVDeviceWatch *s = weak;
        if (!s || s.fired || s.stopped) return;
        AudioObjectPropertyAddress a = Addr(kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal);
        UInt32 alive = 1, size = sizeof alive;
        OSStatus st = AudioObjectGetPropertyData(s.deviceID, &a, 0, NULL, &size, &alive);
        BOOL gone = st != noErr || !alive;
        if (!gone) {   // a device that left the list is gone even when its object still answers
            gone = YES;
            for (OVAudioDevice *d in AllDevices()) if (d.deviceID == s.deviceID) { gone = NO; break; }
        }
        if (!gone) return;
        s.fired = YES;
        dispatch_async(dispatch_get_main_queue(), ^{ if (!s.stopped && s.onGone) s.onGone(); });
    };
    AudioObjectPropertyAddress alive = Addr(kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal);
    AudioObjectAddPropertyListenerBlock(deviceID, &alive, dispatch_get_main_queue(), w.block);
    AudioObjectPropertyAddress list = Addr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal);
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &list, dispatch_get_main_queue(), w.block);
    return w;
}

+ (void)stopWatching:(id)token {
    OVDeviceWatch *w = token;
    if (![w isKindOfClass:OVDeviceWatch.class] || w.stopped) return;
    w.stopped = YES;
    AudioObjectPropertyAddress alive = Addr(kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal);
    AudioObjectRemovePropertyListenerBlock(w.deviceID, &alive, dispatch_get_main_queue(), w.block);
    AudioObjectPropertyAddress list = Addr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal);
    AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &list, dispatch_get_main_queue(), w.block);
}

@end
