// App side of the job manager: the OVWorker runner and the app's own kinds. Not part of the Foundation-only test build.
#import "OVJobs.h"
#import "OVWorker.h"
#import "OVStore.h"
#import "OVLocale.h"

@interface OVWorkerJobRunner : NSObject <OVJobRunner>
@end

@implementation OVWorkerJobRunner {
    OVJobContext *_ctx;
    NSDictionary *_request;
    id _observer;
    BOOL _started, _finished;
}

- (void)start:(OVJob *)job context:(OVJobContext *)ctx {
    _ctx = ctx;
    NSMutableDictionary *req = [NSMutableDictionary dictionary];
    [job.runnerRequest enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) {
        if (![k hasPrefix:@"_"]) req[k] = v;   // underscore keys are notes for the app (for instance _voiceId)
    }];
    _request = req;
    if (![_request[@"cmd"] isKindOfClass:NSString.class]) { [self fail:L(@"The task has no command.")]; return; }
    if (OVWorker.shared.busy) {
        [ctx setStatus:L(@"Waiting for the engine…")];
        __weak typeof(self) w = self;
        _observer = [NSNotificationCenter.defaultCenter addObserverForName:OVWorkerDidChangeNotification object:nil
                                                                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { [w tryStart]; }];
        return;
    }
    [self tryStart];
}

- (void)tryStart {
    if (_started || _finished || _ctx.stopRequested) return;
    if (OVWorker.shared.busy) return;
    _started = YES;
    [self stopObserving];
    OVJobContext *ctx = _ctx;
    [ctx setStatus:L(@"Starting the engine…")];
    [OVWorker.shared request:_request status:^(NSString *msg) { [ctx setStatus:msg]; }
                    progress:^(double v) { [ctx setProgress:v]; }
                        done:^(NSDictionary *data, NSString *error) {
        if (self->_finished) return;
        if (ctx.stopRequested) { [self fail:@"Stopped"]; return; }
        if (error) { [self fail:error code:OVWorker.shared.lastErrorCode]; return; }
        NSMutableArray *outs = [NSMutableArray array];
        if ([data[@"path"] isKindOfClass:NSString.class]) [outs addObject:data[@"path"]];
        if ([data[@"outputs"] isKindOfClass:NSArray.class])
            for (id o in data[@"outputs"]) if ([o isKindOfClass:NSString.class] && ![outs containsObject:o]) [outs addObject:o];
        self->_finished = YES;
        [ctx succeedWithResult:data outputs:outs];
    }];
}

- (void)fail:(NSString *)message { [self fail:message code:nil]; }
- (void)fail:(NSString *)message code:(NSString *)code {
    if (_finished) return;
    _finished = YES;
    [self stopObserving];
    [_ctx failWithError:message code:code];
}

- (void)stopObserving {
    if (_observer) [NSNotificationCenter.defaultCenter removeObserver:_observer];
    _observer = nil;
}

- (void)stop:(OVJob *)job {
    if (!_started) { [self fail:@"Stopped"]; return; }   // still waiting for the engine: nothing to kill
    [OVWorker.shared stop];                              // its done block answers "Stopped" → Stopped
}
@end

OVJobRunnerFactory OVWorkerRunnerFactory(void) {
    return ^id<OVJobRunner>(OVJob *job) { return [OVWorkerJobRunner new]; };
}

static NSString *OVShortText(NSDictionary *r, NSString *fmt) {
    NSString *t = [r[@"text"] isKindOfClass:NSString.class] ? r[@"text"] : @"";
    t = [[t stringByReplacingOccurrencesOfString:@"\n" withString:@" "] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (t.length > 48) t = [[t substringToIndex:48] stringByAppendingString:@"…"];
    return [NSString stringWithFormat:fmt, t];
}

@implementation OVJobs (Builtin)
+ (void)registerBuiltinKinds {
    OVJobs *jobs = OVJobs.shared;
    [jobs registerKind:OVJobKindSynth lane:OVJobLaneCompute retryable:YES
                 title:^NSString *(NSDictionary *r) { return OVShortText(r, L(@"Speech: %@")); }
               factory:OVWorkerRunnerFactory()
             onSuccess:^(OVJob *job) {
        if ([job.origin isEqualToString:@"app"]) [[OVHistory shared] recordJob:job];
    }];
    [jobs registerKind:@"clone" lane:OVJobLaneCompute retryable:YES
                 title:^NSString *(NSDictionary *r) { return L(@"Voice cloning"); }
               factory:OVWorkerRunnerFactory() onSuccess:nil];
    [jobs registerKind:OVJobKindTrain lane:OVJobLaneCompute retryable:YES
                 title:^NSString *(NSDictionary *r) {
        NSString *v = [r[@"voice"] isKindOfClass:NSDictionary.class] ? r[@"voice"][@"name"] : nil;
        return v.length ? [NSString stringWithFormat:L(@"Training: %@"), v] : L(@"Voice training");
    } factory:OVWorkerRunnerFactory() onSuccess:^(OVJob *job) { [[OVVoices shared] reload]; }];   // the voice learned the language, also when the sheet is closed
    [jobs registerKind:OVJobKindSeparate lane:OVJobLaneCompute retryable:YES
                 title:^NSString *(NSDictionary *r) {
        NSString *n = [r[@"_name"] isKindOfClass:NSString.class] ? r[@"_name"] : @"";
        return n.length ? [NSString stringWithFormat:L(@"Remove music: %@"), n] : L(@"Remove music");
    } factory:OVWorkerRunnerFactory() onSuccess:nil];
    [jobs registerKind:@"tool" lane:OVJobLaneCompute retryable:NO   // Audio Tools: effects, formant / pitch, cleanup
                 title:^NSString *(NSDictionary *r) {
        NSString *n = [r[@"_name"] isKindOfClass:NSString.class] ? r[@"_name"] : @"";
        return n.length ? [NSString stringWithFormat:L(@"Audio tools: %@"), n] : L(@"Audio tools");
    } factory:OVWorkerRunnerFactory() onSuccess:nil];
    [jobs registerKind:OVJobKindInstall lane:OVJobLaneNetwork retryable:YES
                 title:^NSString *(NSDictionary *r) { return L(@"Installing components"); }
               factory:OVWorkerRunnerFactory() onSuccess:nil];
}
@end
