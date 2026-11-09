// App side of batch speech: the typed bridge between the runner (OVBatch.m) and the app's classes. Not part of the
// Foundation-only test build.
#import "OVBatchEnv.h"
#import "OVStore.h"
#import "OVWorker.h"
#import "OVPaths.h"
#import "OVLocale.h"

/// Speaks one item through the shared worker (the model stays loaded between items).
@interface OVBatchWorkerSynth : NSObject <OVBatchSynth>
@end
@implementation OVBatchWorkerSynth {
    BOOL _cancelled, _issued;
    void (^_waitingDone)(NSDictionary *, NSString *);
}
- (void)synthesize:(NSDictionary *)req progress:(void (^)(double))progress done:(void (^)(NSDictionary *, NSString *))done {
    if (_cancelled) { done(nil, @"Stopped"); return; }
    if (OVWorker.shared.busy) {   // a page is using the engine: wait for it, never interrupt it
        _waitingDone = done;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!self->_waitingDone) return;   // cancelled meanwhile
            self->_waitingDone = nil;
            [self synthesize:req progress:progress done:done];
        });
        return;
    }
    _issued = YES;
    [OVWorker.shared request:req status:nil progress:progress done:^(NSDictionary *data, NSString *error) {
        self->_issued = NO;
        done(data, error);
    }];
}
- (void)stop {
    _cancelled = YES;
    if (_issued) { [OVWorker.shared stop]; return; }          // our own request is running: kill it
    void (^w)(NSDictionary *, NSString *) = _waitingDone;     // still waiting for the engine: just give up
    _waitingDone = nil;
    if (w) w(nil, @"Stopped");
}
@end

@implementation OVBatchAppEnvironment

- (NSDictionary *)modelSpec { return [OVSettings modelSpec]; }
- (NSDictionary *)generationParams { return [OVSettings generationParams]; }

- (NSDictionary *)voiceSpecForId:(NSString *)voiceId language:(NSString *)language {
    OVVoice *v = [[OVVoices shared] voiceWithId:voiceId];
    return v.ready ? [v workerSpecForLanguage:language] : nil;
}

- (NSString *)identifierOfVoice:(OVVoice *)voice { return voice.identifier; }

/// OVPresets arrives with task 6.14; until then (or if it changes shape) there are simply no presets.
- (id)presetsStore {
    Class c = NSClassFromString(@"OVPresets");
    return [c respondsToSelector:@selector(shared)] ? [c performSelector:@selector(shared)] : nil;
}

- (NSArray<NSDictionary *> *)presetChoices {
    NSMutableArray *out = [NSMutableArray array];
    id all = [[self presetsStore] valueForKey:@"all"];
    if (![all isKindOfClass:NSArray.class]) return out;
    for (id p in all) {
        NSString *name = [p valueForKey:@"name"];
        if ([name isKindOfClass:NSString.class]) [out addObject:@{@"title": name, @"preset": p}];
    }
    return out;
}

- (NSDictionary *)presetFields:(OVPreset *)preset {
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    for (NSString *k in @[@"identifier", @"style", @"formatId", @"quality", @"chain"]) {
        id v = nil;
        @try { v = [(id)preset valueForKey:k]; } @catch (NSException *e) { v = nil; }
        if (v) r[k] = v;
    }
    return r;
}

- (NSString *)historyFolder { return [OVPaths outputs]; }

- (void)recordHistoryPath:(NSString *)path text:(NSString *)text voiceId:(NSString *)voiceId result:(NSDictionary *)result {
    [[OVHistory shared] record:path text:text voice:voiceId ? [[OVVoices shared] voiceWithId:voiceId] : nil result:result];
}

- (id<OVBatchSynth>)makeSynth { return [OVBatchWorkerSynth new]; }
@end

void OVBatchRegister(void) { OVBatchRegisterOn(OVJobs.shared, [OVBatchAppEnvironment new]); }
