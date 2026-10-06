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

### E9. Black screen — ROOT-CAUSE CHAIN IDENTIFIED (fix pending)
- **Symptom**: window opens fullscreen 3440×1440, presents, audio live, GPU
  executes real PM4 packets (pipelines built from the game's own VS/PS
  microcode), but display stays black. User confirmed visually.
- **Eliminated causes**:
  - Frame skipping: "Skipping Vulkan frame presentation due to async
    placeholder draw usage" → fixed with
    `--vulkan_async_skip_incomplete_frames=false` +
    `--async_shader_compilation=false` (skip warnings gone, presents proceed).
  - Guest stall on missing functions: zero unregistered-call logs.
  - Vblank/interrupts: `MarkVblank` ticks at refresh rate and dispatches the
    game's interrupt callback (`SetInterruptCallback(82746D20, 400F8980)`).
  - **Host presenting wrong thing**: instrumented the CP swap-packet handler
    (runtime patch #2, `patches/rexglue-runtime-patches.patch`): **the guest
    issues ZERO VdSwap calls** — every swapchain event seen was the host
    presenting its own placeholder frames. The black screen is "nothing was
    ever submitted", not "submitted but invisible".
- **Established root-cause chain** (debug log + gdb stack sampling):
  1. Boot proceeds ~1–3s: kernel init, UE3 RHI init, shader storage, pipeline
     creation — then ALL kernel/VFS/GPU logging stops for the rest of the run.
  2. gdb sampling (x25s, `kill -INT` on batch gdb; `perf` blocked by
     `perf_event_paranoid=4`, no root) shows exactly ONE guest thread running:
     `XThread…F6C0` spinning in guest call-chain
     `82A78630 → 8296CEA8 → 8296AA98 → 82989068 → 82746938 → 827462C8`
     (GPU-driver region — `82746D20` is the registered GPU interrupt callback;
     `827462C8` contains a poll loop reading a QWORD at `[r29]`).
  3. All ~15 other guest threads are parked in a handful of waits
     (`82A4BE68` ×many, `82EC66D8`, `82763E80`, `82A041B8`).
  4. Interpretation: a game thread polls a GPU-progress value (likely the ring
     buffer read pointer or a swap semaphore) that nothing ever updates; the
     frame loop never runs; VdSwap is never reached; everything else waits on
     the frame loop.
- **Note**: under gdb, the spinner shows SIGSEGV at its `REX_STORE_U32` — that
  is the runtime's page-protection write-tracking faulting by design; gdb just
  intercepts it before the runtime handler. Not a real crash (runs are clean
  outside gdb). Release build has no `ctx` symbols — use RelWithDebInfo for
  context inspection.
- **Session-2 deep dive — corrected + completed diagnosis** (all evidence via
  runtime instrumentation, see `patches/rexglue-runtime-patches.patch`):
  1. **gdb sampling caveat**: batch-gdb stops the process at the runtime's
     first guarded-page store (by-design SIGSEGV in memory tracking). Early
     "spinner thread" samples were frozen boot moments, not long-lived spins.
     Fix: `handle SIGSEGV nostop noprint pass` before `run`.
  2. **True 60s sample: ALL 17 guest threads blocked** in
     `rex::thread::PosixConditionBase::Wait/WaitMultiple` — no guest code
     running at all.
  3. **Wait/signal graph** (instrumented KeWait/NtWait/KeSetEvent): ~20 threads
     park on distinct kernel event handles (`0xf80000xx`, infinite timeout);
     only **2 SETEVENTs ever fire** — a thread 2 ↔ thread 14 handshake.
     **Thread 2 (main game thread) waits for TWO events
     (`WAITN 0x833328cc + 0x83332910`); thread 14 signals the first; nothing
     in the entire run ever signals `0x83332910`.** Two worker threads
     (18/19) poll on 30ms/0ms timeouts — the only live threads.
  4. **GPU interrupts fire correctly**: instrumented dispatch = 60/s at
     callback `0x82746D20` on the vsync thread. Yet no KeSetEvent from it —
     the interrupt handler runs but never signals the event the main thread
     needs.
  5. Read-pointer writeback IS implemented in the CP
     (`read_ptr_writeback_ptr_` written after each primary buffer execution).

- **Session-3 deep dive — the D3D driver boot handshake, fully traced**:
  Addressing convention note: `lis rN,-31949` ⇒ base `0x83330000`; events are
  `0x833328CC` (+10444), `0x833328F0` (+10480), `0x83332900` (+10496),
  `0x83332910` (+10512).
  1. **Guest stops feeding the GPU**: only 8 `UpdateWritePointer` calls ever —
     4 boot submissions (write idx 22→31) then the *same 4 values repeated*
     0.6s later (a second init attempt). Nothing afterwards. (Instrumented
     `CommandProcessor::UpdateWritePointer`.)
  2. **Vblank path works**: MMIO reg `0x7FC86544` (= dword 0x1951) is
     special-cased in `GraphicsSystem::ReadRegister` → returns 1 ("vblank");
     the guest vblank handler (`sub_82746D20`, source==0) sees bit0 set and
     calls its deferred-list worker (`sub_8274F528`) at 60Hz.
  3. **Sync design decoded** (generated code of `sub_82A04820` et al.):
     - main thread `sub_82A04820`: `KeSetEvent(0x833328F0)` (kick helper A),
       then `KeWaitForMultipleObjects(wait-all: 0x833328CC, 0x83332910)`.
     - helper A thread (start `0x82A041B8`): waits kick → works →
       `KeSetEvent(0x833328CC)` ✓ **observed working**.
     - helper B logic `sub_82A051C0`: would `KeSetEvent(0x83332910)` —
       **never executes** (verified: one-shot fprintf marker in generated
       code; zero hits in 25s stderr).
     - No thread ever waits on `0x83332900`; all 17 `ExCreateThread` calls
       succeed (start addrs logged); `sub_82A051C0` has **no static callers
       and no code references** — it is invoked only via a function pointer
       stored in guest DATA (the D3D driver's dispatch struct).
  4. **The source-1 (CP_INTERRUPT) path fires exactly once**: one
     `CP_INTERRUPT` PM4 packet in the whole run (from the boot init command
     buffer), `cpu_mask=0x4` → `DispatchInterruptCallback(1, cpu 2)` → guest
     handler source==1 path → `bctrl` to the driver's registered ISR at
     **`0x8274F628`** (verified via generated-code marker). The ISR runs once,
     does timing/queue bookkeeping, and the handshake to signal `0x83332910`
     never completes. (`sub_82A051C0` is *not* the ISR — it's a
     data-dispatched callback that should run via the ISR/deferred-list path.)
- **Conclusion (updated)**: the D3D driver's boot-time interrupt handshake —
  CP_INTERRUPT → ISR `0x8274F628` → (deferred callback `sub_82A051C0`) →
  `KeSetEvent(0x83332910)` → main thread proceeds — never completes. Only ONE
  CP_INTERRUPT arrives (from init). The stall is inside the emulated
  Xenos/D3D driver interaction, not codegen, not HLE coverage, not scheduling.
- **Xenia Canary comparison** (75s run from the same ISO on this machine,
  reference log: `docs/reference/xenia-canary-boot-75s.log`):
  - Under working xenia the game **also never calls VdSwap in the first 75s** —
    UE3 boot is simply slow; the guest keeps making progress (continuous
    `contents.zzz` streaming via DiscImageDevice, XamEnumerate etc.) the whole
    time, then exits cleanly on request ("Cheap-skate exit!" guest debug
    string — SK left debug prints in the binary).
  - Same guest thread names appear (XThreadE5FFD6C0 / E6FFE6C0 …) — identical
    thread set to our port.
  - **Reframe**: the port's bug is not "missed swaps" — nothing is supposed to
    swap this early. It is precisely the D3D-driver boot handshake stall
    (session-3 trace above). Once cleared, expect a slow streaming boot like
    xenia's, not instant menus.
- **Session-4 probes — ISR path resolved, registration gap isolated**:
  1. ISR `sub_8274F628` ran its increment path (passed queue-full/ms checks),
     then hit the callback dispatch: **`[drv+16540] == 0`** — skip-callback
     branch taken (verified with generated-code markers + slot-check print:
     `drv=400f8980 cb=00000000`).
  2. **drv is a HEAP struct (`0x400F8980`)** — the VdSetGraphicsInterruptCallback
     user_data — *not* the `0x8333xxxx` globals; the constant-based store sites
     (`sub_8312AFE8` → `0x833840AC`, never executes; `sub_82F52078` →
     `0x833440AC`, executes but different struct) are red herrings for this
     slot. Whoever registers `[0x400FBC94]` (+16540 on the heap struct) has not
     run by the time the single CP_INTERRUPT arrives.
  3. The single CP_INTERRUPT (cpu_mask=4) at boot may be normal-by-design
     (init-time, handler not yet registered = no-op). The abnormal part remains:
     **nothing ever signals `0x83332910`**, and its signaler `sub_82A051C0` is
     data-dispatched (no static callers) and never executes.
  4. Xenia comparison (see below) reframes the target: boot is supposed to be a
     slow streaming crawl; our port must simply survive the D3D boot handshake.
- **Session-5 probe — registration watcher (complete)**: added a 1Hz polled
  watcher in the vsync worker (`GraphicsSystem` vsync loop) for guest address
  `0x400FBC94` (`[0x400F8980+16540]`), plus a gdb hardware watchpoint on the
  host address (`0x1400fbc94`; guest arena maps identity at host
  `0x1_00000000`). Result across a 45–60s run: **the slot is never written —
  0x00000000 the entire time** (watcher + hardware watchpoint agree; gdb needs
  `handle SIGSEGV nostop noprint pass` due to the runtime's guarded-page
  faults). The D3D driver ISR callback registration never occurs.
  - Note: `GetPhysicalAddress(0x400FBC94)` returns unmapped — the
    `0x400xxxxx` region must be read via `TranslateVirtual` (physical-alias
    mapping).
  - Re-verified the wait semantics: main thread's
    `KeWaitForMultipleObjects(2, WaitAll, Timeout=NULL)` — truly infinite.
  - **Divergence quantified vs xenia**: 40s trace run — our port reads
    `contents.zzz` **0 times**; xenia's guest streams it continuously
    (UE3 boot). Our log tail is pure vblank dispatch (#2281 = 38s of 60Hz,
    all source=0). The D3D handshake stall is the sole blocker between us
    and a normal slow boot.
  - `--log_noisy` flag didn't produce import traces (flag parse or macro
    gating to revisit); REXKRNL_IMPORT_TRACE is wired to
    `REXCVAR_GET(log_noisy)` in `include/rex/logging/macros.h:25`.
  - Note: `sub_8312AFE8` (the never-run registration candidate) sits inside
    the import-thunk address region (0x8312Exxx = import thunks); treat
    "functions" there with suspicion — it may be a mis-analyzed import stub.
  - The registration code is not a constant-offset store in the generated code
    (all `+16540`/`-16540` constant sites target other structs or counters) —
    it must use a runtime-computed address, or live behind the same gate that
    parks the main thread.
- **Next steps (updated)**:
  1. Compare kernel-call traces: run xenia-canary verbose for the first ~30s
     and diff its F> kernel trace against our port's early boot — the missing
     call is likely the gate that unlocks D3D init (and eventually the
     registration).
  2. Investigate the stubbed `VdGetSystemCommandBuffer` (writes 0xBEEF0000/1
     markers) — if the guest dereferences those as pointers into its driver
     context, the ISR struct's registration field would never be reached.
  3. Examine `sub_8316E858`/`sub_8312AFE8` call chains (both data-dispatched)
     to find what schedule/queue they belong to.

- **Session-7 — WP write site found + structural reinterpretation**:
  1. **The CP_RB_WPTR write site is `sub_827460E0`**
     (generated `toohuman_recomp.21.cpp:10528`,
     `REX_MM_STORE_U32(ctx.r11.u32 + 1812, ctx.r29.u32)` — note the macro is
     `REX_MM_STORE_*`, not "PPC_MM_*"; 1812 = 0x714). The function is the
     D3D driver's command-buffer submit: iterates {ptr,count} pairs, copies
     into the ring, updates cursor [dev+10952], kicks WP, then pokes the
     notification struct [dev+21532]. It ran at boot (8 WP writes) and never
     again — the gate is upstream: **the driver's per-frame submit loop never
     starts**.
  2. **Guest-memory scan for ptr→`0x82A051C0`** found exactly two hits:
     `0x822d8ce0` (image data) and **`0x83332900`** — the "kick event" slot!
     Reinterpretation: the `0x833328xx/9xxx` globals are NOT plain events but
     **kernel-event + work-item records**: hexdump shows 16-byte records with
     "REX\0" tags and kernel handles (`0xF800013C`); `0x833328F0` reads
     `0x00000001` (dispatcher header, signaled) and `0x83332900` holds the
     callback pointer `0x82A051C0`. `sub_82A051C0`'s `r3 == 0x83332900` check
     is the handler matching its own work-item address.
  3. **`0x822D8CC0` is a static dispatch table** of {handler, param} pairs —
     8 entries (`82A04C38/82A04DB8/82A04F90/82A05078/82A051C0/82A05208/
     82A052E8/82A053F0` with heap params `0x4000xxxx`). Helper B is entry #4.
     Something must walk this table and dispatch (likely on the kick event).
  4. Dead ends closed: `VdCallGraphicsNotificationRoutines` is an identical
     stub in xenia; `VdRegisterGraphicsNotification` is never called by the
     game (only IoDismountVolumeByFileHandle fires as stub); the WP write
     never happens post-init because the submit loop never starts.
- **Next steps (updated)**:
  1. Find the walker of table `0x822D8CC0`: search generated code for
     `lis -32243` + loads at offsets 0x8CC0..0x8D00, or instrument the
     handler entries (marker in each of the 8) to see if ANY get dispatched.
  2. Check who wakes on event `0x833328F0` (helper A's thread waits on it —
     does the dispatcher share that wake?) and what pops `0x83332900`.
  3. Re-examine helper-B event signaling via `NtSetEvent` (instrumented now
     via the generic tracer) — the earlier "never signaled" used KeSetEvent
     only.

- **Session-8 — dispatcher identified, dispatch chain measured**:
  1. The dispatch walker is **`sub_82A049F0(table, id)`** (generated partition
     40): `clrlwi id`, skip if id==0, walk entries calling `handler(r3=table)`.
     Called from exactly 3 sites: main's `sub_82A04820` (AFTER the WaitAll —
     never runs), `sub_82A04280` (id=0 → no-op), and helper A's `sub_82A041B8`
     (id=1, `tbl=[thr+13584]`).
  2. **Measured dispatch trace** (60-call cap): `tbl=400a138c id=01` — always
     the driver context at `0x400A138C`, id 1, from helper A's thread. The
     static table `0x822D8CC0` is never dispatched (it is initial registration
     data, likely copied into per-context lists at init).
  3. Handler instrumentation across the 8 table entries: **4 dispatch**
     (`82A04C38`, `82A04DB8` with r3=0x400A138C; `82A052E8`, `82A053F0` with
     r3=0x7018F6D0 — a different context!). Helper B (`82A051C0`) and
     `82A05208`/`82A04F90`/`82A05078` never do. Helper B requires
     `r3 == 0x83332900` — its own work-item address — i.e. a dispatch with the
     work-item as "table", which **nothing ever performs**.
  4. Related find: `sub_8247BC50` does a test-and-set on bit0 of
     `[0x83382910]` (note: 0x8338 page — the *second* device's globals; the
     never-executed `sub_8312AFE8` writes `0x82243760` to `0x833840AC`). The
     0x8338 page (second device) is largely inert.
- **Next steps (updated)**:
  1. Decode helper A's full loop (`sub_82A041B8`, partition 70): after
     dispatching id=1 on the driver context, what does it wait on next, and
     does its loop ever process the `0x83332900` work item?
  2. Find any code calling *anything* with `r3=0x83332900`: scan generated
     code for `addi/lis` materializing 0x83332900 (constants `10512` with
     base `-31949`) near call/bctrl sites.
  3. Consider whether helper B's work item should have been queued by the
     driver during device init (check the second device's init path, 0x8338
     page, for writes to `0x83332900`).

- **Session-9 — helper A decoded; work item is static data; dispatch chain
  mapped to its roots**:
  1. **Helper A (`sub_82A041B8`) fully decoded** — its loop is:
     `KeWaitForSingleObject(0x833328F0 kick, infinite)` → bit-test `[ctx+300]`
     (work flag; main stores it before kicking) → if set: `sub_82A03800(ctx)`
     + `dispatcher(ctx, 1)` → `KeSetEvent(0x833328CC done)` → loop. It **never
     references `0x83332900`**; the loop exits (thread terminates) when
     `[ctx+300] == 0`. Helper A is healthy and unrelated to the work item.
  2. **The work item is STATIC XEX data**: gdb hardware watchpoint on the
     slot (`host 0x1833332900`; image arena maps at `+0x180000000`) never
     fired across a 40s run, yet the value is present — it ships in the
     image's data section. No runtime writer exists to find.
  3. **Dispatch chain mapped**: the queue processor is **`sub_82606DA0`**
     (partition 212): gates on `[r31+10500]` (enabled), `[r31+10496]` vs
     `[r31+10492]` (idx vs high-water), then `bctrl [[r31+0]+2004]` — the
     handler comes from `[device+2004]`. Sole caller: **`sub_826065E0`**, a
     switch on event ids 13–17 (storing `[+8440]`, poking `[+21532]`…),
     itself data-dispatched from `sub_82606D90` / `sub_8263B260` (no static
     callers — registered via guest data/vtables).
  - **Updated model**: the D3D driver registers a per-device handler
    (`[dev+2004]`) invoked by the id-13..17 event switch, which drains a
    command queue whose completion semantics signal `0x83332910` (via the
    helper-B-class handlers). In our port the switch never fires for the
    relevant id — the remaining question is what invokes
    `sub_82606D90`/`sub_8263B260` (vtable slot? kernel callback?) and why it
    stays silent while xenia's run drives it.
- **Next steps (updated)**:
  1. Print the host addresses of `sub_82606D90`/`sub_8263B260`'s registration
     sites: scan guest memory for pointers to them (same technique as the
     `82A051C0` scan) to find their vtables/callback registrations.
  2. Instrument `sub_82606DA0` and `sub_826065E0` entry markers to confirm
     they never execute in our run (expected) — then set gdb watchpoints on
     their registration sites to see if *registration* happens while
     *invocation* doesn't.
  3. Compare against xenia: the same vtable/registration scan on a xenia
     memory dump is not directly possible, but xenia's trace of the guest's
     MMIO/interrupt sequence for the same window (session-2 reference log)
     may show the trigger (e.g., a specific `Vd*` call or MMIO write) our
     port never performs.

- **Session-10 — registration-vs-invocation verified; kernel surface
  exonerated; E10 refocused as prime suspect**:
  1. **Registration scan** (guest-memory scan for both function pointers):
     - `sub_8263B260`: static image sites at `0x821F2478` and `0x822BA678`.
     - `sub_82606D90`: one heap hit at `0x401BFD00` — determined **volatile**
       (gdb watchpoint shows the slot being rewritten with timestamp-like
       values `0x687A5C43` → `0x68812B83`); false positive.
  2. **Invocation check**: execution markers in both functions — **neither is
     ever invoked** in a 30s run. Registration (static data) present,
     invocation absent — consistent with the whole-session picture.
  3. **Kernel-import diff vs xenia**: xenia's load-time import table dump
     (`docs/reference/xenia-canary-boot-75s.log`) shows the game imports
     **171 kernel functions; 17 unimplemented under xenia** (`__C_specific_
     handler`, `Io*ShareAccess/CompleteRequest/InvalidDeviceRequest`,
     `IoDismountVolume*`, `NetDll_XNetQosLookup`, `ObIsTitleObject`,
     `RtlCaptureContext`, `RtlUnwind`, `Stfs*Device`, `XamShow*UI`,
     `XeKeysConsoleSignatureVerification`). **Xenia works with those 17
     unimplemented → no missing kernel HLE call explains our divergence.**
     Our traced call set (~95 exports) is a subset consistent with xenia's
     early boot.
  - **CONCLUSION (session-10)**: the divergence is not at the kernel boundary
    at all. It is inside the emulated GPU/driver interaction. **Prime suspect
    returns to E10**: the boot-time `ExecutePacketType3 overflow (read count
    0xB0, packet count 0x10000)` skipped part of an init command buffer in an
    INDIRECT RINGBUFFER. If the skipped region contained the driver's
    ISR-callback registration or state-setup commands, everything downstream
    (vblank deferred dispatch, helper B, the WaitAll) never activates —
    exactly the observed behavior. Xenia processes the same buffer without
    overflow, which would explain the entire difference between the runs.
- **Next steps (updated)**:
  1. **Debug E10 in isolation**: in `ExecuteIndirectBuffer`, when the overflow
     fires, hexdump the failing packet region (ptr, read offset, the 8 dwords
     at the failure point) — identify the packet and why `count` reads as
     0x3FFF (max). Check whether the indirect buffer base/size from the
     submitting packet is being interpreted correctly (off-by-wrap?).
  2. Compare xenia's `ExecuteIndirectBuffer`/ring-wrap handling against
     ReXGlue's for the same packet sequence.
  3. If E10 skips driver-registration commands, fixing it may clear the ISR
     registration, the deferred dispatch, helper B, and the WaitAll in one
     move.

- **Session-12 — differential state dump (port side) + field analysis**:
  Added a t+6s state dump to the vsync watcher (`/tmp/our_state.bin`, regions:
  ISR struct `0x400F8980..0x400FF000`, dispatch ctx `0x400A1000..2000`,
  pages `0x83330000`/`0x83380000`). Note: the ISR fields extend to +21556 —
  the first dump range (0x3680 bytes) was too small; extended to 0x6680.
  Key state at t+6s (all values BE):
  - `[drv+16540]` ISR callback = **0** (unregistered — the whole-session
    blocker, now measured in-place).
  - `[drv+16548]` = **292 ≈ vblank count** → the driver ISR
    (`sub_8274F628`) runs EVERY vblank and increments its counter — vblank
    delivery and counting WORK; progress is not gated on vblank counting.
  - `[drv+16552]` = 0x1554B804 (timebase), `[drv+16556]` = 0x33 (last
    processed idx), `[drv+16564]`=1, `[drv+16568]`=1, `[drv+16704]` queue
    idx = **0** (deferred queue EMPTY), `[drv+21532]`=0, `[drv+21556]`=0x3C
    (60 — refresh rate).
  - `[drv+10900]` → `0xFF6A2000` (physical ptr); `[[10900]+16]` = 0 (the
    source==1 bctrl callback also unregistered), `[[10900]+4]` = 0.
  - dispatch ctx `0x400A138C`: `[ctx+300]`=0 (no work pending),
    `[ctx+304]`=1. page8333: `0x833328CC`=signaled, `0x83332910`=**0**
    (helper B event — the deadlock). page8338: `0x83382910`=1 (TAS flag
    set), `0x833840AC`=0 (second device's callback never registered,
    consistent with `sub_8312AFE8` never running).
  - **Model refinement**: the driver reaches "ISR ticking per vblank, queue
    empty, both device callbacks unregistered". The late-init stage that
    registers `[drv+16540]` / `[dev+2004]` never executes. xenia's identical
    guest must reach that stage — the gate is whatever input the late init
    awaits (a state set by earlier CP commands, a semaphore, or an event we
    under-signal).
- **Next steps (updated)**:
  1. Find the writer of `[drv+16540]`: it is a plain guest store — scan the
     generated code for stores where a base register is derived from
     `[0x822008BC]`-chain (the drv pointer chain) with offset 16540/0x40AC
     (include negative and SDA-style addressing).
  2. Identify what calls `sub_8312AFE8`-equivalent for THIS device (the
     0x8338-page twin `sub_8312AFE8` registers `0x82243760` for the other
     device — the same function may serve both via its drv argument).
  3. Cross-check in xenia: run xenia under gdb (AppImage extracted to
     `/tmp/xenia-extract/squashfs-root`; guest memory is on-demand-mapped,
     no flat base — read via /proc/pid/mem per page or xenia's own debugger)
     and dump the SAME fields at the equivalent boot point for comparison.
  4. **Static-search result (addendum)**: offset `16540` appears ONLY as
     `lfs` float READS (partitions 103–112, D3D helper cluster) and in the
     ISR's `lwz` — **no store to +16540 exists anywhere in the generated
     code**. The registration store comes from code that never executes in
     our run (or via a bulk SIMD copy from a source structure that itself is
     never populated). xenia extraction for its-side dumps:
     `/tmp/xenia-extract/squashfs-root/usr/bin/xenia_canary` (stripped; guest
     memory on-demand-mapped — no flat base).

- **Session-13 — live device struct dumps; submit path corrected; blocker
  precisely scoped**:
  1. **The device pointer MOVES between boots** (`0x400F8980` in some runs,
     `0x400F8A80` in others — heap allocation order varies with thread
     timing). All fixed-address state dumps before this were potentially
     reading stale/other allocations. The submit-path marker now dumps the
     live device struct (`/tmp/dev_struct.bin`, hit #3) and the ISR dumps
     its own struct (`/tmp/isr_struct_live.bin`).
  2. **Submit-path correction**: `[dev+21532]` (the "gate") only applies to
     **path A** (`[dev+10941]` bit30 SET). Our device has bit30 CLEAR
     (`[dev+10941]=0x00`), so submits take **path B** which bypasses the gate
     and reaches the WP write via `sub_82745F28` + the ring-write loop. The
     live dump confirms: cursor `[dev+10952]`=0x19, ring mask `[dev+14900]`=
     0x1FFF, `[dev+300]`=0x8274D720 / `[dev+304]`=0x8274D078 (function
     pointers). **Submits work.** (The earlier "gate cleared after init"
     theory is dead; the gate=0 readings from the fixed-address dump were
     artifacts.)
  3. **Blocker, final form**: the per-vblank driver callback
     **`[drv+16540]` = 0** after 35+ vblanks (ISR counter `[drv+16548]`=
     0x23 and climbing), and the queue-processor handler **`[dev+2004]`** is
     likewise unregistered. Both are driver-internal late-init registrations
     whose code never executes in our run. Everything else (vblank ticking,
     submits, ring processing, kernel surface) is verified healthy.
- **Session-14 — full dispatch-architecture decode; root cause stack refined
  one level deeper; first downstream progress**:
  1. **Event argument tracer** (`REX_EXPORT` wrapper, logs r3/r4 of first
     20000 KeSetEvent/KeWait*/KeReset* calls): in 75 s there are 200+
     `KeSetEvent(0x833328F0)` (main thread waking workers) and 200+
     `KeSetEvent(0x833328CC)` (workers signaling "free") — and **ZERO
     signals of the completion event 0x83332910**. Nobody ever signals it
     naturally.
  2. **Dispatcher fully decoded** (`sub_82A04330` init in recomp.121):
     - semaphore `KeInitializeSemaphore(0x833328DC, 0)`
     - work item at `0x83332900` = `{handler=0x82A051C0, ...}` (list node
       self-linked at init)
     - completion event at `0x83332910` (byte flag + refcount + list)
     - 6 worker threads via `ExCreateThread` running loop `sub_82A041B8`
       (and variant 0x82A04280): wait on 0x833328F0 → if `[ctx+300]!=0`
       exit; else run DPC processor `sub_82A03800` + dispatcher
       `sub_82A049F0(ctx,1)` (audio/voice work) → signal 0x833328CC → loop.
     - Main thread's flusher `sub_82A04820` (via tail-call wrapper
       `sub_82A0F4F0`, dispatched indirectly): sets `[ctx+300]=[r13+256]`,
       `KeSetEvent(0x833328F0)`, then
       `KeWaitForMultipleObjects(2, {0x833328CC, 0x83332910},
       wait_type=1)` and **loops until the result is 1** (i.e. wait-any
       picked the completion event).
     - Helper B `sub_82A051C0(0x83332900)` = the title-terminate
       notification registrar: calls `sub_82A05208` →
       `ExRegisterTitleTerminateNotification(0x83332900, create=0)` →
       zeroes `[0x83332900]` → `KeSetEvent(0x83332910)`.
     - On HW the item is dispatched BY A WORKER during the flush, before
       that worker signals 0x833328CC, so the flusher's blocking wait-any
       wakes on the completion event first (index 1) and proceeds.
  3. **Runtime wait semantics confirmed live** (`WAITM` logging in
     KeWaitForMultipleObjects_entry): 200/200 waits return
     `result=0` (index 0 = the always-signaled 0x833328CC) — the game
     polls forever. 803 other wait calls returned
     X_STATUS_INVALID_PARAMETER early (native-object lookup) — wait-any
     with transient object availability.
  4. **The completion event's KeSetEvent is a silent NO-OP**: the guest
     header at 0x83332910 has a garbage type byte (0xC0, low byte of the
     stored handler pointer), so `XObject::GetNativeObject` falls to
     `default: assert_always; return NULL` and `xeKeSetEvent` returns 0
     without signaling. **This is the direct reason the HLE injection
     (calling 0x82A051C0 from the vsync watcher, 6×) did not unblock the
     flusher.** Fix candidates: force-create the native object for
     0x83332910 as an auto-reset event, or have
     `KeSetEvent_entry` special-case it.
  5. **Worker-side injection (experiment)**: patched the generated worker
     loop (recomp.70.cpp, `sub_82A041B8`) to call
     `sub_82A051C0(0x83332900)` once, right before its own
     KeSetEvent(0x833328CC). Helper B executed (first time in any run),
     `sub_82A05208` dispatched — and the run then entered **new
     territory**: a tight `Unhandled guest access violation: read of
     guest 0x00000001` loop on a worker thread (handle 0xF80000C4),
     ~100 MB of log spam, title kept running. Next step: backtrace that
     fault (gdb `break xmemory.cpp:547` + `bt` — pending-breakpoint
     variant needed since the symbol lives in librexruntime.so), and
     force-create the 0x83332910 native event so its KeSetEvent actually
     lands. The flush protocol itself is now fully understood.
  5b. **Force-created native event + boot advance**: patched
     `KeSetEvent_entry` to force-create 0x83332910 as an auto-reset XEvent
     (`GetNativeObject<XEvent>(state, ptr, as_type=1)` overrides the
     garbage header type). With both injections active the boot now gets
     FURTHER than ever: after helper B runs and the completion event
     actually signals, the flusher's wait-any wakes with index 1 and the
     boot advances into previously unreached code — which currently
     faults in a tight loop (`Unhandled guest access violation: read of
     guest 0x00000001`, ~27k violations, game keeps running). This is the
     NEXT bug: backtrace the faulting guest PC (gdb breakpoint on
     `xmemory.cpp:547` never resolved via pending breakpoint — try
     breaking on the mangled `Memory::AccessViolationCallback` symbol
     after libs load, or add the guest LR/PC to the violation log line).
  6. Misc corrections: earlier "0x83332930" readings were hex/decimal
     conflations (10512 dec = 0x2910); the GPU-interrupt dispatch runs at
     ~58 Hz (dispatch #4321 in 75 s — earlier "4 prints" was a marker
     cap); the ISR doorbell MMIO write 0x7FC86110 is a display-flip
     fallback register (AVIVO D1GRPH_PRIMARY_SURFACE_ADDRESS), ignored
     by xenia too — not a blocker.

- **Session-15 — THE BOOT DEADLOCK IS BROKEN**:
  1. **Root cause of the guest-0x1 fault was my own injection bug**: the
     worker-loop injection called `sub_82A051C0(0x83332900)` right before
     the worker's `KeSetEvent(0x833328CC)` — but helper B clobbers r3/r4/r5
     (caller-saved in the PPC ABI), so every subsequent KeSetEvent received
     garbage r3 (=0x1) → `GetNativeObject` dereferenced guest 0x1 → the
     100 MB violation-spam loop. Fix: save/restore r3/r4/r5 around the
     injected call in recomp.70.cpp.
  2. **Diagnostics that got there**: unconditional `FAULT-MARK15` logging
     (guest lr + sp) adjacent to the "Unhandled" log line in
     `Memory::AccessViolationCallback` — `guest_lr=0x82A0426C` identified
     the worker-loop KeSetEvent call site immediately. (Earlier attempts
     failed: the conditional gdb breakpoint never fired under gdb due to
     timing differences, and an intermediate stack-walk diagnostic crashed
     the process by doing raw loads inside the signal handler. The
     FAULT-MARK15 lines only appeared in a rotated log file — grep the
     WHOLE logs dir, not just the latest file.)
  3. **Result — the flusher completed for the first time ever**: with the
     register fix + the force-created auto-reset event at 0x83332910, the
     flusher's wait-any returned **index 1** (8×, vs only index-0 spins in
     every previous run), the boot advanced past the flush, and new kernel
     activity appeared (XNotifyGetNext, NtReadFile, RtlUnicode/MultiByte
     conversions, XeCryptShaUpdate). Violation count dropped from ~100k to
     **zero**. GPU driver chain unchanged so far (6 boot submits, ISR cb
     slot still 0) — that stage comes next.
  4. Runtime side-fixes kept in the SDK: `KeSetEvent_entry` force-creates
     auto-reset natives for 0x833328CC and 0x83332910; FAULT-MARK15 diag;
     WAITM result logging; ARG tracer (Ke*Set/Wait/Reset, r3/r4, wait-list
     dump). Game side: worker-loop one-shot dispatch of helper B with
     register save/restore (recomp.70.cpp), vsync-thread HLE dispatch
     (6×, now redundant but harmless while [0x83332900]=0 after first run).
- **Session-15 addendum — 3-minute soak**: with the fix, a 180 s run shows
  the title's main loop alive (XNotifyGetNext polling, NtReadFile,
  crypto/string conversions), zero access violations, and the flush
  protocol completing every time it runs. The GPU driver stage is unchanged
  (6 boot submits; [drv+16540] still 0; no per-frame ring activity yet) —
  the title is past the dispatcher deadlock but the driver late-init (which
  registers the per-vblank callback) still has not executed; that is the
  next gate toward rendering.
- **Session-16 — RENDER PUMP UNLOCKED**:
  1. **vsync-thread HLE injection removed** (graphics_system.cpp) — the
     worker-side dispatch is now the only path, per plan.
  2. **5-minute soak (run 090, worker-only, one-shot dispatch)**: zero
     violations, GPU interrupts at 60 Hz (#17881), ISR running every
     vblank, flush protocol completes (8×) — but `[drv+16540]` still never
     registers and ring submissions stayed at 6. Steady state identified:
     driver worker threads 18/19 do timed waits (30 s) on 0x400FB67C /
     0x400FB6CC from lr=0x82763F14 (driver queue workers waiting for work
     that never arrives); main thread runs the flusher only occasionally
     (18 wake signals in 300 s).
  3. **Root cause of the stall found**: the flush protocol pumps ONE work
     item per cycle; the one-shot worker injection fed only the FIRST
     cycle — later cycles completed vacuously against the pre-signaled
     completion event (auto-reset event created with initial_state from
     the garbage header — nonzero), so all subsequent init work items were
     starved. **Fix: dispatch the work item on EVERY flush cycle**
     (recomp.70.cpp worker loop, register save/restore kept).
  4. **Result (run 091, 150 s)**: ring submissions went from 6 (all boot)
     to **50+ and counting** — the game's render pump is alive for the
     first time; the CP advances the write pointer (updates #1→22, #2→25)
     and processes the buffers. Zero violations. The known-benign E10
     indirect-buffer overflow appeared once at t+1s as before.
  5. **Still missing for a visible frame**: `[drv+16540]` per-vblank
     callback still unregistered (ISR slot-check cb=0), no XE_SWAP packet
     processed yet, VdSwap still only the boot one — presentation has not
     begun. Next: watch whether sustained rendering eventually registers
     the driver callback, or trace what the first EndScene/Present path
     waits on.
- **Session-16 addendum — 4-minute run 092**: steady state stable — zero
  violations, pump alive (submits ≥50, every-50th marker; same command
  buffer resubmitted — a loading-style loop), CP advancing, no XE_SWAP
  processed, VdSwap still boot-only, `[drv+16540]` still 0. The driver
  worker threads (18/19) keep doing 30 s timed waits on 0x400FB67C /
  0x400FB6CC (lr=0x82763F14). Conclusion of the gate analysis: nothing in
  the emitted code stores to +16540 (verified statically earlier), no
  write occurs at runtime in 5+ minutes (hardware watchpoint, session-13)
  — the registration must be a COMPUTED/indirect store (register-held
  offset, e.g. an init loop over callback slots) in code we have not
  identified, or a stage the title still has not reached. Next options:
  (a) find the init loop via stwx-pattern search in the driver init
  region; (b) HLE-register a stub into [drv+16540] once its expected
  behavior is inferred from the ISR call site (args: r3=&stack struct
  {flags, [drv+16564], computed, r8, r7}); (c) check whether the game's
  own Present path eventually runs once asset loading completes (pump
  currently resubmits one buffer — possibly waiting on streaming).- **Session-17 — [drv+16540] gate investigation; pipeline NOT wedged on
  coherence; drain path verified live**:
  1. **Static hunt for the +16540 writer exhausted**: enumerated all 699
     functions in the driver region (0x82740000–0x82770000) — 363 indexed
     (stwx) stores, none matching a small-data-fed callback-slot write;
     the only +16536/+16540 offset-family sites are the STATIC-instance
     creator (sub_828718E0, stores a data-section descriptor — not code),
     the ISR/counter accesses, and float (`lfs`) readers of a DIFFERENT
     struct view. No registration store exists in reachable code.
  2. **WAIT_REG_MEM instrumented** (`WRM` log): every wait in the submitted
     buffers polls `XE_GPU_REG_COHER_STATUS_HOST (0xA31)` for bit31 clear
     — and packets COMPLETE (24+ separate WRM packets processed, same
     buffer resubmitted by the game's loop). **The CP is not wedged**;
     MakeCoherent works. (A first fix attempt conflated 0xA31 with
     VGT_EVENT_INITIATOR — reverted, duplicate-case compile error exposed
     the identity.)
  3. **Queue-drain path verified live**: sub_8274F528 (the ISR's sibling,
     called from int-cb source==0 when MMIO 0x7FC86544 bit0 is set — our
     ReadRegister 0x1951 returns 1) runs at 60 Hz: increments the vblank
     counter [drv+16548], stamps [drv+16552], and DRAINS the ISR ring
     ([drv+16700] read idx → [drv+16704] write idx), dispatching CPU
     doorbells. The ISR→ring→drain chain works.
  4. **Remaining gate refined**: the app-side Present path never runs (no
     XE_SWAP, VdSwap boot-only, one buffer resubmitted — a loading loop).
     Whether that is gated on the never-registered [drv+16540] callback
     (registered by code that does not exist as an analyzable store — its
     value/behavior still unknown) or on unarmed driver queues
     ([dev+10500]=0) is the open question for the next session.
- **Session-17 addendum — loader is gated, not slow**: in run 092 all file
  I/O (46 opens, 40 reads, 23 writes) completes within the FIRST 0.5 s and
  then stops for the rest of the run; the title renders its loading loop
  for minutes with no further I/O. The loading pipeline is blocked, most
  plausibly circularly: loader → driver queues → queue arming
  (`[dev+10500]`, still 0) → driver late-init. **Best next lead**: the
  `[dev+10500]` writers ARE identifiable statically (recomp.52:7921,
  141:30569, 175:7589, 61:35780 store it; sub_82606DA0's reset path clears
  it) — determine which writer targets the heap device (0x400F8980), why
  it never runs, and what gates it. This is more tractable than the
  +16540 hunt because the writers exist as analyzable code.- **Session-18 — the [dev+10500] gate decoded end-to-end; the missing
  stimulus is a HARDWARE payload injection**:
  1. **Writer identification**: of the four [dev+10500] writers,
     `sub_826065E0` (175.cpp:7589) is the arming path — it is the DRIVER
     EVENT SWITCH: on event ids 13–17 it stores r28 into [dev+10500], sets
     [dev+10496], and calls the queue processor (sub_82606DA0).
     sub_83122F68 only arms the STATIC instance (0x8338 base) with a
     data-section descriptor; sub_825D6F08 is a struct copy.
  2. **Dispatch chain**: the switch is called by `sub_82606D90` — a pure
     THUNK: `r4 = event block; event_id = [r4+8]; tail-call switch(r3, id)`
     — and by `sub_8263B260`. Both are indirect-dispatch handlers
     registered in a heap table (runtime scan found ptr->82606D90 at
     0x401BFD00). Marker-verified: the switch NEVER fires.
  3. **The interrupt payload block is hardware-filled**:
     [drv+10900] = **0xFF6A2000** — a hardware block (the ISR vector is
     programmed there by the guest: [sec+16]=0x8274F628). On HW the
     interrupt controller writes the EVENT BLOCK pointer into [sec+20]
     when raising the interrupt; the ISR reads it as r3 and dispatches
     via the callback with r4=payload. In our runtime [sec+20] is always
     0 → payload=0 → the ISR runs with a null payload and nothing ever
     dispatches driver events. (Also fixed two diagnostic crashes I
     introduced: unguarded TranslateVirtual reads of [sec+20]/
     payload with 0 bases wedged the vsync thread in a fault loop —
     run 095; guards + retry-until-nonzero added.)
  4. **Next concrete step**: emulate the payload injection — on each
     graphics interrupt dispatch (DispatchInterruptCallback), write a
     small event block (guest-allocated by the runtime) containing the
     appropriate event id at +8 into [sec+20] (guest 0xFF6A2014) BEFORE
     invoking the callback chain, with ids from the 13–17 range the
     switch handles; then verify sub_82606D90/826065E0 fire, [dev+10500]
     arms, and the loader unblocks. NOTE: the ISR passes r3=&stack-ctx
     (not drv) into the callback — the switch stores [r3+10500]; if the
     stack-ctx form corrupts state, dispatch sub_826065E0 directly with
     r3=drv from the runtime instead of going through the guest thunk.
- **Session-19 — payload injection implemented; event switch FIRES; the
  real root cause surfaces: the heap device's constructor never ran**:
  1. Implemented the payload injection (runtime allocates a 16-byte guest
     event block via SystemHeapAlloc, writes its pointer to 0xFF6A2014
     with the event id at +8, cycled/13 by default, every vblank before
     the interrupt dispatch). Injection verified live (block=0x300A2000).
  2. The ISR still couldn't dispatch (its own [drv+16540] callback slot is
     empty), so the runtime now dispatches the event switch DIRECTLY after
     each interrupt: `ExecuteInterrupt(0x826065E0, {dev, id})` with
     dev read from the guest's own global `[[0x820008BC]]` (the
     executable↔.so shared-global trick failed — drv=0 in the .so's view;
     the guest global chain is authoritative). **The switch now fires with
     the correct device (EVSWITCH r3=400f8980 r4=13).**
  3. The id-13 case then faults reading guest 0x5B3 — and reading the case
     body shows why: it dereferences `[[dev+0]+1460]` — a VTABLE. Our live
     dump (session-13) showed `[dev+0..24] = 0xFFFFFFFF`: **the heap
     device object's CONSTRUCTOR never ran**. Everything else (fields,
     ISR registration, worker threads) was initialized field-by-field by
     later code, but the ctor that stores the vtable at [dev+0] never
     executed — which breaks every virtual-method path through the device
     and is almost certainly the true root cause behind ALL the missing
     late-init (per-vblank callback registration, queue arming).
  4. Fix candidates (next session): (a) find [static_drv+0] (the
     constructed static instance at 0x83380000) and HLE-copy its vtable
     pointer into [heap_dev+0]; (b) find the device constructor in the
     code (the function storing a data-section vtable into [r3+0] whose
     callers include the device-creation path) and work out why it's
     skipped — possibly the allocation path bypassed the ctor (malloc
     without placement-new pattern in the analyzer's view).
- **Session-19 addendum — vtable HLE experiment (run 102)**: copying
  [0x83380000] (static instance [+0]) into [heap_dev+0] did NOT trigger —
  the static instance's first word is NOT a code-range vtable (the static
  instance is also uninitialized, or its layout differs). Violations
  dropped 30k → 451 with the injection + direct dispatch active. The
  correct vtable must come from the device constructor path: next session
  should find the ctor (search for stores of a data-section constant into
  [r3+0] early in a function whose callers allocate the ~21KB device, or
  capture the true vtable via a guest-side dump from xenia) and either
  HLE-write it at the right moment or un-block the constructor's call
  path.- **Session-20 — vtable hunt progress**:
  1. Driver-region ctor scan (lis-built data constant → [reg+0] stores):
     123 KB of hits saved to
     `~/.zcode/cli/exec/sess_997d39e6-2f55-4996-95aa-a0d4b05e160e/call_c921abe210a34d73ac48ab2f-stdout.log`
     (e.g. sub_827613B0/sub_8276EB48/sub_82768098 — large factory/init
     functions with many object constructions). Too generic to eyeball;
     needs pairing with the ~21 KB allocation site.
  2. Embedded-table hypothesis TESTED AND REFUTED: the device object DOES
     embed 184 code-range method pointers at [dev+296..+2100]
     ([dev+296]=0x8274D6E8, +300=0x8274D720, ...), but the entry the
     switch needs ([table+1460] with table=dev+296 → [dev+1756]) is 0 —
     so [dev+0] must point at a STATIC data-section vtable, written by
     the ctor that never ran.
  3. Fastest remaining path: boot the title under xenia (binary at
     /tmp/xenia-extract/squashfs-root/usr/bin/xenia_canary), dump guest
     memory at the heap device ([dev+0..8]) to capture the true vtable
     value V, verify [V+1460] is code, then HLE-write V into [dev+0]
     after device creation in our runtime and re-test the event switch.
     Alternative: pair each ctor-scan hit with the allocator call site
     (sub_82A4C650 family, ~21 KB size immediate) to identify THE device
     ctor directly.- **Session-20 addendum — xenia capture prepared (Yama workaround)**:
  xenia launched fine (PID visible, storage root ~/.local/share/Xenia) but
  /proc/PID/mem reads are blocked by ptrace_scope=4 for non-children.
  Working approach prepared and scripted: launch xenia UNDER gdb
  (`/tmp/xenia_capture.sh` → gdb batch runs the title, external SIGINT at
  t+75s stops the inferior, then gdb `find /w` locates the device's
  embedded method-table signature
  {8274D6E8, 8274D720, 8274D078, 8274D098} across the large mappings
  logged in this session (guest mappings include 0x100010000–0x170000000
  ≈1.75GB and 0x190000000–0x220000000); filter hits to the heap range,
  dev=hit−296, read [dev+0] → true vtable V, verify [V+1460] holds code,
  then HLE-write V into [dev+0] post-creation and re-test.- **Session-20 addendum 2 — first xenia find attempt negative**: the
  gdb+SIGINT capture ran (xenia booted, SIGINT at t+75s stopped it, find
  executed over all three mapping ranges) but reported "Pattern not
  found" — either the device's method table is written later than t+75s
  under xenia, or xenia's guest-heap mapping was outside the searched
  ranges in that launch. Next attempt: SIGINT later (t+120s), and/or
  first verify under xenia the title reaches the device-creation stage by
  grepping xenia's log for the boot markers from
  docs/reference/xenia-canary-boot-75s.log. Scripts remain at
  /tmp/xenia_capture.sh + /tmp/xenia_capture.gdb (edit the sleep and
  ranges there).- **Session-20 addendum 3 — capture pipeline fixed; definitive negative:
  xenia's title also lacks the device at t+120s**: the earlier "Pattern
  not found" runs were invalid — gdb was stopping the inferior at the
  FIRST SIG35 real-time event (xenia thread signaling), seconds into
  boot. With SIG33–SIG38 handled (nostop/noprint/pass), the inferior now
  runs the full 120 s before the stop, and the mapping-aware find sweeps
  every large region cleanly (no exceptions, all ranges searched). The
  signature is still absent in xenia's memory. Interpretation: under
  xenia the title has not created the D3D device by t+120 s — device
  creation happens later there (menus/profile gating), while in our port
  the flush-injection path drove early creation through partially-
  initialized code paths. This reframes the whole late-init mystery: the
  device object we are patching may be a PRE-CONSTRUCTION allocation in a
  healthy environment, and our injected dispatch may be racing the title's
  own init order. Next session should verify WHERE xenia's boot stalls
  (log comparison, guest call tracing via xenia's own logging) before any
  further HLE writes.- **Session-21 — complete data-section scan: the missing vtable is from
  an UNKNOWN interface**:
  1. Dumped the guest data sections from the live runtime
     (/tmp/guest_data.bin, first 0x82000000+4MB then 0x83000000+8MB — the
     full data coverage) and scanned offline for static tables containing
     the device's method pointers. Result: **no static table anywhere
     contains 0x8274D720** (or any long code-pointer run matching the
     embedded table). Only two long code-word runs exist in the post-text
     region (0x831977AC, 16962 words — a jump/dispatch table; and an
     88-word run) — neither related.
  2. Conclusion: the vtable the event switch needs ([[dev+0]+1460])
     belongs to a DIFFERENT interface than the embedded method table —
     its entries are methods we have not identified, written by the
     never-run constructor. Empirical candidates: the ctor-scan hits
     (persisted 123 KB log, lis bases 0x820C/0x8215/0x821E/0x8222/0x8225–
     0x8228) — filterable offline by requiring [V+1460] to be code
     (computable from /tmp/guest_data.bin for bases in the first dump).
  3. Boot-order verification under xenia (capture retries) established
     that xenia's title also lacks the device at t+120 s — so no vtable
     capture is possible there without progressing xenia's own boot
     further (profile/menu gating).
- **Next steps (final for this phase)**:- **Next steps (final for this phase)**:
  1. Identify the registration writer for `[drv+16540]`/`[dev+2004]`: bulk
     copy (SIMD memcpy from a template — instrument `sub_82A45878` when its
     destination is inside the device struct), or a never-reached init
     branch. A gdb watchpoint on the LIVE host address (`base + dev`, dev
     captured from the submit marker's stderr line) catches the writer if
     one ever runs.
  2. If no writer exists in our run: diff the same struct against xenia at
     the equivalent point (xenia binary extracted at
     `/tmp/xenia-extract/squashfs-root`; guest memory on-demand-mapped — use
     gdb `find` over its writable mappings for the device struct pattern,
     e.g. the `{0x8274D720, 0x8274D078}` function-pointer pair) to see the
     registered values xenia's run achieves.
  3. Consider HLE workaround: registering a minimal `[drv+16540]` handler
     ourselves (via a runtime patch that populates it after
     `VdSetGraphicsInterruptCallback`) to emulate the missing late-init —
     riskier, but could unblock the pipeline for experimentation.

- **Session-11 — E10 decoded and EXONERATED (red herring)**: instrumented
  `ExecuteIndirectBuffer` with a failure-region dump (in `patches/`). Result:
  - Failing indirect buffer: base `0x1F470000`, 64 words, read offset `0x50`
    at failure, capacity `0x100`.
  - The failing packet is the dword at `+0x4C`: **`0xFFFFFFFF`** — read as a
    type-3 header it yields count `0x4000` words ("packet count 0x10000")
    against `0xB0` available — the exact overflow values. It is filler after
    ~19 words of valid commands (type-0 writes incl. `RB_BC_CONTROL=0x200E`,
    a type-3 indirect-buffer-priv header, scratch-register traffic).
  - Behavior comparison: xenia's `ExecutePacket`/`ExecuteIndirectBuffer` are
    equivalent (`packet==0` skip, overflow → fail → break; `assert_always` is
    a no-op in release). **Both engines skip this packet identically** — E10
    is either filler the CP never was meant to execute or an intentional
    error-handling probe by the driver. It is NOT the root cause; the
    session-10 refocusing on E10 was wrong.
  - Diagnostic left in place (fires once per boot); candidate for removal.
- **Where this leaves the hunt**: with the kernel boundary (session-10) and
  the CP packet stream (E10) both exonerated, the remaining divergence is in
  guest-internal driver state reached only through *timing- or GPU-side-event
  dependent* paths — i.e., something our runtime state doesn't match xenia's
  by the time the driver finishes init. Candidate techniques for the next
  session, in order of expected yield:
  1. **Differential memory snapshot**: dump the driver context regions
     (`0x400F8980` struct, `0x8333`/`0x8338` pages) from our port at t+5s;
     run xenia with a memory-dump capability (or gdb) at the equivalent point
     and diff the driver state — the first differing field is the stalled
     state machine.
  2. **Vblank-count dependence**: check whether any driver progress is
     gated on the vblank COUNT (e.g., "after N vblanks, advance init state")
     — our vblank counter behavior may differ (xenia increments a guest-
     visible counter per vblank; verify ours matches location + rate).
  3. **XamUI/XMP thread review**: the single VdSwap came from XAM; check
     whether XAM's device (0x8338 page) completion is what unblocks the
     game's device — i.e., trace what XAM does after its present in xenia's
     run (thread states over time) vs ours.

- **Session-6 — generic kernel-call tracer + MAJOR CORRECTION**:
  - Added a generic tracer to `REX_EXPORT` in `include/rex/hook.h`: every
    kernel export now logs its first 40 invocations ("[port-diag] CALL
    __imp__<Name> (n)"). Necessary because **kernel imports are direct host
    calls** (`__imp__X` symbols in the generated code) and never pass through
    `FunctionDispatcher::Execute` — the earlier "guest issues ZERO VdSwap
    calls" conclusion was an **instrumentation artifact** (the CP-side
    swap-packet handler can't see kernel-entry calls).
  - Corrected picture from a 45s run (1930 traced calls, ~95 distinct exports):
    - **`VdSwap` IS called — exactly once**, 0.6s after a *double* D3D init
      (VdInitializeRingBuffer ×2, VdEnableRingBufferRPtrWriteBack ×2 — the
      device was created twice, matching the doubled boot WP writes).
    - `VdCallGraphicsNotificationRoutines` called once between the inits.
    - After VdSwap(1): zero ring submissions, zero WP register writes, zero
      MMIO writes of any kind ("Unknown GPU register" warnings: 0) — the
      guest driver never submits another buffer.
    - 34 exports hit the 40-call cap (XeCryptShaUpdate, XNotifyGetNext,
      XAudio*, Rtl*CriticalSection, NtWait*, Ke*SpinLock…); the trace tail is
      pure `NtWaitForMultipleObjectsEx` (the park).
  - Xenia's reference `VdSwap` is behaviorally identical (fills packet, no WP
    update) and its `VdGetSystemCommandBuffer` has the same 0xBEEF stub — so
    the WP advance after VdSwap must come from the guest driver (MMIO
    `0x7FC80714` = CP_RB_WPTR) in xenia's working run too.
  - **Current blocker, restated**: the guest driver completes init (2 device
    creations, 8 WP writes, 1 CP_INTERRUPT, 1 VdSwap) but never enters its
    per-frame submission loop. The gate between "init done" and "frame
    submissions begin" is the next target — likely the swap-completion or
    deferred-callback event for the single XAM present.
  - Tracer location: `include/rex/hook.h` REX_EXPORT (in patches/).

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

## Session 2 — 2026-10-04 (diagnostics deep-dive, repo setup)

- Created this DEVLOG; exported the two runtime patches from the volatile
  `/tmp/rexglue-sdk` checkout to `patches/rexglue-runtime-patches.patch`
  (#1: discovery trap logs instead of aborting; #2: per-2s VdSwap rate
  diagnostic in the CP swap-packet handler).
- Instrumented VdSwap rate → discovered the guest never swaps (E9).
- gdb stack-sampling methodology that works without root: run the game under
  `gdb -batch -ex run -ex "thread apply all bt 15"`, `kill -INT <gdb pid>`
  from the shell after N seconds; gdb prints all stacks and exits. Sampled
  twice + once with `info args` (Release build → no `ctx` symbol; use
  RelWithDebInfo next time).
- Set up this git repo (main branch), pushed to
  `github.com/thextictac/Too-Human-Recomp`. Remote had a README stub —
  integrated via `git pull --rebase --allow-unrelated-histories`.

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
