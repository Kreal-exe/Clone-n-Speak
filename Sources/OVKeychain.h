#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Secrets live here and nowhere else: generic passwords under the service "Clone'n'Speak API", one item per account.
/// Never written to UserDefaults, files, the log or a notification.
@interface OVKeychain : NSObject
+ (nullable NSString *)secretForAccount:(NSString *)account;
/// Adds or replaces. NO when the Keychain refused (locked, access denied).
+ (BOOL)setSecret:(NSString *)secret forAccount:(NSString *)account;
+ (BOOL)deleteAccount:(NSString *)account;
@end

NS_ASSUME_NONNULL_END
