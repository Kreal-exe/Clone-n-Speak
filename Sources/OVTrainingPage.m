// Training page (task 7.11): a dataset, a check of it, RVC training with live progress and an overtraining detector,
// and the earlier runs. The work is the `rvc_review` and `rvc_train` pro jobs (cns_train.py); this file only asks for them
// through OVProRun and reads what they report.
#import "OVPages.h"
#import "OVDesign.h"
#import "OVUI.h"
#import "OVLocale.h"
#import "OVEngines.h"
#import "OVProKit.h"
#import "OVStore.h"
#import "OVJobs.h"
#import "OVMemory.h"
#import "OVPaths.h"
#import "OVTheme.h"
#import "OVWorker.h"
#import "OVYouTubeSheet.h"
#import "OVTrainingModel.h"
#import <AVFoundation/AVFoundation.h>

/// "Try in Convert": the page writes this defaults key (the model's folder name) before OVNavigate(@"convert"), and posts the
/// notification with userInfo @"model". The Convert page picks the model up from either.
NSString *const OVTrainingConvertModelKey = @"OVConvertPendingRvcModel";
NSNotificationName const OVTrainingTryInConvertNotification = @"OVTrainingTryInConvert";

static const NSUInteger kMaxFiles = 2000;
static const NSUInteger kShownRows = 100;

#pragma mark - Loss chart

/// Mel-loss per epoch, drawn with Core Graphics. Colors come from OVColor roles at draw time.
@interface OVLossChart : NSView
@property (nonatomic, copy) NSArray<NSNumber *> *values;   // one per epoch, oldest first
@property (nonatomic) NSInteger bestEpoch;                 // 1-based epoch to mark; 0 = none
@end

@implementation OVLossChart
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _values = @[];
        self.accessibilityRole = NSAccessibilityImageRole;
        self.accessibilityLabel = L(@"Mel loss per epoch");
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric, 170); }
- (void)setValues:(NSArray<NSNumber *> *)v {
    _values = [v copy] ?: @[];
    NSNumber *last = _values.lastObject;
    NSNumber *lowest = [_values valueForKeyPath:@"@min.self"];
    self.accessibilityValue = _values.count
        ? [NSString stringWithFormat:L(@"%ld epochs, last %.2f, lowest %.2f"), (long)_values.count, last.doubleValue, lowest.doubleValue]
        : L(@"No data yet");
    self.needsDisplay = YES;
}
- (void)setBestEpoch:(NSInteger)b { _bestEpoch = b; self.needsDisplay = YES; }
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }

- (void)drawRect:(NSRect)dirty {
    NSRect box = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath *frame = [NSBezierPath bezierPathWithRoundedRect:box xRadius:10 yRadius:10];
    [OVColor(OVRoleField) setFill];
    [frame fill];
    [OVColor(OVRoleBorder) setStroke];
    frame.lineWidth = 1;
    [frame stroke];
    NSDictionary *small = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular],
                            NSForegroundColorAttributeName: OVColor(OVRoleMuted)};
    if (self.values.count < 1) {
        NSString *t = L(@"The graph appears after the first epoch.");
        NSSize sz = [t sizeWithAttributes:small];
        [t drawAtPoint:NSMakePoint(NSMidX(box) - sz.width / 2, NSMidY(box) - sz.height / 2) withAttributes:small];
        return;
    }
    CGFloat left = 44, right = 14, top = 14, bottom = 24;
    NSRect plot = NSMakeRect(NSMinX(box) + left, NSMinY(box) + top, NSWidth(box) - left - right, NSHeight(box) - top - bottom);
    double lo = [[self.values valueForKeyPath:@"@min.self"] doubleValue], hi = [[self.values valueForKeyPath:@"@max.self"] doubleValue];
    if (hi - lo < 1e-6) { hi += 0.5; lo -= 0.5; }
    double pad = (hi - lo) * 0.08;
    lo -= pad; hi += pad;
    for (int i = 0; i < 3; i++) {   // three guide lines with their values
        CGFloat y = NSMinY(plot) + NSHeight(plot) * i / 2.0;
        NSBezierPath *g = [NSBezierPath bezierPath];
        [g moveToPoint:NSMakePoint(NSMinX(plot), round(y) + 0.5)];
        [g lineToPoint:NSMakePoint(NSMaxX(plot), round(y) + 0.5)];
        [OVColorAlpha(OVRoleBorder, 0.8) setStroke];
        g.lineWidth = 1;
        [g stroke];
        NSString *lab = [NSString stringWithFormat:@"%.1f", hi - (hi - lo) * i / 2.0];
        NSSize sz = [lab sizeWithAttributes:small];
        [lab drawAtPoint:NSMakePoint(NSMinX(plot) - 6 - sz.width, y - sz.height / 2) withAttributes:small];
    }
    NSUInteger n = self.values.count;
    CGFloat (^X)(NSUInteger) = ^CGFloat(NSUInteger i) { return n < 2 ? NSMidX(plot) : NSMinX(plot) + NSWidth(plot) * i / (double)(n - 1); };
    CGFloat (^Y)(double) = ^CGFloat(double v) { return NSMinY(plot) + NSHeight(plot) * (1 - (v - lo) / (hi - lo)); };
    NSBezierPath *line = [NSBezierPath bezierPath];
    line.lineWidth = 2;
    line.lineJoinStyle = NSLineJoinStyleRound;
    for (NSUInteger i = 0; i < n; i++) {
        NSPoint p = NSMakePoint(X(i), Y(self.values[i].doubleValue));
        if (i == 0) [line moveToPoint:p]; else [line lineToPoint:p];
    }
    [OVColor(OVRoleAccent) setStroke];
    [line stroke];
    NSPoint last = NSMakePoint(X(n - 1), Y(self.values[n - 1].doubleValue));
    [OVColor(OVRoleAccent) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(last.x - 3, last.y - 3, 6, 6)] fill];
    if (self.bestEpoch >= 1 && (NSUInteger)self.bestEpoch <= n) {
        NSPoint b = NSMakePoint(X((NSUInteger)self.bestEpoch - 1), Y(self.values[(NSUInteger)self.bestEpoch - 1].doubleValue));
        NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(b.x - 5, b.y - 5, 10, 10)];
        ring.lineWidth = 2;
        [OVColor(OVRoleOK) setStroke];
        [ring stroke];
    }
    NSString *first = @"1", *end = [NSString stringWithFormat:L(@"epoch %lu"), (unsigned long)n];
    [first drawAtPoint:NSMakePoint(NSMinX(plot), NSMaxY(plot) + 6) withAttributes:small];
    NSSize es = [end sizeWithAttributes:small];
    [end drawAtPoint:NSMakePoint(NSMaxX(plot) - es.width, NSMaxY(plot) + 6) withAttributes:small];
}
@end

#pragma mark - Folder drop zone

/// A dashed target that takes a folder (by drop or by "Choose folder…"), in the look of OVDropZone.
@interface OVTrainFolderZone : NSView
@property (nonatomic, copy) void (^onFolder)(NSURL *folder);
@end

@implementation OVTrainFolderZone {
    BOOL _dragging;
}
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        NSTextField *title = OVWrapLabel(L(@"Drop a folder of recordings here, or click to choose one"), 14, OVColor(OVRoleText));
        title.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
        title.alignment = NSTextAlignmentCenter;
        NSTextField *hint = OVWrapLabel(L(@"Every WAV, MP3, M4A, FLAC and OGG file inside is used, including subfolders."), 12, OVColor(OVRoleMuted));
        hint.alignment = NSTextAlignmentCenter;
        NSImageView *icon = OVSymbol(@"folder", 22, OVColor(OVRoleAccent));
        NSStackView *s = OVVStack(@[icon, title, hint], 8);
        s.alignment = NSLayoutAttributeCenterX;
        OVFillWidth(@[title, hint], s);
        [self addSubview:s];
        OVPin(s, self, NSEdgeInsetsMake(22, 20, 22, 20));
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
        for (NSView *v in s.arrangedSubviews) v.accessibilityElement = NO;
        self.accessibilityLabel = L(@"Choose a folder of recordings");
    }
    return self;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityButtonRole; }
- (NSArray *)accessibilityChildren { return @[]; }
- (BOOL)accessibilityPerformPress { [self choose]; return YES; }
- (NSRect)focusRingMaskBounds { return self.bounds; }
- (void)drawFocusRingMask { [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:12 yRadius:12] fill]; }
- (void)drawRect:(NSRect)r {
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:12 yRadius:12];
    if (_dragging) { [OVColor(OVRoleAccentSoft) setFill]; [p fill]; }
    CGFloat dash[2] = {5, 4};
    [p setLineDash:dash count:2 phase:0];
    p.lineWidth = 1;
    [(_dragging ? OVColor(OVRoleAccent) : OVColor(OVRoleGhostBorder)) setStroke];
    [p stroke];
}
- (NSURL *)folderIn:(id<NSDraggingInfo>)info {
    NSArray *urls = [info.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    for (NSURL *u in urls) {
        NSNumber *dir;
        [u getResourceValue:&dir forKey:NSURLIsDirectoryKey error:nil];
        if (dir.boolValue) return u;
    }
    return nil;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info {
    if (![self folderIn:info]) return NSDragOperationNone;
    _dragging = YES; self.needsDisplay = YES;
    return NSDragOperationCopy;
}
- (void)draggingExited:(id<NSDraggingInfo>)info { _dragging = NO; self.needsDisplay = YES; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
    _dragging = NO; self.needsDisplay = YES;
    NSURL *u = [self folderIn:info];
    if (u && self.onFolder) self.onFolder(u);
    return u != nil;
}
- (void)choose {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = NO;
    p.canChooseDirectories = YES;
    p.allowsMultipleSelection = NO;
    p.prompt = L(@"Choose");
    void (^done)(NSModalResponse) = ^(NSModalResponse r) { if (r == NSModalResponseOK && p.URL && self.onFolder) self.onFolder(p.URL); };
    if (self.window) [p beginSheetModalForWindow:self.window completionHandler:done]; else done([p runModal]);
}
- (void)mouseDown:(NSEvent *)e { [self.window makeFirstResponder:self]; [self choose]; }
- (void)keyDown:(NSEvent *)e {
    NSString *c = e.charactersIgnoringModifiers;
    if ([c isEqualToString:@" "] || [c isEqualToString:@"\r"]) [self choose]; else [super keyDown:e];
}
@end

#pragma mark - Helpers

static void SetTreeEnabled(NSView *v, BOOL on) {
    if ([v isKindOfClass:NSControl.class]) ((NSControl *)v).enabled = on;
    else if ([v respondsToSelector:@selector(setEnabled:)] && [v isKindOfClass:OVSliderRow.class]) ((OVSliderRow *)v).enabled = on;
    for (NSView *s in v.subviews) SetTreeEnabled(s, on);
}

static NSString *GB(unsigned long long bytes) { return [OVMemory format:bytes]; }

static NSMutableDictionary *ReadJSON(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    id o = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    return [o isKindOfClass:NSMutableDictionary.class] ? o : nil;
}

static double AudioSeconds(NSURL *url) {
    NSError *e = nil;
    AVAudioFile *f = [[AVAudioFile alloc] initForReading:url error:&e];
    if (f && f.processingFormat.sampleRate > 0) return (double)f.length / f.processingFormat.sampleRate;
    AVURLAsset *a = [AVURLAsset URLAssetWithURL:url options:nil];
    double s = CMTimeGetSeconds(a.duration);
    return isfinite(s) && s > 0 ? s : 0;
}

#pragma mark - Page

@interface OVTrainingPage () <NSTextFieldDelegate>
// gates
@property BOOL mainReady;
@property NSMutableDictionary<NSNumber *, NSNumber *> *rateReady;
@property NSMutableDictionary<NSNumber *, NSView *> *rateGates;
@property NSView *body;
// 1 dataset
@property OVSegmented *sourceMode;
@property NSView *filesPane, *folderPane, *youtubePane;
@property NSTextField *nameField, *nameNote, *summaryLabel;
@property NSStackView *listStack;
@property NSButton *clearButton;
@property NSMutableArray<NSMutableDictionary *> *entries;   // path, duration (NSNumber or nil)
@property (copy) NSString *ownedFolder;                      // datasets/<slug> made by this page
// 2 check
@property NSView *verdictHost, *checkCard;
@property NSStackView *issuesStack;
@property NSTextField *checkStatus, *levelLabel;
@property NSButton *checkButton, *removeFlaggedButton;
@property NSProgressIndicator *checkBar;
@property NSDictionary *report;
@property (weak) OVJob *reviewJob;
// 3 training
@property OVSegmented *rateSeg, *batchSeg, *f0Seg;
@property OVSliderRow *epochsRow, *saveRow;
@property NSTextField *epochsHint, *batchHint, *startNote, *f0Hint;
@property OVPopup *embedderPopup, *indexPopup;
@property OVSwitch *keepSwitch;
@property NSButton *startButton;
@property BOOL epochsTouched, batchTouched;
// 4 progress
@property NSView *progressCard, *detectorHost;
@property NSTextField *progressTitle, *progressDetail, *memoryLabel, *progressNote;
@property NSProgressIndicator *progressBar;
@property OVLossChart *chart;
@property NSButton *stopButton, *useBestButton;
@property (weak) OVJob *job;
@property (copy) NSString *jobName;
@property NSInteger useBestEpoch;       // > 0: after the stop, export this epoch
@property (copy) NSDictionary *jobSettings;
@property NSTimer *timer;
// 5 result
@property NSView *resultCard;
@property NSTextField *resultHeadline;
@property OVSliderRow *moreRow;
@property NSStackView *runsStack;
@property NSArray<NSDictionary *> *runs;
@end

@implementation OVTrainingPage

- (void)dealloc {
    [self.timer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (NSInteger)sampleRateK { return [(@[@32, @40, @48])[MAX(0, MIN(2, self.rateSeg.selectedIndex))] integerValue]; }

- (void)loadView {
    self.entries = [NSMutableArray array];
    self.rateReady = [NSMutableDictionary dictionary];
    self.rateGates = [NSMutableDictionary dictionary];
    self.runs = @[];
    __weak typeof(self) weak = self;

    // gate
    NSView *gate = OVEngineGateCard(L(@"Training"), @[@"pro-env", @"applio", @"rvc-core"], ^(BOOL ready) { weak.mainReady = ready; [weak updateEnabled]; });

    // 1 Dataset
    self.sourceMode = [OVSegmented segmentedWithItems:@[@[L(@"Files"), @"doc.on.doc"], @[L(@"Folder"), @"folder"], @[L(@"YouTube"), @"play.rectangle"]]];
    self.sourceMode.target = self; self.sourceMode.action = @selector(sourceModeChanged:);
    self.sourceMode.accessibilityLabel = L(@"Where the recordings come from");
    self.sourceMode.selectedIndex = 0;
    self.filesPane = [OVDropZone zoneWithTitle:L(@"Drop recordings here, or click to choose files")
                                          hint:L(@"The more clean speech of one person, the better the voice. Files are copied, the originals stay where they are.")
                                         types:[OVTrainingModel datasetExtensions]
                                       onFiles:^(NSArray<NSURL *> *urls) { [weak addURLs:urls]; }];
    OVTrainFolderZone *fz = [OVTrainFolderZone new];
    fz.onFolder = ^(NSURL *u) { [weak addURLs:@[u]]; };
    self.folderPane = fz;
    NSTextField *ytText = OVWrapLabel(L(@"Download the sound of a video you have the rights to. It is added to the list below."), 13, OVColor(OVRoleMuted));
    NSButton *ytButton = OVGhostButton(L(@"Import from YouTube…"), @"play.rectangle", self, @selector(importYouTube:));
    self.youtubePane = OVFillStack(@[ytText, OVHStack(@[ytButton, OVSpacer()], 8)], 10);
    self.folderPane.hidden = YES;
    self.youtubePane.hidden = YES;

    self.nameField = OVField(L(@"my-voice"));
    self.nameField.delegate = self;
    self.nameField.accessibilityLabel = L(@"Voice name");
    self.nameNote = OVWrapLabel(@"", 13, OVColor(OVRoleWarn));
    self.nameNote.hidden = YES;
    NSView *nameBlock = OVFieldBlock(L(@"Voice name"), L(@"Letters, numbers, - and _ only. Spaces become _."), self.nameField);

    self.listStack = OVVStack(@[], 0);
    self.listStack.alignment = NSLayoutAttributeLeading;
    self.summaryLabel = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.clearButton = OVSmallPill(OVGhostButton(L(@"Clear list"), nil, self, @selector(clearList:)));
    NSView *summaryRow = OVHStack(@[self.summaryLabel, OVSpacer(), self.clearButton], 8);
    NSView *c1 = OVFillStack(@[self.sourceMode, self.filesPane, self.folderPane, self.youtubePane, nameBlock, self.nameNote, self.listStack, summaryRow], 12);

    // 2 Dataset check
    self.checkButton = OVSmallPill(OVGhostButton(L(@"Check dataset"), @"checklist", self, @selector(checkDataset:)));
    self.verdictHost = OVHStack(@[], 0);
    self.checkStatus = OVWrapLabel(L(@"Looks for silence, long pauses, clipping, loudness jumps, duplicates and too little speech."), 13, OVColor(OVRoleMuted));
    self.levelLabel = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.levelLabel.hidden = YES;
    self.issuesStack = OVVStack(@[], 8);
    self.issuesStack.alignment = NSLayoutAttributeLeading;
    self.removeFlaggedButton = OVGhostButton(L(@"Remove flagged files"), @"trash", self, @selector(removeFlagged:));
    self.removeFlaggedButton.hidden = YES;
    self.checkBar = OVProgressBar();
    self.checkBar.hidden = YES;
    NSView *c2 = OVFillStack(@[self.verdictHost, self.checkStatus, self.checkBar, self.issuesStack, self.levelLabel,
                               OVHStack(@[self.removeFlaggedButton, OVSpacer()], 8)], 10);
    self.checkCard = OVStepCardWithAccessory(2, @"checklist", L(@"Dataset check"), self.checkButton, c2);

    // 3 Training
    self.rateSeg = [OVSegmented segmentedWithItems:@[@[@"32 kHz", @""], @[@"40 kHz", @""], @[@"48 kHz", @""]]];
    self.rateSeg.selectedIndex = 1;
    self.rateSeg.target = self; self.rateSeg.action = @selector(rateChanged:);
    self.rateSeg.accessibilityLabel = L(@"Sample rate");
    NSMutableArray *gates = [NSMutableArray array];
    for (NSNumber *k in @[@32, @40, @48]) {
        NSInteger kk = k.integerValue;
        NSView *g = OVEngineGateCard([NSString stringWithFormat:L(@"Training at %ld kHz"), (long)kk], @[[NSString stringWithFormat:@"rvc-train-%ldk", (long)kk]],
                                     ^(BOOL ready) { weak.rateReady[@(kk)] = @(ready); [weak updateEnabled]; });
        self.rateGates[k] = g;
        [gates addObject:g];
    }
    self.epochsRow = [OVSliderRow rowWithTitle:L(@"Epochs") hint:nil value:200 min:1 max:500 format:@"%.0f" integer:YES];
    self.epochsRow.step = 1;
    self.epochsRow.accessibilityName = L(@"Epochs");
    self.epochsRow.onChange = ^{ weak.epochsTouched = YES; [weak updateEpochHint]; };
    self.epochsHint = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.saveRow = [OVSliderRow rowWithTitle:L(@"Save every") hint:L(@"A copy of the voice is kept every N epochs; training can be continued from the latest one.")
                                       value:5 min:1 max:50 format:@"%.0f" integer:YES];
    self.saveRow.step = 1;
    self.saveRow.valueFormatter = ^NSString *(double v) { return [NSString stringWithFormat:L(@"%.0f epochs"), v]; };
    [self.saveRow refresh];
    self.batchSeg = [OVSegmented segmentedWithItems:@[@[@"2", @""], @[@"4", @""], @[@"8", @""]]];
    self.batchSeg.selectedIndex = 1;
    self.batchSeg.target = self; self.batchSeg.action = @selector(batchChanged:);
    self.batchSeg.accessibilityLabel = L(@"Batch size");
    self.batchHint = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.f0Seg = [OVSegmented segmentedWithItems:@[@[@"rmvpe", @""], @[@"crepe", @""], @[@"fcpe", @""]]];
    self.f0Seg.selectedIndex = 0;
    self.f0Seg.target = self; self.f0Seg.action = @selector(f0Changed:);
    self.f0Seg.accessibilityLabel = L(@"Pitch extraction");
    self.f0Hint = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.embedderPopup = [OVPopup popup];
    [self.embedderPopup addItemWithTitle:@"contentvec"];
    self.embedderPopup.accessibilityLabel = L(@"Embedder");
    self.indexPopup = [OVPopup popup];
    [self.indexPopup addItemsWithTitles:@[@"Auto", @"Faiss", @"KMeans"]];
    self.indexPopup.accessibilityLabel = L(@"Index algorithm");
    self.keepSwitch = [OVSwitch new];
    self.keepSwitch.on = YES;
    self.keepSwitch.accessibilityLabel = L(@"Keep checkpoints for continuing");
    NSView *keepRow = OVHStack(@[OVLabel(L(@"Keep checkpoints for continuing (1.3 GB)"), 14, NSFontWeightSemibold, nil), OVSpacer(), self.keepSwitch], 12);
    NSView *advanced = OVFillStack(@[OVFieldBlock(L(@"Pitch extraction"), L(@"rmvpe is the most accurate and the default."), self.f0Seg), self.f0Hint,
                                     OVFieldBlock(L(@"Embedder"), nil, OVFillPopup(self.embedderPopup)),
                                     OVFieldBlock(L(@"Index algorithm"), L(@"Auto picks the right one for the size of the dataset."), OVFillPopup(self.indexPopup)),
                                     keepRow], 14);
    OVDisclosure *disc = [OVDisclosure disclosureWithTitle:L(@"Advanced") subtitle:nil symbol:@"slider.horizontal.3" content:advanced];
    self.startNote = OVWrapLabel(@"", 13, OVColor(OVRoleWarn));
    self.startNote.hidden = YES;
    self.startButton = OVPrimaryButton(L(@"Start training"), self, @selector(startTraining:));
    NSView *c3 = OVFillStack(@[OVFieldBlock(L(@"Sample rate"), L(@"Match the rate of the voice you will convert to. 40 kHz suits most cases."), self.rateSeg),
                               OVFillStack(gates, 8), self.epochsRow, self.epochsHint, self.saveRow,
                               OVFieldBlock(L(@"Batch size"), nil, self.batchSeg), self.batchHint, disc,
                               self.startNote, OVHStack(@[self.startButton, OVSpacer()], 8)], 14);
    NSView *trainCard = OVStepCard(3, @"slider.horizontal.3", L(@"Training"), nil, c3);

    // 4 Progress
    self.progressTitle = OVLabel(@"", 15, NSFontWeightSemibold, nil);
    self.progressDetail = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.progressBar = OVProgressBar();
    self.progressBar.accessibilityLabel = L(@"Training progress");
    self.memoryLabel = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.chart = [OVLossChart new];
    self.chart.translatesAutoresizingMaskIntoConstraints = NO;
    [self.chart.heightAnchor constraintEqualToConstant:170].active = YES;
    self.detectorHost = OVHStack(@[], 0);
    self.useBestButton = OVGhostButton(@"", @"checkmark.seal", self, @selector(stopUseBest:));
    self.useBestButton.hidden = YES;
    self.stopButton = OVGhostButton(L(@"Stop"), @"stop.fill", self, @selector(stopTraining:));
    self.progressNote = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.progressNote.hidden = YES;
    OVFlowRow *actions = [OVFlowRow new];
    [actions setItems:@[self.stopButton, self.useBestButton]];
    NSView *c4 = OVFillStack(@[self.progressTitle, self.progressBar, self.progressDetail, self.chart,
                               OVHStack(@[OVLabel(L(@"Overfitting check"), 14, NSFontWeightSemibold, nil), self.detectorHost, OVSpacer()], 10),
                               self.memoryLabel, self.progressNote, actions], 12);
    self.progressCard = OVStepCard(4, @"chart.xyaxis.line", L(@"Progress"), nil, c4);
    self.progressCard.hidden = YES;

    // 5 Result
    self.resultHeadline = OVWrapLabel(@"", 14, OVColor(OVRoleText));
    self.resultHeadline.hidden = YES;
    self.moreRow = [OVSliderRow rowWithTitle:L(@"Continue with") hint:L(@"How many more epochs “Continue training” adds to a finished voice.") value:50 min:10 max:300 format:@"%.0f" integer:YES];
    self.moreRow.step = 10;
    self.moreRow.valueFormatter = ^NSString *(double v) { return [NSString stringWithFormat:L(@"+%.0f epochs"), v]; };
    [self.moreRow refresh];
    self.runsStack = OVVStack(@[], 8);
    self.runsStack.alignment = NSLayoutAttributeLeading;
    self.resultCard = OVStepCard(5, @"checkmark.seal", L(@"Result"), nil, OVFillStack(@[self.resultHeadline, self.moreRow, self.runsStack], 12));

    self.body = OVFillStack(@[OVStepCard(1, @"waveform.badge.plus", L(@"Dataset"), nil, c1), self.checkCard, trainCard, self.progressCard, self.resultCard], 16);
    self.view = OVPageScroll(@[OVPageHeader(L(@"Training"), L(@"Train an RVC voice from your own recordings."), OVProBadge()), gate, self.body]);

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(jobsChanged:) name:OVJobsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(enginesChanged:) name:OVEnginesDidChangeNotification object:nil];
    [self rateChanged:nil];
    [self updateEpochHint];
    [self rebuildList];
    [self refreshRuns];
    [self updateBatchAdvice];
    [self updateEnabled];
}

#pragma mark - Appearing

- (void)viewWillAppear {
    [super viewWillAppear];
    [self refreshRuns];
    [self adoptRunningJob];
    [self updateBatchAdvice];
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [self tick:nil];
    [self applyDeveloperAids];
}

/// Developer aids for snapshots and real runs: OV_TRAINING_FOLDER=<dir of recordings> OV_TRAINING_NAME=<name>
/// [OV_TRAINING_EPOCHS=2 OV_TRAINING_SAVE=1 OV_TRAINING_BATCH=4 OV_TRAINING_AUTOSTART=1]. They go through the same paths as the buttons.
- (void)applyDeveloperAids {
    NSDictionary<NSString *, NSString *> *env = NSProcessInfo.processInfo.environment;
    NSString *folder = env[@"OV_TRAINING_FOLDER"];
    if (!folder.length || self.entries.count || self.job) return;
    if (env[@"OV_TRAINING_NAME"].length) { self.nameField.stringValue = env[@"OV_TRAINING_NAME"]; [self controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:self.nameField]]; }
    if (env[@"OV_TRAINING_EPOCHS"].length) { self.epochsRow.value = env[@"OV_TRAINING_EPOCHS"].doubleValue; self.epochsTouched = YES; [self updateEpochHint]; }
    if (env[@"OV_TRAINING_SAVE"].length) self.saveRow.value = env[@"OV_TRAINING_SAVE"].doubleValue;
    if (env[@"OV_TRAINING_BATCH"].length) { self.batchSeg.selectedIndex = env[@"OV_TRAINING_BATCH"].integerValue == 2 ? 0 : 1; self.batchTouched = YES; [self updateBatchAdvice]; }
    [self addFiles:[OVTrainingModel audioFilesInFolder:[NSURL fileURLWithPath:folder] limit:kMaxFiles]];
    if ([env[@"OV_TRAINING_AUTOSTART"] boolValue]) {
        // wait for the durations and the gates
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ if (!self.job) [self startTraining:nil]; });
    }
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    [self.timer invalidate];
    self.timer = nil;
}

- (void)enginesChanged:(NSNotification *)n { [self updateBatchAdvice]; [self updateEnabled]; }

/// Developer aid: OV_TRAINING_SNAP=/tmp/x writes the whole page to /tmp/x-<n>.png every 20 s while the page is open.
- (void)snapPage {
    NSString *base = NSProcessInfo.processInfo.environment[@"OV_TRAINING_SNAP"];
    if (!base.length || ![self.view isKindOfClass:NSScrollView.class]) return;
    static int n;
    NSView *doc = ((NSScrollView *)self.view).documentView;
    NSBitmapImageRep *rep = [doc bitmapImageRepForCachingDisplayInRect:doc.bounds];
    [doc cacheDisplayInRect:doc.bounds toBitmapImageRep:rep];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[NSString stringWithFormat:@"%@-%d.png", base, n++] atomically:YES];
}

- (void)tick:(NSTimer *)t {
    static int ticks;
    if (NSProcessInfo.processInfo.environment[@"OV_TRAINING_SNAP"].length && ticks++ % 10 == 0) [self snapPage];
    if ([NSProcessInfo.processInfo.environment[@"OV_TRAINING_AUTOCHECK"] boolValue] && !self.reviewJob && self.entries.count && self.mainReady && ticks > 2) [self checkDataset:nil];
    if (self.job.active) { [self refreshProgress]; }
    else [self updateBatchAdvice];
}

#pragma mark - Enabling

- (BOOL)running { return self.job.active; }

/// Why Start is not possible now, or nil.
- (NSString *)startBlocker {
    NSString *slug = [self currentSlug];
    if (!slug.length) return L(@"Name the voice first.");
    if (!self.entries.count) return L(@"Add recordings first.");
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *model = [[OVPaths.rvcModels stringByAppendingPathComponent:slug] stringByAppendingPathComponent:[slug stringByAppendingString:@".pth"]];
    if ([fm fileExistsAtPath:model]) return [NSString stringWithFormat:L(@"A voice named %@ already exists in Models. Pick another name, or continue it from the list below."), slug];
    for (NSDictionary *r in self.runs)
        if ([r[@"name"] isEqual:slug] && ([r[@"has_checkpoints"] boolValue] || [r[@"epochs"] integerValue] > 0))
            return [NSString stringWithFormat:L(@"%@ already has training progress. Continue it from the list below, or pick another name."), slug];
    if (self.f0Seg.selectedIndex == 2 && ![self fcpeReady]) return L(@"fcpe needs its download. Install it in Models, or pick another pitch extraction.");
    return nil;
}

- (BOOL)fcpeReady { return [OVEngines.shared componentWithId:@"rvc-fcpe"].state == OVEngineReady; }

- (void)updateEnabled {
    BOOL on = self.mainReady;
    SetTreeEnabled(self.body, on);
    self.body.alphaValue = on ? 1 : 0.5;
    NSInteger k = [self sampleRateK];
    for (NSNumber *n in self.rateGates) self.rateGates[n].hidden = n.integerValue != k;
    BOOL rateOk = [self.rateReady[@(k)] boolValue];
    NSString *block = [self startBlocker];
    BOOL running = self.running;
    self.startButton.enabled = on && rateOk && !running && !block && !self.reviewJob.active;
    self.checkButton.enabled = on && !running && !self.reviewJob.active && self.entries.count > 0 && [self currentSlug].length > 0;
    self.stopButton.enabled = running;
    self.nameField.enabled = on && !self.ownedFolder;
    self.startNote.stringValue = block && on ? block : (!rateOk && on ? L(@"Install the training base for this sample rate first.") : @"");
    self.startNote.hidden = !self.startNote.stringValue.length || (self.entries.count == 0 && ![self currentSlug].length);
    if (!self.startNote.hidden && !block) self.startNote.textColor = OVColor(OVRoleMuted); else self.startNote.textColor = OVColor(OVRoleWarn);
    self.removeFlaggedButton.enabled = on && !running;
    self.sourceMode.enabled = on;
}

#pragma mark - Dataset

- (NSString *)currentSlug {
    NSString *s = [OVTrainingModel slugForName:self.nameField.stringValue changed:NULL];
    return [OVTrainingModel isValidSlug:s] ? s : nil;
}

- (void)controlTextDidChange:(NSNotification *)n {
    if (n.object != self.nameField) return;
    BOOL changed = NO;
    NSString *s = [OVTrainingModel slugForName:self.nameField.stringValue changed:&changed];
    if (self.nameField.stringValue.length && ![s length]) {
        self.nameNote.stringValue = L(@"Use letters or numbers in the name.");
        self.nameNote.hidden = NO;
    } else if (changed && s.length) {
        self.nameNote.stringValue = [NSString stringWithFormat:L(@"It will be saved as %@."), s];
        self.nameNote.hidden = NO;
    } else self.nameNote.hidden = YES;
    [self updateEnabled];
}

- (void)sourceModeChanged:(id)sender {
    NSInteger m = self.sourceMode.selectedIndex;
    self.filesPane.hidden = m != 0;
    self.folderPane.hidden = m != 1;
    self.youtubePane.hidden = m != 2;
}

- (double)totalSeconds {
    double t = 0;
    for (NSDictionary *e in self.entries) t += [e[@"duration"] doubleValue];
    return t;
}

- (void)addURLs:(NSArray<NSURL *> *)urls {
    if (!self.mainReady) return;
    NSMutableArray<NSURL *> *found = [NSMutableArray array];
    for (NSURL *u in urls) {
        NSNumber *dir;
        [u getResourceValue:&dir forKey:NSURLIsDirectoryKey error:nil];
        if (dir.boolValue) [found addObjectsFromArray:[OVTrainingModel audioFilesInFolder:u limit:kMaxFiles]];
        else if ([[OVTrainingModel datasetExtensions] containsObject:u.pathExtension.lowercaseString]) [found addObject:u];
    }
    [self addFiles:found];
}

- (void)addFiles:(NSArray<NSURL *> *)found {
    NSMutableSet *have = [NSMutableSet set];
    for (NSDictionary *e in self.entries) [have addObject:e[@"path"]];
    NSMutableArray *fresh = [NSMutableArray array];
    for (NSURL *u in found) {
        NSString *p = u.path.stringByStandardizingPath;
        if ([have containsObject:p] || self.entries.count + fresh.count >= kMaxFiles) continue;
        [have addObject:p];
        NSMutableDictionary *e = [@{@"path": p} mutableCopy];
        [fresh addObject:e];
    }
    if (!fresh.count) return;
    [self.entries addObjectsFromArray:fresh];
    [self datasetChanged];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (NSMutableDictionary *e in fresh) {
            double s = AudioSeconds([NSURL fileURLWithPath:e[@"path"]]);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![self.entries containsObject:e]) return;
                e[@"duration"] = @(s);
                [self datasetChanged];
            });
        }
    });
}

/// The list, the total, the recommendation and the buttons follow the entries; a report of the old set is dropped.
- (void)datasetChanged {
    [self rebuildList];
    if (!self.epochsTouched && self.totalSeconds > 0) self.epochsRow.value = [OVTrainingModel recommendedEpochsForSeconds:self.totalSeconds];
    [self updateEpochHint];
    [self updateEnabled];
}

- (void)rebuildList {
    for (NSView *v in self.listStack.arrangedSubviews.copy) { [self.listStack removeArrangedSubview:v]; [v removeFromSuperview]; }
    NSUInteger shown = MIN(self.entries.count, kShownRows);
    for (NSUInteger i = 0; i < shown; i++) {
        NSDictionary *e = self.entries[i];
        NSTextField *name = OVLabel([e[@"path"] lastPathComponent], 13, NSFontWeightRegular, nil);
        name.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [name setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        name.toolTip = e[@"path"];
        NSTextField *dur = OVLabel([OVTrainingModel clockLabel:[e[@"duration"] doubleValue]], 13, NSFontWeightRegular, OVColor(OVRoleMuted));
        dur.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
        NSButton *rm = OVIconButton(@"xmark", [NSString stringWithFormat:L(@"Remove %@"), [e[@"path"] lastPathComponent]], self, @selector(removeRow:));
        rm.tag = (NSInteger)i;
        NSStackView *row = OVHStack(@[name, OVSpacer(), dur, rm], 10);
        [self.listStack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.listStack.widthAnchor].active = YES;
    }
    if (self.entries.count > shown) {
        NSTextField *more = OVLabel([NSString stringWithFormat:L(@"and %ld more files"), (long)(self.entries.count - shown)], 13, NSFontWeightRegular, OVColor(OVRoleMuted));
        [self.listStack addArrangedSubview:more];
    }
    double total = self.totalSeconds;
    self.summaryLabel.stringValue = self.entries.count
        ? [NSString stringWithFormat:L(@"%ld files · %@"), (long)self.entries.count, [OVTrainingModel durationLabel:total]]
        : L(@"No recordings yet.");
    self.clearButton.hidden = !self.entries.count;
    self.report = nil;
    [self showReport];
}

- (void)removeRow:(NSButton *)b {
    NSInteger i = b.tag;
    if (i < 0 || (NSUInteger)i >= self.entries.count) return;
    NSString *p = self.entries[(NSUInteger)i][@"path"];
    [self.entries removeObjectAtIndex:(NSUInteger)i];
    if (self.ownedFolder && [p hasPrefix:[self.ownedFolder stringByAppendingString:@"/"]])
        [NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:p] resultingItemURL:nil error:nil];   // our own copy
    [self datasetChanged];
}

- (void)clearList:(id)sender {
    if (self.ownedFolder) {
        for (NSDictionary *e in self.entries)
            if ([e[@"path"] hasPrefix:[self.ownedFolder stringByAppendingString:@"/"]])
                [NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:e[@"path"]] resultingItemURL:nil error:nil];
        self.ownedFolder = nil;
    }
    [self.entries removeAllObjects];
    [self datasetChanged];
}

/// Copies the files that are not yet inside rvc/datasets/<name>/ there (never moves them) and points the entries at the copies.
- (NSString *)materializeDataset:(NSString **)error {
    NSString *slug = [self currentSlug];
    if (!slug) { if (error) *error = L(@"Name the voice first."); return nil; }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *folder = [OVPaths.rvcDatasets stringByAppendingPathComponent:slug];
    NSString *prefix = [folder stringByAppendingString:@"/"];
    BOOL usesFolder = NO;
    for (NSDictionary *e in self.entries) if ([e[@"path"] hasPrefix:prefix]) usesFolder = YES;
    if ([fm fileExistsAtPath:folder] && !usesFolder && ![self.ownedFolder isEqualToString:folder])
        [fm trashItemAtURL:[NSURL fileURLWithPath:folder] resultingItemURL:nil error:nil];   // an old dataset of this name: to the Trash, not deleted
    NSError *e = nil;
    if (![fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&e]) {
        if (error) *error = [NSString stringWithFormat:L(@"The dataset folder could not be created: %@"), e.localizedDescription];
        return nil;
    }
    self.ownedFolder = folder;
    for (NSMutableDictionary *entry in self.entries) {
        NSString *src = entry[@"path"];
        if ([src hasPrefix:prefix]) continue;
        NSString *base = src.lastPathComponent, *dst = [folder stringByAppendingPathComponent:base];
        for (int n = 2; [fm fileExistsAtPath:dst]; n++)
            dst = [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%d.%@", base.stringByDeletingPathExtension, n, base.pathExtension]];
        if (![fm copyItemAtPath:src toPath:dst error:&e]) {
            if (error) *error = [NSString stringWithFormat:L(@"%@ could not be copied: %@"), base, e.localizedDescription];
            return nil;
        }
        entry[@"path"] = dst;
    }
    return folder;
}

- (void)importYouTube:(id)sender {
    NSString *err = nil;
    if (![self currentSlug]) { [self alert:L(@"Name the voice first") text:L(@"The downloaded sound is saved into the dataset of this voice.")]; return; }
    NSString *folder = [self materializeDataset:&err];
    if (!folder) { [self alert:L(@"Can’t prepare the dataset") text:err]; return; }
    [self rebuildList];
    [OVYouTubeSheet presentOnWindow:self.view.window destinationDirectory:folder completion:^(NSURL *file) {
        if (file) [self addFiles:@[file]];
        [self updateEnabled];
    }];
    [self updateEnabled];
}

- (void)alert:(NSString *)title text:(NSString *)text {
    NSAlert *a = [NSAlert new];
    a.messageText = title;
    a.informativeText = text ?: @"";
    [a addButtonWithTitle:L(@"OK")];
    if (self.view.window) [a beginSheetModalForWindow:self.view.window completionHandler:nil]; else [a runModal];
}

#pragma mark - Dataset check

- (void)checkDataset:(id)sender {
    NSString *err = nil;
    NSString *folder = [self materializeDataset:&err];
    if (!folder) { [self alert:L(@"Can’t check the dataset") text:err]; return; }
    [self rebuildList];
    self.checkStatus.stringValue = L(@"Checking the recordings…");
    self.checkBar.hidden = NO;
    self.checkBar.doubleValue = 0;
    self.checkButton.enabled = NO;
    [OVProRun submitKind:OVProKindRvcReview request:@{@"folder": folder} feature:L(@"Dataset check") window:self.view.window network:(OVNetFeature)-1
              completion:^(OVJob *job, NSString *error) {
        if (!job) {
            self.checkBar.hidden = YES;
            self.checkStatus.stringValue = error ?: L(@"Nothing was checked.");
            [self updateEnabled];
            return;
        }
        self.reviewJob = job;
        [self updateEnabled];
    }];
}

- (void)showReport {
    for (NSView *v in self.issuesStack.arrangedSubviews.copy) { [self.issuesStack removeArrangedSubview:v]; [v removeFromSuperview]; }
    for (NSView *v in self.verdictHost.subviews.copy) [v removeFromSuperview];
    self.removeFlaggedButton.hidden = YES;
    self.levelLabel.hidden = YES;
    if (!self.report) {
        if (!self.reviewJob.active) self.checkStatus.stringValue = L(@"Looks for silence, long pauses, clipping, loudness jumps, duplicates and too little speech.");
        return;
    }
    NSString *verdict = self.report[@"verdict"];
    NSString *tone = [OVTrainingModel toneForVerdict:verdict];
    OVRole role = [tone isEqual:@"ok"] ? OVRoleOK : [tone isEqual:@"err"] ? OVRoleErr : OVRoleWarn;
    NSString *label = [tone isEqual:@"ok"] ? L(@"Good dataset") : [tone isEqual:@"err"] ? L(@"Weak dataset") : L(@"Usable, with notes");
    NSView *badge = OVBadge(label, role);
    [self.verdictHost addSubview:badge];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[[badge.leadingAnchor constraintEqualToAnchor:self.verdictHost.leadingAnchor],
                                              [badge.topAnchor constraintEqualToAnchor:self.verdictHost.topAnchor],
                                              [badge.bottomAnchor constraintEqualToAnchor:self.verdictHost.bottomAnchor]]];
    self.checkStatus.stringValue = [NSString stringWithFormat:L(@"%ld files · %@"), (long)[self.report[@"files"] count], [OVTrainingModel durationLabel:[self.report[@"total_s"] doubleValue]]];
    NSArray *issues = [OVTrainingModel issuesForReport:self.report];
    if (!issues.count) {
        [self.issuesStack addArrangedSubview:OVWrapLabel(L(@"Nothing to fix. The recordings are ready for training."), 14, OVColor(OVRoleText))];
    }
    for (NSDictionary *i in issues) {
        NSTextField *t = OVWrapLabel(i[@"text"], 14, OVColor(OVRoleText));
        NSImageView *dot = OVSymbol(@"exclamationmark.circle", 14, OVColor(OVRoleWarn));
        NSStackView *row = OVHStack(@[dot, t], 8);
        row.alignment = NSLayoutAttributeTop;
        [self.issuesStack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.issuesStack.widthAnchor].active = YES;
    }
    NSString *levels = [OVTrainingModel levelSummaryForReport:self.report];
    self.levelLabel.stringValue = levels ?: @"";
    self.levelLabel.hidden = !levels.length;
    NSUInteger removable = [OVTrainingModel removableFilesInReport:self.report].count;
    self.removeFlaggedButton.hidden = removable == 0;
    self.removeFlaggedButton.title = removable ? [NSString stringWithFormat:L(@"Remove flagged files (%ld)"), (long)removable] : L(@"Remove flagged files");
}

- (void)removeFlagged:(id)sender {
    NSArray<NSString *> *names = [OVTrainingModel removableFilesInReport:self.report];
    if (!names.count) return;
    NSSet *set = [NSSet setWithArray:names];
    NSInteger removed = 0;
    for (NSMutableDictionary *e in self.entries.copy) {
        if (![set containsObject:[e[@"path"] lastPathComponent]]) continue;
        // only the dataset's own copies are touched, and they go to the Trash
        if (self.ownedFolder && [e[@"path"] hasPrefix:[self.ownedFolder stringByAppendingString:@"/"]]) {
            [NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:e[@"path"]] resultingItemURL:nil error:nil];
            [self.entries removeObject:e];
            removed++;
        }
    }
    [self datasetChanged];
    self.checkStatus.stringValue = [NSString stringWithFormat:L(@"Moved %ld files to the Trash. Check the dataset again."), (long)removed];
}

#pragma mark - Settings

- (void)rateChanged:(id)sender { [self updateEnabled]; }

- (void)f0Changed:(id)sender {
    self.f0Hint.stringValue = self.f0Seg.selectedIndex == 2 && ![self fcpeReady] ? L(@"fcpe needs its download, which isn’t installed.") : @"";
    [self updateEnabled];
}

- (void)updateEpochHint {
    double t = self.totalSeconds;
    self.epochsHint.stringValue = t > 0
        ? [NSString stringWithFormat:L(@"Suggested for %@ of audio: %ld. More epochs take longer and can overtrain a small dataset."), [OVTrainingModel durationLabel:t], (long)[OVTrainingModel recommendedEpochsForSeconds:t]]
        : L(@"Add recordings and a length is suggested.");
}

- (void)batchChanged:(id)sender { self.batchTouched = YES; [self updateBatchAdvice]; }

/// Batch 4 peaks at about 10 GB. When the Mac has less than that free (counting what unloading OmniVoice gives back) batch 2 is
/// selected for the user, with the numbers; a choice the user made is left alone.
- (void)updateBatchAdvice {
    OVEngines *eng = OVEngines.shared;
    unsigned long long p4 = [eng peakBytesForKind:OVProKindRvcTrain option:nil], p2 = [eng peakBytesForKind:OVProKindRvcTrain option:@"batch2"];
    unsigned long long reclaim = OVWorker.shared.engineFootprint, avail = [OVMemory availableBytes] + (reclaim > 380000000ULL ? reclaim - 380000000ULL : 0);
    BOOL tight = avail < [OVProRunPlan needForPeak:p4];
    if (!self.batchTouched && !self.running) self.batchSeg.selectedIndex = tight ? 0 : 1;
    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:L(@"Batch 4 needs about %@, batch 2 about %@ and trains slower. Free memory now: %@."), GB(p4), GB(p2), GB(avail)]];
    if (self.batchSeg.selectedIndex == 0 && tight && !self.batchTouched)
        [lines addObject:L(@"Not much memory is free, so batch 2 is selected.")];
    if (self.batchSeg.selectedIndex == 2) [lines addObject:L(@"Batch 8 needs more than 16 GB free; on this Mac batch 4 is used instead.")];
    self.batchHint.stringValue = [lines componentsJoinedByString:@" "];
}

- (NSInteger)effectiveBatch {
    NSInteger sel = self.batchSeg.selectedIndex;
    if (sel == 0) return 2;
    if (sel == 2 && [OVSettings physicalMemoryGB] > 16.5) return 8;
    return 4;
}

#pragma mark - Start

- (NSDictionary *)requestForName:(NSString *)name dataset:(NSString *)dataset resume:(BOOL)resume total:(NSInteger)total settings:(NSDictionary *)s {
    NSMutableDictionary *r = [@{
        @"name": name, @"dataset": dataset ?: @"", @"sample_rate": s[@"sample_rate"], @"total_epoch": @(total),
        @"save_every_epoch": @(MIN(MAX(1, [s[@"save_every"] integerValue]), MAX(1, total))), @"f0_method": s[@"f0"], @"embedder": s[@"embedder"],
        @"index_algorithm": s[@"index"], @"batch_size": s[@"batch"], @"training_dir": OVPaths.rvcTraining, @"models_dir": OVPaths.rvcModels,
        @"resume": @(resume), @"overwrite": @(resume || [s[@"overwrite"] boolValue]),
    } mutableCopy];
    if (!resume) r[@"steps"] = @[@"preprocess", @"extract", @"train", @"index", @"export"];
    return r;
}

- (NSDictionary *)currentSettings {
    return @{@"sample_rate": @([self sampleRateK] * 1000), @"save_every": @((NSInteger)self.saveRow.value), @"f0": @[@"rmvpe", @"crepe", @"fcpe"][MAX(0, self.f0Seg.selectedIndex)],
             @"embedder": self.embedderPopup.titleOfSelectedItem ?: @"contentvec", @"index": self.indexPopup.titleOfSelectedItem ?: @"Auto",
             @"batch": @([self effectiveBatch]), @"keep": @(self.keepSwitch.on), @"total": @((NSInteger)self.epochsRow.value)};
}

- (void)startTraining:(id)sender {
    NSString *block = [self startBlocker];
    if (block) { [self alert:L(@"Can’t start yet") text:block]; return; }
    NSString *err = nil;
    NSString *folder = [self materializeDataset:&err];
    if (!folder) { [self alert:L(@"Can’t prepare the dataset") text:err]; return; }
    [self rebuildList];
    NSString *slug = [self currentSlug];
    NSDictionary *s = [self currentSettings];
    NSInteger total = [s[@"total"] integerValue];
    // the settings travel with the run so that "Continue" uses the same ones
    NSString *exp = [OVPaths.rvcTraining stringByAppendingPathComponent:slug];
    [NSFileManager.defaultManager createDirectoryAtPath:exp withIntermediateDirectories:YES attributes:nil error:nil];
    [self writeRunInfo:s name:slug];
    [self submitRequest:[self requestForName:slug dataset:folder resume:NO total:total settings:s] name:slug settings:s];
}

- (void)writeRunInfo:(NSDictionary *)s name:(NSString *)name {
    NSString *p = [[OVPaths.rvcTraining stringByAppendingPathComponent:name] stringByAppendingPathComponent:@".cns-run.json"];
    NSData *d = [NSJSONSerialization dataWithJSONObject:s options:0 error:nil];
    [d writeToFile:p atomically:YES];
    [NSFileManager.defaultManager removeItemAtPath:[[OVPaths.rvcTraining stringByAppendingPathComponent:name] stringByAppendingPathComponent:[OVTrainingModel completeMarkerName]] error:nil];
}

- (void)submitRequest:(NSDictionary *)req name:(NSString *)name settings:(NSDictionary *)s {
    self.startButton.enabled = NO;
    [OVProRun submitKind:OVProKindRvcTrain request:req feature:L(@"Training") window:self.view.window network:(OVNetFeature)-1
              completion:^(OVJob *job, NSString *error) {
        if (!job) {
            if (error) [self alert:L(@"Training didn’t start") text:error];
            [self updateEnabled];
            return;
        }
        self.job = job;
        self.jobName = name;
        self.jobSettings = s;
        self.useBestEpoch = [req[@"use_epoch"] integerValue];
        self.progressNote.hidden = YES;
        if ([req[@"batch_size"] integerValue] == 4 && [job.request[@"batch_size"] integerValue] == 2) {
            self.progressNote.stringValue = L(@"Memory was low, so training runs with batch 2 (slower, about 8 GB).");
            self.progressNote.hidden = NO;
        }
        self.chart.values = @[];
        self.chart.bestEpoch = 0;
        self.progressCard.hidden = NO;
        [self refreshProgress];
        [self updateEnabled];
    }];
}

#pragma mark - Progress

- (void)adoptRunningJob {
    if (self.job.active) return;
    for (OVJob *j in OVJobs.shared.all) {
        if (!j.active) continue;
        if ([j.kind isEqualToString:OVProKindRvcTrain]) {
            self.job = j;
            self.jobName = j.request[@"name"];
            self.progressCard.hidden = NO;
            [self refreshProgress];
            [self updateEnabled];
            return;
        }
    }
}

- (NSString *)jobLog { return self.job ? [self.job logText] : @""; }

- (void)refreshProgress {
    OVJob *job = self.job;
    if (!job) return;
    NSDictionary *p = [OVTrainingModel progressFromLog:[job logText]];
    NSInteger epoch = [p[@"epoch"] integerValue], total = [job.request[@"total_epoch"] integerValue];
    double spe = [p[@"seconds_per_epoch"] doubleValue];
    BOOL training = epoch > 0;
    self.progressTitle.stringValue = [self progressTitleForJob:job epoch:epoch total:total step:[p[@"step"] integerValue]];
    if (job.state == OVJobRunning || job.state == OVJobQueued) {
        self.progressBar.indeterminate = job.progress < 0 || job.state == OVJobQueued;
        if (self.progressBar.indeterminate) [self.progressBar startAnimation:nil]; else { [self.progressBar stopAnimation:nil]; self.progressBar.doubleValue = job.progress; }
    } else { self.progressBar.indeterminate = NO; self.progressBar.doubleValue = job.state == OVJobSucceeded ? 1 : MAX(0, job.progress); }
    NSMutableArray *bits = [NSMutableArray array];
    if (job.state == OVJobQueued) [bits addObject:L(@"Waiting for the other task to finish")];
    else if (training && spe > 0 && total > epoch && job.active) [bits addObject:[NSString stringWithFormat:L(@"%@ left (%ld s per epoch)"), [OVTrainingModel etaLabelForSeconds:spe * (total - epoch)], (long)spe]];
    else if (job.status.length && job.active) [bits addObject:job.status];
    self.progressDetail.stringValue = [bits componentsJoinedByString:@" · "];
    unsigned long long avail = [OVMemory availableBytes];
    self.memoryLabel.stringValue = [NSString stringWithFormat:L(@"Memory: %@ free · training peaks near %@"), GB(avail),
                                    GB([OVEngines.shared peakBytesForKind:OVProKindRvcTrain option:[OVEngines peakOptionForKind:OVProKindRvcTrain request:job.request]])];
    // detector
    NSString *state = p[@"state"];
    NSInteger best = [p[@"best_epoch"] integerValue];
    for (NSView *v in self.detectorHost.subviews.copy) [v removeFromSuperview];
    if (training || job.state == OVJobSucceeded) {
        NSString *text = [state isEqual:@"plateau"] ? L(@"Plateau") : [state isEqual:@"overtrained"] ? L(@"Overtraining") : L(@"Improving");
        OVRole role = [state isEqual:@"plateau"] ? OVRoleWarn : [state isEqual:@"overtrained"] ? OVRoleErr : OVRoleOK;
        NSView *badge = OVBadge(text, role);
        badge.translatesAutoresizingMaskIntoConstraints = NO;
        [self.detectorHost addSubview:badge];
        [NSLayoutConstraint activateConstraints:@[[badge.leadingAnchor constraintEqualToAnchor:self.detectorHost.leadingAnchor],
                                                  [badge.topAnchor constraintEqualToAnchor:self.detectorHost.topAnchor],
                                                  [badge.bottomAnchor constraintEqualToAnchor:self.detectorHost.bottomAnchor],
                                                  [badge.trailingAnchor constraintEqualToAnchor:self.detectorHost.trailingAnchor]]];
    }
    BOOL offer = job.active && ![state isEqual:@"improving"] && best > 0;
    self.useBestButton.hidden = !offer;
    if (offer) self.useBestButton.title = [NSString stringWithFormat:L(@"Stop and use best epoch (%ld)"), (long)best];
    self.useBestButton.enabled = offer && self.useBestEpoch == 0;
    self.stopButton.enabled = job.active;
    self.chart.bestEpoch = [state isEqual:@"improving"] ? 0 : best;
    [self loadChart];
}

- (NSString *)progressTitleForJob:(OVJob *)job epoch:(NSInteger)epoch total:(NSInteger)total step:(NSInteger)step {
    switch (job.state) {
        case OVJobSucceeded: return [NSString stringWithFormat:L(@"%@ is ready"), self.jobName ?: L(@"The voice")];
        case OVJobStopped: return L(@"Stopped");
        case OVJobFailed: return L(@"Training failed");
        case OVJobInterrupted: return L(@"Interrupted");
        default: break;
    }
    if (epoch > 0) return [NSString stringWithFormat:L(@"Epoch %ld of %ld · step %ld"), (long)epoch, (long)total, (long)step];
    return job.status.length ? job.status : L(@"Starting…");
}

/// Mel loss per epoch from the TensorBoard events Applio writes (read on a background queue, once per tick).
- (void)loadChart {
    NSString *name = self.jobName;
    if (!name.length) return;
    NSString *dir = [[OVPaths.rvcTraining stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"eval"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *pts = [OVTrainingModel scalarsInEventsFolder:dir tag:@"loss/g/mel"];
        NSMutableArray *vals = [NSMutableArray array];
        for (NSArray *p in pts) [vals addObject:p[1]];
        dispatch_async(dispatch_get_main_queue(), ^{ if ([name isEqualToString:self.jobName] && vals.count >= self.chart.values.count) self.chart.values = vals; });
    });
}

- (void)stopTraining:(id)sender {
    if (self.job.active) [OVJobs.shared stop:self.job];
}

- (void)stopUseBest:(id)sender {
    NSDictionary *p = [OVTrainingModel progressFromLog:[self.job logText]];
    NSInteger best = [p[@"best_epoch"] integerValue];
    if (!self.job.active || best <= 0) return;
    self.useBestEpoch = best;
    self.useBestButton.enabled = NO;
    self.progressDetail.stringValue = [NSString stringWithFormat:L(@"Stopping, then saving epoch %ld as the voice…"), (long)best];
    [OVJobs.shared stop:self.job];
}

#pragma mark - Jobs

- (void)jobsChanged:(NSNotification *)n {
    OVJob *job = n.object;
    if (![job isKindOfClass:OVJob.class]) { [self refreshProgress]; return; }
    if (job == self.reviewJob) { [self reviewChanged:job]; return; }
    if (job != self.job) return;
    [self refreshProgress];
    if (job.active) { [self updateEnabled]; return; }
    [self trainingFinished:job];
}

- (void)reviewChanged:(OVJob *)job {
    self.checkBar.hidden = !job.active;
    if (job.active) { self.checkBar.indeterminate = NO; self.checkBar.doubleValue = MAX(0, job.progress); return; }
    self.checkBar.hidden = YES;
    if (job.state == OVJobSucceeded && [job.result[@"report"] isKindOfClass:NSDictionary.class]) {
        self.report = job.result[@"report"];
        [self showReport];
    } else {
        self.report = nil;
        [self showReport];
        self.checkStatus.stringValue = job.state == OVJobStopped ? L(@"The check was stopped.") : (job.error ?: L(@"The check failed."));
    }
    [self updateEnabled];
}

- (void)trainingFinished:(OVJob *)job {
    NSString *name = self.jobName ?: job.request[@"name"];
    NSString *exp = [OVPaths.rvcTraining stringByAppendingPathComponent:name];
    if (job.state == OVJobSucceeded) {
        NSDictionary *meta = [job.result[@"meta"] isKindOfClass:NSDictionary.class] ? job.result[@"meta"] : @{};
        NSDictionary *ot = [job.result[@"overtraining"] isKindOfClass:NSDictionary.class] ? job.result[@"overtraining"] : @{};
        NSDictionary *done = @{@"epochs": meta[@"epoch"] ?: @0, @"best_epoch": job.result[@"best_epoch"] ?: @0, @"state": ot[@"state"] ?: @"improving"};
        [[NSJSONSerialization dataWithJSONObject:done options:0 error:nil] writeToFile:[exp stringByAppendingPathComponent:[OVTrainingModel completeMarkerName]] atomically:YES];
        if (![self.jobSettings[@"keep"] boolValue]) [OVTrainingModel removeCheckpointsInFolder:exp];
        NSString *state = ot[@"state"];
        NSString *how = [state isEqual:@"plateau"] || [state isEqual:@"overtrained"]
            ? [NSString stringWithFormat:L(@"Epoch %@ was the best one and is saved."), meta[@"epoch"] ?: @"?"]
            : [NSString stringWithFormat:L(@"Trained for %@ epochs."), meta[@"epoch"] ?: @"?"];
        self.resultHeadline.stringValue = [NSString stringWithFormat:L(@"%@ is in Models. %@"), name, how];
        self.resultHeadline.hidden = NO;
        self.ownedFolder = nil;   // the name is free to change for the next voice
    } else if (job.state == OVJobStopped) {
        if (self.useBestEpoch > 0) {
            NSInteger use = self.useBestEpoch;
            self.useBestEpoch = 0;
            [self exportEpoch:use name:name];
            return;
        }
        self.progressNote.stringValue = L(@"Stopped. You can continue this voice from the list below.");
        self.progressNote.hidden = NO;
        self.ownedFolder = nil;
    } else if (job.state == OVJobFailed) {
        self.progressNote.stringValue = job.error ?: L(@"Training failed.");
        self.progressNote.hidden = NO;
        self.ownedFolder = nil;
    }
    self.useBestEpoch = 0;
    [self refreshRuns];
    [self updateEnabled];
}

/// After "Stop and use best epoch": index and export, with `use_epoch`. Nothing is trained again.
- (void)exportEpoch:(NSInteger)epoch name:(NSString *)name {
    NSMutableDictionary *s = [(self.jobSettings ?: [self currentSettings]) mutableCopy];
    NSDictionary *info = ReadJSON([[OVPaths.rvcTraining stringByAppendingPathComponent:name] stringByAppendingPathComponent:@".cns-run.json"]);
    if (info) [s addEntriesFromDictionary:info];
    NSMutableDictionary *r = [[self requestForName:name dataset:@"" resume:NO total:MAX(epoch, 1) settings:s] mutableCopy];
    r[@"steps"] = @[@"index", @"export"];
    r[@"use_epoch"] = @(epoch);
    self.progressDetail.stringValue = [NSString stringWithFormat:L(@"Saving epoch %ld as the voice…"), (long)epoch];
    [self submitRequest:r name:name settings:s];
    self.useBestEpoch = 0;
}

#pragma mark - Earlier runs

- (void)refreshRuns {
    self.runs = [OVTrainingModel savedRunsInTraining:OVPaths.rvcTraining models:OVPaths.rvcModels];
    BOOL anyDone = NO;
    for (NSDictionary *r in self.runs) if ([r[@"status"] isEqual:@"done"] && [r[@"has_checkpoints"] boolValue]) anyDone = YES;
    self.moreRow.hidden = !anyDone;
    for (NSView *v in self.runsStack.arrangedSubviews.copy) { [self.runsStack removeArrangedSubview:v]; [v removeFromSuperview]; }
    if (!self.runs.count) {
        [self.runsStack addArrangedSubview:OVWrapLabel(L(@"Trained voices and unfinished runs appear here."), 13, OVColor(OVRoleMuted))];
    }
    for (NSDictionary *r in self.runs) {
        NSView *row = [self rowForRun:r];
        [self.runsStack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.runsStack.widthAnchor].active = YES;
    }
    [self updateEnabled];
}

- (NSView *)rowForRun:(NSDictionary *)r {
    NSString *name = r[@"name"], *status = r[@"status"];
    BOOL interrupted = [status isEqual:@"interrupted"], done = [status isEqual:@"done"];
    NSTextField *title = OVLabel(name, 14, NSFontWeightSemibold, nil);
    title.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [title setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSView *badge = interrupted ? OVBadge(L(@"Interrupted — Continue"), OVRoleWarn) : done ? OVBadge(L(@"Done"), OVRoleOK) : OVBadge(L(@"Unfinished"), OVRoleMuted);
    NSString *meta = [NSString stringWithFormat:L(@"%ld epochs · %@"), (long)[r[@"epochs"] integerValue], GB([r[@"bytes"] unsignedLongLongValue])];
    NSTextField *sub = OVLabel(meta, 13, NSFontWeightRegular, OVColor(OVRoleMuted));
    NSMutableArray *buttons = [NSMutableArray array];
    BOOL job = self.running;
    if (interrupted) [buttons addObject:[self runButton:L(@"Continue") symbol:@"play.fill" action:@selector(continueRun:) name:name enabled:!job]];
    if (done && [r[@"has_model"] boolValue]) {
        [buttons addObject:[self runButton:L(@"Try in Convert") symbol:@"arrow.right.circle" action:@selector(tryRun:) name:name enabled:YES]];
        if ([r[@"has_checkpoints"] boolValue]) [buttons addObject:[self runButton:L(@"Continue training") symbol:@"plus.circle" action:@selector(continueRun:) name:name enabled:!job]];
    }
    if ([r[@"has_checkpoints"] boolValue] && !interrupted)
        [buttons addObject:[self runButton:[NSString stringWithFormat:L(@"Free %@"), GB([r[@"checkpoint_bytes"] unsignedLongLongValue])] symbol:@"trash" action:@selector(freeRun:) name:name enabled:!job]];
    [buttons addObject:[self runButton:L(@"Reveal") symbol:@"folder" action:@selector(revealRun:) name:name enabled:YES]];
    OVFlowRow *flow = [OVFlowRow new];
    [flow setItems:buttons];
    NSStackView *head = OVHStack(@[title, badge, OVSpacer(), sub], 10);
    NSView *inner = OVFillStack(@[head, flow], 8);
    OVBoxView *box = [OVBoxView boxWithFill:OVColor(OVRoleField) border:OVColor(OVRoleBorder) radius:10];
    [box addSubview:inner];
    OVPin(inner, box, NSEdgeInsetsMake(12, 14, 12, 14));
    return box;
}

- (NSButton *)runButton:(NSString *)title symbol:(NSString *)sym action:(SEL)a name:(NSString *)name enabled:(BOOL)on {
    NSButton *b = OVSmallPill(OVGhostButton(title, sym, self, a));
    b.identifier = name;
    b.enabled = on;
    b.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", title, name];
    return b;
}

- (NSDictionary *)runNamed:(NSString *)name { for (NSDictionary *r in self.runs) if ([r[@"name"] isEqual:name]) return r; return nil; }

- (void)revealRun:(NSButton *)b {
    NSString *name = b.identifier;
    NSString *model = [OVPaths.rvcModels stringByAppendingPathComponent:name];
    NSString *path = [NSFileManager.defaultManager fileExistsAtPath:model] ? model : [OVPaths.rvcTraining stringByAppendingPathComponent:name];
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:path]]];
}

- (void)tryRun:(NSButton *)b {
    NSString *name = b.identifier;
    [NSUserDefaults.standardUserDefaults setObject:name forKey:OVTrainingConvertModelKey];
    [NSNotificationCenter.defaultCenter postNotificationName:OVTrainingTryInConvertNotification object:nil userInfo:@{@"model": name}];
    OVNavigate(@"convert");
}

- (void)freeRun:(NSButton *)b {
    NSString *name = b.identifier;
    NSDictionary *r = [self runNamed:name];
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:L(@"Free %@ used by %@?"), GB([r[@"checkpoint_bytes"] unsignedLongLongValue]), name];
    a.informativeText = L(@"This deletes the files that let training continue. The voice itself and its index stay and keep working, but this voice can’t be trained further.");
    [a addButtonWithTitle:L(@"Cancel")];
    [a addButtonWithTitle:L(@"Delete")];
    void (^go)(NSModalResponse) = ^(NSModalResponse resp) {
        if (resp != NSAlertSecondButtonReturn) return;
        [OVTrainingModel removeCheckpointsInFolder:[OVPaths.rvcTraining stringByAppendingPathComponent:name]];
        [self refreshRuns];
    };
    if (self.view.window) [a beginSheetModalForWindow:self.view.window completionHandler:go]; else go([a runModal]);
}

/// "Continue" of an interrupted run goes on to its own total; "Continue training" of a finished voice adds the chosen number of epochs.
- (void)continueRun:(NSButton *)b {
    NSString *name = b.identifier;
    NSDictionary *r = [self runNamed:name];
    if (!r || self.running) return;
    NSMutableDictionary *s = [[self currentSettings] mutableCopy];
    NSDictionary *info = ReadJSON([[OVPaths.rvcTraining stringByAppendingPathComponent:name] stringByAppendingPathComponent:@".cns-run.json"]);
    if (info) [s addEntriesFromDictionary:info];
    else {
        NSDictionary *meta = ReadJSON([[[OVPaths.rvcModels stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"meta.json"] copy]);
        if (meta[@"sample_rate"]) s[@"sample_rate"] = meta[@"sample_rate"];
    }
    NSInteger reached = [r[@"epochs"] integerValue], total = [s[@"total"] integerValue];
    if ([r[@"status"] isEqual:@"done"] || total <= reached) total = reached + (NSInteger)self.moreRow.value;
    s[@"total"] = @(total);
    s[@"overwrite"] = @([r[@"has_model"] boolValue]);
    [self writeRunInfo:s name:name];
    [self submitRequest:[self requestForName:name dataset:@"" resume:YES total:total settings:s] name:name settings:s];
}

@end
