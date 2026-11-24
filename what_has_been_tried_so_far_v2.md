# What Has Been Tried So Far — Qwen 3.6 / WSL2 / 7900 XTX

Companion to the repeatable setup guide. That doc gives you the clean path; this one explains the reasoning, evidence, and dead ends behind *why* it looks the way it does — worth reading if something breaks again, or if you want to revisit the open ROCm question later.

---

## Current Operational State

**Generation runs on the Vulkan backend (`build-vulkan`), not HIP/ROCm — by necessity, not preference.** Vulkan is measurably slower (~19.5 t/s vs. HIP's theoretical ~1000+ t/s territory), but it's the only backend that has completed multiple full, clean, end-to-end runs with no crashes. The HIP/ROCm build is still compiled and used for prompt-processing benchmarking, where it reliably works — it's specifically the *generation* phase that has never once completed successfully on ROCm across this entire setup, regardless of what was changed.

---

## The Core Investigation: Why Doesn't ROCm/HIP Generate Tokens?

### The symptom, consistently
Every single ROCm/HIP attempt to generate tokens (as opposed to just processing a prompt) either hangs indefinitely or crashes the entire PC. Prompt processing (`pp512`) — a handful of large, batched GPU calls — has *always* worked, every time, on every test. Generation (`tg128`) — thousands of small, sequential dispatches — has *never once* completed.

### Hypothesis 1: The rocWMMA flash-attention kernel
Since the HIP build was specifically compiled with `-DGGML_HIP_ROCWMMA_FATTN=ON`, this newer kernel path was the first suspect.
**Test:** re-ran with `-fa 0` (flash attention off).
**Result:** hung/crashed just the same. **Ruled out** — this isn't a flash-attention-specific bug.

### Hypothesis 2: Qwen 3.6's hybrid architecture
Qwen 3.6 uses an unusual hybrid design (16 full-attention layers + 48 "Gated DeltaNet" linear-attention layers). A search turned up [llama.cpp GitHub issue #19880](https://github.com/ggml-org/llama.cpp/issues/19880), which describes ROCm breaking specifically on this model family while Vulkan handles it fine — a strong, currently-open, tracked upstream match for our symptoms.
**Test:** downloaded a small, architecturally ordinary model (Qwen2.5-1.5B-Instruct, plain transformer, no hybrid layers) and tried generating with it.
**Result:** hung too — zero GPU activity in Task Manager for the full timeout window. **Weakens this theory** — if a tiny, ordinary model can't even *start* generating, this doesn't look purely architecture-specific. (It doesn't fully rule out issue #19880 being real and relevant — it may just mean there's *also* a more general problem underneath it.)

### The hard crash: DRIVER_IRQL_NOT_LESS_OR_EQUAL
Twice during this investigation, a long-running HIP generation test — both times while tabbed away from the terminal — took down the entire PC with this Windows bugcheck (a kernel-level driver fault, not an application crash). VRAM was at ~23.2GB/24GB both times.
**Investigated via Event Viewer:** found Hyper-V "Virtual PCI protocol version" errors (Event 33101) around the crash time. Initially treated as a likely cause — then walked back after research showed these are actually common, largely benign WSL2/Hyper-V log noise that shows up on many systems regardless of stability. No Display-driver or `amdkmdap` TDR (Timeout Detection and Recovery) events were found even with full Warning/Information logging enabled, which argues against a "GPU driver attempted a clean reset and that cascaded into failure" explanation — whatever happened, it was too abrupt for that usual pathway to even engage.

### Hypothesis 3: A known ROCm/SDMA driver bug
`HSA_ENABLE_SDMA=0` is a documented workaround for a class of ROCm stability issues on consumer RDNA GPUs.
**Test:** ran the same generation test with this variable set.
**Result:** made things *worse*, not better — the process hung with **zero GPU activity** during model loading, before generation even began (previously it had at least gotten through loading and into generation). **Ruled out**, and reverted.

### Hypothesis 4: Leftover corrupted GPU-passthrough state from the crash
Processes were found stuck in kernel `D` state (uninterruptible sleep) — unkillable even by `SIGKILL` — after the crashes. This raised the question of whether Windows' GPU-passthrough session to WSL2 was left in a bad state that a simple `wsl --shutdown` doesn't fully clear.
**Test:** a full Windows restart (not just `wsl --shutdown`), then immediately retried the small-model test.
**Result:** hung again, identically, right after a clean restart. **Ruled out** — this isn't residual damage from the crash; it's reproducible from a fresh boot.

### Hypothesis 5: Mesa version skew from the Vulkan driver install
Getting Vulkan working had required the `kisak-mesa` PPA, upgrading several Mesa packages system-wide (25.2.8 → 26.1.4). ROCm's userspace shares low-level plumbing with Mesa (`libdrm`), so a version mismatch was a plausible way to degrade HIP reliability without `rocminfo`'s simple device check ever noticing.

Around this point, a retest of the *original, exact command that had worked cleanly at the very start* (`llama-bench -fa 1`, no other changes) came back with the same `pp512` phase completing, but with much wider variance (`844.32 ± 262.20`, vs. the original `1006.76 ± 46.29`) before hanging/crashing on generation — a sign of general instability, not just a generation-specific issue.

**Test:** rolled Mesa back to stock via `ppa-purge` (losing the Vulkan driver as an expected side effect), then reran the same baseline command.
**Result:** variance returned to healthy (`1026.24 ± 58.49`) — seemingly confirming the theory.

**However:** Vulkan needed to be restored afterward, which required re-adding `kisak-mesa`'s `mesa-vulkan-drivers` package — and apt's dependency resolver pulled the *entire* Mesa family back to 26.1.4 in the process (there's no way to upgrade just the Vulkan driver package alone; they're version-locked together). A follow-up prompt-processing-only retest (`-n 0`, generation intentionally skipped) came back healthy again (`1024.29 ± 48.20`) — **on the exact same Mesa version that had supposedly been the problem.** See Open Questions below — this genuinely undercuts confidence in the Mesa theory.

### Where this leaves us
A real, currently-open upstream issue matches our symptoms closely. We've eliminated flash attention, a known SDMA workaround, leftover crash corruption, and (with real evidence, if imperfect certainty) Mesa version as clean explanations. What's left is the honest conclusion that this is a genuine, unresolved environment-level bug in how ROCm/HIP handles sustained generation on this specific WSL2 + gfx1100 + driver combination — not something fixable from the configuration side with what's currently available. Vulkan is the practical answer for now.

---

## Open Questions

Worth being direct about what's genuinely still unknown, rather than overstating how settled this is:

- **Was Mesa version really the cause of the degraded variance, or a coincidence?** The timing lines up, but the same Mesa version was reinstalled at the end and tested healthy again. We may have been looking at two confounded variables (Mesa version *and* accumulated system state from repeated crashes) and only partially separated them.
- **Would HIP generation work now, in the current final state?** We only ever retested prompt-processing (`-n 0`) after the last Mesa change — full generation was never retried again after that point. It's possible it's fine now; it's possible it isn't. Genuinely untested.
- **Are the two hard crashes and the many "softer" D-state hangs the same underlying bug, or two different problems that happen to both surface during generation?** No way to distinguish this with the evidence gathered.
- **Are the Hyper-V Event 33101 errors truly unrelated noise?** Most evidence says yes (widely reported as benign), but one online report of the same log pattern also mentioned an unexplained BSOD, so it isn't a fully closed question.

If picking this back up later, the most efficient next move is probably re-testing full HIP generation once, cleanly, in the current state — that single result would resolve two of the four open questions above at once.

---

## What Was Tried But Failed

Everything below either didn't work, turned out to be a false lead, or was a wrong turn corrected along the way — grouped by theme. Nothing here made it into the final repeatable-steps doc.

### A. ROCm/HIP Generation — Fix Attempts

| Attempt | Result |
|---|---|
| Disable flash attention (`-fa 0`) | Still hung/crashed — ruled out as the cause |
| `HSA_ENABLE_SDMA=0` env var | Made it worse (hung earlier, during model load, zero GPU activity) — reverted |
| Full Windows restart (not just `wsl --shutdown`) | Hang reproduced immediately after — ruled out "leftover crash state" theory |
| Test with tiny non-hybrid model (isolate architecture) | Also hung — weakened the "hybrid-architecture-specific" theory |
| Mesa rollback via `ppa-purge` | Variance improved, but re-adding Mesa for Vulkan brought it back healthy too — inconclusive, see Open Questions |

### B. Vulkan Bring-Up Detours

- **`vulkaninfo` initially showed only `llvmpipe`** (software/CPU rendering) — no GPU-backed Vulkan device at all. Root cause: WSL2's `/dev/dri` didn't exist until the `vgem` kernel module was manually loaded (`sudo modprobe vgem`) — and this module doesn't persist across reboots, so it needed reloading each session until folded into the `wsl.conf` boot command in the final setup.
- **Stock Ubuntu 24.04's Mesa package doesn't include the `dzn` (Dozen) Vulkan driver** WSL2 needs for GPU-backed Vulkan — required the third-party `kisak-mesa` PPA.
- **Direct apt package route for llama.cpp's Vulkan build dependencies failed** (`spirv-headers`, `libspirv-tools-dev`, `glslang-tools`, `libshaderc-dev`) — didn't resolve the `SPIRV-Headers` CMake config error. Had to fall back to installing the full LunarG Vulkan SDK instead, which bundles consistent versions of everything.
- **`vulkan-sdk` package conflict during the Mesa `ppa-purge` process** — `apt --fix-broken install` tried to unpack a `shaderc` package that collided with an already-installed `glslc` package (`trying to overwrite '/usr/bin/glslc'`). Resolved by removing `vulkan-sdk` entirely, fixing the broken dependency state, then proceeding with the Mesa purge separately.

### C. WSL Isolation "Red Herrings"

Two investigations that consumed real time but ultimately confirmed the isolation was working correctly all along:

- **`/mnt/c` appeared to still show a `Users` folder** even after `automount=false` was set. Investigated via `stat` device-ID comparison — turned out to be an empty placeholder folder living inside WSL's *own* filesystem (same device ID as `/`), not an actual connection to the real C: drive (albeit it was still "seeing" the physical hardware given that there were 5 drives matching the same drive letters as the Windows OS drive letters). A non-issue given that these files were empty (besides a few Docker items on the C: drive), but still something worth noting.
- **`.aws`, `.azure`, and `.docker` folders appeared to exist** under that same placeholder path. Investigated as a possible credential leak — checked contents (all completely empty), checked `findmnt` and `/proc/mounts` (no active mount). Explained by Docker Desktop's WSL integration scaffolding empty placeholder folders directly into the distro's filesystem as part of its own setup — never actually connected to real Windows files at any point. Also a non-issue, but worth the thorough check given what was at stake.
- **`systemd` was found to silently remount `/mnt/c`** even with `automount=false` set — a known quirk when `systemd=true` is also enabled. Fixed by adding an explicit `umount -l /mnt/c` to the `wsl.conf` boot command rather than relying on `automount=false` alone.
- **Docker's CLI failed to pull even public images** (`docker-credential-desktop.exe` not found) once `interop` was disabled, since that credential helper is a Windows executable WSL could no longer reach. Fixed by removing the `credsStore` line from `~/.docker/config.json` — with the tradeoff that any future `docker login` credentials would be stored in plain text rather than a secure keychain (not a concern for the public-image use case here).

### D. Model Download Missteps

- **`unsloth/Qwen2.5-1.5B-Instruct-GGUF`** — this repo doesn't exist (404). Wrong assumption about Unsloth's naming for this particular small model.
- Corrected to the actual official **`Qwen/Qwen2.5-1.5B-Instruct-GGUF`** repo — small, genuinely GGUF, genuinely a plain transformer architecture.

### E. Terminal, Process & Tooling Mishaps

- **PID confusion** — `ps aux | grep <name>` always shows a line matching `grep`'s own process against itself; this is normal and not a real result to act on. The actual target process is whichever line matches the full command being searched for, not the `grep` line.
- **Multi-line pasted commands with `\` line continuations** occasionally got mangled by terminal auto-indent/wrapping, showing as fragments like `-cache-t>` — cosmetic display confusion from bash's continuation prompt, not an actual error.
- **An incomplete, unclosed quoted `curl` command** was mistaken for a GPU hang at first glance — it was actually just bash waiting at a continuation prompt (`>`) for a closing quote that was never typed. Ctrl+C resolved it instantly once identified.
- **Running commands from the wrong working directory** (`~` instead of `~/llama.cpp`) produced "No such file or directory" for otherwise-correct relative paths like `./build-hip/bin/llama-bench`.
- **`timeout <seconds> <command>`** without `-s KILL` sends only `SIGTERM` by default, which a process wedged in a kernel-level `D` state can simply ignore — leading to timeouts that don't actually time out. `timeout -s KILL` (forces `SIGKILL`) is the more reliable form when a hang is suspected.
- **`hf: command not found`** after installing `huggingface_hub[cli]` via pip — the installed scripts landed in `~/.local/bin`, which wasn't yet on `PATH`. Fixed by adding it to `PATH` and persisting that to `.bashrc`.

### F. Disk Space Recovery Attempt

- C: drive dropped to under 10GB free — cumulative effect of the full ROCm install, the LunarG Vulkan SDK (which pulls in a large Qt dependency tree), two separate llama.cpp build directories, and ~21GB+ of model files (including the incorrectly-downloaded `Qwen3.5-2B`), all living inside WSL2's virtual disk on the C: drive by default.
- Attempted `diskpart` compaction of the WSL virtual disk (`select vdisk`) — failed because the command needs the actual `.vhdx` file path attached via `file="..."` and was run without it.
- Ultimately resolved a different way — by clearing unrelated files elsewhere on C:, not through any WSL-specific fix. The `diskpart` compaction and the `~/models/test-small` cleanup (leftover wrong-model download) remain genuinely outstanding if more space is needed later — see the Notes section of the main setup guide.