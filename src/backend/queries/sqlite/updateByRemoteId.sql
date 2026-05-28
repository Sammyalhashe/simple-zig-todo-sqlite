UPDATE tasks SET title = ?, status = ?, completed_time = ?, last_modified = ? WHERE remote_task_id = ? AND is_deleted != 'Y';
