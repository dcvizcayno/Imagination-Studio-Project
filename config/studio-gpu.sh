#!/bin/bash
# studio-gpu — choose where Imagination Studio renders: this Mac ("local") or a RunPod GPU pod ("runpod").
#
#   studio-gpu.sh status                 what the switch is set to, and whether that backend can actually run here
#   studio-gpu.sh validate [backend]     full compatibility check; exit 1 when the backend is not viable
#   studio-gpu.sh use local|runpod       set the backend (writes mode in gpu-switch.json)
#   studio-gpu.sh placement [which]      write the app's own 'placement' record into $STUDIO_HOME/sparks/sparks.json (app/sparks.py:459)
#   studio-gpu.sh run                    start the Studio on the selected backend
#   studio-gpu.sh tunnel [up|down]       the ssh tunnel to the pod (runpod only)
#
# The thresholds below are the Studio's own installer gates, not opinions:
#   oneshot-setup.sh:261-280  NEED = 48 (--image-only) / 96 (default) / 128 (--turbo, --ref2va)
#   app/sparks.py:73          KINDS = ("video",) — only single clips may be handed to another machine
#   app/sparks.py:381-390     here_only() — pictures, edits, Library actions and exports never leave the host
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/gpu-switch.json"
VENV_PY="$(cd "$HERE/.." && pwd)/venv/bin/python"
PY="$([ -x "$VENV_PY" ] && echo "$VENV_PY" || echo python3)"

say() { printf '%s\n' "$*"; }
hr()  { printf '%s\n' "------------------------------------------------------------"; }
die() { printf '  x  %s\n' "$*" >&2; exit 1; }

cfg() { "$PY" -c "import json,sys;d=json.load(open('$CONFIG'));print(eval('d'+sys.argv[1]))" "$1"; }
cfg_set() {
  "$PY" - "$CONFIG" "$1" "$2" <<'EOF'
import json, sys
path, dotted, value = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path))
node = d
keys = dotted.split(".")
for k in keys[:-1]:
    node = node[k]
node[keys[-1]] = value
json.dump(d, open(path, "w"), indent=2)
open(path, "a").write("\n")
EOF
}

# STUDIO_HOME wins, as it does in the app (app/studio_home.py:41); then the config; then the app's own default.
studio_home() {
  if [ -n "${STUDIO_HOME:-}" ]; then echo "$STUDIO_HOME"; return; fi
  local h; h="$(cfg "['studio']['studio_home']")"; echo "${h/#\~/$HOME}"
}
# feasible NEEDED AVAILABLE -> true when AVAILABLE >= NEEDED
feasible() { awk -v need="$1" -v have="$2" 'BEGIN{exit !(have+0 >= need+0)}'; }

# ---------------------------------------------------------------- machine facts
chip()  { sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown; }
ram_gb() { echo $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 )); }
os_ver() { sw_vers -productVersion 2>/dev/null || echo 0; }
free_gb() { df -g /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4}' || echo 0; }

# ver_ge A B -> true when A >= B
ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

# ---------------------------------------------------------------- validate local
validate_local() {
  local fails=0 warns=0
  local c r o f
  c="$(chip)"; r="$(ram_gb)"; o="$(os_ver)"; f="$(free_gb)"

  say "This Mac"
  say "  chip            $c"
  say "  unified memory  ${r} GB"
  say "  macOS           $o"
  say "  free disk       ${f} GB"
  hr

  local fam min_os p48 p96 p128
  fam="$(cfg "['backends']['local']['requirements']['chip_family']")"
  min_os="$(cfg "['backends']['local']['requirements']['macos_min']")"
  p48="$(cfg "['backends']['local']['requirements']['unified_memory_gb']['min_pictures_only']")"
  p96="$(cfg "['backends']['local']['requirements']['unified_memory_gb']['min_default']")"
  p128="$(cfg "['backends']['local']['requirements']['unified_memory_gb']['min_turbo_or_ref2va']")"

  if echo "$c" | grep -q "$fam"; then
    say "  ok   chip is $fam (the int8 Metal-4 kernels are measured on ${fam})"
  elif echo "$c" | grep -Eq 'M[1-4]'; then
    say "  warn $c is not $fam: the int8 kernels need Metal 4 tensor units, the engine falls back to bfloat16"
    warns=$((warns+1))
  else
    say "  x    $c is not $fam and not Apple silicon M-series"; fails=$((fails+1))
  fi

  if ver_ge "$o" "$min_os"; then say "  ok   macOS $o meets the $min_os floor (Metal 4)"
  else say "  x    macOS $o is below the $min_os floor (Metal 4)"; fails=$((fails+1)); fi

  say ""
  say "  Unified-memory gate (oneshot-setup.sh:261-280)"
  if feasible "$p128" "$r"; then
    say "  ok   ${r} GB — every install, including --turbo and --ref2va, is supported"
  elif feasible "$p96" "$r"; then
    say "  ok   ${r} GB — the default install (video, voice, music, Bolt) is supported"
  elif feasible "$p48" "$r"; then
    say "  warn ${r} GB — pictures only: the install must be run as 'oneshot-setup.sh --image-only'"
    warns=$((warns+1))
  else
    say "  x    ${r} GB < ${p48} GB — the installer dies at preflight in every mode."
    say "       There is no picture-only tier below 48 GB; this is a hard stop, not a warning."
    fails=$((fails+1))
  fi

  local dmin
  if feasible "$p48" "$r"; then dmin="$(cfg "['backends']['local']['requirements']['disk_free_gb']['pictures_only']")"
  else dmin="$(cfg "['backends']['local']['requirements']['disk_free_gb']['default']")"; fi
  if feasible "$dmin" "$f"; then say "  ok   ${f} GB free of the ${dmin} GB this install needs"
  else say "  x    ${f} GB free, this install needs ${dmin} GB"; fails=$((fails+1)); fi

  say ""
  say "  Toolchain"
  local t
  for t in ffmpeg ffprobe; do
    if command -v "$t" >/dev/null; then say "  ok   $t"; else say "  warn $t missing: no long videos, no timeline export, no frames from a clip"; warns=$((warns+1)); fi
  done
  if [ -x "$VENV_PY" ]; then say "  ok   Python environment at $VENV_PY"
  else say "  x    no Python environment (run the installer, or 'uv venv' + 'uv pip install -r app/requirements.lock')"; fails=$((fails+1)); fi

  hr
  if [ "$fails" -gt 0 ]; then
    say "  VERDICT: local rendering is NOT viable on this Mac (${fails} blocking, ${warns} warning)."
    return 1
  fi
  say "  VERDICT: local rendering is viable (${warns} warning)."
  return 0
}

# ---------------------------------------------------------------- validate runpod
validate_runpod() {
  local fails=0
  local user host port key shape
  user="$(cfg "['backends']['runpod']['ssh']['user']")"
  host="$(cfg "['backends']['runpod']['ssh']['host']")"
  port="$(cfg "['backends']['runpod']['ssh']['port']")"
  key="$(cfg "['backends']['runpod']['ssh']['identity_file']")"; key="${key/#\~/$HOME}"
  shape="$(cfg "['backends']['runpod']['shape']")"

  say "RunPod backend"
  say "  shape           $shape"
  say "  ssh             ${user}@${host}:${port}"
  say "  key             $key"
  hr

  case "$user" in
    REPLACE_WITH_*) say "  x    the pod is not configured yet: set backends.runpod.ssh.user to your pod's ssh user."; fails=$((fails+1));;
    *) say "  ok   pod ssh user is set";;
  esac

  if [ -f "$key" ]; then say "  ok   identity file exists"
  else say "  x    identity file $key not found"; fails=$((fails+1)); fi

  if [ "$fails" -eq 0 ]; then
    say ""
    say "  Asking the pod for its GPU…"
    local gpu vram
    if out=$(ssh -i "$key" -p "$port" -o BatchMode=yes -o ConnectTimeout=12 -o StrictHostKeyChecking=accept-new \
             "$user@$host" 'nvidia-smi --query-gpu=name,memory.total --format=csv,noheader' 2>&1); then
      say "  ok   ${out}"
      gpu="$(echo "$out" | head -1 | cut -d, -f1)"
      vram="$(echo "$out" | head -1 | cut -d, -f2 | grep -oE '[0-9]+' | head -1)"
      vram=$(( ${vram:-0} / 1024 ))
      local v48 v96
      v48="$(cfg "['backends']['runpod']['requirements']['vram_gb']['min_pictures_only']")"
      v96="$(cfg "['backends']['runpod']['requirements']['vram_gb']['min_video_and_voice']")"
      if feasible "$v96" "$vram"; then say "  ok   ${vram} GB VRAM: the full video + voice install fits"
      elif feasible "$v48" "$vram"; then say "  warn ${vram} GB VRAM: pictures only (needs 48 GB for the standard install)"
      else say "  x    ${vram} GB VRAM < ${v48} GB: not enough for this Studio"; fails=$((fails+1)); fi
    else
      say "  x    could not reach the pod: $(echo "$out" | tail -1)"
      fails=$((fails+1))
    fi
  fi

  hr
  if [ "$fails" -gt 0 ]; then
    say "  VERDICT: the runpod backend is not usable yet (${fails} blocking)."
    return 1
  fi
  say "  VERDICT: the runpod backend is reachable and large enough."
  return 0
}

# ---------------------------------------------------------------- labels
# sparks/labels.json is read by the app and never rewritten by it (app/sparks.py:510), so it is a safe place to give
# the machines readable names in the Sparks tab's "Render on" dropdown.
write_labels() {
  local home addr
  home="$(studio_home)"
  addr="$(cfg "['backends']['runpod']['worker_address']")"
  mkdir -p "$home/sparks"
  "$PY" - "$home/sparks/labels.json" "$CONFIG" "$addr" <<'EOF'
import json, os, sys, tempfile
path, config, addr = sys.argv[1], sys.argv[2], sys.argv[3]
labels = json.load(open(config)).get("labels", {})
try:
    found = json.load(open(path))
except (OSError, ValueError):
    found = {}
if labels.get("head"):
    found["head"] = labels["head"]
if labels.get("runpod"):
    found[addr] = labels["runpod"]
tmp = tempfile.NamedTemporaryFile("w", dir=os.path.dirname(path) or ".", delete=False)
json.dump(found, tmp, indent=2)
tmp.write("\n")
tmp.close()
os.replace(tmp.name, path)
print(f"  labels    -> {path}")
EOF
}

# ---------------------------------------------------------------- placement
write_placement() {
  local which="${1:-}"
  [ -n "$which" ] || which="$(cfg "['mode']")"
  local home addr
  home="$(studio_home)"
  addr="$(cfg "['backends']['runpod']['worker_address']")"
  mkdir -p "$home/sparks"  # the hub keeps its book under sparks/, app/sparks.py:459
  "$PY" - "$home/sparks/sparks.json" "$CONFIG" "$which" "$addr" <<'EOF'
import json, os, sys, tempfile
book, config, which, addr = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
cfg = json.load(open(config))
placement = cfg["placement"].get(which, cfg["placement"][cfg["mode"]])
try:
    found = json.load(open(book))
except (OSError, ValueError):
    found = {}
found.setdefault("workers", [])
found.setdefault("sparks", 1)
# The pod is always listed: the Sparks tab hides "Where new clips render" entirely while no worker exists
# (static/sparks.js:151 spkPlacement returns null on an empty list), so the row has to be there to be selectable.
if not any(w.get("address") == addr for w in found["workers"]):
    found["workers"].append({"address": addr, "name": "RunPod", "kind": "ssh", "enabled": True})
found["placement"] = placement
tmp = tempfile.NamedTemporaryFile("w", dir=os.path.dirname(book) or ".", delete=False)
json.dump(found, tmp, indent=2)
tmp.write("\n")
tmp.close()
os.replace(tmp.name, book)
print(f"  placement -> {book}")
print(f"  placement = {json.dumps(placement)}")
EOF
  write_labels
}

# ---------------------------------------------------------------- commands
cmd_status() {
  local mode
  mode="$(cfg "['mode']")"
  say "Imagination Studio — render backend"
  say "  mode      $mode"
  say "  priority  $(cfg "['priority']")"
  say "  config    $CONFIG"
  say "  studio    $(studio_home)"
  hr
  if [ "$mode" = local ]; then validate_local || true
  else validate_runpod || true; fi
}

cmd_use() {
  local want="${1:-}"
  case "$want" in
    local|runpod) ;;
    *) die "use: studio-gpu.sh use local|runpod" ;;
  esac
  cfg_set mode "$want"
  say "  mode -> $want"
  write_placement "$want"
  say ""
  say "Restart the Studio for this to take effect:  studio-gpu.sh run"
}

cmd_run() {
  local mode app port url
  mode="$(cfg "['mode']")"
  app="$(cfg "['studio']['install_dir']")"

  if [ "$mode" = runpod ]; then
    say "The Studio is configured to run on the RunPod pod."
    say "  tunnel:  studio-gpu.sh tunnel up"
    say "  install: on the pod first — bash oneshot-setup-cuda.sh   (needs 48 GB+ VRAM, ~125 GB disk)"
    say "  then open http://127.0.0.1:$(cfg "['backends']['runpod']['local_port']") and use the pod's access key"
    return 0
  fi

  port="$(cfg "['backends']['local']['port']")"
  url="http://127.0.0.1:${port}"
  export PREFIX="$(cfg "['studio']['prefix']")"
  export STUDIO_HOME="$(studio_home)"
  mkdir -p "$STUDIO_HOME"
  say "Starting the Studio at $url  (STUDIO_HOME=$STUDIO_HOME)"
  cd "$app"
  exec "$VENV_PY" app/server.py
}

cmd_tunnel() {
  local action="${1:-up}" user host port key lport rport f
  user="$(cfg "['backends']['runpod']['ssh']['user']")"
  host="$(cfg "['backends']['runpod']['ssh']['host']")"
  port="$(cfg "['backends']['runpod']['ssh']['port']")"
  key="$(cfg "['backends']['runpod']['ssh']['identity_file']")"; key="${key/#\~/$HOME}"
  lport="$(cfg "['backends']['runpod']['local_port']")"
  rport="$(cfg "['backends']['runpod']['remote_port']")"
  f="$HERE/tunnel.pid"

  case "$action" in
    down)
      if [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; then say "  tunnel closed"; else say "  no tunnel running"; fi
      rm -f "$f"; return 0;;
    up) ;;
    *) die "tunnel: up|down";;
  esac

  say "Forwarding 127.0.0.1:${lport} -> ${host} -> 127.0.0.1:${rport}"
  ssh -i "$key" -p "$port" -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
      -L "127.0.0.1:${lport}:127.0.0.1:${rport}" "$user@$host" &
  echo $! > "$f"
  sleep 2
  if kill -0 "$(cat "$f")" 2>/dev/null; then
    say "  tunnel up (pid $(cat "$f")) — open http://127.0.0.1:${lport}"
    say "  close it with: studio-gpu.sh tunnel down"
  else
    rm -f "$f"; die "the tunnel did not stay up"
  fi
}

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-status}" in
  status)     cmd_status ;;
  validate)   case "${2:-$(cfg "['mode']")}" in
                local)  validate_local ;;
                runpod) validate_runpod ;;
                *) die "validate: local|runpod" ;;
              esac ;;
  use)        cmd_use "${2:-}" ;;
  placement)  write_placement "${2:-}" ;;
  run)        cmd_run ;;
  tunnel)     cmd_tunnel "${2:-up}" ;;
  help|-h|--help) usage ;;
  *)          usage; exit 1 ;;
esac
