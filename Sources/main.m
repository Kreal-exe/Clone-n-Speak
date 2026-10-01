#import <Cocoa/Cocoa.h>
#import "OVPages.h"
#import "OVUI.h"
#import "OVLocale.h"
#import "OVRuntime.h"
#import "OVModels.h"
#import "OVWorker.h"
#import "OVStore.h"
#import "OVPaths.h"
#import "OVMemory.h"

#pragma mark - Sidebar

/// Thin bar under the status: how much of the Mac's memory the engine and everything else use.
@interface OVMemoryMeter : NSView
@property (nonatomic) double engine, others;  // fractions of the physical memory
@end
@implementation OVMemoryMeter
- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric, 4); }
- (void)setEngine:(double)e { _engine = e; self.needsDisplay = YES; }
- (void)setOthers:(double)o { _others = o; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)r {
    NSRect b = self.bounds;
    [[NSBezierPath bezierPathWithRoundedRect:b xRadius:2 yRadius:2] addClip];
    [[NSColor.labelColor colorWithAlphaComponent:0.08] setFill];
    NSRectFillUsingOperation(b, NSCompositingOperationSourceOver);
    double e = MAX(0, MIN(1, self.engine)), o = MAX(0, MIN(1 - e, self.others));
    [[NSColor.labelColor colorWithAlphaComponent:0.22] setFill];
    NSRectFillUsingOperation(NSMakeRect(0, 0, NSWidth(b) * (e + o), NSHeight(b)), NSCompositingOperationSourceOver);
    [OVAccent() setFill];
    NSRectFillUsingOperation(NSMakeRect(0, 0, NSWidth(b) * e, NSHeight(b)), NSCompositingOperationSourceOver);
}
@end

/// Rounded, barely tinted box behind the sidebar status.
@interface OVTintBox : NSView
@end
@implementation OVTintBox
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {
    self.layer.cornerRadius = 11;
    self.layer.backgroundColor = [NSColor.labelColor colorWithAlphaComponent:0.055].CGColor;
}
@end

@interface OVSidebar : NSViewController <NSTableViewDataSource, NSTableViewDelegate>
@property NSTableView *table;
@property NSArray<NSArray<NSString *> *> *items; // id, title, symbol
@property NSTextField *footer, *footerDetail, *tagline;
@property NSImageView *footerIcon;
@property OVMemoryMeter *meter;
@property NSButton *themeButton;
@property (copy) void (^onSelect)(NSString *page);
- (void)selectPage:(NSString *)page;
- (void)reloadTexts;
@end

@implementation OVSidebar
- (void)loadView {
    self.table = [NSTableView new];
    [self.table addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"i"]];
    self.table.headerView = nil;
    self.table.style = NSTableViewStyleSourceList;
    self.table.rowHeight = 34;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.backgroundColor = NSColor.clearColor;
    NSScrollView *sv = [NSScrollView new];
    sv.documentView = self.table;
    sv.drawsBackground = NO;

    NSImageView *logo = [NSImageView imageViewWithImage:NSApp.applicationIconImage];
    logo.imageScaling = NSImageScaleProportionallyUpOrDown;
    [logo.widthAnchor constraintEqualToConstant:40].active = YES;
    [logo.heightAnchor constraintEqualToConstant:40].active = YES;
    NSTextField *brand = OVLabel(OVAppName, 15.5, NSFontWeightBold, nil);
    brand.font = OVRoundedFont(15.5, NSFontWeightBold);
    self.tagline = OVWrapLabel(@"", 10.5, NSColor.secondaryLabelColor);
    self.tagline.maximumNumberOfLines = 2;
    NSStackView *head = OVHStack(@[logo, OVVStack(@[brand, self.tagline], 1)], 8);

    // status card: what the engine is doing, memory at a glance, theme switch
    self.footerIcon = OVSymbol(@"circle.fill", 8, NSColor.tertiaryLabelColor);
    self.footer = OVLabel(@"", 11.5, NSFontWeightSemibold, nil);
    self.footerDetail = OVWrapLabel(@"", 10.5, NSColor.secondaryLabelColor);
    self.footerDetail.maximumNumberOfLines = 3;
    self.themeButton = OVIconButton(@"moon.fill", @"", self, @selector(toggleTheme:));
    self.themeButton.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightRegular];
    self.meter = [OVMemoryMeter new];
    self.meter.toolTip = L(@"Memory of this Mac: the speech engine (blue), other apps (gray), free");
    NSStackView *statusLine = OVHStack(@[self.footerIcon, self.footer, OVSpacer(), self.themeButton], 6);
    NSStackView *footStack = OVVStack(@[statusLine, self.footerDetail, self.meter], 5);
    OVFillWidth(@[statusLine, self.footerDetail, self.meter], footStack);
    OVTintBox *foot = [OVTintBox new];
    foot.wantsLayer = YES;
    [foot addSubview:footStack];
    OVPin(footStack, foot, NSEdgeInsetsMake(9, 11, 11, 9));
    [foot setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];

    NSView *root = [NSView new];
    for (NSView *v in @[head, sv, foot]) { v.translatesAutoresizingMaskIntoConstraints = NO; [root addSubview:v]; }
    [NSLayoutConstraint activateConstraints:@[
        [head.topAnchor constraintEqualToAnchor:root.topAnchor constant:46],
        [head.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:16],
        [head.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-10],
        [sv.topAnchor constraintEqualToAnchor:head.bottomAnchor constant:18],
        [sv.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [sv.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [sv.bottomAnchor constraintEqualToAnchor:foot.topAnchor constant:-10],
        [foot.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:12],
        [foot.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-12],
        [foot.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-12],
        [root.widthAnchor constraintGreaterThanOrEqualToConstant:200],
    ]];
    self.view = root;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    for (NSNotificationName n in @[OVRuntimeDidChangeNotification, OVModelsDidChangeNotification, OVWorkerDidChangeNotification,
                                   OVWorkerMemoryDidChangeNotification])
        [nc addObserver:self selector:@selector(refreshFooter) name:n object:nil];
    [self reloadTexts];
}

- (void)reloadTexts {
    self.items = @[@[@"setup", L(@"Setup"), @"checklist"],
                   @[@"synth", L(@"Speech"), @"waveform"],
                   @[@"voices", L(@"Voices"), @"person.wave.2"],
                   @[@"models", L(@"Models"), @"shippingbox"],
                   @[@"settings", L(@"Settings"), @"slider.horizontal.3"],
                   @[@"log", L(@"Log"), @"text.alignleft"]];
    self.tagline.stringValue = L(@"voice cloning · 600+ languages");
    NSInteger sel = self.table.selectedRow;
    [self.table reloadData];
    if (sel >= 0) [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:sel] byExtendingSelection:NO];
    [self refreshThemeButton];
    [self refreshFooter];
}

- (void)viewDidChangeEffectiveAppearance { [self refreshThemeButton]; }

- (void)refreshThemeButton {
    BOOL dark = [OVLocale isDark];
    // show what a click switches to: the sun in dark mode, the moon in light mode
    self.themeButton.image = [NSImage imageWithSystemSymbolName:dark ? @"sun.max.fill" : @"moon.fill" accessibilityDescription:nil];
    self.themeButton.toolTip = dark ? L(@"Switch to light theme") : L(@"Switch to dark theme");
    self.themeButton.accessibilityLabel = self.themeButton.toolTip;
    self.themeButton.contentTintColor = dark ? NSColor.systemYellowColor : NSColor.secondaryLabelColor;
}

- (void)toggleTheme:(id)s {
    [OVLocale setThemeSetting:[OVLocale isDark] ? @"light" : @"dark"];
    [self refreshThemeButton];
}

- (void)refreshFooter {
    OVRuntime *rt = [OVRuntime shared];
    OVWorker *w = [OVWorker shared];
    OVModels *mm = [OVModels shared];
    NSColor *c = NSColor.tertiaryLabelColor;
    NSString *t;
    NSString *model = mm.loraModel ? [NSString stringWithFormat:@"%@ + LoRA", mm.ttsModel.title] : mm.ttsModel.title;
    if (rt.state == OVRuntimeInstalling) { t = L(@"Installing the engine…"); c = NSColor.systemBlueColor; }
    else if (rt.state == OVRuntimeChecking || rt.state == OVRuntimeUnknown) t = L(@"Looking for the engine…");
    else if (rt.state != OVRuntimeReady) { t = L(@"Engine not installed"); c = NSColor.systemOrangeColor; }
    else if (!mm.ttsModel) { t = L(@"No model"); c = NSColor.systemOrangeColor; }
    else if (w.busy) { t = L(@"Working…"); c = NSColor.systemBlueColor; }
    else if (w.loadedModelPath) { t = [NSString stringWithFormat:L(@"%@ loaded"), model]; c = OVGreen(); }
    else { t = [NSString stringWithFormat:L(@"Ready · %@"), model]; c = OVGreen(); }
    unsigned long long avail = w.availableMemory ?: [OVMemory availableBytes];
    BOOL engine = w.engineFootprint > 50 * 1024 * 1024;  // a process that is only starting isn't worth a "0.0 GB"
    NSString *mem = engine
        ? [NSString stringWithFormat:L(@"Engine %@ · free %@"), [OVMemory format:w.engineFootprint], [OVMemory format:avail]]
        : [NSString stringWithFormat:L(@"Free memory %@"), [OVMemory format:avail]];
    // "Ready · OmniVoice · Apple MLX": the state in bold, the rest below it
    NSRange dot = [t rangeOfString:@" · "];
    self.footer.stringValue = dot.location == NSNotFound ? t : [t substringToIndex:dot.location];
    self.footerDetail.stringValue = dot.location == NSNotFound ? mem : [NSString stringWithFormat:@"%@\n%@", [t substringFromIndex:NSMaxRange(dot)], mem];
    self.footerIcon.contentTintColor = c;
    double total = (double)NSProcessInfo.processInfo.physicalMemory;
    self.meter.engine = engine ? w.engineFootprint / total : 0;
    self.meter.others = MAX(0, 1 - avail / total - self.meter.engine);
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return self.items.count; }

- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)row {
    NSTableCellView *cell = [t makeViewWithIdentifier:@"cell" owner:self];
    if (!cell) {
        cell = [NSTableCellView new];
        cell.identifier = @"cell";
        NSImageView *iv = [NSImageView new];
        NSTextField *tf = OVLabel(@"", 13.5, NSFontWeightMedium, nil);
        cell.imageView = iv;
        cell.textField = tf;
        NSStackView *s = OVHStack(@[iv, tf], 8);
        [iv.widthAnchor constraintEqualToConstant:20].active = YES;
        [cell addSubview:s];
        OVPin(s, cell, NSEdgeInsetsMake(0, 6, 0, 4));
    }
    NSArray *it = self.items[row];
    cell.textField.stringValue = it[1];
    cell.imageView.image = [NSImage imageWithSystemSymbolName:it[2] accessibilityDescription:it[1]];
    cell.imageView.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightMedium];
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)n {
    NSInteger r = self.table.selectedRow;
    if (r >= 0 && self.onSelect) self.onSelect(self.items[r][0]);
}

- (void)selectPage:(NSString *)page {
    for (NSUInteger i = 0; i < self.items.count; i++)
        if ([self.items[i][0] isEqualToString:page]) {
            if (self.table.selectedRow != (NSInteger)i)
                [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
            return;
        }
}
@end

#pragma mark - Content container

@interface OVContent : NSViewController
@property NSMutableDictionary<NSString *, NSViewController *> *pages;
@property (nullable) NSViewController *current;
@property (nullable, copy) NSString *currentId;
- (void)show:(NSString *)page;
- (void)reset;
@end

@implementation OVContent
- (void)loadView {
    NSView *v = [NSView new];
    v.wantsLayer = YES;
    self.view = v;
    self.pages = [NSMutableDictionary dictionary];
}
- (void)viewDidLayout { [super viewDidLayout]; [self paint]; }
- (void)viewDidChangeEffectiveAppearance { [self paint]; }
- (void)paint {
    [self.view.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self.view.layer.backgroundColor = OVWindowColor().CGColor;
    }];
}
- (void)show:(NSString *)page {
    NSViewController *vc = self.pages[page];
    if (!vc) {
        Class cls = @{@"setup": OVSetupPage.class, @"synth": OVSynthPage.class, @"voices": OVVoicesPage.class,
                      @"models": OVModelsPage.class, @"settings": OVSettingsPage.class, @"log": OVLogPage.class}[page];
        if (!cls) return;
        vc = [cls new];
        self.pages[page] = vc;
        [self addChildViewController:vc];
    }
    if (vc == self.current) return;
    [self.current.view removeFromSuperview];
    [self.view addSubview:vc.view];
    OVPin(vc.view, self.view, NSEdgeInsetsZero);
    self.current = vc;
    self.currentId = page;
    [self paint];
}
/// Drops every page so they are rebuilt (e.g. in another interface language).
- (void)reset {
    NSString *page = self.currentId ?: @"synth";
    [self.current.view removeFromSuperview];
    for (NSViewController *vc in self.pages.allValues) {
        [NSNotificationCenter.defaultCenter removeObserver:vc];
        [vc removeFromParentViewController];
    }
    [self.pages removeAllObjects];
    self.current = nil;
    [self show:page];
}
@end

#pragma mark - App delegate

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property NSWindow *window;
@property OVSidebar *sidebar;
@property OVContent *content;
@property BOOL autoSwitch;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    [OVSettings registerDefaults];
    [NSUserDefaults.standardUserDefaults registerDefaults:@{@"autoPlay": @YES, @"autoSetup": @YES}];
    [OVPaths ensure];
    [OVLocale applyTheme];
    [NSNotificationCenter.defaultCenter addObserverForName:OVLogNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        OVLogAppend(note.userInfo[@"line"]);
    }];
    [OVPaths migrateFromLegacy];
    [self migrateOldVoice];
    [[OVVoices shared] reload];
    [[OVHistory shared] reload];
    [self buildMenu];
    [self buildWindow];

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(navigate:) name:OVNavigateNotification object:nil];
    [nc addObserver:self selector:@selector(readinessChanged) name:OVRuntimeDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(readinessChanged) name:OVModelsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(uiLanguageChanged) name:OVUILanguageDidChangeNotification object:nil];

    self.autoSwitch = YES;
    [self show:@"setup"];
    [OVModels shared];
    [[OVRuntime shared] detect];

    // Developer aid: OV_SNAPSHOT_DIR=/path renders every page to PNG (no screen-recording permission needed).
    // Launch with `-autoSetup NO -disableLegacyMigration YES -migratedFromOmniVoiceUA YES` to keep it side-effect free.
    NSString *snap = NSProcessInfo.processInfo.environment[@"OV_SNAPSHOT_DIR"];
    if (snap.length) [self snapshotPages:@[@"setup", @"synth", @"voices", @"models", @"settings", @"log"] into:snap index:0];

    // Developer aid: OV_SELFTEST_AUDIO=sample.wav OV_SELFTEST_TEXT="transcript" clones a voice and speaks a phrase
    // through the real app classes, prints the results and quits.
    if (NSProcessInfo.processInfo.environment[@"OV_SELFTEST_AUDIO"].length) [self selfTest];
}

- (void)selfTest {
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    void (^say)(NSString *) = ^(NSString *s) { fprintf(stderr, "SELFTEST %s\n", s.UTF8String); };
    if ([OVRuntime shared].state != OVRuntimeReady || ![OVModels shared].ttsModel) {
        [self performSelector:@selector(selfTest) withObject:nil afterDelay:1];
        return;
    }
    {
        OVVoice *v = [[OVVoices shared] createNamed:env[@"OV_SELFTEST_NAME"] ?: @"Selftest"];
        double secs = 0;
        OVConvertToWav(env[@"OV_SELFTEST_AUDIO"], v.referencePath, &secs, nil);
        v.refText = env[@"OV_SELFTEST_TEXT"] ?: @"";
        v.seconds = secs;
        [v save];
        say([NSString stringWithFormat:@"model %@ bits %@ low_memory %d", [OVSettings modelSpec][@"path"], [OVSettings modelSpec][@"bits"], [OVSettings lowMemory]]);
        NSMutableDictionary *clone = [@{@"cmd": @"clone", @"model": [OVSettings modelSpec], @"audio": v.referencePath, @"ref_text": v.refText,
                                        @"out": v.promptPath, @"language": @"auto"} mutableCopy];
        if ([OVModels shared].asrModel) clone[@"asr_path"] = [OVModels shared].asrModel.localPath;
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        [[OVWorker shared] request:clone status:^(NSString *m) { say(m); } progress:nil done:^(NSDictionary *d, NSString *err) {
            say([NSString stringWithFormat:@"clone → %@ %@ (%.1f s)", err ?: @"ok", d, CFAbsoluteTimeGetCurrent() - t0]);
            v.language = d[@"language"];  // auto-detected; a text in another language then goes through accent removal
            v.refText = d[@"ref_text"] ?: v.refText;
            v.seconds = [d[@"seconds"] doubleValue] ?: v.seconds;
            [v save];
            NSString *text = env[@"OV_SELFTEST_SPEAK"] ?: @"Привіт! Це перевірка нового рушія на Apple Silicon.";
            NSString *out = [[OVHistory shared] newOutputPathForText:text];
            NSString *language = [OVLocale speechLanguageForText:text];
            NSMutableDictionary *synth = [@{@"cmd": @"synth", @"model": [OVSettings modelSpec], @"text": text, @"out": out,
                                            @"voice": [v workerSpecForLanguage:language],
                                            @"language": language, @"params": [OVSettings generationParams]} mutableCopy];
            if ([OVModels shared].asrModel)
                synth[@"improve"] = @{@"asr_path": [OVModels shared].asrModel.localPath, @"attempts": @2, @"threshold": @0.08};
            __block double lastP = 0;
            [[OVWorker shared] request:synth status:^(NSString *m) { say(m); } progress:^(double p) { lastP = p; } done:^(NSDictionary *d2, NSString *err2) {
                say([NSString stringWithFormat:@"synth → %@ %@ progress %.2f memory %.2f/%.2f GB", err2 ?: @"ok", d2, lastP,
                     [OVWorker shared].memoryActive, [OVWorker shared].memoryPeak]);
                if (!env[@"OV_SELFTEST_NAME"]) [[OVVoices shared] remove:v]; // named voices are kept (demo data)
                else if (!err2) [[OVHistory shared] record:d2[@"path"] text:text voice:v result:d2];
                [NSApp terminate:nil];
            }];
        }];
    }
}

- (void)snapshotPages:(NSArray *)pages into:(NSString *)dir index:(NSUInteger)i {
    NSTimeInterval delay = i == 0 ? 6 : 1.5;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (i > 0) {
            NSView *v = self.window.contentView;
            NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
            [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
            NSString *file = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.png", pages[i - 1]]];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:file atomically:YES];
        }
        if (i >= pages.count) { [NSApp terminate:nil]; return; }
        [self show:pages[i]];
        [self snapshotPages:pages into:dir index:i + 1];
    });
}

/// On first detection: jump straight to work if everything is already there.
- (void)readinessChanged {
    OVRuntimeState st = [OVRuntime shared].state;
    if (!self.autoSwitch || st == OVRuntimeChecking || st == OVRuntimeUnknown) return;
    self.autoSwitch = NO;
    if (OVEverythingReady()) { [self show:@"synth"]; return; }

    // Nothing usable found: fetch it right away, progress is shown on the setup page.
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"autoSetup"]) return;
    if (st == OVRuntimeMissing) [[OVRuntime shared] install];
    OVModels *mm = [OVModels shared];
    if (!mm.ttsModel) {
        BOOL busy = NO;
        for (OVModel *m in [mm modelsOfKind:OVModelTTS]) busy |= m.downloading;
        for (OVModel *m in [mm modelsOfKind:OVModelTTS])
            if (m.recommended && !busy) [mm download:m];
    }
}

- (void)uiLanguageChanged {
    [self buildMenu];
    [self.sidebar reloadTexts];
    [self.content reset];
    [self.sidebar selectPage:self.content.currentId];
    if (![OVWorker shared].busy) [[OVWorker shared] stop]; // worker messages follow the UI language
}

- (void)navigate:(NSNotification *)n { [self show:n.object]; }

- (void)show:(NSString *)page {
    [self.content show:page];
    [self.sidebar selectPage:page];
}

- (void)buildWindow {
    self.sidebar = [OVSidebar new];
    self.content = [OVContent new];
    __weak typeof(self) w = self;
    self.sidebar.onSelect = ^(NSString *page) { [w.content show:page]; };

    NSSplitViewController *split = [NSSplitViewController new];
    NSSplitViewItem *side = [NSSplitViewItem sidebarWithViewController:self.sidebar];
    side.minimumThickness = 190;
    side.maximumThickness = 250;
    side.canCollapse = NO;
    side.holdingPriority = NSLayoutPriorityDefaultLow + 10; // window resizes grow the content, not the sidebar
    NSSplitViewItem *main = [NSSplitViewItem splitViewItemWithViewController:self.content];
    main.minimumThickness = 540;
    [split addSplitViewItem:side];
    [split addSplitViewItem:main];

    self.window = [NSWindow windowWithContentViewController:split];
    self.window.styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                            NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView;
    self.window.titlebarAppearsTransparent = YES;
    self.window.titleVisibility = NSWindowTitleHidden;
    self.window.title = OVAppName;
    NSToolbar *tb = [[NSToolbar alloc] initWithIdentifier:@"main"];
    tb.showsBaselineSeparator = NO;
    self.window.toolbar = tb;
    self.window.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;
    self.window.delegate = self;
    [self.window setContentSize:NSMakeSize(980, 680)];
    self.window.contentMinSize = NSMakeSize(820, 560);
    [self.window center];
    self.window.frameAutosaveName = @"MainWindow";
    // never taller or wider than the screen (small MacBook Air displays, Stage Manager, …)
    NSRect vis = (self.window.screen ?: NSScreen.mainScreen).visibleFrame;
    NSRect f = self.window.frame;
    f.size.width = MIN(f.size.width, vis.size.width);
    f.size.height = MIN(f.size.height, vis.size.height);
    f.origin.x = MAX(vis.origin.x, MIN(f.origin.x, NSMaxX(vis) - f.size.width));
    f.origin.y = MAX(vis.origin.y, MIN(f.origin.y, NSMaxY(vis) - f.size.height));
    [self.window setFrame:f display:NO];
    [self.window makeKeyAndOrderFront:nil];
    [split.splitView setPosition:208 ofDividerAtIndex:0];
}

/// The first release (REV5) kept one voice in ~/OmniVoice-UA — import it once.
- (void)migrateOldVoice {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d boolForKey:@"migratedV1"]) return;
    [d setBool:YES forKey:@"migratedV1"];
    NSString *old = [NSHomeDirectory() stringByAppendingPathComponent:@"OmniVoice-UA"];
    NSString *pt = [old stringByAppendingPathComponent:@"voice_clone.pt"];
    if (![NSFileManager.defaultManager fileExistsAtPath:pt]) return;
    OVVoice *v = [[OVVoices shared] createNamed:L(@"My voice (previous version)")];
    [NSFileManager.defaultManager copyItemAtPath:pt toPath:v.promptPath error:nil];
    v.refText = [NSString stringWithContentsOfFile:[old stringByAppendingPathComponent:@"reference.txt"] encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSString *ref = [[NSString stringWithContentsOfFile:[old stringByAppendingPathComponent:@"reference.path"] encoding:NSUTF8StringEncoding error:nil]
                     stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    double secs = 0;
    if (ref.length) OVConvertToWav(ref.stringByExpandingTildeInPath, v.referencePath, &secs, nil);
    v.seconds = secs;
    [v save];
    [[OVVoices shared] reload];
    NSString *target = [NSString stringWithContentsOfFile:[old stringByAppendingPathComponent:@"target.txt"] encoding:NSUTF8StringEncoding error:nil];
    if (target.length && ![d stringForKey:@"draftText"]) [d setObject:target forKey:@"draftText"];
}

- (void)buildMenu {
    NSMenu *bar = [NSMenu new];

    NSMenuItem *appItem = [bar addItemWithTitle:@"" action:nil keyEquivalent:@""];
    NSMenu *app = [NSMenu new];
    [app addItemWithTitle:[NSString stringWithFormat:L(@"About %@"), OVAppName] action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [app addItem:NSMenuItem.separatorItem];
    [app addItemWithTitle:L(@"Settings…") action:@selector(showSettings:) keyEquivalent:@","];
    [app addItem:NSMenuItem.separatorItem];
    [app addItemWithTitle:[NSString stringWithFormat:L(@"Hide %@"), OVAppName] action:@selector(hide:) keyEquivalent:@"h"];
    NSMenuItem *others = [app addItemWithTitle:L(@"Hide Others") action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
    others.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [app addItem:NSMenuItem.separatorItem];
    [app addItemWithTitle:[NSString stringWithFormat:L(@"Quit %@"), OVAppName] action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = app;

    NSMenuItem *editItem = [bar addItemWithTitle:L(@"Edit") action:nil keyEquivalent:@""];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:L(@"Edit")];
    [edit addItemWithTitle:L(@"Undo") action:@selector(undo:) keyEquivalent:@"z"];
    [edit addItemWithTitle:L(@"Redo") action:@selector(redo:) keyEquivalent:@"Z"];
    [edit addItem:NSMenuItem.separatorItem];
    [edit addItemWithTitle:L(@"Cut") action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:L(@"Copy") action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:L(@"Paste") action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:L(@"Select All") action:@selector(selectAll:) keyEquivalent:@"a"];
    [edit addItem:NSMenuItem.separatorItem];
    [edit addItemWithTitle:L(@"Stress Mark") action:@selector(toggleStress:) keyEquivalent:@"'"];
    editItem.submenu = edit;

    NSMenuItem *viewItem = [bar addItemWithTitle:L(@"View") action:nil keyEquivalent:@""];
    NSMenu *view = [[NSMenu alloc] initWithTitle:L(@"View")];
    NSArray *themes = @[@[L(@"Light Theme"), @"light"], @[L(@"Dark Theme"), @"dark"], @[L(@"System Theme"), @"system"]];
    for (NSArray *t in themes) {
        NSMenuItem *it = [view addItemWithTitle:t[0] action:@selector(pickTheme:) keyEquivalent:@""];
        it.representedObject = t[1];
        it.target = self;
    }
    [view addItem:NSMenuItem.separatorItem];
    NSArray *langs = @[@[@"English", @"en"], @[@"Русский", @"ru"], @[L(@"System Language"), @"system"]];
    for (NSArray *t in langs) {
        NSMenuItem *it = [view addItemWithTitle:t[0] action:@selector(pickUILanguage:) keyEquivalent:@""];
        it.representedObject = t[1];
        it.target = self;
    }
    viewItem.submenu = view;

    NSMenuItem *goItem = [bar addItemWithTitle:L(@"Go") action:nil keyEquivalent:@""];
    NSMenu *go = [[NSMenu alloc] initWithTitle:L(@"Go")];
    NSArray *pages = @[@[L(@"Speech"), @"1", @"synth"], @[L(@"Voices"), @"2", @"voices"], @[L(@"Models"), @"3", @"models"],
                       @[L(@"Setup"), @"4", @"setup"], @[L(@"Log"), @"5", @"log"]];
    for (NSArray *p in pages) {
        NSMenuItem *it = [go addItemWithTitle:p[0] action:@selector(goPage:) keyEquivalent:p[1]];
        it.representedObject = p[2];
        it.target = self;
    }
    goItem.submenu = go;

    NSMenuItem *winItem = [bar addItemWithTitle:L(@"Window") action:nil keyEquivalent:@""];
    NSMenu *win = [[NSMenu alloc] initWithTitle:L(@"Window")];
    [win addItemWithTitle:L(@"Minimize") action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [win addItemWithTitle:L(@"Close") action:@selector(performClose:) keyEquivalent:@"w"];
    winItem.submenu = win;
    NSApp.windowsMenu = win;

    NSApp.mainMenu = bar;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(pickTheme:))
        item.state = [[OVLocale themeSetting] isEqualToString:item.representedObject] ? NSControlStateValueOn : NSControlStateValueOff;
    if (item.action == @selector(pickUILanguage:))
        item.state = [[OVLocale uiLanguageSetting] isEqualToString:item.representedObject] ? NSControlStateValueOn : NSControlStateValueOff;
    return YES;
}

- (void)pickTheme:(NSMenuItem *)it { [OVLocale setThemeSetting:it.representedObject]; }
- (void)pickUILanguage:(NSMenuItem *)it { [OVLocale setUILanguageSetting:it.representedObject]; }
- (void)goPage:(NSMenuItem *)it { [self show:it.representedObject]; }
- (void)showSettings:(id)s { [self show:@"settings"]; }

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)a { return YES; }

- (void)applicationWillTerminate:(NSNotification *)n {
    [[OVWorker shared] stop];
    [[OVRuntime shared] cancelInstall];
}
@end

int main(int argc, const char *argv[]) {
    signal(SIGPIPE, SIG_IGN); // writing to a worker that has just died must raise an exception, not kill the app
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        AppDelegate *d = [AppDelegate new];
        app.delegate = d;
        [app run];
    }
    return 0;
}
