# .env is NOT included here on purpose. Make does not strip quotes, so
# LLM_HOST='host' would be exported with the quotes still attached and end up
# in URLs as https://'host'. Every script sources .env itself.

.PHONY: help
help:
	@echo "🚀 llama-server automation commands"
	@echo ""
	@echo "Setup:"
	@echo "  make setup         Create config/llama.yaml from example"
	@echo "  make config-edit   Edit configuration file"
	@echo "  make config        View remote server config"
	@echo ""
	@echo "Deploy:"
	@echo "  make deploy        Deploy config to remote server"
	@echo "  make deploy-dry    Preview deployment without applying"
	@echo ""
	@echo "Server (all instances, or one with INSTANCE=<name>):"
	@echo "  make status        Per-instance state, window, slots, metrics"
	@echo "  make status-f      Watch status (live updates)"
	@echo "  make start         Start instances"
	@echo "  make stop          Stop instances"
	@echo "  make restart       Restart instances"
	@echo "  make enable        Enable auto-start on boot (and start now)"
	@echo "  make disable       Disable auto-start on boot (and stop now)"
	@echo "  make logs          View recent logs"
	@echo "  make logs-f        Follow logs (live tail)"
	@echo "  make ssh           SSH into server"
	@echo ""
	@echo "Testing:"
	@echo "  make lint          Shellcheck all scripts"
	@echo "  make test-unit     Offline render/config tests (no server needed)"
	@echo "  make test-context  Assert the effective per-request context window"
	@echo "  make verify        Assert the running server matches llama.yaml"
	@echo "  make test-drift    Assert verify actually fails on a drifted target"
	@echo "  make test-knobs    Assert every llama.yaml knob reaches the live server"
	@echo "  make test          Run API tests"
	@echo "  make test-models   Run model selection tests"
	@echo "  make benchmark     Run load tests (k6)"
	@echo "  make bench-agent   Streamed + tool-calling + multi-turn; gates on correctness"
	@echo ""
	@echo "Measurement:"
	@echo "  make kv-study-plan Budget for the KV quantization study (changes nothing)"
	@echo "  make kv-study      Measure what KV quantization costs this model"
	@echo ""
	@echo "Tunnel:"
	@echo "  make tunnel-reconfigure                         Change Cloudflare Tunnel hostname"
	@echo ""
	@echo "Models:"
	@echo "  make list-models                                List remote models"
	@echo "  make add-model REPO=org/repo MODEL=file.gguf   Download model"
	@echo "  make switch-model MODEL=f.gguf INSTANCE=name   Switch a model"

.PHONY: setup
setup:
	@./scripts/setup-llama.sh

.PHONY: config-edit
config-edit:
	@$${EDITOR:-vim} config/llama.yaml

.PHONY: deploy
deploy:
	@./scripts/deploy-llama.sh

.PHONY: deploy-dry
deploy-dry:
	@./scripts/deploy-llama.sh --dry-run

.PHONY: status
status:
	@./scripts/server-utils.sh show_status $(INSTANCE)

.PHONY: start
start:
	@./scripts/server-utils.sh start_server $(INSTANCE)

.PHONY: stop
stop:
	@./scripts/server-utils.sh stop_server $(INSTANCE)

.PHONY: restart
restart:
	@./scripts/server-utils.sh restart_server $(INSTANCE)

.PHONY: enable
enable:
	@./scripts/server-utils.sh enable_server $(INSTANCE)

.PHONY: disable
disable:
	@./scripts/server-utils.sh disable_server $(INSTANCE)

.PHONY: status-f
status-f:
	@watch -n 2 -c make status

.PHONY: logs
logs:
	@./scripts/server-utils.sh show_logs $(INSTANCE)

.PHONY: logs-f
logs-f:
	@./scripts/server-utils.sh follow_logs $(INSTANCE)

.PHONY: config
config:
	@./scripts/server-utils.sh show_config $(INSTANCE)

.PHONY: ssh
ssh:
	@echo "SSH into LLM node..."
	@./scripts/server-utils.sh ssh_in

.PHONY: lint
lint:
	@command -v shellcheck >/dev/null 2>&1 || { \
	  echo "shellcheck not installed. Install: sudo apt install shellcheck"; exit 1; }
	@shellcheck $$(git ls-files '*.sh')
	@echo "shellcheck clean"

.PHONY: test-unit
test-unit:
	@./tests/test-render.sh
	@./tests/test-agent-judge.sh

.PHONY: test-unit-accept
test-unit-accept:
	@./tests/test-render.sh --accept

.PHONY: test-context
test-context:
	@./tests/test-context-window.sh

.PHONY: verify
verify:
	@./scripts/verify-deploy.sh

.PHONY: test-drift
test-drift:
	@./tests/test-verify-detects-drift.sh

.PHONY: test-knobs
test-knobs:
	@./tests/test-knob-propagation.sh

.PHONY: test
test:
	@./tests/test-remote.sh

.PHONY: benchmark
benchmark:
	@./scripts/benchmark.sh

.PHONY: benchmark-accept
benchmark-accept:
	@src=bench/$${BENCH_LABEL:-current}.json; \
	 [ -f "$$src" ] || { echo "no benchmark run found at $$src"; exit 1; }; \
	 [ "$$src" = bench/baseline.json ] || cp "$$src" bench/baseline.json; \
	 echo "Baseline updated from $$src. Commit it to record the trade."

.PHONY: bench-agent
bench-agent:
	@./scripts/bench-agent.sh

.PHONY: bench-agent-accept
bench-agent-accept:
	@./scripts/bench-agent.sh --accept

.PHONY: kv-study-plan
kv-study-plan:
	@./scripts/kv-quant-study.sh --plan

.PHONY: kv-study
kv-study:
	@./scripts/kv-quant-study.sh

.PHONY: list-models
list-models:
	@./scripts/list-models.sh

.PHONY: add-model
add-model:
	@./scripts/add-model.sh $(REPO) $(MODEL)

.PHONY: switch-model
switch-model:
	@./scripts/switch-model.sh $(MODEL) $(INSTANCE)

.PHONY: test-models
test-models:
	@./tests/test-model-selection.sh

.PHONY: tunnel-reconfigure
tunnel-reconfigure:
	@sudo ./scripts/setup-cloudflare.sh --reconfigure
