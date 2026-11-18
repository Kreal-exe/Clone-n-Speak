// Full stem separation card (task 7.13): the pro separation models (Kim MDX, BS-Roformer, Demucs, dereverb) through the
// `stems` job kind. Everything heavy runs in the pro engine via OVProRun; the card only builds the request and shows results.
#import "OVStemsCard.h"
#import "OVDesign.h"
#import "OVUI.h"
#import "OVLocale.h"
#import "OVPages.h"
#import "OVPaths.h"
#import "OVPlayerBar.h"
#import "OVAudioIO.h"
#import "OVJobs.h"
#import "OVEngines.h"
#import "OVProKit.h"
#import "OVNetwork.h"
#import <objc/runtime.h>

static NSString *const kModelKey = @"OVStemsModel", *const kOutputKey = @"OVStemsOutput", *const kFormatKey = @"OVStemsFormat";
static const NSTimeInterval kMaxInputSeconds = 60 * 60;
static const NSTimeInterval kLongInputSeconds = 10 * 60;
static char kControllerKey;

#pragma mark - Models

@interface OVStemsModelInfo ()
@property (copy) NSString *identifier, *title, *license, *componentId, *licenseNote;
@property OVStemsKind kind;
@property BOOL verified;
@property double peakGB, speed;
@property unsigned long long fallbackBytes;
@end

@implementation OVStemsModelInfo

+ (NSArray<OVStemsModelInfo *> *)all {
    static NSArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Fixed English captions: L() is applied where they are shown, and tools/strings.py finds these literals below.
        NSString *kimNote = L(@"License unverified: the author of these weights has published none. You accepted this; the model is downloaded only on request.");
        NSString *deNote = L(@"License unverified: fine-tuned from a model that has no published license (the author's page says GPL-3.0). You accepted this; downloaded only on request.");
        a = @[[self id:@"kim-vocal-2" title:L(@"Fast (MDX)") kind:OVStemsKindVocals license:@"unverified" verified:NO peak:7.2 speed:0.4
                bytes:66800000ULL note:kimNote],
              [self id:@"bs-roformer" title:L(@"Quality (Roformer)") kind:OVStemsKindVocals license:@"unverified" verified:NO peak:6.6 speed:1.0
                bytes:639400000ULL note:kimNote],
              [self id:@"htdemucs" title:L(@"Stems (Demucs)") kind:OVStemsKindStems license:@"MIT" verified:YES peak:2.3 speed:0.5
                bytes:84200000ULL note:nil],
              [self id:@"dereverb-anvuew" title:L(@"Remove reverb") kind:OVStemsKindDereverb license:@"unverified" verified:NO peak:6.3 speed:1.0
                bytes:913100000ULL note:deNote]];
    });
    return a;
}

+ (instancetype)id:(NSString *)ident title:(NSString *)title kind:(OVStemsKind)kind license:(NSString *)lic verified:(BOOL)v
              peak:(double)peak speed:(double)speed bytes:(unsigned long long)bytes note:(NSString *)note {
    OVStemsModelInfo *m = [OVStemsModelInfo new];
    m.identifier = ident; m.title = title; m.kind = kind; m.license = lic; m.verified = v; m.peakGB = peak; m.speed = speed;
    m.componentId = [@"stems-" stringByAppendingString:ident]; m.fallbackBytes = bytes;
    m.licenseNote = note ?: @"";
    return m;
}

+ (OVStemsModelInfo *)modelWithId:(NSString *)identifier {
    for (OVStemsModelInfo *m in self.all) if ([m.identifier isEqualToString:identifier]) return m;
    return nil;
}

- (NSTimeInterval)estimateForSeconds:(NSTimeInterval)seconds { return seconds * self.speed; }

- (NSString *)summaryWithDownloadBytes:(unsigned long long)bytes {
    NSString *dl = [NSString stringWithFormat:L(@"Download %@"), OVFormatBytes((long long)(bytes ?: self.fallbackBytes))];
    NSString *time = [NSString stringWithFormat:L(@"≈ %.1f× the length"), self.speed];
    NSString *mem = [NSString stringWithFormat:L(@"Needs about %.1f GB"), self.peakGB];
    return [@[dl, time, mem] componentsJoinedByString:@" · "];
}
@end

@implementation OVStemsRequests

+ (NSDictionary *)requestWithInput:(NSString *)input model:(OVStemsModelInfo *)model output:(NSInteger)output
                            format:(NSString *)format name:(nullable NSString *)name {
    NSString *stems = @"all";
    if (model.kind != OVStemsKindDereverb) stems = output == 1 ? @"vocals" : output == 2 ? @"instrumental" : @"all";
    NSString *fmt = [format.lowercaseString isEqualToString:@"flac"] ? @"flac" : @"wav";
    NSMutableDictionary *r = [@{@"input": input, @"model": model.identifier, @"stems": stems, @"output_format": fmt} mutableCopy];
    if (name.length) r[@"_name"] = name;
    return r;
}

+ (NSString *)stemForOutputPath:(NSString *)path {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"_(vocals|instrumental|drums|bass|other|dry|reverb)(?: \\(\\d+\\))?\\.[A-Za-z0-9]+$" options:0 error:nil];
    });
    NSString *n = path.lastPathComponent;
    NSTextCheckingResult *m = [re firstMatchInString:n options:0 range:NSMakeRange(0, n.length)];
    return m ? [n substringWithRange:[m rangeAtIndex:1]] : nil;
}

+ (NSString *)titleForStem:(NSString *)stem {
    NSDictionary *t = @{@"vocals": L(@"Vocals"), @"instrumental": L(@"Instrumental"), @"drums": L(@"Drums"), @"bass": L(@"Bass"),
                        @"other": L(@"Other"), @"dry": L(@"Without reverb"), @"reverb": L(@"Reverb only")};
    return t[stem] ?: stem;
}

+ (NSTimeInterval)longInputSeconds { return kLongInputSeconds; }
@end

#pragma mark - Card controller

@interface OVStemsController : NSObject
@property (weak) NSWindow *hostWindow;
@property (weak) NSView *card;
@property (copy) NSString *sourcePath, *decodedPath;
@property NSTimeInterval seconds;
@property BOOL decoding;
@property OVPopup *modelPopup, *formatPopup;
@property OVSegmented *outputPicker;
@property NSView *outputBlock, *body, *weightsBox, *resultBox;
@property NSTextField *fileLabel, *summaryLabel, *licenseLabel, *weightsStatus, *longWarning, *runStatus, *resultNote;
@property NSButton *downloadButton, *runButton, *stopButton;
@property NSProgressIndicator *downloadBar, *runBar;
@property OVPlayerBar *inputBar, *resultBar;
@property NSStackView *resultRows;
@property (weak) OVJob *job, *weightsJob;
@property BOOL stopping, submitting;
@property (copy) NSArray<NSString *> *rowPaths;
@end

@implementation OVStemsController

- (OVStemsModelInfo *)model {
    NSInteger i = self.modelPopup.indexOfSelectedItem;
    NSArray *all = OVStemsModelInfo.all;
    return i >= 0 && i < (NSInteger)all.count ? all[(NSUInteger)i] : all.firstObject;
}

- (NSWindow *)window { return self.hostWindow ?: self.card.window; }

- (OVEngineComponent *)weights { return [OVEngines.shared componentWithId:self.model.componentId]; }

- (BOOL)engineReady { return [OVEngines.shared pythonForEngine:@"stems"] != nil; }

- (void)build {
    __weak typeof(self) w = self;
    NSView *gate = OVEngineGateCard(L(@"Full separation"), @[@"pro-env"], ^(BOOL ready) { [w update]; });

    // input
    OVDropZone *zone = [OVDropZone zoneWithTitle:L(@"Drop a song or a recording here") hint:L(@"or click to choose a file; up to 60 minutes")
                                           types:@[@"wav", @"mp3", @"m4a", @"aac", @"flac", @"aiff", @"caf", @"ogg", @"mp4", @"mov", @"m4v"]
                                         onFiles:^(NSArray<NSURL *> *urls) { if (urls.firstObject) [w loadInput:urls.firstObject.path]; }];
    self.fileLabel = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.inputBar = [OVPlayerBar new];
    self.inputBar.hidden = YES;
    self.longWarning = OVWrapLabel(@"", 13, OVColor(OVRoleWarn));
    self.longWarning.hidden = YES;

    // model
    self.modelPopup = [OVPopup popup];
    for (OVStemsModelInfo *m in OVStemsModelInfo.all) [self.modelPopup addItemWithTitle:m.title];
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:kModelKey];
    OVStemsModelInfo *sm = saved ? [OVStemsModelInfo modelWithId:saved] : nil;
    [self.modelPopup selectItemAtIndex:sm ? (NSInteger)[OVStemsModelInfo.all indexOfObject:sm] : 0];
    self.modelPopup.target = self; self.modelPopup.action = @selector(modelChanged:);
    self.modelPopup.accessibilityLabel = L(@"Separation model");
    self.summaryLabel = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.licenseLabel = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.downloadButton = OVSmallPill(OVPrimaryButton(L(@"Download model"), self, @selector(downloadWeights:)));
    self.downloadBar = OVProgressBar();
    self.downloadBar.hidden = YES;
    self.weightsStatus = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.weightsStatus.hidden = YES;
    self.weightsBox = OVFillStack(@[self.licenseLabel, OVHStack(@[self.downloadButton, OVSpacer()], 8), self.downloadBar, self.weightsStatus], 8);
    NSView *modelBlock = OVFieldBlock(L(@"Model"), nil, OVFillStack(@[OVFillPopup(self.modelPopup), self.summaryLabel, self.weightsBox], 8));

    // output
    self.outputPicker = [OVSegmented segmentedWithItems:@[@[L(@"All stems"), @""], @[L(@"Vocals"), @""], @[L(@"Instrumental"), @""]]];
    NSInteger o = [NSUserDefaults.standardUserDefaults integerForKey:kOutputKey];
    self.outputPicker.selectedIndex = o >= 0 && o <= 2 ? o : 0;
    self.outputPicker.target = self; self.outputPicker.action = @selector(outputChanged:);
    self.formatPopup = [OVPopup popup];
    [self.formatPopup addItemsWithTitles:@[@"WAV", @"FLAC"]];
    [self.formatPopup selectItemAtIndex:[[NSUserDefaults.standardUserDefaults stringForKey:kFormatKey] isEqualToString:@"flac"] ? 1 : 0];
    self.formatPopup.target = self; self.formatPopup.action = @selector(outputChanged:);
    self.formatPopup.accessibilityLabel = L(@"File format");
    self.outputBlock = OVFieldBlock(L(@"Output"), L(@"Instrumental is everything except the voice."),
                                    OVHStack(@[self.outputPicker, OVFillPopup(self.formatPopup), OVSpacer()], 12));

    // run
    self.runButton = OVPrimaryButton(L(@"Separate"), self, @selector(run:));
    self.stopButton = OVGhostButton(L(@"Stop"), nil, self, @selector(stop:));
    self.stopButton.hidden = YES;
    self.runBar = OVProgressBar();
    self.runBar.hidden = YES;
    self.runStatus = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.runStatus.hidden = YES;

    // result
    self.resultRows = OVVStack(@[], 8);
    self.resultBar = [OVPlayerBar new];
    self.resultNote = OVWrapLabel(L(@"Press play on a part, then switch between the original and the result."), 13, OVColor(OVRoleMuted));
    self.resultBox = OVFillStack(@[OVLabel(L(@"Result"), 14, NSFontWeightSemibold, nil), self.resultRows, self.resultBar, self.resultNote], 10);
    self.resultBox.hidden = YES;

    self.body = OVFillStack(@[zone, self.fileLabel, self.inputBar, self.longWarning, modelBlock, self.outputBlock,
                              OVHStack(@[self.runButton, self.stopButton, OVSpacer()], 8), self.runBar, self.runStatus, self.resultBox], 14);
    NSStackView *all = OVFillStack(@[gate, self.body], 14);
    NSView *card = OVStepCardWithAccessory(0, @"square.stack.3d.up", L(@"Full separation"), OVProBadge(), all);
    self.card = card;
    objc_setAssociatedObject(card, &kControllerKey, self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(jobsChanged:) name:OVJobsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(enginesChanged:) name:OVEnginesDidChangeNotification object:nil];
    [self update];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

#pragma mark Input

+ (NSString *)inputFolder {
    NSString *d = [[OVPaths.support stringByAppendingPathComponent:@"tmp"] stringByAppendingPathComponent:@"stems"];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

+ (BOOL)folderInUse:(NSString *)folder {
    for (OVJob *j in OVJobs.shared.all) {
        if (!(j.active || j.retryable)) continue;
        NSString *in = j.request[@"input"] ?: j.runnerRequest[@"input"];
        if ([in isKindOfClass:NSString.class] && [in hasPrefix:folder]) return YES;
    }
    return NO;
}

/// Decoded inputs live in an app-owned folder so a retry still finds its file; folders older than a day are swept.
+ (void)sweepInputs {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *d = [self inputFolder];
    for (NSString *n in [fm contentsOfDirectoryAtPath:d error:nil]) {
        NSString *p = [d stringByAppendingPathComponent:n];
        NSDate *m = [fm attributesOfItemAtPath:p error:nil][NSFileModificationDate];
        if (m && -[m timeIntervalSinceNow] > 24 * 3600 && ![self folderInUse:p]) [fm removeItemAtPath:p error:nil];
    }
}

- (void)discardDecoded:(NSString *)path {
    if (!path.length) return;
    NSString *folder = path.stringByDeletingLastPathComponent;
    if (![OVStemsController folderInUse:folder]) [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
}

- (void)loadInput:(NSString *)path {
    if (self.job.active || self.submitting) return;
    NSString *old = self.decodedPath;
    self.sourcePath = path;
    self.decoding = YES;
    self.decodedPath = nil;
    self.seconds = 0;
    [self discardDecoded:old];
    self.fileLabel.stringValue = [NSString stringWithFormat:L(@"Reading %@…"), path.lastPathComponent];
    self.inputBar.hidden = YES;
    [self clearResults];
    [self update];
    // <inputs>/<uuid>/<name>.wav: the engine names its results after the input file
    NSString *base = [path.lastPathComponent stringByDeletingPathExtension];
    NSString *dir = [[OVStemsController inputFolder] stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dst = [dir stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"wav"]];
    __weak typeof(self) w = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        double seconds = 0;
        OVDecodeOptions opts = {0, NO, kMaxInputSeconds};
        BOOL ok = OVDecodeAudio(path, dst, opts, &seconds, &err);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = w;
            if (!s || ![s.sourcePath isEqualToString:path]) { [NSFileManager.defaultManager removeItemAtPath:dir error:nil]; return; }
            s.decoding = NO;
            if (!ok) {
                [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
                s.fileLabel.stringValue = err.localizedDescription ?: L(@"This file could not be read.");
                [s update];
                return;
            }
            s.decodedPath = dst;
            s.seconds = seconds;
            s.fileLabel.stringValue = [NSString stringWithFormat:@"%@ · %@", path.lastPathComponent, OVFormatDuration(seconds)];
            s.inputBar.path = dst;
            s.inputBar.hidden = NO;
            [s update];
        });
    });
}

#pragma mark State

- (void)modelChanged:(id)sender {
    [NSUserDefaults.standardUserDefaults setObject:self.model.identifier forKey:kModelKey];
    [self update];
}

- (void)outputChanged:(id)sender {
    [NSUserDefaults.standardUserDefaults setInteger:self.outputPicker.selectedIndex forKey:kOutputKey];
    [NSUserDefaults.standardUserDefaults setObject:self.formatPopup.indexOfSelectedItem == 1 ? @"flac" : @"wav" forKey:kFormatKey];
}

- (void)enginesChanged:(NSNotification *)n { [self update]; }

- (void)update {
    OVStemsModelInfo *m = self.model;
    OVEngineComponent *wc = [self weights];
    BOOL engine = [self engineReady];
    BOOL running = self.job.active || self.submitting;
    BOOL downloading = self.weightsJob.active;
    BOOL weightsReady = wc.state == OVEngineReady;
    self.body.alphaValue = engine ? 1 : 0.45;
    self.summaryLabel.stringValue = [m summaryWithDownloadBytes:wc.downloadBytes];
    self.licenseLabel.stringValue = m.verified ? [NSString stringWithFormat:L(@"License: %@"), m.license] : m.licenseNote;
    self.licenseLabel.textColor = OVColor(m.verified ? OVRoleMuted : OVRoleWarn);
    self.weightsBox.hidden = weightsReady;
    BOOL partial = OVEngines.shared.statusLoaded && (wc.state == OVEnginePartial || wc.state == OVEngineBroken);
    self.downloadButton.title = partial ? L(@"Finish the download") : L(@"Download model");
    self.downloadButton.enabled = engine && !downloading && !running;
    self.outputBlock.hidden = m.kind == OVStemsKindDereverb;
    self.modelPopup.enabled = !running && !downloading;
    self.outputPicker.enabled = !running;
    self.formatPopup.enabled = !running;
    self.runButton.enabled = engine && weightsReady && !running && !self.decoding && self.decodedPath != nil;
    self.stopButton.hidden = !running;
    self.runBar.hidden = !running;
    self.runStatus.hidden = !running && self.runStatus.stringValue.length == 0;
    BOOL longInput = self.seconds > kLongInputSeconds;
    self.longWarning.hidden = !longInput;
    if (longInput) {
        long mins = (long)ceil([m estimateForSeconds:self.seconds] / 60.0);
        self.longWarning.stringValue = [NSString stringWithFormat:L(@"This is a long recording: it will take about %ld min on this model."), MAX(mins, 1L)];
    }
}

#pragma mark Weights

- (void)downloadWeights:(id)sender {
    if (self.weightsJob.active) return;
    OVStemsModelInfo *m = self.model;
    __weak typeof(self) w = self;
    [OVNetwork requestFeature:OVNetModelDownload window:[self window] completion:^(BOOL allowed) {
        typeof(self) s = w;
        if (!s || !allowed) return;
        NSString *err = nil;
        OVJob *job = [OVEngines.shared install:@[m.componentId] error:&err];
        if (!job) { s.weightsStatus.stringValue = err ?: L(@"The download could not be started."); s.weightsStatus.hidden = NO; return; }
        s.weightsJob = job;
        s.downloadBar.hidden = NO;
        s.downloadBar.indeterminate = YES;
        [s.downloadBar startAnimation:nil];
        s.weightsStatus.stringValue = L(@"Starting…");
        s.weightsStatus.hidden = NO;
        [s update];
    }];
}

#pragma mark Run

- (void)run:(id)sender {
    if (!self.decodedPath || self.job.active || self.submitting) return;
    OVStemsModelInfo *m = self.model;
    [self clearResults];
    self.stopping = NO;
    self.submitting = YES;
    self.runStatus.stringValue = @"";
    NSDictionary *req = [OVStemsRequests requestWithInput:self.decodedPath model:m output:self.outputPicker.selectedIndex
                                                   format:self.formatPopup.indexOfSelectedItem == 1 ? @"flac" : @"wav"
                                                     name:self.sourcePath.lastPathComponent];
    __weak typeof(self) w = self;
    [OVProRun submitKind:OVProKindStems request:req feature:L(@"Full separation") window:[self window] network:(OVNetFeature)-1
              completion:^(OVJob *job, NSString *error) {
        typeof(self) s = w;
        if (!s) return;
        s.submitting = NO;
        s.job = job;
        if (!job) {
            s.runStatus.stringValue = error ?: @"";   // nil error = the user declined: nothing to say
            [s update];
            return;
        }
        s.runBar.indeterminate = YES;
        [s.runBar startAnimation:nil];
        s.runStatus.stringValue = L(@"Starting…");
        [s update];
    }];
    [self update];
}

- (void)stop:(id)sender {
    self.stopping = YES;
    if (self.job.active) [OVJobs.shared stop:self.job];
}

- (void)jobsChanged:(NSNotification *)n {
    OVJob *wj = self.weightsJob;
    if (wj) {
        if (wj.active) {
            if (wj.progress >= 0) { self.downloadBar.indeterminate = NO; self.downloadBar.doubleValue = wj.progress; }
            self.weightsStatus.stringValue = wj.status ?: @"";
        } else {
            self.weightsJob = nil;
            [self.downloadBar stopAnimation:nil];
            self.downloadBar.hidden = YES;
            self.weightsStatus.stringValue = wj.state == OVJobSucceeded ? @"" : (wj.error ?: L(@"The download failed."));
            self.weightsStatus.hidden = wj.state == OVJobSucceeded;
            [OVEngines.shared refresh];
        }
        [self update];
    }
    OVJob *job = self.job;
    if (!job) return;
    if (job.active) {
        if (job.progress >= 0) { self.runBar.indeterminate = NO; self.runBar.doubleValue = job.progress; }
        else if (!self.runBar.indeterminate) { self.runBar.indeterminate = YES; [self.runBar startAnimation:nil]; }
        self.runStatus.stringValue = job.status ?: @"";
        self.runStatus.hidden = NO;
        return;
    }
    self.job = nil;
    [self.runBar stopAnimation:nil];
    if (job.state == OVJobSucceeded && job.outputs.count) {
        self.runStatus.stringValue = @"";
        [self showOutputs:job.outputs];
    } else if (job.state == OVJobStopped || self.stopping) {
        self.runStatus.stringValue = L(@"Stopped.");
    } else {
        self.runStatus.stringValue = job.error ?: L(@"Separation failed.");
    }
    [self update];
}

#pragma mark Result

- (void)clearResults {
    [self.resultBar stopIfPlayingThis];
    for (NSView *v in [self.resultRows.arrangedSubviews copy]) { [self.resultRows removeArrangedSubview:v]; [v removeFromSuperview]; }
    self.rowPaths = @[];
    self.resultBox.hidden = YES;
}

- (void)showOutputs:(NSArray<NSString *> *)outputs {
    NSMutableArray *paths = [NSMutableArray array];
    for (NSString *p in outputs) {
        NSString *stem = [OVStemsRequests stemForOutputPath:p];
        NSString *name = stem ? [OVStemsRequests titleForStem:stem] : p.lastPathComponent;
        NSButton *play = OVPlayButton(self, @selector(playRow:));
        play.tag = (NSInteger)paths.count;
        play.accessibilityLabel = [NSString stringWithFormat:L(@"Play %@"), name];
        NSTextField *title = OVLabel(name, 14, NSFontWeightSemibold, nil);
        NSTextField *file = OVLabel(p.lastPathComponent, 12, NSFontWeightRegular, OVColor(OVRoleMuted));
        file.lineBreakMode = NSLineBreakByTruncatingMiddle;
        NSButton *reveal = OVSmallPill(OVGhostButton(L(@"Show in Finder"), @"folder", self, @selector(revealRow:)));
        reveal.tag = (NSInteger)paths.count;
        NSStackView *row = OVHStack(@[play, OVVStack(@[title, file], 2), OVSpacer(), reveal], 12);
        row.alignment = NSLayoutAttributeCenterY;
        [self.resultRows addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.resultRows.widthAnchor].active = YES;
        [paths addObject:p];
    }
    self.rowPaths = paths;
    self.resultBar.originalPath = self.decodedPath;
    self.resultBar.path = paths.firstObject;
    [self.resultBar selectOriginal:NO];
    [self.resultBar refresh];
    self.resultBox.hidden = NO;
}

- (void)playRow:(NSButton *)b {
    if (b.tag < 0 || b.tag >= (NSInteger)self.rowPaths.count) return;
    NSString *p = self.rowPaths[(NSUInteger)b.tag];
    self.resultBar.originalPath = self.decodedPath;
    self.resultBar.path = p;
    [self.resultBar selectOriginal:NO];
    Class pc = NSClassFromString(@"OVPlayer");   // the shared player lives in the app target; tests link without it
    if ([pc respondsToSelector:@selector(shared)]) [[pc shared] toggle:p];
    [self.resultBar refresh];
}

- (void)revealRow:(NSButton *)b {
    if (b.tag < 0 || b.tag >= (NSInteger)self.rowPaths.count) return;
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:self.rowPaths[(NSUInteger)b.tag]]]];
}

@end

NSView *OVStemsCard(NSWindow *host, NSString *preselectedPath) {
    OVStemsController *c = [OVStemsController new];
    c.hostWindow = host;
    c.rowPaths = @[];
    [OVStemsController sweepInputs];
    [c build];
    if (preselectedPath.length) [c loadInput:preselectedPath];
    return c.card;
}
