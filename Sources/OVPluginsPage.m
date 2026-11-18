// The Plugins page (task 8.8): the global switch, the installed plugins, the consent sheet and the Run sheet.
#import <objc/runtime.h>
#import "OVPages.h"
#import "OVDesign.h"
#import "OVPlugins.h"
#import "OVJobs.h"
#import "OVNetwork.h"
#import "OVPaths.h"
#import "OVLocale.h"
#import "OVStore.h"

#pragma mark - Audio input of the Run sheet

/// "Choose file…" plus "From history": holds the picked path.
@interface OVPluginAudioField : NSStackView
@property (nonatomic, copy, nullable) NSString *path;
@property NSTextField *label;
@end

@implementation OVPluginAudioField
+ (instancetype)field {
    OVPluginAudioField *f = [OVPluginAudioField new];
    f.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    f.spacing = 8;
    f.label = OVLabel(L(@"No file chosen"), 13, NSFontWeightRegular, OVColor(OVRoleMuted));
    f.label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [f.label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSButton *choose = OVSmallPill(OVGhostButton(L(@"Choose file…"), nil, f, @selector(choose:)));
    NSButton *hist = OVSmallPill(OVGhostButton(L(@"From history"), nil, f, @selector(history:)));
    [f setViews:@[choose, hist, f.label] inGravity:NSStackViewGravityLeading];
    return f;
}
- (void)setPath:(NSString *)path {
    _path = [path copy];
    self.label.stringValue = path.length ? path.lastPathComponent : L(@"No file chosen");
    self.label.toolTip = path;
}
- (void)choose:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.allowsMultipleSelection = NO;
    if ([p runModal] == NSModalResponseOK) self.path = p.URL.path;
}
- (void)history:(NSButton *)sender {
    NSMenu *m = [NSMenu new];
    NSArray<OVGeneration *> *all = OVHistory.shared.all;
    for (OVGeneration *g in [all subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)15, all.count))]) {
        if (!g.path.length || ![NSFileManager.defaultManager fileExistsAtPath:g.path]) continue;
        NSString *t = g.text.length > 48 ? [[g.text substringToIndex:48] stringByAppendingString:@"…"] : g.text;
        NSMenuItem *it = [m addItemWithTitle:t.length ? t : g.path.lastPathComponent action:@selector(pickHistory:) keyEquivalent:@""];
        it.target = self;
        it.representedObject = g.path;
    }
    if (!m.itemArray.count) [m addItemWithTitle:L(@"History is empty") action:nil keyEquivalent:@""].enabled = NO;
    [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, sender.bounds.size.height) inView:sender];
}
- (void)pickHistory:(NSMenuItem *)it { self.path = it.representedObject; }
@end

#pragma mark - Page

@interface OVPluginsPage ()
@property OVSwitch *globalSwitch;
@property NSStackView *listStack;
@property NSTextField *statusLabel;
@property NSMutableDictionary<NSString *, OVSwitch *> *switches;
// Run sheet
@property (weak) OVPlugin *runPlugin;
@property NSStackView *formStack;
@property NSMutableDictionary<NSString *, NSView *> *controls;
@property OVPopup *actionPopup;
@property NSAlert *runAlert;
@end

@implementation OVPluginsPage

- (void)loadView {
    self.switches = [NSMutableDictionary dictionary];
    OVPlugins *pl = OVPlugins.shared;

    self.globalSwitch = [OVSwitch new];
    self.globalSwitch.on = pl.enabled;
    self.globalSwitch.target = self;
    self.globalSwitch.action = @selector(globalToggled:);
    self.globalSwitch.accessibilityLabel = L(@"Enable plugins");
    NSTextField *enableLabel = OVLabel(L(@"Enable plugins"), 14, NSFontWeightSemibold, nil);
    NSTextField *warn = OVWrapLabel(L(@"Plugins are code written by other people. They run in a restricted sandbox, but install only plugins you trust."), 13, OVColor(OVRoleMuted));
    NSButton *open = OVSmallPill(OVGhostButton(L(@"Open plugins folder"), @"folder", self, @selector(openFolder:)));
    NSButton *choose = OVSmallPill(OVGhostButton(L(@"Install from folder…"), @"plus", self, @selector(chooseFolder:)));
    NSView *card1 = OVStepCardWithAccessory(0, @"puzzlepiece.extension", L(@"Plugins"), OVProBadge(),
        OVFillStack(@[OVHStack(@[self.globalSwitch, enableLabel, OVSpacer()], 10), warn,
                      OVHStack(@[open, choose, OVSpacer()], 8)], 12));

    self.listStack = OVFillStack(@[], 10);
    self.statusLabel = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.statusLabel.hidden = YES;
    NSView *card2 = OVStepCard(0, @"square.stack.3d.up", L(@"Installed"), nil, OVFillStack(@[self.listStack, self.statusLabel], 12));

    NSView *header = OVPageHeader(L(@"Plugins"), L(@"Add your own tools to Clone’n’Speak."), nil);
    self.view = OVPageScroll(@[header, card1, card2]);

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(changed:) name:OVPluginsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(changed:) name:OVNetworkModeDidChangeNotification object:nil];
    [self rebuildList];
    [pl reload:nil];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)changed:(NSNotification *)n {
    self.globalSwitch.on = OVPlugins.shared.enabled;
    [self rebuildList];
}

#pragma mark List

- (void)rebuildList {
    for (NSView *v in [self.listStack.arrangedSubviews copy]) { [self.listStack removeArrangedSubview:v]; [v removeFromSuperview]; }
    [self.switches removeAllObjects];
    NSArray<OVPlugin *> *plugins = OVPlugins.shared.plugins;
    __weak typeof(self) weakSelf = self;
    for (OVPlugin *p in plugins) [self.listStack addArrangedSubview:[self rowForPlugin:p]];
    OVDropZone *zone = [OVDropZone zoneWithTitle:L(@"Drop a plugin folder") hint:L(@"or click to choose its plugin.json") types:@[]
                                         onFiles:^(NSArray<NSURL *> *urls) { [weakSelf install:urls.firstObject]; }];
    if (!plugins.count) {
        NSTextField *t = OVWrapLabel(L(@"No plugins installed yet. A plugin is a folder with plugin.json and main.py."), 13, OVColor(OVRoleMuted));
        [self.listStack addArrangedSubview:t];
    }
    [self.listStack addArrangedSubview:zone];
    [zone.heightAnchor constraintGreaterThanOrEqualToConstant:96].active = YES;
}

- (NSView *)rowForPlugin:(OVPlugin *)p {
    OVPlugins *pl = OVPlugins.shared;
    NSString *meta = [NSString stringWithFormat:L(@"Version %@ · by %@"), p.version ?: @"?", p.author ?: @"?"];
    NSTextField *name = OVLabel(p.name ?: p.identifier, 14, NSFontWeightSemibold, nil);
    NSMutableArray *lines = [NSMutableArray arrayWithObjects:name, OVLabel(meta, 13, NSFontWeightRegular, OVColor(OVRoleMuted)), nil];
    if (p.error) {
        NSTextField *e = OVWrapLabel(p.error, 13, OVColor(OVRoleErr));
        [lines addObject:e];
    } else if (p.summary.length) {
        [lines addObject:OVWrapLabel(p.summary, 13, OVColor(OVRoleMuted))];
    }
    NSMutableArray *badges = [NSMutableArray array];
    if (p.wantsNetwork) [badges addObject:OVCompactBadge([pl networkAllowed:p] ? L(@"Network allowed") : L(@"Network closed"),
                                                       [pl networkAllowed:p] ? OVRoleWarn : OVRoleMuted)];
    if (!p.error && pl.enabled && [pl switchOn:p] == NO && [pl needsTrust:p] && [NSUserDefaults.standardUserDefaults stringForKey:[@"pluginTrust." stringByAppendingString:p.identifier]])
        [badges addObject:OVCompactBadge(L(@"Files changed"), OVRoleWarn)];
    if (badges.count) [lines addObject:OVHStack(badges, 6)];
    NSStackView *text = OVVStack(lines, 2);
    text.alignment = NSLayoutAttributeLeading;
    [text setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    OVSwitch *sw = [OVSwitch new];
    sw.on = [pl switchOn:p] && pl.enabled;
    sw.enabled = !p.error && pl.enabled;
    sw.accessibilityLabel = [NSString stringWithFormat:L(@"Turn on %@"), p.name ?: p.identifier];
    sw.identifier = p.identifier;
    sw.target = self;
    sw.action = @selector(pluginToggled:);
    self.switches[p.identifier] = sw;

    NSButton *run = OVSmallPill(OVGhostButton(L(@"Run…"), @"play.fill", self, @selector(runClicked:)));
    run.identifier = p.identifier;
    run.enabled = [pl isActive:p];
    NSButton *remove = OVSmallPill(OVGhostButton(L(@"Remove"), @"trash", self, @selector(removeClicked:)));
    remove.identifier = p.identifier;
    NSButton *reveal = OVSmallPill(OVGhostButton(L(@"Reveal"), @"folder", self, @selector(revealClicked:)));
    reveal.identifier = p.identifier;
    for (NSButton *b in @[run, remove, reveal]) b.accessibilityLabel = [NSString stringWithFormat:@"%@ — %@", b.title, p.name ?: p.identifier];

    NSStackView *row = OVHStack(@[sw, text, OVSpacer(), run, reveal, remove], 10);
    row.alignment = NSLayoutAttributeCenterY;
    OVBoxView *box = [OVBoxView boxWithFill:OVColor(OVRoleSurface) border:OVColor(OVRoleBorder) radius:12];
    [box addSubview:row];
    OVPin(row, box, NSEdgeInsetsMake(12, 14, 12, 14));
    return box;
}

- (OVPlugin *)pluginForSender:(NSControl *)s { return [OVPlugins.shared pluginWithId:s.identifier ?: @""]; }

#pragma mark Switches and consent

- (void)globalToggled:(OVSwitch *)s {
    OVPlugins.shared.enabled = s.on;
    [self rebuildList];
}

- (void)pluginToggled:(OVSwitch *)s {
    OVPlugin *p = [self pluginForSender:s];
    if (!p) return;
    if (!s.on) { [OVPlugins.shared turnOff:p]; return; }
    if (![self askTrustFor:p]) s.on = NO;
}

/// The consent sheet: the warning text, the "I trust this plugin" box and, for a plugin that declares it, the network row.
- (BOOL)askTrustFor:(OVPlugin *)p {
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:L(@"Turn on %@?"), p.name ?: p.identifier];
    a.informativeText = [OVPlugins consentTextFor:p];
    NSButton *ok = [a addButtonWithTitle:L(@"Turn on")];
    [a addButtonWithTitle:L(@"Cancel")];
    NSButton *trust = [NSButton checkboxWithTitle:L(@"I trust this plugin") target:self action:@selector(trustBoxChanged:)];
    trust.accessibilityLabel = L(@"I trust this plugin");
    NSButton *net = nil;
    NSMutableArray *views = [NSMutableArray arrayWithObject:trust];
    if (p.wantsNetwork) {
        net = [NSButton checkboxWithTitle:L(@"Allow this plugin to use the network") target:nil action:nil];
        net.accessibilityLabel = L(@"Allow this plugin to use the network");
        NSTextField *h = OVWrapLabel(L(@"The plugin asks for network access. Without it the network stays closed for this plugin. Offline mode always keeps it closed."), 12, OVColor(OVRoleMuted));
        [views addObject:net];
        [views addObject:h];
    }
    NSStackView *acc = OVVStack(views, 8);
    acc.alignment = NSLayoutAttributeLeading;
    [acc setFrameSize:NSMakeSize(380, 24 + (net ? 60 : 0))];
    a.accessoryView = acc;
    ok.enabled = NO;
    objc_setAssociatedObject(trust, "okButton", ok, OBJC_ASSOCIATION_ASSIGN);
    if ([a runModal] != NSAlertFirstButtonReturn) return NO;
    BOOL wantNet = net && net.state == NSControlStateValueOn;
    if (!wantNet) { [OVPlugins.shared trust:p allowNetwork:NO]; return YES; }
    // the network gate answers in a sheet; the plugin is trusted either way, with the network open only if it agrees
    [OVNetwork requestFeature:OVNetPluginNetwork window:self.view.window completion:^(BOOL allowed) {
        [OVPlugins.shared trust:p allowNetwork:allowed];
    }];
    return YES;
}

- (void)trustBoxChanged:(NSButton *)b {
    NSButton *ok = objc_getAssociatedObject(b, "okButton");
    ok.enabled = b.state == NSControlStateValueOn;
}

#pragma mark Install, remove, reveal

- (void)openFolder:(id)sender {
    [NSFileManager.defaultManager createDirectoryAtPath:[OVPaths plugins] withIntermediateDirectories:YES attributes:nil error:nil];
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:[OVPaths plugins]]];
}

- (void)chooseFolder:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = NO;
    p.canChooseDirectories = YES;
    p.message = L(@"Choose the plugin folder (the one with plugin.json)");
    if ([p runModal] == NSModalResponseOK) [self install:p.URL];
}

- (void)install:(NSURL *)url {
    if (!url) return;
    BOOL dir = NO;
    [NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&dir];
    NSString *path = dir ? url.path : url.URLByDeletingLastPathComponent.path;
    [self setStatus:L(@"Installing…") error:NO];
    __weak typeof(self) weakSelf = self;
    [OVPlugins.shared installFolder:path completion:^(NSString *pid, NSString *err) {
        if (!pid) { [weakSelf setStatus:err error:YES]; return; }
        OVPlugin *p = [OVPlugins.shared pluginWithId:pid];
        [weakSelf setStatus:[NSString stringWithFormat:L(@"Installed %@. It is off until you turn it on."), p.name ?: pid] error:NO];
    }];
}

- (void)setStatus:(NSString *)s error:(BOOL)err {
    self.statusLabel.stringValue = s ?: @"";
    self.statusLabel.textColor = OVColor(err ? OVRoleErr : OVRoleMuted);
    self.statusLabel.hidden = !s.length;
    NSAccessibilityPostNotificationWithUserInfo(self.statusLabel, NSAccessibilityAnnouncementRequestedNotification,
        @{NSAccessibilityAnnouncementKey: s ?: @""});
}

- (void)removeClicked:(NSButton *)b {
    OVPlugin *p = [self pluginForSender:b];
    if (!p) return;
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:L(@"Remove %@?"), p.name ?: p.identifier];
    a.informativeText = L(@"The plugin and its data folder go to the Trash.");
    [a addButtonWithTitle:L(@"Cancel")];
    [a addButtonWithTitle:L(@"Remove")];
    if ([a runModal] != NSAlertSecondButtonReturn) return;
    [OVPlugins.shared remove:p];
}

- (void)revealClicked:(NSButton *)b {
    OVPlugin *p = [self pluginForSender:b];
    if (p) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:p.folder]]];
}

#pragma mark Run sheet

- (void)runClicked:(NSButton *)b {
    OVPlugin *p = [self pluginForSender:b];
    if (!p || ![OVPlugins.shared isActive:p]) return;
    self.runPlugin = p;
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:L(@"Run %@"), p.name ?: p.identifier];
    a.informativeText = p.summary ?: @"";
    [a addButtonWithTitle:L(@"Run")];
    [a addButtonWithTitle:L(@"Cancel")];
    self.runAlert = a;
    self.formStack = OVVStack(@[], 12);
    self.formStack.alignment = NSLayoutAttributeLeading;
    NSMutableArray *top = [NSMutableArray array];
    if (p.actions.count > 1) {
        self.actionPopup = [OVPopup popup];
        for (NSDictionary *act in p.actions) {
            [self.actionPopup addItemWithTitle:act[@"label"] ?: act[@"id"]];
            self.actionPopup.lastItem.representedObject = act[@"id"];
        }
        self.actionPopup.target = self;
        self.actionPopup.action = @selector(actionChanged:);
        self.actionPopup.accessibilityLabel = L(@"Action");
        [top addObject:OVFieldBlock(L(@"Action"), nil, self.actionPopup)];
    } else {
        self.actionPopup = nil;
    }
    NSStackView *acc = OVVStack([top arrayByAddingObject:self.formStack], 12);
    acc.alignment = NSLayoutAttributeLeading;
    [self buildFormForAction:p.actions.firstObject];
    a.accessoryView = acc;
    [self sizeAccessory];
    if ([a runModal] != NSAlertFirstButtonReturn) { self.runAlert = nil; return; }
    self.runAlert = nil;
    [self submitCurrent];
}

- (void)sizeAccessory {
    NSView *acc = self.runAlert.accessoryView;
    [acc setFrameSize:NSMakeSize(420, MAX(20, acc.fittingSize.height))];
    [self.runAlert layout];
}

- (NSDictionary *)currentAction {
    NSString *aid = self.actionPopup ? self.actionPopup.selectedItem.representedObject : self.runPlugin.actions.firstObject[@"id"];
    for (NSDictionary *a in self.runPlugin.actions) if ([a[@"id"] isEqualToString:aid]) return a;
    return nil;
}

- (void)actionChanged:(id)sender {
    [self buildFormForAction:[self currentAction]];
    [self sizeAccessory];
}

/// The form comes from the action's inputs: audio = file picker, text = field, number = slider row, choice = popup.
- (void)buildFormForAction:(NSDictionary *)action {
    for (NSView *v in [self.formStack.arrangedSubviews copy]) { [self.formStack removeArrangedSubview:v]; [v removeFromSuperview]; }
    self.controls = [NSMutableDictionary dictionary];
    for (NSDictionary *in in action[@"inputs"]) {
        NSString *name = in[@"name"], *type = in[@"type"], *label = in[@"label"] ?: name;
        NSView *c = nil;
        if ([type isEqualToString:@"audio"]) {
            c = [OVPluginAudioField field];
        } else if ([type isEqualToString:@"number"]) {
            double lo = in[@"min"] ? [in[@"min"] doubleValue] : 0, hi = in[@"max"] ? [in[@"max"] doubleValue] : 100;
            if (hi <= lo) hi = lo + 1;
            OVSliderRow *r = [OVSliderRow rowWithTitle:label hint:nil value:in[@"default"] ? [in[@"default"] doubleValue] : lo
                                                   min:lo max:hi format:@"%.1f" integer:NO];
            r.accessibilityName = label;
            self.controls[name] = r;
            [self.formStack addArrangedSubview:r];
            continue;
        } else if ([type isEqualToString:@"choice"]) {
            OVPopup *pop = [OVPopup popup];
            for (NSString *ch in in[@"choices"]) [pop addItemWithTitle:ch];
            if (in[@"default"]) [pop selectItemWithTitle:in[@"default"]];
            pop.accessibilityLabel = label;
            c = OVFillPopup(pop);
            self.controls[name] = pop;
            [self.formStack addArrangedSubview:OVFieldBlock(label, nil, c)];
            continue;
        } else {
            NSTextField *t = OVField(@"");
            t.stringValue = in[@"default"] ?: @"";
            t.accessibilityLabel = label;
            c = t;
        }
        self.controls[name] = c;
        [self.formStack addArrangedSubview:OVFieldBlock(label, nil, c)];
    }
    if (!self.formStack.arrangedSubviews.count)
        [self.formStack addArrangedSubview:OVLabel(L(@"This action needs no input."), 13, NSFontWeightRegular, OVColor(OVRoleMuted))];
}

- (void)submitCurrent {
    OVPlugin *p = self.runPlugin;
    NSDictionary *action = [self currentAction];
    NSMutableDictionary *inputs = [NSMutableDictionary dictionary];
    for (NSDictionary *in in action[@"inputs"]) {
        NSString *name = in[@"name"], *type = in[@"type"];
        NSView *c = self.controls[name];
        if ([type isEqualToString:@"audio"]) {
            NSString *path = ((OVPluginAudioField *)c).path;
            if (!path.length) { [self setStatus:[NSString stringWithFormat:L(@"Choose a file for “%@” first."), in[@"label"] ?: name] error:YES]; return; }
            inputs[name] = path;
        } else if ([type isEqualToString:@"number"]) {
            inputs[name] = @(((OVSliderRow *)c).value);
        } else if ([type isEqualToString:@"choice"]) {
            inputs[name] = ((OVPopup *)c).titleOfSelectedItem ?: @"";
        } else {
            inputs[name] = ((NSTextField *)c).stringValue ?: @"";
        }
    }
    if (!OVConfirmProRun(self.view.window)) return;
    NSString *err = nil;
    OVJob *job = [OVPlugins.shared submit:p action:action[@"id"] inputs:inputs error:&err];
    if (!job) { [self setStatus:err ?: L(@"The plugin could not be started.") error:YES]; return; }
    [self setStatus:[NSString stringWithFormat:L(@"Started “%@”. Follow it in Jobs; the result opens from there."), p.name ?: p.identifier] error:NO];
    OVNavigate(@"jobs");
}

@end
