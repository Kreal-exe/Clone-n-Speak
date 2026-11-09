// deps: OVJobStore.m OVJobs.m OVPaths.m OVLocale.m
#import <Foundation/Foundation.h>
#import <signal.h>
#import "OVJobs.h"
#import "OVJobStore.h"

static int gFailures = 0;
#define ASSERT(cond, ...) do { if (!(cond)) { gFailures++; fprintf(stderr, "FAIL %s:%d  %s  ", __func__, __LINE__, #cond); \
    fprintf(stderr, "" __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static BOOL waitUntil(NSTimeInterval timeout, BOOL (^cond)(void)) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!cond()) {
        if ([end timeIntervalSinceNow] <= 0) return NO;
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return YES;
}
static void spin(NSTimeInterval t) { waitUntil(t, ^BOOL{ return NO; }); }

static NSString *tempDir(void) {
    NSString *d = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"jobs-test-%u", arc4random()]];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}
static BOOL exists(NSString *p) { return [NSFileManager.defaultManager fileExistsAtPath:p]; }

/// A runner the test finishes by hand.
@interface ManualRunner : NSObject <OVJobRunner>
@property OVJobContext *ctx;
@property BOOL stopFails;   // answer stop with a failure, as a real runner does
@end
@implementation ManualRunner
- (void)start:(OVJob *)job context:(OVJobContext *)ctx { self.ctx = ctx; }
- (void)stop:(OVJob *)job { if (self.stopFails) [self.ctx failWithError:@"Stopped"]; }
@end

static NSMutableDictionary<NSString *, ManualRunner *> *gRunners;
static OVJobRunnerFactory manualFactory(BOOL stopFails) {
    return ^id<OVJobRunner>(OVJob *job) {
        ManualRunner *r = [ManualRunner new];
        r.stopFails = stopFails;
        gRunners[job.identifier] = r;
        return r;
    };
}
static void registerManual(OVJobs *jobs, NSString *kind, OVJobLane lane, BOOL retryable) {
    [jobs registerKind:kind lane:lane retryable:retryable title:^NSString *(NSDictionary *r) { return kind; }
               factory:manualFactory(YES) onSuccess:nil];
}

static OVJobRunnerFactory shellFactory(NSString *script, NSDictionary *env, NSArray *partials, double grace) {
    return OVProcessRunnerFactory(^OVProcessSpec *(OVJob *job) {
        OVProcessSpec *s = [OVProcessSpec new];
        s.executable = @"/bin/sh";
        s.arguments = @[@"-c", script];
        NSMutableDictionary *e = [@{@"PATH": @"/usr/bin:/bin", @"WORK": job.workDirectory} mutableCopy];
        [e addEntriesFromDictionary:env];
        s.environment = e;
        s.partialPaths = partials;
        if (grace > 0) s.killGrace = grace;
        return s;
    });
}

#pragma mark - Tests

static void testSubmitRunsFifoPerLane(void) {
    OVJobs *jobs = [OVJobs jobsWithRoot:tempDir()];
    gRunners = [NSMutableDictionary dictionary];
    registerManual(jobs, @"c", OVJobLaneCompute, NO);
    registerManual(jobs, @"n", OVJobLaneNetwork, NO);
    OVJob *c1 = [jobs submitKind:@"c" request:@{} origin:@"app" onFinish:nil error:nil];
    OVJob *c2 = [jobs submitKind:@"c" request:@{} origin:@"app" onFinish:nil error:nil];
    OVJob *n1 = [jobs submitKind:@"n" request:@{} origin:@"app" onFinish:nil error:nil];
    ASSERT(c1 && c2 && n1);
    ASSERT([OVJobStore isValidIdentifier:c1.identifier], "%s", c1.identifier.UTF8String);
    ASSERT(c1.state == OVJobRunning);
    ASSERT(c2.state == OVJobQueued);
    ASSERT(n1.state == OVJobRunning, "network runs next to compute");
    ASSERT(jobs.activeCount == 3);
    ASSERT([jobs.all.firstObject isEqual:n1], "newest first");
    __block BOOL finished = NO;
    [gRunners[c1.identifier].ctx succeedWithResult:@{@"path": @"/x"} outputs:@[]];
    ASSERT(waitUntil(2, ^BOOL{ return c1.state == OVJobSucceeded; }));
    ASSERT(c2.state == OVJobRunning, "the second compute job starts when the first ends");
    ASSERT(c1.finished != nil && [c1.result[@"path"] isEqual:@"/x"]);
    [gRunners[c2.identifier].ctx failWithError:@"boom"];
    ASSERT(waitUntil(2, ^BOOL{ return c2.state == OVJobFailed; }));
    ASSERT([c2.error isEqual:@"boom"]);
    ASSERT(n1.state == OVJobRunning);
    (void)finished;
    OVJob *none = [jobs submitKind:@"nope" request:@{} origin:@"app" onFinish:nil error:nil];
    NSString *err = nil;
    none = [jobs submitKind:@"nope" request:@{} origin:@"app" onFinish:nil error:&err];
    ASSERT(!none && err.length);
}

static void testOnSuccessAndOnFinishRunOnMain(void) {
    OVJobs *jobs = [OVJobs jobsWithRoot:tempDir()];
    gRunners = [NSMutableDictionary dictionary];
    __block int succ = 0, fin = 0;
    __block BOOL onMain = YES;
    [jobs registerKind:@"k" lane:OVJobLaneCompute retryable:NO title:^NSString *(NSDictionary *r) { return @"t"; }
               factory:manualFactory(NO) onSuccess:^(OVJob *j) { succ++; onMain = onMain && NSThread.isMainThread; }];
    OVJob *j = [jobs submitKind:@"k" request:@{} origin:@"api" onFinish:^(OVJob *x) { fin++; } error:nil];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{ [gRunners[j.identifier].ctx succeedWithResult:nil outputs:@[]]; });
    ASSERT(waitUntil(2, ^BOOL{ return fin == 1; }));
    ASSERT(succ == 1 && onMain);
    ASSERT(j.progress == 1);
}

static void testRemoteQueueLimit(void) {
    OVJobs *jobs = [OVJobs jobsWithRoot:tempDir()];
    gRunners = [NSMutableDictionary dictionary];
    registerManual(jobs, @"c", OVJobLaneCompute, NO);
    for (int i = 0; i < 8; i++) ASSERT([jobs submitKind:@"c" request:@{} origin:@"api" onFinish:nil error:nil] != nil);
    NSString *err = nil;
    ASSERT([jobs submitKind:@"c" request:@{} origin:@"bridge:dev1" onFinish:nil error:&err] == nil && err.length);
    ASSERT([jobs submitKind:@"c" request:@{} origin:@"app" onFinish:nil error:nil] != nil, "the app itself is not limited");
}

static void testStopProcessMidWork(void) {
    NSString *dir = tempDir(), *pidFile = [dir stringByAppendingPathComponent:@"pid"], *out = [dir stringByAppendingPathComponent:@"partial.wav"];
    OVJobs *jobs = [OVJobs jobsWithRoot:[dir stringByAppendingPathComponent:@"jobs"]];
    [jobs registerKind:@"p" lane:OVJobLaneCompute retryable:NO title:^NSString *(NSDictionary *r) { return @"p"; }
               factory:shellFactory(@"touch \"$WORK/a.tmp\"; echo partial > \"$OUT\"; sleep 30 & echo $! > \"$PIDF\"; wait",
                                    @{@"OUT": out, @"PIDF": pidFile}, @[out], 0)
             onSuccess:nil];
    OVJob *j = [jobs submitKind:@"p" request:@{} origin:@"app" onFinish:nil error:nil];
    ASSERT(waitUntil(5, ^BOOL{ return [[NSString stringWithContentsOfFile:pidFile encoding:NSUTF8StringEncoding error:nil] intValue] > 0
                                   && exists([j.workDirectory stringByAppendingPathComponent:@"a.tmp"]) && exists(out); }), "the process started");
    int sleepPid = [[NSString stringWithContentsOfFile:pidFile encoding:NSUTF8StringEncoding error:nil] intValue];
    ASSERT(sleepPid > 0 && kill(sleepPid, 0) == 0);
    spin(0.3);
    [jobs stop:j];
    ASSERT(waitUntil(6, ^BOOL{ return j.state == OVJobStopped; }), "state %ld", (long)j.state);
    ASSERT(j.finished != nil);
    ASSERT(!exists(j.workDirectory), "work/ is gone");
    ASSERT(!exists(out), "partial file is gone");
    ASSERT([j.logText containsString:@"Stopped by user"], "%s", j.logText.UTF8String);
    ASSERT(waitUntil(2, ^BOOL{ return kill(sleepPid, 0) != 0 && errno == ESRCH; }), "the child process is dead");
    ASSERT(jobs.activeCount == 0);
}

static void testStopEscalatesToKill(void) {
    NSString *dir = tempDir(), *pidFile = [dir stringByAppendingPathComponent:@"pid"];
    OVJobs *jobs = [OVJobs jobsWithRoot:[dir stringByAppendingPathComponent:@"jobs"]];
    [jobs registerKind:@"p" lane:OVJobLaneCompute retryable:NO title:^NSString *(NSDictionary *r) { return @"p"; }
               factory:shellFactory(@"trap '' TERM; echo $$ > \"$PIDF\"; while :; do sleep 1; done", @{@"PIDF": pidFile}, nil, 0.5)
             onSuccess:nil];
    OVJob *j = [jobs submitKind:@"p" request:@{} origin:@"app" onFinish:nil error:nil];
    ASSERT(waitUntil(5, ^BOOL{ return [[NSString stringWithContentsOfFile:pidFile encoding:NSUTF8StringEncoding error:nil] intValue] > 0; }));
    int pid = [[NSString stringWithContentsOfFile:pidFile encoding:NSUTF8StringEncoding error:nil] intValue];
    spin(0.2);
    [jobs stop:j];
    ASSERT(waitUntil(6, ^BOOL{ return j.state == OVJobStopped; }), "a process that ignores SIGTERM is killed");
    ASSERT(waitUntil(2, ^BOOL{ return kill(pid, 0) != 0; }));
}

static void testProcessEventsAndResult(void) {
    OVJobs *jobs = [OVJobs jobsWithRoot:tempDir()];
    NSString *script = @"echo '{\"event\":\"status\",\"msg\":\"Working\"}'; echo '{\"event\":\"progress\",\"value\":0.5}'; "
                       @"echo 'to stderr' >&2; echo '{\"event\":\"result\",\"data\":{\"seconds\":2,\"outputs\":[\"/tmp/a.wav\"]}}'";
    [jobs registerKind:@"p" lane:OVJobLaneCompute retryable:NO title:^NSString *(NSDictionary *r) { return @"p"; }
               factory:shellFactory(script, @{}, nil, 0) onSuccess:nil];
    OVJob *j = [jobs submitKind:@"p" request:@{} origin:@"app" onFinish:nil error:nil];
    ASSERT(waitUntil(5, ^BOOL{ return !j.active; }));
    ASSERT(j.state == OVJobSucceeded, "%s", j.error.UTF8String);
    ASSERT([j.status isEqual:@"Working"]);
    ASSERT([j.result[@"seconds"] intValue] == 2 && [j.outputs isEqualToArray:@[@"/tmp/a.wav"]]);
    ASSERT([j.logText containsString:@"to stderr"], "stderr goes to the log");
}

static void testEnvironmentIsNotInherited(void) {
    setenv("JOBS_TEST_SECRET", "leak", 1);
    NSString *dir = tempDir(), *file = [dir stringByAppendingPathComponent:@"env"];
    OVJobs *jobs = [OVJobs jobsWithRoot:[dir stringByAppendingPathComponent:@"jobs"]];
    [jobs registerKind:@"p" lane:OVJobLaneCompute retryable:NO title:^NSString *(NSDictionary *r) { return @"p"; }
               factory:shellFactory(@"/usr/bin/env > \"$FILE\"; echo '{\"event\":\"result\",\"data\":{}}'", @{@"FILE": file}, nil, 0) onSuccess:nil];
    OVJob *j = [jobs submitKind:@"p" request:@{} origin:@"app" onFinish:nil error:nil];
    ASSERT(waitUntil(5, ^BOOL{ return !j.active; }));
    NSString *env = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
    ASSERT(env.length && ![env containsString:@"JOBS_TEST_SECRET"] && [env containsString:@"PATH=/usr/bin:/bin"], "%s", env.UTF8String);
}

static void testCrashedProcessFails(void) {
    OVJobs *jobs = [OVJobs jobsWithRoot:tempDir()];
    [jobs registerKind:@"p" lane:OVJobLaneCompute retryable:NO title:^NSString *(NSDictionary *r) { return @"p"; }
               factory:shellFactory(@"echo oops >&2; exit 3", @{}, nil, 0) onSuccess:nil];
    OVJob *j = [jobs submitKind:@"p" request:@{} origin:@"app" onFinish:nil error:nil];
    ASSERT(waitUntil(5, ^BOOL{ return !j.active; }));
    ASSERT(j.state == OVJobFailed);
    ASSERT([j.error containsString:@"3"], "%s", j.error.UTF8String);
    ASSERT(j.finished != nil && !exists(j.workDirectory));
    ASSERT([j.logText containsString:@"oops"]);
}

static void testBeforeStartCanRefuse(void) {
    OVJobs *jobs = [OVJobs jobsWithRoot:tempDir()];
    [jobs registerKind:@"p" lane:OVJobLaneCompute retryable:NO title:^NSString *(NSDictionary *r) { return @"p"; }
               factory:OVProcessRunnerFactory(^OVProcessSpec *(OVJob *job) {
                   OVProcessSpec *s = [OVProcessSpec new];
                   s.executable = @"/bin/sh"; s.arguments = @[@"-c", @"exit 0"];
                   s.beforeStart = ^(void (^proceed)(BOOL, NSString *)) { proceed(NO, @"Not enough memory. Close other apps."); };
                   return s;
               }) onSuccess:nil];
    OVJob *j = [jobs submitKind:@"p" request:@{} origin:@"app" onFinish:nil error:nil];
    ASSERT(waitUntil(5, ^BOOL{ return !j.active; }));
    ASSERT(j.state == OVJobFailed && [j.error isEqual:@"Not enough memory. Close other apps."]);
}

static void testStopQueuedJob(void) {
    OVJobs *jobs = [OVJobs jobsWithRoot:tempDir()];
    gRunners = [NSMutableDictionary dictionary];
    registerManual(jobs, @"c", OVJobLaneCompute, NO);
    OVJob *a = [jobs submitKind:@"c" request:@{} origin:@"app" onFinish:nil error:nil];
    OVJob *b = [jobs submitKind:@"c" request:@{} origin:@"app" onFinish:nil error:nil];
    ASSERT(b.state == OVJobQueued);
    [jobs stop:b];
    ASSERT(b.state == OVJobStopped && b.finished != nil, "stopped at once");
    ASSERT(a.state == OVJobRunning);
    OVJob *c = [jobs submitKind:@"c" request:@{} origin:@"app" onFinish:nil error:nil];
    [jobs stop:a];
    ASSERT(waitUntil(2, ^BOOL{ return a.state == OVJobStopped; }));
    ASSERT(waitUntil(2, ^BOOL{ return c.state == OVJobRunning; }), "the stopped one is skipped, the next starts");
    ASSERT(gRunners[b.identifier] == nil, "a queued job never got a runner");
}

static void testRetryCopiesRequestAndLinks(void) {
    OVJobs *jobs = [OVJobs jobsWithRoot:tempDir()];
    gRunners = [NSMutableDictionary dictionary];
    registerManual(jobs, @"r", OVJobLaneCompute, YES);
    registerManual(jobs, @"x", OVJobLaneCompute, NO);
    OVJob *a = [jobs submitKind:@"r" request:@{@"text": @"hi", @"n": @3} origin:@"api" onFinish:nil error:nil];
    ASSERT(!a.retryable, "an active job cannot be retried");
    [gRunners[a.identifier].ctx failWithError:@"bad"];
    ASSERT(waitUntil(2, ^BOOL{ return a.state == OVJobFailed; }));
    ASSERT(a.retryable);
    OVJob *b = [jobs retry:a];
    ASSERT(b && ![b.identifier isEqual:a.identifier] && [b.retryOf isEqual:a.identifier]);
    ASSERT([b.request isEqualToDictionary:a.request] && [b.kind isEqual:@"r"] && [b.origin isEqual:@"api"]);
    [gRunners[b.identifier].ctx failWithError:@"bad"];
    ASSERT(waitUntil(2, ^BOOL{ return b.state == OVJobFailed; }));
    OVJob *x = [jobs submitKind:@"x" request:@{} origin:@"app" onFinish:nil error:nil];
    [gRunners[x.identifier].ctx failWithError:@"bad"];
    ASSERT(waitUntil(2, ^BOOL{ return x.state == OVJobFailed; }));
    ASSERT([jobs retry:x] == nil);
}

static NSString *writeRecord(NSString *root, NSString *ident, NSDictionary *rec) {
    NSString *folder = [root stringByAppendingPathComponent:ident];
    [NSFileManager.defaultManager createDirectoryAtPath:[folder stringByAppendingPathComponent:@"work"] withIntermediateDirectories:YES attributes:nil error:nil];
    [NSJSONSerialization dataWithJSONObject:rec options:0 error:nil];
    [[NSJSONSerialization dataWithJSONObject:rec options:0 error:nil] writeToFile:[folder stringByAppendingPathComponent:@"job.json"] atomically:YES];
    return folder;
}

static void testRelaunchMarksRunningAsInterrupted(void) {
    NSString *root = tempDir(), *ident = @"20260101-120000-abcdef";
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSString *folder = writeRecord(root, ident, @{@"id": ident, @"kind": @"synth", @"title": @"T", @"origin": @"app", @"state": @"running",
                                                  @"lane": @0, @"created": @(now - 60), @"started": @(now - 50), @"progress": @0.4,
                                                  @"status": @"x", @"request": @{@"text": @"hi"}, @"outputs": @[]});
    [@"data" writeToFile:[folder stringByAppendingPathComponent:@"work/part.tmp"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ASSERT(exists([folder stringByAppendingPathComponent:@"work/part.tmp"]));
    OVJobs *jobs = [OVJobs jobsWithRoot:root];
    OVJob *j = [jobs jobWithId:ident];
    ASSERT(j && j.state == OVJobInterrupted, "state %ld", (long)j.state);
    ASSERT(j.finished != nil && j.error.length);
    ASSERT(!exists([folder stringByAppendingPathComponent:@"work"]));
    ASSERT(jobs.activeCount == 0);
    NSDictionary *disk = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"job.json"]] options:0 error:nil];
    ASSERT([disk[@"state"] isEqual:@"interrupted"], "persisted");
}

static void testCorruptRecordIsSkipped(void) {
    NSString *root = tempDir();
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    writeRecord(root, @"20260101-120000-aaaaaa", @{@"id": @"20260101-120000-aaaaaa", @"kind": @"synth", @"state": @"succeeded", @"created": @(now)});
    NSString *bad = writeRecord(root, @"20260101-120001-bbbbbb", @{});
    [@"{ not json" writeToFile:[bad stringByAppendingPathComponent:@"job.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    writeRecord(root, @"20260101-120002-cccccc", @{@"id": @"20260101-120002-cccccc", @"kind": @"synth", @"state": @"exploded", @"created": @(now)});
    writeRecord(root, @"20260101-120003-dddddd", @{@"id": @"20260101-999999-eeeeee", @"kind": @"synth", @"state": @"failed", @"created": @(now)});   // id differs from the folder
    [NSFileManager.defaultManager createDirectoryAtPath:[root stringByAppendingPathComponent:@"..evil"] withIntermediateDirectories:YES attributes:nil error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:[root stringByAppendingPathComponent:@"20260101-120004-ffffff"] withIntermediateDirectories:YES attributes:nil error:nil];  // no job.json
    OVJobs *jobs = [OVJobs jobsWithRoot:root];
    ASSERT(jobs.all.count == 1 && [jobs.all.firstObject.identifier isEqual:@"20260101-120000-aaaaaa"], "%lu records", (unsigned long)jobs.all.count);
}

static OVJob *makeJob(NSString *root, int i, OVJobState st, NSTimeInterval age) {
    NSTimeInterval t = NSDate.date.timeIntervalSince1970 - age;
    NSString *ident = [NSString stringWithFormat:@"20260101-%06d-%06x", i, i];
    NSMutableDictionary *d = [@{@"id": ident, @"kind": @"synth", @"state": OVJobStateName(st), @"created": @(t)} mutableCopy];
    if (st != OVJobRunning) d[@"finished"] = @(t + 1);
    return [OVJob jobFromDictionary:d folder:[root stringByAppendingPathComponent:ident]];
}

static void testPruneKeepsActive(void) {
    NSString *root = tempDir();
    OVJobStore *store = [[OVJobStore alloc] initWithRoot:root];
    NSMutableArray *all = [NSMutableArray array];
    for (int i = 0; i < 250; i++) [all addObject:makeJob(root, i, OVJobSucceeded, 3600 + 10.0 * (250 - i))];
    OVJob *running = makeJob(root, 900, OVJobRunning, 40 * 24 * 3600);   // old, but alive
    [all addObject:running];
    OVJob *old = makeJob(root, 901, OVJobFailed, 40 * 24 * 3600);
    [all addObject:old];
    for (OVJob *j in all) [store save:j];
    NSArray *removed = [store pruneJobs:all];
    ASSERT(removed.count == 51, "%lu removed", (unsigned long)removed.count);
    ASSERT(![removed containsObject:running] && [removed containsObject:old]);
    ASSERT([NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil].count == 201);
    ASSERT(exists(running.folder));
    OVJob *newest = all[249];
    ASSERT(exists(newest.folder), "the newest finished ones stay");
    ASSERT(!exists(((OVJob *)all[0]).folder), "the oldest finished ones go");
}

static void testCleanupRefusesPathsOutsideAppData(void) {
    NSString *dir = tempDir();
    OVJobs *jobs = [OVJobs jobsWithRoot:[dir stringByAppendingPathComponent:@"jobs"]];
    gRunners = [NSMutableDictionary dictionary];
    registerManual(jobs, @"c", OVJobLaneCompute, NO);
    ASSERT(![OVJobStore isInsideAppData:@"/etc/hosts"] && ![OVJobStore isInsideAppData:@"/"] && ![OVJobStore isInsideAppData:NSHomeDirectory()]);
    ASSERT(![OVJobStore isInsideAppData:[dir stringByAppendingPathComponent:@"../../../etc/hosts"]], "'..' is refused");
    NSString *link = [dir stringByAppendingPathComponent:@"homelink"];
    symlink(NSHomeDirectory().fileSystemRepresentation, link.fileSystemRepresentation);
    ASSERT(![OVJobStore isInsideAppData:link] && ![OVJobStore isInsideAppData:[link stringByAppendingPathComponent:@"Documents"]]);
    NSString *mine = [dir stringByAppendingPathComponent:@"mine.wav"];
    [@"x" writeToFile:mine atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ASSERT([OVJobStore isInsideAppData:mine] && [OVJobStore isInsideAppData:[dir stringByAppendingPathComponent:@"not-yet/there.wav"]]);

    OVJob *j = [jobs submitKind:@"c" request:@{} origin:@"app" onFinish:nil error:nil];
    OVJobContext *ctx = gRunners[j.identifier].ctx;
    [ctx registerPartialPath:@"/etc/hosts"];
    [ctx registerPartialPath:link];
    [ctx registerPartialPath:mine];
    spin(0.1);
    [ctx failWithError:@"x"];
    ASSERT(waitUntil(2, ^BOOL{ return j.state == OVJobFailed; }));
    ASSERT(exists(@"/etc/hosts"), "outside the app folders: untouched");
    ASSERT(exists(link) && exists(NSHomeDirectory()), "a symlink to the home folder is refused");
    ASSERT(!exists(mine), "an allowed partial file is deleted");
}

static void testRequestSecretsAreRedacted(void) {
    NSDictionary *r = @{@"text": @"hello", @"hf_token": @"hf_SECRET1", @"Authorization": @"Bearer SECRET2", @"max_new_tokens": @128,
                        @"nested": @{@"api_key": @"SECRET3", @"fine": @1, @"deeper": @[@{@"password": @"SECRET4"}]},
                        @"hfToken": @"SECRET5", @"X-Api-Key": @"SECRET6", @"keyboard": @"ok", @"when": [NSDate dateWithTimeIntervalSince1970:5]};
    NSDictionary *red = [OVJobStore redact:r];
    ASSERT([red[@"hf_token"] isEqual:@"***"] && [red[@"Authorization"] isEqual:@"***"] && [red[@"hfToken"] isEqual:@"***"] && [red[@"X-Api-Key"] isEqual:@"***"]);
    ASSERT([red[@"nested"][@"api_key"] isEqual:@"***"] && [red[@"nested"][@"deeper"][0][@"password"] isEqual:@"***"]);
    ASSERT([red[@"nested"][@"fine"] isEqual:@1] && [red[@"max_new_tokens"] isEqual:@128] && [red[@"keyboard"] isEqual:@"ok"] && [red[@"text"] isEqual:@"hello"]);
    ASSERT([NSJSONSerialization isValidJSONObject:red]);

    NSString *root = tempDir();
    OVJobs *jobs = [OVJobs jobsWithRoot:root];
    gRunners = [NSMutableDictionary dictionary];
    registerManual(jobs, @"c", OVJobLaneCompute, NO);
    OVJob *j = [jobs submitKind:@"c" request:r origin:@"app" onFinish:nil error:nil];
    [gRunners[j.identifier].ctx succeedWithResult:@{@"token": @"SECRET7", @"seconds": @1} outputs:@[]];
    ASSERT(waitUntil(2, ^BOOL{ return !j.active; }));
    NSString *disk = [NSString stringWithContentsOfFile:[j.folder stringByAppendingPathComponent:@"job.json"] encoding:NSUTF8StringEncoding error:nil];
    ASSERT(disk.length && ![disk containsString:@"SECRET"], "job.json holds no secrets");
    NSString *mem = [NSString stringWithFormat:@"%@%@", j.request, j.result];
    ASSERT(![mem containsString:@"SECRET"]);
    ASSERT([j.result[@"seconds"] isEqual:@1]);
}

static void testFilesAreOwnerOnly(void) {
    OVJobs *jobs = [OVJobs jobsWithRoot:tempDir()];
    gRunners = [NSMutableDictionary dictionary];
    registerManual(jobs, @"c", OVJobLaneCompute, NO);
    OVJob *j = [jobs submitKind:@"c" request:@{} origin:@"app" onFinish:nil error:nil];
    [gRunners[j.identifier].ctx log:@"hello"];
    NSFileManager *fm = NSFileManager.defaultManager;
    ASSERT([[fm attributesOfItemAtPath:j.folder error:nil][NSFilePosixPermissions] intValue] == 0700);
    ASSERT([[fm attributesOfItemAtPath:j.workDirectory error:nil][NSFilePosixPermissions] intValue] == 0700);
    ASSERT([[fm attributesOfItemAtPath:[j.folder stringByAppendingPathComponent:@"job.json"] error:nil][NSFilePosixPermissions] intValue] == 0600);
    ASSERT([[fm attributesOfItemAtPath:j.logPath error:nil][NSFilePosixPermissions] intValue] == 0600);
}

static void testLogIsCapped(void) {
    OVJobs *jobs = [OVJobs jobsWithRoot:tempDir()];
    gRunners = [NSMutableDictionary dictionary];
    registerManual(jobs, @"c", OVJobLaneCompute, NO);
    OVJob *j = [jobs submitKind:@"c" request:@{} origin:@"app" onFinish:nil error:nil];
    OVJobContext *ctx = gRunners[j.identifier].ctx;
    NSString *pad = [@"" stringByPaddingToLength:1000 withString:@"x" startingAtIndex:0];
    for (int i = 0; i < 2600; i++) [ctx log:[NSString stringWithFormat:@"line-%04d %@", i, pad]];
    unsigned long long size = [[NSFileManager.defaultManager attributesOfItemAtPath:j.logPath error:nil] fileSize];
    ASSERT(size <= 2 * 1024 * 1024, "%llu bytes", size);
    NSString *tail = j.logText;
    ASSERT([tail containsString:@"line-2599"] && ![tail containsString:@"line-0000"], "the head is cut, the tail stays");
    ASSERT(tail.length <= 256 * 1024 + 8);
}

static void testProgressIsThrottled(void) {
    OVJobs *jobs = [OVJobs jobsWithRoot:tempDir()];
    gRunners = [NSMutableDictionary dictionary];
    registerManual(jobs, @"c", OVJobLaneCompute, NO);
    OVJob *j = [jobs submitKind:@"c" request:@{} origin:@"app" onFinish:nil error:nil];
    OVJobContext *ctx = gRunners[j.identifier].ctx;
    NSUInteger before = jobs.store.writeCount;
    __block int notes = 0;
    id obs = [NSNotificationCenter.defaultCenter addObserverForName:OVJobsDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) { notes++; }];
    NSDate *t0 = NSDate.date;
    for (int i = 1; i <= 1000; i++) { [ctx setProgress:i / 1000.0]; [ctx setStatus:[NSString stringWithFormat:@"step %d", i]]; }
    spin(0.3);
    ASSERT(-[t0 timeIntervalSinceNow] < 1.0);
    ASSERT(jobs.store.writeCount - before <= 2, "%lu writes", (unsigned long)(jobs.store.writeCount - before));
    ASSERT(notes <= 3, "%d notifications in 0.3 s", notes);
    ASSERT(j.progress == 1.0 && [j.status isEqual:@"step 1000"], "memory holds the latest values");
    spin(1.2);   // the pending write lands and carries the latest state
    NSDictionary *disk = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[j.folder stringByAppendingPathComponent:@"job.json"]] options:0 error:nil];
    ASSERT([disk[@"status"] isEqual:@"step 1000"], "%s", [disk[@"status"] description].UTF8String);
    [NSNotificationCenter.defaultCenter removeObserver:obs];
}

static void testStopAllAndWait(void) {
    NSString *dir = tempDir();
    OVJobs *jobs = [OVJobs jobsWithRoot:[dir stringByAppendingPathComponent:@"jobs"]];
    gRunners = [NSMutableDictionary dictionary];
    registerManual(jobs, @"c", OVJobLaneCompute, NO);
    [jobs registerKind:@"hang" lane:OVJobLaneNetwork retryable:NO title:^NSString *(NSDictionary *r) { return @"h"; }
               factory:^id<OVJobRunner>(OVJob *job) { ManualRunner *r = [ManualRunner new]; gRunners[job.identifier] = r; return r; } onSuccess:nil];
    OVJob *a = [jobs submitKind:@"c" request:@{} origin:@"app" onFinish:nil error:nil];
    OVJob *b = [jobs submitKind:@"c" request:@{} origin:@"app" onFinish:nil error:nil];
    OVJob *h = [jobs submitKind:@"hang" request:@{} origin:@"app" onFinish:nil error:nil];   // never answers stop
    ASSERT(exists(a.workDirectory) && exists(h.workDirectory));
    [jobs stopAllAndWait:0.5];
    ASSERT(jobs.activeCount == 0);
    ASSERT(a.state == OVJobStopped && b.state == OVJobStopped && h.state == OVJobStopped);
    ASSERT(!exists(a.workDirectory) && !exists(h.workDirectory));
    ASSERT([a.logText containsString:@"Stopped by user"]);
}

static void testRemoveAndClearFinished(void) {
    OVJobs *jobs = [OVJobs jobsWithRoot:tempDir()];
    gRunners = [NSMutableDictionary dictionary];
    registerManual(jobs, @"c", OVJobLaneCompute, NO);
    OVJob *a = [jobs submitKind:@"c" request:@{} origin:@"app" onFinish:nil error:nil];
    OVJob *b = [jobs submitKind:@"c" request:@{} origin:@"app" onFinish:nil error:nil];
    [jobs remove:a];
    ASSERT([jobs jobWithId:a.identifier] != nil, "an active job is not removable");
    [gRunners[a.identifier].ctx succeedWithResult:nil outputs:@[]];
    ASSERT(waitUntil(2, ^BOOL{ return a.state == OVJobSucceeded; }));
    NSString *folder = a.folder;
    [jobs remove:a];
    ASSERT([jobs jobWithId:a.identifier] == nil && !exists(folder));
    [jobs clearFinished];
    ASSERT([jobs jobWithId:b.identifier] != nil);
}

int main(void) {
    @autoreleasepool {
        void (*tests[])(void) = {
            testSubmitRunsFifoPerLane, testOnSuccessAndOnFinishRunOnMain, testRemoteQueueLimit, testStopProcessMidWork,
            testStopEscalatesToKill, testProcessEventsAndResult, testEnvironmentIsNotInherited, testCrashedProcessFails,
            testBeforeStartCanRefuse, testStopQueuedJob, testRetryCopiesRequestAndLinks, testRelaunchMarksRunningAsInterrupted,
            testCorruptRecordIsSkipped, testPruneKeepsActive, testCleanupRefusesPathsOutsideAppData, testRequestSecretsAreRedacted,
            testFilesAreOwnerOnly, testLogIsCapped, testProgressIsThrottled, testStopAllAndWait, testRemoveAndClearFinished,
        };
        for (size_t i = 0; i < sizeof tests / sizeof *tests; i++) tests[i]();
        if (gFailures) { fprintf(stderr, "%d assertion(s) failed\n", gFailures); return 1; }
        printf("jobs_test: all passed\n");
    }
    return 0;
}
