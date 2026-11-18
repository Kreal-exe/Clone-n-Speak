// Data & Privacy: what stays on this Mac, what can go online, where the files live, and the rules for voices.
#import "OVPages.h"
#import "OVDesign.h"
#import "OVPaths.h"
#import "OVLocale.h"
#import "OVNetwork.h"
#import "OVPrivacyCatalog.h"
#import "OVStore.h"
#import "OVJobs.h"
#import "OVWorker.h"

@interface OVPrivacyPage ()
@property (nonatomic) NSMutableDictionary<NSString *, NSNumber *> *sizes;          // location id -> bytes (absent = not counted yet)
@property (nonatomic) NSMutableDictionary<NSString *, NSTextField *> *sizeLabels;
@property (nonatomic, copy) NSString *confirming;                                 // location id, @"all1", @"all2" or nil
@property (nonatomic) NSInteger generation;                                       // bumped to cancel a running count
@property (nonatomic) NSScrollView *scroll;
@property (nonatomic) BOOL freshlyBuilt, lastBusy;
@end

static OVNetFeature FeatureForId(NSString *ident) {
    for (OVNetFeature f = OVNetEdgeTTS; f <= OVNetPluginNetwork; f++)
        if ([[OVNetwork identifierFor:f] isEqualToString:ident]) return f;
    return OVNetModelDownload;
}

static NSTextField *Muted(NSString *t, CGFloat size) { return OVWrapLabel(t, size, OVColor(OVRoleMuted)); }

static NSTextField *Strong(NSString *t) {
    NSTextField *l = OVWrapLabel(t, 14, nil);
    l.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    return l;
}

/// Total size of the regular files under `path`; stops early (returns -1) when `cancelled` says so.
static long long TreeSize(NSString *path, BOOL (^cancelled)(void)) {
    NSURL *root = [NSURL fileURLWithPath:path];
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtURL:root
        includingPropertiesForKeys:@[NSURLTotalFileAllocatedSizeKey, NSURLIsRegularFileKey] options:0 errorHandler:^BOOL(NSURL *u, NSError *err) { return YES; }];
    long long total = 0;
    NSUInteger n = 0;
    for (NSURL *u in e) {
        if ((++n & 255) == 0 && cancelled()) return -1;
        NSNumber *reg = nil, *size = nil;
        [u getResourceValue:&reg forKey:NSURLIsRegularFileKey error:nil];
        if (!reg.boolValue) continue;
        [u getResourceValue:&size forKey:NSURLTotalFileAllocatedSizeKey error:nil];
        total += size.longLongValue;
    }
    return total;
}

@implementation OVPrivacyPage

- (void)loadView {
    self.sizes = [NSMutableDictionary dictionary];
    self.sizeLabels = [NSMutableDictionary dictionary];
    self.view = [NSView new];
    [self rebuild];
    self.freshlyBuilt = YES;   // viewWillAppear then does not build a second time
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(busyMayHaveChanged:) name:OVJobsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(busyMayHaveChanged:) name:OVWorkerDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stateChanged:) name:OVNetworkModeDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stateChanged:) name:OVUILanguageDidChangeNotification object:nil];
}

- (void)dealloc { self.generation++; [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)viewWillAppear {
    [super viewWillAppear];
    if (self.freshlyBuilt) self.freshlyBuilt = NO; else [self rebuild];
}
- (void)viewDidAppear { [super viewDidAppear]; [self startCounting]; }
- (void)viewDidDisappear {   // a running count notices and stops; a half-answered question is dropped
    [super viewDidDisappear];
    self.generation++;
    self.confirming = nil;
}
/// Folders in use by a running task or the engine cannot be deleted from under it.
- (BOOL)appIsBusy { return OVJobs.shared.activeCount > 0 || OVWorker.shared.busy; }
- (void)busyMayHaveChanged:(NSNotification *)n {
    if (self.viewLoaded && self.lastBusy != [self appIsBusy]) [self rebuild];
}
- (void)stateChanged:(NSNotification *)n { if (self.viewLoaded) [self rebuild]; }

#pragma mark - Sizes

- (void)startCounting {
    NSInteger gen = ++self.generation;
    for (NSDictionary *loc in [OVPrivacyCatalog locations]) {
        NSString *ident = loc[@"id"], *path = loc[@"path"];
        __weak OVPrivacyPage *weak = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            long long bytes = TreeSize(path, ^BOOL { return weak == nil || weak.generation != gen; });
            if (bytes < 0) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                OVPrivacyPage *me = weak;
                if (!me || me.generation != gen) return;
                me.sizes[ident] = @(bytes);
                me.sizeLabels[ident].stringValue = OVFormatBytes(bytes);
            });
        });
    }
}

#pragma mark - Layout

- (void)rebuild {
    NSPoint scrollOrigin = self.scroll ? self.scroll.contentView.bounds.origin : NSZeroPoint;
    self.lastBusy = [self appIsBusy];
    [self.scroll removeFromSuperview];
    [self.sizeLabels removeAllObjects];
    NSView *header = OVPageHeader(L(@"Data & Privacy"), L(@"What stays on this Mac, what can go online, and where your files live."), nil);
    self.scroll = OVPageScroll(@[header, [self thisMacCard], [self onlineCard], [self filesCard], [self rightsCard]]);
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.scroll];
    OVPin(self.scroll, self.view, NSEdgeInsetsZero);
    [self.view layoutSubtreeIfNeeded];
    [self.scroll.contentView scrollToPoint:scrollOrigin];
    [self.scroll reflectScrolledClipView:self.scroll.contentView];
}

- (NSView *)thisMacCard {
    NSTextField *text = Muted(L(@"Voices, recordings, models and history stay on this Mac. Nothing is uploaded unless you use a feature marked Online."), 14);
    BOOL off = OVNetwork.offline;
    NSView *status = OVBadge(off ? L(@"Offline mode is on") : L(@"Offline mode is off"), off ? OVRoleOK : OVRoleMuted);
    status.accessibilityLabel = off ? L(@"Offline mode is on") : L(@"Offline mode is off");
    NSButton *settings = OVGhostButton(L(@"Open Settings"), @"gearshape", self, @selector(openSettings:));
    settings.accessibilityLabel = L(@"Open Offline mode settings");
    NSStackView *row = OVHStack(@[status, settings, OVSpacer()], 12);
    NSStackView *col = OVVStack(@[text, row], 12);
    OVFillWidth(@[text], col);
    return OVStepCard(1, @"internaldrive", L(@"On this Mac"), nil, col);
}

- (NSView *)onlineCard {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *e in [OVPrivacyCatalog networkEntries]) [rows addObject:[self networkRow:e]];
    NSStackView *col = OVVStack(rows, 16);
    OVFillWidth(rows, col);
    return OVStepCard(2, @"network", L(@"What goes online"), L(@"Features that talk to other servers. Everything else works without a connection."), col);
}

- (NSView *)networkRow:(NSDictionary *)e {
    NSString *ident = e[@"id"];
    BOOL consent = [e[@"consent"] boolValue];
    BOOL granted = consent && [OVNetwork hasConsentFor:FeatureForId(ident)];
    NSString *flag = [@"privacyRevoked." stringByAppendingString:ident];
    if (granted) [NSUserDefaults.standardUserDefaults removeObjectForKey:flag];
    BOOL revoked = consent && !granted && [NSUserDefaults.standardUserDefaults boolForKey:flag];
    NSString *status = !consent ? L(@"Asked") : (granted ? L(@"Allowed") : (revoked ? L(@"Not allowed") : L(@"Never used")));
    NSView *badge = OVBadge(status, granted ? OVRoleOK : (consent ? OVRoleMuted : OVRoleAccent));
    badge.accessibilityLabel = [NSString stringWithFormat:@"%@: %@", e[@"title"], status];
    badge.toolTip = consent ? L(@"Allowed means you agreed. Never used and Not allowed mean nothing is sent, and you are asked first.")
                            : L(@"Asked means it only runs when you press a download or install button.");
    NSMutableArray *right = [NSMutableArray arrayWithObject:badge];
    if (granted) {
        NSButton *revoke = OVSmallPill(OVGhostButton(L(@"Revoke consent"), nil, self, @selector(revoke:)));
        revoke.identifier = ident;
        revoke.accessibilityLabel = [NSString stringWithFormat:L(@"Revoke consent for %@"), e[@"title"]];
        [right addObject:revoke];
    }
    NSStackView *actions = OVHStack(right, 8);
    NSTextField *title = Strong(e[@"title"]);
    NSTextField *to = Muted([NSString stringWithFormat:L(@"To: %@"), e[@"destination"]], 13);
    NSTextField *sends = Muted([NSString stringWithFormat:L(@"Sends: %@"), e[@"sends"]], 13);
    NSTextField *when = Muted(e[@"when"], 13);
    NSStackView *texts = OVVStack(@[title, to, sends, when], 2);
    OVFillWidth(texts.arrangedSubviews, texts);
    [texts setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [texts setContentCompressionResistancePriority:250 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *row = OVHStack(@[texts, actions], 12);
    row.alignment = NSLayoutAttributeTop;
    return row;
}

- (NSView *)filesCard {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *loc in [OVPrivacyCatalog locations]) [rows addObject:[self locationRow:loc]];
    [rows addObject:[self deleteAllBlock]];
    NSStackView *col = OVVStack(rows, 18);
    OVFillWidth(rows, col);
    return OVStepCard(3, @"folder", L(@"Where your files live"), nil, col);
}

+ (NSSet<NSString *> *)busyFolders { return [NSSet setWithArray:@[@"voices", @"outputs", @"engines", @"rvc", @"plugins", @"api", @"bridge"]]; }

- (NSView *)locationRow:(NSDictionary *)loc {
    NSString *ident = loc[@"id"], *path = loc[@"path"];
    BOOL deletable = [loc[@"deletable"] boolValue];
    NSTextField *title = Strong(loc[@"title"]);
    NSTextField *where = OVLabel(path, 12, NSFontWeightRegular, OVColor(OVRoleMuted));
    where.lineBreakMode = NSLineBreakByTruncatingMiddle;
    where.selectable = YES;
    where.toolTip = path;
    NSNumber *known = self.sizes[ident];
    NSTextField *size = OVLabel(known ? OVFormatBytes(known.longLongValue) : @"…", 13, NSFontWeightRegular, OVColor(OVRoleMuted));
    size.accessibilityLabel = [NSString stringWithFormat:L(@"%@ size"), loc[@"title"]];
    size.alignment = NSTextAlignmentRight;
    [size.widthAnchor constraintEqualToConstant:76].active = YES;
    self.sizeLabels[ident] = size;
    NSStackView *texts = OVVStack(@[title, where], 2);
    OVFillWidth(texts.arrangedSubviews, texts);
    [texts setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [texts setContentCompressionResistancePriority:250 forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSButton *reveal = OVSmallPill(OVGhostButton(L(@"Reveal"), @"magnifyingglass", self, @selector(reveal:)));
    reveal.identifier = ident;
    reveal.accessibilityLabel = [NSString stringWithFormat:L(@"Reveal %@ in Finder"), loc[@"title"]];
    NSMutableArray *buttons = [NSMutableArray arrayWithObject:reveal];
    if (deletable) {
        NSButton *del = OVSmallPill(OVGhostButton(L(@"Delete"), @"trash", self, @selector(askDelete:)));
        del.identifier = ident;
        del.accessibilityLabel = [NSString stringWithFormat:L(@"Delete %@"), loc[@"title"]];
        BOOL inUse = [self appIsBusy] && [[OVPrivacyPage busyFolders] containsObject:ident];
        if (inUse) { del.enabled = NO; del.toolTip = L(@"A task or the engine may be using this folder. Wait until it is finished."); }
        [buttons addObject:del];
    } else {
        NSButton *models = OVSmallPill(OVGhostButton(L(@"Open Models"), @"shippingbox", self, @selector(openModels:)));
        [buttons addObject:models];
    }
    NSStackView *top = OVHStack([@[texts, size] arrayByAddingObjectsFromArray:buttons], 12);
    top.alignment = NSLayoutAttributeCenterY;
    if (![self.confirming isEqualToString:ident]) return top;

    NSTextField *note = OVWrapLabel(loc[@"deleteNote"], 13, nil);
    NSButton *yes = OVSmallPill(OVPrimaryButton(L(@"Delete"), self, @selector(confirmDelete:)));
    yes.identifier = ident;
    NSButton *no = OVSmallPill(OVGhostButton(L(@"Cancel"), nil, self, @selector(cancelConfirm:)));
    NSView *box = [self confirmBoxWithText:note buttons:@[yes, no]];
    NSStackView *col = OVVStack(@[top, box], 10);
    OVFillWidth(col.arrangedSubviews, col);
    return col;
}

/// Inline confirmation: a warm plate with the question and its buttons.
- (NSView *)confirmBoxWithText:(NSTextField *)text buttons:(NSArray<NSView *> *)buttons {
    OVBoxView *box = [OVBoxView boxWithFill:OVColorAlpha(OVRoleWarn, 0.12) border:OVColorAlpha(OVRoleWarn, 0.5) radius:10];
    NSStackView *row = OVHStack([buttons arrayByAddingObject:OVSpacer()], 8);
    NSStackView *col = OVVStack(@[text, row], 10);
    OVFillWidth(@[text], col);
    col.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:col];
    OVPin(col, box, NSEdgeInsetsMake(12, 14, 12, 14));
    box.accessibilityRole = NSAccessibilityGroupRole;
    box.accessibilityLabel = text.stringValue;
    return box;
}

- (NSView *)deleteAllBlock {
    NSButton *all = OVGhostButton(L(@"Delete all app data…"), @"trash", self, @selector(askDeleteAll:));
    NSTextField *hint = Muted(L(@"Moves the app's data folder to the Trash. Models in the shared Hugging Face folder and audio in your Music folder stay."), 13);
    NSStackView *col = OVVStack(@[hint, OVHStack(@[all, OVSpacer()], 0)], 10);
    OVFillWidth(@[hint], col);
    NSMutableArray *parts = [NSMutableArray arrayWithObject:col];
    if ([self.confirming isEqualToString:@"all1"] || [self.confirming isEqualToString:@"all2"]) {
        BOOL second = [self.confirming isEqualToString:@"all2"];
        NSUInteger active = OVJobs.shared.activeCount;
        NSString *first = L(@"Delete all app data? These go to the Trash: voices and recordings, history and jobs, logs, engines, voice models and training, plugins, API and Bridge data. Generated audio in Music and the shared Hugging Face folder stay. You can undo this only by restoring from the Trash; once the Trash is emptied it is final.");
        if (active) first = [first stringByAppendingFormat:@" %@", [NSString stringWithFormat:L(@"%lu running tasks will be stopped."), (unsigned long)active]];
        NSTextField *q = OVWrapLabel(second ? L(@"Last check: move everything to the Trash and quit the app now?") : first, 13, nil);
        NSButton *go = OVSmallPill(OVPrimaryButton(second ? L(@"Move to Trash and quit") : L(@"Continue"), self, second ? @selector(confirmDeleteAll:) : @selector(continueDeleteAll:)));
        NSButton *no = OVSmallPill(OVGhostButton(L(@"Cancel"), nil, self, @selector(cancelConfirm:)));
        [parts addObject:[self confirmBoxWithText:q buttons:@[go, no]]];
    }
    NSStackView *wrap = OVVStack(parts, 10);
    OVFillWidth(parts, wrap);
    return wrap;
}

- (NSView *)rightsCard {
    NSArray *lines = @[
        L(@"Clone only voices you have the rights and the speaker's consent to use."),
        L(@"Do not present generated speech as a real person speaking."),
        L(@"Laws about voices and recordings differ between countries; you are responsible for following yours."),
        L(@"Importing from YouTube and cloning through the local API (POST /v1/clone) ask you to confirm you have those rights."),
        L(@"Install plugins and switch on Bridge only for people and sources you trust."),
    ];
    NSMutableArray *views = [NSMutableArray array];
    for (NSString *t in lines) {
        NSTextField *dot = OVLabel(@"•", 14, NSFontWeightRegular, OVColor(OVRoleMuted));
        NSTextField *l = OVWrapLabel(t, 14, nil);
        [dot setContentHuggingPriority:1000 forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSStackView *r = OVHStack(@[dot, l], 8);
        r.alignment = NSLayoutAttributeFirstBaseline;
        [views addObject:r];
    }
    NSStackView *col = OVVStack(views, 8);
    OVFillWidth(views, col);
    return OVStepCard(4, @"person.badge.shield.checkmark", L(@"Voice rights and consent"), nil, col);
}

#pragma mark - Actions

- (void)openSettings:(id)s {
    [NSUserDefaults.standardUserDefaults setObject:@"general" forKey:@"settingsTab"];
    OVNavigate(@"settings");
}

- (void)openModels:(id)s { OVNavigate(@"models"); }

- (void)revoke:(NSButton *)b {
    [OVNetwork revokeConsentFor:FeatureForId(b.identifier)];
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:[@"privacyRevoked." stringByAppendingString:b.identifier]];
    [self rebuild];
}

- (NSDictionary *)locationWithId:(NSString *)ident {
    for (NSDictionary *l in [OVPrivacyCatalog locations]) if ([l[@"id"] isEqualToString:ident]) return l;
    return nil;
}

- (void)reveal:(NSButton *)b {
    NSString *path = [self locationWithId:b.identifier][@"path"];
    if (!path) return;
    NSURL *u = [NSURL fileURLWithPath:path];
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[u]];
    else [NSWorkspace.sharedWorkspace openURL:[u URLByDeletingLastPathComponent]];
}

- (void)askDelete:(NSButton *)b { self.confirming = b.identifier; [self rebuild]; }
- (void)askDeleteAll:(id)s { self.confirming = @"all1"; [self rebuild]; }
- (void)continueDeleteAll:(id)s { self.confirming = @"all2"; [self rebuild]; }
- (void)cancelConfirm:(id)s { self.confirming = nil; [self rebuild]; }

/// Moves `path` to the Trash; on failure adds its name to `failed`.
static void Trash(NSString *path, NSMutableArray<NSString *> *failed) {
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return;
    NSError *err = nil;
    if (![NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:path] resultingItemURL:nil error:&err]) [failed addObject:path];
}

- (void)alert:(NSString *)title text:(NSString *)text {
    NSAlert *a = [NSAlert new];
    a.messageText = title;
    a.informativeText = text;
    [a addButtonWithTitle:L(@"OK")];
    [a beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse r) {}];
}

- (void)confirmDelete:(NSButton *)b {
    NSString *ident = b.identifier;
    NSString *path = [self locationWithId:ident][@"path"];
    self.confirming = nil;
    if ([[OVPrivacyPage busyFolders] containsObject:ident] && [self appIsBusy]) { [self rebuild]; return; }
    NSMutableArray *failed = [NSMutableArray array];
    if ([ident isEqualToString:@"history"]) {
        [OVJobs.shared clearFinished];                                  // running jobs stay; finished ones lose their folder
    } else if ([ident isEqualToString:@"logs"]) {
        // The log being written is not touched: files changed in the last two minutes stay.
        for (NSString *n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil]) {
            NSString *f = [path stringByAppendingPathComponent:n];
            NSDate *m = [NSFileManager.defaultManager attributesOfItemAtPath:f error:nil].fileModificationDate;
            if (m && -[m timeIntervalSinceNow] < 120) continue;
            Trash(f, failed);
        }
    } else if (path) {
        Trash(path, failed);
        [OVPaths ensure];
        if ([ident isEqualToString:@"voices"]) [OVVoices.shared reload];
    }
    [self.sizes removeObjectForKey:ident];
    [self rebuild];
    [self startCounting];
    if (failed.count) [self alert:L(@"Some files could not be moved to the Trash") text:[failed componentsJoinedByString:@"\n"]];
}

- (void)confirmDeleteAll:(id)s {
    self.confirming = nil;
    NSString *support = [OVPaths support];
    BOOL link = [[[NSFileManager.defaultManager attributesOfItemAtPath:support error:nil] fileType] isEqualToString:NSFileTypeSymbolicLink];
    NSString *refusal = [OVPrivacyCatalog refusalForDataRoot:support home:NSHomeDirectory() override:NSProcessInfo.processInfo.environment[@"OV_DATA_DIR"] isSymlink:link];
    if (refusal) { [self rebuild]; [self alert:L(@"Nothing was deleted") text:refusal]; return; }
    // Stop everything that writes there first; quitting must not be refused for running tasks, and nothing may recreate files.
    [NSNotificationCenter.defaultCenter postNotificationName:OVPrivacyWillDeleteAppDataNotification object:nil];
    [OVJobs.shared stopAllAndWait:5];
    [OVWorker.shared stop];
    if (OVJobs.shared.activeCount > 0) {
        [self rebuild];
        [self alert:L(@"Nothing was deleted") text:L(@"Some tasks did not stop. Try again in a moment.")];
        return;
    }
    NSString *hub = [self hubCachePath];
    NSMutableArray *failed = [NSMutableArray array];
    for (NSString *n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:support error:nil]) {
        NSString *p = [support stringByAppendingPathComponent:n];
        if ([hub isEqualToString:p] || [hub hasPrefix:[p stringByAppendingString:@"/"]]) continue;   // the shared Hugging Face folder is never touched
        Trash(p, failed);
    }
    if (failed.count) {
        [self rebuild];
        [self alert:L(@"Some data could not be moved to the Trash, so the app stays open") text:[failed componentsJoinedByString:@"\n"]];
        return;
    }
    [NSApp terminate:nil];   // no task is active any more: no "tasks are running" question
}

- (NSString *)hubCachePath {
    for (NSDictionary *l in [OVPrivacyCatalog locations]) if ([l[@"id"] isEqualToString:@"models"]) return l[@"path"];
    return @"";
}

@end
