UPDATE tasks SET title = ?, status = ?, completed_time = ?, last_modified = ? WHERE title = ? AND is_deleted != 'Y' AND remote_task_id IS NULL;
