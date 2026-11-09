// The Jobs page: every long task the app ran, with status, progress, log and the actions on it.
#import "OVPages.h"
#import "OVDesign.h"
#import "OVJobs.h"
#import "OVPaths.h"
#import "OVLocale.h"

#pragma mark - Shared helpers

static NSString *JobKindName(NSString *kind) {
    if ([kind isEqualToString:OVJobKindSynth] || [kind isEqualToString:@"clone"]) return L(@"Speech");
    if ([kind isEqualToString:OVJobKindBatch]) return L(@"Batch");
    if ([kind isEqualToString:OVJobKindConvert]) return L(@"Convert");
    if ([kind isEqualToString:OVJobKindTrain]) return L(@"Training");
    if ([kind isEqualToString:OVJobKindSeparate]) return L(@"Separation");
    if ([kind isEqualToString:OVJobKindInstall]) return L(@"Install");
    if ([kind isEqualToString:OVJobKindDownload]) return L(@"Download");
    if ([kind isEqualToString:OVJobKindPlugin]) return L(@"Plugin");
    return kind.length ? [[kind substringToIndex:1].uppercaseString stringByAppendingString:[kind substringFromIndex:1]] : kind;
}

static NSString *JobKindSymbol(NSString *kind) {
    if ([kind isEqualToString:OVJobKindSynth] || [kind isEqualToString:@"clone"]) return @"waveform";
    if ([kind isEqualToString:OVJobKindBatch]) return @"list.bullet.rectangle";
    if ([kind isEqualToString:OVJobKindConvert]) return @"arrow.triangle.2.circlepath";
    if ([kind isEqualToString:OVJobKindTrain]) return @"graduationcap";
    if ([kind isEqualToString:OVJobKindSeparate]) return @"waveform.path.ecg";
    if ([kind isEqualToString:OVJobKindInstall]) return @"shippingbox";
    if ([kind isEqualToString:OVJobKindDownload]) return @"arrow.down.circle";
    if ([kind isEqualToString:OVJobKindPlugin]) return @"puzzlepiece.extension";
    return @"gearshape";
}

static NSString *JobOriginName(NSString *origin) {
    if ([origin isEqualToString:@"app"] || !origin.length) return L(@"App");
    if ([origin isEqualToString:@"api"]) return L(@"API");
    if ([origin hasPrefix:@"bridge:"]) return L(@"Bridge");
    if ([origin hasPrefix:@"plugin:"]) return [NSString stringWithFormat:L(@"Plugin %@"), [origin substringFromIndex:7]];
    return origin;
}

static NSString *JobStateName(OVJobState s) {
    switch (s) {
        case OVJobQueued: return L(@"Queued");
        case OVJobRunning: return L(@"Running");
        case OVJobSucceeded: return L(@"Done");
        case OVJobFailed: return L(@"Failed");
        case OVJobStopped: return L(@"Stopped");
        case OVJobInterrupted: return L(@"Interrupted");
    }
    return @"";
}

static OVRole JobStateTone(OVJobState s) {
    switch (s) {
        case OVJobSucceeded: return OVRoleOK;
        case OVJobRunning: return OVRoleAccent;
        case OVJobQueued: return OVRoleMuted;
        case OVJobStopped: return OVRoleWarn;
        case OVJobFailed: case OVJobInterrupted: return OVRoleErr;
    }
    return OVRoleMuted;
}

static BOOL JobCanRetry(OVJob *j) { return j.retryable && (j.state == OVJobFailed || j.state == OVJobStopped || j.state == OVJobInterrupted); }

static NSArray<NSString *> *JobExistingOutputs(OVJob *j) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *p in j.outputs) if ([NSFileManager.defaultManager fileExistsAtPath:p]) [a addObject:p];
    return a;
}

static NSString *JobDateText(NSDate *d) {
    static NSDateFormatter *f;
    if (!f) { f = [NSDateFormatter new]; f.dateStyle = NSDateFormatterShortStyle; f.timeStyle = NSDateFormatterShortStyle; f.doesRelativeDateFormatting = YES; }
    f.locale = NSLocale.currentLocale;
    return [f stringFromDate:d];
}

static NSString *JobDurationText(OVJob *j) {
    if (!j.started) return nil;
    NSTimeInterval s = [(j.finished ?: NSDate.date) timeIntervalSinceDate:j.started];
    return s >= 0 ? OVFormatDuration(s) : nil;
}

/// "Speech, running 42 percent" / "Speech, failed".
static NSString *JobSpokenState(OVJob *j) {
    NSString *kind = JobKindName(j.kind);
    if (j.state == OVJobRunning && j.progress >= 0)
        return [NSString stringWithFormat:L(@"%@, running %d percent"), kind, (int)lround(MIN(1.0, j.progress) * 100)];
    return [NSString stringWithFormat:@"%@, %@", kind, JobStateName(j.state).lowercaseString];
}

static NSString *JobRetryRefusal(NSString *reason) {
    return reason.length ? reason : L(@"This task cannot be started again.");
}

/// "Delete" and "Clear finished" ask first; the text says what stays.
static void JobConfirmRemoval(NSWindow *w, NSString *message, NSString *button, void (^yes)(void)) {
    NSAlert *a = [NSAlert new];
    a.messageText = message;
    a.informativeText = L(@"This removes the record and its log, not the audio.");
    [a addButtonWithTitle:L(@"Cancel")];
    [a addButtonWithTitle:button];
    ((NSButton *)a.buttons.lastObject).hasDestructiveAction = YES;
    void (^done)(NSModalResponse) = ^(NSModalResponse r) { if (r == NSAlertSecondButtonReturn) yes(); };
    if (w) [a beginSheetModalForWindow:w completionHandler:done]; else done([a runModal]);
}

static void JobReveal(OVJob *j, NSWindow *w) {
    NSArray *files = JobExistingOutputs(j);
    if (!files.count) {
        NSAlert *a = [NSAlert new];
        a.messageText = L(@"The files are not there any more.");
        a.informativeText = L(@"They were moved or deleted outside the app.");
        [a addButtonWithTitle:L(@"Close")];
        if (w) [a beginSheetModalForWindow:w completionHandler:nil]; else [a runModal];
        return;
    }
    NSMutableArray *urls = [NSMutableArray array];
    for (NSString *p in files) [urls addObject:[NSURL fileURLWithPath:p]];
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:urls];
}

static void JobRetry(OVJob *j, NSWindow *w) {
    NSString *err = nil;
    if ([OVJobs.shared retry:j error:&err]) return;
    NSAlert *a = [NSAlert new];
    a.messageText = L(@"The task was not started");
    a.informativeText = JobRetryRefusal(err);
    [a addButtonWithTitle:L(@"Close")];
    if (w) [a beginSheetModalForWindow:w completionHandler:nil]; else [a runModal];
}

#pragma mark - Details sheet

@interface OVJobDetailSheet : NSObject
+ (void)presentJob:(OVJob *)job over:(NSWindow *)window;
@end

@interface OVJobDetailSheet ()
@property (strong) OVJob *job;
@property (strong) NSPanel *panel;
@property (weak) NSWindow *parent;
@property NSTextView *logText;
@property NSScrollView *logScroll;
@property (strong) NSView *headBadgeHolder;
@property NSTextField *statusLine, *errorLabel;
@property NSButton *retry, *reveal, *delete, *logCopier;
@property NSView *errorBox;
@property NSUInteger shownLogLength;
@property (strong) OVJobDetailSheet *selfRetain;
@end

@implementation OVJobDetailSheet
+ (void)presentJob:(OVJob *)job over:(NSWindow *)window {
    OVJobDetailSheet *s = [OVJobDetailSheet new];
    s.job = job;
    s.parent = window;
    [s build];
    s.selfRetain = s;
    [NSNotificationCenter.defaultCenter addObserver:s selector:@selector(changed:) name:OVJobsDidChangeNotification object:nil];
    if (window) [window beginSheet:s.panel completionHandler:^(NSModalResponse r) { [s finish]; }];
    else [s.panel makeKeyAndOrderFront:nil];
    [s refresh];
    [s.logText scrollToEndOfDocument:nil];
}

- (void)finish {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    self.selfRetain = nil;
}

- (NSString *)paramsText {
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *k in [self.job.request.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if ([k hasPrefix:@"_"]) continue;
        id v = self.job.request[k];
        NSString *s = [v isKindOfClass:NSString.class] ? v
            : [v isKindOfClass:NSNumber.class] ? [v stringValue]
            : ([NSJSONSerialization isValidJSONObject:v]
               ? [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:v options:NSJSONWritingFragmentsAllowed | NSJSONWritingSortedKeys error:nil] encoding:NSUTF8StringEncoding]
               : [v description]);
        if (s.length > 300) s = [NSString stringWithFormat:L(@"(text of %lu characters)"), (unsigned long)s.length];
        [lines addObject:[NSString stringWithFormat:@"%@: %@", k, s]];
    }
    return lines.count ? [lines componentsJoinedByString:@"\n"] : L(@"No parameters.");
}

- (void)build {
    OVJob *j = self.job;
    NSTextField *title = OVLabel(j.title.length ? j.title : JobKindName(j.kind), 20, NSFontWeightBold, nil);
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    title.toolTip = j.title;
    [title setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.headBadgeHolder = OVHStack(@[], 0);
    NSStackView *head = OVHStack(@[title, OVSpacer(), self.headBadgeHolder], 10);

    self.statusLine = OVLabel(@"", 13, NSFontWeightRegular, OVColor(OVRoleMuted));
    self.statusLine.lineBreakMode = NSLineBreakByTruncatingTail;

    NSTextField *params = OVWrapLabel([self paramsText], 12, OVColor(OVRoleMuted));
    params.selectable = YES;
    params.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    NSView *paramsBlock = OVFieldBlock(L(@"Parameters"), nil, params);

    self.errorLabel = OVWrapLabel(@"", 13, OVColor(OVRoleErr));
    self.errorLabel.selectable = YES;
    OVBoxView *eb = [OVBoxView boxWithFill:OVColorAlpha(OVRoleErr, 0.10) border:OVColorAlpha(OVRoleErr, 0.45) radius:10];
    [eb addSubview:self.errorLabel];
    OVPin(self.errorLabel, eb, NSEdgeInsetsMake(10, 12, 10, 12));
    self.errorBox = eb;
    eb.accessibilityElement = YES;
    eb.accessibilityRole = NSAccessibilityGroupRole;

    NSTextView *tv = nil;
    NSScrollView *sv = OVLogView(&tv);
    self.logText = tv;
    self.logScroll = sv;
    tv.textColor = OVColor(OVRoleText);
    tv.accessibilityLabel = L(@"Log");
    [sv.heightAnchor constraintGreaterThanOrEqualToConstant:200].active = YES;
    [sv setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    NSView *logBlock = OVFieldBlock(L(@"Log"), nil, sv);

    self.logCopier = OVGhostButton(L(@"Copy log"), @"doc.on.doc", self, @selector(copyLog:));
    self.reveal = OVGhostButton(L(@"Show in Finder"), @"folder", self, @selector(revealOutputs:));
    self.retry = OVGhostButton(L(@"Retry"), @"arrow.clockwise", self, @selector(retryJob:));
    self.delete = OVGhostButton(L(@"Delete"), @"trash", self, @selector(deleteJob:));
    NSButton *close = OVPrimaryButton(L(@"Close"), self, @selector(close:));
    close.keyEquivalent = @"\r";
    NSStackView *buttons = OVHStack(@[self.logCopier, self.reveal, self.retry, self.delete, OVSpacer(), close], 8);

    NSStackView *col = OVVStack(@[head, self.statusLine, self.errorBox, paramsBlock, logBlock, buttons], 12);
    col.edgeInsets = NSEdgeInsetsMake(20, 22, 18, 22);
    col.alignment = NSLayoutAttributeLeading;
    OVFillWidth(col.arrangedSubviews, col);

    NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 640, 560)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
                                              backing:NSBackingStoreBuffered defer:NO];
    p.title = L(@"Task details");
    p.contentMinSize = NSMakeSize(520, 420);
    NSView *root = [NSView new];
    [root addSubview:col];
    OVPin(col, root, NSEdgeInsetsZero);
    p.contentView = root;
    self.panel = p;
}

- (void)refresh {
    OVJob *j = self.job;
    NSView *badge = OVBadge(JobStateName(j.state), JobStateTone(j.state));
    for (NSView *v in [self.headBadgeHolder.subviews copy]) [v removeFromSuperview];
    [(NSStackView *)self.headBadgeHolder addArrangedSubview:badge];
    badge.accessibilityLabel = JobSpokenState(j);
    NSMutableArray *meta = [NSMutableArray arrayWithObjects:JobKindName(j.kind), JobOriginName(j.origin), JobDateText(j.created), nil];
    NSString *d = JobDurationText(j);
    if (d) [meta addObject:d];
    if (j.active && j.status.length) [meta addObject:j.status];
    self.statusLine.stringValue = [meta componentsJoinedByString:@" · "];
    BOOL hasError = j.error.length > 0 && !j.active;
    self.errorBox.hidden = !hasError;
    self.errorLabel.stringValue = hasError ? j.error : @"";
    self.retry.hidden = !JobCanRetry(j);
    self.reveal.hidden = !j.outputs.count;
    self.delete.enabled = !j.active;
    self.delete.toolTip = j.active ? L(@"Stop the task first.") : nil;
    // The log: only touched when it grew; a running job follows the end unless the reader scrolled up.
    NSString *log = j.logText;
    if (log.length != self.shownLogLength) {
        BOOL atEnd = NSMaxY(self.logText.visibleRect) >= NSMaxY(self.logText.bounds) - 20;
        self.logText.string = log;
        self.logText.textColor = OVColor(OVRoleText);
        self.shownLogLength = log.length;
        if (j.state == OVJobRunning && atEnd) [self.logText scrollToEndOfDocument:nil];
    }
}

- (void)changed:(NSNotification *)n {
    if (n.object && n.object != self.job) return;
    if (![OVJobs.shared jobWithId:self.job.identifier]) { [self close:nil]; return; }   // removed elsewhere
    [self refresh];
}

- (void)close:(id)s {
    if (self.parent && self.panel.sheetParent) [self.parent endSheet:self.panel];
    else { [self.panel orderOut:nil]; [self finish]; }
}
- (void)copyLog:(id)s {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:self.job.logText forType:NSPasteboardTypeString];
}
- (void)revealOutputs:(id)s { JobReveal(self.job, self.panel); }
- (void)retryJob:(id)s { JobRetry(self.job, self.panel); }
- (void)deleteJob:(id)s {
    OVJob *j = self.job;
    JobConfirmRemoval(self.panel, L(@"Delete this task?"), L(@"Delete"), ^{
        [OVJobs.shared remove:j];   // the change notification closes the sheet
    });
}
@end

#pragma mark - Row

@interface OVJobRowCell : NSTableCellView
@property NSImageView *icon;
@property NSTextField *titleLabel, *metaLabel;
@property NSView *badgeHolder;
@property NSProgressIndicator *bar;
@property NSButton *stop, *retry, *reveal, *details;
@property (copy) NSString *shownState;
- (void)configure:(OVJob *)j;
@end

@implementation OVJobRowCell
- (instancetype)initWithFrame:(NSRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    self.identifier = @"job";
    self.icon = OVSymbol(@"gearshape", 18, OVColor(OVRoleMuted));
    [self.icon.widthAnchor constraintEqualToConstant:28].active = YES;
    self.titleLabel = OVLabel(@"", 14, NSFontWeightSemibold, nil);
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.metaLabel = OVLabel(@"", 12, NSFontWeightRegular, OVColor(OVRoleMuted));
    self.metaLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    for (NSTextField *t in @[self.titleLabel, self.metaLabel]) [t setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *texts = OVVStack(@[self.titleLabel, self.metaLabel], 2);
    texts.alignment = NSLayoutAttributeLeading;
    [texts setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.bar = OVProgressBar();
    self.bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.bar.widthAnchor constraintEqualToConstant:110].active = YES;
    [self.bar.heightAnchor constraintEqualToConstant:6].active = YES;
    self.badgeHolder = [NSView new];
    self.badgeHolder.translatesAutoresizingMaskIntoConstraints = NO;
    [self.badgeHolder.widthAnchor constraintEqualToConstant:100].active = YES;
    self.stop = OVIconButton(@"stop.circle", L(@"Stop"), nil, @selector(rowStop:));
    self.retry = OVIconButton(@"arrow.clockwise", L(@"Retry"), nil, @selector(rowRetry:));
    self.reveal = OVIconButton(@"folder", L(@"Show in Finder"), nil, @selector(rowReveal:));
    self.details = OVIconButton(@"info.circle", L(@"Details"), nil, @selector(rowDetails:));
    NSMutableArray *slots = [NSMutableArray array];
    for (NSButton *b in @[self.stop, self.retry, self.reveal, self.details]) {   // fixed slots: a hidden button keeps its place
        NSView *slot = [NSView new];
        slot.translatesAutoresizingMaskIntoConstraints = NO;
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [slot addSubview:b];
        [NSLayoutConstraint activateConstraints:@[[slot.widthAnchor constraintEqualToConstant:28], [slot.heightAnchor constraintEqualToConstant:28],
            [b.centerXAnchor constraintEqualToAnchor:slot.centerXAnchor], [b.centerYAnchor constraintEqualToAnchor:slot.centerYAnchor]]];
        [slots addObject:slot];
    }
    NSStackView *row = OVHStack([@[self.icon, texts, self.bar, self.badgeHolder] arrayByAddingObjectsFromArray:slots], 8);
    [row setCustomSpacing:12 afterView:self.bar];
    [self addSubview:row];
    OVPin(row, self, NSEdgeInsetsMake(0, 10, 0, 8));
    return self;
}

- (void)updateMeta:(OVJob *)j {
    NSMutableArray *meta = [NSMutableArray arrayWithObjects:JobKindName(j.kind), JobOriginName(j.origin), JobDateText(j.created), nil];
    NSString *d = JobDurationText(j);
    if (d) [meta addObject:d];
    if (j.active && j.status.length) [meta addObject:j.status];
    else if (j.error.length && !j.active) [meta addObject:j.error];
    NSString *text = [meta componentsJoinedByString:@" · "];
    if (![self.metaLabel.stringValue isEqualToString:text]) { self.metaLabel.stringValue = text; self.metaLabel.toolTip = text; }
}

- (void)configure:(OVJob *)j {
    self.icon.image = [NSImage imageWithSystemSymbolName:JobKindSymbol(j.kind) accessibilityDescription:nil];
    NSString *name = j.title.length ? j.title : JobKindName(j.kind);
    self.titleLabel.stringValue = name;
    self.titleLabel.toolTip = name;
    [self updateMeta:j];
    // The badge is rebuilt only when the state changes.
    NSString *state = [NSString stringWithFormat:@"%ld", (long)j.state];
    if (![state isEqualToString:self.shownState]) {
        self.shownState = state;
        for (NSView *v in [self.badgeHolder.subviews copy]) [v removeFromSuperview];
        NSView *b = OVBadge(JobStateName(j.state), JobStateTone(j.state));
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [self.badgeHolder addSubview:b];
        [NSLayoutConstraint activateConstraints:@[[b.trailingAnchor constraintEqualToAnchor:self.badgeHolder.trailingAnchor],
                                                  [b.centerYAnchor constraintEqualToAnchor:self.badgeHolder.centerYAnchor]]];
    }
    BOOL running = j.state == OVJobRunning;
    self.bar.hidden = !running;
    if (running) {
        if (j.progress < 0) {
            self.bar.indeterminate = YES;
            if (!NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) [self.bar startAnimation:nil];   // still under Reduce Motion
            else [self.bar stopAnimation:nil];
        }
        else { [self.bar stopAnimation:nil]; self.bar.indeterminate = NO; self.bar.doubleValue = MIN(1, j.progress); }
    } else if (self.bar.indeterminate) { [self.bar stopAnimation:nil]; self.bar.indeterminate = NO; }
    self.stop.hidden = !j.active;
    self.retry.hidden = !JobCanRetry(j);
    self.reveal.hidden = !j.outputs.count;
    self.stop.accessibilityLabel = self.stop.toolTip = [NSString stringWithFormat:L(@"Stop %@"), name];
    self.retry.accessibilityLabel = self.retry.toolTip = [NSString stringWithFormat:L(@"Retry %@"), name];
    self.reveal.accessibilityLabel = self.reveal.toolTip = [NSString stringWithFormat:L(@"Show %@ in Finder"), name];
    self.details.accessibilityLabel = self.details.toolTip = [NSString stringWithFormat:L(@"Details of %@"), name];
    NSString *spoken = JobSpokenState(j);
    self.accessibilityElement = YES;
    self.accessibilityRole = NSAccessibilityGroupRole;
    self.accessibilityLabel = spoken;
    self.accessibilityHelp = name;
    self.accessibilityValue = name;
    self.bar.accessibilityLabel = spoken;
}
@end

#pragma mark - Table

@interface OVJobsTable : NSTableView
@property (weak) id jobsOwner;
@end
@implementation OVJobsTable
- (void)keyDown:(NSEvent *)e {
    NSString *c = e.charactersIgnoringModifiers;
    if (c.length && self.selectedRow >= 0) {
        unichar ch = [c characterAtIndex:0];
        if (ch == '\r' || ch == 3) { [self.jobsOwner performSelector:@selector(detailsOfSelected:) withObject:self]; return; }
        if (ch == NSDeleteCharacter || ch == NSDeleteFunctionKey) { [self.jobsOwner performSelector:@selector(deleteSelected:) withObject:self]; return; }
    }
    [super keyDown:e];
}
@end

#pragma mark - Page

/// Tells the page when its view enters or leaves a window (the shell swaps pages without viewDidAppear/Disappear).
@interface OVJobsRootView : NSView
@property (copy) void (^onWindowChange)(BOOL inWindow);
@end
@implementation OVJobsRootView
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; if (self.onWindowChange) self.onWindowChange(self.window != nil); }
@end

@interface OVJobsPage () <NSTableViewDataSource, NSTableViewDelegate>
@property OVJobsTable *table;
@property NSScrollView *tableScroll;
@property NSView *listCard, *emptyHolder, *emptyState;
@property OVSegmented *filter;
@property OVPopup *kindPopup;
@property NSButton *clearButton;
@property NSArray<NSTextField *> *statValues;
@property (copy) NSArray<OVJob *> *rows;
@property (copy) NSString *kindFilter;        // nil = all kinds
@property (copy) NSArray<NSString *> *kindsShown;
@property NSTimer *clock;
@property BOOL stale;
@property NSView *noMatchState;
@end

@implementation OVJobsPage

- (NSView *)statCard:(NSString *)title index:(NSInteger)i values:(NSMutableArray *)values {
    NSTextField *t = OVWrapLabel(title, 13, OVColor(OVRoleMuted));
    t.maximumNumberOfLines = 2;
    NSTextField *v = OVLabel(@"0", 22, NSFontWeightSemibold, nil);
    v.accessibilityLabel = title;
    [values addObject:v];
    NSStackView *s = OVVStack(@[t, v], 2);
    s.alignment = NSLayoutAttributeLeading;
    OVBoxView *box = [OVBoxView boxWithFill:OVColor(OVRoleSurface) border:OVColor(OVRoleBorder) radius:12];
    [box addSubview:s];
    OVPin(s, box, NSEdgeInsetsMake(12, 16, 12, 16));
    return box;
}

- (void)loadView {
    NSMutableArray *values = [NSMutableArray array];
    NSArray *cards = @[[self statCard:L(@"Active") index:0 values:values], [self statCard:L(@"Completed") index:1 values:values],
                       [self statCard:L(@"Failed or interrupted") index:2 values:values], [self statCard:L(@"Stopped") index:3 values:values]];
    self.statValues = values;
    NSStackView *stats = OVHStack(cards, 12);
    stats.distribution = NSStackViewDistributionFillEqually;
    stats.alignment = NSLayoutAttributeTop;
    for (NSView *c in [cards subarrayWithRange:NSMakeRange(1, 3)]) [c.heightAnchor constraintEqualToAnchor:((NSView *)cards[0]).heightAnchor].active = YES;

    self.clearButton = OVGhostButton(L(@"Clear finished"), @"trash", self, @selector(clearFinished:));
    NSView *header = OVPageHeader(L(@"Jobs"), L(@"Everything the app ran: progress, logs, results."), self.clearButton);

    self.filter = [OVSegmented segmentedWithItems:@[@[L(@"All"), @""], @[L(@"Active"), @""], @[L(@"Failed"), @""]]];
    self.filter.selectedIndex = 0;
    self.filter.target = self;
    self.filter.action = @selector(filterChanged:);
    self.filter.accessibilityLabel = L(@"Show");
    self.kindPopup = [OVPopup popup];
    self.kindPopup.target = self;
    self.kindPopup.action = @selector(kindChanged:);
    self.kindPopup.accessibilityLabel = L(@"Kind of task");
    [self.kindPopup.widthAnchor constraintEqualToConstant:200].active = YES;
    NSStackView *filters = OVHStack(@[self.filter, OVSpacer(), self.kindPopup], 12);

    self.table = [OVJobsTable new];
    self.table.jobsOwner = self;
    [self.table addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"j"]];
    self.table.headerView = nil;
    self.table.rowHeight = 56;
    self.table.style = NSTableViewStylePlain;
    self.table.backgroundColor = NSColor.clearColor;
    self.table.intercellSpacing = NSMakeSize(0, 2);
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.target = self;
    self.table.doubleAction = @selector(detailsOfClicked:);
    self.table.allowsEmptySelection = YES;
    self.table.accessibilityLabel = L(@"Jobs");
    NSScrollView *sv = [NSScrollView new];
    sv.documentView = self.table;
    sv.hasVerticalScroller = YES;
    sv.drawsBackground = NO;
    sv.borderType = NSNoBorder;
    self.tableScroll = sv;

    NSView *empty = OVEmptyState(@"clock.arrow.circlepath", L(@"No jobs yet"),
                                 L(@"Speech, conversions, training and downloads appear here with their progress and log."),
                                 @[OVPrimaryButton(L(@"Open Speech"), self, @selector(openSpeech:))]);
    empty.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyState = empty;
    self.emptyHolder = [NSView new];
    [self.emptyHolder addSubview:empty];
    [NSLayoutConstraint activateConstraints:@[
        [empty.centerXAnchor constraintEqualToAnchor:self.emptyHolder.centerXAnchor],
        [empty.centerYAnchor constraintEqualToAnchor:self.emptyHolder.centerYAnchor],
        [empty.widthAnchor constraintLessThanOrEqualToAnchor:self.emptyHolder.widthAnchor constant:-32]]];

    NSView *nomatch = OVEmptyState(@"line.3.horizontal.decrease.circle", L(@"No matching tasks"),
                                   L(@"No task fits the chosen filter."),
                                   @[OVGhostButton(L(@"Show all"), nil, self, @selector(showAll:))]);
    nomatch.translatesAutoresizingMaskIntoConstraints = NO;
    self.noMatchState = nomatch;
    [self.emptyHolder addSubview:nomatch];
    [NSLayoutConstraint activateConstraints:@[
        [nomatch.centerXAnchor constraintEqualToAnchor:self.emptyHolder.centerXAnchor],
        [nomatch.centerYAnchor constraintEqualToAnchor:self.emptyHolder.centerYAnchor],
        [nomatch.widthAnchor constraintLessThanOrEqualToAnchor:self.emptyHolder.widthAnchor constant:-32]]];

    OVBoxView *card = [OVBoxView boxWithFill:OVColor(OVRoleSurface) border:OVColor(OVRoleBorder) radius:12];
    for (NSView *v in @[sv, self.emptyHolder]) { [card addSubview:v]; OVPin(v, card, NSEdgeInsetsMake(6, 6, 6, 6)); }
    self.listCard = card;
    [card setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    [card.heightAnchor constraintGreaterThanOrEqualToConstant:260].active = YES;

    NSStackView *page = OVVStack(@[header, stats, filters, card], 16);
    page.edgeInsets = NSEdgeInsetsMake(24, 28, 28, 28);
    OVFillWidth(page.arrangedSubviews, page);
    OVJobsRootView *root = [OVJobsRootView new];
    __weak typeof(self) weakSelf = self;
    root.onWindowChange = ^(BOOL in) { [weakSelf windowChanged:in]; };
    [root addSubview:page];
    OVPin(page, root, NSEdgeInsetsZero);
    self.view = root;

    self.rows = @[];
    [self rebuild];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(jobsChanged:) name:OVJobsDidChangeNotification object:nil];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [self.clock invalidate]; }

- (void)windowChanged:(BOOL)inWindow {
    if (!inWindow) { [self.clock invalidate]; self.clock = nil; return; }
    if (self.stale) { self.stale = NO; [self rebuild]; }
    // Durations of running jobs tick once a second, only while the page is in a window.
    if (!self.clock) {
        __weak typeof(self) weak = self;
        self.clock = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) { [weak tick]; }];
        [NSRunLoop.mainRunLoop addTimer:self.clock forMode:NSRunLoopCommonModes];
    }
}

- (void)tick {
    [self.rows enumerateObjectsUsingBlock:^(OVJob *j, NSUInteger i, BOOL *stop) {
        if (j.state != OVJobRunning) return;
        OVJobRowCell *cell = [self.table viewAtColumn:0 row:i makeIfNecessary:NO];
        if ([cell isKindOfClass:OVJobRowCell.class]) [cell updateMeta:j];
    }];
}

#pragma mark Data

- (BOOL)passes:(OVJob *)j {
    if (self.kindFilter && ![j.kind isEqualToString:self.kindFilter]) return NO;
    switch (self.filter.selectedIndex) {
        case 1: return j.active;
        case 2: return j.state == OVJobFailed || j.state == OVJobInterrupted;
        default: return YES;
    }
}

- (void)updateStats {
    NSUInteger n[4] = {0, 0, 0, 0};
    for (OVJob *j in OVJobs.shared.all) {
        if (j.active) n[0]++;
        else if (j.state == OVJobSucceeded) n[1]++;
        else if (j.state == OVJobFailed || j.state == OVJobInterrupted) n[2]++;
        else if (j.state == OVJobStopped) n[3]++;
    }
    for (int i = 0; i < 4; i++) {
        NSString *s = [NSString stringWithFormat:@"%lu", (unsigned long)n[i]];
        if (![self.statValues[i].stringValue isEqualToString:s]) self.statValues[i].stringValue = s;
    }
}

- (void)updateKindPopup {
    NSMutableOrderedSet *kinds = [NSMutableOrderedSet orderedSet];
    for (OVJob *j in OVJobs.shared.all) [kinds addObject:j.kind];
    NSArray *sorted = [kinds.array sortedArrayUsingSelector:@selector(compare:)];
    if ([sorted isEqualToArray:self.kindsShown]) return;
    self.kindsShown = sorted;
    [self.kindPopup removeAllItems];
    [self.kindPopup addItemWithTitle:L(@"All kinds")];
    self.kindPopup.lastItem.representedObject = nil;
    NSInteger select = 0;
    for (NSString *k in sorted) {
        [self.kindPopup addItemWithTitle:JobKindName(k)];
        self.kindPopup.lastItem.representedObject = k;
        if ([k isEqualToString:self.kindFilter]) select = self.kindPopup.numberOfItems - 1;
    }
    if (select == 0) self.kindFilter = nil;
    [self.kindPopup selectItemAtIndex:select];
    self.kindPopup.hidden = sorted.count < 2;
}

/// Full rebuild: after the list itself changed (a job appeared, vanished or moved to another filter).
- (void)rebuild {
    [self updateStats];
    [self updateKindPopup];
    NSMutableArray *rows = [NSMutableArray array];
    for (OVJob *j in OVJobs.shared.all) if ([self passes:j]) [rows addObject:j];
    NSArray *oldRows = self.rows;
    self.rows = rows;
    BOOL same = rows.count == oldRows.count;
    for (NSUInteger i = 0; same && i < rows.count; i++) same = rows[i] == oldRows[i];
    if (!same || !self.table.numberOfRows) {
        NSInteger sel = self.table.selectedRow;
        OVJob *selected = sel >= 0 && sel < (NSInteger)oldRows.count ? oldRows[sel] : nil;
        [self.table reloadData];
        NSUInteger at = selected ? [rows indexOfObjectIdenticalTo:selected] : NSNotFound;
        if (at != NSNotFound) [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:at] byExtendingSelection:NO];
    }
    BOOL none = OVJobs.shared.all.count == 0, noMatch = !none && rows.count == 0;
    self.emptyHolder.hidden = !(none || noMatch);
    self.emptyState.hidden = !none;
    self.noMatchState.hidden = !noMatch;
    self.tableScroll.hidden = none || noMatch;
    [self.view.window recalculateKeyViewLoop];
    BOOL anyFinished = NO;
    for (OVJob *j in OVJobs.shared.all) if (!j.active) { anyFinished = YES; break; }
    self.clearButton.enabled = anyFinished;
}

- (void)jobsChanged:(NSNotification *)n {
    if (!self.view.window) { self.stale = YES; return; }   // refreshed when the page comes back
    OVJob *j = n.object;
    if (![j isKindOfClass:OVJob.class]) { [self rebuild]; return; }
    // Same rows in the same order: refresh just this row.
    NSMutableArray *expect = [NSMutableArray array];
    for (OVJob *x in OVJobs.shared.all) if ([self passes:x]) [expect addObject:x];
    if (![expect isEqualToArray:self.rows] || [OVJobs.shared jobWithId:j.identifier] == nil) { [self rebuild]; return; }
    [self updateStats];
    NSUInteger i = [self.rows indexOfObjectIdenticalTo:j];
    if (i != NSNotFound) [self.table reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:i] columnIndexes:[NSIndexSet indexSetWithIndex:0]];
    [self updateKindPopup];
}

#pragma mark Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return self.rows.count; }

- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)row {
    OVJobRowCell *cell = [t makeViewWithIdentifier:@"job" owner:self];
    if (!cell) {
        cell = [[OVJobRowCell alloc] initWithFrame:NSZeroRect];
        for (NSButton *b in @[cell.stop, cell.retry, cell.reveal, cell.details]) b.target = self;
    }
    [cell configure:self.rows[row]];
    return cell;
}

- (NSTableRowView *)tableView:(NSTableView *)t rowViewForRow:(NSInteger)row { return [OVTableRowView new]; }

- (OVJob *)jobForSender:(NSView *)v {
    NSInteger r = [self.table rowForView:v];
    return r >= 0 && r < (NSInteger)self.rows.count ? self.rows[r] : nil;
}

#pragma mark Actions

- (void)rowStop:(NSButton *)b { OVJob *j = [self jobForSender:b]; if (j) [OVJobs.shared stop:j]; }
- (void)rowRetry:(NSButton *)b { OVJob *j = [self jobForSender:b]; if (j) JobRetry(j, self.view.window); }
- (void)rowReveal:(NSButton *)b { OVJob *j = [self jobForSender:b]; if (j) JobReveal(j, self.view.window); }
- (void)rowDetails:(NSButton *)b { OVJob *j = [self jobForSender:b]; if (j) [self showDetails:j]; }

- (void)showDetails:(OVJob *)j { [OVJobDetailSheet presentJob:j over:self.view.window]; }
- (void)detailsOfClicked:(id)s {
    NSInteger r = self.table.clickedRow;
    if (r >= 0 && r < (NSInteger)self.rows.count) [self showDetails:self.rows[r]];
}
- (void)detailsOfSelected:(id)s {
    NSInteger r = self.table.selectedRow;
    if (r >= 0 && r < (NSInteger)self.rows.count) [self showDetails:self.rows[r]];
}
- (void)deleteSelected:(id)s {
    NSInteger r = self.table.selectedRow;
    if (r < 0 || r >= (NSInteger)self.rows.count) return;
    OVJob *j = self.rows[r];
    if (j.active) { NSBeep(); return; }
    JobConfirmRemoval(self.view.window, L(@"Delete this task?"), L(@"Delete"), ^{ [OVJobs.shared remove:j]; });
}
- (void)clearFinished:(id)s {
    JobConfirmRemoval(self.view.window, L(@"Clear all finished tasks?"), L(@"Clear finished"), ^{ [OVJobs.shared clearFinished]; });
}
- (void)showAll:(id)s {
    self.filter.selectedIndex = 0;
    self.kindFilter = nil;
    [self.kindPopup selectItemAtIndex:0];
    [self rebuild];
}
- (void)filterChanged:(id)s { [self rebuild]; }
- (void)kindChanged:(NSPopUpButton *)p {
    self.kindFilter = p.selectedItem.representedObject;
    [self rebuild];
}
- (void)openSpeech:(id)s { OVNavigate(@"synth"); }
@end
