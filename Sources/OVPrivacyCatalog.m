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

@implementation OVPrivacyCatalog

// The ids are the ones OVNetwork identifierFor: returns; tests/test_privacy_catalog.py keeps both lists equal.
+ (NSArray<NSDictionary *> *)networkEntries {
    return @[
        Net(@"edge_tts", L(@"Edge TTS"), L(@"Microsoft speech servers"), L(@"the text you want to hear"),
            L(@"Only when you choose an Edge voice and generate speech."), YES),
        Net(@"youtube", L(@"YouTube import"), L(@"YouTube"), L(@"the video link you paste"),
            L(@"Only when you import audio from a video link."), YES),
        Net(@"bridge", L(@"Bridge"), L(@"a tunnel that makes this Mac reachable from other devices"),
            L(@"the requests your devices send and the audio they get back"),
            L(@"Only while Bridge is switched on."), YES),
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
        Src(@"OVModels.m", dl, @"catalog; downloads go through OVDownloader"),
        Src(@"OVRuntime.m", dl, @"Setup: the uv installer and Python packages"),
        Src(@"OVNetwork.h", @"internal", @"the gate itself; sends nothing"),
        Src(@"OVNetwork.m", @"internal", @"the gate itself; sends nothing"),
        Src(@"OVPrivacyCatalog.m", @"internal", @"this catalog: descriptions only"),
        Src(@"cns_net.py", @"internal", @"the gate for Python processes; sends nothing"),
        Src(@"worker.py", dl, @"speaker model and Seed-VC downloads; cached only while Offline mode is on"),
        Src(@"cns_separate.py", dl, @"music-removal model, pinned address and checksum"),
        Src(@"cns_dfn.py", dl, @"DeepFilterNet program, pinned address and checksum"),
        Src(@"cns_api.py", @"internal", @"local API listener on 127.0.0.1; no outgoing calls"),
        Src(@"cns_engines.py", dl, @"pro-engine installs, pinned versions"),
        Src(@"cns_pins.py", dl, @"pinned versions and checksums for engine installs"),
        Src(@"OVBridge.m", @"bridge", @"tunnel program while Bridge is on"),
        Src(@"OVBridge.h", @"bridge", @"tunnel program while Bridge is on"),
        Src(@"OVPlugins.m", @"plugin_network", @"plugins, only with the network permission"),
        Src(@"cns_youtube.py", @"youtube", @"video downloader, only for the link you paste"),
        Src(@"cns_edge.py", @"edge_tts", @"Edge speech service, only for the text you speak"),
        Src(@"cns_lora.py", dl, @"LoRA files by Hugging Face link that you paste"),
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
