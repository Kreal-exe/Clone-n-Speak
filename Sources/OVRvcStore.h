#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted (main thread) after every scan of the voice-model folder.
extern NSNotificationName const OVRvcStoreDidChangeNotification;

/// One installed voice model: a folder <rvc/models>/<id>/ with <name>.pth, an optional <name>.index and meta.json
/// (written by cns_rvc.py import; its sha256 is what every conversion verifies, so the store never changes it).
@interface OVRvcModel : NSObject
@property (readonly, copy) NSString *identifier;       // folder name = the id cns_rvc.py uses
@property (readonly, copy) NSString *name;             // meta.json "name": what the user sees and can change
@property (readonly, copy) NSString *folder;           // absolute path of the model folder
@property (readonly, copy, nullable) NSString *pthPath, *indexPath;
@property (readonly, copy) NSString *version;          // "v2" (empty when unknown)
@property (readonly) NSInteger sampleRate;             // 40000; 0 when unknown
@property (readonly) BOOL pitch;                       // trained with pitch (f0)
@property (readonly) BOOL hasIndex;
@property (readonly) long long sizeBytes;              // .pth + .index on disk
@property (readonly, copy, nullable) NSString *sha256, *sourceURL;
@property (readonly) NSInteger epochs;                 // 0 when unknown
@end

/// The voice models on disk. Foundation only; main thread. A folder without a readable meta.json or without a .pth is
/// skipped (counted in skippedCount), never deleted.
@interface OVRvcStore : NSObject
+ (instancetype)shared;                                // <support>/rvc/models
+ (instancetype)storeWithRoot:(NSString *)root;        // tests
@property (readonly, copy) NSString *root;
@property (readonly, copy) NSArray<OVRvcModel *> *models;   // sorted by name, case-insensitive
@property (readonly) NSUInteger skippedCount;
- (void)rescan;
- (nullable OVRvcModel *)modelWithIdentifier:(NSString *)identifier;
/// Changes the name shown (meta.json "name" only): folder, files and checksum stay. A name another model already has
/// gets " 2", " 3" … Returns the final name, or nil with an error.
- (nullable NSString *)renameModel:(OVRvcModel *)model to:(NSString *)name error:(NSError *_Nullable *_Nullable)error;
/// Moves the model folder to the Trash (recoverable). Returns the path in the Trash, or nil with an error.
- (nullable NSString *)deleteModel:(OVRvcModel *)model error:(NSError *_Nullable *_Nullable)error;
/// `name` made unique among `used` (adds " 2", " 3"); the name itself when it is free.
+ (NSString *)uniqueName:(NSString *)name amongNames:(NSArray<NSString *> *)used;
/// 40000 -> "40 kHz".
+ (NSString *)kHzText:(NSInteger)sampleRate;
@end

NS_ASSUME_NONNULL_END
