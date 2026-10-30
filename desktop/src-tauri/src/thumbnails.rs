use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use rusqlite::OptionalExtension;
use serde::Deserialize;

use crate::{AppState, sync};

pub async fn upload(state: &AppState, url: &str, secret: &str) -> Result<bool, sync::SyncError> {
    let fail = || sync::SyncError::Failed("Couldn't prepare the image preview".into());
    let candidates: Vec<(String, Option<String>, Option<String>)> = {
        let conn = state.db.lock().unwrap();
        let mut query = conn
            .prepare(
                "SELECT a.id,
             (SELECT path FROM cached_files WHERE attachment_id = a.id AND kind = 'thumbnail'),
             (SELECT path FROM cached_files WHERE attachment_id = a.id AND kind = 'file')
             FROM attachments a JOIN items i ON i.id = a.item_id
             WHERE a.uploaded = 1 AND a.has_thumbnail = 0 AND a.mime_type LIKE 'image/%'
               AND i.deleted_at IS NULL AND i.sync_error IS NULL
               AND EXISTS(SELECT 1 FROM cached_files WHERE attachment_id = a.id)
             ORDER BY a.rowid",
            )
            .map_err(|_| fail())?;
        query
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
            .map_err(|_| fail())?
            .collect::<rusqlite::Result<_>>()
            .map_err(|_| fail())?
    };
    let mut changed = false;
    let mut attempted = 0;
    for (id, thumbnail, original) in candidates {
        let retry_key = format!("{url}/attachments/{id}");
        if state.thumbnail_retries.lock().unwrap().get(&retry_key).is_some_and(|(_, after)| *after > Instant::now()) {
            continue;
        }
        if attempted >= 4 {
            break;
        }
        attempted += 1;
        let attempt: Result<bool, sync::SyncError> = async {
            let current: Option<String> = state.db.lock().unwrap().query_row("SELECT server_url FROM device", [], |row| row.get(0)).map_err(|_| fail())?;
            if current.as_deref() != Some(url) { return Ok(false); }
            let root = state.dir.clone();
            let attachment_id = id.clone();
            let prepared = tokio::task::spawn_blocking(move || -> Result<Vec<u8>, sync::SyncError> {
                if let Some(path) = thumbnail {
                    let path = root.join(path);
                    if std::fs::metadata(&path).is_ok_and(|m| m.len() <= crate::cache::MAX_THUMBNAIL_BYTES) {
                        if let Ok(bytes) = std::fs::read(path) {
                            if bytes.starts_with(&[0xff, 0xd8]) { return Ok(bytes); }
                        }
                    }
                }
                let source = root.join(original.ok_or_else(|| fail())?);
                let folder = root.join("thumbnails");
                std::fs::create_dir_all(&folder).map_err(|_| fail())?;
                let temporary = folder.join(format!(".dl-{}", uuid::Uuid::new_v4()));
                let generated = (|| {
                    let status = Command::new("/usr/bin/sips")
                        .args(["-s", "format", "jpeg", "--resampleHeightWidthMax", "400"])
                        .arg(source).arg("--out").arg(&temporary)
                        .stdout(Stdio::null()).stderr(Stdio::null()).status().map_err(|_| fail())?;
                    if !status.success() || std::fs::metadata(&temporary).map_err(|_| fail())?.len() > crate::cache::MAX_THUMBNAIL_BYTES {
                        return Err(fail());
                    }
                    let bytes = std::fs::read(&temporary).map_err(|_| fail())?;
                    if !bytes.starts_with(&[0xff, 0xd8]) { return Err(fail()); }
                    std::fs::rename(&temporary, folder.join(format!("{attachment_id}.jpg"))).map_err(|_| fail())?;
                    Ok(bytes)
                })();
                let _ = std::fs::remove_file(temporary);
                generated
            }).await.map_err(|_| fail())??;
            {
                let conn = state.db.lock().unwrap();
                let current: Option<String> = conn.query_row("SELECT server_url FROM device", [], |row| row.get(0)).map_err(|_| fail())?;
                if current.as_deref() != Some(url) { return Ok(false); }
                let exists: Option<bool> = conn.query_row("SELECT 1 FROM attachments WHERE id = ?1", [&id], |row| row.get(0)).optional().map_err(|_| fail())?;
                if exists.is_none() { return Ok(false); }
                let relative = format!("thumbnails/{id}.jpg");
                let target = state.dir.join(&relative);
                std::fs::create_dir_all(target.parent().unwrap()).map_err(|_| fail())?;
                std::fs::write(&target, &prepared).map_err(|_| fail())?;
                conn.execute("INSERT INTO cached_files (attachment_id, kind, path, size_bytes, last_used_at) VALUES (?1, 'thumbnail', ?2, ?3, ?4)
                    ON CONFLICT(attachment_id, kind) DO UPDATE SET path = excluded.path, size_bytes = excluded.size_bytes, last_used_at = excluded.last_used_at",
                    (&id, relative, prepared.len() as i64, chrono::Utc::now().timestamp_micros())).map_err(|_| fail())?;
            }
            let response = sync::send(state.http.post(format!("{url}/attachments/{id}/thumbnail-upload-token"))
                .timeout(Duration::from_secs(30)).json(&serde_json::json!({})), secret).await?;
            #[derive(Deserialize)]
            struct Capability { token: String }
            let capability: Capability = response.json().await.map_err(|_| fail())?;
            let response = sync::send(state.http.put(format!("{url}/attachments/{id}/thumbnail"))
                .timeout(Duration::from_secs(30)).header("Content-Type", "image/jpeg").body(prepared.clone()), &capability.token).await?;
            if response.status() != reqwest::StatusCode::NO_CONTENT { return Err(fail()); }
            let conn = state.db.lock().unwrap();
            let current: Option<String> = conn.query_row("SELECT server_url FROM device", [], |row| row.get(0)).map_err(|_| fail())?;
            if current.as_deref() != Some(url) { return Ok(false); }
            conn.execute("UPDATE attachments SET has_thumbnail = 1 WHERE id = ?1", [&id]).map_err(|_| fail())?;
            Ok(true)
        }.await;
        if let Ok(published) = attempt {
            changed |= published;
            state.thumbnail_retries.lock().unwrap().remove(&retry_key);
        } else {
            let mut retries = state.thumbnail_retries.lock().unwrap();
            let attempts = retries.get(&retry_key).map_or(1, |(count, _)| (count + 1).min(5));
            retries.insert(retry_key, (attempts, Instant::now() + Duration::from_secs((30 * (1 << (attempts - 1))).min(300))));
        }
    }
    Ok(changed)
}
