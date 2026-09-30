#import "OVModels.h"
#import "OVPaths.h"
#import "OVDownloader.h"
#import "OVRuntime.h"
#import "OVLocale.h"

NSNotificationName const OVModelsDidChangeNotification = @"OVModelsDidChange";

static NSString *const kAudioTokenizerRepo = @"eustlb/higgs-audio-v2-tokenizer";
static NSString *const kBaseRepo = @"k2-fsa/OmniVoice";

@implementation OVModel
- (BOOL)installed { return self.localPath != nil; }
- (BOOL)ukrainian { return [self.languages containsObject:@"uk"]; }
@end

@interface OVModels ()
@property (readwrite) NSArray<OVModel *> *all;
@property NSMutableDictionary<NSString *, OVDownloader *> *active;
@property NSMutableSet<NSString *> *cancelled;
@property NSMutableArray *asrWaiters;
@property NSMutableSet<NSString *> *migrationTried;
@property (readwrite) BOOL catalogLoading;
@property (readwrite, nullable) NSString *catalogError;
@end

@implementation OVModels

+ (instancetype)shared {
    static OVModels *s;
    static dispatch_once_t once;
    static BOOL scanned;
    dispatch_once(&once, ^{ s = [OVModels new]; });
    // first scan outside dispatch_once: observers of the change notification call +shared again
    if (!scanned) { scanned = YES; [s rescan]; }
    return s;
}

/// Settings override → $HF_HUB_CACHE → $HF_HOME/hub → ~/.cache/huggingface/hub
+ (NSString *)hubCache {
    NSString *custom = [[NSUserDefaults.standardUserDefaults stringForKey:@"hfCacheDir"] stringByExpandingTildeInPath];
    if (custom.length) return custom;
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    if ([env[@"HF_HUB_CACHE"] length]) return [env[@"HF_HUB_CACHE"] stringByExpandingTildeInPath];
    if ([env[@"HF_HOME"] length]) return [[env[@"HF_HOME"] stringByExpandingTildeInPath] stringByAppendingPathComponent:@"hub"];
    return [NSHomeDirectory() stringByAppendingPathComponent:@".cache/huggingface/hub"];
}

static OVModel *M(NSString *repo, NSString *title, NSString *details, OVModelKind kind, double gb, BOOL rec) {
    OVModel *m = [OVModel new];
    m.repo = repo; m.title = title; m.details = details; m.kind = kind;
    m.approxBytes = (long long)(gb * 1e9); m.recommended = rec;
    m.languages = @[];
    return m;
}

- (instancetype)init {
    if ((self = [super init])) {
        _active = [NSMutableDictionary dictionary];
        _cancelled = [NSMutableSet set];
        _asrWaiters = [NSMutableArray array];
        _migrationTried = [NSMutableSet set];
        NSMutableArray *list = [@[
            M(@"mlx-community/OmniVoice-bf16", @"OmniVoice · Apple MLX",
              @"Apple Silicon build of OmniVoice in full 16-bit quality, loaded straight from the download. About 3 GB of RAM while speaking; Whisper is unloaded meanwhile. 600+ languages.",
              OVModelTTS, 1.64, YES),
            M(kBaseRepo, @"OmniVoice · original",
              @"Original k2-fsa weights, converted for Apple Silicon on first use. No download if VoiceStudio already has it.",
              OVModelTTS, 3.27, NO),
            M(@"mlx-community/whisper-large-v3-turbo-asr-fp16", @"Whisper Large v3 Turbo · MLX",
              @"Speech recognition for sample transcripts and clarity checks, in full 16-bit quality (~1.9 GB of RAM). Runs only while needed.",
              OVModelASR, 1.62, YES),
        ] mutableCopy];
        OVModel *tok = M(kAudioTokenizerRepo, @"Higgs Audio v2 tokenizer", @"", OVModelTTS, 0.8, NO);
        tok.hidden = YES;
        [list addObject:tok];
        for (NSDictionary *c in [NSArray arrayWithContentsOfFile:[self customFile]] ?: @[]) {
            OVModel *m = M(c[@"repo"], c[@"title"] ?: c[@"repo"], c[@"details"] ?: @"Added manually", [c[@"kind"] integerValue], 0, NO);
            m.custom = YES;
            m.languages = c[@"languages"] ?: @[];
            // details saved by older versions were in Russian; details are now English and translated at display time
            if ([m.details rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0x0400, 0x100)]].location != NSNotFound)
                m.details = m.languages.count ? [@"Languages: " stringByAppendingString:[m.languages componentsJoinedByString:@", "]]
                          : [m.repo hasPrefix:@"/"] ? [@"Local folder: " stringByAppendingString:[m.repo stringByAbbreviatingWithTildeInPath]]
                          : @"Added manually";
            m.approxBytes = [c[@"bytes"] longLongValue];
            [list addObject:m];
        }
        _all = list;
    }
    return self;
}

- (NSString *)customFile { return [[OVPaths support] stringByAppendingPathComponent:@"custom-models.plist"]; }

- (void)saveCustom {
    NSMutableArray *a = [NSMutableArray array];
    for (OVModel *m in self.all)
        if (m.custom) [a addObject:@{@"repo": m.repo, @"kind": @(m.kind), @"title": m.title, @"details": m.details ?: @"",
                                     @"languages": m.languages ?: @[], @"bytes": @(m.approxBytes)}];
    [a writeToFile:[self customFile] atomically:YES];
}

- (void)changed { [NSNotificationCenter.defaultCenter postNotificationName:OVModelsDidChangeNotification object:self]; }

- (NSArray<OVModel *> *)modelsOfKind:(OVModelKind)kind {
    return [self.all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(OVModel *m, id b) {
        return m.kind == kind && !m.catalog && !m.hidden;
    }]];
}

- (NSArray<OVModel *> *)catalogOfKind:(OVModelKind)kind {
    return [self.all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(OVModel *m, id b) {
        return m.kind == kind && m.catalog;
    }]];
}

- (OVModel *)modelForRepo:(NSString *)repo {
    for (OVModel *m in self.all) if ([m.repo caseInsensitiveCompare:repo ?: @""] == NSOrderedSame) return m;
    return nil;
}

#pragma mark - Selection

- (OVModel *)selectedOfKind:(OVModelKind)kind key:(NSString *)key {
    OVModel *m = [self modelForRepo:[NSUserDefaults.standardUserDefaults stringForKey:key] ?: @""];
    if (m.installed && m.kind == kind) return m;
    for (OVModel *x in [self modelsOfKind:kind]) if (x.installed) return x;
    return nil;
}
- (OVModel *)ttsModel { return [self selectedOfKind:OVModelTTS key:@"ttsModel"]; }
- (OVModel *)asrModel { return [self selectedOfKind:OVModelASR key:@"asrModel"]; }
- (OVModel *)loraSelection {
    OVModel *m = [self modelForRepo:[NSUserDefaults.standardUserDefaults stringForKey:@"loraModel"] ?: @""];
    return m.kind == OVModelLoRA ? m : nil;
}
- (OVModel *)loraModel { OVModel *m = self.loraSelection; return m.installed ? m : nil; }

- (void)select:(OVModel *)m {
    if (m.kind == OVModelLoRA) { [self selectLoRA:m]; return; }
    [NSUserDefaults.standardUserDefaults setObject:m.repo forKey:m.kind == OVModelTTS ? @"ttsModel" : @"asrModel"];
    [self changed];
}

- (void)selectLoRA:(OVModel *)m {
    if (m) {
        if (m.catalog) [self adopt:m];
        [NSUserDefaults.standardUserDefaults setObject:m.repo forKey:@"loraModel"];
        if (!m.installed && !m.downloading) [self download:m]; // auto-fetch the adapter
    } else {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"loraModel"];
    }
    [self changed];
}

#pragma mark - Detection (HF cache layout)

- (NSString *)repoDir:(NSString *)repo {
    return [[OVModels hubCache] stringByAppendingPathComponent:
            [@"models--" stringByAppendingString:[repo stringByReplacingOccurrencesOfString:@"/" withString:@"--"]]];
}

- (NSString *)legacyDir:(NSString *)repo {
    return [[OVPaths models] stringByAppendingPathComponent:[repo stringByReplacingOccurrencesOfString:@"/" withString:@"__"]];
}

- (BOOL)folderLooksComplete:(NSString *)dir kind:(OVModelKind)kind {
    NSFileManager *fm = NSFileManager.defaultManager;
    // fileExistsAtPath follows symlinks: dangling HF-cache links count as missing
    if (kind == OVModelLoRA)
        return [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"adapter_config.json"]] &&
               [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"adapter_model.safetensors"]];
    if (![fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"config.json"]]) return NO;
    BOOL weights = NO;
    for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil])
        if (([f hasSuffix:@".safetensors"] || [f isEqualToString:@"pytorch_model.bin"]) &&
            [fm fileExistsAtPath:[dir stringByAppendingPathComponent:f]]) weights = YES;
    if (!weights) return NO;
    if (kind == OVModelTTS && ![dir containsString:@"higgs-audio"]) {
        if (![fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"tokenizer.json"]]) return NO;
        NSString *at = [dir stringByAppendingPathComponent:@"audio_tokenizer"];
        if ([fm fileExistsAtPath:at]) return [fm fileExistsAtPath:[at stringByAppendingPathComponent:@"model.safetensors"]];
        // no bundled audio tokenizer: OmniVoice falls back to eustlb/higgs-audio-v2-tokenizer
        return [self modelForRepo:kAudioTokenizerRepo].installed;
    }
    return YES;
}

- (NSString *)snapshotFor:(OVModel *)m {
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([m.repo hasPrefix:@"/"]) // local folder (e.g. a LoRA trained by the user)
        return [self folderLooksComplete:m.repo kind:m.kind] ? m.repo : nil;
    NSString *root = [self repoDir:m.repo];
    NSString *snaps = [root stringByAppendingPathComponent:@"snapshots"];
    NSString *ref = [[NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"refs/main"]
                                               encoding:NSUTF8StringEncoding error:nil]
                     stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray *order = [NSMutableArray array];
    if (ref.length) [order addObject:ref];
    [order addObjectsFromArray:[fm contentsOfDirectoryAtPath:snaps error:nil] ?: @[]];
    for (NSString *snap in order) {
        NSString *dir = [snaps stringByAppendingPathComponent:snap];
        if ([self folderLooksComplete:dir kind:m.kind]) return dir;
    }
    return nil;
}

- (void)rescan {
    // the audio tokenizer first: other TTS folders depend on it
    NSArray *ordered = [self.all sortedArrayUsingComparator:^NSComparisonResult(OVModel *a, OVModel *b) {
        return [@(!a.hidden) compare:@(!b.hidden)];
    }];
    for (OVModel *m in ordered) {
        if (m.downloading) continue;
        m.localPath = [self snapshotFor:m];
    }
    // models downloaded by earlier versions into our own folder → move into the HF cache (no re-download)
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL migrate = ![NSUserDefaults.standardUserDefaults boolForKey:@"disableLegacyMigration"];
    for (OVModel *m in self.all)
        if (migrate && m.installed && ![m.repo hasPrefix:@"/"] && [fm fileExistsAtPath:[self legacyDir:m.repo]])
            [fm removeItemAtPath:[self legacyDir:m.repo] error:nil]; // already in the cache: the old copy is redundant
    if (migrate) for (OVModel *m in self.all)
        if (!m.installed && !m.downloading && ![self.migrationTried containsObject:m.repo] &&
            [NSFileManager.defaultManager fileExistsAtPath:[self legacyDir:m.repo]]) {
            [self.migrationTried addObject:m.repo];
            [self download:m];
        }
    [self changed];
}

#pragma mark - Download into the HF cache

- (NSString *)endpoint {
    NSString *e = [[NSUserDefaults.standardUserDefaults stringForKey:@"hfEndpoint"]
                   stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!e.length) e = @"https://huggingface.co";
    while ([e hasSuffix:@"/"]) e = [e substringToIndex:e.length - 1];
    return e;
}

- (NSDictionary *)headers {
    NSString *tok = [[NSUserDefaults.standardUserDefaults stringForKey:@"hfToken"]
                     stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return tok.length ? @{@"Authorization": [@"Bearer " stringByAppendingString:tok]} : @{};
}

static NSString *PercentPath(NSString *p) {
    return [p stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
}

/// Keep weights + configs; skip training state, docs and other frameworks' duplicates.
- (NSArray<NSDictionary *> *)filterFiles:(NSArray *)tree kind:(OVModelKind)kind {
    NSMutableSet *names = [NSMutableSet set];
    for (NSDictionary *f in tree) if ([f[@"type"] isEqualToString:@"file"]) [names addObject:f[@"path"]];
    BOOL hasSafetensors = NO;
    for (NSString *p in names) if ([p hasSuffix:@".safetensors"]) hasSafetensors = YES;
    BOOL adapter = [names containsObject:@"adapter_model.safetensors"];
    NSMutableArray *files = [NSMutableArray array];
    for (NSDictionary *f in tree) {
        if (![f[@"type"] isEqualToString:@"file"]) continue;
        NSString *p = f[@"path"], *lower = [f[@"path"] lowercaseString], *ext = lower.pathExtension, *name = lower.lastPathComponent;
        if ([@[@"md", @"msgpack", @"h5", @"onnx", @"ot", @"tflite", @"gguf", @"mlmodel", @"png", @"jpg", @"jpeg", @"gif", @"wav", @"mp3", @"ogg", @"flac", @"m4a",
               @"pkl", @"gitattributes", @"bak", @"orig_bak", @"txt"] containsObject:ext] && ![name isEqualToString:@"merges.txt"]) continue;
        if ([name isEqualToString:@"optimizer.bin"] || [name isEqualToString:@"scheduler.bin"] || [name hasPrefix:@"random_states"]) continue;
        if ([lower hasPrefix:@"onnx/"] || [lower hasPrefix:@"coreml/"] || [lower hasPrefix:@".git"] || [lower hasPrefix:@"samples/"]) continue;
        if ([lower containsString:@"checkpoint-"] || [lower hasPrefix:@"runs/"]) continue;
        if (hasSafetensors && ([ext isEqualToString:@"bin"] || [ext isEqualToString:@"pt"] || [ext isEqualToString:@"pth"] || [ext isEqualToString:@"ckpt"])) continue;
        // an adapter repo may also carry a full merged model: only the adapter is needed
        if (kind == OVModelLoRA && adapter && [p isEqualToString:@"model.safetensors"]) continue;
        [files addObject:f];
    }
    return files;
}

- (void)download:(OVModel *)m {
    if (m.downloading || [m.repo hasPrefix:@"/"]) return;
    if (m.catalog) [self adopt:m];
    m.downloading = YES;
    m.error = nil;
    m.progress = 0;
    m.received = 0;
    m.total = m.approxBytes;
    m.downloadStatus = L(@"Getting the file list…");
    [self.cancelled removeObject:m.repo];
    [self changed];
    [[OVRuntime shared] log:[NSString stringWithFormat:L(@"Downloading %@ to the Hugging Face cache: %@"), m.repo, [OVModels hubCache]]];

    NSString *rev = [NSString stringWithFormat:@"%@/api/models/%@/revision/main", [self endpoint], m.repo];
    OVFetchJSON([NSURL URLWithString:rev], [self headers], ^(id info, NSError *err) {
        NSString *sha = [info isKindOfClass:NSDictionary.class] ? info[@"sha"] : nil;
        if (err || !sha.length) { [self finish:m error:err.localizedDescription ?: L(@"Couldn’t get model information")]; return; }
        NSString *api = [NSString stringWithFormat:@"%@/api/models/%@/tree/%@?recursive=true", [self endpoint], m.repo, sha];
        OVFetchJSON([NSURL URLWithString:api], [self headers], ^(id json, NSError *err2) {
            if (err2 || ![json isKindOfClass:NSArray.class]) {
                [self finish:m error:err2.localizedDescription ?: L(@"Couldn’t get the file list")];
                return;
            }
            NSArray *files = [self filterFiles:json kind:m.kind];
            if (m.kind == OVModelLoRA && ![[files valueForKey:@"path"] containsObject:@"adapter_model.safetensors"]) {
                [self finish:m error:L(@"The repository has no adapter_model.safetensors — it isn’t a LoRA adapter")];
                return;
            }
            long long total = 0;
            for (NSDictionary *f in files) total += [f[@"size"] longLongValue];
            if (!files.count || total == 0) { [self finish:m error:L(@"The repository has no model files")]; return; }
            m.total = total;
            m.approxBytes = total;
            [self downloadFiles:files index:0 done:0 sha:sha model:m];
        });
    });
}

- (void)downloadFiles:(NSArray *)files index:(NSUInteger)i done:(long long)done sha:(NSString *)sha model:(OVModel *)m {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = [self repoDir:m.repo];
    if ([self.cancelled containsObject:m.repo]) { [self finish:m error:nil]; return; }
    if (i >= files.count) {
        [fm createDirectoryAtPath:[root stringByAppendingPathComponent:@"refs"] withIntermediateDirectories:YES attributes:nil error:nil];
        [sha writeToFile:[root stringByAppendingPathComponent:@"refs/main"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [fm removeItemAtPath:[self legacyDir:m.repo] error:nil];
        [self afterDownload:m files:files];
        return;
    }
    NSDictionary *f = files[i];
    NSString *path = f[@"path"];
    long long size = [f[@"size"] longLongValue];
    NSString *etag = [f[@"lfs"] isKindOfClass:NSDictionary.class] ? f[@"lfs"][@"oid"] : f[@"oid"];
    NSString *blobs = [root stringByAppendingPathComponent:@"blobs"];
    NSString *blob = [blobs stringByAppendingPathComponent:etag];
    NSString *link = [[[root stringByAppendingPathComponent:@"snapshots"] stringByAppendingPathComponent:sha] stringByAppendingPathComponent:path];
    [fm createDirectoryAtPath:blobs withIntermediateDirectories:YES attributes:nil error:nil];

    void (^linkAndNext)(void) = ^{
        // snapshots/<sha>/<path> → ../../blobs/<etag>  (one more ../ per sub-folder)
        [fm createDirectoryAtPath:link.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableString *rel = [NSMutableString stringWithString:@"../../"];
        for (NSUInteger d = 1; d < path.pathComponents.count; d++) [rel appendString:@"../"];
        [rel appendFormat:@"blobs/%@", etag];
        [fm removeItemAtPath:link error:nil];
        [fm createSymbolicLinkAtPath:link withDestinationPath:rel error:nil];
        [self downloadFiles:files index:i + 1 done:done + size sha:sha model:m];
    };

    if ([[fm attributesOfItemAtPath:blob error:nil] fileSize] == (unsigned long long)size && [fm fileExistsAtPath:blob]) {
        linkAndNext();
        return;
    }
    // same file from our old models folder: move it instead of downloading again
    NSString *legacy = [[self legacyDir:m.repo] stringByAppendingPathComponent:path];
    if ([[fm attributesOfItemAtPath:legacy error:nil] fileSize] == (unsigned long long)size && size > 0) {
        [fm removeItemAtPath:blob error:nil];
        if ([fm moveItemAtPath:legacy toPath:blob error:nil]) {
            m.received = done + size;
            m.progress = m.total > 0 ? (double)m.received / m.total : 0;
            m.downloadStatus = [NSString stringWithFormat:L(@"Moving to cache: %@"), path.lastPathComponent];
            [self changed];
            linkAndNext();
            return;
        }
    }
    m.downloadStatus = [NSString stringWithFormat:L(@"File %lu of %lu · %@"), (unsigned long)i + 1, (unsigned long)files.count, path.lastPathComponent];
    [self changed];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@/resolve/%@/%@", [self endpoint], m.repo, sha, PercentPath(path)]];
    __block CFAbsoluteTime lastUI = 0;
    self.active[m.repo] = [OVDownloader download:url to:blob part:[blob stringByAppendingString:@".incomplete"]
                                         headers:[self headers] progress:^(long long r, long long t) {
        m.received = done + r;
        m.progress = m.total > 0 ? (double)m.received / m.total : 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - lastUI > 0.25) { lastUI = now; [self changed]; }
    } completion:^(NSError *err) {
        [self.active removeObjectForKey:m.repo];
        if ([self.cancelled containsObject:m.repo]) { [self finish:m error:nil]; return; }
        if (err) { [self finish:m error:err.localizedDescription]; return; }
        linkAndNext();
    }];
}

/// A TTS finetune without its own audio tokenizer needs the shared one as well.
- (void)afterDownload:(OVModel *)m files:(NSArray *)files {
    OVModel *tok = [self modelForRepo:kAudioTokenizerRepo];
    BOOL needsTokenizer = m.kind == OVModelTTS && !m.hidden && !tok.installed &&
        ![[files valueForKey:@"path"] containsObject:@"audio_tokenizer/model.safetensors"];
    [self finish:m error:nil];
    if (needsTokenizer) [self download:tok];
}

- (void)finish:(OVModel *)m error:(NSString *)error {
    BOOL wasCancelled = [self.cancelled containsObject:m.repo];
    m.downloading = NO;
    m.downloadStatus = nil;
    m.error = wasCancelled ? nil : error;
    [[OVRuntime shared] log:error ? [NSString stringWithFormat:L(@"Download of %@ failed: %@"), m.repo, error]
                           : wasCancelled ? [NSString stringWithFormat:L(@"Download stopped: %@"), m.repo]
                                          : [NSString stringWithFormat:L(@"✔ Model is in the Hugging Face cache: %@"), m.repo]];
    [self rescan];
    if (m.kind == OVModelASR) [self flushASRWaiters:error ?: (wasCancelled ? L(@"Whisper download stopped") : nil)];
}

- (void)cancelDownload:(OVModel *)m {
    [self.cancelled addObject:m.repo];
    [self.active[m.repo] cancel];
}

- (BOOL)remove:(OVModel *)m error:(NSError **)error {
    if ([m.repo hasPrefix:@"/"]) return NO;
    BOOL ok = [NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:[self repoDir:m.repo]] resultingItemURL:nil error:error];
    [self rescan];
    return ok;
}

#pragma mark - Custom & catalog

- (void)adopt:(OVModel *)m {
    if (!m.catalog) return;
    m.catalog = NO;
    m.custom = YES;
    [self saveCustom];
}

- (OVModel *)addCustomRepo:(NSString *)repo kind:(OVModelKind)kind {
    repo = [repo stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([repo hasPrefix:@"~"] || [repo hasPrefix:@"/"]) { // local folder, e.g. an adapter trained on a rented GPU
        repo = repo.stringByExpandingTildeInPath.stringByStandardizingPath;
        BOOL dir = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:repo isDirectory:&dir] || !dir) return nil;
        if ([NSFileManager.defaultManager fileExistsAtPath:[repo stringByAppendingPathComponent:@"adapter_config.json"]]) kind = OVModelLoRA;
    } else {
        for (NSString *prefix in @[@"https://huggingface.co/", @"http://huggingface.co/", @"huggingface.co/"])
            if ([repo hasPrefix:prefix]) repo = [repo substringFromIndex:prefix.length];
        NSArray *parts = [repo componentsSeparatedByString:@"/"];
        if (parts.count < 2 || ![parts[0] length] || ![parts[1] length]) return nil;
        repo = [NSString stringWithFormat:@"%@/%@", parts[0], parts[1]];
    }
    OVModel *existing = [self modelForRepo:repo];
    if (existing) { [self adopt:existing]; return existing; }
    OVModel *m = M(repo, [repo hasPrefix:@"/"] ? repo.lastPathComponent : repo,
                   [repo hasPrefix:@"/"] ? [@"Local folder: " stringByAppendingString:[repo stringByAbbreviatingWithTildeInPath]] : @"Added manually",
                   kind, 0, NO);
    m.custom = YES;
    self.all = [self.all arrayByAddingObject:m];
    [self saveCustom];
    [self rescan];
    return m;
}

- (void)removeCustom:(OVModel *)m {
    if (!m.custom || m.downloading) return;
    if (self.loraSelection == m) [NSUserDefaults.standardUserDefaults removeObjectForKey:@"loraModel"];
    NSMutableArray *a = [self.all mutableCopy];
    [a removeObject:m];
    self.all = a;
    [self saveCustom];
    [self changed];
}

/// Discovers OmniVoice adapters and finetunes on Hugging Face (tags base_model:adapter/finetune).
- (void)refreshCatalog {
    if (self.catalogLoading) return;
    self.catalogLoading = YES;
    self.catalogError = nil;
    [self changed];
    NSMutableArray *found = [NSMutableArray array];
    __block int pending = 2;
    for (NSString *rel in @[@"adapter", @"finetune"]) {
        NSString *url = [NSString stringWithFormat:@"%@/api/models?filter=base_model:%@:%@&full=true&sort=downloads&limit=200",
                         [self endpoint], rel, kBaseRepo];
        OVFetchJSON([NSURL URLWithString:url], [self headers], ^(id json, NSError *err) {
            if (err) self.catalogError = err.localizedDescription;
            if ([json isKindOfClass:NSArray.class]) [found addObjectsFromArray:json];
            if (--pending == 0) [self applyCatalog:found];
        });
    }
}

- (void)applyCatalog:(NSArray *)items {
    NSMutableArray *list = [[self.all filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"catalog == NO"]] mutableCopy];
    NSMutableSet *seen = [NSMutableSet setWithArray:[list valueForKey:@"repo"]];
    for (NSDictionary *it in items) {
        NSString *repo = it[@"id"];
        if (!repo.length || [seen containsObject:repo]) continue;
        NSString *lower = repo.lowercaseString;
        if ([lower containsString:@"mlx"] || [lower containsString:@"onnx"] || [lower containsString:@"gguf"] ||
            [lower containsString:@"tiny-random"] || [lower containsString:@"coreml"]) continue;
        NSSet *files = [NSSet setWithArray:[it[@"siblings"] valueForKey:@"rfilename"] ?: @[]];
        OVModelKind kind;
        if ([files containsObject:@"adapter_model.safetensors"] && [files containsObject:@"adapter_config.json"]) kind = OVModelLoRA;
        else if ([files containsObject:@"config.json"] && [files containsObject:@"model.safetensors"] && [files containsObject:@"tokenizer.json"]) kind = OVModelTTS;
        else continue;
        NSMutableArray *langs = [NSMutableArray array];
        for (NSString *t in it[@"tags"] ?: @[])
            if (t.length == 2 && [t rangeOfCharacterFromSet:NSCharacterSet.uppercaseLetterCharacterSet].location == NSNotFound) [langs addObject:t];
        if (langs.count > 30) [langs setArray:@[@"uk", @"multi"]]; // copies of the multilingual base keep all 600+ tags
        NSString *details = langs.count ? [@"Languages: " stringByAppendingString:[langs componentsJoinedByString:@", "]] : @"Language not specified";
        id gated = it[@"gated"];
        if (gated && ![gated isEqual:@NO]) details = [details stringByAppendingString:@" · Gated on Hugging Face, token required"];
        OVModel *m = M(repo, repo, details, kind, 0, NO);
        m.catalog = YES;
        m.languages = langs;
        m.downloads = [it[@"downloads"] integerValue];
        [seen addObject:repo];
        [list addObject:m];
    }
    self.all = list;
    self.catalogLoading = NO;
    [self rescan];
}

#pragma mark - Whisper on demand

- (void)whenASRReady:(void (^)(OVModel *, NSString *))ready {
    if (self.asrModel) { ready(self.asrModel, nil); return; }
    [self.asrWaiters addObject:[ready copy]];
    for (OVModel *m in [self modelsOfKind:OVModelASR]) if (m.downloading) return;
    for (OVModel *m in [self modelsOfKind:OVModelASR]) if (m.recommended) { [self download:m]; return; }
}

- (void)flushASRWaiters:(NSString *)error {
    if (!self.asrModel && !error) return;
    NSArray *w = self.asrWaiters.copy;
    [self.asrWaiters removeAllObjects];
    for (void (^b)(OVModel *, NSString *) in w) b(self.asrModel, self.asrModel ? nil : (error ?: L(@"Whisper isn’t downloaded")));
}
@end
