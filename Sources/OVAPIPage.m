// "API & Bridge" page: the local API cards and, below them, the Bridge card.
#import "OVPages.h"
#import "OVDesign.h"
#import "OVAPI.h"
#import "OVBridge.h"
#import "OVNetwork.h"
#import <CoreImage/CoreImage.h>
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
@property NSStackView *bridgeBadgeHolder, *bridgeAddressBlock, *deviceRows;
@property NSButton *bridgeButton, *offlineButton;
@property NSTextField *bridgeStatus, *bridgeError, *bridgeAddress, *emptyDevices;
@property NSImageView *bridgeQR;
@property NSString *lastAnnounced;
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
    self.keyLabel.maximumNumberOfLines = 1;                    // never wraps: it truncates in the middle when narrow
    self.keyLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.keyLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
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

#pragma mark - Bridge card

/// A QR code of `text`: black modules on a white plate with a quiet zone, crisp at any size.
static NSImage *QRImage(NSString *text, CGFloat side) {
    CIFilter *f = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [f setValue:[text dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [f setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *ci = f.outputImage;
    if (!ci) return nil;
    CIContext *ctx = [CIContext contextWithOptions:nil];
    CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
    if (!cg) return nil;
    NSImage *img = [NSImage imageWithSize:NSMakeSize(side, side) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [NSColor.whiteColor setFill];
        NSRectFill(r);
        CGFloat margin = side * 0.08;
        CGContextRef c = NSGraphicsContext.currentContext.CGContext;
        CGContextSetInterpolationQuality(c, kCGInterpolationNone);
        CGContextDrawImage(c, NSInsetRect(r, margin, margin), cg);
        return YES;
    }];
    CGImageRelease(cg);
    return img;
}

- (NSView *)bridgeCard {
    self.bridgeBadgeHolder = OVHStack(@[], 0);
    NSView *warnBadge = OVBadge(L(@"Internet"), OVRoleWarn);
    NSTextField *warn = OVWrapLabel(L(@"While Bridge is on, this Mac can be reached from the internet through Cloudflare. Anyone who learns the address can ask to connect, but only devices you approve on this Mac get access. Stop Bridge when you are done."), 13, OVColor(OVRoleMuted));
    NSStackView *warnRow = OVHStack(@[warnBadge, warn], 10);
    warnRow.alignment = NSLayoutAttributeTop;

    self.bridgeButton = OVButtonHeight(OVPillButtonMake(L(@"Start Bridge"), @"play.fill", self, @selector(bridgeToggle:), NO), 34);
    self.bridgeStatus = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.bridgeStatus.accessibilityLabel = L(@"Bridge status");
    self.offlineButton = [self small:L(@"Open Settings") symbol:nil action:@selector(openSettings:)];
    NSStackView *controls = OVHStack(@[self.bridgeButton, self.bridgeStatus, self.offlineButton, OVSpacer()], 12);
    controls.alignment = NSLayoutAttributeCenterY;
    self.bridgeError = OVWrapLabel(@"", 13, OVColor(OVRoleErr));
    self.bridgeError.hidden = YES;

    self.bridgeAddress = [self mono:@"" size:13];
    self.bridgeAddress.accessibilityLabel = L(@"Bridge address");
    self.bridgeAddress.maximumNumberOfLines = 1;
    self.bridgeAddress.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.bridgeAddress setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *addrRow = OVHStack(@[self.bridgeAddress, OVSpacer(), [self small:L(@"Copy") symbol:@"doc.on.doc" action:@selector(copyBridgeAddress:)]], 8);
    addrRow.alignment = NSLayoutAttributeCenterY;
    self.bridgeQR = [NSImageView new];
    self.bridgeQR.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.bridgeQR.accessibilityLabel = L(@"QR code of the Bridge address");
    self.bridgeQR.translatesAutoresizingMaskIntoConstraints = NO;
    [self.bridgeQR.widthAnchor constraintEqualToConstant:150].active = YES;
    [self.bridgeQR.heightAnchor constraintEqualToConstant:150].active = YES;
    NSTextField *change = OVWrapLabel(L(@"This address changes every time you start Bridge."), 13, OVColor(OVRoleMuted));
    NSStackView *qrRow = OVHStack(@[self.bridgeQR, change, OVSpacer()], 16);
    qrRow.alignment = NSLayoutAttributeTop;
    self.bridgeAddressBlock = Column(@[[self boxed:addrRow], qrRow], 12);

    NSTextField *devTitle = OVLabel(L(@"Devices"), 14, NSFontWeightSemibold, nil);
    self.deviceRows = OVVStack(@[], 8);
    self.emptyDevices = OVWrapLabel(L(@"No devices yet. Open the address on another device and ask to connect; you approve it here."), 13, OVColor(OVRoleMuted));
    NSStackView *devices = Column(@[devTitle, self.emptyDevices, self.deviceRows], 8);

    return OVStepCardWithAccessory(0, @"antenna.radiowaves.left.and.right", L(@"Bridge"), self.bridgeBadgeHolder,
                                   Column(@[warnRow, controls, self.bridgeError, self.bridgeAddressBlock, devices], 14));
}

static NSString *DateText(NSDate *d) {
    static NSDateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [NSDateFormatter new]; f.dateStyle = NSDateFormatterMediumStyle; f.timeStyle = NSDateFormatterShortStyle; });
    return [f stringFromDate:d];
}

- (void)refreshBridge {
    OVBridge *b = OVBridge.shared;
    BOOL offline = OVNetwork.offline;
    NSView *badge = b.running ? OVBadge(L(@"Running"), OVRoleOK) : (b.busy ? OVBadge(L(@"Starting"), OVRoleAccent)
                    : (b.lastError.length ? OVBadge(L(@"Error"), OVRoleErr) : OVBadge(L(@"Off"), OVRoleMuted)));
    badge.accessibilityLabel = b.running ? L(@"Running") : (b.busy ? L(@"Starting") : (b.lastError.length ? L(@"Error") : L(@"Off")));
    badge.accessibilityRole = NSAccessibilityStaticTextRole;
    for (NSView *v in [self.bridgeBadgeHolder.arrangedSubviews copy]) { [self.bridgeBadgeHolder removeArrangedSubview:v]; [v removeFromSuperview]; }
    [self.bridgeBadgeHolder addArrangedSubview:badge];

    self.bridgeButton.title = b.busy ? L(@"Stop Bridge") : L(@"Start Bridge");
    self.bridgeButton.image = [NSImage imageWithSystemSymbolName:b.busy ? @"stop.fill" : @"play.fill" accessibilityDescription:nil];
    self.bridgeButton.enabled = b.busy || !offline;
    self.bridgeStatus.stringValue = b.status ?: (offline && !b.busy ? [OVNetwork blockedMessageFor:OVNetBridge] : @"");
    self.bridgeStatus.hidden = !self.bridgeStatus.stringValue.length;
    self.offlineButton.hidden = !(offline && !b.busy);
    self.bridgeError.stringValue = b.lastError ?: @"";
    self.bridgeError.hidden = !b.lastError.length;
    [self announceBridge:b.lastError.length ? b.lastError : b.status];

    // the address goes to the screen only while Bridge runs, and only here
    self.bridgeAddressBlock.hidden = !b.running;
    if (b.running) {
        self.bridgeAddress.stringValue = b.tunnelURL ?: @"";
        self.bridgeAddress.accessibilityValue = b.tunnelURL;
        self.bridgeQR.image = b.tunnelURL ? QRImage(b.tunnelURL, 150) : nil;
    } else {
        self.bridgeAddress.stringValue = @"";
        self.bridgeQR.image = nil;
    }

    for (NSView *v in [self.deviceRows.arrangedSubviews copy]) { [self.deviceRows removeArrangedSubview:v]; [v removeFromSuperview]; }
    NSArray *devices = b.devices;
    self.emptyDevices.hidden = devices.count > 0;
    for (NSDictionary *d in devices) {
        NSTextField *name = OVLabel(d[@"name"], 14, NSFontWeightRegular, nil);
        name.lineBreakMode = NSLineBreakByTruncatingTail;
        NSString *seen = d[@"lastSeen"] ? [NSString stringWithFormat:L(@"Last seen %@"), DateText(d[@"lastSeen"])] : L(@"Never connected");
        NSString *detail = [NSString stringWithFormat:L(@"Added %@"), DateText(d[@"created"])];
        NSTextField *meta = OVLabel([NSString stringWithFormat:@"%@  ·  %@", detail, seen], 13, NSFontWeightRegular, OVColor(OVRoleMuted));
        meta.lineBreakMode = NSLineBreakByTruncatingTail;
        NSStackView *texts = OVVStack(@[name, meta], 2);
        [texts setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSButton *revoke = [self small:L(@"Revoke") symbol:nil action:@selector(revokeDevice:)];
        revoke.identifier = d[@"id"];
        revoke.accessibilityLabel = [NSString stringWithFormat:L(@"Revoke %@"), d[@"name"]];
        NSStackView *row = OVHStack(@[texts, OVSpacer(), revoke], 10);
        row.alignment = NSLayoutAttributeCenterY;
        [self.deviceRows addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.deviceRows.widthAnchor].active = YES;
    }
}

/// VoiceOver hears Bridge's status and errors without looking at the card. A percentage tick is not repeated.
- (void)announceBridge:(NSString *)text {
    if (!text.length) { self.lastAnnounced = nil; return; }
    NSString *key = [text stringByReplacingOccurrencesOfString:@"[0-9]+" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, text.length)];
    if ([key isEqualToString:self.lastAnnounced]) return;
    self.lastAnnounced = key;
    NSAccessibilityPostNotificationWithUserInfo(NSApp, NSAccessibilityAnnouncementRequestedNotification,
        @{NSAccessibilityAnnouncementKey: text, NSAccessibilityPriorityKey: @(NSAccessibilityPriorityMedium)});
}

- (void)bridgeToggle:(id)s {
    if (OVBridge.shared.busy) [OVBridge.shared stop]; else [OVBridge.shared startInWindow:self.view.window];
}

- (void)copyBridgeAddress:(NSButton *)b { if (OVBridge.shared.tunnelURL) [self copyText:OVBridge.shared.tunnelURL from:b secret:YES]; }

- (void)revokeDevice:(NSButton *)b {
    NSString *did = b.identifier;
    if (!did.length) return;
    NSAlert *a = [NSAlert new];
    a.messageText = L(@"Revoke this device?");
    a.informativeText = L(@"It loses access at once and has to ask to connect again.");
    [a addButtonWithTitle:L(@"Cancel")];
    [a addButtonWithTitle:L(@"Revoke")];
    ((NSButton *)a.buttons.lastObject).hasDestructiveAction = YES;
    void (^done)(NSModalResponse) = ^(NSModalResponse r) { if (r == NSAlertSecondButtonReturn) [OVBridge.shared revokeDevice:did]; };
    if (self.view.window) [a beginSheetModalForWindow:self.view.window completionHandler:done]; else done([a runModal]);
}

- (void)openSettings:(id)s {
    [NSUserDefaults.standardUserDefaults setObject:@"general" forKey:@"settingsTab"];
    [NSApp sendAction:NSSelectorFromString(@"showSettings:") to:nil from:nil];
}

- (void)loadView {
    NSView *header = OVPageHeader(L(@"API & Bridge"), L(@"Let other apps and scripts on this Mac use your voices."), nil);
    NSMutableArray *views = [NSMutableArray arrayWithObjects:header, [self localCard], [self keyCard], [self quickStartCard], [self jobsCard], nil];
    [views addObject:[self bridgeCard]];
    self.view = OVPageScroll(views);
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(refresh) name:OVAPIDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refreshJobs) name:OVJobsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refreshBridge) name:OVBridgeDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refreshBridge) name:OVNetworkModeDidChangeNotification object:nil];
    [self refresh];
    [self refreshBridge];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    if (self.keyShown) { self.keyShown = NO; self.showButton.title = L(@"Show"); [self refresh]; }
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

#pragma mark - Showing state

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
    if (!self.portField.currentEditor) self.portField.stringValue = [NSString stringWithFormat:@"%u", api.port];
    NSView *badge = api.running ? OVBadge(L(@"Running"), OVRoleOK) : (api.lastError.length ? OVBadge(L(@"Error"), OVRoleErr) : OVBadge(L(@"Off"), OVRoleMuted));
    badge.accessibilityLabel = api.running ? L(@"Running") : (api.lastError.length ? L(@"Error") : L(@"Off"));
    badge.accessibilityRole = NSAccessibilityStaticTextRole;
    for (NSView *v in [self.badgeHolder.arrangedSubviews copy]) { [self.badgeHolder removeArrangedSubview:v]; [v removeFromSuperview]; }
    [self.badgeHolder addArrangedSubview:badge];
    self.portError.stringValue = api.lastError ?: @"";
    self.portError.hidden = !api.lastError.length;
    // the Keychain is read only when the key is shown (Show), copied or rotated: never on page load
    self.keyLabel.stringValue = self.keyShown ? api.currentKey : @"cns_••••••••••••••••••••";
    self.keyLabel.accessibilityValue = self.keyShown ? api.currentKey : L(@"hidden");
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
        row.accessibilityElement = YES;
        row.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", j.title ?: j.kind, state];
        [self.jobRows addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.jobRows.widthAnchor].active = YES;
    }
}

#pragma mark - Actions

- (void)copyText:(NSString *)s from:(NSButton *)b secret:(BOOL)secret {
    [NSPasteboard.generalPasteboard clearContents];
    NSPasteboardItem *item = [NSPasteboardItem new];
    [item setString:s forType:NSPasteboardTypeString];
    if (secret) [item setData:NSData.data forType:@"org.nspasteboard.ConcealedType"];   // clipboard managers skip it
    [NSPasteboard.generalPasteboard writeObjects:@[item]];
    NSString *old = b.title;
    b.title = L(@"Copied");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ b.title = old; });
}

- (void)copyAddress:(NSButton *)b { [self copyText:OVAPI.shared.baseURL from:b secret:NO]; }
- (void)copyKey:(NSButton *)b { [self copyText:OVAPI.shared.currentKey from:b secret:YES]; }
- (void)copySnippet:(NSButton *)b { [self copyText:[self snippetWithKey:OVAPI.shared.currentKey] from:b secret:YES]; }
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
        [self refresh];
    };
    if (self.view.window) [a beginSheetModalForWindow:self.view.window completionHandler:done]; else done([a runModal]);
}

@end
