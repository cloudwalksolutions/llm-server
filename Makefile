# Load environment variables from .env
-include .env
export

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
	@echo "Server:"
	@echo "  make status        Show server status & metrics"
	@echo "  make status-f      Watch status (live updates)"
	@echo "  make start         Start the server"
	@echo "  make stop          Stop the server"
	@echo "  make restart       Restart the server"
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
	@echo "  make test          Run API tests"
	@echo "  make test-models   Run model selection tests"
	@echo "  make benchmark     Run load tests (k6)"
	@echo ""
	@echo "Tunnel:"
	@echo "  make tunnel-reconfigure                         Change Cloudflare Tunnel hostname"
	@echo ""
	@echo "Models:"
	@echo "  make list-models                                List remote models"
	@echo "  make add-model REPO=org/repo MODEL=file.gguf   Download model"
	@echo "  make switch-model MODEL=file.gguf              Switch active model"

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
	@./scripts/server-utils.sh show_status

.PHONY: start
start:
	@./scripts/server-utils.sh start_server

.PHONY: stop
stop:
	@./scripts/server-utils.sh stop_server

.PHONY: restart
restart:
	@./scripts/server-utils.sh restart_server

.PHONY: enable
enable:
	@./scripts/server-utils.sh enable_server

.PHONY: disable
disable:
	@./scripts/server-utils.sh disable_server

.PHONY: status-f
status-f:
	@watch -n 2 -c make status

.PHONY: logs
logs:
	@./scripts/server-utils.sh show_logs

.PHONY: logs-f
logs-f:
	@./scripts/server-utils.sh follow_logs

.PHONY: config
config:
	@./scripts/server-utils.sh show_config

.PHONY: ssh
ssh:
	@echo "SSH into LLM node..."
	@sshpass -p "$(SSH_PASS)" ssh -o StrictHostKeyChecking=no $(REMOTE_USER)@$(REMOTE_HOST) -L 9090:localhost:9090

.PHONY: lint
lint:
	@command -v shellcheck >/dev/null 2>&1 || { \
	  echo "shellcheck not installed. Install: sudo apt install shellcheck"; exit 1; }
	@shellcheck $$(git ls-files '*.sh')
	@echo "shellcheck clean"

.PHONY: test-unit
test-unit:
	@./tests/test-render.sh

.PHONY: test-unit-accept
test-unit-accept:
	@./tests/test-render.sh --accept

.PHONY: test-context
test-context:
	@./tests/test-context-window.sh

.PHONY: verify
verify:
	@./scripts/verify-deploy.sh

.PHONY: test
test:
	@./tests/test-remote.sh

.PHONY: benchmark
benchmark:
	@./scripts/benchmark.sh

.PHONY: benchmark-accept
benchmark-accept:
	@cp bench/current.json bench/baseline.json
	@echo "Baseline updated from bench/current.json. Commit it to record the trade."

.PHONY: list-models
list-models:
	@./scripts/list-models.sh

.PHONY: add-model
add-model:
	@./scripts/add-model.sh $(REPO) $(MODEL)

.PHONY: switch-model
switch-model:
	@./scripts/switch-model.sh $(MODEL)

.PHONY: test-models
test-models:
	@./tests/test-model-selection.sh

.PHONY: tunnel-reconfigure
tunnel-reconfigure:
	@sudo ./scripts/setup-cloudflare.sh --reconfigure
