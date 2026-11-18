#import "OVToolsModel.h"

const NSTimeInterval OVToolsMaxSeconds = 20 * 60;
const double OVToolsDFNMinDB = 1, OVToolsDFNMaxDB = 30, OVToolsDFNDefaultDB = 12;

@implementation OVToolsModel

+ (BOOL)chainHasActiveEffects:(NSArray<NSDictionary *> *)chain {
    for (NSDictionary *e in chain) if (![e[@"on"] isKindOfClass:NSNumber.class] || [e[@"on"] boolValue]) return YES;
    return NO;
}

+ (NSDictionary *)effectsRequestWithAudio:(NSString *)audio out:(NSString *)out chain:(NSArray<NSDictionary *> *)chain {
    NSMutableArray *active = [NSMutableArray array];
    for (NSDictionary *e in chain) {
        if ([e[@"on"] isKindOfClass:NSNumber.class] && ![e[@"on"] boolValue]) continue;
        [active addObject:e];
    }
    return @{@"cmd": @"fx_apply", @"audio": audio, @"out": out, @"chain": active};
}

+ (double)semitonesForRatio:(double)ratio { return ratio > 0 ? 12.0 * log2(ratio) : 0; }

+ (NSArray<NSDictionary *> *)formantStepsWithAudio:(NSString *)audio out:(NSString *)out tmp:(NSString *)tmp
                                             ratio:(double)ratio semitones:(double)semitones keepCharacter:(BOOL)keep {
    BOOL doPitch = fabs(semitones) > 1e-6, doFormant = fabs(ratio - 1.0) > 1e-6;
    NSMutableArray *steps = [NSMutableArray array];
    if (doPitch) {
        [steps addObject:@{@"cmd": @"pitch_apply", @"audio": audio, @"out": doFormant ? tmp : out,
                           @"semitones": @(semitones), @"preserve_formants": @(keep)}];
    }
    if (doFormant) {
        [steps addObject:@{@"cmd": @"formant_apply", @"audio": doPitch ? tmp : audio, @"out": out, @"ratio": @(ratio)}];
    }
    return steps;
}

+ (NSDictionary *)dfnPlanInstalled:(BOOL)installed audio:(NSString *)audio out:(NSString *)out strengthDB:(double)db {
    if (!installed) return @{@"action": @"download"};
    double clamped = MAX(OVToolsDFNMinDB, MIN(OVToolsDFNMaxDB, db));
    return @{@"action": @"run", @"request": @{@"cmd": @"dfn_apply", @"audio": audio, @"out": out, @"strength_db": @(clamped)}};
}

+ (NSDictionary *)lightCleanupRequestWithAudio:(NSString *)audio out:(NSString *)out {
    return @{@"cmd": @"enhance", @"audio": audio, @"out": out, @"denoise": @YES};
}

+ (NSString *)longFileWarningForSeconds:(NSTimeInterval)seconds {
    if (seconds <= OVToolsMaxSeconds) return nil;
    return @"This file is longer than 20 minutes. Cut it first: the tools take up to 20 minutes.";
}

+ (BOOL)needsDecodeForPath:(NSString *)path { return ![path.pathExtension.lowercaseString isEqualToString:@"wav"]; }

+ (NSString *)workerInputForPath:(NSString *)path workDir:(NSString *)workDir decoder:(OVToolsDecoder)decoder error:(NSError **)error {
    if (![self needsDecodeForPath:path]) return path;
    [NSFileManager.defaultManager createDirectoryAtPath:workDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dst = [workDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.wav", NSUUID.UUID.UUIDString]];
    return decoder(path, dst, error) ? dst : nil;
}

+ (NSString *)disabledReasonForFormat:(NSDictionary *)format {
    if (![format[@"available"] isKindOfClass:NSNumber.class] || [format[@"available"] boolValue]) return nil;
    NSString *r = [format[@"reason"] isKindOfClass:NSString.class] ? format[@"reason"] : nil;
    return r.length ? r : @"This format is not available on this Mac.";
}

+ (NSArray<NSArray *> *)qualityChoicesForFormatId:(NSString *)formatId {
    if ([formatId isEqualToString:@"m4a"] || [formatId isEqualToString:@"mp3"])
        return @[@[@"128 kbps", @128], @[@"192 kbps", @192], @[@"256 kbps", @256], @[@"320 kbps", @320]];
    if ([formatId isEqualToString:@"ogg"])
        return @[@[@"3", @3], @[@"5", @5], @[@"7", @7], @[@"9", @9]];
    return @[];
}

+ (NSInteger)defaultQualityForFormatId:(NSString *)formatId {
    if ([formatId isEqualToString:@"m4a"] || [formatId isEqualToString:@"mp3"]) return 192;
    if ([formatId isEqualToString:@"ogg"]) return 5;
    return -1;
}
@end
