#import <Foundation/Foundation.h>
#import "OVJobs.h"

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const OVPluginsDidChangeNotification;

/// The Python that runs plugins. One place to change: today the app's own runtime; the pro-engine manager
/// (OVEngines pythonForEngine:) replaces it when that lands. nil-safe: returns a path even if the file is missing.
NSString *OVPluginPython(void);

/// One installed plugin (a read-only snapshot of its plugin.json and the folder's checksum).
@interface OVPlugin : NSObject
@property (readonly, copy) NSString *identifier, *folder;
@property (readonly, copy, nullable) NSString *name, *version, *author, *summary, *digest;
@property (readonly, copy) NSArray<NSDictionary *> *actions;   // {id, label, inputs:[{name,type,label,min,max,default,choices}]}
@property (readonly, copy) NSArray<NSString *> *permissions;
@property (readonly) NSInteger timeoutSeconds;
@property (readonly, copy, nullable) NSString *error;          // set when plugin.json is invalid (the plugin cannot run)
@property (readonly) BOOL wantsNetwork;
@end

/// Installed plugins, the global and per-plugin switches, trust, and the `plugin` job kind.
/// Defaults keys: pluginsEnabled, pluginEnabled.<id>, pluginTrust.<id> (= folder checksum the user agreed to),
/// pluginNetwork.<id> (the user allowed this plugin's network use).
@interface OVPlugins : NSObject
+ (instancetype)shared;
/// Registers the `plugin` kind on the shared OVJobs (also done by +shared and by the page).
+ (void)registerKind;
@property (readonly, copy) NSArray<OVPlugin *> *plugins;
@property (nonatomic) BOOL enabled;                            // "Enable plugins", off by default
/// Re-reads plugins/ off the main thread, switches off plugins whose files changed, then calls `done` on main.
- (void)reload:(nullable void (^)(void))done;
- (nullable OVPlugin *)pluginWithId:(NSString *)identifier;

/// The plugin's own switch AND the global one AND its checksum still equals the one the user trusted.
- (BOOL)isActive:(OVPlugin *)p;
- (BOOL)switchOn:(OVPlugin *)p;                                // the plugin's own switch only
- (BOOL)needsTrust:(OVPlugin *)p;                              // never trusted, or the files changed since
- (BOOL)networkAllowed:(OVPlugin *)p;                          // declared + the user allowed it + not Offline mode
/// Records trust for the current files and turns the plugin on.
- (void)trust:(OVPlugin *)p allowNetwork:(BOOL)allowNetwork;
- (void)turnOff:(OVPlugin *)p;
/// The text of the consent sheet.
+ (NSString *)consentTextFor:(OVPlugin *)p;

- (void)installFolder:(NSString *)path completion:(void (^)(NSString *_Nullable identifier, NSString *_Nullable error))done;
/// Moves the installed folder and the plugin's data to the Trash and forgets its settings.
- (void)remove:(OVPlugin *)p;
/// nil + error if the plugin is off or the action is unknown. Origin: plugin:<id>.
- (nullable OVJob *)submit:(OVPlugin *)p action:(NSString *)action inputs:(NSDictionary *)inputs
                     error:(NSString *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
