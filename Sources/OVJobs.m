#import "OVJobs.h"
#import "OVJobStore.h"
#import "OVPaths.h"
#import "OVLocale.h"
#include <spawn.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/wait.h>

extern char **environ;

NSNotificationName const OVJobsDidChangeNotification = @"OVJobsDidChange";
NSString *const OVJobKindSynth = @"synth", *const OVJobKindBatch = @"batch", *const OVJobKindConvert = @"convert",
          *const OVJobKindTrain = @"train", *const OVJobKindSeparate = @"separate", *const OVJobKindInstall = @"install",
          *const OVJobKindDownload = @"download", *const OVJobKindPlugin = @"plugin";

static const NSUInteger kRemoteActiveLimit = 8;
static const NSTimeInterval kNotifyInterval = 0.25;

#pragma mark - Private types

@interface OVKindEntry : NSObject
@property OVJobLane lane;
@property BOOL retryable;
@property (copy) NSString *(^title)(NSDictionary *);
@property (copy) OVJobRunnerFactory factory;
@property (copy, nullable) void (^onSuccess)(OVJob *);
@end
@implementation OVKindEntry
@end

@interface OVJobs ()
- (void)contextStatus:(OVJobContext *)c status:(NSString *)s;
- (void)contextProgress:(OVJobContext *)c value:(double)p;
- (void)contextPartial:(OVJobContext *)c path:(NSString *)path;
- (void)contextSucceed:(OVJobContext *)c result:(NSDictionary *)r outputs:(NSArray *)outs;
- (void)contextFail:(OVJobContext *)c message:(NSString *)m code:(nullable NSString *)code;
@end

@interface OVJobContext ()
@property (weak) OVJobs *manager;
@property (strong) OVJob *job;
@property (copy) NSString *workDirectory;
@property (atomic) BOOL stopRequested, ended;
- (instancetype)initWithManager:(OVJobs *)m job:(OVJob *)job;
@end

@implementation OVJobContext
@synthesize workDirectory = _workDirectory;
- (instancetype)initWithManager:(OVJobs *)m job:(OVJob *)job {
    if ((self = [super init])) { _manager = m; _job = job; _workDirectory = job.workDirectory; }
    return self;
}
- (void)setStatus:(NSString *)s {
    if (self.ended) return;
    OVJobs *m = self.manager;
    dispatch_async(dispatch_get_main_queue(), ^{ [m contextStatus:self status:s ?: @""]; });
}
- (void)setProgress:(double)p {
    if (self.ended) return;
    OVJobs *m = self.manager;
    dispatch_async(dispatch_get_main_queue(), ^{ [m contextProgress:self value:p]; });
}
- (void)log:(NSString *)line {
    if (self.ended || !line.length) return;
    [self.manager.store appendLog:line toJob:self.job];
}
- (void)registerPartialPath:(NSString *)path {
    if (!path.length) return;
    OVJobs *m = self.manager;
    dispatch_async(dispatch_get_main_queue(), ^{ [m contextPartial:self path:path]; });
}
- (void)succeedWithResult:(NSDictionary *)result outputs:(NSArray<NSString *> *)finalPaths {
    OVJobs *m = self.manager;
    dispatch_async(dispatch_get_main_queue(), ^{ [m contextSucceed:self result:result outputs:finalPaths ?: @[]]; });
}
- (void)failWithError:(NSString *)message { [self failWithError:message code:nil]; }
- (void)failWithError:(NSString *)message code:(NSString *)code {
    OVJobs *m = self.manager;
    dispatch_async(dispatch_get_main_queue(), ^{ [m contextFail:self message:message ?: @"" code:code]; });
}
@end

#pragma mark - OVJobs

@implementation OVJobs {
    OVJobStore *_store;
    NSMutableArray<OVJob *> *_jobs;
    NSMutableDictionary<NSString *, OVKindEntry *> *_kinds;
    NSMutableDictionary<NSString *, id<OVJobRunner>> *_runners;
    NSMutableDictionary<NSString *, OVJobContext *> *_contexts;
    NSMutableDictionary<NSString *, void (^)(OVJob *)> *_finishBlocks;
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *_partials;
    NSMutableArray<OVJob *> *_queues[2];
    OVJob *_running[2];
    NSDate *_lastNotify;
    BOOL _notifyPending;
    id _notifyObject;
}

+ (instancetype)shared {
    static OVJobs *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[OVJobs alloc] initWithRoot:[OVPaths jobs]]; });
    return s;
}

+ (instancetype)jobsWithRoot:(NSString *)root { return [[OVJobs alloc] initWithRoot:root]; }

- (instancetype)initWithRoot:(NSString *)root {
    if ((self = [super init])) {
        OVJobStore.appDataRoots = @[[OVPaths support], [OVPaths outputs], NSTemporaryDirectory()];
        _store = [[OVJobStore alloc] initWithRoot:root];
        OVJobStore.protectedRoots = @[root, [OVPaths voices]];
        _store.interruptedMessage = L(@"The app closed while this task was running. Start it again.");
        _kinds = [NSMutableDictionary dictionary];
        _runners = [NSMutableDictionary dictionary];
        _contexts = [NSMutableDictionary dictionary];
        _finishBlocks = [NSMutableDictionary dictionary];
        _partials = [NSMutableDictionary dictionary];
        _queues[0] = [NSMutableArray array];
        _queues[1] = [NSMutableArray array];
        _jobs = [[_store loadAll] mutableCopy];
        [_jobs removeObjectsInArray:[_store pruneJobs:_jobs]];
    }
    return self;
}

- (OVJobStore *)store { return _store; }
- (NSArray<OVJob *> *)all { return [_jobs copy]; }
- (NSUInteger)activeCount {
    NSUInteger n = 0;
    for (OVJob *j in _jobs) if (j.active) n++;
    return n;
}

- (OVJob *)jobWithId:(NSString *)identifier {
    for (OVJob *j in _jobs) if ([j.identifier isEqualToString:identifier]) return j;
    return nil;
}

#pragma mark Notifications

- (void)postChange:(nullable OVJob *)job immediate:(BOOL)immediate {
    if (immediate) {
        _lastNotify = NSDate.date;
        [NSNotificationCenter.defaultCenter postNotificationName:OVJobsDidChangeNotification object:job];
        return;
    }
    NSTimeInterval since = _lastNotify ? -[_lastNotify timeIntervalSinceNow] : 1e9;
    if (since >= kNotifyInterval) { [self postChange:job immediate:YES]; return; }
    if (_notifyPending) {
        if (_notifyObject != job) _notifyObject = nil;   // several jobs changed: "the list changed"
        return;
    }
    _notifyPending = YES;
    _notifyObject = job;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kNotifyInterval - since) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_notifyPending = NO;
        id o = self->_notifyObject;
        self->_notifyObject = nil;
        [self postChange:o immediate:YES];
    });
}

#pragma mark Registry

- (void)refreshRetryable:(OVJob *)j {
    OVKindEntry *e = _kinds[j.kind];
    j.retryable = e.retryable && !j.active;
}

- (void)registerKind:(NSString *)kind lane:(OVJobLane)lane retryable:(BOOL)retryable
               title:(NSString *(^)(NSDictionary *))title factory:(OVJobRunnerFactory)factory
           onSuccess:(void (^)(OVJob *))onSuccess {
    if (_kinds[kind]) NSLog(@"OVJobs: kind '%@' is registered again; the new registration replaces the old one", kind);
    OVKindEntry *e = [OVKindEntry new];
    e.lane = lane; e.retryable = retryable; e.title = title; e.factory = factory; e.onSuccess = onSuccess;
    _kinds[kind] = e;
    for (OVJob *j in _jobs) if ([j.kind isEqualToString:kind]) [self refreshRetryable:j];
}

#pragma mark Submitting

- (OVJob *)submitKind:(NSString *)kind request:(NSDictionary *)request origin:(NSString *)origin
             onFinish:(void (^)(OVJob *))onFinish error:(NSString **)error {
    return [self submitKind:kind request:request origin:origin retryOf:nil onFinish:onFinish error:error];
}

- (OVJob *)submitKind:(NSString *)kind request:(NSDictionary *)request origin:(NSString *)origin retryOf:(NSString *)retryOf
             onFinish:(void (^)(OVJob *))onFinish error:(NSString **)error {
    OVKindEntry *e = _kinds[kind];
    if (!e) { if (error) *error = [NSString stringWithFormat:L(@"Unknown kind of task: %@. Update the app or the plugin."), kind]; return nil; }
    origin = origin.length ? origin : @"app";
    if ([origin isEqualToString:@"api"] || [origin hasPrefix:@"bridge:"]) {
        NSUInteger n = 0;
        for (OVJob *j in _jobs) if (j.active && ([j.origin isEqualToString:@"api"] || [j.origin hasPrefix:@"bridge:"])) n++;
        if (n >= kRemoteActiveLimit) {
            if (error) *error = L(@"Too many tasks are waiting. Wait for some to finish, then send the request again.");
            return nil;
        }
    }
    OVJob *job = [OVJob new];
    NSString *ident;
    do { ident = [OVJobStore newIdentifier]; } while ([self jobWithId:ident]);
    job.identifier = ident;
    job.kind = kind;
    job.origin = origin;
    job.lane = e.lane;
    job.state = OVJobQueued;
    job.created = NSDate.date;
    job.progress = -1;
    job.status = @"";
    job.rawRequest = request ?: @{};
    job.request = [OVJobStore jsonSafe:[OVJobStore redact:request ?: @{}]];
    job.title = e.title ? (e.title(job.request) ?: kind) : kind;
    job.retryOf = retryOf;
    job.outputs = @[];
    job.folder = [_store.root stringByAppendingPathComponent:ident];
    [self refreshRetryable:job];
    [_jobs insertObject:job atIndex:0];
    if (onFinish) _finishBlocks[ident] = [onFinish copy];
    [_store save:job];
    [_queues[e.lane] addObject:job];
    [self postChange:job immediate:YES];
    [self pump];
    return job;
}

- (void)pump {
    for (int lane = 0; lane < 2; lane++) {
        while (!_running[lane] && _queues[lane].count) {
            OVJob *j = _queues[lane].firstObject;
            [_queues[lane] removeObjectAtIndex:0];
            [self startJob:j];
        }
    }
}

- (void)startJob:(OVJob *)job {
    OVKindEntry *e = _kinds[job.kind];
    _running[job.lane] = job;
    job.state = OVJobRunning;
    job.started = NSDate.date;
    [NSFileManager.defaultManager createDirectoryAtPath:job.workDirectory withIntermediateDirectories:YES
                                                                     attributes:@{NSFilePosixPermissions: @0700} error:nil];
    [self refreshRetryable:job];
    [_store save:job];
    OVJobContext *ctx = [[OVJobContext alloc] initWithManager:self job:job];
    _contexts[job.identifier] = ctx;
    [self postChange:job immediate:YES];
    id<OVJobRunner> runner = nil;
    @try {
        runner = e.factory(job);
        if (!runner) {
            [self finish:job state:OVJobFailed error:L(@"The task could not start: no runner for this kind of task. Update the app or the plugin.")
                  result:nil outputs:@[]];
            return;
        }
        _runners[job.identifier] = runner;
        [runner start:job context:ctx];
    } @catch (NSException *ex) {
        [self finish:job state:OVJobFailed error:[NSString stringWithFormat:L(@"The task could not start: %@"), ex.reason ?: ex.name]
              result:nil outputs:@[]];
    }
}

#pragma mark Context callbacks (main)

- (BOOL)isCurrent:(OVJobContext *)c { return _contexts[c.job.identifier] == c && c.job.state == OVJobRunning; }

- (void)contextStatus:(OVJobContext *)c status:(NSString *)s {
    if (![self isCurrent:c]) return;
    c.job.status = s;
    [_store saveThrottled:c.job];
    [self postChange:c.job immediate:NO];
}

- (void)contextProgress:(OVJobContext *)c value:(double)p {
    if (![self isCurrent:c]) return;
    c.job.progress = (p < 0 || isnan(p)) ? -1 : MIN(1, p);
    [_store saveThrottled:c.job];
    [self postChange:c.job immediate:NO];
}

/// Where a job may have partial files: its own work/, the Outputs folder, <tmp>/clonenspeak-<id>/.
- (NSArray<NSString *> *)partialRootsFor:(OVJob *)job {
    return @[[OVPaths outputs], [NSTemporaryDirectory() stringByAppendingPathComponent:[@"clonenspeak-" stringByAppendingString:job.identifier]]];
}

- (void)contextPartial:(OVJobContext *)c path:(NSString *)path {
    if (![self isCurrent:c]) return;
    if (![OVJobStore isDeletablePartial:path roots:[self partialRootsFor:c.job] exceptRoots:@[c.job.workDirectory]]) {
        [_store appendLog:[NSString stringWithFormat:@"Ignored a partial file that is not a plain file in this task's own folders: %@", path] toJob:c.job];
        return;
    }
    NSMutableArray *a = _partials[c.job.identifier];
    if (!a) _partials[c.job.identifier] = a = [NSMutableArray array];
    [a addObject:path];
}

- (void)contextSucceed:(OVJobContext *)c result:(NSDictionary *)r outputs:(NSArray *)outs {
    if (![self isCurrent:c]) return;
    NSMutableArray *paths = [NSMutableArray array];
    for (id o in outs) if ([o isKindOfClass:NSString.class]) [paths addObject:o];
    [self finish:c.job state:OVJobSucceeded error:nil result:r outputs:paths];
}

- (void)contextFail:(OVJobContext *)c message:(NSString *)m code:(NSString *)code {
    if (![self isCurrent:c]) return;
    c.job.errorCode = code.length && !c.stopRequested ? code : nil;   // the result of a failed job stays nil
    [self finish:c.job state:c.stopRequested ? OVJobStopped : OVJobFailed error:c.stopRequested ? nil : m result:nil outputs:@[]];
}

#pragma mark Finishing

- (void)finish:(OVJob *)job state:(OVJobState)state error:(NSString *)error result:(NSDictionary *)result outputs:(NSArray<NSString *> *)outputs {
    NSString *ident = job.identifier;
    OVJobContext *ctx = _contexts[ident];
    ctx.ended = YES;
    [_contexts removeObjectForKey:ident];
    [_runners removeObjectForKey:ident];
    NSMutableArray *partials = _partials[ident];
    [_partials removeObjectForKey:ident];

    if (state != OVJobSucceeded) {
        for (NSString *p in partials)
            [OVJobStore removePartial:p roots:[self partialRootsFor:job] exceptRoots:@[job.workDirectory]];
    }
    BOOL keepWork = NO;
    if (state == OVJobSucceeded) {
        NSString *prefix = [job.workDirectory stringByAppendingString:@"/"];
        for (NSString *o in outputs) if ([o hasPrefix:prefix]) keepWork = YES;   // the output still lives in work/
    }
    if (!keepWork) [_store removeWorkOfJob:job];

    if (state == OVJobStopped) [_store appendLog:@"Stopped by user" toJob:job];
    else if (state == OVJobFailed && error.length) [_store appendLog:[@"Error: " stringByAppendingString:error] toJob:job];
    [_store closeLogOfJob:job];

    job.state = state;
    job.finished = NSDate.date;
    job.error = error.length ? error : nil;
    if (state != OVJobFailed) job.errorCode = nil;
    job.result = result ? [OVJobStore redact:result] : nil;
    job.outputs = outputs ?: @[];
    if (state == OVJobSucceeded) job.progress = 1;
    if (state == OVJobStopped) job.status = L(@"Stopped");
    [self refreshRetryable:job];
    [_store save:job];
    if (_running[job.lane] == job) _running[job.lane] = nil;
    [self postChange:job immediate:YES];

    OVKindEntry *e = _kinds[job.kind];
    if (state == OVJobSucceeded && e.onSuccess) e.onSuccess(job);
    void (^fin)(OVJob *) = _finishBlocks[ident];
    [_finishBlocks removeObjectForKey:ident];
    if (fin) fin(job);

    NSArray *pruned = [_store pruneJobs:_jobs];
    if (pruned.count) { [_jobs removeObjectsInArray:pruned]; [self postChange:nil immediate:YES]; }
    [self pump];
}

#pragma mark Stop, retry, remove

- (void)stop:(OVJob *)job {
    if (!job.active || ![_jobs containsObject:job]) return;
    if (job.state == OVJobQueued) {
        [_queues[job.lane] removeObject:job];
        [self finish:job state:OVJobStopped error:nil result:nil outputs:@[]];
        return;
    }
    OVJobContext *ctx = _contexts[job.identifier];
    if (!ctx || ctx.stopRequested) return;
    ctx.stopRequested = YES;
    [_store appendLog:@"Stop requested" toJob:job];
    [_runners[job.identifier] stop:job];
}

- (OVJob *)retry:(OVJob *)job { return [self retry:job error:nil]; }

- (OVJob *)retry:(OVJob *)job error:(NSString **)error {
    if (!job.retryable) { if (error) *error = L(@"This task cannot be started again."); return nil; }
    if (!job.rawRequest && [OVJobStore hasRedactedValues:job.request]) {
        // after a relaunch the secrets of the first run are gone; sending *** would only fail later and confusingly
        if (error) *error = L(@"This task used a key or password that is not stored. Enter it again and start a new task.");
        return nil;
    }
    return [self submitKind:job.kind request:job.runnerRequest origin:job.origin retryOf:job.identifier onFinish:nil error:error];
}

- (void)remove:(OVJob *)job {
    if (job.active || ![_jobs containsObject:job]) return;
    [_jobs removeObject:job];
    [_store removeFolderOfJob:job];
    [self postChange:nil immediate:YES];
}

- (void)clearFinished {
    for (OVJob *j in [_jobs copy]) if (!j.active) { [_jobs removeObject:j]; [_store removeFolderOfJob:j]; }
    [self postChange:nil immediate:YES];
}

- (void)stopAllAndWait:(NSTimeInterval)timeout {
    for (OVJob *j in [_jobs copy]) if (j.active) [self stop:j];
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (self.activeCount && [end timeIntervalSinceNow] > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    for (OVJob *j in [_jobs copy]) {   // a runner that never answered
        if (!j.active) continue;
        [_queues[j.lane] removeObject:j];
        id<OVJobRunner> r = _runners[j.identifier];
        if ([r respondsToSelector:@selector(kill:)]) [r kill:j];   // the app is about to exit: no waiting for SIGKILL timers
        [self finish:j state:OVJobStopped error:nil result:nil outputs:@[]];
    }
}
@end

#pragma mark - Process runner

@implementation OVProcessSpec
- (instancetype)init { if ((self = [super init])) { _killGrace = 3; _beforeStartTimeout = 120; _arguments = @[]; _environment = @{}; } return self; }
@end

@interface OVProcessRunner : NSObject <OVJobRunner>
@end

@implementation OVProcessRunner {
    OVProcessSpec *(^_specFor)(OVJob *);
    OVProcessSpec *_spec;
    OVJobContext *_ctx;
    pid_t _pid;
    BOOL _reaped, _stopped, _launched, _ended;
    int _stdinFd;   // the kept-open write end (keepStdinOpen), -1 otherwise
    NSDictionary *_resultData;
    NSString *_errorMessage;
}

- (instancetype)initWithSpecBlock:(OVProcessSpec *(^)(OVJob *))b {
    if ((self = [super init])) { _specFor = [b copy]; _stdinFd = -1; }
    return self;
}

- (void)start:(OVJob *)job context:(OVJobContext *)ctx {
    _ctx = ctx;
    _spec = _specFor(job);
    if (_spec.launchError.length) { [self endWithError:_spec.launchError]; return; }
    if (!_spec.executable.length) { [self endWithError:L(@"No program to run was given.")]; return; }
    for (NSString *p in _spec.partialPaths) [ctx registerPartialPath:p];
    void (^go)(void) = ^{ [self launch]; };
    if (_spec.beforeStart) {
        __block BOOL answered = NO;
        NSLock *lock = [NSLock new];
        BOOL (^claim)(void) = ^BOOL{ [lock lock]; BOOL first = !answered; answered = YES; [lock unlock]; return first; };
        _spec.beforeStart(^(BOOL ok, NSString *err) {
            if (!claim()) return;   // timed out already
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                if (!ok) { [self endWithError:err.length ? err : L(@"The task could not start.")]; return; }
                go();
            });
        });
        // a check that never answers must not hold the lane forever
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_spec.beforeStartTimeout * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            if (claim()) [self endWithError:L(@"Preparing the task took too long. Close other apps and start it again.")];
        });
    } else {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), go);
    }
}

/// The one place that ends the job from the runner's side, exactly once.
- (void)endWithError:(NSString *)message {
    @synchronized (self) { if (_ended) return; _ended = YES; }
    [_ctx failWithError:message];
}

- (void)launch {
    @synchronized (self) { if (_stopped || _ended) return; _launched = YES; }
    int in[2] = {-1, -1}, out[2], err[2];
    if (pipe(out) != 0 || pipe(err) != 0 || (_spec.stdinData && pipe(in) != 0)) {
        [self endWithError:[NSString stringWithFormat:L(@"The task could not start: %@"), @(strerror(errno))]];
        return;
    }
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    if (_spec.stdinData) posix_spawn_file_actions_adddup2(&fa, in[0], 0);
    else posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&fa, out[1], 1);
    posix_spawn_file_actions_adddup2(&fa, err[1], 2);
    if (_spec.currentDirectory.length) posix_spawn_file_actions_addchdir_np(&fa, _spec.currentDirectory.fileSystemRepresentation);

    posix_spawnattr_t at;
    posix_spawnattr_init(&at);
    sigset_t none, all;
    sigemptyset(&none);
    sigfillset(&all);
    posix_spawnattr_setsigmask(&at, &none);
    posix_spawnattr_setsigdefault(&at, &all);
    posix_spawnattr_setpgroup(&at, 0);   // its own group: stop kills the whole tree
    posix_spawnattr_setflags(&at, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT);

    NSMutableArray<NSString *> *argvStrings = [NSMutableArray arrayWithObject:_spec.executable];
    [argvStrings addObjectsFromArray:_spec.arguments ?: @[]];
    char **argv = calloc(argvStrings.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < argvStrings.count; i++) argv[i] = (char *)argvStrings[i].fileSystemRepresentation;
    NSMutableArray<NSString *> *envStrings = [NSMutableArray array];
    [_spec.environment enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *s) { [envStrings addObject:[NSString stringWithFormat:@"%@=%@", k, v]]; }];
    char **envp = calloc(envStrings.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < envStrings.count; i++) envp[i] = (char *)envStrings[i].fileSystemRepresentation;

    pid_t pid = 0;
    int rc = posix_spawn(&pid, _spec.executable.fileSystemRepresentation, &fa, &at, argv, envp);
    free(argv); free(envp);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&at);
    close(out[1]); close(err[1]);
    if (in[0] >= 0) close(in[0]);
    if (rc != 0) {
        close(out[0]); close(err[0]);
        if (in[1] >= 0) close(in[1]);
        [self endWithError:[NSString stringWithFormat:L(@"The task could not start: %@"), @(strerror(rc))]];
        return;
    }
    BOOL stopNow;
    @synchronized (self) { _pid = pid; stopNow = _stopped; }
    if (stopNow) [self terminateGroup];

    dispatch_group_t readers = dispatch_group_create();
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    if (in[1] >= 0) {
        int wfd = in[1];
        fcntl(wfd, F_SETNOSIGPIPE, 1);
        NSData *data = _spec.stdinData;
        dispatch_async(q, ^{
            const uint8_t *p = data.bytes;
            size_t left = data.length;
            while (left > 0) { ssize_t n = write(wfd, p, left); if (n <= 0) break; p += n; left -= (size_t)n; }
            if (self->_spec.keepStdinOpen) { @synchronized (self) { self->_stdinFd = wfd; if (self->_reaped || self->_stopped) { close(wfd); self->_stdinFd = -1; } } }
            else close(wfd);
        });
    }
    [self readFd:out[0] group:readers queue:q asEvents:YES];
    [self readFd:err[0] group:readers queue:q asEvents:NO];

    dispatch_async(q, ^{
        int status = 0;
        pid_t r;
        do { r = waitpid(pid, &status, 0); } while (r < 0 && errno == EINTR);
        @synchronized (self) { self->_reaped = YES; }
        [self closeKeptStdin];
        // output still in the pipes is read first; a grandchild that keeps them open cannot hold us longer than this
        dispatch_group_wait(readers, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        [self finishWithStatus:status];
    });
}

/// UTF-8 with every invalid byte replaced by U+FFFD (never nil, so no line is lost).
static NSString *OVLossyString(NSData *d) {
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (s) return s;
    const uint8_t *b = d.bytes;
    NSUInteger n = d.length, i = 0;
    NSMutableString *out = [NSMutableString string];
    while (i < n) {
        NSUInteger len = b[i] < 0x80 ? 1 : (b[i] >> 5) == 0x6 ? 2 : (b[i] >> 4) == 0xE ? 3 : (b[i] >> 3) == 0x1E ? 4 : 0;
        NSString *piece = (len && i + len <= n) ? [[NSString alloc] initWithBytes:b + i length:len encoding:NSUTF8StringEncoding] : nil;
        if (piece) { [out appendString:piece]; i += len; }
        else { [out appendString:@"\uFFFD"]; i++; }
    }
    return out;
}

/// "text\r\n" → "text"; a progress bar redrawn with \r keeps its last frame.
static NSString *OVCleanLine(NSString *line) {
    while ([line hasSuffix:@"\r"]) line = [line substringToIndex:line.length - 1];
    NSRange r = [line rangeOfString:@"\r" options:NSBackwardsSearch];
    return r.location == NSNotFound ? line : [line substringFromIndex:NSMaxRange(r)];
}

- (void)readFd:(int)fd group:(dispatch_group_t)g queue:(dispatch_queue_t)q asEvents:(BOOL)events {
    dispatch_group_enter(g);
    dispatch_async(q, ^{
        NSMutableData *buf = [NSMutableData data];
        uint8_t chunk[8192];
        for (;;) {
            ssize_t n = read(fd, chunk, sizeof chunk);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) break;
            [buf appendBytes:chunk length:(NSUInteger)n];
            for (;;) {
                NSRange r = [buf rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, buf.length)];
                if (r.location == NSNotFound) break;
                NSString *line = OVCleanLine(OVLossyString([buf subdataWithRange:NSMakeRange(0, r.location)]));
                [buf replaceBytesInRange:NSMakeRange(0, r.location + 1) withBytes:NULL length:0];
                if (line.length) { if (events) [self handleLine:line]; else [self->_ctx log:line]; }
            }
            if (buf.length > 4 * 1024 * 1024) [buf setLength:0];   // a stream without newlines
        }
        if (buf.length) {
            NSString *line = OVCleanLine(OVLossyString(buf));
            if (line.length) { if (events) [self handleLine:line]; else [self->_ctx log:line]; }
        }
        close(fd);
        dispatch_group_leave(g);
    });
}

- (void)handleLine:(NSString *)line {
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    id ev = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![ev isKindOfClass:NSDictionary.class]) { [_ctx log:line]; return; }   // not an event: plain output
    NSString *kind = ev[@"event"];
    if ([kind isEqualToString:@"status"]) {
        NSString *m = [ev[@"msg"] isKindOfClass:NSString.class] ? ev[@"msg"] : @"";
        [_ctx setStatus:m];
        [_ctx log:m];
    } else if ([kind isEqualToString:@"progress"]) {
        [_ctx setProgress:[ev[@"value"] doubleValue]];
    } else if ([kind isEqualToString:@"log"]) {
        if ([ev[@"line"] isKindOfClass:NSString.class]) [_ctx log:ev[@"line"]];
    } else if ([kind isEqualToString:@"partial"]) {
        if ([ev[@"path"] isKindOfClass:NSString.class]) [_ctx registerPartialPath:ev[@"path"]];
    } else if ([kind isEqualToString:@"result"]) {
        @synchronized (self) { _resultData = [ev[@"data"] isKindOfClass:NSDictionary.class] ? ev[@"data"] : @{}; }
    } else if ([kind isEqualToString:@"error"]) {
        @synchronized (self) { _errorMessage = [ev[@"msg"] isKindOfClass:NSString.class] ? ev[@"msg"] : L(@"The task failed."); }
    } else {
        [_ctx log:line];
    }
}

- (void)finishWithStatus:(int)status {
    @synchronized (self) { if (_ended) return; _ended = YES; }
    NSDictionary *res;
    NSString *err;
    BOOL stopped;
    @synchronized (self) { res = _resultData; err = _errorMessage; stopped = _stopped; }
    if (err.length) { [_ctx failWithError:err]; return; }
    if (res) {
        NSMutableArray *outs = [NSMutableArray array];
        if ([res[@"outputs"] isKindOfClass:NSArray.class])
            for (id o in res[@"outputs"]) if ([o isKindOfClass:NSString.class]) [outs addObject:o];
        [_ctx succeedWithResult:res outputs:outs];
        return;
    }
    if (stopped || _ctx.stopRequested) { [_ctx failWithError:@"Stopped"]; return; }
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        [_ctx failWithError:L(@"The process ended without a result. See the log of this task.")];
    } else if (WIFSIGNALED(status)) {
        [_ctx failWithError:[NSString stringWithFormat:L(@"The process was terminated by signal %d. See the log of this task."), WTERMSIG(status)]];
    } else {
        [_ctx failWithError:[NSString stringWithFormat:L(@"Exit code %d. See the log of this task."), WEXITSTATUS(status)]];
    }
}

- (void)closeKeptStdin {
    @synchronized (self) { if (_stdinFd > 0) { close(_stdinFd); _stdinFd = -1; } }
}

- (void)terminateGroup {
    [self closeKeptStdin];
    pid_t pid;
    @synchronized (self) { pid = _pid; }
    if (pid <= 0) return;
    killpg(pid, SIGTERM);
    NSTimeInterval grace = _spec.killGrace > 0 ? _spec.killGrace : 3;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(grace * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // A group id cannot be reused while the group has members: ESRCH means it is empty, anything else means stragglers
        // (even when the leader is gone) that must go.
        if (killpg(pid, 0) == 0) killpg(pid, SIGKILL);
    });
}

- (void)stop:(OVJob *)job {
    BOOL beforeLaunch;
    @synchronized (self) { _stopped = YES; beforeLaunch = !_launched; }
    if (beforeLaunch) { [self endWithError:@"Stopped"]; return; }   // waiting in beforeStart: nothing runs, end at once
    [self terminateGroup];
}

- (void)kill:(OVJob *)job {
    pid_t pid;
    @synchronized (self) {
        _stopped = YES;
        if (!_launched) { [self endWithError:@"Stopped"]; return; }
        pid = _pid;
    }
    if (pid > 0 && killpg(pid, 0) == 0) killpg(pid, SIGKILL);   // ESRCH: the group is empty
}
@end

OVJobRunnerFactory OVProcessRunnerFactory(OVProcessSpec *(^specFor)(OVJob *job)) {
    OVProcessSpec *(^b)(OVJob *) = [specFor copy];
    return ^id<OVJobRunner>(OVJob *job) { return [[OVProcessRunner alloc] initWithSpecBlock:b]; };
}
