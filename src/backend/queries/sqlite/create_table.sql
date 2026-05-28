CREATE TABLE IF NOT EXISTS tasks
(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'needsAction',
    last_modified INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER) * 1000),  due_time INTEGER NOT NULL DEFAULT 0
    is_deleted TEXT NOT NULL DEFAULT 'N'
    completed_time INTEGER
)
