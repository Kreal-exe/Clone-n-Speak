// Voice Blender (task 7.12): mixes two installed RVC voice models into a new one (cns_rvc.py blend, kind rvc_blend).
// The mix is written to rvc/models/<id> at once; "Preview" converts a short test recording through it (kind pro_convert),
// "Save" keeps it, "Discard" deletes the folder. Indexes are not mixed, so the new voice has none.
#import "OVPages.h"
#import "OVDesign.h"
#import "OVUI.h"
#import "OVLocale.h"
#import "OVProKit.h"
#import "OVEngines.h"
#import "OVJobs.h"
#import "OVPaths.h"
#import "OVStore.h"
#import "OVAudioIO.h"
#import "OVPlayerBar.h"
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static const NSTimeInterval kPreviewSeconds = 5;

/// One installed voice model, read from its meta.json (written by the import).
@interface OVBlendModel : NSObject
@property (copy) NSString *folder, *name, *version;
@property int sampleRate;
@property BOOL hasIndex;
@property NSInteger epochs;
@end
@implementation OVBlendModel
- (NSString *)detail {
    NSMutableArray *p = [NSMutableArray array];
    if (self.version.length) [p addObject:self.version];
    if (self.sampleRate) [p addObject:[NSString stringWithFormat:@"%d kHz", self.sampleRate / 1000]];
    if (self.epochs > 0) [p addObject:[NSString stringWithFormat:L(@"%ld epochs"), (long)self.epochs]];
    [p addObject:self.hasIndex ? L(@"with index") : L(@"no index")];
    return [p componentsJoinedByString:@" · "];
}
@end

/// The installed models, by name. A folder without a readable meta.json is skipped (the engine refuses it too).
static NSArray<OVBlendModel *> *OVBlendInstalledModels(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *out = [NSMutableArray array];
    NSString *root = OVPaths.rvcModels;
    for (NSString *n in [fm contentsOfDirectoryAtPath:root error:nil]) {
        if ([n hasPrefix:@"."]) continue;
        NSString *dir = [root stringByAppendingPathComponent:n];
        NSData *d = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"meta.json"]];
        NSDictionary *m = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if (![m isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *info = [m[@"info"] isKindOfClass:NSDictionary.class] ? m[@"info"] : @{};
        OVBlendModel *b = [OVBlendModel new];
        b.folder = dir;
        b.name = [m[@"name"] isKindOfClass:NSString.class] && [m[@"name"] length] ? m[@"name"] : n;
        b.version = [info[@"version"] isKindOfClass:NSString.class] ? info[@"version"] : @"";
        b.sampleRate = [info[@"sample_rate"] intValue];
        b.hasIndex = [info[@"has_index"] boolValue];
        b.epochs = [info[@"epochs"] integerValue];
        [out addObject:b];
    }
    [out sortUsingComparator:^NSComparisonResult(OVBlendModel *a, OVBlendModel *c) {
        return [a.name localizedStandardCompare:c.name];
    }];
    return out;
}

/// nil when the two can be blended, else the reason. Checked before the engine starts, from what the import recorded.
static NSString *OVBlendProblem(OVBlendModel *a, OVBlendModel *b) {
    if (!a || !b) return nil;
    if ([a.folder isEqualToString:b.folder]) return L(@"Choose two different models");
    if ((a.version.length && b.version.length && ![a.version isEqualToString:b.version]) ||
        (a.sampleRate && b.sampleRate && a.sampleRate != b.sampleRate))
        return L(@"These voices can’t be blended — different sample rates or versions");
    return nil;
}

@interface OVBlenderPage ()
@property (copy) NSArray<OVBlendModel *> *models;
@property OVPopup *popupA, *popupB;
@property NSTextField *infoA, *infoB, *nameField, *problemLabel, *statusLabel, *resultLabel, *previewFile;
@property NSView *badgeHostA, *badgeHostB;
@property OVSliderRow *ratioRow;
@property NSButton *blendButton, *stopButton, *previewButton, *saveButton, *discardButton, *chooseButton;
@property NSProgressIndicator *bar;
@property NSView *bodyStack, *emptyState, *resultCard;
@property OVPlayerBar *player;
@property (weak) OVJob *job;
@property (copy) NSString *resultFolder, *resultName, *previewSource, *previewTrimmed, *previewOutput;
@property BOOL gateReady, busy;
@end

@implementation OVBlenderPage

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self removePreviewFiles];
}

#pragma mark Layout

- (OVPopup *)modelPopup:(NSString *)label {
    OVPopup *p = [OVPopup popup];
    p.target = self;
    p.action = @selector(selectionChanged:);
    p.accessibilityLabel = label;
    return p;
}

- (void)loadView {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(jobsChanged:) name:OVJobsDidChangeNotification object:nil];

    self.popupA = [self modelPopup:L(@"First voice")];
    self.popupB = [self modelPopup:L(@"Second voice")];
    self.infoA = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.infoB = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    NSView *cardA = OVStepCard(1, @"waveform", L(@"Voice A"), L(@"Choose an installed voice model. Add models on the Models page."),
                               OVFillStack(@[OVFillPopup(self.popupA), self.infoA], 8));
    NSView *cardB = OVStepCard(2, @"waveform", L(@"Voice B"), L(@"Both voices must share the same version and sample rate."),
                               OVFillStack(@[OVFillPopup(self.popupB), self.infoB], 8));

    self.nameField = OVField(L(@"my-blend"));
    self.nameField.accessibilityLabel = L(@"Name of the new voice");
    self.nameField.delegate = (id)self;
    self.ratioRow = [OVSliderRow rowWithTitle:L(@"Blend ratio") hint:L(@"How much of voice A to keep. The rest comes from voice B.")
                                        value:0.5 min:0 max:1 format:@"%.2f" integer:NO];
    self.ratioRow.step = 0.05;
    self.ratioRow.accessibilityName = L(@"Blend ratio, share of voice A");
    self.ratioRow.valueFormatter = ^NSString *(double v) {
        int a = (int)lround(v * 100);
        return [NSString stringWithFormat:L(@"A %d %% · B %d %%"), a, 100 - a];
    };
    __weak typeof(self) weakSelf = self;
    self.ratioRow.onChange = ^{ [weakSelf updateState]; };
    [self.ratioRow refresh];   // the pill shows "A 50 % · B 50 %" from the start
    self.problemLabel = OVWrapLabel(@"", 13, OVColor(OVRoleWarn));
    self.problemLabel.hidden = YES;
    self.problemLabel.accessibilityLabel = L(@"Problem");
    NSView *mix = OVFillStack(@[OVFieldBlock(L(@"Name"), L(@"The new voice is saved under this name."), self.nameField), self.ratioRow,
                                OVWrapLabel(L(@"Indexes aren’t mixed: the new voice has no index, so it sounds a little less like its sources at high Index rate."), 13, OVColor(OVRoleMuted)),
                                self.problemLabel], 14);
    NSView *cardMix = OVStepCard(3, @"slider.horizontal.3", L(@"Blend"), nil, mix);

    self.blendButton = OVPrimaryButton(L(@"Blend voices"), self, @selector(blend:));
    self.stopButton = OVGhostButton(L(@"Stop"), nil, self, @selector(stop:));
    self.stopButton.hidden = YES;
    self.bar = OVProgressBar();
    self.bar.hidden = YES;
    self.statusLabel = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.statusLabel.hidden = YES;
    NSView *run = OVFillStack(@[OVHStack(@[self.blendButton, self.stopButton, OVSpacer()], 8), self.bar, self.statusLabel], 10);
    NSView *cardRun = OVStepCardWithAccessory(0, @"square.stack.3d.up", L(@"Create the voice"), OVProBadge(), run);

    // The result: preview, then keep or throw away.
    self.resultLabel = OVWrapLabel(@"", 14, OVColor(OVRoleText));
    self.previewFile = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.chooseButton = OVGhostButton(L(@"Choose a test recording…"), @"doc", self, @selector(chooseTestFile:));
    self.previewButton = OVGhostButton(L(@"Hear the blend"), @"play.fill", self, @selector(preview:));
    self.player = [OVPlayerBar new];
    self.player.hidden = YES;
    self.saveButton = OVPrimaryButton(L(@"Save"), self, @selector(save:));
    self.discardButton = OVGhostButton(L(@"Discard"), @"trash", self, @selector(discard:));
    NSView *res = OVFillStack(@[self.resultLabel,
                                OVFieldBlock(L(@"Test recording"), L(@"Preview converts its first 5 seconds through the new voice."),
                                             OVFillStack(@[self.previewFile, OVHStack(@[self.chooseButton, self.previewButton, OVSpacer()], 8)], 8)),
                                self.player,
                                OVHStack(@[self.saveButton, self.discardButton, OVSpacer()], 8)], 12);
    self.resultCard = OVStepCard(4, @"checkmark.circle", L(@"Result"), L(@"The new voice is already on the Models page. Keep it, or discard it."), res);
    self.resultCard.hidden = YES;

    self.emptyState = OVWrapLabel(L(@"Blending needs two voice models. Import or train them first; they appear here."), 14, OVColor(OVRoleMuted));
    self.bodyStack = OVFillStack(@[OVColumns(@[cardA, cardB], 16), cardMix, cardRun, self.resultCard], 16);
    NSView *gate = OVEngineGateCard(L(@"Voice Blender"), @[@"pro-env", @"applio"], ^(BOOL ready) {
        weakSelf.gateReady = ready;
        [weakSelf updateState];
    });
    self.view = OVPageScroll(@[OVPageHeader(L(@"Voice Blender"), L(@"Mix two voice models into a new one with a ratio you choose."), OVProBadge()),
                               gate, self.emptyState, self.bodyStack]);
    [self reloadModels];
}

- (void)viewWillAppear { [self reloadModels]; }

#pragma mark Models

- (void)reloadModels {
    OVBlendModel *a = [self modelAt:self.popupA], *b = [self modelAt:self.popupB];
    self.models = OVBlendInstalledModels();
    for (OVPopup *p in @[self.popupA, self.popupB]) {
        [p removeAllItems];
        for (OVBlendModel *m in self.models) [p addItemWithTitle:m.name];
    }
    // Keep the previous choice when it is still there; otherwise the first and the second model.
    NSUInteger ia = a ? [self indexOfFolder:a.folder] : NSNotFound, ib = b ? [self indexOfFolder:b.folder] : NSNotFound;
    if (ia == NSNotFound) ia = 0;
    if (ib == NSNotFound) ib = self.models.count > 1 ? (ia == 0 ? 1 : 0) : 0;
    if (self.models.count) { [self.popupA selectItemAtIndex:ia]; [self.popupB selectItemAtIndex:ib]; }
    [self updateState];
}

- (NSUInteger)indexOfFolder:(NSString *)f {
    for (NSUInteger i = 0; i < self.models.count; i++) if ([self.models[i].folder isEqualToString:f]) return i;
    return NSNotFound;
}

- (OVBlendModel *)modelAt:(OVPopup *)p {
    NSInteger i = p.indexOfSelectedItem;
    return i >= 0 && i < (NSInteger)self.models.count ? self.models[i] : nil;
}

- (void)selectionChanged:(id)sender { [self updateState]; }
- (void)controlTextDidChange:(NSNotification *)n { [self updateState]; }

#pragma mark State

- (NSString *)cleanName { return [self.nameField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; }

- (void)updateState {
    BOOL has = self.models.count > 0;
    self.emptyState.hidden = has;
    self.bodyStack.hidden = !has;
    OVBlendModel *a = [self modelAt:self.popupA], *b = [self modelAt:self.popupB];
    self.infoA.stringValue = a ? [a detail] : @"";
    self.infoB.stringValue = b ? [b detail] : @"";
    NSString *problem = self.models.count < 2 ? (has ? L(@"Choose two different models") : nil) : OVBlendProblem(a, b);
    self.problemLabel.stringValue = problem ?: @"";
    self.problemLabel.hidden = problem == nil;
    BOOL ok = self.gateReady && !self.busy && problem == nil && a && b && [self cleanName].length > 0;
    self.blendButton.enabled = ok;
    self.blendButton.toolTip = ok ? nil : (problem ?: (self.gateReady ? L(@"Name the new voice first") : L(@"Install the engine first")));
    for (NSControl *c in @[self.popupA, self.popupB, self.nameField]) c.enabled = !self.busy;
    self.ratioRow.enabled = !self.busy;
    self.stopButton.hidden = !self.busy;
    BOOL haveResult = self.resultFolder != nil;
    self.resultCard.hidden = !haveResult;
    self.previewButton.enabled = haveResult && !self.busy && self.gateReady && (self.previewSource.length > 0);
    self.chooseButton.enabled = !self.busy;
    self.saveButton.enabled = discardable(self);
    self.discardButton.enabled = discardable(self);
    self.previewFile.stringValue = self.previewSource.length ? self.previewSource.lastPathComponent
                                                              : L(@"No test recording yet. Choose one to hear the new voice.");
}

static BOOL discardable(OVBlenderPage *p) { return p.resultFolder != nil && !p.busy; }

- (void)setBusy:(BOOL)busy status:(NSString *)status {
    self.busy = busy;
    self.bar.hidden = !busy;
    self.statusLabel.hidden = status.length == 0;
    self.statusLabel.stringValue = status ?: @"";
    if (busy) { self.bar.indeterminate = YES; [self.bar startAnimation:nil]; } else [self.bar stopAnimation:nil];
    [self updateState];
}

#pragma mark Blend

- (void)blend:(id)sender {
    OVBlendModel *a = [self modelAt:self.popupA], *b = [self modelAt:self.popupB];
    if (!a || !b || OVBlendProblem(a, b)) return;
    NSString *name = [self cleanName];
    if (!name.length) return;
    [self removePreviewFiles];
    self.resultFolder = nil;
    self.player.hidden = YES;
    NSDictionary *req = @{@"model_a": a.folder, @"model_b": b.folder, @"ratio": @(self.ratioRow.value), @"name": name};
    [self setBusy:YES status:L(@"Starting…")];
    __weak typeof(self) weakSelf = self;
    [OVProRun submitKind:OVProKindRvcBlend request:req feature:L(@"Voice Blender") window:self.view.window network:(OVNetFeature)-1
              completion:^(OVJob *job, NSString *error) {
        typeof(self) s = weakSelf;
        if (!s) return;
        if (!job) { [s setBusy:NO status:error]; return; }   // nil + nil = declined
        s.job = job;
        [s setBusy:YES status:job.status];
    }];
}

- (void)stop:(id)sender { if (self.job) [OVJobs.shared stop:self.job]; }

- (void)jobsChanged:(NSNotification *)n {
    OVJob *job = self.job;
    if (!job || n.object != job) return;
    if (job.active) {
        if ([job.kind isEqualToString:OVProKindRvcBlend] || [job.kind isEqualToString:OVProKindConvert]) {
            self.statusLabel.hidden = job.status.length == 0;
            self.statusLabel.stringValue = job.status ?: @"";
            if (job.progress >= 0) { self.bar.indeterminate = NO; self.bar.doubleValue = job.progress * 100; }
        }
        return;
    }
    self.job = nil;
    if ([job.kind isEqualToString:OVProKindRvcBlend]) [self blendFinished:job]; else [self previewFinished:job];
}

- (void)blendFinished:(OVJob *)job {
    if (job.state == OVJobSucceeded && [job.result[@"model_dir"] isKindOfClass:NSString.class]) {
        self.resultFolder = job.result[@"model_dir"];
        self.resultName = [self cleanName];
        BOOL already = [job.result[@"already"] boolValue];
        self.resultLabel.stringValue = [NSString stringWithFormat:already ? L(@"‘%@’ was already there: these two voices with this ratio were blended before.")
                                                                         : L(@"‘%@’ is ready."), self.resultName];
        [self setBusy:NO status:nil];    } else if (job.state == OVJobStopped) {
        [self setBusy:NO status:L(@"Stopped.")];
    } else {
        [self setBusy:NO status:job.error ?: L(@"The voices couldn’t be blended.")];
    }
}

#pragma mark Preview

- (void)chooseTestFile:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.allowedContentTypes = @[UTTypeAudio, UTTypeMovie];
    p.message = L(@"Choose a short recording of a voice");
    [p beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK || !p.URL) return;
        self.previewSource = p.URL.path;
        [self updateState];
    }];
}

- (void)preview:(id)sender {
    if (!self.resultFolder || !self.previewSource.length) return;
    [self.player stopIfPlayingThis];
    [self removePreviewFiles];
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"blend-preview-%@.wav", NSUUID.UUID.UUIDString]];
    NSError *err = nil;
    OVDecodeOptions o = {.sampleRate = 0, .mono = YES, .maxSeconds = 0};
    if (!OVDecodeAudio(self.previewSource, tmp, o, NULL, &err) || ![self trimWav:tmp to:kPreviewSeconds]) {
        [self setBusy:NO status:L(@"This recording can’t be read. Choose another file.")];
        [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
        return;
    }
    self.previewTrimmed = tmp;
    NSDictionary *req = @{@"engine": @"rvc", @"mode": @"single", @"input": tmp, @"model": self.resultFolder,
                          @"index_rate": @0, @"_name": self.resultName ?: @""};
    [self setBusy:YES status:L(@"Starting…")];
    __weak typeof(self) weakSelf = self;
    [OVProRun submitKind:OVProKindConvert request:req feature:L(@"Voice Blender") window:self.view.window network:(OVNetFeature)-1
              completion:^(OVJob *job, NSString *error) {
        typeof(self) s = weakSelf;
        if (!s) return;
        if (!job) { [s setBusy:NO status:error]; return; }
        s.job = job;
        [s setBusy:YES status:job.status];
    }];
}

/// Keeps the first `seconds` of a float32 WAV (decoded by OVDecodeAudio), in place.
- (BOOL)trimWav:(NSString *)path to:(NSTimeInterval)seconds {
    NSError *e = nil;
    AVAudioFile *in = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:path] error:&e];
    if (!in) return NO;
    AVAudioFrameCount n = (AVAudioFrameCount)MIN((double)in.length, seconds * in.processingFormat.sampleRate);
    if (n == 0) return NO;
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:in.processingFormat frameCapacity:n];
    if (![in readIntoBuffer:buf frameCount:n error:&e]) return NO;
    NSDictionary *settings = in.fileFormat.settings;
    NSString *out = [path stringByAppendingString:@".trim.wav"];
    AVAudioFile *w = [[AVAudioFile alloc] initForWriting:[NSURL fileURLWithPath:out] settings:settings error:&e];
    if (!w || ![w writeFromBuffer:buf error:&e]) return NO;
    w = nil;
    return [NSFileManager.defaultManager replaceItemAtURL:[NSURL fileURLWithPath:path] withItemAtURL:[NSURL fileURLWithPath:out]
                                           backupItemName:nil options:0 resultingItemURL:nil error:nil];
}

- (void)previewFinished:(OVJob *)job {
    NSString *out = job.outputs.firstObject;
    if (job.state == OVJobSucceeded && out) {
        self.previewOutput = out;
        self.player.originalPath = self.previewTrimmed;
        self.player.path = out;
        self.player.hidden = NO;
        [self setBusy:NO status:nil];
        [self.player selectOriginal:NO];
    } else if (job.state == OVJobStopped) {
        [self setBusy:NO status:L(@"Stopped.")];
    } else {
        [self setBusy:NO status:job.error ?: L(@"The preview couldn’t be made.")];
    }
}

- (void)removePreviewFiles {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (self.previewTrimmed) [fm removeItemAtPath:self.previewTrimmed error:nil];
    if (self.previewOutput) [fm removeItemAtPath:self.previewOutput error:nil];
    self.previewTrimmed = self.previewOutput = nil;
}

#pragma mark Save / Discard

- (void)save:(id)sender {
    [self.player stopIfPlayingThis];
    [self removePreviewFiles];
    NSString *name = self.resultName ?: @"";
    self.resultFolder = nil;
    self.player.hidden = YES;
    [self setBusy:NO status:[NSString stringWithFormat:L(@"Saved ‘%@’. It is on the Models page and in Convert."), name]];
}

- (void)discard:(id)sender {
    NSString *folder = self.resultFolder;
    // Only a folder directly inside rvc/models, never anything else.
    NSString *root = OVPaths.rvcModels.stringByResolvingSymlinksInPath;
    NSString *real = folder.stringByResolvingSymlinksInPath;
    if (folder && [real.stringByDeletingLastPathComponent isEqualToString:root] && real.lastPathComponent.length)
        [NSFileManager.defaultManager removeItemAtPath:real error:nil];
    [self.player stopIfPlayingThis];
    [self removePreviewFiles];
    self.resultFolder = nil;
    self.player.hidden = YES;
    [self reloadModels];
    [self setBusy:NO status:L(@"Discarded. The new voice was deleted.")];
}

@end
