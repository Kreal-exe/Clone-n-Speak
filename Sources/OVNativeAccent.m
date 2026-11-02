#import "OVNativeAccent.h"
#import "OVPaths.h"
#import "OVRuntime.h"
#import "OVWorker.h"
#import "OVLocale.h"

NSNotificationName const OVNativeAccentDidChangeNotification = @"OVNativeAccentDidChange";

@interface OVNativeAccent ()
@property (readwrite) BOOL installing;
@property (readwrite) double progress;
@property (readwrite, copy) NSString *step;
@property (readwrite, nullable, copy) NSString *error;
@end

@implementation OVNativeAccent

+ (instancetype)shared {
    static OVNativeAccent *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [OVNativeAccent new]; s.step = @""; });
    return s;
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
    if (self.installing) return;
    NSString *uv = [[OVRuntime shared] findUV];
    if (!uv) {
        self.error = L(@"The uv package manager wasn’t found — reinstall the engine on the Setup page.");
        [self changed];
        return;
    }
    self.installing = YES;
    self.error = nil;
    self.progress = 0;
    self.step = L(@"Starting…");
    [self changed];
    NSDictionary *req = @{@"cmd": @"install_accent", @"dir": [OVPaths accent], @"uv": uv, @"env": [[OVRuntime shared] uvEnv]};
    __weak typeof(self) w = self;
    [[OVWorker shared] request:req status:^(NSString *msg) {
        w.step = msg;
        [w changed];
    } progress:^(double v) {
        w.progress = v;
        [w changed];
    } done:^(NSDictionary *data, NSString *err) {
        w.installing = NO;
        w.error = err;
        w.step = @"";
        [w changed];
    }];
}

- (BOOL)remove:(NSError **)error {
    if (self.installing) return NO;
    BOOL ok = [NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:[OVPaths accent]] resultingItemURL:nil error:error];
    [self changed];
    return ok;
}
@end
