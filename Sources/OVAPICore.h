// The pure part of the local API (Foundation only, testable on its own): keys, on-disk names, and the whitelisting of
// what a client may ask for. Nothing a client sends is ever used as a path: it names an uploadId / voice / model, and
// the app looks these up in its own tables.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// "cns_" + 43 characters of base64url from 32 random bytes (SecRandomCopyBytes).
NSString *OVAPINewKey(void);
/// Lower-case hex SHA-256: the only form of the key the server process ever sees.
NSString *OVAPIKeySHA256(NSString *key);

/// <support>/api/uploads/<uuid>.bin for an upload id the server issued (lower-case UUID); nil for anything else.
NSString *_Nullable OVAPIUploadPath(NSString *_Nullable uploadId);
/// <support>/api/out/<name>.<ext>; name is [A-Za-z0-9_-]{1,64}, ext is wav, m4a or flac; nil otherwise.
NSString *_Nullable OVAPIOutputPath(NSString *_Nullable name, NSString *_Nullable ext);
/// YES when `path` is a file strictly inside <support>/api/out (symlinks resolved).
BOOL OVAPIPathIsInsideOut(NSString *_Nullable path);
/// The audio type the server announces for an extension.
NSString *OVAPIMimeTypeForExtension(NSString *ext);

/// Each returns the cleaned request, or nil with `*error` = "rejected: <why>". Keys the client was not offered are
/// dropped; numbers are clamped into their range; ids must exist in the catalog the app itself published.
/// synthesize → {text, [voiceId], [language], [mood], speed (0.5…2, only if sent), format (wav|m4a|flac, default wav)}.
/// "voice" is accepted as another spelling of "voiceId".
NSDictionary *_Nullable OVAPINormalizeSynth(NSDictionary *params, NSSet<NSString *> *voiceIds, NSArray<NSString *> *moodIds,
                                            NSString *_Nullable *_Nullable error);
/// clone → {name, uploadId, [ref_text], [language]}; consent must be true.
NSDictionary *_Nullable OVAPINormalizeClone(NSDictionary *params, NSString *_Nullable *_Nullable error);
/// convert → {uploadId, model | voice, params{pitch, index_rate, protect, f0_method}}.
NSDictionary *_Nullable OVAPINormalizeConvert(NSDictionary *params, NSSet<NSString *> *modelIds, NSSet<NSString *> *voiceIds,
                                              NSString *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
