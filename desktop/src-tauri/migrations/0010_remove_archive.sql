DELETE FROM outbox WHERE json_extract(op, '$.type') IN ('ArchiveTopic','UnarchiveTopic');
ALTER TABLE topics DROP COLUMN archived_at;
