#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// The one list of pages: the sidebar, the Go menu, ⌘1… shortcuts, the content container and the snapshot run all read it.
@interface OVPageRegistry : NSObject
/// Sidebar groups in order: @[@{@"title": L(@"VOICE"), @"pages": @[@{@"id", @"title", @"symbol", @"class", @"pro": @NO}]}]
+ (NSArray<NSDictionary *> *)groups;
/// Pages that are routable but not in the sidebar (log, gallery).
+ (NSArray<NSDictionary *> *)hiddenPages;
/// Entry (same keys as in `groups`) for any page, visible or hidden.
+ (nullable NSDictionary *)entryForPage:(NSString *)pageId;
/// Every page id, sidebar order first, then the hidden ones.
+ (NSArray<NSString *> *)allPageIds;
+ (nullable Class)classForPage:(NSString *)pageId;
@end

NS_ASSUME_NONNULL_END
