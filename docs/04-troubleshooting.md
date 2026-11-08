# 04 — Troubleshooting

Every failure encountered during the reference deployment, with the actual cause. Ordered by how much time they cost.

---

## 1. The `authenticated 0` trap

**Symptom.** SSH fails with `Permission denied (publickey)` *despite* a correctly registered key. Verbose output shows the server accepting it:

```
debug1: Offering public key: /Users/you/.ssh/id_ed25519 ED25519 SHA256:IS5eQU… explicit
debug1: Server accepts key: /Users/you/.ssh/id_ed25519 ED25519 SHA256:IS5eQU… explicit
root@<POD_IP>: Permission denied (publickey,password).
```

The server-side log shows exactly where it dies:

```
Accepted key ED25519 SHA256:IS5eQU… found at /root/.ssh/authorized_keys:1
debug2: userauth_pubkey: authenticated 0 pkalg ssh-ed25519 [preauth]
Postponed publickey for root … [preauth]
Connection closed by authenticating user root … [preauth]
```

**Cause.** The private key has a **passphrase**. OpenSSH stores the public half *unencrypted* inside the private key file, so the client can derive and offer it — hence `Accepted key`. But producing the signature requires decrypting the private key. With no agent and no terminal (`BatchMode`), ssh cannot prompt, so it aborts the handshake. The client closes, the server logs `authenticated 0`.

**Diagnosis.**

```bash
ssh-keygen -y -f ~/.ssh/id_ed25519
# Enter passphrase for "/Users/you/.ssh/id_ed25519":   ← a passphrase-free key never prompts
```

**Fix.** Use a key with no passphrase for automation:

```bash
ssh-keygen -t ed25519 -N "" -C "studio-deploy" -f ~/.ssh/studio_ed25519
```

| Symptom | Meaning |
|---|---|
| `Server accepts key` then denied | key found, but signature never sent — usually passphrase |
| `Offering public key` and no `Server accepts key` | key is not in `authorized_keys` at all |

---

## 2. `PUBLIC_KEY` set but `/root/.ssh` missing

**Symptom.** The pod's environment has your key:

```json
"env": { "PUBLIC_KEY": "ssh-ed25519 AAAA… you@example.com" }
```

…yet `/root/.ssh` does not exist and no key can authenticate.

**Cause.** On the tested image (`runpod/pytorch:1.5.0-cu1281-torch280-ubuntu2404`) the startup hook that writes `PUBLIC_KEY` into `authorized_keys` did not run. Setting `PUBLIC_KEY` is not proof that it was applied.

**Diagnose.**

```bash
ls -la /root/.ssh          # does it exist?
sshd -T | grep -iE "authorizedkeysfile|permitrootlogin|pubkeyauth"
```

Expected: `authorizedkeysfile .ssh/authorized_keys`.

**Fix.** Create it once, then the normal key flow works:

```bash
mkdir -p /root/.ssh
echo 'ssh-ed25519 AAAA… you@example.com' >> /root/.ssh/authorized_keys
chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys
```

Note this is lost on the next pod restart — see [§5](#5-everything-vanishes-on-restart).

---

## 3. Red herrings (all ruled out by evidence)

Worth recording, because each one looks plausible and wastes an hour.

| Hypothesis | Why it was wrong |
|---|---|
| Two-factor auth broke SSH | Runpod 2FA guards the **web console**. The pod's `sshd` advertises only `publickey,password` — no `keyboard-interactive`, which is the only channel TOTP could use |
| The key isn't registered | `runpodctl ssh list-keys` showed the exact fingerprint |
| `authorized_keys` permissions / `StrictModes` | `-rw------- root root`, `/root` and `.ssh` both `root:root 700` |
| Locked root password (`*`) + `UsePAM yes` | Still denied after setting `UsePAM no` and reloading sshd |
| Expired account / `/etc/nologin` | `Account expires: never`; no nologin file |
| `AllowUsers` / `DenyUsers` | None configured |
| Wrong container behind the port | `Server accepts key` only appeared *after* writing the file — proving the same filesystem |

**Lesson:** the decisive artifact was the **server-side `sshd -ddd` trace**, not client-side guesses. When auth behaves impossibly, capture the server log.

### Capturing a server-side sshd trace

When `/var/log/auth.log` is empty (common in containers), run sshd in debug mode on a spare port and read the log from the pod's Jupyter API or a second session:

```bash
pkill -x sshd; sleep 1
nohup /usr/sbin/sshd -ddd -p 22 > /tmp/sshd_debug.log 2>&1 &
sleep 2; ss -tlnp | grep :22
```

Make one connection attempt, then read `/tmp/sshd_debug.log`. `-d` handles exactly **one** connection and exits — restart the daemon afterwards with `/usr/sbin/sshd`.

---

## 4. The native engine did not build

**Symptom.**

```
/usr/local/cuda/bin/nvcc is CUDA 12.8; the GB10 needs 12.9 or newer
the engine did not build: clips will render on ComfyUI's own blocks (slower).
```

**Cause.** The TensorFold Zig/CUDA engine requires `nvcc` 12.9+. Stock CUDA 12.8 images can't build it.

**Impact.** None on functionality — rendering falls back to ComfyUI's own blocks. Throughput is lower, not absent. Reference numbers on that path: 7.5 s for a 1344×768 still, 37 s for a 5 s 864×480 clip.

**Fix (optional).** Use an image with CUDA 12.9+, or prebuilt carrier image via Docker:

```bash
# with docker present, the installer pulls the prebuilt engine instead of building
bash spark/build-engine.sh
```

---

## 5. Everything vanishes on restart

**Symptom.** The SSH key stops working after any pod stop/start; models must be re-downloaded.

**Cause.** Runpod's **container disk is ephemeral**. Every restart — *including an innocent disk resize* — recreates the container from the image:

| Action | Result |
|---|---|
| Resize container disk | new port, container wiped |
| Stop → start | new port, container wiped |

That is why a resize in the middle of debugging silently deletes `/root/.ssh` and any staged key.

**Fix.** Attach a **network volume** and mount it at the models path (`/root/spark-studio-models`, override with `SPARK_MODELS`). Do the key install *after* the final resize, never before.

**Note:** the exposed-TCP **port and IP change on every restart** — always re-copy the connection line from the console.

---

## 6. Pod stuck in `initializing / awaiting_container`

**Symptom.**

```bash
runpodctl pod list
# runtimeStatus: initializing, runtimeStatusReason: awaiting_container
```

for many minutes, while SSH returns `Permission denied (publickey)`.

**Cause.** The container has not started yet, so there is no `sshd` to authenticate against. Nothing is wrong with your key.

**Diagnose.**

```bash
runpodctl pod get <POD_ID>   # watch uptimeSeconds and runtimeStatus
```

**Fix.** Wait. Large PyTorch images take minutes to provision. Do not start regenerating keys — that is how the passphrase confusion begins.

---

## 7. Disk runs out mid-install

The installer checks once, before downloading:

```bash
[ "$FREE" -ge "$NEED" ] || die "…has ${FREE} GB free; what is not here yet needs about ${NEED} GB"
```

Dry-run the math first:

```bash
STUDIO_DISK_DRY=1 bash oneshot-setup-cuda.sh --yes
# need=108 ref2va=0 swap=0 vram=140
```

| Tier | Weights |
|---|---|
| `--image-only` | 26 GB |
| core (pictures + video) | **108 GB** |
| `--all` | 400 GB+ |

A 134 GB container disk lands the core tier at **127 GB used / 7.7 GB free**. Workable but with almost no headroom — size up to 150 GB+ if you plan to add LoRAs or optional models.

---

## 8. Reading installer progress

The log is full of carriage-return spinners that make `tail` unreadable. Strip them:

```bash
tail -f /workspace/studio-install.log | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g'
```

`df -h /` is the more honest progress indicator — watch `used` climb toward `need`.
