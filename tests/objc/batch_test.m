// deps: OVBatch.m OVJobs.m OVJobStore.m OVExport.m OVPaths.m OVLocale.m
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "OVBatch.h"
#import "OVJobs.h"
#import "OVJobStore.h"

static int gFailures = 0;
#define ASSERT(cond, ...) do { if (!(cond)) { gFailures++; \
    fprintf(stderr, "FAIL %s:%d  %s  -- %s\n", __func__, __LINE__, #cond, [[NSString stringWithFormat:@"" __VA_ARGS__] UTF8String]); } } while (0)

static BOOL waitUntil(NSTimeInterval timeout, BOOL (^cond)(void)) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!cond()) {
        if ([end timeIntervalSinceNow] <= 0) return NO;
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return YES;
}
static NSString *tempDir(void) {
    NSString *d = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"batch-test-%u", arc4random()]];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}
static BOOL exists(NSString *p) { return [NSFileManager.defaultManager fileExistsAtPath:p]; }

static void WriteWav(NSString *path) {
    NSDictionary *s = @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @24000, AVNumberOfChannelsKey: @1,
                        AVLinearPCMBitDepthKey: @16, AVLinearPCMIsFloatKey: @NO, AVLinearPCMIsBigEndianKey: @NO};
    AVAudioFile *f = [[AVAudioFile alloc] initForWriting:[NSURL fileURLWithPath:path] settings:s
                                            commonFormat:AVAudioPCMFormatFloat32 interleaved:NO error:nil];
    AVAudioPCMBuffer *b = [[AVAudioPCMBuffer alloc] initWithPCMFormat:f.processingFormat frameCapacity:2400];
    b.frameLength = 2400;
    for (int i = 0; i < 2400; i++) b.floatChannelData[0][i] = 0.3f * sinf(i * 0.1f);
    [f writeFromBuffer:b error:nil];
}

/// Writes a short WAV for every item; item indexes in `failing` answer with an error; `afterItem` runs after an item is done.
@interface StubSynth : NSObject <OVBatchSynth>
@property NSSet<NSNumber *> *failing;
@property (copy) void (^afterItem)(NSInteger count);
@property NSInteger count, stops;
@property BOOL stopped;
@property BOOL hold;                       // keep `done` until -release
@property (copy) void (^pending)(void);
@property NSMutableArray *requests;
@end
@implementation StubSynth
- (void)synthesize:(NSDictionary *)req progress:(void (^)(double))progress done:(void (^)(NSDictionary *, NSString *))done {
    [self.requests addObject:req];
    NSInteger n = ++self.count;
    void (^go)(void) = ^{
        progress(0.5);
        if (self.stopped) { done(nil, @"Stopped"); return; }
        if ([self.failing containsObject:@(n)]) { done(nil, @"synthesis failed"); }
        else { WriteWav(req[@"out"]); done(@{@"path": req[@"out"], @"seconds": @0.1}, nil); }
        if (self.afterItem) self.afterItem(n);
    };
    if (self.hold) { self.pending = go; return; }
    dispatch_async(dispatch_get_main_queue(), go);
}
- (void)stop {
    self.stops++; self.stopped = YES;
    if (self.pending) { void (^g)(void) = self.pending; self.pending = nil; dispatch_async(dispatch_get_main_queue(), g); }
}
@end

@interface StubEnv : NSObject <OVBatchEnvironment>
@property StubSynth *synth;
@property (copy) NSString *history;
@property BOOL voiceMissing;
@property NSMutableArray *recorded;
@end
@implementation StubEnv
- (NSDictionary *)modelSpec { return @{@"path": @"m"}; }
- (NSDictionary *)generationParams { return @{}; }
- (NSDictionary *)voiceSpecForId:(NSString *)v language:(NSString *)l { return self.voiceMissing ? nil : @{@"audio": v}; }
- (NSString *)identifierOfVoice:(OVVoice *)v { return @"v1"; }
- (NSDictionary *)presetFields:(OVPreset *)p { return @{@"identifier": @"p1", @"formatId": @"ogg", @"quality": @0}; }
- (NSString *)historyFolder { return self.history; }
- (void)recordHistoryPath:(NSString *)p text:(NSString *)t voiceId:(NSString *)v result:(NSDictionary *)r { [self.recorded addObject:p]; }
- (id<OVBatchSynth>)makeSynth { return self.synth; }
@end

static StubEnv *gEnv;

static NSArray *items(NSInteger n) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSInteger i = 1; i <= n; i++)
        [a addObject:@{@"index": @(i), @"text": [NSString stringWithFormat:@"text %ld", (long)i], @"name": [NSString stringWithFormat:@"%03ld-a.wav", (long)i]}];
    return a;
}

static OVJob *run(OVJobs *jobs, NSDictionary *req, BOOL wait) {
    OVJob *job = [jobs submitKind:OVJobKindBatch request:req origin:@"app" onFinish:nil error:nil];
    if (wait) waitUntil(20, ^BOOL{ return !job.active; });
    return job;
}
static NSDictionary *request(NSInteger n, NSString *out) { return OVBatchRequest(items(n), nil, @"auto", nil, out); }
static OVJobs *makeJobs(StubSynth *stub) {
    OVJobs *jobs = [OVJobs jobsWithRoot:tempDir()];
    gEnv = [StubEnv new];
    gEnv.synth = stub;
    gEnv.recorded = [NSMutableArray array];
    OVBatchRegisterOn(jobs, gEnv);
    return jobs;
}
static StubSynth *newStub(void) { StubSynth *s = [StubSynth new]; s.requests = [NSMutableArray array]; return s; }

static void testAllItemsWritten(void) {
    StubSynth *stub = newStub(); OVJobs *jobs = makeJobs(stub);
    NSString *out = [tempDir() stringByAppendingPathComponent:@"o"];
    OVJob *job = run(jobs, request(3, out), YES);
    ASSERT(job.state == OVJobSucceeded, @"state %ld err %@", (long)job.state, job.error);
    ASSERT([job.result[@"done"] integerValue] == 3);
    ASSERT([job.result[@"failed"] integerValue] == 0);
    for (NSString *n in @[@"001-a.wav", @"002-a.wav", @"003-a.wav"]) ASSERT(exists([out stringByAppendingPathComponent:n]), "%@", n);
    ASSERT(job.outputs.count == 3);
    ASSERT(job.progress >= 0.99, "progress %f", job.progress);
}

static void testStopBetweenItems(void) {
    StubSynth *stub = newStub(); OVJobs *jobs = makeJobs(stub);
    NSString *out = [tempDir() stringByAppendingPathComponent:@"o"];
    __block OVJob *job = nil;
    stub.afterItem = ^(NSInteger n) { if (n == 1) [jobs stop:job]; };
    job = run(jobs, request(3, out), NO);
    waitUntil(20, ^BOOL{ return !job.active; });
    ASSERT(job.state == OVJobStopped, "state %ld", (long)job.state);
    NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:out error:nil];
    ASSERT([files containsObject:@"001-a.wav"] && files.count == 1, "%@", files);
    for (NSString *f in files) ASSERT(![f hasSuffix:@".part"]);
    ASSERT(!exists(job.workDirectory), "work directory remains");
    ASSERT(stub.stops == 0, "the worker must not be stopped while idle: %ld", (long)stub.stops);
    ASSERT(stub.count == 1);
}

static void testItemErrorContinues(void) {
    StubSynth *stub = newStub(); stub.failing = [NSSet setWithObject:@2]; OVJobs *jobs = makeJobs(stub);
    NSString *out = [tempDir() stringByAppendingPathComponent:@"o"];
    OVJob *job = run(jobs, request(3, out), YES);
    ASSERT(job.state == OVJobSucceeded, "state %ld", (long)job.state);
    ASSERT([job.result[@"done"] integerValue] == 2 && [job.result[@"failed"] integerValue] == 1);
    NSArray *errs = job.result[@"errors"];
    ASSERT(errs.count == 1 && [errs[0][@"index"] integerValue] == 2);
    ASSERT(!exists([out stringByAppendingPathComponent:@"002-a.wav"]));
    ASSERT(exists([out stringByAppendingPathComponent:@"003-a.wav"]));
}

static void testAllFail(void) {
    StubSynth *stub = newStub(); stub.failing = [NSSet setWithObjects:@1, @2, nil]; OVJobs *jobs = makeJobs(stub);
    OVJob *job = run(jobs, request(2, [tempDir() stringByAppendingPathComponent:@"o"]), YES);
    ASSERT(job.state == OVJobFailed, "state %ld", (long)job.state);
    ASSERT([job.error containsString:@"synthesis failed"] && [job.error containsString:@"start again"], "%@", job.error);
}

static void testSkipExisting(void) {
    StubSynth *stub = newStub(); OVJobs *jobs = makeJobs(stub);
    NSString *out = tempDir();
    NSString *mine = [out stringByAppendingPathComponent:@"002-a.wav"];
    [@"mine" writeToFile:mine atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSMutableDictionary *req = [request(3, out) mutableCopy];
    req[@"skipExisting"] = @YES;
    OVJob *job = run(jobs, req, YES);
    ASSERT(job.state == OVJobSucceeded);
    ASSERT([job.result[@"done"] integerValue] == 2 && [job.result[@"skipped"] integerValue] == 1);
    ASSERT([[NSString stringWithContentsOfFile:mine encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"mine"]);
    ASSERT(stub.count == 2);
}

static void testOutDirCreated(void) {
    StubSynth *stub = newStub(); OVJobs *jobs = makeJobs(stub);
    NSString *out = [[tempDir() stringByAppendingPathComponent:@"a"] stringByAppendingPathComponent:@"b/c"];
    OVJob *job = run(jobs, request(1, out), YES);
    ASSERT(job.state == OVJobSucceeded);
    ASSERT(exists([out stringByAppendingPathComponent:@"001-a.wav"]));
}

static void testRetryRebuildsRequest(void) {
    StubSynth *stub = newStub(); stub.failing = [NSSet setWithObjects:@1, nil]; OVJobs *jobs = makeJobs(stub);
    NSDictionary *req = request(1, [tempDir() stringByAppendingPathComponent:@"o"]);
    OVJob *job = run(jobs, req, YES);
    ASSERT(job.state == OVJobFailed);
    OVJob *again = [jobs retry:job];
    ASSERT(again != nil && [again.retryOf isEqualToString:job.identifier]);
    ASSERT([again.request isEqualToDictionary:job.request]);
    waitUntil(20, ^BOOL{ return !again.active; });
    ASSERT(again.state == OVJobSucceeded, "state %ld", (long)again.state);
}

static void testNameCollisionWithExistingFile(void) {
    StubSynth *stub = newStub(); OVJobs *jobs = makeJobs(stub);
    NSString *out = tempDir();
    NSString *mine = [out stringByAppendingPathComponent:@"001-a.wav"];
    [@"mine" writeToFile:mine atomically:YES encoding:NSUTF8StringEncoding error:nil];
    OVJob *job = run(jobs, request(1, out), YES);
    ASSERT(job.state == OVJobSucceeded);
    ASSERT(exists([out stringByAppendingPathComponent:@"001-a 2.wav"]));
    ASSERT([[NSString stringWithContentsOfFile:mine encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"mine"]);
}

static void testStopWhileSynthesizing(void) {
    StubSynth *stub = newStub(); stub.hold = YES; OVJobs *jobs = makeJobs(stub);
    NSString *out = [tempDir() stringByAppendingPathComponent:@"o"];
    OVJob *job = run(jobs, request(2, out), NO);
    waitUntil(5, ^BOOL{ return stub.pending != nil; });
    [jobs stop:job];
    waitUntil(20, ^BOOL{ return !job.active; });
    ASSERT(job.state == OVJobStopped, "state %ld", (long)job.state);
    ASSERT(stub.stops == 1 && stub.count == 1);
}

static void testMissingVoiceFails(void) {
    StubSynth *stub = newStub(); OVJobs *jobs = makeJobs(stub);
    gEnv.voiceMissing = YES;
    NSMutableDictionary *req = [request(2, [tempDir() stringByAppendingPathComponent:@"o"]) mutableCopy];
    req[@"voice"] = @"gone";
    OVJob *job = run(jobs, req, YES);
    ASSERT(job.state == OVJobFailed && [job.error containsString:@"no longer available"], "%@", job.error);
    ASSERT(stub.count == 0);
}

static void testVoiceSpecPassed(void) {
    StubSynth *stub = newStub(); OVJobs *jobs = makeJobs(stub);
    NSMutableDictionary *req = [request(1, [tempDir() stringByAppendingPathComponent:@"o"]) mutableCopy];
    req[@"voice"] = @"v1";
    OVJob *job = run(jobs, req, YES);
    ASSERT(job.state == OVJobSucceeded);
    ASSERT([stub.requests.firstObject[@"voice"][@"audio"] isEqualToString:@"v1"]);
}

static void testHistoryOnlyInOutputsFolder(void) {
    StubSynth *stub = newStub(); OVJobs *jobs = makeJobs(stub);
    NSString *outputs = [tempDir() stringByAppendingPathComponent:@"outputs"];
    gEnv.history = outputs;
    run(jobs, request(2, outputs), YES);
    ASSERT(gEnv.recorded.count == 2, "%lu", (unsigned long)gEnv.recorded.count);
    [gEnv.recorded removeAllObjects];
    run(jobs, request(2, [tempDir() stringByAppendingPathComponent:@"elsewhere"]), YES);
    ASSERT(gEnv.recorded.count == 0);
    NSMutableDictionary *req = [request(1, [tempDir() stringByAppendingPathComponent:@"outputs"]) mutableCopy];
    req[@"outDir"] = outputs; req[@"format"] = @"m4a";
    run(jobs, req, YES);
    ASSERT(gEnv.recorded.count == 0, "only WAV files are recorded");
}

static void testManySkippedNoRecursion(void) {
    StubSynth *stub = newStub(); OVJobs *jobs = makeJobs(stub);
    NSString *out = tempDir();
    NSArray *its = items(3000);
    for (NSDictionary *it in its) [@"x" writeToFile:[out stringByAppendingPathComponent:it[@"name"]] atomically:NO encoding:NSUTF8StringEncoding error:nil];
    NSMutableDictionary *req = [OVBatchRequest(its, nil, @"auto", nil, out) mutableCopy];
    req[@"skipExisting"] = @YES;
    OVJob *job = run(jobs, req, YES);
    ASSERT(job.state == OVJobSucceeded && [job.result[@"skipped"] integerValue] == 3000);
}

static void testPresetFormatAndQuality(void) {
    StubSynth *stub = newStub(); makeJobs(stub);
    NSDictionary *r = OVBatchRequest(items(1), nil, @"auto", (OVPreset *)@"p", @"/x");
    ASSERT([r[@"format"] isEqualToString:@"ogg"] && [r[@"quality"] integerValue] == -1 && [r[@"preset"] isEqualToString:@"p1"]);
    ASSERT(OVBatchRequest(items(1), nil, @"auto", nil, @"/x")[@"format"] == nil);
}

int main(void) {
    @autoreleasepool {
        testAllItemsWritten();
        testStopBetweenItems();
        testItemErrorContinues();
        testAllFail();
        testSkipExisting();
        testOutDirCreated();
        testRetryRebuildsRequest();
        testNameCollisionWithExistingFile();
        testStopWhileSynthesizing();
        testMissingVoiceFails();
        testVoiceSpecPassed();
        testHistoryOnlyInOutputsFolder();
        testManySkippedNoRecursion();
        testPresetFormatAndQuality();
    }
    if (gFailures) { fprintf(stderr, "%d failure(s)\n", gFailures); return 1; }
    printf("batch_test: all passed\n");
    return 0;
}
