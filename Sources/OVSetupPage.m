#import "OVPages.h"
#import "OVDesign.h"
#import "OVLocale.h"
#import "OVRuntime.h"
#import "OVModels.h"
#import "OVPaths.h"
#import <AVFAudio/AVFAudio.h>

NSNotificationName const OVNavigateNotification = @"OVNavigate";
NSNotificationName const OVPlayerDidChangeNotification = @"OVPlayerDidChange";

void OVNavigate(NSString *page) {
    [NSNotificationCenter.defaultCenter postNotificationName:OVNavigateNotification object:page];
}

BOOL OVEverythingReady(void) {
    return [OVRuntime shared].state == OVRuntimeReady && [OVModels shared].ttsModel != nil;
}

#pragma mark - Player

@interface OVPlayer () <AVAudioPlayerDelegate>
@property (nullable) AVAudioPlayer *player;
@property (readwrite, nullable) NSString *currentPath;
@end

@implementation OVPlayer
+ (instancetype)shared {
    static OVPlayer *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [OVPlayer new]; });
    return s;
}
- (void)changed { [NSNotificationCenter.defaultCenter postNotificationName:OVPlayerDidChangeNotification object:self]; }
- (void)toggle:(NSString *)path {
    if ([self.currentPath isEqualToString:path]) [self pauseOrResume];
    else [self play:path];
}
- (BOOL)playing { return self.player.playing; }
- (NSTimeInterval)currentTime { return self.player.currentTime; }
- (NSTimeInterval)duration { return self.player.duration; }
- (void)pauseOrResume {
    if (!self.player) return;
    if (self.player.playing) [self.player pause]; else [self.player play];
    [self changed];
}
- (void)seek:(NSTimeInterval)t {
    self.player.currentTime = MAX(0, MIN(t, self.player.duration));
    [self changed];
}
- (void)play:(NSString *)path {
    [self.player stop];
    self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:nil];
    self.player.delegate = self;
    self.currentPath = [self.player play] ? path : nil;
    [self changed];
}
- (void)stop {
    [self.player stop];
    self.player = nil;
    self.currentPath = nil;
    [self changed];
}
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)p successfully:(BOOL)ok {
    if (p != self.player) return;
    self.player = nil;
    self.currentPath = nil;
    [self changed];
}
@end

#pragma mark - Button row

/// Buttons in a row that wraps onto further lines when the step is too narrow (long "Download <model> (size)" titles, 820 pt window).
@interface OVFlowRow : NSView
@property (nonatomic, readonly) NSArray<NSView *> *items;
- (void)setItems:(NSArray<NSView *> *)items;
@end

@implementation OVFlowRow {
    NSArray<NSView *> *_items;
    CGFloat _laidOutHeight;
}
- (BOOL)isFlipped { return YES; }
- (NSArray<NSView *> *)items { return _items ?: @[]; }
- (void)setItems:(NSArray<NSView *> *)items {
    for (NSView *v in self.subviews.copy) [v removeFromSuperview];
    _items = [items copy];
    for (NSView *v in _items) { v.translatesAutoresizingMaskIntoConstraints = YES; [self addSubview:v]; }
    [self invalidateIntrinsicContentSize];
    self.needsLayout = YES;
}
- (CGFloat)placeForWidth:(CGFloat)w apply:(BOOL)apply {
    CGFloat x = 0, y = 0, rowH = 0;
    for (NSView *v in _items) {
        NSSize sz = v.fittingSize;
        if (x > 0 && x + sz.width > w) { x = 0; y += rowH + 8; rowH = 0; }
        if (apply) v.frame = NSMakeRect(x, y, sz.width, sz.height);
        x += sz.width + 8;
        rowH = MAX(rowH, sz.height);
    }
    return y + rowH;
}
- (NSSize)intrinsicContentSize {
    CGFloat w = NSWidth(self.bounds) > 1 ? NSWidth(self.bounds) : 100000;
    return NSMakeSize(NSViewNoIntrinsicMetric, [self placeForWidth:w apply:NO]);
}
- (void)layout {
    [super layout];
    CGFloat h = [self placeForWidth:NSWidth(self.bounds) apply:YES];
    if (fabs(h - _laidOutHeight) > 0.5) { _laidOutHeight = h; [self invalidateIntrinsicContentSize]; }
}
@end

#pragma mark - Step row

/// One row of the setup checklist: numbered circle (check / spinner / warning by state), title, status badge, detail, progress, actions.
@interface OVStepView : OVBoxView
@property (nonatomic) NSInteger number;
@property (nonatomic, copy) NSString *state;   // pending | busy | done | error | optional
@property NSTextField *title, *detail, *numberLabel;
@property NSProgressIndicator *bar;
@property OVFlowRow *actions;
@property NSImageView *icon;
@property NSProgressIndicator *spinner;
@property OVBoxView *circle;
@property NSStackView *badgeSlot;
- (void)setDetail:(NSString *)text path:(nullable NSString *)path;
@end

@implementation OVStepView
+ (instancetype)stepWithNumber:(NSInteger)n title:(NSString *)title {
    OVStepView *s = [[OVStepView alloc] initWithFrame:NSZeroRect];
    s.fillColor = OVColor(OVRoleField);
    s.borderColor = OVColor(OVRoleBorder);
    s.radius = 10;
    s.borderWidth = 1;
    s.number = n;

    s.numberLabel = OVLabel([NSString stringWithFormat:@"%ld", (long)n], 14, NSFontWeightSemibold, OVColor(OVRoleMuted));
    s.circle = [OVBoxView boxWithFill:nil border:OVColor(OVRoleGhostBorder) radius:12];
    s.circle.borderWidth = 1;
    s.icon = OVSymbol(@"checkmark.circle.fill", 24, OVColor(OVRoleOK));
    s.spinner = OVSpinner();
    s.spinner.controlSize = NSControlSizeSmall;
    NSView *mark = [NSView new];
    for (NSView *v in @[s.circle, s.numberLabel, s.icon, s.spinner]) {
        [mark addSubview:v];
        v.translatesAutoresizingMaskIntoConstraints = NO;
    }
    NSMutableArray *cs = [NSMutableArray arrayWithArray:@[
        [mark.widthAnchor constraintEqualToConstant:24], [mark.heightAnchor constraintEqualToConstant:24],
        [s.circle.widthAnchor constraintEqualToConstant:24], [s.circle.heightAnchor constraintEqualToConstant:24],
        [s.icon.widthAnchor constraintEqualToConstant:24], [s.icon.heightAnchor constraintEqualToConstant:24]]];
    for (NSView *v in @[s.circle, s.numberLabel, s.icon, s.spinner]) {
        [cs addObject:[v.centerXAnchor constraintEqualToAnchor:mark.centerXAnchor]];
        [cs addObject:[v.centerYAnchor constraintEqualToAnchor:mark.centerYAnchor]];
    }
    [NSLayoutConstraint activateConstraints:cs];

    s.title = OVLabel(title, 15, NSFontWeightSemibold, nil);
    s.badgeSlot = OVHStack(@[], 0);
    NSStackView *top = OVHStack(@[mark, s.title, OVSpacer(), s.badgeSlot], 12);

    s.detail = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    s.bar = OVProgressBar();
    s.bar.hidden = YES;
    s.actions = [OVFlowRow new];
    NSStackView *body = OVVStack(@[s.detail, s.bar, s.actions], 8);
    body.edgeInsets = NSEdgeInsetsMake(0, 36, 0, 0);
    OVFillWidth(@[s.detail, s.bar, s.actions], body);

    NSStackView *col = OVVStack(@[top, body], 8);
    col.edgeInsets = NSEdgeInsetsMake(12, 12, 12, 12);
    OVFillWidth(@[top, body], col);
    [s addSubview:col];
    OVPin(col, s, NSEdgeInsetsZero);
    s.state = @"pending";
    return s;
}

- (void)setDetail:(NSString *)text path:(NSString *)path {
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineBreakMode = NSLineBreakByWordWrapping;
    ps.lineSpacing = 2;
    NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:text ?: @"" attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:13], NSForegroundColorAttributeName: OVColor(OVRoleMuted), NSParagraphStyleAttributeName: ps}];
    if (path.length) {
        [a appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n" stringByAppendingString:path] attributes:@{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName: OVColor(OVRoleMuted), NSParagraphStyleAttributeName: ps}]];
    }
    self.detail.attributedStringValue = a;
}

- (void)setState:(NSString *)state {
    _state = [state copy];
    BOOL busy = [state isEqualToString:@"busy"], done = [state isEqualToString:@"done"], err = [state isEqualToString:@"error"];
    BOOL number = !busy && !done && !err;
    self.circle.hidden = self.numberLabel.hidden = !number;
    self.icon.hidden = !(done || err);
    if (busy) [self.spinner startAnimation:nil]; else [self.spinner stopAnimation:nil];
    if (done || err) {
        self.icon.image = [NSImage imageWithSystemSymbolName:done ? @"checkmark.circle.fill" : @"exclamationmark.triangle.fill"
                                    accessibilityDescription:nil];
        self.icon.contentTintColor = OVColor(done ? OVRoleOK : OVRoleErr);
    }
    NSString *text; OVRole tone;
    if (busy) { text = L(@"In progress"); tone = OVRoleAccent; }
    else if (done) { text = L(@"Ready"); tone = OVRoleOK; }
    else if (err) { text = L(@"Failed"); tone = OVRoleErr; }
    else if ([state isEqualToString:@"optional"]) { text = L(@"Optional"); tone = OVRoleMuted; }
    else { text = L(@"Queued"); tone = OVRoleMuted; }
    for (NSView *v in self.badgeSlot.arrangedSubviews.copy) { [self.badgeSlot removeArrangedSubview:v]; [v removeFromSuperview]; }
    [self.badgeSlot addArrangedSubview:OVBadge(text, tone)];
    self.accessibilityLabel = [NSString stringWithFormat:L(@"Step %ld, %@, %@"), (long)self.number, self.title.stringValue, text];
    [self syncLook];
}

/// Waiting rows (nothing to press) are dimmed like Applio's "Queued"; the row that needs attention gets the stronger border.
- (void)syncLook {
    BOOL hasButtons = self.actions.items.count > 0;
    BOOL waiting = ([self.state isEqualToString:@"pending"] || [self.state isEqualToString:@"optional"]) && !hasButtons;
    BOOL active = [self.state isEqualToString:@"busy"] || [self.state isEqualToString:@"error"] ||
                  ([self.state isEqualToString:@"pending"] && hasButtons);
    self.alphaValue = waiting ? 0.6 : 1;
    self.borderColor = OVColor(active ? OVRoleGhostBorder : OVRoleBorder);
    self.needsDisplay = YES;
}

- (void)setButtons:(NSArray<NSView *> *)buttons {
    [self.actions setItems:buttons];
    self.actions.hidden = buttons.count == 0;
    [self syncLook];
}
@end

#pragma mark - Setup page

@interface OVSetupPage ()
@property OVStepView *engineStep, *modelStep, *asrStep;
@property NSButton *startButton;
@property NSTextView *logView;
@property OVBoxView *dot;
@property NSTextField *overallTitle, *overallCount, *keepOpen;
@property NSProgressIndicator *overallBar;
@end

@implementation OVSetupPage

- (void)loadView {
    NSString *subtitle = [NSString stringWithFormat:L(@"%@ speaks over 600 languages, with first-class support for Ukrainian. Models come from the Hugging Face cache (~/.cache/huggingface), shared with VoiceStudio, so anything already downloaded isn’t downloaded again. The app downloads whatever is missing on its own."), OVAppName];
    NSStackView *header = (NSStackView *)OVPageHeader(L(@"Getting started"), subtitle, nil);
    // the long subtitle wraps inside the column
    NSStackView *left = (NSStackView *)header.arrangedSubviews.firstObject;
    NSTextField *sub = (NSTextField *)left.arrangedSubviews.lastObject;
    sub.lineBreakMode = NSLineBreakByWordWrapping;
    sub.usesSingleLineMode = NO;
    sub.maximumNumberOfLines = 0;
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    [left setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.engineStep = [OVStepView stepWithNumber:1 title:L(@"OmniVoice engine (Python + Apple MLX)")];
    self.modelStep = [OVStepView stepWithNumber:2 title:L(@"Speech synthesis model")];
    self.asrStep = [OVStepView stepWithNumber:3 title:L(@"Speech recognition")];

    self.dot = [OVBoxView boxWithFill:OVColor(OVRoleText) border:nil radius:4];
    self.dot.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[[self.dot.widthAnchor constraintEqualToConstant:8], [self.dot.heightAnchor constraintEqualToConstant:8]]];
    self.overallTitle = OVLabel(L(@"Setup in progress"), 14, NSFontWeightSemibold, nil);
    self.overallCount = OVLabel(@"", 13, NSFontWeightRegular, OVColor(OVRoleMuted));
    NSStackView *head = OVHStack(@[self.dot, self.overallTitle, OVSpacer(), self.overallCount], 8);
    self.overallBar = OVProgressBar();
    self.keepOpen = OVWrapLabel(L(@"Keep the app open. This may take a few minutes, depending on your connection and computer."), 13, OVColor(OVRoleMuted));
    NSStackView *inner = OVVStack(@[head, self.overallBar, self.engineStep, self.modelStep, self.asrStep, self.keepOpen], 8);
    [inner setCustomSpacing:12 afterView:head];
    [inner setCustomSpacing:12 afterView:self.overallBar];
    [inner setCustomSpacing:12 afterView:self.asrStep];
    OVFillWidth(inner.arrangedSubviews, inner);
    NSView *card = OVCard(inner, 20);

    self.startButton = OVPrimaryButton(L(@"Get started  →"), self, @selector(start:));
    self.startButton.keyEquivalent = @"\r";

    NSTextView *tv = nil;
    NSScrollView *logScroll = OVLogView(&tv);
    self.logView = tv;
    [self appendLog:OVLogText()];
    [logScroll.heightAnchor constraintEqualToConstant:220].active = YES;
    OVDisclosure *details = [OVDisclosure disclosureWithTitle:L(@"Technical details & log") subtitle:nil symbol:@"terminal" content:logScroll];

    NSStackView *column = OVVStack(@[header, card, OVHStack(@[self.startButton], 0), details], 16);
    OVFillWidth(@[header, card, details], column);

    // central column: at most 584 pt wide, centred, 16 pt more under the page inset (24 + 16 = 40); narrower windows use the whole width
    NSView *holder = [NSView new];
    [holder addSubview:column];
    column.translatesAutoresizingMaskIntoConstraints = NO;
    NSLayoutConstraint *fill = [column.widthAnchor constraintEqualToAnchor:holder.widthAnchor];
    fill.priority = NSLayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [column.widthAnchor constraintLessThanOrEqualToConstant:584], fill,
        [column.centerXAnchor constraintEqualToAnchor:holder.centerXAnchor],
        [column.topAnchor constraintEqualToAnchor:holder.topAnchor constant:16], [column.bottomAnchor constraintEqualToAnchor:holder.bottomAnchor]]];

    // Scrolls when the window is shorter than the page (small displays): the page never forces the window taller.
    self.view = OVPageScroll(@[holder]);

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(refresh) name:OVRuntimeDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refresh) name:OVModelsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(logLine:) name:OVLogBufferNotification object:nil];
    [self refresh];
}

- (void)appendLog:(NSString *)text {
    NSTextStorage *ts = self.logView.textStorage;
    [ts appendAttributedString:[[NSAttributedString alloc] initWithString:text
                                                               attributes:@{NSFontAttributeName: self.logView.font,
                                                                            NSForegroundColorAttributeName: OVColor(OVRoleMuted)}]];
    if (ts.length > 60000) [ts deleteCharactersInRange:NSMakeRange(0, ts.length - 50000)];
}

- (void)logLine:(NSNotification *)n {
    [self appendLog:[n.userInfo[@"line"] stringByAppendingString:@"\n"]];
    [self.logView scrollToEndOfDocument:nil];
}

- (void)refresh {
    OVRuntime *rt = [OVRuntime shared];
    OVStepView *e = self.engineStep;
    e.bar.hidden = YES;
    switch (rt.state) {
        case OVRuntimeUnknown:
        case OVRuntimeChecking:
            [e setState:@"busy"];
            [e setDetail:L(@"Checking the OmniVoice engine…") path:nil];
            [e setButtons:@[]];
            break;
        case OVRuntimeReady:
            [e setState:@"done"];
            [e setDetail:[NSString stringWithFormat:@"%@ · MLX %@ · mlx-audio %@%@",
                          rt.stepTitle.length ? rt.stepTitle : L(@"Ready"), rt.info[@"mlx"], rt.info[@"mlx_audio"],
                          [rt.info[@"metal"] boolValue] ? @" · Apple GPU (Metal)" : L(@" · CPU only")]
                    path:[rt.pythonPath stringByAbbreviatingWithTildeInPath]];
            [e setButtons:@[]];
            break;
        case OVRuntimeMissing:
            [e setState:@"pending"];
            [e setDetail:[NSString stringWithFormat:
                L(@"The app downloads Python, Apple MLX and OmniVoice (about 360 MB) to %@ on its own — "
                @"no system Python or Homebrew needed."),
                [[OVPaths runtime] stringByAbbreviatingWithTildeInPath]] path:nil];
            [e setButtons:@[OVPrimaryButton(L(@"Install automatically"), self, @selector(install:)),
                            OVGhostButton(L(@"Search again"), nil, self, @selector(redetect:)),
                            OVGhostButton(L(@"Choose Python…"), nil, self, @selector(choosePython:))]];
            break;
        case OVRuntimeInstalling:
            [e setState:@"busy"];
            [e setDetail:rt.stepTitle path:nil];
            e.bar.hidden = NO;
            e.bar.indeterminate = rt.progress < 0;
            e.bar.doubleValue = MAX(0, rt.progress);
            if (e.bar.indeterminate) [e.bar startAnimation:nil]; else [e.bar stopAnimation:nil];
            [e setButtons:@[OVGhostButton(L(@"Cancel"), nil, self, @selector(cancelInstall:))]];
            break;
        case OVRuntimeFailed:
            [e setState:@"error"];
            [e setDetail:rt.errorText ?: L(@"Installation failed") path:nil];
            [e setButtons:@[OVPrimaryButton(L(@"Retry"), self, @selector(install:)),
                            OVGhostButton(L(@"Open log"), nil, self, @selector(openLog:))]];
            break;
    }

    [self refreshModelStep:self.modelStep kind:OVModelTTS];
    [self refreshModelStep:self.asrStep kind:OVModelASR];
    self.startButton.enabled = OVEverythingReady();
    [self refreshOverall];
}

/// Header of the progress card: dot, title, "n / 3 steps", one bar over all three steps, the keep-open note.
- (void)refreshOverall {
    NSArray<OVStepView *> *steps = @[self.engineStep, self.modelStep, self.asrStep];
    int done = 0;
    double extra = 0;
    BOOL working = NO;
    for (OVStepView *s in steps) {
        if ([s.state isEqualToString:@"done"]) done++;
        if (!s.bar.hidden && !s.bar.indeterminate) extra = MAX(extra, s.bar.doubleValue);
        if (!s.bar.hidden) working = YES;
    }
    BOOL ready = OVEverythingReady();
    self.overallTitle.stringValue = ready ? L(@"Everything is ready") : L(@"Setup in progress");
    self.dot.fillColor = OVColor(ready ? OVRoleOK : OVRoleText);
    self.dot.needsDisplay = YES;
    self.overallCount.stringValue = [NSString stringWithFormat:L(@"%d / %d steps"), done, (int)steps.count];
    BOOL indeterminate = !self.engineStep.bar.hidden && self.engineStep.bar.indeterminate;
    self.overallBar.indeterminate = indeterminate;
    self.overallBar.doubleValue = MIN(1, (done + MIN(1, extra)) / (double)steps.count);
    if (indeterminate) [self.overallBar startAnimation:nil]; else [self.overallBar stopAnimation:nil];
    self.keepOpen.hidden = !working;
}

- (void)refreshModelStep:(OVStepView *)s kind:(OVModelKind)kind {
    OVModels *mm = [OVModels shared];
    OVModel *sel = kind == OVModelTTS ? mm.ttsModel : mm.asrModel;
    OVModel *downloading = nil;
    for (OVModel *m in [mm modelsOfKind:kind]) if (m.downloading) downloading = m;
    OVModel *rec = nil;
    for (OVModel *m in [mm modelsOfKind:kind]) if (m.recommended) rec = m;
    s.bar.hidden = YES;

    if (downloading) {
        [s setState:@"busy"];
        [s setDetail:[NSString stringWithFormat:L(@"Downloading %@: %@ of %@ · %@"), downloading.title,
                      OVFormatBytes(downloading.received), OVFormatBytes(downloading.total),
                      downloading.downloadStatus ?: @""] path:nil];
        s.bar.hidden = NO;
        s.bar.indeterminate = NO;
        s.bar.doubleValue = downloading.progress;
        NSButton *stop = OVGhostButton(L(@"Pause"), nil, self, @selector(cancelDownload:));
        stop.identifier = downloading.repo;
        [s setButtons:@[stop]];
    } else if (sel) {
        [s setState:@"done"];
        [s setDetail:[NSString stringWithFormat:L(@"%@ · in the Hugging Face cache"), sel.title]
                path:[sel.localPath stringByAbbreviatingWithTildeInPath]];
        [s setButtons:@[OVGhostButton(L(@"Other models…"), nil, self, @selector(openModels:))]];
    } else {
        NSString *err = nil;
        for (OVModel *m in [mm modelsOfKind:kind]) if (m.error) err = m.error;
        [s setState:err ? @"error" : kind == OVModelASR ? @"optional" : @"pending"];
        NSString *what = kind == OVModelTTS
            ? [NSString stringWithFormat:L(@"The model isn’t in the Hugging Face cache (%@) — the app will download it there."),
               [[OVModels hubCache] stringByAbbreviatingWithTildeInPath]]
            : L(@"Whisper fills in the sample text when cloning and checks clarity in Auto-improve mode. "
              @"If you skip it, it downloads automatically when first needed.");
        [s setDetail:err ? [NSString stringWithFormat:L(@"%@\nError: %@"), what, err] : what path:nil];
        NSString *dlTitle = [NSString stringWithFormat:L(@"Download %@ (%@)"), rec.title, OVFormatBytes(rec.approxBytes)];
        NSButton *dl = kind == OVModelTTS ? OVPrimaryButton(dlTitle, self, @selector(download:))
                                          : OVGhostButton(dlTitle, nil, self, @selector(download:));
        dl.identifier = rec.repo;
        [s setButtons:@[dl, OVGhostButton(L(@"Choose another…"), nil, self, @selector(openModels:))]];
    }
}

- (void)install:(id)s { [[OVRuntime shared] install]; }
- (void)cancelInstall:(id)s { [[OVRuntime shared] cancelInstall]; }
- (void)redetect:(id)s { [[OVRuntime shared] detect]; [[OVModels shared] rescan]; }
- (void)openLog:(id)s { OVNavigate(@"log"); }
- (void)openModels:(id)s { OVNavigate(@"models"); }
- (void)start:(id)s { OVNavigate(@"synth"); }

- (void)download:(NSButton *)b {
    OVModel *m = [[OVModels shared] modelForRepo:b.identifier];
    if (m) [[OVModels shared] download:m];
}
- (void)cancelDownload:(NSButton *)b {
    OVModel *m = [[OVModels shared] modelForRepo:b.identifier];
    if (m) [[OVModels shared] cancelDownload:m];
}

- (void)choosePython:(id)s {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.message = L(@"Choose the Python interpreter from an environment where OmniVoice is installed (for example, …/.venv/bin/python)");
    p.showsHiddenFiles = YES;
    p.treatsFilePackagesAsDirectories = YES;
    if ([p runModal] != NSModalResponseOK) return;
    [OVRuntime shared].customPython = p.URL.path;
    [[OVRuntime shared] detect];
}
@end
