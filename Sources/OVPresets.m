#import "OVPresets.h"
#import "OVPaths.h"
#import <objc/message.h>

NSNotificationName const OVPresetsDidChangeNotification = @"OVPresetsDidChangeNotification";

__attribute__((weak)) NSString *L(NSString *english) { return english; }

static const NSUInteger kMaxPresetBytes = 65536;
static const NSUInteger kNameMax = 60;

#pragma mark - JSON like Python's json.dumps(indent=2, sort_keys=True, ensure_ascii=False)

static void jsonString(NSMutableString *out, NSString *s) {
    [out appendString:@"\""];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        switch (c) {
            case '"': [out appendString:@"\\\""]; break;
            case '\\': [out appendString:@"\\\\"]; break;
            case '\n': [out appendString:@"\\n"]; break;
            case '\r': [out appendString:@"\\r"]; break;
            case '\t': [out appendString:@"\\t"]; break;
            case '\b': [out appendString:@"\\b"]; break;
            case '\f': [out appendString:@"\\f"]; break;
            default:
                if (c < 0x20) [out appendFormat:@"\\u%04x", c];
                else [out appendFormat:@"%C", c];
        }
    }
    [out appendString:@"\""];
}

static void jsonNumber(NSMutableString *out, NSNumber *n) {
    if ((__bridge CFTypeRef)n == (CFTypeRef)kCFBooleanTrue) { [out appendString:@"true"]; return; }
    if ((__bridge CFTypeRef)n == (CFTypeRef)kCFBooleanFalse) { [out appendString:@"false"]; return; }
    const char *t = n.objCType;
    if (t[0] == 'f' || t[0] == 'd') {
        double d = n.doubleValue;
        if (!isfinite(d)) { [out appendString:@"null"]; return; }
        if (d == 0) { [out appendString:signbit(d) ? @"-0.0" : @"0.0"]; return; }
        // Python's repr: the shortest digits that read back exactly; fixed notation for exponents -4...15, else d.ddde+XX.
        char buf[40];
        for (int prec = 0; prec <= 16; prec++) {
            snprintf(buf, sizeof buf, "%.*e", prec, fabs(d));
            if (strtod(buf, NULL) == fabs(d)) break;
        }
        NSString *sci = @(buf);
        NSRange er = [sci rangeOfString:@"e"];
        NSString *digits = [[sci substringToIndex:er.location] stringByReplacingOccurrencesOfString:@"." withString:@""];
        NSInteger ex = [[sci substringFromIndex:er.location + 1] integerValue];
        NSString *s;
        if (ex >= -4 && ex < 16) {
            if (ex >= 0) {
                BOOL more = (NSInteger)digits.length > ex + 1;
                NSString *ip = more ? [digits substringToIndex:ex + 1]
                                    : [digits stringByPaddingToLength:ex + 1 withString:@"0" startingAtIndex:0];
                s = [NSString stringWithFormat:@"%@.%@", ip, more ? [digits substringFromIndex:ex + 1] : @"0"];
            } else {
                s = [NSString stringWithFormat:@"0.%@%@", [@"" stringByPaddingToLength:-ex - 1 withString:@"0" startingAtIndex:0], digits];
            }
        } else {
            NSString *m = digits.length > 1 ? [NSString stringWithFormat:@"%@.%@", [digits substringToIndex:1], [digits substringFromIndex:1]] : digits;
            s = [NSString stringWithFormat:@"%@e%@%02ld", m, ex < 0 ? @"-" : @"+", (long)labs((long)ex)];
        }
        if (d < 0) s = [@"-" stringByAppendingString:s];
        [out appendString:s];
    } else if (t[0] == 'Q') {
        [out appendFormat:@"%llu", n.unsignedLongLongValue];
    } else {
        [out appendFormat:@"%lld", n.longLongValue];
    }
}

static void jsonValue(NSMutableString *out, id v, NSUInteger depth) {
    NSString *pad = [@"" stringByPaddingToLength:(depth + 1) * 2 withString:@" " startingAtIndex:0];
    NSString *endPad = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    if ([v isKindOfClass:NSDictionary.class]) {
        NSDictionary *d = v;
        if (!d.count) { [out appendString:@"{}"]; return; }
        NSArray *keys = [d.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            return [a compare:b options:NSLiteralSearch];
        }];
        [out appendString:@"{\n"];
        for (NSUInteger i = 0; i < keys.count; i++) {
            [out appendString:pad];
            jsonString(out, [keys[i] description]);
            [out appendString:@": "];
            jsonValue(out, d[keys[i]], depth + 1);
            [out appendString:i + 1 < keys.count ? @",\n" : @"\n"];
        }
        [out appendFormat:@"%@}", endPad];
    } else if ([v isKindOfClass:NSArray.class]) {
        NSArray *a = v;
        if (!a.count) { [out appendString:@"[]"]; return; }
        [out appendString:@"[\n"];
        for (NSUInteger i = 0; i < a.count; i++) {
            [out appendString:pad];
            jsonValue(out, a[i], depth + 1);
            [out appendString:i + 1 < a.count ? @",\n" : @"\n"];
        }
        [out appendFormat:@"%@]", endPad];
    } else if ([v isKindOfClass:NSString.class]) {
        jsonString(out, v);
    } else if ([v isKindOfClass:NSNumber.class]) {
        jsonNumber(out, v);
    } else {
        [out appendString:@"null"];
    }
}

#pragma mark - OVPreset

@implementation OVPreset
- (instancetype)init {
    if ((self = [super init])) {
        _identifier = @""; _name = @""; _style = @{}; _chain = @[]; _formant = 1.0; _quality = -1;
    }
    return self;
}
- (NSDictionary *)json {
    NSMutableDictionary *d = [@{@"version": @1, @"name": self.name, @"style": self.style ?: @{},
                                @"chain": self.chain ?: @[], @"formant": @(self.formant)} mutableCopy];
    if (self.formatId.length) {
        d[@"format"] = @{@"id": self.formatId, @"quality": self.quality >= 0 ? (id)@(self.quality) : (id)NSNull.null};
    }
    return d;
}
+ (nullable OVPreset *)presetFromJSON:(NSDictionary *)d identifier:(NSString *)ident {
    NSString *name = [d[@"name"] isKindOfClass:NSString.class]
        ? [d[@"name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    if (!name.length) return nil;
    OVPreset *p = [OVPreset new];
    p.identifier = ident;
    p.name = name.length > kNameMax ? [name substringToIndex:kNameMax] : name;
    if ([d[@"style"] isKindOfClass:NSDictionary.class]) p.style = d[@"style"];
    if ([d[@"chain"] isKindOfClass:NSArray.class]) {
        NSMutableArray *chain = [NSMutableArray array];
        for (id e in d[@"chain"]) if ([e isKindOfClass:NSDictionary.class]) [chain addObject:e];
        p.chain = chain;
    }
    if ([d[@"formant"] isKindOfClass:NSNumber.class]) p.formant = [d[@"formant"] doubleValue];
    NSDictionary *f = d[@"format"];
    if ([f isKindOfClass:NSDictionary.class] && [f[@"id"] isKindOfClass:NSString.class]) {
        p.formatId = f[@"id"];
        p.quality = [f[@"quality"] isKindOfClass:NSNumber.class] ? [f[@"quality"] integerValue] : -1;
    }
    return p;
}
@end

#pragma mark - OVPresets

@interface OVPresets ()
@property (copy) NSString *root;
@property NSMutableArray<OVPreset *> *items;
@end

@implementation OVPresets

+ (instancetype)shared {
    static OVPresets *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [self presetsWithRoot:[[OVPaths support] stringByAppendingPathComponent:@"presets"]]; });
    return s;
}
+ (instancetype)presetsWithRoot:(NSString *)root {
    OVPresets *p = [OVPresets new];
    p.root = root;
    [p load];
    return p;
}

- (NSString *)pathFor:(OVPreset *)p {
    return [[self.root stringByAppendingPathComponent:p.identifier] stringByAppendingPathExtension:@"json"];
}

static BOOL validIdentifier(NSString *s) {
    if (!s.length || s.length > 64) return NO;
    NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"];
    return [s rangeOfCharacterFromSet:ok.invertedSet].location == NSNotFound;
}

- (void)load {
    self.items = [NSMutableArray array];
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.root error:nil] ?: @[]) {
        if (![f.pathExtension isEqualToString:@"json"]) continue;
        NSString *ident = f.stringByDeletingPathExtension;
        if (!validIdentifier(ident)) continue;
        NSString *path = [self.root stringByAppendingPathComponent:f];
        NSDictionary *attr = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if (![attr.fileType isEqualToString:NSFileTypeRegular] || attr.fileSize > kMaxPresetBytes) continue;
        NSData *data = [NSData dataWithContentsOfFile:path];
        id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![obj isKindOfClass:NSDictionary.class]) continue;
        OVPreset *p = [OVPreset presetFromJSON:obj identifier:ident];
        if (p) [self.items addObject:p];
    }
    [self sort];
}
- (void)sort {
    [self.items sortUsingComparator:^NSComparisonResult(OVPreset *a, OVPreset *b) {
        NSComparisonResult r = [a.name localizedCaseInsensitiveCompare:b.name];
        return r != NSOrderedSame ? r : [a.identifier compare:b.identifier];
    }];
}
- (NSArray<OVPreset *> *)all { return [self.items copy]; }

- (BOOL)save:(OVPreset *)p {
    [NSFileManager.defaultManager createDirectoryAtPath:self.root withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions: @0700} error:nil];
    NSString *path = [self pathFor:p];
    if (![[self exportData:p] writeToFile:path options:NSDataWritingAtomic error:nil]) return NO;
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:path error:nil];
    return YES;
}
- (void)changed { [NSNotificationCenter.defaultCenter postNotificationName:OVPresetsDidChangeNotification object:self]; }

static NSString *cleanName(NSString *n) {
    NSString *t = [n stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return t.length > kNameMax ? [t substringToIndex:kNameMax] : t;
}

- (OVPreset *)add:(OVPreset *)src {
    NSString *name = cleanName(src.name);
    if (!name.length) return nil;
    OVPreset *p = [OVPreset new];
    p.identifier = NSUUID.UUID.UUIDString.lowercaseString;
    p.name = name; p.style = src.style; p.formatId = src.formatId; p.quality = src.quality;
    p.chain = src.chain; p.formant = src.formant;
    if (![self save:p]) return nil;
    [self.items addObject:p];
    [self sort];
    [self changed];
    return p;
}
- (BOOL)rename:(OVPreset *)p to:(NSString *)name {
    NSString *n = cleanName(name);
    if (!n.length || ![self.items containsObject:p]) return NO;
    NSString *old = p.name;
    p.name = n;
    if (![self save:p]) { p.name = old; return NO; }
    [self sort];
    [self changed];
    return YES;
}
- (void)remove:(OVPreset *)p {
    if (![self.items containsObject:p]) return;
    [NSFileManager.defaultManager removeItemAtPath:[self pathFor:p] error:nil];
    [self.items removeObject:p];
    [self changed];
}

- (NSData *)exportData:(OVPreset *)p {
    NSMutableString *s = [NSMutableString string];
    jsonValue(s, [p json], 0);
    [s appendString:@"\n"];
    return [s dataUsingEncoding:NSUTF8StringEncoding];
}

- (void)importData:(NSData *)data completion:(void (^)(OVPreset *, NSArray<NSString *> *, NSString *))completion {
    if (data.length > kMaxPresetBytes) {
        completion(nil, @[], L(@"This preset is too large (the limit is 64 KB). Choose a preset exported from Clone'n'Speak."));
        return;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) {
        completion(nil, @[], L(@"This is not a preset file. Choose a preset exported from Clone'n'Speak."));
        return;
    }
    NSDictionary *req = @{@"cmd": @"preset_validate", @"json": text};
    void (^done)(NSDictionary *, NSString *) = ^(NSDictionary *reply, NSString *error) {
        NSDictionary *pj = [reply[@"preset"] isKindOfClass:NSDictionary.class] ? reply[@"preset"] : nil;
        OVPreset *p = pj ? [OVPreset presetFromJSON:pj identifier:@""] : nil;
        if (error || !p) {
            completion(nil, @[], error ?: L(@"This is not a preset file. Choose a preset exported from Clone'n'Speak."));
            return;
        }
        completion(p, [reply[@"warnings"] isKindOfClass:NSArray.class] ? reply[@"warnings"] : @[], nil);
    };
    if (self.validator) { self.validator(req, done); return; }
    // OVWorker is looked up at run time so that this file stays Foundation-only (the tests build it alone).
    Class wc = NSClassFromString(@"OVWorker");
    SEL sharedSel = NSSelectorFromString(@"shared");
    id worker = [wc respondsToSelector:sharedSel] ? ((id (*)(id, SEL))objc_msgSend)(wc, sharedSel) : nil;
    if (!worker) { completion(nil, @[], L(@"The engine isn’t running.")); return; }
    ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(worker, NSSelectorFromString(@"request:status:progress:done:"), req, nil, nil, done);
}
@end
