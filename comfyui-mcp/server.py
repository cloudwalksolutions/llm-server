import asyncio
import base64
import io
import json
import math
import os
import random
import time
from pathlib import Path
from typing import Annotated, Literal

import httpx
import PIL.Image
import PIL.ImageDraw
import PIL.ImageFont
from mcp.server.fastmcp import FastMCP
from mcp.types import CallToolResult, TextContent
from pydantic import BaseModel, Field

WORKFLOW = Path(__file__).parent / "workflows" / "z-image-turbo.api.json"
VIDEO_WORKFLOW = Path(__file__).parent / "workflows" / "wan2.2-t2v-14b.api.json"
COMIC_WORKFLOW = Path(__file__).parent / "workflows" / "qwen-image-2512-comic.json"
COMIC_STYLE = ("Black-and-white xkcd-style stick figure comic panel, simple thin black line art, "
               "plain white background, no text, no letters. ")
COMIC_FONT = Path(__file__).parent / "fonts" / "Humor-Sans.ttf"
COMIC_PANEL = 400
COMIC_PAD = 12
COMIC_LINE = 30
COMIC_GAP = 16
VIDEO_SIZES = {"480p": (832, 480), "720p": (1280, 720)}
SHOWN = "It is shown to the user above your reply. Do not embed it or link to it."
VIEWER = {"ui": {"resourceUri": "ui://comfyui/viewer"}}
VIEWER_PAGE = Path(__file__).parent / "viewer.html"

Side = Annotated[int, Field(ge=256, le=2048, multiple_of=16)]

class Line(BaseModel):
    speaker: str
    text: str


class Panel(BaseModel):
    scene: str
    lines: list[Line] = []


class ComfyUIError(Exception):
    pass


async def submit(comfyui, workflow, **extra_data):
    response = await comfyui.post("/prompt", json={"prompt": workflow, "extra_data": extra_data})
    response.raise_for_status()
    return response.json()["prompt_id"]


def comic_workflow(panels):
    template = json.loads(COMIC_WORKFLOW.read_text())
    workflow = dict(template["shared"])
    for number, panel in enumerate(panels):
        def own(value):
            return [f"{number}.{value[0]}", value[1]] if isinstance(value, list) and value[0] in template["panel"] else value
        for key, node in template["panel"].items():
            workflow[f"{number}.{key}"] = {**node, "inputs": {name: own(value) for name, value in node["inputs"].items()}}
        workflow[f"{number}.positive"]["inputs"]["text"] = COMIC_STYLE + panel.scene
        workflow[f"{number}.sampler"]["inputs"]["seed"] = random.randrange(2**32)
    return workflow


async def finished_within(comfyui, prompt_id, seconds):
    deadline = time.monotonic() + seconds
    while not (entry := (await comfyui.get(f"/history/{prompt_id}")).json().get(prompt_id)):
        if time.monotonic() >= deadline:
            return None
        await asyncio.sleep(1)
    for kind, detail in entry["status"]["messages"]:
        if kind == "execution_error":
            raise ComfyUIError(detail["exception_message"])
    return entry


def lettered(lines, font, width):
    rows = []
    for line in lines:
        row, *words = f"{line['speaker']}: {line['text']}".split()
        for word in words:
            if font.getlength(f"{row} {word}") > width:
                rows.append(row)
                row = word
            else:
                row = f"{row} {word}"
        rows.append(row)
    return rows


def compose(comic, pictures):
    font = PIL.ImageFont.truetype(str(COMIC_FONT), 24)
    panels = []
    for panel, picture in zip(comic["panels"], pictures):
        rows = lettered(panel["lines"], font, COMIC_PANEL - 2 * COMIC_PAD)
        band = len(rows) * COMIC_LINE + (2 * COMIC_PAD if rows else 0)
        drawn = PIL.Image.new("RGB", (COMIC_PANEL, band + COMIC_PANEL), "white")
        draw = PIL.ImageDraw.Draw(drawn)
        for number, row in enumerate(rows):
            draw.text((COMIC_PAD, COMIC_PAD + number * COMIC_LINE), row, font=font, fill="black")
        art = PIL.Image.open(io.BytesIO(picture)).convert("RGB").resize((COMIC_PANEL, COMIC_PANEL))
        drawn.paste(art, (0, band))
        draw.rectangle((0, 0, COMIC_PANEL - 1, drawn.height - 1), outline="black", width=3)
        panels.append(drawn)
    rows = [panels[start:start + 3] for start in range(0, len(panels), 3)]
    heights = [max(drawn.height for drawn in row) for row in rows]
    heading = COMIC_LINE + COMIC_GAP if comic["title"] else 0
    strip = PIL.Image.new("RGB", (COMIC_GAP + len(rows[0]) * (COMIC_PANEL + COMIC_GAP),
                                  heading + COMIC_GAP + sum(height + COMIC_GAP for height in heights)), "white")
    if comic["title"]:
        PIL.ImageDraw.Draw(strip).text((strip.width / 2, COMIC_GAP), comic["title"].upper(),
                                       font=font, fill="black", anchor="mt")
    top = heading + COMIC_GAP
    for row, height in zip(rows, heights):
        for column, drawn in enumerate(row):
            strip.paste(drawn, (COMIC_GAP + column * (COMIC_PANEL + COMIC_GAP), top))
        top += height + COMIC_GAP
    file = io.BytesIO()
    strip.save(file, "PNG")
    return file.getvalue()


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
        entry = await finished_within(comfyui, await submit(comfyui, workflow), math.inf)
        [image] = entry["outputs"]["10"]["images"]
        return shown(await fetch(comfyui, image), "image/png")

    async def result_or_pending(job_id):
        entry = await finished_within(comfyui, job_id, wait)
        if entry is None:
            return f'It is still rendering. Call get_job with job_id "{job_id}" to get it.'
        if comic := entry["prompt"][3].get("comic"):
            pictures = [await fetch(comfyui, entry["outputs"][f"{number}.save"]["images"][0])
                        for number in range(len(comic["panels"]))]
            return shown(compose(comic, pictures), "image/png")
        [clip] = entry["outputs"]["9"]["images"]
        return shown(await fetch(comfyui, clip), "image/webp")

    @mcp.tool(meta=VIEWER)
    async def video(
        prompt: str,
        seconds: Annotated[int, Field(ge=1, le=5)] = 2,
        resolution: Literal["480p", "720p"] = "480p",
    ):
        """Make a video: generate a short silent clip from a text prompt, at 832x480 or, only when asked, 1280x720. At 832x480 a 1 second clip takes about 2 minutes and a 2 second clip about 7; longer clips and 1280x720 take much longer. Returns the clip, or a job_id for get_job if it is still rendering. Calling it again while a clip renders returns that clip's job instead of starting another."""
        if running := await rendering_video(comfyui):
            return await result_or_pending(running)
        width, height = VIDEO_SIZES[resolution]
        workflow = json.loads(VIDEO_WORKFLOW.read_text())
        workflow["5"]["inputs"]["text"] = prompt
        workflow["7"]["inputs"].update(width=width, height=height, length=24 * seconds + 1)
        workflow["8"]["inputs"]["noise_seed"] = random.randrange(2**32)
        return await result_or_pending(await submit(comfyui, workflow))

    @mcp.tool(meta=VIEWER)
    async def comic(panels: Annotated[list[Panel], Field(min_length=1, max_length=6)], title: str | None = None):
        """Make an xkcd-style comic strip, or a meme in that style: black-and-white stick figures, with the dialogue lettered exactly as given in a handwriting font above each panel. Give each panel a scene, describing only what is drawn (who is there, where, doing what) and never any words, and its lines in speaking order. Use this rather than generate whenever a picture needs words. Each panel takes about a minute to draw. Returns the comic, or a job_id for get_job if it is still being drawn."""
        comic = {"panels": [panel.model_dump() for panel in panels], "title": title}
        return await result_or_pending(await submit(comfyui, comic_workflow(panels), comic=comic))

    @mcp.tool(meta=VIEWER)
    async def get_job(job_id: str):
        """Get a clip or comic that video or comic started, using the job_id it returned. It cannot start one: to make one, call video or comic."""
        if not (await queued(comfyui, job_id) or (await comfyui.get(f"/history/{job_id}")).json()):
            raise ComfyUIError(f'There is no job "{job_id}". Call video or comic to start one.')
        return await result_or_pending(job_id)

    return mcp


if __name__ == "__main__":
    comfyui = httpx.AsyncClient(base_url=os.environ["COMFYUI_URL"], timeout=60)
    build_server(comfyui, port=int(os.environ["MCP_PORT"])).run("streamable-http")
