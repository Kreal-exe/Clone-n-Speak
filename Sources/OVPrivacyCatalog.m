#import "OVPrivacyCatalog.h"
#import "OVPaths.h"
#import "OVModels.h"
#import "OVLocale.h"

static NSDictionary *Net(NSString *ident, NSString *title, NSString *dest, NSString *sends, NSString *when, BOOL consent) {
    return @{@"id": ident, @"title": title, @"destination": dest, @"sends": sends, @"when": when, @"consent": @(consent)};
}

static NSDictionary *Src(NSString *file, NSString *feature, NSString *note) {
    return @{@"file": file, @"feature": feature, @"note": note};
}

static NSDictionary *Loc(NSString *ident, NSString *title, NSString *path, BOOL deletable, NSString *note) {
    return @{@"id": ident, @"title": title, @"path": path, @"deletable": @(deletable), @"deleteNote": note};
}

NSNotificationName const OVPrivacyWillDeleteAppDataNotification = @"OVPrivacyWillDeleteAppData";

@implementation OVPrivacyCatalog

+ (NSString *)refusalForDataRoot:(NSString *)root home:(NSString *)home override:(NSString *)override isSymlink:(BOOL)isSymlink {
    if (!root.length || !home.length) return L(@"The data folder is not set.");
    NSString *r = [root stringByStandardizingPath], *h = [home stringByStandardizingPath];
    if ([r isEqualToString:@"/"] || [r isEqualToString:h] || r.pathComponents.count < 3) return L(@"The data folder is too broad to delete.");
    if (isSymlink) return L(@"The data folder is a link, not a folder.");
    NSString *rr = [r stringByResolvingSymlinksInPath];
    if (override.length && [[override stringByStandardizingPath] isEqualToString:r]) {
        for (NSString *base in @[@"/tmp", @"/private/tmp", @"/private/var/folders", [NSTemporaryDirectory() stringByResolvingSymlinksInPath]])
            if (base.length && [rr hasPrefix:[base hasSuffix:@"/"] ? base : [base stringByAppendingString:@"/"]]) return nil;
        return L(@"A custom data folder is only accepted under a temporary folder.");
    }
    NSString *appSupport = [[h stringByAppendingPathComponent:@"Library/Application Support"] stringByResolvingSymlinksInPath];
    if (![rr hasPrefix:[appSupport stringByAppendingString:@"/"]]) return L(@"The data folder is not inside Application Support.");
    return nil;
}

// The ids are the ones OVNetwork identifierFor: returns; tests/test_privacy_catalog.py keeps both lists equal.
+ (NSArray<NSDictionary *> *)networkEntries {
    return @[
        Net(@"edge_tts", L(@"Edge TTS"), L(@"Microsoft speech servers"), L(@"the text you want to hear"),
            L(@"Only when you choose an Edge voice and generate speech."), YES),
        Net(@"youtube", L(@"YouTube import"), L(@"YouTube"), L(@"the video link you paste"),
            L(@"Only when you import audio from a video link."), YES),
        Net(@"bridge", L(@"Bridge"), L(@"Cloudflare, through a tunnel that makes this Mac reachable from your other devices"),
            L(@"the requests your devices send and the audio and results they get back (the traffic passes through Cloudflare)"),
            L(@"Only while Bridge is switched on. Its tunnel program is downloaded once from GitHub, checked before it runs."), YES),
        Net(@"model_download", L(@"Model downloads"), L(@"Hugging Face"), L(@"the names of the models you download"),
            L(@"Only when you press a download or install button."), NO),
        Net(@"plugin_network", L(@"Plugin network access"), L(@"the servers a plugin talks to"), L(@"whatever the plugin sends"),
            L(@"Only when a plugin you installed asks for the network."), YES),
    ];
}

// Every file of tests/test_network_allowlist.py EXPECTED has a row here, and so have the files other tasks add
// (pro-engine installs, Bridge, plugins, YouTube, Edge TTS, LoRA by link, the local API).
+ (NSArray<NSDictionary *> *)networkSources {
    NSString *dl = @"model_download";
    return @[
        Src(@"OVDownloader.m", dl, @"model downloads from Hugging Face that you start"),
        Src(@"OVModels.h", dl, @"download API"),
        Src(@"OVModels.m", dl, @"catalog and LoRA links you paste; downloads go through OVDownloader"),
        Src(@"OVRuntime.m", dl, @"Setup: the uv installer and Python packages"),
        Src(@"OVNetwork.h", @"internal", @"the gate itself; sends nothing"),
        Src(@"OVNetwork.m", @"internal", @"the gate itself; sends nothing"),
        Src(@"OVPrivacyCatalog.m", @"internal", @"this catalog: descriptions only"),
        Src(@"cns_net.py", @"internal", @"the gate for Python processes; sends nothing"),
        Src(@"worker.py", dl, @"speaker model and Seed-VC downloads; cached only while Offline mode is on"),
        Src(@"cns_separate.py", dl, @"music-removal model, pinned address and checksum"),
        Src(@"cns_dfn.py", dl, @"DeepFilterNet program, pinned address and checksum"),
        Src(@"cns_api.py", @"internal", @"local API listener on 127.0.0.1; no outgoing calls"),
        Src(@"OVAPIPage.m", @"internal", @"example commands for the local API on 127.0.0.1; sends nothing"),
        Src(@"cns_realtime.py", @"internal", @"realtime voice process; a local connection to the app only, no internet"),
        Src(@"cns_rt_proto.py", @"internal", @"realtime block protocol over a local connection; no internet"),
        Src(@"cns_engines.py", dl, @"pro-engine installs, pinned versions"),
        Src(@"OVEngines.h", @"internal", @"pro-engine manager; a local connection to the realtime process only"),
        Src(@"OVEngines.m", dl, @"starts the engine installs and updates you ask for; Edge and YouTube jobs wait for the gate"),
        Src(@"OVProKit.m", @"internal", @"checks the gate before Edge and YouTube jobs; sends nothing itself"),
        Src(@"cns_pins.py", dl, @"pinned versions and checksums for engine installs"),
        Src(@"OVBridge.m", @"bridge", @"downloads the tunnel program once from GitHub (pinned address, checksums, signer) and runs it while Bridge is on; the traffic of approved devices passes through Cloudflare"),
        Src(@"OVBridge.h", @"bridge", @"Bridge's interface; sends nothing by itself"),
        Src(@"OVPlugins.m", @"plugin_network", @"plugins, only with the network permission"),
        Src(@"OVYouTubeSheet.m", @"youtube", @"the YouTube import sheet; the download runs as a job you start"),
        Src(@"OVYouTubeSheet.h", @"youtube", @"the YouTube import sheet"),
        Src(@"cns_ytdl.py", @"youtube", @"video downloader, only for the link you paste"),
        Src(@"cns_edge.py", @"edge_tts", @"Edge speech service, only for the text you speak"),
        Src(@"cns_rvc.py", dl, @"voice-model files, only from the link you paste"),
    ];
}

+ (NSArray<NSDictionary *> *)locations {
    NSString *s = [OVPaths support];
    return @[
        Loc(@"voices", L(@"Voices and recordings"), [OVPaths voices], YES,
            L(@"Delete all voices and recordings? They are moved to the Trash.")),
        Loc(@"outputs", L(@"Generated audio"), [OVPaths outputs], YES,
            L(@"Delete all generated audio? It is moved to the Trash.")),
        Loc(@"history", L(@"History and jobs"), [OVPaths jobs], YES,
            L(@"Delete job history? Audio you generated is kept.")),
        Loc(@"logs", L(@"Logs"), [OVPaths logs], YES,
            L(@"Delete logs? Audio you generated is kept.")),
        Loc(@"models", L(@"Models"), [OVModels hubCache], NO,
            L(@"This folder is shared with other programs. Remove models one by one on the Models page.")),
        Loc(@"engines", L(@"Engines"), [OVPaths engines], YES,
            L(@"Delete the downloaded engines? They are moved to the Trash and can be installed again.")),
        Loc(@"rvc", L(@"Voice models and training"), [OVPaths rvc], YES,
            L(@"Delete voice models and training data? They are moved to the Trash.")),
        Loc(@"plugins", L(@"Plugins"), [s stringByAppendingPathComponent:@"plugins"], YES,
            L(@"Delete all plugins? They are moved to the Trash.")),
        Loc(@"api", L(@"API uploads and results"), [s stringByAppendingPathComponent:@"api"], YES,
            L(@"Delete files received and produced by the local API? They are moved to the Trash.")),
        Loc(@"bridge", L(@"Bridge devices"), [s stringByAppendingPathComponent:@"bridge"], YES,
            L(@"Delete Bridge devices and their keys? They are moved to the Trash; devices must pair again.")),
    ];
}

+ (NSDictionary *)entryForFeature:(NSString *)identifier {
    for (NSDictionary *e in [self networkEntries]) if ([e[@"id"] isEqualToString:identifier]) return e;
    return nil;
}

@end
