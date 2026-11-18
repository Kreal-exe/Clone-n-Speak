#import "OVNativeAccent.h"
#import "OVPaths.h"
#import "OVRuntime.h"
#import "OVJobs.h"
#import "OVLocale.h"

NSNotificationName const OVNativeAccentDidChangeNotification = @"OVNativeAccentDidChange";

@interface OVNativeAccent ()
@property (readwrite) double progress;
@property (readwrite, copy) NSString *step;
@property (readwrite, nullable, copy) NSString *error;
@property (strong, nullable) OVJob *job;
@property (strong, nullable) id observer;
@end

@implementation OVNativeAccent
@synthesize installing = _installing;

+ (instancetype)shared {
    static OVNativeAccent *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [OVNativeAccent new]; s.step = @""; [s watchJobs]; });
    return s;
}

/// An install that the Jobs page started again (Retry), or one that is still going, is the same install: the state
/// comes from OVJobs, not only from the button of this page.
- (nullable OVJob *)activeInstallJob {
    for (OVJob *j in OVJobs.shared.all)
        if (j.active && [j.kind isEqualToString:OVJobKindInstall] && [j.request[@"cmd"] isEqual:@"install_accent"]) return j;
    return nil;
}

- (BOOL)installing { return _installing || [self activeInstallJob] != nil; }

- (void)watchJobs {
    __weak typeof(self) w = self;
    self.observer = [NSNotificationCenter.defaultCenter addObserverForName:OVJobsDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                                                                usingBlock:^(NSNotification *n) {
        OVNativeAccent *me = w;
        OVJob *j = n.object;
        if (!me || ![j isKindOfClass:OVJob.class] || ![j.kind isEqualToString:OVJobKindInstall] || ![j.request[@"cmd"] isEqual:@"install_accent"]) return;
        if (j.active) {
            if (j.status.length) me.step = j.status;
            if (j.progress >= 0) me.progress = j.progress;
            me.error = nil;
        } else if (j != me.job) {   // an install this page did not start has just ended
            me.error = j.state == OVJobFailed ? (j.error ?: L(@"The install failed.")) : j.state == OVJobStopped ? L(@"Stopped") : nil;
            me.step = @"";
        }
        [me changed];
    }];
}

- (NSString *)python { return [[OVPaths accent] stringByAppendingPathComponent:@".venv/bin/python"]; }

- (BOOL)installed {
    // the worker writes "ready" last, after Seed-VC has fetched its models
    return !self.installing && [NSFileManager.defaultManager fileExistsAtPath:[[OVPaths accent] stringByAppendingPathComponent:@"ready"]]
        && [NSFileManager.defaultManager isExecutableFileAtPath:[self python]];
}

- (NSDictionary *)workerSpec {
    return self.installed ? @{@"python": [self python], @"dir": [OVPaths accent]} : nil;
}

- (void)changed { [NSNotificationCenter.defaultCenter postNotificationName:OVNativeAccentDidChangeNotification object:self]; }

- (void)install {
    if (self.installing) return;   // also true while a Retry from the Jobs page runs
    NSString *uv = [[OVRuntime shared] findUV];
    if (!uv) {
        self.error = L(@"The uv package manager wasn’t found — reinstall the engine on the Setup page.");
        [self changed];
        return;
    }
    _installing = YES;
    self.error = nil;
    self.progress = 0;
    self.step = L(@"Starting…");
    [self changed];
    NSDictionary *req = @{@"cmd": @"install_accent", @"explicit_download": @YES, @"dir": [OVPaths accent], @"uv": uv, @"env": [[OVRuntime shared] uvEnv]};
    __weak typeof(self) w = self;
    NSString *submitError = nil;
    OVJob *job = [OVJobs.shared submitKind:OVJobKindInstall request:req origin:@"app" onFinish:^(OVJob *j) {
        OVNativeAccent *me = w;
        if (!me) return;
        me.job = nil;
        me->_installing = NO;
        w.error = j.state == OVJobFailed ? (j.error ?: L(@"The install failed.")) : j.state == OVJobStopped ? L(@"Stopped") : nil;
        w.step = @"";
        [w changed];
    } error:&submitError];
    if (!job) {
        _installing = NO;
        self.error = submitError ?: L(@"The install could not be started.");
        [self changed];
        return;
    }
    self.job = job;
}

- (BOOL)remove:(NSError **)error {
    if (self.installing) return NO;
    BOOL ok = [NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:[OVPaths accent]] resultingItemURL:nil error:error];
    [self changed];
    return ok;
}
@end
