use std::path::{Path, PathBuf};

use rusqlite::{Connection, OptionalExtension};
use tokio::io::AsyncWriteExt;

use crate::{AppState, files, preview, sync, thumbnails};

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
    let written: Result<u64, String> = async {
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
        Ok(got)
    }
    .await;
    let published = written.and_then(|size| {
        let conn = state.db.lock().unwrap();
        let exists: bool = conn.query_row("SELECT EXISTS(SELECT 1 FROM attachments WHERE id = ?1)", [id], |r| r.get(0))
            .map_err(crate::error_message::message)?;
        if !exists { return Err("Unknown attachment".into()); }
        std::fs::rename(&partial, &target).map_err(crate::error_message::message)?;
        conn.execute(
            "INSERT INTO cached_files (attachment_id, kind, path, size_bytes, last_used_at) VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT (attachment_id, kind) DO UPDATE SET
                path = excluded.path, size_bytes = excluded.size_bytes, last_used_at = excluded.last_used_at",
            (id, kind, rel, size as i64, now_us),
        ).map_err(crate::error_message::message)?;
        Ok(target)
    });
    if published.is_err() {
        let _ = tokio::fs::remove_file(&partial).await;
    }
    published
}

fn browser_image(mime_type: &str) -> bool {
    matches!(mime_type, "image/jpeg" | "image/png" | "image/gif" | "image/webp" | "image/bmp" | "image/avif" | "image/svg+xml")
}

pub async fn thumbnail(state: &AppState, id: &str, now_us: i64) -> Result<PathBuf, String> {
    let id = uuid::Uuid::parse_str(id).map_err(|_| "Unknown attachment")?.to_string();
    if let Some(path) = cached(state, &id, "thumbnail", now_us)? {
        return Ok(path);
    }
    let (mime_type, has_thumbnail): (String, bool) = state
        .db.lock().unwrap()
        .query_row("SELECT mime_type, has_thumbnail FROM attachments WHERE id = ?1", [&id], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(|_| "Unknown attachment")?;
    if browser_image(&mime_type) {
        if let Some(path) = cached(state, &id, "file", now_us)? {
            return Ok(path);
        }
    } else if let Some(path) = local_preview(state, &id, now_us).await {
        return Ok(path);
    }
    if !has_thumbnail {
        return Err("No preview yet".into());
    }
    download(state, &id, "thumbnail", &format!("/attachments/{id}/thumbnail"), &format!("thumbnails/{id}.jpg"), Size::AtMost(MAX_THUMBNAIL_BYTES), now_us).await
}

pub(crate) async fn local_preview(state: &AppState, id: &str, now_us: i64) -> Option<PathBuf> {
    let source = cached(state, id, "file", now_us).ok()??;
    let mime_type: String = state.db.lock().unwrap()
        .query_row("SELECT mime_type FROM attachments WHERE id = ?1", [id], |r| r.get(0)).ok()?;
    if !mime_type.starts_with("video/") && !mime_type.starts_with("image/") {
        return None;
    }
    let key = format!("preview:{id}");
    if thumbnails::backing_off(state, &key) {
        return None;
    }
    let generated = async {
        let bytes = preview::make(source).await?;
        publish_preview(state, id, &bytes, now_us).await
    }.await;
    if generated.is_some() {
        state.thumbnail_retries.lock().unwrap().remove(&key);
    } else {
        thumbnails::note_failure(state, &key);
    }
    generated
}

async fn publish_preview(state: &AppState, id: &str, bytes: &[u8], now_us: i64) -> Option<PathBuf> {
    let relative = format!("thumbnails/{id}.jpg");
    let target = state.dir.join(&relative);
    let temporary = target.with_file_name(format!(".dl-{}", uuid::Uuid::new_v4()));
    tokio::fs::create_dir_all(target.parent()?).await.ok()?;
    let written = async {
        tokio::fs::write(&temporary, bytes).await.ok()?;
        let conn = state.db.lock().unwrap();
        let exists: bool = conn.query_row("SELECT EXISTS(SELECT 1 FROM attachments WHERE id = ?1)", [id], |r| r.get(0)).ok()?;
        if !exists {
            return None;
        }
        std::fs::rename(&temporary, &target).ok()?;
        conn.execute(
            "INSERT INTO cached_files (attachment_id, kind, path, size_bytes, last_used_at) VALUES (?1, 'thumbnail', ?2, ?3, ?4)
             ON CONFLICT(attachment_id, kind) DO UPDATE SET path = excluded.path, size_bytes = excluded.size_bytes, last_used_at = excluded.last_used_at",
            (id, relative, bytes.len() as i64, now_us),
        ).ok()?;
        Some(())
    }.await;
    if written.is_none() {
        let _ = tokio::fs::remove_file(&temporary).await;
        return None;
    }
    Some(target)
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

pub async fn save(state: &AppState, id: &str, now_us: i64, destination: &Path) -> Result<(), String> {
    let cached = file(state, id, now_us).await?;
    let temporary = destination.with_file_name(format!(".dl-{}", uuid::Uuid::new_v4()));
    let out = std::fs::OpenOptions::new().write(true).create_new(true).open(&temporary)
        .map_err(crate::error_message::message)?;
    drop(out);
    // Publish only a complete copy so a failed save cannot damage an existing file.
    let saved = std::fs::copy(&cached, &temporary)
        .and_then(|_| std::fs::rename(&temporary, destination))
        .map_err(crate::error_message::message);
    if saved.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    saved
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

    #[tokio::test]
    async fn save_copies_the_cached_original_to_the_destination() {
        let (d, conn) = fresh();
        let id = uuid::Uuid::new_v4().to_string();
        put(&d, &conn, &id, "file", 17, 0, 0, false);
        put(&d, &conn, &id, "thumbnail", 1, 0, 0, false);
        let original = d.path().join(format!("files/{id}/f.png"));
        std::fs::write(&original, b"original contents").unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let state = AppState::new(conn, secret, d.path().to_path_buf());
        let destination = d.path().join("saved.png");

        save(&state, &id, 10, &destination).await.unwrap();

        assert_eq!(std::fs::read(&destination).unwrap(), b"original contents");
        assert_eq!(std::fs::read(&original).unwrap(), b"original contents");
        assert_eq!(kept(&state.db.lock().unwrap(), "file"), [id]);
    }

    #[tokio::test]
    async fn save_downloads_the_original_first_when_it_isnt_cached() {
        let mut server = crate::sync::server_tests::TestServer::new();
        server.start();
        let (d, conn) = fresh();
        conn.execute("UPDATE device SET server_url = ?1", [&server.url]).unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        secret.set_password(&server.secret).unwrap();
        let state = AppState::new(conn, secret, d.path().to_path_buf());
        let staged = files::stage_bytes(d.path(), "original.txt", b"original contents").unwrap();
        crate::feed::capture(&state.db.lock().unwrap(), d.path(), "", std::slice::from_ref(&staged.id), &crate::feed::Target::Inbox, None, 1).unwrap();
        sync::cycle(&state).await.unwrap();
        evict(&state.db.lock().unwrap(), d.path(), 2, 0).unwrap();
        assert!(kept(&state.db.lock().unwrap(), "file").is_empty());
        let original = d.path().join(format!("files/{}/original.txt", staged.id));
        assert!(!original.exists());
        let destination = d.path().join("saved.txt");

        save(&state, &staged.id, 3, &destination).await.unwrap();

        assert_eq!(std::fs::read(destination).unwrap(), b"original contents");
        assert_eq!(std::fs::read(original).unwrap(), b"original contents");
        assert_eq!(kept(&state.db.lock().unwrap(), "file"), [staged.id]);
    }

    #[tokio::test]
    async fn save_copy_failure_preserves_existing_destination_and_removes_temporary_file() {
        let (d, conn) = fresh();
        let id = uuid::Uuid::new_v4().to_string();
        put(&d, &conn, &id, "file", 1, 0, 0, false);
        let original = d.path().join(format!("files/{id}/f.png"));
        std::fs::remove_file(&original).unwrap();
        std::fs::create_dir(&original).unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let state = AppState::new(conn, secret, d.path().to_path_buf());
        let output = tempfile::tempdir().unwrap();
        let destination = output.path().join("saved.png");
        std::fs::write(&destination, b"existing contents").unwrap();

        assert!(save(&state, &id, 10, &destination).await.is_err());

        assert_eq!(std::fs::read(&destination).unwrap(), b"existing contents");
        assert_eq!(std::fs::read_dir(output.path()).unwrap().count(), 1);
    }

    #[tokio::test]
    async fn save_replaces_existing_destination_without_temporary_siblings() {
        let (d, conn) = fresh();
        let id = uuid::Uuid::new_v4().to_string();
        put(&d, &conn, &id, "file", 1, 0, 0, false);
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let state = AppState::new(conn, secret, d.path().to_path_buf());
        let output = tempfile::tempdir().unwrap();
        let destination = output.path().join("saved.png");
        std::fs::write(&destination, b"existing contents").unwrap();

        save(&state, &id, 10, &destination).await.unwrap();

        assert_eq!(std::fs::read(&destination).unwrap(), b"x");
        assert_eq!(std::fs::read_dir(output.path()).unwrap().count(), 1);
    }

    #[tokio::test]
    async fn save_onto_cached_original_preserves_contents() {
        let (d, conn) = fresh();
        let id = uuid::Uuid::new_v4().to_string();
        put(&d, &conn, &id, "file", 1, 0, 0, false);
        let original = d.path().join(format!("files/{id}/f.png"));
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let state = AppState::new(conn, secret, d.path().to_path_buf());

        save(&state, &id, 10, &original).await.unwrap();

        assert_eq!(std::fs::read(&original).unwrap(), b"x");
        assert_eq!(std::fs::read_dir(original.parent().unwrap()).unwrap().count(), 1);
    }

    #[tokio::test]
    async fn a_late_download_does_not_restore_removed_content() {
        use tokio::io::AsyncReadExt;
        for kind in ["thumbnail", "file"] {
            for removal in ["attachment", "discard", "purge"] {
                let (d, conn) = fresh();
                let id = uuid::Uuid::new_v4().to_string();
                put(&d, &conn, &id, "file", 1, 0, 0, true);
                let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
                let url = format!("http://{}", listener.local_addr().unwrap());
                conn.execute("UPDATE device SET server_url = ?1", [&url]).unwrap();
                let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
                secret.set_password("test-secret").unwrap();
                let state = AppState::new(conn, secret, d.path().to_path_buf());
                let (requested, received) = tokio::sync::oneshot::channel();
                let (release, released) = tokio::sync::oneshot::channel();
                let server = tokio::spawn(async move {
                    let (mut stream, _) = listener.accept().await.unwrap();
                    let mut request = Vec::new();
                    while !request.ends_with(b"\r\n\r\n") {
                        request.push(stream.read_u8().await.unwrap());
                    }
                    requested.send(()).unwrap();
                    released.await.unwrap();
                    stream.write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 1\r\nconnection: close\r\n\r\nx").await.unwrap();
                });
                let rel = if kind == "thumbnail" { format!("thumbnails/{id}.jpg") } else { format!("files/{id}/f.png") };
                let remove = async {
                    received.await.unwrap();
                    {
                        let conn = state.db.lock().unwrap();
                        let item = format!("item-{id}");
                        match removal {
                            "attachment" => { conn.execute("DELETE FROM attachments WHERE id = ?1", [&id]).unwrap(); }
                            "discard" => {
                                conn.execute("UPDATE items SET sync_error = 'refused' WHERE id = ?1", [&item]).unwrap();
                                crate::feed::discard_item(&conn, d.path(), &item).unwrap();
                            }
                            _ => { conn.execute("DELETE FROM items WHERE id = ?1", [&item]).unwrap(); }
                        }
                        evict(&conn, d.path(), 1, FILE_CACHE_BYTES).unwrap();
                    }
                    release.send(()).unwrap();
                };
                let (result, ()) = tokio::join!(download(&state, &id, kind, "/content", &rel, Size::Exactly(1), 2), remove);
                server.await.unwrap();
                assert!(!d.path().join(&rel).exists(), "{kind}/{removal}: final file restored");
                assert!(kept(&state.db.lock().unwrap(), kind).is_empty(), "{kind}/{removal}: cache row restored");
                assert!(result.is_err(), "{kind}/{removal}");
                assert_eq!(std::fs::read_dir(d.path().join(&rel).parent().unwrap()).unwrap().count(), 0);
            }
        }
    }

    #[tokio::test]
    async fn a_tiff_uses_a_native_preview_before_upload() {
        let (d, conn) = fresh();
        let staged = files::stage_bytes(d.path(), "photo.tiff", include_bytes!("../fixtures/photo.tiff")).unwrap();
        crate::feed::capture(&conn, d.path(), "", std::slice::from_ref(&staged.id), &crate::feed::Target::Inbox, None, 1).unwrap();
        let mime: String = conn.query_row("SELECT mime_type FROM attachments WHERE id = ?1", [&staged.id], |r| r.get(0)).unwrap();
        assert_eq!(mime, "image/tiff");
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let state = AppState::new(conn, secret, d.path().to_path_buf());
        let path = thumbnail(&state, &staged.id, 2).await.unwrap();
        assert_eq!(path, d.path().join(format!("thumbnails/{}.jpg", staged.id)));
        assert!(std::fs::read(path).unwrap().starts_with(&[0xff, 0xd8]));
        assert_eq!(kept(&state.db.lock().unwrap(), "thumbnail"), [staged.id]);
    }

    #[tokio::test]
    async fn a_late_preview_does_not_restore_removed_content() {
        for removal in ["attachment", "discard", "purge"] {
            let (d, conn) = fresh();
            let id = uuid::Uuid::new_v4().to_string();
            put(&d, &conn, &id, "file", 1, 0, 0, false);
            let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
            let state = AppState::new(conn, secret, d.path().to_path_buf());
            let bytes = b"\xff\xd8generated poster";
            {
                let conn = state.db.lock().unwrap();
                let item_id = format!("item-{id}");
                match removal {
                    "attachment" => { conn.execute("DELETE FROM attachments WHERE id = ?1", [&id]).unwrap(); }
                    "discard" => {
                        conn.execute("UPDATE items SET sync_error = 'refused' WHERE id = ?1", [&item_id]).unwrap();
                        crate::feed::discard_item(&conn, d.path(), &item_id).unwrap();
                    }
                    _ => { conn.execute("DELETE FROM items WHERE id = ?1", [&item_id]).unwrap(); }
                }
                evict(&conn, d.path(), 1, FILE_CACHE_BYTES).unwrap();
            }
            let result = publish_preview(&state, &id, bytes, 1).await;
            let poster_exists = d.path().join(format!("thumbnails/{id}.jpg")).exists();
            let rows = kept(&state.db.lock().unwrap(), "thumbnail");
            assert!(!poster_exists && rows.is_empty(), "{removal}: poster exists = {poster_exists}, cached thumbnails = {rows:?}");
            assert!(result.is_none(), "{removal}");
            assert_eq!(std::fs::read_dir(d.path().join("thumbnails")).unwrap().count(), 0, "{removal}: temporary file retained");
        }
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
        conn.execute("UPDATE attachments SET mime_type = 'image/png', has_thumbnail = 0 WHERE id = ?1", [&id]).unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        let state = AppState::new(conn, secret, d.path().to_path_buf());
        let path = thumbnail(&state, &id, 1).await.unwrap();
        assert_eq!(path, d.path().join(format!("files/{id}/f.png")));
        assert_eq!(std::fs::read(path).unwrap(), b"x");
    }

}
