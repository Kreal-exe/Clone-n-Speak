#import "OVKeychain.h"
#import <Security/Security.h>

static NSString *const kService = @"Clone'n'Speak API";

static NSMutableDictionary *Query(NSString *account) {
    return [@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService: kService,
              (__bridge id)kSecAttrAccount: account} mutableCopy];
}

// Test binaries and unbundled tools get a fresh ad-hoc signature on every build, so reading an item they made earlier
// makes macOS ask for the login keychain password. Only the real app (a bundle with our identifier) touches the
// Keychain; everything else keeps secrets in memory for the life of the process.
static BOOL UseKeychain(void) {
    if (NSProcessInfo.processInfo.environment[@"OV_KEYCHAIN_IN_MEMORY"].length) return NO;
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.clonenspeak.mac"];
}

static NSMutableDictionary *MemoryStore(void) {
    static NSMutableDictionary *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [NSMutableDictionary dictionary]; });
    return store;
}

@implementation OVKeychain

+ (NSString *)secretForAccount:(NSString *)account {
    if (!UseKeychain()) { @synchronized (MemoryStore()) { return MemoryStore()[account]; } }
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
    if (!UseKeychain()) { @synchronized (MemoryStore()) { MemoryStore()[account] = [secret copy]; } return YES; }
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
    if (!UseKeychain()) { @synchronized (MemoryStore()) { [MemoryStore() removeObjectForKey:account]; } return YES; }
    OSStatus st = SecItemDelete((__bridge CFDictionaryRef)Query(account));
    return st == errSecSuccess || st == errSecItemNotFound;
}

@end
