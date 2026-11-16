use chrono::{Local, NaiveDate, Timelike};
use serde::{Deserialize, Serialize};
use std::{
    ffi::{CStr, CString},
    fs, io,
    os::raw::{c_char, c_int},
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};

#[repr(C)]
#[derive(Clone, Copy)]
pub struct BCConfig {
    eye_minutes: u32,
    stand_minutes: u32,
    daily_stand_minutes: u32,
    snooze_minutes: u32,
    idle_seconds: u32,
    sound: u32,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum ReminderSound {
    Off,
    #[default]
    Glass,
    Ping,
    Pop,
}

impl ReminderSound {
    fn from_index(index: u32) -> Self {
        match index {
            0 => Self::Off,
            2 => Self::Ping,
            3 => Self::Pop,
            _ => Self::Glass,
        }
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(default)]
struct Config {
    eye_minutes: u32,
    stand_minutes: u32,
    daily_stand_minutes: u32,
    snooze_minutes: u32,
    idle_seconds: u32,
    reminder_sound: ReminderSound,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            eye_minutes: 20,
            stand_minutes: 120,
            daily_stand_minutes: 60,
            snooze_minutes: 5,
            idle_seconds: 120,
            reminder_sound: ReminderSound::Glass,
        }
    }
}

impl Config {
    fn as_ffi(&self) -> BCConfig {
        BCConfig {
            eye_minutes: self.eye_minutes,
            stand_minutes: self.stand_minutes,
            daily_stand_minutes: self.daily_stand_minutes,
            snooze_minutes: self.snooze_minutes,
            idle_seconds: self.idle_seconds,
            sound: self.reminder_sound as u32,
        }
    }
}

#[derive(Serialize, Deserialize)]
struct DayRecord {
    date: NaiveDate,
    standing_seconds: u64,
    #[serde(default)]
    active_seconds_by_minute: Vec<u8>,
    #[serde(default)]
    standing_seconds_by_minute: Vec<u8>,
    #[serde(default)]
    eye_break_minutes: Vec<u16>,
    #[serde(default)]
    eye_reset_minutes: Vec<u16>,
}

impl DayRecord {
    fn new(date: NaiveDate) -> Self {
        Self {
            date,
            standing_seconds: 0,
            active_seconds_by_minute: vec![0; 1440],
            standing_seconds_by_minute: vec![0; 1440],
            eye_break_minutes: Vec::new(),
            eye_reset_minutes: Vec::new(),
        }
    }

    fn normalize(&mut self) {
        self.active_seconds_by_minute.resize(1440, 0);
        self.active_seconds_by_minute.truncate(1440);
        self.standing_seconds_by_minute.resize(1440, 0);
        self.standing_seconds_by_minute.truncate(1440);
        self.eye_break_minutes.retain(|minute| *minute < 1440);
        self.eye_reset_minutes.retain(|minute| *minute < 1440);
    }
}

// Credit only the sampled interval, split at minute boundaries. A minute is
// displayed when at least one second of that activity was observed in it.
fn credit_minutes(buckets: &mut [u8], end_second: u32, seconds: u64) {
    let mut cursor = end_second as u64;
    let start = cursor.saturating_sub(seconds);
    while cursor > start {
        let minute = ((cursor - 1) / 60) as usize;
        let segment_start = start.max(minute as u64 * 60);
        let amount = (cursor - segment_start) as u8;
        buckets[minute] = buckets[minute].saturating_add(amount).min(60);
        cursor = segment_start;
    }
}

struct Engine {
    config: Config,
    settings_path: PathBuf,
    day: DayRecord,
    last_tick: Instant,
    last_save: Instant,
    eye_active_seconds: u64,
    stand_active_seconds: u64,
    eye_due: bool,
    stand_due: bool,
    eye_snoozed_until: Option<Instant>,
    stand_snoozed_until: Option<Instant>,
    eye_break_start: Option<Instant>,
    standing_seconds: u64,
    standing: bool,
    active: bool,
    shown_reminder: u8,
}

impl Engine {
    fn load() -> Self {
        if let Err(error) = migrate_legacy_data(&legacy_app_dir(), &app_dir()) {
            eprintln!("Could not migrate legacy data: {error}");
        }
        let settings_path = selected_settings_path();
        let config = load_settings(&settings_path).unwrap_or_else(|| {
            // Preserve settings from earlier releases when creating the new TOML file.
            let config = if settings_path == default_settings_path() {
                load_json("config.json").unwrap_or_else(bundled_settings)
            } else {
                bundled_settings()
            };
            if !settings_path.exists() {
                save_settings(&settings_path, &config);
            }
            config
        });
        let today = Local::now().date_naive();
        let day: DayRecord = load_json("day.json").unwrap_or_else(|| DayRecord::new(today));
        let mut day = if day.date == today {
            day
        } else {
            DayRecord::new(today)
        };
        day.normalize();
        let now = Instant::now();
        Self {
            config,
            settings_path,
            day,
            last_tick: now,
            last_save: now,
            eye_active_seconds: 0,
            stand_active_seconds: 0,
            eye_due: false,
            stand_due: false,
            eye_snoozed_until: None,
            stand_snoozed_until: None,
            eye_break_start: None,
            standing_seconds: 0,
            standing: false,
            active: false,
            shown_reminder: 0,
        }
    }

    fn tick(&mut self, idle_seconds: f64, screen_ready: bool, media_assertion: bool) -> u8 {
        let now = Instant::now();
        // A sleep/wake gap must not become hours of credited activity or standing time.
        let elapsed = now.duration_since(self.last_tick).as_secs().min(10);
        self.last_tick = now;
        let local_now = Local::now();
        let today = local_now.date_naive();
        let second_of_day = local_now.time().num_seconds_from_midnight();
        if self.day.date != today {
            self.day = DayRecord::new(today);
            self.standing_seconds = 0;
            self.standing = false;
            self.stand_active_seconds = 0;
            self.stand_due = false;
            self.stand_snoozed_until = None;
            self.shown_reminder = 0;
            self.save_day();
        }

        let break_was_in_progress = self.eye_break_start.is_some();
        if self
            .eye_break_start
            .is_some_and(|start| start.elapsed().as_secs() >= 20)
        {
            self.eye_break_start = None;
            self.eye_active_seconds = 0;
            self.eye_snoozed_until = None;
        }

        self.active = screen_ready
            && (idle_seconds.is_finite() && idle_seconds <= self.config.idle_seconds as f64
                || media_assertion);

        // A deliberate standing session can continue while the user steps away
        // and the display dims. The 30-minute cap limits forgotten sessions.
        if self.standing {
            let credited = elapsed.min(30 * 60 - self.standing_seconds);
            self.day.standing_seconds += credited;
            self.standing_seconds += credited;
            credit_minutes(
                &mut self.day.standing_seconds_by_minute,
                second_of_day,
                credited,
            );
            if self.standing_seconds >= 30 * 60 {
                self.standing = false;
                self.standing_seconds = 0;
            }
        }
        if self.active && !break_was_in_progress {
            credit_minutes(
                &mut self.day.active_seconds_by_minute,
                second_of_day,
                elapsed,
            );
        }
        if self.active && !self.standing && !break_was_in_progress {
            if self.eye_break_start.is_none() && !self.eye_due {
                self.eye_active_seconds += elapsed;
            }
            if !self.stand_due {
                self.stand_active_seconds += elapsed;
            }
        }

        if self.eye_active_seconds >= self.config.eye_minutes as u64 * 60
            && self.eye_snoozed_until.is_none_or(|until| now >= until)
            && self.eye_break_start.is_none()
        {
            self.eye_due = true;
        }
        if self.stand_active_seconds >= self.config.stand_minutes as u64 * 60
            && self.day.standing_seconds < self.config.daily_stand_minutes as u64 * 60
            && self.stand_snoozed_until.is_none_or(|until| now >= until)
            && !self.standing
        {
            self.stand_due = true;
        }
        if self.day.standing_seconds >= self.config.daily_stand_minutes as u64 * 60 {
            self.stand_due = false;
        }
        if now.duration_since(self.last_save) >= Duration::from_secs(30) {
            self.save_day();
            self.last_save = now;
        }
        let reminder = if self.active && self.eye_due && self.eye_break_start.is_none() {
            1
        } else if self.active && self.stand_due && self.eye_break_start.is_none() {
            2
        } else {
            0
        };
        if reminder != 0 && self.shown_reminder != reminder {
            self.shown_reminder = reminder;
            reminder
        } else {
            0
        }
    }

    fn action(&mut self, action: c_int) {
        let snooze = Duration::from_secs(self.config.snooze_minutes as u64 * 60);
        match action {
            1 if self.eye_due => {
                // Eye: dismiss this cycle.
                self.eye_due = false;
                self.eye_active_seconds = 0;
                self.eye_snoozed_until = None;
            }
            2 if self.eye_due => {
                // Eye: snooze.
                self.eye_due = false;
                self.eye_snoozed_until = Some(Instant::now() + snooze);
            }
            3 if self.eye_due => {
                // Begin a deliberate 20-second distant look.
                self.eye_due = false;
                self.eye_break_start = Some(Instant::now());
                let minute = (Local::now().time().num_seconds_from_midnight() / 60) as u16;
                self.day.eye_break_minutes.push(minute);
                self.save_day();
            }
            4 => {
                // Restart the eye interval, including a due or snoozed reminder.
                self.eye_due = false;
                self.eye_active_seconds = 0;
                self.eye_snoozed_until = None;
                self.eye_break_start = None;
                let minute = (Local::now().time().num_seconds_from_midnight() / 60) as u16;
                self.day.eye_reset_minutes.push(minute);
                self.save_day();
            }
            5 => {
                // Start a self-reported standing session.
                self.standing = true;
                self.standing_seconds = 0;
                self.stand_due = false;
                self.stand_active_seconds = 0;
                self.stand_snoozed_until = None;
            }
            6 => {
                // Stop standing.
                self.standing = false;
                self.standing_seconds = 0;
                self.save_day();
            }
            7 if self.stand_due => {
                // Standing: snooze.
                self.stand_due = false;
                self.stand_snoozed_until = Some(Instant::now() + snooze);
            }
            8 if self.stand_due => {
                // Standing: dismiss this cycle.
                self.stand_due = false;
                self.stand_active_seconds = 0;
                self.stand_snoozed_until = None;
            }
            _ => {}
        }
        self.shown_reminder = 0;
    }

    fn save_day(&self) {
        if cfg!(test) {
            return;
        }
        save_json("day.json", &self.day);
    }
}

fn app_dir() -> PathBuf {
    let home = std::env::var_os("HOME").unwrap_or_default();
    PathBuf::from(home).join("Library/Application Support/BreakCue")
}

fn legacy_app_dir() -> PathBuf {
    let home = std::env::var_os("HOME").unwrap_or_default();
    PathBuf::from(home).join("Library/Application Support/screen_doctor")
}

fn migrate_legacy_data(old: &Path, new: &Path) -> io::Result<()> {
    if !old.is_dir() {
        return Ok(());
    }
    fs::create_dir_all(new)?;
    for name in [
        "settings.toml",
        "config.json",
        "day.json",
        "settings-path.txt",
    ] {
        let source = old.join(name);
        if !source.is_file() {
            continue;
        }
        let destination = new.join(name);
        if destination.exists() {
            continue;
        }
        let mut input = fs::File::open(&source)?;
        let mut output = match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&destination)
        {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        };
        let result = if name == "settings-path.txt" {
            let selection = fs::read_to_string(&source)?;
            let selected = PathBuf::from(selection.trim());
            let path = if selected == old.join("settings.toml") {
                new.join("settings.toml")
            } else {
                selected
            };
            io::Write::write_all(&mut output, path.to_string_lossy().as_bytes())
        } else {
            io::copy(&mut input, &mut output).map(|_| ())
        };
        if let Err(error) = result {
            let _ = fs::remove_file(&destination);
            return Err(error);
        }
    }
    Ok(())
}

fn default_settings_path() -> PathBuf {
    app_dir().join("settings.toml")
}

fn selected_settings_path() -> PathBuf {
    let mut args = std::env::args_os().skip(1);
    while let Some(arg) = args.next() {
        if arg == "--settings" {
            if let Some(path) = args.next() {
                return PathBuf::from(path);
            }
        }
    }
    if let Some(path) = std::env::var_os("BREAKCUE_SETTINGS")
        .or_else(|| std::env::var_os("SCREEN_DOCTOR_SETTINGS"))
        .filter(|path| !path.is_empty())
    {
        return PathBuf::from(path);
    }
    fs::read_to_string(app_dir().join("settings-path.txt"))
        .ok()
        .map(|path| PathBuf::from(path.trim()))
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(default_settings_path)
}

fn bundled_settings() -> Config {
    toml::from_str(include_str!("../settings.toml")).expect("valid bundled settings")
}

fn load_settings(path: &Path) -> Option<Config> {
    let contents = fs::read_to_string(path).ok()?;
    match toml::from_str::<Config>(&contents) {
        Ok(config) => Some(config),
        Err(error) => {
            eprintln!("Invalid settings file {}: {error}", path.display());
            None
        }
    }
}

fn save_settings(path: &Path, config: &Config) -> bool {
    let Ok(contents) = toml::to_string_pretty(config) else {
        return false;
    };
    let Some(parent) = path.parent() else {
        return false;
    };
    if fs::create_dir_all(parent).is_err() {
        return false;
    }
    let temporary = path.with_extension("toml.tmp");
    fs::write(&temporary, contents).is_ok() && fs::rename(temporary, path).is_ok()
}

fn load_json<T: serde::de::DeserializeOwned>(name: &str) -> Option<T> {
    serde_json::from_slice(&fs::read(app_dir().join(name)).ok()?).ok()
}

fn save_json<T: Serialize>(name: &str, value: &T) {
    let directory = app_dir();
    if fs::create_dir_all(&directory).is_ok() {
        if let Ok(bytes) = serde_json::to_vec_pretty(value) {
            let path = directory.join(name);
            let temporary = directory.join(format!("{name}.tmp"));
            if fs::write(&temporary, bytes).is_ok() {
                let _ = fs::rename(temporary, path);
            }
        }
    }
}

static ENGINE: OnceLock<Mutex<Engine>> = OnceLock::new();
fn engine() -> &'static Mutex<Engine> {
    ENGINE.get_or_init(|| Mutex::new(Engine::load()))
}

extern "C" {
    fn bc_app_run();
    fn bc_present(
        active: bool,
        reminder: u8,
        sound: u32,
        eye: *const c_char,
        stand: *const c_char,
        daily: *const c_char,
        standing: bool,
        active_minutes: *const u8,
        standing_minutes: *const u8,
        eye_break_minutes: *const u16,
        eye_break_count: usize,
        eye_reset_minutes: *const u16,
        eye_reset_count: usize,
        current_minute: u16,
    );
}

fn present(e: &Engine, reminder: u8) {
    let eye = if let Some(start) = e.eye_break_start {
        format!(
            "Look away: {}s left",
            20_u64.saturating_sub(start.elapsed().as_secs())
        )
    } else if e.eye_due {
        "Eye break due now".to_owned()
    } else {
        let left = (e.config.eye_minutes as u64 * 60).saturating_sub(e.eye_active_seconds);
        format!("Eye break in {}", countdown(left))
    };
    let stand = if e.standing {
        format!("Standing: {} min", e.standing_seconds / 60)
    } else if e.stand_due {
        "Time to stand".to_owned()
    } else {
        let left = (e.config.stand_minutes as u64 * 60).saturating_sub(e.stand_active_seconds);
        format!("Stand in {}", countdown(left))
    };
    let daily = format!(
        "Standing today: {} / {} min",
        e.day.standing_seconds / 60,
        e.config.daily_stand_minutes
    );
    let eye = CString::new(eye).unwrap();
    let stand = CString::new(stand).unwrap();
    let daily = CString::new(daily).unwrap();
    unsafe {
        bc_present(
            e.active,
            reminder,
            e.config.reminder_sound as u32,
            eye.as_ptr(),
            stand.as_ptr(),
            daily.as_ptr(),
            e.standing,
            e.day.active_seconds_by_minute.as_ptr(),
            e.day.standing_seconds_by_minute.as_ptr(),
            e.day.eye_break_minutes.as_ptr(),
            e.day.eye_break_minutes.len(),
            e.day.eye_reset_minutes.as_ptr(),
            e.day.eye_reset_minutes.len(),
            (Local::now().time().num_seconds_from_midnight() / 60) as u16,
        );
    }
}

fn countdown(seconds: u64) -> String {
    format!("{:02}:{:02}", seconds / 60, seconds % 60)
}

#[no_mangle]
extern "C" fn bc_tick(idle_seconds: f64, screen_ready: bool, media_assertion: bool) {
    let mut e = engine().lock().unwrap();
    let reminder = e.tick(idle_seconds, screen_ready, media_assertion);
    present(&e, reminder);
}

#[no_mangle]
extern "C" fn bc_action(action: c_int) {
    let mut e = engine().lock().unwrap();
    e.action(action);
    present(&e, 0);
}

#[no_mangle]
extern "C" fn bc_config() -> BCConfig {
    engine().lock().unwrap().config.as_ffi()
}

#[no_mangle]
extern "C" fn bc_apply_config(config: BCConfig) {
    let mut e = engine().lock().unwrap();
    e.config = Config {
        eye_minutes: config.eye_minutes.clamp(1, 240),
        stand_minutes: config.stand_minutes.clamp(1, 240),
        daily_stand_minutes: config.daily_stand_minutes.clamp(1, 480),
        snooze_minutes: config.snooze_minutes.clamp(1, 60),
        idle_seconds: config.idle_seconds.clamp(15, 900),
        reminder_sound: ReminderSound::from_index(config.sound),
    };
    save_settings(&e.settings_path, &e.config);
    present(&e, 0);
}

#[no_mangle]
extern "C" fn bc_settings_path() -> *mut c_char {
    let e = engine().lock().unwrap();
    CString::new(e.settings_path.to_string_lossy().as_bytes())
        .unwrap()
        .into_raw()
}

#[no_mangle]
unsafe extern "C" fn bc_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

#[no_mangle]
unsafe extern "C" fn bc_use_settings_file(path: *const c_char) -> bool {
    if path.is_null() {
        return false;
    }
    let Ok(path) = CStr::from_ptr(path).to_str() else {
        return false;
    };
    let path = PathBuf::from(path);
    let config = if path == default_settings_path() && !path.exists() {
        let config = bundled_settings();
        if !save_settings(&path, &config) {
            return false;
        }
        config
    } else {
        let Some(config) = load_settings(&path) else {
            return false;
        };
        config
    };
    let selection = app_dir().join("settings-path.txt");
    if path == default_settings_path() {
        if selection.exists() && fs::remove_file(selection).is_err() {
            return false;
        }
    } else {
        if fs::create_dir_all(app_dir()).is_err()
            || fs::write(selection, path.to_string_lossy().as_bytes()).is_err()
        {
            return false;
        }
    }
    let mut e = engine().lock().unwrap();
    e.config = config;
    e.settings_path = path;
    present(&e, 0);
    true
}

#[no_mangle]
extern "C" fn bc_shutdown() {
    engine().lock().unwrap().save_day();
}

fn main() {
    let _ = engine();
    unsafe { bc_app_run() };
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn migration_copies_history_and_redirects_default_settings_selection() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("breakcue-migration-{unique}"));
        let old = root.join("screen_doctor");
        let new = root.join("BreakCue");
        fs::create_dir_all(&old).unwrap();
        fs::write(old.join("settings.toml"), "eye_minutes = 25\n").unwrap();
        fs::write(old.join("day.json"), "old history").unwrap();
        fs::write(
            old.join("settings-path.txt"),
            old.join("settings.toml").to_string_lossy().as_bytes(),
        )
        .unwrap();
        migrate_legacy_data(&old, &new).unwrap();
        assert_eq!(
            fs::read_to_string(new.join("settings.toml")).unwrap(),
            "eye_minutes = 25\n"
        );
        assert_eq!(
            fs::read_to_string(new.join("day.json")).unwrap(),
            "old history"
        );
        assert_eq!(
            fs::read_to_string(new.join("settings-path.txt")).unwrap(),
            new.join("settings.toml").to_string_lossy()
        );
        fs::write(new.join("day.json"), "new history").unwrap();
        migrate_legacy_data(&old, &new).unwrap();
        assert_eq!(
            fs::read_to_string(new.join("day.json")).unwrap(),
            "new history"
        );
        assert_eq!(
            fs::read_to_string(old.join("day.json")).unwrap(),
            "old history"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn migration_keeps_custom_settings_selection() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("breakcue-custom-{unique}"));
        let old = root.join("screen_doctor");
        let new = root.join("BreakCue");
        fs::create_dir_all(&old).unwrap();
        let custom = root.join("custom.toml");
        fs::write(
            old.join("settings-path.txt"),
            custom.to_string_lossy().as_bytes(),
        )
        .unwrap();
        migrate_legacy_data(&old, &new).unwrap();
        assert_eq!(
            fs::read_to_string(new.join("settings-path.txt")).unwrap(),
            custom.to_string_lossy()
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn idle_video_counts_when_screen_is_awake() {
        let mut e = Engine::load();
        e.tick(1_000.0, true, true);
        assert!(e.active);
        e.tick(1_000.0, false, true);
        assert!(!e.active);
        e.tick(1_000.0, true, false);
        assert!(!e.active);
    }

    #[test]
    fn old_media_setting_is_ignored_and_sound_defaults_to_glass() {
        let config: Config = toml::from_str("count_media = false\n").unwrap();
        assert_eq!(config.reminder_sound, ReminderSound::Glass);
        assert!(!toml::to_string(&config).unwrap().contains("count_media"));
        assert_eq!(ReminderSound::from_index(3), ReminderSound::Pop);
    }

    #[test]
    fn eye_break_finishes_after_twenty_seconds() {
        let mut e = Engine::load();
        e.eye_due = true;
        e.action(3);
        assert_eq!(e.day.eye_break_minutes.len(), 1);
        e.tick(0.0, true, false);
        assert!(e.eye_break_start.is_some());
        e.eye_break_start = Some(Instant::now() - Duration::from_secs(20));
        e.tick(0.0, true, false);
        assert!(e.eye_break_start.is_none());
        assert!(!e.eye_due);
    }

    #[test]
    fn standing_counts_away_from_display_but_caps_sleep_gaps() {
        let mut e = Engine::load();
        e.standing = true;
        e.last_tick = Instant::now() - Duration::from_secs(600);
        let before = e.day.standing_seconds;
        e.tick(600.0, false, false);
        assert_eq!(e.day.standing_seconds - before, 10);
    }

    #[test]
    fn activity_is_split_at_minute_boundary() {
        let mut minutes = vec![0; 1440];
        credit_minutes(&mut minutes, 61, 5);
        assert_eq!(minutes[0], 4);
        assert_eq!(minutes[1], 1);
    }

    #[test]
    fn old_daily_record_loads_with_empty_timeline() {
        let mut day: DayRecord =
            serde_json::from_str(r#"{"date":"2026-11-16","standing_seconds":3600}"#).unwrap();
        day.normalize();
        assert_eq!(day.standing_seconds, 3600);
        assert_eq!(day.active_seconds_by_minute.len(), 1440);
        assert!(day.eye_break_minutes.is_empty());
        assert!(day.eye_reset_minutes.is_empty());
    }

    #[test]
    fn eye_actions_do_nothing_before_an_alarm() {
        let mut e = Engine::load();
        e.eye_active_seconds = 45;
        e.action(1);
        e.action(2);
        assert_eq!(e.eye_active_seconds, 45);
        assert!(e.eye_snoozed_until.is_none());
    }

    #[test]
    fn bundled_settings_use_two_hour_standing_interval() {
        let config = bundled_settings();
        assert_eq!(config.stand_minutes, 120);
        assert_eq!(Config::default().stand_minutes, 120);
    }

    #[test]
    fn standing_actions_require_a_due_reminder() {
        let mut e = Engine::load();
        e.stand_active_seconds = 300;
        e.action(7);
        e.action(8);
        assert_eq!(e.stand_active_seconds, 300);
        assert!(e.stand_snoozed_until.is_none());
        e.stand_due = true;
        e.action(8);
        assert_eq!(e.stand_active_seconds, 0);
        assert!(!e.stand_due);
    }

    #[test]
    fn reset_eye_timer_clears_due_and_snoozed_state() {
        let mut e = Engine::load();
        let previous_resets = e.day.eye_reset_minutes.len();
        let previous_breaks = e.day.eye_break_minutes.len();
        e.eye_active_seconds = 600;
        e.eye_due = true;
        e.eye_snoozed_until = Some(Instant::now() + Duration::from_secs(300));
        e.action(4);
        assert_eq!(e.eye_active_seconds, 0);
        assert!(!e.eye_due);
        assert!(e.eye_snoozed_until.is_none());
        assert_eq!(e.day.eye_reset_minutes.len(), previous_resets + 1);
        assert!(e.day.eye_reset_minutes.last().unwrap() < &1440);
        assert_eq!(e.day.eye_break_minutes.len(), previous_breaks);
    }

    #[test]
    fn countdown_shows_minutes_and_seconds() {
        assert_eq!(countdown(19 * 60 + 32), "19:32");
        assert_eq!(countdown(120 * 60), "120:00");
        assert_eq!(countdown(0), "00:00");
    }
}
