#import "OVWorker.h"
#import "OVRuntime.h"
#import "OVPaths.h"
#import "OVModels.h"
#import "OVLocale.h"
#import "OVStore.h"
#import "OVMemory.h"

NSNotificationName const OVWorkerDidChangeNotification = @"OVWorkerDidChange";

@interface OVWorker ()
@property (nullable) NSTask *task;
@property (nullable) NSFileHandle *input;
@property NSMutableData *outBuf, *errBuf;
@property NSInteger nextId, currentId;
@property (nullable, copy) OVWorkerStatus statusBlock;
@property (nullable, copy) OVWorkerProgress progressBlock;
@property (nullable, copy) OVWorkerResult doneBlock;
@property (readwrite) BOOL busy;
@property (readwrite, nullable) NSString *loadedModelPath;
@property (readwrite, copy) NSString *lastStatus;
@property BOOL stopping;
@property (nullable) NSTimer *idleTimer;
@property (readwrite) double memoryActive, memoryPeak;
@property (readwrite) unsigned long long engineFootprint, peakFootprint, availableMemory;
@property (nullable) NSTimer *memoryTimer;
@end

@implementation OVWorker

+ (instancetype)shared {
    static OVWorker *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [OVWorker new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) { _lastStatus = @""; _nextId = 1; }
    return self;
}

- (BOOL)running { return self.task.isRunning; }

- (void)sampleMemory {
    self.availableMemory = [OVMemory availableBytes];
    self.engineFootprint = self.task.isRunning ? [OVMemory footprintOfPID:self.task.processIdentifier] : 0;
    self.peakFootprint = MAX(self.peakFootprint, self.engineFootprint);
    if (!self.task.isRunning) { [self.memoryTimer invalidate]; self.memoryTimer = nil; }
    [NSNotificationCenter.defaultCenter postNotificationName:OVWorkerDidChangeNotification object:self];
}

- (void)resetPeak { self.peakFootprint = self.engineFootprint; }

- (unsigned long long)memoryBudget {
    unsigned long long avail = [OVMemory availableBytes];
    // the engine unloads the other model before loading a new one; keep ~0.35 GB for the Python runtime itself
    unsigned long long reusable = self.engineFootprint > 380000000ULL ? self.engineFootprint - 380000000ULL : 0;
    unsigned long long safety = 300000000ULL;
    return avail + reusable > safety ? avail + reusable - safety : 0;
}

- (void)changed { [NSNotificationCenter.defaultCenter postNotificationName:OVWorkerDidChangeNotification object:self]; }

/// Copy worker.py from the bundle so the interpreter can run it from a stable path.
- (NSString *)installScript {
    NSString *src = [NSBundle.mainBundle pathForResource:@"worker" ofType:@"py"];
    NSString *dst = [OVPaths workerScript];
    [OVPaths ensure];
    if (src) {
        [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
        [NSFileManager.defaultManager copyItemAtPath:src toPath:dst error:nil];
    }
    return dst;
}

- (BOOL)start:(NSString **)error {
    NSString *py = [OVRuntime shared].pythonPath;
    if (!py) { *error = L(@"OmniVoice isn’t installed"); return NO; }
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:py];
    t.arguments = @[@"-u", [self installScript]];
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"PYTHONIOENCODING"] = @"utf-8";
    env[@"PYTORCH_ENABLE_MPS_FALLBACK"] = @"1";
    NSString *tok = [NSUserDefaults.standardUserDefaults stringForKey:@"hfToken"];
    if (tok.length) env[@"HF_TOKEN"] = tok;
    env[@"OV_LANG"] = [OVLocale uiLanguage];
    env[@"OV_OPT_DIR"] = [[OVPaths support] stringByAppendingPathComponent:@"optimized"];
    env[@"HF_HUB_CACHE"] = [OVModels hubCache]; // fallback downloads (e.g. audio tokenizer) land in the same cache
    NSString *ep = [NSUserDefaults.standardUserDefaults stringForKey:@"hfEndpoint"];
    if (ep.length) env[@"HF_ENDPOINT"] = ep;
    t.environment = env;

    NSPipe *inP = [NSPipe pipe], *outP = [NSPipe pipe], *errP = [NSPipe pipe];
    t.standardInput = inP;
    t.standardOutput = outP;
    t.standardError = errP;
    self.outBuf = [NSMutableData data];
    self.errBuf = [NSMutableData data];

    __weak typeof(self) w = self;
    outP.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSData *d = h.availableData;
        if (!d.length) { h.readabilityHandler = nil; return; }
        dispatch_async(dispatch_get_main_queue(), ^{ [w consume:d stderr:NO]; });
    };
    errP.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSData *d = h.availableData;
        if (!d.length) { h.readabilityHandler = nil; return; }
        dispatch_async(dispatch_get_main_queue(), ^{ [w consume:d stderr:YES]; });
    };
    t.terminationHandler = ^(NSTask *task) {
        int code = task.terminationStatus;
        dispatch_async(dispatch_get_main_queue(), ^{ [w terminated:task code:code]; });
    };
    NSError *err = nil;
    if (![t launchAndReturnError:&err]) { *error = err.localizedDescription; return NO; }
    self.task = t;
    self.input = inP.fileHandleForWriting;
    [self.memoryTimer invalidate];
    self.memoryTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) { [w sampleMemory]; }];
    [[OVRuntime shared] log:[NSString stringWithFormat:L(@"Worker started: %@"), py]];
    [self changed];
    return YES;
}

- (void)consume:(NSData *)d stderr:(BOOL)isErr {
    NSMutableData *buf = isErr ? self.errBuf : self.outBuf;
    [buf appendData:d];
    while (YES) {
        NSRange r = [buf rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, buf.length)];
        if (r.location == NSNotFound) break;
        NSData *lineData = [buf subdataWithRange:NSMakeRange(0, r.location)];
        [buf replaceBytesInRange:NSMakeRange(0, r.location + 1) withBytes:NULL length:0];
        NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        if (!line.length) continue;
        if (isErr) {
            // tqdm redraws with \r — keep only the last frame
            line = [line componentsSeparatedByString:@"\r"].lastObject;
            if (line.length) [[OVRuntime shared] log:line];
        } else {
            [self handle:line];
        }
    }
}

- (void)handle:(NSString *)line {
    NSDictionary *ev = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![ev isKindOfClass:NSDictionary.class]) { [[OVRuntime shared] log:line]; return; }
    NSString *kind = ev[@"event"];
    if ([kind isEqualToString:@"status"]) {
        self.lastStatus = ev[@"msg"] ?: @"";
        [[OVRuntime shared] log:self.lastStatus];
        if (self.statusBlock) self.statusBlock(self.lastStatus);
        [self changed];
    } else if ([kind isEqualToString:@"progress"]) {
        if (self.progressBlock) self.progressBlock([ev[@"value"] doubleValue]);
    } else if ([kind isEqualToString:@"memory"]) {
        self.memoryActive = [ev[@"active"] doubleValue];
        self.memoryPeak = [ev[@"peak"] doubleValue];
        [self changed];
    } else if ([kind isEqualToString:@"model_loaded"]) {
        self.loadedModelPath = ev[@"path"];
        [self changed];
    } else if ([kind isEqualToString:@"result"] || [kind isEqualToString:@"error"]) {
        if (ev[@"id"] && [ev[@"id"] integerValue] != self.currentId) return;
        OVWorkerResult done = self.doneBlock;
        [self clearRequest];
        if ([kind isEqualToString:@"error"]) [[OVRuntime shared] log:[NSString stringWithFormat:L(@"Error: %@"), ev[@"msg"] ?: @"?"]];
        if (done) done(ev[@"data"], [kind isEqualToString:@"error"] ? (ev[@"msg"] ?: L(@"Error")) : nil);
    }
}

- (void)clearRequest {
    self.doneBlock = nil;
    self.statusBlock = nil;
    self.progressBlock = nil;
    self.busy = NO;
    [self scheduleIdleUnload];
    [self changed];
}

/// Frees all engine memory after a few idle minutes; the next request starts it again (~2 s).
- (void)scheduleIdleUnload {
    [self.idleTimer invalidate];
    NSInteger minutes = [NSUserDefaults.standardUserDefaults integerForKey:@"idleUnloadMinutes"];
    if (minutes <= 0 || !self.task) return;
    __weak typeof(self) w = self;
    self.idleTimer = [NSTimer scheduledTimerWithTimeInterval:minutes * 60 repeats:NO block:^(NSTimer *t) {
        if (w.busy || !w.task) return;
        [[OVRuntime shared] log:L(@"Engine idle — memory released")];
        [w shutdown];
    }];
}

- (void)terminated:(NSTask *)task code:(int)code {
    if (task != self.task) return;
    self.task = nil;
    self.input = nil;
    self.loadedModelPath = nil;
    self.memoryActive = 0;
    self.engineFootprint = 0;
    [[OVRuntime shared] log:[NSString stringWithFormat:L(@"Worker exited (code %d)"), code]];
    OVWorkerResult done = self.doneBlock;
    BOOL stopped = self.stopping;
    self.stopping = NO;
    [self clearRequest];
    if (done) {
        NSString *msg = stopped ? L(@"Stopped") :
            [NSString stringWithFormat:L(@"The Python process quit unexpectedly (code %d). See the Log for details."), code];
        if (!stopped && code == 9) msg = L(@"The Python process was terminated by the system — probably out of memory.");
        done(nil, msg);
    }
}

- (void)request:(NSDictionary *)req status:(OVWorkerStatus)status progress:(OVWorkerProgress)progress done:(OVWorkerResult)done {
    if (self.busy) { done(nil, L(@"Another operation is already in progress")); return; }
    if (!self.running) {
        NSString *err = nil;
        if (![self start:&err]) { done(nil, err); return; }
    }
    NSMutableDictionary *r = [req mutableCopy];
    r[@"low_memory"] = @([OVSettings lowMemory]);
    // precision is decided now, from the memory free at this moment
    if ([r[@"model"] isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *m = [r[@"model"] mutableCopy];
        m[@"bits"] = @([OVSettings ttsBits]);
        r[@"model"] = m;
    }
    r[@"asr_bits"] = @([OVSettings asrBits]);
    [self resetPeak];
    [self.idleTimer invalidate];
    self.currentId = self.nextId++;
    r[@"id"] = @(self.currentId);
    self.statusBlock = status;
    self.progressBlock = progress;
    self.doneBlock = done;
    self.busy = YES;
    [self changed];
    NSMutableData *d = [[NSJSONSerialization dataWithJSONObject:r options:0 error:nil] mutableCopy];
    [d appendBytes:"\n" length:1];
    @try { [self.input writeData:d]; }
    @catch (NSException *e) {
        [self clearRequest];
        done(nil, L(@"Couldn’t send the command to the worker"));
    }
}

- (void)stop {
    if (!self.task) return;
    self.stopping = YES;
    [self.task terminate];
    NSTask *t = self.task;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (t.isRunning) kill(t.processIdentifier, SIGKILL);
    });
}

- (void)shutdown {
    if (!self.task) return;
    @try { [self.input writeData:[@"{\"cmd\":\"quit\"}\n" dataUsingEncoding:NSUTF8StringEncoding]]; } @catch (NSException *e) {}
    NSTask *t = self.task;
    usleep(200000);
    if (t.isRunning) [t terminate];
}
@end
