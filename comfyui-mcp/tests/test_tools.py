import base64
import json

import httpx
import pytest
from mcp.shared.memory import create_connected_server_and_client_session

from server import build_server

pytestmark = pytest.mark.anyio


@pytest.fixture
def anyio_backend():
    return "asyncio"


def fake_comfyui(handler):
    return httpx.AsyncClient(base_url="http://comfyui", transport=httpx.MockTransport(handler))


async def call(comfyui, tool, arguments, **settings):
    server = build_server(comfyui, **settings)
    async with create_connected_server_and_client_session(server._mcp_server) as client:
        return await client.call_tool(tool, arguments)


async def call_generate(comfyui, **arguments):
    return await call(comfyui, "generate", {"prompt": "a red apple", **arguments})


async def test_a_size_beyond_the_workflow_bounds_is_refused():
    submitted = []
    comfyui = fake_comfyui(lambda request: submitted.append(request) or httpx.Response(500))

    result = await call_generate(comfyui, width=4096, height=1024)

    assert result.isError
    assert "width" in result.content[0].text
    assert submitted == []


async def test_a_failed_run_is_reported_with_comfyuis_error():
    def comfyui(request):
        if request.url.path == "/prompt":
            return httpx.Response(200, json={"prompt_id": "p1"})
        return httpx.Response(200, json={"p1": {
            "status": {"status_str": "error", "messages": [
                ["execution_error", {"exception_message": "HIP out of memory"}],
            ]},
            "outputs": {},
        }})

    result = await call_generate(fake_comfyui(comfyui))

    assert result.isError
    assert "HIP out of memory" in result.content[0].text


async def test_the_generated_image_is_returned_as_image_content():
    png = b"\x89PNG\r\n\x1a\nimage bytes"

    def comfyui(request):
        if request.url.path == "/prompt":
            return httpx.Response(200, json={"prompt_id": "p1"})
        if request.url.path == "/history/p1":
            return httpx.Response(200, json={"p1": {
                "status": {"status_str": "success", "messages": []},
                "outputs": {"10": {"images": [{"filename": "mcp_00001_.png", "subfolder": "", "type": "output"}]}},
            }})
        if dict(request.url.params) == {"filename": "mcp_00001_.png", "subfolder": "", "type": "output"}:
            return httpx.Response(200, content=png)
        return httpx.Response(404)

    result = await call_generate(fake_comfyui(comfyui))

    assert not result.isError
    [note, image] = result.content
    assert "already shown to the user" in note.text
    assert image.type == "image"
    assert image.mimeType == "image/png"
    assert base64.b64decode(image.data) == png


async def test_a_video_longer_than_the_bounds_is_refused():
    submitted = []
    comfyui = fake_comfyui(lambda request: submitted.append(request) or httpx.Response(500))

    result = await call(comfyui, "video", {"prompt": "waves", "seconds": 30})

    assert result.isError
    assert "seconds" in result.content[0].text
    assert submitted == []


WEBP = b"RIFF\x00\x00\x00\x00WEBPVP8X animated"


def finished_clip(request):
    if request.url.path == "/prompt":
        return httpx.Response(200, json={"prompt_id": "v1"})
    if request.url.path == "/history/v1":
        return httpx.Response(200, json={"v1": {
            "status": {"status_str": "success", "messages": []},
            "outputs": {"9": {"images": [{"filename": "clip_00001_.webp", "subfolder": "", "type": "output"}],
                              "animated": [True]}},
        }})
    if dict(request.url.params) == {"filename": "clip_00001_.webp", "subfolder": "", "type": "output"}:
        return httpx.Response(200, content=WEBP)
    return httpx.Response(404)


async def test_a_clip_finished_within_the_wait_is_returned_as_an_animated_webp():
    submitted = []

    def comfyui(request):
        if request.url.path == "/prompt":
            submitted.append(json.loads(request.content)["prompt"])
        return finished_clip(request)

    result = await call(fake_comfyui(comfyui), "video", {"prompt": "waves", "width": 256, "height": 256})

    [latent] = [node["inputs"] for node in submitted[0].values() if node["class_type"] == "Wan22ImageToVideoLatent"]
    assert (latent["width"], latent["height"]) == (1280, 704)
    assert not result.isError
    [note, clip] = result.content
    assert "already shown to the user" in note.text
    assert clip.mimeType == "image/webp"
    assert base64.b64decode(clip.data) == WEBP


async def test_a_clip_still_running_returns_its_job_which_get_job_returns_when_done():
    done = False

    def comfyui(request):
        if request.url.path == "/queue":
            return httpx.Response(200, json={"queue_running": [[0, "v1", {}, {}, ["9"]]], "queue_pending": []})
        if request.url.path == "/history/v1" and not done:
            return httpx.Response(200, json={})
        return finished_clip(request)

    started = await call(fake_comfyui(comfyui), "video", {"prompt": "waves"}, wait=0)
    assert not started.isError
    assert "v1" in started.content[0].text

    rendering = await call(fake_comfyui(comfyui), "get_job", {"job_id": "v1"}, wait=0)
    assert not rendering.isError
    assert "still rendering" in rendering.content[0].text

    done = True
    result = await call(fake_comfyui(comfyui), "get_job", {"job_id": "v1"}, wait=0)

    assert result.content[1].mimeType == "image/webp"


async def test_a_job_comfyui_never_ran_is_refused_so_the_model_starts_one_with_video():
    def comfyui(request):
        if request.url.path == "/queue":
            return httpx.Response(200, json={"queue_running": [], "queue_pending": []})
        return httpx.Response(200, json={})

    result = await call(fake_comfyui(comfyui), "get_job", {"job_id": "made-up"}, wait=0)

    assert result.isError
    assert "video" in result.content[0].text
