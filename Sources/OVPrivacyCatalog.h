#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What leaves this Mac and what is stored where. Data only: OVPrivacyPage shows it, OVNetwork takes its consent text from it.
/// Strings are localized when read (L()).
@interface OVPrivacyCatalog : NSObject
/// One entry per network feature behind the OVNetwork gate: @{@"id" (= OVNetwork identifierFor:), @"title", @"destination",
/// @"sends", @"when", @"consent": @YES/@NO}. consent NO = no consent sheet: the feature starts only from an explicit button.
+ (NSArray<NSDictionary *> *)networkEntries;
/// Every source file that may touch the network, and which feature it belongs to: @{@"file", @"feature" (an id of networkEntries,
/// or @"internal" for a listener or the gate itself, which send nothing out), @"note"}. tests/test_privacy_catalog.py compares it
/// with the allowlist in tests/test_network_allowlist.py.
+ (NSArray<NSDictionary *> *)networkSources;
/// What lies where: @{@"id", @"title", @"path", @"deletable": @YES/@NO, @"deleteNote"} for voices, outputs, history, logs, models,
/// engines, rvc, plugins, api, bridge.
+ (NSArray<NSDictionary *> *)locations;
+ (nullable NSDictionary *)entryForFeature:(NSString *)identifier;
@end

NS_ASSUME_NONNULL_END
