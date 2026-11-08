# Imagination Studio Project

Deployment kit and field notes for running **[Imagination Studio by keys+Wasserman](https://github.com/drowzeys/Imagination-Studio-by-keys-Wasserman)** on a remote GPU when your local machine is below the app's hardware floor.

This repo is **not** a fork of the Studio. It contains the compatibility research, the GPU-backend switch, and the deployment runbook that make a "Mac + rented GPU" setup work.

---

## Why this exists

Imagination Studio renders pictures, video and audio locally, and its installer enforces hard hardware minimums. On Apple silicon:

| Install mode | Unified memory required |
|---|---|
| `--image-only` (pictures) | **48 GB** |
| default (video, voice, music, Bolt) | **96 GB** |
| `--turbo` / `--ref2va` | **128 GB** |

A 24 GB Mac — even an **M5**, which is the exact chip the fast native path is built for — is *half* the absolute minimum. The installer doesn't warn, it exits:

```
$ bash oneshot-setup.sh --image-only --yes

==> Preflight
  ✓ Apple M5, macOS 26.7.1, 24 GB
FATAL: needs 48 GB+ unified memory for this install (measured on 256 GB only); this Mac has 24 GB
```

So this project moves the rendering to a rented GPU and keeps the Mac as the control surface.

## Architecture

```
┌─────────────────────────────┐         ┌──────────────────────────────────┐
│  Your Mac (24 GB)           │         │  Runpod GPU pod                  │
│                             │         │                                  │
│  Browser ──────────────┐    │  ssh -L │  ┌────────────────────────────┐  │
│                        │    │  7870   │  │  Imagination Studio 4.4.0  │  │
│  Studio UI (optional) ─┘    │ ──────► │  │  http://127.0.0.1:7870     │  │
│                        │    │         │  └────────────────────────────┘  │
│  gpu-switch/           │    │         │  ┌────────────────────────────┐  │
│    studio-gpu.sh ──────┘    │         │  │  ComfyUI + Qwen-Image 2.1  │  │
│                             │         │  │  FastH3 video + audio      │  │
└─────────────────────────────┘         │  └────────────────────────────┘  │
                                        └──────────────────────────────────┘
```

Two supported shapes (see [docs/03-gpu-switching.md](docs/03-gpu-switching.md)):

- **`pod_as_studio`** — the whole Studio runs on the pod; the Mac is a browser. *The only shape that works when the Mac itself cannot render pictures.*
- **`pod_as_worker`** — Studio runs locally and hands **single video clips** to the pod. Cannot rescue a Mac below 48 GB, because pictures, picture→video clips, long videos and exports always render on the host (`app/sparks.py`, `KINDS = ("video",)`).

## Verified results

Measured on the reference deployment — Apple M5 (24 GB) + Runpod **NVIDIA H200 NVL**:

| Test | Result |
|---|---|
| Still image, Qwen-Image-2.1-Turbo 1344×768 | **7.5 s** |
| Video, FastH3 8 passes, 864×480, 124 frames | **37 s** |
| Disk after core install | 127 GB used / 134 GB |
| Engine | CUDA via ComfyUI's own blocks (see caveat) |

> **Caveat:** the native Zig/TensorFold engine requires `nvcc` 12.9+; stock CUDA 12.8 images skip it and render on ComfyUI's blocks instead — slower, but fully functional. See [docs/04-troubleshooting.md](docs/04-troubleshooting.md).

### Pinned source

The exact Studio version these notes were tested against is preserved separately as an unmodified snapshot:

**[Imagination-Studio-4.4.0](https://github.com/dcvizcayno/Imagination-Studio-4.4.0)** — v4.4.0, upstream commit `4c66927`, Apache-2.0, notices retained verbatim. It exists for reproducibility only and does not track upstream. Model weights and Python environments are deliberately excluded from it (non-redistributable and platform-specific respectively).

## Quick start

### 1. Validate your Mac

Read [docs/01-hardware-validation.md](docs/01-hardware-validation.md) and confirm which tier you qualify for. Don't skip this — a pod costs money per hour and cannot fix a host that can't render pictures.

### 2. Provision the pod

Read [docs/02-runpod-deployment.md](docs/02-runpod-deployment.md). Minimums that matter:

| Resource | Minimum | Recommended |
|---|---|---|
| GPU VRAM | 48 GB (pictures) | **90 GB+** (video, no streaming) |
| System RAM | 64 GB | 128 GB+ |
| Container disk | 40 GB (pictures, 26 GB of weights) | **150 GB+** (core tier fetches 108 GB) |
| Persistence | — | network volume, or pay the 108 GB download again every restart |

### 3. Configure the switch

```bash
cp config/gpu-switch.json ~/.studio/gpu-switch.json   # edit the ssh block
./config/studio-gpu.sh validate runpod
./config/studio-gpu.sh use runpod
```

### 4. Switch backends

Once configured, you don't need the CLI. The Studio has a native control:

**Sparks tab → "Where new clips render"**

| Field | Options |
|---|---|
| Render on | `Automatic` · `Head · This Mac` · `Spark · <your pod>` |
| When busy or offline | `Use another renderer` (fallback) · `Wait for it` (strict) |

## Repository layout

```
README.md
LICENSE
docs/
  01-hardware-validation.md    Compatibility verdict and the hard gates
  02-runpod-deployment.md      Runbook: pod → install → tunnel → verify
  03-gpu-switching.md          The local/runpod switch, CLI and in-app
  04-troubleshooting.md        Every failure hit, with the real cause
config/
  gpu-switch.json              Backend switch configuration (template)
  studio-gpu.sh                status / validate / use / placement / run / tunnel
```

## Field notes worth reading first

The deployment runbook was written after hitting four separate failures. The two that cost the most time:

1. **An ssh key with a passphrase silently breaks automated deploys.** `ssh-keygen` stores the public half unencrypted, so ssh can *offer* the key and the server reports `Accepted key` — then signing fails and the client aborts with `Permission denied`. Use `-N ""`. Full trace in [docs/04](docs/04-troubleshooting.md#1-the-userauththenticated-0-trap).
2. **Runpod does not always inject `PUBLIC_KEY` into `/root/.ssh/authorized_keys`.** On the tested image (`runpod/pytorch`), `/root/.ssh` simply did not exist. Verify before blaming keys or 2FA.

## Credits and licensing

- **Imagination Studio by keys+Wasserman** — built by [Keys (drowzeys)](https://github.com/drowzeys) with Sam Wasserman / Wasserman Productions, powered by TensorFold. Apache-2.0. This repo contains no Studio source code; it documents and configures an installed copy.
- Model weights retain their own licences and are **not** redistributed here. Qwen-Image-2.1 and MMAudio weights are non-commercial; MiniMax H3 has territory limits; Fish Audio hosted services need separate licensing. Check the upstream [licensing guide](https://github.com/drowzeys/Imagination-Studio-by-keys-Wasserman/blob/main/docs/licensing.md) before commercial use.
- This repo's own content: MIT — see [LICENSE](LICENSE).
