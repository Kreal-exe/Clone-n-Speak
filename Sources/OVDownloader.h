#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Resumable single-file HTTP download: writes to `<dest>.part`, continues with a
/// Range request if the part file exists, renames to `dest` when complete.
@interface OVDownloader : NSObject
+ (instancetype)download:(NSURL *)url
                      to:(NSString *)dest
                 headers:(nullable NSDictionary<NSString *, NSString *> *)headers
                progress:(void (^)(long long received, long long total))progress
              completion:(void (^)(NSError *_Nullable error))completion;
/// Same, with an explicit partial-file path (e.g. HF cache `blobs/<etag>.incomplete`).
+ (instancetype)download:(NSURL *)url
                      to:(NSString *)dest
                    part:(nullable NSString *)part
                 headers:(nullable NSDictionary<NSString *, NSString *> *)headers
                progress:(void (^)(long long received, long long total))progress
              completion:(void (^)(NSError *_Nullable error))completion;
- (void)cancel;
@end

/// Small JSON GET helper (completion on main queue).
void OVFetchJSON(NSURL *url, NSDictionary<NSString *, NSString *> *_Nullable headers,
                 void (^completion)(id _Nullable json, NSError *_Nullable error));

NS_ASSUME_NONNULL_END
