SELECT id, title, status FROM tasks WHERE is_deleted != 'Y' AND status != 'completed' ORDER BY last_modified DESC;
