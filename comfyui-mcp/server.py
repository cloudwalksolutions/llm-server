import asyncio
import json
import math
import os
import random
import time
from pathlib import Path
from typing import Annotated

import httpx
from mcp.server.fastmcp import FastMCP, Image
from pydantic import Field

WORKFLOW = Path(__file__).parent / "workflows" / "z-image-turbo.api.json"
VIDEO_WORKFLOW = Path(__file__).parent / "workflows" / "wan2.2-ti2v-5b.api.json"
SHOWN = "It is already shown to the user. Do not embed it or link to it."

Side = Annotated[int, Field(ge=256, le=2048, multiple_of=16)]

class ComfyUIError(Exception):
    pass


async def submit(comfyui, workflow):
    response = await comfyui.post("/prompt", json={"prompt": workflow})
    response.raise_for_status()
    return response.json()["prompt_id"]


async def outputs_within(comfyui, prompt_id, seconds):
    deadline = time.monotonic() + seconds
    while not (entry := (await comfyui.get(f"/history/{prompt_id}")).json().get(prompt_id)):
        if time.monotonic() >= deadline:
            return None
        await asyncio.sleep(1)
    for kind, detail in entry["status"]["messages"]:
        if kind == "execution_error":
            raise ComfyUIError(detail["exception_message"])
    return entry["outputs"]


async def fetch(comfyui, file):
    response = await comfyui.get("/view", params=file)
    response.raise_for_status()
    return response.content


def build_server(comfyui, wait=240, **settings):
    mcp = FastMCP("comfyui", stateless_http=True, **settings)

    @mcp.tool()
    async def generate(prompt: str, width: Side = 1024, height: Side = 1024):
        """Generate a still image from a text prompt. For moving pictures use video."""
        workflow = json.loads(WORKFLOW.read_text())
        workflow["5"]["inputs"]["text"] = prompt
        workflow["7"]["inputs"].update(width=width, height=height)
        workflow["8"]["inputs"]["seed"] = random.randrange(2**32)
        outputs = await outputs_within(comfyui, await submit(comfyui, workflow), math.inf)
        [image] = outputs["10"]["images"]
        return [SHOWN, Image(data=await fetch(comfyui, image), format="png")]

    async def clip_or_pending(job_id):
        outputs = await outputs_within(comfyui, job_id, wait)
        if outputs is None:
            return f'The clip is still rendering. Call get_job with job_id "{job_id}" to get it.'
        [clip] = outputs["9"]["images"]
        return [SHOWN, Image(data=await fetch(comfyui, clip), format="webp")]

    @mcp.tool()
    async def video(
        prompt: str,
        seconds: Annotated[int, Field(ge=1, le=5)] = 2,
    ):
        """Generate a short silent 1280x704 video clip from a text prompt. Takes about four minutes per second of video. Returns the clip, or a job_id for get_job if it is still rendering."""
        workflow = json.loads(VIDEO_WORKFLOW.read_text())
        workflow["5"]["inputs"]["text"] = prompt
        workflow["7"]["inputs"]["length"] = 24 * seconds + 1
        workflow["8"]["inputs"]["seed"] = random.randrange(2**32)
        return await clip_or_pending(await submit(comfyui, workflow))

    @mcp.tool()
    async def get_job(job_id: str):
        """Get a video clip that was still rendering when video returned."""
        return await clip_or_pending(job_id)

    return mcp


if __name__ == "__main__":
    comfyui = httpx.AsyncClient(base_url=os.environ["COMFYUI_URL"], timeout=60)
    build_server(comfyui, port=int(os.environ["MCP_PORT"])).run("streamable-http")
