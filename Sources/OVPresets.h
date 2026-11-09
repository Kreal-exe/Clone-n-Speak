#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const OVPresetsDidChangeNotification;

/// One saved preset: style, export format, effect chain and formant shift. Maps to the cns_presets JSON schema.
@interface OVPreset : NSObject
@property (copy) NSString *identifier, *name;                 // identifier is the uuid in the file name
@property (copy) NSDictionary *style;
@property (copy, nullable) NSString *formatId;                // nil = the preset has no format (the app keeps the current one)
@property NSInteger quality;                                  // negative = default
@property (copy) NSArray<NSDictionary *> *chain;              // @[@{@"type", @"on", @"params"}]
@property double formant;                                     // 1.0 = off
/// The cns_presets schema: version, name, style, chain, formant, and format only when formatId is set.
- (NSDictionary *)json;
@end

/// Presets on disk: <support>/presets/<uuid>.json, one file per preset. Foundation only.
@interface OVPresets : NSObject
+ (instancetype)shared;
+ (instancetype)presetsWithRoot:(NSString *)root;             // for tests
@property (readonly) NSArray<OVPreset *> *all;                // by name
/// Test hook: replaces the worker call of importData (the request dictionary, then the worker's reply).
@property (copy, nullable) void (^validator)(NSDictionary *request, void (^done)(NSDictionary *_Nullable data, NSString *_Nullable error));
/// Saves a copy with a new identifier and returns it. An empty name is rejected (nil).
- (nullable OVPreset *)add:(OVPreset *)p;
/// An empty name is rejected (NO). The same name as another preset is allowed.
- (BOOL)rename:(OVPreset *)p to:(NSString *)name;
- (void)remove:(OVPreset *)p;
/// The same text as cns_presets.export_preset: sorted keys, 2-space indent, a trailing newline.
- (NSData *)exportData:(OVPreset *)p;
/// The worker validates (cmd preset_validate). The preset is NOT added: call -add: with it. A file over 64 KB is refused before the worker.
- (void)importData:(NSData *)data completion:(void (^)(OVPreset *_Nullable preset, NSArray<NSString *> *warnings, NSString *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
