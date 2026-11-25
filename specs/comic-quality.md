# Comic panel quality

`comic` draws its panels with Qwen-Image 2512 and the Lightning 8-step LoRA: about 8x faster than
the full model, at some cost in detail and prompt adherence.

If the panels are not good enough, the next step is the full model: drop the LoRA from
`comfyui-mcp/workflows/qwen-image-2512-comic.json`, sample 50 steps at cfg 4, and remove
`Qwen-Image-2512-Lightning-8steps-V1.0-bf16.safetensors` from `config/comfyui.yaml`. Expect each
panel to take several minutes, so a comic will almost always come back through `get_job`.
