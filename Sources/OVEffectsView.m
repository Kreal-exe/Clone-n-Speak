#import "OVEffectsView.h"
#import "OVDesign.h"
#import "OVUI.h"
#import "OVTheme.h"
#import "OVLocale.h"
#import "OVWorker.h"

static NSString *const kCatalogChanged = @"OVEffectsCatalogDidChange";
static const CGFloat kTitleWidth = 150;   // compact title column: "Low shelf frequency" fits, longer titles wrap to two lines

static NSArray<NSDictionary *> *gCatalog;
static BOOL gCatalogLoading;     // a request is in flight
static BOOL gCatalogWanted;      // some panel was opened (or needs the list): fetch when the worker is free
static NSString *gCatalogError;  // the last failure; cleared by Retry

/// One effect row: its model and the controls that edit it.
@interface OVFxRow : NSObject
@property (copy) NSString *type;
@property BOOL on;
@property NSMutableDictionary *params;
@property NSDictionary *info;                       // the catalog entry
@property OVSwitch *toggle;
@property NSMutableArray<OVSliderRow *> *sliders;
@property NSMutableArray<NSControl *> *others;      // popups and boolean switches
@end
@implementation OVFxRow
@end

@interface OVEffectsView ()
@property NSMutableArray<OVFxRow *> *rows;
@property OVDisclosure *disclosure;
@property BOOL showsList;                            // the disclosure holds the effects, not the loading / error line
@property NSInteger userExpanded;                    // 0 = the user never touched the disclosure, 1 = opened it, 2 = closed it
@property (nonatomic, copy) NSArray<NSDictionary *> *pending;   // the chain to show once the catalog is there
@end

@implementation OVEffectsView

+ (void)initialize {
    if (self != OVEffectsView.class) return;
    // Earlier builds kept one OVFx.<uuid>.* defaults key per slider; the sliders own their values now.
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    for (NSString *k in d.dictionaryRepresentation.allKeys) if ([k hasPrefix:@"OVFx."]) [d removeObjectForKey:k];
}

+ (NSArray<NSDictionary *> *)catalog { return gCatalog; }
+ (void)setCatalog:(NSArray<NSDictionary *> *)catalog {
    gCatalog = [catalog copy];
    if (catalog) gCatalogError = nil;
    [NSNotificationCenter.defaultCenter postNotificationName:kCatalogChanged object:nil];
}

/// Starts the fetch when it is wanted, none is running and the worker is free; a busy worker is waited for (see -workerChanged:).
+ (void)loadCatalogIfNeeded {
    gCatalogWanted = YES;
    if (gCatalog || gCatalogLoading || gCatalogError || OVWorker.shared.busy) return;
    gCatalogLoading = YES;
    [NSNotificationCenter.defaultCenter postNotificationName:kCatalogChanged object:nil];
    [[OVWorker shared] request:@{@"cmd": @"fx_catalog"} status:nil progress:nil done:^(NSDictionary *data, NSString *error) {
        gCatalogLoading = NO;
        NSArray *fx = [data[@"effects"] isKindOfClass:NSArray.class] ? data[@"effects"] : nil;
        if (fx.count) { [OVEffectsView setCatalog:fx]; return; }
        gCatalogError = error.length ? error : L(@"The list of effects could not be loaded.");
        [NSNotificationCenter.defaultCenter postNotificationName:kCatalogChanged object:nil];
    }];
}

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _rows = [NSMutableArray array];
        _pending = @[];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(catalogChanged:) name:kCatalogChanged object:nil];
        [nc addObserver:self selector:@selector(workerChanged:) name:OVWorkerDidChangeNotification object:nil];
        [self rebuild];
    }
    return self;
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)catalogChanged:(NSNotification *)n {
    if (gCatalog && self.showsList) return;   // a view that already shows the list keeps its edits
    [self rebuild];
}

/// The worker became idle: a fetch that was waiting for it goes ahead (an error waits for Retry instead).
- (void)workerChanged:(NSNotification *)n {
    if (gCatalogWanted && !gCatalog && !gCatalogLoading && !gCatalogError && !OVWorker.shared.busy) [OVEffectsView loadCatalogIfNeeded];
}

- (void)retry:(id)sender {
    gCatalogError = nil;
    [OVEffectsView loadCatalogIfNeeded];
    [NSNotificationCenter.defaultCenter postNotificationName:kCatalogChanged object:nil];
}

#pragma mark Model

static double clampTo(double v, double lo, double hi) { return MIN(hi, MAX(lo, v)); }

/// Params of a catalog entry merged with the given values: only keys the catalog knows, numbers clamped, choices checked.
static NSMutableDictionary *mergedParams(NSDictionary *info, NSDictionary *given) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSDictionary *specs = info[@"params"];
    for (NSString *k in specs) {
        NSDictionary *spec = specs[k];
        id v = given[k];
        if (spec[@"choices"]) {
            out[k] = (v && [spec[@"choices"] containsObject:v]) ? v : spec[@"default"];
        } else {
            double d = [v isKindOfClass:NSNumber.class] ? [v doubleValue] : [spec[@"default"] doubleValue];
            out[k] = @(clampTo(d, [spec[@"min"] doubleValue], [spec[@"max"] doubleValue]));
        }
    }
    return out;
}

/// Parameter ids in display order: the catalog's `order` (registration order), then any it did not list, sorted.
static NSArray<NSString *> *paramOrder(NSDictionary *info) {
    NSDictionary *specs = info[@"params"];
    NSMutableArray *out = [NSMutableArray array];
    if ([info[@"order"] isKindOfClass:NSArray.class])
        for (id k in info[@"order"]) if ([k isKindOfClass:NSString.class] && specs[k] && ![out containsObject:k]) [out addObject:k];
    NSMutableArray *rest = [NSMutableArray array];
    for (NSString *k in specs.allKeys) if (![out containsObject:k]) [rest addObject:k];
    [out addObjectsFromArray:[rest sortedArrayUsingSelector:@selector(compare:)]];
    return out;
}

- (NSArray<NSDictionary *> *)chain {
    if (!gCatalog) return self.pending;
    NSMutableArray *out = [NSMutableArray array];
    for (OVFxRow *r in self.rows) [out addObject:@{@"type": r.type, @"on": @(r.on), @"params": [r.params copy]}];
    return out;
}
- (NSArray<NSDictionary *> *)activeChain {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *e in self.chain) if ([e[@"on"] boolValue]) [out addObject:e];
    return out;
}
- (void)setChain:(NSArray<NSDictionary *> *)chain {
    self.pending = chain ?: @[];
    if (self.pending.count && !gCatalog) [OVEffectsView loadCatalogIfNeeded];   // a chain to show: the catalog is needed now
    [self rebuild];
}
- (void)resetToDefaults {
    self.pending = @[];
    [self rebuild];
    if (self.onChange) self.onChange();
}

/// The rows to show: the entries of `pending` the catalog knows, then every catalog effect not yet listed (off, defaults).
- (NSArray<OVFxRow *> *)makeRows {
    NSMutableDictionary<NSString *, NSDictionary *> *byType = [NSMutableDictionary dictionary];
    for (NSDictionary *e in gCatalog) byType[e[@"id"]] = e;
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *e in self.pending) {
        NSDictionary *info = [e[@"type"] isKindOfClass:NSString.class] ? byType[e[@"type"]] : nil;
        if (!info) continue;
        OVFxRow *r = [OVFxRow new];
        r.type = e[@"type"]; r.info = info;
        r.on = [e[@"on"] isKindOfClass:NSNumber.class] ? [e[@"on"] boolValue] : YES;
        r.params = mergedParams(info, [e[@"params"] isKindOfClass:NSDictionary.class] ? e[@"params"] : @{});
        [rows addObject:r];
        [seen addObject:r.type];
    }
    for (NSDictionary *info in gCatalog) {
        if ([seen containsObject:info[@"id"]]) continue;
        OVFxRow *r = [OVFxRow new];
        r.type = info[@"id"]; r.info = info; r.on = NO;
        r.params = mergedParams(info, @{});
        [rows addObject:r];
    }
    return rows;
}

#pragma mark View

/// What the closed-or-open disclosure holds while there is no catalog: a loading line, or the error with a Retry button.
- (NSView *)placeholderContent {
    if (gCatalogError.length) {
        NSTextField *msg = OVWrapLabel(gCatalogError, 13, OVColor(OVRoleMuted));
        NSButton *retry = OVGhostButton(L(@"Retry"), @"arrow.clockwise", self, @selector(retry:));
        return OVFillStack(@[msg, OVHStack(@[retry, OVSpacer()], 8)], 8);
    }
    return OVFillStack(@[OVLabel(L(@"Loading effects…"), 13, NSFontWeightRegular, OVColor(OVRoleMuted))], 0);
}

- (void)rebuild {
    for (NSView *v in [self.subviews copy]) [v removeFromSuperview];
    self.rows = [NSMutableArray array];
    BOOL wasExpanded = self.disclosure ? self.disclosure.expanded : NO;
    self.disclosure = nil;
    self.showsList = NO;

    NSView *content;
    BOOL anyOn = NO;
    if (gCatalog) {
        self.rows = [[self makeRows] mutableCopy];
        NSMutableArray<NSView *> *blocks = [NSMutableArray array];
        for (NSUInteger i = 0; i < self.rows.count; i++) {
            OVFxRow *r = self.rows[i];
            if (r.on) anyOn = YES;
            [blocks addObject:[self blockForRow:r index:i]];
        }
        content = OVFillStack(blocks, 16);
        self.showsList = YES;
    } else {
        content = [self placeholderContent];
    }
    self.disclosure = [OVDisclosure disclosureWithTitle:L(@"Effects") subtitle:nil symbol:@"slider.horizontal.3" content:content];
    [self addSubview:self.disclosure];
    OVPin(self.disclosure, self, NSEdgeInsetsZero);
    // The user's own choice wins; before that, open for a chain that has effects on, and keep what a rebuild found open.
    BOOL open = self.userExpanded == 1 ? YES : self.userExpanded == 2 ? NO : (anyOn || wasExpanded);
    if (NSProcessInfo.processInfo.environment[@"OV_SNAPSHOT_FX_OPEN"].length && self.userExpanded == 0) open = YES;   // developer aid for snapshots
    [self.disclosure setExpanded:open animated:NO];
    __weak OVEffectsView *weak = self;
    self.disclosure.onToggle = ^(BOOL expanded) {
        OVEffectsView *s = weak;
        if (!s) return;
        s.userExpanded = expanded ? 1 : 2;
        if (expanded && !gCatalog) [OVEffectsView loadCatalogIfNeeded];   // first opening: now the list is needed
    };
    if (open && !gCatalog) [OVEffectsView loadCatalogIfNeeded];
    [self updateSummary];
}

- (void)updateSummary {
    if (!self.showsList) { self.disclosure.subtitle = nil; return; }
    NSUInteger n = 0;
    for (OVFxRow *r in self.rows) if (r.on) n++;
    self.disclosure.subtitle = n ? [NSString stringWithFormat:L(@"%lu on"), (unsigned long)n] : L(@"All off");
}

/// Printf format with just enough decimals to show multiples of `step`.
static NSString *formatForStep(double step) {
    if (step >= 1 || step <= 0) return @"%.0f";
    int decimals = MIN(3, (int)ceil(-log10(step) - 1e-9));
    return [NSString stringWithFormat:@"%%.%df", MAX(1, decimals)];
}

static BOOL isIntegral(double v) { return v == floor(v); }

- (NSView *)blockForRow:(OVFxRow *)r index:(NSUInteger)i {
    r.sliders = [NSMutableArray array];
    r.others = [NSMutableArray array];
    NSString *effectTitle = L(r.info[@"title"]);
    OVSwitch *sw = [OVSwitch new];
    sw.on = r.on;
    sw.tag = (NSInteger)i;
    sw.target = self;
    sw.action = @selector(toggled:);
    sw.accessibilityLabel = effectTitle;
    r.toggle = sw;
    NSTextField *title = OVLabel(effectTitle, 14, NSFontWeightSemibold, nil);
    NSMutableArray<NSView *> *lines = [NSMutableArray arrayWithObject:OVHStack(@[sw, title, OVSpacer()], 10)];

    NSDictionary *specs = r.info[@"params"];
    for (NSString *key in paramOrder(r.info)) {
        NSDictionary *spec = specs[key];
        NSString *ptitle = L(spec[@"title"] ?: key);
        NSString *axName = [NSString stringWithFormat:@"%@, %@", effectTitle, ptitle];
        if (spec[@"choices"]) {
            NSArray *choices = spec[@"choices"];
            BOOL boolean = choices.count == 2 && [choices containsObject:@0] && [choices containsObject:@1];
            if (boolean) {
                OVSwitch *b = [OVSwitch new];
                b.on = [r.params[key] boolValue];
                b.accessibilityLabel = axName;
                b.target = self; b.action = @selector(boolChanged:);
                b.identifier = [NSString stringWithFormat:@"%lu|%@", (unsigned long)i, key];
                [r.others addObject:b];
                NSTextField *l = OVLabel(ptitle, 13, NSFontWeightRegular, OVColor(OVRoleMuted));
                [lines addObject:OVHStack(@[l, OVSpacer(), b], 12)];
            } else {
                OVPopup *pop = [OVPopup popup];
                for (id c in choices) [pop addItemWithTitle:[c isKindOfClass:NSString.class] ? L(c) : [NSString stringWithFormat:@"%@", c]];
                [pop selectItemAtIndex:MAX(0, (NSInteger)[choices indexOfObject:r.params[key]])];
                pop.accessibilityLabel = axName;
                pop.target = self; pop.action = @selector(choiceChanged:);
                pop.identifier = [NSString stringWithFormat:@"%lu|%@", (unsigned long)i, key];
                [r.others addObject:pop];
                NSTextField *l = OVLabel(ptitle, 13, NSFontWeightRegular, OVColor(OVRoleMuted));
                l.toolTip = ptitle;
                [l.widthAnchor constraintEqualToConstant:kTitleWidth].active = YES;
                [lines addObject:OVHStack(@[l, OVFillPopup(pop)], 12)];
            }
            continue;
        }
        double lo = [spec[@"min"] doubleValue], hi = [spec[@"max"] doubleValue], def = [spec[@"default"] doubleValue];
        double step = [spec[@"step"] isKindOfClass:NSNumber.class] ? [spec[@"step"] doubleValue] : 0;
        if (step <= 0) {   // an older catalog without steps: guess
            BOOL guessInt = isIntegral(lo) && isIntegral(hi) && isIntegral(def) && hi - lo >= 2;   // a 0...1 range is a fraction, not a count
            step = guessInt ? 1 : (hi - lo <= 10 ? 0.01 : 0.1);
        }
        NSString *rawUnit = [spec[@"unit"] isKindOfClass:NSString.class] ? spec[@"unit"] : @"";
        NSString *unit = rawUnit.length ? L(rawUnit) : @"";
        NSString *fmt = formatForStep(step);
        OVSliderRow *s = [OVSliderRow rowWithTitle:ptitle hint:nil value:[r.params[key] doubleValue] min:lo max:hi format:fmt integer:step >= 1];
        s.compact = YES;
        s.titleWidth = kTitleWidth;
        s.step = step;
        s.accessibilityName = axName;
        if (unit.length) {
            BOOL tight = [rawUnit isEqualToString:@"x"] || [rawUnit isEqualToString:@"%"] || [rawUnit hasPrefix:@":"];
            s.valueFormatter = ^NSString *(double v) {
                return [NSString stringWithFormat:tight ? @"%@%@" : @"%@ %@", [NSString stringWithFormat:fmt, v], unit];
            };
            [s refresh];
        }
        s.enabled = r.on;
        __weak OVEffectsView *weak = self;
        __weak OVFxRow *weakRow = r;
        __weak OVSliderRow *weakSlider = s;
        s.onChange = ^{
            OVFxRow *row = weakRow;
            OVSliderRow *slider = weakSlider;
            if (!row || !slider) return;
            row.params[key] = @(slider.value);
            if (weak.onChange) weak.onChange();
        };
        [r.sliders addObject:s];
        [lines addObject:s];
    }
    for (NSControl *c in r.others) c.enabled = r.on;

    NSStackView *params = OVFillStack([lines subarrayWithRange:NSMakeRange(1, lines.count - 1)], 8);
    NSMutableArray *all = [NSMutableArray arrayWithObject:lines[0]];
    if (lines.count > 1) {
        NSStackView *indented = OVHStack(@[params], 0);
        indented.edgeInsets = NSEdgeInsetsMake(0, 46, 0, 0);
        [all addObject:indented];
        [params.widthAnchor constraintEqualToAnchor:indented.widthAnchor constant:-46].active = YES;
    }
    return OVFillStack(all, 10);
}

#pragma mark Actions

- (void)toggled:(OVSwitch *)sw {
    OVFxRow *r = sw.tag >= 0 && sw.tag < (NSInteger)self.rows.count ? self.rows[sw.tag] : nil;
    if (!r) return;
    r.on = sw.on;
    for (OVSliderRow *s in r.sliders) s.enabled = r.on;
    for (NSControl *c in r.others) c.enabled = r.on;
    [self updateSummary];
    if (self.onChange) self.onChange();
}

- (OVFxRow *)rowForIdentifier:(NSString *)ident param:(NSString **)param {
    NSArray *parts = [ident componentsSeparatedByString:@"|"];
    if (parts.count != 2) return nil;
    NSUInteger i = (NSUInteger)[parts[0] integerValue];
    if (i >= self.rows.count) return nil;
    *param = parts[1];
    return self.rows[i];
}
- (void)boolChanged:(OVSwitch *)sw {
    NSString *key; OVFxRow *r = [self rowForIdentifier:sw.identifier param:&key];
    if (!r) return;
    r.params[key] = sw.on ? @1 : @0;
    if (self.onChange) self.onChange();
}
- (void)choiceChanged:(OVPopup *)pop {
    NSString *key; OVFxRow *r = [self rowForIdentifier:pop.identifier param:&key];
    NSArray *choices = r.info[@"params"][key][@"choices"];
    NSInteger idx = pop.indexOfSelectedItem;
    if (!r || idx < 0 || idx >= (NSInteger)choices.count) return;
    r.params[key] = choices[idx];
    if (self.onChange) self.onChange();
}

@end
