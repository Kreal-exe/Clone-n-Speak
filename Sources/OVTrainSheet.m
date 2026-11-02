#import "OVTrainSheet.h"
#import "OVUI.h"
#import "OVPages.h"
#import "OVLocale.h"
#import "OVModels.h"
#import "OVWorker.h"
#import "OVNativeAccent.h"

static NSInteger const kRounds = 3;
static NSString *const kOwnTakes = @"self", *const kModelNarrator = @"model";

@interface OVTrainSheet ()
@property OVVoice *voice;
@property (copy) NSString *language, *text;
@property NSPopUpButton *langPopup, *sourcePopup;
@property NSTextField *sourceNote, *status;
@property NSButton *getSeedVC, *startButton, *resetButton, *doneButton;
@property NSStackView *results;
@property NSProgressIndicator *bar;
@property BOOL running;
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
}

- (void)build {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 440) styleMask:NSWindowStyleMaskTitled
                                                backing:NSBackingStoreBuffered defer:NO];
    NSTextField *title = OVLabel([NSString stringWithFormat:L(@"Pronunciation of “%@”"), self.voice.name], 17, NSFontWeightSemibold, nil);
    NSTextField *intro = OVWrapLabel(L(@"Round by round the voice gets a new sample in this language and is judged on phrases it never learned on: pronunciation (how native Whisper finds it) and likeness to the original sample. Listen to the rounds and keep the one that sounds best."), 12, NSColor.secondaryLabelColor);

    self.langPopup = [NSPopUpButton new];
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
    self.sourcePopup = [NSPopUpButton new];
    self.sourcePopup.target = self;
    self.sourcePopup.action = @selector(refresh);
    self.sourceNote = OVWrapLabel(@"", 11.5, NSColor.secondaryLabelColor);
    self.getSeedVC = OVButton(L(@"Download Seed-VC (~2.7 GB)"), self, @selector(downloadSeedVC:));
    self.getSeedVC.controlSize = NSControlSizeSmall;
    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[OVLabel(L(@"Language"), 12, NSFontWeightMedium, nil), self.langPopup],
        @[OVLabel(L(@"Learns from"), 12, NSFontWeightMedium, nil), self.sourcePopup],
        @[[NSGridCell emptyContentView], self.sourceNote],
        @[[NSGridCell emptyContentView], self.getSeedVC],
    ]];
    grid.rowSpacing = 8;
    grid.columnSpacing = 12;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [self.sourceNote.widthAnchor constraintEqualToConstant:440].active = YES;

    self.results = OVVStack(@[], 6);
    self.bar = OVProgressBar();
    self.status = OVWrapLabel(@"", 12, NSColor.secondaryLabelColor);
    self.startButton = OVPrimaryButton(L(@"Train"), self, @selector(start:));
    self.resetButton = OVButton(L(@"Back to the original sample"), self, @selector(reset:));
    self.doneButton = OVButton(L(@"Done"), self, @selector(done:));
    self.doneButton.keyEquivalent = @"\e";
    self.resetButton.controlSize = self.doneButton.controlSize = NSControlSizeRegular;
    NSStackView *buttons = OVHStack(@[self.resetButton, OVSpacer(), self.doneButton, self.startButton], 10);

    NSStackView *page = OVVStack(@[title, intro, grid, OVSectionTitle(L(@"Rounds")), self.results, self.bar, self.status, buttons], 12);
    page.edgeInsets = NSEdgeInsetsMake(20, 22, 18, 22);
    OVFillWidth(@[intro, self.results, self.bar, self.status, buttons], page);
    [page.widthAnchor constraintEqualToConstant:600].active = YES;
    self.window.contentView = page;

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(workerEvent:) name:OVWorkerEventNotification object:nil];
    [nc addObserver:self selector:@selector(refresh) name:OVNativeAccentDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refresh) name:OVWorkerDidChangeNotification object:nil];
    [self refresh];
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
    self.sourceNote.textColor = seedvc.error && !seedvc.installing ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    if (seedvc.error && !seedvc.installing) self.sourceNote.stringValue = seedvc.error;
    NSGridView *grid = (NSGridView *)self.getSeedVC.superview;
    if ([grid isKindOfClass:NSGridView.class]) [grid cellForView:self.getSeedVC].row.hidden = seedvc.installed || seedvc.installing;

    BOOL busy = [OVWorker shared].busy;
    self.langPopup.enabled = self.sourcePopup.enabled = !self.running;
    self.getSeedVC.enabled = !busy;
    self.startButton.title = self.running ? L(@"Stop") : L(@"Train");
    self.startButton.enabled = self.running || !busy;
    self.resetButton.enabled = !self.running && [self.voice trainingInfo:self.lang][@"trained"] != nil;
    self.doneButton.enabled = !self.running;
    self.bar.hidden = !self.running;
    [self refreshResults];
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
        [self.results addArrangedSubview:OVLabel(L(@"Not trained in this language yet."), 12, NSFontWeightRegular, NSColor.tertiaryLabelColor)];
        return;
    }
    for (NSDictionary *h in rows) {
        NSInteger r = [h[@"round"] integerValue];
        NSImageView *check = OVSymbol(@"checkmark.circle.fill", 14, OVGreen());
        check.hidden = self.running || r != kept;
        check.toolTip = L(@"The voice speaks this language from this sample");
        NSTextField *name = OVLabel(r == 0 ? L(@"Original sample") : [NSString stringWithFormat:L(@"Round %ld"), (long)r], 12.5, NSFontWeightMedium, nil);
        [name.widthAnchor constraintEqualToConstant:118].active = YES;
        NSTextField *nums = OVLabel([NSString stringWithFormat:L(@"pronunciation %.0f%% · likeness %.0f%%"),
                                     [h[@"pronunciation"] doubleValue] * 100, [h[@"likeness"] doubleValue] * 100], 12, NSFontWeightRegular, nil);
        NSButton *play = OVIconButton(@"play.circle", L(@"Listen"), self, @selector(listen:));
        play.tag = r;
        play.hidden = ![NSFileManager.defaultManager fileExistsAtPath:[self samplePath:r]];
        NSButton *use = OVButton(L(@"Use"), self, @selector(useRound:));
        use.tag = r;
        use.controlSize = NSControlSizeSmall;
        use.hidden = self.running || r == kept || (r > 0 && play.hidden);
        NSStackView *row = OVHStack(@[check, name, nums, OVSpacer(), play, use], 8);
        [self.results addArrangedSubview:row];
        OVFillWidth(@[row], self.results);
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
    if (self.running) { [[OVWorker shared] stop]; return; }
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
    [[OVWorker shared] request:req status:^(NSString *msg) {
        w.status.stringValue = msg;
    } progress:^(double v) {
        w.bar.doubleValue = v;
    } done:^(NSDictionary *data, NSString *error) {
        w.running = NO;
        [[OVVoices shared] reload];
        w.status.stringValue = error ?: [w summary:data];
        [w refresh];
    }];
}

- (NSString *)summary:(NSDictionary *)info {
    NSDictionary *was = info[@"original"], *now = info[@"trained"];
    if (!now) return L(@"No round beat the original sample, so the voice keeps it. Listen to the rounds — you can still pick one by ear.");
    return [NSString stringWithFormat:L(@"The voice now speaks this language from round %ld: pronunciation %.0f%% (was %.0f%%), likeness %.0f%% (was %.0f%%). Listen to the rounds and pick another one if it sounds better."),
            (long)[now[@"round"] integerValue], [now[@"pronunciation"] doubleValue] * 100, [was[@"pronunciation"] doubleValue] * 100,
            [now[@"likeness"] doubleValue] * 100, [was[@"likeness"] doubleValue] * 100];
}
@end
