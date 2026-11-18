// Convert page (task 7.8): re-voice a recording with an RVC model or with the user's cloned voice (Seed-VC).
// All work runs through OVProRun / the pro_convert job kind (preflight, sandbox, memory check); nothing is spawned here.
#import "OVPages.h"
#import "OVDesign.h"
#import "OVUI.h"
#import "OVLocale.h"
#import "OVPlayerBar.h"
#import "OVAudioIO.h"
#import "OVJobs.h"
#import "OVEngines.h"
#import "OVProKit.h"
#import "OVPaths.h"
#import "OVStore.h"
#import "OVExport.h"
#import "OVYouTubeSheet.h"
#import "OVRvcStore.h"

static const NSUInteger kMaxBatch = 200;
static const NSTimeInterval kMaxSeconds = 2 * 3600;
static NSString *const kPage = @"convert";
static NSString *sLastJobID;   // the page is rebuilt when the user comes back; the job it started is found again by this id

#pragma mark - Page

static NSUserDefaults *D(void) { return NSUserDefaults.standardUserDefaults; }
static double DD(NSString *key, double def) { return [D() objectForKey:key] ? [D() doubleForKey:key] : def; }
static BOOL DB(NSString *key, BOOL def) { return [D() objectForKey:key] ? [D() boolForKey:key] : def; }

/// Sets `enabled` on every control below `v` (the page body stays off until the engine is ready).
static void SetEnabledDeep(NSView *v, BOOL on, NSArray<NSView *> *skip) {
    if ([skip containsObject:v]) return;
    if ([v isKindOfClass:NSControl.class]) ((NSControl *)v).enabled = on;
    if ([v isKindOfClass:OVSliderRow.class]) ((OVSliderRow *)v).enabled = on;
    for (NSView *s in v.subviews) SetEnabledDeep(s, on, skip);
}

@interface OVConvertPage ()
// source
@property (nonatomic) OVSegmented *modePicker;
@property (nonatomic) NSView *singleBox, *batchBox;
@property (nonatomic) NSTextField *fileLabel, *batchCount, *batchNote;
@property (nonatomic) OVPlayerBar *inputBar;
@property (nonatomic) NSStackView *batchList;
@property (nonatomic, copy) NSString *sourcePath, *previewPath;
@property (nonatomic) NSMutableArray<NSString *> *batchFiles;
@property (nonatomic) BOOL decoding;
// target
@property (nonatomic) OVSegmented *targetPicker;
@property (nonatomic) OVPopup *modelPopup, *voicePopup;
@property (nonatomic) NSTextField *modelHint, *voiceHint;
@property (nonatomic) NSView *rvcBox, *voiceBox;
@property (nonatomic) NSArray<OVRvcModel *> *models;
@property (nonatomic) NSArray<OVVoice *> *voices;
// settings
@property (nonatomic) NSView *rvcSettings, *seedSettings;
@property (nonatomic) OVSliderRow *pitchRow, *indexRow, *protectRow, *volumeRow, *quefRow, *timbreRow, *autotuneRow, *cleanRow, *stepsRow;
@property (nonatomic) OVSegmented *f0Picker;
@property (nonatomic) NSTextField *f0Hint;
@property (nonatomic) OVSwitch *formantSwitch, *autotuneSwitch;
@property (nonatomic) OVPopup *cleanPopup, *embedderPopup, *formatPopup;
@property (nonatomic) NSView *formantBox, *autotuneBox, *cleanBox, *fcpeGate;
// gate + run
@property (nonatomic) NSView *gateRvc, *gateSeed, *body;
@property (nonatomic) BOOL readyRvc, readySeed, starting, built;
@property (nonatomic) NSButton *runButton, *stopButton, *revealButton, *againButton;
@property (nonatomic) NSProgressIndicator *runBar;
@property (nonatomic) NSTextField *runStatus, *memoryNote;
@property (nonatomic) OVJob *job;
@property (nonatomic, copy) NSString *shownJobId;
// result
@property (nonatomic) NSView *resultBox, *singleResult, *batchResult;
@property (nonatomic) OVPlayerBar *resultBar;
@property (nonatomic) NSStackView *resultList;
@property (nonatomic, copy) NSArray<NSString *> *resultFiles;
@end

@implementation OVConvertPage

#pragma mark Construction

- (OVSliderRow *)sliderTitle:(NSString *)title hint:(NSString *)hint key:(NSString *)key def:(double)def min:(double)min max:(double)max
                        step:(double)step format:(NSString *)fmt integer:(BOOL)integer {
    OVSliderRow *r = [OVSliderRow rowWithTitle:title hint:hint value:MIN(max, MAX(min, DD(key, def))) min:min max:max format:fmt integer:integer];
    r.step = step;
    __weak OVSliderRow *wr = r;
    r.onChange = ^{ [D() setDouble:wr.value forKey:key]; };
    return r;
}

- (OVPopup *)popupItems:(NSArray<NSArray<NSString *> *> *)items key:(NSString *)key label:(NSString *)label {
    OVPopup *p = OVDefaultsPopup(items, key, self, @selector(controlChanged:));
    p.accessibilityLabel = label;
    for (NSUInteger i = 0; i < items.count && i < (NSUInteger)p.numberOfItems; i++) [p itemAtIndex:i].representedObject = items[i][1];
    return p;
}

- (void)loadView {
    __weak typeof(self) weakSelf = self;
    self.batchFiles = [NSMutableArray array];
    [OVConvertPage sweepPreviews];

    // Gates: the RVC engine, or Seed-VC for the cloned voice. Each hides itself while ready.
    NSView *g1 = OVEngineGateCard(L(@"Convert"), @[@"pro-env", @"applio", @"rvc-core"], ^(BOOL ready) {
        weakSelf.readyRvc = ready; [weakSelf updateUI]; });
    NSView *g2 = OVEngineGateCard(L(@"Convert with your cloned voice"), @[@"pro-env", @"seedvc"], ^(BOOL ready) {
        weakSelf.readySeed = ready; [weakSelf updateUI]; });
    self.gateRvc = OVFillStack(@[g1], 0);
    self.gateSeed = OVFillStack(@[g2], 0);

    // 1 Source
    self.modePicker = [OVSegmented segmentedWithItems:@[@[L(@"Single"), @"waveform"], @[L(@"Batch"), @"square.stack"]]];
    self.modePicker.accessibilityLabel = L(@"One file or many files");
    self.modePicker.selectedIndex = DB(@"convert.batch", NO) ? 1 : 0;
    self.modePicker.target = self;
    self.modePicker.action = @selector(controlChanged:);
    OVDropZone *zone = [OVDropZone zoneWithTitle:L(@"Drop a recording here")
                                            hint:L(@"or click to choose; WAV, MP3, M4A, FLAC, OGG, AAC, MP4, MOV")
                                           types:@[@"wav", @"mp3", @"m4a", @"flac", @"ogg", @"aac", @"mp4", @"mov"]
                                         onFiles:^(NSArray<NSURL *> *urls) { [weakSelf addFiles:urls]; }];
    self.fileLabel = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.inputBar = [OVPlayerBar new];
    self.inputBar.hidden = YES;
    self.singleBox = OVFillStack(@[self.fileLabel, self.inputBar], 10);
    self.batchCount = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.batchList = OVVStack(@[], 4);
    self.batchList.alignment = NSLayoutAttributeWidth;
    self.batchNote = OVWrapLabel(L(@"Batch works with an RVC model. Convert files one by one with your cloned voice."), 13, OVColor(OVRoleWarn));
    self.batchBox = OVFillStack(@[self.batchCount, self.batchList, self.batchNote,
                                  OVHStack(@[OVGhostButton(L(@"Clear list"), @"trash", self, @selector(clearBatch:)), OVSpacer()], 8)], 8);
    NSMutableArray *topRow = [NSMutableArray arrayWithObjects:self.modePicker, OVSpacer(), nil];
    [topRow insertObject:OVGhostButton(L(@"From YouTube…"), @"play.rectangle", self, @selector(fromYouTube:)) atIndex:1];
    NSView *c1 = OVFillStack(@[OVHStack(topRow, 8), zone, self.singleBox, self.batchBox], 12);

    // 2 Target voice
    self.targetPicker = [OVSegmented segmentedWithItems:@[@[L(@"RVC model"), @"person.wave.2"], @[L(@"My cloned voice"), @"mic"]]];
    self.targetPicker.accessibilityLabel = L(@"Target voice");
    self.targetPicker.selectedIndex = DB(@"convert.clone", NO) ? 1 : 0;
    self.targetPicker.target = self;
    self.targetPicker.action = @selector(controlChanged:);
    self.modelPopup = OVPopup.popup;
    self.modelPopup.accessibilityLabel = L(@"RVC voice model");
    self.modelPopup.target = self;
    self.modelPopup.action = @selector(modelChanged:);
    self.modelHint = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.rvcBox = OVFillStack(@[OVFieldBlock(L(@"Voice model"), nil, OVFillPopup(self.modelPopup)), self.modelHint,
                                OVHStack(@[OVGhostButton(L(@"Models…"), @"square.stack.3d.up", self, @selector(openModels:)), OVSpacer()], 8)], 8);
    self.voicePopup = OVPopup.popup;
    self.voicePopup.accessibilityLabel = L(@"Cloned voice");
    self.voicePopup.target = self;
    self.voicePopup.action = @selector(voiceChanged:);
    self.voiceHint = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.voiceBox = OVFillStack(@[OVFieldBlock(L(@"Voice"), nil, OVFillPopup(self.voicePopup)), self.voiceHint], 8);
    NSView *c2 = OVFillStack(@[OVHStack(@[self.targetPicker, OVSpacer()], 8), self.rvcBox, self.voiceBox], 12);

    // 3 Settings: RVC
    self.pitchRow = [self sliderTitle:L(@"Pitch") hint:L(@"In semitones. -12 is an octave lower, +12 an octave higher.") key:@"convert.pitch" def:0 min:-24 max:24 step:1 format:@"%.0f" integer:YES];
    self.pitchRow.valueFormatter = ^NSString *(double v) { return [NSString stringWithFormat:@"%+.0f", v]; };
    self.f0Picker = [OVSegmented segmentedWithItems:@[@[@"rmvpe", @""], @[@"crepe", @""], @[@"fcpe", @""]]];
    self.f0Picker.accessibilityLabel = L(@"Pitch extraction");
    self.f0Picker.target = self;
    self.f0Picker.action = @selector(f0Changed:);
    self.f0Hint = OVWrapLabel(L(@"rmvpe is the best all-round choice. crepe is slower. fcpe is fast; download it first."), 13, OVColor(OVRoleMuted));
    self.fcpeGate = OVFillStack(@[OVEngineGateCard(L(@"fcpe"), @[@"rvc-fcpe"], ^(BOOL ready) { [weakSelf updateUI]; })], 0);
    NSView *f0Block = OVFieldBlock(L(@"Pitch extraction"), nil, OVFillStack(@[OVHStack(@[self.f0Picker, OVSpacer()], 8), self.f0Hint, self.fcpeGate], 8));
    self.indexRow = [self sliderTitle:L(@"Index rate") hint:L(@"How much of the model's own timbre to keep. Needs an index file.") key:@"convert.index" def:0.3 min:0 max:1 step:0.05 format:@"%.2f" integer:NO];
    self.protectRow = [self sliderTitle:L(@"Protect") hint:L(@"Protects consonants and breath. 0.5 turns it off.") key:@"convert.protect" def:0.33 min:0 max:0.5 step:0.01 format:@"%.2f" integer:NO];
    self.volumeRow = [self sliderTitle:L(@"Volume envelope") hint:L(@"0 keeps the original loudness, 1 uses the model's.") key:@"convert.volume" def:1 min:0 max:1 step:0.05 format:@"%.2f" integer:NO];

    self.formantSwitch = [OVSwitch new];
    self.formantSwitch.on = DB(@"convert.formant.on", NO);
    self.formantSwitch.target = self;
    self.formantSwitch.action = @selector(controlChanged:);
    self.formantSwitch.accessibilityLabel = L(@"Formant shifting");
    self.quefRow = [self sliderTitle:L(@"Quefrency") hint:nil key:@"convert.formant.q" def:1 min:0.1 max:16 step:0.1 format:@"%.1f" integer:NO];
    self.timbreRow = [self sliderTitle:L(@"Timbre") hint:nil key:@"convert.formant.t" def:1 min:0.1 max:16 step:0.1 format:@"%.1f" integer:NO];
    self.formantBox = OVFillStack(@[self.quefRow, self.timbreRow], 8);
    NSView *formant = OVFillStack(@[OVHStack(@[OVLabel(L(@"Formant shifting"), 14, NSFontWeightSemibold, nil), OVSpacer(), self.formantSwitch], 8),
                                    OVLabel(L(@"Changes the voice's character. Adds 64 ms."), 13, NSFontWeightRegular, OVColor(OVRoleMuted)), self.formantBox], 8);

    self.autotuneSwitch = [OVSwitch new];
    self.autotuneSwitch.on = DB(@"convert.autotune.on", NO);
    self.autotuneSwitch.target = self;
    self.autotuneSwitch.action = @selector(controlChanged:);
    self.autotuneSwitch.accessibilityLabel = L(@"Autotune");
    self.autotuneRow = [self sliderTitle:L(@"Strength") hint:nil key:@"convert.autotune.s" def:1 min:0 max:1 step:0.05 format:@"%.2f" integer:NO];
    self.autotuneBox = OVFillStack(@[self.autotuneRow], 8);
    NSView *autotune = OVFillStack(@[OVHStack(@[OVLabel(L(@"Autotune"), 14, NSFontWeightSemibold, nil), OVSpacer(), self.autotuneSwitch], 8),
                                     OVLabel(L(@"Snaps the pitch to the nearest note. Good for singing."), 13, NSFontWeightRegular, OVColor(OVRoleMuted)), self.autotuneBox], 8);

    self.cleanPopup = [self popupItems:@[@[L(@"Off"), @"off"], @[L(@"Light"), @"light"], @[L(@"Speech"), @"speech"]] key:@"convert.clean.mode" label:L(@"Clean audio")];
    self.cleanRow = [self sliderTitle:L(@"Strength") hint:nil key:@"convert.clean.s" def:12 min:0 max:60 step:1 format:@"%.0f" integer:YES];
    self.cleanBox = OVFillStack(@[self.cleanRow], 8);
    NSView *clean = OVFieldBlock(L(@"Clean audio"), L(@"Removes background noise from the result."), OVFillStack(@[OVFillPopup(self.cleanPopup), self.cleanBox], 8));

    NSMutableArray *emb = [NSMutableArray arrayWithObject:@[L(@"ContentVec (default)"), @"contentvec"]];
    NSDictionary *others = @{@"japanese-hubert-base": @[@"Japanese HuBERT", @"japanese_hubert_base"], @"chinese-hubert-base": @[@"Chinese HuBERT", @"chinese_hubert_base"],
                             @"korean-hubert-base": @[@"Korean HuBERT", @"korean_hubert_base"]};
    for (NSString *k in @[@"japanese-hubert-base", @"chinese-hubert-base", @"korean-hubert-base"]) {   // only the ones installed
        NSString *dir = [[[OVPaths engines] stringByAppendingPathComponent:@"applio/rvc/models/embedders"] stringByAppendingPathComponent:others[k][1]];
        if ([NSFileManager.defaultManager fileExistsAtPath:dir]) [emb addObject:@[others[k][0], k]];
    }
    self.embedderPopup = [self popupItems:emb key:@"convert.embedder" label:L(@"Embedder")];
    NSMutableArray *fmts = [NSMutableArray arrayWithArray:@[@[@"WAV", @"WAV"], @[@"FLAC", @"FLAC"], @[@"M4A", @"M4A"]]];
    if ([OVExport ffmpegPath].length) [fmts addObject:@[@"MP3", @"MP3"]];
    self.formatPopup = [self popupItems:fmts key:@"convert.format" label:L(@"Export format")];
    OVDisclosure *adv = [OVDisclosure disclosureWithTitle:L(@"Advanced") subtitle:L(@"Formants, autotune, cleaning, embedder, file format") symbol:@"slider.horizontal.3"
        content:OVFillStack(@[formant, autotune, clean,
                              OVFieldBlock(L(@"Embedder"), L(@"Reads the sound of the words. Keep the default unless a model asks for another."), OVFillPopup(self.embedderPopup)),
                              OVFieldBlock(L(@"Export format"), nil, OVFillPopup(self.formatPopup))], 16)];
    self.rvcSettings = OVFillStack(@[self.pitchRow, f0Block, self.indexRow, self.protectRow, self.volumeRow, adv], 16);

    // Seed-VC
    self.stepsRow = [self sliderTitle:L(@"Diffusion steps") hint:L(@"More steps sound cleaner and take longer. About 3.5 s of work per second of audio at 50 steps.") key:@"convert.steps" def:50 min:10 max:100 step:1 format:@"%.0f" integer:YES];
    self.seedSettings = OVFillStack(@[self.stepsRow], 12);
    NSView *c3 = OVFillStack(@[self.rvcSettings, self.seedSettings], 16);

    // 4 Result
    self.runButton = OVPrimaryButton(L(@"Convert"), self, @selector(run:));
    self.stopButton = OVGhostButton(L(@"Stop"), nil, self, @selector(stop:));
    self.stopButton.hidden = YES;
    self.runBar = OVProgressBar();
    self.runBar.hidden = YES;
    self.runStatus = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.runStatus.hidden = YES;
    self.memoryNote = OVWrapLabel(L(@"This Mac has less than 16 GB. Close other apps first."), 13, OVColor(OVRoleWarn));
    self.memoryNote.hidden = [OVSettings physicalMemoryGB] >= 16;
    self.resultBar = [OVPlayerBar new];
    self.revealButton = OVGhostButton(L(@"Show in Finder"), @"folder", self, @selector(reveal:));
    self.againButton = OVGhostButton(L(@"Convert again"), @"arrow.clockwise", self, @selector(run:));
    self.singleResult = OVFillStack(@[self.resultBar], 8);
    self.resultList = OVVStack(@[], 6);
    self.resultList.alignment = NSLayoutAttributeWidth;
    self.batchResult = self.resultList;
    self.resultBox = OVFillStack(@[self.singleResult, self.batchResult,
                                   OVHStack(@[self.revealButton, self.againButton, OVSpacer()], 8)], 10);
    self.resultBox.hidden = YES;
    NSView *c4 = OVFillStack(@[OVHStack(@[self.runButton, self.stopButton, OVSpacer()], 8), self.memoryNote, self.runBar, self.runStatus, self.resultBox], 12);

    NSView *s1 = OVStepCard(1, @"waveform.badge.plus", L(@"Source"), nil, c1);
    NSView *s2 = OVStepCard(2, @"person.wave.2", L(@"Target voice"), nil, c2);
    NSView *s3 = OVStepCard(3, @"slider.horizontal.3", L(@"Settings"), nil, c3);
    NSView *s4 = OVStepCard(4, @"waveform", L(@"Result"), nil, c4);
    self.body = OVFillStack(@[s1, s2, s3, s4], 16);
    self.view = OVPageScroll(@[OVPageHeader(L(@"Convert"), L(@"Re-voice a recording with an RVC model or your cloned voice."), OVProBadge()),
                               self.gateRvc, self.gateSeed, self.body]);

    NSUInteger f0i = [@[@"rmvpe", @"crepe", @"fcpe"] indexOfObject:[D() stringForKey:@"convert.f0"] ?: @"rmvpe"];
    self.f0Picker.selectedIndex = f0i == NSNotFound ? 0 : (NSInteger)f0i;
    if (self.f0Picker.selectedIndex == 2 && ![self fcpeReady]) self.f0Picker.selectedIndex = 0;

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(jobsChanged:) name:OVJobsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(enginesChanged:) name:OVEnginesDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(enginesChanged:) name:OVRvcModelsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(tryInConvert:) name:@"OVTrainingTryInConvert" object:nil];
    self.built = YES;
    if (sLastJobID) self.job = [OVJobs.shared jobWithId:sLastJobID];
    [self reloadTargets];
    [self updateUI];
    [self jobsChanged:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

/// Posted by the Training page ("Try in Convert", userInfo @"model" = folder name) just before it navigates here.
- (void)tryInConvert:(NSNotification *)n {
    NSString *m = n.userInfo[@"model"];
    if (![m isKindOfClass:NSString.class] || !m.length) return;
    [D() setObject:m forKey:@"convert.model"];
    [D() removeObjectForKey:@"OVConvertPendingRvcModel"];
    [self reloadTargets];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    [self reloadTargets];
    [self updateUI];
    [self jobsChanged:nil];
}

#pragma mark Previews

+ (NSString *)previewFolder {
    NSString *d = [[OVPaths.support stringByAppendingPathComponent:@"tmp"] stringByAppendingPathComponent:@"convert"];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}
/// Previews (decoded copies for the Original side of A/B) older than a day are removed.
+ (void)sweepPreviews {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *d = [self previewFolder];
    for (NSString *n in [fm contentsOfDirectoryAtPath:d error:nil]) {
        NSString *p = [d stringByAppendingPathComponent:n];
        NSDate *m = [fm attributesOfItemAtPath:p error:nil][NSFileModificationDate];
        if (m && -[m timeIntervalSinceNow] > 24 * 3600) [fm removeItemAtPath:p error:nil];
    }
}

#pragma mark Source

- (BOOL)batchMode { return self.modePicker.selectedIndex == 1; }
- (BOOL)cloneTarget { return self.targetPicker.selectedIndex == 1; }

- (void)addFiles:(NSArray<NSURL *> *)urls {
    if (![self bodyEnabled]) return;
    if ([self batchMode]) {
        for (NSURL *u in urls) {
            if (self.batchFiles.count >= kMaxBatch) break;
            if (![self.batchFiles containsObject:u.path]) [self.batchFiles addObject:u.path];
        }
        [self rebuildBatch];
    } else if (urls.firstObject) {
        [self loadSingle:urls.firstObject.path];
    }
    [self updateUI];
}

- (BOOL)bodyEnabled { return [self cloneTarget] ? self.readySeed : self.readyRvc; }

- (void)loadSingle:(NSString *)path {
    self.sourcePath = path;
    self.previewPath = nil;
    self.decoding = YES;
    self.fileLabel.stringValue = [NSString stringWithFormat:L(@"Reading %@…"), path.lastPathComponent];
    self.inputBar.hidden = YES;
    [self.inputBar stopIfPlayingThis];
    NSString *dir = [[OVConvertPage previewFolder] stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dst = [dir stringByAppendingPathComponent:[[path.lastPathComponent stringByDeletingPathExtension] stringByAppendingPathExtension:@"wav"]];
    __weak typeof(self) w = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        double seconds = 0;
        OVDecodeOptions o = {0, NO, kMaxSeconds};
        BOOL ok = OVDecodeAudio(path, dst, o, &seconds, &err);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) s = w;
            if (!s || ![s.sourcePath isEqualToString:path]) { if (ok) [NSFileManager.defaultManager removeItemAtPath:dir error:nil]; return; }
            s.decoding = NO;
            if (!ok) {
                s.sourcePath = nil;
                s.fileLabel.stringValue = err.localizedDescription ?: L(@"This file could not be read.");
            } else {
                s.previewPath = dst;
                s.fileLabel.stringValue = [NSString stringWithFormat:@"%@ · %@", path.lastPathComponent, OVFormatDuration(seconds)];
                s.inputBar.path = dst;
                s.inputBar.hidden = NO;
            }
            [s updateUI];
        });
    });
}

- (void)rebuildBatch {
    for (NSView *v in [self.batchList.arrangedSubviews copy]) { [self.batchList removeArrangedSubview:v]; [v removeFromSuperview]; }
    NSInteger i = 0;
    for (NSString *p in self.batchFiles) {
        NSTextField *l = OVLabel(p.lastPathComponent, 13, NSFontWeightRegular, nil);
        l.lineBreakMode = NSLineBreakByTruncatingMiddle;
        l.toolTip = p;
        [l setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSButton *rm = OVIconButton(@"xmark", [NSString stringWithFormat:L(@"Remove %@"), p.lastPathComponent], self, @selector(removeBatchRow:));
        rm.tag = i++;
        NSStackView *row = OVHStack(@[l, OVSpacer(), rm], 8);
        [self.batchList addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.batchList.widthAnchor].active = YES;
    }
    self.batchCount.stringValue = self.batchFiles.count
        ? [NSString stringWithFormat:L(@"%lu files (up to %lu)"), (unsigned long)self.batchFiles.count, (unsigned long)kMaxBatch]
        : L(@"No files yet. Drop several recordings above.");
}

- (void)fromYouTube:(id)sender {
    __weak typeof(self) w = self;
    [OVYouTubeSheet presentOnWindow:self.view.window destinationDirectory:[OVConvertPage previewFolder] completion:^(NSURL *file) {
        if (file.path.length) [w addFiles:@[file]];
    }];
}

- (void)removeBatchRow:(NSButton *)b {
    if (b.tag >= 0 && b.tag < (NSInteger)self.batchFiles.count) [self.batchFiles removeObjectAtIndex:b.tag];
    [self rebuildBatch];
    [self updateUI];
}
- (void)clearBatch:(id)s { [self.batchFiles removeAllObjects]; [self rebuildBatch]; [self updateUI]; }

#pragma mark Target

- (void)reloadTargets {
    // "Try in Convert" on the Training page: the model's folder name, picked up once
    NSString *pending = [D() stringForKey:@"OVConvertPendingRvcModel"];
    if (pending.length) { [D() setObject:pending forKey:@"convert.model"]; [D() removeObjectForKey:@"OVConvertPendingRvcModel"]; }
    NSString *wantModel = [D() stringForKey:@"convert.model"], *wantVoice = [D() stringForKey:@"convert.voice"];
    self.models = OVRvcStore.shared.models;
    [self.modelPopup removeAllItems];
    if (!self.models.count) {
        [self.modelPopup addItemWithTitle:L(@"No voice models yet")];
        self.modelPopup.enabled = NO;
    } else {
        self.modelPopup.enabled = YES;
        for (OVRvcModel *m in self.models) [self.modelPopup addItemWithTitle:m.name];
        NSUInteger idx = 0;
        for (NSUInteger i = 0; i < self.models.count; i++) if ([self.models[i].identifier isEqual:wantModel]) idx = i;
        [self.modelPopup selectItemAtIndex:idx];
    }
    NSMutableArray<OVVoice *> *vs = [NSMutableArray array];
    for (OVVoice *v in OVVoices.shared.all) if (v.ready && [NSFileManager.defaultManager fileExistsAtPath:v.referencePath]) [vs addObject:v];
    self.voices = vs;
    [self.voicePopup removeAllItems];
    if (!vs.count) {
        [self.voicePopup addItemWithTitle:L(@"No cloned voices yet")];
        self.voicePopup.enabled = NO;
    } else {
        self.voicePopup.enabled = YES;
        NSUInteger idx = 0;
        for (NSUInteger i = 0; i < vs.count; i++) { [self.voicePopup addItemWithTitle:vs[i].name]; if ([vs[i].identifier isEqual:wantVoice]) idx = i; }
        [self.voicePopup selectItemAtIndex:idx];
    }
    [self refreshTargetHints];
}

- (OVRvcModel *)selectedModel {
    NSInteger i = self.modelPopup.indexOfSelectedItem;
    return i >= 0 && i < (NSInteger)self.models.count ? self.models[i] : nil;
}
- (OVVoice *)selectedVoice {
    NSInteger i = self.voicePopup.indexOfSelectedItem;
    return i >= 0 && i < (NSInteger)self.voices.count ? self.voices[i] : nil;
}

- (void)refreshTargetHints {
    OVRvcModel *m = [self selectedModel];
    if (m) {
        NSMutableArray *parts = [NSMutableArray array];
        if (m.version.length) [parts addObject:m.version];
        if (m.sampleRate > 0) [parts addObject:[OVRvcStore kHzText:m.sampleRate]];
        [parts addObject:m.hasIndex ? L(@"has an index file") : L(@"no index file")];
        self.modelHint.stringValue = [parts componentsJoinedByString:@" · "];
    } else {
        self.modelHint.stringValue = L(@"Import a voice model on the Models page, or train one.");
    }
    OVVoice *v = [self selectedVoice];
    self.voiceHint.stringValue = v ? L(@"Seed-VC copies the sound of this voice's sample. It is slower than an RVC model.")
                                   : L(@"Clone a voice on the Voices page first.");
}

- (void)modelChanged:(id)s {
    OVRvcModel *m = [self selectedModel];
    if (m) [D() setObject:m.identifier forKey:@"convert.model"];
    [self refreshTargetHints];
    [self updateUI];
}
- (void)voiceChanged:(id)s {
    OVVoice *v = [self selectedVoice];
    if (v) [D() setObject:v.identifier forKey:@"convert.voice"];
    [self updateUI];
}
- (void)openModels:(id)s { OVNavigate(@"models"); }

- (BOOL)fcpeReady { return [OVEngines.shared componentWithId:@"rvc-fcpe"].state == OVEngineReady; }

- (void)f0Changed:(id)s {
    NSArray *ids = @[@"rmvpe", @"crepe", @"fcpe"];
    NSInteger i = self.f0Picker.selectedIndex;
    if (i == 2 && ![self fcpeReady]) {   // fcpe is not downloaded: it cannot be chosen
        i = 0;
        self.f0Picker.selectedIndex = 0;
        NSBeep();
    }
    [D() setObject:ids[MAX(0, i)] forKey:@"convert.f0"];
    [self updateUI];
}

- (void)controlChanged:(id)sender {
    [D() setBool:[self batchMode] forKey:@"convert.batch"];
    [D() setBool:[self cloneTarget] forKey:@"convert.clone"];
    [D() setBool:self.formantSwitch.on forKey:@"convert.formant.on"];
    [D() setBool:self.autotuneSwitch.on forKey:@"convert.autotune.on"];
    [self updateUI];
}

- (void)enginesChanged:(NSNotification *)n {
    [self reloadTargets];
    [self updateUI];
}

#pragma mark State

- (BOOL)busy { return self.starting || self.job.active; }

- (void)updateUI {
    if (!self.built) return;   // the gate cards call back while the page is still being built
    BOOL batch = [self batchMode], clone = [self cloneTarget];
    self.singleBox.hidden = batch;
    self.batchBox.hidden = !batch;
    if (batch) [self rebuildBatchIfNeeded];
    self.batchNote.hidden = !(batch && clone);
    self.rvcBox.hidden = clone;
    self.voiceBox.hidden = !clone;
    self.rvcSettings.hidden = clone;
    self.seedSettings.hidden = !clone;
    self.gateRvc.hidden = clone;
    self.gateSeed.hidden = !clone;
    self.formantBox.hidden = !self.formantSwitch.on;
    self.autotuneBox.hidden = !self.autotuneSwitch.on;
    self.cleanBox.hidden = [[self cleanMode] isEqual:@"off"];
    BOOL fcpeOK = [self fcpeReady];
    self.f0Hint.hidden = fcpeOK;
    self.fcpeGate.hidden = fcpeOK || !OVEngines.shared.statusLoaded;   // without a status the main gate above already says what to do

    BOOL on = [self bodyEnabled];
    SetEnabledDeep(self.body, on, @[self.fcpeGate, self.inputBar, self.resultBox, self.stopButton]);   // Stop and the result stay usable while the gate is closed
    self.targetPicker.enabled = YES;   // the way to the other engine's gate stays open
    self.modePicker.enabled = YES;
    // controls that depend on more than the gate
    self.modelPopup.enabled = on && self.models.count > 0;
    self.voicePopup.enabled = on && self.voices.count > 0;
    self.indexRow.enabled = on && [self selectedModel].hasIndex;
    self.body.alphaValue = on ? 1 : 0.5;

    BOOL haveInput = batch ? self.batchFiles.count > 0 : (self.sourcePath.length && !self.decoding);
    BOOL haveTarget = clone ? [self selectedVoice] != nil : [self selectedModel] != nil;
    BOOL ok = on && haveInput && haveTarget && !self.busy && !(batch && clone);
    self.runButton.enabled = ok;
    self.stopButton.hidden = !self.job.active;
    self.runBar.hidden = !self.busy;
    self.runStatus.hidden = !self.busy && self.runStatus.stringValue.length == 0;
}

- (void)rebuildBatchIfNeeded {
    if (self.batchList.arrangedSubviews.count != self.batchFiles.count || !self.batchCount.stringValue.length) [self rebuildBatch];
}

#pragma mark Run

- (NSDictionary *)buildRequest {
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    r[@"_page"] = kPage;
    if ([self cloneTarget]) {
        OVVoice *v = [self selectedVoice];
        if (!v || !self.sourcePath) return nil;
        r[@"engine"] = @"seedvc";
        r[@"input"] = self.sourcePath;
        r[@"target"] = v.referencePath;
        r[@"steps"] = @((NSInteger)self.stepsRow.value);
        r[@"_name"] = self.sourcePath.lastPathComponent;
        return r;
    }
    OVRvcModel *m = [self selectedModel];
    if (!m) return nil;
    NSArray *f0s = @[@"rmvpe", @"crepe", @"fcpe"];
    r[@"engine"] = @"rvc";
    r[@"model"] = m.folder;
    r[@"pitch"] = @((NSInteger)self.pitchRow.value);
    r[@"f0_method"] = f0s[MAX(0, self.f0Picker.selectedIndex)];
    r[@"index_rate"] = @(self.indexRow.value);
    r[@"protect"] = @(self.protectRow.value);
    r[@"volume_envelope"] = @(self.volumeRow.value);
    r[@"formant"] = @{@"on": @(self.formantSwitch.on), @"qfrency": @(self.quefRow.value), @"timbre": @(self.timbreRow.value)};
    r[@"autotune"] = @{@"on": @(self.autotuneSwitch.on), @"strength": @(self.autotuneRow.value)};
    r[@"cleanup"] = @{@"mode": [self cleanMode], @"strength": @(self.cleanRow.value)};
    r[@"embedder"] = [self popupValue:self.embedderPopup key:@"convert.embedder" def:@"contentvec"];
    r[@"export_format"] = [self popupValue:self.formatPopup key:@"convert.format" def:@"WAV"];
    if ([self batchMode]) {
        if (!self.batchFiles.count) return nil;
        r[@"mode"] = @"batch";
        r[@"inputs"] = [self.batchFiles copy];
        r[@"_name"] = [NSString stringWithFormat:L(@"%lu files"), (unsigned long)self.batchFiles.count];
    } else {
        if (!self.sourcePath) return nil;
        r[@"mode"] = @"single";
        r[@"input"] = self.sourcePath;
        r[@"_name"] = self.sourcePath.lastPathComponent;
    }
    return r;
}

- (NSString *)cleanMode { return [self popupValue:self.cleanPopup key:@"convert.clean.mode" def:@"off"]; }
- (NSString *)popupValue:(OVPopup *)p key:(NSString *)key def:(NSString *)def {
    NSString *v = p.selectedItem.representedObject;
    return v.length ? v : def;
}

- (void)run:(id)sender {
    if (self.busy) return;
    NSDictionary *req = [self buildRequest];
    if (!req) return;
    self.starting = YES;
    self.resultBox.hidden = YES;
    [self.resultBar stopIfPlayingThis];
    self.runStatus.stringValue = L(@"Starting…");
    self.runBar.indeterminate = YES;
    [self.runBar startAnimation:nil];
    [self updateUI];
    __weak typeof(self) w = self;
    [OVProRun submitKind:OVProKindConvert request:req feature:L(@"Convert") window:self.view.window network:(OVNetFeature)-1
              completion:^(OVJob *job, NSString *error) {
        typeof(self) s = w;
        if (!s) return;
        s.starting = NO;
        if (!job) {
            s.runStatus.stringValue = error ?: @"";   // nil error: the user declined
            [s.runBar stopAnimation:nil];
            [s updateUI];
            return;
        }
        s.job = job;
        sLastJobID = job.identifier;
        s.shownJobId = nil;
        [s jobsChanged:nil];
    }];
}

- (void)stop:(id)sender {
    if (self.job.active) [OVJobs.shared stop:self.job];
}

/// Finds this page's job (also after coming back from another page) and shows its progress or result.
- (void)jobsChanged:(NSNotification *)n {
    if (!self.job) {
        for (OVJob *j in OVJobs.shared.all) {   // newest first
            if ([j.kind isEqual:OVProKindConvert] && j.active && [j.request[@"_page"] isEqual:kPage]) { self.job = j; sLastJobID = j.identifier; break; }
        }
    }
    OVJob *job = self.job;
    if (!job) { [self updateUI]; return; }
    if (job.active) {
        if (job.progress >= 0) { self.runBar.indeterminate = NO; self.runBar.doubleValue = job.progress; }
        else if (!self.runBar.indeterminate) self.runBar.indeterminate = YES;
        if (self.runBar.indeterminate) [self.runBar startAnimation:nil];
        self.runStatus.stringValue = job.status.length ? job.status : L(@"Starting…");   // includes "Freeing memory…"
        self.runStatus.hidden = NO;
    } else if (![self.shownJobId isEqual:job.identifier]) {
        self.shownJobId = job.identifier;
        [self.runBar stopAnimation:nil];
        if (job.state == OVJobSucceeded && job.outputs.count) {
            self.runStatus.stringValue = @"";
            [self showResult:job];
        } else if (job.state == OVJobStopped) {
            self.runStatus.stringValue = L(@"Stopped.");
        } else {
            self.runStatus.stringValue = job.error ?: L(@"Converting failed.");
        }
    }
    [self updateUI];
}

#pragma mark Result

- (void)showResult:(OVJob *)job {
    self.resultFiles = job.outputs;
    BOOL batch = [job.request[@"inputs"] isKindOfClass:NSArray.class];
    self.resultBox.hidden = NO;
    self.singleResult.hidden = batch;
    self.batchResult.hidden = !batch;
    if (!batch) {
        NSString *input = job.request[@"input"];
        NSString *orig = nil;
        if ([input isEqual:self.sourcePath] && self.previewPath) orig = self.previewPath;
        else if ([@[@"wav", @"mp3", @"m4a", @"flac", @"aac"] containsObject:input.pathExtension.lowercaseString] &&
                 [NSFileManager.defaultManager fileExistsAtPath:input]) orig = input;
        self.resultBar.originalPath = orig;
        self.resultBar.path = job.outputs.firstObject;
        [self.resultBar selectOriginal:NO];
        [self.resultBar refresh];
        return;
    }
    for (NSView *v in [self.resultList.arrangedSubviews copy]) { [self.resultList removeArrangedSubview:v]; [v removeFromSuperview]; }
    NSInteger i = 0;
    for (NSString *out in job.outputs) {
        NSTextField *l = OVLabel(out.lastPathComponent, 13, NSFontWeightRegular, nil);
        l.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [l setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSButton *play = OVIconButton(@"play.fill", [NSString stringWithFormat:L(@"Play %@"), out.lastPathComponent], self, @selector(playResultRow:));
        play.tag = i++;
        [self addResultRow:OVHStack(@[OVSymbol(@"checkmark.circle.fill", 14, OVColor(OVRoleOK)), l, OVSpacer(), play], 8)];
    }
    for (NSDictionary *f in [job.result[@"failed"] isKindOfClass:NSArray.class] ? job.result[@"failed"] : @[]) {
        NSString *name = [f[@"input"] lastPathComponent] ?: @"";
        NSTextField *l = OVWrapLabel([NSString stringWithFormat:@"%@ — %@", name, f[@"error"] ?: L(@"failed")], 13, OVColor(OVRoleErr));
        [self addResultRow:OVHStack(@[OVSymbol(@"exclamationmark.triangle.fill", 14, OVColor(OVRoleErr)), l], 8)];
    }
}

- (void)addResultRow:(NSView *)row {
    [self.resultList addArrangedSubview:row];
    [row.widthAnchor constraintEqualToAnchor:self.resultList.widthAnchor].active = YES;
}

- (void)playResultRow:(NSButton *)b {
    if (b.tag >= 0 && b.tag < (NSInteger)self.resultFiles.count) [OVPlayer.shared toggle:self.resultFiles[b.tag]];
}

- (void)reveal:(id)sender {
    NSMutableArray *urls = [NSMutableArray array];
    for (NSString *p in self.resultFiles) [urls addObject:[NSURL fileURLWithPath:p]];
    if (urls.count) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:urls];
}

@end
