-- One row per DAG. misclassified=t is the bug trigger: a mapping row whose
-- task_id equals the dag_id with the same inserted_at makes the engine treat
-- the DAG as an "operator DAG" and skip the legacy status roll-up.
select d.id as dag_id, d.readable_status,
       array_agg(dt.task_id order by dt.task_id) as task_ids,
       bool_or(dt.task_id = d.id and dt.task_inserted_at = d.inserted_at) as misclassified
from v1_dags_olap d
join v1_dag_to_task_olap dt on (dt.dag_id, dt.dag_inserted_at) = (d.id, d.inserted_at)
group by d.id, d.readable_status
order by d.id;
