#import "OVVoiceCheck.h"
#import "OVLocale.h"
#import <AVFoundation/AVFoundation.h>

static NSString *Clock(double t) {
    int s = (int)MAX(0, floor(t));
    return [NSString stringWithFormat:@"%d:%02d", s / 60, s % 60];
}

NSString *OVRegionTooltip(NSDictionary *r) {
    NSString *kind = r[@"kind"];
    NSDictionary *names = @{@"clipping": L(@"Clipping"), @"noise": L(@"Noise"), @"hum": L(@"Mains hum"),
                            @"pause": L(@"Pause"), @"low_level": L(@"Low level")};
    NSString *name = names[kind] ?: L(@"Problem");
    if ([kind isEqualToString:@"hum"]) return name;
    NSString *a = Clock([r[@"start"] doubleValue]), *b = Clock([r[@"end"] doubleValue]);
    NSString *span = [a isEqualToString:b] ? a : [NSString stringWithFormat:@"%@–%@", a, b];
    return [NSString stringWithFormat:L(@"%@ at %@"), name, span];
}

NSDictionary *OVAdviceInfo(NSString *code) {
    NSDictionary *t = @{
        @"trim_start": @{@"text": L(@"Silence at the start — trim it."), @"button": L(@"Trim silence"), @"action": @"light"},
        @"trim_end": @{@"text": L(@"Silence at the end — trim it."), @"button": L(@"Trim silence"), @"action": @"light"},
        @"denoise": @{@"text": L(@"Background noise — clean it up or record in a quieter room."), @"button": L(@"Denoise"), @"action": @"dfn"},
        @"too_quiet": @{@"text": L(@"Very quiet — speak closer to the microphone.")},
        @"clipping": @{@"text": L(@"Distorted (clipping) — speak a little further from the microphone.")},
        @"long_pause": @{@"text": L(@"A long pause — shorten it."), @"button": L(@"Shorten pauses"), @"action": @"light"},
        @"hum": @{@"text": L(@"Mains hum — remove it with a denoiser."), @"button": L(@"Denoise"), @"action": @"dfn"},
    };
    return t[code];
}

NSDictionary *OVEnhanceRequest(NSString *mode, double strengthDb, NSString *audio, NSString *out, BOOL engineReady, NSString **action) {
    if (![@[@"light", @"dfn", @"music"] containsObject:mode]) mode = @"light";
    if (action) *action = nil;
    if (![mode isEqualToString:@"light"] && !engineReady) {
        if (action) *action = @"download";
        return nil;
    }
    double db = MIN(30, MAX(1, strengthDb));
    return @{@"cmd": @"enhance", @"audio": audio, @"out": out, @"mode": mode, @"strength_db": @(db)};
}

NSArray<NSString *> *OVCompareFlags(NSDictionary *result, NSUInteger index) {
    NSArray *samples = result[@"samples"];
    if (index >= samples.count) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *p in result[@"pairs"])
        if ([p[@"b"] unsignedIntegerValue] == index && [p[@"duplicate"] boolValue]) { [out addObject:L(@"Duplicate")]; break; }
    NSDictionary *s = samples[index];
    double medRms = [result[@"median_rms_db"] doubleValue];
    NSMutableArray<NSNumber *> *snrs = [NSMutableArray array];
    for (NSDictionary *x in samples) [snrs addObject:x[@"snr_db"] ?: @0];
    [snrs sortUsingSelector:@selector(compare:)];
    double medSnr = snrs.count % 2 ? [snrs[snrs.count / 2] doubleValue]
                                   : ([snrs[snrs.count / 2 - 1] doubleValue] + [snrs[snrs.count / 2] doubleValue]) / 2;
    if (medRms - [s[@"rms_db"] doubleValue] > 6) [out addObject:L(@"Much quieter")];
    if (medSnr - [s[@"snr_db"] doubleValue] > 10) [out addObject:L(@"Noisier")];
    return out;
}

NSArray<NSArray<NSNumber *> *> *OVWaveformPeaksForFile(NSString *path, NSUInteger count) {
    NSError *err = nil;
    AVAudioFile *f = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:path] error:&err];
    if (!f || f.length <= 0 || count == 0) return nil;
    AVAudioFormat *fmt = f.processingFormat;
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:16384];
    float *mn = calloc(count, sizeof(float)), *mx = calloc(count, sizeof(float));
    double total = (double)f.length;
    AVAudioFramePosition pos = 0;
    while (pos < f.length) {
        if (![f readIntoBuffer:buf error:&err] || buf.frameLength == 0) break;
        for (AVAudioFrameCount i = 0; i < buf.frameLength; i++) {
            NSUInteger b = MIN(count - 1, (NSUInteger)((double)(pos + i) / total * count));
            for (AVAudioChannelCount c = 0; c < fmt.channelCount; c++) {
                float v = buf.floatChannelData[c][i];
                if (v < mn[b]) mn[b] = v;
                if (v > mx[b]) mx[b] = v;
            }
        }
        pos += buf.frameLength;
    }
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger b = 0; b < count; b++) [out addObject:@[@(MAX(-1, mn[b])), @(MIN(1, mx[b]))]];
    free(mn); free(mx);
    return out;
}
