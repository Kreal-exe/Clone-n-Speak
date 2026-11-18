#import "OVRvcStore.h"
#import "OVLocale.h"
#import "OVPaths.h"

NSNotificationName const OVRvcStoreDidChangeNotification = @"OVRvcStoreDidChange";
/// Same name as OVEngines.h's OVRvcModelsDidChangeNotification (the store stays free of the engine manager's dependencies).
static NSNotificationName const kModelsChanged = @"OVRvcModelsDidChangeNotification";

@interface OVRvcModel ()
@property (copy) NSString *identifier, *name, *folder, *version;
@property (copy) NSString *pthPath, *indexPath, *sha256, *sourceURL;
@property NSInteger sampleRate, epochs;
@property BOOL pitch, hasIndex;
@property long long sizeBytes;
@end
@implementation OVRvcModel
@end

@interface OVRvcStore ()
@property (copy) NSString *root;
@property (copy) NSArray<OVRvcModel *> *models;
@property NSUInteger skippedCount;
@end

@implementation OVRvcStore

+ (instancetype)shared {
    static OVRvcStore *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [OVRvcStore storeWithRoot:[OVPaths rvcModels]]; });
    return s;
}

+ (instancetype)storeWithRoot:(NSString *)root {
    OVRvcStore *s = [OVRvcStore new];
    s.root = root;
    s.models = @[];
    [NSNotificationCenter.defaultCenter addObserver:s selector:@selector(modelsChanged:) name:kModelsChanged object:nil];
    [s scan];   // silent: observers may ask for +shared while it is still being made
    return s;
}

static long long FileSize(NSString *path) {
    NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    return a ? [a[NSFileSize] longLongValue] : 0;
}

static NSInteger IntOf(id v) { return [v isKindOfClass:NSNumber.class] ? [v integerValue] : 0; }

/// One folder -> model, or nil when it is not a finished voice model.
static OVRvcModel *ReadFolder(NSString *folder) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSData *data = [NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"meta.json"]];
    id meta = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![meta isKindOfClass:NSDictionary.class]) return nil;
    NSString *pth = nil, *index = nil;
    for (NSString *f in [[fm contentsOfDirectoryAtPath:folder error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
        if ([f hasPrefix:@"."]) continue;
        NSString *ext = f.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"pth"] && !pth) pth = [folder stringByAppendingPathComponent:f];
        else if ([ext isEqualToString:@"index"] && !index) index = [folder stringByAppendingPathComponent:f];
    }
    if (!pth) return nil;
    NSDictionary *info = [meta[@"info"] isKindOfClass:NSDictionary.class] ? meta[@"info"] : @{};
    OVRvcModel *m = [OVRvcModel new];
    m.identifier = folder.lastPathComponent;
    NSString *name = [meta[@"name"] isKindOfClass:NSString.class] ? meta[@"name"] : @"";
    m.name = name.length ? name : folder.lastPathComponent;
    m.folder = folder;
    m.pthPath = pth;
    m.indexPath = index;
    m.hasIndex = index != nil;
    m.version = [info[@"version"] isKindOfClass:NSString.class] ? info[@"version"] : @"";
    m.sampleRate = IntOf(info[@"sample_rate"]);
    m.epochs = IntOf(info[@"epochs"]);
    id f0 = info[@"f0"];
    m.pitch = [f0 isKindOfClass:NSNumber.class] ? [f0 boolValue] : YES;
    m.sizeBytes = FileSize(pth) + (index ? FileSize(index) : 0);
    m.sha256 = [meta[@"sha256"] isKindOfClass:NSString.class] ? meta[@"sha256"] : nil;
    m.sourceURL = [meta[@"source_url"] isKindOfClass:NSString.class] ? meta[@"source_url"] : nil;
    return m;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

/// Someone else (a blend, an import) changed the folder: read it again. Our own posts are ignored.
- (void)modelsChanged:(NSNotification *)n { if (n.object != self) [self rescanInBackground]; }

- (void)announce { [NSNotificationCenter.defaultCenter postNotificationName:kModelsChanged object:self]; }

- (void)rescan {
    [self scan];
    [NSNotificationCenter.defaultCenter postNotificationName:OVRvcStoreDidChangeNotification object:self];
}

- (void)rescanInBackground {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *list = nil; NSUInteger skipped = 0;
        [self readInto:&list skipped:&skipped];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.models = list;
            self.skippedCount = skipped;
            [NSNotificationCenter.defaultCenter postNotificationName:OVRvcStoreDidChangeNotification object:self];
        });
    });
}

- (void)scan {
    NSArray *list = nil; NSUInteger skipped = 0;
    [self readInto:&list skipped:&skipped];
    self.models = list;
    self.skippedCount = skipped;
}

/// Pure read of the folder (any thread).
- (void)readInto:(NSArray **)out skipped:(NSUInteger *)skippedOut {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<OVRvcModel *> *list = [NSMutableArray array];
    NSUInteger skipped = 0;
    for (NSString *n in [fm contentsOfDirectoryAtPath:_root error:nil]) {
        if ([n hasPrefix:@"."]) continue;   // import staging folders
        NSString *folder = [_root stringByAppendingPathComponent:n];
        BOOL dir = NO;
        if (![fm fileExistsAtPath:folder isDirectory:&dir] || !dir) continue;
        OVRvcModel *m = ReadFolder(folder);
        if (m) [list addObject:m]; else skipped++;
    }
    [list sortUsingComparator:^NSComparisonResult(OVRvcModel *a, OVRvcModel *b) {
        NSComparisonResult r = [a.name caseInsensitiveCompare:b.name];
        return r != NSOrderedSame ? r : [a.identifier compare:b.identifier];
    }];
    // Two folders with one name (a copied folder, two imports of one name) are told apart in the list.
    NSMutableArray *used = [NSMutableArray array];
    for (OVRvcModel *m in list) {
        m.name = [OVRvcStore uniqueName:m.name amongNames:used];
        [used addObject:m.name];
    }
    *out = list;
    *skippedOut = skipped;
}

- (OVRvcModel *)modelWithIdentifier:(NSString *)identifier {
    for (OVRvcModel *m in _models) if ([m.identifier isEqualToString:identifier]) return m;
    return nil;
}

+ (NSString *)uniqueName:(NSString *)name amongNames:(NSArray<NSString *> *)used {
    NSSet *taken = [NSSet setWithArray:[used valueForKey:@"lowercaseString"]];
    if (![taken containsObject:name.lowercaseString]) return name;
    for (NSInteger n = 2; n < 1000; n++) {
        NSString *candidate = [NSString stringWithFormat:@"%@ %ld", name, (long)n];
        if (![taken containsObject:candidate.lowercaseString]) return candidate;
    }
    return [name stringByAppendingFormat:@" %u", arc4random()];
}

+ (NSString *)kHzText:(NSInteger)sr {
    if (sr <= 0) return @"";
    return sr % 1000 == 0 ? [NSString stringWithFormat:@"%ld kHz", (long)(sr / 1000)]
                          : [NSString stringWithFormat:@"%.1f kHz", sr / 1000.0];
}

static NSError *Err(NSString *text) {
    return [NSError errorWithDomain:@"OVRvcStore" code:1 userInfo:@{NSLocalizedDescriptionKey: text}];
}

/// A folder of this store, named like the model's identifier: nothing outside the root is ever touched.
- (BOOL)owns:(OVRvcModel *)m {
    NSString *real = m.folder.stringByResolvingSymlinksInPath;
    NSString *root = _root.stringByResolvingSymlinksInPath;
    return [real hasPrefix:[root stringByAppendingString:@"/"]] && [real.lastPathComponent isEqualToString:m.identifier];
}

- (NSString *)renameModel:(OVRvcModel *)model to:(NSString *)name error:(NSError **)error {
    NSString *clean = [[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                       stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (!clean.length) { if (error) *error = Err(L(@"Type a name for the voice model.")); return nil; }
    if (clean.length > 120) clean = [clean substringToIndex:120];
    if (![self owns:model]) { if (error) *error = Err(L(@"This voice model is not in the models folder.")); return nil; }
    NSString *metaPath = [model.folder stringByAppendingPathComponent:@"meta.json"];
    NSData *data = [NSData dataWithContentsOfFile:metaPath];
    id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![parsed isKindOfClass:NSDictionary.class]) {
        if (error) *error = Err(L(@"This voice model has no valid record, so it can’t be renamed."));
        return nil;
    }
    NSMutableDictionary *meta = [parsed mutableCopy];
    meta[@"name"] = clean;   // the typed name only: a de-dup suffix is added for display, never saved; everything else (id, sha256, info) stays as cns_rvc.py wrote it
    NSData *out = [NSJSONSerialization dataWithJSONObject:meta options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    NSError *werr = nil;
    if (!out || ![out writeToFile:metaPath options:NSDataWritingAtomic error:&werr]) {
        if (error) *error = werr ?: Err(L(@"Couldn’t save the new name."));
        return nil;
    }
    [self rescan];
    [self announce];
    return [self modelWithIdentifier:model.identifier].name ?: clean;
}

- (NSString *)deleteModel:(OVRvcModel *)model error:(NSError **)error {
    if (![self owns:model]) { if (error) *error = Err(L(@"This voice model is not in the models folder.")); return nil; }
    NSURL *result = nil;
    NSError *terr = nil;
    if (![NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:model.folder] resultingItemURL:&result error:&terr]) {
        if (error) *error = terr ?: Err(L(@"Couldn’t move the voice model to the Trash."));
        return nil;
    }
    [self rescan];
    [self announce];
    return result.path ?: @"";
}

@end
