
ssh:
	@echo "SSH into LLM node..."
	@ssh walkerobrien@192.168.1.168

.PHONY: test
test:
	./tests/test-remote.sh

