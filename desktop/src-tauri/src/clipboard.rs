use crate::{AppState, cache, files};
use std::path::PathBuf;

pub struct Payload {
    pub text: Option<String>,
    pub files: Vec<PathBuf>,
}

type Snapshot = (Option<String>, Vec<(String, String, String, i64)>, Option<String>);

pub struct Prepared {
    pub payload: Payload,
    snapshots: Vec<(String, Snapshot)>,
    folder: PathBuf,
}

impl Prepared {
    pub fn validate(&self, state: &AppState) -> Result<(), String> {
        for (id, original) in &self.snapshots {
            if &snapshot(state, id)? != original {
                return Err("The Item changed while preparing the copy; copy it again".into());
            }
        }
        Ok(())
    }

    pub fn discard(self) {
        let _ = std::fs::remove_dir_all(self.folder);
    }
}

fn snapshot(state: &AppState, item_id: &str) -> Result<Snapshot, String> {
    let conn = state.db.lock().unwrap();
    let (text, sync_error) = conn
        .query_row("SELECT text, sync_error FROM items WHERE id = ?1 AND deleted_at IS NULL", [item_id], |r| {
            Ok((r.get(0)?, r.get::<_, Option<String>>(1)?))
        })
        .map_err(|_| "This Item is no longer available")?;
    let mut stmt = conn
        .prepare("SELECT id, filename, mime_type, size_bytes FROM attachments WHERE item_id = ?1 ORDER BY id")
        .map_err(crate::error_message::message)?;
    let attachments = stmt
        .query_map([item_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
        .map_err(crate::error_message::message)?
        .collect::<Result<_, _>>()
        .map_err(crate::error_message::message)?;
    Ok((text, attachments, sync_error))
}

pub async fn prepare(state: &AppState, item_id: &str, now_us: i64) -> Result<Payload, String> {
    Ok(prepare_items(state, &[item_id.into()], now_us, false).await?.payload)
}

pub async fn prepare_many(state: &AppState, item_ids: &[String], now_us: i64) -> Result<Prepared, String> {
    prepare_items(state, item_ids, now_us, true).await
}

async fn prepare_items(state: &AppState, item_ids: &[String], now_us: i64, reject_sync_errors: bool) -> Result<Prepared, String> {
    let mut snapshots = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for id in item_ids.iter().filter(|id| seen.insert(id.as_str())) {
        let value = snapshot(state, id)?;
        if reject_sync_errors && value.2.is_some() { return Err("This Item is no longer available".into()); }
        if value.0.as_deref().is_none_or(str::is_empty) && value.1.is_empty() {
            return Err("This Item is empty".into());
        }
        snapshots.push((id.clone(), value));
    }
    if snapshots.is_empty() { return Err("Select at least one Item".into()); }
    let folder = new_folder(state)?;
    let result = async {
        let mut exported = Vec::new();
        for (id, name, _, _) in snapshots.iter().flat_map(|(_, value)| &value.1) {
            exported.push(export(state, &folder, id, name, now_us).await?);
        }
        let text = snapshots.iter().filter_map(|(_, value)| value.0.as_deref()).filter(|s| !s.is_empty()).collect::<Vec<_>>().join("\n\n");
        let prepared = Prepared {
            payload: Payload { text: (!text.is_empty()).then_some(text), files: exported },
            snapshots, folder: folder.clone(),
        };
        prepared.validate(state)?;
        Ok(prepared)
    }
    .await;
    if result.is_err() {
        let _ = std::fs::remove_dir_all(folder);
    }
    result
}

pub async fn prepare_attachment(state: &AppState, attachment_id: &str, now_us: i64) -> Result<Payload, String> {
    let name: String = state
        .db
        .lock()
        .unwrap()
        .query_row(
            "SELECT a.filename FROM attachments a JOIN items i ON i.id = a.item_id WHERE a.id = ?1 AND i.deleted_at IS NULL",
            [attachment_id],
            |r| r.get(0),
        )
        .map_err(|_| "This file is no longer available")?;
    let folder = new_folder(state)?;
    let result = async {
        let path = export(state, &folder, attachment_id, &name, now_us).await?;
        let available: bool = state.db.lock().unwrap().query_row(
            "SELECT EXISTS(SELECT 1 FROM attachments a JOIN items i ON i.id = a.item_id WHERE a.id = ?1 AND i.deleted_at IS NULL)",
            [attachment_id], |r| r.get(0),
        ).map_err(|_| "This file is no longer available")?;
        if !available { return Err("This file is no longer available".into()); }
        Ok(Payload { text: None, files: vec![path] })
    }.await;
    if result.is_err() {
        let _ = std::fs::remove_dir_all(folder);
    }
    result
}

async fn export(state: &AppState, folder: &std::path::Path, id: &str, name: &str, now_us: i64) -> Result<PathBuf, String> {
    let source = cache::file(state, id, now_us).await?;
    let target = folder.join(id).join(files::safe_name(name));
    tokio::fs::create_dir_all(target.parent().unwrap())
        .await
        .map_err(|_| "Couldn't prepare clipboard files")?;
    tokio::fs::copy(source, &target)
        .await
        .map_err(|_| "Couldn't prepare clipboard files")?;
    Ok(target)
}

fn new_folder(state: &AppState) -> Result<PathBuf, String> {
    let root = state.dir.join("clipboard");
    let mut directory = std::fs::DirBuilder::new();
    directory.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        directory.mode(0o700);
    }
    directory.create(&root).map_err(|_| "Couldn't prepare clipboard files")?;
    // Pasteboard file URLs must outlive cache eviction and Trash.
    for entry in std::fs::read_dir(&root).into_iter().flatten().flatten() {
        if entry
            .metadata()
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.elapsed().ok())
            .is_some_and(|age| age.as_secs() > 7 * 24 * 3600)
        {
            let _ = std::fs::remove_dir_all(entry.path());
        }
    }
    Ok(root.join(uuid::Uuid::new_v4().to_string()))
}

#[cfg(target_os = "macos")]
pub fn write(payload: &Payload, board: &objc2_app_kit::NSPasteboard) -> Result<(), String> {
    use objc2::{AllocAnyThread, runtime::ProtocolObject};
    use objc2_app_kit::{NSImage, NSPasteboardItem, NSPasteboardWriting};
    use objc2_foundation::{NSArray, NSString};
    let mut items = Vec::new();
    if let Some(text) = &payload.text {
        let item = NSPasteboardItem::new();
        if !item.setString_forType(&NSString::from_str(text), &NSString::from_str("public.utf8-plain-text")) {
            return Err("Couldn't prepare clipboard text".into());
        }
        items.push(ProtocolObject::<dyn NSPasteboardWriting>::from_retained(item));
    }
    for path in &payload.files {
        let item = NSPasteboardItem::new();
        let url = url::Url::from_file_path(path).map_err(|_| "Couldn't prepare clipboard file")?;
        if !item.setString_forType(&NSString::from_str(url.as_str()), &NSString::from_str("public.file-url")) {
            return Err("Couldn't prepare clipboard file".into());
        }
        if mime_guess::from_path(path)
            .first_raw()
            .is_some_and(|mime| mime.starts_with("image/"))
        {
            if let Some(image) = NSImage::initWithContentsOfFile(NSImage::alloc(), &NSString::from_str(&path.to_string_lossy())) {
                if let Some(data) = image.TIFFRepresentation() {
                    if !item.setData_forType(&data, &NSString::from_str("public.tiff")) {
                        return Err("Couldn't prepare clipboard image".into());
                    }
                }
            }
        }
        items.push(ProtocolObject::<dyn NSPasteboardWriting>::from_retained(item));
    }
    board.clearContents();
    if board.writeObjects(&NSArray::from_retained_slice(&items)) {
        Ok(())
    } else {
        Err("Couldn't write the complete Item to the clipboard".into())
    }
}

#[cfg(target_os = "windows")]
pub fn write(payload: &Payload, owner: usize) -> Result<(), String> {
    use std::ffi::c_void;
    #[link(name = "user32")]
    unsafe extern "system" {
        fn OpenClipboard(window: *mut c_void) -> i32;
        fn CloseClipboard() -> i32;
        fn EmptyClipboard() -> i32;
        fn SetClipboardData(format: u32, memory: *mut c_void) -> *mut c_void;
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GlobalAlloc(flags: u32, bytes: usize) -> *mut c_void;
        fn GlobalLock(memory: *mut c_void) -> *mut c_void;
        fn GlobalUnlock(memory: *mut c_void) -> i32;
        fn GlobalFree(memory: *mut c_void) -> *mut c_void;
    }
    let mut formats = Vec::new();
    if let Some(text) = &payload.text {
        formats.push((13, text.encode_utf16().chain([0]).flat_map(u16::to_le_bytes).collect::<Vec<_>>()));
    }
    if !payload.files.is_empty() {
        let mut drop = Vec::new();
        for value in [20u32, 0, 0, 0, 1] {
            drop.extend(value.to_le_bytes());
        }
        for path in &payload.files {
            use std::os::windows::ffi::OsStrExt;
            drop.extend(path.as_os_str().encode_wide().chain([0]).flat_map(u16::to_le_bytes));
        }
        drop.extend([0, 0]);
        formats.push((15, drop));
    }
    let mut blocks = Vec::new();
    for (format, bytes) in formats {
        let memory = unsafe { GlobalAlloc(2, bytes.len()) };
        let pointer = if memory.is_null() {
            std::ptr::null_mut()
        } else {
            unsafe { GlobalLock(memory) }
        };
        if pointer.is_null() {
            if !memory.is_null() {
                unsafe {
                    GlobalFree(memory);
                }
            }
            for (_, block) in blocks {
                unsafe {
                    GlobalFree(block);
                }
            }
            return Err("Couldn't prepare clipboard data".into());
        }
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), pointer.cast(), bytes.len());
            GlobalUnlock(memory);
        }
        blocks.push((format, memory));
    }
    let result = unsafe {
        if OpenClipboard(owner as *mut c_void) == 0 {
            Err("The clipboard is busy".into())
        } else {
            let mut success = EmptyClipboard() != 0;
            if success {
                for (format, memory) in &mut blocks {
                    if SetClipboardData(*format, *memory).is_null() {
                        success = false;
                        break;
                    }
                    *memory = std::ptr::null_mut();
                }
            }
            CloseClipboard();
            if success {
                Ok(())
            } else {
                Err("Couldn't write the complete Item to the clipboard".into())
            }
        }
    };
    for (_, memory) in blocks {
        if !memory.is_null() {
            unsafe {
                GlobalFree(memory);
            }
        }
    }
    result
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
pub fn write(_: &Payload) -> Result<(), String> {
    Err("Whole-Item copying isn't supported on this platform".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn single_copy_can_rescue_a_rejected_item_but_batch_copy_refuses_it() {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("db")).unwrap();
        conn.execute("INSERT INTO items (id, text, capture_time, sync_error) VALUES ('rejected', 'keep this text', 1, 'invalid')", []).unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "secret", None).unwrap();
        let state = crate::AppState::new(conn, secret, dir.path().to_path_buf());
        assert_eq!(prepare(&state, "rejected", 1).await.unwrap().text.as_deref(), Some("keep this text"));
        assert!(prepare_many(&state, &["rejected".into()], 1).await.is_err());
    }

    #[tokio::test]
    async fn batch_copy_preserves_order_and_duplicate_filenames_and_rechecks_every_item() {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("db")).unwrap();
        for (id, text) in [("one", "first"), ("two", "second")] {
            conn.execute("INSERT INTO items (id, text, capture_time) VALUES (?1, ?2, 1)", [id, text]).unwrap();
            let attachment = uuid::Uuid::new_v4().to_string();
            std::fs::write(dir.path().join(&attachment), text).unwrap();
            conn.execute("INSERT INTO attachments VALUES (?1, ?2, 'same.txt', 'text/plain', ?3, 1, 0)", (&attachment, id, text.len() as i64)).unwrap();
            conn.execute("INSERT INTO cached_files VALUES (?1, 'file', ?1, ?2, 1)", (&attachment, text.len() as i64)).unwrap();
        }
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "secret", None).unwrap();
        let state = crate::AppState::new(conn, secret, dir.path().to_path_buf());
        let prepared = prepare_many(&state, &["two".into(), "one".into()], 1).await.unwrap();
        assert_eq!(prepared.payload.text.as_deref(), Some("second\n\nfirst"));
        assert_eq!(prepared.payload.files.len(), 2);
        assert_eq!(std::fs::read(&prepared.payload.files[0]).unwrap(), b"second");
        assert_eq!(std::fs::read(&prepared.payload.files[1]).unwrap(), b"first");
        assert_ne!(prepared.payload.files[0], prepared.payload.files[1]);
        prepared.validate(&state).unwrap();
        state.db.lock().unwrap().execute("UPDATE items SET text = 'changed' WHERE id = 'two'", []).unwrap();
        assert!(prepared.validate(&state).is_err());
        prepared.discard();
        assert_eq!(std::fs::read_dir(dir.path().join("clipboard")).unwrap().count(), 0);
        state.db.lock().unwrap().execute("DELETE FROM cached_files WHERE attachment_id IN (SELECT id FROM attachments WHERE item_id = 'one')", []).unwrap();
        assert!(prepare_many(&state, &["two".into(), "one".into()], 1).await.is_err());
        assert_eq!(std::fs::read_dir(dir.path().join("clipboard")).unwrap().count(), 0);
        assert!(prepare_many(&state, &["one".into(), "missing".into()], 1).await.is_err());
    }
    #[tokio::test]
    async fn one_attachment_copies_only_its_file_until_its_item_is_trashed() {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("db")).unwrap();
        conn.execute("INSERT INTO items (id, text, capture_time, in_tunnel) VALUES ('i', 'hello', 1, 1)", []).unwrap();
        let mut ids = Vec::new();
        for (name, bytes) in [("shot.png", b"image".as_slice()), ("deploy.yaml", b"name: deploy".as_slice())] {
            let id = uuid::Uuid::new_v4().to_string();
            std::fs::write(dir.path().join(&id), bytes).unwrap();
            conn.execute("INSERT INTO attachments VALUES (?1, 'i', ?2, 'application/octet-stream', ?3, 1, 0)", (&id, name, bytes.len() as i64)).unwrap();
            conn.execute("INSERT INTO cached_files VALUES (?1, 'file', ?1, ?2, 1)", (&id, bytes.len() as i64)).unwrap();
            ids.push(id);
        }
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "secret", None).unwrap();
        let state = crate::AppState::new(conn, secret, dir.path().to_path_buf());
        let payload = prepare_attachment(&state, &ids[1], 1).await.unwrap();
        assert_eq!(payload.text, None);
        assert_eq!(payload.files.len(), 1);
        assert_eq!(payload.files[0].file_name().unwrap(), "deploy.yaml");
        assert_eq!(std::fs::read(&payload.files[0]).unwrap(), b"name: deploy");
        let future = prepare_attachment(&state, &ids[1], 1);
        futures_util::pin_mut!(future);
        assert!(futures_util::poll!(future.as_mut()).is_pending());
        state.db.lock().unwrap().execute("UPDATE items SET deleted_at = 1 WHERE id = 'i'", []).unwrap();
        assert!(future.await.is_err());
        assert_eq!(std::fs::read_dir(dir.path().join("clipboard")).unwrap().count(), 1);
        state.db.lock().unwrap().execute("UPDATE items SET deleted_at = NULL WHERE id = 'i'", []).unwrap();
        state.db.lock().unwrap().execute("UPDATE attachments SET uploaded = 0 WHERE id = ?1", [&ids[0]]).unwrap();
        state.db.lock().unwrap().execute("DELETE FROM cached_files WHERE attachment_id = ?1", [&ids[0]]).unwrap();
        assert!(prepare_attachment(&state, &ids[0], 1).await.is_err());
        assert_eq!(std::fs::read_dir(dir.path().join("clipboard")).unwrap().count(), 1);
        state.db.lock().unwrap().execute("UPDATE items SET deleted_at = 1 WHERE id = 'i'", []).unwrap();
        assert!(prepare_attachment(&state, &ids[1], 1).await.is_err());
    }

    use keyring_core::api::CredentialStoreApi;

    #[cfg(target_os = "macos")]
    #[test]
    fn native_pasteboard_contains_text_original_file_urls_and_image_bytes() {
        use objc2_app_kit::NSPasteboard;
        use objc2_foundation::NSString;
        let board = NSPasteboard::pasteboardWithName(&NSString::from_str(&format!("app.notebank.test.{}", uuid::Uuid::new_v4())));
        let dir = tempfile::tempdir().unwrap();
        let image = dir.path().join("image.png");
        std::fs::write(&image, include_bytes!("../icons/32x32.png")).unwrap();
        let file = dir.path().join("a b.pdf");
        std::fs::write(&file, b"document").unwrap();
        let payload = Payload {
            text: Some("hello\nworld".into()),
            files: vec![image, file],
        };
        write(&payload, &board).unwrap();
        let items = board.pasteboardItems().unwrap();
        assert_eq!(items.len(), 3);
        assert_eq!(
            items
                .objectAtIndex(0)
                .stringForType(&NSString::from_str("public.utf8-plain-text"))
                .unwrap()
                .to_string(),
            "hello\nworld"
        );
        for (index, path) in payload.files.iter().enumerate() {
            let actual = items
                .objectAtIndex(index + 1)
                .stringForType(&NSString::from_str("public.file-url"))
                .unwrap()
                .to_string();
            assert_eq!(url::Url::parse(&actual).unwrap().to_file_path().unwrap(), *path);
        }
        assert!(
            !items
                .objectAtIndex(1)
                .dataForType(&NSString::from_str("public.tiff"))
                .unwrap()
                .is_empty()
        );
        board.clearContents();
    }

    #[tokio::test]
    async fn exports_preserve_all_bytes_and_survive_cache_removal() {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("db")).unwrap();
        conn.execute(
            "INSERT INTO items (id, text, capture_time, in_tunnel) VALUES ('i', 'hello', 1, 1)",
            [],
        )
        .unwrap();
        for bytes in [b"first".as_slice(), b"second".as_slice()] {
            let id = uuid::Uuid::new_v4().to_string();
            let path = format!("files/{id}/same.txt");
            std::fs::create_dir_all(dir.path().join(&path).parent().unwrap()).unwrap();
            std::fs::write(dir.path().join(&path), bytes).unwrap();
            conn.execute("INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail) VALUES (?1, 'i', 'same.txt', 'text/plain', ?2, 1, 0)", (&id, bytes.len() as i64)).unwrap();
            conn.execute(
                "INSERT INTO cached_files VALUES (?1, 'file', ?2, ?3, 1)",
                (&id, path, bytes.len() as i64),
            )
            .unwrap();
        }
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "secret", None).unwrap();
        let state = crate::AppState::new(conn, secret, dir.path().to_path_buf());
        let payload = prepare(&state, "i", 1).await.unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(dir.path().join("clipboard")).unwrap().permissions().mode() & 0o777, 0o700);
        }
        assert_eq!(payload.text.as_deref(), Some("hello"));
        assert_eq!(payload.files.len(), 2);
        assert_ne!(payload.files[0], payload.files[1]);
        std::fs::remove_dir_all(dir.path().join("files")).unwrap();
        let mut bytes: Vec<_> = payload.files.iter().map(|p| std::fs::read(p).unwrap()).collect();
        bytes.sort();
        assert_eq!(bytes, [b"first".to_vec(), b"second".to_vec()]);
    }

    #[tokio::test]
    async fn missing_attachment_never_produces_a_partial_payload() {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("db")).unwrap();
        conn.execute("INSERT INTO items (id, capture_time, in_tunnel) VALUES ('i', 1, 1)", [])
            .unwrap();
        conn.execute("INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail) VALUES (?1, 'i', 'missing.pdf', 'application/pdf', 1, 0, 0)", [uuid::Uuid::new_v4().to_string()]).unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "secret", None).unwrap();
        let state = crate::AppState::new(conn, secret, dir.path().to_path_buf());
        assert!(prepare(&state, "i", 1).await.is_err());
        assert_eq!(std::fs::read_dir(dir.path().join("clipboard")).unwrap().count(), 0);
        assert_eq!(
            state
                .db
                .lock()
                .unwrap()
                .query_row("SELECT deleted_at IS NULL FROM items WHERE id = 'i'", [], |r| r.get::<_, bool>(0))
                .unwrap(),
            true
        );
    }

    #[tokio::test]
    async fn an_item_changed_during_export_must_be_copied_again() {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("db")).unwrap();
        let id = uuid::Uuid::new_v4().to_string();
        conn.execute(
            "INSERT INTO items (id, text, capture_time, in_tunnel) VALUES ('i', 'before', 1, 1)",
            [],
        )
        .unwrap();
        conn.execute("INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail) VALUES (?1, 'i', 'file.txt', 'text/plain', 5, 1, 0)", [&id]).unwrap();
        std::fs::write(dir.path().join("original"), b"hello").unwrap();
        conn.execute("INSERT INTO cached_files VALUES (?1, 'file', 'original', 5, 1)", [&id])
            .unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "secret", None).unwrap();
        let state = crate::AppState::new(conn, secret, dir.path().to_path_buf());
        let future = prepare(&state, "i", 1);
        futures_util::pin_mut!(future);
        assert!(futures_util::poll!(future.as_mut()).is_pending());
        state
            .db
            .lock()
            .unwrap()
            .execute("UPDATE items SET text = 'after' WHERE id = 'i'", [])
            .unwrap();
        assert!(future.await.is_err());
        assert_eq!(std::fs::read_dir(dir.path().join("clipboard")).unwrap().count(), 0);
    }
}
