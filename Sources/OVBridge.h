#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted (main thread) when Bridge starts, stops, changes its status, address, error or the list of devices.
extern NSNotificationName const OVBridgeDidChangeNotification;

/// "https://abc-def.trycloudflare.com" from a line of the tunnel program's log, or nil. Only that domain, https only,
/// lowercase, a hyphenated name (the service's own api.trycloudflare.com is not an address), no user, port or suffix.
NSString *_Nullable OVBridgeParseTunnelURL(NSString *line);
/// Lowercase hex SHA-256 of a file (CommonCrypto, read in blocks), or @"" when the file cannot be read.
NSString *OVSHA256OfFile(NSString *path);

/// Remote access to the local API: a Cloudflare quick tunnel (`cloudflared`) to the API server's Bridge listener.
/// Never starts by itself. Start goes: Offline mode / consent (OVNetwork) -> helper present? (else a pinned, verified
/// download) -> the API server and its Bridge listener -> the tunnel -> the address. A device that asks to pair is shown
/// to the user with a code; only an approved device gets a token, and the token never reaches this app: the server
/// keeps its SHA-256 and so does devices.json (0600). Main thread only.
@interface OVBridge : NSObject
+ (instancetype)shared;                                   // <support>/bridge
/// For tests: another folder and pin (nil: Resources/bridge-pin.json from the app bundle).
+ (instancetype)bridgeWithRoot:(NSString *)root pin:(nullable NSDictionary *)pin;

@property (readonly) BOOL helperInstalled;                // the pinned program is in place and its SHA-256 matches
@property (readonly) BOOL running;                        // the tunnel is up and its address is known
@property (readonly) BOOL busy;                           // starting (downloading, launching), running or stopping
@property (readonly, nullable, copy) NSString *status;    // "Downloading helper 42 %", "Starting tunnel…", "Running", or nil
@property (readonly, nullable, copy) NSString *tunnelURL; // shown only to the user; never logged
@property (readonly, nullable, copy) NSString *lastError;
@property (readonly, copy) NSArray<NSDictionary *> *devices;   // @{id, name, created: NSDate, lastSeen: NSDate (absent until seen)}; no hashes

- (void)start;                                            // asks (sheet) on the key window when needed; asynchronous
- (void)startInWindow:(nullable NSWindow *)window;
- (void)stop;                                             // asynchronous end of everything Bridge started
- (void)shutdown;                                         // synchronous (quitting): tunnel killed, listener closed, no sheets
- (void)revokeDevice:(NSString *)deviceId;

/// Messages of the API server that belong to Bridge (called by OVAPI): listening (bridgePort), pair_request,
/// device_added, device_seen, error (BRIDGE).
- (void)handleServerMessage:(NSDictionary *)message;
/// The paired devices as the server wants them in its config: @[@{id, name, token_sha256}].
- (NSArray<NSDictionary *> *)devicesForServer;
/// Launch: ends a tunnel process that an earlier crashed run left behind (only a process whose path is our helper).
- (void)cleanupOrphans;

/// The helper's integrity check and install, exposed for tests: SHA-256 of the archive, listing, extraction into an empty
/// temporary folder, SHA-256 of the binary, codesign --verify --strict, the pinned TeamIdentifier, then chmod 755 and a move.
/// Any mismatch deletes the archive (and its .part) and everything extracted: NO with "Bridge helper integrity verification failed".
- (BOOL)installArchiveAtPath:(NSString *)archive error:(NSString *_Nullable *_Nullable)error;

/// Test seam: runs tar / codesign. Default nil: the real tools with an empty environment.
@property (nonatomic, copy, nullable) int (^toolRunner)(NSString *exe, NSArray<NSString *> *args, NSString *_Nullable *_Nullable out, NSString *_Nullable *_Nullable err);
@end

NS_ASSUME_NONNULL_END
