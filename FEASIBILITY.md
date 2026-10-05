# Too Human (Xbox 360) — Decompilation / Recompilation Feasibility

**Target: native Linux (x86-64), Vulkan backend**
**Date: 2026-10-04 · Analysis based on the local USA XGD2 dump**

---

## Verdict

**Feasible, with a proven toolchain path — moderate-to-high effort, concentrated in per-title iteration rather than research.**

The "decompile & recompile" approach you're describing now exists as a real, public toolchain for Xbox 360:
the **ReXGlue SDK** (`rexglue/rexglue-sdk`), a Xenia-derived static-recompilation runtime that converts
PowerPC Xenon code into portable C++ and links it against a native host runtime with Vulkan graphics —
with Linux amd64 as a first-class CI target. Multiple retail 360 games (Burnout Revenge, Ridge Racer
Unbounded, Split/Second, several XBLA titles) are already shipping as native Linux ports built on it
(`CrownParkComputing/Xbox360-Native-Ports`), so the approach is proven on disc-based UE3-era titles.

Too Human specifically is a *good* candidate on paper:

- It **boots and runs in Xenia Canary today** (video evidence, community reports), and ReXGlue's
  console-OS layer is derived from Xenia — so the kernel-HLE, GPU-command, and audio coverage this
  game needs is already largely written upstream.
- The executable is a single **20.1 MB retail XEX2** — one PPC module, no per-DLL hell.
- It's **Unreal Engine 3** (stock-style `Engine.ini`, `TH1Game.TH1GameEngine` class references,
  `.war` cooked maps) with a static engine+game link. UE3 titles are the most-recompiled genre of
  the 360 era.

The caveats: ReXGlue self-describes as **v0.3.x / early development** ("expect things to not work
quite right"), the port process is **not push-button** (manual function boundaries, missing kernel
imports, iterate), and VMX128/paired-singles coverage in codegen isn't explicitly documented — UE3
uses Xenon vector math heavily, so expect to either find it's covered or extend the dispatch table.

---

## 1. What's on the disc (verified from the local ISO)

XGD2 image, 7.3 GB, game partition at LBA 0x7ECC0 (`MICROSOFT*XBOX*MEDIA` XDVDFS volume).
Extracted with `XboxDev/extract-xiso` → `extracted/` (28,027 files, 6.3 GB):

| Content | Count | Format | Notes |
|---|---|---|---|
| `Default.xex` | 1 | XEX2 retail | 20,135,936 B; base `0x82000000`, entry `0x82A46B18`, image ~21.4 MB |
| Streamed SFX | 25,721 | `.xma` = RIFX/WAVEXMA2 | Big-endian XMA2 — vgmstream/ffmpeg-class problem |
| Packages | 1,837 | `.zzz.gz`, `.g00–g49.gz`, `.stm.gz` | Plain gzip → custom BE container, magic `0xF0 0FD CA FE` |
| Sound banks | 97 | `.bnk` = `BKHD` | **Audiokinetic Wwise** banks (Init.bnk + per-world) |
| Cinematics | ~340 | `.stm` (in gzip) | `STOC` container with `VIDS` video stream |
| Menu UI | 18 | `.bgf` = `AnarkBGF` | **Anark Studio** middleware (matches `AnarkMenus.*` localization) |
| Video | 20 | `.wmv` | Standard WMV9 |
| Data tables | 242 | `.csv` | Plaintext item/armor/weapon stats |
| Config | 6 | `.ini` | Plaintext UE3 configs (`TH1Engine.ini` etc.) |
| Localization | ~90 | `.int/.deu/...` | UE-style localization files |

Two implications:

1. **The executable is the only thing that needs recompiling.** Everything else is data that a
   runtime can read as-is from disc (ReXGlue's model) — you do not need to understand the
   `0xF00DCAFE` package format to *run* the game, only to *mod* it.
2. **Asset tooling is a solved ecosystem.** Wwise (ww2ogg & friends), XMA2 (vgmstream), WMV/Bink-era
   video (ffmpeg), and Anark BGF all have public RE work behind them if you later want to extract or
   replace content.

## 2. Engine identification

`Config/TH1Engine.ini` is unmistakably UE3 (`Protocol=unreal`, `Render=Render.Render`,
`GameEngine=TH1Game.TH1GameEngine`, `MapExt=war`, `EXEName=TH1Game.exe`), ~2007-era UE3 with heavy
Silicon Knights customization (custom `.war` cooked maps, custom package container, Wwise instead of
FMod/XAudio-direct). Note the irony given the SK–Epic litigation: the shipped game is UE3-derived.

For recomp feasibility what matters: **one fat PPC module** containing engine + game-native code.
No separate script DLLs; UnrealScript lives cooked inside the packages and executes on the VM inside
the module — the recomp doesn't care.

## 3. The XEX

From header parsing of `extracted/Default.xex`:

- `XEX2`, module flags = Title, 15 optional headers
- Base address `0x82000000`, entry point `0x82A46B18`
- Security header present → standard **retail encryption + (likely) LZX compression**; all the
  360-era signing/encryption keys are public and handled by Xenia's XEX loader (which ReXGlue
  inherits) and by every xextool derivative. This is a solved step, not a research risk.
- The executable carries MSVC-style **`.pdata` exception tables** (ReXGlue's analyzer consumes these
  to find function boundaries — a big win vs. pure heuristic discovery).
- Maps/disc content live in the disc filesystem; the XEX2 header also carries the usual
  save-game/disc-permission metadata.

## 4. Toolchain landscape (as of Oct 2026)

| Tool | Role | Status |
|---|---|---|
| **ReXGlue SDK** (`rexglue/rexglue-sdk`) | PPC→C++23 static recompiler + Xenia-derived native runtime; Linux amd64/arm64 CI; nightly builds (latest Sep 2026) | The main path. v0.3.x, early but active, multiple shipped ports |
| **Xbox360-Native-Ports** | Reference implementations: disc-based retail games (Burnout Revenge etc.) ported with launchers importing user ISOs | Proof the pipeline handles retail discs end-to-end |
| **XenonRecomp / rexdex** | Earlier-generation PPC recompilers ReXGlue credits | Fallback / reference |
| **Xenia Canary** | Dynamic emulator; Vulkan GPU; Too Human runs today | Phase-0 validation + the HLE code ReXGlue reuses |
| `XboxDev/extract-xiso` | XDVDFS extraction (built & used for this analysis) | Done — `extracted/` |
| Ghidra (+ PowerPC BE, Xenon/VMX128 community module) | Manual analysis, function naming, patch development | Standard |
| vgmstream / ww2ogg / ffmpeg | XMA2, Wwise, WMV decode for asset work | Optional, not needed to run |

ReXGlue workflow (from its wiki): `rexglue init` → point `file_path` at the XEX → build the
`*_codegen` CMake target → link generated C++ against the runtime → iterate on function boundaries
(TOML `[functions]`), switch tables, and missing kernel imports; `--force` emits code with error
comments at unresolved sites. Per-game behavior patches use **function overrides** (link-time alias
replacement) and **mid-ASM hooks**.

## 5. Recommended plan (phased)

**Phase 0 — Baseline (days).** Run the game in xenia-canary (Linux build, Vulkan). Whatever works
there — boot, audio, video, saves — delineates exactly what the ReXGlue runtime must reproduce.
Anything xenia can't do, your port inherits as a problem, so this is your risk map.

**Phase 1 — Analysis setup (days–a week or two).**
- Unpack the XEX to a plain PPC image/ELF (Xenia's tooling / xextool-class tools; ReXGlue and its
  `rexiso` companion also accept retail images directly — the Native-Ports launchers import raw
  ISOs/XEXs from users).
- Load in Ghidra with a Xenon-capable PPC module; lean on `.pdata` for boundaries; name the UE3
  runtime entry points (GObjects/GNames if present, allocators, main loop) to make override work
  tractable later.

**Phase 2 — Codegen bring-up (1–3 weeks of iteration, title-dependent).**
`rexglue init`, codegen, fix analysis validation errors: undiscovered functions (add boundaries),
jump tables, unresolved imports. Deliverable: a linked binary that reaches the runtime's first
host-call. Expect the wiki's warning to be accurate: this is the manual-labor phase.

**Phase 3 — Runtime bring-up (2–6 weeks).** VFS over `extracted/` (or the ISO directly), graphics
through the runtime's Vulkan backend, XMA→native mixer path, input mapping, threading (Xenia's
guest-thread model). Get the UE3 boot log rolling, then menus (Anark UI), then gameplay.

**Phase 4 — Polish.** Performance (the Native-Ports titles note over-speed when FPS caps are off —
UE3 ties logic to frame timing in places), save games, controller remaps, resolution scaling,
optional per-game native rewrites of hot paths via function overrides.

## 6. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| ReXGlue immaturity (v0.3.x, graphics/audio backends "in flux") | High | Medium | Nightly cadence is active; Xenia lineage means the heavy lifting exists; XenonRecomp as fallback; worst case you wait/contribute upstream |
| VMX128 / paired-singles codegen gaps (UE3 vector math) | Unknown–Medium | Medium | Extend the ~350-entry instruction dispatch (traps as `PPC_UNIMPLEMENTED`, not silent); Xenia's translations are the reference implementation |
| Custom middleware (Anark UI, `STOC` streams, `0xF00DCAFE` packages) | Certain | Low | Runtime passes bytes through; only matters if the guest code paths that parse them hit unimplemented host calls |
| 6-thread guest scheduling + UE3 thread affinity | Medium | Medium | Already solved territory in Xenia-derived runtimes and shipped ports |
| Too Human-specific xenia bugs carry over | Medium | Medium | Phase 0 identifies them early; function overrides let you patch around |
| Legal | — | — | Same posture as all recomp projects: you own the dump, ship no game content, machine-translated code only. Preservation/interoperability framing. Not legal advice. |

## 7. Effort summary

For someone comfortable with C++/CMake toolchains and RE basics, with ReXGlue doing the heavy
lifting: **roughly 1–3 months of part-time iteration** to a playable native Linux/Vulkan build,
mirroring the trajectory of the shipped Native-Ports titles (which report things like "24% native
console calls" for their most-polished disc port). The floor is much lower if your actual goal is
just *playing it on Linux* — xenia-canary gets you there today; the recomp is the project you choose
when you want native performance, moddability, or the engineering itself.

## Artifacts from this session

- `extracted/` — full 6.3 GB disc contents (28,027 files)
- `iso_listing.txt` — complete XDVDFS listing
- Tools built: `/tmp/extract-xiso/build/extract-xiso`
