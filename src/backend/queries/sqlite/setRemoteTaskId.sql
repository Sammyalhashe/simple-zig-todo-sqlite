UPDATE tasks SET remote_task_id = ? WHERE title = ? AND is_deleted != 'Y' AND remote_task_id IS NULL;
