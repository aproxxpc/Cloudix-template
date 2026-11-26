#!/usr/bin/env python3
"""
Cloudix Real-Time Low-Latency Audio Streamer
Streams Linux PulseAudio / Desktop sound over HTTP to Web & Mobile clients
"""

import base64
import hashlib
import hmac
import json
import mimetypes
import os
import queue
import re
import select
import socket
import subprocess
import struct
import tempfile
import threading
import zipfile
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlparse

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
        try:
            self.process = subprocess.Popen(
                PCM_STREAM_CMD,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                bufsize=0,
            )
            self.reader = threading.Thread(target=self._read_audio, daemon=True)
            self.reader.start()
        except OSError as error:
            self.process = None
            print(f"WARNING: Could not start PulseAudio capture: {error}", flush=True)

    def add_client(self):
        if self.process is None or self.process.poll() is not None:
            code = self.process.returncode if self.process else -1
            raise RuntimeError(
                f"Audio capture exited with status {code}"
            )
        client_queue = queue.Queue(maxsize=2)
        with self.clients_lock:
            self.clients.add(client_queue)
        return client_queue

    def remove_client(self, client_queue):
        with self.clients_lock:
            self.clients.discard(client_queue)

    def _read_audio(self):
        if self.process is None or self.process.stdout is None:
            return
        pending = bytearray()
        try:
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
        except OSError:
            pass

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
            username = "cloudix"
            try:
                if CREDENTIALS_FILE.is_file():
                    found_user = next(
                        (
                            line.partition("=")[2]
                            for line in CREDENTIALS_FILE.read_text(encoding="utf-8").splitlines()
                            if line.startswith("username=")
                        ),
                        "",
                    )
                    if found_user:
                        username = found_user
            except OSError:
                pass
            vnc_ready = self._is_vnc_ready()
            payload = {
                "setup_required": SETUP_TOKEN_FILE.is_file(),
                "username": username,
                "vnc_ready": vnc_ready,
            }
            if not vnc_ready:
                vnc_error = self._get_vnc_error()
                if vnc_error:
                    payload["vnc_error"] = vnc_error
            self._send_json(200, payload)
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

        if clean_path == "/files":
            self._handle_list_files()
            return

        if clean_path == "/download":
            self._handle_download_file()
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

    def _is_port_listening(self, port):
        target_hex = f":{port:04X}"
        checked_proc = False
        for proc_path in ("/proc/net/tcp", "/proc/net/tcp6"):
            try:
                content = Path(proc_path).read_text(encoding="ascii")
                checked_proc = True
                for line in content.splitlines()[1:]:
                    fields = line.split()
                    if len(fields) >= 4 and fields[1].endswith(target_hex) and fields[3] == "0A":
                        return True
            except OSError:
                continue
        if checked_proc:
            return False
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1.0):
                return True
        except OSError:
            return False

    def _is_vnc_ready(self):
        return self._is_port_listening(5900) and self._is_port_listening(6082)

    def _get_vnc_error(self):
        try:
            boot_err = Path("/tmp/cloudix_boot_error.txt")
            if boot_err.is_file():
                text = " ".join(
                    boot_err.read_text(encoding="utf-8", errors="replace").splitlines()
                ).strip()
                if text:
                    return text[:350]
        except OSError:
            pass
        parts = []
        for label, log_path in (
            ("xtigervnc", "/tmp/xtigervnc.log"),
            ("xvfb", "/tmp/xvfb.log"),
            ("x11vnc", "/tmp/x11vnc.log"),
            ("websockify", "/tmp/websockify.log"),
        ):
            try:
                p = Path(log_path)
                if p.is_file():
                    lines = [
                        line.strip()
                        for line in p.read_text(
                            encoding="utf-8", errors="replace"
                        ).splitlines()
                        if line.strip()
                    ]
                    if lines:
                        parts.append(f"{label}: {lines[-1]}")
            except OSError:
                continue
        if parts:
            return " | ".join(parts)[:350]
        return ""

    def _send_json(self, status, body):
        encoded_body = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded_body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded_body)

    def _allowed_roots(self):
        roots = [Path.home().resolve()]
        workspaces = Path("/workspaces")
        if workspaces.exists():
            roots.append(workspaces.resolve())
        return roots

    def _quick_roots(self):
        home = Path.home()
        candidates = [
            ("Downloads", home / "Downloads"),
            ("Desktop", home / "Desktop"),
            ("Documents", home / "Documents"),
        ]
        workspaces = Path("/workspaces")
        if workspaces.is_dir():
            sub_repos = [
                child
                for child in sorted(workspaces.iterdir(), key=lambda p: p.name.lower())
                if child.is_dir() and not child.name.startswith(".")
            ]
            workspace_target = sub_repos[0] if len(sub_repos) == 1 else workspaces
            candidates.append(("Workspace", workspace_target))
        quick = []
        for label, directory in candidates:
            if directory.exists() or label == "Downloads":
                try:
                    directory.mkdir(parents=True, exist_ok=True)
                    quick.append({"name": label, "path": str(directory.resolve())})
                except OSError:
                    continue
        return quick

    def _resolve_safe_path(self, raw_path):
        try:
            candidate = Path(raw_path).expanduser().resolve()
        except OSError:
            return None
        for root in self._allowed_roots():
            if candidate == root or candidate.is_relative_to(root):
                return candidate
        return None

    def _handle_list_files(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        raw_path = (query.get("path") or [""])[0].strip()
        quick = self._quick_roots()
        if not raw_path:
            default_dir = (Path.home() / "Downloads").resolve()
            default_dir.mkdir(parents=True, exist_ok=True)
            target = default_dir
        else:
            target = self._resolve_safe_path(raw_path)
            if target is None:
                self._send_json(403, {"error": "Access to this path is restricted."})
                return

        if not target.exists() or not target.is_dir():
            self._send_json(404, {"error": "Directory not found."})
            return

        parent_path = None
        if target.parent != target and self._resolve_safe_path(str(target.parent)) is not None:
            parent_path = str(target.parent)

        entries = []
        try:
            children = sorted(
                target.iterdir(),
                key=lambda item: (not item.is_dir(), item.name.lower()),
            )
            for child in children:
                if child.name == ".git":
                    continue
                try:
                    is_dir = child.is_dir()
                    size = 0 if is_dir else child.stat().st_size
                except OSError:
                    continue
                entries.append(
                    {
                        "name": child.name,
                        "path": str(child),
                        "is_dir": is_dir,
                        "size": size,
                    }
                )
        except OSError as error:
            self._send_json(500, {"error": f"Could not list directory: {error}"})
            return

        self._send_json(
            200,
            {
                "path": str(target),
                "parent": parent_path,
                "roots": quick,
                "entries": entries,
            },
        )

    def _handle_download_file(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        raw_path = (query.get("path") or [""])[0].strip()
        if not raw_path:
            self._send_json(400, {"error": "File or folder path is required."})
            return

        target = self._resolve_safe_path(raw_path)
        if target is None:
            self._send_json(403, {"error": "Access to this path is restricted."})
            return
        if not target.exists():
            self._send_json(404, {"error": "File or folder not found."})
            return

        if target.is_file():
            self._stream_local_file(target, target.name)
            return

        if target.is_dir():
            tmp_path = None
            try:
                with tempfile.NamedTemporaryFile(
                    prefix="cloudix-dl-", suffix=".zip", delete=False
                ) as tmp:
                    tmp_path = Path(tmp.name)
                with zipfile.ZipFile(
                    tmp_path, "w", compression=zipfile.ZIP_DEFLATED
                ) as archive:
                    base_parent = target.parent
                    added_any = False
                    for root_dir, dir_names, file_names in os.walk(target):
                        dir_names[:] = [d for d in dir_names if d != ".git"]
                        root_path = Path(root_dir)
                        for filename in file_names:
                            file_path = root_path / filename
                            try:
                                arcname = file_path.relative_to(base_parent)
                                archive.write(file_path, arcname.as_posix())
                                added_any = True
                            except OSError:
                                continue
                    if not added_any:
                        archive.writestr(f"{target.name}/", "")
                self._stream_local_file(tmp_path, f"{target.name}.zip")
            except OSError as error:
                self._send_json(500, {"error": f"Could not package folder: {error}"})
            finally:
                if tmp_path is not None and tmp_path.exists():
                    try:
                        tmp_path.unlink()
                    except OSError:
                        pass
            return

        self._send_json(400, {"error": "Unsupported file type."})

    def _stream_local_file(self, file_path, download_name):
        try:
            file_size = file_path.stat().st_size
            with file_path.open("rb") as handle:
                mime_type, _ = mimetypes.guess_type(download_name)
                if download_name.lower().endswith(".apk"):
                    mime_type = "application/vnd.android.package-archive"
                content_type = mime_type or "application/octet-stream"
                safe_name = download_name.replace('"', "")
                encoded_name = quote(download_name)

                self.send_response(200)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(file_size))
                self.send_header(
                    "Content-Disposition",
                    f"attachment; filename=\"{safe_name}\"; filename*=UTF-8''{encoded_name}",
                )
                self.send_header("Cache-Control", "no-store")
                self.end_headers()

                while True:
                    chunk = handle.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except OSError as error:
            print(f"File stream error for {file_path}: {error}", flush=True)
            try:
                self._send_json(500, {"error": f"Could not read file: {error}"})
            except OSError:
                pass

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
