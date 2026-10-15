-- The All Items Feed pages by (capture_time, id); Inbox and Topic Feeds use items_topic_capture_time.
CREATE INDEX items_capture_time ON items (capture_time, id);
