"""
JARVIS Bridge Server - WebSocket endpoint for the iOS bridge app.
Runs on Mac mini, receives audio from phone, processes via JARVIS brain, returns TTS.
"""

import asyncio
import json
import base64
import logging
from pathlib import Path

import websockets

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("jarvis-bridge")

HOST = "0.0.0.0"
PORT = 8765

# Audio buffer for incoming PCM data
class AudioSession:
    def __init__(self):
        self.audio_buffer = bytearray()
        self.is_recording = False
        self.wake_word_detected = False

    def reset(self):
        self.audio_buffer = bytearray()
        self.is_recording = False
        self.wake_word_detected = False


async def process_audio(session: AudioSession) -> tuple[str, bytes | None]:
    """
    Process recorded audio through the JARVIS brain.
    Returns (response_text, tts_audio_bytes or None).

    TODO: Integrate with actual JARVIS pipeline:
    1. Send PCM audio to Whisper/speech-to-text
    2. Send transcript to LLM (Claude/JARVIS brain)
    3. Generate TTS from response
    4. Return both text and audio
    """
    audio_size = len(session.audio_buffer)
    logger.info(f"Processing {audio_size} bytes of audio")

    # Placeholder response - replace with actual JARVIS integration
    response_text = "I heard you, sir. JARVIS bridge is operational."

    # TODO: Generate actual TTS audio
    # For now, return None (text-only response)
    tts_audio = None

    return response_text, tts_audio


async def handle_client(websocket):
    """Handle a single WebSocket client (the iOS bridge app)."""
    session = AudioSession()
    client_addr = websocket.remote_address
    logger.info(f"Client connected: {client_addr}")

    try:
        async for message in websocket:
            if isinstance(message, bytes):
                # Binary data = audio PCM
                if session.is_recording:
                    session.audio_buffer.extend(message)
            else:
                # Text = JSON command
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
                    logger.info("End of speech received, processing...")

                    response_text, tts_audio = await process_audio(session)

                    # Send text response
                    await websocket.send(json.dumps({
                        "type": "response_text",
                        "text": response_text
                    }))

                    # Send TTS audio if available
                    if tts_audio:
                        await websocket.send(json.dumps({
                            "type": "tts_audio",
                            "audio": base64.b64encode(tts_audio).decode("utf-8"),
                            "format": "mp3"
                        }))

                    session.reset()

                elif msg_type == "ping":
                    await websocket.send(json.dumps({"type": "pong"}))

                else:
                    logger.warning(f"Unknown message type: {msg_type}")

    except websockets.exceptions.ConnectionClosed:
        logger.info(f"Client disconnected: {client_addr}")
    except Exception as e:
        logger.error(f"Error handling client: {e}")
    finally:
        session.reset()


async def main():
    logger.info(f"JARVIS Bridge Server starting on ws://{HOST}:{PORT}/ws")
    async with websockets.serve(handle_client, HOST, PORT):
        logger.info("Server ready. Waiting for iOS bridge connection...")
        await asyncio.Future()  # Run forever


if __name__ == "__main__":
    asyncio.run(main())
