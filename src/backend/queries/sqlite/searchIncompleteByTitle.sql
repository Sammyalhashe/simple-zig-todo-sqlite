SELECT last_modified FROM tasks WHERE title = ? AND is_deleted != 'Y' AND remote_task_id IS NULL;
