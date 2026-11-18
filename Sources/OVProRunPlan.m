#import "OVProRunPlan.h"

@implementation OVProRunPlan {
    unsigned long long _peak, _reduced;
}

+ (unsigned long long)needForPeak:(unsigned long long)peak { return (unsigned long long)((double)peak * 1.15); }

+ (instancetype)planWithPeakBytes:(unsigned long long)peak reducedPeakBytes:(unsigned long long)reduced
                     needsNetwork:(BOOL)net heavy:(BOOL)heavy {
    OVProRunPlan *p = [OVProRunPlan new];
    p->_peak = peak; p->_reduced = reduced; p->_needsNetwork = net; p->_heavy = heavy;
    return p;
}

/// The memory question for `avail` bytes of room. YES = go on; *reduced = with the lighter variant. When neither
/// variant fits the user is asked about the lighter one (if there is one), unless they already agreed.
- (BOOL)memoryOK:(unsigned long long)avail host:(id<OVProRunHost>)host reduced:(BOOL *)reduced {
    *reduced = NO;
    if (_peak == 0) return YES;
    unsigned long long need = [OVProRunPlan needForPeak:_peak];
    if (avail >= need) return YES;
    if (_reduced > 0) {
        unsigned long long needLight = [OVProRunPlan needForPeak:_reduced];
        *reduced = YES;
        if (avail >= needLight) return YES;
        need = needLight;
    }
    if (self.lowFreeAccepted) return YES;
    if (![host askLowFreeNeed:need available:avail]) { *reduced = NO; return NO; }
    self.lowFreeAccepted = YES;
    return YES;
}

- (void)executeWithHost:(id<OVProRunHost>)host completion:(void (^)(OVProRunOutcome, BOOL))done {
    void (^afterNetwork)(void) = ^{
        BOOL reduced = NO;
        if (self->_heavy) {
            if ([host physicalMemoryGB] < 16 && ![host confirmLowMemory]) { done(OVProRunDeclined, NO); return; }
            if (![self memoryOK:[host availableBytes] + [host reclaimableBytes] host:host reduced:&reduced]) {
                done(OVProRunDeclined, NO);   // nothing was unloaded
                return;
            }
            [host unloadMainModels];
            if (![self memoryOK:[host availableBytes] host:host reduced:&reduced]) { done(OVProRunDeclined, NO); return; }
        }
        [host submitReducedBatch:reduced];
        done(OVProRunSubmitted, reduced);
    };
    if (_needsNetwork) {
        [host requestNetwork:^(BOOL allowed) {
            if (!allowed) { done(OVProRunDeclined, NO); return; }
            afterNetwork();
        }];
    } else {
        afterNetwork();
    }
}

- (BOOL)prepareToStartWithHost:(id<OVProRunHost>)host reduced:(BOOL *)reduced {
    *reduced = NO;
    if (!_heavy) return YES;
    [host unloadMainModels];
    return [self memoryOK:[host availableBytes] host:host reduced:reduced];
}
@end
