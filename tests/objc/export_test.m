// deps: OVExport.m
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "OVExport.h"

static int gFailures = 0;
#define ASSERT(cond, ...) do { if (!(cond)) { gFailures++; \
    fprintf(stderr, "FAIL %s:%d  %s  -- %s\n", __FILE__, __LINE__, #cond, [[NSString stringWithFormat:@"" __VA_ARGS__] UTF8String]); } } while (0)

static NSString *gTmp;
static const double kRate = 24000;

static NSString *TmpPath(NSString *name) { return [gTmp stringByAppendingPathComponent:name]; }

static NSString *WriteSine(NSString *name, NSInteger frames) {
    NSString *path = TmpPath(name);
    NSDictionary *s = @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @(kRate), AVNumberOfChannelsKey: @1,
                        AVLinearPCMBitDepthKey: @16, AVLinearPCMIsFloatKey: @NO, AVLinearPCMIsBigEndianKey: @NO};
    NSError *e = nil;
    AVAudioFile *f = [[AVAudioFile alloc] initForWriting:[NSURL fileURLWithPath:path] settings:s
                                            commonFormat:AVAudioPCMFormatFloat32 interleaved:NO error:&e];
    if (!f) { fprintf(stderr, "cannot write: %s\n", e.description.UTF8String); exit(2); }
    if (frames > 0) {
        AVAudioPCMBuffer *b = [[AVAudioPCMBuffer alloc] initWithPCMFormat:f.processingFormat frameCapacity:(AVAudioFrameCount)frames];
        b.frameLength = (AVAudioFrameCount)frames;
        float *p = b.floatChannelData[0];
        for (NSInteger i = 0; i < frames; i++) p[i] = 0.5f * sinf(2 * (float)M_PI * 1000.f * i / (float)kRate);
        [f writeFromBuffer:b error:&e];
    }
    f = nil;
    return path;
}

static NSArray<NSNumber *> *ReadSamples(NSString *path, double *durationOut) {
    NSError *e = nil;
    AVAudioFile *f = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:path] error:&e];
    if (!f) return @[];
    AVAudioPCMBuffer *b = [[AVAudioPCMBuffer alloc] initWithPCMFormat:f.processingFormat frameCapacity:(AVAudioFrameCount)f.length];
    [f readIntoBuffer:b error:&e];
    if (durationOut) *durationOut = (double)f.length / f.processingFormat.sampleRate;
    if (f.processingFormat.sampleRate != kRate) {
        // AAC may be written at a higher rate than the source (the encoder refuses 192 kbps mono at 24 kHz): bring it back.
        AVAudioFormat *target = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:kRate channels:1 interleaved:NO];
        AVAudioConverter *c = [[AVAudioConverter alloc] initFromFormat:f.processingFormat toFormat:target];
        AVAudioPCMBuffer *ob = [[AVAudioPCMBuffer alloc] initWithPCMFormat:target frameCapacity:(AVAudioFrameCount)(f.length * kRate / f.processingFormat.sampleRate) + 4096];
        __block BOOL fed = NO;
        [c convertToBuffer:ob error:&e withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount n, AVAudioConverterInputStatus *st) {
            if (fed) { *st = AVAudioConverterInputStatus_EndOfStream; return nil; }
            fed = YES; *st = AVAudioConverterInputStatus_HaveData; return b;
        }];
        b = ob;
    }
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:b.frameLength];
    for (AVAudioFrameCount i = 0; i < b.frameLength; i++) [a addObject:@(b.floatChannelData[0][i])];
    return a;
}

static NSString *Export(NSString *src, NSString *dstName, OVExportFormat fmt, NSInteger q) {
    NSError *e = nil;
    NSString *r = [OVExport exportFile:src to:TmpPath(dstName) format:fmt quality:q error:&e];
    ASSERT(r != nil, "export %s fmt %ld failed: %s", dstName.UTF8String, (long)fmt, e.localizedDescription.UTF8String);
    return r ?: @"/nonexistent";
}

static void testFLACAndALACAreLossless(NSString *src) {
    NSArray *ref = ReadSamples(src, NULL);
    for (NSNumber *fmt in @[@(OVExportFLAC), @(OVExportALAC)]) {
        NSString *out = Export(src, [NSString stringWithFormat:@"lossless%@", fmt], fmt.integerValue, 0);
        NSArray *got = ReadSamples(out, NULL);
        ASSERT(got.count == ref.count, "frames %lu vs %lu (%s)", (unsigned long)got.count, (unsigned long)ref.count, out.UTF8String);
        float worst = 0;
        for (NSUInteger i = 0; i < MIN(got.count, ref.count); i++) worst = MAX(worst, fabsf([got[i] floatValue] - [ref[i] floatValue]));
        ASSERT(worst <= 1.0f / 32768.0f + 1e-9f, "max delta %g for format %ld", worst, (long)fmt.integerValue);
    }
}

static void testAACDurationAndLevel(NSString *src) {
    NSArray *ref = ReadSamples(src, NULL);
    NSString *out = Export(src, @"aac", OVExportM4A, 192);
    double dur = 0;
    NSArray *got = ReadSamples(out, &dur);
    ASSERT(fabs(dur - 1.0) <= 0.05, "duration %g", dur);
    // align by cross-correlation over +-3000 samples
    NSInteger n = (NSInteger)MIN(ref.count, got.count);
    float *r = calloc(ref.count, sizeof(float)), *g = calloc(got.count, sizeof(float));
    for (NSUInteger i = 0; i < ref.count; i++) r[i] = [ref[i] floatValue];
    for (NSUInteger i = 0; i < got.count; i++) g[i] = [got[i] floatValue];
    NSInteger bestLag = 0; double best = -1e30;
    for (NSInteger lag = -3000; lag <= 3000; lag += 1) {
        double acc = 0;
        for (NSInteger i = 4000; i < n - 4000; i += 2) {
            NSInteger j = i + lag;
            if (j < 0 || j >= (NSInteger)got.count) continue;
            acc += (double)r[i] * g[j];
        }
        if (acc > best) { best = acc; bestLag = lag; }
    }
    double sig = 0, noise = 0;
    for (NSInteger i = 4000; i < n - 4000; i++) {
        NSInteger j = i + bestLag;
        if (j < 0 || j >= (NSInteger)got.count) continue;
        double d = g[j] - r[i];
        sig += (double)r[i] * r[i]; noise += d * d;
    }
    double snr = 10 * log10(sig / MAX(noise, 1e-20));
    ASSERT(snr >= 25, "SNR %g dB at lag %ld", snr, (long)bestLag);
    free(r); free(g);
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:out error:nil];
    double kbps = [attrs[NSFileSize] doubleValue] * 8 / dur / 1000;
    ASSERT(kbps >= 192 * 0.65 && kbps <= 192 * 1.35, "bitrate %g kbps", kbps);
}

static void testWAVCopyKeepsSamples(NSString *src) {
    NSString *out = Export(src, @"copy", OVExportWAV, 0);
    ASSERT([out.pathExtension isEqualToString:@"wav"]);
    ASSERT([[NSData dataWithContentsOfFile:out] isEqualToData:[NSData dataWithContentsOfFile:src]], "wav differs");
}

static void testNameCollision(NSString *src) {
    NSString *first = Export(src, @"clash", OVExportM4A, 128);
    NSData *before = [NSData dataWithContentsOfFile:first];
    NSString *second = Export(src, @"clash", OVExportM4A, 128);
    ASSERT([first.lastPathComponent isEqualToString:@"clash.m4a"], "%s", first.UTF8String);
    ASSERT([second.lastPathComponent isEqualToString:@"clash 2.m4a"], "%s", second.UTF8String);
    ASSERT([[NSData dataWithContentsOfFile:first] isEqualToData:before], "first file changed");
    NSArray *left = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:gTmp error:nil];
    for (NSString *n in left) ASSERT(![n hasPrefix:@".cns-export-"], "leftover %s", n.UTF8String);
}

static NSString *WriteTone(NSString *name, double rate, int channels, double seconds) {
    NSString *path = TmpPath(name);
    NSDictionary *s = @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @(rate), AVNumberOfChannelsKey: @(channels),
                        AVLinearPCMBitDepthKey: @16, AVLinearPCMIsFloatKey: @NO, AVLinearPCMIsBigEndianKey: @NO};
    AVAudioFile *f = [[AVAudioFile alloc] initForWriting:[NSURL fileURLWithPath:path] settings:s
                                            commonFormat:AVAudioPCMFormatFloat32 interleaved:NO error:nil];
    AVAudioFrameCount n = (AVAudioFrameCount)(rate * seconds);
    AVAudioPCMBuffer *b = [[AVAudioPCMBuffer alloc] initWithPCMFormat:f.processingFormat frameCapacity:n];
    b.frameLength = n;
    for (int c = 0; c < channels; c++)
        for (AVAudioFrameCount i = 0; i < n; i++) b.floatChannelData[c][i] = 0.4f * sinf(2 * (float)M_PI * (440.f + 100 * c) * i / (float)rate);
    [f writeFromBuffer:b error:nil];
    f = nil;
    return path;
}

static void testAACAnyRateAndChannels(void) {
    struct { double rate; int ch; } cases[] = {{96000, 1}, {96000, 2}, {8000, 1}, {44100, 2}, {32000, 1}, {16000, 2}};
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        NSString *src = WriteTone([NSString stringWithFormat:@"tone%zu.wav", i], cases[i].rate, cases[i].ch, 0.5);
        for (NSNumber *q in @[@96, @192, @320]) {
            NSError *e = nil;
            NSString *out = [OVExport exportFile:src to:TmpPath([NSString stringWithFormat:@"tone%zu-%@", i, q]) format:OVExportM4A quality:q.integerValue error:&e];
            ASSERT(out != nil, "rate %g ch %d kbps %@: %s", cases[i].rate, cases[i].ch, q, e.localizedDescription.UTF8String);
            if (!out) continue;
            AVAudioFile *f = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:out] error:nil];
            double dur = f ? (double)f.length / f.processingFormat.sampleRate : 0;
            ASSERT(fabs(dur - 0.5) <= 0.05, "duration %g (rate %g ch %d)", dur, cases[i].rate, cases[i].ch);
            ASSERT(f.processingFormat.channelCount == (AVAudioChannelCount)cases[i].ch, "channels");
        }
    }
}

static void testEmptyAndMissingSource(void) {
    NSString *empty = WriteSine(@"empty.wav", 0);
    NSString *dstDir = TmpPath(@"never");
    NSError *e = nil;
    NSString *r = [OVExport exportFile:empty to:[dstDir stringByAppendingPathComponent:@"x"] format:OVExportM4A quality:0 error:&e];
    ASSERT(r == nil && e.localizedDescription.length > 5, "empty source accepted");
    r = [OVExport exportFile:TmpPath(@"nope.wav") to:[dstDir stringByAppendingPathComponent:@"y"] format:OVExportFLAC quality:0 error:&e];
    ASSERT(r == nil && e.localizedDescription.length > 5, "missing source accepted");
    ASSERT(![[NSFileManager defaultManager] fileExistsAtPath:dstDir], "output folder created");
}

static void SetEnv(NSString *home, NSString *path, NSString *dirs) {
    setenv("HOME", home.UTF8String, 1);
    setenv("PATH", path.UTF8String, 1);
    if (dirs) setenv("CNS_FFMPEG_DIRS", dirs.UTF8String, 1); else unsetenv("CNS_FFMPEG_DIRS");
    [OVExport resetFFmpegCache];
}

static NSDictionary *Format(NSString *ident) {
    for (NSDictionary *d in [OVExport formats]) if ([d[@"id"] isEqualToString:ident]) return d;
    return nil;
}

static void testFormatsListAndReasons(void) {
    NSString *empty = TmpPath(@"emptyhome");
    [[NSFileManager defaultManager] createDirectoryAtPath:empty withIntermediateDirectories:YES attributes:nil error:nil];
    SetEnv(empty, @"/usr/bin:/bin", empty);
    ASSERT([OVExport ffmpegPath] == nil, "ffmpeg found: %s", [OVExport ffmpegPath].UTF8String);
    NSArray *fmts = [OVExport formats];
    ASSERT(fmts.count == 6);
    NSArray *ids = @[@"wav", @"m4a", @"flac", @"alac", @"mp3", @"ogg"];
    for (NSUInteger i = 0; i < ids.count; i++) ASSERT([fmts[i][@"id"] isEqualToString:ids[i]]);
    for (NSString *n in @[@"wav", @"m4a", @"flac", @"alac"]) ASSERT([Format(n)[@"available"] boolValue], "%s", n.UTF8String);
    for (NSString *n in @[@"mp3", @"ogg"]) {
        ASSERT(![Format(n)[@"available"] boolValue], "%s", n.UTF8String);
        ASSERT([Format(n)[@"reason"] length] > 0, "%s", n.UTF8String);
    }
    ASSERT([Format(@"flac")[@"lossless"] boolValue] && [Format(@"alac")[@"lossless"] boolValue] && ![Format(@"m4a")[@"lossless"] boolValue]);
    ASSERT([Format(@"alac")[@"ext"] isEqualToString:@"m4a"]);
    ASSERT([OVExport formatForIdentifier:@"flac"] == OVExportFLAC && [OVExport formatForIdentifier:@"ogg"] == OVExportOGG);
    ASSERT([OVExport formatForIdentifier:@"weird"] == OVExportWAV);
    // And exporting MP3 without ffmpeg is a clear error.
    NSString *src = WriteSine(@"noff.wav", (NSInteger)kRate / 4);
    NSError *e = nil;
    NSString *r = [OVExport exportFile:src to:TmpPath(@"noff") format:OVExportMP3 quality:0 error:&e];
    ASSERT(r == nil && [e.localizedDescription containsString:@"ffmpeg"], "%s", e.localizedDescription.UTF8String);
}

static NSString *MakeStub(NSString *dirName, NSString *encoders, NSString *body) {
    NSString *dir = TmpPath(dirName);
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *script = [NSString stringWithFormat:
        @"#!/bin/sh\n"
        @"if [ \"$1\" = \"-hide_banner\" ] && [ \"$2\" = \"-encoders\" ]; then\n%@\nexit 0\nfi\n%@\n", encoders, body];
    NSString *p = [dir stringByAppendingPathComponent:@"ffmpeg"];
    [script writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:p error:nil];
    return dir;
}

static void testFakeFFmpeg(NSString *src) {
    NSString *argsFile = TmpPath(@"argv.txt");
    NSString *ok = MakeStub(@"stub-ok",
        @"echo ' A....D libmp3lame           libmp3lame MP3 (MPEG audio layer 3)'; echo ' A....D aac    AAC'",
        [NSString stringWithFormat:@"echo \"$@\" > '%@'\nfor a; do last=\"$a\"; done\necho data > \"$last\"\nexit 0", argsFile]);
    SetEnv(TmpPath(@"emptyhome"), @"/usr/bin:/bin", ok);
    ASSERT([[OVExport ffmpegPath] isEqualToString:[ok stringByAppendingPathComponent:@"ffmpeg"]], "%s", [OVExport ffmpegPath].UTF8String);
    ASSERT([Format(@"mp3")[@"available"] boolValue]);
    ASSERT(![Format(@"ogg")[@"available"] boolValue]);
    ASSERT([Format(@"ogg")[@"reason"] length] > 0);
    NSError *e = nil;
    NSString *out = [OVExport exportFile:src to:TmpPath(@"fake") format:OVExportMP3 quality:0 error:&e];
    ASSERT(out != nil && [out.pathExtension isEqualToString:@"mp3"], "%s", e.localizedDescription.UTF8String);
    NSString *argv = [NSString stringWithContentsOfFile:argsFile encoding:NSUTF8StringEncoding error:nil];
    ASSERT([argv containsString:@"-c:a libmp3lame -b:a 192k"], "argv: %s", argv.UTF8String);
    ASSERT([argv containsString:@"-i "], "argv: %s", argv.UTF8String);
    // OGG is not offered by this stub, so it must refuse without running anything.
    out = [OVExport exportFile:src to:TmpPath(@"fake2") format:OVExportOGG quality:5 error:&e];
    ASSERT(out == nil && e != nil);

    NSString *bad = MakeStub(@"stub-bad",
        @"echo ' A....D libmp3lame  MP3'",
        @"for a; do last=\"$a\"; done\necho partial > \"$last\"\necho 'boom: encoder exploded' >&2\nexit 1");
    SetEnv(TmpPath(@"emptyhome"), @"/usr/bin:/bin", bad);
    e = nil;
    out = [OVExport exportFile:src to:TmpPath(@"failing") format:OVExportMP3 quality:128 error:&e];
    ASSERT(out == nil && [e.localizedDescription containsString:@"boom: encoder exploded"], "%s", e.localizedDescription.UTF8String);
    for (NSString *n in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:gTmp error:nil]) {
        ASSERT(![n hasPrefix:@"failing"] && ![n hasPrefix:@".cns-export-"], "leftover %s", n.UTF8String);
    }
}

// The non-override search: $HOME/.local/bin/ffmpeg is found first, and OGG with quality -1 asks for -q:a 5.
static void testDefaultSearch(NSString *src) {
    NSString *home = TmpPath(@"fakehome");
    NSString *argsFile = TmpPath(@"argv-ogg.txt");
    NSString *dir = MakeStub(@"fakehome/.local/bin", @"echo ' A....D libvorbis  Vorbis'",
        [NSString stringWithFormat:@"echo \"$@\" > '%@'\nfor a; do last=\"$a\"; done\necho data > \"$last\"\nexit 0", argsFile]);
    SetEnv(home, @"/usr/bin:/bin", nil);
    ASSERT([[OVExport ffmpegPath] isEqualToString:[dir stringByAppendingPathComponent:@"ffmpeg"]], "%s", [OVExport ffmpegPath].UTF8String);
    ASSERT([Format(@"ogg")[@"available"] boolValue] && ![Format(@"mp3")[@"available"] boolValue]);
    NSError *e = nil;
    NSString *out = [OVExport exportFile:src to:TmpPath(@"oggdefault") format:OVExportOGG quality:-1 error:&e];
    ASSERT(out != nil, "%s", e.localizedDescription.UTF8String);
    NSString *argv = [NSString stringWithContentsOfFile:argsFile encoding:NSUTF8StringEncoding error:nil];
    ASSERT([argv containsString:@"-c:a libvorbis -q:a 5"], "argv: %s", argv.UTF8String);
    ASSERT([argv containsString:@"-nostdin"] && [argv containsString:@"-loglevel error"], "argv: %s", argv.UTF8String);
}

int main(void) {
    @autoreleasepool {
        gTmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"cns-export-test-" stringByAppendingString:[NSUUID UUID].UUIDString]];
        [[NSFileManager defaultManager] createDirectoryAtPath:gTmp withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *src = WriteSine(@"sine.wav", (NSInteger)kRate);
        testFLACAndALACAreLossless(src);
        testAACDurationAndLevel(src);
        testWAVCopyKeepsSamples(src);
        testNameCollision(src);
        testEmptyAndMissingSource();
        testAACAnyRateAndChannels();
        {
            const char *h = getenv("HOME"), *p = getenv("PATH"), *d = getenv("CNS_FFMPEG_DIRS");
            NSString *h0 = h ? @(h) : @"", *p0 = p ? @(p) : @"/usr/bin:/bin", *d0 = d ? @(d) : nil;
            testFormatsListAndReasons();
            testFakeFFmpeg(src);
            testDefaultSearch(src);
            SetEnv(h0, p0, d0);     // restore the environment
        }
        [[NSFileManager defaultManager] removeItemAtPath:gTmp error:nil];
        if (gFailures) { fprintf(stderr, "%d failure(s)\n", gFailures); return 1; }
        printf("export_test: all passed\n");
    }
    return 0;
}
