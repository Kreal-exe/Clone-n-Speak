// Developer page: every OVDesign component in each state, one card per component.
#import "OVDesign.h"
#import "OVLocale.h"
#import "OVPages.h"

@interface OVGalleryPage ()
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
    [d registerDefaults:@{@"OVGalleryA": @0.35, @"OVGalleryB": @7.0}];

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
    NSView *seg = OVVStack(@[Variant(L(@"With symbols"), @[self.modeSwitch, self.modeLabel]),
                             Variant(L(@"Text only"), @[plain]), Variant(L(@"Disabled"), @[dis])], 14);

    // Sliders
    OVSliderRow *s1 = [OVSliderRow rowWithTitle:L(@"Speed") hint:L(@"Enabled slider") key:@"OVGalleryA" min:0 max:1 format:@"%.2f" integer:NO];
    OVSliderRow *s2 = [OVSliderRow rowWithTitle:L(@"Steps") hint:L(@"Disabled slider") key:@"OVGalleryB" min:1 max:20 format:@"%.0f" integer:YES];
    s2.enabled = NO;
    NSStackView *sliders = OVVStack(@[s1, s2], 14);
    OVFillWidth(sliders.arrangedSubviews, sliders);

    // Fields
    NSTextField *empty = OVField(L(@"Placeholder text"));
    NSTextField *filled = OVField(@"");
    filled.stringValue = L(@"Some entered text");
    NSTextField *offField = OVField(@"");
    offField.stringValue = L(@"Disabled field");
    offField.enabled = NO;
    NSPopUpButton *popup = [NSPopUpButton new];
    [popup addItemsWithTitles:@[L(@"First choice"), L(@"Second choice")]];
    NSButton *on = [NSButton checkboxWithTitle:L(@"On") target:nil action:nil];
    on.state = NSControlStateValueOn;
    NSButton *off = [NSButton checkboxWithTitle:L(@"Off") target:nil action:nil];
    NSStackView *fields = OVVStack(@[empty, filled, offField, OVHStack(@[popup, on, off], 16)], 10);
    OVFillWidth(@[empty, filled, offField], fields);

    // Badges
    NSView *badges = OVHStack(@[OVBadge(L(@"Neutral"), OVRoleMuted), OVBadge(L(@"Ready"), OVRoleOK), OVBadge(L(@"Needs attention"), OVRoleWarn),
                                OVBadge(L(@"Error"), OVRoleErr), OVProBadge(), OVSpacer()], 8);

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
        OVStepCard(0, @"tag", L(@"Badges"), nil, badges),
        OVStepCard(0, @"square.and.arrow.down", L(@"Drop zone"), nil, zone),
        OVStepCard(0, @"tray", L(@"Empty state"), nil, emptyState),
        OVStepCard(0, @"terminal", L(@"Log"), nil, log),
    ];
    NSMutableArray *rows = [NSMutableArray arrayWithObjects:OVTitle(L(@"Design gallery")),
                            OVWrapLabel(L(@"Every component in each state. A developer page, not in the sidebar."), 13, nil), nil];
    [rows addObjectsFromArray:cards];
    NSStackView *page = OVVStack(rows, 16);
    [page setCustomSpacing:6 afterView:rows[0]];
    page.edgeInsets = NSEdgeInsetsMake(30, 32, 28, 32);
    OVFillWidth(rows, page);
    self.view = OVScrollPage(page);

    if ([d boolForKey:@"OVGalleryA11yDump"]) [self performSelector:@selector(dumpAccessibility) withObject:nil afterDelay:1.5];
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
