# 02 — Runpod deployment runbook

End-to-end: rent a pod, make SSH work, install the Studio, tunnel to it, verify.

> Commands assume `pod-ssh` below is:
> ```bash
> ssh -i ~/.ssh/studio_ed25519 -p <PORT> -o IdentitiesOnly=yes root@<POD_IP>
> ```
> Replace `<POD_IP>` and `<PORT>` with the values from the pod's **Connect → SSH over exposed TCP** panel.

---

## 0. Before you rent: size the pod

| Resource | Floor | Recommended | Why |
|---|---|---|---|
| GPU VRAM | 48 GB | **90 GB+** | ≥90 GB means no weight-streaming; 140 GB H200 NVL used here |
| System RAM | 64 GB | 128 GB+ | unconditional check, even for pictures |
| Container disk | 40 GB | **150 GB+** | core tier fetches **108 GB** of weights |
| Network volume | — | strongly advised | container disk is wiped on every restart |

The installer computes its own requirement before downloading:

```
==> Preflight
  ✓ NVIDIA H200 NVL, x86_64, 2267 GB
need=108 ref2va=0 swap=0 vram=140
```

`need` is the download size for your selected tier. If `df` shows less, it refuses.

## 1. Get SSH working — the step that burns the most time

**Use a key with no passphrase.** This is non-negotiable for automation:

```bash
ssh-keygen -t ed25519 -N "" -C "studio-deploy" -f ~/.ssh/studio_ed25519
cat ~/.ssh/studio_ed25519.pub
```

Add that public key to **console.runpod.io → Settings → SSH Public Keys**, then **stop and start the pod** so the container is recreated with it.

Verify — this must print a hostname and `0`:

```bash
ssh -i ~/.ssh/studio_ed25519 -p <PORT> -o IdentitiesOnly=yes root@<POD_IP> 'hostname; id -u'
```

If it fails, go to [04-troubleshooting.md](04-troubleshooting.md). Do not proceed until this works; everything below depends on it.

## 2. Confirm the hardware from inside the pod

```bash
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
free -g | head -2
df -h / | tail -1
nproc
```

Expected for the reference deployment:

```
NVIDIA H200 NVL, 143771 MiB, 595.91.07
Mem:  2267 total
overlay  134G ... 134G avail   1%
128
```

Abort here if free disk is under ~120 GB for the core tier.

## 3. Install the Studio

Install `git`, `ffmpeg`, `ffprobe` first (the installer refuses without them):

```bash
apt-get update -qq && apt-get install -y -qq git ffmpeg
```

Clone and run. `--yes` skips the interactive checklist so it runs unattended:

```bash
cd /workspace
git clone --depth 1 https://github.com/drowzeys/Imagination-Studio-by-keys-Wasserman.git
cd Imagination-Studio-by-keys-Wasserman

setsid nohup bash oneshot-setup-cuda.sh --yes \
  > /workspace/studio-install.log 2>&1 < /dev/null &
```

`setsid nohup … &` detaches it so an SSH disconnect cannot kill a 108 GB download.

Monitor:

```bash
tail -f /workspace/studio-install.log | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g'
df -h /
```

`df` is the honest progress bar — the log is full of carriage-return progress spinners.

**Expected wall time:** ~8 minutes to fetch 108 GB on a fast pod, a few minutes more for the Python environment and test clip.

### Choosing a tier

| Flag | Effect | Disk |
|---|---|---|
| *(none)* + `--yes` | pictures + FastH3 video | 108 GB |
| `--image-only` | pictures only | 26 GB |
| `--all` | everything the machine runs | 400 GB+ |

Do a dry run of the disk math before committing:

```bash
STUDIO_DISK_DRY=1 bash oneshot-setup-cuda.sh --yes
```

## 4. Verify the install

The installer ends with real renders, not a version check:

```
✓ outputs/test.png  (1344x768, turbo)          7.5 s
✓ outputs/test.mp4  (864x480, 124 frames)     37 s
DONE. Web app: bash scripts/app.sh (http://127.0.0.1:7870)
```

If `test.mp4` exists, the GPU path works end to end.

> **Engine note.** If you see `the engine did not build … clips will render on ComfyUI's own blocks (slower)`, that is expected on CUDA 12.8 images — the Zig engine needs `nvcc` 12.9+. Rendering still works. See [04](04-troubleshooting.md#4-the-native-engine-did-not-build).

## 5. Start the Studio and tunnel in

On the pod, detached so it survives disconnects:

```bash
cd /workspace/Imagination-Studio-by-keys-Wasserman
setsid nohup bash scripts/app.sh > /workspace/studio-app.log 2>&1 < /dev/null &
sleep 5 && curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7870/
```

From your Mac:

```bash
ssh -i ~/.ssh/studio_ed25519 -p <PORT> -N \
  -L 127.0.0.1:7870:127.0.0.1:7870 root@<POD_IP>
```

Then open **http://127.0.0.1:7870**. The Studio binds to localhost, so no access key is needed through the tunnel.

## 6. Wire the switch

```bash
./config/studio-gpu.sh validate runpod   # queries real VRAM over ssh
./config/studio-gpu.sh use runpod
```

See [03-gpu-switching.md](03-gpu-switching.md).

## 7. Protect the work you just paid for

The container disk is **wiped on every restart** — including the SSH key install. Before you invest another hour, attach a **network volume** and mount it at the models directory:

```
/root/spark-studio-models
```

Override the location with `SPARK_MODELS` if you mount elsewhere. Without this, every restart re-fetches 108 GB.

## Cost awareness

The reference pod ran at **$3.79/hr**, so an idle pod is the most expensive mistake available. Stop it when you finish:

```bash
runpodctl pod stop <POD_ID>
```
