# Reproduce hatchet-dev/hatchet#4974: DAG run-level status never finalizes when
# a DAG's id collides with one of its own task ids (v0.106.5+).
#
#   make repro     # full bug run on v0.107.1: up -> token -> run twice -> check
#   make control   # same on v0.101.27: first DAG reads COMPLETED
#   make down      # wipe containers + volumes (needed between runs: DB must be fresh)
#
# Requires: docker (compose v2), go 1.22+. Ports: 8890 (dashboard), 7090 (gRPC).

PROJECT     ?= dagrepro
BUG_IMAGE   ?= ghcr.io/hatchet-dev/hatchet/hatchet-lite:v0.107.1
CTRL_IMAGE  ?= ghcr.io/hatchet-dev/hatchet/hatchet-lite:v0.101.27
DASH_PORT   ?= 8890
GRPC_PORT   ?= 7090
COMPOSE      = ENGINE_IMAGE=$(ENGINE_IMAGE) DASH_PORT=$(DASH_PORT) GRPC_PORT=$(GRPC_PORT) docker compose -p $(PROJECT) -f compose.yml
PSQL         = $(COMPOSE) exec -T postgres psql -U hatchet -d hatchet
ENGINE_IMAGE ?= $(BUG_IMAGE)

.PHONY: repro control up wait token run check down clean

repro: up wait token
	$(MAKE) run
	$(MAKE) run
	$(MAKE) check
	@echo; echo "Expected on v0.107.1: dag 1 = QUEUED with task_ids {1,2,3} and misclassified=t; dag 2 = COMPLETED {6,7,8} misclassified=f."

control: ENGINE_IMAGE=$(CTRL_IMAGE)
control: up wait token
	$(MAKE) run
	$(MAKE) check
	@echo; echo "Expected on v0.101.27: dag 1 = COMPLETED (same SDK, same code; only the engine differs)."

up:
	$(COMPOSE) up -d

# Block until goose has applied the engine's migrations (engine boot runs them).
wait:
	@for i in $$(seq 1 90); do \
	  v=$$($(PSQL) -tAc "select version_id from goose_db_version order by version_id desc limit 1" 2>/dev/null); \
	  [ -n "$$v" ] && [ "$$v" != "0" ] && { echo "goose at $$v"; break; }; sleep 2; done

# Mint a client token for the default tenant and write it to .env (gitignored).
token:
	@t=$$($(PSQL) -tAc "select id from \"Tenant\" where slug='default'"); \
	 tok=$$($(COMPOSE) exec -T hatchet-lite /hatchet-admin token create --config /config --tenant-id $$t 2>/dev/null | tail -1); \
	 printf 'HATCHET_CLIENT_TOKEN=%s\nHATCHET_CLIENT_HOST_PORT=localhost:%s\nHATCHET_CLIENT_SERVER_URL=http://localhost:%s\nHATCHET_CLIENT_TLS_STRATEGY=none\n' "$$tok" "$(GRPC_PORT)" "$(DASH_PORT)" > .env; \
	 echo "token written to .env ($${#tok} bytes)"

# Run the 3-step DAG once (worker + trigger, exits by itself).
run:
	@set -a; . ./.env; set +a; go run . 2>&1 | grep -E "triggered|error|panic" ; sleep 5

check:
	@$(PSQL) < check.sql

down:
	$(COMPOSE) down -v

clean: down
	rm -f .env

# Machine-checkable verdicts (used by CI). `assert-bug` passes when the bug is
# present; `assert-fixed` passes when DAG 1 finalized (the control engine, or a
# fixed engine). Both wait up to 60s for the periodic roll-up before judging.
.PHONY: assert-bug assert-fixed
assert-bug:
	@for i in $$(seq 1 12); do sleep 5; s=$$($(PSQL) -tAc "select readable_status from v1_dags_olap where id=1"); [ "$$s" = "COMPLETED" ] && break; done; \
	 mis=$$($(PSQL) -tAc "select bool_or(dt.task_id = d.id and dt.task_inserted_at = d.inserted_at) from v1_dags_olap d join v1_dag_to_task_olap dt on (dt.dag_id, dt.dag_inserted_at) = (d.id, d.inserted_at) where d.id=1"); \
	 echo "dag 1: status=$$s misclassified=$$mis"; \
	 [ "$$s" != "COMPLETED" ] && [ "$$mis" = "t" ] && echo "BUG REPRODUCED: DAG 1 never finalized" || { echo "bug NOT reproduced (engine fixed?)"; exit 1; }
assert-fixed:
	@for i in $$(seq 1 12); do sleep 5; s=$$($(PSQL) -tAc "select readable_status from v1_dags_olap where id=1"); [ "$$s" = "COMPLETED" ] && break; done; \
	 echo "dag 1: status=$$s"; [ "$$s" = "COMPLETED" ] && echo "OK: DAG 1 finalized" || { echo "FAIL: DAG 1 stuck"; exit 1; }
