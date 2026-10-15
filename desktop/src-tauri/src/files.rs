use std::path::Path;

use rusqlite::Connection;
use serde::Serialize;

pub const MAX_ATTACHMENT_BYTES: u64 = 100 << 20;
const MAX_FILENAME_BYTES: usize = 255;

#[derive(Serialize, Debug, PartialEq)]
pub struct Staged {
    pub id: String,
    pub filename: String,
    pub size_bytes: u64,
    pub mime_type: String,
}

pub fn safe_name(name: &str) -> String {
    let replaced: String =
        name.chars().map(|c| if matches!(c, '/' | '\\' | ':') || c.is_control() { '_' } else { c }).collect();
    let name = replaced.trim().trim_start_matches('.');
    let name = if name.is_empty() { "file" } else { name };
    if name.len() <= MAX_FILENAME_BYTES {
        return name.to_string();
    }
    let ext = name.rsplit_once('.').map(|(_, e)| e).filter(|e| e.len() <= 16).unwrap_or("");
    let mut end = MAX_FILENAME_BYTES - if ext.is_empty() { 0 } else { ext.len() + 1 };
    while !name.is_char_boundary(end) {
        end -= 1;
    }
    if ext.is_empty() { name[..end].to_string() } else { format!("{}.{ext}", &name[..end]) }
}

pub fn mime_type(filename: &str) -> String {
    mime_guess::from_path(filename).first_or_octet_stream().to_string()
}

fn place(dir: &Path, name: &str, size_bytes: u64, write: impl FnOnce(&Path) -> std::io::Result<()>) -> Result<Staged, String> {
    let filename = safe_name(name);
    let id = uuid::Uuid::new_v4().to_string();
    let target = dir.join("files").join(&id);
    if std::fs::create_dir_all(&target).and_then(|()| write(&target.join(&filename))).is_err() {
        let _ = std::fs::remove_dir_all(&target);
        return Err(format!("Couldn't save {filename}"));
    }
    Ok(Staged { mime_type: mime_type(&filename), id, filename, size_bytes })
}

pub fn stage_path(dir: &Path, src: &Path) -> Result<Staged, String> {
    let name = src.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let size = std::fs::metadata(src).map_err(|_| format!("Couldn't read {name}"))?.len();
    if size > MAX_ATTACHMENT_BYTES {
        return Err(format!("{name} is over 100 MB"));
    }
    place(dir, &name, size, |to| std::fs::copy(src, to).map(drop))
}

pub fn stage_bytes(dir: &Path, name: &str, bytes: &[u8]) -> Result<Staged, String> {
    if bytes.len() as u64 > MAX_ATTACHMENT_BYTES {
        return Err(format!("{name} is over 100 MB"));
    }
    place(dir, name, bytes.len() as u64, |to| std::fs::write(to, bytes))
}

pub fn unstage(conn: &Connection, dir: &Path, id: &str) -> Result<(), String> {
    let id = uuid::Uuid::parse_str(id).map_err(|_| "Unknown attachment")?.to_string();
    let captured: bool = conn
        .query_row("SELECT EXISTS (SELECT 1 FROM attachments WHERE id = ?1)", [&id], |r| r.get(0))
        .map_err(|e| e.to_string())?;
    if !captured {
        let _ = std::fs::remove_dir_all(dir.join("files").join(&id));
    }
    Ok(())
}

pub fn sweep_staged(conn: &Connection, dir: &Path) -> Result<(), String> {
    let Ok(entries) = std::fs::read_dir(dir.join("files")) else { return Ok(()) };
    for entry in entries.flatten() {
        let known: bool = conn
            .query_row(
                "SELECT EXISTS (SELECT 1 FROM attachments WHERE id = ?1)",
                [entry.file_name().to_string_lossy()],
                |r| r.get(0),
            )
            .map_err(|e| e.to_string())?;
        if !known {
            let _ = std::fs::remove_dir_all(entry.path());
        }
    }
    Ok(())
}

pub fn staged_file(dir: &Path, id: &str) -> Result<(String, u64), String> {
    let gone = || "An attachment is missing; add it again".to_string();
    let entry = std::fs::read_dir(dir.join("files").join(id)).map_err(|_| gone())?.flatten().next().ok_or_else(gone)?;
    let size = entry.metadata().map_err(|_| gone())?.len();
    Ok((entry.file_name().to_string_lossy().into_owned(), size))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fresh() -> (tempfile::TempDir, Connection) {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        (dir, conn)
    }

    fn staged_dirs(dir: &Path) -> usize {
        std::fs::read_dir(dir.join("files")).map(|d| d.count()).unwrap_or(0)
    }

    #[test]
    fn names_are_safe_path_segments_the_server_accepts() {
        for (input, expected) in [
            ("report.pdf", "report.pdf"),
            ("../../etc/passwd", "_.._etc_passwd"),
            ("a/b\\c:d", "a_b_c_d"),
            (".hidden", "hidden"),
            ("..", "file"),
            ("", "file"),
            ("   ", "file"),
            ("tab\there", "tab_here"),
        ] {
            assert_eq!(safe_name(input), expected, "input {input:?}");
        }
        let long = safe_name(&format!("{}.png", "x".repeat(300)));
        assert!(long.len() <= 255 && long.ends_with(".png"), "{} bytes: {long:.20}…", long.len());
        let wide = safe_name(&format!("{}.jpg", "é".repeat(200)));
        assert!(wide.len() <= 255 && wide.ends_with(".jpg"));
    }

    #[test]
    fn a_staged_path_is_copied_with_its_size_and_type() {
        let (d, _conn) = fresh();
        let src = d.path().join("notes.txt");
        std::fs::write(&src, "hello").unwrap();

        let s = stage_path(d.path(), &src).unwrap();
        assert_eq!((s.filename.as_str(), s.size_bytes, s.mime_type.as_str()), ("notes.txt", 5, "text/plain"));
        let copy = d.path().join("files").join(&s.id).join("notes.txt");
        assert_eq!(std::fs::read_to_string(copy).unwrap(), "hello");
        assert_eq!(staged_file(d.path(), &s.id).unwrap(), ("notes.txt".to_string(), 5));
    }

    #[test]
    fn the_size_limit_is_checked_before_copying() {
        let (d, _conn) = fresh();
        let over = d.path().join("over.bin");
        std::fs::File::create(&over).unwrap().set_len(MAX_ATTACHMENT_BYTES + 1).unwrap();
        let err = stage_path(d.path(), &over).unwrap_err();
        assert!(err.contains("over.bin is over 100 MB"), "{err}");
        assert_eq!(staged_dirs(d.path()), 0);

        let exact = d.path().join("exact.bin");
        std::fs::File::create(&exact).unwrap().set_len(MAX_ATTACHMENT_BYTES).unwrap();
        assert_eq!(stage_path(d.path(), &exact).unwrap().size_bytes, MAX_ATTACHMENT_BYTES);
    }

    #[test]
    fn pasted_bytes_are_staged_under_a_safe_name() {
        let (d, _conn) = fresh();
        let s = stage_bytes(d.path(), "../Pasted image.png", b"png").unwrap();
        assert_eq!((s.filename.as_str(), s.size_bytes, s.mime_type.as_str()), ("_Pasted image.png", 3, "image/png"));
        assert!(stage_bytes(d.path(), "big.bin", &vec![0; MAX_ATTACHMENT_BYTES as usize + 1]).is_err());
        assert_eq!(staged_dirs(d.path()), 1);
    }

    #[test]
    fn unstaging_never_deletes_a_captured_file() {
        let (d, conn) = fresh();
        let draft = stage_bytes(d.path(), "draft.txt", b"x").unwrap();
        let sent = stage_bytes(d.path(), "sent.txt", b"x").unwrap();
        conn.execute("INSERT INTO items (id, capture_time) VALUES ('i', 1)", []).unwrap();
        conn.execute(
            "INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail)
             VALUES (?1, 'i', 'sent.txt', 'text/plain', 1, 0, 0)",
            [&sent.id],
        )
        .unwrap();

        unstage(&conn, d.path(), &draft.id).unwrap();
        unstage(&conn, d.path(), &sent.id).unwrap();
        assert!(!d.path().join("files").join(&draft.id).exists());
        assert!(d.path().join("files").join(&sent.id).exists());
        assert!(unstage(&conn, d.path(), "../files").is_err());
    }

    #[test]
    fn sweeping_removes_only_copies_never_captured() {
        let (d, conn) = fresh();
        let left = stage_bytes(d.path(), "left.txt", b"x").unwrap();
        let kept = stage_bytes(d.path(), "kept.txt", b"x").unwrap();
        conn.execute("INSERT INTO items (id, capture_time) VALUES ('i', 1)", []).unwrap();
        conn.execute(
            "INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail)
             VALUES (?1, 'i', 'kept.txt', 'text/plain', 1, 0, 0)",
            [&kept.id],
        )
        .unwrap();

        sweep_staged(&conn, d.path()).unwrap();
        assert!(!d.path().join("files").join(&left.id).exists());
        assert!(d.path().join("files").join(&kept.id).exists());
    }
}
