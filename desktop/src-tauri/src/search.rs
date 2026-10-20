use rusqlite::{Connection, types::Value};
use serde::{Deserialize, Serialize};

use crate::feed::{self, Before, FeedItem};

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Place {
    All,
    Inbox,
    Topic { id: String },
}

#[derive(Deserialize)]
pub struct Query {
    pub text: String,
    pub place: Place,
    pub from_us: Option<i64>,
    pub to_us: Option<i64>,
    pub has_files: bool,
}

#[derive(Serialize)]
pub struct SearchItem {
    #[serde(flatten)]
    pub item: FeedItem,
    pub marked_text: Option<String>,
    pub marked_filenames: Vec<String>,
}

const MARK_START: char = '\u{E000}';
const MARK_END: char = '\u{E001}';

/// Live Items holding every word of `query.text`, newest first, at most PAGE_SIZE.
pub fn search(conn: &Connection, query: &Query, before: Option<&Before>) -> Result<Vec<SearchItem>, String> {
    let words: Vec<&str> = query.text.split_whitespace().collect();
    if words.is_empty() {
        return Err("Type something to search".into());
    }
    // The trigram index can't match under 3 characters, so those words are checked row by row.
    let (long, short): (Vec<&str>, Vec<&str>) = words.into_iter().partition(|w| w.chars().count() >= 3);
    let (kind, topic) = match &query.place {
        Place::All => ("all", None),
        Place::Inbox => ("inbox", None),
        Place::Topic { id } => ("topic", Some(id.clone())),
    };
    let mut args: Vec<Value> = vec![
        kind.to_string().into(),
        topic.into(),
        query.from_us.into(),
        query.to_us.into(),
        query.has_files.into(),
        serde_json::to_string(&short).expect("strings serialize").into(),
        before.map(|b| b.capture_time_us).into(),
        before.map(|b| b.id.clone()).into(),
        feed::PAGE_SIZE.into(),
    ];
    let (matched, text, names) = if long.is_empty() {
        ("", "search.text".to_string(), "search.names".to_string())
    } else {
        // Each word is a quoted phrase, so typed FTS5 syntax is matched as text.
        let phrases: Vec<String> = long.iter().map(|w| format!("\"{}\"", w.replace('"', "\"\""))).collect();
        args.push(phrases.join(" ").into());
        let mark = |col: u8| format!("highlight(search, {col}, char({}), char({}))", MARK_START as u32, MARK_END as u32);
        ("search MATCH ?10 AND", mark(0), mark(1))
    };
    let sql = format!(
        "SELECT items.id, items.text, items.capture_time, items.topic_id, {pending}, items.purge_at, {edit_base}, {text}, {names}, {feedback}
         FROM search JOIN items ON items.rowid = search.rowid
         WHERE {matched} items.deleted_at IS NULL
           AND CASE ?1 WHEN 'all' THEN 1 WHEN 'inbox' THEN items.topic_id IS NULL ELSE items.topic_id = ?2 END
           AND (?3 IS NULL OR items.capture_time >= ?3) AND (?4 IS NULL OR items.capture_time < ?4)
           AND (NOT ?5 OR EXISTS (SELECT 1 FROM attachments WHERE item_id = items.id))
           AND NOT EXISTS (SELECT 1 FROM json_each(?6) WHERE instr(lower(search.text || char(10) || search.names), lower(value)) = 0)
           AND (?7 IS NULL OR (items.capture_time, items.id) < (?7, ?8))
         ORDER BY items.capture_time DESC, items.id DESC
         LIMIT ?9",
        pending = feed::PENDING,
        edit_base = feed::EDIT_BASE,
        feedback = feed::FEEDBACK,
    );
    let run = || -> rusqlite::Result<Vec<SearchItem>> {
        let mut stmt = conn.prepare(&sql)?;
        let (mut items, marked): (Vec<FeedItem>, Vec<(String, String)>) = stmt
            .query_map(rusqlite::params_from_iter(&args), |r| {
                let (sync_error, conflict) = feed::feedback(r, 9)?;
                Ok((
                    FeedItem {
                        id: r.get(0)?,
                        text: r.get(1)?,
                        capture_time_us: r.get(2)?,
                        topic_id: r.get(3)?,
                        pending: r.get(4)?,
                        purge_at_us: r.get(5)?,
                        edit_base: r.get(6)?,
                        sync_error,
                        conflict,
                        attachments: Vec::new(),
                    },
                    (r.get(7)?, r.get(8)?),
                ))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?
            .into_iter()
            .unzip();
        feed::attach(conn, &mut items)?;
        Ok(items
            .into_iter()
            .zip(marked)
            .map(|(item, (text, names))| {
                let parts: Vec<&str> = names.split('\n').collect();
                let marked_filenames = item
                    .attachments
                    .iter()
                    .map(|a| {
                        let part = parts.iter().find(|p| p.replace([MARK_START, MARK_END], "") == a.filename);
                        part.map_or_else(|| a.filename.clone(), |p| p.to_string())
                    })
                    .collect();
                SearchItem { marked_text: item.text.as_ref().map(|_| text), marked_filenames, item }
            })
            .collect())
    };
    run().map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fresh() -> (tempfile::TempDir, Connection) {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        (dir, conn)
    }

    fn put(conn: &Connection, id: &str, text: Option<&str>) {
        conn.execute("INSERT INTO items (id, text, capture_time) VALUES (?1, ?2, 1)", (id, text)).unwrap();
    }

    fn file(conn: &Connection, item: &str, id: &str, name: &str) {
        conn.execute(
            "INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail)
             VALUES (?1, ?2, ?3, 'application/pdf', 1, 0, 0)",
            (id, item, name),
        )
        .unwrap();
    }

    // (item id, indexed text, indexed names) for every index row; an orphan row shows as id "?".
    fn indexed(conn: &Connection) -> Vec<(String, String, String)> {
        let mut stmt = conn
            .prepare("SELECT coalesce(items.id, '?'), search.text, search.names FROM search LEFT JOIN items ON items.rowid = search.rowid ORDER BY 1")
            .unwrap();
        stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap().collect::<rusqlite::Result<_>>().unwrap()
    }

    fn row(id: &str, text: &str, names: &str) -> (String, String, String) {
        (id.into(), text.into(), names.into())
    }

    fn at(conn: &Connection, id: &str, text: &str, topic: Option<&str>, capture_time: i64) {
        conn.execute("INSERT INTO items (id, topic_id, text, capture_time) VALUES (?1, ?2, ?3, ?4)", (id, topic, text, capture_time)).unwrap();
    }

    fn query(text: &str) -> Query {
        Query { text: text.into(), place: Place::All, from_us: None, to_us: None, has_files: false }
    }

    fn ids(found: &[SearchItem]) -> Vec<&str> {
        found.iter().map(|f| f.item.id.as_str()).collect()
    }

    #[test]
    fn words_match_anywhere_in_text_or_file_names_ignoring_case_and_accents() {
        let (_d, conn) = fresh();
        at(&conn, "mid", "a screenshot of it", None, 1);
        at(&conn, "accent", "paid the Café bill", None, 2);
        at(&conn, "cjk", "截图保存好了", None, 3);
        put(&conn, "file", None);
        file(&conn, "file", "f", "Invoice_2026.pdf");
        at(&conn, "other", "nothing here", None, 0);
        assert_eq!(ids(&search(&conn, &query("SHOT"), None).unwrap()), ["mid"]);
        assert_eq!(ids(&search(&conn, &query("cafe"), None).unwrap()), ["accent"]);
        assert_eq!(ids(&search(&conn, &query("保存好"), None).unwrap()), ["cjk"]);
        assert_eq!(ids(&search(&conn, &query("voice_20"), None).unwrap()), ["file"]);
    }

    #[test]
    fn every_word_must_match_and_short_words_still_count() {
        let (_d, conn) = fresh();
        at(&conn, "both", "AI notes for March", None, 2);
        at(&conn, "one", "notes for April", None, 1);
        assert_eq!(ids(&search(&conn, &query("notes march"), None).unwrap()), ["both"]);
        assert_eq!(ids(&search(&conn, &query("ai notes"), None).unwrap()), ["both"]);
        assert_eq!(ids(&search(&conn, &query("ai"), None).unwrap()), ["both"]);
    }

    #[test]
    fn typed_search_syntax_is_matched_literally() {
        let (_d, conn) = fresh();
        at(&conn, "q", r#"say "hi" to x*y: a-b (AND) 50%"#, None, 1);
        at(&conn, "other", "say hi to xy a b and 50", None, 0);
        for typed in [r#""hi""#, "x*y:", "a-b", "(AND)", "50%", "%"] {
            assert_eq!(ids(&search(&conn, &query(typed), None).unwrap()), ["q"], "searching {typed}");
        }
    }

    #[test]
    fn filters_narrow_by_place_dates_and_files_and_trash_is_never_searched() {
        let (_d, conn) = fresh();
        conn.execute("INSERT INTO topics (id, name, archived_at) VALUES ('t', 'Taxes', NULL), ('old', 'Old', 5)", []).unwrap();
        at(&conn, "inbox", "note one", None, 10);
        at(&conn, "taxes", "note two", Some("t"), 20);
        at(&conn, "archived", "note three", Some("old"), 30);
        at(&conn, "trashed", "note four", None, 40);
        conn.execute("UPDATE items SET deleted_at = 41 WHERE id = 'trashed'", []).unwrap();
        file(&conn, "taxes", "f", "a.pdf");

        let with = |f: &dyn Fn(&mut Query)| {
            let mut q = query("note");
            f(&mut q);
            search(&conn, &q, None).unwrap().iter().map(|s| s.item.id.clone()).collect::<Vec<_>>()
        };
        assert_eq!(with(&|_| {}), ["archived", "taxes", "inbox"]);
        assert_eq!(with(&|q| q.place = Place::Inbox), ["inbox"]);
        assert_eq!(with(&|q| q.place = Place::Topic { id: "old".into() }), ["archived"]);
        assert_eq!(with(&|q| q.has_files = true), ["taxes"]);
        // Half-open: from is included, to is not.
        assert_eq!(
            with(&|q| {
                q.from_us = Some(20);
                q.to_us = Some(30);
            }),
            ["taxes"]
        );
    }

    #[test]
    fn results_page_newest_first() {
        let (_d, conn) = fresh();
        for i in 0..(crate::feed::PAGE_SIZE + 1) {
            at(&conn, &format!("{i:03}"), "same words", None, 1);
        }
        let first = search(&conn, &query("same"), None).unwrap();
        assert_eq!(first.len() as i64, crate::feed::PAGE_SIZE);
        assert_eq!(first[0].item.id, format!("{:03}", crate::feed::PAGE_SIZE));
        let last = first.last().unwrap();
        let before = crate::feed::Before { capture_time_us: last.item.capture_time_us, id: last.item.id.clone() };
        assert_eq!(ids(&search(&conn, &query("same"), Some(&before)).unwrap()), ["000"]);
    }

    #[test]
    fn matches_come_back_marked_in_text_and_file_names() {
        let (_d, conn) = fresh();
        at(&conn, "i", "paid the Café bill", None, 1);
        file(&conn, "i", "f1", "café-receipt.pdf");
        file(&conn, "i", "f2", "other.png");
        let found = search(&conn, &query("cafe"), None).unwrap();
        assert_eq!(found[0].marked_text.as_deref(), Some("paid the \u{E000}Café\u{E001} bill"));
        assert_eq!(found[0].marked_filenames, ["\u{E000}café\u{E001}-receipt.pdf", "other.png"]);
        assert_eq!(found[0].item.attachments.len(), 2);

        // Short words have no marks, and an Item with no text has none.
        conn.execute("UPDATE items SET text = NULL", []).unwrap();
        let found = search(&conn, &query("pn"), None).unwrap();
        assert_eq!(found[0].marked_text, None);
        assert_eq!(found[0].marked_filenames, ["café-receipt.pdf", "other.png"]);
    }

    #[test]
    fn blank_text_is_refused() {
        let (_d, conn) = fresh();
        assert_eq!(search(&conn, &query("  \n "), None).err().as_deref(), Some("Type something to search"));
    }

    #[test]
    fn items_and_their_file_names_are_indexed_as_they_change() {
        let (_d, conn) = fresh();
        put(&conn, "a", Some("first"));
        put(&conn, "b", None);
        file(&conn, "b", "f1", "Invoice.pdf");
        file(&conn, "b", "f2", "scan.png");
        assert_eq!(indexed(&conn), vec![row("a", "first", ""), row("b", "", "Invoice.pdf\nscan.png")]);

        conn.execute("UPDATE items SET text = 'second' WHERE id = 'a'", []).unwrap();
        conn.execute("UPDATE items SET text = NULL WHERE id = 'a'", []).unwrap();
        conn.execute("UPDATE attachments SET filename = 'Receipt.pdf' WHERE id = 'f1'", []).unwrap();
        conn.execute("DELETE FROM attachments WHERE id = 'f2'", []).unwrap();
        assert_eq!(indexed(&conn), vec![row("a", "", ""), row("b", "", "Receipt.pdf")]);
    }

    #[test]
    fn a_file_moving_to_another_item_reindexes_both() {
        let (_d, conn) = fresh();
        put(&conn, "a", Some("x"));
        put(&conn, "b", Some("y"));
        file(&conn, "a", "f", "plan.pdf");
        conn.execute("UPDATE attachments SET item_id = 'b' WHERE id = 'f'", []).unwrap();
        assert_eq!(indexed(&conn), vec![row("a", "x", ""), row("b", "y", "plan.pdf")]);
    }

    #[test]
    fn deleting_an_item_with_files_leaves_no_index_row() {
        let (_d, conn) = fresh();
        put(&conn, "a", Some("x"));
        file(&conn, "a", "f", "plan.pdf");
        put(&conn, "b", Some("kept"));
        conn.execute("DELETE FROM items WHERE id = 'a'", []).unwrap();
        assert_eq!(indexed(&conn), vec![row("b", "kept", "")]);
    }

    #[test]
    fn a_pull_page_and_its_tombstones_keep_the_index_current() {
        let (_d, conn) = fresh();
        let page = |json: serde_json::Value| -> crate::sync::Page { serde_json::from_value(json).unwrap() };
        let item = |text: &str| {
            serde_json::json!({"id": "i", "topic_id": null, "text": text, "capture_time": "2025-10-09T08:53:20Z",
                "deleted_at": null, "purge_at": null, "text_rev": 0,
                "attachments": [{"id": "f", "filename": "notes.txt", "mime_type": "text/plain", "size_bytes": 1, "uploaded": true, "has_thumbnail": false}]})
        };
        crate::sync::apply_pull(&conn, &page(serde_json::json!({"items": [item("hello")], "topics": [], "tombstones": [], "cursor": 1, "has_more": false}))).unwrap();
        crate::sync::apply_pull(&conn, &page(serde_json::json!({"items": [item("hello again")], "topics": [], "tombstones": [], "cursor": 2, "has_more": false}))).unwrap();
        assert_eq!(indexed(&conn), vec![row("i", "hello again", "notes.txt")]);
        crate::sync::apply_pull(&conn, &page(serde_json::json!({"items": [], "topics": [], "tombstones": ["i"], "cursor": 3, "has_more": false}))).unwrap();
        assert_eq!(indexed(&conn), vec![]);
    }
}
