import asyncio
import base64
import io
import json
import math
import os
import random
import secrets
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Annotated, Literal

import httpx
import PIL
import PIL.Image
import PIL.ImageDraw
import PIL.ImageFont
from mcp.server.fastmcp import FastMCP
from mcp.types import CallToolResult, TextContent
from pydantic import BaseModel, Field
from starlette.responses import JSONResponse

WORKFLOW = Path(__file__).parent / "workflows" / "z-image-turbo.api.json"
VIDEO_WORKFLOW = Path(__file__).parent / "workflows" / "wan2.2-t2v-14b.api.json"
TALK_WORKFLOW = Path(__file__).parent / "workflows" / "wan2.2-s2v-14b.json"
TALK_CHUNK_SECONDS = 77 / 16
TALK_CHUNKS = 2
ANIMATE_WORKFLOW = Path(__file__).parent / "workflows" / "wan2.2-i2v-14b.api.json"
COMIC_WORKFLOW = Path(__file__).parent / "workflows" / "qwen-image-2512-comic.json"
COMIC_STYLE = ("Black-and-white xkcd-style stick figure comic panel, simple thin black line art, "
               "plain white background, no text, no letters. ")
UPLOAD_LINK_SECONDS = 600
CUTOUT_WORKFLOW = Path(__file__).parent / "workflows" / "remove-background.json"
EDIT_WORKFLOW = Path(__file__).parent / "workflows" / "qwen-image-edit-2511.json"
LOGO_STYLE = ("A professional flat vector logo, solid flat colors, crisp clean edges, no gradients, no shadows, "
              "no photo, centered on a plain white background. ")
COMIC_FONT = Path(__file__).parent / "fonts" / "Humor-Sans.ttf"
COMIC_PANEL = 400
COMIC_PAD = 12
COMIC_LINE = 30
COMIC_GAP = 16
VIDEO_SIZES = {"480p": (832, 480), "720p": (1280, 720)}
ANIMATE_SIZES = {
    "480p": {"landscape": (832, 480), "portrait": (480, 832), "square": (640, 640)},
    "720p": {"landscape": (1280, 720), "portrait": (720, 1280), "square": (960, 960)},
}
SHOWN = "It is shown to the user above your reply. Do not embed it or link to it."
VIEWER = {"ui": {"resourceUri": "ui://comfyui/viewer"}}
VIEWER_PAGE = Path(__file__).parent / "viewer.html"

Side = Annotated[int, Field(ge=256, le=2048, multiple_of=16)]
Seconds = Annotated[int, Field(ge=1, le=5)]
Resolution = Literal["480p", "720p"]

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


def qwen_image_workflow(prompts):
    template = json.loads(COMIC_WORKFLOW.read_text())
    workflow = dict(template["shared"])
    for number, prompt in enumerate(prompts):
        def own(value):
            return [f"{number}.{value[0]}", value[1]] if isinstance(value, list) and value[0] in template["panel"] else value
        for key, node in template["panel"].items():
            workflow[f"{number}.{key}"] = {**node, "inputs": {name: own(value) for name, value in node["inputs"].items()}}
        workflow[f"{number}.positive"]["inputs"]["text"] = prompt
        workflow[f"{number}.sampler"]["inputs"]["seed"] = random.randrange(2**32)
    return workflow


def comic_workflow(panels):
    return qwen_image_workflow([COMIC_STYLE + panel.scene for panel in panels])


def logo_workflow(description, text):
    workflow = qwen_image_workflow([LOGO_STYLE + description + (f', with the text "{text}"' if text else "")])
    cutout = json.loads(CUTOUT_WORKFLOW.read_text())
    del workflow["0.save"], cutout["load"]
    cutout["mask"]["inputs"]["image"] = cutout["join"]["inputs"]["image"] = ["0.decode", 0]
    cutout["save"]["inputs"]["filename_prefix"] = "logo"
    return {**workflow, **cutout}


def edit_workflow(prompt, images):
    template = json.loads(EDIT_WORKFLOW.read_text())
    workflow = dict(template["shared"])
    for number, image in enumerate(images, start=1):
        workflow[f"{number}.load"] = {**template["image"]["load"], "inputs": {"image": image}}
        workflow[f"{number}.scale"] = {**template["image"]["scale"], "inputs": {"image": [f"{number}.load", 0]}}
        for encoder in ("positive", "negative"):
            workflow[encoder]["inputs"][f"image{number}"] = [f"{number}.scale", 0]
    workflow["positive"]["inputs"]["prompt"] = prompt
    workflow["sampler"]["inputs"]["seed"] = random.randrange(2**32)
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
                 if any(node["class_type"] in ("SaveAnimatedWEBP", "SaveVideo") for node in job[2].values())), None)


async def fetch(comfyui, file):
    response = await comfyui.get("/view", params=file)
    response.raise_for_status()
    return response.content


def image_id(image):
    return f"{image['filename']} [{image['type']}]"


def audio_extension(body):
    if body[:4] == b"RIFF" and body[8:12] == b"WAVE":
        return "wav"
    if body[4:8] == b"ftyp":
        return "m4a"
    if body[:3] == b"ID3" or (body[:1] == b"\xff" and body[1] & 0xE0 == 0xE0):
        return "mp3"
    return {b"OggS": "ogg", b"\x1a\x45\xdf\xa3": "webm", b"fLaC": "flac"}.get(body[:4])


def stored_file(image):
    name, _, kind = image.partition(" [")
    return {"filename": name, "subfolder": "", "type": kind.rstrip("]") or "input"}


def orientation(width, height):
    if width > height * 1.1:
        return "landscape"
    if height > width * 1.1:
        return "portrait"
    return "square"


async def store(comfyui, png, name):
    response = await comfyui.post("/upload/image", files={"image": (name, png, "image/png")},
                                  data={"overwrite": "true"})
    response.raise_for_status()
    stored = response.json()
    return image_id({"filename": stored["name"], "type": stored["type"]})


def encoded(data, mime_type, **fields):
    return {**fields, "mimeType": mime_type, "data": base64.b64encode(data).decode()}


def shown(data, mime_type, image=None, downloads=()):
    text = SHOWN if image is None else f'{SHOWN} To change it, pass its image_id "{image}" to edit.'
    return CallToolResult(
        content=[TextContent(type="text", text=text)],
        _meta={"image": encoded(data, mime_type), **({"downloads": list(downloads)} if downloads else {})},
    )


def traced_svg(png):
    with tempfile.TemporaryDirectory() as folder:
        picture, svg = Path(folder) / "logo.png", Path(folder) / "logo.svg"
        picture.write_bytes(png)
        subprocess.run([os.environ["VTRACER"], "--input", picture, "--output", svg], check=True, capture_output=True)
        return svg.read_bytes()


def probed_seconds(clip):
    with tempfile.NamedTemporaryFile() as file:
        file.write(clip)
        file.flush()
        probe = subprocess.run([os.environ["FFPROBE"], "-v", "error", "-show_entries", "format=duration",
                                "-of", "csv=p=0", file.name], check=True, capture_output=True, text=True)
    return float(probe.stdout)


def build_server(comfyui, wait=120, public_url="", clock=time.monotonic, vectorize=traced_svg,
                 audio_seconds=probed_seconds, **settings):
    mcp = FastMCP("comfyui", stateless_http=True, **settings)
    links = {}

    @mcp.tool()
    async def upload_link():
        """Get a single-use link that puts a picture or a voice clip the user attached into these tools. Run the returned command in the terminal with <file> replaced by the attachment's path (attachments are in the chat's working directory). It prints the picture's image_id, or the voice clip's audio_id, which the other tools take. Each link works once, for 10 minutes: get one per file."""
        token = secrets.token_urlsafe(32)
        links[token] = clock() + UPLOAD_LINK_SECONDS
        return f"curl -sf -T <file> {public_url}/upload/{token}"

    @mcp.custom_route("/upload/{token}", methods=["PUT"])
    async def receive_upload(request):
        token = request.path_params["token"]
        if links.pop(token, -math.inf) < clock():
            return JSONResponse({"error": "This link is unknown or already used. Call upload_link again."}, 403)
        body = await request.body()
        if extension := audio_extension(body):
            return JSONResponse({"audio_id": await store(comfyui, body, f"upload-{token}.{extension}")})
        try:
            picture = PIL.Image.open(io.BytesIO(body))
            png = io.BytesIO()
            picture.save(png, "PNG")
        except (PIL.UnidentifiedImageError, OSError):
            return JSONResponse({"error": "That file is neither a picture nor a voice clip."}, 400)
        return JSONResponse({"image_id": await store(comfyui, png.getvalue(), f"upload-{token}.png")})

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
        return shown(await fetch(comfyui, image), "image/png", image_id(image))

    async def clip_size(image, resolution):
        width, height = PIL.Image.open(io.BytesIO(await fetch(comfyui, stored_file(image)))).size
        return ANIMATE_SIZES[resolution][orientation(width, height)]

    async def result_or_pending(job_id):
        entry = await finished_within(comfyui, job_id, wait)
        if entry is None:
            return f'It is still rendering. Call get_job with job_id "{job_id}" to get it.'
        if comic := entry["prompt"][3].get("comic"):
            pictures = [await fetch(comfyui, entry["outputs"][f"{number}.save"]["images"][0])
                        for number in range(len(comic["panels"]))]
            strip = compose(comic, pictures)
            return shown(strip, "image/png", await store(comfyui, strip, f"comic-{job_id}.png"))
        if "save" in entry["outputs"]:
            [image] = entry["outputs"]["save"]["images"]
            png = await fetch(comfyui, image)
            if entry["prompt"][3].get("logo"):
                svg = await asyncio.to_thread(vectorize, png)
                return shown(png, "image/png", image_id(image), [encoded(png, "image/png", name="logo.png"),
                                                                 encoded(svg, "image/svg+xml", name="logo.svg")])
            return shown(png, "image/png", image_id(image), [encoded(png, "image/png", name=image["filename"])])
        [clip] = entry["outputs"]["9"]["images"]
        if clip["filename"].endswith(".mp4"):
            video = await fetch(comfyui, clip)
            return shown(video, "video/mp4", downloads=[encoded(video, "video/mp4", name=clip["filename"])])
        return shown(await fetch(comfyui, clip), "image/webp")

    @mcp.tool(meta=VIEWER)
    async def video(
        prompt: str,
        seconds: Seconds = 2,
        resolution: Resolution = "480p",
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
    async def edit(prompt: str, images: Annotated[list[str], Field(min_length=1, max_length=3)]):
        """Edit pictures by instruction: change the background, outfit, lighting or style, add or remove an object, restore or colorize an old photo, or combine pictures ("put the person in image 1 into the scene in image 2"). Pass up to 3 image_ids: one from a picture these tools made, or from upload_link for a picture the user attached. The result keeps the first picture's composition. Returns the picture and its new image_id, or a job_id for get_job if it is still rendering (about a minute)."""
        return await result_or_pending(await submit(comfyui, edit_workflow(prompt, images)))

    @mcp.tool(meta=VIEWER)
    async def remove_background(image: str):
        """Remove the background from a picture, leaving the subject on transparency: cutouts, stickers, product shots. Pass the image_id of a picture these tools made, or one from upload_link. Returns the transparent PNG, which the user can download, and its image_id."""
        workflow = json.loads(CUTOUT_WORKFLOW.read_text())
        workflow["load"]["inputs"]["image"] = image
        return await result_or_pending(await submit(comfyui, workflow))

    @mcp.tool(meta=VIEWER)
    async def logo(description: str, text: str | None = None):
        """Design a flat vector logo on a transparent background, offered to the user as a PNG and an SVG download. Describe the mark in description (subject, shapes, colors, mood) and pass any wording to text, which is drawn exactly. Takes about a minute; returns the logo and its image_id, or a job_id for get_job."""
        return await result_or_pending(await submit(comfyui, logo_workflow(description, text), logo=True))

    @mcp.tool(meta=VIEWER)
    async def animate(image: str, prompt: str, seconds: Seconds = 2, resolution: Resolution = "480p",
                      last_image: str | None = None):
        """Animate a picture into a short silent clip: pass its image_id (from a picture these tools made, or from upload_link) and describe the motion and camera, not the scene, which the picture already sets. Give last_image to move from the first picture to another, a transition; pass the same image_id as both for a seamless loop. The clip keeps the picture's orientation, at 480p or, only when asked, 720p. At 480p a 1 second clip takes about 2 minutes and a 2 second clip about 7. Returns the clip, or a job_id for get_job. Calling it while a clip renders returns that clip's job instead of starting another."""
        if running := await rendering_video(comfyui):
            return await result_or_pending(running)
        width, height = await clip_size(image, resolution)
        workflow = json.loads(ANIMATE_WORKFLOW.read_text())
        workflow["5"]["inputs"]["text"] = prompt
        workflow["16"]["inputs"]["image"] = image
        workflow["7"]["inputs"].update(width=width, height=height, length=24 * seconds + 1)
        if last_image:
            workflow["17"] = {"class_type": "LoadImage", "inputs": {"image": last_image}}
            workflow["7"]["class_type"] = "WanFirstLastFrameToVideo"
            workflow["7"]["inputs"]["end_image"] = ["17", 0]
        workflow["8"]["inputs"]["noise_seed"] = random.randrange(2**32)
        return await result_or_pending(await submit(comfyui, workflow))

    @mcp.tool(meta=VIEWER)
    async def talk(image: str, audio: str, prompt: str):
        """Make a talking head: the person in a picture speaks a voice clip, lip-synced, as a video with the sound. Pass the face picture's image_id, the voice clip's audio_id (both from upload_link, or the picture from these tools), and a short description of the scene and expression. The clip may be up to about 9.6 seconds; each 4.8 seconds takes several minutes. Returns the video, which the user can download, or a job_id for get_job. Calling it while a clip renders returns that clip's job instead of starting another."""
        if running := await rendering_video(comfyui):
            return await result_or_pending(running)
        seconds =await asyncio.to_thread(audio_seconds, await fetch(comfyui, stored_file(audio)))
        chunks = math.ceil(seconds / TALK_CHUNK_SECONDS)
        if chunks > TALK_CHUNKS:
            raise ComfyUIError(f"The voice clip is {seconds:.1f} s; talk takes about "
                               f"{TALK_CHUNKS * TALK_CHUNK_SECONDS:.1f} s at most. Trim the clip.")
        template = json.loads(TALK_WORKFLOW.read_text())
        workflow = template["shared"]
        if chunks == 2:
            workflow.update(template["extend"])
            workflow["first"]["inputs"]["samples"] = workflow["doubled"]["inputs"]["samples2"] = ["joined", 0]
            workflow["extend_sampler"]["inputs"]["seed"] = random.randrange(2**32)
        workflow["trimmed"]["inputs"].update(batch_index=chunks,
                                             length=round(seconds * workflow["video"]["inputs"]["fps"]))
        workflow["face"]["inputs"]["image"] = image
        width, height = await clip_size(image, "480p")
        workflow["sound"]["inputs"].update(width=width, height=height)
        workflow["voice"]["inputs"]["audio"] = stored_file(audio)["filename"]
        workflow["positive"]["inputs"]["text"] = prompt
        workflow["sampler"]["inputs"]["seed"] = random.randrange(2**32)
        return await result_or_pending(await submit(comfyui, workflow))

    @mcp.tool(meta=VIEWER)
    async def get_job(job_id: str):
        """Get a result that another tool (video, animate, comic, edit, logo, remove_background) started, using the job_id it returned. It cannot start one: to make one, call that tool."""
        if not (await queued(comfyui, job_id) or (await comfyui.get(f"/history/{job_id}")).json()):
            raise ComfyUIError(f'There is no job "{job_id}". Call video, animate, comic, edit or logo to start one.')
        return await result_or_pending(job_id)

    return mcp


if __name__ == "__main__":
    comfyui = httpx.AsyncClient(base_url=os.environ["COMFYUI_URL"], timeout=60)
    build_server(comfyui, public_url=os.environ["PUBLIC_URL"], port=int(os.environ["MCP_PORT"])).run("streamable-http")
