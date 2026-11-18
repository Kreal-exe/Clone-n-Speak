#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const OVNetworkModeDidChangeNotification;

typedef NS_ENUM(NSInteger, OVNetFeature) { OVNetEdgeTTS, OVNetYouTube, OVNetBridge, OVNetModelDownload, OVNetPluginNetwork };
typedef NS_ENUM(NSInteger, OVNetDecision) { OVNetAllowed, OVNetNeedsConsent, OVNetBlockedOffline };

/// The one gate for network features: Offline mode and first-use consent.
@interface OVNetwork : NSObject
@property (class, readonly) BOOL offline;                       // UserDefaults offlineMode, NO by default
+ (void)setOffline:(BOOL)offline;                               // posts OVNetworkModeDidChangeNotification; restarts an idle engine so its environment follows
+ (NSString *)identifierFor:(OVNetFeature)f;                    // @"edge_tts" @"youtube" @"bridge" @"model_download" @"plugin_network"
/// ModelDownload is always allowed (an explicit button). Others: BlockedOffline while offline, else NeedsConsent until agreed.
+ (OVNetDecision)decisionFor:(OVNetFeature)f;
+ (NSString *)blockedMessageFor:(OVNetFeature)f;
/// The only entry for network features: asks for consent (what goes where) and remembers it, or explains Offline mode with an "Open Settings" button.
+ (void)requestFeature:(OVNetFeature)f window:(nullable NSWindow *)w completion:(void (^)(BOOL allowed))completion;
+ (void)revokeConsentFor:(OVNetFeature)f;
/// Records an agreement the feature asked for itself (its own warning sheet); the same record requestFeature:window:completion: keeps.
+ (void)grantConsentFor:(OVNetFeature)f;
+ (BOOL)hasConsentFor:(OVNetFeature)f;
@end

NS_ASSUME_NONNULL_END
