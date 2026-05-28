SELECT title, status, last_modified, due_time, completed_time, is_deleted, task_id FROM supernotedb.t_schedule_task WHERE is_deleted != 'Y';
