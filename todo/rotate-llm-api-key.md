# Rotate the LLM API key

## Why

Until 2026-10-12 every instance passed its key on the `podman run` command line, where
`/proc/<pid>/cmdline` let any local user read it. A research agent's SSH output also captured
it. The leak is closed (`-e LLAMA_API_KEY` passes it through the environment, and `make verify`
fails if it is on a command line again), but the old value is exposed.

## Where it lives

- [ ] The host: `LLAMA_API_KEY` in every `/opt/llm/instances/<name>.conf`. Deploy reads it back
      from the first existing instance and never rewrites it, so a new value has to be written
      into each conf, then `make deploy` restarts the instances.
- [ ] Shannon: GSM secret `openwebui-llm-api-key` (on-prem-admin, `apps/values/shannon`).
- [ ] boatload: GSM `llamacpp-api-key` and `nonprod-llamacpp-api-key` (CI reads it through
      `ci.secrets`), and the GitHub Actions secret `LLAMACPP_API_KEY` used by
      `test-api.yaml` and `test-web.yaml`.
- [ ] twofit CI, which uses `qwen3-8b`: find where its key is kept.

## Order

Write every consumer's new value first and the host's last. Each consumer gets 401s from the
moment the host changes until its own value is updated, so do it in one sitting.
