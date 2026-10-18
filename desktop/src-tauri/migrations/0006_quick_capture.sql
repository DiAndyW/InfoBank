ALTER TABLE device ADD COLUMN quick_capture_shortcut TEXT NOT NULL DEFAULT 'CommandOrControl+Shift+Space';
ALTER TABLE device ADD COLUMN quick_capture_on INTEGER NOT NULL DEFAULT 1 CHECK (quick_capture_on IN (0, 1));
