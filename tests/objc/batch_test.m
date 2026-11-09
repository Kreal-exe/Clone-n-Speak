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
@property NSMutableArray *requests;
@end
@implementation StubSynth
- (void)synthesize:(NSDictionary *)req progress:(void (^)(double))progress done:(void (^)(NSDictionary *, NSString *))done {
    [self.requests addObject:req];
    NSInteger n = ++self.count;
    dispatch_async(dispatch_get_main_queue(), ^{
        progress(0.5);
        if ([self.failing containsObject:@(n)]) { done(nil, @"synthesis failed"); }
        else { WriteWav(req[@"out"]); done(@{@"path": req[@"out"], @"seconds": @0.1}, nil); }
        if (self.afterItem) self.afterItem(n);
    });
}
- (void)stop { self.stops++; }
@end

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
    OVBatchRegisterOn(jobs, ^id<OVBatchSynth>{ return stub; });
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
    ASSERT(stub.stops >= 1);
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
    }
    if (gFailures) { fprintf(stderr, "%d failure(s)\n", gFailures); return 1; }
    printf("batch_test: all passed\n");
    return 0;
}
