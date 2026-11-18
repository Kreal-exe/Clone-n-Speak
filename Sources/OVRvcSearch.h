#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One Hugging Face repository that holds a voice model (a .pth among its files).
@interface OVRvcSearchResult : NSObject
@property (readonly, copy) NSString *repo;               // "author/name"
@property (readonly) NSInteger downloads, likes;
@property (readonly, copy, nullable) NSString *license;  // from the repository's license: tag; nil = not stated
@property (readonly, copy) NSString *pthFile;            // the .pth the Download button takes (path inside the repository)
@property (readonly, copy, nullable) NSString *indexFile; // the .index next to it, if any
@property (readonly) NSUInteger pthCount;                // how many .pth files the repository holds
@end

/// Search of voice models on Hugging Face and the rules for model links. An explicit user action (a button or Return), so
/// it needs only the Offline-mode check of OVNetwork (feature model_download); the host is the one of the Hugging Face
/// address in Settings (https only), and nothing but the typed words is sent (no token, no cookies).
@interface OVRvcSearch : NSObject
/// The Hugging Face address from the settings, https only; nil when it is not https.
+ (nullable NSString *)endpoint;
/// <endpoint>/api/models?search=<q>&limit=20&full=true; nil for an empty query or an address that is not https.
+ (nullable NSURL *)searchURLForQuery:(NSString *)query;
/// Repositories of an API answer that have a .pth file (training checkpoints G_/D_ are not models), in the order given.
+ (NSArray<OVRvcSearchResult *> *)resultsFromJSON:(id)json;
/// <endpoint>/<repo>/resolve/main/<file>.
+ (nullable NSURL *)downloadURLForRepo:(NSString *)repo file:(NSString *)file;
/// The https link to pass to rvc_fetch for text the user typed: Hugging Face blob/ pages become resolve/, anything that
/// is not https is refused. nil + a text for the user when it can't be used (Google Drive and similar pages included).
+ (nullable NSString *)fetchLinkFromText:(NSString *)text error:(NSString *_Nullable *_Nullable)error;
/// Asks Hugging Face. completion (main thread): the results, or nil with a text for the user. In Offline mode nothing is sent.
+ (void)search:(NSString *)query completion:(void (^)(NSArray<OVRvcSearchResult *> *_Nullable results, NSString *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
