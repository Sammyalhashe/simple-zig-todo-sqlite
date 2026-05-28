SELECT COALESCE(MAX(sort), 0) + 1, COALESCE(MAX(sort_completed), 0) + 1 FROM supernotedb.t_schedule_task WHERE user_id = ?
