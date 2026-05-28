UPDATE supernotedb.t_schedule_task SET title = ?, status = ?, completed_time = ?, last_modified = ? WHERE task_id = ? AND is_deleted != 'Y'
