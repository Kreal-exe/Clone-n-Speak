#import "OVTrim.h"
#import <AVFoundation/AVFoundation.h>

NSErrorDomain const OVTrimErrorDomain = @"OVTrim";
const NSTimeInterval OVTrimMinKeep = 1.0;
const NSTimeInterval OVTrimDefaultFade = 0.010;

NSTimeInterval OVClampTrimStart(NSTimeInterval start, NSTimeInterval end, NSTimeInterval duration, NSTimeInterval minKeep) {
    if (!isfinite(start) || !isfinite(duration) || duration <= 0) return 0;
    NSTimeInterval hi = MAX(0, MIN(isfinite(end) ? end : duration, duration) - minKeep);
    return MAX(0, MIN(start, hi));
}

NSTimeInterval OVClampTrimEnd(NSTimeInterval start, NSTimeInterval end, NSTimeInterval duration, NSTimeInterval minKeep) {
    if (!isfinite(duration) || duration <= 0) return 0;
    if (!isfinite(end)) return duration;
    NSTimeInterval lo = MIN(duration, MAX(0, isfinite(start) ? start : 0) + minKeep);
    return MIN(duration, MAX(end, lo));
}

static BOOL Fail(NSError **error, NSInteger code, NSString *msg) {
    if (error) *error = [NSError errorWithDomain:OVTrimErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: msg}];
    return NO;
}

BOOL OVTrimAudioFile(NSString *src, NSString *dst, NSTimeInterval start, NSTimeInterval end, NSTimeInterval fade, NSError **error) {
    NSError *e = nil;
    AVAudioFile *in = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:src] error:&e];
    if (!in) { if (error) *error = e; return NO; }
    AVAudioFormat *fmt = in.processingFormat;
    double rate = fmt.sampleRate;
    if (rate <= 0 || in.length <= 0) return Fail(error, OVTrimCannotRead, @"The file has no audio");
    if (!isfinite(start) || !isfinite(end) || start < 0 || end <= start) return Fail(error, OVTrimBadRange, @"The selection is not valid");
    AVAudioFramePosition first = llround(start * rate), last = llround(end * rate);
    if (last > in.length && last - in.length <= 1) last = in.length;   // one frame of rounding
    if (last > in.length || last - first < llround(OVTrimMinKeep * rate)) return Fail(error, OVTrimBadRange, @"The selection is outside the file or too short");

    // 24-bit stays 24-bit; everything else becomes 16-bit (what the app stores)
    UInt32 bits = in.fileFormat.streamDescription->mBitsPerChannel;
    NSDictionary *settings = @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @(rate), AVNumberOfChannelsKey: @(fmt.channelCount),
                               AVLinearPCMBitDepthKey: @(bits == 24 ? 24 : 16), AVLinearPCMIsFloatKey: @NO, AVLinearPCMIsBigEndianKey: @NO};
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *part = [dst stringByAppendingString:@".part.wav"];
    [fm removeItemAtPath:part error:nil];
    AVAudioFile *out = [[AVAudioFile alloc] initForWriting:[NSURL fileURLWithPath:part] settings:settings
                                              commonFormat:AVAudioPCMFormatFloat32 interleaved:NO error:&e];
    if (!out) { if (error) *error = e; return NO; }

    AVAudioFramePosition total = last - first;
    AVAudioFramePosition fadeFrames = MIN(MAX(0, llround(MAX(0, fade) * rate)), total / 2);
    in.framePosition = first;
    const AVAudioFrameCount chunk = 16384;
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:chunk];
    AVAudioFramePosition done = 0;
    BOOL ok = YES;
    while (done < total) {
        AVAudioFrameCount want = (AVAudioFrameCount)MIN((AVAudioFramePosition)chunk, total - done);
        buf.frameLength = 0;
        if (![in readIntoBuffer:buf frameCount:want error:&e] || buf.frameLength == 0) { ok = NO; break; }
        for (AVAudioFrameCount i = 0; i < buf.frameLength; i++) {
            AVAudioFramePosition pos = done + i;
            float g = 1;
            if (fadeFrames > 0) {
                if (pos < fadeFrames) g = (float)pos / (float)fadeFrames;
                AVAudioFramePosition fromEnd = total - 1 - pos;
                if (fromEnd < fadeFrames) g = MIN(g, (float)fromEnd / (float)fadeFrames);
            }
            if (g < 1) for (AVAudioChannelCount c = 0; c < fmt.channelCount; c++) buf.floatChannelData[c][i] *= g;
        }
        if (![out writeFromBuffer:buf error:&e]) { ok = NO; break; }
        done += buf.frameLength;
    }
    out = nil;   // closes the file: the header gets its final length
    if (!ok) {
        [fm removeItemAtPath:part error:nil];
        if (error) *error = e ?: [NSError errorWithDomain:OVTrimErrorDomain code:OVTrimWriteFailed userInfo:@{NSLocalizedDescriptionKey: @"Couldn’t write the trimmed audio"}];
        return NO;
    }
    NSURL *dstURL = [NSURL fileURLWithPath:dst];
    BOOL moved = [fm fileExistsAtPath:dst]
        ? [fm replaceItemAtURL:dstURL withItemAtURL:[NSURL fileURLWithPath:part] backupItemName:nil options:0 resultingItemURL:nil error:&e]
        : [fm moveItemAtURL:[NSURL fileURLWithPath:part] toURL:dstURL error:&e];
    if (!moved) {
        [fm removeItemAtPath:part error:nil];
        if (error) *error = e;
        return NO;
    }
    return YES;
}
