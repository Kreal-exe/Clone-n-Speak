#import "OVRvcSearch.h"
#import "OVDownloader.h"
#import "OVLocale.h"
#import "OVNetwork.h"

@interface OVRvcSearchResult ()
@property (copy) NSString *repo, *pthFile;
@property (copy) NSString *license, *indexFile;
@property NSInteger downloads, likes;
@property NSUInteger pthCount;
@end
@implementation OVRvcSearchResult
@end

@implementation OVRvcSearch

+ (NSString *)endpoint {
    NSString *e = [[NSUserDefaults.standardUserDefaults stringForKey:@"hfEndpoint"]
                   stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!e.length) e = @"https://huggingface.co";
    while ([e hasSuffix:@"/"]) e = [e substringToIndex:e.length - 1];
    return [e.lowercaseString hasPrefix:@"https://"] ? e : nil;
}

+ (NSURL *)searchURLForQuery:(NSString *)query {
    NSString *q = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *base = [self endpoint];
    if (!q.length || !base) return nil;
    if (q.length > 100) q = [q substringToIndex:100];
    NSMutableCharacterSet *allowed = [NSCharacterSet.alphanumericCharacterSet mutableCopy];
    [allowed addCharactersInString:@"-._~"];
    NSString *enc = [q stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/models?search=%@&limit=20&full=true", base, enc]];
}

/// G_/D_ files are training checkpoints (generator, discriminator), not voices.
static BOOL IsVoicePth(NSString *file) {
    NSString *n = file.lastPathComponent;
    if (![n.pathExtension.lowercaseString isEqualToString:@"pth"]) return NO;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^[gd]_\\d+\\.pth$" options:NSRegularExpressionCaseInsensitive error:nil];
    return [re numberOfMatchesInString:n options:0 range:NSMakeRange(0, n.length)] == 0;
}

+ (NSArray<OVRvcSearchResult *> *)resultsFromJSON:(id)json {
    NSMutableArray *out = [NSMutableArray array];
    if (![json isKindOfClass:NSArray.class]) return out;
    for (id item in json) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *repo = [item[@"id"] isKindOfClass:NSString.class] ? item[@"id"] : item[@"modelId"];
        if (![repo isKindOfClass:NSString.class] || ![repo containsString:@"/"]) continue;
        NSMutableArray *pth = [NSMutableArray array], *index = [NSMutableArray array];
        for (id sib in [item[@"siblings"] isKindOfClass:NSArray.class] ? item[@"siblings"] : @[]) {
            NSString *f = [sib isKindOfClass:NSDictionary.class] ? sib[@"rfilename"] : nil;
            if (![f isKindOfClass:NSString.class] || !f.length) continue;
            if (IsVoicePth(f)) [pth addObject:f];
            else if ([f.pathExtension.lowercaseString isEqualToString:@"index"]) [index addObject:f];
        }
        if (!pth.count) continue;
        [pth sortUsingSelector:@selector(compare:)];
        NSString *chosen = pth.firstObject;
        // the index that belongs to it: same folder, "added_…" (the finished one) before "trained_…"
        NSString *folder = chosen.stringByDeletingLastPathComponent, *best = nil;
        for (NSString *i in [index sortedArrayUsingSelector:@selector(compare:)]) {
            if (![i.stringByDeletingLastPathComponent isEqualToString:folder]) continue;
            if (!best || ([i.lastPathComponent hasPrefix:@"added"] && ![best.lastPathComponent hasPrefix:@"added"])) best = i;
        }
        NSString *license = nil;
        for (id tag in [item[@"tags"] isKindOfClass:NSArray.class] ? item[@"tags"] : @[])
            if ([tag isKindOfClass:NSString.class] && [tag hasPrefix:@"license:"] && [tag length] > 8) { license = [tag substringFromIndex:8]; break; }
        OVRvcSearchResult *r = [OVRvcSearchResult new];
        r.repo = repo;
        r.pthFile = chosen;
        r.indexFile = best;
        r.pthCount = pth.count;
        r.license = license;
        r.downloads = [item[@"downloads"] respondsToSelector:@selector(integerValue)] ? [item[@"downloads"] integerValue] : 0;
        r.likes = [item[@"likes"] respondsToSelector:@selector(integerValue)] ? [item[@"likes"] integerValue] : 0;
        [out addObject:r];
    }
    return out;
}

+ (NSURL *)downloadURLForRepo:(NSString *)repo file:(NSString *)file {
    NSString *base = [self endpoint];
    if (!base || ![repo containsString:@"/"] || [file containsString:@".."]) return nil;
    NSString *path = [file stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@/resolve/main/%@", base, repo, path]];
}

+ (NSString *)fetchLinkFromText:(NSString *)text error:(NSString **)error {
    NSString *s = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSURLComponents *c = s.length ? [NSURLComponents componentsWithString:s] : nil;
    NSString *host = c.host.lowercaseString;
    if (!c || !host.length) { if (error) *error = L(@"Paste a link to a voice model (.pth or .zip)."); return nil; }
    if (![c.scheme.lowercaseString isEqualToString:@"https"]) {
        if (error) *error = L(@"Only secure https:// links can be downloaded.");
        return nil;
    }
    for (NSString *h in @[@"drive.google.com", @"docs.google.com", @"drive.usercontent.google.com", @"mega.nz", @"mediafire.com", @"www.mediafire.com"])
        if ([host isEqualToString:h]) {
            if (error) *error = L(@"Google Drive and similar share pages aren’t supported. Download the file in your browser and use Import instead.");
            return nil;
        }
    NSString *ext = c.path.pathExtension.lowercaseString;
    if (![ext isEqualToString:@"pth"] && ![ext isEqualToString:@"zip"]) {
        if (error) *error = L(@"The link must point to a .pth or .zip file.");
        return nil;
    }
    if ([host isEqualToString:@"huggingface.co"] || [host isEqualToString:@"www.huggingface.co"] || [host isEqualToString:@"hf.co"]) {
        NSRange r = [c.path rangeOfString:@"/blob/"];
        if (r.location != NSNotFound) c.path = [c.path stringByReplacingCharactersInRange:r withString:@"/resolve/"];
    }
    c.fragment = nil;
    return c.string;
}

+ (void)search:(NSString *)query completion:(void (^)(NSArray<OVRvcSearchResult *> *, NSString *))completion {
    if ([OVNetwork decisionFor:OVNetModelDownload] == OVNetBlockedOffline) {
        completion(nil, [OVNetwork blockedMessageFor:OVNetModelDownload]);
        return;
    }
    NSURL *url = [self searchURLForQuery:query];
    if (!url) {
        completion(nil, [self endpoint] ? L(@"Type what to look for, for example “rvc”.")
                                        : L(@"The Hugging Face address in the settings is not https, so nothing is searched."));
        return;
    }
    OVFetchJSON(url, @{}, ^(id json, NSError *err) {
        if (![json isKindOfClass:NSArray.class]) {
            completion(nil, [NSString stringWithFormat:L(@"Couldn’t reach Hugging Face: %@"), err.localizedDescription ?: L(@"unexpected answer")]);
            return;
        }
        completion([self resultsFromJSON:json], nil);
    });
}

@end
