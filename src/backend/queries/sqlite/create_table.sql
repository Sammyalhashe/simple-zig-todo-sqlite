CREATE TABLE IF NOT EXISTS tasks
(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'needsAction',
    last_modified INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER) * 1000),
    due_time INTEGER NOT NULL DEFAULT 0,
    is_deleted TEXT NOT NULL DEFAULT 'N',
    completed_time INTEGER,
    remote_task_id TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_remote_task_id ON tasks(remote_task_id) WHERE remote_task_id IS NOT NULL;
