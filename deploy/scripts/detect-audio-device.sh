#!/bin/bash
# Detect the audio capture device and emit the ALSA device string for
# `arecord -D <...>`. Used by genie-core when `audio_device = "auto"`.
#
# Priority order:
#   1. Tegra APE card with I2S2 controls present AND ADMAIF1 Mux set to I2S2
#      (i.e. an external I2S frontend such as ESP32-LyraT on the 40-pin header,
#      see doc/lyrat-jetson-audio.md). Emits "plughw:APE,0".
#   2. A USB audio card (Lenovo E03, headsets, generic USB-Audio). Emits
#      "plughw:<N>,0".
#   3. Fallback to "plughw:0,0".

# 1. Prefer APE/I2S2 when the AHUB route is already configured for external
#    capture. We check ADMAIF1 Mux's current item rather than just the
#    presence of controls, so that a stock JetPack with the I2S2 overlay
#    applied but no external master wired doesn't accidentally win.
if amixer -c APE controls 2>/dev/null | grep -q "I2S2 Mux"; then
    ADMAIF1_CGET=$(amixer -c APE cget name="ADMAIF1 Mux" 2>/dev/null)
    ADMAIF1_IDX=$(printf '%s\n' "$ADMAIF1_CGET" | sed -n 's/.*: values=//p' | head -1)
    if [ -n "$ADMAIF1_IDX" ] && [ "$ADMAIF1_IDX" != "0" ]; then
        ADMAIF1_SRC=$(printf '%s\n' "$ADMAIF1_CGET" | awk -F"'" -v idx="$ADMAIF1_IDX" '$0 ~ ("Item #" idx " ") {print $2; exit}')
        if [ "$ADMAIF1_SRC" = "I2S2" ]; then
            echo "plughw:APE,0"
            exit 0
        fi
    fi
fi

# 2. USB audio fallback (original behavior).
CARD=$(cat /proc/asound/cards 2>/dev/null | grep -i "USB-Audio\|USB Audio\|Lenovo\|Headphone\|Headset" | head -1 | awk '{print $1}')

if [ -n "$CARD" ]; then
    echo "plughw:${CARD},0"
    exit 0
fi

# 3. Fallback: card 0.
if [ -e /proc/asound/card0 ]; then
    echo "plughw:0,0"
    exit 0
fi

# No audio device found
echo ""
exit 1
