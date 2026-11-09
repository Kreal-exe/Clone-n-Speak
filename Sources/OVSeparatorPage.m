// Separation page, light part (task 6.17): remove music with Kim_Vocal_2 on onnxruntime. The full stem card is added by the pro sub-plan.
#import "OVPages.h"
#import "OVDesign.h"
#import "OVUI.h"
#import "OVLocale.h"
#import "OVPlayerBar.h"
#import "OVAudioIO.h"
#import "OVJobs.h"
#import "OVWorker.h"
#import "OVRuntime.h"
#import "OVPaths.h"
#import "OVStore.h"
#import "OVExport.h"
#import "OVSeparatorModel.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

/// Posted by "Use in Audio Tools" just before the page switch; userInfo @"path" = the result file. The Audio Tools page
/// may also read +[OVSeparatorPage pendingToolsInputPath] when it appears.
NSNotificationName const OVSeparatorUseInToolsNotification = @"OVSeparatorUseInTools";

static NSString *sPendingToolsInput;

static const NSTimeInterval kMaxSeconds = 20 * 60;   // the 20-minute limit

@interface OVSeparatorPage ()
@property (nonatomic) OVSeparatorModel *model;
// input
@property (nonatomic, copy) NSString *sourcePath, *decodedPath;
@property (nonatomic) BOOL decoding;
@property (nonatomic) NSTextField *fileLabel, *engineLabel, *modelLabel, *licenseLabel, *memoryNote, *runStatus, *installStatus, *resultNote;
@property (nonatomic) OVPlayerBar *inputBar, *resultBar;
// engine
@property (nonatomic) NSView *licenseBox;
@property (nonatomic) NSButton *downloadButton, *licenseLink, *voiceCheck, *musicCheck, *runButton, *stopButton, *saveButton, *toolsButton;
@property (nonatomic) NSProgressIndicator *installBar, *runBar;
@property (nonatomic) BOOL installing;
// run
@property (nonatomic) OVJob *job;
@property (nonatomic) NSMutableArray<NSString *> *pendingStems;
@property (nonatomic) NSMutableDictionary<NSString *, NSString *> *results;   // stem -> file
@property (nonatomic) BOOL stopping;
@property (nonatomic) OVSegmented *resultPicker;
@property (nonatomic) NSView *resultCard;
@end

@implementation OVSeparatorPage

+ (NSString *)pendingToolsInputPath { return sPendingToolsInput; }

+ (void)registerKind {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [OVJobs.shared registerKind:OVJobKindSeparate lane:OVJobLaneCompute retryable:YES
                              title:^NSString *(NSDictionary *r) {
            NSString *n = [r[@"_name"] isKindOfClass:NSString.class] ? r[@"_name"] : @"";
            return n.length ? [NSString stringWithFormat:L(@"Remove music: %@"), n] : L(@"Remove music");
        } factory:OVWorkerRunnerFactory() onSuccess:nil];
    });
}

- (void)loadView {
    [OVSeparatorPage registerKind];
    self.model = [OVSeparatorModel new];
    self.pendingStems = [NSMutableArray array];
    self.results = [NSMutableDictionary dictionary];

    // 1 Input
    OVDropZone *zone;
    __weak typeof(self) weakSelf = self;
    zone = [OVDropZone zoneWithTitle:L(@"Drop a recording or a video here") hint:L(@"or click to choose a file; up to 20 minutes")
                               types:@[@"wav", @"mp3", @"m4a", @"aac", @"flac", @"aiff", @"caf", @"ogg", @"mp4", @"mov", @"m4v"]
                             onFiles:^(NSArray<NSURL *> *urls) { if (urls.firstObject) [weakSelf loadInput:urls.firstObject.path]; }];
    self.fileLabel = OVLabel(@"", 13, NSFontWeightRegular, OVColor(OVRoleMuted));
    self.inputBar = [OVPlayerBar new];
    self.inputBar.hidden = YES;
    NSView *c1 = OVFillStack(@[zone, self.fileLabel, self.inputBar], 10);

    // 2 Remove music
    self.engineLabel = OVLabel(@"", 13, NSFontWeightRegular, OVColor(OVRoleMuted));
    self.modelLabel = OVLabel(@"", 13, NSFontWeightRegular, OVColor(OVRoleMuted));
    self.licenseLabel = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.licenseLink = OVGhostButton(L(@"Open the model page"), @"arrow.up.right.square", self, @selector(openLicense:));
    self.licenseBox = OVFillStack(@[self.licenseLabel, OVHStack(@[self.licenseLink, OVSpacer()], 8)], 6);
    self.licenseBox.hidden = YES;
    self.downloadButton = OVPrimaryButton(L(@"Download engine"), self, @selector(download:));
    self.installBar = OVProgressBar();
    self.installBar.hidden = YES;
    self.installStatus = OVLabel(@"", 13, NSFontWeightRegular, OVColor(OVRoleMuted));
    self.installStatus.hidden = YES;
    NSStackView *engine = OVFillStack(@[self.engineLabel, self.modelLabel, self.licenseBox,
                                        OVHStack(@[self.downloadButton, OVSpacer()], 8), self.installBar, self.installStatus], 8);

    self.voiceCheck = OVCheckbox(L(@"Voice only"), @"OVSeparatorVoice");
    self.musicCheck = OVCheckbox(L(@"Music only"), @"OVSeparatorMusic");
    if (![NSUserDefaults.standardUserDefaults objectForKey:@"OVSeparatorVoice"]) [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"OVSeparatorVoice"];
    self.voiceCheck.state = [NSUserDefaults.standardUserDefaults boolForKey:@"OVSeparatorVoice"] ? NSControlStateValueOn : NSControlStateValueOff;
    self.memoryNote = OVWrapLabel(L(@"This Mac has less than 12 GB of memory, so removing music may take much longer. It still works."), 13, OVColor(OVRoleWarn));
    self.memoryNote.hidden = ![OVSeparatorModel slowOnMemoryGB:[OVSettings physicalMemoryGB]];
    self.runButton = OVPrimaryButton(L(@"Remove music"), self, @selector(run:));
    self.stopButton = OVGhostButton(L(@"Stop"), nil, self, @selector(stop:));
    self.stopButton.hidden = YES;
    self.runBar = OVProgressBar();
    self.runBar.hidden = YES;
    self.runStatus = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.runStatus.hidden = YES;
    NSView *remove = OVFillStack(@[engine,
                                   OVFieldBlock(L(@"What to keep"), L(@"Each result takes one pass of the model."), OVHStack(@[self.voiceCheck, self.musicCheck, OVSpacer()], 18)),
                                   self.memoryNote, OVHStack(@[self.runButton, self.stopButton, OVSpacer()], 8), self.runBar, self.runStatus], 14);
    NSView *c2 = OVStepCard(2, @"music.note.slash", L(@"Remove music"), L(@"Keeps the voice and takes the music out, or the other way round. Runs on this Mac."), remove);

    // 3 Result
    self.resultPicker = [OVSegmented segmentedWithItems:@[@[L(@"Voice only"), @""], @[L(@"Music only"), @""]]];
    self.resultPicker.target = self;
    self.resultPicker.action = @selector(pickResult:);
    self.resultPicker.hidden = YES;
    self.resultBar = [OVPlayerBar new];
    self.resultNote = OVLabel(L(@"The result appears here."), 13, NSFontWeightRegular, OVColor(OVRoleMuted));
    self.saveButton = OVGhostButton(L(@"Save as…"), @"square.and.arrow.down", self, @selector(save:));
    self.toolsButton = OVGhostButton(L(@"Use in Audio Tools"), @"slider.horizontal.3", self, @selector(useInTools:));
    NSView *res = OVFillStack(@[self.resultNote, self.resultPicker, self.resultBar, OVHStack(@[self.saveButton, self.toolsButton, OVSpacer()], 8)], 12);
    self.resultCard = OVStepCard(3, @"waveform", L(@"Result"), nil, res);
    self.resultCard.hidden = YES;

    // 4 Full stem separation: a stand-in. The pro sub-plan puts its OVStemsCard here (STEMS-CARD-SLOT).
    NSButton *disabled = OVGhostButton(L(@"Separate into stems"), nil, nil, nil);
    disabled.enabled = NO;
    disabled.toolTip = L(@"Available after installing the Pro engines");
    NSView *stems = OVFillStack(@[OVWrapLabel(L(@"Splits a song into vocals, drums, bass and the rest. Available after installing the Pro engines."), 13, OVColor(OVRoleMuted)),
                                  OVHStack(@[disabled, OVGhostButton(L(@"Learn more"), nil, self, @selector(learnMore:)), OVSpacer()], 8)], 10);
    NSView *c4 = OVStepCardWithAccessory(0, @"square.stack.3d.up", L(@"Full stem separation"), OVProBadge(), stems);   // STEMS-CARD-SLOT

    self.view = OVPageScroll(@[OVPageHeader(L(@"Separation"), L(@"Take the music out of a recording and keep the voice."), nil),
                               OVStepCard(1, @"waveform.badge.plus", L(@"Input"), nil, c1), c2, self.resultCard, c4]);

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(jobsChanged:) name:OVJobsDidChangeNotification object:nil];
    [self updateEngineUI];
    [self updateRunUI];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (self.decodedPath) [NSFileManager.defaultManager removeItemAtPath:self.decodedPath error:nil];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    [self refreshStatus];
}

#pragma mark - Engine state

- (void)refreshStatus {
    if (self.installing) return;
    if (OVWorker.shared.busy) { [self performSelector:@selector(refreshStatus) withObject:nil afterDelay:2]; return; }
    __weak typeof(self) w = self;
    [OVWorker.shared request:[OVSeparatorModel statusRequestWithDirectory:[OVPaths separationModels]] status:nil progress:nil
                        done:^(NSDictionary *data, NSString *error) {
        typeof(self) s = w;
        if (!s) return;
        if (data) [s.model applyStatus:data];
        else s.installStatus.stringValue = error ?: @"";
        s.installStatus.hidden = data != nil;
        [s updateEngineUI];
    }];
}

- (void)updateEngineUI {
    OVSeparatorModel *m = self.model;
    self.engineLabel.stringValue = m.onnxruntime ? L(@"Engine (onnxruntime, about 76 MB): installed") : L(@"Engine (onnxruntime, about 76 MB): not installed");
    self.modelLabel.stringValue = m.modelReady ? L(@"Voice extractor model (about 67 MB): installed") : L(@"Voice extractor model (about 67 MB): not installed");
    BOOL ready = m.state == OVSeparatorReady;
    if (!ready && m.license.length) {
        self.licenseLabel.stringValue = [NSString stringWithFormat:L(@"Model license: %@"), m.license];
        self.licenseBox.hidden = NO;
        [m markLicenseShown];   // the license is on screen before the model can be downloaded
    }
    self.licenseLink.hidden = m.licenseURL.length == 0;
    self.downloadButton.hidden = ready;
    self.downloadButton.title = m.state == OVSeparatorNeedsModel ? L(@"Download model") : L(@"Download engine");
    self.downloadButton.enabled = !self.installing && (m.state == OVSeparatorNeedsEngine || m.canDownloadModel);
    [self updateRunUI];
}

- (void)updateRunUI {
    BOOL running = self.job.active || self.pendingStems.count > 0;
    BOOL ready = self.model.state == OVSeparatorReady;
    BOOL anyStem = self.voiceCheck.state == NSControlStateValueOn || self.musicCheck.state == NSControlStateValueOn;
    self.runButton.enabled = ready && !running && !self.decoding && self.decodedPath != nil && anyStem && !self.installing;
    self.stopButton.hidden = !running;
    self.runBar.hidden = !running;
    self.runStatus.hidden = !running && self.runStatus.stringValue.length == 0;
}

- (void)download:(id)sender {
    if (self.installing) return;
    OVSeparatorModel *m = self.model;
    if (m.state == OVSeparatorReady) return;
    if (m.state == OVSeparatorNeedsModel && !m.canDownloadModel) return;   // the license has not been shown yet
    self.installing = YES;
    self.installBar.hidden = NO;
    self.installStatus.hidden = NO;
    self.installStatus.stringValue = L(@"Starting…");
    self.installBar.indeterminate = YES;
    [self.installBar startAnimation:nil];
    [self updateEngineUI];
    if (m.state == OVSeparatorNeedsEngine) {
        __weak typeof(self) w = self;
        [OVRuntime.shared installOptionalPackages:@[OVSeparatorOnnxSpec] title:L(@"Installing the music-removal engine")
                                         progress:^(double f, NSString *line) {
            typeof(self) s = w;
            if (!s) return;
            if (f >= 0) { s.installBar.indeterminate = NO; s.installBar.doubleValue = f; }
            if (line.length) s.installStatus.stringValue = line;
        } done:^(NSString *error) {
            typeof(self) s = w;
            if (!s) return;
            if (error) { [s finishInstall:error]; return; }
            [s installModelAfterEngine];
        }];
    } else {
        [self installModelAfterEngine];
    }
}

/// The model download needs the engine check refreshed first (the worker sees the new package), then runs sep_install_model.
- (void)installModelAfterEngine {
    __weak typeof(self) w = self;
    [OVWorker.shared request:[OVSeparatorModel statusRequestWithDirectory:[OVPaths separationModels]] status:nil progress:nil
                        done:^(NSDictionary *data, NSString *error) {
        typeof(self) s = w;
        if (!s) return;
        if (data) [s.model applyStatus:data];
        if (s.model.modelReady) { [s finishInstall:nil]; return; }
        s.installBar.indeterminate = NO;
        s.installBar.doubleValue = 0;
        [OVWorker.shared request:[OVSeparatorModel installModelRequestWithDirectory:[OVPaths separationModels]]
                          status:^(NSString *msg) { s.installStatus.stringValue = msg; }
                        progress:^(double v) { s.installBar.doubleValue = v; }
                            done:^(NSDictionary *d2, NSString *e2) { [s finishInstall:e2]; }];
    }];
}

- (void)finishInstall:(NSString *)error {
    self.installing = NO;
    [self.installBar stopAnimation:nil];
    self.installBar.hidden = YES;
    self.installStatus.stringValue = error ?: @"";
    self.installStatus.hidden = error == nil;
    [self refreshStatus];
    [self updateEngineUI];
}

- (void)openLicense:(id)sender {
    NSURL *u = [NSURL URLWithString:self.model.licenseURL ?: @""];
    if ([u.scheme.lowercaseString isEqualToString:@"https"]) [NSWorkspace.sharedWorkspace openURL:u];
}

#pragma mark - Input

- (void)loadInput:(NSString *)path {
    if (self.job.active) return;
    self.sourcePath = path;
    self.decoding = YES;
    self.decodedPath = nil;
    self.fileLabel.stringValue = [NSString stringWithFormat:L(@"Reading %@…"), path.lastPathComponent];
    self.inputBar.hidden = YES;
    [self clearResults];
    [self updateRunUI];
    NSString *dst = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"clonenspeak-sep-in-%@.wav", NSUUID.UUID.UUIDString]];
    __weak typeof(self) w = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        double seconds = 0;
        OVDecodeOptions o = {0, NO, kMaxSeconds};
        BOOL ok = OVDecodeAudio(path, dst, o, &seconds, &err);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = w;
            if (!s || ![s.sourcePath isEqualToString:path]) { if (ok) [NSFileManager.defaultManager removeItemAtPath:dst error:nil]; return; }
            s.decoding = NO;
            if (!ok) {
                s.fileLabel.stringValue = err.localizedDescription ?: L(@"This file could not be read.");
                [s updateRunUI];
                return;
            }
            if (s.decodedPath) [NSFileManager.defaultManager removeItemAtPath:s.decodedPath error:nil];
            s.decodedPath = dst;
            s.fileLabel.stringValue = [NSString stringWithFormat:@"%@ · %@", path.lastPathComponent, OVFormatDuration(seconds)];
            s.inputBar.path = dst;
            s.inputBar.hidden = NO;
            [s updateRunUI];
        });
    });
}

#pragma mark - Run

- (void)run:(id)sender {
    if (!self.decodedPath || self.job.active) return;
    [NSUserDefaults.standardUserDefaults setBool:self.voiceCheck.state == NSControlStateValueOn forKey:@"OVSeparatorVoice"];
    [NSUserDefaults.standardUserDefaults setBool:self.musicCheck.state == NSControlStateValueOn forKey:@"OVSeparatorMusic"];
    [self clearResults];
    [self.pendingStems removeAllObjects];
    if (self.voiceCheck.state == NSControlStateValueOn) [self.pendingStems addObject:@"vocals"];
    if (self.musicCheck.state == NSControlStateValueOn) [self.pendingStems addObject:@"music"];
    if (!self.pendingStems.count) return;
    self.stopping = NO;
    self.runStatus.stringValue = @"";
    [self startNextStem];
}

- (NSString *)outputPathForStem:(NSString *)stem {
    NSString *base = [self.sourcePath.lastPathComponent stringByDeletingPathExtension];
    NSString *suffix = [stem isEqualToString:@"vocals"] ? L(@"voice") : L(@"music");
    [NSFileManager.defaultManager createDirectoryAtPath:[OVPaths outputs] withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *p = [[OVPaths outputs] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ (%@).wav", base, suffix]];
    for (int i = 2; [NSFileManager.defaultManager fileExistsAtPath:p]; i++)
        p = [[OVPaths outputs] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ (%@) %d.wav", base, suffix, i]];
    return p;
}

- (void)startNextStem {
    NSString *stem = self.pendingStems.firstObject;
    if (!stem) { [self runDone]; return; }
    [self.pendingStems removeObjectAtIndex:0];
    NSMutableDictionary *req = [[OVSeparatorModel vocalsRequestWithAudio:self.decodedPath out:[self outputPathForStem:stem]
                                                                    stem:stem directory:[OVPaths separationModels]] mutableCopy];
    req[@"_name"] = self.sourcePath.lastPathComponent;
    NSString *error = nil;
    __weak typeof(self) w = self;
    self.job = [OVJobs.shared submitKind:OVJobKindSeparate request:req origin:@"app" onFinish:^(OVJob *job) {
        [w stemFinished:job stem:stem];
    } error:&error];
    if (!self.job) {
        [self.pendingStems removeAllObjects];
        self.runStatus.stringValue = error ?: L(@"The task could not be started.");
        [self runDone];
        return;
    }
    self.runBar.indeterminate = YES;
    [self.runBar startAnimation:nil];
    self.runStatus.stringValue = L(@"Starting…");
    [self updateRunUI];
}

- (void)jobsChanged:(NSNotification *)n {
    OVJob *job = self.job;
    if (!job || !job.active) return;
    if (job.progress >= 0) { self.runBar.indeterminate = NO; self.runBar.doubleValue = job.progress; }
    else if (!self.runBar.indeterminate) { self.runBar.indeterminate = YES; [self.runBar startAnimation:nil]; }
    self.runStatus.stringValue = job.status ?: @"";   // includes "Freeing memory…" when the voice engine is unloaded
    self.runStatus.hidden = NO;
}

- (void)stemFinished:(OVJob *)job stem:(NSString *)stem {
    if (job.state == OVJobSucceeded && job.outputs.firstObject) {
        self.results[stem] = job.outputs.firstObject;
        [self startNextStem];
        return;
    }
    [self.pendingStems removeAllObjects];
    if (job.state == OVJobStopped || self.stopping) {
        self.runStatus.stringValue = L(@"Stopped.");
    } else {
        NSString *e = job.error ?: L(@"Removing the music failed.");
        if ([OVSeparatorModel isEngineMissingMessage:e]) {
            self.runStatus.stringValue = L(@"The engine or the model is not installed. Use \"Download engine\" above.");
            [self refreshStatus];
        } else {
            self.runStatus.stringValue = e;
        }
    }
    [self runDone];
}

- (void)runDone {
    [self.runBar stopAnimation:nil];
    self.job = nil;
    if (self.results.count) {
        [self showResults];
        self.runStatus.stringValue = @"";
    }
    [self updateRunUI];
}

- (void)stop:(id)sender {
    self.stopping = YES;
    [self.pendingStems removeAllObjects];
    if (self.job.active) [OVJobs.shared stop:self.job];
}

#pragma mark - Result

- (void)clearResults {
    [self.resultBar stopIfPlayingThis];
    [self.results removeAllObjects];
    self.resultCard.hidden = YES;
}

- (void)showResults {
    self.resultCard.hidden = NO;
    BOOL both = self.results[@"vocals"] && self.results[@"music"];
    self.resultPicker.hidden = !both;
    self.resultPicker.selectedIndex = self.results[@"vocals"] ? 0 : 1;
    self.resultNote.hidden = YES;
    [self applyResultSelection];
}

- (NSString *)selectedStem {
    if (self.results.count == 1) return self.results.allKeys.firstObject;
    return self.resultPicker.selectedIndex == 0 ? @"vocals" : @"music";
}

- (void)pickResult:(id)sender { [self applyResultSelection]; }

- (void)applyResultSelection {
    NSString *file = self.results[[self selectedStem]];
    self.resultBar.originalPath = self.decodedPath;
    self.resultBar.path = file;
    [self.resultBar selectOriginal:NO];
    [self.resultBar refresh];
}

- (void)save:(id)sender {
    NSString *src = self.results[[self selectedStem]];
    if (!src) return;
    NSSavePanel *p = [NSSavePanel savePanel];
    p.allowedContentTypes = @[UTTypeWAV, UTTypeMPEG4Audio];
    p.nameFieldStringValue = src.lastPathComponent;
    __weak typeof(self) w = self;
    [p beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK || !p.URL) return;
        NSString *dst = p.URL.path;
        NSString *ext = dst.pathExtension.lowercaseString;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *err = nil;
            NSString *out = [OVExport exportFile:src to:dst format:[OVExport formatForIdentifier:ext] quality:-1 error:&err];
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) s = w;
                if (!out) { s.resultNote.stringValue = err.localizedDescription ?: L(@"The file could not be saved."); s.resultNote.hidden = NO; return; }
                [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:out]]];
            });
        });
    }];
}

- (void)useInTools:(id)sender {
    NSString *file = self.results[[self selectedStem]];
    if (!file) return;
    sPendingToolsInput = [file copy];
    [NSNotificationCenter.defaultCenter postNotificationName:OVSeparatorUseInToolsNotification object:nil userInfo:@{@"path": file}];
    OVNavigate(@"tools");
}

- (void)learnMore:(id)sender { OVNavigate(@"models"); }

@end
