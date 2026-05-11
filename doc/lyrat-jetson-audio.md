# LyraT / I2S2 Audio Frontend (Jetson Orin Nano)

GenieClaw can use an **ESP32-LyraT V4.3** wired to the Jetson Orin Nano 40-pin
header as its microphone frontend. The Jetson treats the LyraT as a passive
I2S source via the Tegra APE AHUB and surfaces it as `plughw:APE,0` for ALSA.

This document is the GenieClaw-specific install slice; the full step-by-step
bring-up (firmware, wiring, pinmux overlay, byte-exact verification) lives in
the hardware curriculum:

- [ai-hardware-engineer-roadmap — ESP32-LyraT I2S Mic on Jetson Orin Nano](https://github.com/ai-hpc/ai-hardware-engineer-roadmap/tree/main/Phase%204%20-%20Track%20B%20-%20Nvidia%20Jetson/5.%20Application%20Development/4.%20Multimedia/ESP32-LyraT-I2S-Mic-Jetson-Orin-Nano)

That guide is the source of truth for hardware setup. Sections below cover
only the GenieClaw integration.

## What this gets you

- LyraT onboard L+R microphones (3.5 cm apart) as `arecord -D plughw:APE,0`
- The existing `genie-core` voice loop unchanged — it already takes
  `audio_device` from config and shells out to `arecord` / `aplay`
- Boot-time AHUB route applied by `genie-audio.service` so no manual `amixer`
  after reboot

## Prerequisites on the Jetson

Done **before** running `make deploy`:

1. Flash LyraT with the `lyrat_jp4_passthrough` firmware (see the roadmap
   guide §9). Verify with PuTTY/screen on the LyraT's USB serial — you should
   see `JP4_PASSTHROUGH: rate=192000 B/s` every 2 s.
2. Wire 4 jumpers between LyraT JP4 and Jetson 40-pin header:
   `SCLK→12`, `LRCK→35`, `ASDOUT→38`, `GND→6`.
3. Enable the 40-pin I2S2 overlay: `sudo /opt/nvidia/jetson-io/jetson-io.py`,
   pick I2S2 from the 40-pin configurator, save, reboot.
4. Confirm controls exist: `amixer -c APE controls | grep I2S2 | wc -l`
   should report ≥18.

## GenieClaw side

The deploy pipeline now installs `/opt/geniepod/bin/genie-audio-init`, which
the existing `genie-audio.service` runs after `sound.target`. It sets:

```
ADMAIF1 Mux                    = I2S2
I2S2 codec master mode         = cbm-cfm   (external master drives BCLK + LRCK)
I2S2 codec frame mode          = i2s
I2S2 Sample Rate               = 48000
I2S2 Capture Audio Channels    = 2
I2S2 Capture Audio Bit Format  = 16
I2S2 Client  Channels          = 2
I2S2 Client  Bit Format        = 16
ADMAIF1 Capture Audio Channels = 2
ADMAIF1 Capture Client Channels= 2
```

Config (`/etc/geniepod/geniepod.toml`):

```toml
[core]
voice_enabled    = true
audio_device     = "auto"           # auto-detect picks plughw:APE,0 when the
                                    # ADMAIF1 -> I2S2 route is configured.
                                    # Or pin explicitly: "plughw:APE,0"
audio_sample_rate = 48000
wakeword_script  = ""               # empty = push-to-talk mode; set to
                                    # /opt/geniepod/bin/genie-wake-listen.py
                                    # once you want wake-word detection.
```

The `record_audio` helper in `genie-core` records mono. ALSA's `plughw:`
plugin downmixes the LyraT stereo to mono and resamples 48 kHz → 16 kHz for
Whisper, so no Rust changes are needed.

## Verify after deploy

On the Jetson:

```bash
# Route applied?
amixer -c APE cget name="ADMAIF1 Mux" | grep -E ': values'
# 4-second test capture
arecord -D plughw:APE,0 -c 1 -r 16000 -f S16_LE -d 4 /tmp/test.wav
sox /tmp/test.wav -n stat
# Should show non-zero RMS amplitude.
```

If the test WAV is silent, work back through the roadmap guide §14 ("Verified
test result — Jetson side") — that section enumerates the failure modes and
which `amixer` control or wire to inspect for each.

## Limitations / known gaps

- Capture only. TTS playback goes through the Jetson's default audio sink
  (HDMI / USB DAC / 3.5 mm), **not** the LyraT speakers. The LyraT's DAC
  side (`DSDIN` / `GPIO26`) is not driven by the current firmware.
- Wake-word is push-to-talk by default for the first alpha that supports
  LyraT. Set `wakeword_script` once you've validated push-to-talk works.
- No beamforming yet. The LyraT's L+R mics are 3.5 cm apart, which is
  below Espressif's recommended 4–6.5 cm range for their `MASE`/`esp_afe_doa`
  defaults; if/when beamforming lands in GenieClaw, `mic_distance` must be
  set to `0.035`, not the upstream defaults.
