#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// The effects-chain editor. Rows come from the worker's fx_catalog (read once, cached): a switch, the effect's name and a compact
/// slider (or popup / switch for choices) per parameter. Ranges and defaults are never written here, only read from the catalog.
/// The whole list sits in one OVDisclosure.
@interface OVEffectsView : NSView
/// @[@{@"type", @"on", @"params"}] in the order shown, one entry per row, including pitch and formant. Entries of the catalog that are
/// missing from a set chain are appended, off and at their defaults. Unknown types are dropped; values are clamped to the catalog.
@property (nonatomic, copy) NSArray<NSDictionary *> *chain;
/// After the user changed a switch, slider or popup, or reset (not after setting `chain`).
@property (nonatomic, copy, nullable) void (^onChange)(void);
/// Every effect off, every parameter at its default, in catalog order.
- (void)resetToDefaults;
/// The chain without the effects that are off: what the synth request carries.
@property (nonatomic, readonly) NSArray<NSDictionary *> *activeChain;

/// The cached catalog (the worker's "effects" array), or nil until it was read.
+ (nullable NSArray<NSDictionary *> *)catalog;
/// Test and snapshot hook: installs a catalog without asking the worker.
+ (void)setCatalog:(nullable NSArray<NSDictionary *> *)catalog;
@end

NS_ASSUME_NONNULL_END
