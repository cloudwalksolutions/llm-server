import base64
import io
import json
import re
import wave

import httpx
import PIL.Image
import PIL.ImageDraw
import pytest
from mcp.shared.memory import create_connected_server_and_client_session

from server import VIDEO_WORKFLOW, WORKFLOW, build_server

pytestmark = pytest.mark.anyio

PUBLIC_URL = "https://comfy.example.com"
WEBP = b"RIFF\x00\x00\x00\x00WEBPVP8X animated"
MP4 = b"\x00\x00\x00\x20ftypisom video with sound"


@pytest.fixture
def anyio_backend():
    return "asyncio"


def picture(width=1024, height=1024):
    drawn = PIL.Image.new("RGB", (width, height), "white")
    PIL.ImageDraw.Draw(drawn).ellipse((width // 3, height // 3, width // 2, height // 2), outline="black", width=8)
    file = io.BytesIO()
    drawn.save(file, "PNG")
    return file.getvalue()


def voice(seconds):
    file = io.BytesIO()
    with wave.open(file, "wb") as clip:
        clip.setnchannels(1)
        clip.setsampwidth(2)
        clip.setframerate(16000)
        clip.writeframes(b"\0\0" * 16000 * seconds)
    return file.getvalue()


class FakeComfyUI:
    def __init__(self, picture=picture(), running=(), finished=True, error=None):
        self.picture = picture
        self.running = [[0, job_id, workflow, {}, []] for job_id, workflow in running]
        self.finished = finished
        self.error = error
        self.jobs = {}
        self.stored = []
        self.client = httpx.AsyncClient(base_url="http://comfyui", transport=httpx.MockTransport(self.answer))

    @property
    def submitted(self):
        return [job["prompt"] for job in self.jobs.values()]

    @property
    def job(self):
        [job] = self.submitted
        return job

    def answer(self, request):
        path = request.url.path
        if path == "/prompt":
            job_id = f"job-{len(self.jobs) + 1}"
            self.jobs[job_id] = json.loads(request.content)
            return httpx.Response(200, json={"prompt_id": job_id})
        if path == "/queue":
            waiting = [[0, job_id, job["prompt"], {}, []] for job_id, job in self.jobs.items() if not self.finished]
            return httpx.Response(200, json={"queue_running": self.running + waiting, "queue_pending": []})
        if path.startswith("/history/"):
            job_id = path.removeprefix("/history/")
            if job_id not in self.jobs or not self.finished:
                return httpx.Response(200, json={})
            return httpx.Response(200, json={job_id: self.history(job_id)})
        if path == "/view":
            extension = request.url.params["filename"].rsplit(".", 1)[-1]
            return httpx.Response(200, content={"webp": WEBP, "mp4": MP4}.get(extension, self.picture))
        if path == "/upload/image":
            self.stored.append(request.content)
            name = re.search(rb'filename="([^"]+)"', request.content).group(1).decode()
            return httpx.Response(200, json={"name": name, "subfolder": "", "type": "input"})
        return httpx.Response(404)

    def history(self, job_id):
        job = self.jobs[job_id]
        if self.error:
            return {"status": {"status_str": "error", "messages": [["execution_error", {"exception_message": self.error}]]},
                    "outputs": {}}
        saves = {key: node for key, node in job["prompt"].items() if node["class_type"].startswith("Save")}
        return {
            "status": {"status_str": "success", "messages": []},
            "prompt": [0, job_id, job["prompt"], job.get("extra_data", {}), list(saves)],
            "outputs": {key: {"images": [{"filename": saved_name(node), "subfolder": "", "type": "output"}]}
                        for key, node in saves.items()},
        }


def saved_name(node):
    extension = {"SaveAnimatedWEBP": "webp", "SaveVideo": "mp4"}.get(node["class_type"], "png")
    return f"{node['inputs']['filename_prefix']}_00001_.{extension}"


def nodes_of(job, class_type):
    return [node["inputs"] for node in job.values() if node["class_type"] == class_type]


def source(job, link):
    return job[link[0]]


async def call(tool, arguments, comfyui=None, **settings):
    server = build_server((comfyui or FakeComfyUI()).client, wait=0, **settings)
    async with create_connected_server_and_client_session(server._mcp_server) as client:
        return await client.call_tool(tool, arguments)


def text(result):
    return result.content[0].text


def shown(result):
    assert not result.isError, text(result)
    return result.meta["image"]["mimeType"], base64.b64decode(result.meta["image"]["data"])


def downloads(result):
    return [(file["name"], file["mimeType"], base64.b64decode(file["data"])) for file in result.meta["downloads"]]


def refused(result, argument):
    return result.isError and argument in text(result)


async def test_every_tool_that_returns_a_picture_shows_it_in_the_viewer():
    server = build_server(FakeComfyUI().client)

    async with create_connected_server_and_client_session(server._mcp_server) as client:
        tools = (await client.list_tools()).tools

    assert {tool.name: (tool.meta or {}).get("ui", {}).get("resourceUri") for tool in tools} == {
        **{name: "ui://comfyui/viewer"
           for name in ("generate", "video", "comic", "edit", "remove_background", "logo", "animate", "talk",
                        "get_job")},
        "upload_link": None}


async def test_the_viewer_is_served_as_an_mcp_app():
    server = build_server(FakeComfyUI().client)

    async with create_connected_server_and_client_session(server._mcp_server) as client:
        [viewer] = (await client.read_resource("ui://comfyui/viewer")).contents

    assert viewer.mimeType == "text/html;profile=mcp-app"
    assert viewer.text.startswith("<!doctype html>")


async def test_a_size_beyond_the_workflow_bounds_is_refused():
    comfyui = FakeComfyUI()

    result = await call("generate", {"prompt": "a red apple", "width": 4096}, comfyui)

    assert refused(result, "width")
    assert comfyui.submitted == []


async def test_a_failed_run_is_reported_with_comfyuis_error():
    comfyui = FakeComfyUI(error="HIP out of memory")

    result = await call("generate", {"prompt": "a red apple"}, comfyui)

    assert refused(result, "HIP out of memory")


async def test_the_generated_image_goes_to_the_viewer_and_the_model_is_told_its_image_id():
    comfyui = FakeComfyUI()

    result = await call("generate", {"prompt": "a red apple"}, comfyui)

    assert shown(result) == ("image/png", comfyui.picture)
    assert "shown to the user" in text(result)
    assert 'image_id "mcp_00001_.png [output]"' in text(result)


async def test_a_video_outside_the_bounds_is_refused():
    comfyui = FakeComfyUI()

    too_long = await call("video", {"prompt": "waves", "seconds": 30}, comfyui)
    too_sharp = await call("video", {"prompt": "waves", "resolution": "4k"}, comfyui)

    assert refused(too_long, "seconds")
    assert refused(too_sharp, "resolution")
    assert comfyui.submitted == []


async def test_a_finished_clip_goes_to_the_viewer_as_an_animated_webp_at_the_asked_resolution():
    comfyui = FakeComfyUI()

    default = await call("video", {"prompt": "waves"}, comfyui)
    await call("video", {"prompt": "waves", "resolution": "720p"}, comfyui)

    assert shown(default) == ("image/webp", WEBP)
    assert [(latent["width"], latent["height"]) for job in comfyui.submitted
            for latent in nodes_of(job, "EmptyHunyuanLatentVideo")] == [(832, 480), (1280, 720)]


async def test_a_clip_still_rendering_returns_its_job_which_get_job_returns_when_done():
    comfyui = FakeComfyUI(finished=False)

    started = await call("video", {"prompt": "waves"}, comfyui)
    rendering = await call("get_job", {"job_id": "job-1"}, comfyui)
    comfyui.finished = True
    done = await call("get_job", {"job_id": "job-1"}, comfyui)

    assert 'job_id "job-1"' in text(started)
    assert "still rendering" in text(rendering)
    assert shown(done) == ("image/webp", WEBP)


async def test_a_retried_video_returns_the_clip_already_rendering_instead_of_starting_another():
    comfyui = FakeComfyUI(running=[("v1", json.loads(VIDEO_WORKFLOW.read_text()))], finished=False)

    result = await call("video", {"prompt": "waves"}, comfyui)

    assert comfyui.submitted == []
    assert 'job_id "v1"' in text(result)


async def test_an_image_being_generated_does_not_stop_a_video_from_starting():
    comfyui = FakeComfyUI(running=[("i1", json.loads(WORKFLOW.read_text()))])

    await call("video", {"prompt": "waves"}, comfyui)

    assert len(comfyui.submitted) == 1


async def test_a_job_comfyui_never_ran_is_refused_so_the_model_starts_one():
    result = await call("get_job", {"job_id": "made-up"})

    assert refused(result, "video")


def panel(scene="two stick figures at a whiteboard", *lines):
    return {"scene": scene, "lines": [{"speaker": speaker, "text": text} for speaker, text in lines]}


async def draw_comic(*panels, **arguments):
    mime_type, png = shown(await call("comic", {"panels": list(panels), **arguments}))
    assert mime_type == "image/png"
    return PIL.Image.open(io.BytesIO(png))


async def test_a_comic_with_no_panels_or_more_than_six_is_refused():
    comfyui = FakeComfyUI()

    empty = await call("comic", {"panels": []}, comfyui)
    crowded = await call("comic", {"panels": [panel()] * 7}, comfyui)

    assert refused(empty, "panels")
    assert refused(crowded, "panels")
    assert comfyui.submitted == []


async def test_a_comic_is_one_job_drawing_each_scene_without_its_dialogue():
    comfyui = FakeComfyUI(finished=False)
    panels = [panel("an engineer at a laptop", ("ENGINEER", "Is it working?")),
              panel("a coworker shrugging", ("COWORKER", "It's always DNS."))]

    await call("comic", {"panels": panels}, comfyui)

    samplers = nodes_of(comfyui.job, "KSampler")
    prompts = [source(comfyui.job, sampler["positive"])["inputs"]["text"] for sampler in samplers]
    assert [prompt.split(". ")[-1] for prompt in prompts] == ["an engineer at a laptop", "a coworker shrugging"]
    assert all("xkcd" in prompt and "DNS" not in prompt for prompt in prompts)
    assert len({sampler["seed"] for sampler in samplers}) == 2
    assert comfyui.jobs["job-1"]["extra_data"]["comic"]["panels"] == panels


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


async def test_a_title_is_lettered_above_the_panels():
    untitled = await draw_comic(panel())
    titled = await draw_comic(panel(), title="Debugging")

    assert titled.height > untitled.height


async def test_a_line_too_long_for_its_panel_wraps_instead_of_running_off_it():
    short = await draw_comic(panel("a stick figure", ("ALICE", "Hi.")))
    long = await draw_comic(panel("a stick figure", ("ALICE", "I have been debugging this for six hours " * 3)))

    assert long.width == short.width
    assert long.height > short.height


async def test_a_comic_still_being_drawn_returns_its_job_which_get_job_returns_when_done():
    comfyui = FakeComfyUI(finished=False)

    started = await call("comic", {"panels": [panel()]}, comfyui)
    comfyui.finished = True
    done = await call("get_job", {"job_id": "job-1"}, comfyui)

    assert 'job_id "job-1"' in text(started)
    assert shown(done)[0] == "image/png"


async def test_a_comic_is_stored_so_it_can_be_edited_by_its_image_id():
    comfyui = FakeComfyUI()

    result = await call("comic", {"panels": [panel()]}, comfyui)

    assert len(comfyui.stored) == 1
    assert 'image_id "comic-job-1.png [input]"' in text(result)


async def upload_path(server):
    async with create_connected_server_and_client_session(server._mcp_server) as client:
        command = text(await client.call_tool("upload_link", {}))
    return re.search(rf"{re.escape(PUBLIC_URL)}(/upload/\S+)", command).group(1)


async def put(server, path, body):
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=server.streamable_http_app()),
                                 base_url=PUBLIC_URL) as terminal:
        return await terminal.put(path, content=body)


async def test_an_upload_link_is_a_command_putting_the_file_on_the_public_host():
    result = await call("upload_link", {}, public_url=PUBLIC_URL)

    assert re.search(rf"curl -sf -T <file> {re.escape(PUBLIC_URL)}/upload/[\w-]{{40,}}", text(result))


async def test_an_uploaded_picture_is_stored_in_comfyui_and_named_by_its_image_id_once():
    comfyui = FakeComfyUI()
    server = build_server(comfyui.client, public_url=PUBLIC_URL)
    path = await upload_path(server)

    first = await put(server, path, picture())
    again = await put(server, path, picture())

    assert first.status_code == 200
    assert re.fullmatch(r"upload-[\w-]+\.png \[input\]", first.json()["image_id"])
    assert again.status_code == 403
    assert len(comfyui.stored) == 1


async def test_an_upload_to_a_made_up_link_or_of_something_not_a_picture_is_refused():
    comfyui = FakeComfyUI()
    server = build_server(comfyui.client, public_url=PUBLIC_URL)
    path = await upload_path(server)

    not_a_picture = await put(server, path, b"#!/bin/sh\nrm -rf /\n")
    made_up = await put(server, "/upload/made-up", picture())

    assert not_a_picture.status_code == 400
    assert made_up.status_code == 403
    assert comfyui.stored == []


async def test_an_uploaded_voice_clip_is_stored_as_it_is_and_named_by_its_audio_id():
    comfyui = FakeComfyUI()
    server = build_server(comfyui.client, public_url=PUBLIC_URL)
    path = await upload_path(server)

    response = await put(server, path, voice(seconds=3))

    assert response.status_code == 200
    assert re.fullmatch(r"upload-[\w-]+\.wav \[input\]", response.json()["audio_id"])
    assert comfyui.stored[0].count(voice(seconds=3)) == 1


@pytest.mark.parametrize("header, extension", [
    (b"ID3\x04\x00", "mp3"), (b"\xff\xfb\x90\x00", "mp3"), (b"\x00\x00\x00\x20ftypM4A ", "m4a"),
    (b"OggS\x00\x02", "ogg"), (b"\x1a\x45\xdf\xa3\x9f\x42", "webm"), (b"fLaC\x00\x00", "flac")])
async def test_a_voice_clip_keeps_the_extension_its_recorder_gave_it(header, extension):
    server = build_server(FakeComfyUI().client, public_url=PUBLIC_URL)
    path = await upload_path(server)

    response = await put(server, path, header + b"\0" * 64)

    assert response.json()["audio_id"].endswith(f".{extension} [input]")


async def test_an_upload_link_older_than_ten_minutes_is_refused():
    now = [0.0]
    comfyui = FakeComfyUI()
    server = build_server(comfyui.client, public_url=PUBLIC_URL, clock=lambda: now[0])
    path = await upload_path(server)

    now[0] = 601
    response = await put(server, path, picture())

    assert response.status_code == 403
    assert comfyui.stored == []


async def test_an_edit_of_no_image_or_more_than_three_is_refused():
    comfyui = FakeComfyUI()

    none = await call("edit", {"prompt": "make it blue", "images": []}, comfyui)
    four = await call("edit", {"prompt": "make it blue", "images": ["a.png"] * 4}, comfyui)

    assert refused(none, "images")
    assert refused(four, "images")
    assert comfyui.submitted == []


async def test_an_edit_is_one_job_loading_every_image_it_names_beside_the_instruction():
    comfyui = FakeComfyUI(finished=False)
    edit = {"prompt": "put the cat on the sofa", "images": ["mcp_00012_.png [output]", "upload-abc.png"]}

    await call("edit", edit, comfyui)
    await call("edit", edit, comfyui)

    first, second = comfyui.submitted
    [encoder] = [inputs for inputs in nodes_of(first, "TextEncodeQwenImageEditPlus") if inputs["prompt"]]
    loaded = [source(first, source(first, encoder[f"image{n}"])["inputs"]["image"]) for n in (1, 2)]
    assert encoder["prompt"] == "put the cat on the sofa"
    assert [load["inputs"]["image"] for load in loaded] == edit["images"]
    assert nodes_of(first, "KSampler")[0]["seed"] != nodes_of(second, "KSampler")[0]["seed"]


async def test_a_finished_edit_goes_to_the_viewer_and_names_its_image_id_for_the_next_edit():
    comfyui = FakeComfyUI()

    result = await call("edit", {"prompt": "make it blue", "images": ["a.png"]}, comfyui)

    assert shown(result) == ("image/png", comfyui.picture)
    assert 'image_id "edit_00001_.png [output]"' in text(result)


async def test_removing_a_background_is_one_job_turning_birefnets_mask_into_alpha():
    comfyui = FakeComfyUI(finished=False)

    await call("remove_background", {"image": "upload-abc.png"}, comfyui)

    [save] = nodes_of(comfyui.job, "SaveImage")
    join = source(comfyui.job, save["images"])
    invert = source(comfyui.job, join["inputs"]["alpha"])
    assert join["class_type"] == "JoinImageWithAlpha"
    assert source(comfyui.job, join["inputs"]["image"])["inputs"]["image"] == "upload-abc.png"
    assert invert["class_type"] == "InvertMask"
    assert source(comfyui.job, invert["inputs"]["mask"])["class_type"] == "RemoveBackground"


async def test_a_cutout_is_shown_and_offered_as_a_png_download_with_its_image_id():
    comfyui = FakeComfyUI()

    result = await call("remove_background", {"image": "upload-abc.png"}, comfyui)

    assert downloads(result) == [("cutout_00001_.png", "image/png", comfyui.picture)]
    assert 'image_id "cutout_00001_.png [output]"' in text(result)


async def test_a_logo_is_one_job_drawing_the_styled_prompt_with_its_text_then_cutting_out_the_background():
    comfyui = FakeComfyUI(finished=False)

    await call("logo", {"description": "a coffee cup with steam", "text": "Bean There"}, comfyui)

    [sampler] = nodes_of(comfyui.job, "KSampler")
    [unet] = nodes_of(comfyui.job, "UNETLoader")
    [save] = nodes_of(comfyui.job, "SaveImage")
    prompt = source(comfyui.job, sampler["positive"])["inputs"]["text"]
    assert "flat vector logo" in prompt
    assert prompt.endswith('a coffee cup with steam, with the text "Bean There"')
    assert unet["unet_name"] == "qwen_image_2512_fp8_e4m3fn.safetensors"
    assert source(comfyui.job, save["images"])["class_type"] == "JoinImageWithAlpha"
    assert comfyui.jobs["job-1"]["extra_data"]["logo"] is True


async def test_a_finished_logo_is_offered_as_png_and_as_the_svg_traced_from_it():
    comfyui = FakeComfyUI()
    traced = []

    def vectorize(png):
        traced.append(png)
        return b"<svg>traced</svg>"

    result = await call("logo", {"description": "a rocket"}, comfyui, vectorize=vectorize)

    assert traced == [comfyui.picture]
    assert downloads(result) == [("logo.png", "image/png", comfyui.picture),
                                 ("logo.svg", "image/svg+xml", b"<svg>traced</svg>")]
    assert 'image_id "logo_00001_.png [output]"' in text(result)


async def animation_of(comfyui, **arguments):
    await call("animate", {"image": "upload-abc.png", "prompt": "it sways", **arguments}, comfyui)
    return comfyui.submitted[-1]


async def test_animating_loads_the_picture_as_the_first_frame_of_the_image_to_video_models():
    comfyui = FakeComfyUI(finished=False)

    job = await animation_of(comfyui, prompt="the camera slowly pushes in")

    [start] = nodes_of(job, "WanImageToVideo")
    assert source(job, start["start_image"])["inputs"]["image"] == "upload-abc.png"
    assert source(job, start["positive"])["inputs"]["text"] == "the camera slowly pushes in"
    assert sorted(unet["unet_name"] for unet in nodes_of(job, "UNETLoader")) == [
        "wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors", "wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors"]


async def test_an_animation_keeps_the_pictures_orientation():
    portrait = FakeComfyUI(picture=picture(768, 1024), finished=False)
    landscape = FakeComfyUI(picture=picture(1024, 768), finished=False)
    square = FakeComfyUI(picture=picture(900, 900), finished=False)

    jobs = [await animation_of(comfyui) for comfyui in (portrait, landscape, square)]

    assert [(start["width"], start["height"]) for job in jobs
            for start in nodes_of(job, "WanImageToVideo")] == [(480, 832), (832, 480), (640, 640)]


async def test_an_animation_given_a_last_picture_moves_from_the_first_to_it():
    comfyui = FakeComfyUI(finished=False)

    job = await animation_of(comfyui, image="day.png", last_image="night.png [output]")

    [frames] = nodes_of(job, "WanFirstLastFrameToVideo")
    assert nodes_of(job, "WanImageToVideo") == []
    assert source(job, frames["start_image"])["inputs"]["image"] == "day.png"
    assert source(job, frames["end_image"])["inputs"]["image"] == "night.png [output]"


async def test_an_animation_takes_videos_length_and_resolution_within_the_same_bounds():
    comfyui = FakeComfyUI(picture=picture(1024, 768), finished=False)
    animate = {"image": "upload-abc.png", "prompt": "it sways"}

    too_long = await call("animate", {**animate, "seconds": 30}, comfyui)
    too_sharp = await call("animate", {**animate, "resolution": "4k"}, comfyui)
    job = await animation_of(comfyui, seconds=3, resolution="720p")

    assert refused(too_long, "seconds")
    assert refused(too_sharp, "resolution")
    [start] = nodes_of(job, "WanImageToVideo")
    assert (start["width"], start["height"], start["length"]) == (1280, 720, 73)


async def test_animating_while_a_clip_renders_returns_that_clip_instead_of_starting_another():
    comfyui = FakeComfyUI(running=[("v1", json.loads(VIDEO_WORKFLOW.read_text()))], finished=False)

    result = await call("animate", {"image": "upload-abc.png", "prompt": "it sways"}, comfyui)

    assert comfyui.submitted == []
    assert 'job_id "v1"' in text(result)


async def talk(comfyui, seconds=3.0, **arguments):
    talking = {"image": "upload-face.png", "audio": "upload-voice.wav [input]", "prompt": "a woman speaking warmly"}
    return await call("talk", {**talking, **arguments}, comfyui, audio_seconds=lambda clip: seconds)


async def test_talking_is_one_job_lip_syncing_the_face_to_the_voice_at_the_templates_four_steps():
    comfyui = FakeComfyUI(finished=False)

    await talk(comfyui)

    [sound] = nodes_of(comfyui.job, "WanSoundImageToVideo")
    [sampler] = nodes_of(comfyui.job, "KSampler")
    encoded = source(comfyui.job, sound["audio_encoder_output"])["inputs"]
    assert source(comfyui.job, sound["ref_image"])["inputs"]["image"] == "upload-face.png"
    assert source(comfyui.job, encoded["audio"])["inputs"]["audio"] == "upload-voice.wav"
    assert source(comfyui.job, sound["positive"])["inputs"]["text"] == "a woman speaking warmly"
    assert [unet["unet_name"] for unet in nodes_of(comfyui.job, "UNETLoader")] == ["wan2.2_s2v_14B_fp8_scaled.safetensors"]
    assert (sampler["steps"], sampler["cfg"]) == (4, 1)


async def test_the_voice_clips_length_decides_how_many_chunks_are_drawn_up_to_two():
    short, long, too_long = (FakeComfyUI(finished=False) for _ in range(3))

    await talk(short, seconds=3.0)
    await talk(long, seconds=7.0)
    refusal = await talk(too_long, seconds=12.0)

    assert len(nodes_of(short.job, "WanSoundImageToVideoExtend")) == 0
    assert len(nodes_of(long.job, "WanSoundImageToVideoExtend")) == 1
    assert [trim["batch_index"] for trim in nodes_of(short.job, "ImageFromBatch")] == [1]
    assert [trim["batch_index"] for trim in nodes_of(long.job, "ImageFromBatch")] == [2]
    assert refused(refusal, "9.6")
    assert too_long.submitted == []


async def test_a_finished_talking_head_plays_in_the_viewer_with_its_sound_and_can_be_downloaded():
    comfyui = FakeComfyUI()

    result = await talk(comfyui)

    assert shown(result) == ("video/mp4", MP4)
    assert downloads(result) == [("talk_00001_.mp4", "video/mp4", MP4)]


async def test_a_talking_head_rendering_counts_as_the_one_clip_at_a_time():
    comfyui = FakeComfyUI(finished=False)
    await talk(comfyui)

    result = await call("video", {"prompt": "waves"}, comfyui)

    assert len(comfyui.submitted) == 1
    assert 'job_id "job-1"' in text(result)


async def test_talking_while_a_clip_renders_returns_that_clip_instead_of_starting_another():
    comfyui = FakeComfyUI(running=[("v1", json.loads(VIDEO_WORKFLOW.read_text()))], finished=False)

    result = await talk(comfyui)

    assert comfyui.submitted == []
    assert 'job_id "v1"' in text(result)


async def test_a_talking_head_ends_when_its_voice_clip_does():
    comfyui = FakeComfyUI(finished=False)

    await talk(comfyui, seconds=3.0)

    [trim] = nodes_of(comfyui.job, "ImageFromBatch")
    [video] = nodes_of(comfyui.job, "CreateVideo")
    assert trim["length"] / video["fps"] == 3.0


async def test_a_talking_head_keeps_the_faces_orientation():
    portrait = FakeComfyUI(picture=picture(768, 1024), finished=False)

    await talk(portrait)

    [sound] = nodes_of(portrait.job, "WanSoundImageToVideo")
    assert (sound["width"], sound["height"]) == (480, 832)
