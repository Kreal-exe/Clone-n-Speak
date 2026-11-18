// "API & Bridge" page: the local API (this task) and, below it, the Bridge card (task 8.7).
#import "OVPages.h"
#import "OVDesign.h"
#import "OVAPI.h"
#import "OVJobs.h"
#import "OVLocale.h"

static NSStackView *Column(NSArray<NSView *> *rows, CGFloat gap) {
    NSStackView *s = OVVStack(rows, gap);
    OVFillWidth(rows, s);
    return s;
}

@interface OVAPIPage ()
@property OVSwitch *enableSwitch;
@property NSStackView *badgeHolder;
@property NSTextField *addressLabel, *portField, *portError, *keyLabel, *snippetLabel, *emptyJobs;
@property NSButton *showButton;
@property NSStackView *jobRows;
@property BOOL keyShown;
@end

@implementation OVAPIPage

#pragma mark - Building

- (NSTextField *)mono:(NSString *)text size:(CGFloat)size {
    NSTextField *t = OVWrapLabel(text, size, nil);
    t.font = [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
    t.selectable = YES;
    return t;
}

- (NSView *)boxed:(NSView *)v {
    OVBoxView *box = [OVBoxView boxWithFill:OVColor(OVRoleField) border:OVColor(OVRoleBorder) radius:10];
    [box addSubview:v];
    OVPin(v, box, NSEdgeInsetsMake(10, 12, 10, 12));
    return box;
}

- (NSButton *)small:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    return OVSmallPill(OVGhostButton(title, symbol, self, action));
}

- (NSView *)localCard {
    self.enableSwitch = [OVSwitch new];
    self.enableSwitch.target = self;
    self.enableSwitch.action = @selector(toggled:);
    self.enableSwitch.accessibilityLabel = L(@"Enable local API");
    NSTextField *title = OVWrapLabel(L(@"Enable local API"), 14, nil);
    title.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    NSTextField *hint = OVWrapLabel(L(@"Other apps and scripts on this Mac can make it speak. It listens on this Mac only and works offline."), 13, OVColor(OVRoleMuted));
    NSStackView *texts = Column(@[title, hint], 2);
    NSStackView *switchRow = OVHStack(@[self.enableSwitch, texts], 12);
    switchRow.alignment = NSLayoutAttributeTop;

    self.addressLabel = [self mono:@"" size:13];
    self.addressLabel.accessibilityLabel = L(@"Address");
    NSStackView *addr = OVHStack(@[self.addressLabel, OVSpacer(), [self small:L(@"Copy") symbol:@"doc.on.doc" action:@selector(copyAddress:)]], 8);
    addr.alignment = NSLayoutAttributeCenterY;

    self.portField = OVField(@"18777");
    self.portField.accessibilityLabel = L(@"Port");
    [self.portField.widthAnchor constraintEqualToConstant:100].active = YES;
    self.portField.target = self;
    self.portField.action = @selector(applyPort:);
    NSButton *apply = [self small:L(@"Apply") symbol:nil action:@selector(applyPort:)];
    NSStackView *portRow = OVHStack(@[self.portField, apply, OVSpacer()], 8);
    portRow.alignment = NSLayoutAttributeCenterY;
    self.portError = OVWrapLabel(@"", 13, OVColor(OVRoleErr));
    self.portError.hidden = YES;
    NSView *port = OVFieldBlock(L(@"Port"), L(@"Applying a new port restarts the API."), portRow);

    self.badgeHolder = OVHStack(@[], 0);
    return OVStepCardWithAccessory(0, @"chevron.left.forwardslash.chevron.right", L(@"Local API"), self.badgeHolder,
                                   Column(@[switchRow, [self boxed:addr], port, self.portError], 14));
}

- (NSView *)keyCard {
    self.keyLabel = [self mono:@"" size:13];
    self.keyLabel.accessibilityLabel = L(@"API key");
    self.showButton = [self small:L(@"Show") symbol:@"eye" action:@selector(toggleKey:)];
    NSStackView *row = OVHStack(@[self.keyLabel, OVSpacer(), self.showButton, [self small:L(@"Copy") symbol:@"doc.on.doc" action:@selector(copyKey:)],
                                  [self small:L(@"Rotate") symbol:@"arrow.triangle.2.circlepath" action:@selector(rotate:)]], 8);
    row.alignment = NSLayoutAttributeCenterY;
    NSTextField *warn = OVWrapLabel(L(@"Anyone who has this key can make this Mac speak and clone voices. Keep it private."), 13, OVColor(OVRoleMuted));
    return OVStepCard(0, @"key", L(@"API key"), nil, Column(@[[self boxed:row], warn], 12));
}

- (NSView *)quickStartCard {
    self.snippetLabel = [self mono:@"" size:12];
    self.snippetLabel.accessibilityLabel = L(@"Example commands");
    NSButton *copy = [self small:L(@"Copy") symbol:@"doc.on.doc" action:@selector(copySnippet:)];
    return OVStepCardWithAccessory(0, @"terminal", L(@"Quick start"), copy,
                                   Column(@[OVWrapLabel(L(@"Speak a sentence, wait for it, then download the audio."), 13, OVColor(OVRoleMuted)),
                                            [self boxed:self.snippetLabel]], 12));
}

- (NSView *)jobsCard {
    self.jobRows = OVVStack(@[], 8);
    self.emptyJobs = OVWrapLabel(L(@"No API jobs yet. Calls from other apps show up here."), 13, OVColor(OVRoleMuted));
    NSStackView *col = Column(@[self.emptyJobs, self.jobRows], 8);
    return OVStepCard(0, @"clock.arrow.circlepath", L(@"Recent API jobs"), nil, col);
}

- (void)loadView {
    NSView *header = OVPageHeader(L(@"API & Bridge"), L(@"Let other apps and scripts on this Mac use your voices."), nil);
    NSMutableArray *views = [NSMutableArray arrayWithObjects:header, [self localCard], [self keyCard], [self quickStartCard], [self jobsCard], nil];
    // Task 8.7: the Bridge card is added here (views.addObject:), below the API cards.
    self.view = OVPageScroll(views);
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(refresh) name:OVAPIDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refreshJobs) name:OVJobsDidChangeNotification object:nil];
    [self refresh];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

#pragma mark - Showing state

- (NSString *)maskedKey:(NSString *)k {
    return k.length > 12 ? [NSString stringWithFormat:@"cns_••••••••••••%@", [k substringFromIndex:k.length - 4]] : @"••••";
}

- (NSString *)snippetWithKey:(NSString *)key {
    NSString *base = OVAPI.shared.baseURL;
    NSString *auth = @"-H \"Authorization: Bearer $CNS_KEY\"";
    NSArray *lines = @[
        [NSString stringWithFormat:@"export CNS_KEY='%@'", key],
        @"",
        @"# 1. Start speaking: the answer holds a jobId",
        [NSString stringWithFormat:@"curl -s %@ -H \"Content-Type: application/json\" \\", auth],
        [NSString stringWithFormat:@"  -d '{\"text\": \"Hello from my Mac\"}' %@/v1/synthesize", base],
        @"",
        @"# 2. Ask until the state is \"succeeded\"",
        [NSString stringWithFormat:@"curl -s %@ %@/v1/jobs/<jobId>", auth, base],
        @"",
        @"# 3. Download the audio",
        [NSString stringWithFormat:@"curl -s %@ -o speech.wav %@/v1/jobs/<jobId>/output", auth, base],
    ];
    return [lines componentsJoinedByString:@"\n"];
}

- (void)refresh {
    OVAPI *api = OVAPI.shared;
    self.enableSwitch.on = api.enabled;
    self.addressLabel.stringValue = api.baseURL;
    if (self.view.window.firstResponder != self.portField.currentEditor) self.portField.stringValue = [NSString stringWithFormat:@"%u", api.port];
    NSView *badge = api.running ? OVBadge(L(@"Running"), OVRoleOK) : (api.lastError.length ? OVBadge(L(@"Error"), OVRoleErr) : OVBadge(L(@"Off"), OVRoleMuted));
    for (NSView *v in [self.badgeHolder.arrangedSubviews copy]) { [self.badgeHolder removeArrangedSubview:v]; [v removeFromSuperview]; }
    [self.badgeHolder addArrangedSubview:badge];
    self.portError.stringValue = api.lastError ?: @"";
    self.portError.hidden = !api.lastError.length;
    NSString *key = api.currentKey;
    self.keyLabel.stringValue = self.keyShown ? key : [self maskedKey:key];
    self.snippetLabel.stringValue = [self snippetWithKey:@"<your key>"];
    [self refreshJobs];
}

- (void)refreshJobs {
    for (NSView *v in [self.jobRows.arrangedSubviews copy]) { [self.jobRows removeArrangedSubview:v]; [v removeFromSuperview]; }
    NSArray *jobs = [OVAPI.shared recentJobs:5];
    self.emptyJobs.hidden = jobs.count > 0;
    for (OVJob *j in jobs) {
        NSTextField *title = OVLabel(j.title ?: j.kind, 14, NSFontWeightRegular, nil);
        title.lineBreakMode = NSLineBreakByTruncatingTail;
        [title setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSString *state; OVRole tone;
        switch (j.state) {
            case OVJobQueued: state = L(@"Queued"); tone = OVRoleMuted; break;
            case OVJobRunning: state = L(@"Running"); tone = OVRoleAccent; break;
            case OVJobSucceeded: state = L(@"Done"); tone = OVRoleOK; break;
            case OVJobStopped: state = L(@"Stopped"); tone = OVRoleWarn; break;
            default: state = L(@"Failed"); tone = OVRoleErr; break;
        }
        NSButton *open = [self small:L(@"Open in Jobs") symbol:nil action:@selector(openJobs:)];
        NSStackView *row = OVHStack(@[title, OVSpacer(), OVCompactBadge(state, tone), open], 10);
        row.alignment = NSLayoutAttributeCenterY;
        [self.jobRows addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.jobRows.widthAnchor].active = YES;
    }
}

#pragma mark - Actions

- (void)copyText:(NSString *)s from:(NSButton *)b {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:s forType:NSPasteboardTypeString];
    NSString *old = b.title;
    b.title = L(@"Copied");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ b.title = old; });
}

- (void)copyAddress:(NSButton *)b { [self copyText:OVAPI.shared.baseURL from:b]; }
- (void)copyKey:(NSButton *)b { [self copyText:OVAPI.shared.currentKey from:b]; }
- (void)copySnippet:(NSButton *)b { [self copyText:[self snippetWithKey:OVAPI.shared.currentKey] from:b]; }
- (void)openJobs:(id)s { OVNavigate(@"jobs"); }

- (void)toggleKey:(id)s {
    self.keyShown = !self.keyShown;
    self.showButton.title = self.keyShown ? L(@"Hide") : L(@"Show");
    [self refresh];
}

- (void)toggled:(OVSwitch *)sw {
    NSString *err = nil;
    if (![OVAPI.shared setEnabled:sw.on error:&err]) sw.on = NO;
    [self refresh];
}

- (void)applyPort:(id)s {
    NSString *err = nil;
    if (![OVAPI.shared applyPort:self.portField.integerValue error:&err]) {
        self.portError.stringValue = err ?: @"";
        self.portError.hidden = !err.length;
        self.portField.stringValue = [NSString stringWithFormat:@"%u", OVAPI.shared.port];
        return;
    }
    [self refresh];
}

- (void)rotate:(id)s {
    NSAlert *a = [NSAlert new];
    a.messageText = L(@"Create a new API key?");
    a.informativeText = L(@"Apps using the old key stop working.");
    [a addButtonWithTitle:L(@"Cancel")];
    [a addButtonWithTitle:L(@"Create new key")];
    ((NSButton *)a.buttons.lastObject).hasDestructiveAction = YES;
    void (^done)(NSModalResponse) = ^(NSModalResponse r) {
        if (r != NSAlertSecondButtonReturn) return;
        [OVAPI.shared rotateKey];
        self.keyShown = YES;
        self.showButton.title = L(@"Hide");
        [self refresh];
    };
    if (self.view.window) [a beginSheetModalForWindow:self.view.window completionHandler:done]; else done([a runModal]);
}

@end
