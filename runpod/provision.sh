#!/usr/bin/env bash
# =============================================================================
#  Triple Max — RunPod provisioning for huchukato/comfyui-base:cu130
#
#  Runs BEFORE the image's /start.sh (via the template's start command), does the
#  minimum needed for the MiniMax H3 StoryFlow workflow, then `exec /start.sh`.
#  Idempotent: safe on every boot; a warm network volume makes every step a skip.
#
#  Mirrors the two first-boot steps of /start.sh (verified from the image):
#    - copy /opt/comfyui-baked -> /workspace/runpod-slim/ComfyUI  (if missing)
#    - python3.12 -m venv --system-site-packages .venv-cu130 + ensurepip (if missing)
#  so that custom nodes and pip deps exist before ComfyUI's one-shot import.
#
#  The idle/hard-cap watchdog starts FIRST (before any step that can fail) so a pod can
#  never keep billing unattended because provisioning or ComfyUI died.
#
#  Usage:
#    bash provision.sh               full provisioning, ends with exec /start.sh
#    bash provision.sh --check       print status table and exit
#    bash provision.sh --models-only download/verify models only (background worker)
#    bash provision.sh --watchdog    run the watchdog loop in the foreground (internal/tests)
#
#  Env (all optional):
#    PROVISION_URL                 raw URL of this script (models.txt is fetched next to it)
#    PROVISION_MODELS_MODE         background (default) | foreground
#    PROVISION_IDLE_STOP_MIN       stop the pod after N minutes with an empty ComfyUI queue (default 45; 0 = off)
#    PROVISION_UNREACHABLE_STOP_MIN stop the pod after N minutes of ComfyUI not answering (default 30; 0 = off)
#    PROVISION_MAX_POD_HOURS       stop the pod after N hours no matter what (default 6; 0 = off)
#    PROVISION_IDLE_ACTION         stop (default) | terminate
#    PROVISION_COMFY_ARGS          override the ComfyUI args written to comfyui_args.txt
#    PROVISION_WORKFLOW_URL        optional URL of a workflow JSON to install for manual UI use
#    MIN_COMFY / COMFY_TAG         minimum ComfyUI version (0.34.2) / force a tag checkout
#    ADDON_SHA / UPSCALER_SHA      pins for the two custom node repos
#    HF_TOKEN                      Hugging Face token (only needed if a repo becomes gated)
#    RUNPOD_API_KEY                RunPod injects a pod-scoped key; used by the watchdog's REST fallback
# =============================================================================
set -Eeuo pipefail

# ----------------------------------------------------------------------------- config
WS=${TRIPLE_MAX_WS:-/workspace/runpod-slim}        # override only for local smoke tests
COMFY=$WS/ComfyUI
BAKED=${TRIPLE_MAX_BAKED:-/opt/comfyui-baked}
VENV_SUFFIX=${VENV_SUFFIX:-cu130}
VENV=$COMFY/.venv-$VENV_SUFFIX
STATE=$WS/.provision
SELF=$WS/provision.sh
ARGS_FILE=$WS/comfyui_args.txt

MIN_COMFY=${MIN_COMFY:-0.34.2}
COMFY_TAG=${COMFY_TAG:-}

ADDON_DIR=ComfyUI-H3-Motion-Context-Auto-Chain-addon
ADDON_REPO=https://github.com/Ltamann/ComfyUI-H3-Motion-Context-Auto-Chain-addon
ADDON_SHA=${ADDON_SHA:-521007e0736744a4c431974f1e4248e67b5a76a4}
UPSCALER_DIR=Comfyui_Minimax_h3_latent_Upscaler
UPSCALER_REPO=https://github.com/LBH-123-AI/Comfyui_Minimax_h3_latent_Upscaler
UPSCALER_SHA=${UPSCALER_SHA:-d7c01b9011f2e8439493f6c02c29995a27df276f}

PROVISION_URL=${PROVISION_URL:-}
BASE_URL=${PROVISION_URL%/*}                       # folder that also holds models.txt
WORKFLOW_URL=${PROVISION_WORKFLOW_URL:-}
MODELS_MODE=${PROVISION_MODELS_MODE:-background}
IDLE_STOP_MIN=${PROVISION_IDLE_STOP_MIN:-45}
UNREACHABLE_STOP_MIN=${PROVISION_UNREACHABLE_STOP_MIN:-30}
MAX_POD_HOURS=${PROVISION_MAX_POD_HOURS:-6}
IDLE_ACTION=${PROVISION_IDLE_ACTION:-stop}
# seconds (tests override these to run the loop fast)
IDLE_STOP_SEC=${PROVISION_IDLE_STOP_SEC:-$((IDLE_STOP_MIN * 60))}
UNREACHABLE_STOP_SEC=${PROVISION_UNREACHABLE_STOP_SEC:-$((UNREACHABLE_STOP_MIN * 60))}
MAX_POD_SEC=${PROVISION_MAX_POD_SEC:-$((MAX_POD_HOURS * 3600))}
WATCHDOG_INTERVAL_S=${PROVISION_WATCHDOG_INTERVAL_S:-60}
COMFY_PROBE_URL=${PROVISION_COMFY_PROBE_URL:-http://127.0.0.1:8188/prompt}
STOP_CMD=${PROVISION_STOP_CMD:-}                    # tests: command to run instead of stopping a real pod

export HF_HOME=$WS/.hf-cache
export PIP_CACHE_DIR=$WS/.pip-cache
export GIT_TERMINAL_PROMPT=0
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PYTHONUNBUFFERED=1
if [ -f /opt/comfyui-runtime-constraints.txt ]; then
    export PIP_CONSTRAINT=/opt/comfyui-runtime-constraints.txt   # same guard as /start.sh (keeps torch)
fi

MODE=full
case "${1:-}" in
    --check) MODE=check ;;
    --models-only) MODE=models ;;
    --watchdog) MODE=watchdog ;;
    "") ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
esac

# Embedded fallback of models.txt (used when PROVISION_URL is unset/offline).
MODELS_FALLBACK='https://huggingface.co/smhfacct/Minimax-H3-fl2va-ref2va-hybrid-models/resolve/main/minimax_h3_hybrid_fl2va_ref2va_b20-49-int8.safetensors|diffusion_models/minimax_h3_hybrid_fl2va_ref2va_b20-49-int8.safetensors|20500000000
https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors|text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors|15300000000
https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_video_vae_fp16.safetensors|vae/minimax_h3_video_vae_fp16.safetensors|5100000000
https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_audio_vae_fp32.safetensors|vae/minimax_h3_audio_vae_fp32.safetensors|590000000
https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors|loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors|1900000000
https://huggingface.co/LBH-123-AI/Minimax_h3_latent_Upscaler/resolve/main/minimax_h3_latent_upscaler_3d_fp16.safetensors|latent_upscale_models/minimax_h3_latent_upscaler_3d_fp16.safetensors|660000000'

# ----------------------------------------------------------------------------- logging
mkdir -p "$STATE"
LOG_FILE=$STATE/provision.log
case "$MODE" in
    models) LOG_FILE=$STATE/models.log ;;
    watchdog) LOG_FILE=$STATE/watchdog.log ;;
esac
# log to stderr + file so functions whose stdout is captured stay clean
log()  { printf '%s [provision] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }
warn() { log "WARNING: $*"; }
die()  { log "ERROR: $*"; exit 1; }

on_error() {
    local rc=$? line=${BASH_LINENO[0]}
    log "ERROR: step failed (exit $rc) at line $line: ${BASH_COMMAND}"
    touch "$STATE/provision.failed"
    if [ "$MODE" = full ]; then
        log "handing over to /start.sh anyway so SSH/Jupyter stay reachable for debugging (watchdog keeps running)"
        exec /start.sh
    fi
    exit "$rc"
}
trap on_error ERR

# ----------------------------------------------------------------------------- helpers
PY=$VENV/bin/python
pipi() { "$PY" -m pip install --no-cache-dir -q "$@"; }
have() { command -v "$1" >/dev/null 2>&1; }

file_size() { stat -L -c %s "$1" 2>/dev/null || echo 0; }

# returns 0 when $1 >= $2 (dotted versions)
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

self_persist() {
    # keep an offline copy so later boots work without PROVISION_URL
    local src
    src=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if [ -f "$src" ] && [ "$src" != "$SELF" ]; then
        install -m 0755 "$src" "$SELF"
    fi
}

gpu_sanity() {
    if ! have nvidia-smi; then warn "nvidia-smi not found"; return 0; fi
    local info cap
    info=$(nvidia-smi --query-gpu=name,compute_cap,memory.total --format=csv,noheader 2>/dev/null | head -n1 || true)
    log "GPU: ${info:-unknown}"
    cap=$(printf '%s' "$info" | awk -F', ' '{print $2}')
    if [ -n "$cap" ] && ! version_ge "$cap" "10.0"; then
        warn "compute capability $cap < 10.0: the nvfp4 text encoder needs a Blackwell GPU (RTX 50xx / RTX PRO 6000 / B200); fine for a download-only boot"
    fi
}

first_boot_copy() {
    if [ -f "$COMFY/main.py" ]; then log "ComfyUI workspace present: skip copy"; return 0; fi
    log "first boot: copying $BAKED -> $COMFY (this takes a minute)"
    mkdir -p "$WS"
    cp -a "$BAKED" "$COMFY"
}

ensure_venv() {
    if [ -x "$PY" ]; then log "venv present: $VENV"; return 0; fi
    log "creating venv $VENV (system-site-packages, same as /start.sh)"
    ( cd "$COMFY" && python3.12 -m venv --system-site-packages "$VENV" )
    "$PY" -m ensurepip >/dev/null 2>&1 || true
    [ -x "$PY" ] || die "venv creation failed"
}

comfy_version() {
    ( cd "$COMFY" 2>/dev/null && "$PY" -c 'import comfyui_version as v; print(v.__version__)' 2>/dev/null ) || echo "0"
}

ensure_comfy_version() {
    local cur target
    cur=$(comfy_version)
    target=$COMFY_TAG
    if [ -z "$target" ]; then
        if version_ge "$cur" "$MIN_COMFY"; then
            log "ComfyUI $cur >= $MIN_COMFY: ok"; echo "$cur" >"$STATE/comfy.version"; return 0
        fi
        target="v$MIN_COMFY"
    elif [ "v$cur" = "$target" ] || [ "$cur" = "$target" ]; then
        log "ComfyUI already at $target"; echo "$cur" >"$STATE/comfy.version"; return 0
    fi
    log "ComfyUI $cur -> checking out $target"
    if [ ! -d "$COMFY/.git" ]; then
        ( cd "$COMFY" && git init -q && git remote add origin https://github.com/comfyanonymous/ComfyUI )
    fi
    git -C "$COMFY" fetch -q --depth 1 origin "refs/tags/$target:refs/tags/$target"
    git -C "$COMFY" checkout -q -f "$target"      # tracked files only; models/custom_nodes/input/output/user untouched
    pipi -r "$COMFY/requirements.txt"             # never -U: torch must stay the image build
    comfy_version >"$STATE/comfy.version"
    log "ComfyUI now $(cat "$STATE/comfy.version")"
}

install_node() { # <dir> <repo> <sha>
    local dir=$COMFY/custom_nodes/$1 repo=$2 sha=$3 head
    mkdir -p "$COMFY/custom_nodes"
    if [ ! -d "$dir/.git" ]; then
        log "cloning $repo"
        rm -rf "$dir"
        git clone -q --no-checkout "$repo" "$dir"
    fi
    head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo none)
    if [ "$head" != "$sha" ]; then
        log "$1: checkout ${sha:0:12}"
        git -C "$dir" fetch -q origin "$sha" 2>/dev/null || git -C "$dir" fetch -q origin
        git -C "$dir" checkout -q -f "$sha"
    else
        log "$1: pinned at ${sha:0:12}"
        # A fresh --no-checkout clone can already have HEAD == sha while its
        # working tree is empty. Checkout even then (also repairs older installs).
        # Do not force this path: warm boots must preserve existing local edits.
        git -C "$dir" checkout -q "$sha"
    fi
    [ -f "$dir/__init__.py" ] || die "$1: checkout is missing __init__.py"
    if [ -f "$dir/requirements.txt" ]; then pipi -r "$dir/requirements.txt"; fi
}

install_nodes() {
    install_node "$ADDON_DIR" "$ADDON_REPO" "$ADDON_SHA"
    install_node "$UPSCALER_DIR" "$UPSCALER_REPO" "$UPSCALER_SHA"
    # addon deps (the repo ships no requirements.txt); mostly already satisfied by the image
    pipi imageio-ffmpeg safetensors numpy Pillow
    mkdir -p "$COMFY/models/latent_upscale_models" "$COMFY/models/diffusion_models" \
             "$COMFY/models/text_encoders" "$COMFY/models/vae" "$COMFY/models/loras" \
             "$COMFY/user/default/workflows/triple-max" "$COMFY/output/video" "$COMFY/output/h3_context"
}

write_comfy_args() {
    local args
    if [ -n "${PROVISION_COMFY_ARGS:-}" ]; then
        args=$(printf '%s' "$PROVISION_COMFY_ARGS" | tr ' ' '\n' | sed '/^$/d')
    else
        args=$'--disable-auto-launch\n--fast fp16_accumulation\n--async-offload\n--cuda-malloc'
        if "$PY" -c 'import comfy_kitchen' >/dev/null 2>&1; then args+=$'\n--use-ck-attention'; fi
    fi
    {
        echo "# managed by triple-max provision.sh — set PROVISION_COMFY_ARGS to override"
        echo "# /start.sh adds: --listen 0.0.0.0 --port 8188 --enable-cors-header"
        printf '%s\n' "$args"
    } >"$ARGS_FILE"
    log "comfyui_args.txt: $(printf '%s' "$args" | tr '\n' ' ')"
}

install_workflow() {
    # Optional: only when PROVISION_WORKFLOW_URL is set (the desktop app sends the graph itself).
    if [ -z "$WORKFLOW_URL" ]; then return 0; fi
    local dest="$COMFY/user/default/workflows/triple-max/StoryFlow_v11 (template).json"
    if curl -fsSL --retry 3 "$WORKFLOW_URL" -o "$dest.tmp"; then
        mv -f "$dest.tmp" "$dest"; log "workflow installed: $dest"
    else
        rm -f "$dest.tmp"; warn "workflow download failed ($WORKFLOW_URL)"
    fi
}

# ----------------------------------------------------------------------------- models
fetch_manifest() { # prints "url|dest|min" lines to stdout
    local dest=$STATE/models.txt
    if [ -n "$BASE_URL" ] && curl -fsSL --retry 3 "$BASE_URL/models.txt" -o "$dest.new" 2>/dev/null; then
        mv -f "$dest.new" "$dest"
    elif [ ! -s "$dest" ]; then
        printf '%s\n' "$MODELS_FALLBACK" >"$dest"
    fi
    rm -f "$dest.new"
    sed -i 's/\r$//' "$dest"
    { grep -v '^[[:space:]]*#' "$dest" | grep -v '^[[:space:]]*$'; } || true
}

remote_size() { # <url> -> bytes or empty (empty when OFFLINE=1)
    [ -z "${OFFLINE:-}" ] || return 0
    local hdr v
    hdr=$(curl -sIL --max-time 20 ${HF_TOKEN:+-H "Authorization: Bearer $HF_TOKEN"} "$1" 2>/dev/null | tr -d '\r') || return 0
    v=$(printf '%s\n' "$hdr" | awk 'tolower($1)=="x-linked-size:"{v=$2} END{print v}')
    if ! printf '%s' "$v" | grep -qE '^[0-9]+$'; then
        v=$(printf '%s\n' "$hdr" | awk 'tolower($1)=="content-length:"{v=$2} END{print v}')
    fi
    printf '%s' "$v" | grep -E '^[0-9]+$' || true
}

verify_file() { # <dest> <url> <min_bytes> -> 0 ok
    local dest=$1 url=$2 min=$3 size exact
    [ -f "$dest" ] || return 1
    size=$(file_size "$dest")
    [ "$size" -ge "$min" ] || return 1
    exact=$({ grep -F "$dest|" "$STATE/sizes.txt" 2>/dev/null || true; } | tail -n1 | cut -d'|' -f2)
    if [ -z "$exact" ]; then exact=$(remote_size "$url" || true); fi
    if [ -n "$exact" ] && [ "$size" != "$exact" ]; then
        warn "$(basename "$dest"): size $size != expected $exact"; return 1
    fi
    return 0
}

ensure_hf_cli() {
    if have hf || have huggingface-cli; then return 0; fi
    pipi huggingface_hub || true
    have hf || have huggingface-cli
}

download_one() { # <url> <dest> <min_bytes>
    local url=$1 dest=$2 min=$3 name repo="" rev="" path="" stage cli tmp
    name=$(basename "$dest")
    mkdir -p "$(dirname "$dest")"
    if [[ "$url" =~ ^https://huggingface\.co/([^/]+/[^/]+)/resolve/([^/]+)/(.+)$ ]]; then
        repo=${BASH_REMATCH[1]}; rev=${BASH_REMATCH[2]}; path=${BASH_REMATCH[3]}
    fi
    if [ -n "$repo" ] && ensure_hf_cli; then
        stage=$STATE/stage/$name; rm -rf "$stage"; mkdir -p "$stage"
        cli=hf; have hf || cli=huggingface-cli
        # hf_transfer is deprecated upstream in favour of hf_xet; harmless when absent
        if "$PY" -c 'import hf_transfer' >/dev/null 2>&1; then export HF_HUB_ENABLE_HF_TRANSFER=1; else unset HF_HUB_ENABLE_HF_TRANSFER; fi
        log "downloading $name via $cli ($repo@$rev)"
        if "$cli" download "$repo" "$path" --revision "$rev" --local-dir "$stage" >>"$LOG_FILE" 2>&1 && [ -f "$stage/$path" ]; then
            mv -f "$stage/$path" "$dest"
        else
            warn "$cli failed for $name, falling back to curl"
        fi
        rm -rf "$stage"
    fi
    if [ ! -f "$dest" ]; then
        tmp=$dest.part
        log "downloading $name via curl"
        if ! curl -fL -C - --retry 10 --retry-all-errors --retry-delay 5 \
                ${HF_TOKEN:+-H "Authorization: Bearer $HF_TOKEN"} -o "$tmp" "$url" >>"$LOG_FILE" 2>&1; then
            warn "curl failed for $name (partial kept for resume)"; return 1
        fi
        mv -f "$tmp" "$dest"
    fi
    if verify_file "$dest" "$url" "$min"; then
        echo "$dest|$(file_size "$dest")" >>"$STATE/sizes.txt"
        log "ok: $name ($(file_size "$dest") bytes)"
        return 0
    fi
    warn "$name failed verification; removing"; rm -f "$dest"; return 1
}

download_models() {
    local total=0 ready=0 failed=0 url dest min attempt
    rm -f "$STATE/models.done"
    while IFS='|' read -r url dest min; do
        [ -n "$url" ] || continue
        total=$((total+1))
        dest=$COMFY/models/$dest
        if verify_file "$dest" "$url" "$min"; then
            ready=$((ready+1)); log "present: $(basename "$dest")"; continue
        fi
        for attempt in 1 2 3; do
            if download_one "$url" "$dest" "$min" </dev/null; then ready=$((ready+1)); break; fi
            if [ "$attempt" -lt 3 ]; then warn "retry $attempt for $(basename "$dest")"; sleep $((attempt*20)); fi
        done
        [ -f "$dest" ] || failed=$((failed+1))
    done < <(fetch_manifest)
    log "models: $ready/$total ready, $failed failed"
    # the HF staging cache is not needed once files are in place
    rm -rf "$STATE/stage" "$HF_HOME/hub" 2>/dev/null || true
    if [ "$failed" -eq 0 ] && [ "$total" -gt 0 ]; then
        { date +%s; sha256sum "$STATE/models.txt" | cut -d' ' -f1; } >"$STATE/models.done"
        return 0
    fi
    return 1
}

models_status() { # prints "ready/total"; returns 0 when everything is present
    local total=0 ready=0 url dest min
    while IFS='|' read -r url dest min; do
        [ -n "$url" ] || continue
        total=$((total+1))
        if OFFLINE=1 verify_file "$COMFY/models/$dest" "$url" "$min"; then ready=$((ready+1)); fi
    done < <(fetch_manifest)
    printf '%s/%s' "$ready" "$total"
    [ "$ready" -eq "$total" ] && [ "$total" -gt 0 ]
}

# ----------------------------------------------------------------------------- watchdog
# Stops (or terminates) THIS pod. Tries every documented path in order and logs each one:
#   1. runpodctl (preinstalled on every pod)  — current syntax `runpodctl pod stop`, legacy `stop pod`
#   2. REST v2  POST https://api.runpod.io/v2/pods/{id}/action {"action":"stop"}   (Bearer RUNPOD_API_KEY)
#   3. REST v1  POST https://rest.runpod.io/v1/pods/{id}/stop  (deprecated, retires 2026-11-15)
stop_pod() {
    local id=${RUNPOD_POD_ID:-} action=$IDLE_ACTION key=${RUNPOD_API_KEY:-}
    if [ -n "$STOP_CMD" ]; then log "stop_pod (test hook): $STOP_CMD"; bash -c "$STOP_CMD"; return $?; fi
    [ -n "$id" ] || { warn "RUNPOD_POD_ID unset: cannot $action pod"; return 1; }
    if have runpodctl; then
        if [ "$action" = terminate ]; then
            runpodctl pod delete "$id" 2>>"$LOG_FILE" && { log "runpodctl pod delete ok"; return 0; }
            runpodctl remove pod "$id" 2>>"$LOG_FILE" && { log "runpodctl remove pod ok"; return 0; }
        else
            runpodctl pod stop "$id" 2>>"$LOG_FILE" && { log "runpodctl pod stop ok"; return 0; }
            runpodctl stop pod "$id" 2>>"$LOG_FILE" && { log "runpodctl stop pod ok"; return 0; }
        fi
        warn "runpodctl could not $action the pod; trying REST"
    fi
    [ -n "$key" ] || { warn "RUNPOD_API_KEY unset and runpodctl failed: cannot $action pod"; return 1; }
    if [ "$action" = terminate ]; then
        curl -fsS -X DELETE "https://api.runpod.io/v2/pods/$id" -H "Authorization: Bearer $key" >>"$LOG_FILE" 2>&1 \
            && { log "REST v2 terminate ok"; return 0; }
        curl -fsS -X DELETE "https://rest.runpod.io/v1/pods/$id" -H "Authorization: Bearer $key" >>"$LOG_FILE" 2>&1 \
            && { log "REST v1 terminate ok"; return 0; }
    else
        curl -fsS -X POST "https://api.runpod.io/v2/pods/$id/action" -H "Authorization: Bearer $key" \
            -H "Content-Type: application/json" -d '{"action":"stop"}' >>"$LOG_FILE" 2>&1 \
            && { log "REST v2 stop ok"; return 0; }
        curl -fsS -X POST "https://rest.runpod.io/v1/pods/$id/stop" -H "Authorization: Bearer $key" >>"$LOG_FILE" 2>&1 \
            && { log "REST v1 stop ok"; return 0; }
    fi
    warn "every $action path failed; will retry next tick"
    return 1
}

queue_remaining() { # prints ComfyUI's queue_remaining, or nothing when unreachable
    curl -fsS --max-time 5 "$COMFY_PROBE_URL" 2>/dev/null \
        | sed -n 's/.*"queue_remaining"[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p' | head -n1
}

watchdog_loop() {
    local start now idle=0 unreachable=0 remaining announced_models=0
    start=$(date +%s)
    log "watchdog: idle-stop ${IDLE_STOP_SEC}s, unreachable-stop ${UNREACHABLE_STOP_SEC}s, hard cap ${MAX_POD_SEC}s, action=$IDLE_ACTION"
    while true; do
        sleep "$WATCHDOG_INTERVAL_S"
        now=$(date +%s)
        if [ "$MAX_POD_SEC" -gt 0 ] && [ $((now - start)) -ge "$MAX_POD_SEC" ]; then
            log "hard cap reached ($(( (now - start) / 60 )) min): $IDLE_ACTION pod"
            stop_pod && exit 0
            continue
        fi
        if [ ! -f "$STATE/models.done" ]; then
            [ "$announced_models" = 1 ] || { log "watchdog: models not ready yet, only the hard cap applies"; announced_models=1; }
            continue
        fi
        remaining=$(queue_remaining || true)
        if [ -z "$remaining" ]; then
            unreachable=$((unreachable + WATCHDOG_INTERVAL_S))
            if [ "$UNREACHABLE_STOP_SEC" -gt 0 ] && [ "$unreachable" -ge "$UNREACHABLE_STOP_SEC" ]; then
                log "ComfyUI unreachable for $((unreachable / 60)) min (crashed?): $IDLE_ACTION pod"
                stop_pod && exit 0
                unreachable=0
            fi
            continue
        fi
        unreachable=0
        if [ "$remaining" = "0" ]; then
            idle=$((idle + WATCHDOG_INTERVAL_S))
        else
            [ "$idle" = 0 ] || log "watchdog: queue busy ($remaining), idle counter reset"
            idle=0
        fi
        if [ "$IDLE_STOP_SEC" -gt 0 ] && [ "$idle" -ge "$IDLE_STOP_SEC" ]; then
            log "queue idle for $((idle / 60)) min: $IDLE_ACTION pod"
            stop_pod && exit 0
            idle=0
        fi
    done
}

start_watchdog() {
    if [ "$IDLE_STOP_SEC" -le 0 ] && [ "$UNREACHABLE_STOP_SEC" -le 0 ] && [ "$MAX_POD_SEC" -le 0 ]; then
        warn "watchdog disabled (all thresholds 0): this pod will keep billing until stopped by hand"
        return 0
    fi
    local src
    src=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if have setsid; then
        setsid nohup bash "$src" --watchdog >>"$STATE/watchdog.log" 2>&1 </dev/null &
    else
        nohup bash "$src" --watchdog >>"$STATE/watchdog.log" 2>&1 </dev/null &
    fi
    echo $! >"$STATE/watchdog.pid"
    log "watchdog started (pid $!)"
}

# ----------------------------------------------------------------------------- status
status_table() {
    local n
    echo "== Triple Max provisioning status =="
    echo "workspace      : $COMFY $([ -f "$COMFY/main.py" ] && echo present || echo MISSING)"
    echo "venv           : $VENV $([ -x "$PY" ] && echo present || echo MISSING)"
    echo "ComfyUI        : $(comfy_version) (min $MIN_COMFY)"
    for n in "$ADDON_DIR" "$UPSCALER_DIR"; do
        echo "node           : $n @ $(git -C "$COMFY/custom_nodes/$n" rev-parse --short HEAD 2>/dev/null || echo MISSING)"
    done
    echo "models         : $(models_status || true) ready $([ -f "$STATE/models.done" ] && echo '(models.done)' || echo '(no models.done marker)')"
    echo "args           : $({ grep -v '^#' "$ARGS_FILE" 2>/dev/null || true; } | tr '\n' ' ')"
    echo "watchdog       : idle ${IDLE_STOP_MIN} min / unreachable ${UNREACHABLE_STOP_MIN} min / hard cap ${MAX_POD_HOURS} h / action $IDLE_ACTION$([ -f "$STATE/watchdog.pid" ] && echo " / pid $(cat "$STATE/watchdog.pid")")"
    echo "failed marker  : $([ -f "$STATE/provision.failed" ] && echo YES || echo no)"
    echo "logs           : $STATE/provision.log  $STATE/models.log  $STATE/watchdog.log"
}

# ----------------------------------------------------------------------------- main
case "$MODE" in
    check)
        status_table
        exit 0
        ;;
    models)
        [ -x "$PY" ] || die "venv missing; run full provisioning first"
        if download_models; then exit 0; else exit 1; fi
        ;;
    watchdog)
        trap - ERR
        watchdog_loop
        exit 0
        ;;
esac

log "=== Triple Max provisioning start (pod ${RUNPOD_POD_ID:-?}) ==="
rm -f "$STATE/provision.failed"
start_watchdog
self_persist
gpu_sanity
first_boot_copy
ensure_venv
ensure_comfy_version
install_nodes
write_comfy_args
install_workflow

if models_status >/dev/null; then
    log "models: all present"
    [ -f "$STATE/models.done" ] || { date +%s; echo cached; } >"$STATE/models.done"
elif [ "$MODELS_MODE" = foreground ]; then
    download_models || warn "some models failed; see $STATE/models.log"
else
    log "models incomplete: downloading in background (tail -f $STATE/models.log)"
    nohup bash "$SELF" --models-only >>"$STATE/models.log" 2>&1 </dev/null &
fi

status_table | tee -a "$LOG_FILE"
log "=== handing over to /start.sh ==="
exec /start.sh
