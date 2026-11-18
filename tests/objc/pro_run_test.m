// deps: OVProRunPlan.m OVJobStore.m OVJobs.m OVPaths.m OVLocale.m
// Prints "PASS <name>" or "FAIL <name>" per case; tests/test_pro_run.py maps each case to a Python test.
#import <Foundation/Foundation.h>
#import "OVProRunPlan.h"
#import "OVJobs.h"

static NSString *gCase;
static int gFailures = 0, gCaseFailures = 0;
#define ASSERT(cond, ...) do { if (!(cond)) { gCaseFailures++; fprintf(stderr, "FAIL %s:%d  %s  ", gCase.UTF8String, __LINE__, #cond); \
    fprintf(stderr, "" __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static const unsigned long long GB = 1ULL << 30;

static BOOL waitUntil(NSTimeInterval timeout, BOOL (^cond)(void)) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!cond()) {
        if ([end timeIntervalSinceNow] <= 0) return NO;
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return YES;
}

/// A host that writes what it is asked into a journal.
@interface FakeHost : NSObject <OVProRunHost>
@property NSMutableArray<NSString *> *log;
@property double gb;
@property BOOL confirmAnswer, networkAnswer, lowFreeAnswer;
@property unsigned long long avail, reclaim;
@property unsigned long long askedNeed, askedAvail;
@property int asks;
@property BOOL submittedReduced;
@end
@implementation FakeHost
- (instancetype)init {
    if ((self = [super init])) { _log = [NSMutableArray array]; _gb = 16; _confirmAnswer = YES; _networkAnswer = YES; _avail = 12 * GB; }
    return self;
}
- (double)physicalMemoryGB { return _gb; }
- (BOOL)confirmLowMemory { [_log addObject:[NSString stringWithFormat:@"confirm(%.0f GB)", _gb]]; return _confirmAnswer; }
- (void)unloadMainModels { [_log addObject:@"unload"]; _avail += _reclaim; _reclaim = 0; }
- (unsigned long long)availableBytes { [_log addObject:@"memory"]; return _avail; }
- (unsigned long long)reclaimableBytes { return _reclaim; }
- (BOOL)askLowFreeNeed:(unsigned long long)need available:(unsigned long long)avail {
    [_log addObject:@"askLowFree"]; _asks++; _askedNeed = need; _askedAvail = avail; return _lowFreeAnswer;
}
- (void)requestNetwork:(void (^)(BOOL))done { [_log addObject:@"network?"]; done(_networkAnswer); }
- (void)submitReducedBatch:(BOOL)reduced { [_log addObject:@"submit"]; _submittedReduced = reduced; }
- (NSInteger)indexOf:(NSString *)s { return (NSInteger)[_log indexOfObject:s]; }
- (NSInteger)lastIndexOf:(NSString *)s { return (NSInteger)[_log indexOfObjectWithOptions:NSEnumerationReverse passingTest:^BOOL(NSString *o, NSUInteger i, BOOL *st) { return [o isEqualToString:s]; }]; }
@end

static OVProRunOutcome run(OVProRunPlan *plan, FakeHost *h) {
    __block OVProRunOutcome out = OVProRunDeclined;
    __block BOOL called = NO;
    [plan executeWithHost:h completion:^(OVProRunOutcome o, BOOL r) { out = o; called = YES; }];
    ASSERT(called);
    return out;
}

static OVProRunPlan *heavyPlan(double peakGB, double reducedGB, BOOL net) {
    return [OVProRunPlan planWithPeakBytes:(unsigned long long)(peakGB * GB) reducedPeakBytes:(unsigned long long)(reducedGB * GB) needsNetwork:net heavy:YES];
}

static void testUnloadsMainModelsFirst(void) {
    FakeHost *h = [FakeHost new];
    h.gb = 8; h.reclaim = 2 * GB; h.avail = 9 * GB;
    OVProRunPlan *p = [OVProRunPlan planWithPeakBytes:(unsigned long long)(3.4 * GB) reducedPeakBytes:0 needsNetwork:YES heavy:YES];
    ASSERT(run(p, h) == OVProRunSubmitted);
    NSInteger net = [h indexOf:@"network?"], conf = [h indexOf:@"confirm(8 GB)"], un = [h indexOf:@"unload"],
              mem = [h lastIndexOf:@"memory"], sub = [h indexOf:@"submit"];
    ASSERT(net == 0 && conf == 1, "%s", [h.log componentsJoinedByString:@","].UTF8String);
    ASSERT(un > conf, "unload after the confirmation");
    ASSERT(mem > un, "the memory is read again after the unload");
    ASSERT(sub > mem && sub == (NSInteger)h.log.count - 1, "submit is last");
    ASSERT(h.asks == 0);
}

static void testDeclinedKeepsModelsLoaded(void) {
    FakeHost *h = [FakeHost new];
    h.gb = 8; h.confirmAnswer = NO;
    ASSERT(run(heavyPlan(3.4, 0, NO), h) == OVProRunDeclined);
    ASSERT([h indexOf:@"unload"] == NSNotFound && [h indexOf:@"submit"] == NSNotFound, "declined confirm");

    // not enough memory even after what the unload would free, and the user says no
    h = [FakeHost new];
    h.avail = 2 * GB; h.reclaim = 1 * GB; h.lowFreeAnswer = NO;
    ASSERT(run(heavyPlan(6.6, 0, NO), h) == OVProRunDeclined);
    ASSERT(h.asks == 1);
    ASSERT([h indexOf:@"unload"] == NSNotFound && [h indexOf:@"submit"] == NSNotFound, "declined low memory: %s", [h.log componentsJoinedByString:@","].UTF8String);
}

static void test16GBSkipsConfirmButUnloads(void) {
    FakeHost *h = [FakeHost new];
    h.gb = 16;
    ASSERT(run(heavyPlan(3.4, 0, NO), h) == OVProRunSubmitted);
    ASSERT([h indexOf:@"confirm(16 GB)"] == NSNotFound);
    ASSERT([h indexOf:@"unload"] != NSNotFound && [h indexOf:@"unload"] < [h indexOf:@"submit"]);
    h = [FakeHost new];
    h.gb = 32;
    run(heavyPlan(3.4, 0, NO), h);
    ASSERT([h indexOf:@"unload"] != NSNotFound);
    for (NSString *s in h.log) ASSERT(![s hasPrefix:@"confirm"]);
}

static void testLowMemoryWarnsWithNumbers(void) {
    FakeHost *h = [FakeHost new];
    h.avail = 3 * GB; h.reclaim = 0; h.lowFreeAnswer = YES;
    ASSERT(run(heavyPlan(6.5, 0, NO), h) == OVProRunSubmitted);
    ASSERT(h.asks == 1, "asked once, not again after the unload: %d", h.asks);
    ASSERT(h.askedNeed == (unsigned long long)((double)(unsigned long long)(6.5 * GB) * 1.15), "need = peak x 1.15");
    ASSERT(h.askedAvail == 3 * GB);
    ASSERT([h indexOf:@"unload"] < [h indexOf:@"submit"]);
    ASSERT(!h.submittedReduced);
}

static void testTrainFallsBackToBatch2(void) {
    FakeHost *h = [FakeHost new];
    h.avail = 10 * GB;   // 10 GB x 1.15 = 11.5 does not fit, 8.2 x 1.15 = 9.43 does
    ASSERT(run(heavyPlan(10.0, 8.2, NO), h) == OVProRunSubmitted);
    ASSERT(h.asks == 0 && h.submittedReduced, "batch 2 without a question");
    h = [FakeHost new];
    h.avail = 12 * GB;
    ASSERT(run(heavyPlan(10.0, 8.2, NO), h) == OVProRunSubmitted);
    ASSERT(h.asks == 0 && !h.submittedReduced, "the full run when it fits");
    h = [FakeHost new];
    h.avail = 5 * GB; h.lowFreeAnswer = NO;
    ASSERT(run(heavyPlan(10.0, 8.2, NO), h) == OVProRunDeclined);
    ASSERT(h.asks == 1 && h.askedNeed == (unsigned long long)((double)(unsigned long long)(8.2 * GB) * 1.15), "the question is about the lighter run");
}

static void testOfflineBlocksEdgeAndYouTubeFirst(void) {
    FakeHost *h = [FakeHost new];
    h.gb = 8; h.networkAnswer = NO;
    OVProRunPlan *p = [OVProRunPlan planWithPeakBytes:0 reducedPeakBytes:0 needsNetwork:YES heavy:NO];
    ASSERT(run(p, h) == OVProRunDeclined);
    ASSERT(h.log.count == 1 && [h.log[0] isEqual:@"network?"], "%s", [h.log componentsJoinedByString:@","].UTF8String);
    // the same on a heavy plan: nothing happens before the network answer
    h = [FakeHost new];
    h.networkAnswer = NO;
    ASSERT(run(heavyPlan(3.4, 0, YES), h) == OVProRunDeclined);
    ASSERT(h.log.count == 1);
    // network features are not heavy: no confirmation, no unload
    h = [FakeHost new];
    h.gb = 8;
    ASSERT(run(p, h) == OVProRunSubmitted);
    ASSERT(([h.log isEqualToArray:@[@"network?", @"submit"]]), "%s", [h.log componentsJoinedByString:@","].UTF8String);
}

static void testBeforeStartUnloadsWhenStartedFromQueue(void) {
    FakeHost *h = [FakeHost new];
    h.avail = 8 * GB;
    OVProRunPlan *p = heavyPlan(3.4, 0, NO);
    BOOL reduced = YES;
    ASSERT([p prepareToStartWithHost:h reduced:&reduced] && !reduced);
    ASSERT(([h.log isEqualToArray:@[@"unload", @"memory"]]), "%s", [h.log componentsJoinedByString:@","].UTF8String);
    // tight: asks (nobody agreed before), and a "no" fails the start
    h = [FakeHost new];
    h.avail = 1 * GB; h.lowFreeAnswer = NO;
    ASSERT(![p prepareToStartWithHost:h reduced:&reduced]);
    // the user already agreed when submitting: no second question
    h = [FakeHost new];
    h.avail = 1 * GB;
    p.lowFreeAccepted = YES;
    ASSERT([p prepareToStartWithHost:h reduced:&reduced] && h.asks == 0);
    // training from the queue: the lighter run
    h = [FakeHost new];
    h.avail = 10 * GB;
    ASSERT([heavyPlan(10.0, 8.2, NO) prepareToStartWithHost:h reduced:&reduced] && reduced);
}

static void testTwoProJobsNeverRunTogether(void) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"prorun-%u", arc4random()]];
    OVJobs *jobs = [OVJobs jobsWithRoot:dir];
    for (NSString *kind in @[@"pro_a", @"pro_b"]) {
        [jobs registerKind:kind lane:OVJobLaneCompute retryable:YES title:^NSString *(NSDictionary *r) { return kind; }
                   factory:OVProcessRunnerFactory(^OVProcessSpec *(OVJob *job) {
            OVProcessSpec *s = [OVProcessSpec new];
            s.executable = @"/bin/sh";
            s.arguments = @[@"-c", @"sleep 0.6; echo '{\"event\":\"result\",\"data\":{}}'"];
            s.environment = @{@"PATH": @"/usr/bin:/bin"};
            return s;
        }) onSuccess:nil];
    }
    OVJob *a = [jobs submitKind:@"pro_a" request:@{} origin:@"app" onFinish:nil error:nil];
    OVJob *b = [jobs submitKind:@"pro_b" request:@{} origin:@"app" onFinish:nil error:nil];
    ASSERT(a && b);
    ASSERT(waitUntil(5, ^BOOL{ return a.state == OVJobRunning; }));
    ASSERT(b.state == OVJobQueued, "the second pro job waits");
    ASSERT(waitUntil(5, ^BOOL{ return a.state == OVJobSucceeded; }));
    ASSERT(b.state == OVJobRunning || b.state == OVJobSucceeded, "and starts when the first ends");
    ASSERT(waitUntil(5, ^BOOL{ return b.state == OVJobSucceeded; }));
    ASSERT([a.finished timeIntervalSinceDate:b.started] <= 0.05, "b started only after a finished");
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
}

static void runCase(NSString *name, void (^body)(void)) {
    gCase = name; gCaseFailures = 0;
    @autoreleasepool { body(); }
    printf("%s %s\n", gCaseFailures ? "FAIL" : "PASS", name.UTF8String);
    if (gCaseFailures) gFailures++;
}

int main(void) {
    @autoreleasepool {
        runCase(@"test_pro_job_unloads_main_models_first", ^{ testUnloadsMainModelsFirst(); });
        runCase(@"test_declined_pro_run_keeps_models_loaded", ^{ testDeclinedKeepsModelsLoaded(); });
        runCase(@"test_16gb_mac_skips_confirm_but_still_unloads", ^{ test16GBSkipsConfirmButUnloads(); });
        runCase(@"test_low_memory_warns_with_numbers", ^{ testLowMemoryWarnsWithNumbers(); });
        runCase(@"test_train_falls_back_to_batch_2_when_tight", ^{ testTrainFallsBackToBatch2(); });
        runCase(@"test_offline_blocks_edge_and_youtube_before_anything", ^{ testOfflineBlocksEdgeAndYouTubeFirst(); });
        runCase(@"test_two_pro_jobs_never_run_together", ^{ testTwoProJobsNeverRunTogether(); });
        runCase(@"test_before_start_unloads_when_started_from_queue", ^{ testBeforeStartUnloadsWhenStartedFromQueue(); });
    }
    return gFailures ? 1 : 0;
}
