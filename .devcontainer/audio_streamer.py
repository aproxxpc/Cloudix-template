#!/usr/bin/env python3
"""
Cloudix Real-Time Low-Latency Audio Streamer
Streams Linux PulseAudio / Desktop sound over HTTP to Web & Mobile clients
"""

import base64
import hashlib
import hmac
import json
import os
import queue
import re
import select
import socket
import subprocess
import struct
import threading
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 6081
AUDIO_SOURCE = os.environ.get("CLOUDIX_AUDIO_SOURCE", "Speaker.monitor")
FFMPEG_CMD = [
    "ffmpeg",
    "-nostdin",
    "-f", "pulse",
    "-fragment_size", "2048",
    "-i", AUDIO_SOURCE,
    "-ac", "2",
    "-ar", "48000",
    "-b:a", "128k",
    "-c:a", "libmp3lame",
    "-reservoir", "0",
    "-content_type", "audio/mpeg",
    "-f", "mp3",
    "-"
]
PCM_STREAM_CMD = [
    "ffmpeg",
    "-nostdin",
    "-hide_banner",
    "-loglevel", "error",
    "-f", "pulse",
    "-fragment_size", "2048",
    "-i", AUDIO_SOURCE,
    "-ac", "1",
    "-ar", "32000",
    "-c:a", "pcm_s16le",
    "-flush_packets", "1",
    "-f", "s16le",
    "-"
]
PCM_FRAME_BYTES = 32000 * 2 // 50
CLOUDIX_CONFIG_DIR = Path.home() / ".config" / "cloudix"
SETUP_TOKEN_FILE = CLOUDIX_CONFIG_DIR / "setup-token"
CREDENTIALS_FILE = CLOUDIX_CONFIG_DIR / "credentials"
HTPASSWD_FILE = CLOUDIX_CONFIG_DIR / "nginx.htpasswd"
SETUP_LOCK = threading.Lock()


class AudioBroadcaster:
    def __init__(self):
        self.clients = set()
        self.clients_lock = threading.Lock()
        self.process = subprocess.Popen(
            PCM_STREAM_CMD,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            bufsize=0,
        )
        self.reader = threading.Thread(target=self._read_audio, daemon=True)
        self.reader.start()

    def add_client(self):
        if self.process.poll() is not None:
            raise RuntimeError(
                f"Audio capture exited with status {self.process.returncode}"
            )
        client_queue = queue.Queue(maxsize=2)
        with self.clients_lock:
            self.clients.add(client_queue)
        return client_queue

    def remove_client(self, client_queue):
        with self.clients_lock:
            self.clients.discard(client_queue)

    def _read_audio(self):
        pending = bytearray()
        while True:
            chunk = os.read(
                self.process.stdout.fileno(), PCM_FRAME_BYTES - len(pending)
            )
            if not chunk:
                break
            pending.extend(chunk)
            if len(pending) == PCM_FRAME_BYTES:
                self._broadcast(bytes(pending))
                pending.clear()

        if self.process.poll() is not None:
            print(
                f"ERROR: PulseAudio capture exited with status "
                f"{self.process.returncode}",
                flush=True,
            )

    def _broadcast(self, frame):
        with self.clients_lock:
            for client_queue in tuple(self.clients):
                try:
                    client_queue.put_nowait(frame)
                except queue.Full:
                    try:
                        client_queue.get_nowait()
                    except queue.Empty:
                        pass
                    try:
                        client_queue.put_nowait(frame)
                    except queue.Full:
                        pass


class AudioStreamHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Quiet logging

    def setup(self):
        super().setup()
        self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Type", "audio/mpeg")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

    def do_GET(self):
        clean_path = self.path.split("?")[0].rstrip("/")
        if clean_path == "/setup-status":
            try:
                username = next(
                    (
                        line.partition("=")[2]
                        for line in CREDENTIALS_FILE.read_text(encoding="utf-8").splitlines()
                        if line.startswith("username=")
                    ),
                    "",
                )
            except OSError:
                self._send_json(500, {"error": "Could not read desktop credentials."})
                return
            self._send_json(
                200,
                {
                    "setup_required": SETUP_TOKEN_FILE.is_file(),
                    "username": username,
                },
            )
            return

        if clean_path == "/audiows":
            self.do_audio_websocket()
            return

        if clean_path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(b"OK")
            return

        if clean_path.startswith("/launch"):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()

            env = dict(os.environ)
            env["DISPLAY"] = ":1"
            if "terminal" in self.path:
                subprocess.Popen(["xfce4-terminal", "--disable-server"], env=env)
            elif "chrome" in self.path:
                subprocess.Popen(
                    [
                        "google-chrome-stable",
                        "--no-sandbox",
                        "--disable-background-networking",
                        "--disable-component-update",
                        "--disable-sync",
                        "--no-first-run",
                    ],
                    env=env,
                )
            elif "code" in self.path:
                subprocess.Popen(["code", "--no-sandbox"], env=env)
            self.wfile.write(b'{"status":"launched"}')
            return

        try:
            proc = subprocess.Popen(
                FFMPEG_CMD,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                bufsize=0,
            )
        except OSError as error:
            self.send_error(503, f"Could not start audio capture: {error}")
            return
        if proc.poll() is not None:
            self.send_error(503, f"Audio capture exited with status {proc.returncode}")
            return

        self.send_response(200)
        self.send_header("Content-Type", "audio/mpeg")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        try:
            while True:
                chunk = os.read(proc.stdout.fileno(), 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            if proc:
                proc.terminate()
                try:
                    proc.wait(timeout=1)
                except Exception:
                    proc.kill()

    def do_POST(self):
        clean_path = self.path.split("?")[0].rstrip("/")
        if clean_path != "/setup-auth":
            self.send_error(404)
            return

        with SETUP_LOCK:
            if not SETUP_TOKEN_FILE.is_file():
                self._send_json(409, {"error": "Desktop credentials are already set."})
                return

            try:
                content_length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                self._send_json(400, {"error": "Invalid request length."})
                return
            if content_length <= 0 or content_length > 8192:
                self._send_json(413, {"error": "Request is too large."})
                return

            try:
                request_data = json.loads(self.rfile.read(content_length))
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._send_json(400, {"error": "Invalid setup request."})
                return
            if not isinstance(request_data, dict):
                self._send_json(400, {"error": "Invalid setup request."})
                return

            setup_token = request_data.get("setup_token")
            username = request_data.get("username")
            password = request_data.get("password")
            if not all(isinstance(value, str) for value in (setup_token, username, password)):
                self._send_json(400, {"error": "Setup code, username, and password are required."})
                return
            if not re.fullmatch(r"[a-f0-9]{48}", setup_token):
                self._send_json(403, {"error": "The one-time setup code is invalid."})
                return
            if not re.fullmatch(r"[A-Za-z0-9._-]{1,39}", username):
                self._send_json(400, {"error": "Username must be 1–39 letters, numbers, dots, dashes, or underscores."})
                return
            if len(password) < 12 or len(password) > 128 or any(
                character in password for character in "\r\n\x00"
            ):
                self._send_json(400, {"error": "Password must be 12–128 characters and cannot contain line breaks."})
                return

            try:
                expected_token = SETUP_TOKEN_FILE.read_text(encoding="utf-8").strip()
            except OSError:
                self._send_json(500, {"error": "Could not read the one-time setup code."})
                return
            if not expected_token or not hmac.compare_digest(setup_token, expected_token):
                self._send_json(403, {"error": "The one-time setup code is invalid."})
                return

            try:
                hash_result = subprocess.run(
                    ["openssl", "passwd", "-apr1", "-stdin"],
                    input=password.encode("utf-8"),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    check=True,
                )
                password_hash = hash_result.stdout.decode("ascii").strip()
                self._atomic_write(
                    CREDENTIALS_FILE,
                    f"username={username}\npassword={password}\n",
                    0o600,
                )
                self._atomic_write(
                    HTPASSWD_FILE,
                    f"{username}:{password_hash}\n",
                    0o640,
                )
                SETUP_TOKEN_FILE.unlink()
            except (OSError, subprocess.CalledProcessError, UnicodeDecodeError):
                self._send_json(500, {"error": "Could not save desktop credentials."})
                return

        self._send_json(200, {"status": "credentials_set"})

    def _atomic_write(self, destination, content, mode):
        temporary = destination.with_name(destination.name + ".tmp")
        try:
            temporary.write_text(content, encoding="utf-8")
            os.chmod(temporary, mode)
            os.replace(temporary, destination)
        finally:
            if temporary.exists():
                temporary.unlink()

    def _send_json(self, status, body):
        encoded_body = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded_body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded_body)

    def do_audio_websocket(self):
        key = self.headers.get("Sec-WebSocket-Key")
        if self.headers.get("Upgrade", "").lower() != "websocket" or not key:
            self.send_error(400, "A WebSocket upgrade is required")
            return

        try:
            client_queue = self.server.audio_broadcaster.add_client()
        except RuntimeError as error:
            self.send_error(503, str(error))
            return

        accept = base64.b64encode(
            hashlib.sha1(
                (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")
            ).digest()
        ).decode("ascii")
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.wfile.flush()

        try:
            while True:
                readable, _, _ = select.select([self.connection], [], [], 0)
                if readable:
                    if not self._handle_websocket_control():
                        break
                try:
                    frame = client_queue.get(timeout=0.02)
                except queue.Empty:
                    continue
                self._send_websocket_frame(frame)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            self.server.audio_broadcaster.remove_client(client_queue)
            self.close_connection = True

    def _handle_websocket_control(self):
        header = self._recv_exact(2)
        if header is None:
            return False
        opcode = header[0] & 0x0F
        masked = bool(header[1] & 0x80)
        payload_length = header[1] & 0x7F
        if payload_length == 126:
            extended = self._recv_exact(2)
            if extended is None:
                return False
            payload_length = struct.unpack("!H", extended)[0]
        elif payload_length == 127:
            extended = self._recv_exact(8)
            if extended is None:
                return False
            payload_length = struct.unpack("!Q", extended)[0]

        mask = self._recv_exact(4) if masked else b""
        if mask is None:
            return False
        payload = self._recv_exact(payload_length)
        if payload is None:
            return False
        payload = bytearray(payload)
        if masked:
            for index in range(len(payload)):
                payload[index] ^= mask[index % 4]

        if opcode == 8:
            self._send_websocket_frame(bytes(payload), opcode=8)
            return False
        if opcode == 9:
            self._send_websocket_frame(bytes(payload), opcode=10)
        return True

    def _recv_exact(self, size):
        data = bytearray()
        while len(data) < size:
            chunk = self.connection.recv(size - len(data))
            if not chunk:
                return None
            data.extend(chunk)
        return bytes(data)

    def _send_websocket_frame(self, payload, opcode=2):
        length = len(payload)
        if length < 126:
            header = bytes((0x80 | opcode, length))
        elif length <= 0xFFFF:
            header = bytes((0x80 | opcode, 126)) + struct.pack("!H", length)
        else:
            header = bytes((0x80 | opcode, 127)) + struct.pack("!Q", length)
        self.wfile.write(header + payload)
        self.wfile.flush()

def main():
    print(f"=== [Cloudix Audio] Starting PulseAudio Streamer on port {PORT} ===")
    ThreadingHTTPServer.allow_reuse_address = True
    server = ThreadingHTTPServer(("127.0.0.1", PORT), AudioStreamHandler)
    server.audio_broadcaster = AudioBroadcaster()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == "__main__":
    main()
