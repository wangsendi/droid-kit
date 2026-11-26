#!/usr/bin/env python3
"""Receive a Nova-Persona-Stream WebRTC session and feed a v4l2loopback device.

Nova's WebRTC endpoint (see docs/stream-integration.md):
  POST /api/stream/offer   {group_id, session_id, type:"offer", sdp}
  DELETE /api/stream/viewers/{viewer_id}

This receiver:
  * polls /api/stream for the active session;
  * creates a recvonly video transceiver, posts the offer, applies the answer
    (host ICE candidates only, like Nova);
  * decodes VP8 with PyAV, rotates portrait sessions, scales/pads to the
    camera frame and pipes yuv420p frames to ffmpeg -> YUYV -> /dev/videoN.

Run it in the host network namespace so Nova can reach the host ICE candidate
(the container bridge address is usually not routable from Nova):
  sudo nsenter -t 1 -n -- env NOVA_BASE=http://172.11.11.45:8100 \
    /opt/venv/bin/python3 camera/host/feed-nova-webrtc.py

If Nova runs on this host, the default 127.0.0.1:8100 works. Nova's WebRTC
signaling endpoint accepts direct requests; only preview.webm enforces
127.0.0.1 (use nova-proxy.py for that path).

Environment:
  NOVA_BASE   default http://127.0.0.1:8100
  VIDEO_NR    default 10
  OUT_W/OUT_H default 1280x720
  FPS         default 30
  OUTPUT      default /dev/video$VIDEO_NR; "null" for a decode-only test
  POLL        default 2 seconds
"""
import asyncio
import json
import os
import signal
import sys

import httpx
from aiortc import (
    RTCBundlePolicy,
    RTCConfiguration,
    RTCPeerConnection,
    RTCSessionDescription,
)
from aiortc.mediastreams import MediaStreamError

NOVA_BASE = os.environ.get("NOVA_BASE", "http://127.0.0.1:8100")
VIDEO_NR = int(os.environ.get("VIDEO_NR", "10"))
OUT_W = int(os.environ.get("OUT_W", "1280"))
OUT_H = int(os.environ.get("OUT_H", "720"))
FPS = int(os.environ.get("FPS", "30"))
POLL = float(os.environ.get("POLL", "2"))
OUTPUT = os.environ.get("OUTPUT", f"/dev/video{VIDEO_NR}")
FFMPEG = os.environ.get("FFMPEG", "ffmpeg")
FIRST_FRAME_TIMEOUT = float(os.environ.get("FIRST_FRAME_TIMEOUT", "20"))
IDLE_TIMEOUT = float(os.environ.get("IDLE_TIMEOUT", "15"))


def log(*args):
    print(*args, flush=True)


class FFmpegWriter:
    def __init__(self, width, height):
        self.width = width
        self.height = height
        self.proc = None
        self.frames = 0

    async def start(self):
        vf = []
        if self.width < self.height:
            vf.append("transpose=1")
        vf.append(f"scale={OUT_W}:{OUT_H}:force_original_aspect_ratio=decrease")
        vf.append(f"pad={OUT_W}:{OUT_H}:(ow-iw)/2:(oh-ih)/2")
        if OUTPUT == "null":
            sink = ["-f", "null", "-"]
        else:
            sink = ["-f", "v4l2", OUTPUT]
        cmd = [
            FFMPEG, "-hide_banner", "-loglevel", "error",
            "-f", "rawvideo", "-pix_fmt", "yuv420p",
            "-s", f"{self.width}x{self.height}", "-r", str(FPS), "-i", "-",
            "-an", "-vf", ",".join(vf),
            "-pix_fmt", "yuyv422", *sink,
        ]
        log("ffmpeg:", " ".join(cmd))
        self.proc = await asyncio.create_subprocess_exec(
            *cmd, stdin=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        self._stderr_task = asyncio.create_task(self._read_stderr())

    async def _read_stderr(self):
        try:
            while True:
                line = await self.proc.stderr.readline()
                if not line:
                    break
                log("ffmpeg:", line.decode(errors="replace").strip())
        except asyncio.CancelledError:
            pass

    async def write(self, data):
        if self.proc is None:
            await self.start()
        try:
            self.proc.stdin.write(data)
            await self.proc.stdin.drain()
            self.frames += 1
        except (BrokenPipeError, ConnectionResetError):
            raise RuntimeError("ffmpeg exited")

    async def close(self):
        if self.proc is None:
            return
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            await asyncio.wait_for(self.proc.wait(), timeout=5)
        except asyncio.TimeoutError:
            self.proc.kill()
            await self.proc.wait()
        rc = self.proc.returncode
        if rc not in (0, None):
            log("ffmpeg exited", rc)
        try:
            await asyncio.wait_for(self._stderr_task, timeout=1)
        except Exception:
            self._stderr_task.cancel()
        self.proc = None


async def discard_audio(track):
    try:
        while True:
            await track.recv()
    except (MediaStreamError, asyncio.CancelledError):
        pass


async def run_session(client, status):
    """Run one WebRTC session until it ends. Returns when done."""
    config = status.get("config") or {}
    audio_enabled = bool(config.get("audio_enabled"))
    log("nova session", status.get("session_id"),
        f"({config.get('width')}x{config.get('height')}@{config.get('fps')})",
        "audio" if audio_enabled else "video-only")

    pc = RTCPeerConnection(
        RTCConfiguration(iceServers=[], bundlePolicy=RTCBundlePolicy.MAX_BUNDLE)
    )
    done = asyncio.Event()
    first_frame = asyncio.Event()
    writer = FFmpegWriter(0, 0)
    tasks = []
    viewer_id = None

    async def consume_video(track):
        nonlocal writer
        last_frame = asyncio.get_running_loop().time()
        try:
            while True:
                timeout = IDLE_TIMEOUT if first_frame.is_set() else FIRST_FRAME_TIMEOUT
                frame = await asyncio.wait_for(track.recv(), timeout=timeout)
                if frame.format.name != "yuv420p":
                    frame = frame.reformat(format="yuv420p")
                if writer.width != frame.width or writer.height != frame.height:
                    await writer.close()
                    writer = FFmpegWriter(frame.width, frame.height)
                    await writer.start()
                raw = frame.to_ndarray(format="yuv420p").tobytes()
                if writer.frames == 0:
                    log("raw frame", len(raw), frame.width, frame.height, frame.format.name)
                await writer.write(raw)
                if writer.frames % 30 == 0:
                    log("frames", writer.frames)
                last_frame = asyncio.get_running_loop().time()
                if not first_frame.is_set():
                    first_frame.set()
                    log("first video frame", f"{frame.width}x{frame.height}")
        except (MediaStreamError, asyncio.TimeoutError, RuntimeError) as e:
            log("video stopped:", type(e).__name__, e)
        finally:
            done.set()

    @pc.on("track")
    def on_track(track):
        if track.kind == "video":
            tasks.append(asyncio.create_task(consume_video(track)))
        else:
            tasks.append(asyncio.create_task(discard_audio(track)))

    @pc.on("connectionstatechange")
    async def on_state():
        log("connection:", pc.connectionState)
        if pc.connectionState in ("failed", "closed", "disconnected"):
            done.set()

    try:
        pc.addTransceiver("video", direction="recvonly")
        if audio_enabled:
            pc.addTransceiver("audio", direction="recvonly")

        offer = await pc.createOffer()
        await pc.setLocalDescription(offer)
        # Host candidates only; wait briefly for ICE gathering to put them in SDP.
        for _ in range(100):
            if pc.iceGatheringState == "complete":
                break
            await asyncio.sleep(0.05)

        payload = {
            "group_id": status["active_group_id"],
            "session_id": status["session_id"],
            "type": pc.localDescription.type,
            "sdp": pc.localDescription.sdp,
        }
        response = await client.post("/api/stream/offer", json=payload)
        response.raise_for_status()
        answer = response.json()
        viewer_id = answer.get("viewer_id")
        await pc.setRemoteDescription(
            RTCSessionDescription(sdp=answer["sdp"], type=answer["type"])
        )
        log("viewer:", viewer_id, "state:", pc.connectionState)

        while not done.is_set():
            try:
                await asyncio.wait_for(done.wait(), timeout=1)
            except asyncio.TimeoutError:
                pass
    finally:
        done.set()
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await writer.close()
        await pc.close()
        if viewer_id:
            try:
                await client.delete(f"/api/stream/viewers/{viewer_id}")
            except Exception:
                pass
        log("session closed", viewer_id or "")


async def main():
    stop = asyncio.Event()

    def on_signal(_sig, _frame):
        stop.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, on_signal)

    async with httpx.AsyncClient(base_url=NOVA_BASE, timeout=15) as client:
        log("nova base:", NOVA_BASE, "->", OUTPUT)
        while not stop.is_set():
            try:
                response = await client.get("/api/stream")
                response.raise_for_status()
                status = response.json()
            except Exception as e:
                log("status error:", e)
                await asyncio.sleep(POLL)
                continue

            if status.get("phase") not in ("running", "stopping") or \
               not status.get("active_group_id") or not status.get("session_id"):
                await asyncio.sleep(POLL)
                continue

            try:
                await run_session(client, status)
            except Exception as e:
                log("session error:", type(e).__name__, e)
            await asyncio.sleep(POLL)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
