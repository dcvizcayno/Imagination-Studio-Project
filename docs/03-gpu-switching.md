# 03 — The local ↔ Runpod switch

One config value decides where rendering happens. This document covers both the CLI and the in-app control that the Studio already ships.

## Why a switch rather than a hard-coded remote

Because the right answer changes:

- On a machine that meets the memory floor, local rendering is free, private and faster.
- On a machine below it, remote is the only option but costs money per hour.
- With both available, you want **local priority with remote fallback** — use what's free until it's busy.

## Two deployment shapes

| Shape | Where the Studio runs | Works when |
|---|---|---|
| `pod_as_worker` | On your Mac; the pod renders **single video clips** | Mac meets the 48 GB picture floor |
| `pod_as_studio` | On the pod; your Mac is a browser | **Mac below 48 GB** — the only viable shape |

`pod_as_worker` cannot rescue an under-spec Mac, because pictures, picture→video clips, long videos and exports always render on the host (`app/sparks.py`, `KINDS = ("video",)`, `here_only()`).

## Configuration

`config/gpu-switch.json` holds everything. The value you change is `mode`:

```json
{
  "mode": "local",
  "priority": ["local", "runpod"],
  "backends": {
    "local":  { "port": 7870, "requirements": { ... } },
    "runpod": {
      "shape": "pod_as_studio",
      "ssh": { "host": "<POD_IP>", "port": 22222, "user": "root",
               "identity_file": "~/.ssh/studio_ed25519" },
      "worker_address": "http://127.0.0.1:7870"
    }
  },
  "placement": {
    "local":         { "worker": "head", "policy": "prefer" },
    "local_strict":  { "worker": "head", "policy": "require" },
    "runpod":        { "worker": "http://127.0.0.1:7870", "policy": "prefer" },
    "runpod_strict": { "worker": "http://127.0.0.1:7870", "policy": "require" },
    "off": null
  }
}
```

Never hand-edit the derived files. `studio-gpu.sh` writes them.

## How this maps onto the Studio

The switch does not invent a parallel mechanism — it writes the app's own `placement` record into `$STUDIO_HOME/sparks/sparks.json`, which `app/sparks.py:555` validates:

| `mode` | `placement` written | Behaviour |
|---|---|---|
| `local` *(default)* | `{"worker":"head","policy":"prefer"}` | Head renders if free; spills to the pod when busy |
| `local_strict` | `{"worker":"head","policy":"require"}` | Head only, never offloads |
| `runpod` | `{"worker":"<pod>","policy":"prefer"}` | Pod first, falls back to head |
| `runpod_strict` | `{"worker":"<pod>","policy":"require"}` | Pod only; fails rather than falls back |
| `off` | `null` | Studio's stock scheduler |

`policy: "prefer"` on `head` **is** "local priority" — from `sparks.py team()`:

```python
if selected and selected["worker"] == "head":
    if selected["policy"] == "require" or not any(...running...):
        return []          # head takes it
    # otherwise falls through to worker scheduling → falls back
```

## CLI

```bash
./config/studio-gpu.sh status            # current backend + viability
./config/studio-gpu.sh validate local    # exit 1 when not viable
./config/studio-gpu.sh validate runpod   # ssh probe + real VRAM query
./config/studio-gpu.sh use local|runpod  # set mode + write placement
./config/studio-gpu.sh placement local   # write placement only
./config/studio-gpu.sh run               # start the Studio locally
./config/studio-gpu.sh tunnel up|down    # the ssh tunnel to the pod
```

`validate local` reproduces the installer's own gates, so it tells you *why* local is or isn't viable:

```
  Unified-memory gate (oneshot-setup.sh:261-280)
  x    24 GB < 48 GB — the installer dies at preflight in every mode.
       There is no picture-only tier below 48 GB; this is a hard stop, not a warning.
  VERDICT: local rendering is NOT viable on this Mac (1 blocking, 2 warning).
```

## In-app control (no CLI)

The Studio ships its own control — the CLI is only needed to *bootstrap* the worker record.

**Sparks tab → "Where new clips render"** (`static/sparks.js:150`)

| Field | Options | Maps to |
|---|---|---|
| Render on | `Automatic` · `Head · This Mac` · `Spark · <name>` | off / local / runpod |
| When busy or offline | `Use another renderer` · `Wait for it` | `prefer` / `require` |

**Local priority** = *Render on* `Head · This Mac` + *When busy or offline* `Use another renderer`.

Two practical notes:

- The panel is **hidden while the worker list is empty** — `spkPlacement()` returns `null` when there are no workers. Registering the pod (which `studio-gpu.sh placement` does) is what makes it appear.
- Friendly names come from `$STUDIO_HOME/sparks/labels.json`. The app only ever **reads** that file (`app/sparks.py:510`), so your labels survive upgrades:

```json
{ "head": "This Mac (M5 · 24 GB)", "http://127.0.0.1:7870": "Runpod H200" }
```

## Why not patch the Settings page

The upstream update path is `git pull` + `oneshot-setup.sh --upgrade`. Edits to the app's own JavaScript would be silently overwritten. This project therefore stays **data-only** — it writes `sparks.json` and `labels.json`, both of which are supported file interfaces, and leaves the app's code untouched.

## Verifying the wiring

After `placement runpod`, the running app must echo it back:

```bash
curl -s http://127.0.0.1:7870/api/sparks | python3 -m json.tool | head -20
```

```json
{
  "placement": { "worker": "http://127.0.0.1:7870", "policy": "prefer" },
  "workers": [{ "address": "http://127.0.0.1:7870", "name": "Runpod", "kind": "ssh" }]
}
```

If `placement` is `null`, the file went to the wrong place — it belongs at `$STUDIO_HOME/sparks/sparks.json`, not `$STUDIO_HOME/sparks.json` (`self.folder = home / "sparks"`, `app/sparks.py:459`).
