(() => {
    const isCloudixApp =
        new URLSearchParams(window.location.search).get("cloudix_app") === "1" ||
        window.__cloudixHideAudioButton === true;

    let audioContext = null;
    let socket = null;
    let nextStartTime = 0;
    let active = false;
    let toggleButton = null;

    function updateButton(label, pressed) {
        if (!toggleButton) {
            return;
        }
        toggleButton.textContent = label;
        toggleButton.setAttribute("aria-pressed", pressed ? "true" : "false");
    }

    async function disableAudio() {
        active = false;
        if (socket) {
            try {
                socket.close();
            } catch (_) {}
            socket = null;
        }
        if (audioContext) {
            try {
                await audioContext.close();
            } catch (_) {}
            audioContext = null;
        }
        nextStartTime = 0;
        updateButton("Sound Off", false);
        return false;
    }

    async function enableAudio() {
        if (active && socket && socket.readyState <= WebSocket.OPEN) {
            if (audioContext && audioContext.state === "suspended") {
                try {
                    await audioContext.resume();
                } catch (_) {}
            }
            return true;
        }

        updateButton("Connecting audio...", false);
        active = true;
        try {
            const AudioCtx = window.AudioContext || window.webkitAudioContext;
            audioContext = new AudioCtx({
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
                updateButton("Connecting audio...", false);
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
                updateButton("Sound On", true);
            });
            socket.addEventListener("error", async () => {
                await disableAudio();
                updateButton("Audio connection failed - tap to retry", false);
            });
            socket.addEventListener("close", () => {
                if (active) {
                    active = false;
                    updateButton("Sound Off", false);
                }
            });
            return true;
        } catch (error) {
            await disableAudio();
            updateButton("Sound unavailable - tap to retry", false);
            console.error("Cloudix desktop audio playback failed:", error);
            return false;
        }
    }

    window.cloudixBrowserAudio = {
        enable: enableAudio,
        disable: disableAudio,
        toggle: async () => (active ? disableAudio() : enableAudio()),
        isActive: () => active,
    };

    function addAudioControl() {
        if (document.getElementById("cloudix-audio-toggle")) {
            return;
        }

        const button = document.createElement("button");
        toggleButton = button;
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
            display: isCloudixApp ? "none" : "block",
        });

        button.addEventListener("click", async () => {
            if (active) {
                await disableAudio();
            } else {
                await enableAudio();
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
