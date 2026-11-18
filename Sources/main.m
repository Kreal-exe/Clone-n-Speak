#import <Cocoa/Cocoa.h>
#import "OVPages.h"
#import "OVUI.h"
#import "OVTheme.h"
#import "OVLocale.h"
#import "OVRuntime.h"
#import "OVModels.h"
#import "OVWorker.h"
#import "OVStore.h"
#import "OVBatch.h"
#import "OVPlugins.h"
#import "OVPaths.h"
#import "OVMemory.h"
#import "OVPageRegistry.h"
#import "OVDesign.h"
#import "OVJobs.h"
#import "OVProKit.h"
#import "OVAPI.h"
#import "OVBridge.h"

@interface OVSeparatorPage (LaunchSweep)
/// Removes decoded inputs older than a day that no running or retryable task needs (implemented in OVSeparatorPage.m).
+ (void)sweepInputFolder;
@end

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

/// Card behind the sidebar status: surface fill and hairline border from the palette.
@interface OVTintBox : NSView
@end
@implementation OVTintBox
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self.layer.cornerRadius = 10;
        self.layer.borderWidth = 1;
        self.layer.backgroundColor = OVColor(OVRoleSurface).CGColor;
        self.layer.borderColor = OVColor(OVRoleBorder).CGColor;
    }];
}
@end

/// Selected row: a soft accent plate instead of the system blue.
@interface OVSidebarRowView : NSTableRowView
@end
@implementation OVSidebarRowView
- (void)drawSelectionInRect:(NSRect)r {
    if (self.selectionHighlightStyle == NSTableViewSelectionHighlightStyleNone) return;
    [OVColor(OVRoleAccentSoft) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0, 0) xRadius:7.5 yRadius:7.5] fill];
}
- (void)setSelected:(BOOL)selected { [super setSelected:selected]; self.needsDisplay = YES; }
- (BOOL)isEmphasized { return NO; }
@end

/// Page row: icon, title, optional compact "16 GB" badge.
@interface OVSidebarCell : NSTableCellView
@property NSView *proBadge;
@property (copy) NSString *symbolName;
@property (nonatomic) BOOL selectedRow;
@end
@implementation OVSidebarCell
- (void)setSelectedRow:(BOOL)sel {
    _selectedRow = sel;
    [self restyle];
}
- (void)restyle {
    // Selected text stays OVRoleText: the neutral Applio accent (#9e9e9e) on its soft plate is dimmer than unselected rows.
    self.textField.textColor = OVColor(OVRoleText);
    // Image tint is not re-resolved by AppKit: resolve the dynamic color under this view's appearance.
    __block NSColor *tint;
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        tint = [OVColor(self.selectedRow ? OVRoleText : OVRoleMuted) colorUsingType:NSColorTypeComponentBased] ?: OVColor(OVRoleMuted);
        tint = [NSColor colorWithCGColor:OVColor(self.selectedRow ? OVRoleText : OVRoleMuted).CGColor] ?: tint;
    }];
    self.imageView.contentTintColor = nil;
    if (self.symbolName) {   // palette-colored symbol: a plain tint renders near-black under the sidebar's vibrancy
        NSImageSymbolConfiguration *cfg = [[NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightRegular]
            configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[tint]]];
        self.imageView.image = [[NSImage imageWithSystemSymbolName:self.symbolName accessibilityDescription:nil] imageWithSymbolConfiguration:cfg];
    }
}
- (void)viewDidChangeEffectiveAppearance { [self restyle]; }
- (void)viewDidMoveToWindow { [self restyle]; }
@end

@interface OVSidebar : NSViewController <NSTableViewDataSource, NSTableViewDelegate>
@property NSTableView *table;
@property NSArray<NSDictionary *> *items;   // group header: @{@"group"}, page: registry entry + @"groupTitle"
@property NSTextField *footer, *footerDetail, *tagline;
@property NSImageView *footerIcon;
@property OVMemoryMeter *meter;
@property NSButton *themeButton;
@property NSView *statusCard;
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
    self.table.rowHeight = 32;
    self.table.intercellSpacing = NSMakeSize(0, 2);
    self.table.floatsGroupRows = NO;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.backgroundColor = NSColor.clearColor;
    NSScrollView *sv = [NSScrollView new];
    sv.documentView = self.table;
    sv.drawsBackground = NO;
    sv.hasVerticalScroller = YES;
    sv.autohidesScrollers = YES;
    sv.scrollerStyle = NSScrollerStyleOverlay;
    self.table.accessibilityLabel = L(@"Pages");

    NSImageView *logo = [NSImageView imageViewWithImage:NSApp.applicationIconImage];
    logo.imageScaling = NSImageScaleProportionallyUpOrDown;
    logo.accessibilityElement = NO;
    [logo.widthAnchor constraintEqualToConstant:32].active = YES;
    [logo.heightAnchor constraintEqualToConstant:32].active = YES;
    NSTextField *brand = OVLabel(OVAppName, 14, NSFontWeightBold, OVColor(OVRoleText));
    brand.font = OVRoundedFont(14, NSFontWeightBold);
    brand.lineBreakMode = NSLineBreakByTruncatingTail;
    [brand setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSString *ver = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSView *verBadge = OVCompactBadge([@"v" stringByAppendingString:ver], OVRoleMuted);
    self.tagline = OVWrapLabel(@"", 10.5, NSColor.secondaryLabelColor);  // kept as the brand tooltip
    [verBadge setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    verBadge.accessibilityElement = NO;
    brand.accessibilityLabel = [NSString stringWithFormat:@"%@ %@", OVAppName, ver];
    NSStackView *head = OVHStack(@[logo, brand, verBadge], 7);
    head.alignment = NSLayoutAttributeCenterY;

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
        [head.topAnchor constraintEqualToAnchor:root.topAnchor constant:44],
        [head.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:16],
        [head.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-10],
        [sv.topAnchor constraintEqualToAnchor:head.bottomAnchor constant:10],
        [sv.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [sv.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [sv.bottomAnchor constraintEqualToAnchor:foot.topAnchor constant:-10],
        [foot.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:12],
        [foot.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-12],
        [foot.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-12],
        [root.widthAnchor constraintGreaterThanOrEqualToConstant:220],
    ]];
    self.view = root;
    self.statusCard = foot;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(themeChanged) name:OVThemeDidChangeNotification object:nil];
    for (NSNotificationName n in @[OVRuntimeDidChangeNotification, OVModelsDidChangeNotification, OVWorkerDidChangeNotification,
                                   OVWorkerMemoryDidChangeNotification])
        [nc addObserver:self selector:@selector(refreshFooter) name:n object:nil];
    [self reloadTexts];
}

- (void)reloadTexts {
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *g in [OVPageRegistry groups]) {
        [items addObject:@{@"group": g[@"title"]}];
        for (NSDictionary *p in g[@"pages"]) {
            NSMutableDictionary *e = [p mutableCopy];
            e[@"groupTitle"] = g[@"title"];
            [items addObject:e];
        }
    }
    self.items = items;
    self.tagline.stringValue = L(@"voice cloning · 600+ languages");
    self.view.toolTip = self.tagline.stringValue;
    NSInteger sel = self.table.selectedRow;
    [self.table reloadData];
    if (sel >= 0 && sel < (NSInteger)items.count) [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:sel] byExtendingSelection:NO];
    [self refreshThemeButton];
    [self refreshFooter];
}

- (void)viewDidChangeEffectiveAppearance { [self refreshThemeButton]; }

- (void)themeChanged {
    self.statusCard.needsDisplay = YES;
    // palette-colored icons and tracked header strings bake in colors: rebuild the visible rows
    NSInteger sel = self.table.selectedRow;
    [self.table reloadData];
    if (sel >= 0) [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:sel] byExtendingSelection:NO];
    [self refreshFooter];
}

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
    // OV_SNAPSHOT_DIR runs need reproducible pictures: a fixed memory reading instead of the live one
    BOOL frozen = [NSProcessInfo.processInfo.environment[@"OV_SNAPSHOT_DIR"] length] > 0;
    unsigned long long avail = frozen ? 8ull << 30 : (w.availableMemory ?: [OVMemory availableBytes]);
    BOOL engine = !frozen && w.engineFootprint > 50 * 1024 * 1024;  // a process that is only starting isn't worth a "0.0 GB"
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

- (BOOL)tableView:(NSTableView *)t isGroupRow:(NSInteger)row { return self.items[row][@"group"] != nil; }
- (BOOL)tableView:(NSTableView *)t shouldSelectRow:(NSInteger)row { return self.items[row][@"group"] == nil; }
- (CGFloat)tableView:(NSTableView *)t heightOfRow:(NSInteger)row {
    if (self.items[row][@"group"] == nil) return 32;
    return row == 0 ? 26 : 32;   // room above every header but the first
}

- (NSTableRowView *)tableView:(NSTableView *)t rowViewForRow:(NSInteger)row {
    NSDictionary *it = self.items[row];
    if (it[@"group"]) {
        NSTableRowView *rv = [NSTableRowView new];
        rv.accessibilityRole = NSAccessibilityStaticTextRole;
        rv.accessibilityLabel = it[@"group"];
        return rv;
    }
    OVSidebarRowView *rv = [OVSidebarRowView new];
    NSString *label = [NSString stringWithFormat:@"%@, %@", it[@"title"], it[@"groupTitle"]];
    if ([it[@"pro"] boolValue]) label = [label stringByAppendingFormat:@", %@", L(@"needs 16 GB")];
    rv.accessibilityLabel = label;
    return rv;
}

- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)row {
    NSDictionary *it = self.items[row];
    if (it[@"group"]) {
        NSTableCellView *cell = [t makeViewWithIdentifier:@"group" owner:self];
        if (!cell) {
            cell = [NSTableCellView new];
            cell.identifier = @"group";
            NSTextField *tf = OVLabel(@"", 11, NSFontWeightSemibold, OVColor(OVRoleMuted));
            tf.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:tf];
            cell.textField = tf;
            [NSLayoutConstraint activateConstraints:@[
                [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:8],
                [tf.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-4],
                [tf.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor constant:-3]]];
        }
        // 11 pt, semibold, caps, +0.05 em tracking
        cell.textField.attributedStringValue = [[NSAttributedString alloc] initWithString:[it[@"group"] uppercaseString] attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName: OVColor(OVRoleMuted),
            NSKernAttributeName: @0.55}];
        return cell;
    }
    OVSidebarCell *cell = [t makeViewWithIdentifier:@"cell" owner:self];
    if (!cell) {
        cell = [OVSidebarCell new];
        cell.identifier = @"cell";
        NSImageView *iv = [NSImageView new];
        iv.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightRegular];
        NSTextField *tf = OVLabel(@"", 13.5, NSFontWeightMedium, nil);
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        [tf setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        cell.imageView = iv;
        cell.textField = tf;
        // monochrome grey pill, right-aligned so all pills line up; the title truncates first
        NSView *badge = OVCompactBadge(L(@"16 GB"), OVRoleMuted);
        badge.toolTip = L(@"This feature is meant for Macs with 16 GB of memory or more. On a Mac with less it may run out of memory.");
        badge.accessibilityElement = NO;   // the row label already says "needs 16 GB"
        cell.proBadge = badge;
        for (NSView *v in @[iv, tf, badge]) { v.translatesAutoresizingMaskIntoConstraints = NO; [cell addSubview:v]; }
        [NSLayoutConstraint activateConstraints:@[
            [iv.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:8],
            [iv.widthAnchor constraintEqualToConstant:18],
            [iv.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [tf.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:9],
            [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [badge.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
            [badge.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [tf.trailingAnchor constraintLessThanOrEqualToAnchor:badge.leadingAnchor constant:-6]]];
    }
    cell.textField.stringValue = it[@"title"];
    cell.symbolName = it[@"symbol"];
    cell.proBadge.hidden = ![it[@"pro"] boolValue];
    cell.selectedRow = row == t.selectedRow;
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)n {
    NSInteger r = self.table.selectedRow;
    for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
        OVSidebarCell *c = [self.table viewAtColumn:0 row:i makeIfNecessary:NO];
        if ([c isKindOfClass:OVSidebarCell.class]) c.selectedRow = i == r;
    }
    if (r >= 0 && self.onSelect) self.onSelect(self.items[r][@"id"]);
}

- (void)selectPage:(NSString *)page {
    for (NSUInteger i = 0; i < self.items.count; i++)
        if ([self.items[i][@"id"] isEqualToString:page]) {
            if (self.table.selectedRow != (NSInteger)i)
                [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
            return;
        }
    [self.table deselectAll:nil];   // a page that is not in the sidebar (Log, gallery)
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
        Class cls = [OVPageRegistry classForPage:page];
        if (!cls) return;
        vc = [cls new];
        if ([vc isKindOfClass:OVPlaceholderPage.class]) ((OVPlaceholderPage *)vc).pageId = page;
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

static NSRect OVDefaultWindowFrame(NSScreen *screen) {
    NSRect vis = screen.visibleFrame;
    CGFloat w = MIN(MAX(vis.size.width * 0.80, 1100), 1600);
    CGFloat h = MIN(MAX(vis.size.height * 0.88, 720), 1100);
    w = MIN(w, vis.size.width - 16);   // small screens scale the window down below the clamps, 8 pt margin each side
    h = MIN(h, vis.size.height - 16);
    return NSMakeRect(NSMidX(vis) - w / 2, NSMidY(vis) - h / 2, round(w), round(h));
}

static NSScreen *OVScreenForFrame(NSRect f) {
    for (NSScreen *s in NSScreen.screens)
        if (NSContainsRect(s.visibleFrame, f)) return s;
    return NSScreen.mainScreen ?: NSScreen.screens.firstObject;
}

/// The default frame of the screen the window will appear on; the saved origin (OVWindowOrigin) is kept only when
/// the whole window then fits on a connected screen, otherwise the window is centred on the main screen.
static NSRect OVInitialWindowFrame(void) {
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:@"OVWindowOrigin"];
    if (saved.length) {
        NSPoint o = NSPointFromString(saved);
        for (NSScreen *s in NSScreen.screens) {
            NSRect f = OVDefaultWindowFrame(s);
            f.origin = o;
            if (NSContainsRect(s.visibleFrame, f)) return f;
        }
    }
    return OVDefaultWindowFrame(NSScreen.mainScreen ?: NSScreen.screens.firstObject);
}

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property NSWindow *window;
@property OVSidebar *sidebar;
@property OVContent *content;
@property BOOL autoSwitch;
@property BOOL closedWithWork;   // the last window was closed while background work ran
@end

static void OVRedrawTree(NSView *v) {
    v.needsDisplay = YES;
    v.needsLayout = YES;
    for (NSView *sub in v.subviews) OVRedrawTree(sub);
}

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    [OVSettings registerDefaults];
    [NSUserDefaults.standardUserDefaults registerDefaults:@{@"autoPlay": @YES, @"autoSetup": @YES}];
    [OVPaths ensure];
    [OVLocale applyTheme];
    // Colors are dynamic: a palette change only needs the whole view tree redrawn.
    [NSNotificationCenter.defaultCenter addObserverForName:OVThemeDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        for (NSWindow *w in NSApp.windows) OVRedrawTree(w.contentView);
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:OVLogNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        OVLogAppend(note.userInfo[@"line"]);
    }];
    [OVPaths migrateFromLegacy];
    [self migrateOldVoice];
    [[OVVoices shared] reload];
    [[OVHistory shared] reload];
    [OVJobs registerBuiltinKinds];
    [OVProKit registerKinds];
    [OVSeparatorPage sweepInputFolder];
    [OVBridge.shared cleanupOrphans];               // a tunnel an earlier crash left behind; Bridge itself never starts here
    [OVAPI.shared startIfEnabled];
    OVBatchRegister();
    [OVPlugins shared];   // registers the plugin job kind
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(jobsChanged:) name:OVJobsDidChangeNotification object:nil];
    [self buildMenu];
    [self buildWindow];

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(navigate:) name:OVNavigateNotification object:nil];
    [nc addObserver:self selector:@selector(readinessChanged) name:OVRuntimeDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(readinessChanged) name:OVModelsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(uiLanguageChanged) name:OVUILanguageDidChangeNotification object:nil];

    self.autoSwitch = YES;
    [self show:@"setup"];
    // Developer aid: -OVStartPage gallery opens a page that is not in the sidebar.
    NSString *start = [NSUserDefaults.standardUserDefaults stringForKey:@"OVStartPage"];
    if (start.length) { self.autoSwitch = NO; [self show:start]; }
    [OVModels shared];
    [[OVRuntime shared] detect];

    // Developer aid: OV_SNAPSHOT_DIR=/path renders every page to PNG (no screen-recording permission needed).
    // Launch with `-autoSetup NO -disableLegacyMigration YES -migratedFromOmniVoiceUA YES` to keep it side-effect free.
    // OV_SNAPSHOT_SIZE=WxH sets the content size first, OV_SNAPSHOT_PAGES=synth,voices limits the pages,
    // OV_SNAPSHOT_FLIP=<paletteId> adds <page>-flip.png taken after switching to that palette on the fly,
    // -OVA11yDump YES prints the accessibility tree of the shown page(s) to stderr.
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    NSString *snap = env[@"OV_SNAPSHOT_DIR"];
    NSString *size = env[@"OV_SNAPSHOT_SIZE"];
    if (size.length) {
        NSArray *wh = [size.lowercaseString componentsSeparatedByString:@"x"];
        CGFloat w = wh.count == 2 ? [wh[0] doubleValue] : 0, h = wh.count == 2 ? [wh[1] doubleValue] : 0;
        if (w >= 200 && h >= 200) {
            self.window.contentMinSize = NSMakeSize(MIN(self.window.contentMinSize.width, w), MIN(self.window.contentMinSize.height, h));
            [self.window setContentSize:NSMakeSize(w, h)];
        } else NSLog(@"OV_SNAPSHOT_SIZE=%@ is not WxH", size);
    }
    NSArray<NSString *> *snapPages = [OVPageRegistry allPageIds];
    if ([env[@"OV_SNAPSHOT_PAGES"] length]) {
        NSMutableArray *only = [NSMutableArray array];
        for (NSString *pg in [env[@"OV_SNAPSHOT_PAGES"] componentsSeparatedByString:@","]) {
            NSString *t = [pg stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if ([snapPages containsObject:t]) [only addObject:t]; else if (t.length) NSLog(@"OV_SNAPSHOT_PAGES: unknown page %@", t);
        }
        snapPages = only;
    }
    if (snap.length) [self snapshotPages:snapPages into:snap index:0];
    else if ([NSUserDefaults.standardUserDefaults boolForKey:@"OVA11yDump"])
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self dumpAccessibility]; });

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
            v.accented = [d[@"accent"][@"accented"] boolValue];
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

static void OVDumpAX(id el, int depth, NSMutableSet *seen) {
    if (depth > 40 || !el) return;
    NSValue *key = [NSValue valueWithNonretainedObject:el];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    NSString *role = [el respondsToSelector:@selector(accessibilityRole)] ? [el accessibilityRole] : nil;
    BOOL isView = [el isKindOfClass:NSView.class];
    if (role.length && (!isView || [el isAccessibilityElement] || ![role isEqualToString:NSAccessibilityGroupRole])) {
        id v = [el respondsToSelector:@selector(accessibilityValue)] ? [el accessibilityValue] : nil;
        fprintf(stderr, "A11Y %*s%s label=%s value=%s\n", depth * 2, "", role.UTF8String,
                [[el accessibilityLabel] ?: @"-" UTF8String], [[v description] ?: @"-" UTF8String]);
    }
    NSArray *kids = [el respondsToSelector:@selector(accessibilityChildren)] ? [el accessibilityChildren] : nil;
    if (!kids.count && isView) kids = [el subviews];
    for (id k in kids) OVDumpAX(k, depth + 1, seen);
}

/// -OVA11yDump YES: role / label / value of every accessible element of the page that is shown.
- (void)dumpAccessibility {
    fprintf(stderr, "A11Y page=%s\n", self.content.currentId.UTF8String);
    OVDumpAX(self.content.current.view, 0, [NSMutableSet set]);
    fflush(stderr);
}

/// Overlay scrollers fade in and out on their own: switch them off so two runs give the same pixels.
static void OVHideScrollers(NSView *v) {
    if ([v isKindOfClass:NSScrollView.class]) {
        ((NSScrollView *)v).hasVerticalScroller = NO;
        ((NSScrollView *)v).hasHorizontalScroller = NO;
    }
    for (NSView *c in v.subviews) OVHideScrollers(c);
}

static void OVWriteSnapshot(NSView *v, NSString *file) {
    OVHideScrollers(v);
    [v displayIfNeeded];
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:file atomically:YES];
}

- (void)snapshotPages:(NSArray *)pages into:(NSString *)dir index:(NSUInteger)i {
    NSTimeInterval delay = i == 0 ? 6 : 1.5;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        void (^next)(void) = ^{
            if (i >= pages.count) { [NSApp terminate:nil]; return; }
            [self show:pages[i]];
            [self snapshotPages:pages into:dir index:i + 1];
        };
        if (i == 0) { next(); return; }
        NSString *page = pages[i - 1];
        NSView *v = self.window.contentView;
        OVWriteSnapshot(v, [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.png", page]]);
        // A page taller than the window also gets <page>-2.png, <page>-3.png … (scrolled one screen at a time).
        // Only inside the page (not the sidebar's scroll view): the widest taller-than-visible scroll view wins.
        NSScrollView *sv = nil;
        NSMutableArray<NSView *> *todo = [NSMutableArray arrayWithObject:self.content.current.view ?: v];
        while (todo.count) {
            NSView *c = todo.firstObject;
            [todo removeObjectAtIndex:0];
            if ([c isKindOfClass:NSScrollView.class] && NSHeight(((NSScrollView *)c).documentView.frame) > NSHeight(c.bounds) + 4
                && (!sv || NSWidth(c.bounds) * NSHeight(c.bounds) > NSWidth(sv.bounds) * NSHeight(sv.bounds))) sv = (NSScrollView *)c;
            [todo addObjectsFromArray:c.subviews];
        }
        if (sv) {
            CGFloat step = NSHeight(sv.contentView.bounds) - 40, max = NSHeight(sv.documentView.frame) - NSHeight(sv.contentView.bounds);
            for (int n = 2; n <= 8 && step > 0; n++) {
                CGFloat y = MIN((n - 1) * step, max);
                [sv.contentView scrollToPoint:NSMakePoint(0, y)];
                [sv reflectScrolledClipView:sv.contentView];
                OVWriteSnapshot(v, [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%d.png", page, n]]);
                if (y >= max) break;
            }
            [sv.contentView scrollToPoint:NSZeroPoint];
            [sv reflectScrolledClipView:sv.contentView];
        }
        if ([NSUserDefaults.standardUserDefaults boolForKey:@"OVA11yDump"]) [self dumpAccessibility];
        // OV_SNAPSHOT_FLIP: switch the palette on the fly, give the redraw 0.6 s, shoot <page>-flip.png, switch back.
        NSString *flip = NSProcessInfo.processInfo.environment[@"OV_SNAPSHOT_FLIP"];
        if (flip.length && ![flip isEqualToString:OVTheme.paletteId]) {
            NSString *orig = OVTheme.paletteId;
            [OVTheme setPaletteId:flip];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                OVWriteSnapshot(v, [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-flip.png", page]]);
                [OVTheme setPaletteId:orig];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), next);
            });
            return;
        }
        next();
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

- (void)windowDidMove:(NSNotification *)n {
    if (n.object != self.window) return;
    [NSUserDefaults.standardUserDefaults setObject:NSStringFromPoint(self.window.frame.origin) forKey:@"OVWindowOrigin"];
}

- (void)buildWindow {
    self.sidebar = [OVSidebar new];
    self.content = [OVContent new];
    __weak typeof(self) w = self;
    self.sidebar.onSelect = ^(NSString *page) { [w.content show:page]; };

    NSSplitViewController *split = [NSSplitViewController new];
    NSSplitViewItem *side = [NSSplitViewItem sidebarWithViewController:self.sidebar];
    side.minimumThickness = 220;
    side.maximumThickness = 270;
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
    self.window.releasedWhenClosed = NO;   // the window comes back on a click on the Dock icon while tasks run
    NSToolbar *tb = [[NSToolbar alloc] initWithIdentifier:@"main"];
    tb.showsBaselineSeparator = NO;
    self.window.toolbar = tb;
    self.window.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;
    self.window.delegate = self;
    // Opens at a size derived from the screen on every launch; only the position is remembered.
    NSRect frame = OVInitialWindowFrame();
    NSRect vis = OVScreenForFrame(frame).visibleFrame;
    self.window.contentMinSize = NSMakeSize(MIN(820, vis.size.width - 16), MIN(560, vis.size.height - 16));
    [self.window setFrame:frame display:NO];
    [self.window makeKeyAndOrderFront:nil];
    [split.splitView setPosition:236 ofDividerAtIndex:0];
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
    NSUInteger n = 0;   // ⌘1…⌘9 go to the first nine sidebar pages; groups are separated by a line
    for (NSDictionary *g in [OVPageRegistry groups]) {
        if (go.numberOfItems) [go addItem:NSMenuItem.separatorItem];
        for (NSDictionary *p in g[@"pages"]) {
            NSMenuItem *it = [go addItemWithTitle:p[@"title"] action:@selector(goPage:) keyEquivalent:++n <= 9 ? [NSString stringWithFormat:@"%lu", (unsigned long)n] : @""];
            it.representedObject = p[@"id"];
            it.target = self;
        }
    }
    goItem.submenu = go;

    NSMenuItem *winItem = [bar addItemWithTitle:L(@"Window") action:nil keyEquivalent:@""];
    NSMenu *win = [[NSMenu alloc] initWithTitle:L(@"Window")];
    [win addItemWithTitle:L(@"Minimize") action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [win addItemWithTitle:L(@"Close") action:@selector(performClose:) keyEquivalent:@"w"];
    [win addItem:NSMenuItem.separatorItem];
    NSMenuItem *logItem = [win addItemWithTitle:L(@"Log") action:@selector(goPage:) keyEquivalent:@"l"];
    logItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    logItem.representedObject = @"log";
    logItem.target = self;
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

/// Closing the last window ends the app, unless tasks are running (and, from 8.6, while the local API is on):
/// they go on in the background with the Dock icon, and a click on it opens the window again.
/// Work that keeps the app alive without a window. 8.6 adds the local API ([OVAPI shared].enabled) here.
- (BOOL)hasBackgroundWork {
    return OVJobs.shared.activeCount > 0 || OVAPI.shared.enabled;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a {
    self.closedWithWork = [self hasBackgroundWork];
    return !self.closedWithWork;
}

/// The window was closed while tasks ran: quit when the last one ends, unless the window came back.
- (void)jobsChanged:(NSNotification *)n {
    if (!self.closedWithWork || self.window.isVisible || self.window.isMiniaturized || [self hasBackgroundWork]) return;
    for (NSWindow *w in NSApp.windows) if (w.isVisible && w.canBecomeMainWindow) return;
    [NSApp terminate:nil];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)a hasVisibleWindows:(BOOL)visible {
    if (self.window.isMiniaturized) [self.window deminiaturize:nil];
    self.closedWithWork = NO;
    if (!visible) [self.window makeKeyAndOrderFront:nil];
    return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)a {
    NSUInteger n = OVJobs.shared.activeCount;
    if (n == 0) return NSTerminateNow;
    NSAlert *alert = [NSAlert new];
    alert.messageText = n == 1 ? L(@"1 task is running") : [NSString stringWithFormat:L(@"%lu tasks are running"), (unsigned long)n];
    alert.informativeText = L(@"If you quit now, the running tasks are stopped and their unfinished files are deleted.");
    [alert addButtonWithTitle:L(@"Cancel")];   // the default button: Return keeps the work
    [alert addButtonWithTitle:L(@"Stop and quit")];
    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] != NSAlertSecondButtonReturn) return NSTerminateCancel;
    [OVJobs.shared stopAllAndWait:3];
    return NSTerminateNow;
}
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)a { return YES; }

- (void)applicationWillTerminate:(NSNotification *)n {
    [OVBridge.shared shutdown];                    // the tunnel goes before the server it points to
    [OVAPI.shared stop];
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
