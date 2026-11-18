// deps: OVAPICore.m OVPaths.m OVLocale.m
// Pure parts of the local API: key format, upload/output paths, request whitelisting. Keychain IO and the server
// process are checked by hand on the running app (task 8.6, step 4).
#import <Foundation/Foundation.h>
#import "OVAPICore.h"
#import "OVPaths.h"

static int gFailures = 0;
#define ASSERT(cond, ...) do { if (!(cond)) { gFailures++; fprintf(stderr, "FAIL %s:%d  %s  ", __func__, __LINE__, #cond); \
    fprintf(stderr, "" __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static void testNewKeyFormatAndUniqueness(void) {
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"] invertedSet];
    NSMutableSet *seen = [NSMutableSet set];
    for (int i = 0; i < 1000; i++) {
        NSString *k = OVAPINewKey();
        ASSERT([k hasPrefix:@"cns_"], "%s", k.UTF8String);
        ASSERT(k.length == 47, "length %lu", (unsigned long)k.length);
        ASSERT([[k substringFromIndex:4] rangeOfCharacterFromSet:bad].location == NSNotFound, "alphabet: %s", k.UTF8String);
        [seen addObject:k];
    }
    ASSERT(seen.count == 1000, "unique %lu", (unsigned long)seen.count);
    NSString *h = OVAPIKeySHA256(@"cns_abc");
    ASSERT(h.length == 64, "hash length");
    ASSERT([h isEqualToString:OVAPIKeySHA256(@"cns_abc")] && ![h isEqualToString:OVAPIKeySHA256(@"cns_abd")], "hash is stable and differs");
}

static void testUploadPathRejectsBadIds(void) {
    for (NSString *bad in @[@"../x", @"", @"not-a-uuid", @"..", @"/etc/passwd",
                            @"3F2504E0-4F89-11D3-9A0C-0305E82C3301",          // upper case: the server only issues lower case
                            @"3f2504e0-4f89-11d3-9a0c-0305e82c3301/../x",
                            @"3f2504e0-4f89-11d3-9a0c-0305e82c33010",
                            @"3f2504e0-4f89-11d3-9a0c-0305e82c330",
                            @"3f2504e0-4f89-11d3-9a0c-0305e82c3301\n",
                            @"3f2504e0-4f89-11d3-9a0c-0305e82c33zz"])
        ASSERT(OVAPIUploadPath(bad) == nil, "accepted %s", bad.UTF8String);
    ASSERT(OVAPIUploadPath((id)NSNull.null) == nil, "NSNull");
    ASSERT(OVAPIUploadPath(nil) == nil, "nil");
}

static void testUploadPathStaysInsideUploadsDir(void) {
    NSString *good = @"3f2504e0-4f89-11d3-9a0c-0305e82c3301";
    NSString *p = OVAPIUploadPath(good);
    ASSERT(p != nil, "valid id refused");
    NSString *root = [OVPaths apiUploads].stringByStandardizingPath;
    ASSERT([p.stringByStandardizingPath hasPrefix:[root stringByAppendingString:@"/"]], "%s not inside %s", p.UTF8String, root.UTF8String);
    ASSERT([p.lastPathComponent isEqualToString:[good stringByAppendingString:@".bin"]], "name %s", p.lastPathComponent.UTF8String);
    ASSERT([p.stringByDeletingLastPathComponent.stringByStandardizingPath isEqualToString:root], "one level only");
}

static void testApiOutputPathIsInsideOutDir(void) {
    NSString *root = [OVPaths apiOut].stringByStandardizingPath;
    NSString *p = OVAPIOutputPath(@"3f2504e0-4f89-11d3-9a0c-0305e82c3301", @"m4a");
    ASSERT(p != nil && [p.stringByStandardizingPath hasPrefix:[root stringByAppendingString:@"/"]], "inside out/");
    ASSERT([p hasSuffix:@".m4a"], "extension");
    ASSERT(OVAPIOutputPath(@"../evil", @"wav") == nil, "dot-dot name");
    ASSERT(OVAPIOutputPath(@"a/b", @"wav") == nil, "slash name");
    ASSERT(OVAPIOutputPath(@"", @"wav") == nil, "empty name");
    ASSERT(OVAPIOutputPath(@"ok", @"sh") == nil, "extension outside the whitelist");
    ASSERT(OVAPIOutputPath(@"ok", @"wav/../../x") == nil, "extension with slashes");
    ASSERT(OVAPIOutputPath(@"ok", @"wav") != nil && OVAPIOutputPath(@"ok", @"flac") != nil, "wav and flac");
    ASSERT(OVAPIPathIsInsideOut([OVPaths.apiOut stringByAppendingPathComponent:@"x.wav"]), "inside");
    ASSERT(!OVAPIPathIsInsideOut([OVPaths.apiOut stringByAppendingPathComponent:@"../x.wav"]), "escape");
    ASSERT(!OVAPIPathIsInsideOut(OVPaths.apiOut), "the folder itself");
}

static void testBuildSynthRequestClampsAndWhitelists(void) {
    NSSet *voices = [NSSet setWithObjects:@"V-1", @"V-2", nil];
    NSArray *moods = @[@"neutral", @"calm", @"sad"];
    NSString *err = nil;
    NSDictionary *r = OVAPINormalizeSynth(@{@"text": @"  Привіт  ", @"voiceId": @"V-1", @"speed": @9.5, @"mood": @"calm",
                                            @"language": @"uk", @"format": @"m4a",
                                            @"cmd": @"rm", @"out": @"/etc/passwd", @"model": @{@"path": @"/x"}, @"uploadPath": @"/etc/hosts"},
                                          voices, moods, &err);
    ASSERT(r != nil && err == nil, "valid request rejected: %s", err.UTF8String);
    ASSERT([r[@"text"] isEqualToString:@"Привіт"], "text trimmed");
    ASSERT([r[@"voiceId"] isEqualToString:@"V-1"] && [r[@"mood"] isEqualToString:@"calm"], "voice/mood kept");
    ASSERT([r[@"speed"] doubleValue] == 2.0, "speed clamped to 2.0");
    ASSERT([r[@"format"] isEqualToString:@"m4a"] && [r[@"language"] isEqualToString:@"uk"], "format/language kept");
    NSSet *allowed = [NSSet setWithObjects:@"text", @"voiceId", @"language", @"mood", @"speed", @"format", nil];
    for (NSString *k in r) ASSERT([allowed containsObject:k], "foreign key survived: %s", k.UTF8String);
    ASSERT(!r[@"cmd"] && !r[@"out"] && !r[@"model"] && !r[@"uploadPath"], "keys of the client must not reach the worker request");

    r = OVAPINormalizeSynth(@{@"text": @"x", @"speed": @0.01, @"voice": @"V-2"}, voices, moods, &err);
    ASSERT(r && [r[@"speed"] doubleValue] == 0.5 && [r[@"voiceId"] isEqualToString:@"V-2"] && [r[@"format"] isEqualToString:@"wav"],
           "low speed clamps to 0.5, voice is an alias of voiceId, default format wav");

    err = nil;
    ASSERT(OVAPINormalizeSynth(@{@"text": @"x", @"voiceId": @"V-9"}, voices, moods, &err) == nil, "voice outside the catalog");
    ASSERT([err hasPrefix:@"rejected"], "error must say rejected: %s", err.UTF8String);
    err = nil;
    ASSERT(OVAPINormalizeSynth(@{@"text": @"x", @"voiceId": @"../../etc"}, voices, moods, &err) == nil && [err hasPrefix:@"rejected"], "path-like voice");
    err = nil;
    ASSERT(OVAPINormalizeSynth(@{@"text": @"   "}, voices, moods, &err) == nil && [err hasPrefix:@"rejected"], "empty text");
    err = nil;
    ASSERT(OVAPINormalizeSynth(@{@"text": @"x", @"mood": @"furious"}, voices, moods, &err) == nil && [err hasPrefix:@"rejected"], "unknown mood");
    err = nil;
    ASSERT(OVAPINormalizeSynth(@{@"text": @"x", @"format": @"exe"}, voices, moods, &err) == nil && [err hasPrefix:@"rejected"], "unknown format");
    err = nil;
    ASSERT(OVAPINormalizeSynth(@{@"text": @"x", @"language": @"../x"}, voices, moods, &err) == nil && [err hasPrefix:@"rejected"], "bad language");
    err = nil;
    ASSERT(OVAPINormalizeSynth(@{@"text": @42}, voices, moods, &err) == nil && [err hasPrefix:@"rejected"], "non-string text");
    err = nil;
    NSString *huge = [@"" stringByPaddingToLength:20001 withString:@"a" startingAtIndex:0];
    ASSERT(OVAPINormalizeSynth(@{@"text": huge}, voices, moods, &err) == nil && [err hasPrefix:@"rejected"], "text over 20000 characters");
    err = nil;
    ASSERT(OVAPINormalizeSynth(@{@"text": @"x", @"speed": @"fast"}, voices, moods, &err) == nil && [err hasPrefix:@"rejected"], "non-numeric speed");
}

static void testCloneAndConvertAreWhitelisted(void) {
    NSString *err = nil;
    NSString *uid = @"3f2504e0-4f89-11d3-9a0c-0305e82c3301";
    NSDictionary *c = OVAPINormalizeClone(@{@"name": @" Anna ", @"uploadId": uid, @"consent": @YES, @"ref_text": @"hi", @"language": @"uk",
                                            @"out": @"/etc/x"}, &err);
    ASSERT(c && [c[@"name"] isEqualToString:@"Anna"] && [c[@"uploadId"] isEqualToString:uid] && !c[@"out"], "clone: %s", err.UTF8String);
    ASSERT(OVAPINormalizeClone(@{@"name": @"A", @"uploadId": uid}, &err) == nil, "clone without consent");
    ASSERT(OVAPINormalizeClone(@{@"name": @"A", @"uploadId": @"../x", @"consent": @YES}, &err) == nil, "clone with a path as uploadId");
    NSDictionary *v = OVAPINormalizeConvert(@{@"uploadId": uid, @"model": @"m1", @"params": @{@"pitch": @99, @"index_rate": @-1, @"f0_method": @"rmvpe", @"evil": @1}},
                                            [NSSet setWithObject:@"m1"], [NSSet set], &err);
    ASSERT(v != nil, "convert: %s", err.UTF8String);
    ASSERT([v[@"params"][@"pitch"] doubleValue] == 24 && [v[@"params"][@"index_rate"] doubleValue] == 0 && !v[@"params"][@"evil"], "convert params clamp");
    ASSERT(OVAPINormalizeConvert(@{@"uploadId": uid, @"model": @"zz"}, [NSSet setWithObject:@"m1"], [NSSet set], &err) == nil, "unknown model");
}

int main(void) {
    @autoreleasepool {
        testNewKeyFormatAndUniqueness();
        testUploadPathRejectsBadIds();
        testUploadPathStaysInsideUploadsDir();
        testApiOutputPathIsInsideOutDir();
        testBuildSynthRequestClampsAndWhitelists();
        testCloneAndConvertAreWhitelisted();
    }
    if (gFailures) { fprintf(stderr, "%d failure(s)\n", gFailures); return 1; }
    printf("api_test: ok\n");
    return 0;
}
