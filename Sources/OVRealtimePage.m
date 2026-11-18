// Realtime page (task 7.9): live voice conversion through the microphone. The session is a job of kind rvc_realtime
// (the engine process loads the voice, ~3-15 s), the audio runs in OVRealtimeIO. The session lives in a process-wide
// object, not in the page: leaving the page or closing the window does not stop it, and coming back shows "Realtime is
// running" with a Stop button.
#import "OVPages.h"
#import "OVDesign.h"
#import "OVUI.h"
#import "OVLocale.h"
#import "OVJobs.h"
#import "OVEngines.h"
#import "OVProKit.h"
#import "OVPaths.h"
#import "OVAudioDevices.h"
#import "OVRealtimeIO.h"
#import <AVFoundation/AVFoundation.h>

static NSNotificationName const OVRtSessionDidChange = @"OVRtSessionDidChange";
static NSString *const kPreset = @"OVRtPreset", *const kBlock = @"OVRtBlock", *const kExtra = @"OVRtExtra", *const kCross = @"OVRtCrossfade",
                       *const kF0 = @"OVRtF0", *const kThreshold = @"OVRtSilentThreshold", *const kVad = @"OVRtVad", *const kVadSens = @"OVRtVadSensitivity",
                       *const kPitch = @"OVRtPitch", *const kIndex = @"OVRtIndexRate", *const kProtect = @"OVRtProtect",
                       *const kSpeakerOK = @"OVRtSpeakersConfirmed", *const kModel = @"OVRtModel", *const kInUID = @"OVRtInputUID", *const kOutUID = @"OVRtOutputUID";

typedef NS_ENUM(NSInteger, OVRtState) { OVRtIdle, OVRtStarting, OVRtLoading, OVRtConnecting, OVRtRunning, OVRtStopping };

/// The presets of the plan: block / extra / crossfade (seconds).
static NSArray<NSArray<NSNumber *> *> *Presets(void) { return @[@[@0.15, @0.10, @0.03], @[@0.20, @0.15, @0.05], @[@0.30, @0.25, @0.05]]; }

#pragma mark - Session (one per process)

@interface OVRtSession : NSObject
+ (instancetype)shared;
@property (readonly) OVRtState state;
@property (readonly, strong, nullable) OVRealtimeIO *io;
@property (readonly, strong, nullable) OVJob *job;
@property (readonly, copy, nullable) NSString *error;
@property (readonly, copy, nullable) NSDictionary *lastStats;     // the engine's own stats of the last finished session
@property (readonly, copy, nullable) NSDictionary *lastMeasured;   // {p50,p95,hw,count,dropped,underruns} when it stopped
- (void)startWithRequest:(NSDictionary *)request input:(OVAudioDevice *)input output:(OVAudioDevice *)output monitor:(BOOL)monitor
                  window:(nullable NSWindow *)window;
- (void)stop;
- (void)clearError;
@end

@implementation OVRtSession {
    NSInteger _generation;
}
@synthesize state = _state, io = _io, job = _job, error = _error, lastStats = _lastStats, lastMeasured = _lastMeasured;

+ (instancetype)shared {
    static OVRtSession *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [OVRtSession new];
        [NSNotificationCenter.defaultCenter addObserver:s selector:@selector(jobChanged:) name:OVJobsDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:s selector:@selector(appWillQuit:) name:NSApplicationWillTerminateNotification object:nil];
    });
    return s;
}

- (void)post { [NSNotificationCenter.defaultCenter postNotificationName:OVRtSessionDidChange object:self]; }
- (void)clearError { _error = nil; [self post]; }
- (void)appWillQuit:(NSNotification *)n { [_io stop]; }

- (void)startWithRequest:(NSDictionary *)request input:(OVAudioDevice *)input output:(OVAudioDevice *)output monitor:(BOOL)monitor window:(NSWindow *)window {
    if (_state != OVRtIdle) return;
    _state = OVRtStarting; _error = nil;
    NSInteger gen = ++_generation;
    [self post];
    [OVProRun submitKind:OVProKindRealtime request:request feature:L(@"Realtime") window:window network:(OVNetFeature)-1
              completion:^(OVJob *job, NSString *err) {
        if (gen != self->_generation || self->_state != OVRtStarting) { if (job) [OVJobs.shared stop:job]; return; }
        if (!job) { self->_state = OVRtIdle; self->_error = err; [self post]; return; }   // nil error: the user declined
        OVRealtimeIO *io = [[OVRealtimeIO alloc] initWithInput:input output:output blockSeconds:[request[@"block_s"] doubleValue]];
        if (!io) { self->_state = OVRtIdle; self->_error = L(@"Not enough memory for the audio buffers."); [OVJobs.shared stop:job]; [self post]; return; }
        io.monitorOwnVoice = monitor;
        io.onError = ^(NSString *message) { [self failWith:message]; };
        self->_io = io; self->_job = job; self->_state = OVRtLoading;
        [self post];
        [self jobChanged:nil];
    }];
}

- (void)failWith:(NSString *)message {
    if (_state == OVRtIdle || _state == OVRtStopping) return;
    _error = message;
    [self stop];
}

- (void)jobChanged:(NSNotification *)n {
    OVJob *job = _job;
    if (!job || _state == OVRtIdle || _state == OVRtStarting) return;
    if (job.active) {
        if (_state == OVRtLoading && job.state == OVJobRunning && [job.status isEqualToString:@"ready"]) [self connect];
        else [self post];   // the status line changes
        return;
    }
    // the process has ended: whatever the audio was doing, it is over
    OVRealtimeIO *io = _io;
    [self captureMeasured];
    _io = nil; _job = nil;
    NSDictionary *stats = job.result[@"stats"];
    if ([stats isKindOfClass:NSDictionary.class]) _lastStats = stats;
    if (job.state == OVJobFailed && !_error.length && _state != OVRtStopping) _error = job.error.length ? job.error : L(@"The voice engine stopped. Press Start to run it again.");
    _state = OVRtIdle;
    _generation++;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [io stop]; });
    [self post];
}

- (void)connect {
    _state = OVRtConnecting;
    [self post];
    OVRealtimeIO *io = _io;
    OVJob *job = _job;
    NSInteger gen = _generation;
    [io connectToSocket:[job.workDirectory stringByAppendingPathComponent:@"rt.sock"] timeout:30 completion:^(NSString *err) {
        if (gen != self->_generation || self->_state != OVRtConnecting) return;
        NSString *startError = err;
        if (!startError) { NSString *e = nil; if (![io startAudio:&e]) startError = e ?: L(@"The audio could not be started."); }
        if (startError) { self->_error = startError; [self stop]; return; }
        self->_state = OVRtRunning;
        [self post];
    }];
}

- (void)captureMeasured {
    OVRealtimeIO *io = _io;
    if (!io || !io.running) return;
    double p50 = 0, p95 = 0; uint64_t count = 0, dropped = 0, under = 0;
    [io getP50:&p50 p95:&p95 count:&count dropped:&dropped underruns:&under];
    _lastMeasured = @{@"p50": @(p50), @"p95": @(p95), @"hw": @(io.inputHardwareMs + io.outputHardwareMs), @"count": @(count), @"dropped": @(dropped), @"underruns": @(under)};
}

- (void)stop {
    if (_state == OVRtIdle || _state == OVRtStopping) return;
    OVRtState was = _state;
    _generation++;
    [self captureMeasured];
    _state = OVRtStopping;
    [self post];
    OVRealtimeIO *io = _io;
    OVJob *job = _job;
    if (was == OVRtStarting || !job) { _state = OVRtIdle; [self post]; return; }
    if (was == OVRtLoading || was == OVRtConnecting || job.state == OVJobQueued) {
        [OVJobs.shared stop:job];       // the engine is still loading: no session to end gracefully
    } else {
        // graceful: quit goes over the socket, the engine answers with its stats and the job Succeeds; after 6 s it is stopped
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ if (job.active) [OVJobs.shared stop:job]; });
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [io stop];
        dispatch_async(dispatch_get_main_queue(), ^{ [self jobChanged:nil]; });
    });
}

@end

#pragma mark - Page

@interface OVRealtimePage ()
@property (nonatomic) NSView *gate, *modelBlock;
@property (nonatomic) NSView *micCard, *speakerWarning, *bluetoothNote, *blackHoleBlock, *virtualFound, *emptyModels;
@property (nonatomic) OVPopup *inputPopup, *outputPopup, *modelPopup;
@property (nonatomic) OVSwitch *monitorSwitch, *vadSwitch;
@property (nonatomic) OVMeterBar *meter;
@property (nonatomic) OVSegmented *presetPicker, *f0Picker, *vadSensitivity;
@property (nonatomic) OVSliderRow *pitchRow, *indexRow, *protectRow, *blockRow, *extraRow, *crossRow, *thresholdRow;
@property (nonatomic) OVDisclosure *advanced;
@property (nonatomic) NSButton *startButton;
@property (nonatomic) NSStackView *badgeHost;
@property (nonatomic) NSTextField *statusLine, *errorLine, *monitorNote, *latencyBig, *latencyDetail, *latencyAdvice, *counters, *f0Note, *levelNote;
@property (nonatomic) NSArray<OVAudioDevice *> *inputs, *outputs;
@property (nonatomic) NSArray<NSDictionary *> *models;
@property (nonatomic) NSMutableArray *lockables;   // controls that cannot change while a session runs
@property (nonatomic) BOOL gateReady, built, monitorBlocked;
@property (nonatomic) NSTimer *timer;
@property (nonatomic) NSInteger tick;
@property (nonatomic) float levelValue;
@end

@implementation OVRealtimePage

#pragma mark Building

- (OVSliderRow *)sliderTitle:(NSString *)t hint:(NSString *)hint key:(NSString *)key min:(double)lo max:(double)hi format:(NSString *)fmt integer:(BOOL)integer {
    OVSliderRow *r = [OVSliderRow rowWithTitle:t hint:hint key:key min:lo max:hi format:fmt integer:integer];
    r.accessibilityName = t;
    return r;
}

- (NSView *)switchRow:(NSString *)title hint:(nullable NSString *)hint sw:(OVSwitch *)sw {
    sw.accessibilityLabel = title;
    NSTextField *l = OVLabel(title, 14, NSFontWeightSemibold, OVColor(OVRoleText));
    NSMutableArray *rows = [NSMutableArray arrayWithObject:OVHStack(@[l, OVSpacer(), sw], 12)];
    if (hint.length) [rows addObject:OVWrapLabel(hint, 13, OVColor(OVRoleMuted))];
    return OVFillStack(rows, 4);
}

- (void)loadView {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud registerDefaults:@{kPreset: @0, kBlock: @0.15, kExtra: @0.10, kCross: @0.03, kF0: @"rmvpe", kThreshold: @(-60), kVad: @YES, kVadSens: @2,
                           kPitch: @0, kIndex: @0.3, kProtect: @0.33}];
    self.lockables = [NSMutableArray array];
    __weak typeof(self) w = self;

    // Gate: the engine has to be installed (Voice engine + analysis weights)
    self.gate = OVEngineGateCard(L(@"Realtime"), @[@"pro-env", @"applio", @"rvc-core"], ^(BOOL ready) { w.gateReady = ready; [w updateUI]; });

    // 1 Devices
    self.inputPopup = [OVPopup popup]; self.inputPopup.accessibilityLabel = L(@"Input");
    self.inputPopup.target = self; self.inputPopup.action = @selector(devicePicked:);
    self.outputPopup = [OVPopup popup]; self.outputPopup.accessibilityLabel = L(@"Output");
    self.outputPopup.target = self; self.outputPopup.action = @selector(devicePicked:);
    self.speakerWarning = OVWrapLabel(L(@"Use headphones — speakers will feed back into the microphone"), 13, OVColor(OVRoleWarn));
    self.bluetoothNote = OVWrapLabel(L(@"Bluetooth adds 100–200 ms. A wired headset keeps the delay low."), 13, OVColor(OVRoleWarn));
    self.monitorNote = OVWrapLabel(@"", 13, OVColor(OVRoleWarn));
    self.monitorNote.hidden = YES;
    self.monitorSwitch = [OVSwitch new]; self.monitorSwitch.on = NO;   // feedback guard: never restored across launches
    self.monitorSwitch.target = self; self.monitorSwitch.action = @selector(monitorToggled:);
    self.meter = [OVMeterBar new]; self.meter.accessibilityLabel = L(@"Input level");
    self.levelNote = OVWrapLabel(L(@"The level shows while Realtime runs."), 13, OVColor(OVRoleMuted));
    self.virtualFound = OVLabel(L(@"Virtual device found"), 13, NSFontWeightRegular, OVColor(OVRoleMuted));
    self.blackHoleBlock = OVEmptyState(@"speaker.wave.2", L(@"Zoom or Discord?"),
        L(@"To use this in Zoom or Discord, install a virtual audio device such as BlackHole yourself, then choose it as the Output here. Clone'n'Speak installs no drivers."), @[]);
    NSView *devices = OVFillStack(@[OVColumns(@[OVFieldBlock(L(@"Input"), nil, OVFillPopup(self.inputPopup)),
                                               OVFieldBlock(L(@"Output"), nil, OVFillPopup(self.outputPopup))], 16),
                                    self.speakerWarning, self.bluetoothNote,
                                    [self switchRow:L(@"Monitor my own voice") hint:L(@"Plays your unprocessed voice into the output too. Off by default.") sw:self.monitorSwitch], self.monitorNote,
                                    OVFieldBlock(L(@"Input level"), nil, OVFillStack(@[self.meter, self.levelNote], 6)),
                                    self.virtualFound, self.blackHoleBlock], 14);
    [self.lockables addObjectsFromArray:@[self.inputPopup, self.outputPopup]];

    // 2 Voice
    self.modelPopup = [OVPopup popup]; self.modelPopup.accessibilityLabel = L(@"Voice");
    self.modelPopup.target = self; self.modelPopup.action = @selector(modelPicked:);
    self.emptyModels = OVWrapLabel(L(@"No voice models yet. Add one on the Models page, then come back."), 13, OVColor(OVRoleWarn));
    self.pitchRow = [self sliderTitle:L(@"Pitch") hint:L(@"Semitones: +12 is an octave up. Changes at once.") key:kPitch min:-24 max:24 format:@"%+.0f" integer:YES];
    self.indexRow = [self sliderTitle:L(@"Index rate") hint:L(@"How much of the model's own timbre to use. Changes at once.") key:kIndex min:0 max:1 format:@"%.2f" integer:NO];
    self.protectRow = [self sliderTitle:L(@"Protect") hint:L(@"Keeps consonants and breaths clear. Changes at once.") key:kProtect min:0 max:0.5 format:@"%.2f" integer:NO];
    self.pitchRow.onChange = ^{ [w liveChanged]; };
    self.indexRow.onChange = ^{ [w liveChanged]; };
    self.protectRow.onChange = ^{ [w liveChanged]; };
    self.modelBlock = OVFieldBlock(L(@"Voice model"), nil, OVFillPopup(self.modelPopup));
    NSView *voice = OVFillStack(@[self.modelBlock, self.emptyModels,
                                  self.pitchRow, self.indexRow, self.protectRow], 14);
    [self.lockables addObject:self.modelPopup];

    // 3 Quality and latency
    self.presetPicker = [OVSegmented segmentedWithItems:@[@[L(@"Low latency"), @""], @[L(@"Balanced"), @""], @[L(@"Quality"), @""]]];
    self.presetPicker.selectedIndex = [ud integerForKey:kPreset];
    self.presetPicker.target = self; self.presetPicker.action = @selector(presetPicked:);
    self.presetPicker.accessibilityLabel = L(@"Quality and latency");
    self.blockRow = [self sliderTitle:L(@"Block") hint:L(@"Audio is processed in blocks of this length: shorter means less delay, more load.") key:kBlock min:0.05 max:0.5 format:@"%.2f s" integer:NO];
    self.extraRow = [self sliderTitle:L(@"Extra context") hint:L(@"Earlier audio the model also sees. More is smoother and slower.") key:kExtra min:0 max:1 format:@"%.2f s" integer:NO];
    self.crossRow = [self sliderTitle:L(@"Crossfade") hint:L(@"Blend between blocks to hide the seams.") key:kCross min:0 max:0.2 format:@"%.2f s" integer:NO];
    for (OVSliderRow *r in @[self.blockRow, self.extraRow, self.crossRow]) { r.step = 0.01; r.onChange = ^{ w.presetPicker.selectedIndex = -1; [NSUserDefaults.standardUserDefaults setInteger:-1 forKey:kPreset]; }; }
    self.f0Picker = [OVSegmented segmentedWithItems:@[@[@"rmvpe", @""], @[@"fcpe", @""]]];
    self.f0Picker.selectedIndex = [[ud stringForKey:kF0] isEqualToString:@"fcpe"] ? 1 : 0;
    self.f0Picker.target = self; self.f0Picker.action = @selector(f0Picked:);
    self.f0Picker.accessibilityLabel = L(@"Pitch extraction");
    self.f0Note = OVWrapLabel(L(@"fcpe is faster. It needs the optional pitch add-on from the Models page."), 13, OVColor(OVRoleMuted));
    self.thresholdRow = [self sliderTitle:L(@"Silence threshold") hint:L(@"Quieter than this counts as silence (dB). Changes at once.") key:kThreshold min:-90 max:0 format:@"%.0f dB" integer:YES];
    self.thresholdRow.onChange = ^{ [w liveChanged]; };
    self.vadSwitch = [OVSwitch new]; self.vadSwitch.on = [ud boolForKey:kVad];
    self.vadSwitch.target = self; self.vadSwitch.action = @selector(vadToggled:);
    self.vadSensitivity = [OVSegmented segmentedWithItems:@[@[@"0", @""], @[@"1", @""], @[@"2", @""], @[@"3", @""]]];
    self.vadSensitivity.selectedIndex = [ud integerForKey:kVadSens];
    self.vadSensitivity.target = self; self.vadSensitivity.action = @selector(vadSensitivityPicked:);
    self.vadSensitivity.accessibilityLabel = L(@"Voice detection sensitivity");
    NSView *advancedBody = OVFillStack(@[self.blockRow, self.extraRow, self.crossRow,
                                         OVFieldBlock(L(@"Pitch extraction"), nil, OVFillStack(@[self.f0Picker, self.f0Note], 6)), self.thresholdRow,
                                         [self switchRow:L(@"Skip silence (voice detection)") hint:L(@"Does not run the model on pauses. Saves power.") sw:self.vadSwitch],
                                         OVFieldBlock(L(@"Sensitivity"), L(@"0 is lenient, 3 is strict."), self.vadSensitivity)], 14);
    self.advanced = [OVDisclosure disclosureWithTitle:L(@"Advanced") subtitle:nil symbol:nil content:advancedBody];
    NSView *quality = OVFillStack(@[self.presetPicker, self.advanced], 14);
    [self.lockables addObjectsFromArray:@[self.presetPicker, self.blockRow, self.extraRow, self.crossRow, self.f0Picker, self.vadSwitch, self.vadSensitivity]];

    // 4 Live
    self.startButton = OVButtonHeight(OVPrimaryButton(L(@"Start"), self, @selector(startStop:)), 48);
    self.badgeHost = OVVStack(@[], 0);
    self.statusLine = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.errorLine = OVWrapLabel(@"", 13, OVColor(OVRoleErr));
    self.errorLine.hidden = YES;
    self.latencyBig = OVLabel(@"—", 34, NSFontWeightBold, OVColor(OVRoleText));
    self.latencyBig.accessibilityLabel = L(@"Measured delay");
    self.latencyDetail = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.latencyAdvice = OVWrapLabel(L(@"Too slow for comfortable talking. Try a shorter block, the fcpe pitch method, closing heavy apps, and wired headphones instead of Bluetooth (Bluetooth adds 100–200 ms)."), 13, OVColor(OVRoleWarn));
    self.latencyAdvice.hidden = YES;
    self.counters = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    NSTextField *caption = OVWrapLabel(L(@"Measured on this Mac with your devices."), 13, OVColor(OVRoleMuted));
    self.micCard = OVEmptyState(@"mic.slash", L(@"Microphone access is off"),
        L(@"Clone'n'Speak needs the microphone to change your voice live. Nothing is recorded or kept."),
        @[OVGhostButton(L(@"Open Privacy Settings"), @"gearshape", self, @selector(openPrivacy:))]);
    self.micCard.hidden = YES;
    NSView *live = OVFillStack(@[self.micCard, OVHStack(@[self.startButton, self.badgeHost, OVSpacer()], 14), self.statusLine, self.errorLine,
                                 self.latencyBig, self.latencyDetail, self.latencyAdvice, self.counters, caption], 12);

    NSView *header = OVPageHeader(L(@"Realtime"), L(@"Change your voice live, through your microphone."), OVProBadge());
    self.view = OVPageScroll(@[header, self.gate,
                               OVStepCard(1, @"headphones", L(@"Devices"), nil, devices),
                               OVStepCard(2, @"person.wave.2", L(@"Voice"), nil, voice),
                               OVStepCard(3, @"gauge.with.dots.needle.67percent", L(@"Quality and latency"), nil, quality),
                               OVStepCard(4, @"dot.radiowaves.left.and.right", L(@"Live"), nil, live)]);
    self.startButton.accessibilityLabel = L(@"Start");

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(sessionChanged:) name:OVRtSessionDidChange object:nil];
    [nc addObserver:self selector:@selector(devicesChanged:) name:OVAudioDevicesDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(enginesChanged:) name:OVEnginesDidChangeNotification object:nil];
    [OVAudioDevices startObserving];
    [self reloadDevices];
    [self reloadModels];
    self.built = YES;
    [self updateUI];
}

- (void)dealloc {
    [self.timer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark Appearing

- (void)viewWillAppear {
    [super viewWillAppear];
    [self reloadDevices];
    [self reloadModels];
    [self checkMicrophone];
    [self updateUI];
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(poll:) userInfo:nil repeats:YES];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    [self.timer invalidate];
    self.timer = nil;   // the session goes on without the page
}

- (void)enginesChanged:(NSNotification *)n { [self updateUI]; }
- (void)sessionChanged:(NSNotification *)n { [self updateUI]; }
- (void)devicesChanged:(NSNotification *)n { if (OVRtSession.shared.state == OVRtIdle) [self reloadDevices]; }

#pragma mark Devices and models

static NSString *DeviceTitle(OVAudioDevice *d) {
    NSString *t = [OVAudioDevices transportName:d.transport];
    return d.transport == OVAudioTransportBuiltIn || d.transport == OVAudioTransportOther ? d.name : [NSString stringWithFormat:@"%@ · %@", d.name, t];
}

- (void)fillPopup:(OVPopup *)p devices:(NSArray<OVAudioDevice *> *)list savedUID:(NSString *)uid fallback:(OVAudioDevice *)def {
    [p removeAllItems];
    OVAudioDevice *pick = nil;
    for (OVAudioDevice *d in list) {
        [p addItemWithTitle:DeviceTitle(d)];
        p.lastItem.representedObject = d.uid;
        if (uid.length && [d.uid isEqualToString:uid]) pick = d;
    }
    if (!pick) for (OVAudioDevice *d in list) if (def && d.deviceID == def.deviceID) pick = d;
    if (!pick) pick = list.firstObject;
    if (pick) [p selectItemAtIndex:[list indexOfObject:pick]];
    if (!list.count) [p addItemWithTitle:p == self.inputPopup ? L(@"No microphone found") : L(@"No output device found")];
}

- (void)reloadDevices {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    self.inputs = OVAudioDevices.inputDevices;
    self.outputs = OVAudioDevices.outputDevices;
    [self fillPopup:self.inputPopup devices:self.inputs savedUID:[ud stringForKey:kInUID] fallback:OVAudioDevices.defaultInput];
    [self fillPopup:self.outputPopup devices:self.outputs savedUID:[ud stringForKey:kOutUID] fallback:OVAudioDevices.defaultOutput];
    BOOL blackHole = NO;
    for (OVAudioDevice *d in self.outputs) if ([OVAudioDevices isBlackHoleName:d.name]) blackHole = YES;
    self.blackHoleBlock.hidden = blackHole;
    self.virtualFound.hidden = !blackHole;
    [self updateDeviceNotes];
}

- (OVAudioDevice *)selectedInput {
    NSInteger i = self.inputPopup.indexOfSelectedItem;
    return i >= 0 && i < (NSInteger)self.inputs.count ? self.inputs[i] : nil;
}
- (OVAudioDevice *)selectedOutput {
    NSInteger i = self.outputPopup.indexOfSelectedItem;
    return i >= 0 && i < (NSInteger)self.outputs.count ? self.outputs[i] : nil;
}

- (void)updateDeviceNotes {
    OVAudioDevice *o = [self selectedOutput], *i = [self selectedInput];
    self.speakerWarning.hidden = !(o && o.isBuiltInSpeaker);
    self.bluetoothNote.hidden = !((o && o.transport == OVAudioTransportBluetooth) || (i && i.transport == OVAudioTransportBluetooth));
    // monitoring your own voice into speakers (or into the microphone's own device) feeds back
    NSString *why = nil;
    if (o && o.isBuiltInSpeaker) why = L(@"Monitoring is off while the output is the built-in speakers: it would feed back into the microphone.");
    else if (o && i && o.deviceID == i.deviceID) why = L(@"Monitoring is off while the input and the output are the same device: it would feed back.");
    self.monitorBlocked = why != nil;
    if (why) { self.monitorSwitch.on = NO; OVRtSession.shared.io.monitorOwnVoice = NO; }
    self.monitorNote.stringValue = why ?: @"";
    self.monitorNote.hidden = !why;
    if (self.built) self.monitorSwitch.enabled = self.gateReady && !self.monitorBlocked;
}

- (void)devicePicked:(id)sender {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    if ([self selectedInput]) [ud setObject:[self selectedInput].uid forKey:kInUID];
    if ([self selectedOutput]) [ud setObject:[self selectedOutput].uid forKey:kOutUID];
    [self updateDeviceNotes];
}

- (void)reloadModels {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = OVPaths.rvcModels;
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *n in [[fm contentsOfDirectoryAtPath:root error:nil] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) {
        NSString *dir = [root stringByAppendingPathComponent:n];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;
        BOOL hasPth = NO;
        for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) if ([f.pathExtension isEqualToString:@"pth"]) hasPth = YES;
        if (!hasPth) continue;
        NSDictionary *meta = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"meta.json"]] ?: [NSData data] options:0 error:nil];
        NSString *name = [meta isKindOfClass:NSDictionary.class] && [meta[@"name"] isKindOfClass:NSString.class] ? meta[@"name"] : n;
        [list addObject:@{@"name": name, @"path": dir}];
    }
    self.models = list;
    [self.modelPopup removeAllItems];
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:kModel];
    NSInteger sel = 0, idx = 0;
    for (NSDictionary *m in list) { [self.modelPopup addItemWithTitle:m[@"name"]]; if ([m[@"path"] isEqualToString:saved]) sel = idx; idx++; }
    if (list.count) [self.modelPopup selectItemAtIndex:sel];
    self.modelBlock.hidden = !list.count;
    self.emptyModels.hidden = list.count > 0;
}

- (void)modelPicked:(id)sender {
    NSInteger i = self.modelPopup.indexOfSelectedItem;
    if (i >= 0 && i < (NSInteger)self.models.count) [NSUserDefaults.standardUserDefaults setObject:self.models[i][@"path"] forKey:kModel];
}

#pragma mark Settings

- (void)presetPicked:(id)sender {
    NSInteger i = self.presetPicker.selectedIndex;
    if (i < 0 || i >= (NSInteger)Presets().count) return;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSArray *p = Presets()[i];
    [ud setDouble:[p[0] doubleValue] forKey:kBlock]; [ud setDouble:[p[1] doubleValue] forKey:kExtra]; [ud setDouble:[p[2] doubleValue] forKey:kCross];
    [ud setInteger:i forKey:kPreset];
    for (OVSliderRow *r in @[self.blockRow, self.extraRow, self.crossRow]) [r refresh];
}

- (void)f0Picked:(id)sender {
    NSString *m = self.f0Picker.selectedIndex == 1 ? @"fcpe" : @"rmvpe";
    if ([m isEqualToString:@"fcpe"]) {
        OVEngineComponent *c = [OVEngines.shared componentWithId:@"rvc-fcpe"];
        if (!c || c.state != OVEngineReady) {
            self.f0Picker.selectedIndex = 0; m = @"rmvpe";
            self.f0Note.textColor = OVColor(OVRoleWarn);
        }
    }
    if ([m isEqualToString:@"rmvpe"]) self.f0Note.textColor = OVColor(OVRoleMuted);
    [NSUserDefaults.standardUserDefaults setObject:m forKey:kF0];
}

- (void)monitorToggled:(id)sender {
    OVRtSession.shared.io.monitorOwnVoice = self.monitorSwitch.on;
}
- (void)vadToggled:(id)sender { [NSUserDefaults.standardUserDefaults setBool:self.vadSwitch.on forKey:kVad]; [self updateUI]; }
- (void)vadSensitivityPicked:(id)sender { [NSUserDefaults.standardUserDefaults setInteger:MAX(0, self.vadSensitivity.selectedIndex) forKey:kVadSens]; }

- (void)liveChanged {
    OVRealtimeIO *io = OVRtSession.shared.io;
    if (!io || !io.running) return;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [io sendSet:@{@"pitch": @((NSInteger)[ud integerForKey:kPitch]), @"index_rate": @([ud doubleForKey:kIndex]),
                  @"protect": @([ud doubleForKey:kProtect]), @"silent_threshold": @((double)[ud integerForKey:kThreshold])}];
}

#pragma mark Start and stop

- (void)checkMicrophone {
    AVAuthorizationStatus s = OVRealtimeIO.microphoneStatus;
    self.micCard.hidden = !(s == AVAuthorizationStatusDenied || s == AVAuthorizationStatusRestricted);
}

- (void)openPrivacy:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]];
}

- (void)startStop:(id)sender {
    OVRtSession *s = OVRtSession.shared;
    if (s.state != OVRtIdle) { [s stop]; return; }
    [s clearError];
    if (!self.gateReady) return;
    if (![self selectedInput] || ![self selectedOutput]) { [self showError:L(@"Choose an input and an output device first.")]; return; }
    if (self.models.count == 0 || self.modelPopup.indexOfSelectedItem < 0) { [self showError:L(@"Choose a voice model first.")]; return; }
    AVAuthorizationStatus st = OVRealtimeIO.microphoneStatus;
    if (st == AVAuthorizationStatusDenied || st == AVAuthorizationStatusRestricted) { [self checkMicrophone]; return; }
    if (st == AVAuthorizationStatusNotDetermined) {
        __weak typeof(self) w = self;
        [OVRealtimeIO requestMicrophoneAccess:^(BOOL granted) { [w checkMicrophone]; if (granted) [w beginSession]; }];
        return;
    }
    OVAudioDevice *outDev = [self selectedOutput];
    if (outDev.isBuiltInSpeaker && ![NSUserDefaults.standardUserDefaults boolForKey:kSpeakerOK]) {
        NSAlert *a = [NSAlert new];
        a.messageText = L(@"Use headphones");
        a.informativeText = L(@"The output is the built-in speakers. Your converted voice will play into the microphone and can howl. Headphones are strongly recommended.");
        [a addButtonWithTitle:L(@"Start anyway")];
        [a addButtonWithTitle:L(@"Cancel")];
        if ([a runModal] != NSAlertFirstButtonReturn) return;
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:kSpeakerOK];   // asked once
    }
    [self beginSession];
}

- (void)showError:(NSString *)text {
    self.errorLine.stringValue = text;
    self.errorLine.hidden = NO;
}

- (NSDictionary *)requestFromSettings {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSInteger m = self.modelPopup.indexOfSelectedItem;
    return @{@"model": self.models[m][@"path"],
             @"block_s": @([ud doubleForKey:kBlock]), @"extra_s": @([ud doubleForKey:kExtra]), @"crossfade_s": @([ud doubleForKey:kCross]),
             @"silent_threshold": @((double)[ud integerForKey:kThreshold]),
             @"vad": @{@"on": @([ud boolForKey:kVad]), @"sensitivity": @([ud integerForKey:kVadSens])},
             @"f0_method": [ud stringForKey:kF0] ?: @"rmvpe",
             @"pitch": @((NSInteger)[ud integerForKey:kPitch]), @"index_rate": @([ud doubleForKey:kIndex]), @"protect": @([ud doubleForKey:kProtect])};
}

- (void)beginSession {
    if (OVRtSession.shared.state != OVRtIdle) return;
    OVAudioDevice *in = [self selectedInput], *out = [self selectedOutput];
    if (!in || !out || self.models.count == 0) return;
    [self.errorLine setHidden:YES];
    [OVRtSession.shared startWithRequest:[self requestFromSettings] input:in output:out monitor:self.monitorSwitch.on window:self.view.window];
}

#pragma mark Refreshing

- (void)setBadge:(NSString *)text tone:(OVRole)tone {
    for (NSView *v in self.badgeHost.arrangedSubviews) { [self.badgeHost removeArrangedSubview:v]; [v removeFromSuperview]; }
    [self.badgeHost addArrangedSubview:OVBadge(text, tone)];
}

- (void)updateUI {
    if (!self.built) return;   // the gate reports synchronously while the page is still being built
    OVRtSession *s = OVRtSession.shared;
    BOOL idle = s.state == OVRtIdle;
    // lock what a running session cannot change
    for (id c in self.lockables) { if ([c respondsToSelector:@selector(setEnabled:)]) [c setEnabled:idle && self.gateReady]; }
    for (OVSliderRow *r in @[self.pitchRow, self.indexRow, self.protectRow, self.thresholdRow]) r.enabled = self.gateReady;
    self.monitorSwitch.enabled = self.gateReady && !self.monitorBlocked;
    self.vadSensitivity.enabled = idle && self.gateReady && self.vadSwitch.on;
    self.startButton.enabled = self.gateReady && s.state != OVRtStopping;
    self.startButton.title = idle ? L(@"Start") : L(@"Stop");
    self.startButton.accessibilityLabel = self.startButton.title;
    NSString *status = @""; NSString *badge = L(@"Stopped"); OVRole tone = OVRoleMuted;
    switch (s.state) {
        case OVRtIdle: break;
        case OVRtStarting: badge = L(@"Starting…"); tone = OVRoleAccent; status = L(@"Preparing: memory check and the voice engine."); break;
        case OVRtLoading:
            badge = L(@"Loading the voice…"); tone = OVRoleAccent;
            status = s.job.state == OVJobQueued ? L(@"Waiting for the previous task to finish.") : L(@"Loading the voice. This takes 3–15 seconds."); break;
        case OVRtConnecting: badge = L(@"Connecting…"); tone = OVRoleAccent; status = L(@"Connecting the microphone to the voice engine."); break;
        case OVRtRunning: badge = L(@"Realtime is running"); tone = OVRoleOK;
            status = L(@"Talk into the microphone. Realtime keeps running if you leave this page; press Stop here to end it."); break;
        case OVRtStopping: badge = L(@"Stopping…"); tone = OVRoleMuted; status = L(@"Stopping."); break;
    }
    [self setBadge:badge tone:tone];
    self.statusLine.stringValue = status;
    self.statusLine.hidden = !status.length;
    if (s.error.length) { self.errorLine.stringValue = s.error; self.errorLine.hidden = NO; }
    else if (!s.error.length && s.state != OVRtIdle) self.errorLine.hidden = YES;
    [self updateMetrics];
}

- (void)updateMetrics {
    OVRtSession *s = OVRtSession.shared;
    OVRealtimeIO *io = s.io;
    double p50 = 0, p95 = 0, hw = 0; uint64_t count = 0, dropped = 0, under = 0;
    BOOL live = io && io.running;
    if (live) {
        [io getP50:&p50 p95:&p95 count:&count dropped:&dropped underruns:&under];
        hw = io.inputHardwareMs + io.outputHardwareMs;
    } else if (s.lastMeasured) {
        NSDictionary *m = s.lastMeasured;
        p50 = [m[@"p50"] doubleValue]; p95 = [m[@"p95"] doubleValue]; hw = [m[@"hw"] doubleValue];
        count = [m[@"count"] unsignedLongLongValue]; dropped = [m[@"dropped"] unsignedLongLongValue]; under = [m[@"underruns"] unsignedLongLongValue];
    }
    if (count == 0) {
        self.latencyBig.stringValue = @"—";
        self.latencyBig.textColor = OVColor(OVRoleMuted);
        self.latencyDetail.stringValue = live ? L(@"Measuring… speak for a moment.") : L(@"The delay is measured while Realtime runs.");
        self.latencyAdvice.hidden = YES;
        self.counters.stringValue = @"";
        return;
    }
    double total = p95 + hw;
    self.latencyBig.stringValue = [NSString stringWithFormat:@"≈ %.0f ms", total];
    BOOL ok = total <= 300;
    self.latencyBig.textColor = OVColor(ok ? OVRoleOK : OVRoleWarn);
    self.latencyDetail.stringValue = [NSString stringWithFormat:L(@"p50 %.0f ms · p95 %.0f ms measured, plus %.0f ms in the audio hardware"), p50, p95, hw];
    self.latencyAdvice.hidden = ok;
    self.counters.stringValue = [NSString stringWithFormat:L(@"Dropped blocks: %llu · Underruns: %llu"), dropped, under];
}

- (void)poll:(NSTimer *)t {
    OVRtSession *s = OVRtSession.shared;
    OVRealtimeIO *io = s.io;
    if (io && io.running) {
        float peak = [io takeInputLevel];
        float db = peak > 0.00001f ? 20.0f * log10f(peak) : -90.0f;
        float v = fmaxf(0, fminf(100, (db + 36.0f) / 36.0f * 100.0f));
        self.levelValue = v > self.levelValue ? v : self.levelValue * 0.85f;   // fast attack, slow release
        self.meter.doubleValue = self.levelValue;
        self.levelNote.hidden = YES;
        [io checkHealth];
        if (++self.tick % 10 == 0) [self updateMetrics];
    } else if (self.levelValue > 0) {
        self.levelValue = 0; self.meter.doubleValue = 0; self.levelNote.hidden = NO;
    }
}

@end
