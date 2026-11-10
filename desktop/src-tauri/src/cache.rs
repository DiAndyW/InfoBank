use std::path::{Path, PathBuf};

use rusqlite::{Connection, OptionalExtension};
use tokio::io::AsyncWriteExt;

use crate::{AppState, files, sync};

pub const FILE_CACHE_BYTES: i64 = 500 << 20;
const THUMBNAIL_KEEP_US: i64 = 60 * 24 * 60 * 60 * 1_000_000;
const OFFLINE: &str = "Can't download while offline";
pub const MAX_THUMBNAIL_BYTES: u64 = 1 << 20;
const TOO_BIG: &str = "The Server sent more than expected";

enum Size {
    Exactly(u64),
    AtMost(u64),
}

fn cached(state: &AppState, id: &str, kind: &str, now_us: i64) -> Result<Option<PathBuf>, String> {
    let conn = state.db.lock().unwrap();
    let path: Option<String> = conn
        .query_row("SELECT path FROM cached_files WHERE attachment_id = ?1 AND kind = ?2", [id, kind], |r| r.get(0))
        .optional()
        .map_err(crate::error_message::message)?;
    let Some(path) = path else { return Ok(None) };
    if !state.dir.join(&path).exists() {
        conn.execute("DELETE FROM cached_files WHERE attachment_id = ?1 AND kind = ?2", [id, kind]).map_err(crate::error_message::message)?;
        return Ok(None);
    }
    conn.execute("UPDATE cached_files SET last_used_at = ?3 WHERE attachment_id = ?1 AND kind = ?2", (id, kind, now_us))
        .map_err(crate::error_message::message)?;
    Ok(Some(state.dir.join(path)))
}

async fn download(state: &AppState, id: &str, kind: &str, route: &str, rel: &str, size: Size, now_us: i64) -> Result<PathBuf, String> {
    let (url, token) = sync::server_access(state).map_err(|_| OFFLINE.to_string())?;
    let send = state.http.get(format!("{url}{route}")).bearer_auth(token).send();
    let mut res = tokio::time::timeout(sync::IDLE_TIMEOUT, send).await.ok().and_then(Result::ok).ok_or(OFFLINE)?;
    match res.status() {
        s if s.is_success() => {}
        reqwest::StatusCode::NOT_FOUND => return Err("Not on the Server yet".into()),
        reqwest::StatusCode::UNAUTHORIZED => return Err("The Server rejected the secret".into()),
        s => return Err(format!("The Server answered {s}")),
    }
    let max = match size {
        Size::Exactly(n) | Size::AtMost(n) => n,
    };
    if res.content_length().is_some_and(|n| n > max) {
        return Err(TOO_BIG.into());
    }
    let target = state.dir.join(rel);
    let partial = target.with_file_name(format!(".dl-{}", uuid::Uuid::new_v4()));
    let written: Result<(), String> = async {
        let save = |_| "Couldn't save the download".to_string();
        tokio::fs::create_dir_all(target.parent().expect("rel has a directory")).await.map_err(save)?;
        let mut out = tokio::fs::File::create(&partial).await.map_err(save)?;
        let mut got: u64 = 0;
        while let Some(chunk) =
            tokio::time::timeout(sync::IDLE_TIMEOUT, res.chunk()).await.ok().and_then(Result::ok).ok_or(OFFLINE)?
        {
            got += chunk.len() as u64;
            if got > max {
                return Err(TOO_BIG.to_string());
            }
            out.write_all(&chunk).await.map_err(save)?;
        }
        if matches!(size, Size::Exactly(n) if got != n) {
            return Err("The download was incomplete".to_string());
        }
        out.flush().await.map_err(save)?;
        tokio::fs::rename(&partial, &target).await.map_err(save)
    }
    .await;
    if written.is_err() {
        let _ = tokio::fs::remove_file(&partial).await;
    }
    written?;
    let size = tokio::fs::metadata(&target).await.map_err(crate::error_message::message)?.len() as i64;
    state
        .db
        .lock()
        .unwrap()
        .execute(
            "INSERT INTO cached_files (attachment_id, kind, path, size_bytes, last_used_at) VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT (attachment_id, kind) DO UPDATE SET
                path = excluded.path, size_bytes = excluded.size_bytes, last_used_at = excluded.last_used_at",
            (id, kind, rel, size, now_us),
        )
        .map_err(crate::error_message::message)?;
    Ok(target)
}

pub async fn thumbnail(state: &AppState, id: &str, now_us: i64) -> Result<PathBuf, String> {
    let id = uuid::Uuid::parse_str(id).map_err(|_| "Unknown attachment")?.to_string();
    if let Some(path) = cached(state, &id, "thumbnail", now_us)? {
        return Ok(path);
    }
    let own: Option<String> = state
        .db
        .lock()
        .unwrap()
        .query_row(
            "SELECT c.path FROM attachments a JOIN cached_files c ON c.attachment_id = a.id AND c.kind = 'file'
             WHERE a.id = ?1 AND a.mime_type LIKE 'image/%'",
            [&id],
            |r| r.get(0),
        )
        .optional()
        .map_err(crate::error_message::message)?;
    if own.is_some() {
        if let Some(path) = cached(state, &id, "file", now_us)? {
            return Ok(path);
        }
    }
    download(state, &id, "thumbnail", &format!("/attachments/{id}/thumbnail"), &format!("thumbnails/{id}.jpg"), Size::AtMost(MAX_THUMBNAIL_BYTES), now_us).await
}

pub fn stored(state: &AppState, id: &str, now_us: i64) -> Result<bool, String> {
    let id = uuid::Uuid::parse_str(id).map_err(|_| "Unknown attachment")?.to_string();
    Ok(cached(state, &id, "file", now_us)?.is_some())
}

pub async fn file(state: &AppState, id: &str, now_us: i64) -> Result<PathBuf, String> {
    let id = uuid::Uuid::parse_str(id).map_err(|_| "Unknown attachment")?.to_string();
    if let Some(path) = cached(state, &id, "file", now_us)? {
        return Ok(path);
    }
    let (filename, uploaded, size_bytes): (String, bool, i64) = state
        .db
        .lock()
        .unwrap()
        .query_row("SELECT filename, uploaded, size_bytes FROM attachments WHERE id = ?1", [&id], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })
        .map_err(|_| "Unknown attachment")?;
    if !uploaded {
        return Err("Not uploaded yet".into());
    }
    let size_bytes = u64::try_from(size_bytes).ok().filter(|&n| n <= files::MAX_ATTACHMENT_BYTES).ok_or(TOO_BIG)?;
    let rel = format!("files/{id}/{}", files::safe_name(&filename));
    let path = download(state, &id, "file", &format!("/attachments/{id}"), &rel, Size::Exactly(size_bytes), now_us).await?;
    evict(&state.db.lock().unwrap(), &state.dir, now_us, FILE_CACHE_BYTES).map_err(crate::error_message::message)?;
    Ok(path)
}

pub fn start_prefetch<R: tauri::Runtime>(app: &tauri::AppHandle<R>, now_us: i64) {
    use tauri::Manager;
    if app.state::<AppState>().prefetching.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return;
    }
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let state = app.state::<AppState>();
        prefetch_thumbnails(&state, now_us).await;
        state.prefetching.store(false, std::sync::atomic::Ordering::SeqCst);
    });
}

pub(crate) async fn prefetch_thumbnails(state: &AppState, now_us: i64) {
    let ids: Vec<String> = {
        let conn = state.db.lock().unwrap();
        let Ok(mut stmt) = conn.prepare(
            "SELECT a.id FROM attachments a JOIN items i ON i.id = a.item_id
             WHERE a.has_thumbnail = 1 AND i.deleted_at IS NULL AND i.capture_time >= ?1
               AND NOT EXISTS (SELECT 1 FROM cached_files c WHERE c.attachment_id = a.id AND c.kind = 'thumbnail')",
        ) else {
            return;
        };
        stmt.query_map([now_us - THUMBNAIL_KEEP_US], |r| r.get(0)).map(|rows| rows.flatten().collect()).unwrap_or_default()
    };
    use futures_util::StreamExt;
    let mut downloads = futures_util::stream::iter(ids).map(|id| async move { thumbnail(state, &id, now_us).await }).buffer_unordered(4);
    while let Some(result) = downloads.next().await {
        if result.is_err() {
            return;
        }
    }
}

pub fn sweep_partial_downloads(dir: &Path) {
    let file_dirs = std::fs::read_dir(dir.join("files")).into_iter().flatten().flatten().map(|e| e.path());
    for folder in file_dirs.chain([dir.join("thumbnails")]) {
        for entry in std::fs::read_dir(folder).into_iter().flatten().flatten() {
            if entry.file_name().to_string_lossy().starts_with(".dl-") {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
}

pub fn evict(conn: &Connection, dir: &Path, now_us: i64, max_file_bytes: i64) -> rusqlite::Result<()> {
    let doomed: Vec<(String, String, String)> = conn
        .prepare(
            "SELECT c.attachment_id, c.kind, c.path FROM cached_files c
             LEFT JOIN attachments a ON a.id = c.attachment_id
             LEFT JOIN items i ON i.id = a.item_id
             WHERE a.id IS NULL OR (c.kind = 'thumbnail' AND c.last_used_at < ?1 AND i.capture_time < ?1)
             UNION ALL
             SELECT attachment_id, kind, path FROM (
                 SELECT c.attachment_id, c.kind, c.path,
                        sum(c.size_bytes) OVER (ORDER BY c.last_used_at DESC, c.attachment_id) AS running
                 FROM cached_files c JOIN attachments a ON a.id = c.attachment_id
                 WHERE c.kind = 'file' AND a.uploaded = 1)
             WHERE running > ?2",
        )?
        .query_map((now_us - THUMBNAIL_KEEP_US, max_file_bytes), |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
        .collect::<rusqlite::Result<_>>()?;
    for (id, kind, path) in doomed {
        let path = dir.join(path);
        let _ = std::fs::remove_file(&path);
        if kind == "file" {
            let _ = path.parent().map(std::fs::remove_dir);
        }
        conn.execute("DELETE FROM cached_files WHERE attachment_id = ?1 AND kind = ?2", [&id, &kind])?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use keyring_core::api::CredentialStoreApi;

    use super::*;

    const DAY_US: i64 = 24 * 60 * 60 * 1_000_000;

    fn fresh() -> (tempfile::TempDir, Connection) {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        (dir, conn)
    }

    #[allow(clippy::too_many_arguments)]
    fn put(d: &tempfile::TempDir, conn: &Connection, id: &str, kind: &str, size: i64, used: i64, captured: i64, uploaded: bool) {
        conn.execute("INSERT INTO items (id, capture_time) VALUES (?1, ?2) ON CONFLICT DO NOTHING", (format!("item-{id}"), captured))
            .unwrap();
        conn.execute(
            "INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail)
             VALUES (?1, ?2, 'f.png', 'image/png', ?3, ?4, 1) ON CONFLICT DO NOTHING",
            (id, format!("item-{id}"), size, uploaded),
        )
        .unwrap();
        let path = if kind == "file" { format!("files/{id}/f.png") } else { format!("thumbnails/{id}.jpg") };
        std::fs::create_dir_all(d.path().join(&path).parent().unwrap()).unwrap();
        std::fs::write(d.path().join(&path), "x").unwrap();
        conn.execute(
            "INSERT INTO cached_files (attachment_id, kind, path, size_bytes, last_used_at) VALUES (?1, ?2, ?3, ?4, ?5)",
            (id, kind, &path, size, used),
        )
        .unwrap();
    }

    fn kept(conn: &Connection, kind: &str) -> Vec<String> {
        let mut stmt = conn.prepare("SELECT attachment_id FROM cached_files WHERE kind = ?1 ORDER BY attachment_id").unwrap();
        stmt.query_map([kind], |r| r.get(0)).unwrap().collect::<rusqlite::Result<_>>().unwrap()
    }

    #[test]
    fn the_cap_keeps_500_mb_of_the_most_recently_used_files() {
        let (d, conn) = fresh();
        put(&d, &conn, "older", "file", 400 << 20, 1, 0, true);
        put(&d, &conn, "newer", "file", 200 << 20, 2, 0, true);
        put(&d, &conn, "unsent", "file", 600 << 20, 0, 0, false);
        evict(&conn, d.path(), 10, FILE_CACHE_BYTES).unwrap();
        assert_eq!(kept(&conn, "file"), ["newer", "unsent"]);
        assert!(d.path().join("files/unsent/f.png").exists());
    }

    #[tokio::test]
    async fn stored_looks_for_the_original_and_never_the_thumbnail() {
        let (d, conn) = fresh();
        let original = uuid::Uuid::new_v4().to_string();
        let thumbnail_only = uuid::Uuid::new_v4().to_string();
        let absent = uuid::Uuid::new_v4().to_string();
        let missing = uuid::Uuid::new_v4().to_string();
        put(&d, &conn, &original, "file", 1, 0, 0, true);
        put(&d, &conn, &thumbnail_only, "thumbnail", 1, 0, 0, true);
        put(&d, &conn, &missing, "file", 1, 0, 0, true);
        std::fs::remove_file(d.path().join(format!("files/{missing}/f.png"))).unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let state = AppState::new(conn, secret, d.path().to_path_buf());
        assert!(stored(&state, &original, 10).unwrap());
        assert!(!stored(&state, &thumbnail_only, 10).unwrap());
        assert!(!stored(&state, &absent, 10).unwrap());
        assert!(!stored(&state, &missing, 10).unwrap());
        assert_eq!(kept(&state.db.lock().unwrap(), "file"), [original]);
        assert_eq!(stored(&state, "malformed", 10).unwrap_err(), "Unknown attachment");
    }

    #[tokio::test]
    async fn stored_finds_an_original_that_has_not_been_uploaded() {
        let (d, conn) = fresh();
        let id = uuid::Uuid::new_v4().to_string();
        put(&d, &conn, &id, "file", 1, 0, 0, false);
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let state = AppState::new(conn, secret, d.path().to_path_buf());
        assert!(stored(&state, &id, 10).unwrap());
    }

    #[tokio::test]
    async fn stored_finds_an_image_whose_preview_is_the_original() {
        let (d, conn) = fresh();
        let id = uuid::Uuid::new_v4().to_string();
        put(&d, &conn, &id, "file", 1, 0, 0, true);
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let state = AppState::new(conn, secret, d.path().to_path_buf());
        assert_eq!(thumbnail(&state, &id, 10).await.unwrap(), d.path().join(format!("files/{id}/f.png")));
        assert!(stored(&state, &id, 10).unwrap());
    }

    #[tokio::test]
    async fn file_never_returns_the_thumbnail_when_the_original_is_absent() {
        let (d, conn) = fresh();
        let id = uuid::Uuid::new_v4().to_string();
        put(&d, &conn, &id, "thumbnail", 1, 0, 0, true);
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let state = AppState::new(conn, secret, d.path().to_path_buf());
        assert_eq!(file(&state, &id, 10).await.unwrap_err(), OFFLINE);
        assert!(d.path().join(format!("thumbnails/{id}.jpg")).exists());
        assert!(kept(&state.db.lock().unwrap(), "file").is_empty());
    }

    #[test]
    fn a_thumbnail_goes_only_when_both_its_capture_and_last_use_are_old() {
        let (d, conn) = fresh();
        let now = 100 * DAY_US;
        put(&d, &conn, "old", "thumbnail", 1, 0, 0, true);
        put(&d, &conn, "seen", "thumbnail", 1, now - DAY_US, 0, true);
        put(&d, &conn, "new", "thumbnail", 1, 0, now - DAY_US, true);
        evict(&conn, d.path(), now, FILE_CACHE_BYTES).unwrap();
        assert_eq!(kept(&conn, "thumbnail"), ["new", "seen"]);
        assert!(!d.path().join("thumbnails/old.jpg").exists());
    }

    #[test]
    fn files_over_the_cap_go_least_recent_first_but_never_unuploaded_ones() {
        let (d, conn) = fresh();
        put(&d, &conn, "older", "file", 2, 1, 0, true);
        put(&d, &conn, "newer", "file", 2, 3, 0, true);
        put(&d, &conn, "mine", "file", 5, 0, 0, false);
        evict(&conn, d.path(), 10, 3).unwrap();
        assert_eq!(kept(&conn, "file"), ["mine", "newer"]);
        assert!(!d.path().join("files/older").exists(), "the emptied directory stays behind");
    }

    #[test]
    fn files_of_deleted_attachments_go() {
        let (d, conn) = fresh();
        put(&d, &conn, "gone", "thumbnail", 1, 10, 10, true);
        conn.execute("DELETE FROM items", []).unwrap();
        evict(&conn, d.path(), 10, FILE_CACHE_BYTES).unwrap();
        assert!(kept(&conn, "thumbnail").is_empty());
        assert!(!d.path().join("thumbnails/gone.jpg").exists());
    }

    #[test]
    fn partial_downloads_are_swept_and_cached_files_kept() {
        let (d, _conn) = fresh();
        for path in ["files/a/f.png", "files/a/.dl-1", "thumbnails/b.jpg", "thumbnails/.dl-2"] {
            std::fs::create_dir_all(d.path().join(path).parent().unwrap()).unwrap();
            std::fs::write(d.path().join(path), "x").unwrap();
        }
        sweep_partial_downloads(d.path());
        assert!(d.path().join("files/a/f.png").exists() && d.path().join("thumbnails/b.jpg").exists());
        assert!(!d.path().join("files/a/.dl-1").exists() && !d.path().join("thumbnails/.dl-2").exists());
    }

    #[tokio::test]
    async fn a_file_not_uploaded_by_another_device_cannot_be_opened_yet() {
        let (d, conn) = fresh();
        let id = uuid::Uuid::new_v4().to_string();
        conn.execute("INSERT INTO items (id, capture_time) VALUES ('i', 1)", []).unwrap();
        conn.execute(
            "INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail)
             VALUES (?1, 'i', 'r.pdf', 'application/pdf', 1, 0, 0)",
            [&id],
        )
        .unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let state = AppState::new(conn, secret, d.path().to_path_buf());
        assert_eq!(file(&state, &id, 1).await.unwrap_err(), "Not uploaded yet");
    }
    #[tokio::test]
    async fn an_uploaded_image_uses_its_cached_original_as_a_preview() {
        let (d, conn) = fresh();
        let id = uuid::Uuid::new_v4().to_string();
        put(&d, &conn, &id, "file", 1, 0, 0, true);
        conn.execute("UPDATE attachments SET mime_type = 'image/heic', has_thumbnail = 0 WHERE id = ?1", [&id]).unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let state = AppState::new(conn, secret, d.path().to_path_buf());
        let path = thumbnail(&state, &id, 1).await.unwrap();
        assert_eq!(path, d.path().join(format!("files/{id}/f.png")));
        assert_eq!(std::fs::read(path).unwrap(), b"x");
    }

}
