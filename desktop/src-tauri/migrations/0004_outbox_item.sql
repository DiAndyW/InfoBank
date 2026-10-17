CREATE INDEX outbox_item ON outbox (json_extract(op, '$.item_id'));
