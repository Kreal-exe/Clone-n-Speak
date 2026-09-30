#import "OVPages.h"
#import "OVUI.h"
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

#pragma mark - Step card

/// One row of the setup checklist: icon, title, detail, progress, actions.
@interface OVStepView : NSStackView
@property NSImageView *icon;
@property NSProgressIndicator *spinner;
@property NSTextField *title, *detail;
@property NSProgressIndicator *bar;
@property NSStackView *actions;
@end

@implementation OVStepView
+ (instancetype)stepWithNumber:(int)n title:(NSString *)title {
    OVStepView *s = [OVStepView new];
    s.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    s.alignment = NSLayoutAttributeTop;
    s.spacing = 14;
    s.icon = OVSymbol([NSString stringWithFormat:@"%d.circle", n], 22, NSColor.tertiaryLabelColor);
    s.spinner = OVSpinner();
    s.spinner.controlSize = NSControlSizeRegular;
    NSView *iconBox = [NSView new];
    [iconBox addSubview:s.icon];
    [iconBox addSubview:s.spinner];
    s.icon.translatesAutoresizingMaskIntoConstraints = NO;
    s.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [iconBox.widthAnchor constraintEqualToConstant:28], [iconBox.heightAnchor constraintEqualToConstant:28],
        [s.icon.centerXAnchor constraintEqualToAnchor:iconBox.centerXAnchor], [s.icon.centerYAnchor constraintEqualToAnchor:iconBox.centerYAnchor],
        [s.spinner.centerXAnchor constraintEqualToAnchor:iconBox.centerXAnchor], [s.spinner.centerYAnchor constraintEqualToAnchor:iconBox.centerYAnchor],
    ]];
    s.title = OVLabel(title, 15, NSFontWeightSemibold, nil);
    s.detail = OVWrapLabel(@"", 12.5, nil);
    s.bar = OVProgressBar();
    s.bar.hidden = YES;
    s.actions = OVHStack(@[], 8);
    NSStackView *body = OVVStack(@[s.title, s.detail, s.bar, s.actions], 6);
    [body setCustomSpacing:10 afterView:s.bar];
    [s addArrangedSubview:iconBox];
    [s addArrangedSubview:body];
    s.bar.translatesAutoresizingMaskIntoConstraints = NO;
    [s.bar.widthAnchor constraintEqualToAnchor:body.widthAnchor].active = YES;
    s.detail.translatesAutoresizingMaskIntoConstraints = NO;
    [s.detail.widthAnchor constraintEqualToAnchor:body.widthAnchor].active = YES;
    return s;
}

- (void)setState:(NSString *)state {
    // state: pending | busy | done | error
    BOOL busy = [state isEqualToString:@"busy"];
    self.icon.hidden = busy;
    if (busy) [self.spinner startAnimation:nil]; else [self.spinner stopAnimation:nil];
    NSString *sym = [state isEqualToString:@"done"] ? @"checkmark.circle.fill" :
                    [state isEqualToString:@"error"] ? @"exclamationmark.triangle.fill" : nil;
    if (sym) self.icon.image = [NSImage imageWithSystemSymbolName:sym accessibilityDescription:nil];
    self.icon.contentTintColor = [state isEqualToString:@"done"] ? OVGreen() :
                                 [state isEqualToString:@"error"] ? NSColor.systemOrangeColor : NSColor.tertiaryLabelColor;
}

- (void)setButtons:(NSArray<NSView *> *)buttons {
    for (NSView *v in self.actions.arrangedSubviews.copy) [v removeFromSuperview];
    for (NSView *v in buttons) [self.actions addArrangedSubview:v];
    self.actions.hidden = buttons.count == 0;
}
@end

#pragma mark - Setup page

@interface OVSetupPage ()
@property OVStepView *engineStep, *modelStep, *asrStep;
@property NSButton *startButton;
@property NSTextView *logView;
@property int engineNumber;
@end

@implementation OVSetupPage

- (void)loadView {
    NSStackView *page = OVVStack(@[], 18);
    page.edgeInsets = NSEdgeInsetsMake(34, 40, 30, 40);

    NSTextField *title = OVTitle(L(@"Getting started"));
    NSTextField *sub = OVWrapLabel([NSString stringWithFormat:L(@"%@ speaks over 600 languages, with first-class support for Ukrainian. Models come from the Hugging Face cache (~/.cache/huggingface), shared with VoiceStudio, so anything already downloaded isn’t downloaded again. The app downloads whatever is missing on its own."), OVAppName], 13, nil);
    self.engineStep = [OVStepView stepWithNumber:1 title:L(@"OmniVoice engine (Python + Apple MLX)")];
    self.modelStep = [OVStepView stepWithNumber:2 title:L(@"Speech synthesis model")];
    self.asrStep = [OVStepView stepWithNumber:3 title:L(@"Speech recognition — optional")];

    NSStackView *steps = OVVStack(@[self.engineStep, [self separator], self.modelStep, [self separator], self.asrStep], 16);
    NSView *card = OVCard(steps, 20);
    OVFillWidth(steps.arrangedSubviews, steps);

    self.startButton = OVPrimaryButton(L(@"Get started  →"), self, @selector(start:));
    self.startButton.keyEquivalent = @"\r";

    NSTextField *logTitle = OVLabel(L(@"Installation log"), 12, NSFontWeightSemibold, NSColor.secondaryLabelColor);
    NSScrollView *logScroll = [NSTextView scrollableTextView];
    self.logView = logScroll.documentView;
    self.logView.editable = NO;
    self.logView.font = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular];
    self.logView.textColor = NSColor.secondaryLabelColor;
    self.logView.drawsBackground = NO;
    self.logView.string = OVLogText();
    logScroll.drawsBackground = NO;
    logScroll.borderType = NSNoBorder;
    NSView *logCard = OVCard(logScroll, 10);
    [logScroll.heightAnchor constraintGreaterThanOrEqualToConstant:90].active = YES;

    for (NSView *v in @[title, sub, card, OVHStack(@[self.startButton], 0), logTitle, logCard]) [page addArrangedSubview:v];
    [page setCustomSpacing:6 afterView:title];
    [page setCustomSpacing:24 afterView:card];
    [page setCustomSpacing:8 afterView:logTitle];
    OVFillWidth(@[sub, card, logCard], page);
    [logCard setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];

    NSView *root = [NSView new];
    [root addSubview:page];
    OVPin(page, root, NSEdgeInsetsZero);
    [page.widthAnchor constraintLessThanOrEqualToConstant:860].active = YES;
    self.view = root;

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(refresh) name:OVRuntimeDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refresh) name:OVModelsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(logLine:) name:OVLogBufferNotification object:nil];
    [self refresh];
}

- (NSView *)separator {
    NSBox *b = [NSBox new];
    b.boxType = NSBoxSeparator;
    return b;
}

- (void)logLine:(NSNotification *)n {
    NSTextStorage *ts = self.logView.textStorage;
    [ts appendAttributedString:[[NSAttributedString alloc] initWithString:[n.userInfo[@"line"] stringByAppendingString:@"\n"]
                                                               attributes:@{NSFontAttributeName: self.logView.font,
                                                                            NSForegroundColorAttributeName: NSColor.secondaryLabelColor}]];
    if (ts.length > 60000) [ts deleteCharactersInRange:NSMakeRange(0, ts.length - 50000)];
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
            e.detail.stringValue = L(@"Checking the OmniVoice engine…");
            [e setButtons:@[]];
            break;
        case OVRuntimeReady:
            [e setState:@"done"];
            e.detail.stringValue = [NSString stringWithFormat:@"%@ · MLX %@ · mlx-audio %@%@\n%@",
                                    rt.stepTitle.length ? rt.stepTitle : L(@"Ready"), rt.info[@"mlx"], rt.info[@"mlx_audio"],
                                    [rt.info[@"metal"] boolValue] ? @" · Apple GPU (Metal)" : L(@" · CPU only"),
                                    [rt.pythonPath stringByAbbreviatingWithTildeInPath]];
            [e setButtons:@[]];
            break;
        case OVRuntimeMissing:
            [e setState:@"pending"];
            e.detail.stringValue = [NSString stringWithFormat:
                L(@"The app downloads Python, Apple MLX and OmniVoice (about 360 MB) to %@ on its own — "
                @"no system Python or Homebrew needed."),
                [[OVPaths runtime] stringByAbbreviatingWithTildeInPath]];
            [e setButtons:@[OVPrimaryButton(L(@"Install automatically"), self, @selector(install:)),
                            OVButton(L(@"Search again"), self, @selector(redetect:)),
                            OVButton(L(@"Choose Python…"), self, @selector(choosePython:))]];
            break;
        case OVRuntimeInstalling:
            [e setState:@"busy"];
            e.detail.stringValue = rt.stepTitle;
            e.bar.hidden = NO;
            e.bar.indeterminate = rt.progress < 0;
            e.bar.doubleValue = MAX(0, rt.progress);
            [e setButtons:@[OVButton(L(@"Cancel"), self, @selector(cancelInstall:))]];
            break;
        case OVRuntimeFailed:
            [e setState:@"error"];
            e.detail.stringValue = rt.errorText ?: L(@"Installation failed");
            [e setButtons:@[OVPrimaryButton(L(@"Retry"), self, @selector(install:)),
                            OVButton(L(@"Open log"), self, @selector(openLog:))]];
            break;
    }

    [self refreshModelStep:self.modelStep kind:OVModelTTS];
    [self refreshModelStep:self.asrStep kind:OVModelASR];
    self.startButton.enabled = OVEverythingReady();
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
        s.detail.stringValue = [NSString stringWithFormat:L(@"Downloading %@: %@ of %@ · %@"), downloading.title,
                                OVFormatBytes(downloading.received), OVFormatBytes(downloading.total),
                                downloading.downloadStatus ?: @""];
        s.bar.hidden = NO;
        s.bar.indeterminate = NO;
        s.bar.doubleValue = downloading.progress;
        NSButton *stop = OVButton(L(@"Pause"), self, @selector(cancelDownload:));
        stop.identifier = downloading.repo;
        [s setButtons:@[stop]];
    } else if (sel) {
        [s setState:@"done"];
        s.detail.stringValue = [NSString stringWithFormat:L(@"%@ · in the Hugging Face cache\n%@"), sel.title,
                                [sel.localPath stringByAbbreviatingWithTildeInPath]];
        [s setButtons:@[OVButton(L(@"Other models…"), self, @selector(openModels:))]];
    } else {
        NSString *err = nil;
        for (OVModel *m in [mm modelsOfKind:kind]) if (m.error) err = m.error;
        [s setState:err ? @"error" : @"pending"];
        NSString *what = kind == OVModelTTS
            ? [NSString stringWithFormat:L(@"The model isn’t in the Hugging Face cache (%@) — the app will download it there."),
               [[OVModels hubCache] stringByAbbreviatingWithTildeInPath]]
            : L(@"Whisper fills in the sample text when cloning and checks clarity in Auto-improve mode. "
              @"If you skip it, it downloads automatically when first needed.");
        s.detail.stringValue = err ? [NSString stringWithFormat:L(@"%@\nError: %@"), what, err] : what;
        NSButton *dl = kind == OVModelTTS ? OVPrimaryButton([NSString stringWithFormat:L(@"Download %@ (%@)"), rec.title, OVFormatBytes(rec.approxBytes)], self, @selector(download:))
                                          : OVButton([NSString stringWithFormat:L(@"Download %@ (%@)"), rec.title, OVFormatBytes(rec.approxBytes)], self, @selector(download:));
        dl.identifier = rec.repo;
        [s setButtons:@[dl, OVButton(L(@"Choose another…"), self, @selector(openModels:))]];
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
