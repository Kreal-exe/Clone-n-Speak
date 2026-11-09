// Developer page: every OVDesign component in each state, one card per component.
#import "OVDesign.h"
#import "OVLocale.h"
#import "OVPages.h"

@interface OVGalleryPage () <NSTableViewDataSource, NSTableViewDelegate>
@property NSTableView *rowTable;
@property OVSegmented *modeSwitch;
@property NSTextField *modeLabel;
@property NSTextView *logText;
@end

static NSTextField *Cap(NSString *s) { return OVLabel(s, 11, NSFontWeightMedium, OVColor(OVRoleMuted)); }

/// A caption above a row of controls.
static NSView *Variant(NSString *caption, NSArray<NSView *> *views) {
    return OVVStack(@[Cap(caption), OVHStack(views, 10)], 6);
}

@implementation OVGalleryPage

- (void)loadView {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d registerDefaults:@{@"OVGalleryA": @0.35, @"OVGalleryB": @7.0, @"OVGalleryC": @0.6, @"OVGalleryD": @8.0, @"OVGalleryChkOn": @YES, @"OVGalleryChkOff": @NO, @"OVGalleryChkHint": @YES}];

    // Buttons
    NSButton *off1 = OVPrimaryButton(L(@"Primary"), nil, nil);
    off1.enabled = NO;
    NSButton *off2 = OVGhostButton(L(@"Ghost"), @"arrow.down.circle", nil, nil);
    off2.enabled = NO;
    NSButton *playOff = OVPlayButton(nil, nil);
    playOff.enabled = NO;
    NSButton *pause = OVPlayButton(nil, nil);
    pause.image = [NSImage imageWithSystemSymbolName:@"pause.fill" accessibilityDescription:nil];
    pause.accessibilityLabel = L(@"Pause");
    NSView *buttons = OVVStack(@[
        Variant(L(@"Enabled"), @[OVPrimaryButton(L(@"Primary"), nil, nil), OVGhostButton(L(@"Ghost"), @"arrow.down.circle", nil, nil),
                                 OVIconButton(@"gearshape", L(@"Settings"), nil, nil), OVPlayButton(nil, nil), pause]),
        Variant(L(@"Disabled"), @[off1, off2, playOff]),
    ], 14);

    // Headers and step cards
    NSView *stepA = OVStepCard(1, @"doc.text", L(@"Text"), L(@"Type the words to speak."), OVField(L(@"Hello, this is a sample.")));
    NSView *stepB = OVStepCard(2, @"music.note", L(@"Voice"), nil,
                               OVHStack(@[OVLabel(L(@"Header with an accessory"), 13, NSFontWeightRegular, nil), OVSpacer(), OVGhostButton(L(@"Refresh"), @"arrow.clockwise", nil, nil)], 8));
    NSView *headers = OVVStack(@[
        OVCardHeader(0, @"waveform", L(@"No step number"), OVBadge(L(@"2 voices"), OVRoleMuted)),
        OVCardHeader(3, nil, L(@"No symbol"), nil),
    ], 12);
    OVFillWidth(headers.subviews, (NSStackView *)headers);

    NSStackView *cardsStack = OVVStack(@[headers, stepA, stepB], 12);
    OVFillWidth(cardsStack.arrangedSubviews, cardsStack);

    // Disclosure
    OVDisclosure *closed = [OVDisclosure disclosureWithTitle:L(@"Advanced") subtitle:L(@"Collapsed, click to open") symbol:@"slider.horizontal.3"
                                                     content:OVWrapLabel(L(@"Hidden settings live here."), 13, nil)];
    OVDisclosure *open = [OVDisclosure disclosureWithTitle:L(@"Advanced") subtitle:L(@"Expanded") symbol:@"slider.horizontal.3"
                                                   content:OVWrapLabel(L(@"Hidden settings live here."), 13, nil)];
    [open setExpanded:YES animated:NO];
    NSStackView *disc = OVVStack(@[closed, open], 6);
    OVFillWidth(disc.arrangedSubviews, disc);

    // Segmented
    self.modeSwitch = [OVSegmented segmentedWithItems:@[@[L(@"Write text"), @"textformat"], @[L(@"Upload file"), @"arrow.up.doc"]]];
    self.modeSwitch.target = self;
    self.modeSwitch.action = @selector(modeChanged:);
    self.modeSwitch.accessibilityLabel = L(@"Input mode");
    self.modeLabel = OVLabel(L(@"Selected: Write text"), 12, NSFontWeightRegular, OVColor(OVRoleMuted));
    OVSegmented *plain = [OVSegmented segmentedWithItems:@[@[L(@"Low"), @""], @[L(@"Medium"), @""], @[L(@"High"), @""]]];
    plain.selectedIndex = 1;
    plain.accessibilityLabel = L(@"Quality");
    OVSegmented *dis = [OVSegmented segmentedWithItems:@[@[L(@"Off"), @""], @[L(@"On"), @""]]];
    dis.selectedIndex = 1;
    dis.enabled = NO;
    dis.accessibilityLabel = L(@"Disabled switch");
    OVSegmented *icons = [OVSegmented segmentedWithItems:@[@[@"", @"face.smiling", L(@"Calm")], @[@"", @"bolt", L(@"Excited")],
                                                           @[@"", @"moon", L(@"Sleepy")], @[@"", @"flame", L(@"Angry")]]];
    icons.selectedIndex = 1;
    icons.accessibilityLabel = L(@"Mood");
    OVSegmented *none = [OVSegmented segmentedWithItems:@[@[L(@"Low"), @""], @[L(@"High"), @""]]];
    none.selectedIndex = -1;
    none.accessibilityLabel = L(@"Nothing selected");
    NSView *seg = OVVStack(@[Variant(L(@"With symbols"), @[self.modeSwitch, self.modeLabel]),
                             Variant(L(@"Text only"), @[plain]), Variant(L(@"Icons only, with labels"), @[icons]),
                             Variant(L(@"Nothing selected"), @[none]), Variant(L(@"Disabled"), @[dis])], 14);

    // Sliders
    OVSliderRow *s1 = [OVSliderRow rowWithTitle:L(@"Speed") hint:L(@"Enabled slider") key:@"OVGalleryA" min:0 max:1 format:@"%.2f" integer:NO];
    OVSliderRow *s2 = [OVSliderRow rowWithTitle:L(@"Steps") hint:L(@"Disabled slider") key:@"OVGalleryB" min:1 max:20 format:@"%.0f" integer:YES];
    s2.enabled = NO;
    OVSliderRow *s3 = [OVSliderRow rowWithTitle:L(@"Strength") hint:nil key:@"OVGalleryC" min:0 max:1 format:@"%.2f" integer:NO];
    s3.compact = YES;
    s3.step = 0.05;
    OVSliderRow *s4 = [OVSliderRow rowWithTitle:L(@"Pitch") hint:nil key:@"OVGalleryD" min:-12 max:12 format:@"%.0f" integer:YES];
    s4.compact = YES;
    s4.valueFormatter = ^NSString *(double v) { return [NSString stringWithFormat:@"%+.0f st", v]; };
    [s4 refresh];
    __weak OVDisclosure *wClosed = closed;
    s1.onChange = ^{ wClosed.subtitle = [NSString stringWithFormat:L(@"Speed is now %.2f"), [NSUserDefaults.standardUserDefaults doubleForKey:@"OVGalleryA"]]; };
    NSStackView *sliders = OVVStack(@[s1, s2, s3, s4], 14);
    OVFillWidth(sliders.arrangedSubviews, sliders);

    // Fields
    NSTextField *empty = OVField(L(@"Placeholder text"));
    NSTextField *filled = OVField(@"");
    filled.stringValue = L(@"Some entered text");
    NSTextField *offField = OVField(@"");
    offField.stringValue = L(@"Disabled field");
    offField.enabled = NO;
    NSStackView *fields = OVVStack(@[empty, filled, offField], 10);
    OVFillWidth(fields.arrangedSubviews, fields);

    // Popup, checkboxes, switches, radio buttons
    OVPopup *popup = [OVPopup popup];
    [popup addItemsWithTitles:@[L(@"First choice"), L(@"Second choice")]];
    OVPopup *longPopup = [OVPopup popup];
    [longPopup addItemsWithTitles:@[L(@"A choice with a very long name that does not fit in the field and gets cut off")]];
    OVPopup *offPopup = [OVPopup popup];
    [offPopup addItemsWithTitles:@[L(@"Disabled popup")]];
    offPopup.enabled = NO;
    NSView *popups = OVVStack(@[Variant(L(@"Normal"), @[popup]), Variant(L(@"Long title"), @[longPopup]), Variant(L(@"Disabled"), @[offPopup])], 10);
    [longPopup.widthAnchor constraintEqualToConstant:240].active = YES;
    OVSwitch *swOn = [OVSwitch new];
    swOn.on = YES;
    swOn.accessibilityLabel = L(@"Switch on");
    OVSwitch *swOff = [OVSwitch new];
    swOff.accessibilityLabel = L(@"Switch off");
    OVSwitch *swDis = [OVSwitch new];
    swDis.enabled = NO;
    swDis.accessibilityLabel = L(@"Switch disabled");
    NSView *switches = OVHStack(@[Variant(L(@"On"), @[swOn]), Variant(L(@"Off"), @[swOff]), Variant(L(@"Disabled"), @[swDis]), OVSpacer()], 28);
    NSButton *cOn = OVCheckbox(L(@"Checked"), @"OVGalleryChkOn");
    NSButton *cOff = OVCheckbox(L(@"Unchecked"), @"OVGalleryChkOff");
    NSButton *cDis = OVCheckbox(L(@"Disabled"), @"OVGalleryChkOff");
    cDis.enabled = NO;
    NSButton *cHint = OVCheckbox(L(@"Checkbox with a hint"), @"OVGalleryChkHint");
    NSView *checks = OVVStack(@[OVHStack(@[cOn, cOff, cDis, OVSpacer()], 24), OVCheckRow(cHint, L(@"The hint sits under the checkbox, indented by 24 pt."))], 12);
    OVFillWidth(@[checks.subviews.lastObject], (NSStackView *)checks);
    NSButton *r1 = OVRadioButton(L(@"First option"), self, @selector(radioPicked:));
    NSButton *r2 = OVRadioButton(L(@"Second option"), self, @selector(radioPicked:));
    NSButton *r3 = OVRadioButton(L(@"Third option"), self, @selector(radioPicked:));
    r2.state = NSControlStateValueOn;
    NSView *radios = OVHStack(@[r1, r2, r3, OVSpacer()], 24);
    NSView *controls = OVVStack(@[popups, switches, checks, radios], 18);
    OVFillWidth(@[checks, radios], (NSStackView *)controls);

    // Page header, field block, columns
    NSView *hdr = OVPageHeader(L(@"Page title"), L(@"A short description of what the page does."), OVGhostButton(L(@"Action"), @"arrow.clockwise", nil, nil));
    NSView *hdrBare = OVPageHeader(L(@"Title only"), nil, nil);
    NSStackView *hdrs = OVVStack(@[hdr, hdrBare], 12);
    OVFillWidth(hdrs.arrangedSubviews, hdrs);
    OVPopup *fbPopup = [OVPopup popup];
    [fbPopup addItemsWithTitles:@[L(@"First choice"), L(@"Second choice")]];
    NSView *fieldBlock = OVFieldBlock(L(@"Field label"), L(@"A muted hint under the control explains what it does."), fbPopup);
    NSView *fieldBlock2 = OVFieldBlock(L(@"Name"), nil, OVField(L(@"Placeholder text")));
    NSView *cols = OVColumns(@[fieldBlock, fieldBlock2], 16);

    // Text area
    NSScrollView *ts = [NSTextView scrollableTextView];
    ((NSTextView *)ts.documentView).string = L(@"Text in a text area. Click it to see the focus border.");
    NSView *textArea = OVTextArea(ts, 90);
    NSView *textAreaBlock = OVFieldBlock(L(@"Text"), L(@"The border turns to the focus color while you type."), textArea);

    // Table rows: selected, hover, plain
    self.rowTable = [NSTableView new];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"c"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [self.rowTable addTableColumn:col];
    self.rowTable.headerView = nil;
    self.rowTable.backgroundColor = NSColor.clearColor;
    self.rowTable.rowHeight = 36;
    self.rowTable.intercellSpacing = NSMakeSize(0, 2);
    self.rowTable.dataSource = self;
    self.rowTable.delegate = self;
    self.rowTable.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    self.rowTable.focusRingType = NSFocusRingTypeNone;
    self.rowTable.accessibilityLabel = L(@"Rows");
    [self.rowTable reloadData];
    [self.rowTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    [self.rowTable.heightAnchor constraintEqualToConstant:3 * 38].active = YES;

    // Progress
    NSProgressIndicator *pDet = OVProgressBar();
    pDet.doubleValue = 0.6;
    NSProgressIndicator *pInd = OVProgressBar();
    pInd.indeterminate = YES;
    [pInd startAnimation:nil];
    NSStackView *progress = OVVStack(@[Variant(L(@"Determinate"), @[pDet]), Variant(L(@"Indeterminate"), @[pInd])], 12);
    for (NSStackView *st in progress.arrangedSubviews) OVFillWidth(@[st.arrangedSubviews.lastObject], st);
    OVFillWidth(progress.arrangedSubviews, progress);

    // Badges
    NSView *badges = OVHStack(@[OVBadge(L(@"Neutral"), OVRoleMuted), OVBadge(L(@"Ready"), OVRoleOK), OVBadge(L(@"Needs attention"), OVRoleWarn),
                                OVBadge(L(@"Error"), OVRoleErr), OVBadge(L(@"Accent"), OVRoleAccent), OVProBadge(), OVSpacer()], 8);

    // Drop zone, empty state, log
    OVDropZone *zone = [OVDropZone zoneWithTitle:L(@"Drop audio here") hint:L(@"or click to choose a file") types:@[@"wav", @"mp3", @"m4a", @"flac"]
                                         onFiles:^(NSArray<NSURL *> *urls) { OVLogAppend([NSString stringWithFormat:@"gallery: %lu file(s)", (unsigned long)urls.count]); }];
    NSView *emptyState = OVEmptyState(@"waveform", L(@"Nothing here yet"), L(@"Clone a voice to see it in this list."),
                                      @[OVPrimaryButton(L(@"Clone a voice"), nil, nil), OVGhostButton(L(@"Learn more"), nil, nil, nil)]);
    NSTextView *lt = nil;
    NSScrollView *log = OVLogView(&lt);
    self.logText = lt;
    self.logText.string = @"12:00:01  engine ready\n12:00:02  model loaded: 4-bit\n12:00:09  synthesized 3 phrases in 2.1 s";
    [log.heightAnchor constraintEqualToConstant:90].active = YES;

    NSArray *cards = @[
        OVStepCard(0, @"button.horizontal", L(@"Buttons"), nil, buttons),
        OVStepCard(0, @"rectangle.on.rectangle", L(@"Cards and headers"), nil, cardsStack),
        OVStepCard(0, @"chevron.down.square", L(@"Disclosure"), nil, disc),
        OVStepCard(0, @"switch.2", L(@"Segmented switch"), nil, seg),
        OVStepCard(0, @"slider.horizontal.3", L(@"Sliders"), nil, sliders),
        OVStepCard(0, @"character.cursor.ibeam", L(@"Fields"), nil, fields),
        OVStepCard(0, @"menubar.rectangle", L(@"Page header"), nil, hdrs),
        OVStepCard(0, @"text.alignleft", L(@"Field block and columns"), nil, cols),
        OVStepCard(0, @"filemenu.and.selection", L(@"Popup, switch, checkbox, radio"), nil, controls),
        OVStepCard(0, @"text.cursor", L(@"Text area"), nil, textAreaBlock),
        OVStepCard(0, @"list.bullet", L(@"Table rows"), L(@"Selected, hovered and plain rows."), self.rowTable),
        OVStepCard(0, @"chart.bar", L(@"Progress"), nil, progress),
        OVStepCard(0, @"tag", L(@"Badges"), nil, badges),
        OVStepCard(0, @"square.and.arrow.down", L(@"Drop zone"), nil, zone),
        OVStepCard(0, @"tray", L(@"Empty state"), nil, emptyState),
        OVStepCard(0, @"terminal", L(@"Log"), nil, log),
    ];
    NSMutableArray *rows = [NSMutableArray arrayWithObject:
        OVPageHeader(L(@"Design gallery"), L(@"Every component in each state. A developer page, not in the sidebar."), nil)];
    [rows addObjectsFromArray:cards];
    self.view = OVPageScroll(rows);

    if ([d boolForKey:@"OVGalleryA11yDump"]) [self performSelector:@selector(dumpAccessibility) withObject:nil afterDelay:1.5];
}

- (void)radioPicked:(NSButton *)b {
    for (NSView *v in b.superview.subviews)
        if ([v isKindOfClass:NSButton.class] && v != b) ((NSButton *)v).state = NSControlStateValueOff;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return 3; }

- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)row {
    NSString *names[] = {L(@"Selected row"), L(@"Hovered row"), L(@"Plain row")};
    NSTextField *l = OVLabel(names[row], 14, NSFontWeightMedium, nil);
    NSTableCellView *cell = [NSTableCellView new];
    [cell addSubview:l];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[[l.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:14],
                                              [l.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-14],
                                              [l.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]]];
    return cell;
}

- (NSTableRowView *)tableView:(NSTableView *)t rowViewForRow:(NSInteger)row {
    OVTableRowView *r = [OVTableRowView new];
    if (row == 1) r.hovered = YES;   // a still picture cannot hover
    return r;
}

- (void)modeChanged:(OVSegmented *)s {
    self.modeLabel.stringValue = [NSString stringWithFormat:L(@"Selected: %@"), s.selectedIndex == 0 ? L(@"Write text") : L(@"Upload file")];
}

/// -OVGalleryA11yDump YES: prints roles of the custom controls to stderr.
- (void)dumpAccessibility {
    NSMutableArray<NSView *> *stack = [NSMutableArray arrayWithObject:self.view];
    while (stack.count) {
        NSView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:OVSegmented.class] || [v isKindOfClass:OVDropZone.class] || [v isKindOfClass:OVDisclosure.class]) {
            fprintf(stderr, "A11Y %s role=%s label=%s value=%s acceptsFirstResponder=%d\n", NSStringFromClass(v.class).UTF8String,
                    v.accessibilityRole.UTF8String, [v.accessibilityLabel ?: @"-" UTF8String],
                    [[v.accessibilityValue description] ?: @"-" UTF8String], v.acceptsFirstResponder);
            for (id c in v.accessibilityChildren)
                fprintf(stderr, "A11Y   child role=%s label=%s value=%s\n", [[c accessibilityRole] UTF8String], [[c accessibilityLabel] UTF8String],
                        [[[c accessibilityValue] description] UTF8String]);
        }
        [stack addObjectsFromArray:v.subviews];
    }
    fflush(stderr);
}
@end
