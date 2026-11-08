# 01 — Hardware validation

Before spending an hour on a GPU rental, establish what your machine can and cannot run. The Studio's installer enforces these numbers itself; they are not advisory.

## Apple silicon requirements

Source: `oneshot-setup.sh:261-280` (v4.3.1), `docs/installation.md` (upstream).

| Install mode | Unified memory | Disk |
|---|---|---|
| `--image-only` — Qwen-Image-2.1 only | **48 GB** | 40 GB |
| default — video, voice, music, Bolt | **96 GB** | ~185 GB |
| `--turbo` / `--ref2va` | **128 GB** | ~530 GB |
| Upscale / Remove-a-person | 192 GB | ~535 GB |

The gate:

```bash
FAST_NEED=96; FORMER_NEED=64
if [ "$VIDEO" = 0 ]; then NEED=48
elif [ "$TURBO" = 1 ] || [ "$REF2VA" = 1 ]; then NEED=128
else NEED=$FAST_NEED; fi

if [ "$RAM" -lt "$NEED" ] ... ; then
  die "needs ${NEED} GB+ unified memory ...; this Mac has ${RAM} GB"
fi
```

There is a legacy path that keeps **64–95 GB** machines on an install made before 4.3.1. It does not help anything below 64 GB.

## Non-memory requirements

| Requirement | Notes |
|---|---|
| Apple silicon, **macOS 26+** | Metal 4 is required for the int8 kernels |
| **M5 family** | The fast native video path is measured on M5 only. M1–M4 fall back to bfloat16 and are materially slower |
| `python@3.11`, `uv`, `ffmpeg` | `brew install python@3.11 uv ffmpeg` |

A useful shortcut is that `uv` and Python can be installed **without Homebrew**, entirely in user space — which is how this project set up its own head node.

## The verdict for a 24 GB M5

| Check | Requirement | Actual | Result |
|---|---|---|---|
| Repository valid | — | v4.4.0, Apache-2.0, active | ✅ |
| Chip | M5 family | Apple M5 | ✅ ideal |
| OS | macOS 26+ | 26.7.1 | ✅ |
| Arch | arm64 | arm64 | ✅ |
| Disk | 40–185 GB | ~239 GB free | ✅ |
| **Unified memory** | **48 GB minimum** | **24 GB** | ❌ **half** |

Empirically confirmed by running the real installer in its *smallest* configuration:

```
$ bash oneshot-setup.sh --image-only --yes

==> Preflight
  ✓ Apple M5, macOS 26.7.1, 24 GB
  ✓ version 4.3.1
FATAL: needs 48 GB+ unified memory for this install (measured on 256 GB only); this Mac has 24 GB
EXIT_CODE: 1
```

It exits before downloading a single byte. There is **no mode** that installs on 24 GB.

## What a remote GPU can and cannot fix

This is the part most people get wrong. The Studio's remote "worker" path accepts **only single video clips**:

```python
KINDS = ("video",)   # app/sparks.py:73 — what is handed to a worker
```

```python
def here_only(kind, params):
    if kind == "studio":
        return "A clip that starts from a new picture renders on this Spark: the picture model is here."
    if kind not in KINDS:
        return "Pictures, edits, Library actions and exports render on this Spark: only clips are handed to other Sparks."
```

| Job | Can render remotely? |
|---|---|
| Single video clip | ✅ |
| **Pictures (Qwen-Image)** | ❌ always on host |
| Pictures → video ("studio" clips) | ❌ |
| Long videos (chained) | ❌ |
| Edits, Library actions, exports | ❌ |

**Consequence:** attaching a pod as a *worker* does not rescue a host below 48 GB, because the host must still render pictures. Running the **entire Studio on the pod** (`pod_as_studio`) is the only viable shape — see [03-gpu-switching.md](03-gpu-switching.md).

## GPU-side requirements (Linux/CUDA)

Source: `oneshot-setup-cuda.sh:200-205`.

```bash
[ "$VRAM_GB" -ge 90 ] || [ "$IMAGE_ONLY" = 1 ] || [ "${STUDIO_ALLOW_SMALL_VRAM:-0}" = 1 ] \
  || die "video needs a card of about 96 GB ...; this one has ${VRAM_GB} GB. --image-only fits on 48 GB."
[ "$MEM_GB" -ge 64 ] \
  || die "the machine needs 64 GB of RAM or more beside the card"
```

| GPU VRAM | What you get |
|---|---|
| < 48 GB | nothing — below the picture floor |
| 48–89 GB | `--image-only` only, unless `STUDIO_ALLOW_SMALL_VRAM=1` (weights stream from RAM per block) |
| **≥ 90 GB** | full video install, models resident in VRAM |

**System RAM ≥ 64 GB is unconditional**, even for pictures. Many cheap GPU pods ship far less — check before renting.

## Reference hardware used by this project

| | |
|---|---|
| Host | Apple M5, 24 GB unified, macOS 26.7.1, arm64 |
| Pod | NVIDIA **H200 NVL**, 140.4 GB VRAM (driver 595.91.07) |
| Pod RAM / CPU | 2.27 TB / 128 vCPU |
| Pod OS | Ubuntu 24.04.5 LTS |
| Pod disk | 134 GB overlay |
