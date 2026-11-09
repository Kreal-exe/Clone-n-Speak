// Batch speech synthesis as an OVJobs kind. Foundation only: the app classes it talks to (OVWorker, OVSettings,
// OVVoices, OVHistory) are looked up at run time, so the runner is testable with OVJobs + OVJobStore alone.
#import "OVBatch.h"
#import "OVExport.h"
#import "OVLocale.h"
#import <objc/message.h>

#pragma mark - Request

NSDictionary *OVBatchRequest(NSArray<NSDictionary *> *items, OVVoice *voice, NSString *language, OVPreset *presetObject, NSString *outDir) {
    id v = voice, preset = presetObject;   // the classes live in other files (OVStore, OVPresets): read through KVC
    NSMutableArray *list = [NSMutableArray array];
    for (NSDictionary *it in items)
        [list addObject:@{@"index": it[@"index"] ?: @0, @"text": it[@"text"] ?: @"", @"name": it[@"name"] ?: @""}];
    NSString *voiceId = v ? [v valueForKey:@"identifier"] : nil;
    NSMutableDictionary *r = [@{@"items": list, @"voice": voiceId ?: NSNull.null, @"language": language.length ? language : @"auto",
                                @"style": @{}, @"preset": NSNull.null, @"format": @"wav", @"quality": @(-1),
                                @"outDir": outDir ?: @"", @"skipExisting": @NO} mutableCopy];
    if (preset) {
        r[@"preset"] = [preset valueForKey:@"identifier"] ?: NSNull.null;
        NSDictionary *style = [preset valueForKey:@"style"];
        if ([style isKindOfClass:NSDictionary.class]) r[@"style"] = style;
        NSString *fmt = [preset valueForKey:@"formatId"];
        if ([fmt isKindOfClass:NSString.class] && fmt.length) r[@"format"] = fmt;
        r[@"quality"] = [preset valueForKey:@"quality"] ?: @(-1);
        NSArray *chain = [preset valueForKey:@"chain"];
        if ([chain isKindOfClass:NSArray.class] && chain.count) r[@"chain"] = chain;
    }
    return r;
}

#pragma mark - Default synth (OVWorker)

static id Call0(id target, NSString *sel) {
    SEL s = NSSelectorFromString(sel);
    return [target respondsToSelector:s] ? ((id (*)(id, SEL))objc_msgSend)(target, s) : nil;
}
static id Call1(id target, NSString *sel, id arg) {
    SEL s = NSSelectorFromString(sel);
    return [target respondsToSelector:s] ? ((id (*)(id, SEL, id))objc_msgSend)(target, s, arg) : nil;
}

@interface OVBatchWorkerSynth : NSObject <OVBatchSynth>
@end
@implementation OVBatchWorkerSynth {
    BOOL _stopped;
}
- (void)synthesize:(NSDictionary *)req progress:(void (^)(double))progress done:(void (^)(NSDictionary *, NSString *))done {
    id worker = Call0(NSClassFromString(@"OVWorker"), @"shared");
    if (!worker) { done(nil, L(@"The speech engine is not available. Restart the app.")); return; }
    if (_stopped) { done(nil, @"Stopped"); return; }
    if ([[worker valueForKey:@"busy"] boolValue]) {   // a direct call of a page is running: wait for it
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self synthesize:req progress:progress done:done];
        });
        return;
    }
    ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(worker, NSSelectorFromString(@"request:status:progress:done:"),
                                                      req, nil, progress, done);
}
- (void)stop {
    _stopped = YES;
    Call0(Call0(NSClassFromString(@"OVWorker"), @"shared"), @"stop");
}
@end

/// The worker request for one item: model, voice and generation settings come from the app.
static NSDictionary *WorkerRequest(NSDictionary *batch, NSDictionary *item, NSString *out) {
    NSString *language = [batch[@"language"] isKindOfClass:NSString.class] ? batch[@"language"] : @"auto";
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    NSDictionary *gp = Call0(NSClassFromString(@"OVSettings"), @"generationParams");
    if ([gp isKindOfClass:NSDictionary.class]) [params addEntriesFromDictionary:gp];
    if ([batch[@"style"] isKindOfClass:NSDictionary.class] && [batch[@"style"] count]) params[@"style"] = batch[@"style"];
    NSMutableDictionary *req = [@{@"cmd": @"synth", @"text": item[@"text"] ?: @"", @"out": out,
                                  @"language": language, @"params": params} mutableCopy];
    id spec = Call0(NSClassFromString(@"OVSettings"), @"modelSpec");
    if (spec) req[@"model"] = spec;
    if ([batch[@"voice"] isKindOfClass:NSString.class]) {
        id voice = Call1(Call0(NSClassFromString(@"OVVoices"), @"shared"), @"voiceWithId:", batch[@"voice"]);
        id workerSpec = Call1(voice, @"workerSpecForLanguage:", [language isEqualToString:@"auto"] ? nil : language);
        if (workerSpec) req[@"voice"] = workerSpec;
    }
    if ([batch[@"chain"] isKindOfClass:NSArray.class]) req[@"chain"] = batch[@"chain"];
    return req;
}

/// Every finished item goes into the Speech history at once (when the app is there).
static void RecordHistory(NSDictionary *batch, NSDictionary *item, NSString *path, NSDictionary *data) {
    id history = Call0(NSClassFromString(@"OVHistory"), @"shared");
    SEL rec = NSSelectorFromString(@"record:text:voice:result:");
    if (!history || ![history respondsToSelector:rec]) return;
    id voice = nil;
    if ([batch[@"voice"] isKindOfClass:NSString.class])
        voice = Call1(Call0(NSClassFromString(@"OVVoices"), @"shared"), @"voiceWithId:", batch[@"voice"]);
    ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(history, rec, path, item[@"text"] ?: @"", voice, data ?: @{});
}

#pragma mark - Runner

@interface OVBatchRunner : NSObject <OVJobRunner>
- (instancetype)initWithSynth:(id<OVBatchSynth>)synth;
@end

@implementation OVBatchRunner {
    id<OVBatchSynth> _synth;
    OVJobContext *_ctx;
    NSDictionary *_req;
    NSArray *_items;
    NSString *_outDir, *_ext;
    OVExportFormat _format;
    NSInteger _quality, _next, _failed, _skipped;
    NSMutableArray *_outputs, *_errors;
    BOOL _finished, _skip;
}

- (instancetype)initWithSynth:(id<OVBatchSynth>)synth { if ((self = [super init])) _synth = synth; return self; }

- (void)start:(OVJob *)job context:(OVJobContext *)ctx {
    _ctx = ctx;
    _req = job.runnerRequest;
    _items = [_req[@"items"] isKindOfClass:NSArray.class] ? _req[@"items"] : @[];
    _outDir = [_req[@"outDir"] isKindOfClass:NSString.class] ? _req[@"outDir"] : @"";
    _skip = [_req[@"skipExisting"] boolValue];
    _format = [OVExport formatForIdentifier:[_req[@"format"] isKindOfClass:NSString.class] ? _req[@"format"] : @"wav"];
    _ext = @[@"wav", @"m4a", @"flac", @"m4a", @"mp3", @"ogg"][_format];
    _quality = [_req[@"quality"] respondsToSelector:@selector(integerValue)] ? [_req[@"quality"] integerValue] : -1;
    _outputs = [NSMutableArray array];
    _errors = [NSMutableArray array];
    if (!_items.count) { [self fail:L(@"There is nothing to speak. Add text or a file and start again.")]; return; }
    if (!_outDir.length) { [self fail:L(@"Choose a folder for the audio files and start again.")]; return; }
    NSError *e = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:_outDir withIntermediateDirectories:YES attributes:nil error:&e]) {
        [self fail:[NSString stringWithFormat:L(@"The folder could not be created (%@). Choose another folder."), e.localizedDescription]];
        return;
    }
    [NSFileManager.defaultManager createDirectoryAtPath:ctx.workDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    [self runNext];
}

- (void)fail:(NSString *)m {
    if (_finished) return;
    _finished = YES;
    [_ctx failWithError:m];
}

- (void)runNext {
    if (_finished) return;
    if (_ctx.stopRequested) { [self fail:@"Stopped"]; return; }
    if (_next >= (NSInteger)_items.count) { [self finish]; return; }
    NSInteger i = _next++, n = _items.count;
    NSDictionary *item = [_items[i] isKindOfClass:NSDictionary.class] ? _items[i] : @{};
    NSString *base = [([item[@"name"] isKindOfClass:NSString.class] ? item[@"name"] : @"") stringByDeletingPathExtension].lastPathComponent;
    if (!base.length) base = [NSString stringWithFormat:@"%03ld", (long)[item[@"index"] integerValue]];
    NSString *dst = [_outDir stringByAppendingPathComponent:[base stringByAppendingPathExtension:_ext]];
    if (_skip && [NSFileManager.defaultManager fileExistsAtPath:dst]) {
        _skipped++;
        [_ctx log:[NSString stringWithFormat:@"Item %@ skipped: %@ exists", item[@"index"], dst.lastPathComponent]];
        [_ctx setProgress:(double)(i + 1) / n];
        [self runNext];
        return;
    }
    [_ctx setStatus:[NSString stringWithFormat:L(@"Item %ld of %ld"), (long)i + 1, (long)n]];
    NSString *master = [_ctx.workDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"item-%ld.wav", (long)i + 1]];
    OVJobContext *ctx = _ctx;
    [_synth synthesize:WorkerRequest(_req, item, master) progress:^(double p) {
        [ctx setProgress:(i + MIN(1, MAX(0, p))) / n];
    } done:^(NSDictionary *data, NSString *error) {
        if (self->_finished) return;
        if (self->_ctx.stopRequested) { [self fail:@"Stopped"]; return; }
        if (error) { [self itemFailed:item error:error]; return; }
        NSString *wav = [data[@"path"] isKindOfClass:NSString.class] ? data[@"path"] : master;
        NSInteger q = self->_quality;
        OVExportFormat f = self->_format;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *ee = nil;
            NSString *final = [OVExport exportFile:wav to:dst format:f quality:q error:&ee];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self->_finished) return;
                if (!final) { [self itemFailed:item error:ee.localizedDescription ?: L(@"The file could not be saved.")]; return; }
                [self->_outputs addObject:final];
                [ctx setProgress:(double)(i + 1) / n];
                RecordHistory(self->_req, item, final, data);
                [self runNext];
            });
        });
    }];
}

- (void)itemFailed:(NSDictionary *)item error:(NSString *)error {
    _failed++;
    [_errors addObject:@{@"index": item[@"index"] ?: @0, @"error": error}];
    [_ctx log:[NSString stringWithFormat:@"Item %@ failed: %@", item[@"index"], error]];
    [self runNext];
}

- (void)finish {
    if (_finished) return;
    if (_outputs.count == 0 && _skipped == 0) {
        [self fail:[NSString stringWithFormat:L(@"No item could be spoken (%@). Check the text and the voice, then start again."),
                    _errors.firstObject[@"error"] ?: @""]];
        return;
    }
    _finished = YES;
    [_ctx succeedWithResult:@{@"done": @(_outputs.count), @"failed": @(_failed), @"skipped": @(_skipped),
                              @"outputs": _outputs, @"errors": _errors} outputs:_outputs];
}

/// Kills a synthesis in progress; between items (or while a file is exported) the loop sees stopRequested.
- (void)stop:(OVJob *)job { [_synth stop]; }
@end

#pragma mark - Registration

void OVBatchRegisterOn(OVJobs *jobs, id<OVBatchSynth> (^synthFactory)(void)) {
    [jobs registerKind:OVJobKindBatch lane:OVJobLaneCompute retryable:YES
                 title:^NSString *(NSDictionary *r) {
        NSUInteger n = [r[@"items"] isKindOfClass:NSArray.class] ? [r[@"items"] count] : 0;
        return [NSString stringWithFormat:L(@"Batch speech: %lu items"), (unsigned long)n];
    } factory:^id<OVJobRunner>(OVJob *job) {
        id<OVBatchSynth> s = synthFactory ? synthFactory() : nil;
        return [[OVBatchRunner alloc] initWithSynth:s ?: [OVBatchWorkerSynth new]];
    } onSuccess:nil];
}

void OVBatchRegister(void) { OVBatchRegisterOn(OVJobs.shared, nil); }
