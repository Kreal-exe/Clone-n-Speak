#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const OVModelsDidChangeNotification;

typedef NS_ENUM(NSInteger, OVModelKind) { OVModelTTS, OVModelASR, OVModelLoRA };

@interface OVModel : NSObject
@property (copy) NSString *repo;            // HuggingFace repo id
@property (copy) NSString *title;
@property (copy) NSString *details;
@property OVModelKind kind;
@property long long approxBytes;
@property BOOL recommended, custom;
@property BOOL catalog;                     // discovered on Hugging Face, not added yet
@property BOOL hidden;                      // dependency, not listed (audio tokenizer)
@property (copy) NSArray<NSString *> *languages;
@property NSInteger downloads;
@property (readonly) BOOL ukrainian;

// installation
@property (nullable, copy) NSString *localPath;     // snapshot folder usable by from_pretrained
@property (readonly) BOOL installed;

// download
@property BOOL downloading;
@property double progress;
@property long long received, total;
@property (nullable, copy) NSString *downloadStatus, *error;
@end

/// Models live in the standard Hugging Face hub cache (~/.cache/huggingface/hub),
/// in the same layout huggingface_hub / VoiceStudio use, so downloads are shared.
@interface OVModels : NSObject
+ (instancetype)shared;
+ (NSString *)hubCache;

@property (readonly) NSArray<OVModel *> *all;
- (NSArray<OVModel *> *)modelsOfKind:(OVModelKind)kind;         // listed (non-catalog, non-hidden)
- (NSArray<OVModel *> *)catalogOfKind:(OVModelKind)kind;        // discovered on HF
@property (readonly) BOOL catalogLoading;
@property (readonly, nullable) NSString *catalogError;
- (void)refreshCatalog;

/// Selected models (TTS/ASR fall back to the first installed one; LoRA may be none).
@property (nullable, readonly) OVModel *ttsModel, *asrModel, *loraModel;
/// Selected LoRA even while it is still downloading.
@property (nullable, readonly) OVModel *loraSelection;
- (void)select:(OVModel *)m;
- (void)selectLoRA:(nullable OVModel *)m;   // downloads it automatically if needed

- (void)rescan;
- (void)download:(OVModel *)m;
- (void)cancelDownload:(OVModel *)m;
- (BOOL)remove:(OVModel *)m error:(NSError **)error;
- (nullable OVModel *)addCustomRepo:(NSString *)repo kind:(OVModelKind)kind;
- (void)removeCustom:(OVModel *)m;
- (nullable OVModel *)modelForRepo:(NSString *)repo;

/// Calls `ready` once a Whisper model is installed, downloading the recommended one if needed.
- (void)whenASRReady:(void (^)(OVModel *_Nullable asr, NSString *_Nullable error))ready;
@end

NS_ASSUME_NONNULL_END
