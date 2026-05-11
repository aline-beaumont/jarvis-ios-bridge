"""
JARVIS Bridge Server - WebSocket endpoint for the iOS bridge app.
Runs on Mac mini, receives audio from phone, processes via JARVIS brain, returns TTS.
"""

import asyncio
import json
import base64
import logging
import os
import tempfile
import wave
from pathlib import Path

import websockets

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("jarvis-bridge")

HOST = "0.0.0.0"
PORT = int(os.environ.get("JARVIS_PORT", "8765"))

ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY", "")

SYSTEM_PROMPT = """You are J.A.R.V.I.S., a highly capable AI assistant modeled after the AI from Iron Man.
You serve Richard Wang, Founder & CEO of Aiper (a smart pool cleaning robotics company based in Singapore).
You are concise, proactive, and witty. You address Richard as "sir" occasionally but not excessively.
Keep responses short and conversational — this is a voice interface, not a text chat.
Respond in the same language the user speaks (Chinese or English)."""


class AudioSession:
    def __init__(self):
        self.audio_buffer = bytearray()
        self.is_recording = False
        self.wake_word_detected = False
        self.conversation_history = []

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


async def get_jarvis_response(transcript: str, conversation_history: list) -> str:
    """Get response from Claude (JARVIS brain)."""
    if not ANTHROPIC_API_KEY:
        logger.warning("No ANTHROPIC_API_KEY set, returning placeholder response")
        return f"I heard: \"{transcript}\". JARVIS brain is not connected yet — please set ANTHROPIC_API_KEY."

    import httpx

    conversation_history.append({"role": "user", "content": transcript})

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
    """Generate TTS audio using OpenAI TTS API."""
    if not OPENAI_API_KEY:
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
            logger.error(f"TTS API error: {response.status_code} {response.text}")
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

    # Step 2: Get JARVIS response
    response_text = await get_jarvis_response(transcript, session.conversation_history)
    logger.info(f"Response: {response_text}")

    # Step 3: Generate TTS
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
                        await websocket.send(json.dumps({
                            "type": "tts_audio",
                            "audio": base64.b64encode(tts_audio).decode("utf-8"),
                            "format": "mp3"
                        }))

                    session.reset_audio()

                elif msg_type == "ping":
                    await websocket.send(json.dumps({"type": "pong"}))

                else:
                    logger.warning(f"Unknown message type: {msg_type}")

    except websockets.exceptions.ConnectionClosed:
        logger.info(f"Client disconnected: {client_addr}")
    except Exception as e:
        logger.error(f"Error handling client: {e}", exc_info=True)


async def main():
    logger.info(f"JARVIS Bridge Server starting on ws://{HOST}:{PORT}")
    logger.info(f"Anthropic API: {'configured' if ANTHROPIC_API_KEY else 'NOT SET'}")
    logger.info(f"OpenAI API: {'configured' if OPENAI_API_KEY else 'NOT SET'}")
    async with websockets.serve(handle_client, HOST, PORT):
        logger.info("Server ready. Waiting for iOS bridge connection...")
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
