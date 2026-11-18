// deps: OVEngines.m OVProRunPlan.m OVJobs.m OVJobStore.m OVPaths.m OVLocale.m OVRuntime.m OVNetwork.m OVPrivacyCatalog.m OVWorker.m OVModels.m OVDownloader.m OVStore.m OVMemory.m
// Prints "PASS <name>" or "FAIL <name>" per case; tests/test_pro_run.py maps each case to a Python test.
#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <sys/stat.h>
#import "OVEngines.h"
#import "OVJobs.h"
#import "OVPaths.h"
#import "OVWorker.h"

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

static NSString *tempDir(void) {
    NSString *d = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"engines-test-%u", arc4random()]];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static void writeExecutable(NSString *path, NSString *body) {
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chmod(path.fileSystemRepresentation, 0755);
}

static NSString *pythonIn(NSString *root, NSString *folder) { return [root stringByAppendingFormat:@"/%@/.venv/bin/python", folder]; }

/// A fake python: prints the arguments and a few facts as the result event, and keeps the stdin line next to the job.
static NSString *const kFakePython =
    @"#!/bin/sh\n"
    @"read line\n"
    @"printf '%s' \"$line\" > \"$TMPDIR/stdin.json\"\n"
    @"echo \"{\\\"event\\\":\\\"result\\\",\\\"data\\\":{\\\"args\\\":\\\"$*\\\",\\\"offline\\\":\\\"$OV_OFFLINE\\\",\\\"cwd\\\":\\\"$(pwd)\\\"}}\"\n";

/// Creates the fake interpreters of every environment under root.
static void makeEnvs(NSString *root) {
    for (NSString *f in @[@"pro", @"applio-env", @"edge"]) writeExecutable(pythonIn(root, f), kFakePython);
    [NSFileManager.defaultManager createDirectoryAtPath:[root stringByAppendingPathComponent:@"applio"] withIntermediateDirectories:YES attributes:nil error:nil];
}

static NSDictionary *row(NSString *cid, NSString *state) {
    return @{@"id": cid, @"title": cid, @"state": state, @"download_bytes": @(100), @"disk_bytes": @(200), @"license": @"MIT", @"optional": @(![cid isEqual:@"pro-env"])};
}

static NSDictionary *status(NSString *layout, NSDictionary<NSString *, NSString *> *states) {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *k in [states.allKeys sortedArrayUsingSelector:@selector(compare:)]) [rows addObject:row(k, states[k])];
    return @{@"layout": layout, @"ready": @NO, @"components": rows, @"peak_gb": @{@"infer": @3.4, @"train": @10.0, @"train_b2": @8.2, @"seedvc": @4.0,
                                                                                 @"mdx": @6.5, @"roformer": @6.6, @"realtime": @2.7, @"blend": @1.0,
                                                                                 @"ytdlp": @0.3, @"edge": @0.3}};
}

/// A runner the test ends by hand.
@interface ManualRunner : NSObject <OVJobRunner>
@property OVJobContext *ctx;
@end
@implementation ManualRunner
- (void)start:(OVJob *)job context:(OVJobContext *)ctx { self.ctx = ctx; }
- (void)stop:(OVJob *)job { [self.ctx failWithError:@"Stopped"]; }
@end
static NSMutableDictionary<NSString *, ManualRunner *> *gRunners;

static void registerManualPro(OVJobs *jobs) {
    gRunners = [NSMutableDictionary dictionary];
    for (NSDictionary *r in [OVEngines kindTable]) {
        [jobs registerKind:r[@"kind"] lane:(OVJobLane)[r[@"lane"] integerValue] retryable:YES title:^NSString *(NSDictionary *q) { return r[@"kind"]; }
                   factory:^id<OVJobRunner>(OVJob *job) { ManualRunner *m = [ManualRunner new]; gRunners[job.identifier] = m; return m; } onSuccess:nil];
    }
}

static void registerReal(OVJobs *jobs, OVEngines *engines) {
    for (NSDictionary *r in [OVEngines kindTable]) {
        NSString *kind = r[@"kind"];
        [jobs registerKind:kind lane:(OVJobLane)[r[@"lane"] integerValue] retryable:YES title:^NSString *(NSDictionary *q) { return kind; }
                   factory:OVProcessRunnerFactory(^OVProcessSpec *(OVJob *job) { return [engines specForKind:kind job:job]; }) onSuccess:nil];
    }
}

static NSDictionary *allReady(NSString *layout) {
    NSMutableDictionary *s = [@{@"pro-env": @"ready", @"applio": @"ready", @"rvc-core": @"ready", @"seedvc": @"ready", @"ytdlp": @"ready",
                                @"edge": @"ready", @"stems-mdx": @"ready"} mutableCopy];
    if ([layout isEqual:@"split"]) s[@"applio-env"] = @"ready";
    return status(layout, s);
}

#pragma mark - Cases

static void testEnginesStateFromStatusJson(void) {
    NSString *root = tempDir();
    makeEnvs(root);
    OVJobs *jobs = [OVJobs jobsWithRoot:[root stringByAppendingPathComponent:@"jobs"]];
    OVEngines *e = [OVEngines enginesWithRoot:root jobs:jobs mainPython:@"/usr/bin/python3"];
    __block int notes = 0;
    id obs = [NSNotificationCenter.defaultCenter addObserverForName:OVEnginesDidChangeNotification object:e queue:nil usingBlock:^(NSNotification *n) { notes++; }];
    ASSERT([e pythonForEngine:OVEnginePro] == nil, "nothing is known before the first status");
    [e applyStatus:status(@"shared", @{@"pro-env": @"ready", @"applio": @"partial", @"rvc-core": @"broken", @"ytdlp": @"notinstalled", @"seedvc": @"ready"})];
    ASSERT(notes == 1);
    ASSERT([e componentWithId:@"pro-env"].state == OVEngineReady);
    ASSERT([e componentWithId:@"applio"].state == OVEnginePartial);
    ASSERT([e componentWithId:@"rvc-core"].state == OVEngineBroken);
    ASSERT([e componentWithId:@"ytdlp"].state == OVEngineNotInstalled);
    OVEngineComponent *c = [e componentWithId:@"pro-env"];
    ASSERT(c.downloadBytes == 100 && c.diskBytes == 200 && [c.license isEqual:@"MIT"] && !c.optional);
    ASSERT([[e componentWithId:@"applio"] optional]);
    NSString *py = pythonIn(root, @"pro");
    ASSERT([[e pythonForEngine:OVEnginePro] isEqual:py], "pro env is ready");
    ASSERT([e pythonForEngine:@"rvc"] == nil, "partial Applio is not ready");
    ASSERT([e pythonForEngine:@"realtime"] == nil);
    ASSERT([e pythonForEngine:@"ytdlp"] == nil, "not installed");
    ASSERT([e pythonForEngine:OVEngineEdge] == nil, "edge is not in the list at all");
    ASSERT([[e pythonForEngine:@"seedvc"] isEqual:py]);
    ASSERT([e pythonForEngine:@"nonsense"] == nil);
    [e applyStatus:status(@"shared", @{@"pro-env": @"ready", @"applio": @"ready", @"edge": @"ready"})];
    ASSERT([[e pythonForEngine:@"rvc"] isEqual:py], "shared layout: one environment for everything");
    ASSERT([[e pythonForEngine:OVEngineEdge] isEqual:pythonIn(root, @"edge")]);
    // ready on paper, interpreter gone: not ready
    [NSFileManager.defaultManager removeItemAtPath:pythonIn(root, @"pro") error:nil];
    ASSERT([e pythonForEngine:OVEnginePro] == nil);
    // a running install turns the missing pieces into Installing
    makeEnvs(root);
    registerManualPro(jobs);
    OVJob *j = [e install:@[@"applio"] error:nil];
    ASSERT(j != nil);
    [e applyStatus:status(@"shared", @{@"pro-env": @"ready", @"applio": @"partial"})];
    ASSERT([e componentWithId:@"applio"].state == OVEngineInstalling);
    [NSNotificationCenter.defaultCenter removeObserver:obs];
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

static void testInstallRefusedWhileProJobActive(void) {
    NSString *root = tempDir();
    makeEnvs(root);
    OVJobs *jobs = [OVJobs jobsWithRoot:[root stringByAppendingPathComponent:@"jobs"]];
    registerManualPro(jobs);
    OVEngines *e = [OVEngines enginesWithRoot:root jobs:jobs mainPython:@"/usr/bin/python3"];
    [e applyStatus:allReady(@"shared")];
    ASSERT(!e.proJobActive);
    NSString *err = nil;
    OVJob *busy = [jobs submitKind:OVProKindConvert request:@{@"input": @"/x.wav"} origin:@"app" onFinish:nil error:nil];
    ASSERT(busy != nil && e.proJobActive);
    ASSERT([e install:@[@"rvc-fcpe"] error:&err] == nil && [err containsString:@"pro job is running"], "%s", err.UTF8String);
    err = nil;
    ASSERT(![e uninstall:@[@"seedvc"] error:&err] && [err containsString:@"pro job is running"]);
    err = nil;
    ASSERT([e updateYtDlp:&err] == nil && err.length);
    // network-lane work (Edge, YouTube) does not count: it holds no big memory
    [gRunners[busy.identifier].ctx succeedWithResult:nil outputs:@[]];
    ASSERT(waitUntil(2, ^BOOL{ return !e.proJobActive; }));
    OVJob *edge = [jobs submitKind:OVProKindEdge request:@{} origin:@"app" onFinish:nil error:nil];
    ASSERT(edge != nil && !e.proJobActive);
    err = nil;
    OVJob *inst = [e install:@[@"rvc-fcpe"] error:&err];
    ASSERT(inst != nil && [inst.kind isEqual:OVProKindEngineWeights], "weights only → engine_weights (%s)", err.UTF8String);
    OVJob *inst2 = [e install:@[@"pro-env", @"applio"] error:&err];
    ASSERT(inst2 != nil && [inst2.kind isEqual:OVProKindEngineInstall]);
    ASSERT([inst2.request[@"components"] isEqual:(@[@"pro-env", @"applio"])]);
    ASSERT([e install:@[] error:&err] == nil);
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

static void testLayoutSplitMapsLogicalNames(void) {
    NSString *root = tempDir();
    makeEnvs(root);
    OVEngines *e = [OVEngines enginesWithRoot:root jobs:[OVJobs jobsWithRoot:[root stringByAppendingPathComponent:@"jobs"]] mainPython:@"/usr/bin/python3"];
    [e applyStatus:allReady(@"split")];
    NSString *applioEnv = pythonIn(root, @"applio-env"), *pro = pythonIn(root, @"pro");
    ASSERT([[e pythonForEngine:@"rvc"] isEqual:applioEnv], "rvc lives in applio-env");
    ASSERT([[e pythonForEngine:@"realtime"] isEqual:applioEnv]);
    ASSERT([[e pythonForEngine:@"seedvc"] isEqual:pro], "Seed-VC in the pro env");
    ASSERT([[e pythonForEngine:@"stems"] isEqual:pro]);
    ASSERT([[e pythonForEngine:@"ytdlp"] isEqual:pro]);
    ASSERT([[e pythonForEngine:@"plugins"] isEqual:pro]);
    ASSERT([[e pythonForEngine:OVEnginePro] isEqual:pro]);
    ASSERT([[e pythonForEngine:OVEngineEdge] isEqual:pythonIn(root, @"edge")]);
    // split but applio-env missing: rvc is not ready, the rest still is
    NSMutableDictionary *s = [allReady(@"split") mutableCopy];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *r in s[@"components"]) if (![r[@"id"] isEqual:@"applio-env"]) [rows addObject:r];
    s[@"components"] = rows;
    [e applyStatus:s];
    ASSERT([e pythonForEngine:@"rvc"] == nil && [e pythonForEngine:@"stems"] != nil);
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

static void testPeakBytesFromStatus(void) {
    NSString *root = tempDir();
    OVEngines *e = [OVEngines enginesWithRoot:root jobs:[OVJobs jobsWithRoot:[root stringByAppendingPathComponent:@"jobs"]] mainPython:nil];
    ASSERT([e peakBytesForKind:OVProKindConvert option:@"rvc"] == (unsigned long long)(3.4 * GB), "built-in table before the first status");
    NSMutableDictionary *s = [allReady(@"shared") mutableCopy];
    s[@"peak_gb"] = @{@"infer": @2.0, @"seedvc": @5.0, @"train": @10.0, @"train_b2": @8.0, @"roformer": @7.0, @"mdx": @6.0};
    [e applyStatus:s];
    ASSERT([e peakBytesForKind:OVProKindConvert option:@"rvc"] == 2 * GB);
    ASSERT([e peakBytesForKind:OVProKindConvert option:nil] == 2 * GB);
    ASSERT([e peakBytesForKind:OVProKindConvert option:@"seedvc"] == 5 * GB);
    ASSERT([e peakBytesForKind:OVProKindRvcTrain option:nil] == 10 * GB);
    ASSERT([e peakBytesForKind:OVProKindRvcTrain option:@"batch2"] == 8 * GB);
    ASSERT([e peakBytesForKind:OVProKindStems option:@"roformer-vocals"] == 7 * GB);
    ASSERT([e peakBytesForKind:OVProKindStems option:@"UVR-MDX-NET-Inst_HQ_3"] == 6 * GB);
    ASSERT([e peakBytesForKind:OVProKindRealtime option:nil] == (unsigned long long)(2.7 * GB), "keys missing in status keep their defaults");
    ASSERT([e peakBytesForKind:OVProKindEngineInstall option:nil] == 0, "installs have no memory peak");
    ASSERT([[OVEngines peakOptionForKind:OVProKindRvcTrain request:@{@"batch_size": @2}] isEqual:@"batch2"]);
    ASSERT([OVEngines peakOptionForKind:OVProKindRvcTrain request:@{@"batch_size": @8}] == nil);
    ASSERT([[OVEngines peakOptionForKind:OVProKindConvert request:@{@"engine": @"seedvc"}] isEqual:@"seedvc"]);
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

static OVJob *submitted(OVJobs *jobs, NSString *kind, NSDictionary *req) {
    OVJob *j = [jobs submitKind:kind request:req origin:@"app" onFinish:nil error:nil];
    return j;
}

/// Splits `-f <file> -D K=V ... <rest>` into the parameters and the command that runs inside the sandbox.
static NSDictionary *sandboxParts(OVProcessSpec *s, NSArray **rest) {
    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    NSArray *a = s.arguments;
    NSUInteger i = 0;
    if (a.count < 2 || ![a[0] isEqual:@"-f"]) { *rest = a; return nil; }
    p[@"file"] = a[1];
    i = 2;
    while (i + 1 < a.count && [a[i] isEqual:@"-D"]) {
        NSString *kv = a[i + 1];
        NSRange eq = [kv rangeOfString:@"="];
        p[[kv substringToIndex:eq.location]] = [kv substringFromIndex:eq.location + 1];
        i += 2;
    }
    *rest = [a subarrayWithRange:NSMakeRange(i, a.count - i)];
    return p;
}

static NSDictionary *stdinOf(OVProcessSpec *spec) {
    return [NSJSONSerialization JSONObjectWithData:spec.stdinData options:0 error:nil];
}

static void testSpecForProKindRunsUnderSandbox(void) {
    NSString *root = tempDir();
    makeEnvs(root);
    OVJobs *jobs = [OVJobs jobsWithRoot:[root stringByAppendingPathComponent:@"jobs"]];
    registerManualPro(jobs);
    OVEngines *e = [OVEngines enginesWithRoot:root jobs:jobs mainPython:@"/usr/bin/python3"];
    [e applyStatus:allReady(@"shared")];
    NSString *py = pythonIn(root, @"pro");

    OVJob *conv = submitted(jobs, OVProKindConvert, @{@"input": @"/in.wav", @"model": @"/m", @"_note": @"app only"});
    OVProcessSpec *s = [e specForKind:OVProKindConvert job:conv];
    ASSERT([s.executable isEqual:@"/usr/bin/sandbox-exec"]);
    NSArray *rest = nil;
    NSDictionary *sb = sandboxParts(s, &rest);
    ASSERT(sb && [sb[@"file"] hasSuffix:@"/sandbox/engine.sb"], "the one shared profile file");
    ASSERT([sb[@"NET"] isEqual:@"deny-ip"], "inference has no IP traffic");
    ASSERT([sb[@"WORK"] isEqual:conv.workDirectory.stringByResolvingSymlinksInPath] && [sb[@"OUT"] isEqual:[OVPaths outputs].stringByResolvingSymlinksInPath]);
    for (NSString *k in @[@"ROOT1", @"ROOT2", @"ROOT3", @"ROOT4", @"DCACHE", @"DTEMP"]) ASSERT([sb[k] length] > 0, "%s is always given", k.UTF8String);
    ASSERT([rest[0] isEqual:py] && [rest[1] isEqual:@"-s"] && [rest[2] hasSuffix:@"/cns_rvc.py"] && [rest[3] isEqual:@"infer"],
           "%s", [s.arguments componentsJoinedByString:@" "].UTF8String);
    ASSERT([s.environment[@"CNS_SANDBOXED"] isEqual:@"1"] && s.environment[@"CNS_SANDBOX_FILE"], "the child is told it is already sandboxed");
    ASSERT(!s.keepStdinOpen && s.launchError == nil);
    NSDictionary *req = stdinOf(s);
    ASSERT([req[@"input"] isEqual:@"/in.wav"] && [req[@"work_dir"] isEqual:conv.workDirectory] && [req[@"job_id"] isEqual:conv.identifier]);
    ASSERT([req[@"outputs_dir"] isEqual:[OVPaths outputs]] && req[@"_note"] == nil, "app-side notes are not sent");
    ASSERT([s.currentDirectory isEqual:[root stringByAppendingPathComponent:@"applio"]], "Applio root");
    ASSERT(s.beforeStart == nil, "no host: no checks");

    // request shapes pick the script and command
    OVJob *batch = submitted(jobs, OVProKindConvert, @{@"inputs": @[@"/a.wav"], @"model": @"/m"});
    ASSERT([[e specForKind:OVProKindConvert job:batch].arguments.lastObject isEqual:@"batch"]);
    ASSERT([[e specForKind:OVProKindRvcInfo job:submitted(jobs, OVProKindRvcInfo, @{@"model": @"/m"})].arguments.lastObject isEqual:@"info"]);
    OVJob *seed = submitted(jobs, OVProKindConvert, @{@"engine": @"seedvc", @"input": @"/a.wav", @"target": @"/t.wav"});
    OVProcessSpec *ss = [e specForKind:OVProKindConvert job:seed];
    NSArray *seedRest = nil;
    sandboxParts(ss, &seedRest);
    ASSERT([seedRest[2] hasSuffix:@"/cns_seedvc.py"] && [seedRest[3] isEqual:@"convert"]);
    ASSERT([ss.environment[@"HF_HOME"] isEqual:[root stringByAppendingPathComponent:@"seedvc/hf"]] && [ss.environment[@"TRANSFORMERS_OFFLINE"] isEqual:@"1"]);
    OVJob *train = submitted(jobs, OVProKindRvcTrain, @{@"name": @"v"});
    OVProcessSpec *ts = [e specForKind:OVProKindRvcTrain job:train];
    NSArray *trainRest = nil;
    NSDictionary *tsb = sandboxParts(ts, &trainRest);
    ASSERT([trainRest[2] hasSuffix:@"/cns_train.py"] && [trainRest[3] isEqual:@"run"]);
    ASSERT([tsb[@"ROOT1"] isEqual:[OVPaths rvcTraining].stringByResolvingSymlinksInPath] && [tsb[@"NET"] isEqual:@"deny-ip"], "training is writable, no IP");
    ASSERT([ts.environment[@"CNS_SANDBOXED"] isEqual:@"1"], "cns_train must not wrap its child again (no double sandbox)");
    OVJob *rt = submitted(jobs, OVProKindRealtime, @{@"model": @"/m", @"socket": @"/x/rt.sock"});
    OVProcessSpec *rs = [e specForKind:OVProKindRealtime job:rt];
    NSArray *rtRest = nil;
    NSDictionary *rsb = sandboxParts(rs, &rtRest);
    ASSERT([rsb[@"NET"] isEqual:@"deny-ip"] && rs.keepStdinOpen, "realtime: AF_UNIX works under deny-ip, stdin stays open");
    ASSERT([rtRest[2] hasSuffix:@"/cns_realtime.py"] && [rtRest[3] isEqual:@"run"]);
    OVJob *imp = submitted(jobs, OVProKindRvcImport, @{@"pth": @"/a.pth", @"name": @"v"});
    NSArray *impRest = nil;
    NSDictionary *isb = sandboxParts([e specForKind:OVProKindRvcImport job:imp], &impRest);
    ASSERT([isb[@"ROOT1"] isEqual:[OVPaths rvcModels].stringByResolvingSymlinksInPath] && [isb[@"NET"] isEqual:@"deny-ip"]);
    ASSERT([ts.environment[@"APPLIO_LOGS_DIR"] isEqual:[root stringByAppendingPathComponent:@"training"]]);

    // network features: the same profile with NET=allow, writes only in work + outputs; the pro python inside it
    // (cns_ytdl runs in the pro env), the engines root in the request
    OVJob *yt = submitted(jobs, OVProKindYouTube, @{@"url": @"https://youtu.be/x", @"consent": @YES});
    OVProcessSpec *ys = [e specForKind:OVProKindYouTube job:yt];
    NSArray *ytRest = nil;
    NSDictionary *ysb = sandboxParts(ys, &ytRest);
    ASSERT([ys.executable isEqual:@"/usr/bin/sandbox-exec"] && [ysb[@"NET"] isEqual:@"allow"] && [ysb[@"OUT"] isEqual:[OVPaths outputs].stringByResolvingSymlinksInPath]);
    ASSERT([ysb[@"ROOT1"] isEqual:ysb[@"WORK"]] && [ysb[@"ROOT2"] isEqual:ysb[@"WORK"]], "no extra write folder");
    ASSERT([ytRest[0] isEqual:py] && [ytRest[2] hasSuffix:@"/cns_ytdl.py"] && [ytRest[3] isEqual:@"fetch"]);
    ASSERT([stdinOf(ys)[@"root"] isEqual:root] && [ys.environment[@"CNS_ENGINES_ROOT"] isEqual:root]);
    ASSERT(ys.environment[@"OV_OFFLINE"] == nil, "YouTube may go online");
    OVJob *edge = submitted(jobs, OVProKindEdge, @{@"text": @"hi"});
    OVProcessSpec *es = [e specForKind:OVProKindEdge job:edge];
    NSArray *edRest = nil;
    NSDictionary *esb = sandboxParts(es, &edRest);
    ASSERT([esb[@"NET"] isEqual:@"allow"] && [edRest[0] isEqual:pythonIn(root, @"edge")] && [edRest[2] hasSuffix:@"/cns_edge.py"]);
    OVJob *fetch = submitted(jobs, OVProKindRvcFetch, @{@"url": @"https://x/y.zip", @"name": @"v"});
    NSDictionary *fsb = sandboxParts([e specForKind:OVProKindRvcFetch job:fetch], &rest);
    ASSERT([fsb[@"NET"] isEqual:@"allow"] && [fsb[@"ROOT1"] isEqual:[OVPaths rvcModels].stringByResolvingSymlinksInPath]);
    // installs are not sandboxed (they write the engines folder) and run in the main runtime
    OVProcessSpec *ins = [e specForKind:OVProKindEngineInstall job:submitted(jobs, OVProKindEngineInstall, @{@"components": @[@"pro-env"]})];
    ASSERT([ins.executable isEqual:@"/usr/bin/python3"] && sandboxParts(ins, &rest) == nil && ins.environment[@"CNS_SANDBOXED"] == nil);
    // not installed: no program (the job fails with a message, the gate card stops it before)
    [e applyStatus:status(@"shared", @{@"pro-env": @"notinstalled"})];
    OVProcessSpec *none = [e specForKind:OVProKindConvert job:conv];
    ASSERT(none.executable.length == 0 && [none.launchError containsString:@"needs its engine"], "a specific message, not 'no program'");
    ASSERT([e specForKind:@"nope" job:conv] == nil);
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

static void testSpecEnvironmentIsADictionary(void) {
    NSString *root = tempDir();
    makeEnvs(root);
    OVJobs *jobs = [OVJobs jobsWithRoot:[root stringByAppendingPathComponent:@"jobs"]];
    registerManualPro(jobs);
    OVEngines *e = [OVEngines enginesWithRoot:root jobs:jobs mainPython:@"/usr/bin/python3"];
    [e applyStatus:allReady(@"shared")];
    OVJob *conv = submitted(jobs, OVProKindConvert, @{@"input": @"/in.wav", @"hf_token": @"secret"});
    NSDictionary *env = [e specForKind:OVProKindConvert job:conv].environment;
    ASSERT([env[@"PATH"] isEqual:@"/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"]);
    ASSERT([env[@"HOME"] isEqual:NSHomeDirectory()] && [env[@"TMPDIR"] isEqual:conv.workDirectory]);
    ASSERT([env[@"PYTHONNOUSERSITE"] isEqual:@"1"] && [env[@"PYTHONDONTWRITEBYTECODE"] isEqual:@"1"] && [env[@"PYTORCH_ENABLE_MPS_FALLBACK"] isEqual:@"1"]);
    ASSERT([env[@"OV_OFFLINE"] isEqual:@"1"] && [env[@"HF_HUB_OFFLINE"] isEqual:@"1"], "inference never goes online");
    ASSERT([env[@"LANG"] length] > 0);
    for (NSString *k in env) {
        NSString *u = k.uppercaseString;
        ASSERT(![u containsString:@"TOKEN"] && ![u containsString:@"SECRET"] && ![u containsString:@"API_KEY"], "no secret in the environment: %s", k.UTF8String);
    }
    ASSERT(env[@"DYLD_LIBRARY_PATH"] == nil && env[@"PYTHONPATH"] == nil, "nothing inherited");
    // installs: the main runtime, no offline flags, uv facts in the request
    OVJob *inst = submitted(jobs, OVProKindEngineInstall, @{@"components": @[@"pro-env"]});
    OVProcessSpec *is = [e specForKind:OVProKindEngineInstall job:inst];
    ASSERT([is.executable isEqual:@"/usr/bin/python3"] && [is.arguments[2] isEqual:@"install"] && [is.arguments[1] hasSuffix:@"/cns_engines.py"]);
    ASSERT(is.environment[@"HF_HUB_OFFLINE"] == nil, "downloads need the network");
    NSDictionary *r = stdinOf(is);
    ASSERT([r[@"components"] isEqual:@[@"pro-env"]] && [r[@"root"] isEqual:root] && [r[@"env"] isKindOfClass:NSDictionary.class]);
    OVJob *w = submitted(jobs, OVProKindEngineWeights, @{@"components": @[@"rvc-core"]});
    ASSERT([[e specForKind:OVProKindEngineWeights job:w].arguments[2] isEqual:@"weights"]);
    OVJob *u = submitted(jobs, OVProKindEngineUpdate, @{@"components": @[@"ytdlp"]});
    ASSERT([[e specForKind:OVProKindEngineUpdate job:u].arguments[2] isEqual:@"update-ytdlp"]);
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

@interface MiniHost : NSObject <OVProRunHost>
@property NSMutableArray *log;
@property unsigned long long avail;
@end
@implementation MiniHost
- (double)physicalMemoryGB { return 16; }
- (BOOL)confirmLowMemory { return YES; }
- (void)unloadMainModels { [_log addObject:@"unload"]; }
- (unsigned long long)availableBytes { [_log addObject:@"memory"]; return _avail; }
- (unsigned long long)reclaimableBytes { return 0; }
- (BOOL)askLowFreeNeed:(unsigned long long)n available:(unsigned long long)a { [_log addObject:@"ask"]; return NO; }
- (void)requestNetwork:(void (^)(BOOL))done { done(YES); }
- (void)submitReducedBatch:(BOOL)r {}
@end

static BOOL sandboxWorks(void) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/sandbox-exec"];
    t.arguments = @[@"-p", @"(version 1)(allow default)(deny network*)", @"/usr/bin/true"];
    t.standardError = NSFileHandle.fileHandleWithNullDevice;
    return [t launchAndReturnError:nil] && ([t waitUntilExit], t.terminationStatus == 0);
}

static void testSpecRunsThroughTheJobManager(void) {
    NSString *root = tempDir();
    makeEnvs(root);
    OVJobs *jobs = [OVJobs jobsWithRoot:[root stringByAppendingPathComponent:@"jobs"]];
    OVEngines *e = [OVEngines enginesWithRoot:root jobs:jobs mainPython:@"/usr/bin/python3"];
    [e applyStatus:allReady(@"shared")];
    registerReal(jobs, e);
    MiniHost *host = [MiniHost new];
    host.log = [NSMutableArray array];
    host.avail = 12 * GB;
    e.runHost = host;
    if (!sandboxWorks()) { fprintf(stderr, "(sandbox-exec cannot be applied here: running the spec without checking the run)\n"); return; }
    OVJob *j = submitted(jobs, OVProKindConvert, @{@"input": @"/in.wav"});
    ASSERT(waitUntil(15, ^BOOL{ return j.state == OVJobSucceeded || j.state == OVJobFailed; }), "state %ld", (long)j.state);
    ASSERT(j.state == OVJobSucceeded, "%s", j.error.UTF8String);
    ASSERT([j.result[@"args"] hasSuffix:@"/cns_rvc.py infer"] && [j.result[@"offline"] isEqual:@"1"], "%s", [NSString stringWithFormat:@"%@", j.result].UTF8String);
    ASSERT([j.result[@"cwd"] hasSuffix:@"/applio"], "cwd %s", [j.result[@"cwd"] UTF8String]);
    NSString *sent = [NSString stringWithContentsOfFile:[j.workDirectory stringByAppendingPathComponent:@"stdin.json"] encoding:NSUTF8StringEncoding error:nil];
    ASSERT(sent == nil || [sent containsString:j.identifier], "stdin reached the process");
    ASSERT(host.log.count >= 2 && [host.log.firstObject isEqual:@"unload"] && [host.log.lastObject isEqual:@"memory"], "beforeStart ran the preflight: %s", [host.log componentsJoinedByString:@","].UTF8String);

    // a start from the queue that finds no memory fails with a message, and does not run the process
    host.log = [NSMutableArray array];
    host.avail = 1 * GB;
    OVJob *j2 = submitted(jobs, OVProKindConvert, @{@"input": @"/in.wav"});
    ASSERT(waitUntil(15, ^BOOL{ return j2.state == OVJobFailed; }), "state %ld", (long)j2.state);
    ASSERT([j2.error containsString:@"free memory"] && [host.log containsObject:@"ask"], "%s", j2.error.UTF8String);
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

static void testSocketConnectsThroughALongPath(void) {
    NSString *dir = tempDir();
    for (int i = 0; i < 4; i++) dir = [dir stringByAppendingPathComponent:@"a-rather-long-folder-name-for-the-realtime-socket"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"rt.sock"];
    ASSERT(path.length > 104, "the path is too long for sockaddr_un");
    char cwd[PATH_MAX];
    getcwd(cwd, sizeof cwd);
    int srv = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    strlcpy(a.sun_path, "rt.sock", sizeof a.sun_path);
    chdir(dir.fileSystemRepresentation);
    ASSERT(bind(srv, (struct sockaddr *)&a, sizeof a) == 0 && listen(srv, 1) == 0);
    chdir(cwd);
    int fd = OVEnginesConnectSocket(path);
    ASSERT(fd >= 0, "connected");
    char now[PATH_MAX];
    getcwd(now, sizeof now);
    ASSERT(strcmp(cwd, now) == 0, "the working directory is restored");
    if (fd >= 0) {
        int c = accept(srv, NULL, NULL);
        ASSERT(c >= 0);
        ASSERT(write(fd, "x", 1) == 1);
        char b = 0;
        ASSERT(read(c, &b, 1) == 1 && b == 'x');
        close(c); close(fd);
    }
    ASSERT(OVEnginesConnectSocket([dir stringByAppendingPathComponent:@"nobody.sock"]) == -1);
    ASSERT(OVEnginesConnectSocket(@"relative.sock") == -1);
    close(srv);
}

static void testKindTableCoversTheContract(void) {
    NSArray *names = @[@"pro_convert", @"rvc_import", @"rvc_info", @"rvc_fetch", @"rvc_blend", @"rvc_train", @"rvc_review", @"rvc_realtime",
                       @"stems", @"yt_import", @"edge_tts", @"engine_install", @"engine_weights", @"engine_update"];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *r in [OVEngines kindTable]) {
        NSString *k = r[@"kind"];
        [seen addObject:k];
        ASSERT([names containsObject:k], "unexpected kind %s", k.UTF8String);
        ASSERT([r[@"retryable"] boolValue] == ![k isEqual:@"rvc_realtime"], "retryable %s", k.UTF8String);
        BOOL network = [@[@"rvc_fetch", @"yt_import", @"edge_tts", @"engine_install", @"engine_weights", @"engine_update"] containsObject:k];
        ASSERT([r[@"lane"] integerValue] == (network ? OVJobLaneNetwork : OVJobLaneCompute), "lane of %s", k.UTF8String);
        BOOL light = [@[@"rvc_import", @"rvc_info"] containsObject:k];
        ASSERT([r[@"heavy"] boolValue] == (!network && !light), "heavy %s", k.UTF8String);
        ASSERT([r[@"light"] boolValue] == light && [r[@"keepStdin"] boolValue] == [k isEqual:@"rvc_realtime"], "light / keepStdin %s", k.UTF8String);
        NSArray *taken = @[@"synth", @"train", @"install", @"convert", @"separate", @"download", @"plugin", @"batch", @"clone", @"tool"];
        ASSERT(![taken containsObject:k], "%s collides with a kind of sub-plan D", k.UTF8String);
    }
    ASSERT(seen.count == names.count);
}

static void testWorkerGuardBlocksModelLoading(void) {
    NSString *root = tempDir();
    OVJobs *jobs = [OVJobs jobsWithRoot:[root stringByAppendingPathComponent:@"jobs"]];
    registerManualPro(jobs);
    OVEngines *e = [OVEngines enginesWithRoot:root jobs:jobs mainPython:nil];
    // the production list, not a copy of it
    NSSet *list = [OVEngines modelLoadingCommands];
    for (NSString *c in @[@"synth", @"clone", @"transcribe", @"prepare", @"train_voice", @"install_accent", @"enhance", @"sep_vocals", @"dfn_apply"])
        ASSERT([list containsObject:c], "%s is guarded", c.UTF8String);
    for (NSString *c in @[@"hello", @"unload", @"analyze", @"quit"]) ASSERT(![list containsObject:c], "%s is not guarded", c.UTF8String);
    for (NSString *c in list) ASSERT([e guardMessageForRequest:@{@"cmd": c}] == nil, "no pro job: %s passes", c.UTF8String);
    OVJob *busy = [jobs submitKind:OVProKindStems request:@{} origin:@"app" onFinish:nil error:nil];
    ASSERT(busy != nil);
    for (NSString *c in list)
        ASSERT([[e guardMessageForRequest:@{@"cmd": c}] isEqual:@"A pro job is running — wait for it or stop it in Jobs"], "%s waits", c.UTF8String);
    ASSERT([e guardMessageForRequest:@{@"cmd": @"unload"}] == nil && [e guardMessageForRequest:@{}] == nil);
    // wired into OVWorker: a direct request is refused with the message
    OVWorker.requestGuard = ^NSString *(NSDictionary *req) { return [e guardMessageForRequest:req]; };
    __block NSString *err = nil;
    __block int calls = 0;
    [OVWorker.shared request:@{@"cmd": @"sep_vocals"} status:nil progress:nil done:^(NSDictionary *d, NSString *m) { err = m; calls++; }];
    ASSERT(calls == 1 && [err containsString:@"pro job is running"], "%s", err.UTF8String);
    OVWorker.requestGuard = nil;
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

static void testKeepStdinOpenUntilStop(void) {
    NSString *root = tempDir();
    OVJobs *jobs = [OVJobs jobsWithRoot:[root stringByAppendingPathComponent:@"jobs"]];
    for (NSNumber *keep in @[@NO, @YES]) {
        NSString *kind = keep.boolValue ? @"hold" : @"drop";
        [jobs registerKind:kind lane:OVJobLaneCompute retryable:NO title:^NSString *(NSDictionary *r) { return kind; }
                   factory:OVProcessRunnerFactory(^OVProcessSpec *(OVJob *job) {
            OVProcessSpec *s = [OVProcessSpec new];
            s.executable = @"/bin/sh";
            s.arguments = @[@"-c", @"read a; read b; echo '{\"event\":\"result\",\"data\":{}}'"];   // a second line, or EOF
            s.environment = @{@"PATH": @"/usr/bin:/bin"};
            s.stdinData = [@"{}\n" dataUsingEncoding:NSUTF8StringEncoding];
            s.keepStdinOpen = keep.boolValue;
            return s;
        }) onSuccess:nil];
    }
    OVJob *drop = [jobs submitKind:@"drop" request:@{} origin:@"app" onFinish:nil error:nil];
    ASSERT(waitUntil(5, ^BOOL{ return drop.state == OVJobSucceeded; }), "without keepStdinOpen the process reads EOF and ends");
    OVJob *hold = [jobs submitKind:@"hold" request:@{} origin:@"app" onFinish:nil error:nil];
    ASSERT(waitUntil(5, ^BOOL{ return hold.state == OVJobRunning; }));
    [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
    ASSERT(hold.state == OVJobRunning, "with keepStdinOpen it keeps waiting for the next line");
    [jobs stop:hold];
    ASSERT(waitUntil(8, ^BOOL{ return hold.state == OVJobStopped; }), "stop ends it (state %ld)", (long)hold.state);
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

#pragma mark -

static void runCase(NSString *name, void (^body)(void)) {
    gCase = name; gCaseFailures = 0;
    @autoreleasepool { body(); }
    printf("%s %s\n", gCaseFailures ? "FAIL" : "PASS", name.UTF8String);
    if (gCaseFailures) gFailures++;
}

int main(void) {
    @autoreleasepool {
        NSString *data = tempDir();
        setenv("OV_DATA_DIR", data.fileSystemRepresentation, 1);
        runCase(@"testEnginesStateFromStatusJson", ^{ testEnginesStateFromStatusJson(); });
        runCase(@"testInstallRefusedWhileProJobActive", ^{ testInstallRefusedWhileProJobActive(); });
        runCase(@"testLayoutSplitMapsLogicalNames", ^{ testLayoutSplitMapsLogicalNames(); });
        runCase(@"testPeakBytesFromStatus", ^{ testPeakBytesFromStatus(); });
        runCase(@"testSpecForProKindRunsUnderSandbox", ^{ testSpecForProKindRunsUnderSandbox(); });
        runCase(@"testSpecEnvironmentIsADictionary", ^{ testSpecEnvironmentIsADictionary(); });
        runCase(@"testSpecRunsThroughTheJobManager", ^{ testSpecRunsThroughTheJobManager(); });
        runCase(@"testSocketConnectsThroughALongPath", ^{ testSocketConnectsThroughALongPath(); });
        runCase(@"testKindTableCoversTheContract", ^{ testKindTableCoversTheContract(); });
        runCase(@"testWorkerGuardBlocksModelLoading", ^{ testWorkerGuardBlocksModelLoading(); });
        runCase(@"testKeepStdinOpenUntilStop", ^{ testKeepStdinOpenUntilStop(); });
        [NSFileManager.defaultManager removeItemAtPath:data error:nil];
    }
    return gFailures ? 1 : 0;
}
