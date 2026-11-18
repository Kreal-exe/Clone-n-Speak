#import "OVBridge.h"
#import "OVAPI.h"
#import "OVJobs.h"
#import "OVNetwork.h"
#import "OVDownloader.h"
#import "OVPaths.h"
#import "OVLocale.h"
#import "OVPrivacyCatalog.h"
#import <CommonCrypto/CommonDigest.h>
#import <libproc.h>
#import <signal.h>
#import <sys/stat.h>
#import <sys/xattr.h>

NSNotificationName const OVBridgeDidChangeNotification = @"OVBridgeDidChangeNotification";

static NSString *const kHelperPrefix = @"cloudflared-";
static NSString *const kPlaceholderHost = @"bridge-starting.invalid";     // until the tunnel's address is known; nobody can reach it
static const NSTimeInterval kTunnelTimeout = 30;
static const NSTimeInterval kListenerTimeout = 10;
static const NSTimeInterval kPairShown = 125;                              // the server forgets a request after 120 s

#pragma mark - Pure helpers

NSString *OVBridgeParseTunnelURL(NSString *line) {
    NSRange r = [line rangeOfString:@"https://"];
    if (r.location == NSNotFound) return nil;
    if (r.location > 0) {
        unichar p = [line characterAtIndex:r.location - 1];
        if (![NSCharacterSet.whitespaceCharacterSet characterIsMember:p] && !strchr("|(\"'<[", p < 128 ? (char)p : 'x')) return nil;
    }
    NSUInteger i = NSMaxRange(r), start = i, n = line.length;
    while (i < n) {
        unichar c = [line characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-') i++; else break;
    }
    if (i < n) {                                                           // what follows the host must end it
        unichar c = [line characterAtIndex:i];
        if (!([NSCharacterSet.whitespaceCharacterSet characterIsMember:c] || (c < 128 && strchr("/|)\"',>]}", (char)c) && c != 0))) return nil;
    }
    NSString *host = [line substringWithRange:NSMakeRange(start, i - start)];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^[a-z0-9]+(-[a-z0-9]+)+\\.trycloudflare\\.com$" options:0 error:nil];
    if (![re firstMatchInString:host options:0 range:NSMakeRange(0, host.length)]) return nil;
    return [@"https://" stringByAppendingString:host];
}

NSString *OVSHA256OfFile(NSString *path) {
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!h) return @"";
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    for (;;) {
        @autoreleasepool {
            NSError *e = nil;
            NSData *d = [h readDataUpToLength:1 << 20 error:&e];
            if (e) { [h closeFile]; return @""; }
            if (!d.length) break;
            CC_SHA256_Update(&ctx, d.bytes, (CC_LONG)d.length);
        }
    }
    [h closeFile];
    unsigned char md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(md, &ctx);
    NSMutableString *s = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", md[i]];
    return s;
}

static BOOL IsHex64(id v) {
    if (![v isKindOfClass:NSString.class] || [v length] != 64) return NO;
    for (NSUInteger i = 0; i < 64; i++) {
        unichar c = [v characterAtIndex:i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return NO;
    }
    return YES;
}

static BOOL IsDeviceId(id v) {
    if (![v isKindOfClass:NSString.class] || [v length] < 1 || [v length] > 32) return NO;
    for (NSUInteger i = 0; i < [v length]; i++) {
        unichar c = [v characterAtIndex:i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '-')) return NO;
    }
    return YES;
}

/// The pin is used only when it has exactly the shape and address the project allows.
static BOOL PinIsValid(NSDictionary *pin) {
    if (![pin isKindOfClass:NSDictionary.class]) return NO;
    NSString *v = pin[@"version"], *url = pin[@"url"], *team = pin[@"team_id"];
    if (![v isKindOfClass:NSString.class] || ![url isKindOfClass:NSString.class] || ![team isKindOfClass:NSString.class]) return NO;
    NSRegularExpression *ver = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]{4}\\.[0-9]+\\.[0-9]+$" options:0 error:nil];
    if (![ver firstMatchInString:v options:0 range:NSMakeRange(0, v.length)]) return NO;
    NSString *want = [NSString stringWithFormat:@"https://github.com/cloudflare/cloudflared/releases/download/%@/cloudflared-darwin-arm64.tgz", v];
    if (![url isEqualToString:want]) return NO;
    NSRegularExpression *tid = [NSRegularExpression regularExpressionWithPattern:@"^[A-Z0-9]{10}$" options:0 error:nil];
    if (![tid firstMatchInString:team options:0 range:NSMakeRange(0, team.length)]) return NO;
    return IsHex64(pin[@"sha256_archive"]) && IsHex64(pin[@"sha256_binary"]);
}

/// Runs a system tool with an empty environment; output is small (listings, codesign).
static int RunTool(NSString *exe, NSArray<NSString *> *args, NSString **out, NSString **err) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:exe];
    t.arguments = args;
    t.environment = @{@"PATH": @"/usr/bin:/bin"};
    NSPipe *o = [NSPipe pipe], *e = [NSPipe pipe];
    t.standardOutput = o; t.standardError = e; t.standardInput = NSFileHandle.fileHandleWithNullDevice;
    if (![t launchAndReturnError:nil]) return -1;
    __block NSData *eData = nil;
    dispatch_group_t g = dispatch_group_create();
    dispatch_group_async(g, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ eData = [e.fileHandleForReading readDataToEndOfFile]; });
    NSData *oData = [o.fileHandleForReading readDataToEndOfFile];
    dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
    [t waitUntilExit];
    if (out) *out = [[NSString alloc] initWithData:oData encoding:NSUTF8StringEncoding] ?: @"";
    if (err) *err = [[NSString alloc] initWithData:eData encoding:NSUTF8StringEncoding] ?: @"";
    return t.terminationStatus;
}

static BOOL IsRegularFileNoLink(NSString *path, struct stat *st) {
    struct stat s;
    if (lstat(path.fileSystemRepresentation, &s) != 0 || !S_ISREG(s.st_mode)) return NO;
    if (st) *st = s;
    return YES;
}

#pragma mark - The job runner for the helper download

@interface OVBridge ()
@property (readwrite, nullable, copy) NSString *status, *tunnelURL, *lastError;
- (void)runHelperDownload:(OVJobContext *)ctx;
- (void)cancelHelperDownload;
@end

@interface OVBridgeDownloadRunner : NSObject <OVJobRunner>
@property (weak) OVBridge *bridge;
@end
@implementation OVBridgeDownloadRunner
- (void)start:(OVJob *)job context:(OVJobContext *)ctx {
    if (![job.request[@"what"] isEqual:@"bridge-helper"] || !self.bridge) { [ctx failWithError:L(@"Bridge helper integrity verification failed")]; return; }
    [self.bridge runHelperDownload:ctx];
}
- (void)stop:(OVJob *)job { [self.bridge cancelHelperDownload]; }
- (void)kill:(OVJob *)job { [self.bridge cancelHelperDownload]; }
@end

#pragma mark - OVBridge

typedef NS_ENUM(NSInteger, OVBridgeState) { BSIdle, BSStarting, BSRunning };

@implementation OVBridge {
    NSString *_root;
    NSDictionary *_pin;
    NSMutableArray<NSMutableDictionary *> *_devices;     // @{id, name, created, lastSeen?, token_sha256}
    OVBridgeState _state;
    NSInteger _gen;                                      // every start / teardown bumps it: late callbacks see a stale number
    pid_t _tunnelPid;                                    // the tunnel program, owned by the API server process
    NSAlert *_wlAlert;                                   // an alert shown without a window (no sheet host)
    void (^_wlDone)(NSModalResponse);
    BOOL _awaitingListener, _launchingAPI, _startedAPI, _jobRunning;
    uint16_t _bridgePort;
    OVDownloader *_downloader;
    OVJobContext *_downloadContext;
    NSString *_downloadArchive;
    NSMutableArray<NSDictionary *> *_pairQueue;
    NSAlert *_pairAlert;
    NSWindow *_pairParent;
    NSString *_pairShownId;
    NSString *_verifiedPath;                              // helperInstalled cache: path + inode + size + mtime
    struct stat _verifiedStat;
    BOOL _verifiedOK;
    NSTimeInterval _lastSeenSaved;
}

+ (instancetype)shared {
    static OVBridge *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[OVBridge alloc] initWithRoot:[OVPaths bridge] pin:nil];
        [s registerJobKind];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:s selector:@selector(apiChanged:) name:OVAPIDidChangeNotification object:nil];
        [nc addObserver:s selector:@selector(networkModeChanged:) name:OVNetworkModeDidChangeNotification object:nil];
        [nc addObserver:s selector:@selector(willDeleteAppData:) name:OVPrivacyWillDeleteAppDataNotification object:nil];
    });
    return s;
}

+ (instancetype)bridgeWithRoot:(NSString *)root pin:(NSDictionary *)pin {
    return [[OVBridge alloc] initWithRoot:root pin:pin];
}

- (instancetype)initWithRoot:(NSString *)root pin:(NSDictionary *)pin {
    if ((self = [super init])) {
        _root = [root copy];
        if (!pin) {
            NSData *d = [NSData dataWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"bridge-pin" ofType:@"json"]];
            pin = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        }
        _pin = PinIsValid(pin) ? [pin copy] : nil;
        _devices = [NSMutableArray array];
        _pairQueue = [NSMutableArray array];
        [self loadDevices];
    }
    return self;
}

- (void)registerJobKind {
    __weak OVBridge *w = self;
    [OVJobs.shared registerKind:OVJobKindDownload lane:OVJobLaneNetwork retryable:NO
                          title:^NSString *(NSDictionary *r) { return L(@"Downloading the Bridge helper"); }
                        factory:^id<OVJobRunner>(OVJob *job) { OVBridgeDownloadRunner *r = [OVBridgeDownloadRunner new]; r.bridge = w; return r; }
                      onSuccess:nil];
}

- (void)changed { [NSNotificationCenter.defaultCenter postNotificationName:OVBridgeDidChangeNotification object:self]; }
- (BOOL)running { return _state == BSRunning; }
- (BOOL)busy { return _state != BSIdle; }

- (void)setStatusText:(nullable NSString *)s { self.status = s; [self changed]; }

#pragma mark - Paths and helper

- (NSString *)helperPath { return _pin ? [_root stringByAppendingPathComponent:[kHelperPrefix stringByAppendingString:_pin[@"version"]]] : nil; }
- (NSString *)devicesPath { return [_root stringByAppendingPathComponent:@"devices.json"]; }
- (NSString *)pidPath { return [_root stringByAppendingPathComponent:@"tunnel.pid"]; }

- (void)ensureRoot {
    [NSFileManager.defaultManager createDirectoryAtPath:_root withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions: @0700} error:nil];
}

/// Present, a plain file (no link), executable, not quarantined, and its SHA-256 is the pinned one. Hashed again only when the file changes.
- (BOOL)helperVerified {
    NSString *p = [self helperPath];
    struct stat st;
    if (!p || !IsRegularFileNoLink(p, &st) || !(st.st_mode & S_IXUSR)) return NO;
    if (getxattr(p.fileSystemRepresentation, "com.apple.quarantine", NULL, 0, 0, XATTR_NOFOLLOW) >= 0) return NO;
    if (_verifiedPath && [_verifiedPath isEqualToString:p] && _verifiedStat.st_ino == st.st_ino && _verifiedStat.st_size == st.st_size &&
        _verifiedStat.st_mtimespec.tv_sec == st.st_mtimespec.tv_sec && _verifiedStat.st_mtimespec.tv_nsec == st.st_mtimespec.tv_nsec)
        return _verifiedOK;
    _verifiedOK = [OVSHA256OfFile(p) isEqualToString:_pin[@"sha256_binary"]];
    _verifiedPath = p; _verifiedStat = st;
    return _verifiedOK;
}

- (BOOL)helperInstalled { return [self helperVerified]; }

/// <support>/bridge must be a real directory of ours (never a link), mode 0700.
- (BOOL)rootIsSafe {
    struct stat st;
    if (lstat(_root.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != getuid()) return NO;
    if ((st.st_mode & 0777) != 0700 && chmod(_root.fileSystemRepresentation, 0700) != 0) return NO;
    return YES;
}

/// Right before a run: no cache. A plain file of ours that nobody else can write, not quarantined, with the pinned SHA-256.
- (BOOL)helperVerifiedFresh {
    NSString *p = [self helperPath];
    struct stat st;
    if (!p || !IsRegularFileNoLink(p, &st) || st.st_uid != getuid() || (st.st_mode & 022) || !(st.st_mode & S_IXUSR)) return NO;
    if (getxattr(p.fileSystemRepresentation, "com.apple.quarantine", NULL, 0, 0, XATTR_NOFOLLOW) >= 0) return NO;
    _verifiedPath = nil;
    return [self helperVerified];
}

- (void)discardDownload:(NSString *)archive {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:archive error:nil];
    [fm removeItemAtPath:[archive stringByAppendingString:@".part"] error:nil];
}

/// Any failure of the install: the archive, its .part and the unpacked folder are deleted.
- (int)run:(NSString *)exe args:(NSArray<NSString *> *)args out:(NSString **)out err:(NSString **)err {
    return self.toolRunner ? self.toolRunner(exe, args, out, err) : RunTool(exe, args, out, err);
}

- (BOOL)failInstall:(NSString *)tmp archive:(NSString *)archive error:(NSString **)error {
    [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
    [self discardDownload:archive];
    if (error) *error = L(@"Bridge helper integrity verification failed");
    return NO;
}

- (BOOL)installArchiveAtPath:(NSString *)archive error:(NSString **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *tmp = [_root stringByAppendingPathComponent:[@"tmp-" stringByAppendingString:NSUUID.UUID.UUIDString]];
#define FAIL return [self failInstall:tmp archive:archive error:error]
    if (!_pin) FAIL;
    [self ensureRoot];
    // 1. the archive, before anything is unpacked
    if (!IsRegularFileNoLink(archive, NULL) || ![OVSHA256OfFile(archive) isEqualToString:_pin[@"sha256_archive"]]) FAIL;
    // 2. it holds exactly one file, the program
    NSString *list = nil;
    if ([self run:@"/usr/bin/tar" args:@[@"-tzf", archive] out:&list err:nil] != 0) FAIL;
    NSArray *names = [[list stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@"\n"];
    if (names.count != 1 || !([names[0] isEqualToString:@"cloudflared"] || [names[0] isEqualToString:@"./cloudflared"])) FAIL;
    // 3. unpacked into an empty private folder
    if (![fm createDirectoryAtPath:tmp withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions: @0700} error:nil]) FAIL;
    if ([self run:@"/usr/bin/tar" args:@[@"-xzf", archive, @"-C", tmp] out:nil err:nil] != 0) FAIL;
    NSString *bin = [tmp stringByAppendingPathComponent:@"cloudflared"];
    if (!IsRegularFileNoLink(bin, NULL)) FAIL;
    // 4. the program itself, its signature and its signer
    if (![OVSHA256OfFile(bin) isEqualToString:_pin[@"sha256_binary"]]) FAIL;
    if ([self run:@"/usr/bin/codesign" args:@[@"--verify", @"--strict", bin] out:nil err:nil] != 0) FAIL;
    NSString *info = nil;
    [self run:@"/usr/bin/codesign" args:@[@"-dvv", bin] out:nil err:&info];
    BOOL teamOK = NO;
    for (NSString *l in [info componentsSeparatedByString:@"\n"])
        if ([l isEqualToString:[@"TeamIdentifier=" stringByAppendingString:_pin[@"team_id"]]]) teamOK = YES;
    if (!teamOK) FAIL;
    // 5. only now it becomes executable and moves into place
    removexattr(bin.fileSystemRepresentation, "com.apple.quarantine", XATTR_NOFOLLOW);
    if (chmod(bin.fileSystemRepresentation, 0755) != 0) FAIL;
    NSString *dst = [self helperPath];
    [fm removeItemAtPath:dst error:nil];
    if (rename(bin.fileSystemRepresentation, dst.fileSystemRepresentation) != 0) FAIL;
    [fm removeItemAtPath:tmp error:nil];
    [self discardDownload:archive];
    for (NSString *n in [fm contentsOfDirectoryAtPath:_root error:nil])                       // older versions go
        if ([n hasPrefix:kHelperPrefix] && ![n hasSuffix:@".tgz"] && ![n isEqualToString:dst.lastPathComponent])
            [fm removeItemAtPath:[_root stringByAppendingPathComponent:n] error:nil];
    return YES;
#undef FAIL
}

#pragma mark - Devices

- (void)loadDevices {
    NSData *d = [NSData dataWithContentsOfFile:[self devicesPath]];
    id obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    NSArray *list = [obj isKindOfClass:NSDictionary.class] ? obj[@"devices"] : nil;
    if (![list isKindOfClass:NSArray.class]) return;
    for (id e in list) {
        if (![e isKindOfClass:NSDictionary.class] || !IsDeviceId(e[@"id"]) || !IsHex64(e[@"token_sha256"])) continue;
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        m[@"id"] = e[@"id"];
        m[@"name"] = [e[@"name"] isKindOfClass:NSString.class] ? e[@"name"] : @"Device";
        m[@"created"] = [e[@"created"] isKindOfClass:NSNumber.class] ? e[@"created"] : @0;
        if ([e[@"lastSeen"] isKindOfClass:NSNumber.class]) m[@"lastSeen"] = e[@"lastSeen"];
        m[@"token_sha256"] = e[@"token_sha256"];
        [_devices addObject:m];
    }
}

- (void)saveDevices {
    [self ensureRoot];
    NSData *d = [NSJSONSerialization dataWithJSONObject:@{@"devices": _devices} options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    if (!d) return;
    NSString *p = [self devicesPath];
    [d writeToFile:p options:NSDataWritingAtomic error:nil];
    chmod(p.fileSystemRepresentation, 0600);
}

- (NSArray<NSDictionary *> *)devices {
    NSMutableArray *a = [NSMutableArray array];
    for (NSDictionary *m in _devices) {
        NSMutableDictionary *o = [@{@"id": m[@"id"], @"name": m[@"name"],
                                    @"created": [NSDate dateWithTimeIntervalSince1970:[m[@"created"] doubleValue]]} mutableCopy];
        if (m[@"lastSeen"]) o[@"lastSeen"] = [NSDate dateWithTimeIntervalSince1970:[m[@"lastSeen"] doubleValue]];
        [a addObject:o];
    }
    return a;
}

- (NSArray<NSDictionary *> *)devicesForServer {
    NSMutableArray *a = [NSMutableArray array];
    for (NSDictionary *m in _devices) [a addObject:@{@"id": m[@"id"], @"name": m[@"name"], @"token_sha256": m[@"token_sha256"]}];
    return a;
}

- (void)revokeDevice:(NSString *)deviceId {
    NSUInteger before = _devices.count;
    for (NSMutableDictionary *m in [_devices copy]) if ([m[@"id"] isEqualToString:deviceId]) [_devices removeObject:m];
    if (_devices.count == before) return;
    [self saveDevices];
    // the server forgets the token at once (it checks every request against its list); work already started goes too
    [OVAPI.shared sendMessage:@{@"op": @"revoke", @"deviceId": deviceId}];
    NSString *origin = [@"bridge:" stringByAppendingString:deviceId];
    for (OVJob *j in OVJobs.shared.all) if (j.active && [j.origin isEqualToString:origin]) [OVJobs.shared stop:j];
    [self changed];
}

#pragma mark - Messages from the server

- (void)handleServerMessage:(NSDictionary *)m {
    NSString *op = [m[@"op"] isKindOfClass:NSString.class] ? m[@"op"] : @"";
    if ([op isEqualToString:@"listening"]) {
        id bp = m[@"bridgePort"];
        if (_awaitingListener && [bp isKindOfClass:NSNumber.class] && [bp integerValue] > 0 && [bp integerValue] < 65536) {
            _awaitingListener = NO;
            _bridgePort = (uint16_t)[bp integerValue];
            [self launchTunnel];
        }
    } else if ([op isEqualToString:@"error"]) {
        if ([m[@"code"] isEqual:@"BRIDGE"] && _state != BSIdle) [self teardownWithError:L(@"Bridge could not open its listener.")];
    } else if ([op hasPrefix:@"tunnel_"]) {
        [self tunnelMessage:m];
    } else if ([op isEqualToString:@"pair_request"]) {
        [self pairRequested:m];
    } else if ([op isEqualToString:@"device_added"]) {
        if (!IsDeviceId(m[@"id"]) || !IsHex64(m[@"token_sha256"])) return;       // only a hash is ever taken from the message
        for (NSDictionary *d in _devices) if ([d[@"id"] isEqualToString:m[@"id"]]) return;
        NSString *name = [m[@"name"] isKindOfClass:NSString.class] ? [m[@"name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
        if (name.length > 200) name = [name substringToIndex:200];
        [_devices addObject:[@{@"id": m[@"id"], @"name": name.length ? name : @"Device",
                               @"created": @(NSDate.date.timeIntervalSince1970), @"token_sha256": m[@"token_sha256"]} mutableCopy]];
        [self saveDevices];
        [self changed];
    } else if ([op isEqualToString:@"device_seen"]) {
        for (NSMutableDictionary *d in _devices) {
            if (![d[@"id"] isEqual:m[@"id"]]) continue;
            NSTimeInterval now = NSDate.date.timeIntervalSince1970;
            d[@"lastSeen"] = @(now);
            if (now - _lastSeenSaved > 30) { _lastSeenSaved = now; [self saveDevices]; }
            [self changed];
            break;
        }
    }
}

#pragma mark - Pairing

- (void)pairRequested:(NSDictionary *)m {
    if (_state != BSRunning) return;
    NSString *pid = m[@"pairId"], *name = m[@"name"], *code = m[@"code"];
    if (![pid isKindOfClass:NSString.class] || ![name isKindOfClass:NSString.class] || ![code isKindOfClass:NSString.class]) return;
    for (NSDictionary *q in _pairQueue) if ([q[@"pairId"] isEqualToString:pid]) return;
    if ([_pairShownId isEqualToString:pid] || _pairQueue.count >= 8) return;
    [_pairQueue addObject:@{@"pairId": pid, @"name": name, @"code": code}];
    [self showNextPair];
}

static NSString *SpacedCode(NSString *code) {
    if (code.length == 6) return [NSString stringWithFormat:@"%@ %@", [code substringToIndex:3], [code substringFromIndex:3]];
    return code;
}

- (NSWindow *)hostWindow {
    NSWindow *w = NSApp.mainWindow ?: NSApp.keyWindow;
    if (w.attachedSheet) return nil;                      // one sheet at a time: fall back to a modal alert
    return w.isVisible ? w : nil;
}

- (void)showNextPair {
    if (_pairAlert || !_pairQueue.count || _state != BSRunning) return;
    NSDictionary *req = _pairQueue.firstObject;
    [_pairQueue removeObjectAtIndex:0];
    NSString *pid = req[@"pairId"];
    NSAlert *a = [NSAlert new];
    a.alertStyle = NSAlertStyleWarning;
    a.messageText = [NSString stringWithFormat:L(@"“%@” wants to connect."), req[@"name"]];
    a.informativeText = [NSString stringWithFormat:L(@"Code %@ — check it matches the code on that device."), SpacedCode(req[@"code"])];
    [a addButtonWithTitle:L(@"Deny")];                    // the default button is the safe one
    [a addButtonWithTitle:L(@"Allow")];
    _pairAlert = a;
    _pairShownId = pid;
    NSInteger gen = _gen;
    [NSApp requestUserAttention:NSCriticalRequest];
    void (^done)(NSModalResponse) = ^(NSModalResponse r) {
        if (self->_pairAlert != a) return;
        self->_pairAlert = nil; self->_pairParent = nil; self->_pairShownId = nil;
        BOOL approve = r == NSAlertSecondButtonReturn && gen == self->_gen && self->_state == BSRunning;
        [OVAPI.shared sendMessage:@{@"op": @"pair_decision", @"pairId": pid, @"approve": @(approve)}];
        dispatch_async(dispatch_get_main_queue(), ^{ [self showNextPair]; });
    };
    NSWindow *host = [self hostWindow];
    if (host) { _pairParent = host; [a beginSheetModalForWindow:host completionHandler:done]; }
    else [self showWindowless:a done:done];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPairShown * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_pairAlert != a) return;                                         // expired: a denial
        if (self->_pairParent) [self->_pairParent endSheet:a.window returnCode:NSModalResponseStop];
        else [self closeWindowlessWithResponse:NSModalResponseStop];
    });
}

/// An alert with no window to hang on (the app has none open): a floating panel, answered by its buttons.
- (void)showWindowless:(NSAlert *)a done:(void (^)(NSModalResponse))done {
    [a layout];
    _wlAlert = a;
    _wlDone = [done copy];
    for (NSUInteger i = 0; i < a.buttons.count; i++) { a.buttons[i].target = self; a.buttons[i].action = @selector(windowlessButton:); a.buttons[i].tag = (NSInteger)i; }
    NSWindow *win = a.window;
    win.level = NSFloatingWindowLevel;
    [win center];
    [NSApp activateIgnoringOtherApps:YES];
    [win makeKeyAndOrderFront:nil];
}

- (void)windowlessButton:(NSButton *)b { [self closeWindowlessWithResponse:NSAlertFirstButtonReturn + b.tag]; }

- (void)closeWindowlessWithResponse:(NSModalResponse)r {
    NSAlert *a = _wlAlert;
    void (^d)(NSModalResponse) = _wlDone;
    if (!a) return;
    _wlAlert = nil; _wlDone = nil;
    [a.window orderOut:nil];
    if (d) d(r);
}

/// Teardown: the panel goes without an answer.
- (void)dismissWindowless {
    NSAlert *a = _wlAlert;
    _wlAlert = nil; _wlDone = nil;
    [a.window orderOut:nil];
}

/// Closes a request that is on screen without approving it.
- (void)dismissPairing {
    [_pairQueue removeAllObjects];
    [self dismissWindowless];
    if (_pairAlert) {
        NSAlert *a = _pairAlert;
        if (_pairParent) [_pairParent endSheet:a.window returnCode:NSModalResponseStop];
        _pairAlert = nil; _pairParent = nil; _pairShownId = nil;
    }
}

#pragma mark - Start

- (void)start { [self startInWindow:nil]; }

- (void)askConsent:(NSWindow *)w completion:(void (^)(BOOL))completion {
    if ([OVNetwork decisionFor:OVNetBridge] != OVNetNeedsConsent) { [OVNetwork requestFeature:OVNetBridge window:w completion:completion]; return; }
    NSAlert *a = [NSAlert new];
    a.alertStyle = NSAlertStyleWarning;
    a.messageText = L(@"Use Bridge?");
    a.informativeText = L(@"Traffic, including audio and results, passes through Cloudflare. Anyone who learns the address can ask to connect, but only devices you approve on this Mac get access. Stop Bridge when you are done.");
    [a addButtonWithTitle:L(@"Not now")];                 // the default button is the safe one
    [a addButtonWithTitle:L(@"Allow")];
    void (^done)(NSModalResponse) = ^(NSModalResponse r) {
        BOOL ok = r == NSAlertSecondButtonReturn;
        if (ok) [OVNetwork grantConsentFor:OVNetBridge];
        completion(ok);
    };
    NSWindow *host = w ?: [self hostWindow];
    if (host) [a beginSheetModalForWindow:host completionHandler:done]; else [self showWindowless:a done:done];
}

- (void)startInWindow:(NSWindow *)window {
    if (_state != BSIdle) return;
    self.lastError = nil;
    _state = BSStarting;
    NSInteger gen = ++_gen;
    [self setStatusText:L(@"Waiting for your answer…")];
    [self askConsent:window completion:^(BOOL ok) {
        if (gen != self->_gen || self->_state != BSStarting) return;
        if (!ok) { [self teardownWithError:nil]; return; }
        [self ensureHelper];
    }];
}

- (void)ensureHelper {
    if (!_pin) { [self teardownWithError:L(@"Bridge helper integrity verification failed")]; return; }
    if ([self helperVerified]) { [self launchListener]; return; }
    [self ensureRoot];
    [self setStatusText:[NSString stringWithFormat:L(@"Downloading helper %d %%"), 0]];
    NSInteger gen = _gen;
    NSString *err = nil;
    OVJob *job = [OVJobs.shared submitKind:OVJobKindDownload request:@{@"what": @"bridge-helper", @"version": _pin[@"version"]} origin:@"app"
                                  onFinish:^(OVJob *j) {
        if (gen != self->_gen || self->_state != BSStarting) return;
        if (j.state == OVJobSucceeded && [self helperVerified]) { [self launchListener]; return; }
        [self teardownWithError:j.state == OVJobStopped ? nil : (j.error.length ? j.error : L(@"Bridge helper integrity verification failed"))];
    } error:&err];
    if (!job) [self teardownWithError:err ?: L(@"The helper could not be downloaded.")];
}

// Called by the job runner (main thread).
- (void)runHelperDownload:(OVJobContext *)ctx {
    NSInteger gen = _gen;
    NSString *archive = [_root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@%@.tgz", kHelperPrefix, _pin[@"version"]]];
    [self discardDownload:archive];                                     // a stale partial file is never resumed
    _downloadContext = ctx;
    _downloadArchive = archive;
    NSURL *url = [NSURL URLWithString:_pin[@"url"]];
    __weak OVBridge *w = self;
    _downloader = [OVDownloader download:url to:archive headers:nil
        progress:^(long long got, long long total) {
            OVBridge *s = w;
            if (!s || gen != s->_gen || total <= 0) return;
            double f = (double)got / (double)total;
            [ctx setProgress:f];
            [s setStatusText:[NSString stringWithFormat:L(@"Downloading helper %d %%"), (int)(f * 100)]];
        }
        completion:^(NSError *e) {
            OVBridge *s = w;
            if (!s) return;
            s->_downloader = nil;
            if (ctx.stopRequested || gen != s->_gen) { [s discardDownload:archive]; [ctx failWithError:@"Stopped"]; return; }
            if (e) { [s discardDownload:archive]; [ctx failWithError:e.localizedDescription]; return; }
            [s setStatusText:L(@"Verifying helper…")];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSString *err = nil;
                BOOL ok = [s installArchiveAtPath:archive error:&err];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (ok) [ctx succeedWithResult:nil outputs:@[]]; else [ctx failWithError:err ?: L(@"Bridge helper integrity verification failed")];
                });
            });
        }];
}

- (void)cancelHelperDownload {
    [_downloader cancel];
    _downloader = nil;
    if (_downloadArchive) [self discardDownload:_downloadArchive];
}

- (void)launchListener {
    if (_state != BSStarting) return;
    [self setStatusText:L(@"Starting tunnel…")];
    OVAPI *api = OVAPI.shared;
    if (!api.running) {
        NSString *err = nil;
        _launchingAPI = YES;
        BOOL ok = [api start:&err];
        _launchingAPI = NO;
        if (!ok) { [self teardownWithError:err ?: L(@"The API server did not start.")]; return; }
        _startedAPI = YES;
    }
    _awaitingListener = YES;
    NSInteger gen = _gen;
    [api sendMessage:@{@"op": @"bridge", @"host": kPlaceholderHost}];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kListenerTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen == self->_gen && self->_awaitingListener) [self teardownWithError:L(@"Bridge could not open its listener.")];
    });
}

- (void)launchTunnel {
    if (_state != BSStarting) return;
    NSString *bin = [self helperPath];
    if (![self rootIsSafe] || ![self helperVerifiedFresh]) {            // changed since the check: unverified code is never run
        if (bin) [NSFileManager.defaultManager removeItemAtPath:bin error:nil];
        [self teardownWithError:L(@"Bridge helper integrity verification failed")];
        return;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *config = [_root stringByAppendingPathComponent:@"tunnel.yml"], *home = [_root stringByAppendingPathComponent:@"home"];
    [fm createFileAtPath:config contents:[NSData data] attributes:@{NSFilePosixPermissions: @0600}];
    [fm createDirectoryAtPath:home withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil];
    // The API server process starts and owns the tunnel program (its own process group, a clean environment, no config or
    // certificate of the user): it ends with the server, which ends with the app, whatever way the app ends. It hashes the file again.
    NSInteger gen = _gen;
    [OVAPI.shared sendMessage:@{@"op": @"tunnel_start", @"path": bin, @"sha256": _pin[@"sha256_binary"], @"config": config, @"home": home, @"cwd": _root}];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTunnelTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen == self->_gen && self->_state == BSStarting)
            [self teardownWithError:L(@"Bridge could not open the tunnel. Check your internet connection and try again.")];
    });
}

- (void)tunnelMessage:(NSDictionary *)m {
    NSString *op = m[@"op"];
    if ([op isEqualToString:@"tunnel_started"]) {
        if (_state != BSStarting || ![m[@"pid"] isKindOfClass:NSNumber.class]) return;
        _tunnelPid = (pid_t)[m[@"pid"] intValue];
        [[NSString stringWithFormat:@"%d\n", _tunnelPid] writeToFile:[self pidPath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else if ([op isEqualToString:@"tunnel_line"]) {
        NSString *line = [m[@"line"] isKindOfClass:NSString.class] ? m[@"line"] : nil;
        NSString *url = (_state == BSStarting && line) ? OVBridgeParseTunnelURL(line) : nil;
        if (url) [self tunnelIsUp:url];
    } else if ([op isEqualToString:@"tunnel_exit"]) {
        if (_state == BSIdle) return;
        _tunnelPid = 0;
        [self teardownWithError:_state == BSRunning ? L(@"The tunnel stopped. Start Bridge again.")
                                                    : L(@"Bridge could not open the tunnel. Check your internet connection and try again.")];
    } else if ([op isEqualToString:@"tunnel_error"]) {
        if (_state == BSIdle) return;
        BOOL integrity = [m[@"code"] isEqual:@"hash"] || [m[@"code"] isEqual:@"unsafe_file"];
        if (integrity && [self helperPath]) [NSFileManager.defaultManager removeItemAtPath:[self helperPath] error:nil];
        [self teardownWithError:integrity ? L(@"Bridge helper integrity verification failed") : L(@"The tunnel program did not start.")];
    }
}

- (void)tunnelIsUp:(NSString *)url {
    NSString *host = [NSURL URLWithString:url].host;
    if (!host.length) return;
    [OVAPI.shared sendMessage:@{@"op": @"bridge", @"host": host}];         // the listener now accepts requests for this name
    self.tunnelURL = url;
    _state = BSRunning;
    [self setStatusText:L(@"Running")];
}

#pragma mark - Stop

- (void)stop { [self teardownWithError:nil]; }

- (void)shutdown {
    pid_t pid = _tunnelPid;
    [self teardownWithError:nil];
    [self waitForExit:pid];
}

/// The tunnel program belongs to the server process, so the app only watches that it is gone (SIGKILL when it lingers).
- (void)waitForExit:(pid_t)pid {
    if (pid <= 1) return;
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:1.5];
    while (kill(pid, 0) == 0 && until.timeIntervalSinceNow > 0) [NSThread sleepForTimeInterval:0.02];
    char buf[PROC_PIDPATHINFO_MAXSIZE];
    if (kill(pid, 0) == 0 && proc_pidpath(pid, buf, sizeof buf) > 0 && [[NSString stringWithUTF8String:buf] hasPrefix:[_root stringByAppendingPathComponent:kHelperPrefix]])
        kill(pid, SIGKILL);
}

/// Everything Bridge started goes away: sheets, download, tunnel, listener, and the API server too when Bridge launched it.
- (void)teardownWithError:(nullable NSString *)error {
    BOOL was = _state != BSIdle;
    _state = BSIdle;
    _gen++;
    _awaitingListener = NO;
    [self dismissPairing];
    [self cancelHelperDownload];
    for (OVJob *j in OVJobs.shared.all)
        if (j.active && [j.kind isEqualToString:OVJobKindDownload] && [j.request[@"what"] isEqual:@"bridge-helper"]) [OVJobs.shared stop:j];
    if (was) [OVAPI.shared sendMessage:@{@"op": @"tunnel_stop"}];
    _tunnelPid = 0;
    [NSFileManager.defaultManager removeItemAtPath:[self pidPath] error:nil];
    if (was && OVAPI.shared.running) [OVAPI.shared sendMessage:@{@"op": @"bridge"}];       // no host: the listener closes
    if (_startedAPI) {
        _startedAPI = NO;
        if (!OVAPI.shared.enabled) [OVAPI.shared stop];
    }
    self.tunnelURL = nil;
    self.status = nil;
    if (error) self.lastError = error;
    if (was || error) [self changed];
}

- (void)apiChanged:(NSNotification *)n {
    if (_state == BSIdle || _launchingAPI || OVAPI.shared.running) return;
    [self teardownWithError:L(@"The API stopped or its key changed, so Bridge stopped too.")];
}

- (void)networkModeChanged:(NSNotification *)n {
    if (_state != BSIdle && OVNetwork.offline) [self teardownWithError:L(@"Offline mode is on. Bridge was stopped.")];
}

- (void)willDeleteAppData:(NSNotification *)n {
    pid_t pid = _tunnelPid;
    [self teardownWithError:nil];
    [self waitForExit:pid];
    [_devices removeAllObjects];
    self.lastError = nil;
    [self changed];
}

#pragma mark - Orphans

- (void)cleanupOrphans {
    NSString *s = [NSString stringWithContentsOfFile:[self pidPath] encoding:NSUTF8StringEncoding error:nil];
    [NSFileManager.defaultManager removeItemAtPath:[self pidPath] error:nil];
    pid_t pid = (pid_t)s.intValue;
    if (pid <= 1) return;
    char buf[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, buf, sizeof buf) <= 0) return;
    NSString *path = [NSString stringWithUTF8String:buf];
    if (![path hasPrefix:[_root stringByAppendingPathComponent:kHelperPrefix]]) return;       // a recycled pid is not touched
    kill(pid, SIGTERM);
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:1.0];
    while (kill(pid, 0) == 0 && until.timeIntervalSinceNow > 0) [NSThread sleepForTimeInterval:0.05];
    if (kill(pid, 0) == 0) kill(pid, SIGKILL);
}

@end
