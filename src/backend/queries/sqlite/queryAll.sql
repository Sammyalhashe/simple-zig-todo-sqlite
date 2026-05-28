SELECT title, status, last_modified, due_time, completed_time, is_deleted, remote_task_id FROM tasks WHERE is_deleted != 'Y';
