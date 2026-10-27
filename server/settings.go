package server

func (b *batch) setTrashAfterCopy(o pushOp, s stamp) (opResult, error) {
	if o.Value == nil {
		return rejected("invalid"), nil
	}
	var cur stamp
	if err := b.tx.QueryRow(b.ctx, `
		SELECT trash_after_copy_updated_at, trash_after_copy_updated_by FROM settings FOR UPDATE`).Scan(&cur.at, &cur.by); err != nil {
		return opResult{}, err
	}
	if !s.beats(cur) {
		return rejected("superseded"), nil
	}
	_, err := b.tx.Exec(b.ctx, `
		UPDATE settings SET trash_after_copy = $1, trash_after_copy_updated_at = $2, trash_after_copy_updated_by = $3`,
		*o.Value, s.at, s.by)
	return accepted(), err
}
