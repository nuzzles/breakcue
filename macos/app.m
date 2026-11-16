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
extern void sd_shutdown(void);

@interface SDAppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) NSPopover *popover;
@property (strong) NSWindow *settingsWindow;
@property (strong) NSTextField *stateLabel;
@property (strong) NSTextField *eyeLabel;
@property (strong) NSTextField *standLabel;
@property (strong) NSTextField *dailyLabel;
@property (strong) NSButton *eyeStartButton;
@property (strong) NSButton *eyeSnoozeButton;
@property (strong) NSButton *eyeDismissButton;
@property (strong) NSButton *standStartButton;
@property (strong) NSButton *standStopButton;
@property (strong) NSButton *standSnoozeButton;
@property (strong) NSButton *standDismissButton;
@property (strong) NSArray<NSTextField *> *settingsFields;
@property (strong) NSButton *mediaCheckbox;
@property (strong) NSButton *startupCheckbox;
@property (assign) bool eyeDue;
@property (assign) bool standDue;
@property (assign) bool standing;
@end

static SDAppDelegate *doctor;

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
    [NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(updateActivity) userInfo:nil repeats:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    sd_shutdown();
}

- (void)makePopover {
    NSViewController *controller = [[NSViewController alloc] init];
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 336, 292)];
    controller.view = view;

    [view addSubview:label(@"screen_doctor", NSMakeRect(18, 258, 300, 23), YES)];
    self.stateLabel = label(@"Checking activity…", NSMakeRect(18, 235, 300, 19), NO);
    [view addSubview:self.stateLabel];
    self.eyeLabel = label(@"", NSMakeRect(18, 202, 300, 20), YES);
    [view addSubview:self.eyeLabel];
    self.eyeStartButton = button(@"Start 20-second look", NSMakeRect(18, 168, 144, 28), self, @selector(performAction:), 3);
    self.eyeSnoozeButton = button(@"Snooze", NSMakeRect(170, 168, 72, 28), self, @selector(performAction:), 2);
    self.eyeDismissButton = button(@"Dismiss", NSMakeRect(246, 168, 76, 28), self, @selector(performAction:), 1);
    for (NSButton *control in @[self.eyeStartButton, self.eyeSnoozeButton, self.eyeDismissButton]) [view addSubview:control];

    self.standLabel = label(@"", NSMakeRect(18, 132, 300, 20), YES);
    [view addSubview:self.standLabel];
    self.dailyLabel = label(@"", NSMakeRect(18, 113, 300, 18), NO);
    [view addSubview:self.dailyLabel];
    self.standStartButton = button(@"Start standing", NSMakeRect(18, 78, 126, 28), self, @selector(performAction:), 5);
    self.standStopButton = button(@"Stop standing", NSMakeRect(18, 78, 126, 28), self, @selector(performAction:), 6);
    self.standSnoozeButton = button(@"Snooze", NSMakeRect(170, 78, 72, 28), self, @selector(performAction:), 7);
    self.standDismissButton = button(@"Dismiss", NSMakeRect(246, 78, 76, 28), self, @selector(performAction:), 8);
    for (NSButton *control in @[self.standStartButton, self.standStopButton, self.standSnoozeButton, self.standDismissButton]) [view addSubview:control];

    [view addSubview:button(@"Settings…", NSMakeRect(18, 17, 100, 28), self, @selector(openSettings:), 0)];
    [view addSubview:button(@"Quit", NSMakeRect(250, 17, 72, 28), NSApp, @selector(terminate:), 0)];

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
            standing:(BOOL)standing {
    NSButton *anchor = self.statusItem.button;
    NSString *symbol = active ? @"eye.fill" : @"eye.slash";
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:active ? @"screen_doctor tracking" : @"screen_doctor paused"];
    image.template = YES;
    anchor.image = image;
    anchor.contentTintColor = active ? NSColor.systemGreenColor : NSColor.secondaryLabelColor;
    anchor.toolTip = active ? (media ? @"screen_doctor: tracking possible media playback" : @"screen_doctor: tracking activity") : @"screen_doctor: paused while away or screen locked";
    self.stateLabel.stringValue = active ? (media ? @"Tracking · input or media playback" : @"Tracking · recent input") : @"Paused · away, locked, or display asleep";
    self.eyeLabel.stringValue = eye;
    self.standLabel.stringValue = stand;
    self.dailyLabel.stringValue = daily;
    self.eyeDue = [eye isEqualToString:@"Eye break due now"];
    self.standDue = [stand isEqualToString:@"Time to stand"];
    self.standing = standing;
    self.eyeStartButton.hidden = !self.eyeDue;
    self.eyeSnoozeButton.hidden = !self.eyeDue;
    self.eyeDismissButton.hidden = !self.eyeDue;
    self.standStartButton.hidden = standing;
    self.standStopButton.hidden = !standing;
    self.standSnoozeButton.hidden = !self.standDue;
    self.standDismissButton.hidden = !self.standDue;
    if (reminder != 0 && !self.popover.isShown) [self showPopover];
}

- (void)openSettings:(id)sender {
    (void)sender;
    if (self.settingsWindow) {
        [self.settingsWindow makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        return;
    }
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 420, 352)
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
        CGFloat y = 304 - 43 * i;
        [view addSubview:label(names[i], NSMakeRect(18, y, 277, 20), NO)];
        NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(304, y - 2, 90, 24)];
        field.integerValue = values[i];
        [view addSubview:field];
        [fields addObject:field];
    }
    self.settingsFields = fields;
    self.mediaCheckbox = [NSButton checkboxWithTitle:@"Count display-awake media playback as activity" target:nil action:nil];
    self.mediaCheckbox.frame = NSMakeRect(18, 78, 380, 22);
    self.mediaCheckbox.state = config.count_media ? NSControlStateValueOn : NSControlStateValueOff;
    [view addSubview:self.mediaCheckbox];
    self.startupCheckbox = [NSButton checkboxWithTitle:@"Launch at login" target:nil action:nil];
    self.startupCheckbox.frame = NSMakeRect(18, 49, 380, 22);
    self.startupCheckbox.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [view addSubview:self.startupCheckbox];
    [view addSubview:button(@"Save", NSMakeRect(304, 12, 90, 29), self, @selector(saveSettings:), 0)];
    [window center];
    self.settingsWindow = window;
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
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

void sd_present(bool active, bool media, uint8_t reminder, const char *eye, const char *stand, const char *daily, bool standing) {
    [doctor presentActive:active media:media reminder:reminder
                     eye:[NSString stringWithUTF8String:eye]
                   stand:[NSString stringWithUTF8String:stand]
                   daily:[NSString stringWithUTF8String:daily]
              standing:standing];
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
