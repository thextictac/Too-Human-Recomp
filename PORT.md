# Too Human — Native Linux Port (ReXGlue static recompilation)

Status: **decompiled, recompiled, and running natively** — Vulkan window + audio live.
Rendering shows a black screen at the logo/movie stage; see Known issues.

## How to run

```bash
cd "/home/nick/Desktop/Coding/Roms/Too Human/port/out/build/linux-amd64-release"
export LD_LIBRARY_PATH=/tmp/rexglue-sdk/out/install/linux-amd64/lib
./toohuman \
  --game_data_root "/home/nick/Desktop/Coding/Roms/Too Human/extracted" \
  --user_data_root "/home/nick/Desktop/Coding/Roms/Too Human/port/userdata" \
  --gpu_plugin xenos \
  --vulkan_async_skip_incomplete_frames=false \
  --async_shader_compilation=false
```

A window opens (goes fullscreen at 3440x1440), audio outputs through the system
endpoint (6ch/48kHz), and the game's Xenos command stream executes on Vulkan.

## What was done (2026-10-04)

1. Extracted the XGD2 ISO with `extract-xiso` → `../extracted/` (28,027 files).
2. Built the ReXGlue SDK (commit of 2026-10-04, v0.10.0.0-dev) with Clang 23
   (`/tmp/llvm-root/LLVM-23.1.2-Linux-X64`), Vulkan backend, installed to
   `/tmp/rexglue-sdk/out/install/linux-amd64`.
3. `rexglue init` → `port/` project pointing at `../extracted/default.xex`
   (retail XEX2, Title 4D5307DE, built 2008-07-22). The SDK decrypts retail
   XEXs internally — no manual unpacking needed.
4. Analysis pass 1 found 11 unresolved tail-call targets → registered as
   functions in `port/toohuman_manifest.toml`.
5. One codegen bug fixed by carving a shared-tail block
   (`0x82EF071C` end=`0x82EF0764`, continuation as its own function).
6. Runtime trap patched (`rexglue-sdk/src/system/function_dispatcher.cpp`) to
   log unregistered indirect calls instead of aborting — each boot then reveals
   more targets. 7 rounds of discovery+rebuild added 7 more functions:
   `0x82A027C0, 0x823E7368, 0x827C9558, 0x828CD340, 0x82A0B928, 0x82A22018,
   0x82B71E18`. Last run: **zero fatals, zero new discoveries**.
7. Final image: 479 generated C++ files (252 MB source, 480 functions+chunks
   incl. gap-fill), 175 compile units → `toohuman` (141 MB ELF, links clean).

## Known issues / next steps

- **Black screen**: the window presents, audio initializes, the GPU processes
  real PM4 packets (pipelines built from the game's own VS/PS microcode), but
  nothing visible yet. Likely stuck in the stubbed logo-movie phase (WMV files
  exist on disc; no `XamMovie*`/XMedia calls appear in logs) or the resolve →
  frontbuffer path. Things to try: check whether the guest is blocked on a
  kernel primitive (`--log-level debug`), `--readback_resolve`,
  `--host_present_from_non_ui_thread`, movie-player HLE.
- One-time `ExecutePacketType3 overflow` at ring-buffer wrap — suspicious but
  non-recurring; worth a look if frames stay empty.
- `IoDismountVolumeByFileHandle` is stubbed (benign so far).
- The runtime `InvalidFunctionTrap` patch should be reverted to `REX_FATAL`
  for a release build (it currently only logs).
- `librexgpu-xenos.so` is symlinked next to the binary; keep it there or pass
  an absolute path to `--gpu_plugin`.

## Toolchain locations (this machine)

- SDK source + build: `/tmp/rexglue-sdk` (install: `out/install/linux-amd64`)
- Clang 23: `/tmp/llvm-root/LLVM-23.1.2-Linux-X64/bin` (shims in `/tmp/llvm-shim`)
- Rebuild codegen + binary:
  ```bash
  cd "/home/nick/Desktop/Coding/Roms/Too Human/port"
  export PATH=/tmp/llvm-shim:/tmp/llvm-root/LLVM-23.1.2-Linux-X64/bin:$PATH
  cmake --build out/build/linux-amd64-release --target toohuman_codegen
  cmake --build out/build/linux-amd64-release --target toohuman
  ```

Both `/tmp` locations are volatile — move them somewhere persistent
(e.g. `~/toolchains/`) if you want the setup to survive a reboot.
