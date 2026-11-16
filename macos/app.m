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
    uint32_t sound;
} BCConfig;

extern void bc_tick(double idle_seconds, bool screen_ready, bool media_assertion);
extern void bc_action(int action);
extern BCConfig bc_config(void);
extern void bc_apply_config(BCConfig config);
extern char *bc_settings_path(void);
extern void bc_free_string(char *value);
extern bool bc_use_settings_file(const char *path);
extern void bc_shutdown(void);

@interface BCTimelineView : NSView
@property (strong) NSData *activity;
@property (strong) NSData *standing;
@property (strong) NSData *eyeBreaks;
@property (strong) NSData *eyeResets;
@property (strong) NSString *standingGoal;
@property (assign) uint16_t currentMinute;
- (void)updateActivity:(const uint8_t *)activity
              standing:(const uint8_t *)standing
             eyeBreaks:(const uint16_t *)eyeBreaks
            breakCount:(NSUInteger)breakCount
             eyeResets:(const uint16_t *)eyeResets
            resetCount:(NSUInteger)resetCount
         currentMinute:(uint16_t)currentMinute;
@end

@interface BCAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) NSMenu *menu;
@property (assign) BOOL menuOpen;
@property (strong) NSWindow *settingsWindow;
@property (strong) NSTextField *trackingLabel;
@property (strong) NSImageView *trackingIcon;
@property (strong) NSTextField *eyeLabel;
@property (strong) NSTextField *standLabel;
@property (strong) BCTimelineView *timeline;
@property (strong) NSButton *eyeResetButton;
@property (strong) NSButton *eyeSnoozeButton;
@property (strong) NSButton *standStartButton;
@property (strong) NSButton *standStopButton;
@property (strong) NSButton *standSnoozeButton;
@property (strong) NSButton *standDismissButton;
@property (strong) NSArray<NSTextField *> *settingsFields;
@property (strong) NSTextField *settingsPathLabel;
@property (strong) NSButton *settingsOpenButton;
@property (strong) NSPopUpButton *soundPopup;
@property (strong) NSButton *soundTestButton;
@property (strong) NSSound *playingSound;
@property (strong) NSButton *startupCheckbox;
@property (assign) bool eyeDue;
@property (assign) bool standDue;
@property (assign) bool standing;
@end

static BCAppDelegate *delegate;

@implementation BCTimelineView

- (void)updateActivity:(const uint8_t *)activity
              standing:(const uint8_t *)standing
             eyeBreaks:(const uint16_t *)eyeBreaks
            breakCount:(NSUInteger)breakCount
             eyeResets:(const uint16_t *)eyeResets
            resetCount:(NSUInteger)resetCount
         currentMinute:(uint16_t)currentMinute {
    self.activity = [NSData dataWithBytes:activity length:1440];
    self.standing = [NSData dataWithBytes:standing length:1440];
    self.eyeBreaks = [NSData dataWithBytes:eyeBreaks length:breakCount * sizeof(uint16_t)];
    self.eyeResets = [NSData dataWithBytes:eyeResets length:resetCount * sizeof(uint16_t)];
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
    CGFloat plotX = 95;
    CGFloat plotWidth = bounds.size.width - plotX - 12;
    NSBezierPath *background = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 1, 1) xRadius:8 yRadius:8];
    [[NSColor.controlBackgroundColor colorWithAlphaComponent:0.48] setFill];
    [background fill];

    NSColor *secondary = NSColor.secondaryLabelColor;
    NSFont *small = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    [self drawText:@"TODAY · 00:00–24:00" x:11 y:76 color:secondary font:small];
    NSMutableParagraphStyle *rightAligned = [[NSMutableParagraphStyle alloc] init];
    rightAligned.alignment = NSTextAlignmentRight;
    [self.standingGoal drawInRect:NSMakeRect(172, 76, bounds.size.width - 183, 14)
                  withAttributes:@{NSForegroundColorAttributeName: secondary,
                                   NSFontAttributeName: small,
                                   NSParagraphStyleAttributeName: rightAligned}];
    [self drawText:@"Screen" x:11 y:54 color:NSColor.labelColor font:small];
    [self drawText:@"Standing" x:11 y:35 color:NSColor.labelColor font:small];
    [self drawText:@"Eye" x:11 y:16 color:NSColor.labelColor font:small];
    [NSColor.systemTealColor setFill];
    NSRectFill(NSMakeRect(67, 57, 6, 6));
    [NSColor.systemOrangeColor setFill];
    NSRectFill(NSMakeRect(67, 38, 6, 6));
    [NSColor.systemRedColor setFill];
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
    CGFloat nowX = plotX + plotWidth * self.currentMinute / 1440.0;
    [[NSColor.labelColor colorWithAlphaComponent:0.62] setFill];
    NSRectFill(NSMakeRect(nowX, 14, 1, 51));
    const uint16_t *eyeMinutes = self.eyeBreaks.bytes;
    [NSColor.systemRedColor setFill];
    for (NSUInteger index = 0; index < self.eyeBreaks.length / sizeof(uint16_t); index++) {
        CGFloat x = plotX + plotWidth * eyeMinutes[index] / 1440.0;
        NSRectFill(NSMakeRect(x - 1.5, 14, 3, 14));
    }
    const uint16_t *resetMinutes = self.eyeResets.bytes;
    [NSColor.systemRedColor setFill];
    for (NSUInteger index = 0; index < self.eyeResets.length / sizeof(uint16_t); index++) {
        CGFloat x = plotX + plotWidth * resetMinutes[index] / 1440.0;
        NSRectFill(NSMakeRect(x - 1.5, 14, 3, 14));
    }
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

@implementation BCAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    [self makeMenu];
    [self updateActivity];
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.25 target:self selector:@selector(updateActivity) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    bc_shutdown();
}

- (void)menuWillOpen:(NSMenu *)menu {
    (void)menu;
    self.menuOpen = YES;
}

- (void)menuDidClose:(NSMenu *)menu {
    (void)menu;
    self.menuOpen = NO;
}

- (void)makeMenu {
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 336, 360)];

    NSTextField *title = label(@"BreakCue", NSMakeRect(18, 327, 180, 23), YES);
    title.font = [NSFont boldSystemFontOfSize:15];
    [view addSubview:title];
    self.trackingLabel = label(@"Idle", NSMakeRect(218, 329, 79, 20), NO);
    self.trackingLabel.alignment = NSTextAlignmentRight;
    NSFontDescriptor *italic = [[NSFont systemFontOfSize:12].fontDescriptor fontDescriptorWithSymbolicTraits:NSFontDescriptorTraitItalic];
    self.trackingLabel.font = [NSFont fontWithDescriptor:italic size:12] ?: [NSFont systemFontOfSize:12];
    self.trackingLabel.textColor = NSColor.secondaryLabelColor;
    [view addSubview:self.trackingLabel];
    self.trackingIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(304, 334, 15, 15)];
    [view addSubview:self.trackingIcon];
    NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(18, 316, 304, 1)];
    separator.boxType = NSBoxSeparator;
    [view addSubview:separator];

    self.eyeLabel = label(@"", NSMakeRect(18, 269, 146, 20), YES);
    [view addSubview:self.eyeLabel];
    self.eyeSnoozeButton = button(@"Snooze", NSMakeRect(170, 267, 72, 28), self, @selector(performAction:), 2);
    self.eyeResetButton = button(@"Reset", NSMakeRect(246, 267, 76, 28), self, @selector(performAction:), 4);
    for (NSButton *control in @[self.eyeSnoozeButton, self.eyeResetButton]) [view addSubview:control];

    self.standLabel = label(@"", NSMakeRect(18, 222, 146, 20), YES);
    [view addSubview:self.standLabel];
    self.standStartButton = button(@"Start standing", NSMakeRect(18, 180, 304, 28), self, @selector(performAction:), 5);
    self.standStopButton = button(@"Stop standing", NSMakeRect(18, 180, 304, 28), self, @selector(performAction:), 6);
    self.standSnoozeButton = button(@"Snooze", NSMakeRect(170, 220, 72, 28), self, @selector(performAction:), 7);
    self.standDismissButton = button(@"Dismiss", NSMakeRect(246, 220, 76, 28), self, @selector(performAction:), 8);
    for (NSButton *control in @[self.standStartButton, self.standStopButton, self.standSnoozeButton, self.standDismissButton]) [view addSubview:control];

    self.timeline = [[BCTimelineView alloc] initWithFrame:NSMakeRect(8, 63, 320, 93)];
    self.timeline.accessibilityLabel = @"Today from 00:00 to 24:00: screen activity, standing, and red eye break marks";
    [view addSubview:self.timeline];

    [view addSubview:button(@"Settings…", NSMakeRect(18, 7, 100, 28), self, @selector(openSettings:), 0)];
    [view addSubview:button(@"Quit", NSMakeRect(250, 7, 72, 28), NSApp, @selector(terminate:), 0)];

    self.menu = [[NSMenu alloc] initWithTitle:@"BreakCue"];
    self.menu.delegate = self;
    NSMenuItem *content = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    content.view = view;
    [self.menu addItem:content];
    self.statusItem.menu = self.menu;
}

- (void)updateActivity {
    double idle = CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType);
    bc_tick(idle, screenReady(), mediaKeepsDisplayAwake());
}

- (void)performAction:(NSButton *)sender {
    bc_action((int)sender.tag);
}

- (void)presentActive:(BOOL)active
            reminder:(uint8_t)reminder
               sound:(uint32_t)sound
                 eye:(NSString *)eye
               stand:(NSString *)stand
               daily:(NSString *)daily
            standing:(BOOL)standing
       activeMinutes:(const uint8_t *)activeMinutes
     standingMinutes:(const uint8_t *)standingMinutes
     eyeBreakMinutes:(const uint16_t *)eyeBreakMinutes
       eyeBreakCount:(NSUInteger)eyeBreakCount
     eyeResetMinutes:(const uint16_t *)eyeResetMinutes
       eyeResetCount:(NSUInteger)eyeResetCount
       currentMinute:(uint16_t)currentMinute {
    NSButton *anchor = self.statusItem.button;
    NSString *symbol = active ? @"eye.fill" : @"eye.slash";
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:active ? @"BreakCue tracking" : @"BreakCue paused"];
    image.template = YES;
    anchor.image = image;
    self.trackingLabel.stringValue = active ? @"Tracking" : @"Idle";
    NSImage *trackingImage = [NSImage imageWithSystemSymbolName:active ? @"eye.fill" : @"pause.circle"
                                              accessibilityDescription:active ? @"Tracking" : @"Idle"];
    trackingImage.template = YES;
    self.trackingIcon.image = trackingImage;
    self.eyeLabel.stringValue = eye;
    self.standLabel.stringValue = stand;
    self.timeline.standingGoal = [NSString stringWithFormat:@"STAND %@", [daily stringByReplacingOccurrencesOfString:@"Standing today: " withString:@""]];
    self.timeline.toolTip = daily;
    self.timeline.accessibilityLabel = [NSString stringWithFormat:@"Today from 00:00 to 24:00: screen activity, standing, and red eye break marks. %@", daily];
    [self.timeline updateActivity:activeMinutes standing:standingMinutes eyeBreaks:eyeBreakMinutes breakCount:eyeBreakCount eyeResets:eyeResetMinutes resetCount:eyeResetCount currentMinute:currentMinute];
    self.eyeDue = [eye isEqualToString:@"Eye break in 0:00"];
    self.standDue = [stand isEqualToString:@"Stand in 0:00"];
    self.standing = standing;
    self.eyeLabel.textColor = self.eyeDue ? NSColor.systemRedColor : NSColor.labelColor;
    self.standLabel.textColor = self.standDue ? NSColor.systemRedColor : NSColor.labelColor;
    self.eyeSnoozeButton.enabled = self.eyeDue;
    self.standStartButton.hidden = standing;
    self.standStopButton.hidden = !standing;
    self.standSnoozeButton.enabled = self.standDue;
    self.standDismissButton.enabled = self.standDue;
    if (reminder != 0) {
        [self playSoundAtIndex:sound];
        if (!self.menuOpen) [self.statusItem.button performClick:nil];
    }
}

- (void)playSoundAtIndex:(NSUInteger)index {
    NSArray<NSString *> *names = @[@"", @"Glass", @"Ping", @"Pop"];
    if (index == 0 || index >= names.count) return;
    [self.playingSound stop];
    self.playingSound = [NSSound soundNamed:names[index]];
    [self.playingSound play];
}

- (void)testReminderSound:(id)sender {
    (void)sender;
    [self playSoundAtIndex:self.soundPopup.indexOfSelectedItem];
}

- (void)soundSelectionChanged:(id)sender {
    (void)sender;
    self.soundTestButton.enabled = self.soundPopup.indexOfSelectedItem > 0;
}

- (void)openSettings:(id)sender {
    (void)sender;
    [self.menu cancelTracking];
    if (self.settingsWindow) {
        [self refreshSettingsValues];
        [self.settingsWindow makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        return;
    }
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 480, 560)
                                                     styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                       backing:NSBackingStoreBuffered defer:NO];
    window.title = @"BreakCue Settings";
    window.releasedWhenClosed = NO;
    NSView *view = window.contentView;
    [view addSubview:label(@"Reminders", NSMakeRect(24, 525, 432, 20), YES)];
    [view addSubview:label(@"Sound", NSMakeRect(24, 296, 432, 20), YES)];
    [view addSubview:label(@"Startup", NSMakeRect(24, 208, 432, 20), YES)];
    [view addSubview:label(@"Settings file", NSMakeRect(24, 123, 432, 20), YES)];
    for (NSNumber *position in @[@514, @286, @198, @113, @42]) {
        NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(24, position.doubleValue, 432, 1)];
        separator.boxType = NSBoxSeparator;
        [view addSubview:separator];
    }
    BCConfig config = bc_config();
    NSArray<NSString *> *names = @[@"Eye interval (active minutes)", @"Stand interval (active minutes)", @"Daily standing goal (minutes)", @"Snooze (minutes)", @"Away after no input (seconds)"];
    uint32_t values[] = {config.eye_minutes, config.stand_minutes, config.daily_stand_minutes, config.snooze_minutes, config.idle_seconds};
    NSMutableArray<NSTextField *> *fields = [NSMutableArray array];
    for (int i = 0; i < 5; i++) {
        CGFloat y = 477 - 34 * i;
        [view addSubview:label(names[i], NSMakeRect(24, y, 330, 20), NO)];
        NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(370, y - 2, 86, 24)];
        field.integerValue = values[i];
        [view addSubview:field];
        [fields addObject:field];
    }
    self.settingsFields = fields;
    [view addSubview:label(@"Reminder sound", NSMakeRect(24, 244, 188, 20), NO)];
    self.soundPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(230, 238, 140, 28) pullsDown:NO];
    [self.soundPopup addItemsWithTitles:@[@"Off", @"Glass", @"Ping", @"Pop"]];
    [self.soundPopup selectItemAtIndex:MIN(config.sound, 3)];
    self.soundPopup.target = self;
    self.soundPopup.action = @selector(soundSelectionChanged:);
    [view addSubview:self.soundPopup];
    self.soundTestButton = button(@"Play", NSMakeRect(380, 238, 76, 28), self, @selector(testReminderSound:), 0);
    self.soundTestButton.enabled = config.sound != 0;
    [view addSubview:self.soundTestButton];
    self.startupCheckbox = [NSButton checkboxWithTitle:@"Launch at login" target:nil action:nil];
    self.startupCheckbox.frame = NSMakeRect(24, 162, 432, 22);
    self.startupCheckbox.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [view addSubview:self.startupCheckbox];
    self.settingsPathLabel = label(@"", NSMakeRect(24, 86, 432, 19), NO);
    self.settingsPathLabel.textColor = NSColor.secondaryLabelColor;
    [view addSubview:self.settingsPathLabel];
    [view addSubview:button(@"Choose…", NSMakeRect(24, 50, 100, 28), self, @selector(chooseSettingsFile:), 0)];
    self.settingsOpenButton = button(@"Open File", NSMakeRect(132, 50, 88, 28), self, @selector(openSettingsFile:), 0);
    [view addSubview:self.settingsOpenButton];
    [view addSubview:button(@"Use Default", NSMakeRect(228, 50, 112, 28), self, @selector(useDefaultSettingsFile:), 0)];
    [self refreshSettingsPath];
    [view addSubview:button(@"Save", NSMakeRect(366, 8, 90, 29), self, @selector(saveSettings:), 0)];
    [window center];
    self.settingsWindow = window;
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)refreshSettingsPath {
    char *path = bc_settings_path();
    self.settingsPathLabel.stringValue = path ? [NSString stringWithUTF8String:path] : @"";
    self.settingsPathLabel.toolTip = self.settingsPathLabel.stringValue;
    self.settingsOpenButton.enabled = path && [[NSFileManager defaultManager] isReadableFileAtPath:self.settingsPathLabel.stringValue];
    bc_free_string(path);
}

- (void)openSettingsFile:(id)sender {
    (void)sender;
    char *rawPath = bc_settings_path();
    NSString *path = rawPath ? [NSString stringWithUTF8String:rawPath] : nil;
    bc_free_string(rawPath);
    NSWorkspace *workspace = NSWorkspace.sharedWorkspace;
    NSURL *fileURL = path ? [NSURL fileURLWithPath:path] : nil;
    NSURL *editorURL = fileURL ? [workspace URLForApplicationToOpenURL:fileURL] : nil;
    if (!editorURL) editorURL = [workspace URLForApplicationWithBundleIdentifier:@"com.apple.TextEdit"];
    if (fileURL && editorURL) {
        [workspace openURLs:@[fileURL] withApplicationAtURL:editorURL
             configuration:[NSWorkspaceOpenConfiguration configuration]
         completionHandler:^(NSRunningApplication *application, NSError *error) {
            (void)application;
            if (error) dispatch_async(dispatch_get_main_queue(), ^{ [self showSettingsOpenError:path]; });
        }];
        return;
    }
    [self showSettingsOpenError:path];
}

- (void)showSettingsOpenError:(NSString *)path {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Could not open settings file";
    alert.informativeText = path ?: @"No settings file is selected.";
    [alert beginSheetModalForWindow:self.settingsWindow completionHandler:nil];
}

- (void)showInvalidSettingsFile {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Could not open settings file";
    alert.informativeText = @"Choose an existing, readable settings.toml with valid settings.";
    [alert beginSheetModalForWindow:self.settingsWindow completionHandler:nil];
}

- (void)refreshSettingsValues {
    BCConfig config = bc_config();
    uint32_t values[] = {config.eye_minutes, config.stand_minutes, config.daily_stand_minutes, config.snooze_minutes, config.idle_seconds};
    for (int i = 0; i < 5; i++) self.settingsFields[i].integerValue = values[i];
    [self.soundPopup selectItemAtIndex:MIN(config.sound, 3)];
    self.soundTestButton.enabled = config.sound != 0;
    self.startupCheckbox.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self refreshSettingsPath];
}

- (void)chooseSettingsFile:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    [panel beginSheetModalForWindow:self.settingsWindow completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        if (!bc_use_settings_file(panel.URL.path.UTF8String)) {
            [self showInvalidSettingsFile];
            return;
        }
        [self refreshSettingsValues];
    }];
}

- (void)useDefaultSettingsFile:(id)sender {
    (void)sender;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/BreakCue/settings.toml"];
    if (!bc_use_settings_file(path.UTF8String)) {
        [self showInvalidSettingsFile];
        return;
    }
    [self refreshSettingsValues];
}

- (void)saveSettings:(id)sender {
    (void)sender;
    BCConfig config = bc_config();
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
    config.sound = (uint32_t)self.soundPopup.indexOfSelectedItem;
    bc_apply_config(config);
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

void bc_present(bool active, uint8_t reminder, uint32_t sound, const char *eye, const char *stand, const char *daily, bool standing,
                const uint8_t *active_minutes, const uint8_t *standing_minutes,
                const uint16_t *eye_break_minutes, size_t eye_break_count,
                const uint16_t *eye_reset_minutes, size_t eye_reset_count, uint16_t current_minute) {
    [delegate presentActive:active reminder:reminder sound:sound
                     eye:[NSString stringWithUTF8String:eye]
                   stand:[NSString stringWithUTF8String:stand]
                   daily:[NSString stringWithUTF8String:daily]
              standing:standing
         activeMinutes:active_minutes
       standingMinutes:standing_minutes
       eyeBreakMinutes:eye_break_minutes
         eyeBreakCount:eye_break_count
       eyeResetMinutes:eye_reset_minutes
         eyeResetCount:eye_reset_count
         currentMinute:current_minute];
}

void bc_app_run(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        delegate = [[BCAppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
}
