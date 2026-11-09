#import "OVEffectsView.h"
#import "OVDesign.h"
#import "OVUI.h"
#import "OVTheme.h"
#import "OVLocale.h"
#import "OVWorker.h"

static NSString *const kCatalogLoaded = @"OVEffectsCatalogDidLoad";
static NSArray<NSDictionary *> *gCatalog;
static BOOL gCatalogLoading;

/// One effect row: its model and the controls that edit it.
@interface OVFxRow : NSObject
@property (copy) NSString *type;
@property BOOL on;
@property NSMutableDictionary *params;
@property NSDictionary *info;                       // the catalog entry
@property OVSwitch *toggle;
@property NSMutableArray<OVSliderRow *> *sliders;
@property NSMutableDictionary<NSString *, NSString *> *sliderParam;   // defaults key -> param name
@property NSMutableArray<NSControl *> *others;      // popups and boolean switches
@end
@implementation OVFxRow
@end

@interface OVEffectsView ()
@property NSString *uid;
@property NSMutableArray<OVFxRow *> *rows;
@property OVDisclosure *disclosure;
@property NSTextField *loading;
@property (nonatomic, copy) NSArray<NSDictionary *> *pending;   // the chain to show once the catalog is there
@end

@implementation OVEffectsView

+ (NSArray<NSDictionary *> *)catalog { return gCatalog; }
+ (void)setCatalog:(NSArray<NSDictionary *> *)catalog {
    gCatalog = [catalog copy];
    if (catalog) [NSNotificationCenter.defaultCenter postNotificationName:kCatalogLoaded object:nil];
}
+ (void)loadCatalogIfNeeded {
    if (gCatalog || gCatalogLoading) return;
    gCatalogLoading = YES;
    [[OVWorker shared] request:@{@"cmd": @"fx_catalog"} status:nil progress:nil done:^(NSDictionary *data, NSString *error) {
        gCatalogLoading = NO;
        NSArray *fx = [data[@"effects"] isKindOfClass:NSArray.class] ? data[@"effects"] : nil;
        if (fx.count) [OVEffectsView setCatalog:fx];
    }];
}

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _uid = NSUUID.UUID.UUIDString;
        _rows = [NSMutableArray array];
        _pending = @[];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(catalogLoaded:) name:kCatalogLoaded object:nil];
        [self rebuild];
        if (!gCatalog) [OVEffectsView loadCatalogIfNeeded];
    }
    return self;
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self dropDefaults];
}

- (void)catalogLoaded:(NSNotification *)n {
    if (!self.disclosure) [self rebuild];   // a view that already shows the list keeps its edits
}

#pragma mark Model

- (NSString *)defaultsKeyForRow:(NSUInteger)i param:(NSString *)p { return [NSString stringWithFormat:@"OVFx.%@.%lu.%@", self.uid, (unsigned long)i, p]; }

- (void)dropDefaults {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    for (OVFxRow *r in self.rows) for (NSString *k in r.sliderParam) [d removeObjectForKey:k];
}

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

- (void)rebuild {
    [self dropDefaults];
    for (NSView *v in [self.subviews copy]) [v removeFromSuperview];
    self.rows = [NSMutableArray array];
    self.disclosure = nil;
    self.loading = nil;
    if (!gCatalog) {
        self.loading = OVLabel(L(@"Loading effects…"), 13, NSFontWeightRegular, OVColor(OVRoleMuted));
        [self addSubview:self.loading];
        OVPin(self.loading, self, NSEdgeInsetsMake(8, 0, 8, 0));
        return;
    }
    BOOL wasOpen = NO;
    self.rows = [[self makeRows] mutableCopy];
    NSMutableArray<NSView *> *blocks = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.rows.count; i++) {
        OVFxRow *r = self.rows[i];
        if (r.on) wasOpen = YES;
        [blocks addObject:[self blockForRow:r index:i]];
    }
    NSStackView *list = OVFillStack(blocks, 16);
    self.disclosure = [OVDisclosure disclosureWithTitle:L(@"Effects") subtitle:nil symbol:@"slider.horizontal.3" content:list];
    [self addSubview:self.disclosure];
    OVPin(self.disclosure, self, NSEdgeInsetsZero);
    [self.disclosure setExpanded:wasOpen animated:NO];
    [self updateSummary];
}

- (void)updateSummary {
    NSUInteger n = 0;
    for (OVFxRow *r in self.rows) if (r.on) n++;
    self.disclosure.subtitle = n ? [NSString stringWithFormat:L(@"%lu on"), (unsigned long)n] : L(@"All off");
}

static BOOL isIntegral(double v) { return v == floor(v); }

- (NSView *)blockForRow:(OVFxRow *)r index:(NSUInteger)i {
    r.sliders = [NSMutableArray array];
    r.sliderParam = [NSMutableDictionary dictionary];
    r.others = [NSMutableArray array];
    OVSwitch *sw = [OVSwitch new];
    sw.on = r.on;
    sw.tag = (NSInteger)i;
    sw.target = self;
    sw.action = @selector(toggled:);
    sw.accessibilityLabel = L(r.info[@"title"]);
    r.toggle = sw;
    NSTextField *title = OVLabel(L(r.info[@"title"]), 14, NSFontWeightSemibold, nil);
    NSMutableArray<NSView *> *lines = [NSMutableArray arrayWithObject:OVHStack(@[sw, title, OVSpacer()], 10)];

    NSDictionary *specs = r.info[@"params"];
    for (NSString *key in [specs.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *spec = specs[key];
        NSString *ptitle = L(spec[@"title"] ?: key);
        if (spec[@"choices"]) {
            NSArray *choices = spec[@"choices"];
            BOOL boolean = choices.count == 2 && [choices containsObject:@0] && [choices containsObject:@1];
            if (boolean) {
                OVSwitch *b = [OVSwitch new];
                b.on = [r.params[key] boolValue];
                b.accessibilityLabel = ptitle;
                b.target = self; b.action = @selector(boolChanged:);
                b.identifier = [NSString stringWithFormat:@"%lu|%@", (unsigned long)i, key];
                [r.others addObject:b];
                NSTextField *l = OVLabel(ptitle, 13, NSFontWeightRegular, OVColor(OVRoleMuted));
                [lines addObject:OVHStack(@[l, OVSpacer(), b], 12)];
            } else {
                OVPopup *pop = [OVPopup popup];
                for (id c in choices) [pop addItemWithTitle:[c isKindOfClass:NSString.class] ? L(c) : [NSString stringWithFormat:@"%@", c]];
                [pop selectItemAtIndex:MAX(0, (NSInteger)[choices indexOfObject:r.params[key]])];
                pop.accessibilityLabel = ptitle;
                pop.target = self; pop.action = @selector(choiceChanged:);
                pop.identifier = [NSString stringWithFormat:@"%lu|%@", (unsigned long)i, key];
                [r.others addObject:pop];
                NSTextField *l = OVLabel(ptitle, 13, NSFontWeightRegular, OVColor(OVRoleMuted));
                [l.widthAnchor constraintEqualToConstant:82].active = YES;
                [lines addObject:OVHStack(@[l, OVFillPopup(pop)], 12)];
            }
            continue;
        }
        double lo = [spec[@"min"] doubleValue], hi = [spec[@"max"] doubleValue], def = [spec[@"default"] doubleValue];
        BOOL integer = isIntegral(lo) && isIntegral(hi) && isIntegral(def) && hi - lo >= 2;   // a 0...1 range is a fraction, not a count
        NSString *rawUnit = [spec[@"unit"] isKindOfClass:NSString.class] ? spec[@"unit"] : @"";
        NSString *unit = rawUnit.length ? L(rawUnit) : @"";
        NSString *fmt = integer ? @"%.0f" : (hi - lo <= 10 ? @"%.2f" : @"%.1f");
        NSString *dkey = [self defaultsKeyForRow:i param:key];
        [NSUserDefaults.standardUserDefaults setDouble:[r.params[key] doubleValue] forKey:dkey];
        OVSliderRow *s = [OVSliderRow rowWithTitle:ptitle hint:nil key:dkey min:lo max:hi format:fmt integer:integer];
        s.compact = YES;
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
        s.onChange = ^{
            OVFxRow *row = weakRow;
            if (!row) return;
            row.params[key] = @([NSUserDefaults.standardUserDefaults doubleForKey:dkey]);
            if (weak.onChange) weak.onChange();
        };
        r.sliderParam[dkey] = key;
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
