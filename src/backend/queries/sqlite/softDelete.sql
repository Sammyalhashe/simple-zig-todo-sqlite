UPDATE tasks SET is_deleted = 'Y', last_modified = CAST(strftime('%s','now') AS INTEGER) * 1000 WHERE id = ?;
