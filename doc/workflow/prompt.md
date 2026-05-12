# GenieClaw — Workflow Diagram Prompts

Prompts for generating 8 architectural workflow diagrams that document how
GenieClaw works end-to-end. Each prompt is standalone — paste it into any
text-to-image diagram generator (or a Mermaid / PlantUML LLM) preceded by
the shared style preamble below.

Component names, ports, file paths, and config field names are written
verbatim from the codebase so the renderer should not paraphrase them.

## Shared style preamble (prepend to every prompt below)

```
Generate an architectural workflow diagram for "GenieClaw", a local home AI
assistant running on a Jetson Orin Nano with an ESP32-LyraT V4.3 I2S microphone
frontend. Style: clean, modern, isometric-or-flat architecture diagram with
rounded rectangular nodes, labeled arrows for data/control flow, distinct
colors for hardware (dark slate), Rust services (orange), C++ inference
binaries (blue), config/systemd (purple), external user-facing surfaces (green).
Use mono-spaced font for code/path labels. Include a title bar at top.
Background: light neutral. Resolution: 1920x1080. Avoid emojis. Component names
should appear EXACTLY as written below — these are real binaries, services,
files, and ports from the codebase.
```

If your renderer prefers Mermaid/PlantUML over a pixel image, swap
"architectural workflow diagram" for "Mermaid flowchart" (or
"PlantUML component diagram") and the rest carries over.

---

## 1. Entire workflow (one big picture)

```
Title: "GenieClaw — End-to-End System Workflow"

Show three horizontal swim lanes from top to bottom:
  (a) HARDWARE: ESP32-LyraT V4.3 (I2S mic) → Jetson 40-pin header (I2S2) →
      Jetson Orin Nano Super Devkit (7.6 GB iGPU) → speaker/headphone out
      → optional ESP32-C6 sidecar (Thread/Matter via UART /dev/ttyTHS1).
  (b) SERVICES on Jetson, grouped under "geniepod.target": homeassistant,
      genie-audio (one-shot AHUB route setup), genie-whisper +
      genie-whisper-warmup, genie-llm + genie-llm-warmup, genie-core,
      genie-governor, genie-health, genie-api, genie-mqtt.
  (c) USER SURFACES: voice push-to-talk (LyraT mic + speaker), chat UI
      (http://jetson:3000), dashboard (http://jetson:3080), Home Assistant
      (8123), Telegram bot (optional).

Draw clear arrows: audio in from LyraT to genie-core; HTTP between
genie-core and genie-llm (8080) and genie-whisper (8178); Piper TTS out via
aplay; Home Assistant calls; MQTT pub/sub on 1883. Mark systemd-managed
boundaries. Label the iGPU memory budget under genie-llm (~2.4 GB Phi-4-mini)
and genie-whisper (~487 MB whisper-small).
```

---

## 2. Voice pipeline workflow in detail

```
Title: "GenieClaw — Voice Pipeline (Push-to-Talk Cycle)"

Linear left-to-right flowchart, one cycle of voice_loop::voice_cycle(),
with timing markers shown above each transition:

  [User presses Enter]
    → flush_mic_buffer (1 s throwaway arecord) — drains stale samples
    → arecord -D plughw:APE,0 -c 2 -r 24000 -d 3   [≈3.02 s wall]
    → [AUDIO_CAPTURED marker stamped] (speech end)
    → preprocess_capture branches on audio_denoiser config:
        ├─ deepfilternet: sox(channels 1, highpass 100, lowpass 7000)
        │     → deep-filter --atten-lim-db 100
        │     → sox(gain -n -3)                    [≈820 ms total]
        ├─ sox: sox(channels 1, highpass, lowpass, noisered, compand, gain)
        └─ none: bandpass + compand + normalize only
    → aec::process_aec (skips stale references, NLMS otherwise)
    → stt::transcribe_via_server → HTTP POST → whisper-server :8178
        ─ whisper.cpp ggml-small, CUDA, flash-attn, model resident in iGPU
        ─ multipart/form-data: language=en, temperature=0.0,
          response_format=json
                                                    [≈285 ms warm]
    → [STT_DONE marker]
    → intent::assess_transcript (reject hallucinations / ambient narration)
    → conversation store append (user turn)
    → handle_quick_tool_for_voice (try memory_recall, get_time, etc.)
    → streaming::stream_and_speak:
        ─ build_memory_context_with_read_context
        ─ apply_reasoning_mode
        ─ HTTP POST → llama-server :8080 (Phi-4-mini Q4_K_M, --ctx-size 2048,
          --flash-attn on, GPU layers 999)
        ─ stream tokens → split into sentences
        ─ per sentence: tts::TtsEngine::speak → spawn Piper → spawn aplay
            ├─ [FIRST_SPEAK marker]
            └─ [FIRST_AUDIO marker — before aplay.stdin.write_all]
    → aplay finishes
    → half-duplex gate: tokio::sleep(post_tts_silence_ms = 1500 ms)
        ─ ALSA HW buffer drains, room reverb decays below no-speech-thold
    → extract::extract_and_store (background memory write)
    → loop back

In a side box, show the FIRST-REPLY LATENCY BANNER fields it produces once
per process:
    preprocess (DFN+sox)
    STT
    LLM until first sentence
    TTS first synth
    speech end → first audio
```

---

## 3. AI agent & system prompt workflow

```
Title: "GenieClaw — AI Agent Reasoning & System Prompt Composition"

Diagram showing how a user utterance becomes an LLM call:

  Inputs (left side, parallel):
    ─ User transcript (from STT, with detected_language)
    ─ Speaker identity (speaker_identity::identify → name + confidence)
    ─ Memory read context (build_memory_read_context)
    ─ Conversation history (recent N turns, max_history_turns = 20)
    ─ System prompt template (prompt::build for model="phi", family=Phi)
    ─ Memory injection (inject::build_memory_context_with_read_context →
       per-query namespace tree lookup + shared-room redaction filter)
    ─ Reasoning mode (reasoning::apply_reasoning_mode →
       InteractionKind::Voice)

  → Composed messages: [system, ...history, user]
  → LLM streaming call (genie-llm at :8080, streaming response)
  → Token stream → response text

  → Tool detection: tools::try_tool_call_with_context →
        ToolExecutionContext { memory_read_context, request_origin=Voice,
        confirmed=false }
       → ToolDispatcher
       → On hit: tool_result.tool + tool_result.output

  → If tool hit: build summary_msgs (with summary system prompt),
      apply_reasoning_mode (InteractionKind::ToolSummary), second LLM
      call, speak the summary.

  → Auto-fact capture: extract::extract_and_store (after TTS, non-blocking)

Show distinct lanes for:
  ─ "system prompt" (purple)
  ─ "memory" (green, with sub-boxes: durable MEMORY.md, namespaces/INDEX.md,
     person/private/restricted notes — redaction-aware projection)
  ─ "tools" (orange, with sub-boxes: get_time, memory_recall, web_search,
     home_status, home_control, plus skill-loaded tools)
  ─ "actuation safety gate" (red) intercepts home_control before execution.
```

---

## 4. ESP32 + Thread/WiFi/BLE/Home Assistant integration

```
Title: "GenieClaw — ESP32 Sidecar & Home/Network Integration"

Show TWO ESP32 boards distinctly:

  (1) ESP32-LyraT V4.3 (capture-only mic frontend):
      ─ Custom IDF firmware "lyrat_jp4_passthrough" (in
        espressif/esp-adf fork)
      ─ ES8388 codec → MCLK/SCLK/LRCK/SDOUT pins → JP4 connector
      ─ Wires to Jetson 40-pin header: GPIO5 SCLK, GPIO25 LRCK,
        GPIO35 ASDOUT, GPIO0 MCLK
      ─ Pure I2S slave, no networking
      ─ Firmware flashed via Windows ESP32 flash download tool over
        single USB-micro-B

  (2) ESP32-C6 (optional connectivity sidecar):
      ─ Thread/Matter via UART /dev/ttyTHS1 @ 115200 (configurable
        device_path /dev/ttyACM0 or /dev/ttyUSB0 on dev boards)
      ─ MTU 1024, response_timeout_ms 250
      ─ Reset GPIO 24, no hardware flow control
      ─ Connects to Thread border router / Matter fabric for home devices
      ─ Configured via [connectivity] block in geniepod.toml

  Jetson runtime networking:
      ─ WiFi LAN → Home Assistant container (homeassistant.service,
        :8123) — HA_TOKEN auth
      ─ MQTT broker (mosquitto.conf, port 1883) — local subscription
        for genie-mqtt
      ─ Optional Telegram long-poll (TELEGRAM_BOT_TOKEN, allowlist by
        chat_id)
      ─ Optional ESP32-C6 commands relayed from voice/HA/Telegram via
        genie-core's connectivity subsystem (currently state=Disabled
        by default)

  Show how a "turn on kitchen light" voice command flows:
    voice → STT → LLM → tool_call "home_control"
      → actuation_safety::evaluate (confidence ≥ 0.78, allowed_origins,
         rate_limit max_actions_per_minute_by_origin)
      → HA REST API → device state changes
      → genie-mqtt picks up state change event
      → genie-core speaks confirmation via Piper
```

---

## 5. OS / Bring-up workflow

```
Title: "GenieClaw — OS, First-Boot & Service Bring-Up"

Vertical flow from "Jetson boot" to "voice loop ready":

  POWER ON → JetPack 6.x → systemd starts geniepod.target
  geniepod.target pulls in (in dependency order, parallel where possible):

    ─ [5b/6] nvpmodel -m 1 (25 W max), jetson_clocks (max)
    ─ /etc/sysctl.d/99-geniepod.conf applied (vm.min_free_kbytes etc.)
    ─ Optional: cma=256M boot-arg already set on extlinux.conf

    Service tree:
    ┌── homeassistant.service (docker compose, :8123)
    ├── genie-audio.service (one-shot)
    │     /opt/geniepod/bin/genie-audio-init
    │     amixer cset I2S2 routes:
    │       ADMAIF1 Mux = I2S2, codec master cbm-cfm, i2s framing,
    │       I2S2 Sample Rate = 24000, channels=2, bits=16
    ├── genie-whisper.service (whisper-server :8178, ggml-small, CUDA)
    │     │
    │     └─ After: genie-whisper-warmup.service (one-shot)
    │           ─ nc -z :8178 (poll readiness ≤ 90 s)
    │           ─ sox -n -r 16000 -c 1 trim 0 1 → silent WAV
    │           ─ curl -F file=@<wav> -F language=en :8178/inference
    │           ─ forces ggml-small + CUDA kernels into iGPU
    ├── genie-llm.service (llama-server :8080, Phi-4-mini Q4_K_M,
    │     --ctx-size 2048, --n-gpu-layers 999, --flash-attn on)
    │     │
    │     └─ After: genie-llm-warmup.service (one-shot)
    │           ─ curl /health poll ≤ 90 s
    │           ─ curl POST /completion {"prompt":"hi","n_predict":1}
    │           ─ forces Phi-4-mini into iGPU
    ├── genie-core.service (main runtime, :3000)
    ├── genie-governor.service (memory pressure / model swap)
    ├── genie-health.service (alert webhook, 30 s polls)
    ├── genie-api.service (dashboard :3080)
    └── genie-mqtt.service (mosquitto bridge)

  Side box: setup-jetson.sh phases (one-time deploy audit):
    [1/6] mkdir; clean stale drop-ins
    [2/6] verify 6 Rust binaries
    [3/6] /etc/geniepod/geniepod.toml chmod 600
    [4/6] Phi-4-mini-instruct-Q4_K_M.gguf present (auto-download
          from HuggingFace if default path)
    [5/6] llama-server present
    [5b] nvpmodel, jetson_clocks
    [5c] sysctl + CMA hints
    [5e] voice prereqs audit (whisper-cli, whisper-server, sox,
          ggml-small.bin, piper, voice .onnx + .onnx.json)
    [5f] deep-filter binary auto-download
          (deep-filter-0.5.6-aarch64-unknown-linux-gnu, ~39 MB)
    [6/6] systemctl enable each genie-* unit + geniepod.target
```

---

## 6. Security workflow

```
Title: "GenieClaw — Security Boundaries, Gates & Audit"

Cross-sectional view showing layered enforcement:

  STARTUP AUDIT (genie-core::security::run_audit):
    ─ Critical: data dir world-readable → flag for chmod 700
    ─ Warn: data dir group-readable
    ─ Warn: ha_token plaintext in config (suggest env)
    ─ Warn: process running as root (suggest dedicated geniepod uid)
    ─ Info: HTTP API bound to 127.0.0.1 only (not exposed)
    ─ Info: sensitive env vars (HA_TOKEN, TELEGRAM_BOT_TOKEN, *_KEY,
       *_SECRET, *_TOKEN) excluded from tool execution

  REQUEST ORIGIN AT ENTRY:
    voice → ToolExecutionContext { request_origin: Voice }
    api   → ToolExecutionContext { request_origin: Api }
    telegram → ToolExecutionContext { request_origin: Telegram }
    repl  → ToolExecutionContext { request_origin: Repl }

  TOOL GATE (CoreConfig.tool_policy — partially enforced today,
  fully enforced under issue #22):
    allowed_tools_by_origin / denied_tools_by_origin / wildcards
    rate-limit window: max_actions_per_minute / per origin
    confirmation flow: confirmed=false → require second call

  ACTUATION SAFETY (CoreConfig.actuation_safety):
    min_target_confidence ≥ 0.78
    min_sensitive_confidence ≥ 0.90
    deny_multi_target_sensitive = true
    require_available_state = true
    allowed_origins list
    sliding-window rate caps per origin

  SKILL LOADER (CoreConfig.skill_policy):
    require_manifest / require_signature
    denied_permissions list (network.raw, filesystem.write, …)
    each loaded skill's manifest hash logged

  AUDIT TRAIL (today):
    /opt/geniepod/data/runtime/contracts.jsonl ← prompt + tool + policy
    contract hashes recorded each boot

  AUDIT TRAIL (beta-track #24):
    /opt/geniepod/data/audit/events.jsonl ← append-only, hash-chained
    events: voice_cycle, tool_call_decision, tool_call_executed,
    actuation, memory_write, skill_load, config_change
    daily rotation + sealed footer signature
    genie-ctl audit { tail | verify | export }

  BETA-TRACK GAPS (call out as TODO in red):
    #22 single chokepoint enforcement for tool calls
    #23 drop root, landlock/bubblewrap, subprocess + network allowlists
    #24 tamper-evident hash-chained audit log
```

---

## 7. LLM runtime workflow (genie-ai-runtime)

```
Title: "GenieClaw — LLM Runtime (llama.cpp on iGPU)"

Show the LLM serving subsystem in detail:

  STATIC CONFIG:
    /opt/geniepod/models/phi-4-mini-instruct-q4_k_m.gguf (~2.4 GB)
    llama-server invocation flags from genie-llm.service:
      --model <path>
      --host 0.0.0.0 --port 8080
      --ctx-size 2048          ← halved from 4096 in #2
      --n-gpu-layers 999
      --threads 4
      --parallel 1
      --flash-attn on
      --no-warmup              ← warmup handled by genie-llm-warmup

    Inline NOTE in service unit: --cache-type-k/v q4_0 quant disabled —
    crashes Phi-3/Phi-4 attn graph on aarch64 CUDA via ggml_reshape_2d.

  iGPU MEMORY BUDGET (7.6 GB Orin Nano total):
    Phi-4-mini Q4_K_M weights      ~2.4 GB
    KV cache (ctx=2048, fp16)       ~570 MB
    whisper-small + CUDA kernels    ~487 MB + activations
    DeepFilterNet (subprocess)      tract-loaded, ~50 MB peak
    Piper (subprocess per call)     short-lived, ~100 MB
    System / other                  ~3 GB headroom

  BOOT SEQUENCE:
    systemd starts genie-llm.service:
      ExecStartPre: sync && drop_caches (3) ← Jetson NvMap wants
                                              contiguous blocks
      llama-server boots, loads weights, opens :8080
    genie-llm-warmup.service:
      poll /health ≤ 90 s
      POST /completion {"prompt":"hi","n_predict":1}
      → first inference loads kernels + materializes attention
        scratchpads → "warm"

  REQUEST PATH (per voice cycle):
    genie-core → HTTP /completion (streaming) on :8080
    body: { messages: [system, ...history, user],
            max_tokens: 256, temperature varies by reasoning mode,
            stream: true }
    → token stream → genie-core buffers tokens
    → streaming::stream_and_speak (current: waits for full stream,
       then splits sentences; #26 will stream sentences as they
       complete)

  GOVERNOR INTERACTION (genie-governor.service):
    poll_interval_ms = 5000
    night_start_hour 23, day_start_hour 6
    night_model_swap toggle (off by default; would swap to 9B at night)
    pressure thresholds:
      stop_optins_mb (Nextcloud/Jellyfin) = 500
      reduce_context_mb = 300
      swap_stt_mb = 200 (downgrade whisper to tiny)
      zram_mb = 100 (enable 2 GB zram as last resort)

  TUNING LEVERS (color callouts):
    ─ #25 future CPU pinning (whisper cores 2-3, llama core 4,
       genie-core core 5)
    ─ #26 future real streaming TTS
    ─ #5  future whisper-medium fallback with context-aware
       confidence escalation
```

---

## 8. Memory & conversation data flow

```
Title: "GenieClaw — Memory, Conversation & Speaker Identity Data Flow"

Show the per-utterance data flow through the memory subsystem:

  USER UTTERANCE (after STT) →
    ┌────────────────────────────────────────────────────────────────┐
    │ speaker_identity::identify                                     │
    │   provider: none | fixed | local_biometric                     │
    │   inputs: wav_path, transcript, detected_language              │
    │   output: SpeakerIdentity { name, confidence }                 │
    │   storage: /opt/geniepod/data/speakers/                        │
    └────────────────────────────────────────────────────────────────┘
        ↓
    ┌────────────────────────────────────────────────────────────────┐
    │ identity::build_memory_read_context                             │
    │   filters: shared-room safety (default), redaction rules        │
    │   sensitivity: shared | person | private | restricted           │
    │   spoken_policy: allowed | redacted                             │
    └────────────────────────────────────────────────────────────────┘
        ↓
    ┌────────────────────────────────────────────────────────────────┐
    │ inject::build_memory_context_with_read_context                 │
    │   ranks: durable MEMORY.md + namespaces/ + INDEX.md             │
    │   redaction: non-shared-safe entries projected as [redacted]    │
    │   output: "Relevant household context:" prelude appended to     │
    │           the system prompt                                     │
    └────────────────────────────────────────────────────────────────┘
        ↓
       LLM → response

  POST-RESPONSE BACKGROUND TASK:
    extract::extract_and_store
      ─ heuristic + LLM-assisted extraction of durable facts
      ─ tags: scope, sensitivity, spoken_policy
      ─ writes to memory store (sqlite + markdown projection)

  PERSISTENT STATE:
    sqlite (conversation_store):
      conv_id, role, content, tool_name (optional),
      created_at; bounded by max_history_turns
    durable memory:
      memory/MEMORY.md         ← shared-room safe entries only
      memory/INDEX.md          ← generated tree entry point
      memory/namespaces/       ← person / private / restricted
                                 (markdown projection of structured
                                  rows, redacted by default)
      data/runtime/contracts.jsonl  ← prompt/tool/policy hashes
                                       at each boot

  TOOL `memory_recall`:
    voice → "Who is Christine?"
    → memory_recall(query)
    → fuzzy + namespace-scoped search bounded by read_context
    → returns short fact ("Your name is Jared")
    → LLM speaks summary via Piper

  CONFIG KNOBS:
    [core] max_history_turns = 20
    [core.speaker_identity] enabled, provider, fixed_name,
                            fixed_confidence, local_profile_dir,
                            local_min_score
```
