#import "OVEngines.h"
#import "OVPaths.h"
#import "OVRuntime.h"
#import "OVNetwork.h"
#import "OVLocale.h"
#import "OVMemory.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <sys/stat.h>

NSNotificationName const OVEnginesDidChangeNotification = @"OVEnginesDidChangeNotification";
NSString *const OVEnginePro = @"pro";
NSString *const OVEngineEdge = @"edge";

NSString *const OVProKindConvert = @"pro_convert", *const OVProKindRvcImport = @"rvc_import", *const OVProKindRvcInfo = @"rvc_info",
          *const OVProKindRvcFetch = @"rvc_fetch", *const OVProKindRvcBlend = @"rvc_blend", *const OVProKindRvcTrain = @"rvc_train",
          *const OVProKindRvcReview = @"rvc_review", *const OVProKindRealtime = @"rvc_realtime", *const OVProKindStems = @"stems",
          *const OVProKindYouTube = @"yt_import", *const OVProKindEdge = @"edge_tts", *const OVProKindEngineInstall = @"engine_install",
          *const OVProKindEngineWeights = @"engine_weights", *const OVProKindEngineUpdate = @"engine_update";

@interface OVEngineComponent ()
@property (copy) NSString *identifier, *title, *license;
@property OVEngineState state;
@property unsigned long long downloadBytes, diskBytes;
@property BOOL optional;
@end
@implementation OVEngineComponent
@end

#pragma mark - The kind table

// One row per kind. Later tasks (7.8 and on) only add rows; nothing else in this file knows a kind by name except
// the helpers that map a request to an engine name or a peak option.
typedef NSArray<NSString *> *(^OVProCommandBlock)(NSDictionary *req);   // @[script, command]

static OVProCommandBlock FixedCmd(NSString *script, NSString *command) { return ^NSArray *(NSDictionary *r) { return @[script, command]; }; }

static NSDictionary *Row(NSString *kind, OVJobLane lane, BOOL retryable, BOOL heavy, NSInteger net, BOOL denyNetwork,
                         BOOL installKind, NSString *cwd, NSArray<NSString *> *roots, OVProCommandBlock cmd) {
    return @{@"kind": kind, @"lane": @(lane), @"retryable": @(retryable), @"heavy": @(heavy), @"net": @(net),
             @"sandbox": @(denyNetwork), @"install": @(installKind), @"cwd": cwd ?: @"", @"roots": roots, @"cmd": cmd};
}

static NSDictionary *With(NSDictionary *row, NSDictionary *extra) {
    NSMutableDictionary *m = [row mutableCopy];
    [m addEntriesFromDictionary:extra];
    return m;
}

static NSArray<NSDictionary *> *KindTable(void) {
    static NSArray *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        OVProCommandBlock convert = ^NSArray *(NSDictionary *r) {
            if ([r[@"engine"] isEqual:@"seedvc"]) return @[@"cns_seedvc.py", @"convert"];
            if ([r[@"mode"] isEqual:@"batch"] || [r[@"inputs"] isKindOfClass:NSArray.class]) return @[@"cns_rvc.py", @"batch"];
            return @[@"cns_rvc.py", @"infer"];
        };
        // net: an OVNetFeature the run needs, or -1. cwd: "applio" = the Applio folder. roots: where the sandbox lets it
        // write (the job's work folder is always one).
        t = @[
            Row(OVProKindConvert,       OVJobLaneCompute, YES, YES, -1, YES, NO, @"applio", @[@"outputs"], convert),
            With(Row(OVProKindRvcImport, OVJobLaneCompute, YES, NO, -1, YES, NO, @"applio", @[@"models"], FixedCmd(@"cns_rvc.py", @"import")), @{@"light": @YES}),
            With(Row(OVProKindRvcInfo,   OVJobLaneCompute, YES, NO, -1, YES, NO, @"applio", @[], FixedCmd(@"cns_rvc.py", @"info")), @{@"light": @YES}),
            Row(OVProKindRvcFetch,      OVJobLaneNetwork, YES, NO,  OVNetModelDownload, NO, NO, @"applio", @[@"models"], FixedCmd(@"cns_rvc.py", @"fetch")),
            Row(OVProKindRvcBlend,      OVJobLaneCompute, YES, YES, -1, YES, NO, @"applio", @[@"models"], FixedCmd(@"cns_rvc.py", @"blend")),
            Row(OVProKindRvcTrain,      OVJobLaneCompute, YES, YES, -1, YES, NO, @"applio", @[@"training", @"datasets", @"models"], FixedCmd(@"cns_train.py", @"run")),
            Row(OVProKindRvcReview,     OVJobLaneCompute, YES, YES, -1, YES, NO, @"applio", @[@"training"], FixedCmd(@"cns_train.py", @"review")),
            With(Row(OVProKindRealtime, OVJobLaneCompute, NO, YES, -1, YES, NO, @"applio", @[], FixedCmd(@"cns_realtime.py", @"run")), @{@"keepStdin": @YES}),
            Row(OVProKindStems,         OVJobLaneCompute, YES, YES, -1, YES, NO, @"",       @[@"outputs"], FixedCmd(@"cns_stems.py", @"separate")),
            Row(OVProKindYouTube,       OVJobLaneNetwork, YES, NO,  OVNetYouTube, NO, NO, @"", @[@"outputs"], FixedCmd(@"cns_ytdl.py", @"fetch")),
            Row(OVProKindEdge,          OVJobLaneNetwork, YES, NO,  OVNetEdgeTTS, NO, NO, @"", @[@"outputs"], FixedCmd(@"cns_edge.py", @"synth")),
            Row(OVProKindEngineInstall, OVJobLaneNetwork, YES, NO,  -1, NO, YES, @"", @[], FixedCmd(@"cns_engines.py", @"install")),
            Row(OVProKindEngineWeights, OVJobLaneNetwork, YES, NO,  -1, NO, YES, @"", @[], FixedCmd(@"cns_engines.py", @"weights")),
            Row(OVProKindEngineUpdate,  OVJobLaneNetwork, YES, NO,  OVNetYouTube, NO, YES, @"", @[], FixedCmd(@"cns_engines.py", @"update-ytdlp")),
        ];
    });
    return t;
}

static NSString *J(NSString *a, NSString *b) { return [a stringByAppendingPathComponent:b]; }

/// Defaults of status.peak_gb (cns_engines.PEAK_GB), used until the first status arrives.
static NSDictionary<NSString *, NSNumber *> *DefaultPeaks(void) {
    return @{@"infer": @3.4, @"seedvc": @4.0, @"train": @10.0, @"train_b2": @8.2, @"realtime": @2.7, @"mdx": @6.5,
             @"roformer": @6.6, @"blend": @1.0, @"ytdlp": @0.3, @"edge": @0.3};
}

#pragma mark - OVEngines

@interface OVEngines ()
@property (copy) NSString *root, *layout;
@property (copy) NSArray<OVEngineComponent *> *components;
@property (copy) NSString *mainPythonOverride;
@property OVJobs *jobs;
@property BOOL refreshing, refreshAgain, statusLoaded, inBeforeStart;
@property (copy) NSString *statusError;
@property (copy) NSDate *statusDate;
@property (copy) NSDictionary<NSString *, NSNumber *> *peaks;
@property NSMutableSet<NSString *> *settledJobs;
@end

@implementation OVEngines

+ (instancetype)shared {
    static OVEngines *e;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ e = [[OVEngines alloc] initWithRoot:[OVPaths engines] jobs:nil mainPython:nil]; });
    return e;
}

+ (instancetype)enginesWithRoot:(NSString *)root jobs:(OVJobs *)jobs mainPython:(NSString *)python {
    return [[OVEngines alloc] initWithRoot:root jobs:jobs mainPython:python];
}

- (instancetype)initWithRoot:(NSString *)root jobs:(OVJobs *)jobs mainPython:(NSString *)python {
    if ((self = [super init])) {
        _root = [root copy];
        _jobs = jobs;
        _mainPythonOverride = python;
        _layout = @"shared";
        _components = @[];
        _peaks = DefaultPeaks();
        _settledJobs = [NSMutableSet set];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(jobsChanged:) name:OVJobsDidChangeNotification object:nil];
    }
    return self;
}

- (OVJobs *)activeJobs { return _jobs ?: OVJobs.shared; }

+ (nullable NSString *)pythonForEngine:(NSString *)name { return [OVEngines.shared pythonForEngine:name]; }

- (NSString *)mainPython {
    if (_mainPythonOverride) return _mainPythonOverride;
    return [OVRuntime shared].pythonPath ?: [OVPaths ownPython];
}

#pragma mark State

- (OVEngineComponent *)componentWithId:(NSString *)identifier {
    for (OVEngineComponent *c in _components) if ([c.identifier isEqualToString:identifier]) return c;
    return nil;
}

- (BOOL)isReady:(NSString *)cid { return [self componentWithId:cid].state == OVEngineReady; }

- (NSString *)envFolder:(NSString *)cid {
    NSString *f = @{@"pro-env": @"pro", @"applio-env": @"applio-env", @"edge": @"edge"}[cid];
    return f ?: @"pro";
}

- (nullable NSString *)pythonForEngine:(NSString *)name {
    BOOL split = [_layout isEqualToString:@"split"];
    NSString *env = @"pro-env";
    NSArray<NSString *> *need;
    if ([name isEqualToString:OVEnginePro] || [name isEqualToString:@"stems"] || [name isEqualToString:@"plugins"]) need = @[@"pro-env"];
    else if ([name isEqualToString:OVEngineEdge]) { env = @"edge"; need = @[@"edge"]; }
    else if ([name isEqualToString:@"rvc"] || [name isEqualToString:@"realtime"]) {
        env = split ? @"applio-env" : @"pro-env";
        need = @[env, @"applio"];
    }
    else if ([name isEqualToString:@"seedvc"]) need = @[@"pro-env", @"seedvc"];
    else if ([name isEqualToString:@"ytdlp"]) need = @[@"pro-env", @"ytdlp"];
    else return nil;
    for (NSString *c in need) if (![self isReady:c]) return nil;
    NSString *py = J(J(J(_root, [self envFolder:env]), @".venv"), @"bin/python");
    return [NSFileManager.defaultManager isExecutableFileAtPath:py] ? py : nil;
}

- (BOOL)proJobActive {
    for (OVJob *j in [self activeJobs].all) {
        if (!j.active) continue;
        NSDictionary *info = [OVEngines infoForKind:j.kind];
        if (info && [info[@"lane"] integerValue] == OVJobLaneCompute) return YES;
    }
    return NO;
}

- (BOOL)installActive {
    for (OVJob *j in [self activeJobs].all) {
        if (!j.active) continue;
        if ([j.kind isEqualToString:OVProKindEngineInstall] || [j.kind isEqualToString:OVProKindEngineWeights] ||
            [j.kind isEqualToString:OVProKindEngineUpdate]) return YES;
    }
    return NO;
}

- (OVEngineState)stateFromString:(NSString *)s {
    if ([s isEqualToString:@"ready"]) return OVEngineReady;
    if ([s isEqualToString:@"partial"]) return OVEnginePartial;
    if ([s isEqualToString:@"broken"]) return OVEngineBroken;
    return OVEngineNotInstalled;
}

- (void)applyStatus:(NSDictionary *)status {
    NSMutableSet<NSString *> *installing = [NSMutableSet set];
    for (OVJob *j in [self activeJobs].all) {
        if (!j.active) continue;
        if ([j.kind isEqualToString:OVProKindEngineInstall] || [j.kind isEqualToString:OVProKindEngineWeights]) {
            id ids = j.request[@"components"];
            if ([ids isKindOfClass:NSArray.class]) [installing addObjectsFromArray:ids];
        }
    }
    NSMutableArray *list = [NSMutableArray array];
    NSArray *rows = [status[@"components"] isKindOfClass:NSArray.class] ? status[@"components"] : @[];
    for (NSDictionary *r in rows) {
        if (![r isKindOfClass:NSDictionary.class] || ![r[@"id"] isKindOfClass:NSString.class]) continue;
        OVEngineComponent *c = [OVEngineComponent new];
        c.identifier = r[@"id"];
        c.title = [r[@"title"] isKindOfClass:NSString.class] ? r[@"title"] : r[@"id"];
        c.license = [r[@"license"] isKindOfClass:NSString.class] ? r[@"license"] : @"";
        c.state = [self stateFromString:r[@"state"]];
        c.downloadBytes = [r[@"download_bytes"] unsignedLongLongValue];
        c.diskBytes = [r[@"disk_bytes"] unsignedLongLongValue];
        c.optional = [r[@"optional"] boolValue];
        if (c.state != OVEngineReady && [installing containsObject:c.identifier]) c.state = OVEngineInstalling;
        [list addObject:c];
    }
    self.components = list;
    self.statusLoaded = YES;
    self.statusError = nil;
    self.statusDate = [NSDate date];
    NSString *layout = status[@"layout"];
    self.layout = [layout isEqualToString:@"split"] ? @"split" : @"shared";
    if ([status[@"peak_gb"] isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *p = [DefaultPeaks() mutableCopy];
        for (NSString *k in status[@"peak_gb"]) if ([status[@"peak_gb"][k] isKindOfClass:NSNumber.class]) p[k] = status[@"peak_gb"][k];
        self.peaks = p;
    }
    [NSNotificationCenter.defaultCenter postNotificationName:OVEnginesDidChangeNotification object:self];
}

#pragma mark Running cns_engines.py

/// Runs `cns_engines.py <command>` in the main runtime with one JSON request on stdin and returns the `result` data.
- (NSDictionary *)runEngines:(NSString *)command request:(NSDictionary *)req timeout:(NSTimeInterval)timeout error:(NSString **)error {
    NSString *py = [self mainPython];
    if (![NSFileManager.defaultManager isExecutableFileAtPath:py]) {
        if (error) *error = L(@"The main engine isn’t installed yet — set it up on the Setup page first.");
        return nil;
    }
    NSMutableDictionary *body = [req mutableCopy];
    body[@"root"] = _root;
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:py];
    t.arguments = @[@"-s", [OVEngines scriptPath:@"cns_engines.py"], command];
    t.environment = @{@"PATH": @"/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", @"HOME": NSHomeDirectory(),
                      @"PYTHONNOUSERSITE": @"1", @"PYTHONDONTWRITEBYTECODE": @"1", @"LANG": @"en_US.UTF-8"};
    NSPipe *in = [NSPipe pipe], *out = [NSPipe pipe];
    t.standardInput = in; t.standardOutput = out; t.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSError *err = nil;
    if (![t launchAndReturnError:&err]) { if (error) *error = err.localizedDescription; return nil; }
    NSMutableData *data = [NSMutableData data];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [data appendData:[out.fileHandleForReading readDataToEndOfFile]];
        dispatch_semaphore_signal(done);
    });
    NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:body options:0 error:nil] mutableCopy];
    [line appendBytes:"\n" length:1];
    @try { [in.fileHandleForWriting writeData:line]; [in.fileHandleForWriting closeFile]; } @catch (NSException *e) {}
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) {
        [t terminate];
        if (error) *error = L(@"The engine check took too long.");
        return nil;
    }
    [t waitUntilExit];
    NSDictionary *result = nil;
    NSString *failure = nil;
    for (NSString *l in [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] componentsSeparatedByString:@"\n"]) {
        if (!l.length) continue;
        NSDictionary *ev = [NSJSONSerialization JSONObjectWithData:[l dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![ev isKindOfClass:NSDictionary.class]) continue;
        if ([ev[@"event"] isEqual:@"result"] && [ev[@"data"] isKindOfClass:NSDictionary.class]) result = ev[@"data"];
        else if ([ev[@"event"] isEqual:@"error"]) failure = [ev[@"msg"] description];
    }
    if (!result && error) *error = failure ?: [NSString stringWithFormat:L(@"The task could not start: %@"), [NSString stringWithFormat:@"exit %d", t.terminationStatus]];
    return result;
}

- (void)refresh {
    if (_refreshing) { _refreshAgain = YES; return; }
    _refreshing = YES;
    [NSNotificationCenter.defaultCenter postNotificationName:OVEnginesDidChangeNotification object:self];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *err = nil;
        NSDictionary *st = [self runEngines:@"status" request:@{} timeout:60 error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.refreshing = NO;
            if (st) [self applyStatus:st];
            else {
                self.statusError = err ?: L(@"The engine check failed.");
                [NSNotificationCenter.defaultCenter postNotificationName:OVEnginesDidChangeNotification object:self];
            }
            if (self.refreshAgain) { self.refreshAgain = NO; [self refresh]; }
        });
    });
}

- (void)jobsChanged:(NSNotification *)n {
    OVJob *j = [n.object isKindOfClass:OVJob.class] ? n.object : nil;
    if (!j || ![[OVEngines infoForKind:j.kind][@"install"] boolValue]) return;
    if (j.active) { [self applyStatusKeepingRows]; return; }
    if ([_settledJobs containsObject:j.identifier]) return;
    NSMutableSet *live = [NSMutableSet set];
    for (OVJob *x in [self activeJobs].all) [live addObject:x.identifier];
    [_settledJobs intersectSet:live];   // forget jobs that were removed from the list
    [_settledJobs addObject:j.identifier];
    [self refresh];   // a failed or stopped install leaves "partial" behind: show it
}

/// A running install marks its components Installing without asking Python.
- (void)applyStatusKeepingRows {
    NSMutableArray *rows = [NSMutableArray array];
    for (OVEngineComponent *c in _components) {
        NSString *s = c.state == OVEngineReady ? @"ready" : c.state == OVEngineBroken ? @"broken" :
                      c.state == OVEngineNotInstalled ? @"notinstalled" : @"partial";
        [rows addObject:@{@"id": c.identifier, @"title": c.title, @"license": c.license, @"state": s, @"download_bytes": @(c.downloadBytes),
                          @"disk_bytes": @(c.diskBytes), @"optional": @(c.optional)}];
    }
    NSDate *keep = _statusDate;
    BOOL loaded = _statusLoaded;
    [self applyStatus:@{@"layout": _layout, @"components": rows}];
    self.statusDate = keep;           // this was not a status from Python
    self.statusLoaded = loaded;
}

#pragma mark Install, uninstall, update


static BOOL IsWeightId(NSString *i) { return [i hasPrefix:@"rvc-core"] || [i hasPrefix:@"rvc-fcpe"] || [i hasPrefix:@"rvc-train-"] || [i hasPrefix:@"stems-"]; }

- (OVJob *)install:(NSArray<NSString *> *)ids error:(NSString **)error {
    if (!ids.count) { if (error) *error = L(@"Nothing to install."); return nil; }
    if (self.proJobActive) { if (error) *error = L(@"A pro job is running — wait for it or stop it in Jobs"); return nil; }
    if ([OVNetwork decisionFor:OVNetModelDownload] != OVNetAllowed) { if (error) *error = [OVNetwork blockedMessageFor:OVNetModelDownload]; return nil; }
    BOOL weightsOnly = YES;
    for (NSString *i in ids) if (!IsWeightId(i)) weightsOnly = NO;
    NSString *kind = weightsOnly ? OVProKindEngineWeights : OVProKindEngineInstall;
    return [[self activeJobs] submitKind:kind request:@{@"components": ids} origin:@"app" onFinish:nil error:error];
}

- (BOOL)uninstall:(NSArray<NSString *> *)ids error:(NSString **)error {
    if (self.proJobActive || [self installActive]) { if (error) *error = L(@"A pro job is running — wait for it or stop it in Jobs"); return NO; }
    if (!ids.count) { if (error) *error = L(@"Nothing to install."); return NO; }
    NSString *err = nil;
    NSDictionary *res = [self runEngines:@"uninstall" request:@{@"components": ids} timeout:600 error:&err];
    if (!res) { if (error) *error = err; return NO; }
    [self applyStatus:res];
    return YES;
}

/// Same, off the main thread (deleting gigabytes takes a while); completion runs on main. Pages use this one.
- (void)uninstall:(NSArray<NSString *> *)ids completion:(void (^)(BOOL ok, NSString *_Nullable error))done {
    if (self.proJobActive || [self installActive]) { done(NO, L(@"A pro job is running — wait for it or stop it in Jobs")); return; }
    if (!ids.count) { done(NO, L(@"Nothing to install.")); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil;
        NSDictionary *res = [self runEngines:@"uninstall" request:@{@"components": ids} timeout:600 error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (res) [self applyStatus:res];
            done(res != nil, res ? nil : (err ?: L(@"The engine check failed.")));
        });
    });
}

#pragma mark Guard

/// Commands of the main engine that load the voice or speech models (or the separation / enhancement models).
+ (NSSet<NSString *> *)modelLoadingCommands {
    return [NSSet setWithObjects:@"synth", @"clone", @"transcribe", @"prepare", @"train_voice", @"install_accent", @"enhance",
                                 @"sep_vocals", @"dfn_apply", nil];
}

/// The OVWorker.requestGuard: a message while a pro job holds the memory, nil otherwise.
- (NSString *)guardMessageForRequest:(NSDictionary *)req {
    if (![req[@"cmd"] isKindOfClass:NSString.class] || ![[OVEngines modelLoadingCommands] containsObject:req[@"cmd"]]) return nil;
    return self.proJobActive ? L(@"A pro job is running — wait for it or stop it in Jobs") : nil;
}

/// Any job of the compute lane is queued or running (a synth, a clone, a pro job).
- (BOOL)computeLaneBusy {
    for (OVJob *j in [self activeJobs].all) if (j.active && j.lane == OVJobLaneCompute) return YES;
    return NO;
}

- (OVJob *)updateYtDlp:(NSString **)error {
    if (OVNetwork.offline) { if (error) *error = [OVNetwork blockedMessageFor:OVNetYouTube]; return nil; }
    if (self.proJobActive) { if (error) *error = L(@"A pro job is running — wait for it or stop it in Jobs"); return nil; }
    return [[self activeJobs] submitKind:OVProKindEngineUpdate request:@{@"components": @[@"ytdlp"]} origin:@"app" onFinish:nil error:error];
}

#pragma mark Memory

- (unsigned long long)peakBytesForKind:(NSString *)kind option:(NSString *)option {
    NSString *key = nil;
    if ([kind isEqualToString:OVProKindConvert]) key = [option isEqualToString:@"seedvc"] ? @"seedvc" : @"infer";
    else if ([kind isEqualToString:OVProKindRvcBlend]) key = @"blend";
    else if ([kind isEqualToString:OVProKindRvcTrain]) key = [option isEqualToString:@"batch2"] ? @"train_b2" : @"train";
    else if ([kind isEqualToString:OVProKindRealtime]) key = @"realtime";
    else if ([kind isEqualToString:OVProKindStems]) key = [option.lowercaseString containsString:@"roformer"] ? @"roformer" : @"mdx";
    else if ([kind isEqualToString:OVProKindYouTube]) key = @"ytdlp";
    else if ([kind isEqualToString:OVProKindEdge]) key = @"edge";
    else if ([kind isEqualToString:OVProKindRvcImport] || [kind isEqualToString:OVProKindRvcInfo] || [kind isEqualToString:OVProKindRvcReview]) key = @"blend";
    if (!key) return 0;
    double gb = [_peaks[key] doubleValue];
    return (unsigned long long)(gb * (double)(1ULL << 30));
}

+ (NSString *)peakOptionForKind:(NSString *)kind request:(NSDictionary *)req {
    if ([kind isEqualToString:OVProKindConvert]) return [req[@"engine"] isEqual:@"seedvc"] ? @"seedvc" : @"rvc";
    if ([kind isEqualToString:OVProKindRvcTrain]) {
        NSInteger b = [req[@"batch_size"] integerValue];
        return b > 0 && b <= 2 ? @"batch2" : nil;
    }
    if ([kind isEqualToString:OVProKindStems]) return [req[@"model"] isKindOfClass:NSString.class] ? req[@"model"] : nil;
    return nil;
}

#pragma mark Kinds

+ (NSArray<NSDictionary *> *)kindTable {
    NSMutableArray *a = [NSMutableArray array];
    for (NSDictionary *r in KindTable()) {
        [a addObject:@{@"kind": r[@"kind"], @"lane": r[@"lane"], @"retryable": r[@"retryable"], @"heavy": r[@"heavy"], @"light": r[@"light"] ?: @NO, @"keepStdin": r[@"keepStdin"] ?: @NO, @"net": r[@"net"]}];
    }
    return a;
}

+ (NSDictionary *)infoForKind:(NSString *)kind {
    for (NSDictionary *r in KindTable()) if ([r[@"kind"] isEqualToString:kind]) return r;
    return nil;
}

+ (NSString *)engineNameForKind:(NSString *)kind request:(NSDictionary *)req {
    NSDictionary *info = [self infoForKind:kind];
    if (!info || [info[@"install"] boolValue]) return nil;
    if ([kind isEqualToString:OVProKindConvert]) return [req[@"engine"] isEqual:@"seedvc"] ? @"seedvc" : @"rvc";
    if ([kind isEqualToString:OVProKindRealtime]) return @"realtime";
    if ([kind isEqualToString:OVProKindStems]) return @"stems";
    if ([kind isEqualToString:OVProKindYouTube]) return @"ytdlp";
    if ([kind isEqualToString:OVProKindEdge]) return OVEngineEdge;
    return @"rvc";
}

/// The one sandbox profile: Resources/sandbox/engine.sb (the app bundle, or the repository copy when tests run from its root).
+ (NSString *)sandboxFile {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *c = [NSMutableArray array];
    NSString *env = NSProcessInfo.processInfo.environment[@"CNS_SANDBOX_FILE"];
    if (env.length) [c addObject:env];
    [c addObject:J(NSBundle.mainBundle.resourcePath ?: @"", @"sandbox/engine.sb")];
    [c addObject:J(fm.currentDirectoryPath, @"Resources/sandbox/engine.sb")];
    for (NSString *p in c) if ([fm fileExistsAtPath:p]) return p;
    return nil;
}

static NSString *DarwinDir(int name, NSString *fallback) {
    char buf[PATH_MAX];
    if (confstr(name, buf, sizeof buf) == 0) return fallback;
    return [[NSString stringWithUTF8String:buf] stringByResolvingSymlinksInPath];
}

/// `-f engine.sb -D KEY=VALUE ...` for sandbox-exec. net: @"deny-ip" or @"allow". At most four extra write folders.
+ (NSArray<NSString *> *)sandboxArgumentsWithFile:(NSString *)file net:(NSString *)net work:(NSString *)work out:(NSString *)out
                                            roots:(NSArray<NSString *> *)roots {
    NSMutableArray *a = [NSMutableArray arrayWithObjects:@"-f", file, nil];
    NSString *w = work.stringByResolvingSymlinksInPath;
    NSMutableDictionary<NSString *, NSString *> *d = [NSMutableDictionary dictionaryWithDictionary:@{
        @"NET": net, @"WORK": w, @"OUT": (out ?: work).stringByResolvingSymlinksInPath,
        @"DCACHE": DarwinDir(_CS_DARWIN_USER_CACHE_DIR, w), @"DTEMP": DarwinDir(_CS_DARWIN_USER_TEMP_DIR, w)}];
    for (int i = 0; i < 4; i++) d[[NSString stringWithFormat:@"ROOT%d", i + 1]] = i < (int)roots.count ? roots[i].stringByResolvingSymlinksInPath : w;
    for (NSString *k in [d.allKeys sortedArrayUsingSelector:@selector(compare:)]) [a addObjectsFromArray:@[@"-D", [NSString stringWithFormat:@"%@=%@", k, d[k]]]];
    return a;
}

- (NSData *)stdinForRequest:(NSDictionary *)req job:(OVJob *)job reduced:(BOOL)reduced {
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    [req enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) { if (![k hasPrefix:@"_"]) r[k] = v; }];
    r[@"work_dir"] = job.workDirectory;
    r[@"outputs_dir"] = [OVPaths outputs];
    r[@"job_id"] = job.identifier;
    r[@"root"] = _root;
    if (reduced) r[@"batch_size"] = @2;
    NSMutableData *d = [[NSJSONSerialization dataWithJSONObject:r options:0 error:nil] mutableCopy];
    [d appendBytes:"\n" length:1];
    return d;
}

- (NSData *)installStdin:(NSDictionary *)req job:(OVJob *)job extra:(NSDictionary *)extra {
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    [req enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) { if (![k hasPrefix:@"_"]) r[k] = v; }];
    [r addEntriesFromDictionary:extra];
    r[@"root"] = _root;
    r[@"job_id"] = job.identifier;
    NSMutableData *d = [[NSJSONSerialization dataWithJSONObject:r options:0 error:nil] mutableCopy];
    [d appendBytes:"\n" length:1];
    return d;
}

static OVProcessSpec *Refused(NSString *why) {
    OVProcessSpec *s = [OVProcessSpec new];
    s.executable = @"";
    s.launchError = why;
    return s;
}

- (OVProcessSpec *)specForKind:(NSString *)kind job:(OVJob *)job {
    NSDictionary *info = [OVEngines infoForKind:kind];
    if (!info) return nil;
    NSDictionary *req = job.runnerRequest;
    BOOL install = [info[@"install"] boolValue];
    NSString *engineName = [OVEngines engineNameForKind:kind request:req];
    NSString *py = install ? [self mainPython] : (engineName ? [self pythonForEngine:engineName] : nil);
    if (!py) return Refused([NSString stringWithFormat:L(@"%@ needs its engine — install it first."), L(@"This feature")]);
    OVProcessSpec *spec = [OVProcessSpec new];
    NSString *work = job.workDirectory;
    [NSFileManager.defaultManager createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:nil];
    NSArray<NSString *> *cmd = ((OVProCommandBlock)info[@"cmd"])(req);
    NSString *script = [OVEngines scriptPath:cmd[0]];

    BOOL denyNet = [info[@"sandbox"] boolValue];
    NSMutableDictionary *env = [@{
        @"PATH": @"/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
        @"HOME": NSHomeDirectory(),
        @"TMPDIR": work,
        @"LANG": @"en_US.UTF-8",
        @"PYTHONNOUSERSITE": @"1",
        @"PYTHONDONTWRITEBYTECODE": @"1",
        @"PYTHONIOENCODING": @"utf-8",
        @"PYTORCH_ENABLE_MPS_FALLBACK": @"1",
        @"CNS_ENGINES_ROOT": _root,
        @"OV_LANG": [OVLocale uiLanguage],
        @"XDG_CACHE_HOME": J(work, @"cache"),
        @"NUMBA_CACHE_DIR": J(work, @"cache/numba"),
        @"MPLCONFIGDIR": J(work, @"cache/mpl"),
    } mutableCopy];
    if (denyNet || OVNetwork.offline) env[@"OV_OFFLINE"] = @"1";
    if (!install) env[@"HF_HUB_OFFLINE"] = @"1";
    if ([engineName isEqualToString:@"seedvc"]) {
        NSString *hf = J(J(_root, @"seedvc"), @"hf");
        [env addEntriesFromDictionary:@{@"HF_HOME": hf, @"HF_HUB_CACHE": J(hf, @"hub"), @"HF_HUB_OFFLINE": @"1", @"TRANSFORMERS_OFFLINE": @"1"}];
    }
    if ([kind isEqualToString:OVProKindRvcTrain] || [kind isEqualToString:OVProKindRvcReview]) env[@"APPLIO_LOGS_DIR"] = J(_root, @"training");
    if (install) {
        NSMutableDictionary *extra = [NSMutableDictionary dictionary];
        NSString *uv = [[OVRuntime shared] findUV];
        if (uv) extra[@"uv"] = uv;
        extra[@"env"] = [[OVRuntime shared] uvEnv];
        spec.stdinData = [self installStdin:req job:job extra:extra];
    } else {
        spec.stdinData = [self stdinForRequest:req job:job reduced:NO];
    }
    spec.environment = env;
    spec.keepStdinOpen = [info[@"keepStdin"] boolValue];
    spec.currentDirectory = work;
    if ([info[@"cwd"] isEqual:@"applio"]) {
        NSString *applio = J(_root, @"applio");
        if ([NSFileManager.defaultManager fileExistsAtPath:applio]) spec.currentDirectory = applio;
    }

    NSArray<NSString *> *args = @[@"-s", script, cmd[1]];
    if (install) {
        spec.executable = py;
        spec.arguments = args;
    } else {
        // Every engine process runs under the one profile engine.sb: writes only in the work folder, the outputs and the
        // kind's own roots; no IP traffic for the kinds that need none (AF_UNIX, DataLoader and torch_shm_manager still
        // work). Without sandbox-exec or the profile nothing starts.
        NSString *file = [OVEngines sandboxFile];
        if (![NSFileManager.defaultManager isExecutableFileAtPath:@"/usr/bin/sandbox-exec"]) return Refused(L(@"Can’t start this safely: the macOS sandbox tool is missing."));
        if (!file) return Refused(L(@"Can’t start this safely: the sandbox profile is missing."));
        NSDictionary *tokens = @{@"models": [OVPaths rvcModels], @"training": [OVPaths rvcTraining], @"datasets": [OVPaths rvcDatasets]};
        NSMutableArray *roots = [NSMutableArray array];
        BOOL toOutputs = NO;
        for (NSString *t in info[@"roots"]) {
            if ([t isEqual:@"outputs"]) toOutputs = YES;
            else if (tokens[t]) [roots addObject:tokens[t]];
        }
        for (NSString *k in @[@"dest_dir", @"output_dir"]) {
            NSString *d = req[k];
            if ([d isKindOfClass:NSString.class] && d.isAbsolutePath) [roots addObject:d];
        }
        if (roots.count > 4) return Refused(L(@"Too many output folders for this task."));
        NSString *out = toOutputs ? [OVPaths outputs] : work;
        for (NSString *r in [roots arrayByAddingObjectsFromArray:@[work, out]])
            [NSFileManager.defaultManager createDirectoryAtPath:r withIntermediateDirectories:YES attributes:nil error:nil];
        NSArray *sb = [OVEngines sandboxArgumentsWithFile:file net:denyNet ? @"deny-ip" : @"allow" work:work out:out roots:roots];
        env[@"CNS_SANDBOXED"] = @"1";   // cns_train must not wrap its child a second time
        env[@"CNS_SANDBOX_FILE"] = file;
        spec.environment = env;
        spec.executable = @"/usr/bin/sandbox-exec";
        spec.arguments = [[sb arrayByAddingObject:py] arrayByAddingObjectsFromArray:args];
    }

    // Starting later (from the queue or the API): unload and check the memory again, then maybe with the lighter variant.
    BOOL heavy = [info[@"heavy"] boolValue], light = [info[@"light"] boolValue];
    if ((heavy || light) && self.runHost) {
        NSString *option = [OVEngines peakOptionForKind:kind request:req];
        BOOL canLighten = [kind isEqualToString:OVProKindRvcTrain] && ![option isEqual:@"batch2"];
        OVProRunPlan *plan = [OVProRunPlan planWithPeakBytes:[self peakBytesForKind:kind option:option]
                                            reducedPeakBytes:canLighten ? [self peakBytesForKind:kind option:@"batch2"] : 0
                                                needsNetwork:NO heavy:heavy];
        plan.memoryCheckOnly = light;
        plan.lowFreeAccepted = [req[@"_lowFreeAccepted"] boolValue];
        id<OVProRunHost> host = self.runHost;
        OVProcessSpec *captured = spec;
        spec.beforeStart = ^(void (^proceed)(BOOL, NSString *)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                // The job runs now, so the compute lane is ours: this is where OmniVoice is unloaded (a running synth or
                // clone is never killed for it, and nothing here waits in a nested run loop).
                self.inBeforeStart = YES;
                if (heavy) [host unloadMainModels];
                self.inBeforeStart = NO;
                NSTimeInterval settle = heavy && [host respondsToSelector:@selector(settleDelay)] ? [host settleDelay] : 0;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(settle * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    BOOL reduced = NO;
                    BOOL ok = [plan prepareToStartWithHost:host reduced:&reduced];
                    if (ok && reduced) captured.stdinData = [self stdinForRequest:req job:job reduced:YES];
                    proceed(ok, ok ? nil : L(@"Not enough free memory — close other apps and try again."));
                });
            });
        };
        spec.beforeStartTimeout = 600;   // the user may be reading a dialog
    }
    return spec;
}

#pragma mark Scripts

+ (NSString *)scriptPath:(NSString *)script {
    static dispatch_once_t once;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *runtime = [OVPaths runtime];
    dispatch_once(&once, ^{
        // The scripts import each other from one folder: copy every bundled one (what OVWorker does at its start, without
        // the clean-up), so the engines work before the main worker has ever run.
        NSString *bundled = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"py"];
        NSArray *files = [fm contentsOfDirectoryAtPath:bundled error:nil];
        if (!files.count) return;
        [fm createDirectoryAtPath:runtime withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSString *n in files) {
            if (![n hasSuffix:@".py"] || [n hasPrefix:@"._"]) continue;
            NSString *from = J(bundled, n), *to = J(runtime, n);
            NSData *a = [NSData dataWithContentsOfFile:from], *b = [NSData dataWithContentsOfFile:to];
            if (a && b && [a isEqualToData:b]) continue;
            [fm removeItemAtPath:to error:nil];
            [fm copyItemAtPath:from toPath:to error:nil];
        }
    });
    return J(runtime, script);
}

@end

#pragma mark - Sockets

static NSLock *SockLock(void) { static NSLock *l; static dispatch_once_t o; dispatch_once(&o, ^{ l = [NSLock new]; }); return l; }

/// A short alias of a long folder: /tmp/cns-<uid>/<hash> -> dir (the folder is ours, mode 0700). nil if it cannot be made.
static NSString *ShortAlias(NSString *dir) {
    NSString *base = [NSString stringWithFormat:@"/tmp/cns-%u", getuid()];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:base withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil];
    struct stat st;
    if (lstat(base.fileSystemRepresentation, &st) != 0 || st.st_uid != getuid() || !S_ISDIR(st.st_mode)) return nil;
    NSUInteger h = dir.hash;
    NSString *link = [base stringByAppendingFormat:@"/%08lx", (unsigned long)(h & 0xffffffffUL)];
    NSString *cur = [fm destinationOfSymbolicLinkAtPath:link error:nil];
    if (cur && ![cur isEqualToString:dir]) { [fm removeItemAtPath:link error:nil]; cur = nil; }
    if (!cur && ![fm createSymbolicLinkAtPath:link withDestinationPath:dir error:nil]) return nil;
    return link;
}

int OVEnginesConnectSocket(NSString *path) {
    NSString *dir = path.stringByDeletingLastPathComponent, *name = path.lastPathComponent;
    if (!path.isAbsolutePath || !name.length || strlen(name.fileSystemRepresentation) >= sizeof(((struct sockaddr_un *)0)->sun_path)) return -1;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    if (strlen(path.fileSystemRepresentation) < sizeof a.sun_path) {          // fits: connect directly
        strlcpy(a.sun_path, path.fileSystemRepresentation, sizeof a.sun_path);
        if (connect(fd, (struct sockaddr *)&a, sizeof a) == 0) return fd;
        close(fd);
        return -1;
    }
    NSString *alias = ShortAlias(dir);                                        // too long: through a short alias, no chdir
    NSString *shortPath = alias ? [alias stringByAppendingPathComponent:name] : nil;
    if (shortPath && strlen(shortPath.fileSystemRepresentation) < sizeof a.sun_path) {
        strlcpy(a.sun_path, shortPath.fileSystemRepresentation, sizeof a.sun_path);
        if (connect(fd, (struct sockaddr *)&a, sizeof a) == 0) return fd;
        close(fd);
        return -1;
    }
    strlcpy(a.sun_path, name.fileSystemRepresentation, sizeof a.sun_path);
    // Last resort. chdir is process-wide: the lock keeps other users of this function out, and the folder is restored at once
    [SockLock() lock];
    char cwd[PATH_MAX];
    BOOL haveCwd = getcwd(cwd, sizeof cwd) != NULL;
    int rc = -1;
    if (chdir(dir.fileSystemRepresentation) == 0) {
        rc = connect(fd, (struct sockaddr *)&a, sizeof a);
        if (haveCwd) chdir(cwd);
    }
    [SockLock() unlock];
    if (rc != 0) { close(fd); return -1; }
    return fd;
}
