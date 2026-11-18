// deps: OVToolsModel.m
#import <Foundation/Foundation.h>
#import "OVToolsModel.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL %s:%d  ", __func__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void testChainRequestShape(void) {
    NSArray *chain = @[@{@"type": @"gain", @"on": @YES, @"params": @{@"db": @3}},
                       @{@"type": @"reverb", @"on": @NO, @"params": @{@"mix": @0.3}},
                       @{@"type": @"eq", @"on": @YES, @"params": @{}}];
    NSDictionary *r = [OVToolsModel effectsRequestWithAudio:@"/a.wav" out:@"/o.wav" chain:chain];
    NSDictionary *want = @{@"cmd": @"fx_apply", @"audio": @"/a.wav", @"out": @"/o.wav",
                           @"chain": @[chain[0], chain[2]]};
    CHECK([r isEqualToDictionary:want], "fx_apply without the effects that are off: %s", r.description.UTF8String);
    CHECK([OVToolsModel chainHasActiveEffects:chain], "active");
    CHECK(![OVToolsModel chainHasActiveEffects:@[chain[1]]], "all off");
    CHECK(![OVToolsModel chainHasActiveEffects:@[]], "empty");
}

static void testDFNRequiresInstall(void) {
    NSDictionary *p = [OVToolsModel dfnPlanInstalled:NO audio:@"/a.wav" out:@"/o.wav" strengthDB:12];
    CHECK([p[@"action"] isEqual:@"download"] && p[@"request"] == nil, "not installed -> download, no request");
    p = [OVToolsModel dfnPlanInstalled:YES audio:@"/a.wav" out:@"/o.wav" strengthDB:99];
    NSDictionary *want = @{@"cmd": @"dfn_apply", @"audio": @"/a.wav", @"out": @"/o.wav", @"strength_db": @30};
    CHECK([p[@"action"] isEqual:@"run"] && [p[@"request"] isEqualToDictionary:want], "installed -> dfn_apply, clamped to 30 dB");
    CHECK([[OVToolsModel lightCleanupRequestWithAudio:@"/a" out:@"/o"][@"cmd"] isEqual:@"enhance"], "light cleanup is enhance");
}

static void testFormantSteps(void) {
    CHECK([OVToolsModel formantStepsWithAudio:@"/a" out:@"/o" tmp:@"/t" ratio:1 semitones:0 keepCharacter:YES].count == 0, "neutral -> nothing");
    NSArray *s = [OVToolsModel formantStepsWithAudio:@"/a" out:@"/o" tmp:@"/t" ratio:1.2 semitones:0 keepCharacter:NO];
    CHECK(s.count == 1 && [s[0][@"cmd"] isEqual:@"formant_apply"] && [s[0][@"audio"] isEqual:@"/a"] && [s[0][@"out"] isEqual:@"/o"], "formant only");
    s = [OVToolsModel formantStepsWithAudio:@"/a" out:@"/o" tmp:@"/t" ratio:1 semitones:-3 keepCharacter:YES];
    CHECK(s.count == 1 && [s[0][@"cmd"] isEqual:@"pitch_apply"] && [s[0][@"preserve_formants"] boolValue] && [s[0][@"semitones"] doubleValue] == -3, "pitch only");
    s = [OVToolsModel formantStepsWithAudio:@"/a" out:@"/o" tmp:@"/t" ratio:0.8 semitones:2 keepCharacter:YES];
    CHECK(s.count == 2 && [s[0][@"out"] isEqual:@"/t"] && [s[1][@"audio"] isEqual:@"/t"] && [s[1][@"out"] isEqual:@"/o"], "both go through tmp");
    CHECK(fabs([OVToolsModel semitonesForRatio:2] - 12) < 1e-9 && fabs([OVToolsModel semitonesForRatio:0.5] + 12) < 1e-9, "ratio -> semitones");
}

static void testFormatsDisabledReason(void) {
    CHECK([OVToolsModel disabledReasonForFormat:(@{@"id": @"wav", @"available": @YES})] == nil, "available");
    NSString *r = [OVToolsModel disabledReasonForFormat:@{@"id": @"mp3", @"available": @NO, @"reason": @"Needs ffmpeg."}];
    CHECK([r isEqual:@"Needs ffmpeg."], "own reason");
    r = [OVToolsModel disabledReasonForFormat:@{@"id": @"ogg", @"available": @NO}];
    CHECK(r.length > 0, "default reason");
    CHECK([OVToolsModel qualityChoicesForFormatId:@"wav"].count == 0 && [OVToolsModel defaultQualityForFormatId:@"flac"] == -1, "lossless: no quality");
    CHECK([OVToolsModel defaultQualityForFormatId:@"mp3"] == 192 && [OVToolsModel defaultQualityForFormatId:@"ogg"] == 5, "defaults");
}

static void testPickedVideoGoesThroughDecode(void) {
    __block int calls = 0;
    __block NSString *seenSrc = nil;
    OVToolsDecoder dec = ^BOOL(NSString *src, NSString *dst, NSError **e) {
        calls++; seenSrc = src;
        return [@"RIFF" writeToFile:dst atomically:YES encoding:NSUTF8StringEncoding error:nil];
    };
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"tools-%u", arc4random()]];
    NSString *out = [OVToolsModel workerInputForPath:@"/x/clip.MOV" workDir:dir decoder:dec error:nil];
    CHECK(calls == 1 && [seenSrc isEqual:@"/x/clip.MOV"], ".mov is decoded once, before the worker");
    CHECK(out && [out hasPrefix:dir] && [out.pathExtension isEqual:@"wav"] && [NSFileManager.defaultManager fileExistsAtPath:out], "the worker gets the WAV");
    out = [OVToolsModel workerInputForPath:@"/x/voice.wav" workDir:dir decoder:dec error:nil];
    CHECK(calls == 1 && [out isEqual:@"/x/voice.wav"], "a WAV goes as it is");
    OVToolsDecoder bad = ^BOOL(NSString *s, NSString *d, NSError **e) {
        if (e) *e = [NSError errorWithDomain:@"x" code:1 userInfo:@{NSLocalizedDescriptionKey: @"No audio."}];
        return NO;
    };
    NSError *err = nil;
    CHECK([OVToolsModel workerInputForPath:@"/x/a.mp3" workDir:dir decoder:bad error:&err] == nil && err, "decode failure -> nil + error");
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
}

static void testLongFileWarning(void) {
    CHECK([OVToolsModel longFileWarningForSeconds:1201].length > 0, "1201 s warns");
    CHECK([OVToolsModel longFileWarningForSeconds:1200] == nil && [OVToolsModel longFileWarningForSeconds:30] == nil, "1200 s and shorter do not");
}

int main(void) {
    @autoreleasepool {
        testChainRequestShape(); testDFNRequiresInstall(); testFormantSteps(); testFormatsDisabledReason();
        testPickedVideoGoesThroughDecode(); testLongFileWarning();
    }
    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("toolsmodel_test: ok\n");
    return 0;
}
