#import "OVPlugins.h"
#import "OVPaths.h"
#import "OVLocale.h"
#import "OVNetwork.h"
#import "OVWorker.h"

NSNotificationName const OVPluginsDidChangeNotification = @"OVPluginsDidChange";

NSString *OVPluginPython(void) { return [OVPaths ownPython]; }   // TODO: [OVEngines pythonForEngine:] when the pro engines land

static NSString *const kEnabledKey = @"pluginsEnabled";
static NSString *EnabledKey(NSString *pid) { return [@"pluginEnabled." stringByAppendingString:pid]; }
static NSString *TrustKey(NSString *pid)   { return [@"pluginTrust." stringByAppendingString:pid]; }
static NSString *NetKey(NSString *pid)     { return [@"pluginNetwork." stringByAppendingString:pid]; }

#pragma mark - Calling cns_plugins.py

/// Runs `python cns_plugins.py <args>` and parses its one JSON line. Blocking; call off the main thread when the
/// folder can be big (list, install, digest). Returns nil + error on failure.
static id RunCLI(NSArray<NSString *> *args, NSString **error) {
    NSString *script = [[OVPaths runtime] stringByAppendingPathComponent:@"cns_plugins.py"];
    NSString *py = [NSFileManager.defaultManager isExecutableFileAtPath:OVPluginPython()] ? OVPluginPython() : @"/usr/bin/python3";
    if (![NSFileManager.defaultManager fileExistsAtPath:script]) {
        if (error) *error = L(@"The plugin support files are missing. Open Setup and repair the engine.");
        return nil;
    }
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:py];
    t.arguments = [@[script] arrayByAddingObjectsFromArray:args];
    t.environment = @{@"PATH": @"/usr/bin:/bin", @"LANG": @"en_US.UTF-8", @"PYTHONNOUSERSITE": @"1",
                      @"PYTHONDONTWRITEBYTECODE": @"1", @"OV_OFFLINE": OVNetwork.offline ? @"1" : @"0"};
    NSPipe *out = [NSPipe pipe];
    t.standardOutput = out;
    t.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSError *e = nil;
    if (![t launchAndReturnError:&e]) { if (error) *error = e.localizedDescription; return nil; }
    NSData *data = [out.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    id obj = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (!obj) { if (error) *error = L(@"The plugin helper did not answer."); return nil; }
    if ([obj isKindOfClass:NSDictionary.class] && [obj[@"error"] isKindOfClass:NSString.class]) {
        if (error) *error = obj[@"error"];
        return nil;
    }
    return obj;
}

#pragma mark - OVPlugin

@interface OVPlugin ()
@property (copy) NSString *identifier, *folder;
@property (copy, nullable) NSString *name, *version, *author, *summary, *digest, *error;
@property (copy) NSArray<NSDictionary *> *actions;
@property (copy) NSArray<NSString *> *permissions;
@property NSInteger timeoutSeconds;
@end

@implementation OVPlugin
- (BOOL)wantsNetwork { return [self.permissions containsObject:@"network"]; }
@end

#pragma mark - OVPlugins

@interface OVPlugins ()
- (OVProcessSpec *)specForJob:(OVJob *)job;
@end

@implementation OVPlugins {
    NSArray<OVPlugin *> *_plugins;
}

+ (instancetype)shared {
    static OVPlugins *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [OVPlugins new]; [self registerKind]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) _plugins = @[];
    return self;
}

- (NSArray<OVPlugin *> *)plugins { return _plugins; }
- (BOOL)enabled { return [NSUserDefaults.standardUserDefaults boolForKey:kEnabledKey]; }
- (void)setEnabled:(BOOL)enabled {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kEnabledKey];
    [NSNotificationCenter.defaultCenter postNotificationName:OVPluginsDidChangeNotification object:self];
}

- (OVPlugin *)pluginWithId:(NSString *)identifier {
    for (OVPlugin *p in _plugins) if ([p.identifier isEqualToString:identifier]) return p;
    return nil;
}

- (void)reload:(void (^)(void))done {
    NSString *dir = [OVPaths plugins];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil;
        NSArray *items = RunCLI(@[@"list", dir], &err);
        NSMutableArray<OVPlugin *> *list = [NSMutableArray array];
        for (NSDictionary *it in [items isKindOfClass:NSArray.class] ? items : @[]) {
            OVPlugin *p = [OVPlugin new];
            NSDictionary *m = it[@"manifest"];
            p.folder = it[@"folder"] ?: @"";
            p.identifier = m[@"id"] ?: it[@"dir_id"] ?: @"";
            p.error = it[@"error"];
            p.name = m[@"name"] ?: p.identifier;
            p.version = m[@"version"]; p.author = m[@"author"]; p.summary = m[@"description"];
            p.digest = it[@"digest"];
            p.actions = m[@"actions"] ?: @[];
            p.permissions = m[@"permissions"] ?: @[];
            p.timeoutSeconds = [m[@"timeout_s"] integerValue] ?: 600;
            [list addObject:p];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_plugins = list;
            for (OVPlugin *p in list) if ([self switchOn:p] && [self needsTrust:p]) [self turnOff:p];   // files changed: ask again
            [NSNotificationCenter.defaultCenter postNotificationName:OVPluginsDidChangeNotification object:self];
            if (done) done();
        });
    });
}

#pragma mark State

- (BOOL)switchOn:(OVPlugin *)p { return [NSUserDefaults.standardUserDefaults boolForKey:EnabledKey(p.identifier)]; }

- (BOOL)needsTrust:(OVPlugin *)p {
    NSString *stored = [NSUserDefaults.standardUserDefaults stringForKey:TrustKey(p.identifier)];
    return !(stored.length && p.digest.length && [stored isEqualToString:p.digest]);
}

- (BOOL)isActive:(OVPlugin *)p {
    return self.enabled && !p.error && [self switchOn:p] && ![self needsTrust:p];
}

- (BOOL)networkAllowed:(OVPlugin *)p {
    return p.wantsNetwork && [NSUserDefaults.standardUserDefaults boolForKey:NetKey(p.identifier)]
        && [OVNetwork decisionFor:OVNetPluginNetwork] == OVNetAllowed;
}

- (void)trust:(OVPlugin *)p allowNetwork:(BOOL)allowNetwork {
    if (!p.digest.length) return;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setObject:p.digest forKey:TrustKey(p.identifier)];
    [d setBool:allowNetwork && p.wantsNetwork forKey:NetKey(p.identifier)];
    [d setBool:YES forKey:EnabledKey(p.identifier)];
    [NSNotificationCenter.defaultCenter postNotificationName:OVPluginsDidChangeNotification object:self];
}

- (void)turnOff:(OVPlugin *)p {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:NO forKey:EnabledKey(p.identifier)];
    [d removeObjectForKey:NetKey(p.identifier)];
    [NSNotificationCenter.defaultCenter postNotificationName:OVPluginsDidChangeNotification object:self];
}

+ (NSString *)consentTextFor:(OVPlugin *)p {
    return [NSString stringWithFormat:L(@"This is code written by someone else. It runs on your Mac with your user’s permissions inside a restricted sandbox (cannot write outside its own folders; network only if it declares it and you allow it). Install only plugins you trust. Plugin: %@ by %@, files checksum %@."),
            p.name ?: p.identifier, p.author ?: @"?", [p.digest substringToIndex:MIN((NSUInteger)12, p.digest.length)] ?: @""];
}

#pragma mark Install, remove

- (void)installFolder:(NSString *)path completion:(void (^)(NSString *, NSString *))done {
    NSString *dir = [OVPaths plugins];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil;
        NSDictionary *r = RunCLI(@[@"install", path, dir], &err);
        NSString *pid = [r isKindOfClass:NSDictionary.class] ? r[@"id"] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!pid) { done(nil, err ?: L(@"The plugin could not be installed.")); return; }
            [self reload:^{ done(pid, nil); }];
        });
    });
}

- (void)remove:(OVPlugin *)p {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *pid = p.identifier;
    [fm trashItemAtURL:[NSURL fileURLWithPath:p.folder] resultingItemURL:nil error:nil];
    NSString *data = [[OVPaths pluginData] stringByAppendingPathComponent:pid];
    if ([fm fileExistsAtPath:data]) [fm trashItemAtURL:[NSURL fileURLWithPath:data] resultingItemURL:nil error:nil];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    for (NSString *k in @[EnabledKey(pid), TrustKey(pid), NetKey(pid)]) [d removeObjectForKey:k];
    [self reload:nil];
}

#pragma mark Running

- (OVJob *)submit:(OVPlugin *)p action:(NSString *)action inputs:(NSDictionary *)inputs error:(NSString **)error {
    if (![self isActive:p]) {
        if (error) *error = L(@"This plugin is off. Turn it on in Plugins first.");
        return nil;
    }
    NSDictionary *a = nil;
    for (NSDictionary *x in p.actions) if ([x[@"id"] isEqualToString:action]) a = x;
    if (!a) { if (error) *error = L(@"The plugin has no such action."); return nil; }
    NSDictionary *req = @{@"plugin": p.identifier, @"action": action, @"inputs": inputs ?: @{},
                          @"title": [NSString stringWithFormat:@"%@ — %@", p.name, a[@"label"] ?: action]};
    return [OVJobs.shared submitKind:OVJobKindPlugin request:req origin:[@"plugin:" stringByAppendingString:p.identifier]
                            onFinish:nil error:error];
}

+ (void)registerKind {
    [OVJobs.shared registerKind:OVJobKindPlugin lane:OVJobLaneCompute retryable:NO   // inputs may hold redacted values; run it again from the page
        title:^NSString *(NSDictionary *r) { return r[@"title"] ?: L(@"Plugin"); }
        factory:OVProcessRunnerFactory(^OVProcessSpec *(OVJob *job) { return [OVPlugins.shared specForJob:job]; })
        onSuccess:nil];
}

static OVProcessSpec *Failing(NSString *message) {
    OVProcessSpec *s = [OVProcessSpec new];
    s.executable = @"/usr/bin/true";
    s.beforeStart = ^(void (^proceed)(BOOL, NSString *)) { proceed(NO, message); };
    return s;
}

/// Builds the process: sandbox-exec + the plugin host in the plugin's Python, the allowlisted environment, the request on stdin.
- (OVProcessSpec *)specForJob:(OVJob *)job {
    NSDictionary *req = job.runnerRequest;
    OVPlugin *p = [self pluginWithId:[req[@"plugin"] isKindOfClass:NSString.class] ? req[@"plugin"] : @""];
    NSString *action = [req[@"action"] isKindOfClass:NSString.class] ? req[@"action"] : @"";
    if (!p || ![self isActive:p]) return Failing(L(@"This plugin is off. Turn it on in Plugins first."));
    NSString *py = OVPluginPython();
    NSString *host = [[OVPaths runtime] stringByAppendingPathComponent:@"cns_plugin_host.py"];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm isExecutableFileAtPath:py] || ![fm fileExistsAtPath:host])
        return Failing(L(@"Plugins need the Python engine. Open Setup and install it first."));
    NSString *work = job.workDirectory;
    NSString *data = [[OVPaths pluginData] stringByAppendingPathComponent:p.identifier];
    [fm createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *err = nil;
    // The sandbox hides the home folder from the plugin: only the job's own input files (audio inputs) are opened up.
    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithArray:@[@"launch", py, host, p.folder, action, work, data,
                                    [self networkAllowed:p] ? @"1" : @"0",
                                    [job.folder stringByAppendingPathComponent:@"sandbox.sb"]]];
    NSDictionary *given = [req[@"inputs"] isKindOfClass:NSDictionary.class] ? req[@"inputs"] : @{};
    for (NSDictionary *a in p.actions) {
        if (![a[@"id"] isEqualToString:action]) continue;
        for (NSDictionary *in in a[@"inputs"]) {
            NSString *path = given[in[@"name"]];
            if ([in[@"type"] isEqualToString:@"audio"] && [path isKindOfClass:NSString.class] && path.isAbsolutePath)
                [args addObject:path];
        }
    }
    NSDictionary *launch = RunCLI(args, &err);
    NSArray *argv = [launch isKindOfClass:NSDictionary.class] ? launch[@"argv"] : nil;
    if (argv.count < 2) return Failing(err ?: L(@"The plugin could not be started."));

    OVProcessSpec *spec = [OVProcessSpec new];
    spec.executable = argv[0];
    spec.arguments = [argv subarrayWithRange:NSMakeRange(1, argv.count - 1)];
    spec.environment = launch[@"env"];
    spec.currentDirectory = work;
    NSDictionary *input = @{@"inputs": [req[@"inputs"] isKindOfClass:NSDictionary.class] ? req[@"inputs"] : @{}, @"work_dir": work};
    NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:input options:0 error:nil] mutableCopy];
    [line appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    spec.stdinData = line;
    spec.killGrace = 2;
    NSString *pid = p.identifier, *folder = p.folder;
    spec.beforeStart = ^(void (^proceed)(BOOL, NSString *)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (OVWorker.shared.running && !OVWorker.shared.busy) [OVWorker.shared shutdown];   // free memory for the plugin
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                // the files may have changed since the switch was turned on: check the checksum again, right before the start
                NSString *derr = nil;
                NSDictionary *r = RunCLI(@[@"digest", folder], &derr);
                NSString *now = [r isKindOfClass:NSDictionary.class] ? r[@"digest"] : nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                    OVPlugin *cur = [OVPlugins.shared pluginWithId:pid];
                    NSString *stored = [NSUserDefaults.standardUserDefaults stringForKey:TrustKey(pid)];
                    if (!now || !stored.length || ![stored isEqualToString:now]) {
                        if (cur) [OVPlugins.shared turnOff:cur];
                        [OVPlugins.shared reload:nil];
                        proceed(NO, L(@"The plugin’s files changed since you turned it on. Turn it on again to confirm."));
                        return;
                    }
                    proceed(YES, nil);
                });
            });
        });
    };
    return spec;
}

@end
