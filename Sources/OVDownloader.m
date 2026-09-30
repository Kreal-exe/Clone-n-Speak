#import "OVDownloader.h"
#import "OVLocale.h"

@interface OVDownloader () <NSURLSessionDataDelegate>
@property NSURLSession *session;
@property NSURLSessionDataTask *task;
@property NSString *dest, *part;
@property NSFileHandle *out;
@property long long received, total, lastReport;
@property (copy) void (^progress)(long long, long long);
@property (copy) void (^completion)(NSError *);
@property BOOL finished;
@end

@implementation OVDownloader

+ (instancetype)download:(NSURL *)url to:(NSString *)dest headers:(NSDictionary *)headers
                progress:(void (^)(long long, long long))progress completion:(void (^)(NSError *))completion {
    return [self download:url to:dest part:nil headers:headers progress:progress completion:completion];
}

+ (instancetype)download:(NSURL *)url to:(NSString *)dest part:(NSString *)part headers:(NSDictionary *)headers
                progress:(void (^)(long long, long long))progress completion:(void (^)(NSError *))completion {
    OVDownloader *d = [OVDownloader new];
    d.dest = dest;
    d.part = part ?: [dest stringByAppendingString:@".part"];
    d.progress = progress;
    d.completion = completion;
    [NSFileManager.defaultManager createDirectoryAtPath:dest.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    long long have = [[NSFileManager.defaultManager attributesOfItemAtPath:d.part error:nil] fileSize];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 60;
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) { [req setValue:v forHTTPHeaderField:k]; }];
    if (have > 0) [req setValue:[NSString stringWithFormat:@"bytes=%lld-", have] forHTTPHeaderField:@"Range"];
    d.received = have;

    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.defaultSessionConfiguration;
    cfg.timeoutIntervalForResource = 60 * 60 * 24;
    NSOperationQueue *q = [NSOperationQueue new];
    q.maxConcurrentOperationCount = 1;
    d.session = [NSURLSession sessionWithConfiguration:cfg delegate:d delegateQueue:q];
    d.task = [d.session dataTaskWithRequest:req];
    [d.task resume];
    return d;
}

- (void)cancel {
    [self.task cancel];
}

- (void)finish:(NSError *)err {
    if (self.finished) return;
    self.finished = YES;
    [self.out closeFile];
    self.out = nil;
    if (!err) {
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm removeItemAtPath:self.dest error:nil];
        NSError *mv = nil;
        if (![fm moveItemAtPath:self.part toPath:self.dest error:&mv]) err = mv;
    }
    [self.session finishTasksAndInvalidate];
    void (^c)(NSError *) = self.completion;
    self.completion = nil;
    self.progress = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ if (c) c(err); });
}

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveResponse:(NSURLResponse *)resp
 completionHandler:(void (^)(NSURLSessionResponseDisposition))handler {
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
    NSInteger code = http.statusCode;
    if (code == 416) { // already complete
        self.total = self.received;
        handler(NSURLSessionResponseCancel);
        [self finish:nil];
        return;
    }
    if (code != 200 && code != 206) {
        handler(NSURLSessionResponseCancel);
        NSString *msg = [NSString stringWithFormat:L(@"HTTP %ld while downloading %@"), (long)code, resp.URL.lastPathComponent];
        if (code == 401 || code == 403) msg = [NSString stringWithFormat:L(@"%@ (access or an HF token is required)"), msg];
        [self finish:[NSError errorWithDomain:@"OV" code:code userInfo:@{NSLocalizedDescriptionKey: msg}]];
        return;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    if (code == 200) { // server ignored Range — start over
        self.received = 0;
        [fm removeItemAtPath:self.part error:nil];
    }
    if (![fm fileExistsAtPath:self.part]) [fm createFileAtPath:self.part contents:nil attributes:nil];
    self.out = [NSFileHandle fileHandleForWritingAtPath:self.part];
    [self.out seekToEndOfFile];
    long long expected = resp.expectedContentLength;
    self.total = expected > 0 ? self.received + expected : -1;
    handler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)data {
    @try { [self.out writeData:data]; }
    @catch (NSException *e) {
        [t cancel];
        [self finish:[NSError errorWithDomain:@"OV" code:1 userInfo:@{NSLocalizedDescriptionKey: L(@"Couldn’t write the file (out of disk space?)")}]];
        return;
    }
    self.received += data.length;
    if (self.received - self.lastReport > 512 * 1024 || self.received == self.total) {
        self.lastReport = self.received;
        long long r = self.received, tot = self.total;
        void (^p)(long long, long long) = self.progress;
        dispatch_async(dispatch_get_main_queue(), ^{ if (p) p(r, tot); });
    }
}

- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)error {
    if (self.finished) return;
    if (!error && self.total > 0 && self.received < self.total)
        error = [NSError errorWithDomain:@"OV" code:2 userInfo:@{NSLocalizedDescriptionKey: L(@"Connection lost — click Download again to resume")}];
    [self finish:error];
}
@end

void OVFetchJSON(NSURL *url, NSDictionary *headers, void (^completion)(id, NSError *)) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 30;
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) { [req setValue:v forHTTPHeaderField:k]; }];
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        id json = nil;
        NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
        if (!err && code >= 400)
            err = [NSError errorWithDomain:@"OV" code:code userInfo:@{NSLocalizedDescriptionKey:
                   code == 404 ? L(@"Model not found on Hugging Face") :
                   (code == 401 || code == 403) ? L(@"No access to the model (private or gated — an HF token is required)") :
                   [NSString stringWithFormat:@"HTTP %ld", (long)code]}];
        if (!err && data) json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(json, err); });
    }] resume];
}
