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
	@echo "  make logs          View recent logs"
	@echo "  make logs-f        Follow logs (live tail)"
	@echo "  make ssh           SSH into server"
	@echo ""
	@echo "Testing:"
	@echo "  make test          Run API tests"
	@echo "  make benchmark     Run load tests (k6)"

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

.PHONY: status-f
status-f:
	@watch -n 2 -c make status

.PHONY: logs
logs:
	@sshpass -p "$(SSH_PASS)" ssh -o StrictHostKeyChecking=no $(REMOTE_USER)@$(REMOTE_HOST) "journalctl -u llama-server -n 50 --no-pager"

.PHONY: logs-f
logs-f:
	@sshpass -p "$(SSH_PASS)" ssh -o StrictHostKeyChecking=no $(REMOTE_USER)@$(REMOTE_HOST) "journalctl -u llama-server -f"

.PHONY: config
config:
	@./scripts/server-utils.sh show_config

.PHONY: ssh
ssh:
	@echo "SSH into LLM node..."
	@sshpass -p "$(SSH_PASS)" ssh -o StrictHostKeyChecking=no $(REMOTE_USER)@$(REMOTE_HOST) -L 9090:localhost:9090

.PHONY: test
test:
	@./tests/test-remote.sh

.PHONY: benchmark
benchmark:
	@./scripts/benchmark.sh
