#import "OVEdgeTTS.h"
#import "OVRvcStore.h"
#import "OVDesign.h"
#import "OVUI.h"
#import "OVPages.h"
#import "OVLocale.h"
#import "OVJobs.h"
#import "OVStore.h"
#import "OVPaths.h"
#import "OVEngines.h"
#import "OVProKit.h"
#import "OVNetwork.h"

static NSString *const kEngineKey = @"speechEngine";   // omnivoice | edge
static NSString *const kEngineEdge = @"edge";
static NSString *const kLangKey = @"edgeLang", *const kVoiceKey = @"edgeVoice", *const kThenKey = @"edgeThen",
                       *const kThenKindKey = @"edgeThenKind", *const kThenRvcKey = @"edgeThenRvc", *const kThenVoiceKey = @"edgeThenVoice";
static NSString *const kEdgeChainChanged = @"OVEdgeChainDidChange";

#pragma mark - The history entries

/// Writes the history entry of a finished take and tags it with its source (Edge, or Edge → RVC / Seed-VC).
static void RecordTake(NSString *path, NSString *text, NSString *label, NSString *dryPath) {
    if (!path.length || ![NSFileManager.defaultManager fileExistsAtPath:path]) return;
    NSMutableDictionary *r = [@{@"seconds": @(OVAudioDuration(path))} mutableCopy];
    if (dryPath.length) r[@"dry_path"] = dryPath;
    OVHistory *h = OVHistory.shared;
    [h record:path text:text voice:nil result:r];
    NSString *plist = [path.stringByDeletingPathExtension stringByAppendingPathExtension:@"plist"];
    NSMutableDictionary *meta = [NSMutableDictionary dictionaryWithContentsOfFile:plist];
    if (!meta) return;
    meta[@"voice"] = label;
    [meta writeToFile:plist atomically:YES];
    [h reload];
}

#pragma mark - The chain: Edge speech, then the optional voice change

/// Lives as long as the app: the page may be gone when a job ends. Everything it needs is in the job's request.
@interface OVEdgeChain : NSObject
+ (instancetype)shared;
@property (readonly, weak) OVJob *job;               // the job being followed
@property (readonly, copy) NSString *statusLine;
@property (readonly) double progress;
@property (readonly) BOOL busy;
@property (readonly, copy, nullable) NSString *lastPath;   // the newest finished take
@property (readonly) NSInteger finishedCount;
/// `then`: nil, or @{engine: rvc|seedvc, model|target, name}.
- (void)startText:(NSString *)text voice:(NSString *)voice rate:(NSString *)rate pitch:(NSString *)pitch volume:(NSString *)volume
             then:(nullable NSDictionary *)then window:(nullable NSWindow *)w;
- (void)loadVoicesWindow:(nullable NSWindow *)w completion:(void (^)(NSString *_Nullable error))done;
- (void)stop;
@end

@implementation OVEdgeChain {
    NSMutableSet<NSString *> *_handled;
    BOOL _starting;
}

+ (instancetype)shared {
    static OVEdgeChain *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [OVEdgeChain new];
        s->_handled = [NSMutableSet set];
        s->_statusLine = @"";
        s->_progress = -1;
        [NSNotificationCenter.defaultCenter addObserver:s selector:@selector(jobsChanged:) name:OVJobsDidChangeNotification object:nil];
    });
    return s;
}

- (void)announce { [NSNotificationCenter.defaultCenter postNotificationName:kEdgeChainChanged object:self]; }

- (BOOL)busy { return _starting || self.job.active; }

- (void)startText:(NSString *)text voice:(NSString *)voice rate:(NSString *)rate pitch:(NSString *)pitch volume:(NSString *)volume
             then:(NSDictionary *)then window:(NSWindow *)w {
    if (self.busy) return;
    NSString *out = [OVHistory.shared newOutputPathForText:text];
    NSMutableDictionary *req = [@{@"text": text, @"voice": voice, @"rate": rate, @"pitch": pitch, @"volume": volume,
                                  @"out_name": out.lastPathComponent, @"_edgeVoice": voice} mutableCopy];
    if (then) req[@"_edgeThen"] = then;
    _starting = YES;
    _statusLine = L(@"Asking Microsoft’s voice…");
    _progress = -1;
    [self announce];
    [OVProRun submitKind:OVProKindEdge request:req feature:L(@"Edge TTS") window:w network:(OVNetFeature)-1 completion:^(OVJob *job, NSString *error) {
        self->_starting = NO;
        if (job) { self->_job = job; self->_statusLine = job.status.length ? job.status : L(@"Starting…"); }
        else self->_statusLine = error ?: @"";   // nil job and no error = the user declined (or Offline mode blocked it)
        self->_progress = -1;
        [self announce];
    }];
}

- (void)loadVoicesWindow:(NSWindow *)w completion:(void (^)(NSString *))done {
    [OVProRun submitKind:OVProKindEdgeVoices request:@{} feature:L(@"Edge TTS") window:w network:(OVNetFeature)-1
              completion:^(OVJob *job, NSString *error) {
        if (!job) { done(error); return; }
        __block id obs = nil;
        __block BOOL finished = NO;
        void (^check)(void) = ^{
            if (finished || job.active) return;
            finished = YES;
            if (obs) [NSNotificationCenter.defaultCenter removeObserver:obs];
            obs = nil;
            done(job.state == OVJobSucceeded ? nil : (job.state == OVJobStopped ? L(@"Stopped") : (job.error ?: L(@"Could not load the Edge voice list. Check the network and try again."))));
        };
        obs = [NSNotificationCenter.defaultCenter addObserverForName:OVJobsDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                                                          usingBlock:^(NSNotification *n) { check(); }];
        check();   // the job may already be over
    }];
}

- (void)stop { if (self.job.active) [OVJobs.shared stop:self.job]; }

- (void)jobsChanged:(NSNotification *)n {
    OVJob *j = self.job;
    if (!j) return;
    if (j.active) {
        NSString *what = [j.kind isEqualToString:OVProKindEdge] ? L(@"Asking Microsoft’s voice…") : L(@"Changing the voice…");
        _statusLine = j.status.length ? j.status : what;
        _progress = j.progress;
        [self announce];
        return;
    }
    if ([_handled containsObject:j.identifier]) return;
    [_handled addObject:j.identifier];
    if (j.state != OVJobSucceeded) {
        _statusLine = j.state == OVJobStopped ? L(@"Stopped") : (j.error ?: L(@"Speech failed."));
        _progress = -1;
        [self announce];
        return;
    }
    if ([j.kind isEqualToString:OVProKindEdge]) [self edgeFinished:j];
    else [self convertFinished:j];
}

- (void)edgeFinished:(OVJob *)j {
    NSString *wav = j.outputs.firstObject;
    NSString *text = j.request[@"text"];
    NSString *voice = j.request[@"_edgeVoice"] ?: @"";
    RecordTake(wav, text ?: @"", [NSString stringWithFormat:L(@"Edge · %@"), voice], nil);
    NSDictionary *then = [j.request[@"_edgeThen"] isKindOfClass:NSDictionary.class] ? j.request[@"_edgeThen"] : nil;
    if (!then || !wav.length) { [self finishedWith:wav status:nil]; return; }
    BOOL seed = [then[@"engine"] isEqual:@"seedvc"];
    NSMutableDictionary *req = [@{@"engine": seed ? @"seedvc" : @"rvc", @"input": wav, @"_name": then[@"name"] ?: @"",
                                  @"_edgeText": text ?: @"", @"_edgeDry": wav} mutableCopy];
    if (seed) req[@"target"] = then[@"target"] ?: @"";
    else {
        // the user's saved Convert settings, when there are any
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        id pitch = [d objectForKey:@"convert.pitch"], f0 = [d objectForKey:@"convert.f0"], idx = [d objectForKey:@"convert.index"];
        req[@"model"] = then[@"model"] ?: @""; req[@"mode"] = @"single";
        req[@"pitch"] = [pitch isKindOfClass:NSNumber.class] ? pitch : @0;
        req[@"f0_method"] = [f0 isKindOfClass:NSString.class] ? f0 : @"rmvpe";
        if ([idx isKindOfClass:NSNumber.class]) req[@"index_rate"] = idx;
    }
    req[@"_edgeLabel"] = [NSString stringWithFormat:seed ? L(@"Edge → Seed-VC · %@") : L(@"Edge → RVC · %@"), then[@"name"] ?: @""];
    _starting = YES;
    _statusLine = L(@"Changing the voice…");
    [self announce];
    [OVProRun submitKind:OVProKindConvert request:req feature:L(@"Voice change") window:NSApp.keyWindow ?: NSApp.mainWindow network:(OVNetFeature)-1
              completion:^(OVJob *job, NSString *error) {
        self->_starting = NO;
        if (job) { self->_job = job; self->_statusLine = L(@"Changing the voice…"); self->_progress = -1; [self announce]; return; }
        // declined or failed: the Edge take itself is done and in the history
        [self finishedWith:wav status:error ?: L(@"The voice was not changed — the Edge take is in the history.")];
    }];
}

- (void)convertFinished:(OVJob *)j {
    NSString *out = j.outputs.firstObject;
    RecordTake(out, j.request[@"_edgeText"] ?: @"", j.request[@"_edgeLabel"] ?: L(@"Edge"), j.request[@"_edgeDry"]);
    [self finishedWith:out status:nil];
}

- (void)finishedWith:(NSString *)path status:(NSString *)status {
    _lastPath = path;
    _finishedCount++;
    _statusLine = status ?: [NSString stringWithFormat:L(@"Done: %@ of audio"), OVFormatDuration(path.length ? OVAudioDuration(path) : 0)];
    _progress = -1;
    [self announce];
}
@end

#pragma mark - Pure helpers

static NSString *LanguageOfLocale(NSString *loc) {
    NSRange r = [loc rangeOfString:@"-"];
    return (r.location == NSNotFound ? loc : [loc substringToIndex:r.location]).lowercaseString;
}

static NSString *CachePath(void) {
    return [[OVEngines.shared.root stringByAppendingPathComponent:@"edge"] stringByAppendingPathComponent:@"voices.json"];
}

#pragma mark - The card

@interface OVEdgeTTS ()
@property (readwrite) NSView *engineBlock, *view;
@property OVSegmented *engineChoice, *thenKind;
@property OVPopup *langPopup, *voicePopup, *thenPopup;
@property OVSwitch *thenSwitch;
@property OVSliderRow *rate, *pitch, *volume;
@property NSView *gate, *body, *thenBody;
@property NSButton *loadVoices, *openModels;
@property NSTextField *thenHint, *voiceHint;
@property BOOL ready, loadingVoices;
@property (copy) NSArray<NSDictionary *> *voiceList, *rvcModels;
@property NSInteger seenFinished;
@property (copy) NSString *loadError;
@end

@implementation OVEdgeTTS

+ (NSString *)rateString:(double)percent {
    return [NSString stringWithFormat:@"%+ld%%", (long)llround(MIN(100, MAX(-50, percent)))];
}

+ (NSString *)pitchString:(double)hz {
    return [NSString stringWithFormat:@"%+ldHz", (long)llround(MIN(50, MAX(-50, hz)))];
}

+ (NSArray<NSString *> *)languagesOf:(NSArray<NSDictionary *> *)all {
    NSMutableSet *s = [NSMutableSet set];
    for (NSDictionary *v in all) {
        NSString *loc = v[@"Locale"];
        if ([loc isKindOfClass:NSString.class] && loc.length) [s addObject:LanguageOfLocale(loc)];
    }
    return [s.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

+ (NSArray<NSDictionary *> *)voices:(NSArray<NSDictionary *> *)all forLanguage:(NSString *)language {
    NSMutableArray *a = [NSMutableArray array];
    for (NSDictionary *v in all) {
        NSString *loc = v[@"Locale"], *name = v[@"ShortName"];
        if ([loc isKindOfClass:NSString.class] && [name isKindOfClass:NSString.class] && name.length &&
            [LanguageOfLocale(loc) isEqualToString:language.lowercaseString]) [a addObject:v];
    }
    [a sortUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) {
        NSComparisonResult c = [x[@"Locale"] compare:y[@"Locale"]];
        return c != NSOrderedSame ? c : [x[@"ShortName"] compare:y[@"ShortName"]];
    }];
    return a;
}

+ (NSArray<NSDictionary *> *)readVoiceCache:(NSString *)path {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return nil;
    id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    NSArray *v = [o isKindOfClass:NSDictionary.class] ? o[@"voices"] : nil;
    if (![v isKindOfClass:NSArray.class] || !v.count) return nil;
    for (id i in v) if (![i isKindOfClass:NSDictionary.class]) return nil;
    return v;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    [self build];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(chainChanged) name:kEdgeChainChanged object:nil];
    [nc addObserver:self selector:@selector(refresh) name:OVEnginesDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refresh) name:OVNetworkModeDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refresh) name:OVVoicesDidChangeNotification object:nil];
    self.seenFinished = OVEdgeChain.shared.finishedCount;
    [self refresh];
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (BOOL)selected { return [[NSUserDefaults.standardUserDefaults stringForKey:kEngineKey] isEqualToString:kEngineEdge]; }
- (BOOL)busy { return OVEdgeChain.shared.busy; }
- (NSString *)statusLine { return OVEdgeChain.shared.statusLine; }
- (double)progress { return OVEdgeChain.shared.progress; }

- (void)changed { if (self.onChange) self.onChange(); }

- (void)build {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    self.engineChoice = [OVSegmented segmentedWithItems:@[@[L(@"OmniVoice (on this Mac)"), @""], @[L(@"Edge TTS (online)"), @""]]];
    self.engineChoice.target = self;
    self.engineChoice.action = @selector(enginePicked:);
    self.engineChoice.accessibilityLabel = L(@"Engine");
    self.engineBlock = OVFieldBlock(L(@"Engine"), nil, self.engineChoice);

    __weak typeof(self) w = self;
    self.gate = OVEngineGateCard(L(@"Edge TTS"), @[OVEngineEdge], ^(BOOL ready) { w.ready = ready; [w refresh]; [w changed]; });

    // what is sent, said plainly, with the Online badge
    NSTextField *notice = OVWrapLabel(L(@"Your text is sent to Microsoft’s servers to be spoken. Nothing else leaves your Mac."), 13, nil);
    NSStackView *noticeRow = OVHStack(@[OVBadge(L(@"Online"), OVRoleWarn), notice], 10);
    noticeRow.alignment = NSLayoutAttributeTop;
    OVBoxView *noticeBox = [OVBoxView boxWithFill:OVColorAlpha(OVRoleWarn, 0.08) border:OVColor(OVRoleWarn) radius:10];
    [noticeBox addSubview:noticeRow];
    OVPin(noticeRow, noticeBox, NSEdgeInsetsMake(10, 12, 10, 12));
    noticeBox.toolTip = L(@"The first time, you are asked to agree. Offline mode in Settings blocks it. You can take the agreement back in Privacy.");

    self.langPopup = [OVPopup popup];
    self.langPopup.target = self;
    self.langPopup.action = @selector(langPicked:);
    self.langPopup.accessibilityLabel = L(@"Language");
    self.voicePopup = [OVPopup popup];
    self.voicePopup.target = self;
    self.voicePopup.action = @selector(voicePicked:);
    self.voicePopup.accessibilityLabel = L(@"Voice");
    self.loadVoices = OVButtonHeight(OVGhostButton(L(@"Load voices"), @"arrow.clockwise", self, @selector(loadVoicesPressed:)), 28);
    self.loadVoices.toolTip = L(@"Asks Microsoft for the list of voices (nothing of yours is sent) and keeps it for a week.");
    self.voiceHint = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    NSView *langBlock = OVFieldBlock(L(@"Language"), nil, OVFillPopup(self.langPopup));
    NSView *voiceBlock = OVFieldBlock(L(@"Voice"), nil, OVFillPopup(self.voicePopup));

    OVSliderRow *(^slider)(NSString *, NSString *, NSString *, double, double, NSString *) =
        ^OVSliderRow *(NSString *title, NSString *key, NSString *unit, double min, double max, NSString *tip) {
            OVSliderRow *r = [OVSliderRow rowWithTitle:title hint:nil key:key min:min max:max format:@"%.0f" integer:YES];
            r.compact = YES;
            r.step = 5;
            r.valueFormatter = ^(double v) { return fabs(v) < 0.5 ? @"0" : [NSString stringWithFormat:@"%+.0f%@", v, unit]; };
            r.toolTip = tip;
            [r refresh];
            return r;
        };
    self.rate = slider(L(@"Speed"), @"edgeRate", @"%", -50, 100, L(@"Faster or slower than the voice’s normal pace."));
    self.pitch = slider(L(@"Pitch"), @"edgePitch", @" Hz", -50, 50, L(@"Lower or higher than the voice’s normal pitch."));
    self.volume = slider(L(@"Volume"), @"edgeVolume", @"%", -50, 50, L(@"Quieter or louder than normal."));

    // Then change the voice: a second step, its own job, visible in Jobs
    self.thenSwitch = [OVSwitch new];
    self.thenSwitch.target = self;
    self.thenSwitch.action = @selector(thenToggled:);
    self.thenSwitch.accessibilityLabel = L(@"Then change the voice");
    NSTextField *thenTitle = OVLabel(L(@"Then change the voice"), 14, NSFontWeightSemibold, nil);
    NSTextField *thenSub = OVWrapLabel(L(@"Runs the Edge speech through a voice model or through your cloned voice. A second task, shown in Jobs."), 13, OVColor(OVRoleMuted));
    NSStackView *thenTexts = OVVStack(@[thenTitle, thenSub], 2);
    OVFillWidth(@[thenSub], thenTexts);
    NSStackView *thenHeader = OVHStack(@[self.thenSwitch, thenTexts, OVSpacer(), OVProBadge()], 10);
    thenHeader.alignment = NSLayoutAttributeCenterY;
    self.thenKind = [OVSegmented segmentedWithItems:@[@[L(@"Voice model (RVC)"), @""], @[L(@"My cloned voice (Seed-VC)"), @""]]];
    self.thenKind.selectedIndex = [[d stringForKey:kThenKindKey] isEqualToString:@"seedvc"] ? 1 : 0;
    self.thenKind.target = self;
    self.thenKind.action = @selector(thenKindPicked:);
    self.thenKind.accessibilityLabel = L(@"Change the voice with");
    self.thenPopup = [OVPopup popup];
    self.thenPopup.target = self;
    self.thenPopup.action = @selector(thenPicked:);
    self.thenPopup.accessibilityLabel = L(@"Voice to change to");
    self.thenHint = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.openModels = OVButtonHeight(OVGhostButton(L(@"Open Models"), @"shippingbox", self, @selector(openModelsPressed:)), 28);
    NSStackView *modelsRow = OVHStack(@[self.openModels, OVSpacer()], 8);
    self.thenBody = OVFillStack(@[self.thenKind, OVFillPopup(self.thenPopup), self.thenHint, modelsRow], 10);
    NSStackView *then = OVFillStack(@[thenHeader, self.thenBody], 12);
    OVBoxView *thenBox = [OVBoxView boxWithFill:OVColor(OVRoleField) border:OVColor(OVRoleBorder) radius:10];
    [thenBox addSubview:then];
    OVPin(then, thenBox, NSEdgeInsetsMake(12, 12, 12, 12));

    NSStackView *loadRow = OVHStack(@[self.loadVoices, OVSpacer()], 8);
    NSStackView *voiceNote = OVFillStack(@[self.voiceHint, loadRow], 8);
    self.body = OVFillStack(@[noticeBox, OVColumns(@[langBlock, voiceBlock], 16), voiceNote,
                              OVFillStack(@[self.rate, self.pitch, self.volume], 12), thenBox], 14);
    self.view = OVFillStack(@[self.gate, self.body], 14);
}

#pragma mark Actions

- (void)enginePicked:(OVSegmented *)s {
    [NSUserDefaults.standardUserDefaults setObject:s.selectedIndex == 1 ? kEngineEdge : @"omnivoice" forKey:kEngineKey];
    [self refresh];
    [self changed];
}

- (void)langPicked:(OVPopup *)p {
    [NSUserDefaults.standardUserDefaults setObject:p.selectedItem.representedObject ?: @"" forKey:kLangKey];
    [self fillVoices];
    [self changed];
}

- (void)voicePicked:(OVPopup *)p {
    [NSUserDefaults.standardUserDefaults setObject:p.selectedItem.representedObject ?: @"" forKey:kVoiceKey];
    [self changed];
}

- (void)thenToggled:(OVSwitch *)s {
    [NSUserDefaults.standardUserDefaults setBool:s.on forKey:kThenKey];
    [self refresh];
    [self changed];
}

- (void)thenKindPicked:(OVSegmented *)s {
    [NSUserDefaults.standardUserDefaults setObject:s.selectedIndex == 1 ? @"seedvc" : @"rvc" forKey:kThenKindKey];
    [self fillThen];
    [self changed];
}

- (void)thenPicked:(OVPopup *)p {
    NSString *key = self.thenKind.selectedIndex == 1 ? kThenVoiceKey : kThenRvcKey;
    [NSUserDefaults.standardUserDefaults setObject:p.selectedItem.representedObject ?: @"" forKey:key];
    [self changed];
}

- (void)openModelsPressed:(id)s { OVNavigate(@"models"); }

- (void)loadVoicesPressed:(id)s {
    if (self.loadingVoices) return;
    self.loadingVoices = YES;
    self.loadError = nil;
    [self refresh];
    __weak typeof(self) w = self;
    [OVEdgeChain.shared loadVoicesWindow:self.view.window completion:^(NSString *error) {
        w.loadingVoices = NO;
        w.loadError = error;
        [w refresh];
        [w changed];
    }];
}

- (void)stop { [OVEdgeChain.shared stop]; }

#pragma mark State

- (void)chainChanged {
    OVEdgeChain *c = OVEdgeChain.shared;
    if (c.finishedCount != self.seenFinished) {
        self.seenFinished = c.finishedCount;
        if (c.lastPath.length && self.onFinished) self.onFinished(c.lastPath);
    }
    [self refresh];
    [self changed];
}

- (void)fillLanguages {
    [self.langPopup removeAllItems];
    NSArray *langs = [OVEdgeTTS languagesOf:self.voiceList ?: @[]];
    if (!langs.count) {
        [self.langPopup addItemWithTitle:L(@"Load the voices first")];
        [self.voicePopup removeAllItems];
        [self.voicePopup addItemWithTitle:L(@"Load the voices first")];
        self.langPopup.enabled = self.voicePopup.enabled = NO;
        return;
    }
    self.langPopup.enabled = YES;
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSString *code in langs) [pairs addObject:@[[NSLocale.currentLocale localizedStringForLanguageCode:code] ?: code, code]];
    [pairs sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[0] localizedCaseInsensitiveCompare:b[0]]; }];
    for (NSArray *p in pairs) {
        [self.langPopup addItemWithTitle:[NSString stringWithFormat:@"%@ (%@)", p[0], p[1]]];
        self.langPopup.lastItem.representedObject = p[1];
    }
    NSInteger i = [self.langPopup indexOfItemWithRepresentedObject:[NSUserDefaults.standardUserDefaults stringForKey:kLangKey] ?: @"en"];
    if (i < 0) i = MAX(0, [self.langPopup indexOfItemWithRepresentedObject:@"en"]);
    [self.langPopup selectItemAtIndex:i];
    [self fillVoices];
}

- (void)fillVoices {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *lang = self.langPopup.selectedItem.representedObject;
    [self.voicePopup removeAllItems];
    NSArray *list = lang ? [OVEdgeTTS voices:self.voiceList ?: @[] forLanguage:lang] : @[];
    for (NSDictionary *v in list) {
        NSString *name = v[@"FriendlyName"] ?: v[@"ShortName"];
        // "Microsoft Aria Online (Natural) - English (United States)": the part before " - " is the voice's own name
        NSRange dash = [name rangeOfString:@" - "];
        if (dash.location != NSNotFound) name = [name substringToIndex:dash.location];
        name = [name stringByReplacingOccurrencesOfString:@"Microsoft " withString:@""];
        [self.voicePopup addItemWithTitle:[NSString stringWithFormat:@"%@ · %@ · %@", name, v[@"Locale"], [v[@"Gender"] length] ? v[@"Gender"] : @"—"]];
        self.voicePopup.lastItem.representedObject = v[@"ShortName"];
    }
    self.voicePopup.enabled = list.count > 0;
    if (!list.count) { [self.voicePopup addItemWithTitle:L(@"No voices for this language")]; return; }
    NSInteger i = [self.voicePopup indexOfItemWithRepresentedObject:[d stringForKey:kVoiceKey] ?: @""];
    [self.voicePopup selectItemAtIndex:MAX(0, i)];
    [d setObject:self.voicePopup.selectedItem.representedObject forKey:kVoiceKey];
}

- (void)fillThen {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL seed = self.thenKind.selectedIndex == 1;
    [self.thenPopup removeAllItems];
    BOOL engine = [OVEngines.shared pythonForEngine:seed ? @"seedvc" : @"rvc"] != nil;
    if (seed) {
        for (OVVoice *v in OVVoices.shared.all) {
            if (!v.ready) continue;
            [self.thenPopup addItemWithTitle:v.name];
            self.thenPopup.lastItem.representedObject = v.identifier;
        }
    } else {
        for (NSDictionary *m in self.rvcModels) {
            [self.thenPopup addItemWithTitle:m[@"name"]];
            self.thenPopup.lastItem.representedObject = m[@"folder"];
        }
    }
    BOOL available = self.thenPopup.numberOfItems > 0;
    if (available) {
        NSInteger i = [self.thenPopup indexOfItemWithRepresentedObject:[d stringForKey:seed ? kThenVoiceKey : kThenRvcKey] ?: @""];
        [self.thenPopup selectItemAtIndex:MAX(0, i)];
    } else {
        [self.thenPopup addItemWithTitle:seed ? L(@"No cloned voices") : L(@"No voice models")];
    }
    self.thenPopup.enabled = available;
    if (!available) self.thenHint.stringValue = seed ? L(@"No cloned voices yet — make one on the Voices page.") : L(@"No voice models yet — add one on the Models page.");
    else if (!engine) self.thenHint.stringValue = seed ? L(@"Seed-VC isn’t installed yet — install it in Models.") : L(@"The voice-model engine isn’t installed yet — install it in Models.");
    else self.thenHint.stringValue = seed ? L(@"Takes about four times as long as the speech itself. Needs the 16 GB tier.") : L(@"Takes a few seconds for a short text.");
    self.openModels.hidden = available && engine;
}

- (NSArray<NSDictionary *> *)scanRvcModels {
    NSMutableArray *a = [NSMutableArray array];
    for (OVRvcModel *m in OVRvcStore.shared.models) [a addObject:@{@"name": m.name, @"folder": m.folder}];
    return a;
}

- (void)refresh {
    self.engineChoice.selectedIndex = self.selected ? 1 : 0;
    self.view.hidden = !self.selected;
    self.ready = [OVEngines.shared pythonForEngine:OVEngineEdge] != nil;
    self.voiceList = [OVEdgeTTS readVoiceCache:CachePath()];
    self.rvcModels = [self scanRvcModels];
    [self fillLanguages];
    self.thenSwitch.on = [NSUserDefaults.standardUserDefaults boolForKey:kThenKey];
    self.thenBody.hidden = !self.thenSwitch.on;
    [self fillThen];
    BOOL offline = OVNetwork.offline, listed = self.voiceList.count > 0;
    self.loadVoices.superview.hidden = listed && !self.loadError;
    self.loadVoices.hidden = NO;
    self.loadVoices.enabled = !self.loadingVoices && self.ready && !offline;
    self.loadVoices.title = self.loadingVoices ? L(@"Loading…") : (listed ? L(@"Reload voices") : L(@"Load voices"));
    self.voiceHint.stringValue = self.loadError ?: offline ? L(@"Offline mode is on — Edge voices need the internet. Turn Offline mode off in Settings.")
        : !listed ? L(@"Press Load voices once: Microsoft sends the list of its voices (nothing of yours is sent).") : @"";
    self.voiceHint.hidden = self.voiceHint.stringValue.length == 0;
    self.body.alphaValue = self.ready ? 1 : 0.45;
    self.rate.enabled = self.pitch.enabled = self.volume.enabled = self.ready;
    self.thenSwitch.enabled = self.ready;
}

- (NSString *)problem {
    if (!self.ready) return L(@"Edge TTS isn’t installed yet — install it above.");
    if (OVNetwork.offline) return L(@"Offline mode is on — Edge voices need the internet.");
    if (!self.voiceList.count) return L(@"Load the Edge voices first.");
    if (![self.voicePopup.selectedItem.representedObject length]) return L(@"Pick an Edge voice first.");
    if (self.thenSwitch.on && !self.thenPopup.enabled) return L(@"Pick a voice to change to, or turn “Then change the voice” off.");
    return nil;
}

- (void)speak:(NSString *)text window:(NSWindow *)window {
    if (self.problem || self.busy) return;
    NSDictionary *then = nil;
    if (self.thenSwitch.on) {
        id sel = self.thenPopup.selectedItem.representedObject;
        if (self.thenKind.selectedIndex == 1) {
            OVVoice *v = [sel isKindOfClass:NSString.class] ? [OVVoices.shared voiceWithId:sel] : nil;
            if (v) then = @{@"engine": @"seedvc", @"target": v.referencePath, @"name": v.name};
        } else if ([sel isKindOfClass:NSString.class] && [sel length]) {
            then = @{@"engine": @"rvc", @"model": sel, @"name": self.thenPopup.selectedItem.title};
        }
        if (!then) return;
    }
    [OVEdgeChain.shared startText:text voice:self.voicePopup.selectedItem.representedObject
                             rate:[OVEdgeTTS rateString:self.rate.value] pitch:[OVEdgeTTS pitchString:self.pitch.value]
                           volume:[OVEdgeTTS rateString:self.volume.value] then:then window:window];
}
@end
