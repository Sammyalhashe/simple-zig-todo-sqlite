SELECT id, title, status FROM tasks WHERE is_deleted != 'Y' ORDER BY last_modified DESC;
