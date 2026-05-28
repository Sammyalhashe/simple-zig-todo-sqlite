INSERT INTO tasks (title, last_modified) VALUES (?, CAST(strftime('%s','now') AS INTEGER) * 1000);
