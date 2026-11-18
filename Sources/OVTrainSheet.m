#import "OVTrainSheet.h"
#import "OVUI.h"
#import "OVDesign.h"
#import "OVPages.h"
#import "OVLocale.h"
#import "OVModels.h"
#import "OVWorker.h"
#import "OVNativeAccent.h"
#import "OVJobs.h"

static NSInteger const kRounds = 3;
static NSString *const kOwnTakes = @"self", *const kModelNarrator = @"model";

@interface OVTrainSheet ()
@property OVVoice *voice;
@property (copy) NSString *language, *text;
@property NSPopUpButton *langPopup, *sourcePopup;
@property NSTextField *sourceNote, *status;
@property NSButton *getSeedVC, *startButton, *resetButton, *doneButton;
@property NSStackView *results;
@property NSView *seedRow;
@property NSScrollView *scroll;
@property NSView *bottomBar;
@property NSProgressIndicator *bar;
@property BOOL running;
@property (strong) OVJob *job;
@property NSMutableArray<NSDictionary *> *live;  // rounds of the training under way, as they come
@end

static OVTrainSheet *shown;  // the sheet keeps its controller alive

@implementation OVTrainSheet

+ (void)showForVoice:(OVVoice *)voice language:(NSString *)language text:(NSString *)text window:(NSWindow *)window {
    if (shown) return;
    OVTrainSheet *s = [OVTrainSheet new];
    s.voice = voice;
    s.language = language;
    s.text = text ?: @"";
    [s build];
    shown = s;
    [window beginSheet:s.window completionHandler:^(NSModalResponse r) {
        [NSNotificationCenter.defaultCenter removeObserver:shown];
        shown = nil;
    }];
    [s.window.contentView layoutSubtreeIfNeeded];
    [s fitHeight:YES];
}

- (void)build {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 500) styleMask:NSWindowStyleMaskTitled
                                                backing:NSBackingStoreBuffered defer:NO];
    NSTextField *title = OVLabel([NSString stringWithFormat:L(@"Pronunciation of “%@”"), self.voice.name], 20, NSFontWeightBold, OVColor(OVRoleText));
    NSTextField *intro = OVWrapLabel(L(@"Round by round the voice gets a new sample in this language and is judged on phrases it never learned on: pronunciation (how native Whisper finds it) and likeness to the original sample. Listen to the rounds and keep the one that sounds best."), 13, OVColor(OVRoleMuted));
    NSStackView *head = OVVStack(@[title, intro], 6);
    OVFillWidth(@[intro], head);

    self.langPopup = [OVPopup popup];
    NSMutableArray *codes = [NSMutableArray array];
    for (NSString *c in @[self.language ?: @"", self.voice.language ?: @""]) if (c.length && ![codes containsObject:c]) [codes addObject:c];
    for (NSString *c in [[OVLocale pinnedSpeechLanguages] arrayByAddingObjectsFromArray:@[@"de", @"pl", @"fr", @"es", @"it", @"pt"]])
        if (![codes containsObject:c]) [codes addObject:c];
    for (NSString *c in codes) {
        [self.langPopup addItemWithTitle:[OVLocale nameForLanguage:c]];
        self.langPopup.lastItem.representedObject = c;
    }
    self.langPopup.target = self;
    self.langPopup.action = @selector(refresh);
    self.sourcePopup = [OVPopup popup];
    self.sourcePopup.target = self;
    self.sourcePopup.action = @selector(refresh);
    self.sourceNote = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.getSeedVC = OVGhostButton(L(@"Download Seed-VC"), nil, self, @selector(downloadSeedVC:));
    self.seedRow = OVHStack(@[self.getSeedVC, OVBadge(@"2.7 GB", OVRoleMuted)], 8);
    NSStackView *source = OVVStack(@[OVColumns(@[OVFieldBlock(L(@"Language"), nil, self.langPopup),
                                                 OVFieldBlock(L(@"Learns from"), nil, self.sourcePopup)], 16),
                                     self.sourceNote, self.seedRow], 12);
    OVFillWidth(@[source.arrangedSubviews[0], self.sourceNote], source);

    self.results = OVVStack(@[], 8);
    self.bar = OVProgressBar();
    self.status = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    NSStackView *rounds = OVVStack(@[self.results, self.bar, self.status], 12);
    OVFillWidth(@[self.results, self.bar, self.status], rounds);

    self.startButton = OVPrimaryButton(L(@"Train"), self, @selector(start:));
    self.resetButton = OVGhostButton(L(@"Back to the original sample"), nil, self, @selector(reset:));
    self.doneButton = OVGhostButton(L(@"Done"), nil, self, @selector(done:));
    self.doneButton.keyEquivalent = @"\e";
    NSStackView *buttons = OVHStack(@[self.resetButton, OVSpacer(), self.doneButton, self.startButton], 10);
    buttons.edgeInsets = NSEdgeInsetsMake(14, 28, 16, 28);
    NSView *rule = [OVBoxView boxWithFill:OVColor(OVRoleBorder) border:nil radius:0];
    NSStackView *bottom = OVVStack(@[rule, buttons], 0);
    OVFillWidth(@[rule, buttons], bottom);
    [rule.heightAnchor constraintEqualToConstant:1].active = YES;
    self.bottomBar = bottom;

    self.scroll = OVPageScroll(@[head,
        OVStepCard(1, @"globe", L(@"Language & source"), nil, source),
        OVStepCard(2, @"chart.line.uptrend.xyaxis", L(@"Rounds"), nil, rounds)]);
    NSView *root = [NSView new];
    for (NSView *v in @[self.scroll, bottom]) { v.translatesAutoresizingMaskIntoConstraints = NO; [root addSubview:v]; }
    [NSLayoutConstraint activateConstraints:@[
        [root.widthAnchor constraintEqualToConstant:640],
        [self.scroll.topAnchor constraintEqualToAnchor:root.topAnchor],
        [self.scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [self.scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [self.scroll.bottomAnchor constraintEqualToAnchor:bottom.topAnchor],
        [bottom.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [bottom.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [bottom.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];
    self.window.contentView = root;
    self.window.backgroundColor = OVColor(OVRoleBackground);

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(workerEvent:) name:OVWorkerEventNotification object:nil];
    [nc addObserver:self selector:@selector(refresh) name:OVNativeAccentDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(jobChanged:) name:OVJobsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refresh) name:OVWorkerDidChangeNotification object:nil];
    [self refresh];
}

/// Window height = content, capped by the screen (minus 120 pt) and the parent window (minus 40 pt); the scroll view takes the rest.
/// Once the sheet is attached (`initial`) it is sized exactly; afterwards it only grows, so refreshes never make it jump.
- (void)fitHeight:(BOOL)initial {
    NSWindow *parent = self.window.sheetParent;
    NSScreen *screen = parent.screen ?: self.window.screen ?: NSScreen.mainScreen;
    CGFloat cap = screen.visibleFrame.size.height - 120;
    if (parent) cap = MIN(cap, parent.frame.size.height - 40);
    CGFloat docH = self.scroll.documentView.fittingSize.height, barH = self.bottomBar.fittingSize.height;
    CGFloat h = MAX(300, MIN(docH + barH, cap));
    CGFloat curH = [self.window contentRectForFrameRect:self.window.frame].size.height;
    if (!initial && h <= curH + 0.5) return;
    NSRect f = [self.window frameRectForContentRect:NSMakeRect(0, 0, 640, h)];
    NSRect cur = self.window.frame;
    f.origin = NSMakePoint(cur.origin.x, cur.origin.y + cur.size.height - f.size.height);
    if (fabs(cur.size.height - f.size.height) > 0.5) [self.window setFrame:f display:YES];
}

/// A compact "nothing yet" box for the rounds card: icon + title on one line, ~50 pt tall; fits without scrolling.
static NSView *EmptyRounds(NSString *title) {
    NSImageView *icon = OVSymbol(@"graduationcap", 22, OVColor(OVRoleMuted));
    [icon.widthAnchor constraintEqualToConstant:28].active = YES;
    [icon.heightAnchor constraintEqualToConstant:24].active = YES;
    NSTextField *t = OVLabel(title, 14, NSFontWeightSemibold, OVColor(OVRoleMuted));
    NSStackView *st = OVHStack(@[icon, t], 8);
    NSView *box = [OVBoxView boxWithFill:nil border:OVColor(OVRoleBorder) radius:10];
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:st];
    [NSLayoutConstraint activateConstraints:@[
        [st.centerXAnchor constraintEqualToAnchor:box.centerXAnchor],
        [st.topAnchor constraintEqualToAnchor:box.topAnchor constant:14],
        [st.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-14],
    ]];
    return box;
}

- (NSString *)lang { return self.langPopup.selectedItem.representedObject; }

#pragma mark State

- (void)refresh {
    [self refreshSources];
    OVNativeAccent *seedvc = [OVNativeAccent shared];
    NSString *from = self.sourcePopup.selectedItem.representedObject;
    BOOL own = [from isEqualToString:kOwnTakes];
    if (seedvc.installing)
        self.sourceNote.stringValue = [NSString stringWithFormat:L(@"Downloading Seed-VC: %.0f%% · %@"), seedvc.progress * 100, seedvc.step];
    else if (!seedvc.installed)
        self.sourceNote.stringValue = [NSString stringWithFormat:@"%@ %@", L(@"The voice learns from its own takes: that helps in another language than its sample, but an accent in the sample’s own language stays."),
                                       L(@"A native narrator removes it and needs Seed-VC.")];
    else
        self.sourceNote.stringValue = own ? L(@"The voice learns from its own takes: that helps in another language than its sample, but an accent in the sample’s own language stays.")
                                          : L(@"A native speaker reads the learning phrases and Seed-VC gives the reading this voice: the accent goes, the voice sounds a little less like the sample.");
    self.sourceNote.textColor = seedvc.error && !seedvc.installing ? OVColor(OVRoleErr) : OVColor(OVRoleMuted);
    if (seedvc.error && !seedvc.installing) self.sourceNote.stringValue = seedvc.error;
    self.seedRow.hidden = seedvc.installed || seedvc.installing;

    BOOL busy = [OVWorker shared].busy;
    self.langPopup.enabled = self.sourcePopup.enabled = !self.running;
    self.getSeedVC.enabled = !busy;
    self.startButton.title = self.running ? L(@"Stop") : L(@"Train");
    self.startButton.enabled = self.running || !busy;
    self.resetButton.enabled = !self.running && [self.voice trainingInfo:self.lang][@"trained"] != nil;
    self.doneButton.enabled = !self.running;
    self.bar.hidden = !self.running;
    [self refreshResults];
    [self.window.contentView layoutSubtreeIfNeeded];
    [self fitHeight:NO];
}

/// Own takes always; with Seed-VC the model's own voice and the user's voices in that language as narrators.
- (void)refreshSources {
    NSString *keep = self.sourcePopup.selectedItem.representedObject;
    [self.sourcePopup removeAllItems];
    [self.sourcePopup addItemWithTitle:L(@"Its own takes")];
    self.sourcePopup.lastItem.representedObject = kOwnTakes;
    if ([OVNativeAccent shared].installed) {
        [self.sourcePopup addItemWithTitle:L(@"A native narrator: the model’s own voice")];
        self.sourcePopup.lastItem.representedObject = kModelNarrator;
        for (OVVoice *v in [OVVoices shared].all) {
            if (v == self.voice || !v.ready || ![v.language isEqualToString:self.lang]) continue;
            [self.sourcePopup addItemWithTitle:[NSString stringWithFormat:L(@"A native narrator: %@"), v.name]];
            self.sourcePopup.lastItem.representedObject = v.identifier;
        }
    }
    NSInteger i = keep ? [self.sourcePopup indexOfItemWithRepresentedObject:keep] : -1;
    [self.sourcePopup selectItemAtIndex:i >= 0 ? i : self.sourcePopup.numberOfItems > 1 ? 1 : 0];
}

- (void)refreshResults {
    for (NSView *v in self.results.arrangedSubviews.copy) [v removeFromSuperview];
    NSDictionary *info = [self.voice trainingInfo:self.lang];
    NSArray *rows = self.running ? self.live : info[@"history"];
    NSInteger kept = info[@"trained"] ? [info[@"trained"][@"round"] integerValue] : 0;
    if (!rows.count) {
        NSView *empty = EmptyRounds(L(@"Not trained in this language yet."));
        [self.results addArrangedSubview:empty];
        OVFillWidth(@[empty], self.results);
        return;
    }
    for (NSDictionary *h in rows) {
        NSInteger r = [h[@"round"] integerValue];
        double pron = [h[@"pronunciation"] doubleValue], like = [h[@"likeness"] doubleValue];
        NSImageView *check = OVSymbol(@"checkmark.circle.fill", 16, OVColor(OVRoleOK));
        check.hidden = self.running || r != kept;
        check.toolTip = L(@"The voice speaks this language from this sample");
        check.accessibilityLabel = L(@"In use");
        NSTextField *name = OVLabel(r == 0 ? L(@"Original sample") : [NSString stringWithFormat:L(@"Round %ld"), (long)r], 14, NSFontWeightSemibold, OVColor(OVRoleText));
        OVRole tone = pron * 100 >= 85 ? OVRoleOK : pron * 100 >= 60 ? OVRoleWarn : OVRoleErr;
        NSView *pronBadge = OVBadge([NSString stringWithFormat:L(@"pronunciation %.0f%%"), pron * 100], tone);
        NSView *likeBadge = OVBadge([NSString stringWithFormat:L(@"likeness %.0f%%"), like * 100], OVRoleMuted);
        NSButton *play = OVPlayButton(self, @selector(listen:));
        [play.widthAnchor constraintEqualToConstant:28].active = YES;
        [play.heightAnchor constraintEqualToConstant:28].active = YES;
        play.tag = r;
        play.toolTip = L(@"Listen");
        play.accessibilityLabel = L(@"Listen");
        play.hidden = ![NSFileManager.defaultManager fileExistsAtPath:[self samplePath:r]];
        NSButton *use = OVGhostButton(L(@"Use"), nil, self, @selector(useRound:));
        use.tag = r;
        use.hidden = self.running || r == kept || (r > 0 && play.hidden);
        NSStackView *line = OVHStack(@[check, name, pronBadge, likeBadge, OVSpacer(), play, use], 8);
        line.edgeInsets = NSEdgeInsetsMake(10, 12, 10, 12);
        NSView *box = [OVBoxView boxWithFill:OVColor(OVRoleField) border:OVColor(OVRoleBorder) radius:10];
        line.translatesAutoresizingMaskIntoConstraints = NO;
        [box addSubview:line];
        OVPin(line, box, NSEdgeInsetsZero);
        [self.results addArrangedSubview:box];
        OVFillWidth(@[box], self.results);
    }
}

- (NSString *)samplePath:(NSInteger)round {
    return round == 0 ? self.voice.referencePath
                      : [NSString stringWithFormat:@"%@.r%ld.wav", [self.voice trainingBase:self.lang], (long)round];
}

#pragma mark Actions

- (void)listen:(NSButton *)b { [[OVPlayer shared] toggle:[self samplePath:b.tag]]; }

- (void)useRound:(NSButton *)b {
    if (b.tag == 0) [self.voice forgetTraining:self.lang];
    else [self.voice useTrainingRound:b.tag language:self.lang];
    self.status.stringValue = b.tag == 0 ? L(@"The voice speaks this language from its original sample again.")
                                         : [NSString stringWithFormat:L(@"The voice now speaks this language from round %ld."), (long)b.tag];
    [self refresh];
}

- (void)reset:(id)s { [self useRound:[NSButton new]]; }

- (void)done:(id)s {
    [[OVPlayer shared] stop];
    [self.window.sheetParent endSheet:self.window];
}

- (void)downloadSeedVC:(id)s { [[OVNativeAccent shared] install]; }

- (void)workerEvent:(NSNotification *)n {
    if (!self.running || ![n.userInfo[@"event"] isEqual:@"train"]) return;
    [self.live addObject:n.userInfo];
    [self refreshResults];
}

- (void)start:(id)s {
    if (self.running) { if (self.job) [OVJobs.shared stop:self.job]; return; }
    NSDictionary *spec = [OVSettings modelSpec];
    if (!spec) { self.status.stringValue = L(@"Finish setup first: the OmniVoice engine and model."); return; }
    self.status.stringValue = L(@"Whisper judges the pronunciation — getting it ready…");
    __weak typeof(self) w = self;
    [[OVModels shared] whenASRReady:^(OVModel *asr, NSString *err) {
        if (err || !asr.localPath) { w.status.stringValue = err ?: L(@"Whisper is needed to judge the pronunciation."); return; }
        [w trainWith:spec asr:asr.localPath];
    }];
}

- (void)trainWith:(NSDictionary *)spec asr:(NSString *)asr {
    NSString *lang = self.lang;
    NSMutableDictionary *voice = [self.voice.workerSpec mutableCopy];
    voice[@"adapt_name"] = [OVLocale nameForLanguage:lang];
    NSMutableDictionary *req = [@{@"cmd": @"train_voice", @"model": spec, @"voice": voice, @"language": lang,
                                  @"out": [[self.voice trainingBase:lang] stringByAppendingPathExtension:@"npz"],
                                  @"rounds": @(kRounds), @"asr_path": asr, @"text": self.text} mutableCopy];
    NSString *from = self.sourcePopup.selectedItem.representedObject;
    NSDictionary *seedvc = [OVNativeAccent shared].workerSpec;
    if (![from isEqualToString:kOwnTakes] && seedvc) {
        req[@"native"] = seedvc;
        OVVoice *narrator = [[OVVoices shared] voiceWithId:from];
        if (narrator) req[@"narrator"] = narrator.workerSpec;
    }
    self.running = YES;
    self.live = [NSMutableArray array];
    self.bar.doubleValue = 0;
    [self refresh];
    __weak typeof(self) w = self;
    NSString *submitError = nil;
    OVJob *job = [OVJobs.shared submitKind:OVJobKindTrain request:req origin:@"app" onFinish:^(OVJob *j) { [w jobFinished:j]; } error:&submitError];
    if (!job) {
        self.running = NO;
        self.status.stringValue = submitError ?: L(@"The task could not be started.");
        [self refresh];
        return;
    }
    self.job = job;
}

/// Status and progress come from the job manager (the job goes on when the sheet is closed).
- (void)jobChanged:(NSNotification *)n {
    OVJob *j = n.object;
    if (!j || j != self.job || !j.active) return;
    if (j.status.length) self.status.stringValue = j.status;
    if (j.progress >= 0) self.bar.doubleValue = j.progress;
}

- (void)jobFinished:(OVJob *)j {
    if (j != self.job) return;
    self.job = nil;
    self.running = NO;
    [[OVVoices shared] reload];
    self.status.stringValue = j.state == OVJobSucceeded ? [self summary:j.result] : j.state == OVJobStopped ? L(@"Stopped") : (j.error ?: L(@"Training failed."));
    [self refresh];
}

- (NSString *)summary:(NSDictionary *)info {
    NSDictionary *was = info[@"original"], *now = info[@"trained"];
    if (!now) return L(@"No round beat the original sample, so the voice keeps it. Listen to the rounds — you can still pick one by ear.");
    return [NSString stringWithFormat:L(@"The voice now speaks this language from round %ld: pronunciation %.0f%% (was %.0f%%), likeness %.0f%% (was %.0f%%). Listen to the rounds and pick another one if it sounds better."),
            (long)[now[@"round"] integerValue], [now[@"pronunciation"] doubleValue] * 100, [was[@"pronunciation"] doubleValue] * 100,
            [now[@"likeness"] doubleValue] * 100, [was[@"likeness"] doubleValue] * 100];
}
@end
