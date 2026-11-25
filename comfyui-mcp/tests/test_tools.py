import base64
import io
import json
import re

import httpx
import PIL.Image
import PIL.ImageDraw
import pytest
from mcp.shared.memory import create_connected_server_and_client_session

from server import VIDEO_WORKFLOW, WORKFLOW, build_server

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


async def test_every_tool_that_returns_a_picture_shows_it_in_the_viewer():
    server = build_server(fake_comfyui(lambda request: httpx.Response(500)))
    async with create_connected_server_and_client_session(server._mcp_server) as client:
        tools = (await client.list_tools()).tools

    assert {tool.name: (tool.meta or {}).get("ui", {}).get("resourceUri") for tool in tools} == {
        **{name: "ui://comfyui/viewer" for name in ("generate", "video", "comic", "edit", "get_job")},
        "upload_link": None}


async def test_the_viewer_is_served_as_an_mcp_app():
    server = build_server(fake_comfyui(lambda request: httpx.Response(500)))
    async with create_connected_server_and_client_session(server._mcp_server) as client:
        [viewer] = (await client.read_resource("ui://comfyui/viewer")).contents

    assert viewer.mimeType == "text/html;profile=mcp-app"
    assert viewer.text.startswith("<!doctype html>")


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


async def test_the_generated_image_goes_to_the_viewer_and_the_model_is_told_it_is_shown():
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
    [note] = result.content
    assert "shown to the user" in note.text
    assert 'image_id "mcp_00001_.png [output]"' in note.text
    assert result.meta["image"]["mimeType"] == "image/png"
    assert base64.b64decode(result.meta["image"]["data"]) == png


async def test_a_video_longer_than_the_bounds_is_refused():
    submitted = []
    comfyui = fake_comfyui(lambda request: submitted.append(request) or httpx.Response(500))

    result = await call(comfyui, "video", {"prompt": "waves", "seconds": 30})

    assert result.isError
    assert "seconds" in result.content[0].text
    assert submitted == []


async def test_a_resolution_wan_was_not_trained_at_is_refused():
    submitted = []
    comfyui = fake_comfyui(lambda request: submitted.append(request) or httpx.Response(500))

    result = await call(comfyui, "video", {"prompt": "waves", "resolution": "4k"})

    assert result.isError
    assert "resolution" in result.content[0].text
    assert submitted == []


WEBP = b"RIFF\x00\x00\x00\x00WEBPVP8X animated"


def finished_clip(request):
    if request.url.path == "/queue":
        return httpx.Response(200, json={"queue_running": [], "queue_pending": []})
    if request.url.path == "/prompt":
        return httpx.Response(200, json={"prompt_id": "v1"})
    if request.url.path == "/history/v1":
        return httpx.Response(200, json={"v1": {
            "status": {"status_str": "success", "messages": []},
            "prompt": [0, "v1", {}, {}, ["9"]],
            "outputs": {"9": {"images": [{"filename": "clip_00001_.webp", "subfolder": "", "type": "output"}],
                              "animated": [True]}},
        }})
    if dict(request.url.params) == {"filename": "clip_00001_.webp", "subfolder": "", "type": "output"}:
        return httpx.Response(200, content=WEBP)
    return httpx.Response(404)


async def test_a_clip_finished_within_the_wait_goes_to_the_viewer_as_an_animated_webp():
    submitted = []

    def comfyui(request):
        if request.url.path == "/prompt":
            submitted.append(json.loads(request.content)["prompt"])
        return finished_clip(request)

    result = await call(fake_comfyui(comfyui), "video", {"prompt": "waves", "width": 256, "height": 256})
    await call(fake_comfyui(comfyui), "video", {"prompt": "waves", "resolution": "720p"})

    sizes = [(node["inputs"]["width"], node["inputs"]["height"])
             for workflow in submitted for node in workflow.values() if node["class_type"] == "EmptyHunyuanLatentVideo"]
    assert sizes == [(832, 480), (1280, 720)]
    assert not result.isError
    [note] = result.content
    assert "shown to the user" in note.text
    assert result.meta["image"]["mimeType"] == "image/webp"
    assert base64.b64decode(result.meta["image"]["data"]) == WEBP


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

    assert result.meta["image"]["mimeType"] == "image/webp"


async def test_a_retried_video_returns_the_clip_already_rendering_instead_of_starting_another():
    posted = []

    def comfyui(request):
        if request.url.path == "/queue":
            running = json.loads(VIDEO_WORKFLOW.read_text())
            return httpx.Response(200, json={"queue_running": [[0, "v1", running, {}, ["9"]]], "queue_pending": []})
        if request.url.path == "/prompt":
            posted.append(request)
        return finished_clip(request)

    result = await call(fake_comfyui(comfyui), "video", {"prompt": "waves"})

    assert posted == []
    assert result.meta["image"]["mimeType"] == "image/webp"


async def test_an_image_being_generated_does_not_stop_a_video_from_starting():
    posted = []

    def comfyui(request):
        if request.url.path == "/queue":
            image = json.loads(WORKFLOW.read_text())
            return httpx.Response(200, json={"queue_running": [[0, "i1", image, {}, ["10"]]], "queue_pending": []})
        if request.url.path == "/prompt":
            posted.append(request)
        return finished_clip(request)

    await call(fake_comfyui(comfyui), "video", {"prompt": "waves"})

    assert len(posted) == 1


def panel(scene="two stick figures at a whiteboard", *lines):
    return {"scene": scene, "lines": [{"speaker": speaker, "text": text} for speaker, text in lines]}


async def test_a_comic_with_no_panels_or_more_than_six_is_refused():
    submitted = []
    comfyui = fake_comfyui(lambda request: submitted.append(request) or httpx.Response(500))

    for panels in ([], [panel()] * 7):
        result = await call(comfyui, "comic", {"panels": panels})
        assert result.isError
        assert "panels" in result.content[0].text
    assert submitted == []


async def test_a_comic_is_one_job_drawing_each_scene_without_its_dialogue():
    submitted = []

    def comfyui(request):
        if request.url.path == "/prompt":
            submitted.append(json.loads(request.content))
            return httpx.Response(200, json={"prompt_id": "c1"})
        return httpx.Response(200, json={})

    panels = [panel("an engineer at a laptop", ("ENGINEER", "Is it working?")),
              panel("a coworker shrugging", ("COWORKER", "It's always DNS."))]
    await call(fake_comfyui(comfyui), "comic", {"panels": panels}, wait=0)

    [job] = submitted
    samplers = [node["inputs"] for node in job["prompt"].values() if node["class_type"] == "KSampler"]
    prompts = [job["prompt"][sampler["positive"][0]]["inputs"]["text"] for sampler in samplers]
    seeds = {sampler["seed"] for sampler in samplers}
    assert [prompt.endswith(scene) and "xkcd" in prompt for prompt, scene in
            zip(prompts, ["an engineer at a laptop", "a coworker shrugging"])] == [True, True]
    assert not any("DNS" in prompt for prompt in prompts)
    assert len(seeds) == 2
    assert job["extra_data"]["comic"]["panels"] == panels


def drawn_panel():
    picture = PIL.Image.new("RGB", (1024, 1024), "white")
    PIL.ImageDraw.Draw(picture).ellipse((400, 300, 600, 500), outline="black", width=8)
    file = io.BytesIO()
    picture.save(file, "PNG")
    return file.getvalue()


def comfyui_drawing_comics(done=lambda: True, stored=None):
    jobs = {}
    stored = [] if stored is None else stored

    def comfyui(request):
        if request.url.path == "/prompt":
            body = json.loads(request.content)
            jobs["c1"] = body
            return httpx.Response(200, json={"prompt_id": "c1"})
        if request.url.path == "/queue":
            return httpx.Response(200, json={"queue_running": [], "queue_pending": []})
        if request.url.path == "/history/c1" and not done():
            return httpx.Response(200, json={})
        if request.url.path == "/history/c1":
            body = jobs["c1"]
            saves = [key for key, node in body["prompt"].items() if node["class_type"] == "SaveImage"]
            return httpx.Response(200, json={"c1": {
                "status": {"status_str": "success", "messages": []},
                "prompt": [0, "c1", body["prompt"], body["extra_data"], saves],
                "outputs": {key: {"images": [{"filename": f"{key}.png", "subfolder": "", "type": "output"}]}
                            for key in saves},
            }})
        if request.url.path == "/view":
            return httpx.Response(200, content=drawn_panel())
        if request.url.path == "/upload/image":
            stored.append(request.content)
            return httpx.Response(200, json={"name": "comic-c1.png", "subfolder": "", "type": "input"})
        return httpx.Response(404)

    return fake_comfyui(comfyui)


async def draw_comic(*panels, **arguments):
    result = await call(comfyui_drawing_comics(), "comic", {"panels": list(panels), **arguments})
    assert not result.isError, result.content[0].text
    assert result.meta["image"]["mimeType"] == "image/png"
    return PIL.Image.open(io.BytesIO(base64.b64decode(result.meta["image"]["data"])))


async def test_a_comic_lays_its_panels_in_rows_of_three_with_the_dialogue_lettered_above_them():
    talking = panel("two stick figures", ("ALICE", "Is it working?"))

    one = await draw_comic(talking)
    two = await draw_comic(talking, talking)
    three = await draw_comic(talking, talking, talking)
    four = await draw_comic(talking, talking, talking, talking)
    silent = await draw_comic(panel("two stick figures"))

    assert one.width < two.width < three.width == four.width
    assert three.height < four.height
    assert silent.height < one.height


async def test_a_comic_still_being_drawn_returns_its_job_which_get_job_returns_when_done():
    drawn = []
    comfyui = comfyui_drawing_comics(done=lambda: bool(drawn))
    started = await call(comfyui, "comic", {"panels": [panel()]}, wait=0)
    assert "c1" in started.content[0].text

    drawn.append(True)
    result = await call(comfyui, "get_job", {"job_id": "c1"}, wait=0)

    assert not result.isError, result.content[0].text
    assert result.meta["image"]["mimeType"] == "image/png"


async def test_a_comic_is_stored_so_it_can_be_edited_by_its_image_id():
    stored = []
    result = await call(comfyui_drawing_comics(stored=stored), "comic", {"panels": [panel()]})

    assert len(stored) == 1
    assert 'image_id "comic-c1.png [input]"' in result.content[0].text


async def test_a_title_is_lettered_above_the_panels():
    untitled = await draw_comic(panel())
    titled = await draw_comic(panel(), title="Debugging")

    assert titled.height > untitled.height


async def test_a_line_too_long_for_its_panel_wraps_instead_of_running_off_it():
    short = await draw_comic(panel("a stick figure", ("ALICE", "Hi.")))
    long = await draw_comic(panel("a stick figure", ("ALICE", "I have been debugging this for six hours " * 3)))

    assert long.width == short.width
    assert long.height > short.height


async def test_a_job_comfyui_never_ran_is_refused_so_the_model_starts_one_with_video():
    def comfyui(request):
        if request.url.path == "/queue":
            return httpx.Response(200, json={"queue_running": [], "queue_pending": []})
        return httpx.Response(200, json={})

    result = await call(fake_comfyui(comfyui), "get_job", {"job_id": "made-up"}, wait=0)

    assert result.isError
    assert "video" in result.content[0].text


async def test_an_upload_link_is_a_command_putting_the_file_on_the_public_host():
    result = await call(fake_comfyui(lambda request: httpx.Response(500)), "upload_link", {},
                        public_url="https://comfy.example.com")

    command = result.content[0].text
    assert re.search(r"curl -sf -T <file> https://comfy\.example\.com/upload/[\w-]{40,}", command)


def comfyui_storing_uploads(stored):
    def comfyui(request):
        if request.url.path == "/upload/image":
            stored.append(request.content)
            name = re.search(rb'filename="([^"]+)"', request.content).group(1).decode()
            return httpx.Response(200, json={"name": name, "subfolder": "", "type": "input"})
        return httpx.Response(404)

    return fake_comfyui(comfyui)


async def upload_path(server):
    async with create_connected_server_and_client_session(server._mcp_server) as client:
        command = (await client.call_tool("upload_link", {})).content[0].text
    return re.search(r"https://comfy\.example\.com(/upload/\S+)", command).group(1)


async def put(server, path, body):
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=server.streamable_http_app()),
                                 base_url="https://comfy.example.com") as terminal:
        return await terminal.put(path, content=body)


def server_storing_uploads(stored, **settings):
    return build_server(comfyui_storing_uploads(stored), public_url="https://comfy.example.com", **settings)


async def test_an_uploaded_picture_is_stored_in_comfyui_and_named_by_its_image_id_once():
    stored = []
    server = server_storing_uploads(stored)
    path = await upload_path(server)

    response = await put(server, path, drawn_panel())
    reused = await put(server, path, drawn_panel())

    assert response.status_code == 200
    assert re.fullmatch(r"upload-[\w-]+\.png \[input\]", response.json()["image_id"])
    assert reused.status_code == 403
    assert len(stored) == 1


async def test_an_upload_to_a_made_up_link_or_of_something_not_a_picture_is_refused():
    stored = []
    server = server_storing_uploads(stored)

    not_a_picture = await put(server, await upload_path(server), b"#!/bin/sh\nrm -rf /\n")
    made_up = await put(server, "/upload/made-up", drawn_panel())

    assert not_a_picture.status_code == 400
    assert made_up.status_code == 403
    assert stored == []


async def test_an_upload_link_older_than_ten_minutes_is_refused():
    now = [0.0]
    stored = []
    server = server_storing_uploads(stored, clock=lambda: now[0])
    path = await upload_path(server)

    now[0] = 601
    response = await put(server, path, drawn_panel())

    assert response.status_code == 403
    assert stored == []


async def test_an_edit_of_no_image_or_more_than_three_is_refused():
    submitted = []
    comfyui = fake_comfyui(lambda request: submitted.append(request) or httpx.Response(500))

    for images in ([], ["a.png"] * 4):
        result = await call(comfyui, "edit", {"prompt": "make it blue", "images": images})
        assert result.isError
        assert "images" in result.content[0].text
    assert submitted == []


async def test_an_edit_is_one_job_loading_every_image_it_names_beside_the_instruction():
    submitted = []

    def comfyui(request):
        if request.url.path == "/prompt":
            submitted.append(json.loads(request.content)["prompt"])
            return httpx.Response(200, json={"prompt_id": "e1"})
        return httpx.Response(200, json={})

    images = ["mcp_00012_.png [output]", "upload-abc.png"]
    await call(fake_comfyui(comfyui), "edit", {"prompt": "put the cat on the sofa", "images": images}, wait=0)
    await call(fake_comfyui(comfyui), "edit", {"prompt": "put the cat on the sofa", "images": images}, wait=0)

    first, second = submitted
    encoder = next(node["inputs"] for node in first.values() if node["class_type"] == "TextEncodeQwenImageEditPlus"
                   and node["inputs"]["prompt"])
    loaded = [first[encoder[f"image{n}"][0]] for n in (1, 2)]
    assert encoder["prompt"] == "put the cat on the sofa"
    assert [first[node["inputs"]["image"][0]]["inputs"]["image"] for node in loaded] == images
    seeds = [next(node["inputs"]["seed"] for node in job.values() if node["class_type"] == "KSampler")
             for job in submitted]
    assert seeds[0] != seeds[1]


async def test_a_finished_edit_goes_to_the_viewer_and_names_its_image_id_for_the_next_edit():
    def comfyui(request):
        if request.url.path == "/prompt":
            return httpx.Response(200, json={"prompt_id": "e1"})
        if request.url.path == "/history/e1":
            return httpx.Response(200, json={"e1": {
                "status": {"status_str": "success", "messages": []},
                "prompt": [0, "e1", {}, {}, ["save"]],
                "outputs": {"save": {"images": [{"filename": "edit_00001_.png", "subfolder": "", "type": "output"}]}},
            }})
        if request.url.path == "/view":
            return httpx.Response(200, content=drawn_panel())
        return httpx.Response(404)

    result = await call(fake_comfyui(comfyui), "edit", {"prompt": "make it blue", "images": ["a.png"]})

    assert not result.isError, result.content[0].text
    assert result.meta["image"]["mimeType"] == "image/png"
    assert 'image_id "edit_00001_.png [output]"' in result.content[0].text
