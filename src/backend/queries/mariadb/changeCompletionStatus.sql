UPDATE supernotedb.t_schedule_task SET status = ?, completed_time = ?, last_modified = ROUND(UNIX_TIMESTAMP(NOW(3)) * 1000) WHERE task_id = ?
