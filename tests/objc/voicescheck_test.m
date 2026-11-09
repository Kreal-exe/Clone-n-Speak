// deps: OVVoiceCheck.m OVLocale.m
#import <Foundation/Foundation.h>
#import "OVVoiceCheck.h"

static int gFails = 0;
#define ASSERT(cond, ...) do { if (!(cond)) { gFails++; printf("FAIL %s:%d %s: ", __FILE__, __LINE__, #cond); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void testRegionsToTooltips(void) {
    NSString *s = OVRegionTooltip(@{@"start": @12.2, @"end": @13.9, @"kind": @"clipping", @"severity": @0.5});
    ASSERT([s isEqualToString:@"Clipping at 0:12–0:13"], "%s", s.UTF8String);
    s = OVRegionTooltip(@{@"start": @75.0, @"end": @140.0, @"kind": @"pause", @"severity": @0.2});
    ASSERT([s isEqualToString:@"Pause at 1:15–2:20"], "%s", s.UTF8String);
    s = OVRegionTooltip(@{@"start": @3.1, @"end": @3.8, @"kind": @"noise", @"severity": @0.2});
    ASSERT([s isEqualToString:@"Noise at 0:03"], "%s", s.UTF8String);
    s = OVRegionTooltip(@{@"start": @0, @"end": @9, @"kind": @"hum", @"severity": @0.4});
    ASSERT([s isEqualToString:@"Mains hum"], "%s", s.UTF8String);
}

static void testAdviceMapping(void) {
    ASSERT([OVAdviceInfo(@"trim_start")[@"button"] isEqualToString:@"Trim silence"], "trim_start");
    ASSERT([OVAdviceInfo(@"trim_end")[@"button"] isEqualToString:@"Trim silence"], "trim_end");
    ASSERT([OVAdviceInfo(@"denoise")[@"button"] isEqualToString:@"Denoise"], "denoise");
    ASSERT([OVAdviceInfo(@"denoise")[@"action"] isEqualToString:@"dfn"], "denoise action");
    ASSERT(OVAdviceInfo(@"clipping") != nil && OVAdviceInfo(@"clipping")[@"button"] == nil, "clipping has text only");
    ASSERT(OVAdviceInfo(@"nope") == nil, "unknown");
}

static void testEnhanceRequestModes(void) {
    NSString *act = @"x";
    NSDictionary *r = OVEnhanceRequest(@"light", 18, @"/a.wav", @"/b.wav", NO, &act);
    ASSERT([r[@"mode"] isEqualToString:@"light"] && act == nil, "light needs no engine");
    r = OVEnhanceRequest(@"dfn", 99, @"/a.wav", @"/b.wav", YES, &act);
    ASSERT([r[@"mode"] isEqualToString:@"dfn"] && [r[@"strength_db"] doubleValue] == 30 && [r[@"cmd"] isEqualToString:@"enhance"], "dfn clamps to 30");
    r = OVEnhanceRequest(@"dfn", -4, @"/a.wav", @"/b.wav", YES, &act);
    ASSERT([r[@"strength_db"] doubleValue] == 1, "dfn clamps to 1");
    r = OVEnhanceRequest(@"music", 12, @"/a.wav", @"/b.wav", YES, &act);
    ASSERT([r[@"mode"] isEqualToString:@"music"] && [r[@"out"] isEqualToString:@"/b.wav"] && [r[@"audio"] isEqualToString:@"/a.wav"], "music fields");
    r = OVEnhanceRequest(@"music", 12, @"/a.wav", @"/b.wav", NO, &act);
    ASSERT(r == nil && [act isEqualToString:@"download"], "music without engine -> download");
    r = OVEnhanceRequest(@"dfn", 12, @"/a.wav", @"/b.wav", NO, &act);
    ASSERT(r == nil && [act isEqualToString:@"download"], "dfn without binary -> download");
}

static void testCompareFlags(void) {
    NSDictionary *res = @{@"samples": @[@{@"rms_db": @-20, @"snr_db": @35}, @{@"rms_db": @-20, @"snr_db": @34},
                                         @{@"rms_db": @-32, @"snr_db": @12}],
                          @"pairs": @[@{@"a": @0, @"b": @1, @"duplicate": @YES}], @"median_rms_db": @-20};
    ASSERT([OVCompareFlags(res, 0) count] == 0, "first is clean");
    ASSERT([OVCompareFlags(res, 1) containsObject:@"Duplicate"], "duplicate");
    NSArray *f = OVCompareFlags(res, 2);
    ASSERT([f containsObject:@"Much quieter"] && [f containsObject:@"Noisier"], "outlier flags");
}

int main(void) {
    @autoreleasepool {
        testRegionsToTooltips(); testAdviceMapping(); testEnhanceRequestModes(); testCompareFlags();
        printf(gFails ? "voicescheck_test: %d FAILED\n" : "voicescheck_test: OK\n", gFails);
    }
    return gFails ? 1 : 0;
}
