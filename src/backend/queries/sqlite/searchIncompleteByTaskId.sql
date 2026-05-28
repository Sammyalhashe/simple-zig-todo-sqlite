SELECT last_modified FROM tasks WHERE remote_task_id = ? AND is_deleted != 'Y';
