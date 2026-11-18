// CoreAudio devices for the Realtime page: inputs and outputs with id, name, transport and the hardware latency
// (device latency + safety offset + buffer size + stream latency), plus change notifications.
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main queue when devices appear or disappear or a default device changes.
extern NSNotificationName const OVAudioDevicesDidChangeNotification;

typedef NS_ENUM(NSInteger, OVAudioTransport) {
    OVAudioTransportOther, OVAudioTransportBuiltIn, OVAudioTransportUSB, OVAudioTransportBluetooth, OVAudioTransportVirtual,
    OVAudioTransportHDMI, OVAudioTransportAggregate
};

@interface OVAudioDevice : NSObject
@property (readonly) AudioDeviceID deviceID;
@property (readonly, copy) NSString *uid, *name;
@property (readonly) OVAudioTransport transport;
@property (readonly) uint32_t transportCode;                 // the raw kAudioDeviceTransportType…
@property (readonly) BOOL hasInput, hasOutput;
/// The built-in speakers (output, built-in transport, data source "ispk"): playing a live voice there feeds back into a microphone.
@property (readonly) BOOL isBuiltInSpeaker;
@property (readonly) double sampleRate;
/// Frames of latency of the scope: device latency + safety offset + buffer frame size + stream latency (CoreAudio's own
/// numbers; Bluetooth devices report less than they have).
- (uint32_t)latencyFramesForInput:(BOOL)input;
/// The same in milliseconds at the device's sample rate.
- (double)latencyMsForInput:(BOOL)input;
/// Sets kAudioDevicePropertyBufferFrameSize (the plan's 128-frame fallback); returns the size in effect.
- (uint32_t)setBufferFrames:(uint32_t)frames;
@end

@interface OVAudioDevices : NSObject
+ (NSArray<OVAudioDevice *> *)inputDevices;
+ (NSArray<OVAudioDevice *> *)outputDevices;
+ (nullable OVAudioDevice *)defaultInput;
+ (nullable OVAudioDevice *)defaultOutput;
+ (nullable OVAudioDevice *)deviceWithUID:(NSString *)uid;
+ (nullable OVAudioDevice *)deviceWithID:(AudioDeviceID)deviceID;
/// Pure helpers (tests, UI text).
+ (OVAudioTransport)transportForCode:(uint32_t)code;
+ (NSString *)transportName:(OVAudioTransport)t;
/// YES for a name that looks like BlackHole ("BlackHole 2ch", "BlackHole 16ch").
+ (BOOL)isBlackHoleName:(NSString *)name;
/// Starts listening (idempotent); the notification above follows.
+ (void)startObserving;
@end

@interface OVAudioDevices (Watch)
/// Calls `onGone` once on the main queue when the device stops being alive or leaves the system. Returns a token;
/// pass it to stopWatching:.
+ (id)watchDevice:(AudioDeviceID)deviceID onGone:(void (^)(void))onGone;
+ (void)stopWatching:(nullable id)token;
@end

NS_ASSUME_NONNULL_END
