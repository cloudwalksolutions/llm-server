
ssh-n1:
	@echo "SSH into node1..."
	@ssh node1@192.168.1.50
	# @ssh node1@ssh.cloudwalksolutions.net

ssh-l1:
	@echo "SSH into LLM node 1..."
	# @ssh walkerobrien@llm.cloudwalksolutions.ai
	@ssh walkerobrien@192.168.1.168

.PHONY: test
test:
	./tests/test-remote.sh

