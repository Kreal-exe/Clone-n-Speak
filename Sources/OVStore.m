#import "OVStore.h"
#import "OVPaths.h"
#import "OVModels.h"
#import "OVLocale.h"
#import "OVMemory.h"
#import "OVWorker.h"
#import <AVFAudio/AVFAudio.h>

NSNotificationName const OVVoicesDidChangeNotification = @"OVVoicesDidChange";
NSNotificationName const OVHistoryDidChangeNotification = @"OVHistoryDidChange";

#pragma mark - Voices

@implementation OVVoice
- (NSString *)referencePath { return [self.folder stringByAppendingPathComponent:@"reference.wav"]; }
- (NSString *)promptPath { return [self.folder stringByAppendingPathComponent:@"prompt.npz"]; }
/// Voices cloned by the PyTorch versions have prompt.pt; the MLX engine re-encodes them from the sample.
- (BOOL)ready {
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:self.promptPath]) return YES;
    return [fm fileExistsAtPath:[self.folder stringByAppendingPathComponent:@"prompt.pt"]] &&
           [fm fileExistsAtPath:self.referencePath] && self.refText.length > 0;
}
- (NSDictionary *)workerSpec {
    return @{@"prompt": self.promptPath, @"audio": self.referencePath, @"ref_text": self.refText ?: @""};
}
- (NSString *)adaptedPath:(NSString *)language ext:(NSString *)ext {
    return [self.folder stringByAppendingPathComponent:[NSString stringWithFormat:@"adapted-%@.%@", language, ext]];
}
- (NSString *)adaptedSamplePath:(NSString *)language { return [self adaptedPath:language ext:@"wav"]; }
- (BOOL)adaptsToLanguage:(NSString *)language {
    return [OVSettings adaptAccent] && language.length && self.language.length && ![language isEqualToString:self.language];
}
- (NSDictionary *)workerSpecForLanguage:(NSString *)language {
    if (![self adaptsToLanguage:language]) return self.workerSpec;
    NSMutableDictionary *spec = [self.workerSpec mutableCopy];
    spec[@"adapt_prompt"] = [self adaptedPath:language ext:@"npz"];
    spec[@"adapt_name"] = [OVLocale nameForLanguage:language];
    return spec;
}
- (NSArray<NSString *> *)adaptedLanguages {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.folder error:nil])
        if ([f hasPrefix:@"adapted-"] && [f.pathExtension isEqualToString:@"npz"])
            [out addObject:[f.stringByDeletingPathExtension substringFromIndex:@"adapted-".length]];
    return [out sortedArrayUsingSelector:@selector(compare:)];
}
- (void)forgetAdaptations {
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.folder error:nil])
        if ([f hasPrefix:@"adapted-"]) [NSFileManager.defaultManager removeItemAtPath:[self.folder stringByAppendingPathComponent:f] error:nil];
}
- (void)save {
    [NSFileManager.defaultManager createDirectoryAtPath:self.folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary *d = [@{@"name": self.name ?: @"", @"refText": self.refText ?: @"",
                                @"created": self.created ?: NSDate.date, @"seconds": @(self.seconds)} mutableCopy];
    if (self.language.length) d[@"language"] = self.language;
    d[@"languageAuto"] = @(self.languageAuto);
    [d writeToFile:[self.folder stringByAppendingPathComponent:@"meta.plist"] atomically:YES];
    // refresh the list first so observers already find this voice in it (reload posts the change notification)
    [[OVVoices shared] reload];
}
@end

@interface OVVoices ()
@property (readwrite) NSArray<OVVoice *> *all;
@end

@implementation OVVoices
+ (instancetype)shared {
    static OVVoices *s;
    static dispatch_once_t once;
    static BOOL loaded;
    dispatch_once(&once, ^{ s = [OVVoices new]; });
    if (!loaded) { loaded = YES; [s reload]; }
    return s;
}

- (void)reload {
    NSMutableArray *list = [NSMutableArray array];
    NSString *root = [OVPaths voices];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]) {
        NSString *dir = [root stringByAppendingPathComponent:name];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:@"meta.plist"]];
        if (!meta) continue;
        OVVoice *v = [OVVoice new];
        v.identifier = name;
        v.folder = dir;
        v.name = meta[@"name"] ?: name;
        v.refText = meta[@"refText"] ?: @"";
        v.created = meta[@"created"] ?: NSDate.distantPast;
        v.seconds = [meta[@"seconds"] doubleValue];
        v.language = meta[@"language"];
        // voices made before 1.0.1 had their language picked by hand
        v.languageAuto = meta[@"languageAuto"] ? [meta[@"languageAuto"] boolValue] : v.language == nil;
        [list addObject:v];
    }
    [list sortUsingComparator:^NSComparisonResult(OVVoice *a, OVVoice *b) { return [b.created compare:a.created]; }];
    self.all = list;
    [NSNotificationCenter.defaultCenter postNotificationName:OVVoicesDidChangeNotification object:self];
}

- (OVVoice *)createNamed:(NSString *)name {
    OVVoice *v = [OVVoice new];
    v.identifier = NSUUID.UUID.UUIDString;
    v.folder = [[OVPaths voices] stringByAppendingPathComponent:v.identifier];
    v.name = name;
    v.refText = @"";
    v.created = NSDate.date;
    v.languageAuto = YES;
    [NSFileManager.defaultManager createDirectoryAtPath:v.folder withIntermediateDirectories:YES attributes:nil error:nil];
    return v;
}

- (void)remove:(OVVoice *)v {
    [NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:v.folder] resultingItemURL:nil error:nil];
    [self reload];
}

- (OVVoice *)voiceWithId:(NSString *)identifier {
    for (OVVoice *v in self.all) if ([v.identifier isEqualToString:identifier]) return v;
    return nil;
}
@end

#pragma mark - History

@implementation OVGeneration
@end

@interface OVHistory ()
@property (readwrite) NSArray<OVGeneration *> *all;
@end

@implementation OVHistory
+ (instancetype)shared {
    static OVHistory *s;
    static dispatch_once_t once;
    static BOOL loaded;
    dispatch_once(&once, ^{ s = [OVHistory new]; });
    if (!loaded) { loaded = YES; [s reload]; }
    return s;
}

- (void)reload {
    NSString *root = [OVPaths outputs];
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]) {
        if (![f.pathExtension.lowercaseString isEqualToString:@"wav"]) continue;
        NSString *path = [root stringByAppendingPathComponent:f];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:[path.stringByDeletingPathExtension stringByAppendingPathExtension:@"plist"]];
        OVGeneration *g = [OVGeneration new];
        g.path = path;
        g.text = meta[@"text"] ?: f.stringByDeletingPathExtension;
        g.voiceName = meta[@"voice"] ?: @"";
        g.date = meta[@"date"] ?: [[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] fileModificationDate] ?: NSDate.date;
        g.seconds = meta[@"seconds"] ? [meta[@"seconds"] doubleValue] : OVAudioDuration(path);
        g.elapsed = [meta[@"elapsed"] doubleValue];
        g.voiceId = meta[@"voiceId"];
        g.clarity = meta[@"clarity"] ? [meta[@"clarity"] doubleValue] : -1;
        g.likeness = meta[@"likeness"] ? [meta[@"likeness"] doubleValue] : -1;
        g.problems = meta[@"problems"] ?: @[];
        [list addObject:g];
    }
    [list sortUsingComparator:^NSComparisonResult(OVGeneration *a, OVGeneration *b) { return [b.date compare:a.date]; }];
    self.all = list;
    [NSNotificationCenter.defaultCenter postNotificationName:OVHistoryDidChangeNotification object:self];
}

- (NSString *)newOutputPathForText:(NSString *)text {
    [OVPaths ensure];
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd HH.mm.ss";
    // a few words of the text make the file recognisable in Finder
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?*\"<>|\n\r\t"];
    NSString *words = [[text componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@" "];
    words = [words stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (words.length > 40) words = [[words substringToIndex:40] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *base = [NSString stringWithFormat:@"%@ %@", [df stringFromDate:NSDate.date], words];
    NSString *path = [[OVPaths outputs] stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"wav"]];
    for (int i = 2; [NSFileManager.defaultManager fileExistsAtPath:path]; i++)
        path = [[OVPaths outputs] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ (%d).wav", base, i]];
    return path;
}

- (void)record:(NSString *)path text:(NSString *)text voice:(OVVoice *)voice result:(NSDictionary *)r {
    NSMutableDictionary *meta = [@{@"text": text, @"voice": voice.name ?: L(@"Model’s own voice"), @"date": NSDate.date,
                                   @"seconds": r[@"seconds"] ?: @0, @"elapsed": r[@"elapsed"] ?: @0} mutableCopy];
    if (voice.identifier) meta[@"voiceId"] = voice.identifier;
    if (r[@"clarity"]) meta[@"clarity"] = r[@"clarity"];
    if (r[@"likeness"]) meta[@"likeness"] = r[@"likeness"];
    if ([r[@"problems"] count]) meta[@"problems"] = r[@"problems"];
    [meta writeToFile:[path.stringByDeletingPathExtension stringByAppendingPathExtension:@"plist"] atomically:YES];
    [self reload];
}

- (void)remove:(OVGeneration *)g {
    [NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:g.path] resultingItemURL:nil error:nil];
    [NSFileManager.defaultManager removeItemAtPath:[g.path.stringByDeletingPathExtension stringByAppendingPathExtension:@"plist"] error:nil];
    [self reload];
}
@end

#pragma mark - Audio

double OVAudioDuration(NSString *path) {
    AVAudioFile *f = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:path] error:nil];
    if (!f || f.processingFormat.sampleRate <= 0) return 0;
    return (double)f.length / f.processingFormat.sampleRate;
}

BOOL OVConvertToWav(NSString *src, NSString *dst, double *seconds, NSError **error) {
    AVAudioFile *in = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:src] error:error];
    if (!in) return NO;
    AVAudioFormat *inFmt = in.processingFormat;
    AVAudioFormat *outFmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:24000 channels:1 interleaved:NO];
    AVAudioConverter *conv = [[AVAudioConverter alloc] initFromFormat:inFmt toFormat:outFmt];
    if (!conv) {
        if (error) *error = [NSError errorWithDomain:@"OV" code:1 userInfo:@{NSLocalizedDescriptionKey: L(@"Unsupported audio format")}];
        return NO;
    }
    if (inFmt.channelCount > 1) {
        // stereo → mono: take the first channel (reference clips are voice, channels are near-identical)
        conv.channelMap = @[@0];
    }
    NSString *tmp = [dst stringByAppendingString:@".tmp.wav"];
    [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
    NSDictionary *settings = @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @24000, AVNumberOfChannelsKey: @1,
                               AVLinearPCMBitDepthKey: @16, AVLinearPCMIsFloatKey: @NO, AVLinearPCMIsBigEndianKey: @NO};
    AVAudioFile *out = [[AVAudioFile alloc] initForWriting:[NSURL fileURLWithPath:tmp] settings:settings
                                              commonFormat:AVAudioPCMFormatFloat32 interleaved:NO error:error];
    if (!out) return NO;
    AVAudioFrameCount chunk = 16384;
    AVAudioPCMBuffer *inBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:inFmt frameCapacity:chunk];
    AVAudioPCMBuffer *outBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outFmt
                                                              frameCapacity:(AVAudioFrameCount)(chunk * 24000.0 / inFmt.sampleRate) + 1024];
    __block BOOL eof = NO;
    long long written = 0;
    while (YES) {
        NSError *cerr = nil;
        AVAudioConverterOutputStatus st = [conv convertToBuffer:outBuf error:&cerr withInputFromBlock:
            ^AVAudioBuffer *(AVAudioPacketCount n, AVAudioConverterInputStatus *status) {
                if (eof) { *status = AVAudioConverterInputStatus_EndOfStream; return nil; }
                inBuf.frameLength = 0;
                if (![in readIntoBuffer:inBuf frameCount:MIN(n, chunk) error:nil] || inBuf.frameLength == 0) {
                    eof = YES;
                    *status = AVAudioConverterInputStatus_EndOfStream;
                    return nil;
                }
                *status = AVAudioConverterInputStatus_HaveData;
                return inBuf;
            }];
        if (st == AVAudioConverterOutputStatus_Error) { if (error) *error = cerr; return NO; }
        if (outBuf.frameLength > 0) {
            if (![out writeFromBuffer:outBuf error:error]) return NO;
            written += outBuf.frameLength;
        }
        if (st == AVAudioConverterOutputStatus_EndOfStream || (eof && outBuf.frameLength == 0)) break;
    }
    out = nil; // close file
    [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
    if (![NSFileManager.defaultManager moveItemAtPath:tmp toPath:dst error:error]) return NO;
    if (seconds) *seconds = written / 24000.0;
    return YES;
}

#pragma mark - Settings

@implementation OVSettings
+ (void)registerDefaults {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        @"language": @"auto",
        @"numStep": @32,
        @"guidance": @2.0,
        @"speed": @1.0,
        @"tShift": @0.1,
        @"classTemp": @0.0,
        @"posTemp": @5.0,
        @"layerPenalty": @5.0,
        @"normalizeText": @YES,
        @"seed": @-1,
        // voice style (Speech page): 0 = as the model speaks
        @"styleMood": @"neutral",
        @"styleIntonation": @0.0,
        @"styleEnergy": @0.0,
        @"stylePitch": @0.0,
        @"styleTone": @0.0,
        @"stylePauses": @1.0,
        @"styleVolume": @0.0,
        @"stylePanel": @YES,
        @"adaptAccent": @YES,
        @"precision": @0,   // 0 = automatic: best precision that fits into free memory
        @"lowMemory": @([OVSettings physicalMemoryGB] <= 12),
        @"idleUnloadMinutes": @([OVSettings physicalMemoryGB] <= 12 ? 3 : 10),
        @"prepareText": @YES,
        @"improve": @NO,
        @"improveAttempts": @3,
        @"improveThreshold": @0.08,
    }];
}

/// 0 in settings = automatic: the best precision for which ONE model fits on this Mac. Whisper and the voice
/// model take turns in memory, so an 8 GB Mac runs both in 16-bit — one set of weights, no extra copies.
+ (NSInteger)autoBits { return [self physicalMemoryGB] >= 7.5 ? 16 : 8; }
+ (NSInteger)ttsBits {
    NSInteger fixed = [NSUserDefaults.standardUserDefaults integerForKey:@"precision"];
    return fixed > 0 ? fixed : [self autoBits];
}
+ (NSInteger)asrBits {
    NSInteger fixed = [NSUserDefaults.standardUserDefaults integerForKey:@"asrPrecision"];
    return fixed > 0 ? fixed : [self autoBits];
}

+ (double)physicalMemoryGB { return NSProcessInfo.processInfo.physicalMemory / 1073741824.0; }
+ (BOOL)lowMemory { return [NSUserDefaults.standardUserDefaults boolForKey:@"lowMemory"]; }

+ (NSDictionary *)improveParams {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    return @{@"attempts": @([d integerForKey:@"improveAttempts"]), @"threshold": @([d doubleForKey:@"improveThreshold"])};
}

+ (NSString *)language { return [OVLocale speechLanguageSetting]; }

+ (NSDictionary *)modelSpec {
    OVModel *m = [OVModels shared].ttsModel;
    if (!m.localPath) return nil;
    NSMutableDictionary *spec = [@{@"path": m.localPath, @"bits": @([self ttsBits])} mutableCopy];
    OVModel *lora = [OVModels shared].loraModel;
    if (lora.localPath) spec[@"lora"] = lora.localPath;
    return spec;
}

+ (BOOL)adaptAccent { return [NSUserDefaults.standardUserDefaults boolForKey:@"adaptAccent"]; }

+ (NSArray<NSDictionary *> *)moods {
    // intonation / energy / tone: −1…1, pitch: semitones, pauses: multiplier
    return @[
        @{@"id": @"neutral", @"emoji": @"😐", @"title": L(@"Neutral"), @"styleIntonation": @0.0, @"styleEnergy": @0.0, @"stylePitch": @0.0, @"styleTone": @0.0, @"stylePauses": @1.0},
        @{@"id": @"calm", @"emoji": @"😌", @"title": L(@"Calm"), @"styleIntonation": @-0.3, @"styleEnergy": @-0.5, @"stylePitch": @-0.5, @"styleTone": @-0.3, @"stylePauses": @1.3},
        @{@"id": @"cheerful", @"emoji": @"😊", @"title": L(@"Cheerful"), @"styleIntonation": @0.6, @"styleEnergy": @0.5, @"stylePitch": @1.0, @"styleTone": @0.3, @"stylePauses": @0.9},
        @{@"id": @"energetic", @"emoji": @"⚡️", @"title": L(@"Energetic"), @"styleIntonation": @0.4, @"styleEnergy": @0.9, @"stylePitch": @0.5, @"styleTone": @0.4, @"stylePauses": @0.8},
        @{@"id": @"serious", @"emoji": @"🧐", @"title": L(@"Serious"), @"styleIntonation": @-0.5, @"styleEnergy": @0.1, @"stylePitch": @-1.0, @"styleTone": @0.0, @"stylePauses": @1.1},
        @{@"id": @"warm", @"emoji": @"🤗", @"title": L(@"Warm"), @"styleIntonation": @0.2, @"styleEnergy": @-0.2, @"stylePitch": @-0.5, @"styleTone": @-0.6, @"stylePauses": @1.15},
        @{@"id": @"sad", @"emoji": @"😔", @"title": L(@"Sad"), @"styleIntonation": @-0.6, @"styleEnergy": @-0.8, @"stylePitch": @-1.0, @"styleTone": @-0.4, @"stylePauses": @1.5},
        @{@"id": @"storyteller", @"emoji": @"📖", @"title": L(@"Storyteller"), @"styleIntonation": @0.7, @"styleEnergy": @-0.1, @"stylePitch": @0.0, @"styleTone": @-0.2, @"stylePauses": @1.4},
    ];
}

+ (void)applyMood:(NSString *)identifier {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    for (NSDictionary *m in [self moods]) {
        if (![m[@"id"] isEqualToString:identifier]) continue;
        for (NSString *k in m) if ([k hasPrefix:@"style"]) [d setObject:m[k] forKey:k];
        [d setObject:identifier forKey:@"styleMood"];
    }
}

+ (BOOL)styleIsNeutral {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    for (NSString *k in @[@"styleIntonation", @"styleEnergy", @"stylePitch", @"styleTone", @"styleVolume"])
        if (fabs([d doubleForKey:k]) > 0.005) return NO;
    return fabs([d doubleForKey:@"stylePauses"] - 1.0) < 0.005;
}

/// Voice design tags for the model's own voice ("female, low pitch, whisper"); ignored for cloned voices.
+ (NSString *)designInstruct {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSMutableArray *tags = [NSMutableArray array];
    for (NSString *k in @[@"designGender", @"designAge", @"designPitch", @"designAccent"])
        if ([d stringForKey:k].length) [tags addObject:[d stringForKey:k]];
    if ([d boolForKey:@"designWhisper"]) [tags addObject:@"whisper"];
    return [tags componentsJoinedByString:@", "];
}

+ (NSDictionary *)generationParams {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    return @{
        @"style": @{@"intonation": @([d doubleForKey:@"styleIntonation"]), @"energy": @([d doubleForKey:@"styleEnergy"]),
                    @"pitch": @([d doubleForKey:@"stylePitch"]), @"tone": @([d doubleForKey:@"styleTone"]),
                    @"pauses": @([d doubleForKey:@"stylePauses"]), @"volume": @([d doubleForKey:@"styleVolume"])},
        @"instruct": [self designInstruct],
        @"num_step": @([d integerForKey:@"numStep"]),
        @"guidance_scale": @([d doubleForKey:@"guidance"]),
        @"speed": @([d doubleForKey:@"speed"]),
        @"t_shift": @([d doubleForKey:@"tShift"]),
        @"class_temperature": @([d doubleForKey:@"classTemp"]),
        @"position_temperature": @([d doubleForKey:@"posTemp"]),
        @"layer_penalty_factor": @([d doubleForKey:@"layerPenalty"]),
        @"normalize_text": @([d boolForKey:@"normalizeText"]),
        @"prepare_text": @([d boolForKey:@"prepareText"]),
        @"seed": @([d integerForKey:@"seed"]),
    };
}
@end
