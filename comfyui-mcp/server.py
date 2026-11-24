import asyncio
import json
import os
import random
from pathlib import Path
from typing import Annotated

import httpx
from mcp.server.fastmcp import FastMCP, Image
from pydantic import Field

WORKFLOW = Path(__file__).parent / "workflows" / "z-image-turbo.api.json"

Side = Annotated[int, Field(ge=256, le=2048, multiple_of=16)]


class ComfyUIError(Exception):
    pass


async def run(comfyui, workflow):
    response = await comfyui.post("/prompt", json={"prompt": workflow})
    response.raise_for_status()
    prompt_id = response.json()["prompt_id"]
    while not (entry := (await comfyui.get(f"/history/{prompt_id}")).json().get(prompt_id)):
        await asyncio.sleep(1)
    for kind, detail in entry["status"]["messages"]:
        if kind == "execution_error":
            raise ComfyUIError(detail["exception_message"])
    return entry["outputs"]


def build_server(comfyui, **settings):
    mcp = FastMCP("comfyui", stateless_http=True, **settings)

    @mcp.tool()
    async def generate(prompt: str, width: Side = 1024, height: Side = 1024):
        """Generate an image from a text prompt."""
        workflow = json.loads(WORKFLOW.read_text())
        workflow["5"]["inputs"]["text"] = prompt
        workflow["7"]["inputs"].update(width=width, height=height)
        workflow["8"]["inputs"]["seed"] = random.randrange(2**32)
        outputs = await run(comfyui, workflow)
        [image] = outputs["10"]["images"]
        response = await comfyui.get("/view", params=image)
        response.raise_for_status()
        return Image(data=response.content, format="png")

    return mcp


if __name__ == "__main__":
    comfyui = httpx.AsyncClient(base_url=os.environ["COMFYUI_URL"], timeout=60)
    build_server(comfyui, port=int(os.environ["MCP_PORT"])).run("streamable-http")
