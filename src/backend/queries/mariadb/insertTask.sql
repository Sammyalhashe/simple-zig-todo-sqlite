INSERT INTO supernotedb.t_schedule_task
(
user_id, task_id, title, detail, importance, recurrence, links, status, last_modified, due_time, completed_time, is_deleted, sort, sort_completed, sort_time, planer_sort, planer_sort_time
) VALUES
(
?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'N', ?, ?, ROUND(UNIX_TIMESTAMP(NOW(3)) * 1000), 0, 0
)
