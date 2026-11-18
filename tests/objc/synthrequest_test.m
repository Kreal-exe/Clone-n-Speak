// deps: OVStore.m OVPaths.m OVModels.m OVDownloader.m OVRuntime.m OVLocale.m OVMemory.m OVWorker.m OVNetwork.m OVJobs.m OVJobStore.m
#import <Foundation/Foundation.h>
#import "OVStore.h"

static int gFailures = 0;
#define ASSERT(cond, ...) do { if (!(cond)) { gFailures++; \
    fprintf(stderr, "FAIL %s:%d  %s  -- %s\n", __FILE__, __LINE__, #cond, [[NSString stringWithFormat:@"" __VA_ARGS__] UTF8String]); } } while (0)

static void testChainOmittedWhenEmpty(void) {
    NSMutableDictionary *req = [@{@"cmd": @"synth", @"out": @"/tmp/a/take.wav"} mutableCopy];
    OVSynthApplyChain(req, @[], @"/tmp/a/take.wav");
    ASSERT(req[@"chain"] == nil && req[@"dry_out"] == nil, "%@", req);
    OVSynthApplyChain(req, nil, @"/tmp/a/take.wav");
    ASSERT(req[@"chain"] == nil && req[@"dry_out"] == nil, "%@", req);
    ASSERT(req.count == 2);
}

static void testDryOutNextToResult(void) {
    NSArray *chain = @[@{@"type": @"reverb", @"on": @YES, @"params": @{@"wet": @0.3}}];
    NSMutableDictionary *req = [@{@"cmd": @"synth", @"out": @"/tmp/a/2026-11-09 10.00.00 Hi.wav"} mutableCopy];
    OVSynthApplyChain(req, chain, req[@"out"]);
    ASSERT([req[@"chain"] isEqualToArray:chain]);
    ASSERT([req[@"dry_out"] isEqualToString:@"/tmp/a/2026-11-09 10.00.00 Hi.dry.wav"], "%@", req[@"dry_out"]);
    ASSERT([OVDryPathForOutput(@"/x/y.wav") isEqualToString:@"/x/y.dry.wav"]);
    ASSERT([OVDryPathForOutput(@"/x/a.b.wav") isEqualToString:@"/x/a.b.dry.wav"]);
}

static void testStyleRoundTrip(void) {
    NSString *domain = NSBundle.mainBundle.bundleIdentifier ?: NSProcessInfo.processInfo.processName;   // the test binary's own defaults domain
    [NSUserDefaults.standardUserDefaults removePersistentDomainForName:domain];
    [OVSettings registerDefaults];
    NSDictionary *style = @{@"intonation": @0.4, @"energy": @-0.2, @"pitch": @1.5, @"tone": @0.1, @"pauses": @1.2, @"volume": @3};
    [OVSettings applyStyle:style];
    ASSERT([[OVSettings currentStyle] isEqualToDictionary:style], "%@", [OVSettings currentStyle]);
    ASSERT([OVSettings.generationParams[@"style"] isEqualToDictionary:style]);
    ASSERT([[OVSettings exportFormatId] isEqualToString:@"wav"]);
    ASSERT([OVSettings exportQuality] == -1);
    [NSUserDefaults.standardUserDefaults removePersistentDomainForName:domain];
}

int main(void) {
    @autoreleasepool {
        testChainOmittedWhenEmpty();
        testDryOutNextToResult();
        testStyleRoundTrip();
    }
    if (gFailures) { fprintf(stderr, "%d failure(s)\n", gFailures); return 1; }
    printf("synthrequest_test: ok\n");
    return 0;
}
