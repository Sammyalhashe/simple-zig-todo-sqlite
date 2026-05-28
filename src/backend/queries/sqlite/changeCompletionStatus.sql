UPDATE tasks SET status = ?, completed_time = ?, last_modified = CAST(strftime('%s','now') AS INTEGER) * 1000 WHERE id = ?;
