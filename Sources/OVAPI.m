#import "OVAPI.h"
#import "OVAPICore.h"
#import "OVKeychain.h"
#import "OVJobs.h"
#import "OVStore.h"
#import "OVModels.h"
#import "OVRuntime.h"
#import "OVExport.h"
#import "OVPaths.h"
#import "OVLocale.h"
#import <signal.h>

NSNotificationName const OVAPIDidChangeNotification = @"OVAPIDidChangeNotification";

static NSString *const kKeyAccount = @"local-api-key";
static const uint16_t kDefaultPort = 18777;
static const NSInteger kMaxRestarts = 3;
static const NSTimeInterval kUploadTTL = 3600;

@interface OVAPI ()
@property (readwrite, getter=isRunning) BOOL running;
@property (readwrite, nullable, copy) NSString *lastError;
@end

@implementation OVAPI {
    NSTask *_task;
    NSFileHandle *_toServer;
    NSMutableData *_inBuf;
    BOOL _listening, _wantRunning;
    NSString *_startError;            // set by an "error" event while start waits
    NSInteger _restarts;
    NSDate *_launchedAt;
    NSString *_key;
    NSMutableDictionary<NSString *, NSString *> *_lastSent;     // jobId -> JSON last sent to the server
    NSMutableSet<NSString *> *_encoding;                         // synth jobs whose file is being converted
    NSMutableDictionary<NSString *, OVJob *> *_byRequest;        // reqId -> job (to stop a job the server gave up on)
    NSTimer *_sweepTimer;
    NSUInteger _lastJobCount;
    BOOL _catalogScheduled;
}

+ (instancetype)shared {
    static OVAPI *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [OVAPI new]; });
    return s;
}

+ (NSString *)newKey { return OVAPINewKey(); }

- (instancetype)init {
    if ((self = [super init])) {
        _lastSent = [NSMutableDictionary dictionary];
        _encoding = [NSMutableSet set];
        _byRequest = [NSMutableDictionary dictionary];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(jobsChanged:) name:OVJobsDidChangeNotification object:nil];
        [nc addObserver:self selector:@selector(catalogChanged:) name:OVVoicesDidChangeNotification object:nil];
        [nc addObserver:self selector:@selector(catalogChanged:) name:OVModelsDidChangeNotification object:nil];
    }
    return self;
}

#pragma mark - Settings

- (BOOL)enabled { return [NSUserDefaults.standardUserDefaults boolForKey:@"apiEnabled"]; }

- (uint16_t)port {
    NSInteger p = [NSUserDefaults.standardUserDefaults objectForKey:@"apiPort"] ? [NSUserDefaults.standardUserDefaults integerForKey:@"apiPort"] : kDefaultPort;
    return (p >= 1024 && p <= 65535) ? (uint16_t)p : kDefaultPort;
}

- (NSString *)baseURL { return [NSString stringWithFormat:@"http://127.0.0.1:%u", self.port]; }

- (void)changed { [NSNotificationCenter.defaultCenter postNotificationName:OVAPIDidChangeNotification object:self]; }

- (BOOL)setEnabled:(BOOL)on error:(NSString **)error {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (!on) {
        [d setBool:NO forKey:@"apiEnabled"];
        [self stop];
        self.lastError = nil;
        [self changed];
        return YES;
    }
    [d setBool:YES forKey:@"apiEnabled"];
    NSString *err = nil;
    if ([self start:&err]) return YES;
    [d setBool:NO forKey:@"apiEnabled"];
    if (error) *error = err;
    [self changed];
    return NO;
}

- (BOOL)applyPort:(NSInteger)port error:(NSString **)error {
    if (port < 1024 || port > 65535) {
        if (error) *error = L(@"Use a port between 1024 and 65535.");
        return NO;
    }
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSInteger old = self.port;
    [d setInteger:port forKey:@"apiPort"];
    if (self.running || _wantRunning) {
        [self stop];
        NSString *err = nil;
        if (![self start:&err]) {
            [d setInteger:old forKey:@"apiPort"];
            if (error) *error = err;
            [self start:nil];                      // back on the old port
            return NO;
        }
    }
    [self changed];
    return YES;
}

- (void)startIfEnabled {
    if (!self.enabled || self.running) return;
    NSString *err = nil;
    if (![self start:&err]) { self.lastError = err; [self changed]; }
}

#pragma mark - Key

- (NSString *)currentKey {
    if (_key) return _key;
    NSString *k = [OVKeychain secretForAccount:kKeyAccount];
    if (!k) {
        k = OVAPINewKey();
        if (![OVKeychain setSecret:k forAccount:kKeyAccount])
            self.lastError = L(@"The key could not be saved to the Keychain. It will change at the next launch.");
    }
    _key = k;
    return k;
}

- (NSString *)rotateKey {
    NSString *k = OVAPINewKey();
    if ([OVKeychain setSecret:k forAccount:kKeyAccount]) { if ([self.lastError hasPrefix:@"The key could not"]) self.lastError = nil; }
    else self.lastError = L(@"The key could not be saved to the Keychain. It will change at the next launch.");
    _key = k;
    if (self.running || _wantRunning) { [self stop]; _wantRunning = NO; NSString *e = nil; if (![self start:&e]) self.lastError = e; }
    [self changed];
    return k;
}

#pragma mark - Process

/// Where cns_api.py runs from: the runtime folder, next to worker.py. The bundled copy is put there when it differs.
- (NSString *)installedScript {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dst = [[OVPaths runtime] stringByAppendingPathComponent:@"cns_api.py"];
    NSString *src = [[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"py"] stringByAppendingPathComponent:@"cns_api.py"];
    NSData *a = [NSData dataWithContentsOfFile:src];
    if (a) {
        NSData *b = [NSData dataWithContentsOfFile:dst];
        if (!b || ![a isEqualToData:b]) {
            [fm createDirectoryAtPath:[OVPaths runtime] withIntermediateDirectories:YES attributes:nil error:nil];
            [fm removeItemAtPath:dst error:nil];
            [a writeToFile:dst options:NSDataWritingAtomic error:nil];
        }
    }
    return [fm fileExistsAtPath:dst] ? dst : nil;
}

- (void)send:(NSDictionary *)msg {
    if (!_toServer || !_task.running) return;
    NSData *d = [NSJSONSerialization dataWithJSONObject:msg options:0 error:nil];
    if (!d) return;
    NSMutableData *line = [d mutableCopy];
    [line appendBytes:"\n" length:1];
    [_toServer writeData:line error:nil];
}

/// Starts the child and sends it its configuration. Returns an error text, or nil.
- (NSString *)launch {
    NSString *script = [self installedScript];
    if (!script) return L(@"The API server is missing from the app. Reinstall Clone'n'Speak.");
    [OVPaths ensure];
    NSString *py = [OVRuntime shared].pythonPath ?: @"/usr/bin/python3";
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:py];
    t.arguments = @[@"-u", script];
    t.environment = @{@"PATH": @"/usr/bin:/bin", @"PYTHONIOENCODING": @"utf-8", @"PYTHONDONTWRITEBYTECODE": @"1"};   // nothing else is inherited
    NSPipe *in = [NSPipe pipe], *out = [NSPipe pipe], *err = [NSPipe pipe];
    t.standardInput = in; t.standardOutput = out; t.standardError = err;
    _inBuf = [NSMutableData data];
    _listening = NO; _startError = nil;
    __weak OVAPI *w = self;
    __weak NSTask *wt = t;
    out.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSData *d = h.availableData;
        if (!d.length) { h.readabilityHandler = nil; return; }
        dispatch_async(dispatch_get_main_queue(), ^{ [w consume:d from:wt]; });
    };
    err.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {   // drained so the child never blocks; the server logs routes only
        if (!h.availableData.length) h.readabilityHandler = nil;
    };
    t.terminationHandler = ^(NSTask *done) {
        dispatch_async(dispatch_get_main_queue(), ^{ [w ended:done]; });
    };
    NSError *e = nil;
    if (![t launchAndReturnError:&e]) return [NSString stringWithFormat:L(@"The API server did not start: %@"), e.localizedDescription];
    _task = t;
    _toServer = in.fileHandleForWriting;
    _launchedAt = NSDate.date;
    NSMutableDictionary *cfg = [[self catalogPayload] mutableCopy];
    cfg[@"op"] = @"config";
    cfg[@"key_sha256"] = OVAPIKeySHA256([self currentKey]);
    cfg[@"uploads_dir"] = [OVPaths apiUploads];
    cfg[@"outputs_dir"] = [OVPaths apiOut];
    cfg[@"port"] = @(self.port);
    [self send:cfg];
    return nil;
}

- (BOOL)start:(NSString **)error {
    if (self.running) return YES;
    if (_task.running) [self stop];
    _wantRunning = YES;
    self.lastError = nil;
    NSString *fail = [self launch];
    if (!fail) {
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8];
        while (!_listening && !_startError && _task.running && deadline.timeIntervalSinceNow > 0)
            [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        if (!_listening) fail = _startError ?: L(@"The API server did not start.");
    }
    if (fail) {
        [self killTask];
        _wantRunning = NO;
        self.lastError = fail;
        if (error) *error = fail;
        [self changed];
        return NO;
    }
    [self afterStart];
    return YES;
}

- (void)afterStart {
    self.running = YES;
    self.lastError = nil;
    [self sweepFiles];
    _sweepTimer = [NSTimer scheduledTimerWithTimeInterval:600 repeats:YES block:^(NSTimer *t) { [self sweepFiles]; }];
    for (OVJob *j in OVJobs.shared.all) [self pushJob:j];
    [self changed];
}

- (void)killTask {
    NSTask *t = _task;
    t.terminationHandler = nil;
    ((NSPipe *)t.standardOutput).fileHandleForReading.readabilityHandler = nil;
    ((NSPipe *)t.standardError).fileHandleForReading.readabilityHandler = nil;
    if (t.running) {
        [self send:@{@"op": @"quit"}];
        [_toServer closeAndReturnError:nil];                 // EOF also ends the server
        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:1.5];
        while (t.running && until.timeIntervalSinceNow > 0) [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        if (t.running) {
            [t terminate];
            until = [NSDate dateWithTimeIntervalSinceNow:0.5];
            while (t.running && until.timeIntervalSinceNow > 0) [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        }
        if (t.running) kill(t.processIdentifier, SIGKILL);
    }
    [_toServer closeAndReturnError:nil];
    _task = nil; _toServer = nil; _listening = NO;
}

- (void)stop {
    _wantRunning = NO;
    [_sweepTimer invalidate]; _sweepTimer = nil;
    BOOL was = self.running;
    if (_task) [self killTask];
    [_lastSent removeAllObjects];
    if (was) { self.running = NO; [self changed]; }
}

/// The child quit on its own (not through stop).
- (void)ended:(NSTask *)t {
    if (t != _task) return;
    [self killTask];
    [_sweepTimer invalidate]; _sweepTimer = nil;
    BOOL was = self.running;
    self.running = NO;
    if (!_wantRunning) { if (was) [self changed]; return; }
    if (-_launchedAt.timeIntervalSinceNow > 60) _restarts = 0;
    if (_startError) return;                                 // start: is waiting and reports it
    if (_restarts >= kMaxRestarts) {
        _wantRunning = NO;
        self.lastError = L(@"The API server stopped unexpectedly. Switch it off and on again.");
        [self changed];
        return;
    }
    _restarts++;
    [self changed];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_restarts * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self->_wantRunning || self->_task) return;
        NSString *fail = [self launch];
        if (fail) { self->_wantRunning = NO; self.lastError = fail; [self changed]; }
    });
}

#pragma mark - Messages from the server

- (void)consume:(NSData *)d from:(NSTask *)t {
    if (t != _task) return;
    [_inBuf appendData:d];
    if (_inBuf.length > 4 * 1024 * 1024) { _inBuf = [NSMutableData data]; return; }   // a runaway line
    for (;;) {
        NSRange nl = [_inBuf rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, _inBuf.length)];
        if (nl.location == NSNotFound) break;
        NSData *line = [_inBuf subdataWithRange:NSMakeRange(0, nl.location)];
        [_inBuf replaceBytesInRange:NSMakeRange(0, nl.location + 1) withBytes:NULL length:0];
        id obj = line.length ? [NSJSONSerialization JSONObjectWithData:line options:0 error:nil] : nil;
        if ([obj isKindOfClass:NSDictionary.class]) [self handle:obj];
    }
}

- (void)handle:(NSDictionary *)m {
    NSString *op = [m[@"op"] isKindOfClass:NSString.class] ? m[@"op"] : @"";
    if ([op isEqualToString:@"listening"]) {
        _listening = YES;
    } else if ([op isEqualToString:@"error"]) {
        NSString *code = [m[@"code"] isKindOfClass:NSString.class] ? m[@"code"] : @"";
        NSString *text = [code isEqualToString:@"EADDRINUSE"] ? [NSString stringWithFormat:L(@"Port %u is in use. Pick another port."), self.port]
                                                              : L(@"The API server could not start.");
        if (!_listening) { _startError = text; return; }     // start: reports it
        self.lastError = text; [self changed];
    } else if ([op isEqualToString:@"submit"]) {
        [self handleSubmit:m];
    } else if ([op isEqualToString:@"stop"]) {
        NSString *jid = m[@"jobId"];
        OVJob *j = [jid isKindOfClass:NSString.class] ? [OVJobs.shared jobWithId:jid] : nil;
        if (j && [self isRemote:j] && j.active) [OVJobs.shared stop:j];
    } else if ([op isEqualToString:@"submit_abandoned"]) {
        OVJob *j = [m[@"reqId"] isKindOfClass:NSString.class] ? _byRequest[m[@"reqId"]] : nil;
        if (j && j.active) [OVJobs.shared stop:j];
    }
    // pair_request, device_seen: the Bridge (task 8.7)
}

- (BOOL)isRemote:(OVJob *)j { return [j.origin isEqualToString:@"api"] || [j.origin hasPrefix:@"bridge:"]; }

- (void)reply:(NSString *)reqId job:(NSString *)jobId error:(NSString *)err {
    if (err) [self send:@{@"op": @"rejected", @"reqId": reqId, @"error": err}];
    else [self send:@{@"op": @"submitted", @"reqId": reqId, @"jobId": jobId}];
}

#pragma mark - Catalog

- (NSSet<NSString *> *)voiceIds {
    NSMutableSet *s = [NSMutableSet set];
    for (OVVoice *v in OVVoices.shared.all) if (v.ready) [s addObject:v.identifier];
    return s;
}

/// RVC voice models: the .pth files in the RVC models folder, named by their stem.
- (NSArray<NSDictionary *> *)rvcModels {
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:[OVPaths rvcModels] error:nil]) {
        if (![n.pathExtension.lowercaseString isEqualToString:@"pth"] || [n hasPrefix:@"."]) continue;
        NSString *stem = n.stringByDeletingPathExtension;
        [a addObject:@{@"id": stem, @"name": stem}];
    }
    return a;
}

- (NSDictionary *)catalogPayload {
    NSMutableArray *voices = [NSMutableArray array];
    for (OVVoice *v in OVVoices.shared.all) {
        if (!v.ready) continue;
        [voices addObject:@{@"id": v.identifier, @"name": v.name ?: @"", @"language": v.language ?: NSNull.null, @"seconds": @(v.seconds)}];
    }
    NSMutableArray *tts = [NSMutableArray array];
    for (OVModel *m in [OVModels.shared modelsOfKind:OVModelTTS])
        if (m.installed) [tts addObject:@{@"id": m.repo, @"name": m.title ?: m.repo}];
    return @{@"voices": voices, @"models": @{@"tts": tts, @"rvc": [self rvcModels]}};
}

- (void)catalogChanged:(NSNotification *)n {
    if (!self.running || _catalogScheduled) return;
    _catalogScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_catalogScheduled = NO;
        if (!self.running) return;
        NSMutableDictionary *m = [[self catalogPayload] mutableCopy];
        m[@"op"] = @"catalog";
        [self send:m];
    });
}

#pragma mark - Submitting

- (void)handleSubmit:(NSDictionary *)m {
    NSString *reqId = m[@"reqId"], *kind = m[@"kind"], *origin = m[@"origin"];
    NSDictionary *params = m[@"params"];
    if (![reqId isKindOfClass:NSString.class] || !reqId.length) return;
    if (![kind isKindOfClass:NSString.class] || ![params isKindOfClass:NSDictionary.class] || ![origin isKindOfClass:NSString.class]
        || !([origin isEqualToString:@"api"] || [origin hasPrefix:@"bridge:"])) {
        [self reply:reqId job:nil error:@"rejected: bad request"];
        return;
    }
    if ([kind isEqualToString:@"synthesize"]) {
        NSString *err = nil;
        NSDictionary *req = [self synthRequest:params err:&err];
        [self finishSubmit:reqId kind:OVJobKindSynth request:req origin:origin error:err cleanup:nil];
    } else if ([kind isEqualToString:@"clone"]) {
        [self submitClone:params reqId:reqId origin:origin];
    } else if ([kind isEqualToString:@"convert"]) {
        NSString *err = nil;
        NSMutableSet *models = [NSMutableSet set];
        for (NSDictionary *r in [self rvcModels]) [models addObject:r[@"id"]];
        NSDictionary *n = OVAPINormalizeConvert(params, models, [self voiceIds], &err);
        NSMutableDictionary *req = nil;
        if (n) {
            NSString *up = OVAPIUploadPath(n[@"uploadId"]);
            if (!up || ![NSFileManager.defaultManager fileExistsAtPath:up]) err = @"rejected: unknown upload";
            else {
                req = [n mutableCopy];
                [req removeObjectForKey:@"uploadId"];
                req[@"input"] = up;
                req[@"out"] = OVAPIOutputPath(NSUUID.UUID.UUIDString.lowercaseString, @"wav");
                req[@"_uploadId"] = n[@"uploadId"];
                req[@"_apiFormat"] = @"wav";
            }
        }
        [self finishSubmit:reqId kind:OVJobKindConvert request:req origin:origin error:err cleanup:nil];
    } else {
        [self reply:reqId job:nil error:@"rejected: unknown kind"];
    }
}

- (void)finishSubmit:(NSString *)reqId kind:(NSString *)kind request:(NSDictionary *)req origin:(NSString *)origin
               error:(NSString *)err cleanup:(void (^)(void))cleanup {
    if (!req) { if (cleanup) cleanup(); [self reply:reqId job:nil error:err ?: @"rejected"]; return; }
    NSString *jerr = nil;
    OVJob *job = [OVJobs.shared submitKind:kind request:req origin:origin onFinish:^(OVJob *j) { [self jobFinished:j]; } error:&jerr];
    if (!job) {
        if (cleanup) cleanup();
        BOOL unavailable = [kind isEqualToString:OVJobKindConvert];     // its kind is registered by the conversion engine (sub-plan C)
        [self reply:reqId job:nil error:unavailable ? @"rejected: not available" : [@"rejected: " stringByAppendingString:jerr ?: @"queue is full"]];
        return;
    }
    _byRequest[reqId] = job;
    if (_byRequest.count > 64) [_byRequest removeObjectForKey:_byRequest.allKeys.firstObject];
    [self reply:reqId job:job.identifier error:nil];
    [self pushJob:job];
}

- (NSDictionary *)synthRequest:(NSDictionary *)params err:(NSString **)err {
    NSArray *moodIds = [[OVSettings moods] valueForKey:@"id"];
    NSDictionary *n = OVAPINormalizeSynth(params, [self voiceIds], moodIds, err);
    if (!n) return nil;
    NSDictionary *spec = [OVSettings modelSpec];
    if (!spec) { *err = @"rejected: engine_not_ready: finish Setup in Clone'n'Speak first"; return nil; }
    NSString *text = n[@"text"];
    NSString *language = n[@"language"] ?: [OVLocale speechLanguageForText:text];
    NSMutableDictionary *p = [[OVSettings generationParams] mutableCopy];
    NSDictionary *neutral = [OVSettings moods].firstObject;
    NSDictionary *mood = neutral;
    for (NSDictionary *md in [OVSettings moods]) if ([md[@"id"] isEqualToString:n[@"mood"]]) mood = md;
    p[@"style"] = @{@"intonation": mood[@"styleIntonation"] ?: @0, @"energy": mood[@"styleEnergy"] ?: @0, @"pitch": mood[@"stylePitch"] ?: @0,
                    @"tone": mood[@"styleTone"] ?: @0, @"pauses": mood[@"stylePauses"] ?: @1, @"volume": @0};   // the same whatever the Speech page shows
    if (n[@"speed"]) p[@"speed"] = n[@"speed"];
    NSString *out = OVAPIOutputPath(NSUUID.UUID.UUIDString.lowercaseString, @"wav");
    NSMutableDictionary *req = [@{@"cmd": @"synth", @"model": spec, @"text": text, @"out": out, @"language": language, @"params": p,
                                  @"_apiFormat": n[@"format"]} mutableCopy];
    if (n[@"voiceId"]) {
        OVVoice *v = [OVVoices.shared voiceWithId:n[@"voiceId"]];
        if (!v || !v.ready) { *err = @"rejected: unknown voice"; return nil; }
        req[@"voice"] = [v workerSpecForLanguage:language];
        req[@"_voiceId"] = v.identifier;
        if ([v adaptsToLanguage:language] && OVModels.shared.asrModel.localPath) req[@"asr_path"] = OVModels.shared.asrModel.localPath;
    }
    return req;
}

- (void)submitClone:(NSDictionary *)params reqId:(NSString *)reqId origin:(NSString *)origin {
    NSString *err = nil;
    NSDictionary *n = OVAPINormalizeClone(params, &err);
    NSDictionary *spec = n ? [OVSettings modelSpec] : nil;
    if (n && !spec) err = @"rejected: engine_not_ready: finish Setup in Clone'n'Speak first";
    NSString *up = n ? OVAPIUploadPath(n[@"uploadId"]) : nil;
    if (n && spec && (!up || ![NSFileManager.defaultManager fileExistsAtPath:up])) err = @"rejected: unknown upload";
    NSString *refText = n[@"ref_text"] ?: @"";
    OVModel *asr = OVModels.shared.asrModel;
    if (n && spec && up && !refText.length && !asr.localPath) err = @"rejected: send ref_text (Whisper is not installed to transcribe the sample)";
    if (!n || !spec || !up || (!refText.length && !asr.localPath) || ![NSFileManager.defaultManager fileExistsAtPath:up]) {
        [self reply:reqId job:nil error:err ?: @"rejected"];
        return;
    }
    // the upload becomes the voice's sample (24 kHz mono WAV): off the main thread, it may be minutes of audio
    OVVoice *v = [OVVoices.shared createNamed:n[@"name"]];
    NSString *vid = v.identifier, *folder = v.folder, *ref = v.referencePath, *prompt = v.promptPath;
    NSString *lang = n[@"language"];
    v.refText = refText;
    v.languageAuto = lang == nil;
    if (lang) v.language = lang;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *e = nil;
        double secs = 0;
        BOOL ok = OVConvertToWav(up, ref, &secs, &e);
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSFileManager.defaultManager removeItemAtPath:up error:nil];            // the sample is a copy now
            void (^discard)(void) = ^{ [NSFileManager.defaultManager removeItemAtPath:folder error:nil]; [OVVoices.shared reload]; };
            if (!ok) { discard(); [self reply:reqId job:nil error:@"rejected: the audio cannot be read"]; return; }
            OVVoice *vv = [OVVoices.shared voiceWithId:vid] ?: v;
            vv.seconds = secs;
            [vv save];                                                               // reload: the voice now exists on disk
            NSMutableDictionary *req = [@{@"cmd": @"clone", @"model": spec, @"audio": ref, @"ref_text": refText, @"out": prompt,
                                          @"language": lang ?: @"auto", @"_voiceId": vid, @"_apiName": n[@"name"]} mutableCopy];
            if (asr.localPath) req[@"asr_path"] = asr.localPath;
            [self finishSubmit:reqId kind:@"clone" request:req origin:origin error:nil cleanup:discard];
        });
    });
}

#pragma mark - Finished jobs

- (void)jobFinished:(OVJob *)j {
    NSString *vid = j.request[@"_voiceId"];
    if ([j.kind isEqualToString:@"clone"]) {
        if (j.state == OVJobSucceeded) [self completeClone:j];
        else if (vid.length) {                                                       // nothing usable came out: remove the half-made voice
            OVVoice *v = [OVVoices.shared voiceWithId:vid];
            if (v) { [NSFileManager.defaultManager removeItemAtPath:v.folder error:nil]; [OVVoices.shared reload]; }
        }
    }
    NSString *uid = j.request[@"_uploadId"];
    NSString *up = [uid isKindOfClass:NSString.class] ? OVAPIUploadPath(uid) : nil;
    if (up) [NSFileManager.defaultManager removeItemAtPath:up error:nil];
    if ([j.kind isEqualToString:OVJobKindSynth] && j.state == OVJobSucceeded) {
        NSString *fmt = j.request[@"_apiFormat"];
        NSString *wav = j.request[@"out"];
        if ([fmt isKindOfClass:NSString.class] && ![fmt isEqualToString:@"wav"] && [wav isKindOfClass:NSString.class] && OVAPIPathIsInsideOut(wav)) {
            [self encode:j wav:wav format:fmt];
            return;
        }
    }
    [self pushJob:j];
}

- (void)completeClone:(OVJob *)j {
    OVVoice *v = [OVVoices.shared voiceWithId:j.request[@"_voiceId"]];
    NSDictionary *data = j.result ?: @{};
    if (!v) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *trimmed = [data[@"trimmed"] isKindOfClass:NSString.class] ? data[@"trimmed"] : nil;
    if (trimmed.length && [fm fileExistsAtPath:trimmed]) {                           // a long sample was cut to its best seconds
        NSString *orig = [v.folder stringByAppendingPathComponent:@"reference.orig.wav"];
        if (![fm fileExistsAtPath:orig]) [fm moveItemAtPath:v.referencePath toPath:orig error:nil];
        [fm removeItemAtPath:v.referencePath error:nil];
        [fm moveItemAtPath:trimmed toPath:v.referencePath error:nil];
    }
    if ([data[@"ref_text"] isKindOfClass:NSString.class]) v.refText = data[@"ref_text"];
    if ([data[@"seconds"] doubleValue] > 0) v.seconds = [data[@"seconds"] doubleValue];
    if (v.languageAuto && [data[@"language"] isKindOfClass:NSString.class]) v.language = data[@"language"];
    if ([data[@"accent"] isKindOfClass:NSDictionary.class]) v.accented = [data[@"accent"][@"accented"] boolValue];
    [v save];
}

- (void)encode:(OVJob *)j wav:(NSString *)wav format:(NSString *)fmt {
    NSString *jid = j.identifier;
    [_encoding addObject:jid];
    NSString *stem = [wav stringByDeletingPathExtension];
    OVExportFormat f = [OVExport formatForIdentifier:fmt];
    [self pushJob:j];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *res = [OVExport exportFile:wav to:stem format:f quality:-1 error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (res) [NSFileManager.defaultManager removeItemAtPath:wav error:nil];   // else the WAV stays and is served
            [self->_encoding removeObject:jid];
            [self pushJob:j];
        });
    });
}

#pragma mark - Job snapshots for the server

- (NSDictionary *)outputOfJob:(OVJob *)j {
    NSString *wav = [j.request[@"out"] isKindOfClass:NSString.class] ? j.request[@"out"] : nil;
    if (!wav) return nil;
    NSString *stem = wav.lastPathComponent.stringByDeletingPathExtension;
    NSString *want = [j.request[@"_apiFormat"] isKindOfClass:NSString.class] ? j.request[@"_apiFormat"] : @"wav";
    for (NSString *ext in @[want, @"wav"]) {
        NSString *p = OVAPIOutputPath(stem, ext);
        if (!p || !OVAPIPathIsInsideOut(p) || ![NSFileManager.defaultManager fileExistsAtPath:p]) continue;
        NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:p error:nil];
        return @{@"name": [@"speech." stringByAppendingString:ext], @"bytes": a[NSFileSize] ?: @0,
                 @"type": OVAPIMimeTypeForExtension(ext), @"path": p};
    }
    return nil;
}

- (NSDictionary *)snapshotOfJob:(OVJob *)j {
    NSString *state;
    switch (j.state) {
        case OVJobQueued: state = @"queued"; break;
        case OVJobRunning: state = @"running"; break;
        case OVJobSucceeded: state = [_encoding containsObject:j.identifier] ? @"running" : @"succeeded"; break;
        case OVJobFailed: state = @"failed"; break;
        case OVJobStopped: state = @"stopped"; break;
        case OVJobInterrupted: state = @"failed"; break;
    }
    BOOL done = j.state == OVJobSucceeded && ![_encoding containsObject:j.identifier];
    NSString *kind = [j.kind isEqualToString:OVJobKindSynth] ? @"synthesize" : j.kind;
    NSMutableDictionary *s = [@{@"id": j.identifier, @"kind": kind, @"state": state, @"origin": j.origin,
                                @"progress": j.progress >= 0 ? @(MIN(1.0, j.progress)) : NSNull.null,
                                @"status": j.status ?: @""} mutableCopy];
    if (j.error.length) s[@"error"] = j.error;
    if (done && [j.kind isEqualToString:OVJobKindSynth]) { NSDictionary *o = [self outputOfJob:j]; if (o) s[@"output"] = o; }
    return s;
}

- (void)pushJob:(OVJob *)j {
    if (!self.running || ![self isRemote:j]) return;
    NSDictionary *snap = [self snapshotOfJob:j];
    NSData *d = [NSJSONSerialization dataWithJSONObject:snap options:NSJSONWritingSortedKeys error:nil];
    NSString *json = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
    if (!json || [_lastSent[j.identifier] isEqualToString:json]) return;
    _lastSent[j.identifier] = json;
    [self send:@{@"op": @"job", @"job": snap}];
}

- (void)jobsChanged:(NSNotification *)n {
    OVJob *j = [n.object isKindOfClass:OVJob.class] ? n.object : nil;
    if (j) [self pushJob:j];
    NSUInteger count = OVJobs.shared.all.count;
    BOOL shrank = count < _lastJobCount;
    _lastJobCount = count;
    if (!self.running) return;
    if (!j) for (OVJob *x in OVJobs.shared.all) [self pushJob:x];
    if (shrank) [self sweepFiles];
}

- (NSArray *)recentJobs:(NSUInteger)limit {
    NSMutableArray *a = [NSMutableArray array];
    for (OVJob *j in OVJobs.shared.all) {
        if (![j.origin isEqualToString:@"api"]) continue;
        [a addObject:j];
        if (a.count >= limit) break;
    }
    return a;
}

#pragma mark - Housekeeping

/// Uploads older than an hour go; so does API audio whose job has been deleted.
- (void)sweepFiles {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *ups = [OVPaths apiUploads];
    for (NSString *n in [fm contentsOfDirectoryAtPath:ups error:nil]) {
        NSString *p = [ups stringByAppendingPathComponent:n];
        NSDate *mod = [fm attributesOfItemAtPath:p error:nil].fileModificationDate;
        if (mod && -mod.timeIntervalSinceNow > kUploadTTL) [fm removeItemAtPath:p error:nil];
    }
    NSMutableSet *keep = [NSMutableSet set];
    for (OVJob *j in OVJobs.shared.all) {
        NSString *o = [j.request[@"out"] isKindOfClass:NSString.class] ? j.request[@"out"] : nil;
        if (o && [self isRemote:j]) [keep addObject:o.lastPathComponent.stringByDeletingPathExtension];
    }
    NSString *out = [OVPaths apiOut];
    for (NSString *n in [fm contentsOfDirectoryAtPath:out error:nil]) {
        if ([n hasPrefix:@"."] || [keep containsObject:n.stringByDeletingPathExtension]) continue;
        NSString *p = [out stringByAppendingPathComponent:n];
        if (OVAPIPathIsInsideOut(p)) [fm removeItemAtPath:p error:nil];
    }
}

@end
