(() => {
    function addAudioControl() {
        if (document.getElementById("cloudix-audio-toggle")) {
            return;
        }

        const button = document.createElement("button");
        button.id = "cloudix-audio-toggle";
        button.type = "button";
        button.textContent = "Sound Off";
        button.setAttribute("aria-pressed", "false");
        Object.assign(button.style, {
            position: "fixed",
            bottom: "12px",
            right: "12px",
            zIndex: "10000",
            border: "1px solid rgba(255,255,255,.25)",
            borderRadius: "10px",
            padding: "10px 14px",
            background: "rgba(30,35,45,.92)",
            color: "#fff",
            font: "600 14px system-ui, sans-serif",
            cursor: "pointer",
            touchAction: "manipulation",
        });

        let audioContext = null;
        let socket = null;
        let nextStartTime = 0;
        let active = false;

        button.addEventListener("click", async () => {
            if (active) {
                active = false;
                if (socket) {
                    socket.close();
                    socket = null;
                }
                if (audioContext) {
                    await audioContext.close();
                    audioContext = null;
                }
                nextStartTime = 0;
                button.textContent = "Sound Off";
                button.setAttribute("aria-pressed", "false");
                return;
            }

            button.textContent = "Connecting audio...";
            active = true;
            try {
                audioContext = new AudioContext({
                    latencyHint: "interactive",
                    sampleRate: 32000,
                });
                nextStartTime = 0;
                await audioContext.resume();

                const endpoint = new URL("/audiows", window.location.href);
                endpoint.protocol = endpoint.protocol === "https:" ? "wss:" : "ws:";
                socket = new WebSocket(endpoint);
                socket.binaryType = "arraybuffer";
                socket.addEventListener("open", () => {
                    button.textContent = "Connecting audio...";
                });
                socket.addEventListener("message", (event) => {
                    if (!(event.data instanceof ArrayBuffer) || !audioContext) {
                        return;
                    }

                    const samples = event.data.byteLength / 2;
                    if (!Number.isInteger(samples) || samples === 0) {
                        return;
                    }
                    const now = audioContext.currentTime;
                    if (nextStartTime > now + 0.08) {
                        return;
                    }

                    const buffer = audioContext.createBuffer(1, samples, 32000);
                    const pcm = new DataView(event.data);
                    const channel = buffer.getChannelData(0);
                    for (let index = 0; index < samples; index++) {
                        channel[index] = pcm.getInt16(index * 2, true) / 32768;
                    }

                    const source = audioContext.createBufferSource();
                    source.buffer = buffer;
                    source.connect(audioContext.destination);
                    nextStartTime = Math.max(nextStartTime, now + 0.03);
                    source.start(nextStartTime);
                    nextStartTime += buffer.duration;
                    button.textContent = "Sound On";
                    button.setAttribute("aria-pressed", "true");
                });
                socket.addEventListener("error", async () => {
                    active = false;
                    if (socket) {
                        socket.close();
                        socket = null;
                    }
                    if (audioContext) {
                        await audioContext.close();
                        audioContext = null;
                    }
                    button.textContent = "Audio connection failed - tap to retry";
                    button.setAttribute("aria-pressed", "false");
                });
                socket.addEventListener("close", () => {
                    if (active) {
                        active = false;
                        button.textContent = "Sound Off";
                        button.setAttribute("aria-pressed", "false");
                    }
                });
            } catch (error) {
                active = false;
                if (audioContext) {
                    await audioContext.close();
                    audioContext = null;
                }
                button.textContent = "Sound unavailable - tap to retry";
                button.setAttribute("aria-pressed", "false");
                console.error("Cloudix desktop audio playback failed:", error);
            }
        });

        document.body.appendChild(button);
    }

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", addAudioControl, { once: true });
    } else {
        addAudioControl();
    }
})();
