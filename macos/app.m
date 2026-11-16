#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <ServiceManagement/ServiceManagement.h>

typedef struct {
    uint32_t eye_minutes;
    uint32_t stand_minutes;
    uint32_t daily_stand_minutes;
    uint32_t snooze_minutes;
    uint32_t idle_seconds;
    bool count_media;
} SDConfig;

extern void sd_tick(double idle_seconds, bool screen_ready, bool media_assertion);
extern void sd_action(int action);
extern SDConfig sd_config(void);
extern void sd_apply_config(SDConfig config);
extern char *sd_settings_path(void);
extern void sd_free_string(char *value);
extern bool sd_use_settings_file(const char *path);
extern void sd_shutdown(void);

@interface SDTimelineView : NSView
@property (strong) NSData *activity;
@property (strong) NSData *standing;
@property (strong) NSData *eyeBreaks;
@property (assign) uint16_t currentMinute;
- (void)updateActivity:(const uint8_t *)activity
              standing:(const uint8_t *)standing
             eyeBreaks:(const uint16_t *)eyeBreaks
                 count:(NSUInteger)count
         currentMinute:(uint16_t)currentMinute;
@end

@interface SDAppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) NSPopover *popover;
@property (strong) NSWindow *settingsWindow;
@property (strong) NSTextField *trackingLabel;
@property (strong) NSImageView *trackingIcon;
@property (strong) NSTextField *eyeLabel;
@property (strong) NSTextField *standLabel;
@property (strong) NSTextField *dailyLabel;
@property (strong) SDTimelineView *timeline;
@property (strong) NSButton *eyeStartButton;
@property (strong) NSButton *eyeSnoozeButton;
@property (strong) NSButton *eyeDismissButton;
@property (strong) NSButton *standStartButton;
@property (strong) NSButton *standStopButton;
@property (strong) NSButton *standSnoozeButton;
@property (strong) NSButton *standDismissButton;
@property (strong) NSArray<NSTextField *> *settingsFields;
@property (strong) NSTextField *settingsPathLabel;
@property (strong) NSButton *mediaCheckbox;
@property (strong) NSButton *startupCheckbox;
@property (strong) id localMouseMonitor;
@property (strong) id globalMouseMonitor;
@property (assign) bool eyeDue;
@property (assign) bool standDue;
@property (assign) bool standing;
@end

static SDAppDelegate *doctor;

@implementation SDTimelineView

- (void)updateActivity:(const uint8_t *)activity
              standing:(const uint8_t *)standing
             eyeBreaks:(const uint16_t *)eyeBreaks
                 count:(NSUInteger)count
         currentMinute:(uint16_t)currentMinute {
    self.activity = [NSData dataWithBytes:activity length:1440];
    self.standing = [NSData dataWithBytes:standing length:1440];
    self.eyeBreaks = [NSData dataWithBytes:eyeBreaks length:count * sizeof(uint16_t)];
    self.currentMinute = currentMinute;
    [self setNeedsDisplay:YES];
}

- (void)drawText:(NSString *)text x:(CGFloat)x y:(CGFloat)y color:(NSColor *)color font:(NSFont *)font {
    [text drawAtPoint:NSMakePoint(x, y) withAttributes:@{
        NSForegroundColorAttributeName: color,
        NSFontAttributeName: font
    }];
}

- (void)drawActivity:(NSData *)data y:(CGFloat)y color:(NSColor *)color plotX:(CGFloat)plotX plotWidth:(CGFloat)plotWidth {
    if (data.length != 1440) return;
    const uint8_t *minutes = data.bytes;
    [color setFill];
    for (NSUInteger start = 0; start < 1440;) {
        if (minutes[start] == 0) { start++; continue; }
        NSUInteger end = start + 1;
        while (end < 1440 && minutes[end] > 0) end++;
        CGFloat x = plotX + plotWidth * start / 1440.0;
        CGFloat width = MAX(1.0, plotWidth * (end - start) / 1440.0);
        NSRectFill(NSMakeRect(x, y, width, 10));
        start = end;
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect bounds = self.bounds;
    CGFloat plotX = 77;
    CGFloat plotWidth = bounds.size.width - plotX - 12;
    NSBezierPath *background = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 1, 1) xRadius:8 yRadius:8];
    [[NSColor.controlBackgroundColor colorWithAlphaComponent:0.48] setFill];
    [background fill];

    NSColor *secondary = NSColor.secondaryLabelColor;
    NSFont *small = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    [self drawText:@"TODAY · 00:00–24:00" x:11 y:76 color:secondary font:small];
    [self drawText:@"Screen" x:11 y:54 color:NSColor.labelColor font:small];
    [self drawText:@"Standing" x:11 y:35 color:NSColor.labelColor font:small];
    [self drawText:@"Eye breaks" x:11 y:16 color:NSColor.labelColor font:small];
    [NSColor.systemTealColor setFill];
    NSRectFill(NSMakeRect(67, 57, 6, 6));
    [NSColor.systemOrangeColor setFill];
    NSRectFill(NSMakeRect(67, 38, 6, 6));
    [NSColor.systemPinkColor setFill];
    NSRectFill(NSMakeRect(67, 19, 6, 6));

    [[NSColor.separatorColor colorWithAlphaComponent:0.32] setFill];
    for (CGFloat y = 54; y >= 16; y -= 19) {
        NSRectFill(NSMakeRect(plotX, y, plotWidth, 10));
    }
    for (NSUInteger tick = 0; tick <= 4; tick++) {
        CGFloat x = plotX + plotWidth * tick / 4.0;
        [[NSColor.secondaryLabelColor colorWithAlphaComponent:0.22] setFill];
        NSRectFill(NSMakeRect(x, 14, 1, 51));
        NSString *time = [NSString stringWithFormat:@"%02lu", (unsigned long)tick * 6];
        CGFloat labelX = tick == 4 ? x - 12 : x - 6;
        [self drawText:time x:labelX y:1 color:secondary font:small];
    }

    [self drawActivity:self.activity y:54 color:NSColor.systemTealColor plotX:plotX plotWidth:plotWidth];
    [self drawActivity:self.standing y:35 color:NSColor.systemOrangeColor plotX:plotX plotWidth:plotWidth];
    const uint16_t *eyeMinutes = self.eyeBreaks.bytes;
    [[NSColor.systemPinkColor colorWithAlphaComponent:0.95] setFill];
    for (NSUInteger index = 0; index < self.eyeBreaks.length / sizeof(uint16_t); index++) {
        CGFloat x = plotX + plotWidth * eyeMinutes[index] / 1440.0;
        NSRectFill(NSMakeRect(x - 1, 14, 2, 14));
    }
    CGFloat nowX = plotX + plotWidth * self.currentMinute / 1440.0;
    [[NSColor.labelColor colorWithAlphaComponent:0.62] setFill];
    NSRectFill(NSMakeRect(nowX, 14, 1, 51));
}
@end

static NSTextField *label(NSString *text, NSRect frame, BOOL bold) {
    NSTextField *field = [NSTextField labelWithString:text];
    field.frame = frame;
    field.font = bold ? [NSFont boldSystemFontOfSize:13] : [NSFont systemFontOfSize:12];
    field.lineBreakMode = NSLineBreakByTruncatingTail;
    return field;
}

static NSButton *button(NSString *title, NSRect frame, id target, SEL action, int tag) {
    NSButton *control = [NSButton buttonWithTitle:title target:target action:action];
    control.frame = frame;
    control.bezelStyle = NSBezelStyleRounded;
    control.tag = tag;
    return control;
}

static BOOL screenReady(void) {
    if (CGDisplayIsAsleep(CGMainDisplayID())) return NO;
    CFDictionaryRef session = CGSessionCopyCurrentDictionary();
    if (!session) return NO;
    NSDictionary *details = CFBridgingRelease(session);
    NSNumber *onConsole = details[@"kCGSSessionOnConsoleKey"];
    NSNumber *locked = details[@"CGSSessionScreenIsLocked"];
    return onConsole.boolValue && !locked.boolValue;
}

static BOOL mediaKeepsDisplayAwake(void) {
    CFDictionaryRef status = NULL;
    if (IOPMCopyAssertionsStatus(&status) != kIOReturnSuccess || !status) return NO;
    NSDictionary *assertions = CFBridgingRelease(status);
    NSNumber *value = assertions[@"PreventUserIdleDisplaySleep"];
    return value.integerValue > 0;
}

@implementation SDAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(togglePopover:);
    [self makePopover];
    [self updateActivity];
    [self installClickAwayMonitors];
    [NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(updateActivity) userInfo:nil repeats:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    if (self.localMouseMonitor) [NSEvent removeMonitor:self.localMouseMonitor];
    if (self.globalMouseMonitor) [NSEvent removeMonitor:self.globalMouseMonitor];
    sd_shutdown();
}

- (void)installClickAwayMonitors {
    __weak typeof(self) weakSelf = self;
    NSEventMask clicks = NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown;
    self.localMouseMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:clicks handler:^NSEvent *(NSEvent *event) {
        SDAppDelegate *owner = weakSelf;
        if (owner.popover.isShown && event.window != owner.popover.contentViewController.view.window
            && event.window != owner.statusItem.button.window) {
            [owner.popover performClose:nil];
        }
        return event;
    }];
    self.globalMouseMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:clicks handler:^(NSEvent *event) {
        (void)event;
        SDAppDelegate *owner = weakSelf;
        if (owner.popover.isShown) [owner.popover performClose:nil];
    }];
}

- (void)makePopover {
    NSViewController *controller = [[NSViewController alloc] init];
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 336, 330)];
    controller.view = view;

    NSTextField *title = label(@"Screen Doctor", NSMakeRect(18, 297, 180, 23), YES);
    title.font = [NSFont boldSystemFontOfSize:15];
    [view addSubview:title];
    self.trackingLabel = label(@"Idle", NSMakeRect(218, 299, 79, 20), NO);
    self.trackingLabel.alignment = NSTextAlignmentRight;
    NSFontDescriptor *italic = [[NSFont systemFontOfSize:12].fontDescriptor fontDescriptorWithSymbolicTraits:NSFontDescriptorTraitItalic];
    self.trackingLabel.font = [NSFont fontWithDescriptor:italic size:12] ?: [NSFont systemFontOfSize:12];
    self.trackingLabel.textColor = NSColor.secondaryLabelColor;
    [view addSubview:self.trackingLabel];
    self.trackingIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(304, 301, 15, 15)];
    [view addSubview:self.trackingIcon];
    NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(18, 286, 304, 1)];
    separator.boxType = NSBoxSeparator;
    [view addSubview:separator];

    self.eyeLabel = label(@"", NSMakeRect(18, 244, 146, 20), YES);
    [view addSubview:self.eyeLabel];
    self.eyeStartButton = button(@"Start eye break", NSMakeRect(18, 239, 144, 28), self, @selector(performAction:), 3);
    self.eyeSnoozeButton = button(@"Snooze", NSMakeRect(170, 239, 72, 28), self, @selector(performAction:), 2);
    self.eyeDismissButton = button(@"Dismiss", NSMakeRect(246, 239, 76, 28), self, @selector(performAction:), 1);
    for (NSButton *control in @[self.eyeStartButton, self.eyeSnoozeButton, self.eyeDismissButton]) [view addSubview:control];

    self.standLabel = label(@"", NSMakeRect(18, 198, 146, 20), YES);
    [view addSubview:self.standLabel];
    self.dailyLabel = label(@"", NSMakeRect(18, 174, 300, 18), NO);
    [view addSubview:self.dailyLabel];
    self.standStartButton = button(@"Start standing", NSMakeRect(18, 140, 126, 28), self, @selector(performAction:), 5);
    self.standStopButton = button(@"Stop standing", NSMakeRect(18, 140, 126, 28), self, @selector(performAction:), 6);
    self.standSnoozeButton = button(@"Snooze", NSMakeRect(170, 193, 72, 28), self, @selector(performAction:), 7);
    self.standDismissButton = button(@"Dismiss", NSMakeRect(246, 193, 76, 28), self, @selector(performAction:), 8);
    for (NSButton *control in @[self.standStartButton, self.standStopButton, self.standSnoozeButton, self.standDismissButton]) [view addSubview:control];

    self.timeline = [[SDTimelineView alloc] initWithFrame:NSMakeRect(8, 39, 320, 93)];
    self.timeline.accessibilityLabel = @"Today from 00:00 to 24:00: screen activity, standing, and eye breaks";
    [view addSubview:self.timeline];

    [view addSubview:button(@"Settings…", NSMakeRect(18, 7, 100, 28), self, @selector(openSettings:), 0)];
    [view addSubview:button(@"Quit", NSMakeRect(250, 7, 72, 28), NSApp, @selector(terminate:), 0)];

    self.popover = [[NSPopover alloc] init];
    self.popover.contentViewController = controller;
    self.popover.behavior = NSPopoverBehaviorTransient;
}

- (void)updateActivity {
    double idle = CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType);
    sd_tick(idle, screenReady(), mediaKeepsDisplayAwake());
}

- (void)togglePopover:(id)sender {
    (void)sender;
    if (self.popover.isShown) [self.popover performClose:nil];
    else [self showPopover];
}

- (void)showPopover {
    NSButton *anchor = self.statusItem.button;
    [self.popover showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSRectEdgeMinY];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)performAction:(NSButton *)sender {
    sd_action((int)sender.tag);
}

- (void)presentActive:(BOOL)active
               media:(BOOL)media
            reminder:(uint8_t)reminder
                 eye:(NSString *)eye
               stand:(NSString *)stand
               daily:(NSString *)daily
            standing:(BOOL)standing
       activeMinutes:(const uint8_t *)activeMinutes
     standingMinutes:(const uint8_t *)standingMinutes
     eyeBreakMinutes:(const uint16_t *)eyeBreakMinutes
       eyeBreakCount:(NSUInteger)eyeBreakCount
       currentMinute:(uint16_t)currentMinute {
    NSButton *anchor = self.statusItem.button;
    NSString *symbol = active ? @"eye.fill" : @"eye.slash";
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:active ? @"screen_doctor tracking" : @"screen_doctor paused"];
    image.template = YES;
    anchor.image = image;
    anchor.toolTip = active ? (media ? @"screen_doctor: tracking possible media playback" : @"screen_doctor: tracking activity") : @"screen_doctor: paused while away or screen locked";
    self.trackingLabel.stringValue = active ? @"Tracking" : @"Idle";
    NSImage *trackingImage = [NSImage imageWithSystemSymbolName:active ? @"eye.fill" : @"pause.circle"
                                              accessibilityDescription:active ? @"Tracking" : @"Idle"];
    trackingImage.template = YES;
    self.trackingIcon.image = trackingImage;
    self.eyeLabel.stringValue = eye;
    self.standLabel.stringValue = stand;
    self.dailyLabel.stringValue = daily;
    [self.timeline updateActivity:activeMinutes standing:standingMinutes eyeBreaks:eyeBreakMinutes count:eyeBreakCount currentMinute:currentMinute];
    self.eyeDue = [eye isEqualToString:@"Eye break due now"];
    self.standDue = [stand isEqualToString:@"Time to stand"];
    self.standing = standing;
    self.eyeStartButton.hidden = !self.eyeDue;
    self.eyeLabel.hidden = self.eyeDue;
    self.eyeSnoozeButton.enabled = self.eyeDue;
    self.eyeDismissButton.enabled = self.eyeDue;
    self.standStartButton.hidden = standing;
    self.standStopButton.hidden = !standing;
    self.standSnoozeButton.enabled = self.standDue;
    self.standDismissButton.enabled = self.standDue;
    if (reminder != 0 && !self.popover.isShown) [self showPopover];
}

- (void)openSettings:(id)sender {
    (void)sender;
    [self.popover performClose:nil];
    if (self.settingsWindow) {
        [self.settingsWindow makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        return;
    }
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 420, 430)
                                                     styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                       backing:NSBackingStoreBuffered defer:NO];
    window.title = @"screen_doctor Settings";
    window.releasedWhenClosed = NO;
    NSView *view = window.contentView;
    SDConfig config = sd_config();
    NSArray<NSString *> *names = @[@"Eye interval (active minutes)", @"Stand interval (active minutes)", @"Daily standing goal (minutes)", @"Snooze (minutes)", @"Away after no input (seconds)"];
    uint32_t values[] = {config.eye_minutes, config.stand_minutes, config.daily_stand_minutes, config.snooze_minutes, config.idle_seconds};
    NSMutableArray<NSTextField *> *fields = [NSMutableArray array];
    for (int i = 0; i < 5; i++) {
        CGFloat y = 382 - 43 * i;
        [view addSubview:label(names[i], NSMakeRect(18, y, 277, 20), NO)];
        NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(304, y - 2, 90, 24)];
        field.integerValue = values[i];
        [view addSubview:field];
        [fields addObject:field];
    }
    self.settingsFields = fields;
    self.mediaCheckbox = [NSButton checkboxWithTitle:@"Count display-awake media playback as activity" target:nil action:nil];
    self.mediaCheckbox.frame = NSMakeRect(18, 160, 380, 22);
    self.mediaCheckbox.state = config.count_media ? NSControlStateValueOn : NSControlStateValueOff;
    [view addSubview:self.mediaCheckbox];
    self.startupCheckbox = [NSButton checkboxWithTitle:@"Launch at login" target:nil action:nil];
    self.startupCheckbox.frame = NSMakeRect(18, 131, 380, 22);
    self.startupCheckbox.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [view addSubview:self.startupCheckbox];
    [view addSubview:label(@"Settings file", NSMakeRect(18, 104, 380, 19), YES)];
    self.settingsPathLabel = label(@"", NSMakeRect(18, 83, 380, 19), NO);
    self.settingsPathLabel.textColor = NSColor.secondaryLabelColor;
    [view addSubview:self.settingsPathLabel];
    [view addSubview:button(@"Choose…", NSMakeRect(18, 46, 100, 28), self, @selector(chooseSettingsFile:), 0)];
    [view addSubview:button(@"Use Default", NSMakeRect(124, 46, 110, 28), self, @selector(useDefaultSettingsFile:), 0)];
    [self refreshSettingsPath];
    [view addSubview:button(@"Save", NSMakeRect(304, 12, 90, 29), self, @selector(saveSettings:), 0)];
    [window center];
    self.settingsWindow = window;
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)refreshSettingsPath {
    char *path = sd_settings_path();
    self.settingsPathLabel.stringValue = path ? [NSString stringWithUTF8String:path] : @"";
    self.settingsPathLabel.toolTip = self.settingsPathLabel.stringValue;
    sd_free_string(path);
}

- (void)showInvalidSettingsFile {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Could not open settings file";
    alert.informativeText = @"Choose an existing, readable settings.toml with valid settings.";
    [alert beginSheetModalForWindow:self.settingsWindow completionHandler:nil];
}

- (void)refreshSettingsValues {
    SDConfig config = sd_config();
    uint32_t values[] = {config.eye_minutes, config.stand_minutes, config.daily_stand_minutes, config.snooze_minutes, config.idle_seconds};
    for (int i = 0; i < 5; i++) self.settingsFields[i].integerValue = values[i];
    self.mediaCheckbox.state = config.count_media ? NSControlStateValueOn : NSControlStateValueOff;
    [self refreshSettingsPath];
}

- (void)chooseSettingsFile:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    [panel beginSheetModalForWindow:self.settingsWindow completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        if (!sd_use_settings_file(panel.URL.path.UTF8String)) {
            [self showInvalidSettingsFile];
            return;
        }
        [self refreshSettingsValues];
    }];
}

- (void)useDefaultSettingsFile:(id)sender {
    (void)sender;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/screen_doctor/settings.toml"];
    if (!sd_use_settings_file(path.UTF8String)) {
        [self showInvalidSettingsFile];
        return;
    }
    [self refreshSettingsValues];
}

- (void)saveSettings:(id)sender {
    (void)sender;
    SDConfig config = sd_config();
    uint32_t *values[] = {&config.eye_minutes, &config.stand_minutes, &config.daily_stand_minutes, &config.snooze_minutes, &config.idle_seconds};
    int limits[] = {240, 240, 480, 60, 900};
    for (int i = 0; i < 5; i++) {
        NSInteger input = self.settingsFields[i].integerValue;
        if (input < 1 || input > limits[i] || (i == 4 && input < 15)) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Please enter a valid positive interval.";
            alert.informativeText = [NSString stringWithFormat:@"%@ must be between %d and %d.", @[@"Eye interval", @"Stand interval", @"Daily goal", @"Snooze", @"Away threshold"][i], i == 4 ? 15 : 1, limits[i]];
            [alert beginSheetModalForWindow:self.settingsWindow completionHandler:nil];
            return;
        }
        *values[i] = (uint32_t)input;
    }
    config.count_media = self.mediaCheckbox.state == NSControlStateValueOn;
    sd_apply_config(config);
    SMAppService *service = SMAppService.mainAppService;
    BOOL wantStartup = self.startupCheckbox.state == NSControlStateValueOn;
    BOOL registered = service.status == SMAppServiceStatusEnabled;
    if (wantStartup != registered) {
        NSError *error = nil;
        BOOL success = wantStartup ? [service registerAndReturnError:&error] : [service unregisterAndReturnError:&error];
        if (!success) {
            NSAlert *alert = [NSAlert alertWithError:error];
            alert.messageText = @"Launch at login could not be changed";
            [alert beginSheetModalForWindow:self.settingsWindow completionHandler:nil];
            return;
        }
    }
    [self.settingsWindow close];
}
@end

void sd_present(bool active, bool media, uint8_t reminder, const char *eye, const char *stand, const char *daily, bool standing,
                const uint8_t *active_minutes, const uint8_t *standing_minutes,
                const uint16_t *eye_break_minutes, size_t eye_break_count, uint16_t current_minute) {
    [doctor presentActive:active media:media reminder:reminder
                     eye:[NSString stringWithUTF8String:eye]
                   stand:[NSString stringWithUTF8String:stand]
                   daily:[NSString stringWithUTF8String:daily]
              standing:standing
         activeMinutes:active_minutes
       standingMinutes:standing_minutes
       eyeBreakMinutes:eye_break_minutes
         eyeBreakCount:eye_break_count
         currentMinute:current_minute];
}

void sd_app_run(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        doctor = [[SDAppDelegate alloc] init];
        app.delegate = doctor;
        [app run];
    }
}
