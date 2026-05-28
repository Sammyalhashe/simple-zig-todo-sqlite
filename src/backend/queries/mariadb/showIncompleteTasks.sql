SELECT task_id, title, status FROM supernotedb.t_schedule_task WHERE is_deleted != 'Y' AND status != 'completed' ORDER BY last_modified DESC;
