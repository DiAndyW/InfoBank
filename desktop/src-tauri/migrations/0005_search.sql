-- Every Item, Trash included; search joins items for its filters. rowid = items.rowid, which holds because nothing runs VACUUM.
CREATE VIRTUAL TABLE search USING fts5(text, names, tokenize = 'trigram remove_diacritics 1');

CREATE VIEW item_names AS
    SELECT item_id, group_concat(filename, char(10)) AS names
    FROM (SELECT item_id, filename FROM attachments ORDER BY rowid)
    GROUP BY item_id;

CREATE TRIGGER search_item_added AFTER INSERT ON items BEGIN
    INSERT INTO search (rowid, text, names)
    VALUES (new.rowid, coalesce(new.text, ''), coalesce((SELECT names FROM item_names WHERE item_id = new.id), ''));
END;

-- Pull's upsert sets text on every page, so only a real change touches the index.
CREATE TRIGGER search_text_changed AFTER UPDATE OF text ON items WHEN old.text IS NOT new.text BEGIN
    UPDATE search SET text = coalesce(new.text, '') WHERE rowid = new.rowid;
END;

CREATE TRIGGER search_item_removed AFTER DELETE ON items BEGIN
    DELETE FROM search WHERE rowid = old.rowid;
END;

CREATE TRIGGER search_file_added AFTER INSERT ON attachments BEGIN
    UPDATE search SET names = coalesce((SELECT names FROM item_names WHERE item_id = new.item_id), '')
    WHERE rowid = (SELECT rowid FROM items WHERE id = new.item_id);
END;

CREATE TRIGGER search_file_removed AFTER DELETE ON attachments BEGIN
    UPDATE search SET names = coalesce((SELECT names FROM item_names WHERE item_id = old.item_id), '')
    WHERE rowid = (SELECT rowid FROM items WHERE id = old.item_id);
END;

CREATE TRIGGER search_file_changed AFTER UPDATE OF filename, item_id ON attachments
WHEN old.filename IS NOT new.filename OR old.item_id IS NOT new.item_id BEGIN
    UPDATE search SET names = coalesce((SELECT names FROM item_names WHERE item_id = old.item_id), '')
    WHERE rowid = (SELECT rowid FROM items WHERE id = old.item_id);
    UPDATE search SET names = coalesce((SELECT names FROM item_names WHERE item_id = new.item_id), '')
    WHERE rowid = (SELECT rowid FROM items WHERE id = new.item_id);
END;

INSERT INTO search (rowid, text, names)
SELECT rowid, coalesce(text, ''), coalesce((SELECT names FROM item_names WHERE item_id = items.id), '') FROM items;
