#import "OVAPICore.h"
#import "OVPaths.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>

NSString *OVAPINewKey(void) {
    uint8_t bytes[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof bytes, bytes) != errSecSuccess) arc4random_buf(bytes, sizeof bytes);
    NSString *b64 = [[NSData dataWithBytes:bytes length:sizeof bytes] base64EncodedStringWithOptions:0];
    b64 = [[b64 stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    b64 = [b64 stringByReplacingOccurrencesOfString:@"=" withString:@""];
    return [@"cns_" stringByAppendingString:b64];
}

NSString *OVAPIKeySHA256(NSString *key) {
    NSData *d = [key dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data;
    uint8_t h[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, h);
    NSMutableString *s = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", h[i]];
    return s;
}

#pragma mark - Paths

static BOOL IsHexLower(unichar c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'); }

/// 8-4-4-4-12 lower-case hex, nothing before, after or between (checked by hand: ICU's $ also matches before a final newline).
static BOOL IsUploadId(id v) {
    if (![v isKindOfClass:NSString.class] || [(NSString *)v length] != 36) return NO;
    NSString *s = v;
    for (NSUInteger i = 0; i < 36; i++) {
        unichar c = [s characterAtIndex:i];
        BOOL dash = i == 8 || i == 13 || i == 18 || i == 23;
        if (dash ? c != '-' : !IsHexLower(c)) return NO;
    }
    return YES;
}

static BOOL IsNameToken(id v, NSUInteger maxLen) {
    if (![v isKindOfClass:NSString.class]) return NO;
    NSString *s = v;
    if (!s.length || s.length > maxLen) return NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-')) return NO;
    }
    return YES;
}

NSString *OVAPIUploadPath(NSString *uploadId) {
    if (!IsUploadId(uploadId)) return nil;
    NSString *root = [OVPaths apiUploads];
    NSString *p = [root stringByAppendingPathComponent:[uploadId stringByAppendingString:@".bin"]];
    return [p.stringByStandardizingPath hasPrefix:[root.stringByStandardizingPath stringByAppendingString:@"/"]] ? p : nil;
}

NSString *OVAPIOutputPath(NSString *name, NSString *ext) {
    if (!IsNameToken(name, 64) || ![@[@"wav", @"m4a", @"flac"] containsObject:ext ?: @""]) return nil;
    return [[OVPaths apiOut] stringByAppendingPathComponent:[name stringByAppendingPathExtension:ext]];
}

BOOL OVAPIPathIsInsideOut(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.length) return NO;
    NSString *root = [[OVPaths apiOut] stringByResolvingSymlinksInPath].stringByStandardizingPath;
    NSString *real = [path stringByResolvingSymlinksInPath].stringByStandardizingPath;
    return [real hasPrefix:[root stringByAppendingString:@"/"]] && real.length > root.length + 1;
}

NSString *OVAPIMimeTypeForExtension(NSString *ext) {
    if ([ext isEqualToString:@"m4a"]) return @"audio/mp4";
    if ([ext isEqualToString:@"flac"]) return @"audio/flac";
    return @"audio/wav";
}

#pragma mark - Requests

static NSDictionary *Reject(NSString **error, NSString *why) {
    if (error) *error = [@"rejected: " stringByAppendingString:why];
    return nil;
}

static BOOL IsNumber(id v) {
    return [v isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)v) != CFBooleanGetTypeID();
}

static double Clamp(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }

/// "uk", "en-US", "fil": two or three letters, optional subtag.
static BOOL IsLanguageCode(id v) {
    if (![v isKindOfClass:NSString.class]) return NO;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ re = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})?$" options:0 error:nil]; });
    NSString *s = v;
    return s.length <= 12 && [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)] != nil;
}

static BOOL IsCatalogId(id v) {
    if (![v isKindOfClass:NSString.class]) return NO;
    NSString *s = v;
    if (!s.length || s.length > 64) return NO;
    unichar f = [s characterAtIndex:0];
    if (!((f >= 'a' && f <= 'z') || (f >= 'A' && f <= 'Z') || (f >= '0' && f <= '9') || f == '_')) return NO;
    for (NSUInteger i = 1; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.')) return NO;
    }
    return YES;
}

NSDictionary *OVAPINormalizeSynth(NSDictionary *p, NSSet<NSString *> *voiceIds, NSArray<NSString *> *moodIds, NSString **error) {
    if (![p isKindOfClass:NSDictionary.class]) return Reject(error, @"body must be an object");
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (![p[@"text"] isKindOfClass:NSString.class]) return Reject(error, @"text must be a string");
    NSString *text = [p[@"text"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) return Reject(error, @"text is empty");
    if (text.length > 20000) return Reject(error, @"text is too long");
    out[@"text"] = text;
    id voice = p[@"voiceId"] ?: p[@"voice"];
    if (voice) {
        if (!IsCatalogId(voice) || ![voiceIds containsObject:voice]) return Reject(error, @"unknown voice");
        out[@"voiceId"] = voice;
    }
    if (p[@"language"]) {
        if (!IsLanguageCode(p[@"language"])) return Reject(error, @"bad language");
        out[@"language"] = p[@"language"];
    }
    if (p[@"mood"]) {
        if (![p[@"mood"] isKindOfClass:NSString.class] || ![moodIds containsObject:p[@"mood"]]) return Reject(error, @"unknown mood");
        out[@"mood"] = p[@"mood"];
    }
    if (p[@"speed"]) {
        if (!IsNumber(p[@"speed"]) || isnan([p[@"speed"] doubleValue])) return Reject(error, @"speed must be a number");
        out[@"speed"] = @(Clamp([p[@"speed"] doubleValue], 0.5, 2.0));
    }
    id fmt = p[@"format"] ?: @"wav";
    if (![@[@"wav", @"m4a", @"flac"] containsObject:fmt]) return Reject(error, @"unknown format");
    out[@"format"] = fmt;
    return out;
}

NSDictionary *OVAPINormalizeClone(NSDictionary *p, NSString **error) {
    if (![p isKindOfClass:NSDictionary.class]) return Reject(error, @"body must be an object");
    if (![p[@"consent"] isKindOfClass:NSNumber.class] || ![p[@"consent"] boolValue]) return Reject(error, @"consent is required");
    if (![p[@"name"] isKindOfClass:NSString.class]) return Reject(error, @"name must be a string");
    NSString *name = [p[@"name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length || name.length > 60 || [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        return Reject(error, @"bad name");
    if (!IsUploadId(p[@"uploadId"])) return Reject(error, @"bad uploadId");
    NSMutableDictionary *out = [@{@"name": name, @"uploadId": p[@"uploadId"]} mutableCopy];
    if (p[@"ref_text"]) {
        if (![p[@"ref_text"] isKindOfClass:NSString.class] || [p[@"ref_text"] length] > 2000) return Reject(error, @"bad ref_text");
        out[@"ref_text"] = p[@"ref_text"];
    }
    if (p[@"language"]) {
        if (!IsLanguageCode(p[@"language"])) return Reject(error, @"bad language");
        out[@"language"] = p[@"language"];
    }
    return out;
}

NSDictionary *OVAPINormalizeConvert(NSDictionary *p, NSSet<NSString *> *modelIds, NSSet<NSString *> *voiceIds, NSString **error) {
    if (![p isKindOfClass:NSDictionary.class]) return Reject(error, @"body must be an object");
    if (!IsUploadId(p[@"uploadId"])) return Reject(error, @"bad uploadId");
    if ((p[@"model"] != nil) == (p[@"voice"] != nil)) return Reject(error, @"give exactly one of model or voice");
    NSMutableDictionary *out = [@{@"uploadId": p[@"uploadId"]} mutableCopy];
    if (p[@"model"]) {
        if (!IsCatalogId(p[@"model"]) || ![modelIds containsObject:p[@"model"]]) return Reject(error, @"unknown model");
        out[@"model"] = p[@"model"];
    } else {
        if (!IsCatalogId(p[@"voice"]) || ![voiceIds containsObject:p[@"voice"]]) return Reject(error, @"unknown voice");
        out[@"voice"] = p[@"voice"];
    }
    NSDictionary *in = p[@"params"];
    NSMutableDictionary *pr = [NSMutableDictionary dictionary];
    if (in != nil && ![in isKindOfClass:NSDictionary.class]) return Reject(error, @"params must be an object");
    NSDictionary *ranges = @{@"pitch": @[@-24, @24], @"index_rate": @[@0, @1], @"protect": @[@0, @0.5]};
    for (NSString *k in ranges) {
        if (!in[k]) continue;
        if (!IsNumber(in[k]) || isnan([in[k] doubleValue])) return Reject(error, [k stringByAppendingString:@" must be a number"]);
        pr[k] = @(Clamp([in[k] doubleValue], [ranges[k][0] doubleValue], [ranges[k][1] doubleValue]));
    }
    if (in[@"f0_method"]) {
        if (![@[@"rmvpe", @"crepe", @"crepe-tiny", @"fcpe", @"harvest", @"pm", @"dio"] containsObject:in[@"f0_method"]])
            return Reject(error, @"unknown f0_method");
        pr[@"f0_method"] = in[@"f0_method"];
    }
    out[@"params"] = pr;
    return out;
}
