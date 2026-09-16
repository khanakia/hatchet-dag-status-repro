# hatchet-dag-status-repro

[![engine v0.107.1](https://github.com/khanakia/hatchet-dag-status-repro/actions/workflows/engine-v0.107.1.yml/badge.svg)](https://github.com/khanakia/hatchet-dag-status-repro/actions/workflows/engine-v0.107.1.yml) [![engine v0.101.27 (control)](https://github.com/khanakia/hatchet-dag-status-repro/actions/workflows/engine-v0.101.27.yml/badge.svg)](https://github.com/khanakia/hatchet-dag-status-repro/actions/workflows/engine-v0.101.27.yml)

Minimal, self-contained reproduction for [hatchet-dev/hatchet#4974](https://github.com/hatchet-dev/hatchet/issues/4974): on hatchet-lite **v0.106.5+** a DAG run whose id collides with one of its own task ids never reaches a terminal run-level status — its tasks all complete, but `v1_dags_olap.readable_status` (and the REST `run.status`) stays `QUEUED` forever. On a **fresh database** this is guaranteed for the first DAG run, because `v1_dag_id_seq` and `v1_task_id_seq` both start at 1.

The badges are the live verdict. Both workflows assert the same thing — *the first DAG run on a fresh database reaches a terminal status* — so **red on v0.107.1 means the bug is present** (open the failing step to see the `QUEUED` row and `FAIL: DAG 1 stuck`), and green on v0.101.27 is the control. When an engine build fixes it, re-run the v0.107.1 workflow with its `engine_image` input pointed at that build and it turns green.

## Run it (docker + go, ~2 minutes)

```sh
make repro      # boots hatchet-lite v0.107.1 on an empty Postgres, runs a 3-step DAG twice, prints the verdict
make assert-bug # exit 0 == bug reproduced
make down       # wipe — the DB must be fresh for the next run
make control    # same thing on v0.101.27: DAG 1 finalizes
```

Expected `make repro` output on v0.107.1:

```
 dag_id | readable_status | task_ids | misclassified
--------+-----------------+----------+---------------
      1 | QUEUED          | {1,2,3}  | t
      2 | COMPLETED       | {4,5,6}  | f
```

DAG 1 stays `QUEUED` indefinitely while all three of its tasks are `COMPLETED`. DAG 2 — same engine, same code, seconds later — finalizes, because its id (2) is not among its task ids. Expected `make control` output on v0.101.27: DAG 1 = `COMPLETED` (note `misclassified=t` there too — that engine simply has no such clause).

## What is in here

| File | Purpose |
|---|---|
| `compose.yml` | hatchet-lite + empty Postgres 15; `ENGINE_IMAGE` selects bug vs control image |
| `main.go` | 3-step `WithParents` DAG; worker + one trigger in one process; Go SDK v0.107.1 |
| `check.sql` | the audit query — `misclassified=t` marks a DAG the engine will never finalize |
| `Makefile` | `repro` / `control` / `assert-bug` / `assert-fixed` / `down`; no other tooling needed |
| `.github/workflows/engine-v0.107.1.yml` | asserts DAG 1 finalizes on v0.107.1 — red while the bug exists; `workflow_dispatch` input `engine_image` tests a candidate fix |
| `.github/workflows/engine-v0.101.27.yml` | the same assertion on v0.101.27 — green control |

## Mechanism (short)

`UpdateDAGStatusesFromMQ` / `UpdateDAGStatuses` skip a DAG when `v1_dag_to_task_olap` has a row with `task_id = dag_id AND task_inserted_at = dag_inserted_at` — intended to detect operator DAGs ("dag-as-durable-task") by their self-mapping row. But DAG ids and task ids come from independent sequences and a DAG plus its tasks are inserted in one transaction, so any ordinary DAG whose id equals one of its own task ids is misclassified. Full write-up, production evidence and suggested fix are in the issue.

Workaround for a fresh database: `select setval('v1_task_id_seq', 1000);` before the first DAG run.
