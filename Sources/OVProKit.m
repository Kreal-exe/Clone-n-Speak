#import "OVProKit.h"
#import "OVDesign.h"
#import "OVLocale.h"
#import "OVMemory.h"
#import "OVPaths.h"
#import "OVStore.h"
#import "OVWorker.h"
#import "OVRuntime.h"

#pragma mark - Titles

static NSString *OVProName(NSDictionary *r) {
    for (NSString *k in @[@"_name", @"name"]) {
        id v = r[k];
        if ([v isKindOfClass:NSString.class] && [v length]) return v;
    }
    id in = r[@"input"];
    if ([in isKindOfClass:NSString.class] && [in length]) return [in lastPathComponent];
    id url = r[@"url"];
    if ([url isKindOfClass:NSString.class] && [url length]) return [NSURL URLWithString:url].host ?: url;
    return @"";
}

static NSString *OVProTitle(NSString *kind, NSDictionary *r) {
    NSString *n = OVProName(r);
    BOOL has = n.length > 0;
    if ([kind isEqualToString:OVProKindConvert]) return has ? [NSString stringWithFormat:L(@"Convert: %@"), n] : L(@"Convert voice");
    if ([kind isEqualToString:OVProKindRvcImport]) return has ? [NSString stringWithFormat:L(@"Import voice model: %@"), n] : L(@"Import voice model");
    if ([kind isEqualToString:OVProKindRvcInfo]) return L(@"Checking voice model");
    if ([kind isEqualToString:OVProKindRvcFetch]) return has ? [NSString stringWithFormat:L(@"Download voice model: %@"), n] : L(@"Download voice model");
    if ([kind isEqualToString:OVProKindRvcBlend]) return has ? [NSString stringWithFormat:L(@"Blend voices: %@"), n] : L(@"Blend voices");
    if ([kind isEqualToString:OVProKindRvcTrain]) return has ? [NSString stringWithFormat:L(@"Training: %@"), n] : L(@"Voice training");
    if ([kind isEqualToString:OVProKindRvcReview]) return L(@"Reviewing the training audio");
    if ([kind isEqualToString:OVProKindRealtime]) return L(@"Realtime voice");
    if ([kind isEqualToString:OVProKindStems]) return has ? [NSString stringWithFormat:L(@"Separate: %@"), n] : L(@"Separate stems");
    if ([kind isEqualToString:OVProKindYouTube]) return has ? [NSString stringWithFormat:L(@"YouTube: %@"), n] : L(@"YouTube import");
    if ([kind isEqualToString:OVProKindEdge]) return L(@"Edge speech");
    if ([kind isEqualToString:OVProKindEdgeVoices]) return L(@"Edge voices");
    if ([kind isEqualToString:OVProKindEngineWeights]) return L(@"Downloading models");
    if ([kind isEqualToString:OVProKindEngineUpdate]) return L(@"Updating yt-dlp");
    return L(@"Installing components");
}

#pragma mark - The live host

@interface OVProLiveHost : NSObject <OVProRunHost>
@property (weak) NSWindow *window;
@property unsigned long long pendingReclaim;   // what the engine we just shut down will give back
@property (strong) NSDate *unloadedAt;
@property OVNetFeature net;
@property (copy) void (^submit)(BOOL reduced);
@end

@implementation OVProLiveHost
- (double)physicalMemoryGB { return [OVSettings physicalMemoryGB]; }
- (BOOL)confirmLowMemory { return OVConfirmProRun(self.window); }
- (BOOL)justUnloaded { return self.unloadedAt && -[self.unloadedAt timeIntervalSinceNow] < 3; }
- (unsigned long long)availableBytes { return [OVMemory availableBytes] + ([self justUnloaded] ? self.pendingReclaim : 0); }
- (unsigned long long)reclaimableBytes {
    unsigned long long f = OVWorker.shared.engineFootprint;
    return f > 380000000ULL ? f - 380000000ULL : 0;
}
- (NSTimeInterval)settleDelay { return [self justUnloaded] ? 1.2 : 0; }   // the process needs a moment to exit

/// Frees OmniVoice and Whisper. A running synth or clone is never killed for it: when the compute lane or the worker is
/// busy, nothing happens here and the pro job unloads in its own beforeStart, when the lane is free.
- (void)unloadMainModels {
    OVEngines *e = OVEngines.shared;
    if (OVWorker.shared.busy) return;
    if (!e.inBeforeStart && e.computeLaneBusy) return;
    BOOL had = OVWorker.shared.running;
    unsigned long long reclaim = [self reclaimableBytes];
    [OVWorker.shared shutdown];
    if (had) { self.pendingReclaim = reclaim; self.unloadedAt = [NSDate date]; }
}

- (BOOL)askLowFreeNeed:(unsigned long long)need available:(unsigned long long)avail {
    NSAlert *a = [NSAlert new];
    a.messageText = L(@"Not enough free memory");
    a.informativeText = [NSString stringWithFormat:L(@"This needs about %@ of free memory, and %@ is free now. Close other apps first, or run it anyway and risk a big slowdown."),
                         [OVMemory format:need], [OVMemory format:avail]];
    [a addButtonWithTitle:L(@"Cancel")];       // Return = the safe answer
    [a addButtonWithTitle:L(@"Run anyway")];
    NSWindow *w = self.window;
    if (w) {
        NSRect f = a.window.frame;
        [a.window setFrameOrigin:NSMakePoint(NSMidX(w.frame) - NSWidth(f) / 2, NSMidY(w.frame) - NSHeight(f) / 2)];
    }
    return [a runModal] == NSAlertSecondButtonReturn;
}

- (void)requestNetwork:(void (^)(BOOL))done {
    if ((NSInteger)self.net < 0) { done(YES); return; }
    [OVNetwork requestFeature:self.net window:self.window completion:done];
}

- (void)submitReducedBatch:(BOOL)reduced { if (self.submit) self.submit(reduced); }
@end

#pragma mark - OVProKit

@implementation OVProKit
+ (void)registerKinds {
    OVEngines *engines = OVEngines.shared;
    engines.runHost = [OVProLiveHost new];
    for (NSDictionary *row in [OVEngines kindTable]) {
        NSString *kind = row[@"kind"];
        BOOL engineKind = [kind isEqualToString:OVProKindEngineInstall] || [kind isEqualToString:OVProKindEngineWeights] ||
                          [kind isEqualToString:OVProKindEngineUpdate];
        [OVJobs.shared registerKind:kind lane:(OVJobLane)[row[@"lane"] integerValue] retryable:[row[@"retryable"] boolValue]
                              title:^NSString *(NSDictionary *r) { return OVProTitle(kind, r); }
                            factory:OVProcessRunnerFactory(^OVProcessSpec *(OVJob *job) { return [OVEngines.shared specForKind:kind job:job]; })
                          onSuccess:engineKind ? ^(OVJob *job) { [OVEngines.shared refresh]; }
                                     : [kind isEqualToString:OVProKindRvcBlend] ? ^(OVJob *job) {   // lists refresh even when the page is gone
                                           [NSNotificationCenter.defaultCenter postNotificationName:OVRvcModelsDidChangeNotification object:nil];
                                       } : nil];
    }
    // A pro job holds the memory the main models would need: direct requests wait for it.
    OVWorker.requestGuard = ^NSString *(NSDictionary *req) { return [OVEngines.shared guardMessageForRequest:req]; };
    [engines refresh];
}
@end

#pragma mark - OVProRun

@implementation OVProRun
+ (void)submitKind:(NSString *)kind request:(NSDictionary *)req feature:(NSString *)feature window:(NSWindow *)w
           network:(OVNetFeature)net completion:(void (^)(OVJob *, NSString *))done {
    NSDictionary *info = [OVEngines infoForKind:kind];
    if (!info) { done(nil, L(@"This task isn’t available.")); return; }
    BOOL install = [kind isEqualToString:OVProKindEngineInstall] || [kind isEqualToString:OVProKindEngineWeights] ||
                   [kind isEqualToString:OVProKindEngineUpdate];
    NSString *engine = [OVEngines engineNameForKind:kind request:req];
    if (!install && (!engine || ![OVEngines.shared pythonForEngine:engine])) {
        done(nil, [NSString stringWithFormat:L(@"%@ needs its engine — install it first."), feature.length ? feature : L(@"This feature")]);
        return;
    }
    OVEngines *engines = OVEngines.shared;
    NSString *option = [OVEngines peakOptionForKind:kind request:req];
    BOOL train = [kind isEqualToString:OVProKindRvcTrain] && ![option isEqual:@"batch2"];
    NSInteger feat = (NSInteger)net >= 0 ? (NSInteger)net : [info[@"net"] integerValue];
    BOOL heavy = [info[@"heavy"] boolValue], light = [info[@"light"] boolValue];
    OVProRunPlan *plan = [OVProRunPlan planWithPeakBytes:heavy || light ? [engines peakBytesForKind:kind option:option] : 0
                                        reducedPeakBytes:heavy && train ? [engines peakBytesForKind:kind option:@"batch2"] : 0
                                            needsNetwork:feat >= 0 heavy:heavy];
    plan.memoryCheckOnly = light;
    OVProLiveHost *host = [OVProLiveHost new];
    host.window = w;
    host.net = (OVNetFeature)feat;
    host.submit = ^(BOOL reduced) {
        NSMutableDictionary *r = [req mutableCopy];
        if (reduced) r[@"batch_size"] = @2;
        if (plan.lowFreeAccepted) r[@"_lowFreeAccepted"] = @YES;   // the job re-checks silently when it starts
        NSString *err = nil;
        OVJob *job = [OVJobs.shared submitKind:kind request:r origin:@"app" onFinish:nil error:&err];
        done(job, job ? nil : (err ?: L(@"The task could not be started.")));
    };
    [plan executeWithHost:host completion:^(OVProRunOutcome outcome, BOOL reduced) {
        if (outcome == OVProRunDeclined) { OVProLiveHost *keep = host; (void)keep; done(nil, nil); }
    }];
}
@end

#pragma mark - The gate card

static BOOL IsInstallKind(NSString *k) { return [k isEqualToString:OVProKindEngineInstall] || [k isEqualToString:OVProKindEngineWeights]; }

@interface OVEngineGate : OVBoxView
@property (copy) NSString *feature;
@property (copy) NSArray<NSString *> *ids;
@property (copy) void (^onChange)(BOOL ready);
@property NSTextField *titleLabel, *detailLabel;
@property NSButton *action, *stop;
@property NSProgressIndicator *bar;
@property NSNumber *lastReady;
@property (weak) OVJob *job;
@property BOOL retry, needsSetup;
@end

@implementation OVEngineGate

+ (instancetype)gateWithFeature:(NSString *)feature ids:(NSArray<NSString *> *)ids onChange:(void (^)(BOOL))onChange {
    OVEngineGate *g = [OVEngineGate boxWithFill:OVColor(OVRoleField) border:OVColor(OVRoleBorder) radius:12];
    g.feature = feature; g.ids = ids; g.onChange = onChange;
    g.titleLabel = OVLabel(@"", 14, NSFontWeightSemibold, nil);
    g.detailLabel = OVWrapLabel(@"", 13, nil);
    g.action = OVSmallPill(OVPrimaryButton(L(@"Install"), g, @selector(act:)));
    g.stop = OVSmallPill(OVGhostButton(L(@"Stop"), nil, g, @selector(stopJob:)));
    g.bar = OVProgressBar();
    NSStackView *text = OVVStack(@[g.titleLabel, g.detailLabel], 4);
    OVFillWidth(@[g.detailLabel], text);
    NSStackView *row = OVHStack(@[text, OVSpacer(), g.stop, g.action], 10);
    row.alignment = NSLayoutAttributeCenterY;
    NSStackView *all = OVVStack(@[row, g.bar], 10);
    OVFillWidth(@[row, g.bar], all);
    all.translatesAutoresizingMaskIntoConstraints = NO;
    [g addSubview:all];
    OVPin(all, g, NSEdgeInsetsMake(14, 16, 14, 16));
    g.action.accessibilityLabel = L(@"Install");
    [NSNotificationCenter.defaultCenter addObserver:g selector:@selector(update) name:OVEnginesDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:g selector:@selector(update) name:OVJobsDidChangeNotification object:nil];
    [OVEngines.shared refresh];
    [g update];
    return g;
}

- (NSArray<OVEngineComponent *> *)missing {
    NSMutableArray *m = [NSMutableArray array];
    for (NSString *i in self.ids) {
        OVEngineComponent *c = [OVEngines.shared componentWithId:i];
        if (!c || c.state != OVEngineReady) { if (c) [m addObject:c]; }
    }
    return m;
}

/// The newest install job that touches one of our components.
- (OVJob *)relevantJob {
    for (OVJob *j in OVJobs.shared.all) {
        if (!IsInstallKind(j.kind)) continue;
        id ids = j.request[@"components"];
        if (![ids isKindOfClass:NSArray.class]) continue;
        for (NSString *i in self.ids) if ([ids containsObject:i]) return j;
    }
    return nil;
}

- (void)update {
    OVEngines *engines = OVEngines.shared;
    self.accessibilityRole = NSAccessibilityGroupRole;
    self.accessibilityLabel = [NSString stringWithFormat:L(@"%@: engine setup"), self.feature];
    if (!engines.statusLoaded) {
        // No status yet: checking, or the check failed (the main engine may be missing).
        self.hidden = NO;
        BOOL failed = engines.statusError.length && !engines.refreshing;
        self.titleLabel.stringValue = failed ? L(@"Set up the main engine first") : [NSString stringWithFormat:L(@"%@: checking the engine…"), self.feature];
        self.detailLabel.stringValue = failed ? engines.statusError : L(@"Checking…");
        self.detailLabel.textColor = failed ? OVColor(OVRoleErr) : OVColor(OVRoleMuted);
        self.bar.hidden = YES;
        self.stop.hidden = YES;
        self.action.hidden = !failed;
        self.retry = YES;
        self.needsSetup = failed && OVRuntime.shared.state != OVRuntimeReady;   // Retry cannot help: the main engine has to be installed first
        self.action.title = self.needsSetup ? L(@"Open Setup") : L(@"Retry");
        self.action.accessibilityLabel = self.action.title;
        if (!failed && !engines.refreshing) [engines refresh];
        return;
    }
    NSArray<OVEngineComponent *> *missing = [self missing];
    BOOL ready = missing.count == 0;
    if (!self.lastReady || self.lastReady.boolValue != ready) {
        self.lastReady = @(ready);
        if (self.onChange) self.onChange(ready);
    }
    self.hidden = ready;
    if (ready) return;

    unsigned long long bytes = 0;
    BOOL broken = NO, partial = NO;
    for (OVEngineComponent *c in missing) {
        bytes += c.downloadBytes;
        if (c.state == OVEngineBroken) broken = YES;
        if (c.state == OVEnginePartial) partial = YES;
    }
    OVJob *job = [self relevantJob];
    self.job = job;
    self.retry = NO;
    self.needsSetup = NO;
    BOOL running = job.active;
    self.titleLabel.stringValue = [NSString stringWithFormat:L(@"%1$@ needs its engine · %2$@ download"), self.feature, OVFormatBytes((long long)bytes)];
    self.bar.hidden = !running;
    self.stop.hidden = !running;
    self.action.hidden = running;
    self.stop.accessibilityLabel = [NSString stringWithFormat:L(@"Stop %@"), self.feature];
    self.detailLabel.textColor = OVColor(OVRoleMuted);
    if (running) {
        self.detailLabel.stringValue = job.status.length ? job.status : L(@"Installing…");
        self.bar.indeterminate = job.progress < 0;
        if (job.progress >= 0) { self.bar.minValue = 0; self.bar.maxValue = 1; self.bar.doubleValue = job.progress; }
        else [self.bar startAnimation:nil];
        self.bar.accessibilityLabel = L(@"Installation progress");
        self.bar.accessibilityValue = job.progress >= 0 ? [NSString stringWithFormat:@"%.0f%%", job.progress * 100] : L(@"In progress");
        return;
    }
    [self.bar stopAnimation:nil];
    NSString *detail = L(@"Installs once; it works offline afterwards.");
    NSString *title = L(@"Install");
    // A failure counts only when it is newer than the last status: after a fresh check the state speaks for itself.
    BOOL failedNewer = job && job.state == OVJobFailed && job.error.length && job.finished &&
                       (!engines.statusDate || [job.finished compare:engines.statusDate] == NSOrderedDescending);
    if (failedNewer) {
        detail = job.error;
        title = L(@"Try again");
        self.detailLabel.textColor = OVColor(OVRoleErr);
    } else if (broken) {
        detail = L(@"Some engine files are damaged or missing.");
        title = L(@"Repair");
    } else if (partial) {
        detail = L(@"The installation was interrupted. It continues where it stopped.");
        title = L(@"Finish installing");
    }
    self.detailLabel.stringValue = detail;
    self.action.title = title;
    self.action.accessibilityLabel = [NSString stringWithFormat:@"%@ — %@", title, self.feature];
}

- (void)act:(id)sender {
    if (self.needsSetup) { [NSNotificationCenter.defaultCenter postNotificationName:@"OVNavigate" object:@"setup"]; return; }   // same as OVNavigate(@"setup")
    if (self.retry) { [OVEngines.shared refresh]; [self update]; return; }
    NSMutableArray *ids = [NSMutableArray array];
    for (OVEngineComponent *c in [self missing]) [ids addObject:c.identifier];
    NSString *err = nil;
    OVJob *j = [OVEngines.shared install:ids error:&err];   // refuses with a text while a pro job runs or the gate is closed
    if (!j) {
        self.detailLabel.stringValue = err ?: L(@"The installation could not start.");
        self.detailLabel.textColor = OVColor(OVRoleErr);
        return;
    }
    [self update];
}

- (void)stopJob:(id)sender { if (self.job.active) [OVJobs.shared stop:self.job]; }
@end

NSView *OVEngineGateCard(NSString *feature, NSArray<NSString *> *componentIds, void (^onChange)(BOOL ready)) {
    return [OVEngineGate gateWithFeature:feature ids:componentIds onChange:onChange];
}
