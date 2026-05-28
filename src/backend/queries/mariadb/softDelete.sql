UPDATE supernotedb.t_schedule_task SET is_deleted = 'Y', last_modified = ROUND(UNIX_TIMESTAMP(NOW(3)) * 1000) WHERE task_id = ?
