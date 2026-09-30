#import "OVRuntime.h"
#import "OVPaths.h"
#import "OVLocale.h"
#import "OVDownloader.h"
#include <sys/stat.h>

NSNotificationName const OVRuntimeDidChangeNotification = @"OVRuntimeDidChange";
NSNotificationName const OVLogNotification = @"OVLog";

static NSString *const kPythonVersion = @"3.11";
// Apple-Silicon-native stack: MLX instead of PyTorch (~360 MB instead of ~1.1 GB, a third of the RAM)
static NSString *const kRequirements[] = {@"mlx-audio>=0.5.7", @"num2words", @"scipy"};

NSTask *OVRunTask(NSString *path, NSArray<NSString *> *args, NSDictionary *env,
                  void (^onLine)(NSString *), void (^done)(int)) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:path];
    t.arguments = args;
    NSMutableDictionary *e = [NSProcessInfo.processInfo.environment mutableCopy];
    [e addEntriesFromDictionary:env ?: @{}];
    t.environment = e;
    NSPipe *pipe = [NSPipe pipe];
    t.standardOutput = pipe;
    t.standardError = pipe;
    t.standardInput = [NSFileHandle fileHandleWithNullDevice];
    NSMutableData *buf = [NSMutableData data];
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSData *d = h.availableData;
        if (!d.length) { h.readabilityHandler = nil; return; }
        [buf appendData:d];
        // split on \n or \r (uv/pip redraw progress with \r)
        NSMutableArray *lines = [NSMutableArray array];
        const char *bytes = buf.bytes;
        NSUInteger start = 0;
        for (NSUInteger i = 0; i < buf.length; i++) {
            if (bytes[i] == '\n' || bytes[i] == '\r') {
                NSString *l = [[NSString alloc] initWithBytes:bytes + start length:i - start encoding:NSUTF8StringEncoding];
                if (l.length) [lines addObject:l];
                start = i + 1;
            }
        }
        [buf replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
        if (onLine && lines.count)
            dispatch_async(dispatch_get_main_queue(), ^{ for (NSString *l in lines) onLine(l); });
    };
    t.terminationHandler = ^(NSTask *task) {
        int st = task.terminationStatus;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            pipe.fileHandleForReading.readabilityHandler = nil;
            if (done) done(st);
        });
    };
    NSError *err = nil;
    if (![t launchAndReturnError:&err]) {
        if (onLine) onLine([NSString stringWithFormat:L(@"Couldn’t launch %@: %@"), path.lastPathComponent, err.localizedDescription]);
        if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(-1); });
        return nil;
    }
    return t;
}

@interface OVRuntime ()
@property (readwrite) OVRuntimeState state;
@property (readwrite, nullable) NSString *pythonPath, *sourceName;
@property (readwrite, nullable) NSDictionary *info;
@property (readwrite, copy) NSString *stepTitle;
@property (readwrite) double progress;
@property (readwrite, nullable, copy) NSString *errorText;
@property (readwrite) NSArray<NSDictionary *> *candidates;
@property (nullable) NSTask *currentTask;
@property (nullable) OVDownloader *currentDownload;
@property BOOL cancelled;
@property NSFileHandle *logFile;
@end

@implementation OVRuntime

+ (instancetype)shared {
    static OVRuntime *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [OVRuntime new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _stepTitle = @"";
        _candidates = @[];
        [OVPaths ensure];
        NSString *lp = [[OVPaths logs] stringByAppendingPathComponent:@"setup.log"];
        [[NSFileManager defaultManager] createFileAtPath:lp contents:nil attributes:nil];
        _logFile = [NSFileHandle fileHandleForWritingAtPath:lp];
    }
    return self;
}

- (NSString *)customPython { return [NSUserDefaults.standardUserDefaults stringForKey:@"customPython"]; }
- (void)setCustomPython:(NSString *)p {
    if (p.length) [NSUserDefaults.standardUserDefaults setObject:p forKey:@"customPython"];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:@"customPython"];
}

- (void)changed {
    [NSNotificationCenter.defaultCenter postNotificationName:OVRuntimeDidChangeNotification object:self];
}

- (void)log:(NSString *)line {
    [self.logFile writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [NSNotificationCenter.defaultCenter postNotificationName:OVLogNotification object:self userInfo:@{@"line": line}];
}

#pragma mark - Detection

- (NSString *)sourceForPython:(NSString *)py {
    if ([py hasPrefix:[OVPaths support]]) return OVAppName;
    if ([py hasPrefix:[OVPaths legacySupport]]) return OVAppName;
    return L(@"Chosen manually");
}

/// Probe a python: returns info dict if MLX + mlx-audio import, nil otherwise.
- (NSDictionary *)probe:(NSString *)py {
    NSString *code =
        @"import json,sys\n"
        @"import importlib.metadata as m\n"
        @"import importlib.util as u\n"
        @"import mlx.core as mx, mlx_audio\n"
        @"print('OVINFO'+json.dumps({'python':sys.version.split()[0],'mlx':m.version('mlx'),"
        @"'mlx_audio':m.version('mlx-audio'),'metal':bool(mx.metal.is_available())}))\n";
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:py];
    t.arguments = @[@"-c", code];
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p;
    t.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![t launchAndReturnError:nil]) return nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{
        if (t.isRunning) [t terminate];
    });
    NSData *d = [p.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    for (NSString *line in [s componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"OVINFO"]) {
            NSData *j = [[line substringFromIndex:6] dataUsingEncoding:NSUTF8StringEncoding];
            return [NSJSONSerialization JSONObjectWithData:j options:0 error:nil];
        }
    }
    return nil;
}

- (void)detect {
    if (self.state == OVRuntimeInstalling || self.state == OVRuntimeChecking) return;
    self.state = OVRuntimeChecking;
    self.stepTitle = L(@"Looking for an installed OmniVoice…");
    self.errorText = nil;
    [self changed];

    NSMutableArray *order = [NSMutableArray array];
    if (self.customPython.length) [order addObject:self.customPython];
    [order addObject:[OVPaths ownPython]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *cands = [NSMutableArray array];
        NSString *found = nil;
        NSDictionary *foundInfo = nil;
        NSMutableSet *seen = [NSMutableSet set];
        for (NSString *py in order) {
            if ([seen containsObject:py]) continue;
            [seen addObject:py];
            if (![NSFileManager.defaultManager isExecutableFileAtPath:py]) continue;
            dispatch_async(dispatch_get_main_queue(), ^{ [self log:[NSString stringWithFormat:L(@"Checking %@"), py]]; });
            NSDictionary *info = found ? nil : [self probe:py];
            [cands addObject:@{@"path": py, @"ok": @(info != nil), @"checked": @(found == nil),
                               @"source": [self sourceForPython:py]}];
            if (info && !found) { found = py; foundInfo = info; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.candidates = cands;
            if (found) {
                self.pythonPath = found;
                self.info = foundInfo;
                self.sourceName = [self sourceForPython:found];
                self.state = OVRuntimeReady;
                [self log:[NSString stringWithFormat:L(@"Found MLX %@ · mlx-audio %@ — %@"),
                           foundInfo[@"mlx"], foundInfo[@"mlx_audio"], found]];
            } else {
                self.pythonPath = nil;
                self.info = nil;
                self.state = OVRuntimeMissing;
                [self log:L(@"The OmniVoice engine isn’t installed yet.")];
            }
            self.stepTitle = @"";
            [self changed];
        });
    });
}

#pragma mark - Installation

- (void)setStep:(NSString *)title progress:(double)p {
    self.stepTitle = title;
    self.progress = p;
    [self log:[@"▶ " stringByAppendingString:title]];
    [self changed];
}

- (void)fail:(NSString *)msg {
    self.currentTask = nil;
    self.currentDownload = nil;
    self.state = self.cancelled ? OVRuntimeMissing : OVRuntimeFailed;
    self.errorText = self.cancelled ? nil : msg;
    self.stepTitle = self.cancelled ? L(@"Installation canceled") : msg;
    [self log:[@"✖ " stringByAppendingString:self.stepTitle]];
    [self changed];
}

- (void)cancelInstall {
    self.cancelled = YES;
    [self.currentTask terminate];
    [self.currentDownload cancel];
}

- (NSString *)findUV {
    NSMutableArray *c = [NSMutableArray arrayWithObject:[[OVPaths binDir] stringByAppendingPathComponent:@"uv"]];
    [c addObjectsFromArray:@[@"/opt/homebrew/bin/uv", @"/usr/local/bin/uv",
                             [NSHomeDirectory() stringByAppendingPathComponent:@".local/bin/uv"],
                             [NSHomeDirectory() stringByAppendingPathComponent:@".cargo/bin/uv"]]];
    for (NSString *p in c)
        if ([NSFileManager.defaultManager isExecutableFileAtPath:p]) return p;
    return nil;
}

- (NSDictionary *)uvEnv {
    return @{
        // keep the Python interpreter inside our folder so the app is self-contained
        @"UV_PYTHON_INSTALL_DIR": [[OVPaths runtime] stringByAppendingPathComponent:@"python"],
        @"UV_PYTHON_PREFERENCE": @"only-managed",
        @"UV_NO_PROGRESS": @"0",
        @"NO_COLOR": @"1",
    };
}

- (void)install {
    if (self.state == OVRuntimeInstalling) return;
    self.cancelled = NO;
    self.errorText = nil;
    self.state = OVRuntimeInstalling;
    [OVPaths ensure];
    NSString *uv = [self findUV];
    if (uv) {
        [self log:[@"uv: " stringByAppendingString:uv]];
        [self createVenvWithUV:uv];
    } else {
        [self downloadUV];
    }
}

- (void)downloadUV {
#if defined(__arm64__)
    NSString *arch = @"aarch64";
#else
    NSString *arch = @"x86_64";
#endif
    NSString *name = [NSString stringWithFormat:@"uv-%@-apple-darwin", arch];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
                  @"https://github.com/astral-sh/uv/releases/latest/download/%@.tar.gz", name]];
    NSString *tgz = [[OVPaths binDir] stringByAppendingPathComponent:@"uv.tar.gz"];
    [self setStep:L(@"Step 1/3 · Downloading the uv package manager") progress:0];
    __weak typeof(self) w = self;
    self.currentDownload = [OVDownloader download:url to:tgz headers:nil progress:^(long long r, long long t) {
        if (t > 0) { w.progress = (double)r / t * 0.08; [w changed]; }
    } completion:^(NSError *err) {
        if (err) { [w fail:[NSString stringWithFormat:L(@"Couldn’t download uv: %@"), err.localizedDescription]]; return; }
        NSString *tmp = [[OVPaths binDir] stringByAppendingPathComponent:@"uv-extract"];
        [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
        [NSFileManager.defaultManager createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:nil];
        w.currentTask = OVRunTask(@"/usr/bin/tar", @[@"-xzf", tgz, @"-C", tmp], nil, ^(NSString *l) { [w log:l]; }, ^(int st) {
            NSString *src = [[tmp stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"uv"];
            NSString *dst = [[OVPaths binDir] stringByAppendingPathComponent:@"uv"];
            [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
            if (st != 0 || ![NSFileManager.defaultManager moveItemAtPath:src toPath:dst error:nil]) {
                [w fail:L(@"Couldn’t unpack uv")];
                return;
            }
            chmod(dst.fileSystemRepresentation, 0755);
            [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
            [NSFileManager.defaultManager removeItemAtPath:tgz error:nil];
            [w createVenvWithUV:dst];
        });
    }];
}

- (void)createVenvWithUV:(NSString *)uv {
    [self setStep:[NSString stringWithFormat:L(@"Step 2/3 · Python %@ and virtual environment"), kPythonVersion] progress:0.1];
    __weak typeof(self) w = self;
    self.currentTask = OVRunTask(uv, @[@"venv", @"--clear", @"--relocatable", @"--python", kPythonVersion, [OVPaths ownVenv]], [self uvEnv],
        ^(NSString *l) { [w log:l]; },
        ^(int st) {
            if (w.cancelled || st != 0) { [w fail:L(@"Couldn’t create the Python environment (see the log for details)")]; return; }
            [w installPackagesWithUV:uv];
        });
}

- (void)installPackagesWithUV:(NSString *)uv {
    [self setStep:L(@"Step 3/3 · Installing MLX and OmniVoice (~360 MB)") progress:0.15];
    NSMutableArray *args = [@[@"pip", @"install", @"--python", [OVPaths ownPython]] mutableCopy];
    for (size_t i = 0; i < sizeof(kRequirements) / sizeof(kRequirements[0]); i++) [args addObject:kRequirements[i]];
    __weak typeof(self) w = self;
    __block NSInteger downloaded = 0;
    self.currentTask = OVRunTask(uv, args, [self uvEnv], ^(NSString *l) {
        [w log:l];
        // uv prints "Downloading mlx (30.1MiB)" / "Downloaded mlx": show it and creep the bar forward
        NSString *t = [l stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([t hasPrefix:@"Downloading "] || [t hasPrefix:@"Downloaded "] || [t hasPrefix:@"Installed "] ||
            [t hasPrefix:@"Prepared "] || [t hasPrefix:@"Resolved "]) {
            if ([t hasPrefix:@"Downloaded "]) downloaded++;
            w.stepTitle = [NSString stringWithFormat:L(@"Step 3/3 · %@"), t];
            w.progress = MIN(0.95, 0.15 + downloaded * 0.03);
            if ([t hasPrefix:@"Installed "]) w.progress = 0.97;
            [w changed];
        }
    }, ^(int st) {
        if (w.cancelled || st != 0) { [w fail:L(@"Couldn’t install packages (see the log for details)")]; return; }
        [w verifyInstall];
    });
}

- (void)verifyInstall {
    [self setStep:L(@"Verifying installation…") progress:0.98];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *info = [self probe:[OVPaths ownPython]];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.currentTask = nil;
            self.currentDownload = nil;
            if (!info) { [self fail:L(@"OmniVoice is installed but can’t be imported (see the log)")]; return; }
            self.pythonPath = [OVPaths ownPython];
            self.sourceName = OVAppName;
            self.info = info;
            self.state = OVRuntimeReady;
            self.progress = 1;
            self.stepTitle = @"";
            [self log:L(@"✔ Environment installed")];
            [self changed];
        });
    });
}
@end
