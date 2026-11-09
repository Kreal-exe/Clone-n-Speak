#import "OVAudioIO.h"
#import <AVFoundation/AVFoundation.h>

NSErrorDomain const OVAudioIOErrorDomain = @"OVAudioIO";

// L() lives in OVLocale.m (AppKit). This weak fallback lets the Foundation-only test build link;
// in the app the strong definition wins.
__attribute__((weak)) NSString *L(NSString *english) { return english; }

static NSError *IOError(NSInteger code, NSString *msg) {
    return [NSError errorWithDomain:OVAudioIOErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static NSString *MsgUnsupported(void) { return L(@"This file can't be read as audio or video."); }
static NSString *MsgNoAudio(void) { return L(@"This video has no audio track."); }
static NSString *MsgTooLong(void) { return L(@"Cut it first: this file is longer than the allowed length."); }
static NSString *MsgEmpty(void) { return L(@"No sound was found in this file."); }

static NSArray<AVAssetTrack *> *TracksOf(AVAsset *asset, AVMediaType type) {
    __block NSArray *out = @[];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [asset loadTracksWithMediaType:type completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *e) {
        if (tracks) out = tracks;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return out;
}

static void PutLE32(NSMutableData *d, uint32_t v) { v = CFSwapInt32HostToLittle(v); [d appendBytes:&v length:4]; }
static void PutLE16(NSMutableData *d, uint16_t v) { v = CFSwapInt16HostToLittle(v); [d appendBytes:&v length:2]; }

static NSData *WavHeader(uint32_t rate, uint16_t ch, uint32_t frames) {
    uint32_t dataBytes = frames * ch * 4;
    NSMutableData *h = [NSMutableData data];
    [h appendBytes:"RIFF" length:4]; PutLE32(h, 4 + 24 + 12 + 8 + dataBytes);
    [h appendBytes:"WAVE" length:4];
    [h appendBytes:"fmt " length:4]; PutLE32(h, 16);
    PutLE16(h, 3); PutLE16(h, ch); PutLE32(h, rate); PutLE32(h, rate * ch * 4); PutLE16(h, ch * 4); PutLE16(h, 32);
    [h appendBytes:"fact" length:4]; PutLE32(h, 4); PutLE32(h, frames);
    [h appendBytes:"data" length:4]; PutLE32(h, dataBytes);
    return h;
}

BOOL OVDecodeAudio(NSString *src, NSString *dstWav, OVDecodeOptions opts, double *seconds, NSError **error) {
    NSError *result = nil;  // outlives the pool, so the caller's autoreleased error stays valid
    BOOL ok = NO;
    @autoreleasepool {
        NSString *part = [dstWav stringByAppendingString:@".part"];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *fail = nil;
        FILE *fp = NULL;
        do {
            if (![fm isReadableFileAtPath:src]) { fail = IOError(OVAudioIOUnsupported, MsgUnsupported()); break; }
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:src] options:nil];
            NSArray<AVAssetTrack *> *audio = TracksOf(asset, AVMediaTypeAudio);
            if (audio.count == 0) {
                if (TracksOf(asset, AVMediaTypeVideo).count > 0) fail = IOError(OVAudioIONoAudio, MsgNoAudio());
                else fail = IOError(OVAudioIOUnsupported, MsgUnsupported());
                break;
            }
            if (opts.maxSeconds > 0) {
                double dur = 0;
                for (AVAssetTrack *t in audio) dur = MAX(dur, CMTimeGetSeconds(CMTimeRangeGetEnd(t.timeRange)));
                if (dur > opts.maxSeconds + 1e-3) { fail = IOError(OVAudioIOTooLong, MsgTooLong()); break; }
            }

            // Native format of the first track.
            double nativeRate = 44100; int nativeCh = 1;
            CMFormatDescriptionRef fd = (__bridge CMFormatDescriptionRef)audio.firstObject.formatDescriptions.firstObject;
            const AudioStreamBasicDescription *asbd = fd ? CMAudioFormatDescriptionGetStreamBasicDescription(fd) : NULL;
            if (asbd) {
                if (asbd->mSampleRate > 0) nativeRate = asbd->mSampleRate;
                if (asbd->mChannelsPerFrame > 0) nativeCh = (int)asbd->mChannelsPerFrame;
            }
            double rate = opts.sampleRate > 0 ? opts.sampleRate : nativeRate;
            rate = MIN(MAX(rate, 8000), 96000);
            int ch = opts.mono ? 1 : MIN(nativeCh, 2);

            NSError *re = nil;
            AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&re];
            NSDictionary *settings = @{
                AVFormatIDKey: @(kAudioFormatLinearPCM), AVLinearPCMBitDepthKey: @32, AVLinearPCMIsFloatKey: @YES,
                AVLinearPCMIsBigEndianKey: @NO, AVLinearPCMIsNonInterleaved: @NO,
                AVSampleRateKey: @(rate), AVNumberOfChannelsKey: @(ch)};
            AVAssetReaderAudioMixOutput *out = [AVAssetReaderAudioMixOutput assetReaderAudioMixOutputWithAudioTracks:audio audioSettings:settings];
            if (!reader || ![reader canAddOutput:out]) { fail = IOError(OVAudioIOUnsupported, MsgUnsupported()); break; }
            [reader addOutput:out];
            if (![reader startReading]) { fail = IOError(OVAudioIOUnsupported, MsgUnsupported()); break; }

            [fm createDirectoryAtPath:[dstWav stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
            fp = fopen(part.fileSystemRepresentation, "wb");
            if (!fp) { fail = IOError(OVAudioIOUnsupported, [NSString stringWithFormat:@"Cannot write %@", part]); break; }
            NSData *ph = WavHeader((uint32_t)llround(rate), (uint16_t)ch, 0);
            fwrite(ph.bytes, 1, ph.length, fp);

            uint64_t frames = 0;
            uint64_t limit = opts.maxSeconds > 0 ? (uint64_t)ceil(opts.maxSeconds * rate) + (uint64_t)(rate * 0.002) : UINT64_MAX;
            BOOL over = NO;
            CMSampleBufferRef sb;
            while ((sb = [out copyNextSampleBuffer])) {
                CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
                size_t len = bb ? CMBlockBufferGetDataLength(bb) : 0;
                if (len) {
                    NSMutableData *tmp = [NSMutableData dataWithLength:len];
                    CMBlockBufferCopyDataBytes(bb, 0, len, tmp.mutableBytes);
                    fwrite(tmp.bytes, 1, len, fp);
                    frames += len / (4 * (size_t)ch);
                }
                CFRelease(sb);
                if (frames > limit) { over = YES; [reader cancelReading]; break; }
            }
            // The resampler drops its tail; restore the exact length (rate * duration) with silence.
            if (!over && rate != nativeRate && frames > 0) {
                double dur = 0;
                for (AVAssetTrack *t in audio) dur = MAX(dur, CMTimeGetSeconds(CMTimeRangeGetEnd(t.timeRange)));
                uint64_t want = (uint64_t)llround(dur * rate);
                if (want > frames && want - frames <= (uint64_t)(rate * 0.1)) {
                    NSMutableData *z = [NSMutableData dataWithLength:(want - frames) * (size_t)ch * 4];
                    fwrite(z.bytes, 1, z.length, fp);
                    frames = want;
                }
            }
            if (over) { fail = IOError(OVAudioIOTooLong, MsgTooLong()); break; }
            if (reader.status == AVAssetReaderStatusFailed) { fail = IOError(OVAudioIOUnsupported, MsgUnsupported()); break; }
            if (frames == 0) { fail = IOError(OVAudioIOEmpty, MsgEmpty()); break; }
            if (frames * (uint64_t)ch * 4 > 0xFFFFFF00u) { fail = IOError(OVAudioIOTooLong, MsgTooLong()); break; }
            NSData *h = WavHeader((uint32_t)llround(rate), (uint16_t)ch, (uint32_t)frames);
            fseek(fp, 0, SEEK_SET);
            fwrite(h.bytes, 1, h.length, fp);
            int cr = fclose(fp);
            fp = NULL;
            if (cr != 0 || rename(part.fileSystemRepresentation, dstWav.fileSystemRepresentation) != 0) {
                fail = IOError(OVAudioIOUnsupported, @"Write failed");
                break;
            }
            if (seconds) *seconds = (double)frames / rate;
            ok = YES;
        } while (0);
        if (fp) fclose(fp);
        if (!ok) {
            [fm removeItemAtPath:part error:nil];
            result = fail;
        }
    }
    if (!ok && error) *error = result;
    return ok;
}

OVMediaKind OVMediaKindOfFile(NSString *path) {
    if (![[NSFileManager defaultManager] isReadableFileAtPath:path]) return OVMediaUnknown;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    if (TracksOf(asset, AVMediaTypeVideo).count > 0) return OVMediaVideo;
    if (TracksOf(asset, AVMediaTypeAudio).count > 0) return OVMediaAudio;
    return OVMediaUnknown;
}

NSArray<NSString *> *OVVideoExtensions(void) { return @[@"mp4", @"mov", @"m4v"]; }
