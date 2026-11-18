#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted (main thread) whenever the service starts, stops, fails or changes its port or key.
extern NSNotificationName const OVAPIDidChangeNotification;

/// The local API: cns_api.py (stdlib HTTP server on 127.0.0.1) runs as a child process and the app is its backend.
/// The process gets the SHA-256 of the key, never the key; the key itself is in the Keychain only.
/// Requests that synthesize or clone go through OVJobs with origin "api", so they show up on the Jobs page.
/// UserDefaults: apiEnabled (NO), apiPort (18777). Main thread only.
@interface OVAPI : NSObject
+ (instancetype)shared;
@property (readonly, getter=isRunning) BOOL running;
@property (readonly, nullable, copy) NSString *lastError;
@property (readonly) uint16_t port;                       // the configured port (apiPort), 18777 by default
@property (readonly) NSString *baseURL;                   // http://127.0.0.1:<port>
/// The user's switch (apiEnabled). Keeps the app alive without a window (main.m) and starts the service at launch.
@property (readonly) BOOL enabled;
/// Switches the service on or off and remembers it. NO with *error (and the switch off again) when it cannot start.
- (BOOL)setEnabled:(BOOL)on error:(NSString *_Nullable *_Nullable)error;
/// Saves a new port (1024…65535) and restarts a running service on it. NO with *error when it is invalid or taken.
- (BOOL)applyPort:(NSInteger)port error:(NSString *_Nullable *_Nullable)error;

- (BOOL)start:(NSString *_Nullable *_Nullable)error;      // waits (at most a few seconds) until the server listens; "Port 18777 is in use. Pick another port."
- (void)stop;                                             // synchronous: the child is gone when it returns
- (NSString *)currentKey;                                 // from the Keychain; created on first use
- (NSString *)rotateKey;                                  // a new key, the server restarts with it
+ (NSString *)newKey;                                     // "cns_" + 43 characters base64url from SecRandomCopyBytes(32)
/// Launch-time hook: starts the service if apiEnabled. Failures stay in lastError (the page shows them).
- (void)startIfEnabled;

/// Newest first, at most `limit` jobs whose origin is "api".
- (NSArray *)recentJobs:(NSUInteger)limit;
@end

NS_ASSUME_NONNULL_END
