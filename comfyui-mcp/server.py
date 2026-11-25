import asyncio
import base64
import json
import math
import os
import random
import time
from pathlib import Path
from typing import Annotated, Literal

import httpx
from mcp.server.fastmcp import FastMCP
from mcp.types import CallToolResult, TextContent
from pydantic import Field

WORKFLOW = Path(__file__).parent / "workflows" / "z-image-turbo.api.json"
VIDEO_WORKFLOW = Path(__file__).parent / "workflows" / "wan2.2-t2v-14b.api.json"
VIDEO_SIZES = {"480p": (832, 480), "720p": (1280, 720)}
SHOWN = "It is shown to the user above your reply. Do not embed it or link to it."
VIEWER = {"ui": {"resourceUri": "ui://comfyui/viewer"}}
VIEWER_PAGE = Path(__file__).parent / "viewer.html"

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


async def jobs(comfyui):
    queue = (await comfyui.get("/queue")).json()
    return queue["queue_running"] + queue["queue_pending"]


async def queued(comfyui, prompt_id):
    return any(job[1] == prompt_id for job in await jobs(comfyui))


async def rendering_video(comfyui):
    return next((job[1] for job in await jobs(comfyui)
                 if any(node["class_type"] == "SaveAnimatedWEBP" for node in job[2].values())), None)


async def fetch(comfyui, file):
    response = await comfyui.get("/view", params=file)
    response.raise_for_status()
    return response.content


def shown(data, mime_type):
    return CallToolResult(
        content=[TextContent(type="text", text=SHOWN)],
        _meta={"image": {"mimeType": mime_type, "data": base64.b64encode(data).decode()}},
    )


def build_server(comfyui, wait=120, **settings):
    mcp = FastMCP("comfyui", stateless_http=True, **settings)

    @mcp.resource(VIEWER["ui"]["resourceUri"], mime_type="text/html;profile=mcp-app")
    def viewer():
        return VIEWER_PAGE.read_text()

    @mcp.tool(meta=VIEWER)
    async def generate(prompt: str, width: Side = 1024, height: Side = 1024):
        """Generate a still image from a text prompt. For moving pictures use video."""
        workflow = json.loads(WORKFLOW.read_text())
        workflow["5"]["inputs"]["text"] = prompt
        workflow["7"]["inputs"].update(width=width, height=height)
        workflow["8"]["inputs"]["seed"] = random.randrange(2**32)
        outputs = await outputs_within(comfyui, await submit(comfyui, workflow), math.inf)
        [image] = outputs["10"]["images"]
        return shown(await fetch(comfyui, image), "image/png")

    async def clip_or_pending(job_id):
        outputs = await outputs_within(comfyui, job_id, wait)
        if outputs is None:
            return f'The clip is still rendering. Call get_job with job_id "{job_id}" to get it.'
        [clip] = outputs["9"]["images"]
        return shown(await fetch(comfyui, clip), "image/webp")

    @mcp.tool(meta=VIEWER)
    async def video(
        prompt: str,
        seconds: Annotated[int, Field(ge=1, le=5)] = 2,
        resolution: Literal["480p", "720p"] = "480p",
    ):
        """Make a video: generate a short silent clip from a text prompt, at 832x480 or, only when asked, 1280x720. At 832x480 a 1 second clip takes about 2 minutes and a 2 second clip about 7; longer clips and 1280x720 take much longer. Returns the clip, or a job_id for get_job if it is still rendering. Calling it again while a clip renders returns that clip's job instead of starting another."""
        if running := await rendering_video(comfyui):
            return await clip_or_pending(running)
        width, height = VIDEO_SIZES[resolution]
        workflow = json.loads(VIDEO_WORKFLOW.read_text())
        workflow["5"]["inputs"]["text"] = prompt
        workflow["7"]["inputs"].update(width=width, height=height, length=24 * seconds + 1)
        workflow["8"]["inputs"]["noise_seed"] = random.randrange(2**32)
        return await clip_or_pending(await submit(comfyui, workflow))

    @mcp.tool(meta=VIEWER)
    async def get_job(job_id: str):
        """Get a clip that video started, using the job_id video returned. It cannot start a video: to make one, call video."""
        if not (await queued(comfyui, job_id) or (await comfyui.get(f"/history/{job_id}")).json()):
            raise ComfyUIError(f'There is no job "{job_id}". Call video to start one.')
        return await clip_or_pending(job_id)

    return mcp


if __name__ == "__main__":
    comfyui = httpx.AsyncClient(base_url=os.environ["COMFYUI_URL"], timeout=60)
    build_server(comfyui, port=int(os.environ["MCP_PORT"])).run("streamable-http")
