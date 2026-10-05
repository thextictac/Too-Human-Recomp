# Too Human Port — Development Log

Detailed chronological record of every error encountered, root cause, and fix.
Companion to [PORT.md](PORT.md) (current status + run instructions).

Format per entry: **SYMPTOM → ROOT CAUSE → FIX → EVIDENCE/PREVENTION**

---

## Session 1 — 2026-10-04 (disc analysis → toolchain → running binary)

### E1. `rexglue init`: "Entrypoint XEX not found: .../port/../extracted/default.xex"
- **Symptom**: init failed although `Default.xex` existed at the given path.
- **Root cause**: the on-disc file is `Default.xex` (mixed case); `rexglue init`
  lowercases the recorded manifest path (`default.xex`). ReXGlue normalizes Xbox
  guest paths to lowercase (fine for the console's case-insensitive FS) but the
  Linux host FS is case-sensitive, so codegen's file lookup missed.
- **Fix**: `mv extracted/Default.xex extracted/default.xex`.
- **Prevention**: keep all game-side filenames lowercase in `extracted/` (the
  disc is otherwise all-lowercase already; this was the only mixed-case file).

### E2. Project preset fails: "clang-20 ... not found in PATH"
- **Symptom**: `cmake --preset linux-amd64-release` in the generated port
  project failed to find the compiler.
- **Root cause**: the `rexglue init` template pins `clang-20`/`clang++-20`;
  host had no system clang at all (Ubuntu 26.04, no sudo) — we installed
  LLVM 23.1.2 under `/tmp/llvm-root/LLVM-23.1.2-Linux-X64`.
- **Fix**: created version-name symlinks in `/tmp/llvm-shim/`
  (`clang-20 → clang`, `clang++-20 → clang++`, `lld-20`, `lld-link-20`) and
  prepend `/tmp/llvm-shim` to PATH for all project builds.
- **Prevention**: keep the shim dir; or edit the generated `CMakePresets.json`.

### E3. Codegen analysis: 11 × `UnresolvedCall` (validation failed)
- **Symptom**: `Validate` phase failed: "11 unresolved calls … target not in
  any function", e.g. `b 0x82549E98 from 0x823E54C0`.
- **Root cause**: tail-call targets (`b` at function end) whose addresses were
  never seeded as functions — discovery only finds functions reachable from
  entries/`.pdata`/vtables; these were only referenced by raw branch.
- **Fix**: registered all 11 as `[entrypoint.functions."0x…"]` entries in
  `toohuman_manifest.toml` (empty tables = infer boundaries):
  `0x82549E98, 0x82628208, 0x8236D678, 0x825292D0, 0x825BA3C0, 0x826354E0,
  0x8251A2C8, 0x8251DF28, 0x825AABB0, 0x82A089E0, 0x82360288`.
- **Result**: analysis validated; codegen wrote 479 files in 165s.

### E4. Codegen warnings (non-fatal, logged for the record)
- `Function 0x8237BD08 is 1184677 bytes` and `Function 0x8315D708 is 1358333
  bytes` exceed `max_file_size_bytes` — over-merged gap-fill regions. Candidate
  future source of subtle glitches; fix via `[functions]` boundary hints if
  in-game symptoms appear.
- `Unexpected float16_4 pack instruction at 82997BD4` — VMX128-adjacent vector
  op; emitted non-fatally. Watch for bad math in that area.

### E5. Link failure: `undefined reference to PPCImageConfig`
- **Symptom**: `toohuman` link failed after the first `--target toohuman`
  build; only 3 app objects were linked, none of the 479 generated ones.
- **Root cause**: chicken-and-egg — CMake configure ran *before* codegen
  produced `generated/default/sources.cmake`, so the `toohuman_recomp` OBJECT
  library was empty. The generated `generated/rexglue.cmake` only picks up the
  source list at configure time.
- **Fix**: re-run `cmake --preset linux-amd64-release` after any codegen that
  creates/removes partition files, then build.
- **Prevention**: after `toohuman_codegen` changes the partition count,
  reconfigure. (Codegen that only rewrites existing files doesn't need it.)

### E6. Compile error: `use of undeclared label 'loc_82EF0764'`
- **Symptom**: `toohuman_recomp.28.cpp:30180` — branch to a label emitted in a
  different translation unit (`toohuman_recomp.158.cpp`).
- **Root cause**: shared-tail code block with two entry points
  (`sub_82EF06BC` at 28.cpp, `sub_82EF071C` at 158.cpp — overlapping ranges).
  A conditional `beq` in the 06BC copy targeted `0x82EF0764`, an interior
  address that only *071C's* body contained → generator emitted a local
  `goto` label that didn't exist in that file.
- **Fix**: carve the second function so the target address becomes a function
  entry (cross-function branches are emitted as calls, which link across TUs):
  ```toml
  [entrypoint.functions."0x82EF071C"]
  end = 0x82EF0764
  [entrypoint.functions."0x82EF0764"]
  ```
  Semantics stay correct: the continuation returns via the caller's saved `lr`.
- **Result**: both sites now emit `sub_82EF0764(ctx, base)` transitions.

### E7. Runtime fatal: "Call to invalid or unregistered function at 0x82A027C0"
- **Symptom**: guest aborted (SIGABRT) ~1s after audio endpoint init, during
  UE3 boot (configs + `Core.int` read OK before death).
- **Root cause**: runtime `function_dispatcher.cpp` resolves indirect calls
  through the registry of *discovered* functions; any guest function reachable
  ONLY via a function pointer stored in data (vtable slot, callback
  registration) is missing if analysis never seeded it. Trap was `REX_FATAL`.
- **Fix (two parts)**:
  1. Patched `src/system/function_dispatcher.cpp` `InvalidFunctionTrap` to log
     `[port-discovery] unregistered function call: 0x…` (once per address) and
     return, instead of aborting. Rebuilt SDK (`cmake --build … --target
     install`, ~1 min incremental). **Revert to REX_FATAL for release.**
  2. Each run then revealed the next missing targets; added over 4 rounds:
     - R1: `0x82A027C0` (audio init path)
     - R2: `0x823E7368` (boot path)
     - R3: `0x827C9558, 0x828CD340, 0x82A0B928, 0x82A22018` (batch from first
       patched run)
     - R4: `0x82B71E18` (UE3 shader backend path, right after
       `VFS: 'ShaderDumpxe:\CompareBackEnds' → [no device]`)
- **Result**: zero fatals, zero new discoveries in final runs. Total manual
  function registrations: 11 (E3) + 1 (E6) + 7 (E7) = 19.

### E8. GPU plugin "not found at …/librexgpu-x"
- **Symptom**: `--gpu_plugin xenos` → "GPU plugin 'xenos' not found" and app
  exited.
- **Root cause**: loader resolves bare names relative to the *app directory*;
  the plugin was only in the SDK install prefix.
- **Fix**: `ln -sf /tmp/rexglue-sdk/out/install/linux-amd64/lib/librexgpu-xenos.so .`
  next to the `toohuman` binary.
- **Result**: Vulkan initializes; RTX 4080 selected (llvmpipe also present as
  device 1 — use `--vulkan_device 0` if selection ever goes wrong).

### E9. Black screen (OPEN)
- **Symptom**: window opens fullscreen 3440×1440, presents, audio live, GPU
  executes real PM4 packets (pipelines built from the game's own VS/PS
  microcode), but display stays black. User confirmed visually.
- **Eliminated causes**:
  - Frame skipping: was "Skipping Vulkan frame presentation due to async
    placeholder draw usage" → fixed with
    `--vulkan_async_skip_incomplete_frames=false` +
    `--async_shader_compilation=false` (skip warnings gone, presents proceed).
  - Guest stall on missing functions: zero unregistered-call logs.
  - Vblank/interrupts: `MarkVblank` ticks at refresh rate and dispatches the
    game's interrupt callback (`SetInterruptCallback(82746D20, 400F8980)`).
- **Remaining suspects**:
  1. Guest parked in logo-movie phase: WMVs exist on disc, but no
     `XamMovie*`/XMedia kernel calls appear — the game may be waiting on
     something *before* issuing them, or uses an unimplemented decode path.
  2. PM4 ring-buffer overflow (E10) corrupting early frame setup.
  3. Resolve→frontbuffer path not producing what VdSwap presents.
- **Next diagnostic**: `--log-level debug` run; inspect what guest threads
  block on during the quiet minutes after boot.

### E10. `ExecutePacketType3 overflow (read count 000000B0, packet count 00010000)` (OPEN, once per boot)
- **Symptom**: one failed PM4 packet right as the game first touches the
  ring buffer (19:41:50.629, immediately after `ShaderDumpxe` VFS probe).
  Non-recurring afterwards; game continues.
- **Root cause**: not yet diagnosed — `read count 0xB0` (176 dwords requested)
  vs `packet count 0x10000` suggests a read-pointer/wrap edge on the primary
  ring (or the game writing a packet the disassembler sizes differently).
- **Impact if unfixed**: could zero out early render state; prime black-screen
  suspect #2.

### E11. Benign stubs/warnings (no action needed yet)
- `IoDismountVolumeByFileHandle(0x…) - stub` ×2 per boot — harmless.
- `SDL GameControllerDB: file 'gamecontrollerdb.txt' does not exist` — fixed by
  dropping [gamecontrollerdb.txt](port/out/build/linux-amd64-release/gamecontrollerdb.txt)
  (488 mappings) next to the binary. Input untested in-game.
- `VulkanTextureCache: k_Cr_Y1_Cb_Y0_REP … fallback format` — informational.
- `VulkanPresenter: Presentation … dropped as … outdated` at mode switches —
  informational (720p window → fullscreen resize).

---

## Environment notes (volatile!)

- SDK source/build/install: `/tmp/rexglue-sdk` — **wiped on reboot**. Move to a
  persistent path if keeping long-term. The `InvalidFunctionTrap` patch (E7)
  lives only in this checkout.
- LLVM 23.1.2: `/tmp/llvm-root/LLVM-23.1.2-Linux-X64`, shims `/tmp/llvm-shim`.
- Runtime logs land in `port/out/build/linux-amd64-release/logs/toohuman_NNN.log`
  (auto-numbered). Stdout only shows the SDL line.

## Open questions for gameplay progress

1. What does the guest block on after engine init? (debug log run)
2. Is the logo movie path ever reached? (grep logs for XMedia/XamMovie/XMV)
3. Does the PM4 overflow (E10) eat the first frame's state? (packet trace)
4. Are the over-merged 1MB+ functions (E4) on the boot/render path?
