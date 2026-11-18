#import "OVJobStore.h"
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <limits.h>
#include <sys/stat.h>

static const unsigned long long kLogCap = 2 * 1024 * 1024;       // the file is cut when it grows beyond this…
static const unsigned long long kLogKeep = 1024 * 1024;          // …to this much of its tail
static const NSUInteger kMaxLineBytes = 16 * 1024;
static const NSUInteger kLogShown = 256 * 1024;
static const NSUInteger kKeepFinished = 200;
static const NSTimeInterval kKeepSeconds = 30 * 24 * 3600;

NSString *OVJobStateName(OVJobState s) {
    switch (s) {
        case OVJobQueued: return @"queued";
        case OVJobRunning: return @"running";
        case OVJobSucceeded: return @"succeeded";
        case OVJobFailed: return @"failed";
        case OVJobStopped: return @"stopped";
        case OVJobInterrupted: return @"interrupted";
    }
    return @"failed";
}

static BOOL OVJobStateFromName(NSString *n, OVJobState *out) {
    for (OVJobState s = OVJobQueued; s <= OVJobInterrupted; s++)
        if ([OVJobStateName(s) isEqualToString:n]) { *out = s; return YES; }
    return NO;
}

#pragma mark - OVJob

@implementation OVJob
- (BOOL)active { return self.state == OVJobQueued || self.state == OVJobRunning; }
- (NSDictionary *)runnerRequest { return self.rawRequest ?: self.request; }
- (NSString *)logPath { return [self.folder stringByAppendingPathComponent:@"log.txt"]; }
- (NSString *)workDirectory { return [self.folder stringByAppendingPathComponent:@"work"]; }

- (NSString *)logText {
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:self.logPath];
    if (!h) return @"";
    unsigned long long size = [h seekToEndOfFile];
    unsigned long long from = size > kLogShown ? size - kLogShown : 0;
    [h seekToFileOffset:from];
    NSData *d = [h readDataToEndOfFile];
    [h closeFile];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(MIN(4, d.length), d.length - MIN(4, d.length))]
                                      encoding:NSUTF8StringEncoding] ?: @"";
    return s;
}

- (NSDictionary *)dictionary {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"id"] = self.identifier ?: @"";
    d[@"kind"] = self.kind ?: @"";
    d[@"title"] = self.title ?: @"";
    d[@"origin"] = self.origin ?: @"app";
    d[@"state"] = OVJobStateName(self.state);
    d[@"lane"] = @(self.lane);
    d[@"created"] = @(self.created.timeIntervalSince1970);
    if (self.started) d[@"started"] = @(self.started.timeIntervalSince1970);
    if (self.finished) d[@"finished"] = @(self.finished.timeIntervalSince1970);
    d[@"progress"] = @(self.progress);
    d[@"status"] = self.status ?: @"";
    if (self.error) d[@"error"] = self.error;
    if (self.errorCode) d[@"errorCode"] = self.errorCode;
    d[@"request"] = [OVJobStore jsonSafe:[OVJobStore redact:self.request ?: @{}]];
    if (self.result) d[@"result"] = [OVJobStore jsonSafe:[OVJobStore redact:self.result]];
    d[@"outputs"] = self.outputs ?: @[];
    if (self.retryOf) d[@"retryOf"] = self.retryOf;
    return d;
}

+ (OVJob *)jobFromDictionary:(NSDictionary *)d folder:(NSString *)folder {
    if (![d isKindOfClass:NSDictionary.class]) return nil;
    NSString *ident = d[@"id"], *kind = d[@"kind"];
    OVJobState st;
    if (![ident isKindOfClass:NSString.class] || ![OVJobStore isValidIdentifier:ident]) return nil;
    if (![kind isKindOfClass:NSString.class] || !kind.length) return nil;
    if (![d[@"state"] isKindOfClass:NSString.class] || !OVJobStateFromName(d[@"state"], &st)) return nil;
    if (![d[@"created"] isKindOfClass:NSNumber.class]) return nil;
    OVJob *j = [OVJob new];
    j.identifier = ident;
    j.kind = kind;
    j.title = [d[@"title"] isKindOfClass:NSString.class] ? d[@"title"] : kind;
    j.origin = [d[@"origin"] isKindOfClass:NSString.class] ? d[@"origin"] : @"app";
    j.state = st;
    j.lane = [d[@"lane"] integerValue] == OVJobLaneNetwork ? OVJobLaneNetwork : OVJobLaneCompute;
    j.created = [NSDate dateWithTimeIntervalSince1970:[d[@"created"] doubleValue]];
    if ([d[@"started"] isKindOfClass:NSNumber.class]) j.started = [NSDate dateWithTimeIntervalSince1970:[d[@"started"] doubleValue]];
    if ([d[@"finished"] isKindOfClass:NSNumber.class]) j.finished = [NSDate dateWithTimeIntervalSince1970:[d[@"finished"] doubleValue]];
    j.progress = [d[@"progress"] isKindOfClass:NSNumber.class] ? [d[@"progress"] doubleValue] : -1;
    j.status = [d[@"status"] isKindOfClass:NSString.class] ? d[@"status"] : @"";
    j.error = [d[@"error"] isKindOfClass:NSString.class] ? d[@"error"] : nil;
    j.errorCode = [d[@"errorCode"] isKindOfClass:NSString.class] ? d[@"errorCode"] : nil;
    j.request = [d[@"request"] isKindOfClass:NSDictionary.class] ? d[@"request"] : @{};
    j.result = [d[@"result"] isKindOfClass:NSDictionary.class] ? d[@"result"] : nil;
    NSMutableArray *outs = [NSMutableArray array];
    if ([d[@"outputs"] isKindOfClass:NSArray.class])
        for (id o in d[@"outputs"]) if ([o isKindOfClass:NSString.class]) [outs addObject:o];
    j.outputs = outs;
    j.retryOf = [d[@"retryOf"] isKindOfClass:NSString.class] ? d[@"retryOf"] : nil;
    j.folder = folder;
    return j;
}
@end

#pragma mark - OVJobStore

static NSArray<NSString *> *gRoots;

@interface OVJobStore ()
@property (readwrite) NSUInteger writeCount;
@end

@implementation OVJobStore {
    NSMutableDictionary<NSString *, NSDate *> *_lastWrite;
    NSMutableDictionary<NSString *, OVJob *> *_pending;
    NSMutableDictionary<NSString *, NSFileHandle *> *_logs;
    NSMutableDictionary<NSString *, NSNumber *> *_logSizes;
    NSMutableDictionary<NSString *, NSNumber *> *_requestWritten;
}

+ (NSArray<NSString *> *)appDataRoots { @synchronized (self) { return gRoots ?: @[NSTemporaryDirectory()]; } }
+ (void)setAppDataRoots:(NSArray<NSString *> *)roots { @synchronized (self) { gRoots = [roots copy]; } }

- (instancetype)initWithRoot:(NSString *)root {
    if ((self = [super init])) {
        _interruptedMessage = @"The app closed while this task was running. Start it again.";
        _root = [root copy];
        _lastWrite = [NSMutableDictionary dictionary];
        _pending = [NSMutableDictionary dictionary];
        _logs = [NSMutableDictionary dictionary];
        _logSizes = [NSMutableDictionary dictionary];
        _requestWritten = [NSMutableDictionary dictionary];
        [self makeDirectory:root];
    }
    return self;
}

- (void)makeDirectory:(NSString *)path {
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions: @0700} error:nil];
}

+ (BOOL)isValidIdentifier:(NSString *)s {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ re = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$" options:0 error:nil]; });
    return s.length == 22 && [re numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)] == 1;
}

+ (NSString *)newIdentifier {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyyMMdd-HHmmss";
    return [NSString stringWithFormat:@"%@-%06x", [f stringFromDate:NSDate.date], arc4random_uniform(0x1000000)];
}

#pragma mark Writing

/// Temp file with the right mode, then rename: a crash leaves either the old file or the new one.
- (BOOL)writeData:(NSData *)data toPath:(NSString *)path {
    NSString *tmp = [path stringByAppendingFormat:@".tmp%u", arc4random()];
    int fd = open(tmp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) return NO;
    const uint8_t *p = data.bytes;
    size_t left = data.length;
    BOOL ok = YES;
    while (left > 0) {
        ssize_t n = write(fd, p, left);
        if (n <= 0) { ok = NO; break; }
        p += n; left -= (size_t)n;
    }
    close(fd);
    if (!ok || rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
        unlink(tmp.fileSystemRepresentation);
        return NO;
    }
    return YES;
}

- (void)writeJob:(OVJob *)job {   // call inside @synchronized(self)
    if (![OVJobStore isValidIdentifier:job.identifier]) return;
    [self makeDirectory:job.folder];
    NSMutableDictionary *rec = [job.dictionary mutableCopy];
    NSDictionary *request = rec[@"request"];
    [rec removeObjectForKey:@"request"];   // written once, in its own file: progress saves stay small
    NSData *data = [NSJSONSerialization dataWithJSONObject:rec options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    if (!data) return;
    if (!_requestWritten[job.identifier]) {
        NSData *rd = [NSJSONSerialization dataWithJSONObject:request ?: @{} options:NSJSONWritingSortedKeys error:nil];
        if (rd && [self writeData:rd toPath:[job.folder stringByAppendingPathComponent:@"request.json"]]) _requestWritten[job.identifier] = @YES;
    }
    [self writeData:data toPath:[job.folder stringByAppendingPathComponent:@"job.json"]];
    _lastWrite[job.identifier] = NSDate.date;
    [_pending removeObjectForKey:job.identifier];
    self.writeCount++;
}

- (void)save:(OVJob *)job {
    @synchronized (self) { [self writeJob:job]; }
}

- (void)saveThrottled:(OVJob *)job {
    NSString *ident = job.identifier;
    NSTimeInterval wait = 0;
    @synchronized (self) {
        NSDate *last = _lastWrite[ident];
        NSTimeInterval since = last ? -[last timeIntervalSinceNow] : 1e9;
        if (since >= 1.0) { [self writeJob:job]; return; }
        if (_pending[ident]) return;
        _pending[ident] = job;
        wait = 1.0 - since;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @synchronized (self) {
            if (_pending[ident] == job) [self writeJob:job];   // a save, a remove or a newer pending write cancels this one
        }
    });
}

#pragma mark Log

- (void)appendLog:(NSString *)line toJob:(OVJob *)job {
    if (!line.length || ![OVJobStore isValidIdentifier:job.identifier]) return;
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
    if (d.length > kMaxLineBytes) d = [d subdataWithRange:NSMakeRange(0, kMaxLineBytes)];
    NSMutableData *out = [d mutableCopy];
    if (![line hasSuffix:@"\n"]) [out appendBytes:"\n" length:1];
    NSString *ident = job.identifier;
    @synchronized (self) {
        NSFileHandle *h = _logs[ident];
        if (!h) {
            [self makeDirectory:job.folder];
            int fd = open(job.logPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0600);
            if (fd < 0) return;
            h = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
            _logs[ident] = h;
            struct stat st;
            _logSizes[ident] = @(fstat(fd, &st) == 0 ? (unsigned long long)st.st_size : 0ULL);
        }
        @try { [h writeData:out]; } @catch (NSException *e) { return; }
        unsigned long long size = _logSizes[ident].unsignedLongLongValue + out.length;
        _logSizes[ident] = @(size);
        if (size > kLogCap) [self truncateLogOfJob:job];
    }
}

/// Keeps the tail, starting at a line boundary.
- (void)truncateLogOfJob:(OVJob *)job {
    NSString *ident = job.identifier;
    [_logs removeObjectForKey:ident];   // closes the descriptor
    NSFileHandle *r = [NSFileHandle fileHandleForReadingAtPath:job.logPath];
    unsigned long long size = [r seekToEndOfFile];
    unsigned long long from = size > kLogKeep ? size - kLogKeep : 0;
    [r seekToFileOffset:from];
    NSData *tail = [r readDataToEndOfFile];
    [r closeFile];
    NSRange nl = [tail rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, tail.length)];
    if (from > 0 && nl.location != NSNotFound) tail = [tail subdataWithRange:NSMakeRange(nl.location + 1, tail.length - nl.location - 1)];
    NSMutableData *out = [[@"[the beginning of the log was cut]\n" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [out appendData:tail];
    [self writeData:out toPath:job.logPath];
    [_logSizes removeObjectForKey:ident];
}

- (void)closeLogOfJob:(OVJob *)job {
    @synchronized (self) {
        [_logs removeObjectForKey:job.identifier];
        [_logSizes removeObjectForKey:job.identifier];
    }
}

#pragma mark Loading and cleaning

- (NSArray<OVJob *> *)loadAll {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<OVJob *> *jobs = [NSMutableArray array];
    for (NSString *name in [fm contentsOfDirectoryAtPath:self.root error:nil]) {
        if (![OVJobStore isValidIdentifier:name]) continue;
        NSString *folder = [self.root stringByAppendingPathComponent:name];
        NSData *data = [NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"job.json"]];
        if (!data) continue;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSData *rd = [NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"request.json"]];
        id req = rd ? [NSJSONSerialization JSONObjectWithData:rd options:0 error:nil] : nil;
        if ([obj isKindOfClass:NSDictionary.class] && [req isKindOfClass:NSDictionary.class]) {
            NSMutableDictionary *m = [obj mutableCopy];
            m[@"request"] = req;
            obj = m;
        }
        OVJob *j = [OVJob jobFromDictionary:obj folder:folder];
        if (!j || ![j.identifier isEqualToString:name]) continue;   // corrupt, or a record copied under another name
        if (j.active) {
            j.state = OVJobInterrupted;
            j.finished = NSDate.date;
            j.error = self.interruptedMessage;
            [self removeWorkOfJob:j];
            [self save:j];
        }
        [jobs addObject:j];
    }
    [jobs sortUsingComparator:^NSComparisonResult(OVJob *a, OVJob *b) {
        NSComparisonResult c = [b.created compare:a.created];
        return c != NSOrderedSame ? c : [b.identifier compare:a.identifier];
    }];
    return jobs;
}

- (void)removeWorkOfJob:(OVJob *)job {
    if (![OVJobStore isValidIdentifier:job.identifier]) return;
    [NSFileManager.defaultManager removeItemAtPath:job.workDirectory error:nil];
}

- (void)removeFolderOfJob:(OVJob *)job {
    if (![OVJobStore isValidIdentifier:job.identifier]) return;
    if (![job.folder isEqualToString:[self.root stringByAppendingPathComponent:job.identifier]]) return;
    @synchronized (self) {
        [_pending removeObjectForKey:job.identifier];
        [_lastWrite removeObjectForKey:job.identifier];
        [_logs removeObjectForKey:job.identifier];
        [_logSizes removeObjectForKey:job.identifier];
        [_requestWritten removeObjectForKey:job.identifier];
    }
    [NSFileManager.defaultManager removeItemAtPath:job.folder error:nil];
}

- (NSArray<OVJob *> *)pruneJobs:(NSArray<OVJob *> *)jobs {
    NSMutableArray<OVJob *> *finished = [NSMutableArray array], *removed = [NSMutableArray array];
    for (OVJob *j in jobs) if (!j.active) [finished addObject:j];
    [finished sortUsingComparator:^NSComparisonResult(OVJob *a, OVJob *b) {
        return [(b.finished ?: b.created) compare:(a.finished ?: a.created)];
    }];
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-kKeepSeconds];
    [finished enumerateObjectsUsingBlock:^(OVJob *j, NSUInteger i, BOOL *stop) {
        if (i >= kKeepFinished || [(j.finished ?: j.created) compare:cutoff] == NSOrderedAscending) [removed addObject:j];
    }];
    for (OVJob *j in removed) [self removeFolderOfJob:j];
    return removed;
}

#pragma mark Secrets

static BOOL OVSecretKey(NSString *key) {
    static NSRegularExpression *plain, *camel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // a whole word at the end of the name: token, hf_token, api-key, Authorization … but not max_new_tokens
        plain = [NSRegularExpression regularExpressionWithPattern:@"(^|[^a-z])(token|key|password|passwd|secret|authorization)$"
                                                          options:NSRegularExpressionCaseInsensitive error:nil];
        camel = [NSRegularExpression regularExpressionWithPattern:@"[a-z](Token|Key|Password|Secret|Authorization)$" options:0 error:nil];
    });
    NSRange all = NSMakeRange(0, key.length);
    return [plain numberOfMatchesInString:key options:0 range:all] || [camel numberOfMatchesInString:key options:0 range:all];
}

+ (id)redact:(id)v {
    if ([v isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        [v enumerateKeysAndObjectsUsingBlock:^(id k, id val, BOOL *stop) {
            out[k] = ([k isKindOfClass:NSString.class] && OVSecretKey(k)) ? @"***" : [self redact:val];
        }];
        return out;
    }
    if ([v isKindOfClass:NSArray.class]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id x in v) [out addObject:[self redact:x]];
        return out;
    }
    return v;   // numbers, strings, dates, URLs, data: untouched (jsonSafe: makes them writable)
}

+ (id)jsonSafe:(id)v {
    if ([v isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        [v enumerateKeysAndObjectsUsingBlock:^(id k, id val, BOOL *stop) {
            out[[k isKindOfClass:NSString.class] ? k : [k description]] = [self jsonSafe:val];
        }];
        return out;
    }
    if ([v isKindOfClass:NSArray.class]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id x in v) [out addObject:[self jsonSafe:x]];
        return out;
    }
    if ([v isKindOfClass:NSString.class]) return v;
    if ([v isKindOfClass:NSNumber.class]) {
        double d = [v doubleValue];
        return (isnan(d) || isinf(d)) ? [NSNull null] : v;
    }
    if ([v isKindOfClass:NSNull.class]) return v;
    if ([v isKindOfClass:NSDate.class]) return @([(NSDate *)v timeIntervalSince1970]);
    if ([v isKindOfClass:NSURL.class]) return [(NSURL *)v isFileURL] ? [(NSURL *)v path] : [(NSURL *)v absoluteString];
    if ([v isKindOfClass:NSData.class]) return [NSString stringWithFormat:@"<%lu bytes>", (unsigned long)[(NSData *)v length]];
    return [v description];
}

+ (BOOL)hasRedactedValues:(id)v {
    if ([v isKindOfClass:NSDictionary.class]) { for (id x in [v allValues]) if ([self hasRedactedValues:x]) return YES; return NO; }
    if ([v isKindOfClass:NSArray.class]) { for (id x in v) if ([self hasRedactedValues:x]) return YES; return NO; }
    return [v isKindOfClass:NSString.class] && [v isEqualToString:@"***"];
}

#pragma mark Paths

/// realpath of the deepest existing ancestor + the rest; nil if the path has ".." parts or cannot be resolved.
static NSString *OVRealPathLoose(NSString *path) {
    if (!path.length || ![path hasPrefix:@"/"]) return nil;
    NSArray *parts = path.pathComponents;
    for (NSString *p in parts) if ([p isEqualToString:@".."]) return nil;
    NSString *existing = path;
    NSMutableArray *rest = [NSMutableArray array];
    char buf[PATH_MAX];
    while (existing.length > 1 && !realpath(existing.fileSystemRepresentation, buf)) {
        [rest insertObject:existing.lastPathComponent atIndex:0];
        existing = existing.stringByDeletingLastPathComponent;
    }
    if (!realpath(existing.fileSystemRepresentation, buf)) return nil;
    NSString *real = [NSString stringWithUTF8String:buf];
    for (NSString *r in rest) real = [real stringByAppendingPathComponent:r];
    return real;
}

+ (BOOL)isInsideAppData:(NSString *)path {
    NSString *real = OVRealPathLoose(path);
    if (!real) return NO;
    for (NSString *root in self.appDataRoots) {
        NSString *r = OVRealPathLoose(root);
        if (!r || r.length < 2) continue;
        NSString *prefix = [r hasSuffix:@"/"] ? r : [r stringByAppendingString:@"/"];
        if (real.length > prefix.length && [real hasPrefix:prefix]) return YES;   // the root itself is not deletable
    }
    return NO;
}
static NSArray<NSString *> *gProtected;
+ (NSArray<NSString *> *)protectedRoots { @synchronized (self) { return gProtected ?: @[]; } }
+ (void)setProtectedRoots:(NSArray<NSString *> *)roots { @synchronized (self) { gProtected = [roots copy]; } }

static BOOL OVInsideAny(NSString *real, NSArray<NSString *> *roots) {
    for (NSString *root in roots) {
        NSString *r = OVRealPathLoose(root);
        if (!r || r.length < 2) continue;
        NSString *prefix = [r hasSuffix:@"/"] ? r : [r stringByAppendingString:@"/"];
        if (real.length > prefix.length && [real hasPrefix:prefix]) return YES;
    }
    return NO;
}

+ (BOOL)isDeletablePartial:(NSString *)path roots:(NSArray<NSString *> *)roots exceptRoots:(NSArray<NSString *> *)exceptRoots {
    NSString *real = OVRealPathLoose(path);
    if (!real) return NO;
    BOOL ok = OVInsideAny(real, exceptRoots) || (OVInsideAny(real, roots) && !OVInsideAny(real, self.protectedRoots));
    if (!ok) return NO;
    struct stat st;
    if (lstat(real.fileSystemRepresentation, &st) != 0) return YES;   // not there (yet): nothing to refuse
    return S_ISREG(st.st_mode);                                       // never a folder, a link or a device
}

+ (BOOL)removePartial:(NSString *)path roots:(NSArray<NSString *> *)roots exceptRoots:(NSArray<NSString *> *)exceptRoots {
    if (![self isDeletablePartial:path roots:roots exceptRoots:exceptRoots]) return NO;
    NSString *real = OVRealPathLoose(path);
    return unlink(real.fileSystemRepresentation) == 0;
}
@end
