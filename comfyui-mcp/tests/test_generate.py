import base64

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


async def call_generate(comfyui, **arguments):
    server = build_server(comfyui)
    async with create_connected_server_and_client_session(server._mcp_server) as client:
        return await client.call_tool("generate", {"prompt": "a red apple", **arguments})


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
    [image] = result.content
    assert image.type == "image"
    assert image.mimeType == "image/png"
    assert base64.b64decode(image.data) == png
