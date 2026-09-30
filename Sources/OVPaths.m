#import "OVPaths.h"
#import "OVLocale.h"

static NSString *J(NSString *a, NSString *b) { return [a stringByAppendingPathComponent:b]; }

@implementation OVPaths

+ (NSString *)appSupportRoot {
    return NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
        ?: J(NSHomeDirectory(), @"Library/Application Support");
}
/// OV_DATA_DIR redirects all app data (demo screenshots, tests).
+ (NSString *)dataOverride { return NSProcessInfo.processInfo.environment[@"OV_DATA_DIR"]; }
+ (NSString *)support      { return [self dataOverride] ?: J([self appSupportRoot], OVAppName); }
+ (NSString *)legacySupport { return J([self appSupportRoot], @"OmniVoice-UA"); }
+ (NSString *)legacyPython  { return J([self legacySupport], @"runtime/.venv/bin/python"); }
+ (NSString *)runtime      { return J([self support], @"runtime"); }
+ (NSString *)ownVenv      { return J([self runtime], @".venv"); }
+ (NSString *)ownPython    { return J([self ownVenv], @"bin/python"); }
+ (NSString *)binDir       { return J([self runtime], @"bin"); }
+ (NSString *)models       { return J([self legacySupport], @"models"); }
+ (NSString *)voices       { return J([self support], @"voices"); }
+ (NSString *)logs         { return J([self support], @"logs"); }
+ (NSString *)workerScript { return J([self runtime], @"worker.py"); }
+ (NSString *)outputs {
    NSString *music = NSSearchPathForDirectoriesInDomains(NSMusicDirectory, NSUserDomainMask, YES).firstObject
        ?: NSHomeDirectory();
    if ([self dataOverride]) return J([self dataOverride], @"Music");
    return J(music, OVAppName);
}

+ (void)ensure {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *d in @[[self support], [self runtime], [self binDir],
                          [self voices], [self logs], [self outputs]])
        [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
}


/// One-time move of voices, settings and recordings from the earlier names of the app
/// (OmniVoice UA → Text to Speech → Clone'n'Speak).
+ (void)migrateFromLegacy {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d boolForKey:@"migratedFromOmniVoiceUA"]) return;
    [d setBool:YES forKey:@"migratedFromOmniVoiceUA"];
    NSArray *keep = @[@"voice", @"draftText", @"ttsModel", @"asrModel", @"loraModel", @"language", @"theme", @"uiLanguage"];
    for (NSString *domain in @[@"com.texttospeech.mac", @"ua.omnivoice.app"]) { // newest first
        NSDictionary *old = [d persistentDomainForName:domain];
        for (NSString *k in old) {
            if ([k hasPrefix:@"NS"] || [@[@"device", @"dtype", @"attn", @"migratedFromOmniVoiceUA"] containsObject:k]) continue;
            if (![d objectForKey:k] || ([keep containsObject:k] && ![d boolForKey:@"migratedPickedNewest"])) [d setObject:old[k] forKey:k];
        }
        if (old.count) [d setBool:YES forKey:@"migratedPickedNewest"];
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    [self ensure];
    for (NSString *legacy in @[J([self appSupportRoot], @"Text to Speech"), [self legacySupport]]) {
        for (NSString *name in @[@"voices", @"custom-models.plist"]) {
            NSString *src = J(legacy, name), *dst = J([self support], name);
            if (![fm fileExistsAtPath:src]) continue;
            if ([name isEqualToString:@"voices"]) {
                for (NSString *v in [fm contentsOfDirectoryAtPath:src error:nil])
                    if (![fm fileExistsAtPath:J(dst, v)]) [fm moveItemAtPath:J(src, v) toPath:J(dst, v) error:nil];
            } else if (![fm fileExistsAtPath:dst]) {
                [fm moveItemAtPath:src toPath:dst error:nil];
            }
        }
    }
    // generated audio → ~/Music/Clone'n'Speak
    for (NSString *oldName in @[@"Text to Speech", @"OmniVoice UA"]) {
        NSString *oldOut = J([self outputs].stringByDeletingLastPathComponent, oldName);
        for (NSString *f in [fm contentsOfDirectoryAtPath:oldOut error:nil])
            if (![fm fileExistsAtPath:J([self outputs], f)]) [fm moveItemAtPath:J(oldOut, f) toPath:J([self outputs], f) error:nil];
        if ([fm fileExistsAtPath:oldOut] && ![fm contentsOfDirectoryAtPath:oldOut error:nil].count) [fm removeItemAtPath:oldOut error:nil];
    }
}
@end

NSString *OVFormatBytes(long long bytes) {
    return [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleFile];
}

NSString *OVFormatDuration(double s) {
    if (s < 0 || isnan(s)) s = 0;
    int t = (int)lround(s);
    return t >= 3600 ? [NSString stringWithFormat:@"%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60]
                     : [NSString stringWithFormat:@"%d:%02d", t / 60, t % 60];
}
