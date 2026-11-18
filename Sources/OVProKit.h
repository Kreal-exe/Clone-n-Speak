#import <Cocoa/Cocoa.h>
#import "OVEngines.h"
#import "OVNetwork.h"

NS_ASSUME_NONNULL_BEGIN

/// The gate card of a pro feature: shown instead of the controls until every component is Ready.
///   "Convert needs its engine · 1.9 GB download · [Install]" → progress from the job → hidden when Ready, or the error
///   with "Try again"; Partial → "Finish installing"; Broken → "Repair". `onChange(ready)` fires when readiness changes
///   (after the first status is known); the card hides itself while ready, so put it into a stack.
NSView *OVEngineGateCard(NSString *feature, NSArray<NSString *> *componentIds, void (^_Nullable onChange)(BOOL ready));

@interface OVProKit : NSObject
/// Registers every pro job kind (the table of OVEngines) on OVJobs.shared, gives OVEngines its live memory host and
/// installs the OVWorker guard. Called once at launch, next to +[OVJobs registerBuiltinKinds].
+ (void)registerKinds;
@end

@interface OVProRun : NSObject
/// The one way to start a pro job from a page: 1 network (when the kind needs it), 2 the 16 GB confirmation, 3 unload the
/// main models, 4 memory (training tries batch size 2 first), 5 submit. `net`: the feature to ask for, or (OVNetFeature)-1 to
/// use the kind's own. completion (main thread): the job, or nil with an error text; nil job and nil error = the user declined.
+ (void)submitKind:(NSString *)kind request:(NSDictionary *)req feature:(NSString *)feature window:(nullable NSWindow *)w
           network:(OVNetFeature)net completion:(void (^)(OVJob *_Nullable job, NSString *_Nullable error))done;
@end

NS_ASSUME_NONNULL_END
