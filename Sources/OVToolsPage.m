// Audio Tools page (task 6.16): analyzer, effects chain, formant / pitch shift, DeepFilterNet cleanup and format conversion
// for any audio or video file. Processing runs as OVJobs kind "tool"; the logic lives in OVToolsModel.
#import "OVPages.h"
#import "OVDesign.h"
#import "OVUI.h"
#import "OVLocale.h"
#import "OVPlayerBar.h"
#import "OVWaveformView.h"
#import "OVAnalyzerView.h"
#import "OVEffectsView.h"
#import "OVPresets.h"
#import "OVAudioIO.h"
#import "OVExport.h"
#import "OVJobs.h"
#import "OVWorker.h"
#import "OVPaths.h"
#import "OVToolsModel.h"
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kToolJobKind = @"tool";   // registered in +[OVJobs registerBuiltinKinds]
static NSString *const kKeyRatio = @"OVToolsFormantRatio", *const kKeySemis = @"OVToolsSemitones", *const kKeyKeep = @"OVToolsKeepVoice",
                       *const kKeyDFN = @"OVToolsDFNStrength", *const kKeyLight = @"OVToolsLightCleanup",
                       *const kKeyPitch = @"OVToolsShowPitch", *const kKeyCentroid = @"OVToolsShowCentroid",
                       *const kKeyFormat = @"OVToolsConvertFormat";

@interface OVToolsPage ()
// input
@property (nonatomic, copy) NSString *sourcePath;     // what the user picked
@property (nonatomic, copy) NSString *inputPath;      // a WAV the worker may read (the pick itself, or its decoded copy)
@property (nonatomic, copy) NSString *handedOffPath;  // the last file taken over from the Separation page
@property (nonatomic) NSTimeInterval inputSeconds;
@property (nonatomic) NSUInteger loadToken;
@property (nonatomic) BOOL decoding, analyzing;
@property (nonatomic) NSDictionary *analysis;
@property (nonatomic) NSTextField *summaryLabel, *warningLabel, *analyzeStatus;
@property (nonatomic) OVPlayerBar *inputBar, *resultBar;
@property (nonatomic) OVWaveformView *waveform;
@property (nonatomic) OVAnalyzerView *analyzer;
@property (nonatomic) NSButton *analyzeButton, *pitchCheck, *centroidCheck;
@property (nonatomic) NSView *analyzerCard, *processCard, *resultCard;
// process
@property (nonatomic) OVSegmented *modePicker;
@property (nonatomic) NSArray<NSView *> *panes;
@property (nonatomic) OVEffectsView *effects;
@property (nonatomic) OVPopup *presetPopup, *formatPopup, *qualityPopup;
@property (nonatomic) OVSliderRow *ratioRow, *semisRow, *dfnRow;
@property (nonatomic) NSButton *keepCheck, *lightCheck, *dfnDownload, *applyButton, *stopButton;
@property (nonatomic) NSView *qualityBlock, *dfnBox;
@property (nonatomic) NSTextField *dfnStatus, *presetNote, *formatNote, *processStatus, *cleanupHint;
@property (nonatomic) NSProgressIndicator *processBar, *dfnBar;
@property (nonatomic) NSArray<NSDictionary *> *formats;
@property (nonatomic) BOOL dfnInstalled, dfnKnown, dfnInstalling, converting;
// run
@property (nonatomic) OVJob *job;
@property (nonatomic) NSMutableArray<NSDictionary *> *pendingSteps;
@property (nonatomic) NSMutableArray<NSString *> *scratch;   // intermediate files of the run
@property (nonatomic, copy) NSString *runOutput, *runFolder, *runSuffix;
@property (nonatomic) BOOL stopping;
// result
@property (nonatomic, copy) NSString *resultPath, *masterPath, *savedPath, *resultFormatId;
@property (nonatomic) NSInteger resultQuality;
@property (nonatomic) NSTextField *resultNote;
@property (nonatomic) NSTimer *playheadTimer;
@end

@implementation OVToolsPage

#pragma mark - Folders

+ (NSString *)workFolder {
    NSString *d = [NSTemporaryDirectory() stringByAppendingPathComponent:@"clonenspeak-tools"];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

/// Files of earlier sessions older than a day are removed.
+ (void)sweepWorkFolder {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *d = [self workFolder];
    for (NSString *n in [fm contentsOfDirectoryAtPath:d error:nil]) {
        NSString *p = [d stringByAppendingPathComponent:n];
        NSDate *m = [fm attributesOfItemAtPath:p error:nil][NSFileModificationDate];
        if (m && -[m timeIntervalSinceNow] > 24 * 3600) [fm removeItemAtPath:p error:nil];
    }
}

+ (NSString *)newSubfolder:(NSString *)prefix {
    NSString *d = [[self workFolder] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@", prefix, NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

#pragma mark - View

- (void)loadView {
    [OVToolsPage sweepWorkFolder];
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud registerDefaults:@{kKeyRatio: @1.0, kKeySemis: @0.0, kKeyKeep: @YES, kKeyDFN: @(OVToolsDFNDefaultDB), kKeyLight: @NO,
                           kKeyPitch: @YES, kKeyCentroid: @NO, kKeyFormat: @"wav"}];
    self.pendingSteps = [NSMutableArray array];
    self.scratch = [NSMutableArray array];
    self.resultQuality = -1;
    __weak typeof(self) w = self;

    // 1 Input
    OVDropZone *zone = [OVDropZone zoneWithTitle:L(@"Drop a recording or a video here") hint:L(@"or click to choose a file; up to 20 minutes")
                                           types:@[@"wav", @"mp3", @"m4a", @"aac", @"flac", @"aiff", @"caf", @"ogg", @"mp4", @"mov", @"m4v"]
                                         onFiles:^(NSArray<NSURL *> *urls) { if (urls.firstObject) [w loadInput:urls.firstObject.path]; }];
    NSButton *choose = OVGhostButton(L(@"Choose file…"), @"folder", self, @selector(chooseFile:));
    NSButton *fromVideo = OVGhostButton(L(@"Import audio from video…"), @"film", self, @selector(importFromVideo:));
    OVFlowRow *buttons = [OVFlowRow new];
    [buttons setItems:@[choose, fromVideo]];
    self.summaryLabel = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.warningLabel = OVWrapLabel(@"", 13, OVColor(OVRoleWarn));
    self.warningLabel.hidden = YES;
    self.waveform = [OVWaveformView new];
    self.waveform.accessibilityLabel = L(@"Waveform of the input");
    self.waveform.hidden = YES;
    self.waveform.onSeek = ^(NSTimeInterval t) { [w seekInput:t]; };
    self.inputBar = [OVPlayerBar new];
    self.inputBar.hidden = YES;
    NSView *c1 = OVFillStack(@[zone, buttons, self.summaryLabel, self.warningLabel, self.inputBar, self.waveform], 12);

    // 2 Analyzer
    self.analyzer = [OVAnalyzerView new];
    self.analyzer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.analyzer.heightAnchor constraintEqualToConstant:200].active = YES;
    self.analyzer.accessibilityLabel = L(@"Spectrogram of the input");
    self.analyzer.accessibilityRole = NSAccessibilitySliderRole;   // VoiceOver can adjust the playhead (increment / decrement)
    self.analyzer.onSeek = ^(NSTimeInterval t) { [w seekInput:t]; };
    self.analyzer.showsPitch = [ud boolForKey:kKeyPitch];
    self.analyzer.showsCentroid = [ud boolForKey:kKeyCentroid];
    self.pitchCheck = OVCheckbox(L(@"Pitch"), kKeyPitch);
    self.pitchCheck.target = self;
    self.pitchCheck.action = @selector(curvesChanged:);
    self.centroidCheck = OVCheckbox(L(@"Centroid"), kKeyCentroid);
    self.centroidCheck.target = self;
    self.centroidCheck.action = @selector(curvesChanged:);
    self.analyzeButton = OVGhostButton(L(@"Analyze"), @"waveform.path.ecg", self, @selector(analyze:));
    self.analyzeStatus = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.analyzeStatus.hidden = YES;
    NSView *c2 = OVFillStack(@[self.analyzer, OVHStack(@[self.pitchCheck, self.centroidCheck, OVSpacer(), self.analyzeButton], 18), self.analyzeStatus], 12);
    self.analyzerCard = OVStepCard(2, @"chart.xyaxis.line", L(@"Analyzer"), L(@"Spectrogram with the pitch and brightness curves."), c2);

    // 3 Process
    self.modePicker = [OVSegmented segmentedWithItems:@[@[L(@"Effects"), @""], @[L(@"Formant & pitch"), @""], @[L(@"Clean up"), @""], @[L(@"Convert"), @""]]];
    self.modePicker.target = self;
    self.modePicker.action = @selector(modeChanged:);
    self.modePicker.selectedIndex = 0;
    self.panes = @[[self buildEffectsPane], [self buildFormantPane], [self buildCleanupPane], [self buildConvertPane]];
    self.applyButton = OVPrimaryButton(L(@"Apply"), self, @selector(apply:));
    self.stopButton = OVGhostButton(L(@"Stop"), nil, self, @selector(stop:));
    self.stopButton.hidden = YES;
    self.processBar = OVProgressBar();
    self.processBar.hidden = YES;
    self.processStatus = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.processStatus.hidden = YES;
    NSView *c3 = OVFillStack(@[self.modePicker, OVFillStack(self.panes, 0), OVHStack(@[self.applyButton, self.stopButton, OVSpacer()], 8),
                               self.processBar, self.processStatus], 14);
    self.processCard = OVStepCard(3, @"slider.horizontal.3", L(@"Process"), nil, c3);

    // 4 Result
    self.resultBar = [OVPlayerBar new];
    self.resultNote = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    NSButton *save = OVGhostButton(L(@"Save as…"), @"square.and.arrow.down", self, @selector(save:));
    NSButton *reveal = OVGhostButton(L(@"Reveal in Finder"), @"folder", self, @selector(reveal:));
    NSButton *reuse = OVGhostButton(L(@"Use as input"), @"arrow.uturn.left", self, @selector(useAsInput:));
    OVFlowRow *resultButtons = [OVFlowRow new];
    [resultButtons setItems:@[save, reveal, reuse]];
    self.resultCard = OVStepCard(4, @"waveform", L(@"Result"), nil, OVFillStack(@[self.resultNote, self.resultBar, resultButtons], 12));

    self.view = OVPageScroll(@[OVPageHeader(L(@"Audio Tools"), L(@"Analyze, fix and convert any recording or the sound of a video."), nil),
                               OVStepCard(1, @"waveform.badge.plus", L(@"Input"), nil, c1), self.analyzerCard, self.processCard, self.resultCard]);

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(jobsChanged:) name:OVJobsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(presetsChanged:) name:OVPresetsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(handOff:) name:OVSeparatorUseInToolsNotification object:nil];
    [self modeChanged:nil];
    [self updateFormatPopup];
    [self presetsChanged:nil];
    [self updateVisibility];
    [self updateButtons];
}

- (void)dealloc {
    [self.playheadTimer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

- (NSView *)buildEffectsPane {
    self.presetPopup = [OVPopup popup];
    self.presetPopup.target = self;
    self.presetPopup.action = @selector(presetPicked:);
    self.presetPopup.accessibilityLabel = L(@"Preset");
    NSButton *save = OVGhostButton(L(@"Save as preset…"), nil, self, @selector(savePreset:));
    NSButton *imp = OVGhostButton(L(@"Import…"), nil, self, @selector(importPreset:));
    NSButton *exp = OVGhostButton(L(@"Export…"), nil, self, @selector(exportPreset:));
    OVFlowRow *row = [OVFlowRow new];
    [row setItems:@[save, imp, exp]];
    self.presetNote = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.presetNote.hidden = YES;
    self.effects = [OVEffectsView new];
    return OVFillStack(@[OVFieldBlock(L(@"Preset"), nil, OVFillPopup(self.presetPopup)), row, self.presetNote, self.effects], 12);
}

- (NSView *)buildFormantPane {
    self.ratioRow = [OVSliderRow rowWithTitle:L(@"Formant ratio") hint:L(@"Below 1 makes the voice deeper and larger, above 1 lighter and smaller. The pitch stays.")
                                          key:kKeyRatio min:0.5 max:2.0 format:@"%.2f" integer:NO];
    self.ratioRow.step = 0.01;
    self.ratioRow.valueFormatter = ^NSString *(double v) {
        return [NSString stringWithFormat:L(@"%.2f (%+.1f semitones)"), v, [OVToolsModel semitonesForRatio:v]];
    };
    [self.ratioRow refresh];
    self.semisRow = [OVSliderRow rowWithTitle:L(@"Pitch") hint:L(@"Shifts the pitch up or down in semitones; 12 is one octave.")
                                          key:kKeySemis min:-12 max:12 format:@"%+.1f" integer:NO];
    self.semisRow.step = 0.5;
    self.semisRow.valueFormatter = ^NSString *(double v) { return [NSString stringWithFormat:L(@"%+.1f semitones"), v]; };
    [self.semisRow refresh];
    self.keepCheck = OVCheckbox(L(@"Keep voice character"), kKeyKeep);
    return OVFillStack(@[self.ratioRow, self.semisRow, OVCheckRow(self.keepCheck, L(@"When the pitch moves, the formants stay where they were, so the voice does not turn into a chipmunk."))], 16);
}

- (NSView *)buildCleanupPane {
    self.dfnRow = [OVSliderRow rowWithTitle:L(@"Noise reduction") hint:L(@"The most DeepFilterNet may cut the noise by. Higher removes more and can dull the voice.")
                                        key:kKeyDFN min:OVToolsDFNMinDB max:OVToolsDFNMaxDB format:@"%.0f dB" integer:YES];
    self.dfnStatus = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.dfnDownload = OVPrimaryButton(L(@"Download DeepFilterNet (27 MB)"), self, @selector(downloadDFN:));
    self.dfnBar = OVProgressBar();
    self.dfnBar.hidden = YES;
    self.dfnBox = OVFillStack(@[self.dfnRow, self.dfnStatus, OVHStack(@[self.dfnDownload, OVSpacer()], 8), self.dfnBar], 10);
    self.lightCheck = OVCheckbox(L(@"Light cleanup instead"), kKeyLight);
    self.lightCheck.target = self;
    self.lightCheck.action = @selector(lightChanged:);
    return OVFillStack(@[self.dfnBox, OVCheckRow(self.lightCheck, L(@"A simple noise gate that needs nothing to download. It also trims long pauses and evens out the loudness."))], 16);
}

- (NSView *)buildConvertPane {
    self.formatPopup = [OVPopup popup];
    self.formatPopup.autoenablesItems = NO;
    self.formatPopup.target = self;
    self.formatPopup.action = @selector(formatPicked:);
    self.formatPopup.accessibilityLabel = L(@"Format");
    self.qualityPopup = [OVPopup popup];
    self.qualityPopup.accessibilityLabel = L(@"Quality");
    self.formatNote = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.formatNote.hidden = YES;
    self.qualityBlock = OVFieldBlock(L(@"Quality"), nil, OVFillPopup(self.qualityPopup));
    return OVFillStack(@[OVFieldBlock(L(@"Format"), L(@"Converts the input file. To convert a result, press \"Use as input\" first."), OVFillPopup(self.formatPopup)),
                         self.formatNote, self.qualityBlock], 12);
}

#pragma mark - Appearing

- (void)viewWillAppear {
    [super viewWillAppear];
    [OVExport resetFFmpegCache];
    [self loadFormats];
    [self refreshDFN];
    NSString *pending = [OVSeparatorPage pendingToolsInputPath];
    if (pending.length && ![pending isEqualToString:self.handedOffPath] && [NSFileManager.defaultManager fileExistsAtPath:pending]) {
        self.handedOffPath = pending;
        [self loadInput:pending];
    }
    // Developer aid for snapshots: OV_TOOLS_INPUT=/path/to/file.wav loads that file as the input.
    NSString *dev = NSProcessInfo.processInfo.environment[@"OV_TOOLS_INPUT"];
    if (dev.length && !self.sourcePath) [self loadInput:dev];
    [self.playheadTimer invalidate];
    self.playheadTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(tickPlayhead:) userInfo:nil repeats:YES];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    [self.playheadTimer invalidate];
    self.playheadTimer = nil;
}

- (void)handOff:(NSNotification *)n {
    NSString *p = n.userInfo[@"path"];
    if (![p isKindOfClass:NSString.class] || !p.length || [p isEqualToString:self.handedOffPath]) return;
    self.handedOffPath = p;
    [self loadInput:p];
}

- (void)tickPlayhead:(NSTimer *)t {
    OVPlayer *pl = OVPlayer.shared;
    BOOL mine = self.inputPath && [pl.currentPath isEqualToString:self.inputPath];
    if (!mine || !pl.playing) return;
    self.waveform.position = pl.currentTime;
    self.analyzer.position = pl.currentTime;
}

- (void)seekInput:(NSTimeInterval)t {
    if (!self.inputPath) return;
    OVPlayer *pl = OVPlayer.shared;
    if (![pl.currentPath isEqualToString:self.inputPath]) [pl play:self.inputPath];
    [pl seek:t];
    self.waveform.position = t;
    self.analyzer.position = t;
}

#pragma mark - Visibility and buttons

- (void)updateVisibility {
    BOOL has = self.inputPath.length > 0;
    self.analyzerCard.hidden = !has;
    self.processCard.hidden = !has;
    self.resultCard.hidden = self.resultPath.length == 0;
    self.waveform.hidden = !has;
    self.inputBar.hidden = !has;
    self.summaryLabel.hidden = self.summaryLabel.stringValue.length == 0;
    self.warningLabel.hidden = self.warningLabel.stringValue.length == 0;
}

- (BOOL)busy { return self.job.active || self.pendingSteps.count > 0 || self.decoding || self.converting || self.dfnInstalling; }

- (void)updateButtons {
    BOOL running = self.job.active || self.pendingSteps.count > 0;
    self.applyButton.enabled = self.inputPath.length > 0 && ![self busy];
    self.stopButton.hidden = !(running || self.converting);
    self.stopButton.enabled = running;
    self.processBar.hidden = !(running || self.converting);
    self.analyzeButton.enabled = self.inputPath.length > 0 && !self.analyzing && !self.decoding;
    BOOL light = self.lightCheck.state == NSControlStateValueOn;
    self.dfnBox.alphaValue = light ? 0.45 : 1;
    self.dfnRow.enabled = !light;
    self.dfnDownload.hidden = self.dfnInstalled || !self.dfnKnown;
    self.dfnDownload.enabled = !self.dfnInstalling && !light;
    self.dfnStatus.hidden = !self.dfnKnown && !self.dfnInstalling;
}

- (void)modeChanged:(id)sender {
    NSInteger m = MAX(0, self.modePicker.selectedIndex);
    for (NSUInteger i = 0; i < self.panes.count; i++) self.panes[i].hidden = (NSInteger)i != m;
    self.applyButton.title = m == OVToolsModeConvert ? L(@"Convert") : L(@"Apply");
    self.processStatus.stringValue = @"";
    self.processStatus.hidden = YES;
}

#pragma mark - Input

- (void)chooseFile:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.allowsMultipleSelection = NO;
    NSMutableArray *types = [NSMutableArray array];
    for (NSString *e in @[@"wav", @"mp3", @"m4a", @"aac", @"flac", @"aiff", @"caf", @"ogg", @"mp4", @"mov", @"m4v"]) {
        UTType *t = [UTType typeWithFilenameExtension:e];
        if (t) [types addObject:t];
    }
    p.allowedContentTypes = types;
    __weak typeof(self) w = self;
    [p beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse r) {
        if (r == NSModalResponseOK && p.URL) [w loadInput:p.URL.path];
    }];
}

- (void)importFromVideo:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.allowsMultipleSelection = NO;
    p.message = L(@"Choose a video: its sound becomes the input.");
    NSMutableArray *types = [NSMutableArray array];
    for (NSString *e in OVVideoExtensions()) {
        UTType *t = [UTType typeWithFilenameExtension:e];
        if (t) [types addObject:t];
    }
    p.allowedContentTypes = types;
    __weak typeof(self) w = self;
    [p beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse r) {
        if (r == NSModalResponseOK && p.URL) [w loadInput:p.URL.path];
    }];
}

- (void)clearResult {
    [self.resultBar stopIfPlayingThis];
    self.resultPath = nil;
    self.masterPath = nil;
    self.savedPath = nil;
    self.resultBar.path = nil;
}

- (void)loadInput:(NSString *)path {
    if (self.job.active || self.pendingSteps.count || self.converting) return;
    NSUInteger token = ++self.loadToken;
    [self.inputBar stopIfPlayingThis];
    [self clearResult];
    self.sourcePath = path;
    self.inputPath = nil;
    self.analysis = nil;
    self.decoding = YES;
    self.warningLabel.stringValue = @"";
    self.summaryLabel.stringValue = [NSString stringWithFormat:L(@"Reading %@…"), path.lastPathComponent];
    self.processStatus.hidden = YES;
    [self updateVisibility];
    [self updateButtons];
    NSString *dir = [OVToolsPage newSubfolder:@"in"];
    __weak typeof(self) w = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // the length is known before anything is decoded: a long file is a warning, not a half-gigabyte WAV
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
        double len = CMTimeGetSeconds(asset.duration);
        if (!isfinite(len)) len = 0;
        NSString *warning = [OVToolsModel longFileWarningForSeconds:len];
        NSString *wav = nil;
        NSError *err = nil;
        double seconds = len;
        if (!warning) {
            __block double decoded = 0;
            wav = [OVToolsModel workerInputForPath:path workDir:dir decoder:^BOOL(NSString *src, NSString *dst, NSError **e) {
                OVDecodeOptions o = {0, NO, 0};
                return OVDecodeAudio(src, dst, o, &decoded, e);
            } error:&err];
            if (decoded > 0) seconds = decoded;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = w;
            if (!s || s.loadToken != token) return;
            s.decoding = NO;
            if (warning) {
                s.summaryLabel.stringValue = [NSString stringWithFormat:@"%@ · %@", path.lastPathComponent, OVFormatDuration(len)];
                s.warningLabel.stringValue = L(warning);
            } else if (!wav) {
                s.summaryLabel.stringValue = err.localizedDescription ?: L(@"This file could not be read.");
            } else {
                s.inputPath = wav;
                s.inputSeconds = seconds;
                s.summaryLabel.stringValue = [NSString stringWithFormat:@"%@ · %@", path.lastPathComponent, OVFormatDuration(seconds)];
                s.inputBar.path = wav;
                s.waveform.peaks = @[];
                s.waveform.duration = seconds;
                s.waveform.position = 0;
                s.analyzer.position = 0;
                s.resultBar.originalPath = wav;
            }
            [s updateVisibility];
            [s updateButtons];
            if (wav) [s analyze:nil];
        });
    });
}

#pragma mark - Analyzer

- (void)curvesChanged:(id)sender {
    self.analyzer.showsPitch = self.pitchCheck.state == NSControlStateValueOn;
    self.analyzer.showsCentroid = self.centroidCheck.state == NSControlStateValueOn;
}

- (void)analyze:(id)sender {
    NSString *audio = self.inputPath;
    if (!audio || self.analyzing) return;
    if (OVWorker.shared.busy) {   // a task holds the engine: try again in a moment
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(analyze:) object:nil];
        [self performSelector:@selector(analyze:) withObject:nil afterDelay:1.5];
        self.analyzeStatus.stringValue = L(@"Waiting for the engine…");
        self.analyzeStatus.hidden = NO;
        return;
    }
    self.analyzing = YES;
    self.analyzeStatus.stringValue = L(@"Analyzing…");
    self.analyzeStatus.hidden = NO;
    [self updateButtons];
    NSString *outDir = [OVToolsPage newSubfolder:@"analysis"];
    __weak typeof(self) w = self;
    [OVWorker.shared request:@{@"cmd": @"analyze_audio", @"audio": audio, @"out_dir": outDir} status:nil progress:nil
                        done:^(NSDictionary *data, NSString *error) {
        typeof(self) s = w;
        if (!s) return;
        s.analyzing = NO;
        if (![s.inputPath isEqualToString:audio]) { [s updateButtons]; return; }   // another file was picked meanwhile
        if (!data) {
            s.analyzeStatus.stringValue = error ?: L(@"The analysis failed.");
            [s updateButtons];
            return;
        }
        s.analysis = data;
        NSError *verr = nil;
        if (![s.analyzer loadResult:data error:&verr]) { s.analyzeStatus.stringValue = verr.localizedDescription ?: L(@"The analysis failed."); }
        else s.analyzeStatus.hidden = YES;
        NSArray *peaks = [data[@"waveform"] isKindOfClass:NSDictionary.class] ? data[@"waveform"][@"peaks"] : nil;
        if ([peaks isKindOfClass:NSArray.class]) s.waveform.peaks = peaks;
        double secs = [data[@"seconds"] doubleValue];
        if (secs > 0) s.waveform.duration = secs;
        int sr = [data[@"sr"] intValue], ch = [data[@"channels"] intValue];
        if (sr > 0 && ch > 0) {
            s.summaryLabel.stringValue = [NSString stringWithFormat:@"%@ · %@ · %.1f kHz · %@", s.sourcePath.lastPathComponent,
                                          OVFormatDuration(secs > 0 ? secs : s.inputSeconds), sr / 1000.0, ch == 1 ? L(@"mono") : (ch == 2 ? L(@"stereo") : [NSString stringWithFormat:L(@"%d channels"), ch])];
        }
        [s updateButtons];
    }];
}

#pragma mark - Presets

- (void)presetsChanged:(NSNotification *)n {
    NSString *keep = self.presetPopup.selectedItem.representedObject;
    [self.presetPopup removeAllItems];
    [self.presetPopup addItemWithTitle:L(@"No preset")];
    for (OVPreset *p in OVPresets.shared.all) {
        [self.presetPopup addItemWithTitle:p.name];
        self.presetPopup.lastItem.representedObject = p.identifier;
        if ([p.identifier isEqualToString:keep]) [self.presetPopup selectItem:self.presetPopup.lastItem];
    }
}

- (OVPreset *)selectedPreset {
    NSString *ident = self.presetPopup.selectedItem.representedObject;
    for (OVPreset *p in OVPresets.shared.all) if ([p.identifier isEqualToString:ident]) return p;
    return nil;
}

- (void)presetPicked:(id)sender {
    OVPreset *p = [self selectedPreset];
    self.presetNote.hidden = YES;
    if (!p) return;
    self.effects.chain = p.chain ?: @[];
    if (fabs(p.formant - 1.0) > 1e-6) {
        [NSUserDefaults.standardUserDefaults setDouble:MAX(0.5, MIN(2.0, p.formant)) forKey:kKeyRatio];
        [self.ratioRow refresh];
    }
    if (p.formatId.length) {
        [NSUserDefaults.standardUserDefaults setObject:p.formatId forKey:kKeyFormat];
        [self updateFormatPopup];
    }
}

- (void)showPresetNote:(NSString *)s {
    self.presetNote.stringValue = s ?: @"";
    self.presetNote.hidden = s.length == 0;
}

- (void)savePreset:(id)sender {
    NSAlert *a = [NSAlert new];
    a.messageText = L(@"Save as preset");
    a.informativeText = L(@"The preset keeps the effects and the formant ratio.");
    NSTextField *name = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    name.placeholderString = L(@"Preset name");
    a.accessoryView = name;
    [a addButtonWithTitle:L(@"Save")];
    [a addButtonWithTitle:L(@"Cancel")];
    a.window.initialFirstResponder = name;
    __weak typeof(self) w = self;
    [a beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse r) {
        typeof(self) s = w;
        if (!s || r != NSAlertFirstButtonReturn) return;
        NSString *n = [name.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!n.length) { [s showPresetNote:L(@"Give the preset a name.")]; return; }
        OVPreset *p = [OVPreset new];
        p.name = n;
        p.style = @{};
        p.quality = -1;
        p.chain = s.effects.chain;
        p.formant = [NSUserDefaults.standardUserDefaults doubleForKey:kKeyRatio];
        OVPreset *saved = [OVPresets.shared add:p];
        [s presetsChanged:nil];
        if (saved) [s.presetPopup selectItemAtIndex:[s.presetPopup indexOfItemWithRepresentedObject:saved.identifier]];
        [s showPresetNote:saved ? L(@"Preset saved.") : L(@"The preset could not be saved.")];
    }];
}

- (void)importPreset:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.allowedContentTypes = @[UTTypeJSON];
    p.allowsMultipleSelection = NO;
    __weak typeof(self) w = self;
    [p beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK || !p.URL) return;
        NSData *data = [NSData dataWithContentsOfURL:p.URL];
        if (!data) { [w showPresetNote:L(@"This file could not be read.")]; return; }
        [OVPresets.shared importData:data completion:^(OVPreset *preset, NSArray<NSString *> *warnings, NSString *error) {
            typeof(self) s = w;
            if (!s) return;
            if (!preset) { [s showPresetNote:error ?: L(@"This is not a preset file.")]; return; }
            OVPreset *saved = [OVPresets.shared add:preset];
            [s presetsChanged:nil];
            if (saved) {
                [s.presetPopup selectItemAtIndex:[s.presetPopup indexOfItemWithRepresentedObject:saved.identifier]];
                [s presetPicked:nil];
            }
            [s showPresetNote:warnings.count ? [warnings componentsJoinedByString:@" "] : L(@"Preset imported.")];
        }];
    }];
}

- (void)exportPreset:(id)sender {
    OVPreset *preset = [self selectedPreset];
    if (!preset) { [self showPresetNote:L(@"Choose a preset to export.")]; return; }
    NSSavePanel *p = [NSSavePanel savePanel];
    p.allowedContentTypes = @[UTTypeJSON];
    p.nameFieldStringValue = [preset.name stringByAppendingPathExtension:@"json"];
    __weak typeof(self) w = self;
    [p beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK || !p.URL) return;
        NSError *err = nil;
        BOOL ok = [[OVPresets.shared exportData:preset] writeToURL:p.URL options:NSDataWritingAtomic error:&err];
        [w showPresetNote:ok ? L(@"Preset exported.") : (err.localizedDescription ?: L(@"The file could not be saved."))];
    }];
}

#pragma mark - Formats

- (void)loadFormats {
    __weak typeof(self) w = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *f = [OVExport formats];   // may look for ffmpeg: off the main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            w.formats = f;
            [w updateFormatPopup];
        });
    });
}

- (NSDictionary *)selectedFormat {
    NSInteger i = self.formatPopup.indexOfSelectedItem;
    return (i >= 0 && i < (NSInteger)self.formats.count) ? self.formats[i] : nil;
}

- (void)updateFormatPopup {
    NSString *want = [NSUserDefaults.standardUserDefaults stringForKey:kKeyFormat] ?: @"wav";
    [self.formatPopup removeAllItems];
    NSArray *fs = self.formats.count ? self.formats : @[@{@"id": @"wav", @"title": @"WAV", @"available": @YES}];
    NSInteger sel = 0;
    NSMutableArray *notes = [NSMutableArray array];
    for (NSUInteger i = 0; i < fs.count; i++) {
        NSDictionary *f = fs[i];
        NSString *raw = [OVToolsModel disabledReasonForFormat:f];
        NSString *reason = raw ? L(raw) : nil;
        [self.formatPopup addItemWithTitle:f[@"title"]];
        NSMenuItem *item = self.formatPopup.lastItem;
        item.enabled = reason == nil;   // greyed out
        item.toolTip = reason;
        if (reason && ![notes containsObject:reason]) [notes addObject:reason];
        if (!reason && [f[@"id"] isEqualToString:want]) sel = i;
    }
    [self.formatPopup selectItemAtIndex:sel];
    self.formatNote.stringValue = notes.count ? [NSString stringWithFormat:L(@"Greyed-out formats: %@"), [notes componentsJoinedByString:@" "]] : @"";
    self.formatNote.hidden = notes.count == 0;
    [self updateQualityPopup];
}

- (void)formatPicked:(id)sender {
    NSDictionary *f = [self selectedFormat];
    if (f) [NSUserDefaults.standardUserDefaults setObject:f[@"id"] forKey:kKeyFormat];
    [self updateQualityPopup];
}

- (void)updateQualityPopup {
    NSString *ident = [self selectedFormat][@"id"] ?: @"wav";
    NSArray *choices = [OVToolsModel qualityChoicesForFormatId:ident];
    [self.qualityPopup removeAllItems];
    NSInteger def = [OVToolsModel defaultQualityForFormatId:ident];
    for (NSArray *c in choices) {
        [self.qualityPopup addItemWithTitle:[ident isEqualToString:@"ogg"] ? [NSString stringWithFormat:L(@"Quality %@"), c[0]] : c[0]];
        self.qualityPopup.lastItem.tag = [c[1] integerValue];
        if ([c[1] integerValue] == def) [self.qualityPopup selectItem:self.qualityPopup.lastItem];
    }
    self.qualityBlock.hidden = choices.count == 0;
}

#pragma mark - DeepFilterNet

- (void)refreshDFN {
    if (self.dfnInstalling) return;
    if (OVWorker.shared.busy) { [self performSelector:@selector(refreshDFN) withObject:nil afterDelay:2]; return; }
    __weak typeof(self) w = self;
    [OVWorker.shared request:@{@"cmd": @"dfn_status"} status:nil progress:nil done:^(NSDictionary *data, NSString *error) {
        typeof(self) s = w;
        if (!s) return;
        if (data) {
            s.dfnKnown = YES;
            s.dfnInstalled = [data[@"installed"] boolValue];
            s.dfnStatus.stringValue = s.dfnInstalled ? L(@"DeepFilterNet is installed.") : L(@"DeepFilterNet is not installed. It removes noise from speech and music alike; the download is 27 MB.");
        } else {
            s.dfnKnown = YES;
            s.dfnStatus.stringValue = error ?: @"";
        }
        [s updateButtons];
    }];
}

- (void)downloadDFN:(id)sender {
    if (self.dfnInstalling) return;
    if (OVWorker.shared.busy) { self.processStatus.stringValue = L(@"Waiting for the engine… Try again in a moment."); self.processStatus.hidden = NO; return; }
    self.dfnInstalling = YES;
    self.dfnBar.hidden = NO;
    self.dfnBar.indeterminate = NO;
    self.dfnBar.doubleValue = 0;
    self.dfnStatus.stringValue = L(@"Starting…");
    [self updateButtons];
    __weak typeof(self) w = self;
    [OVWorker.shared request:@{@"cmd": @"dfn_install"}
                      status:^(NSString *msg) { w.dfnStatus.stringValue = msg; }
                    progress:^(double v) { w.dfnBar.doubleValue = v; }
                        done:^(NSDictionary *data, NSString *error) {
        typeof(self) s = w;
        if (!s) return;
        s.dfnInstalling = NO;
        s.dfnBar.hidden = YES;
        if (error) s.dfnStatus.stringValue = error;
        [s updateButtons];
        if (!error) [s refreshDFN];
    }];
}

- (void)lightChanged:(id)sender { [self updateButtons]; }

#pragma mark - Apply

- (NSString *)suffixForMode:(NSInteger)m {
    switch (m) {
        case OVToolsModeEffects: return L(@"effects");
        case OVToolsModeFormant: return L(@"voice");
        case OVToolsModeCleanup: return L(@"clean");
        default: return L(@"converted");
    }
}

- (NSString *)pathInFolder:(NSString *)folder suffix:(NSString *)suffix ext:(NSString *)ext {
    NSString *base = [self.sourcePath.lastPathComponent stringByDeletingPathExtension] ?: @"audio";
    return [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ (%@).%@", base, suffix, ext]];
}

- (void)say:(NSString *)s {
    self.processStatus.stringValue = s ?: @"";
    self.processStatus.hidden = s.length == 0;
}

- (void)apply:(id)sender {
    if (!self.inputPath || [self busy]) return;
    NSInteger mode = MAX(0, self.modePicker.selectedIndex);
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [self say:nil];
    if (mode == OVToolsModeConvert) { [self convertNow]; return; }
    self.runSuffix = [self suffixForMode:mode];
    self.runFolder = [OVToolsPage newSubfolder:@"run"];
    self.runOutput = [self pathInFolder:self.runFolder suffix:self.runSuffix ext:@"wav"];
    NSString *audio = self.inputPath, *out = self.runOutput;
    NSArray *steps = nil;
    if (mode == OVToolsModeEffects) {
        NSArray *chain = self.effects.chain;
        if (![OVToolsModel chainHasActiveEffects:chain]) { [self say:L(@"Turn on at least one effect.")]; return; }
        steps = @[[OVToolsModel effectsRequestWithAudio:audio out:out chain:chain]];
    } else if (mode == OVToolsModeFormant) {
        NSString *tmp = [self.runFolder stringByAppendingPathComponent:@"step.wav"];
        steps = [OVToolsModel formantStepsWithAudio:audio out:out tmp:tmp ratio:[ud doubleForKey:kKeyRatio] semitones:[ud doubleForKey:kKeySemis]
                                      keepCharacter:[ud boolForKey:kKeyKeep]];
        if (!steps.count) { [self say:L(@"Move the formant or pitch slider first.")]; return; }
        [self.scratch addObject:tmp];
    } else if ([ud boolForKey:kKeyLight]) {
        steps = @[[OVToolsModel lightCleanupRequestWithAudio:audio out:out]];
    } else {
        NSDictionary *plan = [OVToolsModel dfnPlanInstalled:self.dfnInstalled audio:audio out:out strengthDB:[ud doubleForKey:kKeyDFN]];
        if ([plan[@"action"] isEqualToString:@"download"]) {
            [self say:L(@"DeepFilterNet has to be downloaded first.")];
            [self downloadDFN:nil];
            return;
        }
        steps = @[plan[@"request"]];
    }
    self.stopping = NO;
    [self clearResult];
    [self updateVisibility];
    [self.pendingSteps setArray:steps];
    [self startNextStep];
}

- (void)startNextStep {
    NSDictionary *step = self.pendingSteps.firstObject;
    if (!step) { [self runFinishedOK]; return; }
    [self.pendingSteps removeObjectAtIndex:0];
    NSMutableDictionary *req = [step mutableCopy];
    req[@"_name"] = self.sourcePath.lastPathComponent ?: @"";
    NSString *error = nil;
    __weak typeof(self) w = self;
    self.job = [OVJobs.shared submitKind:kToolJobKind request:req origin:@"app" onFinish:^(OVJob *job) { [w stepFinished:job]; } error:&error];
    if (!self.job) {
        [self.pendingSteps removeAllObjects];
        [self say:error ?: L(@"The task could not be started.")];
        [self cleanupRun];
        [self updateButtons];
        return;
    }
    self.processBar.indeterminate = YES;
    [self.processBar startAnimation:nil];
    [self say:L(@"Starting…")];
    [self updateButtons];
}

- (void)jobsChanged:(NSNotification *)n {
    OVJob *job = self.job;
    if (!job || !job.active) return;
    if (job.progress >= 0) { self.processBar.indeterminate = NO; self.processBar.doubleValue = job.progress; }
    else if (!self.processBar.indeterminate) { self.processBar.indeterminate = YES; [self.processBar startAnimation:nil]; }
    [self say:job.status];
}

- (void)stepFinished:(OVJob *)job {
    if (job.state == OVJobSucceeded) { [self startNextStep]; return; }
    [self.pendingSteps removeAllObjects];
    if (job.state == OVJobStopped || self.stopping) [self say:L(@"Stopped.")];
    else {
        [self say:job.error ?: L(@"The task failed.")];   // an input error already says what to do
        if ([job.errorCode isEqualToString:@"engine_missing"]) {   // DeepFilterNet vanished since the last check: offer the download again
            self.dfnInstalled = NO; self.dfnKnown = YES;
            [self updateButtons];
        }
    }
    [self cleanupRun];
    self.job = nil;
    [self.processBar stopAnimation:nil];
    [self updateButtons];
}

- (void)runFinishedOK {
    NSString *out = self.runOutput;
    self.job = nil;
    [self.processBar stopAnimation:nil];
    [self cleanupScratch];
    if (![NSFileManager.defaultManager fileExistsAtPath:out]) { [self say:L(@"The task finished without a result.")]; [self updateButtons]; return; }
    self.resultFormatId = @"wav";
    self.resultQuality = -1;
    [self showResultAt:out master:out];
    [self say:nil];
    [self updateButtons];
}

- (void)cleanupScratch {
    for (NSString *p in self.scratch) [NSFileManager.defaultManager removeItemAtPath:p error:nil];
    [self.scratch removeAllObjects];
}

/// A stopped or failed run leaves nothing behind: the intermediate step and the target folder go.
- (void)cleanupRun {
    [self cleanupScratch];
    if (self.runFolder) [NSFileManager.defaultManager removeItemAtPath:self.runFolder error:nil];
    self.runFolder = nil;
}

- (void)stop:(id)sender {
    self.stopping = YES;
    [self.pendingSteps removeAllObjects];
    if (self.job.active) [OVJobs.shared stop:self.job];
}

#pragma mark - Convert (native)

- (void)convertNow {
    NSDictionary *f = [self selectedFormat];
    if (!f || [OVToolsModel disabledReasonForFormat:f]) { [self say:L([OVToolsModel disabledReasonForFormat:f ?: @{@"available": @NO}])]; return; }
    NSString *ident = f[@"id"];
    NSInteger quality = self.qualityPopup.selectedItem ? self.qualityPopup.selectedItem.tag : -1;
    NSString *src = self.inputPath;
    NSString *folder = [OVToolsPage newSubfolder:@"run"];
    NSString *target = [self pathInFolder:folder suffix:[self suffixForMode:OVToolsModeConvert] ext:f[@"ext"]];
    self.converting = YES;
    [self clearResult];
    [self updateVisibility];
    self.processBar.indeterminate = YES;
    [self.processBar startAnimation:nil];
    [self say:L(@"Converting…")];
    [self updateButtons];
    __weak typeof(self) w = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        NSString *out = [OVExport exportFile:src to:target format:[OVToolsPage exportFormatForId:ident] quality:quality error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = w;
            if (!s) return;
            s.converting = NO;
            [s.processBar stopAnimation:nil];
            if (!out) {
                [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
                [s say:err.localizedDescription ?: L(@"The file could not be converted.")];
            } else if (![s.inputPath isEqualToString:src]) {
                [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
            } else {
                s.resultFormatId = ident;
                s.resultQuality = quality;
                [s showResultAt:out master:src];
                [s say:nil];
            }
            [s updateButtons];
        });
    });
}

+ (OVExportFormat)exportFormatForId:(NSString *)ident { return [OVExport formatForIdentifier:ident]; }

#pragma mark - Result

- (void)showResultAt:(NSString *)path master:(NSString *)master {
    self.resultPath = path;
    self.masterPath = master;
    self.savedPath = nil;
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    NSString *size = attrs ? OVFormatBytes([attrs fileSize]) : @"";
    self.resultNote.stringValue = [NSString stringWithFormat:@"%@ · %@", path.lastPathComponent, size];
    self.resultBar.originalPath = self.inputPath;
    self.resultBar.path = path;
    [self.resultBar selectOriginal:NO];
    [self.resultBar refresh];
    [self updateVisibility];
}

- (void)save:(id)sender {
    if (!self.masterPath) return;
    NSMutableArray *types = [NSMutableArray array];
    NSMutableArray *allowedExts = [NSMutableArray array];
    for (NSDictionary *f in (self.formats.count ? self.formats : @[@{@"ext": @"wav", @"available": @YES}])) {
        if ([OVToolsModel disabledReasonForFormat:f]) continue;
        UTType *t = [UTType typeWithFilenameExtension:f[@"ext"]];
        if (t && ![types containsObject:t]) { [types addObject:t]; [allowedExts addObject:f[@"ext"]]; }
    }
    NSSavePanel *p = [NSSavePanel savePanel];
    p.allowedContentTypes = types;
    p.nameFieldStringValue = self.resultPath.lastPathComponent;
    p.message = L(@"The extension of the name sets the format.");
    __weak typeof(self) w = self;
    [p beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse r) {
        typeof(self) s = w;
        if (!s || r != NSModalResponseOK || !p.URL) return;
        NSString *dst = p.URL.path;
        NSString *ext = dst.pathExtension.lowercaseString;
        if (![allowedExts containsObject:ext]) { dst = [dst stringByAppendingPathExtension:@"wav"]; ext = @"wav"; }
        NSString *master = s.masterPath;
        NSString *ident = ext;
        NSInteger quality = -1;
        if ([ext isEqualToString:[s.resultPath.pathExtension lowercaseString]] && s.resultFormatId.length) {   // the converted format keeps its own settings (ALAC vs AAC)
            ident = s.resultFormatId;
            quality = s.resultQuality;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *err = nil;
            [NSFileManager.defaultManager removeItemAtPath:dst error:nil];   // the panel already asked about overwriting
            NSString *out = [OVExport exportFile:master to:dst format:[OVToolsPage exportFormatForId:ident] quality:quality error:&err];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!out) { s.resultNote.stringValue = err.localizedDescription ?: L(@"The file could not be saved."); return; }
                s.savedPath = out;
                s.resultNote.stringValue = [NSString stringWithFormat:L(@"Saved: %@"), out.lastPathComponent];
                [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:out]]];
            });
        });
    }];
}

- (void)reveal:(id)sender {
    NSString *p = self.savedPath ?: self.resultPath;
    if (p) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:p]]];
}

- (void)useAsInput:(id)sender {
    NSString *p = self.resultPath;
    if (p && ![self busy]) [self loadInput:p];
}

@end
