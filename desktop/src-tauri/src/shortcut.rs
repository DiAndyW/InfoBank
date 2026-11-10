use std::str::FromStr;

use rusqlite::Connection;
use tauri_plugin_global_shortcut::{Modifiers, Shortcut};

#[derive(Debug, PartialEq, serde::Serialize)]
pub struct Hotkey {
    pub shortcut: String,
    pub on: bool,
}

pub fn parse(s: &str) -> Result<Shortcut, String> {
    let shortcut = Shortcut::from_str(s).map_err(|_| format!("\"{s}\" isn't a shortcut"))?;
    // Also rules out ⌥-only combinations, which macOS 15 refuses to register.
    if !shortcut.mods.intersects(Modifiers::SUPER | Modifiers::CONTROL) {
        return Err("Add ⌘ or Ctrl to the shortcut".into());
    }
    Ok(shortcut)
}

pub fn get(conn: &Connection) -> Result<Hotkey, String> {
    let (stored, on): (String, bool) = conn
        .query_row("SELECT quick_capture_shortcut, quick_capture_on FROM device", [], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(crate::error_message::message)?;
    Ok(Hotkey { shortcut: parse(&stored)?.into_string(), on })
}

pub fn set_shortcut(conn: &Connection, new: &str, register: impl FnOnce(&Shortcut) -> Result<(), String>) -> Result<Hotkey, String> {
    let new = parse(new)?;
    if get(conn)?.on {
        register(&new)?;
    }
    conn.execute("UPDATE device SET quick_capture_shortcut = ?1", [new.into_string()]).map_err(crate::error_message::message)?;
    get(conn)
}

pub fn set_on(conn: &Connection, on: bool, register: impl FnOnce(&Shortcut) -> Result<(), String>) -> Result<Hotkey, String> {
    if on {
        register(&parse(&get(conn)?.shortcut)?)?;
    }
    conn.execute("UPDATE device SET quick_capture_on = ?1", [on]).map_err(crate::error_message::message)?;
    get(conn)
}

#[cfg(test)]
mod tests {
    use super::*;

    // The migration's default.
    const DEFAULT_SHORTCUT: &str = "CommandOrControl+Shift+Space";

    fn db() -> (tempfile::TempDir, Connection) {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        (dir, conn)
    }

    fn canonical(s: &str) -> String {
        parse(s).unwrap().into_string()
    }

    fn hotkey(shortcut: &str, on: bool) -> Hotkey {
        Hotkey { shortcut: canonical(shortcut), on }
    }

    #[test]
    fn a_fresh_database_has_the_default_turned_on() {
        let (_d, conn) = db();
        assert_eq!(get(&conn).unwrap(), hotkey(DEFAULT_SHORTCUT, true));
    }

    #[test]
    fn a_shortcut_needs_command_or_control() {
        for ok in ["Super+Shift+Space", "Control+Alt+KeyK", "CommandOrControl+Shift+Space", "Control+F5"] {
            assert!(parse(ok).is_ok(), "{ok} rejected");
        }
        for bad in ["Alt+Space", "Alt+Shift+Space", "Shift+KeyK", "KeyK", "Shift", "", "Super+", "nonsense+Q"] {
            assert!(parse(bad).is_err(), "{bad} accepted");
        }
    }

    #[test]
    fn a_new_shortcut_is_registered_and_stored_in_canonical_form() {
        let (_d, conn) = db();
        let mut registered = None;
        let stored = set_shortcut(&conn, "Control+Alt+KeyK", |s| {
            registered = Some(s.into_string());
            Ok(())
        })
        .unwrap();
        assert_eq!(stored, hotkey("Control+Alt+KeyK", true));
        assert_eq!(registered, Some(canonical("Control+Alt+KeyK")));
        assert_eq!(get(&conn).unwrap(), stored);
    }

    #[test]
    fn a_failed_registration_keeps_the_old_shortcut() {
        let (_d, conn) = db();
        let err = set_shortcut(&conn, "Control+Alt+KeyK", |_| Err("taken".into())).unwrap_err();
        assert_eq!(err, "taken");
        assert_eq!(get(&conn).unwrap(), hotkey(DEFAULT_SHORTCUT, true));
    }

    #[test]
    fn an_invalid_shortcut_never_reaches_registration() {
        let (_d, conn) = db();
        assert!(set_shortcut(&conn, "Alt+Space", |_| panic!("registered an invalid shortcut")).is_err());
        assert_eq!(get(&conn).unwrap(), hotkey(DEFAULT_SHORTCUT, true));
    }

    #[test]
    fn setting_the_current_shortcut_registers_it_again() {
        let (_d, conn) = db();
        let mut registered = false;
        set_shortcut(&conn, DEFAULT_SHORTCUT, |_| {
            registered = true;
            Ok(())
        })
        .unwrap();
        assert!(registered, "a shortcut that failed to register at launch could never be retried");
    }

    #[test]
    fn turning_off_keeps_the_shortcut_and_turning_on_registers_it() {
        let (_d, conn) = db();
        set_shortcut(&conn, "Control+Alt+KeyK", |_| Ok(())).unwrap();
        assert_eq!(set_on(&conn, false, |_| panic!("registered while turning off")).unwrap(), hotkey("Control+Alt+KeyK", false));
        assert_eq!(get(&conn).unwrap(), hotkey("Control+Alt+KeyK", false));

        let mut registered = None;
        let on = set_on(&conn, true, |s| {
            registered = Some(s.into_string());
            Ok(())
        })
        .unwrap();
        assert_eq!(on, hotkey("Control+Alt+KeyK", true));
        assert_eq!(registered, Some(canonical("Control+Alt+KeyK")));
    }

    #[test]
    fn turning_on_a_taken_shortcut_stays_off() {
        let (_d, conn) = db();
        set_on(&conn, false, |_| Ok(())).unwrap();
        assert_eq!(set_on(&conn, true, |_| Err("taken".into())).unwrap_err(), "taken");
        assert_eq!(get(&conn).unwrap(), hotkey(DEFAULT_SHORTCUT, false));
    }

    #[test]
    fn a_new_shortcut_while_off_is_saved_without_registering() {
        let (_d, conn) = db();
        set_on(&conn, false, |_| Ok(())).unwrap();
        let stored = set_shortcut(&conn, "Control+Alt+KeyK", |_| panic!("registered while off")).unwrap();
        assert_eq!(stored, hotkey("Control+Alt+KeyK", false));
        assert_eq!(get(&conn).unwrap(), stored);
    }
}
