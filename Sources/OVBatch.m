// Batch speech synthesis as an OVJobs kind. Foundation only: everything from the app (model, voices, history, the
// worker) comes through OVBatchEnvironment, so the runner is testable with OVJobs + OVJobStore + OVExport alone.
#import "OVBatch.h"
#import "OVExport.h"
#import "OVLocale.h"

static id<OVBatchEnvironment> gEnv;

#pragma mark - Request

NSDictionary *OVBatchRequest(NSArray<NSDictionary *> *items, OVVoice *voice, NSString *language, OVPreset *preset, NSString *outDir) {
    NSMutableArray *list = [NSMutableArray array];
    for (NSDictionary *it in items)
        [list addObject:@{@"index": it[@"index"] ?: @0, @"text": it[@"text"] ?: @"", @"name": it[@"name"] ?: @""}];
    NSString *voiceId = voice ? [gEnv identifierOfVoice:voice] : nil;
    NSMutableDictionary *r = [@{@"items": list, @"voice": voiceId ?: NSNull.null, @"language": language.length ? language : @"auto",
                                @"style": @{}, @"preset": NSNull.null, @"quality": @(-1),
                                @"outDir": outDir ?: @"", @"skipExisting": @NO} mutableCopy];
    if (preset) {
        NSDictionary *p = [gEnv presetFields:preset];
        if ([p[@"identifier"] isKindOfClass:NSString.class]) r[@"preset"] = p[@"identifier"];
        if ([p[@"style"] isKindOfClass:NSDictionary.class]) r[@"style"] = p[@"style"];
        NSString *fmt = [p[@"formatId"] isKindOfClass:NSString.class] ? p[@"formatId"] : nil;
        if (fmt.length) {
            r[@"format"] = fmt;
            NSInteger q = [p[@"quality"] respondsToSelector:@selector(integerValue)] ? [p[@"quality"] integerValue] : -1;
            // 0 is "unset" in a preset; for the kbps formats OVExport treats it as the default too
            r[@"quality"] = @(q <= 0 ? -1 : q);
        }
        if ([p[@"chain"] isKindOfClass:NSArray.class] && [p[@"chain"] count]) r[@"chain"] = p[@"chain"];
    }
    return r;
}

#pragma mark - Runner

@interface OVBatchRunner : NSObject <OVJobRunner>
- (instancetype)initWithEnvironment:(id<OVBatchEnvironment>)env;
@end

@implementation OVBatchRunner {
    id<OVBatchEnvironment> _env;
    id<OVBatchSynth> _synth;
    OVJobContext *_ctx;
    NSDictionary *_req, *_voiceSpec;
    NSArray *_items;
    NSString *_outDir, *_ext;
    OVExportFormat _format;
    NSInteger _quality, _next, _failed, _skipped;
    NSMutableArray *_outputs, *_errors, *_history;
    BOOL _finished, _skip, _inFlight, _recordHistory;
}

- (instancetype)initWithEnvironment:(id<OVBatchEnvironment>)env {
    if ((self = [super init])) { _env = env; _synth = [env makeSynth]; }
    return self;
}

- (void)start:(OVJob *)job context:(OVJobContext *)ctx {
    _ctx = ctx;
    _req = job.runnerRequest;
    _items = [_req[@"items"] isKindOfClass:NSArray.class] ? _req[@"items"] : @[];
    _outDir = [_req[@"outDir"] isKindOfClass:NSString.class] ? _req[@"outDir"] : @"";
    _skip = [_req[@"skipExisting"] boolValue];
    NSString *fmt = [_req[@"format"] isKindOfClass:NSString.class] ? _req[@"format"] : @"wav";
    _format = [OVExport formatForIdentifier:fmt];
    _ext = [OVExport formats][_format][@"ext"];
    _quality = [_req[@"quality"] respondsToSelector:@selector(integerValue)] ? [_req[@"quality"] integerValue] : -1;
    _outputs = [NSMutableArray array];
    _errors = [NSMutableArray array];
    _history = [NSMutableArray array];
    if (!_items.count) { [self fail:L(@"There is nothing to speak. Add text or a file and start again.")]; return; }
    if (!_outDir.length) { [self fail:L(@"Choose a folder for the audio files and start again.")]; return; }
    NSString *voiceId = [_req[@"voice"] isKindOfClass:NSString.class] ? _req[@"voice"] : nil;
    if (voiceId) {
        NSString *lang = [_req[@"language"] isKindOfClass:NSString.class] && ![_req[@"language"] isEqualToString:@"auto"] ? _req[@"language"] : nil;
        _voiceSpec = [_env voiceSpecForId:voiceId language:lang];
        if (!_voiceSpec) { [self fail:L(@"The voice is no longer available. Choose another voice and start again.")]; return; }
    }
    NSError *e = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:_outDir withIntermediateDirectories:YES attributes:nil error:&e]) {
        [self fail:[NSString stringWithFormat:L(@"The folder could not be created (%@). Choose another folder."), e.localizedDescription]];
        return;
    }
    NSString *hist = _env.historyFolder;
    _recordHistory = hist.length && [_ext isEqualToString:@"wav"] &&
        [_outDir.stringByStandardizingPath isEqualToString:hist.stringByStandardizingPath];
    [NSFileManager.defaultManager createDirectoryAtPath:ctx.workDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    [self runNext];
}

/// One exit for every outcome: the Speech history gets the finished files first (one pass, not one reload per item).
- (void)flushHistory {
    NSArray *entries = _history;
    _history = nil;
    for (NSDictionary *h in entries) [_env recordHistoryPath:h[@"path"] text:h[@"text"] voiceId:h[@"voice"] == NSNull.null ? nil : h[@"voice"] result:h[@"result"]];
}

- (void)fail:(NSString *)m {
    if (_finished) return;
    _finished = YES;
    [self flushHistory];
    [_ctx failWithError:m];
}

- (NSDictionary *)workerRequestFor:(NSDictionary *)item out:(NSString *)out {
    NSString *language = [_req[@"language"] isKindOfClass:NSString.class] ? _req[@"language"] : @"auto";
    NSMutableDictionary *params = [[_env generationParams] mutableCopy] ?: [NSMutableDictionary dictionary];
    if ([_req[@"style"] isKindOfClass:NSDictionary.class] && [_req[@"style"] count]) params[@"style"] = _req[@"style"];
    NSMutableDictionary *r = [@{@"cmd": @"synth", @"text": item[@"text"] ?: @"", @"out": out,
                                @"language": language, @"params": params} mutableCopy];
    NSDictionary *model = [_env modelSpec];
    if (model) r[@"model"] = model;
    if (_voiceSpec) r[@"voice"] = _voiceSpec;
    if ([_req[@"chain"] isKindOfClass:NSArray.class]) r[@"chain"] = _req[@"chain"];
    return r;
}

- (void)runNext {
    // skipped items are passed in a loop, not by recursion
    while (!_finished) {
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
            continue;
        }
        [self synthesizeItem:item at:i of:n to:dst];
        return;
    }
}

- (void)synthesizeItem:(NSDictionary *)item at:(NSInteger)i of:(NSInteger)n to:(NSString *)dst {
    [_ctx setStatus:[NSString stringWithFormat:L(@"Item %ld of %ld"), (long)i + 1, (long)n]];
    NSString *master = [_ctx.workDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"item-%ld.wav", (long)i + 1]];
    OVJobContext *ctx = _ctx;
    _inFlight = YES;
    [_synth synthesize:[self workerRequestFor:item out:master] progress:^(double p) {
        [ctx setProgress:(i + MIN(1, MAX(0, p))) / n];
    } done:^(NSDictionary *data, NSString *error) {
        self->_inFlight = NO;
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
                if (self->_recordHistory)
                    [self->_history addObject:@{@"path": final, @"text": item[@"text"] ?: @"",
                                                @"voice": [self->_req[@"voice"] isKindOfClass:NSString.class] ? self->_req[@"voice"] : NSNull.null,
                                                @"result": data ?: @{}}];
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
    [self flushHistory];
    [_ctx succeedWithResult:@{@"done": @(_outputs.count), @"failed": @(_failed), @"skipped": @(_skipped),
                              @"outputs": _outputs, @"errors": _errors} outputs:_outputs];
}

/// Only a synthesis of this batch is stopped; between items (or while a file is exported) the loop sees stopRequested,
/// and the worker, which may belong to the Speech page, is left alone.
- (void)stop:(OVJob *)job { if (_inFlight) [_synth stop]; }
@end

#pragma mark - Registration

void OVBatchRegisterOn(OVJobs *jobs, id<OVBatchEnvironment> env) {
    gEnv = env;
    [jobs registerKind:OVJobKindBatch lane:OVJobLaneCompute retryable:YES
                 title:^NSString *(NSDictionary *r) {
        NSUInteger n = [r[@"items"] isKindOfClass:NSArray.class] ? [r[@"items"] count] : 0;
        return [NSString stringWithFormat:L(@"Batch speech: %lu items"), (unsigned long)n];
    } factory:^id<OVJobRunner>(OVJob *job) {
        return [[OVBatchRunner alloc] initWithEnvironment:env];
    } onSuccess:nil];
}
