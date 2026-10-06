# Generated-code patches (port/generated/default/ — gitignored, must be re-applied after a full codegen regen)

These edits live in files produced by the ReXGlue codegen. A full regen
(deleting `port/generated/default/`) destroys them; re-apply per below and
rebuild. Verified against codegen stamp of 2026-10 (dev builds).

## 1. Worker-loop work dispatch (`toohuman_recomp.70.cpp`, function `sub_82A041B8`)

Add the declaration after the last `#include`:

```cpp
DECLARE_REX_FUNC(sub_82A051C0);
```

At the loop tail — the block beginning `loc_82A0425C:` that sets
`r3 = r28` (0x833328CC), `r5 = 0`, `r4 = 1` and calls
`__imp__KeSetEvent(ctx, base)` — insert BETWEEN the `li r4,1` store and the
`bl __imp__KeSetEvent`:

```cpp
	// PORT DIAGNOSTIC: the driver's missing work dispatch. On HW a worker
	// processes the item at 0x83332900 (handler sub_82A051C0) before signaling
	// 0x833328CC, so the flusher's wait-any wakes on the item event first.
	// Dispatch on EVERY cycle: each flush pumps one work item; a one-shot
	// injection left later cycles completing vacuously against the
	// pre-signaled completion event, starving subsequent init work.
	{ uint64_t pd_r3 = ctx.r3.u64, pd_r4 = ctx.r4.u64, pd_r5 = ctx.r5.u64;
	  ctx.r3.u64 = 0x83332900ull; sub_82A051C0(ctx, base);
	  ctx.r3.u64 = pd_r3; ctx.r4.u64 = pd_r4; ctx.r5.u64 = pd_r5; }
```

Register save/restore is REQUIRED: `sub_82A051C0` clobbers r3/r4/r5
(caller-saved in the PPC ABI); without the restore the following
`KeSetEvent` receives garbage r3 and the kernel object lookup faults on
guest 0x1 in a tight loop (DEVLOG session-15).

## 2. Submit-path marker + live device pointer feed (`toohuman_recomp.17.cpp`, function `sub_82746738`)

File scope, after the includes:

```cpp
extern "C" { volatile uint32_t pd_drv_guest; }
```

First statement of the function body:

```cpp
	{ pd_drv_guest = (unsigned)ctx.r3.u32; } { static int pd_hit = 0; ++pd_hit; if (pd_hit <= 6 || pd_hit % 50 == 0) fprintf(stderr, "[port-diag] sub_82746738 ENTRY r3=%08x r4=%08x r5=%08x gate=%08x (#%d)\n", ...original args...); { if (pd_hit == 3) { FILE* pd_f = fopen("/tmp/dev_struct.bin", "wb"); ... } } }
```

(The `pd_hit == 3` device-struct dump and the `pd_drv_guest` feed are
diagnostics consumed by the runtime-side watcher; see
`patches/rexglue-runtime-patches.patch` and DEVLOG sessions 13–16.)
