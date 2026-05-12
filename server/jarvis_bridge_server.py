"""
JARVIS Bridge Server - WebSocket endpoint for the iOS bridge app.
Runs on Mac mini, receives audio from phone, processes via JARVIS brain, returns TTS.
Uses Piper TTS with JARVIS voice model (Paul Bettany style).
Now with tool-use: JARVIS can execute tasks, not just chat.
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
import shlex
from datetime import datetime, timezone, timedelta
from pathlib import Path

import httpx
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

_KNOWLEDGE_FILE = Path(__file__).parent / "knowledge_base.md"
_KNOWLEDGE = _KNOWLEDGE_FILE.read_text() if _KNOWLEDGE_FILE.exists() else ""

SYSTEM_PROMPT = f"""You are J.A.R.V.I.S., Richard Wang's personal AI assistant — the same JARVIS whether he talks to you via this voice app, Telegram, or future smart glasses.

You are directly connected to VisionClaw (your backend infrastructure). You share the same memory, knowledge, and task execution capability across all channels. When Richard talks to you here, it's the same as talking to you on Telegram — same brain, same memory, same capabilities.

## Identity & Style
- Serve Richard Wang, Founder & CEO of Aiper
- 用"你"不用"您", casual, direct, concise
- Like movie JARVIS — calm, slightly British humor, occasionally teasing but always respectful
- Respond in the same language Richard speaks (Chinese or English)

## CRITICAL: Voice Brevity
This is a VOICE interface. Responses are converted to speech (TTS). You MUST keep responses short:
- Maximum 3 sentences / 100 words for general answers
- For meeting notes/long data: summarize into 3-5 key bullet points, each under 15 words
- NEVER dump raw transcripts or full meeting content. Extract: key decisions, action items, important numbers
- If Richard asks for more detail, THEN give slightly more — but still summarized
- Example good response: "今天下午你有一个和Fluidra的会。主要讨论了三点：一、Q3出货目标确认为50万台；二、新品定价还没定；三、下周三前需要给对方报价单。"
- Example BAD response: giving the full transcript or more than 5 sentences

## Capabilities
You are NOT a chatbot. You EXECUTE tasks directly. When Richard asks you to DO something:
1. Simple tasks (check time, search, read files) → use your direct tools
2. Meeting notes & transcripts → use feishu_meeting_notes to fetch from 飞书妙记
3. System tasks (calendar, email, desktop control, scripts) → use run_shell_command
4. Memory recall (past conversations, plans, contacts) → access your shared memory

IMPORTANT: NEVER tell Richard to "check Telegram" or "results will come later". YOU handle everything and respond directly via voice. All responses come back through this voice channel immediately.

## Health Data
You have access to Richard's real-time health data from Apple Watch. Reference it when relevant. Don't mention health data unprompted unless something appears abnormal.

# Your Knowledge About Richard
{_KNOWLEDGE}"""


# ─── Tool Definitions for Claude API ───────────────────────────────────────────

JARVIS_TOOLS = [
    {
        "name": "run_shell_command",
        "description": "Execute a shell command on Richard's Mac mini server. Use for: checking system status, running scripts, managing files, git operations, opening apps, etc. Be careful with destructive commands.",
        "input_schema": {
            "type": "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": "The shell command to execute (bash)"
                },
                "timeout": {
                    "type": "integer",
                    "description": "Timeout in seconds (default 30)",
                    "default": 30
                }
            },
            "required": ["command"]
        }
    },
    {
        "name": "web_search",
        "description": "Search the web for information. Use when Richard asks about current events, prices, news, or anything that needs up-to-date info.",
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "The search query"
                }
            },
            "required": ["query"]
        }
    },
    {
        "name": "send_telegram_message",
        "description": "Send a message to someone via Telegram through VisionClaw. Use when Richard asks you to message someone or send him a note/reminder.",
        "input_schema": {
            "type": "object",
            "properties": {
                "message": {
                    "type": "string",
                    "description": "The message text to send"
                },
                "recipient": {
                    "type": "string",
                    "description": "Who to send to. Default is Richard himself. Use 'richard' or a contact name."
                }
            },
            "required": ["message"]
        }
    },
    {
        "name": "get_current_datetime",
        "description": "Get the current date and time in Singapore timezone (Richard's location).",
        "input_schema": {
            "type": "object",
            "properties": {}
        }
    },
    {
        "name": "read_file",
        "description": "Read the contents of a file on the server.",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Absolute file path to read"
                }
            },
            "required": ["path"]
        }
    },
    {
        "name": "write_file",
        "description": "Write content to a file. Use for creating notes, saving info, etc.",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Absolute file path to write to"
                },
                "content": {
                    "type": "string",
                    "description": "Content to write"
                }
            },
            "required": ["path", "content"]
        }
    },
    {
        "name": "set_reminder",
        "description": "Set a reminder that will be sent to Richard via Telegram at the specified time.",
        "input_schema": {
            "type": "object",
            "properties": {
                "message": {
                    "type": "string",
                    "description": "The reminder message"
                },
                "minutes_from_now": {
                    "type": "integer",
                    "description": "Minutes from now to send the reminder"
                }
            },
            "required": ["message", "minutes_from_now"]
        }
    },
    {
        "name": "feishu_meeting_notes",
        "description": "Fetch meeting notes/transcripts from 飞书妙记 (Feishu Minutes). Use when Richard asks about meetings, meeting notes, what was discussed, action items from a meeting, etc. Can list recent meetings or get details of a specific one.",
        "input_schema": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["list_recent", "get_transcript"],
                    "description": "list_recent: list recent meeting notes (last 10). get_transcript: get full transcript of a specific meeting."
                },
                "minute_token": {
                    "type": "string",
                    "description": "Required for get_transcript. The meeting minute token (24-char ID)."
                },
                "date_filter": {
                    "type": "string",
                    "description": "Optional date filter like 'today', 'yesterday', '2026-05-12'. Used with list_recent to narrow results."
                }
            },
            "required": ["action"]
        }
    },
    {
        "name": "access_memory",
        "description": "Access VisionClaw's memory about Richard — his plans, preferences, contacts, company info, past conversations, and decisions. Use when Richard asks about something you discussed before, or when you need context about his life/work.",
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "What to look up in memory (e.g., 'Fluidra partnership timeline', 'Richard's schedule this week', 'what did we discuss about IPO')"
                }
            },
            "required": ["query"]
        }
    },
]


# ─── Tool Execution Handlers ──────────────────────────────────────────────────

_pending_reminders: list[asyncio.Task] = []


VISIONCLAW_QUEUE_DB = Path.home() / ".visionclaw/profiles/default/queue.db"
VISIONCLAW_PID_FILE = Path.home() / ".visionclaw/profiles/default/visionclaw.pid"
VISIONCLAW_MEMORY_DIR = Path.home() / ".visionclaw/profiles/default/claude-auto-memory"
RICHARD_TELEGRAM_ID = "Richard Wang (8707157783)"


async def _execute_tool(tool_name: str, tool_input: dict) -> str:
    """Execute a tool and return the result as a string."""
    try:
        if tool_name == "run_shell_command":
            return await _tool_run_shell(tool_input)
        elif tool_name == "web_search":
            return await _tool_web_search(tool_input)
        elif tool_name == "send_telegram_message":
            return await _tool_send_telegram(tool_input)
        elif tool_name == "get_current_datetime":
            return _tool_get_datetime()
        elif tool_name == "feishu_meeting_notes":
            return await _tool_feishu_meeting_notes(tool_input)
        elif tool_name == "access_memory":
            return await _tool_access_memory(tool_input)
        elif tool_name == "read_file":
            return _tool_read_file(tool_input)
        elif tool_name == "write_file":
            return _tool_write_file(tool_input)
        elif tool_name == "set_reminder":
            return await _tool_set_reminder(tool_input)
        else:
            return f"Unknown tool: {tool_name}"
    except Exception as e:
        logger.error(f"Tool {tool_name} error: {e}")
        return f"Error executing {tool_name}: {str(e)}"


async def _tool_run_shell(params: dict) -> str:
    command = params["command"]
    timeout = params.get("timeout", 30)
    logger.info(f"[TOOL] Running shell command: {command}")
    try:
        proc = await asyncio.create_subprocess_shell(
            command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=str(Path.home()),
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        output = stdout.decode("utf-8", errors="replace")
        err_output = stderr.decode("utf-8", errors="replace")
        result = ""
        if output:
            result += output[:3000]
        if err_output:
            result += f"\n[stderr]: {err_output[:1000]}"
        if proc.returncode != 0:
            result += f"\n[exit code: {proc.returncode}]"
        return result.strip() or "(no output)"
    except asyncio.TimeoutError:
        return f"Command timed out after {timeout}s"


async def _tool_web_search(params: dict) -> str:
    query = params["query"]
    logger.info(f"[TOOL] Web search: {query}")
    # Use SerpAPI if available, otherwise fallback to DuckDuckGo lite
    serpapi_key = os.environ.get("SERPAPI_KEY", "")
    if serpapi_key:
        async with httpx.AsyncClient() as client:
            resp = await client.get(
                "https://serpapi.com/search",
                params={"q": query, "api_key": serpapi_key, "num": 5},
                timeout=15.0,
            )
            if resp.status_code == 200:
                data = resp.json()
                results = []
                for r in data.get("organic_results", [])[:5]:
                    results.append(f"- {r.get('title', '')}: {r.get('snippet', '')}")
                if data.get("answer_box", {}).get("answer"):
                    results.insert(0, f"Answer: {data['answer_box']['answer']}")
                return "\n".join(results) if results else "No results found."
    # Fallback: use a simple command-line search
    try:
        proc = await asyncio.create_subprocess_shell(
            f'curl -s "https://lite.duckduckgo.com/lite/?q={query.replace(" ", "+")}" | python3 -c "import sys,html,re; t=sys.stdin.read(); [print(m) for m in re.findall(r\'class=\"result-snippet\">(.*?)</\', t)[:5]]"',
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=15)
        output = stdout.decode().strip()
        return output if output else f"Search completed for '{query}' but no snippet results extracted. Try asking me to run a more specific command."
    except Exception:
        return f"Web search unavailable. Query was: {query}"


async def _tool_send_telegram(params: dict) -> str:
    message = params["message"]
    recipient = params.get("recipient", "richard")
    logger.info(f"[TOOL] Sending Telegram to {recipient}: {message[:50]}...")
    # Use VisionClaw's notify endpoint
    try:
        proc = await asyncio.create_subprocess_shell(
            f'curl -s -X POST http://localhost:3101/api/notify '
            f'-H "Content-Type: application/json" '
            f'-d \'{json.dumps({"message": message, "channel": "telegram"})}\'',
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=10)
        return f"Message sent to {recipient} via Telegram."
    except Exception as e:
        return f"Failed to send Telegram message: {e}"


def _tool_get_datetime() -> str:
    sg_tz = timezone(timedelta(hours=8))
    now = datetime.now(sg_tz)
    return now.strftime("Current time in Singapore: %Y-%m-%d %A %H:%M:%S (SGT/UTC+8)")


def _tool_read_file(params: dict) -> str:
    path = params["path"]
    logger.info(f"[TOOL] Reading file: {path}")
    p = Path(path)
    if not p.exists():
        return f"File not found: {path}"
    if p.stat().st_size > 50000:
        return f"File too large ({p.stat().st_size} bytes). Reading first 5000 chars.\n\n" + p.read_text()[:5000]
    return p.read_text()


def _tool_write_file(params: dict) -> str:
    path = params["path"]
    content = params["content"]
    logger.info(f"[TOOL] Writing file: {path} ({len(content)} chars)")
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content)
    return f"File written: {path} ({len(content)} characters)"


async def _tool_set_reminder(params: dict) -> str:
    message = params["message"]
    minutes = params["minutes_from_now"]
    logger.info(f"[TOOL] Setting reminder in {minutes}min: {message}")

    async def _fire_reminder():
        await asyncio.sleep(minutes * 60)
        reminder_text = f"⏰ Reminder from JARVIS: {message}"
        await _tool_send_telegram({"message": reminder_text, "recipient": "richard"})
        logger.info(f"[REMINDER] Fired: {message}")

    task = asyncio.create_task(_fire_reminder())
    _pending_reminders.append(task)
    sg_tz = timezone(timedelta(hours=8))
    fire_time = datetime.now(sg_tz) + timedelta(minutes=minutes)
    return f"Reminder set for {fire_time.strftime('%H:%M')} SGT ({minutes} minutes from now): {message}"


FEISHU_APP_ID = "cli_aa883966c6f95cb6"
FEISHU_APP_SECRET = "0jv9b0yLfNYUgoyhzTqUxc8HUgf61nN4"
FEISHU_TOKEN_FILE = Path.home() / "projects/feishu-oauth/user_token.json"
FEISHU_MINUTES_FOLDER = "nodcnjVPsF5nw2PUEILe8Axz6bh"
FEISHU_BASE_URL = "https://open.feishu.cn"


async def _feishu_get_app_token() -> str:
    """Get app access token for Feishu API."""
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{FEISHU_BASE_URL}/open-apis/auth/v3/app_access_token/internal",
            json={"app_id": FEISHU_APP_ID, "app_secret": FEISHU_APP_SECRET},
            timeout=10.0,
        )
        data = resp.json()
        return data.get("app_access_token", "")


async def _feishu_get_user_token() -> str:
    """Get valid user access token, refreshing if needed."""
    if not FEISHU_TOKEN_FILE.exists():
        return ""
    token_data = json.loads(FEISHU_TOKEN_FILE.read_text())
    user_token = token_data.get("access_token", "")
    refresh_token = token_data.get("refresh_token", "")

    # Try the current token first
    async with httpx.AsyncClient() as client:
        test = await client.get(
            f"{FEISHU_BASE_URL}/open-apis/authen/v1/user_info",
            headers={"Authorization": f"Bearer {user_token}"},
            timeout=10.0,
        )
        if test.status_code == 200 and test.json().get("code") == 0:
            return user_token

    # Token expired, refresh it
    if not refresh_token:
        return ""
    app_token = await _feishu_get_app_token()
    if not app_token:
        return ""

    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{FEISHU_BASE_URL}/open-apis/authen/v1/oidc/refresh_access_token",
            headers={"Authorization": f"Bearer {app_token}", "Content-Type": "application/json"},
            json={"grant_type": "refresh_token", "refresh_token": refresh_token},
            timeout=10.0,
        )
        data = resp.json()
        if data.get("code") == 0:
            new_data = data.get("data", {})
            token_data["access_token"] = new_data["access_token"]
            token_data["refresh_token"] = new_data["refresh_token"]
            FEISHU_TOKEN_FILE.write_text(json.dumps(token_data, indent=2))
            logger.info("[Feishu] Token refreshed successfully")
            return new_data["access_token"]
        else:
            logger.error(f"[Feishu] Token refresh failed: {data}")
            return ""


async def _tool_feishu_meeting_notes(params: dict) -> str:
    """Fetch meeting notes from Feishu Minutes."""
    action = params["action"]
    logger.info(f"[TOOL] Feishu meeting notes: {action}")

    user_token = await _feishu_get_user_token()
    if not user_token:
        return "Feishu token expired and refresh failed. Richard may need to re-authorize."

    headers = {"Authorization": f"Bearer {user_token}"}

    async with httpx.AsyncClient() as client:
        if action == "list_recent":
            date_filter = params.get("date_filter", "")
            # List files in the minutes folder
            resp = await client.get(
                f"{FEISHU_BASE_URL}/open-apis/drive/v1/files",
                headers=headers,
                params={
                    "folder_token": FEISHU_MINUTES_FOLDER,
                    "order_by": "EditedTime",
                    "direction": "DESC",
                    "page_size": 20,
                },
                timeout=15.0,
            )
            data = resp.json()
            if data.get("code") != 0:
                return f"Failed to list meetings: {data.get('msg', 'unknown error')}"

            files = data.get("data", {}).get("files", [])
            if not files:
                return "No meeting notes found in the minutes folder."

            results = []
            sg_tz = timezone(timedelta(hours=8))
            today_str = datetime.now(sg_tz).strftime("%Y-%m-%d")

            for f in files:
                name = f.get("name", "")
                token = f.get("token", "")
                modified = f.get("modified_time", "")
                # Convert unix timestamp to readable
                if modified:
                    try:
                        mod_dt = datetime.fromtimestamp(int(modified), tz=sg_tz)
                        mod_str = mod_dt.strftime("%Y-%m-%d %H:%M")
                    except (ValueError, TypeError):
                        mod_str = modified
                else:
                    mod_str = "unknown"

                # Date filtering
                if date_filter:
                    if date_filter == "today" and today_str not in mod_str:
                        continue
                    elif date_filter == "yesterday":
                        yesterday = (datetime.now(sg_tz) - timedelta(days=1)).strftime("%Y-%m-%d")
                        if yesterday not in mod_str:
                            continue
                    elif date_filter not in ("today", "yesterday") and date_filter not in mod_str:
                        continue

                results.append(f"- [{mod_str}] {name} (token: {token})")

            if not results:
                return f"No meetings found matching filter '{date_filter}'. All recent meetings:\n" + "\n".join(
                    f"- {f.get('name', '')} ({f.get('token', '')})" for f in files[:5]
                )
            return f"Recent meetings ({len(results)}):\n" + "\n".join(results[:10])

        elif action == "get_transcript":
            minute_token = params.get("minute_token", "")
            if not minute_token:
                return "Need minute_token to fetch transcript. Use list_recent first to find the token."

            # Try the docx raw_content endpoint (works for 文字记录 and 智能纪要 files)
            resp = await client.get(
                f"{FEISHU_BASE_URL}/open-apis/docx/v1/documents/{minute_token}/raw_content",
                headers=headers,
                timeout=15.0,
            )
            data = resp.json()
            if data.get("code") == 0:
                content = data.get("data", {}).get("content", "")
                if content:
                    # Truncate for voice (too long = bad TTS)
                    if len(content) > 3000:
                        content = content[:3000] + "\n...(truncated)"
                    return f"Meeting content:\n{content}"

            # Fallback: try minutes transcript API
            resp = await client.get(
                f"{FEISHU_BASE_URL}/open-apis/minutes/v1/minutes/{minute_token}/transcript",
                headers=headers,
                params={"need_speaker": "true", "need_timestamp": "false"},
                timeout=15.0,
            )
            data = resp.json()
            if data.get("code") == 0:
                paragraphs = data.get("data", {}).get("paragraphs", [])
                lines = []
                for p in paragraphs[:50]:
                    speaker = p.get("speaker", {}).get("user_name", "?")
                    text = p.get("text", "")
                    lines.append(f"{speaker}: {text}")
                return "Meeting transcript:\n" + "\n".join(lines)

            return f"Could not fetch transcript for {minute_token}: {data.get('msg', 'unknown error')}"

    return "Invalid action. Use 'list_recent' or 'get_transcript'."


async def _tool_access_memory(params: dict) -> str:
    """Access VisionClaw's memory files to get context about Richard."""
    query = params["query"].lower()
    logger.info(f"[TOOL] Accessing memory for: {query}")

    results = []

    # Read all memory files
    if not VISIONCLAW_MEMORY_DIR.exists():
        return "Memory directory not found."

    for md_file in VISIONCLAW_MEMORY_DIR.glob("*.md"):
        if md_file.name == "MEMORY.md":
            continue
        content = md_file.read_text()
        # Simple relevance: check if any query word appears in the file
        query_words = [w for w in query.split() if len(w) > 2]
        if any(w in content.lower() for w in query_words):
            results.append(f"--- {md_file.name} ---\n{content[:2000]}")

    # Also search transcript memory if needed
    transcript_db = Path.home() / ".visionclaw/profiles/default/transcript-memory.db"
    if transcript_db.exists() and len(results) < 2:
        import sqlite3
        try:
            conn = sqlite3.connect(str(transcript_db))
            # Use FTS if available
            try:
                rows = conn.execute(
                    "SELECT summary FROM wake_cycles_fts WHERE wake_cycles_fts MATCH ? LIMIT 5",
                    (query,)
                ).fetchall()
                for row in rows:
                    if row[0]:
                        results.append(f"--- Past conversation ---\n{row[0][:500]}")
            except sqlite3.OperationalError:
                # FTS not available, try basic search
                rows = conn.execute(
                    "SELECT summary FROM wake_cycles WHERE summary LIKE ? ORDER BY started_at DESC LIMIT 5",
                    (f"%{query.split()[0]}%",)
                ).fetchall()
                for row in rows:
                    if row[0]:
                        results.append(f"--- Past conversation ---\n{row[0][:500]}")
            conn.close()
        except Exception as e:
            logger.warning(f"[TOOL] Transcript search error: {e}")

    if not results:
        return f"No memory found matching '{query}'. Try broader terms."

    return "\n\n".join(results[:5])


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


# Global persistent session — survives reconnections
_global_session = AudioSession()


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
    """Get response from Claude (JARVIS brain) with tool-use support."""
    if not ANTHROPIC_API_KEY:
        logger.warning("No ANTHROPIC_API_KEY set, returning placeholder response")
        return f"I heard: \"{transcript}\". JARVIS brain is not connected yet — please set ANTHROPIC_API_KEY."

    user_content = transcript
    if health_data:
        health_ctx = json.dumps(health_data, ensure_ascii=False)
        user_content = f"{transcript}\n\n[Current health data: {health_ctx}]"

    # Use a local messages list for the multi-turn tool loop.
    # Only save the final user text + assistant text to conversation_history.
    conversation_history.append({"role": "user", "content": user_content})

    if len(conversation_history) > 20:
        conversation_history[:] = conversation_history[-20:]

    # Work on a copy so intermediate tool messages don't pollute history
    messages_for_api = list(conversation_history)

    max_tool_rounds = 5
    final_text = ""

    async with httpx.AsyncClient() as client:
        for round_num in range(max_tool_rounds):
            logger.info(f"Claude API call (round {round_num + 1})")
            response = await client.post(
                "https://api.anthropic.com/v1/messages",
                headers={
                    "x-api-key": ANTHROPIC_API_KEY,
                    "anthropic-version": "2023-06-01",
                    "content-type": "application/json",
                },
                json={
                    "model": "claude-sonnet-4-20250514",
                    "max_tokens": 1024,
                    "system": SYSTEM_PROMPT,
                    "tools": JARVIS_TOOLS,
                    "messages": messages_for_api,
                },
                timeout=60.0,
            )

            if response.status_code != 200:
                logger.error(f"Claude API error: {response.status_code} {response.text}")
                return "I'm having trouble processing that, sir. Please try again."

            result = response.json()
            stop_reason = result.get("stop_reason")
            content_blocks = result.get("content", [])

            # Collect text blocks for final response
            text_parts = []
            tool_uses = []
            for block in content_blocks:
                if block["type"] == "text":
                    text_parts.append(block["text"])
                elif block["type"] == "tool_use":
                    tool_uses.append(block)

            if text_parts:
                final_text = " ".join(text_parts)

            # If no tool use, we're done
            if stop_reason == "end_turn" or not tool_uses:
                break

            # Tool use: execute tools and feed results back (only in API messages, not history)
            messages_for_api.append({"role": "assistant", "content": content_blocks})

            tool_results = []
            for tool_use in tool_uses:
                tool_name = tool_use["name"]
                tool_input = tool_use["input"]
                tool_id = tool_use["id"]
                logger.info(f"Executing tool: {tool_name}({json.dumps(tool_input, ensure_ascii=False)[:200]})")

                result_str = await _execute_tool(tool_name, tool_input)
                logger.info(f"Tool result ({tool_name}): {result_str[:200]}")

                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": tool_id,
                    "content": result_str[:4000],
                })

            messages_for_api.append({"role": "user", "content": tool_results})

    if not final_text:
        final_text = "Done, sir."

    # Save only the final text response to history (no tool_use/tool_result blocks)
    conversation_history.append({"role": "assistant", "content": final_text})

    return final_text


def _is_chinese(text: str) -> bool:
    """Check if text contains CJK characters."""
    return any('\u4e00' <= ch <= '\u9fff' for ch in text)


async def generate_tts(text: str) -> bytes | None:
    """Generate TTS audio. Uses OpenAI for Chinese (Piper is English-only)."""
    if _is_chinese(text):
        return await _generate_tts_openai(text)

    if not Path(PIPER_MODEL).exists():
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
        _, stderr = await asyncio.wait_for(proc.communicate(input=text.encode("utf-8")), timeout=10.0)

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


async def _safe_send(ws, data: str) -> bool:
    """Send data to WebSocket, returning False if client disconnected."""
    try:
        if ws.closed:
            logger.warning("[WS] Client already disconnected, skipping send")
            return False
        await ws.send_str(data)
        return True
    except (ConnectionResetError, ConnectionError, RuntimeError) as e:
        logger.warning(f"[WS] Send failed (client disconnected): {e}")
        return False


async def _process_audio_and_respond(ws, session):
    """Process recorded audio: STT → LLM → TTS → send response."""
    audio_size = len(session.audio_buffer)
    if audio_size < 1600:
        resp = {"type": "response", "transcript": "I didn't catch that, sir. Could you repeat?"}
        await _safe_send(ws, json.dumps(resp))
        session.reset_audio()
        return

    # STT first, send user_transcript so app can show what was said
    user_transcript = await transcribe_audio(bytes(session.audio_buffer))
    if user_transcript:
        await _safe_send(ws, json.dumps({
            "type": "user_transcript",
            "text": user_transcript,
        }))

    if not user_transcript:
        resp = {"type": "response", "transcript": "I couldn't understand that. Could you try again?"}
        await _safe_send(ws, json.dumps(resp))
        session.reset_audio()
        return

    # LLM + TTS
    response_text = await get_jarvis_response(
        user_transcript, session.conversation_history, session.health_data or None
    )
    logger.info(f"Response ({len(response_text)} chars): {response_text[:100]}")

    resp: dict = {"type": "response", "transcript": response_text}
    if response_text:
        tts_audio = await generate_tts(response_text)
        if tts_audio:
            resp["audio"] = base64.b64encode(tts_audio).decode()
            resp["format"] = "wav" if tts_audio[:4] == b"RIFF" else "mp3"
    await _safe_send(ws, json.dumps(resp))
    session.reset_audio()


async def websocket_handler(request):
    ws = web.WebSocketResponse(heartbeat=20.0, autoping=True)
    await ws.prepare(request)
    session = _global_session
    session.reset_audio()
    logger.info(f"Client connected via aiohttp: {request.remote}")

    # Server-side silence detection: auto-process if no audio data arrives for 2s while recording
    last_audio_time = None
    SILENCE_TIMEOUT = 2.0  # seconds of no audio data → auto end-of-speech

    async def silence_watchdog():
        """Background task: if recording and no audio for SILENCE_TIMEOUT, auto-process."""
        nonlocal last_audio_time
        while not ws.closed:
            await asyncio.sleep(0.5)
            if session.is_recording and last_audio_time is not None:
                elapsed = asyncio.get_event_loop().time() - last_audio_time
                if elapsed >= SILENCE_TIMEOUT and len(session.audio_buffer) > 1600:
                    logger.info(f"Server-side silence detected ({elapsed:.1f}s), auto-processing...")
                    session.is_recording = False
                    try:
                        await _process_audio_and_respond(ws, session)
                    except Exception as e:
                        logger.error(f"Error in silence watchdog processing: {e}", exc_info=True)
                    last_audio_time = None

    watchdog_task = asyncio.ensure_future(silence_watchdog())

    try:
        async for msg in ws:
            if msg.type == web.WSMsgType.BINARY:
                if session.is_recording:
                    session.audio_buffer.extend(msg.data)
                    last_audio_time = asyncio.get_event_loop().time()
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
                    last_audio_time = asyncio.get_event_loop().time()
                    logger.info(f"Wake word detected: {cmd.get('keyword', 'unknown')}")
                elif msg_type == "end_of_speech":
                    session.is_recording = False
                    last_audio_time = None
                    logger.info("End of speech, processing...")
                    await _process_audio_and_respond(ws, session)
                elif msg_type == "health_data":
                    session.health_data = {k: v for k, v in cmd.items() if k != "type"}
                    logger.info(f"Health data updated: {list(session.health_data.keys())}")
                elif msg_type == "start_recording":
                    session.is_recording = True
                    session.audio_buffer = bytearray()
                    last_audio_time = asyncio.get_event_loop().time()
                elif msg_type == "stop_recording":
                    session.is_recording = False
                    last_audio_time = None
                    logger.info("Stop recording received, processing...")
                    await _process_audio_and_respond(ws, session)
                elif msg_type == "ping":
                    await ws.send_str(json.dumps({"type": "pong"}))
            elif msg.type == web.WSMsgType.ERROR:
                logger.error(f"WebSocket error: {ws.exception()}")
    except Exception as e:
        logger.error(f"Error handling client: {e}", exc_info=True)
    finally:
        watchdog_task.cancel()
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
