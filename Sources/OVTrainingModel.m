#import "OVTrainingModel.h"
#import "OVLocale.h"

@implementation OVTrainingModel

#pragma mark Names

+ (NSString *)slugForName:(NSString *)raw changed:(BOOL *)changed {
    NSString *s = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    NSMutableString *m = [s mutableCopy];
    // Cyrillic, accents and the like become plain Latin letters (Applio's argument is ASCII)
    CFStringTransform((__bridge CFMutableStringRef)m, NULL, kCFStringTransformToLatin, false);
    CFStringTransform((__bridge CFMutableStringRef)m, NULL, kCFStringTransformStripCombiningMarks, false);
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < m.length; i++) {
        unichar c = [m characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-';
        if (ok) [out appendFormat:@"%C", c];
        else if (c == ' ' || c == '\t' || c == '.') [out appendString:@"_"];
    }
    // the first character is a letter or a digit
    while (out.length && ([out hasPrefix:@"_"] || [out hasPrefix:@"-"])) [out deleteCharactersInRange:NSMakeRange(0, 1)];
    if (out.length > 64) [out deleteCharactersInRange:NSMakeRange(64, out.length - 64)];
    if (changed) *changed = ![out isEqualToString:s];
    return out;
}

+ (BOOL)isValidSlug:(NSString *)slug {
    if (!slug.length || slug.length > 64) return NO;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$" options:0 error:nil];
    return [re numberOfMatchesInString:slug options:0 range:NSMakeRange(0, slug.length)] == 1;
}

#pragma mark Dataset

+ (NSArray<NSString *> *)datasetExtensions { return @[@"wav", @"mp3", @"m4a", @"flac", @"ogg"]; }

+ (NSArray<NSURL *> *)audioFilesInFolder:(NSURL *)folder limit:(NSUInteger)limit {
    NSMutableArray<NSURL *> *out = [NSMutableArray array];
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtURL:folder includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                                                                     options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants
                                                                errorHandler:nil];
    NSSet *ext = [NSSet setWithArray:[self datasetExtensions]];
    for (NSURL *u in e) {
        NSNumber *reg;
        [u getResourceValue:&reg forKey:NSURLIsRegularFileKey error:nil];
        if (reg.boolValue && [ext containsObject:u.pathExtension.lowercaseString]) [out addObject:u];
        if (out.count >= limit) break;
    }
    [out sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return [a.path localizedStandardCompare:b.path]; }];
    return out;
}

+ (NSInteger)recommendedEpochsForSeconds:(double)s {
    if (s <= 0) return 200;
    if (s < 60) return 100;
    if (s < 180) return 150;
    if (s < 600) return 200;
    if (s < 1800) return 300;
    return 400;
}

+ (NSString *)durationLabel:(double)seconds {
    long t = (long)llround(MAX(0, seconds));
    if (t >= 3600) return [NSString stringWithFormat:L(@"%ld h %02ld min"), t / 3600, (t / 60) % 60];
    if (t >= 60) return [NSString stringWithFormat:L(@"%ld min %ld s"), t / 60, t % 60];
    return [NSString stringWithFormat:L(@"%ld s"), t];
}

+ (NSString *)clockLabel:(double)seconds {
    if (seconds <= 0 || isnan(seconds)) return @"—";
    long t = (long)llround(seconds);
    return t >= 3600 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", t / 3600, (t / 60) % 60, t % 60]
                     : [NSString stringWithFormat:@"%ld:%02ld", t / 60, t % 60];
}

+ (NSString *)etaLabelForSeconds:(double)seconds {
    if (seconds < 0 || isnan(seconds)) return @"—";
    long t = (long)llround(seconds);
    if (t < 60) return L(@"under a minute");
    long minutes = (t + 30) / 60;
    if (minutes >= 60) return [NSString stringWithFormat:L(@"about %ld h %ld min"), minutes / 60, minutes % 60];
    return [NSString stringWithFormat:L(@"about %ld min"), minutes];
}

#pragma mark Dataset review

static NSSet<NSString *> *RemovableCodes(void) {
    return [NSSet setWithObjects:@"excessive_silence", @"too_short", @"duplicate", @"unreadable", @"clipping", nil];
}

static NSString *NamesText(NSArray<NSString *> *names) {
    NSArray *first = [names subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)3, names.count))];
    NSString *s = [first componentsJoinedByString:@", "];
    if (names.count > 3) s = [s stringByAppendingFormat:L(@" and %ld more"), (long)(names.count - 3)];
    return s;
}

+ (NSArray<NSDictionary *> *)issuesForReport:(NSDictionary *)report {
    NSMutableArray *out = [NSMutableArray array];
    NSArray *flags = [report[@"dataset_flags"] isKindOfClass:NSArray.class] ? report[@"dataset_flags"] : @[];
    double total = [report[@"total_s"] doubleValue];
    if ([flags containsObject:@"short_dataset"]) {
        [out addObject:@{@"code": @"short_dataset", @"files": @[],
                         @"text": [NSString stringWithFormat:L(@"Total %@ — add recordings, 10+ minutes give a much better voice."), [self durationLabel:total]]}];
    } else if (total < 600 && total > 0) {
        [out addObject:@{@"code": @"more_is_better", @"files": @[], @"text": L(@"A longer recording (10 minutes or more) gives a better voice.")}];
    }
    NSArray *rows = [report[@"files"] isKindOfClass:NSArray.class] ? report[@"files"] : @[];
    NSArray *codes = @[@"excessive_silence", @"long_pause", @"long_edge", @"level_outlier", @"clipping", @"low_sample_rate", @"too_short", @"duplicate", @"unreadable"];
    NSDictionary *formats = @{
        @"excessive_silence": L(@"Mostly silence, remove them (%ld): %@"),
        @"long_pause": L(@"Pauses longer than 2 seconds, trim them (%ld): %@"),
        @"long_edge": L(@"Over a second of silence at the start or end, trim it (%ld): %@"),
        @"level_outlier": L(@"Much louder or quieter than the rest (6 dB or more), even them out (%ld): %@"),
        @"clipping": L(@"Clipped, re-record them quieter or remove them (%ld): %@"),
        @"low_sample_rate": L(@"Below 32 kHz, replace them with better recordings (%ld): %@"),
        @"too_short": L(@"Under 1 second, remove them (%ld): %@"),
        @"duplicate": L(@"Exact repeats of another file, remove them (%ld): %@"),
        @"unreadable": L(@"Can’t be read, replace or remove them (%ld): %@"),
    };
    for (NSString *code in codes) {
        NSMutableArray *names = [NSMutableArray array];
        for (NSDictionary *r in rows) {
            if (![r isKindOfClass:NSDictionary.class]) continue;
            if ([r[@"flags"] isKindOfClass:NSArray.class] && [r[@"flags"] containsObject:code] && [r[@"file"] isKindOfClass:NSString.class])
                [names addObject:r[@"file"]];
        }
        if (!names.count) continue;
        BOOL removable = [RemovableCodes() containsObject:code];
        [out addObject:@{@"code": code, @"files": removable ? names : @[],
                         @"text": [NSString stringWithFormat:formats[code], (long)names.count, NamesText(names)]}];
    }
    return out;
}

+ (NSArray<NSString *> *)removableFilesInReport:(NSDictionary *)report {
    NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *i in [self issuesForReport:report]) [names addObjectsFromArray:i[@"files"]];
    return names.array;
}

+ (NSString *)levelSummaryForReport:(NSDictionary *)report {
    NSNumber *med = report[@"median_rms_db"];
    if (![med isKindOfClass:NSNumber.class]) return nil;
    NSInteger off = 0;
    for (NSDictionary *r in [report[@"files"] isKindOfClass:NSArray.class] ? report[@"files"] : @[])
        if ([r isKindOfClass:NSDictionary.class] && [r[@"flags"] isKindOfClass:NSArray.class] && [r[@"flags"] containsObject:@"level_outlier"]) off++;
    NSString *base = [NSString stringWithFormat:L(@"Levels: median %.0f dB"), med.doubleValue];
    if (off) return [base stringByAppendingFormat:L(@"; off by 6 dB or more: %ld"), (long)off];
    return [base stringByAppendingString:L(@"; all files are even")];
}

+ (NSString *)toneForVerdict:(NSString *)v {
    if ([v isEqualToString:@"ok"]) return @"ok";
    if ([v isEqualToString:@"poor"]) return @"err";
    return @"warn";
}

#pragma mark Live training

+ (NSDictionary *)progressFromLog:(NSString *)log {
    static NSRegularExpression *epochRE, *speedRE, *checkRE;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        epochRE = [NSRegularExpression regularExpressionWithPattern:@"epoch=(\\d+) \\| step=(\\d+)(?: \\| batch=\\d+/\\d+)?(.*)$" options:0 error:nil];
        speedRE = [NSRegularExpression regularExpressionWithPattern:@"training_speed=(\\d+):(\\d+):(\\d+)" options:0 error:nil];
        checkRE = [NSRegularExpression regularExpressionWithPattern:@"^Overtraining check: (\\w+)\\. The best epoch so far is (\\w+)" options:0 error:nil];
    });
    NSInteger epoch = 0, step = 0, best = 0;
    double speed = 0;
    NSString *state = @"improving";
    NSArray<NSString *> *lines = [log componentsSeparatedByString:@"\n"];
    NSInteger lastEpochLine = -1, lastCheckLine = -1;
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *line = lines[i];
        NSTextCheckingResult *m = [epochRE firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (m && [line containsString:@"time="]) {
            epoch = [[line substringWithRange:[m rangeAtIndex:1]] integerValue];
            step = [[line substringWithRange:[m rangeAtIndex:2]] integerValue];
            NSTextCheckingResult *sp = [speedRE firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
            if (sp) speed = [[line substringWithRange:[sp rangeAtIndex:1]] doubleValue] * 3600 + [[line substringWithRange:[sp rangeAtIndex:2]] doubleValue] * 60 +
                            [[line substringWithRange:[sp rangeAtIndex:3]] doubleValue];
            lastEpochLine = (NSInteger)i;
        }
        // a log line may carry a timestamp prefix; the check line is found anywhere in it
        NSRange at = [line rangeOfString:@"Overtraining check:"];
        if (at.location != NSNotFound) {
            NSString *tail = [line substringFromIndex:at.location];
            NSTextCheckingResult *c = [checkRE firstMatchInString:tail options:0 range:NSMakeRange(0, tail.length)];
            if (c) {
                state = [tail substringWithRange:[c rangeAtIndex:1]];
                best = [[tail substringWithRange:[c rangeAtIndex:2]] integerValue];
                lastCheckLine = (NSInteger)i;
            }
        }
    }
    if (lastCheckLine < lastEpochLine) state = @"improving";   // the engine logs the check after every epoch while not improving
    if (![@[@"plateau", @"overtrained"] containsObject:state]) { state = @"improving"; best = 0; }
    return @{@"epoch": @(epoch), @"step": @(step), @"seconds_per_epoch": @(speed), @"state": state, @"best_epoch": @(best)};
}

#pragma mark TensorBoard scalars

static BOOL ReadVarint(const uint8_t *b, NSUInteger n, NSUInteger *pos, uint64_t *out) {
    uint64_t v = 0;
    int shift = 0;
    while (*pos < n && shift < 64) {
        uint8_t c = b[(*pos)++];
        v |= (uint64_t)(c & 0x7F) << shift;
        if (!(c & 0x80)) { *out = v; return YES; }
        shift += 7;
    }
    return NO;
}

/// Skips one field value of wire type `wire` (after its tag). NO when the data ends early or the type is unknown.
static BOOL SkipField(const uint8_t *b, NSUInteger n, NSUInteger *pos, int wire) {
    uint64_t v;
    switch (wire) {
        case 0: return ReadVarint(b, n, pos, &v);
        case 1: if (*pos + 8 > n) return NO; *pos += 8; return YES;
        case 2: if (!ReadVarint(b, n, pos, &v) || v > n - *pos) return NO; *pos += (NSUInteger)v; return YES;
        case 5: if (*pos + 4 > n) return NO; *pos += 4; return YES;
        default: return NO;
    }
}

/// Summary.Value: tag (1, string) and simple_value (2, float).
static void ParseValue(const uint8_t *b, NSUInteger n, NSString *wantTag, double *value, BOOL *match) {
    NSUInteger pos = 0;
    NSString *tag = nil;
    float f = 0;
    BOOL haveValue = NO;
    while (pos < n) {
        uint64_t key;
        if (!ReadVarint(b, n, &pos, &key)) return;
        int field = (int)(key >> 3), wire = (int)(key & 7);
        if (field == 1 && wire == 2) {
            uint64_t len;
            if (!ReadVarint(b, n, &pos, &len) || len > n - pos) return;
            tag = [[NSString alloc] initWithBytes:b + pos length:(NSUInteger)len encoding:NSUTF8StringEncoding];
            pos += (NSUInteger)len;
        } else if (field == 2 && wire == 5) {
            if (pos + 4 > n) return;
            memcpy(&f, b + pos, 4);
            pos += 4;
            haveValue = YES;
        } else if (!SkipField(b, n, &pos, wire)) return;
    }
    if (haveValue && [tag isEqualToString:wantTag] && isfinite(f)) { *value = f; *match = YES; }
}

+ (NSArray<NSArray<NSNumber *> *> *)scalarsInEventsFolder:(NSString *)folder tag:(NSString *)tag {
    NSMutableArray *out = [NSMutableArray array];
    NSArray *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:nil] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names) {
        if (![name hasPrefix:@"events.out.tfevents"]) continue;
        NSData *d = [NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:name] options:NSDataReadingMappedIfSafe error:nil];
        const uint8_t *b = d.bytes;
        NSUInteger n = d.length, pos = 0;
        while (pos + 12 <= n) {   // length (8) + its crc (4) + data + data crc (4)
            uint64_t len;
            memcpy(&len, b + pos, 8);
            if (len > n || pos + 12 + len + 4 > n) break;   // half-written record
            const uint8_t *ev = b + pos + 12;
            pos += 12 + (NSUInteger)len + 4;
            NSUInteger p = 0, evn = (NSUInteger)len;
            int64_t step = 0;
            NSMutableArray<NSNumber *> *vals = [NSMutableArray array];
            while (p < evn) {
                uint64_t key;
                if (!ReadVarint(ev, evn, &p, &key)) break;
                int field = (int)(key >> 3), wire = (int)(key & 7);
                if (field == 2 && wire == 0) {
                    uint64_t v;
                    if (!ReadVarint(ev, evn, &p, &v)) break;
                    step = (int64_t)v;
                } else if (field == 5 && wire == 2) {   // summary
                    uint64_t slen;
                    if (!ReadVarint(ev, evn, &p, &slen) || slen > evn - p) break;
                    const uint8_t *sm = ev + p;
                    NSUInteger sp = 0, sn = (NSUInteger)slen;
                    p += (NSUInteger)slen;
                    while (sp < sn) {
                        uint64_t skey;
                        if (!ReadVarint(sm, sn, &sp, &skey)) break;
                        int sf = (int)(skey >> 3), sw = (int)(skey & 7);
                        if (sf == 1 && sw == 2) {
                            uint64_t vlen;
                            if (!ReadVarint(sm, sn, &sp, &vlen) || vlen > sn - sp) break;
                            double val = 0;
                            BOOL match = NO;
                            ParseValue(sm + sp, (NSUInteger)vlen, tag, &val, &match);
                            if (match) [vals addObject:@(val)];
                            sp += (NSUInteger)vlen;
                        } else if (!SkipField(sm, sn, &sp, sw)) break;
                    }
                } else if (!SkipField(ev, evn, &p, wire)) break;
            }
            for (NSNumber *v in vals) [out addObject:@[@(step), v]];
        }
    }
    return out;
}

#pragma mark Earlier runs

+ (NSString *)completeMarkerName { return @".cns-complete"; }

+ (unsigned long long)sizeOfFolder:(NSString *)folder {
    unsigned long long total = 0;
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:folder] includingPropertiesForKeys:@[NSURLFileSizeKey, NSURLIsRegularFileKey]
                                                                     options:0 errorHandler:nil];
    for (NSURL *u in e) {
        NSNumber *reg, *size;
        [u getResourceValue:&reg forKey:NSURLIsRegularFileKey error:nil];
        [u getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (reg.boolValue) total += size.unsignedLongLongValue;
    }
    return total;
}

+ (unsigned long long)removeCheckpointsInFolder:(NSString *)folder {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^[GD]_\\d+\\.pth$" options:0 error:nil];
    NSFileManager *fm = NSFileManager.defaultManager;
    unsigned long long freed = 0;
    for (NSString *f in [fm contentsOfDirectoryAtPath:folder error:nil]) {
        if ([re numberOfMatchesInString:f options:0 range:NSMakeRange(0, f.length)] != 1) continue;
        NSString *p = [folder stringByAppendingPathComponent:f];
        NSDictionary *a = [fm attributesOfItemAtPath:p error:nil];
        if (![a[NSFileType] isEqual:NSFileTypeRegular]) continue;   // not a link, not a folder
        if ([fm removeItemAtPath:p error:nil]) freed += [a[NSFileSize] unsignedLongLongValue];
    }
    return freed;
}

+ (NSArray<NSDictionary *> *)savedRunsInTraining:(NSString *)training models:(NSString *)models {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSRegularExpression *weights = [NSRegularExpression regularExpressionWithPattern:@"^(.+)_(\\d+)e_(\\d+)s\\.pth$" options:0 error:nil];
    NSRegularExpression *ckpt = [NSRegularExpression regularExpressionWithPattern:@"^[GD]_\\d+\\.pth$" options:0 error:nil];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSString *name in [fm contentsOfDirectoryAtPath:training error:nil]) {
        if (![self isValidSlug:name]) continue;
        NSString *dir = [training stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;
        NSInteger reached = 0;
        unsigned long long ckBytes = 0;
        BOOL g = NO, d = NO;
        for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            NSTextCheckingResult *m = [weights firstMatchInString:f options:0 range:NSMakeRange(0, f.length)];
            if (m && [[f substringWithRange:[m rangeAtIndex:1]] isEqualToString:name]) reached = MAX(reached, [[f substringWithRange:[m rangeAtIndex:2]] integerValue]);
            if ([ckpt numberOfMatchesInString:f options:0 range:NSMakeRange(0, f.length)] == 1) {
                if ([f hasPrefix:@"G"]) g = YES; else d = YES;
                ckBytes += [[fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:f] error:nil][NSFileSize] unsignedLongLongValue];
            }
        }
        BOOL hasModel = [fm fileExistsAtPath:[[models stringByAppendingPathComponent:name] stringByAppendingPathComponent:[name stringByAppendingString:@".pth"]]];
        BOOL complete = [fm fileExistsAtPath:[dir stringByAppendingPathComponent:[self completeMarkerName]]];
        NSString *status = complete ? @"done" : (g && d) ? @"interrupted" : hasModel ? @"done" : @"unfinished";
        NSDate *mod = [fm attributesOfItemAtPath:dir error:nil][NSFileModificationDate] ?: NSDate.distantPast;
        [out addObject:@{@"name": name, @"epochs": @(reached), @"bytes": @([self sizeOfFolder:dir]), @"checkpoint_bytes": @(ckBytes),
                         @"has_checkpoints": @(g && d), @"status": status, @"has_model": @(hasModel), @"path": dir, @"modified": mod}];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"modified"] compare:a[@"modified"]]; }];
    return out;
}

@end
