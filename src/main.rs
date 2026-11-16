use chrono::{Local, NaiveDate};
use serde::{Deserialize, Serialize};
use std::{
    ffi::CString,
    fs,
    os::raw::{c_char, c_int},
    path::PathBuf,
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SDConfig {
    eye_minutes: u32,
    stand_minutes: u32,
    daily_stand_minutes: u32,
    snooze_minutes: u32,
    idle_seconds: u32,
    count_media: bool,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(default)]
struct Config {
    eye_minutes: u32,
    stand_minutes: u32,
    daily_stand_minutes: u32,
    snooze_minutes: u32,
    idle_seconds: u32,
    count_media: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            eye_minutes: 20,
            stand_minutes: 60,
            daily_stand_minutes: 60,
            snooze_minutes: 5,
            idle_seconds: 120,
            count_media: true,
        }
    }
}

impl Config {
    fn as_ffi(&self) -> SDConfig {
        SDConfig {
            eye_minutes: self.eye_minutes,
            stand_minutes: self.stand_minutes,
            daily_stand_minutes: self.daily_stand_minutes,
            snooze_minutes: self.snooze_minutes,
            idle_seconds: self.idle_seconds,
            count_media: self.count_media,
        }
    }
}

#[derive(Serialize, Deserialize)]
struct DayRecord {
    date: NaiveDate,
    standing_seconds: u64,
}

struct Engine {
    config: Config,
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
    media_active: bool,
    shown_reminder: u8,
}

impl Engine {
    fn load() -> Self {
        let config = load_json("config.json").unwrap_or_default();
        let today = Local::now().date_naive();
        let day: DayRecord = load_json("day.json").unwrap_or(DayRecord {
            date: today,
            standing_seconds: 0,
        });
        let day = if day.date == today {
            day
        } else {
            DayRecord {
                date: today,
                standing_seconds: 0,
            }
        };
        let now = Instant::now();
        Self {
            config,
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
            media_active: false,
            shown_reminder: 0,
        }
    }

    fn tick(&mut self, idle_seconds: f64, screen_ready: bool, media_assertion: bool) -> u8 {
        let now = Instant::now();
        // A sleep/wake gap must not become hours of credited activity or standing time.
        let elapsed = now.duration_since(self.last_tick).as_secs().min(10);
        self.last_tick = now;
        let today = Local::now().date_naive();
        if self.day.date != today {
            self.day = DayRecord {
                date: today,
                standing_seconds: 0,
            };
            self.standing_seconds = 0;
            self.standing = false;
            self.stand_active_seconds = 0;
            self.stand_due = false;
            self.stand_snoozed_until = None;
            self.shown_reminder = 0;
            self.save_day();
        }

        if self
            .eye_break_start
            .is_some_and(|start| start.elapsed().as_secs() >= 20)
        {
            self.eye_break_start = None;
            self.eye_active_seconds = 0;
            self.eye_snoozed_until = None;
        }

        self.media_active = screen_ready && self.config.count_media && media_assertion;
        self.active = screen_ready
            && (idle_seconds.is_finite() && idle_seconds <= self.config.idle_seconds as f64
                || self.media_active);

        // A deliberate standing session can continue while the user steps away
        // and the display dims. The 30-minute cap limits forgotten sessions.
        if self.standing {
            let credited = elapsed.min(30 * 60 - self.standing_seconds);
            self.day.standing_seconds += credited;
            self.standing_seconds += credited;
            if self.standing_seconds >= 30 * 60 {
                self.standing = false;
                self.standing_seconds = 0;
            }
        }
        if self.active && !self.standing {
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
            1 => {
                // Eye: dismiss this cycle.
                self.eye_due = false;
                self.eye_active_seconds = 0;
                self.eye_snoozed_until = None;
            }
            2 => {
                // Eye: snooze.
                self.eye_due = false;
                self.eye_snoozed_until = Some(Instant::now() + snooze);
            }
            3 if self.eye_due => {
                // Begin a deliberate 20-second distant look.
                self.eye_due = false;
                self.eye_break_start = Some(Instant::now());
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
            7 => {
                // Standing: snooze.
                self.stand_due = false;
                self.stand_snoozed_until = Some(Instant::now() + snooze);
            }
            8 => {
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
        save_json("day.json", &self.day);
    }
}

fn app_dir() -> PathBuf {
    let home = std::env::var_os("HOME").unwrap_or_default();
    PathBuf::from(home).join("Library/Application Support/screen_doctor")
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
    fn sd_app_run();
    fn sd_present(
        active: bool,
        media: bool,
        reminder: u8,
        eye: *const c_char,
        stand: *const c_char,
        daily: *const c_char,
        standing: bool,
    );
}

fn present(e: &Engine, reminder: u8) {
    let eye = if let Some(start) = e.eye_break_start {
        format!(
            "Look 20 feet away: {}s left",
            20_u64.saturating_sub(start.elapsed().as_secs())
        )
    } else if e.eye_due {
        "Eye break due now".to_owned()
    } else {
        let left = (e.config.eye_minutes as u64 * 60).saturating_sub(e.eye_active_seconds);
        format!("Eye break in {} min", left.div_ceil(60))
    };
    let stand = if e.standing {
        format!(
            "Standing: {} min (max 30 min/session)",
            e.standing_seconds / 60
        )
    } else if e.stand_due {
        "Time to stand".to_owned()
    } else {
        let left = (e.config.stand_minutes as u64 * 60).saturating_sub(e.stand_active_seconds);
        format!("Stand reminder in {} min", left.div_ceil(60))
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
        sd_present(
            e.active,
            e.media_active,
            reminder,
            eye.as_ptr(),
            stand.as_ptr(),
            daily.as_ptr(),
            e.standing,
        );
    }
}

#[no_mangle]
extern "C" fn sd_tick(idle_seconds: f64, screen_ready: bool, media_assertion: bool) {
    let mut e = engine().lock().unwrap();
    let reminder = e.tick(idle_seconds, screen_ready, media_assertion);
    present(&e, reminder);
}

#[no_mangle]
extern "C" fn sd_action(action: c_int) {
    let mut e = engine().lock().unwrap();
    e.action(action);
    present(&e, 0);
}

#[no_mangle]
extern "C" fn sd_config() -> SDConfig {
    engine().lock().unwrap().config.as_ffi()
}

#[no_mangle]
extern "C" fn sd_apply_config(config: SDConfig) {
    let mut e = engine().lock().unwrap();
    e.config = Config {
        eye_minutes: config.eye_minutes.clamp(1, 240),
        stand_minutes: config.stand_minutes.clamp(1, 240),
        daily_stand_minutes: config.daily_stand_minutes.clamp(1, 480),
        snooze_minutes: config.snooze_minutes.clamp(1, 60),
        idle_seconds: config.idle_seconds.clamp(15, 900),
        count_media: config.count_media,
    };
    save_json("config.json", &e.config);
    present(&e, 0);
}

#[no_mangle]
extern "C" fn sd_shutdown() {
    engine().lock().unwrap().save_day();
}

fn main() {
    let _ = engine();
    unsafe { sd_app_run() };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idle_video_counts_only_with_media_enabled_and_awake_screen() {
        let mut e = Engine::load();
        e.config.count_media = true;
        e.tick(1_000.0, true, true);
        assert!(e.active);
        e.tick(1_000.0, false, true);
        assert!(!e.active);
        e.config.count_media = false;
        e.tick(1_000.0, true, true);
        assert!(!e.active);
    }

    #[test]
    fn eye_break_finishes_after_twenty_seconds() {
        let mut e = Engine::load();
        e.eye_due = true;
        e.action(3);
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
}
