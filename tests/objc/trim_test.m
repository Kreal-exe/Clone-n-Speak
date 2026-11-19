// deps: OVTrim.m
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "OVTrim.h"

static int gFails = 0;
#define CHECK(cond, ...) do { if (!(cond)) { gFails++; printf("FAIL %s:%d %s: ", __FILE__, __LINE__, #cond); printf(__VA_ARGS__); printf("\n"); } } while (0)

static NSString *gDir;
static NSString *Tmp(NSString *name) { return [gDir stringByAppendingPathComponent:name]; }

/// A 440 Hz tone at amplitude 0.5, `seconds` long, 16-bit PCM WAV.
static NSString *MakeTone(NSString *name, double rate, int channels, double seconds, int bits) {
    NSString *path = Tmp(name);
    NSDictionary *s = @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @(rate), AVNumberOfChannelsKey: @(channels),
                        AVLinearPCMBitDepthKey: @(bits), AVLinearPCMIsFloatKey: @NO, AVLinearPCMIsBigEndianKey: @NO};
    AVAudioFile *f = [[AVAudioFile alloc] initForWriting:[NSURL fileURLWithPath:path] settings:s commonFormat:AVAudioPCMFormatFloat32 interleaved:NO error:nil];
    AVAudioFrameCount n = (AVAudioFrameCount)llround(seconds * rate);
    AVAudioPCMBuffer *b = [[AVAudioPCMBuffer alloc] initWithPCMFormat:f.processingFormat frameCapacity:n];
    b.frameLength = n;
    for (int c = 0; c < channels; c++)
        for (AVAudioFrameCount i = 0; i < n; i++) b.floatChannelData[c][i] = 0.5f * sinf(2 * M_PI * 440 * i / rate);
    [f writeFromBuffer:b error:nil];
    return path;
}

static AVAudioPCMBuffer *ReadAll(NSString *path, AVAudioFile **fileOut) {
    AVAudioFile *f = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:path] error:nil];
    if (!f) return nil;
    AVAudioPCMBuffer *b = [[AVAudioPCMBuffer alloc] initWithPCMFormat:f.processingFormat frameCapacity:(AVAudioFrameCount)f.length];
    [f readIntoBuffer:b error:nil];
    if (fileOut) *fileOut = f;
    return b;
}

static void testTrimsTone(void) {
    NSString *src = MakeTone(@"tone.wav", 24000, 1, 3.0, 16), *dst = Tmp(@"cut.wav");
    NSError *err = nil;
    CHECK(OVTrimAudioFile(src, dst, 0.5, 2.0, OVTrimDefaultFade, &err), "trim failed: %s", err.description.UTF8String);
    AVAudioFile *f = nil;
    AVAudioPCMBuffer *b = ReadAll(dst, &f);
    CHECK(b != nil, "result is not readable");
    CHECK(llabs(f.length - 36000) <= 1, "1.5 s at 24 kHz is %lld frames", (long long)f.length);
    CHECK(f.fileFormat.sampleRate == 24000 && f.fileFormat.channelCount == 1, "format %.0f Hz %u ch", f.fileFormat.sampleRate, f.fileFormat.channelCount);
    CHECK(f.fileFormat.streamDescription->mBitsPerChannel == 16, "bits %u", f.fileFormat.streamDescription->mBitsPerChannel);
    // fades: the first and last samples are silent, the middle is the tone at full level
    CHECK(fabsf(b.floatChannelData[0][0]) < 0.002f, "first sample %f", b.floatChannelData[0][0]);
    CHECK(fabsf(b.floatChannelData[0][b.frameLength - 1]) < 0.01f, "last sample %f", b.floatChannelData[0][b.frameLength - 1]);
    float peak = 0, early = 0;
    for (AVAudioFrameCount i = 0; i < b.frameLength; i++) peak = MAX(peak, fabsf(b.floatChannelData[0][i]));
    for (AVAudioFrameCount i = 0; i < 60; i++) early = MAX(early, fabsf(b.floatChannelData[0][i]));
    CHECK(peak > 0.45f && peak < 0.55f, "peak %f", peak);
    CHECK(early < 0.25f, "the fade-in is not rising: %f in the first 60 frames", early);
    // the content comes from the right place: the source at 0.5 s is sin(2π·440·0.5) = 0 → the second sample follows the tone
    CHECK(![[NSFileManager defaultManager] fileExistsAtPath:[dst stringByAppendingString:@".part.wav"]], ".part file left behind");
    CHECK(![[NSFileManager defaultManager] fileExistsAtPath:[dst stringByAppendingString:@".part"]], ".part file left behind");
}

static void testKeepsRateChannelsAndReplaces(void) {
    NSString *src = MakeTone(@"st.wav", 44100, 2, 4.0, 16), *dst = Tmp(@"st-cut.wav");
    NSError *err = nil;
    CHECK(OVTrimAudioFile(src, dst, 1.0, 3.5, 0.010, &err), "stereo trim failed: %s", err.description.UTF8String);
    AVAudioFile *f = nil;
    ReadAll(dst, &f);
    CHECK(f.fileFormat.sampleRate == 44100 && f.fileFormat.channelCount == 2, "format %.0f Hz %u ch", f.fileFormat.sampleRate, f.fileFormat.channelCount);
    CHECK(llabs(f.length - 110250) <= 1, "2.5 s at 44.1 kHz is %lld frames", (long long)f.length);
    // an existing destination is replaced
    CHECK(OVTrimAudioFile(src, dst, 0, 2.0, 0.010, &err), "replace failed: %s", err.description.UTF8String);
    ReadAll(dst, &f);
    CHECK(llabs(f.length - 88200) <= 1, "replaced file has %lld frames", (long long)f.length);
    // 24-bit stays 24-bit
    NSString *s24 = MakeTone(@"t24.wav", 48000, 1, 3.0, 24), *d24 = Tmp(@"t24-cut.wav");
    CHECK(OVTrimAudioFile(s24, d24, 0.2, 2.2, 0.010, &err), "24-bit trim failed: %s", err.description.UTF8String);
    ReadAll(d24, &f);
    CHECK(f.fileFormat.streamDescription->mBitsPerChannel == 24, "bits %u", f.fileFormat.streamDescription->mBitsPerChannel);
    // the whole file is a valid range
    NSString *whole = Tmp(@"whole.wav");
    CHECK(OVTrimAudioFile(src, whole, 0, 4.0, 0.010, &err), "whole file refused: %s", err.description.UTF8String);
}

static void testRefusesBadRanges(void) {
    NSString *src = MakeTone(@"bad.wav", 24000, 1, 3.0, 16);
    NSFileManager *fm = NSFileManager.defaultManager;
    struct { double s, e; } cases[] = {{-0.1, 2}, {2, 1}, {1, 1}, {0, 3.5}, {2.5, 3.0}, {NAN, 2}, {0, NAN}, {0, INFINITY}, {0.5, 1.2}};
    for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
        NSString *dst = Tmp([NSString stringWithFormat:@"refused%zu.wav", i]);
        NSError *err = nil;
        BOOL ok = OVTrimAudioFile(src, dst, cases[i].s, cases[i].e, 0.010, &err);
        CHECK(!ok && err != nil, "range %g…%g was accepted", cases[i].s, cases[i].e);
        CHECK(err.code == OVTrimBadRange && [err.domain isEqualToString:OVTrimErrorDomain], "range %g…%g: error %s", cases[i].s, cases[i].e, err.description.UTF8String);
        CHECK(![fm fileExistsAtPath:dst] && ![fm fileExistsAtPath:[dst stringByAppendingString:@".part.wav"]], "range %g…%g left files", cases[i].s, cases[i].e);
    }
    // a failed trim leaves an existing destination as it was
    NSString *keep = Tmp(@"keep.wav");
    [fm copyItemAtPath:src toPath:keep error:nil];
    NSData *before = [NSData dataWithContentsOfFile:keep];
    CHECK(!OVTrimAudioFile(src, keep, 2, 1, 0.010, nil), "bad range with a nil error accepted");
    CHECK([[NSData dataWithContentsOfFile:keep] isEqualToData:before], "destination changed by a refused trim");
    // an unreadable source
    NSError *err = nil;
    CHECK(!OVTrimAudioFile(Tmp(@"missing.wav"), Tmp(@"x.wav"), 0, 2, 0.010, &err) && err, "missing source");
}

static void testSelectionMath(void) {
    const double d = 10, m = OVTrimMinKeep;
    CHECK(OVClampTrimStart(-3, 8, d, m) == 0, "start below 0");
    CHECK(OVClampTrimStart(2, 8, d, m) == 2, "start inside");
    CHECK(OVClampTrimStart(7.5, 8, d, m) == 7, "start stops 1 s before the end: %g", OVClampTrimStart(7.5, 8, d, m));
    CHECK(OVClampTrimStart(9, 8, d, m) == 7, "start dragged past the end");
    CHECK(OVClampTrimStart(NAN, 8, d, m) == 0, "NaN start");
    CHECK(OVClampTrimEnd(2, 12, d, m) == 10, "end above the duration");
    CHECK(OVClampTrimEnd(2, 5, d, m) == 5, "end inside");
    CHECK(OVClampTrimEnd(2, 2.4, d, m) == 3, "end stops 1 s after the start: %g", OVClampTrimEnd(2, 2.4, d, m));
    CHECK(OVClampTrimEnd(9.5, 9.6, d, m) == 10, "end near the end of the file");
    CHECK(OVClampTrimEnd(2, NAN, d, m) == 10, "NaN end");
    CHECK(OVClampTrimEnd(0, 5, 0, m) == 0 && OVClampTrimStart(1, 5, 0, m) == 0, "no duration yet");
    // for every pair: start < end and the kept part is >= minKeep when the file allows it
    for (double s = -2; s <= 12; s += 0.7)
        for (double e = -2; e <= 12; e += 0.9) {
            double ns = OVClampTrimStart(s, e, d, m), ne = OVClampTrimEnd(ns, e, d, m);
            CHECK(ns >= 0 && ne <= d && ne - ns >= m - 1e-9, "(%g, %g) → (%g, %g)", s, e, ns, ne);
        }
}

int main(void) {
    @autoreleasepool {
        gDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:gDir withIntermediateDirectories:YES attributes:nil error:nil];
        testTrimsTone();
        testKeepsRateChannelsAndReplaces();
        testRefusesBadRanges();
        testSelectionMath();
        [NSFileManager.defaultManager removeItemAtPath:gDir error:nil];
    }
    if (gFails) { printf("%d failure(s)\n", gFails); return 1; }
    printf("trim_test: ok\n");
    return 0;
}
