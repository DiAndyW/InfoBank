use std::time::{Duration, Instant};

use rusqlite::OptionalExtension;
use serde::Deserialize;

use crate::{AppState, preview, sync};

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
             WHERE a.uploaded = 1 AND a.has_thumbnail = 0 AND (a.mime_type LIKE 'image/%' OR a.mime_type LIKE 'video/%')
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
        if backing_off(state, &retry_key) {
            continue;
        }
        if attempted >= 4 {
            break;
        }
        let attempt: Result<bool, sync::SyncError> = async {
            let current: Option<String> = state.db.lock().unwrap().query_row("SELECT server_url FROM device", [], |row| row.get(0)).map_err(|_| fail())?;
            if current.as_deref() != Some(url) { return Ok(false); }
            let mut prepared = None;
            if let Some(path) = thumbnail {
                let path = state.dir.join(path);
                if tokio::fs::metadata(&path).await.is_ok_and(|m| m.len() <= crate::cache::MAX_THUMBNAIL_BYTES)
                    && let Ok(bytes) = tokio::fs::read(path).await
                    && bytes.len() as u64 <= crate::cache::MAX_THUMBNAIL_BYTES
                    && bytes.starts_with(&[0xff, 0xd8])
                {
                    prepared = Some(bytes);
                }
            }
            let preview_key = format!("preview:{id}");
            let prepared = if let Some(bytes) = prepared {
                attempted += 1;
                bytes
            } else {
                if backing_off(state, &preview_key) { return Ok(false); }
                let Some(source) = original else { return Ok(false); };
                attempted += 1;
                let Some(bytes) = preview::make(state.dir.join(source)).await else {
                    note_failure(state, &preview_key);
                    return Ok(false);
                };
                state.thumbnail_retries.lock().unwrap().remove(&preview_key);
                bytes
            };
            {
                let conn = state.db.lock().unwrap();
                let current: Option<String> = conn.query_row("SELECT server_url FROM device", [], |row| row.get(0)).map_err(|_| fail())?;
                if current.as_deref() != Some(url) { return Ok(false); }
                let exists: Option<bool> = conn.query_row("SELECT 1 FROM attachments WHERE id = ?1", [&id], |row| row.get(0)).optional().map_err(|_| fail())?;
                if exists.is_none() { return Ok(false); }
                let relative = format!("thumbnails/{id}.jpg");
                let target = state.dir.join(&relative);
                std::fs::create_dir_all(target.parent().unwrap()).map_err(|_| fail())?;
                let temporary = target.with_file_name(format!(".dl-{}", uuid::Uuid::new_v4()));
                let written = std::fs::write(&temporary, &prepared)
                    .and_then(|()| std::fs::rename(&temporary, &target));
                if written.is_err() {
                    let _ = std::fs::remove_file(&temporary);
                    return Err(fail());
                }
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
                .timeout(Duration::from_secs(30)).header("Content-Type", "image/jpeg").body(prepared), &capability.token).await?;
            if response.status() != reqwest::StatusCode::NO_CONTENT { return Err(fail()); }
            let conn = state.db.lock().unwrap();
            if !sync::same_server(&conn, url).map_err(|_| fail())? { return Ok(false); }
            conn.execute("UPDATE attachments SET has_thumbnail = 1 WHERE id = ?1", [&id]).map_err(|_| fail())?;
            Ok(true)
        }.await;
        if let Ok(published) = attempt {
            changed |= published;
            state.thumbnail_retries.lock().unwrap().remove(&retry_key);
        } else {
            note_failure(state, &retry_key);
        }
    }
    Ok(changed)
}

pub(crate) fn backing_off(state: &AppState, key: &str) -> bool {
    state.thumbnail_retries.lock().unwrap().get(key).is_some_and(|(_, after)| *after > Instant::now())
}

pub(crate) fn note_failure(state: &AppState, key: &str) {
    let mut retries = state.thumbnail_retries.lock().unwrap();
    let attempts = retries.get(key).map_or(1, |(count, _)| (count + 1).min(5));
    retries.insert(key.to_string(), (attempts, Instant::now() + Duration::from_secs((30 * (1 << (attempts - 1))).min(300))));
}
