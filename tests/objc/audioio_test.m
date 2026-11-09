// deps: OVAudioIO.m
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "OVAudioIO.h"

static int gFails = 0;
#define ASSERT(cond, ...) do { if (!(cond)) { gFails++; printf("FAIL %s:%d %s: ", __FILE__, __LINE__, #cond); printf(__VA_ARGS__); printf("\n"); } } while (0)

static NSString *gDir;
static NSString *Tmp(NSString *name) { return [gDir stringByAppendingPathComponent:name]; }
static NSString *Fixture(NSString *name) {
    NSString *p = [@"tests/fixtures" stringByAppendingPathComponent:name];
    return [[NSFileManager defaultManager] currentDirectoryPath] ? [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:p] : p;
}

// Parsed float32 WAV.
typedef struct { int ch; int rate; NSUInteger frames; NSData *data; } Wav;
static BOOL ReadWav(NSString *path, Wav *w) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (d.length < 44 || memcmp(d.bytes, "RIFF", 4) || memcmp((const char *)d.bytes + 8, "WAVE", 4)) return NO;
    const uint8_t *b = d.bytes;
    NSUInteger pos = 12; int fmt = 0;
    while (pos + 8 <= d.length) {
        uint32_t sz; memcpy(&sz, b + pos + 4, 4);
        if (!memcmp(b + pos, "fmt ", 4)) {
            uint16_t f, c, bits; uint32_t r;
            memcpy(&f, b + pos + 8, 2); memcpy(&c, b + pos + 10, 2); memcpy(&r, b + pos + 12, 4); memcpy(&bits, b + pos + 22, 2);
            if (f != 3 || bits != 32) return NO;
            w->ch = c; w->rate = (int)r; fmt = 1;
        } else if (!memcmp(b + pos, "data", 4)) {
            if (!fmt) return NO;
            w->data = [d subdataWithRange:NSMakeRange(pos + 8, sz)];
            w->frames = sz / (4 * (NSUInteger)w->ch);
            return YES;
        }
        pos += 8 + sz + (sz & 1);
    }
    return NO;
}
static const float *Samples(Wav w) { return w.data.bytes; }

static double Goertzel(const float *x, NSUInteger n, int stride, int offset, double freq, double rate) {
    double w = 2 * M_PI * freq / rate, c = 2 * cos(w), s1 = 0, s2 = 0;
    for (NSUInteger i = 0; i < n; i++) { double s = x[i * stride + offset] + c * s1 - s2; s2 = s1; s1 = s; }
    return s1 * s1 + s2 * s2 - c * s1 * s2;
}
static double Peak(const float *x, NSUInteger n) { double p = 0; for (NSUInteger i = 0; i < n; i++) p = MAX(p, fabs(x[i])); return p; }

// Writes a PCM file with the given channel generator through AVAudioFile (container by extension).
static BOOL WriteTone(NSString *path, double rate, int ch, double secs, NSDictionary *fileSettings, double (^gen)(int c, NSUInteger i)) {
    AVAudioFormat *fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:(AVAudioChannelCount)ch];
    AVAudioFrameCount n = (AVAudioFrameCount)llround(secs * rate);
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:n];
    buf.frameLength = n;
    for (int c = 0; c < ch; c++) for (NSUInteger i = 0; i < n; i++) buf.floatChannelData[c][i] = (float)gen(c, i);
    NSError *e = nil;
    AVAudioFile *f = [[AVAudioFile alloc] initForWriting:[NSURL fileURLWithPath:path] settings:fileSettings commonFormat:AVAudioPCMFormatFloat32 interleaved:NO error:&e];
    if (!f) { printf("writer: %s\n", e.description.UTF8String); return NO; }
    BOOL ok = [f writeFromBuffer:buf error:&e];
    f = nil;
    return ok;
}
static NSDictionary *WavSettings(double rate, int ch) {
    return @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @(rate), AVNumberOfChannelsKey: @(ch),
             AVLinearPCMBitDepthKey: @32, AVLinearPCMIsFloatKey: @YES, AVLinearPCMIsBigEndianKey: @NO, AVLinearPCMIsNonInterleaved: @NO};
}

static OVDecodeOptions Opts(double rate, BOOL mono, double max) { OVDecodeOptions o = {rate, mono, max}; return o; }
static BOOL Exists(NSString *p) { return [[NSFileManager defaultManager] fileExistsAtPath:p]; }

static void testDecodeMP3(void) {
    NSString *dst = Tmp(@"mp3.wav"); NSError *e = nil; double secs = 0;
    BOOL ok = OVDecodeAudio(Fixture(@"tone-1s-44k-mono.mp3"), dst, Opts(0, NO, 0), &secs, &e);
    ASSERT(ok, "%s", e.description.UTF8String);
    Wav w; ASSERT(ReadWav(dst, &w), "wav");
    ASSERT(fabs(secs - 1.0) < 0.06, "seconds %f", secs);
    ASSERT(fabs((double)w.frames / w.rate - 1.0) < 0.06, "frames %lu", (unsigned long)w.frames);
    ASSERT(w.rate == 44100 && w.ch == 1, "rate %d ch %d", w.rate, w.ch);
    NSUInteger n = MIN(w.frames, (NSUInteger)w.rate);
    double a = Goertzel(Samples(w), n, 1, 0, 1000, w.rate), b = Goertzel(Samples(w), n, 1, 0, 1500, w.rate);
    ASSERT(a >= 10 * b, "1000 Hz %g vs 1500 Hz %g", a, b);
}

static void testDecodeM4AMadeInTest(void) {
    NSString *m4a = Tmp(@"made.m4a");
    NSDictionary *aac = @{AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @44100, AVNumberOfChannelsKey: @1, AVEncoderBitRateKey: @64000};
    ASSERT(WriteTone(m4a, 44100, 1, 1.0, aac, ^double(int c, NSUInteger i) { return 0.5 * sin(2 * M_PI * 1000 * i / 44100.0); }), "write m4a");
    NSString *dst = Tmp(@"m4a.wav"); NSError *e = nil; double secs = 0;
    BOOL ok = OVDecodeAudio(m4a, dst, Opts(0, NO, 0), &secs, &e);
    ASSERT(ok, "%s", e.description.UTF8String);
    Wav w; ASSERT(ReadWav(dst, &w), "wav");
    ASSERT(fabs(secs - 1.0) < 0.06, "seconds %f", secs);
    double a = Goertzel(Samples(w), MIN(w.frames, (NSUInteger)w.rate), 1, 0, 1000, w.rate), b = Goertzel(Samples(w), MIN(w.frames, (NSUInteger)w.rate), 1, 0, 1500, w.rate);
    ASSERT(a >= 10 * b, "tone %g vs %g", a, b);
}

static void testWAVRates(void) {
    double rates[] = {8000, 22050, 96000};
    for (int k = 0; k < 3; k++) {
        double sr = rates[k];
        NSString *src = Tmp([NSString stringWithFormat:@"in%d.wav", (int)sr]);
        NSUInteger n = (NSUInteger)llround(0.7 * sr);
        ASSERT(WriteTone(src, sr, 1, 0.7, WavSettings(sr, 1), ^double(int c, NSUInteger i) { return 0.4 * sin(2 * M_PI * 440 * i / sr); }), "write");
        NSString *dst = Tmp(@"out.wav"); NSError *e = nil; Wav w;
        ASSERT(OVDecodeAudio(src, dst, Opts(24000, NO, 0), NULL, &e), "%s", e.description.UTF8String);
        ASSERT(ReadWav(dst, &w) && w.rate == 24000, "rate");
        long expect = lround((double)n * 24000.0 / sr);
        ASSERT(labs((long)w.frames - expect) <= 1, "sr %.0f: %lu frames, expected %ld", sr, (unsigned long)w.frames, expect);
        ASSERT(OVDecodeAudio(src, dst, Opts(0, NO, 0), NULL, &e), "%s", e.description.UTF8String);
        ASSERT(ReadWav(dst, &w) && w.rate == (int)sr && labs((long)w.frames - (long)n) <= 1, "native rate kept, got %d", w.rate);
    }
}

static void testStereoToMono(void) {
    NSString *src = Tmp(@"st.wav");
    ASSERT(WriteTone(src, 44100, 2, 0.5, WavSettings(44100, 2), ^double(int c, NSUInteger i) {
        double v = 0.5 * sin(2 * M_PI * 1000 * i / 44100.0); return c == 0 ? v : -v; }), "write");
    NSString *dst = Tmp(@"mono.wav"); NSError *e = nil; Wav w;
    ASSERT(OVDecodeAudio(src, dst, Opts(0, YES, 0), NULL, &e), "%s", e.description.UTF8String);
    ASSERT(ReadWav(dst, &w) && w.ch == 1, "mono channels");
    ASSERT(Peak(Samples(w), w.frames) < 0.01, "downmix of L=-R must cancel, peak %f", Peak(Samples(w), w.frames));
    ASSERT(OVDecodeAudio(src, dst, Opts(0, NO, 0), NULL, &e), "%s", e.description.UTF8String);
    ASSERT(ReadWav(dst, &w) && w.ch == 2, "stereo channels");
    ASSERT(Peak(Samples(w), w.frames * 2) > 0.4, "stereo keeps the tone");
}

static void testVideoExtractsAudio(void) {
    NSString *dst = Tmp(@"vid.wav"); NSError *e = nil; double secs = 0; Wav w;
    ASSERT(OVDecodeAudio(Fixture(@"tone-video-1s.mp4"), dst, Opts(0, NO, 0), &secs, &e), "%s", e.description.UTF8String);
    ASSERT(ReadWav(dst, &w), "wav");
    ASSERT(fabs(secs - 1.0) < 0.06, "seconds %f", secs);
    NSUInteger n = MIN(w.frames, (NSUInteger)w.rate);
    double a = Goertzel(Samples(w), n, w.ch, 0, 1000, w.rate), b = Goertzel(Samples(w), n, w.ch, 0, 1500, w.rate);
    ASSERT(a >= 10 * b, "tone %g vs %g", a, b);
}

static NSString *MakeSilentVideo(NSString *path) {
    NSError *e = nil;
    AVAssetWriter *wr = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:path] fileType:AVFileTypeMPEG4 error:&e];
    NSDictionary *vs = @{AVVideoCodecKey: AVVideoCodecTypeH264, AVVideoWidthKey: @64, AVVideoHeightKey: @64};
    AVAssetWriterInput *in = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:vs];
    AVAssetWriterInputPixelBufferAdaptor *ad = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:in sourcePixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA), (id)kCVPixelBufferWidthKey: @64, (id)kCVPixelBufferHeightKey: @64}];
    [wr addInput:in];
    if (![wr startWriting]) return nil;
    [wr startSessionAtSourceTime:kCMTimeZero];
    for (int i = 0; i < 10; i++) {
        CVPixelBufferRef pb = NULL;
        CVPixelBufferCreate(NULL, 64, 64, kCVPixelFormatType_32BGRA, NULL, &pb);
        CVPixelBufferLockBaseAddress(pb, 0);
        memset(CVPixelBufferGetBaseAddress(pb), 0, CVPixelBufferGetBytesPerRow(pb) * 64);
        CVPixelBufferUnlockBaseAddress(pb, 0);
        while (!in.readyForMoreMediaData) [NSThread sleepForTimeInterval:0.01];
        [ad appendPixelBuffer:pb withPresentationTime:CMTimeMake(i, 10)];
        CVPixelBufferRelease(pb);
    }
    [in markAsFinished];
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    [wr finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(s); }];
    dispatch_semaphore_wait(s, DISPATCH_TIME_FOREVER);
    return wr.status == AVAssetWriterStatusCompleted ? path : nil;
}

static void testVideoWithoutAudioTrack(void) {
    NSString *v = MakeSilentVideo(Tmp(@"silent.mp4"));
    ASSERT(v != nil, "could not build silent video");
    if (!v) return;
    NSString *dst = Tmp(@"silent.wav"); NSError *e = nil;
    ASSERT(!OVDecodeAudio(v, dst, Opts(0, NO, 0), NULL, &e), "must fail");
    ASSERT(e.code == OVAudioIONoAudio && [e.domain isEqualToString:OVAudioIOErrorDomain], "code %ld", (long)e.code);
    ASSERT([e.localizedDescription isEqualToString:@"This video has no audio track."], "%s", e.localizedDescription.UTF8String);
    ASSERT(!Exists(dst) && !Exists([dst stringByAppendingString:@".part"]), "no leftovers");
    ASSERT(OVMediaKindOfFile(v) == OVMediaVideo, "kind");
}

static void testNotMedia(void) {
    NSString *txt = Tmp(@"note.txt");
    [@"hello, this is not audio" writeToFile:txt atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *dst = Tmp(@"txt.wav"); NSError *e = nil;
    ASSERT(!OVDecodeAudio(txt, dst, Opts(0, NO, 0), NULL, &e), "must fail");
    ASSERT(e.code == OVAudioIOUnsupported, "code %ld", (long)e.code);
    ASSERT(!Exists(dst) && !Exists([dst stringByAppendingString:@".part"]), "no leftovers");
    ASSERT(!OVDecodeAudio(Tmp(@"missing.mp3"), dst, Opts(0, NO, 0), NULL, &e) && e.code == OVAudioIOUnsupported, "missing file");
}

static void testTooLong(void) {
    NSString *dst = Tmp(@"long.wav"); NSError *e = nil;
    ASSERT(!OVDecodeAudio(Fixture(@"tone-1s-44k-mono.mp3"), dst, Opts(0, NO, 0.5), NULL, &e), "must fail");
    ASSERT(e.code == OVAudioIOTooLong, "code %ld", (long)e.code);
    ASSERT([e.localizedDescription hasPrefix:@"Cut it first"], "%s", e.localizedDescription.UTF8String);
    ASSERT(!Exists(dst) && !Exists([dst stringByAppendingString:@".part"]), "no leftovers");
}

static void testMediaKind(void) {
    ASSERT(OVMediaKindOfFile(Fixture(@"tone-1s-44k-mono.mp3")) == OVMediaAudio, "mp3");
    ASSERT(OVMediaKindOfFile(Fixture(@"tone-video-1s.mp4")) == OVMediaVideo, "mp4");
    NSString *txt = Tmp(@"k.txt"); [@"x" writeToFile:txt atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ASSERT(OVMediaKindOfFile(txt) == OVMediaUnknown, "text");
    ASSERT([OVVideoExtensions() containsObject:@"mp4"] && [OVVideoExtensions() containsObject:@"mov"] && [OVVideoExtensions() containsObject:@"m4v"], "extensions");
}

int main(void) {
    @autoreleasepool {
        gDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"audioio-%d", getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:gDir withIntermediateDirectories:YES attributes:nil error:nil];
        setvbuf(stdout, NULL, _IONBF, 0);
        void (*tests[])(void) = {testDecodeMP3, testDecodeM4AMadeInTest, testWAVRates, testStereoToMono, testVideoExtractsAudio,
                                 testVideoWithoutAudioTrack, testNotMedia, testTooLong, testMediaKind};
        for (size_t i = 0; i < sizeof tests / sizeof *tests; i++) { printf("test %zu\n", i); tests[i](); }
        [[NSFileManager defaultManager] removeItemAtPath:gDir error:nil];
        if (gFails) { printf("%d failure(s)\n", gFails); return 1; }
        printf("audioio: all passed\n");
    }
    return 0;
}
