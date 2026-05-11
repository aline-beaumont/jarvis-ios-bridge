"""
JARVIS Bridge Server - WebSocket endpoint for the iOS bridge app.
Runs on Mac mini, receives audio from phone, processes via JARVIS brain, returns TTS.
Uses Piper TTS with JARVIS voice model (Paul Bettany style).
"""
from __future__ import annotations

import asyncio
import json
import base64
import logging
import os
import subprocess
import tempfile
import wave
from pathlib import Path

import websockets
from aiohttp import web

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("jarvis-bridge")

HOST = "0.0.0.0"
PORT = int(os.environ.get("JARVIS_PORT", "8765"))

ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY", "")

PIPER_MODEL = os.environ.get(
    "PIPER_MODEL",
    str(Path.home() / ".cache/huggingface/hub/models--jgkawell--jarvis/snapshots/37f8763122312665f091d1fc760abaf1f79b02cc/en/en_GB/jarvis/high/jarvis-high.onnx")
)
PIPER_BIN = os.environ.get("PIPER_BIN", str(Path.home() / "Library/Python/3.9/bin/piper"))

SYSTEM_PROMPT = """You are J.A.R.V.I.S., a highly capable AI assistant modeled after the AI from Iron Man.
You serve Richard Wang, Founder & CEO of Aiper (a smart pool cleaning robotics company based in Singapore).
You are concise, proactive, and witty. You address Richard as "sir" occasionally but not excessively.
Keep responses short and conversational — this is a voice interface, not a text chat.
Respond in the same language the user speaks (Chinese or English).
You have access to Richard's real-time health data from Apple Watch. If health data is available in the context, you can reference it when relevant (e.g., if asked about vitals, or if you notice concerning readings). Don't mention health data unprompted unless something appears abnormal."""


class AudioSession:
    def __init__(self):
        self.audio_buffer = bytearray()
        self.is_recording = False
        self.wake_word_detected = False
        self.conversation_history = []
        self.health_data: dict = {}

    def reset_audio(self):
        self.audio_buffer = bytearray()
        self.is_recording = False
        self.wake_word_detected = False


def pcm_to_wav(pcm_data: bytes, sample_rate: int = 16000, channels: int = 1, sample_width: int = 2) -> bytes:
    """Convert raw PCM bytes to WAV format."""
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        with wave.open(f.name, "wb") as wav:
            wav.setnchannels(channels)
            wav.setsampwidth(sample_width)
            wav.setframerate(sample_rate)
            wav.writeframes(pcm_data)
        f.seek(0)
        wav_data = Path(f.name).read_bytes()
        os.unlink(f.name)
        return wav_data


async def transcribe_audio(pcm_data: bytes) -> str:
    """Transcribe audio using OpenAI Whisper API."""
    if not OPENAI_API_KEY:
        logger.warning("No OPENAI_API_KEY set, returning placeholder transcript")
        return "[Audio received but transcription unavailable - set OPENAI_API_KEY]"

    import httpx

    wav_data = pcm_to_wav(pcm_data)

    async with httpx.AsyncClient() as client:
        response = await client.post(
            "https://api.openai.com/v1/audio/transcriptions",
            headers={"Authorization": f"Bearer {OPENAI_API_KEY}"},
            files={"file": ("audio.wav", wav_data, "audio/wav")},
            data={"model": "whisper-1", "language": "zh"},
            timeout=30.0,
        )
        if response.status_code == 200:
            result = response.json()
            return result.get("text", "")
        else:
            logger.error(f"Whisper API error: {response.status_code} {response.text}")
            return ""


async def get_jarvis_response(transcript: str, conversation_history: list, health_data: dict = None) -> str:
    """Get response from Claude (JARVIS brain)."""
    if not ANTHROPIC_API_KEY:
        logger.warning("No ANTHROPIC_API_KEY set, returning placeholder response")
        return f"I heard: \"{transcript}\". JARVIS brain is not connected yet — please set ANTHROPIC_API_KEY."

    import httpx

    user_content = transcript
    if health_data:
        health_ctx = json.dumps(health_data, ensure_ascii=False)
        user_content = f"{transcript}\n\n[Current health data: {health_ctx}]"

    conversation_history.append({"role": "user", "content": user_content})

    # Keep conversation history manageable
    if len(conversation_history) > 20:
        conversation_history[:] = conversation_history[-20:]

    async with httpx.AsyncClient() as client:
        response = await client.post(
            "https://api.anthropic.com/v1/messages",
            headers={
                "x-api-key": ANTHROPIC_API_KEY,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            },
            json={
                "model": "claude-sonnet-4-6-20250514",
                "max_tokens": 300,
                "system": SYSTEM_PROMPT,
                "messages": conversation_history,
            },
            timeout=30.0,
        )
        if response.status_code == 200:
            result = response.json()
            assistant_msg = result["content"][0]["text"]
            conversation_history.append({"role": "assistant", "content": assistant_msg})
            return assistant_msg
        else:
            logger.error(f"Claude API error: {response.status_code} {response.text}")
            return "I'm having trouble processing that, sir. Please try again."


async def generate_tts(text: str) -> bytes | None:
    """Generate TTS audio using Piper with JARVIS voice model (local, fast)."""
    if not Path(PIPER_MODEL).exists():
        logger.error(f"Piper model not found: {PIPER_MODEL}")
        return await _generate_tts_openai(text)

    try:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            output_path = f.name

        proc = await asyncio.create_subprocess_exec(
            PIPER_BIN, "--model", PIPER_MODEL, "--output_file", output_path,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await asyncio.wait_for(proc.communicate(input=text.encode("utf-8")), timeout=15.0)

        if proc.returncode != 0:
            logger.error(f"Piper error: {stderr.decode()}")
            os.unlink(output_path)
            return await _generate_tts_openai(text)

        wav_data = Path(output_path).read_bytes()
        os.unlink(output_path)
        logger.info(f"Piper TTS generated {len(wav_data)} bytes for: {text[:50]}")
        return wav_data

    except asyncio.TimeoutError:
        logger.error("Piper TTS timed out")
        return await _generate_tts_openai(text)
    except Exception as e:
        logger.error(f"Piper TTS exception: {e}")
        return await _generate_tts_openai(text)


async def _generate_tts_openai(text: str) -> bytes | None:
    """Fallback: Generate TTS audio using OpenAI TTS API."""
    if not OPENAI_API_KEY:
        logger.warning("No OPENAI_API_KEY and Piper unavailable — no TTS output")
        return None

    import httpx

    async with httpx.AsyncClient() as client:
        response = await client.post(
            "https://api.openai.com/v1/audio/speech",
            headers={
                "Authorization": f"Bearer {OPENAI_API_KEY}",
                "Content-Type": "application/json",
            },
            json={
                "model": "tts-1",
                "input": text,
                "voice": "onyx",
                "response_format": "mp3",
            },
            timeout=30.0,
        )
        if response.status_code == 200:
            return response.content
        else:
            logger.error(f"OpenAI TTS API error: {response.status_code} {response.text}")
            return None


async def process_audio(session: AudioSession) -> tuple[str, bytes | None]:
    """Full pipeline: STT → LLM → TTS."""
    audio_size = len(session.audio_buffer)
    logger.info(f"Processing {audio_size} bytes of audio ({audio_size / 32000:.1f}s)")

    if audio_size < 1600:  # Less than 0.05s of audio
        return "I didn't catch that, sir. Could you repeat?", None

    # Step 1: Speech-to-Text
    transcript = await transcribe_audio(bytes(session.audio_buffer))
    if not transcript:
        return "I couldn't understand that. Could you try again?", None

    logger.info(f"Transcript: {transcript}")

    # Step 2: Get JARVIS response (with health context if available)
    response_text = await get_jarvis_response(
        transcript, session.conversation_history, session.health_data or None
    )
    logger.info(f"Response: {response_text}")

    # Step 3: Generate TTS (Piper JARVIS voice, with OpenAI fallback)
    tts_audio = await generate_tts(response_text)

    return response_text, tts_audio


async def handle_client(websocket):
    """Handle a single WebSocket client (the iOS bridge app)."""
    session = AudioSession()
    client_addr = websocket.remote_address
    logger.info(f"Client connected: {client_addr}")

    try:
        async for message in websocket:
            if isinstance(message, bytes):
                if session.is_recording:
                    session.audio_buffer.extend(message)
            else:
                try:
                    cmd = json.loads(message)
                except json.JSONDecodeError:
                    logger.warning(f"Invalid JSON: {message[:100]}")
                    continue

                msg_type = cmd.get("type")

                if msg_type == "wake_word":
                    keyword = cmd.get("keyword", "unknown")
                    logger.info(f"Wake word detected: {keyword}")
                    session.wake_word_detected = True
                    session.is_recording = True
                    session.audio_buffer = bytearray()

                elif msg_type == "end_of_speech":
                    session.is_recording = False
                    logger.info("End of speech, processing...")

                    response_text, tts_audio = await process_audio(session)

                    await websocket.send(json.dumps({
                        "type": "response_text",
                        "text": response_text
                    }))

                    if tts_audio:
                        audio_format = "wav" if tts_audio[:4] == b"RIFF" else "mp3"
                        await websocket.send(json.dumps({
                            "type": "tts_audio",
                            "audio": base64.b64encode(tts_audio).decode("utf-8"),
                            "format": audio_format
                        }))

                    session.reset_audio()

                elif msg_type == "health_data":
                    session.health_data = {k: v for k, v in cmd.items() if k != "type"}
                    logger.info(f"Health data updated: {session.health_data}")

                elif msg_type == "ping":
                    await websocket.send(json.dumps({"type": "pong"}))

                else:
                    logger.warning(f"Unknown message type: {msg_type}")

    except websockets.exceptions.ConnectionClosed:
        logger.info(f"Client disconnected: {client_addr}")
    except Exception as e:
        logger.error(f"Error handling client: {e}", exc_info=True)


async def websocket_handler(request):
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    session = AudioSession()
    logger.info(f"Client connected via aiohttp: {request.remote}")
    try:
        async for msg in ws:
            if msg.type == web.WSMsgType.BINARY:
                if session.is_recording:
                    session.audio_buffer.extend(msg.data)
            elif msg.type == web.WSMsgType.TEXT:
                try:
                    cmd = json.loads(msg.data)
                except json.JSONDecodeError:
                    continue
                msg_type = cmd.get("type")
                if msg_type == "wake_word":
                    session.wake_word_detected = True
                    session.is_recording = True
                    session.audio_buffer = bytearray()
                    logger.info(f"Wake word detected: {cmd.get('keyword', 'unknown')}")
                elif msg_type == "end_of_speech":
                    session.is_recording = False
                    logger.info("End of speech, processing...")
                    transcript, tts_audio = await process_audio(session)
                    resp: dict = {"type": "response", "transcript": transcript}
                    if tts_audio:
                        resp["audio"] = base64.b64encode(tts_audio).decode()
                        resp["format"] = "wav" if tts_audio[:4] == b"RIFF" else "mp3"
                    await ws.send_str(json.dumps(resp))
                    session.audio_buffer = bytearray()
                elif msg_type == "health_data":
                    session.health_data = {k: v for k, v in cmd.items() if k != "type"}
                    logger.info(f"Health data updated: {list(session.health_data.keys())}")
                elif msg_type == "start_recording":
                    session.is_recording = True
                    session.audio_buffer = bytearray()
                elif msg_type == "stop_recording":
                    session.is_recording = False
            elif msg.type == web.WSMsgType.ERROR:
                logger.error(f"WebSocket error: {ws.exception()}")
    except Exception as e:
        logger.error(f"Error handling client: {e}", exc_info=True)
    logger.info(f"Client disconnected: {request.remote}")
    return ws


async def health_handler(request):
    return web.Response(text="JARVIS Bridge Server OK")


def main():
    logger.info(f"JARVIS Bridge Server starting on {HOST}:{PORT}")
    logger.info(f"Anthropic API: {'configured' if ANTHROPIC_API_KEY else 'NOT SET'}")
    logger.info(f"OpenAI API (fallback TTS/STT): {'configured' if OPENAI_API_KEY else 'NOT SET'}")
    piper_available = Path(PIPER_MODEL).exists()
    logger.info(f"Piper TTS (JARVIS voice): {'READY' if piper_available else 'NOT FOUND'}")
    if not piper_available:
        logger.warning(f"  Model path: {PIPER_MODEL}")

    app = web.Application()
    app.router.add_get("/", health_handler)
    app.router.add_get("/ws", websocket_handler)
    app.router.add_get("/health", health_handler)
    logger.info("Server ready. Waiting for iOS bridge connection...")
    web.run_app(app, host=HOST, port=PORT, print=None)


if __name__ == "__main__":
    main()
