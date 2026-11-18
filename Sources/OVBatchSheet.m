#import "OVBatchSheet.h"
#import "OVBatch.h"
#import "OVBatchEnv.h"
#import "OVJobs.h"
#import "OVExport.h"
#import "OVStore.h"
#import "OVUI.h"
#import "OVDesign.h"
#import "OVTheme.h"
#import "OVLocale.h"
#import "OVPaths.h"
#import "OVWorker.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kOutDirKey = @"batchOutDir";

@interface OVBatchSheet ()
@property NSTextField *fileField, *outField, *status;
@property NSScrollView *textScroll;
@property OVPopup *modePopup, *voicePopup, *languagePopup, *presetPopup, *formatPopup;
@property NSButton *startButton, *stopButton, *closeButton, *skipBox;
@property NSProgressIndicator *bar;
@property (nullable) OVJob *job;
@property BOOL planning;
@end

static OVBatchSheet *shown;  // the sheet keeps its controller alive

@implementation OVBatchSheet

+ (void)showInWindow:(NSWindow *)window {
    if (shown) return;
    OVBatchSheet *s = [OVBatchSheet new];
    [s build];
    shown = s;
    [window beginSheet:s.window completionHandler:^(NSModalResponse r) {
        [NSNotificationCenter.defaultCenter removeObserver:shown];
        shown = nil;
    }];
}

- (NSTextView *)textView { return self.textScroll.documentView; }

- (void)build {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 560) styleMask:NSWindowStyleMaskTitled
                                                backing:NSBackingStoreBuffered defer:NO];
    NSTextField *title = OVLabel(L(@"Batch speech"), 20, NSFontWeightBold, OVColor(OVRoleText));
    NSTextField *intro = OVWrapLabel(L(@"Turn a text file or pasted text into many audio files at once: one file per line, paragraph or subtitle, all in the same voice."), 13, OVColor(OVRoleMuted));
    NSStackView *head = OVVStack(@[title, intro], 6);
    OVFillWidth(@[intro], head);

    // 1. Source
    self.fileField = OVField(L(@"Text, Markdown or SRT file (or paste text below)"));
    self.fileField.accessibilityLabel = L(@"Text file");
    NSButton *choose = OVButton(L(@"Choose…"), self, @selector(chooseFile:));
    choose.accessibilityLabel = L(@"Choose a text file");
    NSScrollView *ts = NSTextView.scrollableTextView;
    ts.hasVerticalScroller = YES;
    self.textScroll = ts;
    ((NSTextView *)ts.documentView).font = [NSFont systemFontOfSize:13];
    ((NSTextView *)ts.documentView).accessibilityLabel = L(@"Text to speak");
    NSView *area = OVTextArea(ts, 110);
    self.modePopup = [OVPopup popup];
    for (NSArray *m in @[@[L(@"Each line"), @"lines"], @[L(@"Each paragraph"), @"paragraphs"], @[L(@"Each subtitle (SRT)"), @"srt"],
                         @[L(@"Everything in one file"), @"whole"]]) {
        [self.modePopup addItemWithTitle:m[0]];
        self.modePopup.lastItem.representedObject = m[1];
    }
    self.modePopup.accessibilityLabel = L(@"Split by");
    NSStackView *src = OVVStack(@[OVHStack(@[self.fileField, choose], 8), area,
                                  OVFieldBlock(L(@"Split by"), nil, self.modePopup)], 12);
    OVFillWidth(@[src.arrangedSubviews[0], area], src);
    [self.fileField setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    // 2. Voice and result
    self.voicePopup = [OVPopup popup];
    [self.voicePopup addItemWithTitle:L(@"Built-in voice")];
    for (OVVoice *v in [OVVoices shared].all) {
        if (!v.ready) continue;
        [self.voicePopup addItemWithTitle:v.name];
        self.voicePopup.lastItem.representedObject = v.identifier;
    }
    self.languagePopup = [OVPopup popup];
    [self.languagePopup addItemWithTitle:L(@"Detect automatically")];
    self.languagePopup.lastItem.representedObject = @"auto";
    for (NSString *c in [OVLocale pinnedSpeechLanguages]) {
        [self.languagePopup addItemWithTitle:[OVLocale nameForLanguage:c]];
        self.languagePopup.lastItem.representedObject = c;
    }
    self.presetPopup = [OVPopup popup];
    [self.presetPopup addItemWithTitle:L(@"No preset")];
    for (NSDictionary *c in [[OVBatchAppEnvironment new] presetChoices]) {
        [self.presetPopup addItemWithTitle:c[@"title"]];
        self.presetPopup.lastItem.representedObject = c[@"preset"];
    }
    self.formatPopup = [OVPopup popup];
    for (NSDictionary *f in [OVExport formatsWithoutBlocking]) {
        if (![f[@"available"] boolValue]) continue;
        [self.formatPopup addItemWithTitle:f[@"title"]];
        self.formatPopup.lastItem.representedObject = f[@"id"];
    }
    self.formatPopup.accessibilityLabel = L(@"File format");
    NSString *dir = [NSUserDefaults.standardUserDefaults stringForKey:kOutDirKey] ?: [[OVPaths outputs] stringByAppendingPathComponent:@"Batch"];
    self.outField = OVField(L(@"Folder for the audio files"));
    self.outField.stringValue = dir;
    self.outField.accessibilityLabel = L(@"Output folder");
    NSButton *chooseOut = OVButton(L(@"Choose…"), self, @selector(chooseFolder:));
    chooseOut.accessibilityLabel = L(@"Choose the output folder");
    self.voicePopup.accessibilityLabel = L(@"Voice");
    self.languagePopup.accessibilityLabel = L(@"Language");
    self.presetPopup.accessibilityLabel = L(@"Preset");
    self.skipBox = OVCheckbox(L(@"Skip files that already exist"), @"batchSkipExisting");
    NSStackView *voice = OVVStack(@[OVColumns(@[OVFieldBlock(L(@"Voice"), nil, self.voicePopup),
                                                OVFieldBlock(L(@"Language"), nil, self.languagePopup)], 16),
                                    OVColumns(@[OVFieldBlock(L(@"Preset"), nil, self.presetPopup),
                                                OVFieldBlock(L(@"Format"), L(@"A preset brings its own format."), self.formatPopup)], 16),
                                    OVHStack(@[self.outField, chooseOut], 8), self.skipBox], 12);
    OVFillWidth(@[voice.arrangedSubviews[0], voice.arrangedSubviews[1], voice.arrangedSubviews[2]], voice);

    // 3. Progress
    self.bar = OVProgressBar();
    self.bar.hidden = YES;
    self.bar.accessibilityLabel = L(@"Batch progress");
    self.status = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    NSStackView *progress = OVVStack(@[self.bar, self.status], 10);
    OVFillWidth(@[self.bar, self.status], progress);

    self.startButton = OVPrimaryButton(L(@"Start"), self, @selector(start:));
    self.stopButton = OVGhostButton(L(@"Stop"), nil, self, @selector(stop:));
    self.stopButton.hidden = YES;
    self.closeButton = OVGhostButton(L(@"Close"), nil, self, @selector(close:));
    self.closeButton.keyEquivalent = @"\e";
    NSStackView *buttons = OVHStack(@[OVSpacer(), self.closeButton, self.stopButton, self.startButton], 10);
    buttons.edgeInsets = NSEdgeInsetsMake(14, 28, 16, 28);
    NSView *rule = [OVBoxView boxWithFill:OVColor(OVRoleBorder) border:nil radius:0];
    NSStackView *bottom = OVVStack(@[rule, buttons], 0);
    OVFillWidth(@[rule, buttons], bottom);
    [rule.heightAnchor constraintEqualToConstant:1].active = YES;

    NSScrollView *scroll = OVPageScroll(@[head,
        OVStepCard(1, @"doc.text", L(@"Text"), nil, src),
        OVStepCard(2, @"waveform", L(@"Voice & result"), nil, voice),
        OVStepCard(3, @"chart.bar", L(@"Progress"), nil, progress)]);
    NSView *root = [NSView new];
    for (NSView *v in @[scroll, bottom]) { v.translatesAutoresizingMaskIntoConstraints = NO; [root addSubview:v]; }
    [NSLayoutConstraint activateConstraints:@[
        [root.widthAnchor constraintEqualToConstant:640], [root.heightAnchor constraintEqualToConstant:620],
        [scroll.topAnchor constraintEqualToAnchor:root.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:bottom.topAnchor],
        [bottom.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [bottom.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [bottom.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];
    self.window.contentView = root;
    self.window.backgroundColor = OVColor(OVRoleBackground);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(jobChanged:) name:OVJobsDidChangeNotification object:nil];
}

#pragma mark Actions

- (void)chooseFile:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.allowedContentTypes = @[UTTypePlainText, [UTType typeWithFilenameExtension:@"md"] ?: UTTypePlainText,
                              [UTType typeWithFilenameExtension:@"srt"] ?: UTTypePlainText];
    [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        self.fileField.stringValue = p.URL.path;
        if ([p.URL.pathExtension.lowercaseString isEqualToString:@"srt"]) [self.modePopup selectItemAtIndex:2];
    }];
}

- (void)chooseFolder:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = NO; p.canChooseDirectories = YES; p.canCreateDirectories = YES;
    [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r == NSModalResponseOK) self.outField.stringValue = p.URL.path;
    }];
}

- (void)close:(id)sender { [self.window.sheetParent endSheet:self.window]; }

- (void)setRunning:(BOOL)running {
    self.startButton.enabled = !running;
    self.stopButton.hidden = !running;
    self.stopButton.enabled = running && self.job != nil;   // nothing to stop while the text is being split
    self.bar.hidden = !running;
}

- (void)start:(id)sender {
    if (self.planning || self.job.active) return;
    NSString *file = [self.fileField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *text = self.textView.string;
    if (!file.length && ![text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) {
        self.status.stringValue = L(@"Choose a text file or paste the text first.");
        return;
    }
    NSString *outDir = [self.outField.stringValue stringByExpandingTildeInPath];
    if (!outDir.length) { self.status.stringValue = L(@"Choose a folder for the audio files."); return; }
    if (OVWorker.shared.busy) { self.status.stringValue = L(@"The engine is busy. Wait for the current task and press Start again."); return; }
    id preset = self.presetPopup.selectedItem.representedObject;
    NSString *ext = self.formatPopup.selectedItem.representedObject;
    NSString *presetExt = preset ? [OVBatchAppEnvironment.new presetFields:preset][@"formatId"] : nil;
    if (presetExt.length) ext = presetExt;
    NSMutableDictionary *plan = [@{@"cmd": @"batch_plan", @"mode": self.modePopup.selectedItem.representedObject ?: @"lines",
                                   @"ext": ext.length ? ([ext isEqualToString:@"alac"] ? @"m4a" : ext) : @"wav"} mutableCopy];
    if (file.length) plan[@"path"] = file; else plan[@"text"] = text;
    self.planning = YES;
    self.status.stringValue = L(@"Splitting the text…");
    [self setRunning:YES];
    [OVWorker.shared request:plan status:nil progress:nil done:^(NSDictionary *data, NSString *error) {
        self.planning = NO;
        if (error) { self.status.stringValue = error; [self setRunning:NO]; return; }
        [self submitPlan:data outDir:outDir preset:preset];
    }];
}

- (void)submitPlan:(NSDictionary *)plan outDir:(NSString *)outDir preset:(id)preset {
    NSArray *raw = plan[@"items"], *names = plan[@"names"];
    NSMutableArray *items = [NSMutableArray array];
    for (NSUInteger i = 0; i < raw.count && i < names.count; i++)
        [items addObject:@{@"index": raw[i][@"index"], @"text": raw[i][@"text"], @"name": names[i]}];
    NSString *vid = self.voicePopup.selectedItem.representedObject;
    OVVoice *voice = vid ? [[OVVoices shared] voiceWithId:vid] : nil;
    NSString *language = self.languagePopup.selectedItem.representedObject ?: @"auto";
    NSMutableDictionary *req = [OVBatchRequest(items, voice, language, (OVPreset *)preset, outDir) mutableCopy];
    if (!req[@"format"]) req[@"format"] = self.formatPopup.selectedItem.representedObject ?: @"wav";   // a preset without a format keeps the chosen one
    req[@"skipExisting"] = @(self.skipBox.state == NSControlStateValueOn);
    [NSUserDefaults.standardUserDefaults setObject:outDir forKey:kOutDirKey];
    NSString *err = nil;
    self.job = [OVJobs.shared submitKind:OVJobKindBatch request:req origin:@"app" onFinish:nil error:&err];
    if (!self.job) { self.status.stringValue = err ?: L(@"The batch could not start."); [self setRunning:NO]; return; }
    self.bar.doubleValue = 0;
    self.stopButton.enabled = YES;
    [self jobChanged:nil];
}

- (void)stop:(id)sender {
    if (self.job.active) [OVJobs.shared stop:self.job];
    self.status.stringValue = L(@"Stopping…");
}

- (void)jobChanged:(NSNotification *)n {
    OVJob *job = self.job;
    if (!job) return;
    if (job.active) {
        self.bar.doubleValue = MAX(0, job.progress) * 100;
        self.status.stringValue = job.status;
        return;
    }
    [self setRunning:NO];
    self.job = nil;
    NSDictionary *r = job.result;
    if (job.state == OVJobSucceeded) {
        NSMutableString *s = [NSMutableString stringWithFormat:L(@"Done: %ld files"), (long)[r[@"done"] integerValue]];
        if ([r[@"failed"] integerValue]) [s appendFormat:L(@", %ld failed (see the log)"), (long)[r[@"failed"] integerValue]];
        if ([r[@"skipped"] integerValue]) [s appendFormat:L(@", %ld skipped"), (long)[r[@"skipped"] integerValue]];
        self.status.stringValue = s;
        if (job.outputs.firstObject) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:job.outputs.firstObject]]];
    } else if (job.state == OVJobStopped) {
        self.status.stringValue = L(@"Stopped. Files that were ready are in the folder.");
    } else {
        self.status.stringValue = job.error ?: L(@"The batch failed.");
    }
}
@end
