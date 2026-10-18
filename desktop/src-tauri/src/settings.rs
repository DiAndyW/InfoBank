use keyring_core::Entry;
use rusqlite::Connection;

#[derive(serde::Serialize)]
pub struct Settings {
    pub server_url: Option<String>,
    pub has_secret: bool,
    pub quick_capture: crate::shortcut::Hotkey,
}

pub fn get(conn: &Connection, secret: &Entry) -> Result<Settings, String> {
    let server_url = conn
        .query_row("SELECT server_url FROM device", [], |r| r.get(0))
        .map_err(|e| e.to_string())?;
    let has_secret = match secret.get_password() {
        Ok(_) => true,
        Err(keyring_core::Error::NoEntry) => false,
        Err(e) => return Err(format!("Couldn't read the keychain: {e}")),
    };
    Ok(Settings { server_url, has_secret, quick_capture: crate::shortcut::get(conn)? })
}

pub fn save(conn: &Connection, secret: &Entry, server_url: &str, new_secret: Option<&str>) -> Result<(), String> {
    let url = url::Url::parse(server_url.trim())
        .map_err(|_| "Enter the Server URL, starting with https://".to_string())?;
    let local = matches!(url.host_str(), Some("localhost" | "127.0.0.1"));
    if !(url.scheme() == "https" || (url.scheme() == "http" && local)) || url.host_str().is_none() {
        return Err("The Server URL must start with https://".into());
    }
    let url = url.as_str().trim_end_matches('/').to_string();

    // The secret goes first so a keychain failure leaves Settings as they were.
    match new_secret.map(str::trim) {
        Some("") => return Err("The secret can't be blank".into()),
        Some(s) => secret.set_password(s).map_err(|e| format!("Couldn't save to the keychain: {e}"))?,
        None => {
            let current = get(conn, secret)?;
            if !current.has_secret {
                return Err("Enter the shared secret".into());
            }
            // A mistyped URL must not receive the secret.
            if current.server_url.as_deref() != Some(url.as_str()) {
                return Err("Enter the secret again for a new Server".into());
            }
        }
    }
    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
    let new_server: bool =
        tx.query_row("SELECT server_url IS NOT ?1 FROM device", [&url], |r| r.get(0)).map_err(|e| e.to_string())?;
    if new_server {
        // A cursor and mirror only mean something to the Server they came from; unsynced Captures and Topics go to the new one.
        tx.execute_batch(
            "DELETE FROM items WHERE id NOT IN
                 (SELECT json_extract(op, '$.item_id') FROM outbox WHERE json_extract(op, '$.type') = 'CaptureItem');
             DELETE FROM topics WHERE id NOT IN
                 (SELECT json_extract(op, '$.topic_id') FROM outbox WHERE json_extract(op, '$.type') = 'CreateTopic');
             UPDATE device SET pull_cursor = 0;",
        )
        .map_err(|e| e.to_string())?;
    }
    tx.execute("UPDATE device SET server_url = ?1", [&url]).map_err(|e| e.to_string())?;
    tx.commit().map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use keyring_core::api::CredentialStoreApi;

    fn env() -> (tempfile::TempDir, Connection, Entry) {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        // A fresh in-memory keychain per test; nothing touches the real Keychain.
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        (dir, conn, secret)
    }

    fn cursor(conn: &Connection) -> i64 {
        conn.query_row("SELECT pull_cursor FROM device", [], |r| r.get(0)).unwrap()
    }

    #[test]
    fn first_launch_has_nothing_set() {
        let (_d, conn, secret) = env();
        let s = get(&conn, &secret).unwrap();
        assert_eq!(s.server_url, None);
        assert!(!s.has_secret);
        assert!(s.quick_capture.on);
    }

    #[test]
    fn url_validation() {
        let ok = [
            ("https://notes.example.com", "https://notes.example.com"),
            ("  https://notes.example.com/  ", "https://notes.example.com"),
            ("HTTPS://Notes.Example.com", "https://notes.example.com"),
            ("http://localhost:8080", "http://localhost:8080"),
            ("http://127.0.0.1:8080/", "http://127.0.0.1:8080"),
        ];
        for (input, stored) in ok {
            let (_d, conn, secret) = env();
            save(&conn, &secret, input, Some("s3cret")).unwrap_or_else(|e| panic!("{input:?} rejected: {e}"));
            assert_eq!(get(&conn, &secret).unwrap().server_url.as_deref(), Some(stored), "input {input:?}");
        }
        for input in ["http://notes.example.com", "notes.example.com", "", "ftp://localhost", "https://"] {
            let (_d, conn, secret) = env();
            assert!(save(&conn, &secret, input, Some("s3cret")).is_err(), "{input:?} accepted");
            assert_eq!(get(&conn, &secret).unwrap().server_url, None, "{input:?} was stored");
        }
    }

    #[test]
    fn secret_round_trips_trimmed_and_is_never_returned() {
        let (_d, conn, secret) = env();
        save(&conn, &secret, "https://notes.example.com", Some("  s3cret\n")).unwrap();
        assert_eq!(secret.get_password().unwrap(), "s3cret");
        let json = serde_json::to_string(&get(&conn, &secret).unwrap()).unwrap();
        assert!(json.contains("\"has_secret\":true"), "{json}");
        assert!(!json.contains("s3cret"), "settings leaked the secret: {json}");
    }

    #[test]
    fn saving_without_a_secret_keeps_the_stored_one() {
        let (_d, conn, secret) = env();
        save(&conn, &secret, "https://a.example.com", Some("s3cret")).unwrap();
        save(&conn, &secret, "https://a.example.com/", None).unwrap();
        assert_eq!(secret.get_password().unwrap(), "s3cret");
    }

    #[test]
    fn a_new_server_needs_the_secret_again() {
        let (_d, conn, secret) = env();
        save(&conn, &secret, "https://a.example.com", Some("s3cret")).unwrap();
        let err = save(&conn, &secret, "https://b.example.com", None).unwrap_err();
        assert!(err.contains("secret again"), "{err}");
        assert_eq!(get(&conn, &secret).unwrap().server_url.as_deref(), Some("https://a.example.com"));
    }

    #[test]
    fn a_secret_is_required_the_first_time() {
        let (_d, conn, secret) = env();
        assert!(save(&conn, &secret, "https://notes.example.com", None).is_err());
        assert!(save(&conn, &secret, "https://notes.example.com", Some("   ")).is_err());
        assert_eq!(get(&conn, &secret).unwrap().server_url, None);
    }

    #[test]
    fn keychain_failure_saves_nothing() {
        let (_d, conn, secret) = env();
        let mock: &keyring_core::mock::Cred = secret.as_any().downcast_ref().unwrap();
        mock.set_error(keyring_core::Error::Invalid("keychain".into(), "denied".into()));
        assert!(save(&conn, &secret, "https://notes.example.com", Some("s3cret")).is_err());
        assert_eq!(get(&conn, &secret).unwrap().server_url, None);
    }

    #[test]
    fn changing_the_url_resets_the_pull_cursor() {
        let (_d, conn, secret) = env();
        save(&conn, &secret, "https://a.example.com", Some("s3cret")).unwrap();
        conn.execute("UPDATE device SET pull_cursor = 42", []).unwrap();

        save(&conn, &secret, "https://a.example.com/", None).unwrap();
        assert_eq!(cursor(&conn), 42, "the same Server reset the cursor");

        save(&conn, &secret, "https://b.example.com", Some("s3cret")).unwrap();
        assert_eq!(cursor(&conn), 0, "a new Server kept the old cursor");
    }

    #[test]
    fn a_new_server_clears_the_old_ones_items_but_keeps_unsynced_captures_and_topics() {
        let (d, conn, secret) = env();
        save(&conn, &secret, "https://a.example.com", Some("s3cret")).unwrap();
        conn.execute_batch(
            "INSERT INTO items (id, text, capture_time) VALUES ('pulled', 'x', 1);
             INSERT INTO topics (id, name) VALUES ('old', 'Old');",
        )
        .unwrap();
        crate::feed::capture(&conn, d.path(), "unsynced", &[], None, 2).unwrap();
        crate::topics::create(&conn, "Mine", 3).unwrap();
        let count = |table: &str| -> i64 { conn.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0)).unwrap() };

        save(&conn, &secret, "https://a.example.com", None).unwrap();
        assert_eq!(count("items"), 2, "the same Server lost Items");

        save(&conn, &secret, "https://b.example.com", Some("s3cret")).unwrap();
        let text: String = conn.query_row("SELECT text FROM items", [], |r| r.get(0)).unwrap();
        let name: String = conn.query_row("SELECT name FROM topics", [], |r| r.get(0)).unwrap();
        assert_eq!((count("items"), text.as_str(), count("topics"), name.as_str()), (1, "unsynced", 1, "Mine"));
        assert_eq!(count("outbox"), 2);
    }
}
