#import "OVKeychain.h"
#import <Security/Security.h>

static NSString *const kService = @"Clone'n'Speak API";

static NSMutableDictionary *Query(NSString *account) {
    return [@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService: kService,
              (__bridge id)kSecAttrAccount: account} mutableCopy];
}

@implementation OVKeychain

+ (NSString *)secretForAccount:(NSString *)account {
    NSMutableDictionary *q = Query(account);
    q[(__bridge id)kSecReturnData] = @YES;
    q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef out = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &out) != errSecSuccess || !out) return nil;
    NSData *d = CFBridgingRelease(out);
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    return s.length ? s : nil;
}

+ (BOOL)setSecret:(NSString *)secret forAccount:(NSString *)account {
    NSData *data = [secret dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return NO;
    OSStatus st = SecItemUpdate((__bridge CFDictionaryRef)Query(account),
                                (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: data});
    if (st == errSecItemNotFound) {
        NSMutableDictionary *q = Query(account);
        q[(__bridge id)kSecValueData] = data;
        q[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
        st = SecItemAdd((__bridge CFDictionaryRef)q, NULL);
        if (st != errSecSuccess) {                      // some ad-hoc-signed builds refuse the attribute: store without it, once noted
            static dispatch_once_t once;
            dispatch_once(&once, ^{ NSLog(@"Keychain: accessibility attribute refused (%d); stored without it", (int)st); });
            [q removeObjectForKey:(__bridge id)kSecAttrAccessible];
            st = SecItemAdd((__bridge CFDictionaryRef)q, NULL);
        }
    }
    return st == errSecSuccess;
}

+ (BOOL)deleteAccount:(NSString *)account {
    OSStatus st = SecItemDelete((__bridge CFDictionaryRef)Query(account));
    return st == errSecSuccess || st == errSecItemNotFound;
}

@end
