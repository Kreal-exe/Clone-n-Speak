#import "OVExport.h"
#import <AVFoundation/AVFoundation.h>

// L() lives in OVLocale.m (AppKit). This weak fallback lets the file build standalone for tests (English text);
// in the app the strong definition from OVLocale.m wins at link time.
__attribute__((weak)) NSString *L(NSString *english) { return english; }
static NSString *T(NSString *s) { return L(s); }

NSErrorDomain const OVExportErrorDomain = @"OVExportErrorDomain";

static NSError *ExportError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:OVExportErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *const kNeedsFFmpeg = @"Needs ffmpeg. Install it with “brew install ffmpeg”.";

static NSString *gFFmpegPath;
static BOOL gFFmpegResolved;
static NSString *gEncoders;     // output of `ffmpeg -hide_banner -encoders`, nil = not read yet
static NSObject *gLock;

// Runs a program with stdout+stderr captured into a temp file. Returns exit status, -1 when it cannot start.
static int RunProgram(NSString *path, NSArray<NSString *> *args, NSString *_Nullable *_Nullable output) {
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"cns-export-%@.log", [NSUUID UUID].UUIDString]];
    [[NSFileManager defaultManager] createFileAtPath:tmp contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:tmp];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = args;
    task.standardOutput = fh;
    task.standardError = fh;
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    NSError *err = nil;
    int status = -1;
    if ([task launchAndReturnError:&err]) {
        [task waitUntilExit];
        status = task.terminationStatus;
    }
    [fh closeFile];
    if (output) {
        NSData *d = [NSData dataWithContentsOfFile:tmp];
        *output = d ? ([[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"") : @"";
    }
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
    return status;
}

static BOOL IsExecutable(NSString *p) {
    BOOL dir = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&dir] && !dir && [[NSFileManager defaultManager] isExecutableFileAtPath:p];
}

static NSString *Tail(NSString *s, NSUInteger n) {
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return s.length > n ? [@"…" stringByAppendingString:[s substringFromIndex:s.length - n]] : s;
}

// AVAudioFile leaves ~60 KB of reserved space in front of the audio in an M4A. A passthrough re-mux (no re-encode)
// drops it. Best effort: on any failure the original file stays.
static void CompactM4A(NSString *path) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *tmp = [path stringByAppendingString:@".tmp.m4a"];
    [fm removeItemAtPath:tmp error:nil];
    AVAssetExportSession *s = [[AVAssetExportSession alloc] initWithAsset:[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil]
                                                               presetName:AVAssetExportPresetPassthrough];
    if (!s) return;
    s.outputURL = [NSURL fileURLWithPath:tmp];
    s.outputFileType = AVFileTypeAppleM4A;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [s exportAsynchronouslyWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    NSDictionary *a = [fm attributesOfItemAtPath:tmp error:nil];
    if (s.status == AVAssetExportSessionStatusCompleted && [a fileSize] > 0) {
        [fm removeItemAtPath:path error:nil];
        [fm moveItemAtPath:tmp toPath:path error:nil];
    } else {
        [fm removeItemAtPath:tmp error:nil];
    }
}

@implementation OVExport

+ (void)initialize {
    if (self == [OVExport class]) gLock = [NSObject new];
}

#pragma mark - ffmpeg discovery

+ (NSString *)ffmpegPath {
    @synchronized (gLock) {
        if (gFFmpegResolved) return gFFmpegPath;
        NSMutableArray<NSString *> *dirs = [NSMutableArray array];
        const char *override = getenv("CNS_FFMPEG_DIRS");
        if (override) {
            for (NSString *d in [[NSString stringWithUTF8String:override] componentsSeparatedByString:@":"]) if (d.length) [dirs addObject:d];
        } else {
            const char *home = getenv("HOME");
            if (home) [dirs addObject:[[NSString stringWithUTF8String:home] stringByAppendingPathComponent:@".local/bin"]];
            [dirs addObjectsFromArray:@[@"/opt/homebrew/bin", @"/usr/local/bin"]];
        }
        NSString *found = nil;
        for (NSString *d in dirs) {
            NSString *p = [d stringByAppendingPathComponent:@"ffmpeg"];
            if (IsExecutable(p)) { found = p; break; }
        }
        if (!found && !override) {
            NSString *out = nil;
            if (RunProgram(@"/bin/sh", @[@"-lc", @"command -v ffmpeg"], &out) == 0) {
                NSString *line = [[out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsSeparatedByString:@"\n"].lastObject;
                if ([line hasPrefix:@"/"] && IsExecutable(line)) found = line;
            }
        }
        gFFmpegPath = found;
        gFFmpegResolved = YES;
        return found;
    }
}

+ (void)resetFFmpegCache {
    @synchronized (gLock) {
        gFFmpegPath = nil;
        gFFmpegResolved = NO;
        gEncoders = nil;
    }
}

+ (BOOL)ffmpegHasEncoder:(NSString *)name {
    NSString *path = [self ffmpegPath];
    if (!path) return NO;
    NSString *list;
    @synchronized (gLock) { list = gEncoders; }
    if (!list) {
        NSString *out = nil;
        list = RunProgram(path, @[@"-hide_banner", @"-encoders"], &out) == 0 ? out : @"";
        @synchronized (gLock) { if (gFFmpegPath) gEncoders = list; }
    }
    for (NSString *line in [list componentsSeparatedByString:@"\n"]) {
        for (NSString *w in [line componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]) {
            if ([w isEqualToString:name]) return YES;
        }
    }
    return NO;
}

#pragma mark - formats

+ (NSArray<NSDictionary *> *)formats {
    BOOL mp3 = [self ffmpegHasEncoder:@"libmp3lame"];
    BOOL ogg = [self ffmpegHasEncoder:@"libvorbis"];
    NSString *reason = T(kNeedsFFmpeg);
    NSDictionary *(^mk)(NSString *, NSString *, NSString *, BOOL, BOOL) = ^NSDictionary *(NSString *i, NSString *t, NSString *e, BOOL lossless, BOOL avail) {
        NSMutableDictionary *d = [@{@"id": i, @"title": t, @"ext": e, @"lossless": @(lossless), @"available": @(avail)} mutableCopy];
        if (!avail) d[@"reason"] = reason;
        return d;
    };
    return @[
        mk(@"wav", @"WAV", @"wav", YES, YES),
        mk(@"m4a", @"M4A (AAC)", @"m4a", NO, YES),
        mk(@"flac", @"FLAC", @"flac", YES, YES),
        mk(@"alac", @"ALAC (M4A)", @"m4a", YES, YES),
        mk(@"mp3", @"MP3", @"mp3", NO, mp3),
        mk(@"ogg", @"OGG Vorbis", @"ogg", NO, ogg),
    ];
}

+ (OVExportFormat)formatForIdentifier:(NSString *)identifier {
    NSString *s = identifier.lowercaseString;
    NSArray *ids = @[@"wav", @"m4a", @"flac", @"alac", @"mp3", @"ogg"];
    NSUInteger i = [ids indexOfObject:s];
    return i == NSNotFound ? OVExportWAV : (OVExportFormat)i;
}

static NSString *ExtensionFor(OVExportFormat f) {
    switch (f) {
        case OVExportWAV: return @"wav";
        case OVExportM4A: case OVExportALAC: return @"m4a";
        case OVExportFLAC: return @"flac";
        case OVExportMP3: return @"mp3";
        case OVExportOGG: return @"ogg";
    }
    return @"wav";
}

#pragma mark - export

+ (NSString *)uniquePathForBase:(NSString *)base ext:(NSString *)ext {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *p = [base stringByAppendingPathExtension:ext];
    for (int n = 2; [fm fileExistsAtPath:p]; n++) {
        p = [[NSString stringWithFormat:@"%@ %d", base, n] stringByAppendingPathExtension:ext];
    }
    return p;
}

// Native encode through AVAudioFile. `settings` describes the destination; when its sample rate differs from the
// source's, the audio is resampled on the way (AAC refuses high bitrates at low rates, e.g. 192 kbps mono at 24 kHz).
+ (BOOL)encodeNative:(AVAudioFile *)src to:(NSString *)dst settings:(NSDictionary *)settings error:(NSString **)why {
    NSError *err = nil;
    AVAudioFile *out = [[AVAudioFile alloc] initForWriting:[NSURL fileURLWithPath:dst] settings:settings
                                              commonFormat:AVAudioPCMFormatFloat32 interleaved:NO error:&err];
    if (!out) { *why = err.localizedDescription ?: @"cannot create the file"; return NO; }
    AVAudioFormat *inFmt = src.processingFormat;
    AVAudioFormat *outFmt = out.processingFormat;
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:inFmt frameCapacity:16384];
    src.framePosition = 0;
    if (inFmt.sampleRate == outFmt.sampleRate && inFmt.channelCount == outFmt.channelCount) {
        while (src.framePosition < src.length) {
            err = nil;
            if (![src readIntoBuffer:buf error:&err]) { *why = err.localizedDescription ?: @"read failed"; return NO; }
            if (buf.frameLength == 0) break;
            if (![out writeFromBuffer:buf error:&err]) { *why = err.localizedDescription ?: @"write failed"; return NO; }
        }
    } else {
        AVAudioConverter *conv = [[AVAudioConverter alloc] initFromFormat:inFmt toFormat:outFmt];
        if (!conv) { *why = @"cannot resample"; return NO; }
        AVAudioFrameCount cap = (AVAudioFrameCount)(16384 * outFmt.sampleRate / inFmt.sampleRate) + 1024;
        AVAudioPCMBuffer *ob = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outFmt frameCapacity:cap];
        __block NSString *readFail = nil;
        for (;;) {
            NSError *cerr = nil;
            AVAudioConverterOutputStatus st = [conv convertToBuffer:ob error:&cerr withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount n, AVAudioConverterInputStatus *status) {
                if (src.framePosition >= src.length) { *status = AVAudioConverterInputStatus_EndOfStream; return nil; }
                NSError *re = nil;
                if (![src readIntoBuffer:buf error:&re] || buf.frameLength == 0) {
                    if (re) readFail = re.localizedDescription;
                    *status = AVAudioConverterInputStatus_EndOfStream; return nil;
                }
                *status = AVAudioConverterInputStatus_HaveData;
                return buf;
            }];
            if (st == AVAudioConverterOutputStatus_Error) { *why = cerr.localizedDescription ?: readFail ?: @"resampling failed"; return NO; }
            if (ob.frameLength > 0 && ![out writeFromBuffer:ob error:&err]) { *why = err.localizedDescription ?: @"write failed"; return NO; }
            if (st == AVAudioConverterOutputStatus_EndOfStream || ob.frameLength == 0) break;
        }
    }
    out = nil;      // finalizes the container
    return YES;
}

+ (NSString *)exportFile:(NSString *)src to:(NSString *)dst format:(OVExportFormat)f quality:(NSInteger)quality error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (src.length == 0 || ![fm fileExistsAtPath:src isDirectory:&isDir] || isDir) {
        if (error) *error = ExportError(1, T(@"The source audio file was not found. Generate or choose the audio again."));
        return nil;
    }
    NSError *openErr = nil;
    AVAudioFile *in = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:src] error:&openErr];
    if (!in) {
        if (error) *error = ExportError(2, [NSString stringWithFormat:T(@"The source audio file cannot be read (%@). Choose a WAV file."), openErr.localizedDescription ?: @""]);
        return nil;
    }
    if (in.length <= 0) {
        if (error) *error = ExportError(3, T(@"The audio is empty, so there is nothing to export."));
        return nil;
    }
    if (f == OVExportMP3 || f == OVExportOGG) {
        BOOL ok = [self ffmpegHasEncoder:f == OVExportMP3 ? @"libmp3lame" : @"libvorbis"];
        if (!ok) {
            if (error) *error = ExportError(4, T(kNeedsFFmpeg));
            return nil;
        }
    }

    NSString *ext = ExtensionFor(f);
    NSString *base = dst;
    NSString *given = dst.pathExtension.lowercaseString;
    if ([@[@"wav", @"m4a", @"flac", @"mp3", @"ogg", @"aac", @"aiff"] containsObject:given]) base = dst.stringByDeletingPathExtension;
    NSString *dir = base.stringByDeletingLastPathComponent;
    NSError *dirErr = nil;
    if (dir.length && ![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&dirErr]) {
        if (error) *error = ExportError(5, [NSString stringWithFormat:T(@"Cannot create the folder (%@). Choose another place."), dirErr.localizedDescription ?: @""]);
        return nil;
    }
    NSString *part = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@".cns-export-%@.%@", [NSUUID UUID].UUIDString, ext]];

    NSString *why = nil;
    BOOL ok = NO;
    double rate = in.processingFormat.sampleRate;
    AVAudioChannelCount ch = in.processingFormat.channelCount;
    NSDictionary *fileSettings = in.fileFormat.settings;
    NSInteger srcBits = [fileSettings[AVLinearPCMBitDepthKey] integerValue];
    BOOL srcFloat = [fileSettings[AVLinearPCMIsFloatKey] boolValue];
    NSInteger bits = (srcBits >= 24 || srcFloat) ? 24 : 16;

    switch (f) {
        case OVExportWAV: {
            NSError *e = nil;
            ok = [fm copyItemAtPath:src toPath:part error:&e];
            if (!ok) why = e.localizedDescription;
            break;
        }
        case OVExportM4A: {
            NSInteger kbps = quality > 0 ? MIN(MAX(quality, 32), 320) : 192;
            NSDictionary *s = @{AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @(rate), AVNumberOfChannelsKey: @(ch),
                                AVEncoderBitRateKey: @(kbps * 1000),
                                AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant};
            ok = [self encodeNative:in to:part settings:s error:&why];
            if (!ok && rate < 48000) {
                [fm removeItemAtPath:part error:nil];
                NSMutableDictionary *s2 = [s mutableCopy];
                s2[AVSampleRateKey] = @48000;
                NSString *why2 = nil;
                if ([self encodeNative:in to:part settings:s2 error:&why2]) ok = YES; else why = why2 ?: why;
            }
            break;
        }
        case OVExportALAC: {
            NSDictionary *s = @{AVFormatIDKey: @(kAudioFormatAppleLossless), AVSampleRateKey: @(rate), AVNumberOfChannelsKey: @(ch),
                                AVEncoderBitDepthHintKey: @(bits)};
            ok = [self encodeNative:in to:part settings:s error:&why];
            break;
        }
        case OVExportFLAC: {
            NSDictionary *s = @{AVFormatIDKey: @(kAudioFormatFLAC), AVSampleRateKey: @(rate), AVNumberOfChannelsKey: @(ch),
                                AVLinearPCMBitDepthKey: @(bits)};
            ok = [self encodeNative:in to:part settings:s error:&why];
            if (!ok) {
                [fm removeItemAtPath:part error:nil];
                NSString *out = nil;
                ok = RunProgram(@"/usr/bin/afconvert", @[@"-f", @"flac", @"-d", @"flac", src, part], &out) == 0
                     && [fm fileExistsAtPath:part];
                if (!ok) why = Tail(out ?: why ?: @"", 400);
            }
            break;
        }
        case OVExportMP3:
        case OVExportOGG: {
            NSArray *codec;
            if (f == OVExportMP3) codec = @[@"-c:a", @"libmp3lame", @"-b:a", [NSString stringWithFormat:@"%ldk", (long)(quality > 0 ? MIN(quality, 320) : 192)]];
            else codec = @[@"-c:a", @"libvorbis", @"-q:a", [NSString stringWithFormat:@"%ld", (long)(quality >= 0 ? MIN(quality, 10) : 5)]];
            NSMutableArray *args = [@[@"-y", @"-i", src, @"-vn"] mutableCopy];
            [args addObjectsFromArray:codec];
            [args addObject:part];
            NSString *out = nil;
            int status = RunProgram([self ffmpegPath], args, &out);
            ok = status == 0 && [fm fileExistsAtPath:part];
            if (!ok) why = status == 0 ? @"ffmpeg produced no file" : Tail(out, 400);
            break;
        }
    }
    in = nil;
    if (ok && (f == OVExportM4A || f == OVExportALAC)) CompactM4A(part);

    if (!ok) {
        [fm removeItemAtPath:part error:nil];
        if (error) *error = ExportError(6, [NSString stringWithFormat:T(@"Export failed: %@"), why.length ? why : T(@"unknown error")]);
        return nil;
    }
    // Pick the final name last, so two exports in a row never overwrite each other.
    NSString *final = [self uniquePathForBase:base ext:ext];
    NSError *mvErr = nil;
    if (![fm moveItemAtPath:part toPath:final error:&mvErr]) {
        [fm removeItemAtPath:part error:nil];
        if (error) *error = ExportError(7, [NSString stringWithFormat:T(@"Cannot save the file (%@). Choose another place."), mvErr.localizedDescription ?: @""]);
        return nil;
    }
    return final;
}

@end
