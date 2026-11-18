#import "OVYouTubeSheet.h"
#import "OVDesign.h"
#import "OVEngines.h"
#import "OVExport.h"
#import "OVJobs.h"
#import "OVLocale.h"
#import "OVNetwork.h"
#import "OVPaths.h"
#import "OVProKit.h"
#import "OVTheme.h"
#import "OVUI.h"

static const NSInteger kMaxMinutes = 20;   // the engine's default; the sheet never asks for more

#pragma mark - URL check (mirror of cns_ytdl.parse_url)

static BOOL IsVideoId(NSString *s) {
    if (s.length != 11) return NO;
    static NSCharacterSet *ok;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ok = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"]; });
    return [s rangeOfCharacterFromSet:ok.invertedSet].location == NSNotFound;
}

BOOL OVYouTubeCheckURL(NSString *url, NSString **canonical, NSString **reason) {
    NSString *u = [url stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *why = nil;
    NSString *vid = @"", *site = @"www.youtube.com";
    NSURLComponents *c = u.length && u.length <= 400 ? [NSURLComponents componentsWithString:u] : nil;
    NSString *host = c.host.lowercaseString;
    NSString *path = c.percentEncodedPath ?: @"";
    BOOL watchHost = [@[@"youtube.com", @"www.youtube.com", @"m.youtube.com", @"music.youtube.com"] containsObject:host ?: @""];
    BOOL shortHost = [host isEqualToString:@"youtu.be"];
    BOOL playlistLike = [path hasPrefix:@"/playlist"] || [path hasPrefix:@"/@"] || [path hasPrefix:@"/channel"] || [path hasPrefix:@"/c/"] || [path hasPrefix:@"/user/"];
    BOOL hasList = NO;
    for (NSURLQueryItem *q in c.queryItems) if ([q.name isEqualToString:@"list"]) hasList = YES;

    if (!u.length) why = L(@"Paste the link to one YouTube video.");
    else if (u.length > 400) why = L(@"This link is too long to be a YouTube video link.");
    else if (!c || !host.length) why = L(@"This doesn’t look like a link. Paste the address of one YouTube video.");
    else if (![c.scheme.lowercaseString isEqualToString:@"https"]) why = L(@"The link must start with https://");
    else if (c.user || c.password || (c.port && c.port.integerValue != 443)) why = L(@"Use the plain video link, without a user name or a port.");
    else if (!watchHost && !shortHost)
        why = [host hasSuffix:@"youtube.com"] ? L(@"Use a YouTube video link (youtube.com/watch?v=, /shorts/, youtu.be/).")
                                              : L(@"Only YouTube links work here (youtube.com or youtu.be).");
    else if (watchHost) {
        NSArray<NSString *> *seg = [path componentsSeparatedByString:@"/"];   // "", "shorts", "<id>", maybe ""
        BOOL idPath = (seg.count == 3 || (seg.count == 4 && !seg[3].length)) && !seg[0].length && seg[2].length > 0 &&
                      ([seg[1] isEqualToString:@"shorts"] || [seg[1] isEqualToString:@"live"] || [seg[1] isEqualToString:@"embed"]);
        if (idPath) { vid = seg[2]; site = @"www.youtube.com"; }
        else if (![path isEqualToString:@"/watch"])
            why = playlistLike ? L(@"One video only. Playlists and channels are not supported.") : L(@"Paste the link to one video (youtube.com/watch?v=…, /shorts/…).");
        else {
            NSMutableArray *vals = [NSMutableArray array];
            for (NSURLQueryItem *q in c.queryItems) if ([q.name isEqualToString:@"v"]) [vals addObject:q.value ?: @""];
            vid = vals.count == 1 ? vals[0] : @"";
            site = [host isEqualToString:@"music.youtube.com"] ? host : @"www.youtube.com";
        }
    } else {   // youtu.be/<id> or youtu.be/<id>/ : exactly one path segment
        NSString *p = path.length > 1 ? [path substringFromIndex:1] : @"";
        if ([p hasSuffix:@"/"]) p = [p substringToIndex:p.length - 1];
        vid = [p containsString:@"/"] ? @"" : p;
    }
    if (!why && !IsVideoId(vid))
        why = hasList ? L(@"One video only. Playlists and channels are not supported.") : L(@"The video ID in this link is missing or wrong. Copy the link again.");
    if (why) { if (reason) *reason = why; return NO; }
    if (canonical) *canonical = [NSString stringWithFormat:@"https://%@/watch?v=%@", site, vid];
    return YES;
}

/// YES while `t` could still become a valid link by typing more (so no error shows mid-typing).
static BOOL IsLinkPrefix(NSString *t) {
    NSMutableArray *stems = [NSMutableArray array];
    for (NSString *h in @[@"youtube.com", @"www.youtube.com", @"m.youtube.com", @"music.youtube.com"]) {
        [stems addObject:[NSString stringWithFormat:@"https://%@/watch?v=", h]];
        for (NSString *k in @[@"shorts", @"live", @"embed"]) [stems addObject:[NSString stringWithFormat:@"https://%@/%@/", h, k]];
    }
    [stems addObject:@"https://youtu.be/"];
    for (NSString *st in stems) {
        NSString *full = [st stringByAppendingString:@"aaaaaaaaaaa"];
        if ([full hasPrefix:t]) return YES;
        if ([t hasPrefix:st] && [t length] - st.length < 11 && IsVideoId([[t substringFromIndex:st.length] stringByAppendingString:[@"aaaaaaaaaaa" substringFromIndex:[t length] - st.length]])) return YES;
    }
    return NO;
}

#pragma mark - Sheet

@interface OVYouTubeSheet () <NSTextFieldDelegate>
@property (copy) NSString *destination;
@property (copy) void (^completion)(NSURL *_Nullable);
@property NSView *gate, *offlineNotice, *ffmpegNotice;
@property NSTextField *urlField, *urlError, *status;
@property NSButton *rightsBox, *consentBox, *goButton, *stopButton, *cancelButton, *updateButton;
@property NSProgressIndicator *bar;
@property (weak) OVJob *job, *updateJob;
@property BOOL gateReady, finished, starting, urlTouched;
@property (copy) NSString *cachedVersion;
@property BOOL versionCached;
@end

static OVYouTubeSheet *shown;   // one sheet at a time; this keeps the controller alive

@implementation OVYouTubeSheet

+ (void)presentOnWindow:(NSWindow *)w destinationDirectory:(NSString *)dir completion:(void (^)(NSURL *))done {
    if (shown) { done(nil); return; }
    OVYouTubeSheet *s = [OVYouTubeSheet new];
    s.destination = dir.length ? dir : OVPaths.outputs;
    s.completion = done;
    [s build];
    shown = s;
    [w beginSheet:s.window completionHandler:^(NSModalResponse r) {
        [NSNotificationCenter.defaultCenter removeObserver:s];
        shown = nil;
        [s deliver:nil];   // no-op when a file was delivered already
    }];
    [s.window makeFirstResponder:s.urlField];
    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification object:w queue:nil usingBlock:^(NSNotification *n) {
        if (shown != s) return;   // the parent closed without ending the sheet
        if (s.job.active) [OVJobs.shared stop:s.job];
        if (s.updateJob.active) [OVJobs.shared stop:s.updateJob];
        [NSNotificationCenter.defaultCenter removeObserver:s];
        shown = nil;
        [s deliver:nil];
    }];
}

/// A notice block: symbol + text on a tinted plate (never colour alone: the symbol and the words say it too).
static NSView *Notice(NSString *symbol, NSString *text, OVRole tone) {
    OVBoxView *box = [OVBoxView boxWithFill:OVColorAlpha(tone, 0.10) border:OVColorAlpha(tone, 0.45) radius:10];
    NSTextField *t = OVWrapLabel(text, 13, OVColor(OVRoleText));
    NSImageView *icon = OVSymbol(symbol, 15, OVColor(tone));
    icon.accessibilityElement = NO;
    NSStackView *row = OVHStack(@[icon, t], 10);
    row.alignment = NSLayoutAttributeTop;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:row];
    OVPin(row, box, NSEdgeInsetsMake(10, 12, 10, 12));
    [t setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    box.accessibilityElement = YES;
    box.accessibilityRole = NSAccessibilityGroupRole;
    box.accessibilityLabel = text;
    return box;
}

- (void)build {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 660) styleMask:NSWindowStyleMaskTitled
                                                backing:NSBackingStoreBuffered defer:NO];
    NSTextField *title = OVLabel(L(@"Import audio from YouTube"), 20, NSFontWeightBold, OVColor(OVRoleText));
    NSTextField *intro = OVWrapLabel(L(@"Downloads the sound of one video as a WAV file, for a voice sample or to convert."), 13, OVColor(OVRoleMuted));
    NSStackView *head = OVVStack(@[title, intro], 6);
    OVFillWidth(@[intro], head);

    __weak OVYouTubeSheet *weak = self;
    self.gate = OVEngineGateCard(L(@"YouTube import"), @[@"pro-env", @"ytdlp"], ^(BOOL ready) { weak.gateReady = ready; [weak refresh]; });
    self.offlineNotice = Notice(@"wifi.slash", [OVNetwork blockedMessageFor:OVNetYouTube], OVRoleWarn);
    self.ffmpegNotice = Notice(@"exclamationmark.triangle", L(@"YouTube import needs ffmpeg — install it with Homebrew (brew install ffmpeg)"), OVRoleWarn);

    // 1. Link
    self.urlField = OVField(L(@"https://www.youtube.com/watch?v=…"));
    self.urlField.delegate = self;
    self.urlField.target = self;
    self.urlField.action = @selector(fieldAction:);
    self.urlField.accessibilityLabel = L(@"YouTube video link");
    self.urlError = OVWrapLabel(@"", 13, OVColor(OVRoleErr));
    self.urlError.hidden = YES;
    NSTextField *limit = OVWrapLabel([NSString stringWithFormat:L(@"One video only. Up to %ld minutes."), (long)kMaxMinutes], 13, OVColor(OVRoleMuted));
    NSStackView *link = OVVStack(@[self.urlField, self.urlError, limit], 8);
    OVFillWidth(@[self.urlField, self.urlError, limit], link);

    // 2. Permission (both required, never remembered)
    self.rightsBox = OVCheckbox(L(@"I own this recording or have the rights to use it"), @"");
    self.consentBox = OVCheckbox(L(@"The speaker has agreed that their voice is used for this"), @"");
    for (NSButton *b in @[self.rightsBox, self.consentBox]) { b.state = NSControlStateValueOff; b.target = self; b.action = @selector(boxChanged:); }
    self.rightsBox.accessibilityLabel = L(@"I own this recording or have the rights to use it");
    self.consentBox.accessibilityLabel = L(@"The speaker has agreed that their voice is used for this");
    NSStackView *perm = OVVStack(@[self.rightsBox, self.consentBox], 10);
    OVFillWidth(@[self.rightsBox, self.consentBox], perm);   // a long (Russian) title gets the full card width

    // 3. Progress
    self.bar = OVProgressBar();
    self.bar.hidden = YES;
    self.bar.accessibilityLabel = L(@"Download progress");
    self.status = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.updateButton = OVSmallPill(OVGhostButton(@"Update yt-dlp", nil, self, @selector(updateYtDlp:)));
    NSStackView *statusRow = OVHStack(@[self.status, OVSpacer(), self.updateButton], 10);
    NSStackView *prog = OVVStack(@[self.bar, statusRow], 10);
    OVFillWidth(@[self.bar, statusRow], prog);
    [self.status setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.cancelButton = OVGhostButton(L(@"Cancel"), nil, self, @selector(cancel:));
    self.cancelButton.keyEquivalent = @"\e";
    self.stopButton = OVGhostButton(L(@"Stop"), nil, self, @selector(stop:));
    self.stopButton.hidden = YES;
    self.goButton = OVPrimaryButton(L(@"Download audio"), self, @selector(start:));
    self.goButton.keyEquivalent = @"\r";
    NSStackView *buttons = OVHStack(@[OVSpacer(), self.cancelButton, self.stopButton, self.goButton], 10);
    buttons.edgeInsets = NSEdgeInsetsMake(14, 28, 16, 28);
    NSView *rule = [OVBoxView boxWithFill:OVColor(OVRoleBorder) border:nil radius:0];
    NSStackView *bottom = OVVStack(@[rule, buttons], 0);
    OVFillWidth(@[rule, buttons], bottom);
    [rule.heightAnchor constraintEqualToConstant:1].active = YES;

    NSScrollView *scroll = OVPageScroll(@[head, self.gate, self.offlineNotice, self.ffmpegNotice,
        OVStepCard(1, @"link", L(@"Video link"), nil, link),
        OVStepCard(2, @"checkmark.shield", L(@"Permission"), L(@"Both are required."), perm),
        OVStepCard(3, @"arrow.down.circle", L(@"Download"), nil, prog)]);
    NSView *root = [NSView new];
    for (NSView *v in @[scroll, bottom]) { v.translatesAutoresizingMaskIntoConstraints = NO; [root addSubview:v]; }
    [NSLayoutConstraint activateConstraints:@[
        [root.widthAnchor constraintEqualToConstant:560], [root.heightAnchor constraintEqualToConstant:660],
        [scroll.topAnchor constraintEqualToAnchor:root.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:bottom.topAnchor],
        [bottom.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [bottom.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [bottom.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];
    self.window.contentView = root;
    self.window.backgroundColor = OVColor(OVRoleBackground);
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(jobChanged:) name:OVJobsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refresh) name:OVNetworkModeDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(enginesChanged:) name:OVEnginesDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(windowActive:) name:NSWindowDidBecomeKeyNotification object:self.window];
    [OVExport resetFFmpegCache];
    [self refresh];
}

#pragma mark State

- (BOOL)running { return self.job.active; }

- (void)refresh {
    BOOL offline = OVNetwork.offline;
    BOOL ffmpeg = [OVExport ffmpegPath] != nil;
    NSString *reason = nil;
    NSString *typed = [self.urlField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL urlOK = OVYouTubeCheckURL(typed, nil, &reason);
    // the reason shows after the field was left, or while the text is long enough not to be a prefix of a link still being typed
    BOOL typedSomething = typed.length > 0 && (self.urlTouched || !IsLinkPrefix(typed));
    BOOL busy = self.running || self.starting || self.updateJob.active;
    self.offlineNotice.hidden = !offline;
    self.ffmpegNotice.hidden = ffmpeg;
    BOOL wasHidden = self.urlError.hidden;
    self.urlError.hidden = urlOK || !typedSomething;
    if (!self.urlError.hidden && ![self.urlError.stringValue isEqualToString:reason ?: @""]) {
        self.urlError.stringValue = reason ?: @"";
        NSAccessibilityPostNotificationWithUserInfo(self.urlError, NSAccessibilityAnnouncementRequestedNotification,
            @{NSAccessibilityAnnouncementKey: self.urlError.stringValue, NSAccessibilityPriorityKey: @(NSAccessibilityPriorityMedium)});
    }
    (void)wasHidden;
    BOOL formOn = self.gateReady && !self.running && !self.starting;
    self.urlField.enabled = formOn;
    self.rightsBox.enabled = formOn;
    self.consentBox.enabled = formOn;
    self.goButton.enabled = self.gateReady && !offline && ffmpeg && urlOK && !busy &&
        self.rightsBox.state == NSControlStateValueOn && self.consentBox.state == NSControlStateValueOn;
    self.stopButton.hidden = !self.running;
    self.updateButton.enabled = self.gateReady && !offline && !busy;
    NSString *ver = [self ytDlpVersion];
    self.updateButton.title = ver ? [NSString stringWithFormat:L(@"Update yt-dlp (%@)"), ver] : L(@"Update yt-dlp");
    self.updateButton.accessibilityLabel = self.updateButton.title;
}

/// Version of the installed yt-dlp, from its dist-info folder in the pro environment (the same place cns_engines.py reads).
- (void)enginesChanged:(NSNotification *)n { self.versionCached = NO; [self refresh]; }

- (NSString *)ytDlpVersion {
    if (self.versionCached) return self.cachedVersion;
    self.cachedVersion = [self readYtDlpVersion];
    self.versionCached = YES;
    return self.cachedVersion;
}

- (NSString *)readYtDlpVersion {
    NSString *py = [OVEngines pythonForEngine:@"ytdlp"];
    if (!py) return nil;
    NSString *venv = [[py stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *lib = [venv stringByAppendingPathComponent:@"lib"];
    for (NSString *pyDir in [fm contentsOfDirectoryAtPath:lib error:nil]) {
        NSString *site = [[lib stringByAppendingPathComponent:pyDir] stringByAppendingPathComponent:@"site-packages"];
        for (NSString *n in [fm contentsOfDirectoryAtPath:site error:nil])
            if ([n.lowercaseString hasPrefix:@"yt_dlp-"] && [n hasSuffix:@".dist-info"])
                return [n substringWithRange:NSMakeRange(7, n.length - 7 - 10)];
    }
    return nil;
}

- (void)setStatusText:(NSString *)t error:(BOOL)err {
    BOOL changed = ![self.status.stringValue isEqualToString:t ?: @""];
    self.status.stringValue = t ?: @"";
    self.status.textColor = OVColor(err ? OVRoleErr : OVRoleMuted);
    if (changed && t.length && (err || ![t hasPrefix:@"Downloading"]))
        NSAccessibilityPostNotificationWithUserInfo(self.status, NSAccessibilityAnnouncementRequestedNotification,
            @{NSAccessibilityAnnouncementKey: t, NSAccessibilityPriorityKey: @(err ? NSAccessibilityPriorityHigh : NSAccessibilityPriorityLow)});
}

- (void)windowActive:(NSNotification *)n { [OVExport resetFFmpegCache]; [self refresh]; }   // the user may have just installed ffmpeg
- (void)controlTextDidChange:(NSNotification *)n { [self refresh]; }
- (void)controlTextDidEndEditing:(NSNotification *)n { self.urlTouched = YES; [self refresh]; }
- (void)boxChanged:(id)sender { [self refresh]; }
- (void)fieldAction:(id)sender { if (self.goButton.enabled) [self start:nil]; }

#pragma mark Actions

- (void)start:(id)sender {
    NSString *canonical = nil, *reason = nil;
    if (!self.goButton.enabled) return;
    if (!OVYouTubeCheckURL(self.urlField.stringValue, &canonical, &reason)) { [self setStatusText:reason error:YES]; return; }
    [NSFileManager.defaultManager createDirectoryAtPath:self.destination withIntermediateDirectories:YES attributes:nil error:nil];
    // consent:true only here, after both boxes are on (the button is disabled otherwise)
    NSDictionary *req = @{@"url": canonical, @"consent": @YES, @"dest_dir": self.destination, @"max_minutes": @(kMaxMinutes)};
    [self setStatusText:L(@"Starting…") error:NO];
    self.bar.hidden = NO;
    self.bar.indeterminate = YES;
    [self.bar startAnimation:nil];
    self.starting = YES;
    [self refresh];
    [OVProRun submitKind:OVProKindYouTube request:req feature:L(@"YouTube import") window:self.window network:OVNetYouTube
              completion:^(OVJob *job, NSString *error) {
        self.starting = NO;
        if (!job) {   // declined (no text) or refused
            [self endProgress];
            [self setStatusText:error ?: L(@"Nothing was downloaded.") error:error != nil];
            [self refresh];
            return;
        }
        self.job = job;
        [self jobChanged:nil];
        [self refresh];
    }];
}

- (void)stop:(id)sender {
    if (self.job.active) { [OVJobs.shared stop:self.job]; [self setStatusText:L(@"Stopping…") error:NO]; }
}

- (void)cancel:(id)sender {   // Cancel also stops a running yt-dlp update
    if (self.job.active) [OVJobs.shared stop:self.job];
    if (self.updateJob.active) [OVJobs.shared stop:self.updateJob];
    [self.window.sheetParent endSheet:self.window];
}

- (void)updateYtDlp:(id)sender {
    NSString *err = nil;
    OVJob *j = [OVEngines.shared updateYtDlp:&err];
    if (!j) { [self setStatusText:err ?: L(@"yt-dlp could not be updated.") error:YES]; return; }
    self.updateJob = j;
    [self setStatusText:L(@"Updating yt-dlp…") error:NO];
    [self jobChanged:nil];
    [self refresh];
}

- (void)endProgress {
    [self.bar stopAnimation:nil];
    self.bar.indeterminate = NO;
    self.bar.hidden = YES;
}

- (void)jobChanged:(NSNotification *)n {
    OVJob *job = self.job;
    if (job && job.active) {
        self.bar.hidden = NO;
        if (job.progress < 0) { self.bar.indeterminate = YES; [self.bar startAnimation:nil]; }
        else { [self.bar stopAnimation:nil]; self.bar.indeterminate = NO; self.bar.doubleValue = job.progress; self.bar.accessibilityValueDescription = [NSString stringWithFormat:@"%d%%", (int)round(job.progress * 100)]; }
        [self setStatusText:job.status.length ? job.status : L(@"Downloading…") error:NO];
    } else if (job && !self.finished) {
        self.job = nil;
        [self endProgress];
        NSString *out = job.outputs.firstObject;
        if (job.state == OVJobSucceeded && out.length) {
            self.finished = YES;
            [self deliver:[NSURL fileURLWithPath:out]];
            [self.window.sheetParent endSheet:self.window];
            return;
        }
        if (job.state == OVJobStopped) [self setStatusText:L(@"Stopped.") error:NO];
        else [self setStatusText:job.error ?: L(@"The download failed. Check the link and try again.") error:YES];
        [self refresh];
    }
    OVJob *up = self.updateJob;
    if (up && !up.active) {
        self.updateJob = nil;
        [self endProgress];
        NSString *msg = up.state == OVJobSucceeded ? L(@"yt-dlp is up to date.") : (up.state == OVJobStopped ? L(@"Stopped.") : (up.error ?: L(@"yt-dlp could not be updated.")));
        [self setStatusText:msg error:up.state == OVJobFailed];
        self.versionCached = NO;
        [OVEngines.shared refresh];
        [self refresh];
    } else if (up) {
        self.bar.hidden = NO;
        self.bar.indeterminate = up.progress < 0;
        if (up.progress < 0) [self.bar startAnimation:nil]; else self.bar.doubleValue = up.progress;
        [self setStatusText:up.status.length ? up.status : L(@"Updating yt-dlp…") error:NO];
        [self refresh];
    }
}

/// The completion runs exactly once.
- (void)deliver:(NSURL *)file {
    void (^cb)(NSURL *) = self.completion;
    self.completion = nil;
    if (cb) cb(file);
}
@end
