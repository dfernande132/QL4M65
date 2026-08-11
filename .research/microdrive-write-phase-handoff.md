# QL4M65 / CoreQL — starting Milestone 2 phase B: microdrive write support

## Who you're talking to and what this is

This is a **fresh-start briefing** for a new conversation, not a bug report.
Milestone 2 phase A (microdrive, read-only, one drive) is **done, tested on
real hardware, and published**. This document hands off everything needed
to start phase B: **write support**, without needing the (very long) prior
conversation that built phase A. Read this fully before touching any code,
then read the files it points to.

You're working with the user in an interactive Claude Code session. They
are the project owner (dfsantos), technically strong, and prefers working
one task at a time, testing on real MEGA65 R6 hardware after each build,
asking when something is unclear rather than guessing. Two standing rules,
already established and expected to continue without being asked again:
**update `DECISIONES.md` and `.research/PORTING-PLAN.md` (and anything else
that needs it) after every compile, and commit locally** - no permission
needed for that. **Never push to GitHub unless explicitly asked in that
specific moment** - a push authorized once does not carry forward.

## Where things stand right now

- **Milestone 1**: complete. QL boots end-to-end, keyboard works, ROM
  loading works.
- **Milestone 2 phase A**: complete. One microdrive (`mdv1_`), read-only,
  loaded from a `.MDV` image via the Shell's Options menu. `DIR mdv1_` and
  `LRUN mdv1_xxx` both work reliably on real hardware, including full,
  sustained reads of real programs. A synthesized motor-hum sound effect
  was also added (gated on `mdv_sel(0)`, mixed into the existing beeper
  audio path). Published to GitHub (`QL4M65` and `QL_MiSTer` repos).
- **This session's task**: implement **microdrive write support** (`SAVE`,
  and whatever else QDOS needs to write to microdrive) - this is phase B
  of the original microdrive design plan, done in its originally-intended
  order (phase C, moving the buffer to HyperRAM, was considered as an
  alternative next step for its value as a rehearsal for the future 4MB
  memory expansion milestone, but the user decided to stick with the
  original order: write support first).

## Read these first, in this order

1. **`DECISIONES.md`** (`E:\QL_MEGA65\Fase0\DECISIONES.md`, parent
   directory of the `CoreQL` repo, not inside it) - skim the whole
   microdrive story if you want full historical context (search for
   "Milestone 2" and "mdv1"), but at minimum read the **last ~15 entries**
   (`M2011` through the final "Milestone 2 fase A queda cerrada" and
   `M2019` entries) for the freshest, most relevant state and the exact
   protocol-level facts discovered during the read implementation (cycle
   budgets, gap timing, checksum format) - these transfer directly to
   understanding writes.
2. **`.research/PORTING-PLAN.md`** section 0 - current state snapshot.
3. **`.research/microdrive-read-design.md`** - the original design
   document for the read implementation. Written before phase A started;
   it already sketches a rough phase B (write) outline, but treat that
   outline as a rough starting point only - it predates everything learned
   below and hasn't been revisited since.
4. **`E:\QL_MEGA65\Fase0\mdv1-sustained-read-analysis.md`** and
   **`...-round2.md`** (outside the repo, same `Fase0` directory) - the two
   external-model analyses that eventually solved the read reliability
   bug. Read these for the deep protocol knowledge (Minerva's actual
   polling-loop cycle counts, the real sector/checksum layout, the gap
   timing state machine) - all directly reusable for understanding the
   *write* side of the same protocol.
5. **`doc/m2m/exceptions.md`** - documents every deliberate RTL deviation
   from upstream MiSTer-devel in this port, with rationale. Update this
   file when you make new deviations (you will - see below).

## The single most important finding to start from

**`rtl/mdv.v` (the microdrive controller, pristine unmodified MiSTer-devel
code) has ZERO write support at the RTL level today.** Confirmed by
reading the file directly: `assign tx_empty = 1'b0;` (`mdv.v:70`) is
**hardcoded permanently false** - the "transmit buffer empty" status bit
QDOS's write routine would need to poll to know it can send the next byte
never indicates readiness. There is no data-input port, no write-enable
output, nothing. This is not "wire up an existing capability" - it's
designing and implementing real write emulation for the first time, either
by modifying `mdv.v` itself or by some other RTL mechanism.

**First thing to actually do**: check whether a newer version of `mdv.v`
exists upstream (github.com/MiSTer-devel/QL_MiSTer) that implements write
support that could be adopted instead of designed from scratch. This
project's `CORE/QL_MiSTer` is a separate git submodule/repo tracking (a
fork of) that upstream - check its own git log for when it was last synced,
and compare against upstream's current `rtl/mdv.v` via GitHub (`gh` CLI
isn't available in this environment's Bash tool - use `WebFetch` on GitHub
URLs, or look for an equivalent MCP tool, following the same approach used
successfully earlier in the read-support investigation to check upstream
commit history).

## Suggested research plan (already discussed with the user, not yet started)

**Phase 1 - reconnaissance:**
1. Check upstream `mdv.v` for existing write support (above).
2. Read Minerva's actual write driver source in full detail - almost
   certainly `md/write.asm` (a sibling of the already-extensively-studied
   `md/read.asm`, referenced throughout the round-1/round-2 analyses above)
   - determine exactly what status bits it polls, what its real-time cycle
   budget looks like (the read side turned out to have only ~7 CPU cycles
   of margin against video-contention wait-states - the write side may
   have a similarly tight, or different, budget; don't assume it's the
   same without checking), how it computes and writes sector/block
   checksums, and what if any read-after-write verification it performs.
3. Scope the MVP deliberately: writing to an already-formatted microdrive
   with existing free sectors (`SAVE` a file - the common case) is very
   different in complexity from formatting a blank cartridge from scratch
   (`FORMAT`, a QL utility operation with its own protocol). Recommend
   scoping FORMAT out of the first pass unless the user wants it included.

**Phase 2 - architecture design:**
4. Design the RTL write path - most likely requires real modifications to
   `mdv.v` (breaking, for the first time, the "never modify" policy this
   file has had since phase A) or a parallel/replacement module: a genuine
   data-input port, real `tx_empty` generation, and logic to write an
   incoming byte at the current `mem_addr` position instead of only
   reading from it.
5. Design how written data gets persisted back to the SD card's `.mdv`
   file. Unlike reads (serve-only, nothing to persist beyond the session),
   writes need a QNICE-side mechanism in the *opposite* direction from the
   existing loader (core clock domain -> QNICE clock domain -> SD card),
   with some notion of dirty-sector tracking and a decision about when to
   flush (every write? on eject? periodically? user-triggered?). AExp's
   `adf_track_engine.vhd` write-through cache (mentioned in the round-1
   analysis - `avm_cache` updates on write hits so reads stay coherent) is
   a relevant architectural reference for the dirty-tracking concept, even
   though its underlying transport (Avalon-MM/HyperRAM) differs from
   mdv1's serial approach. **There is no existing "write back to SD"
   pattern anywhere in this project to reuse directly** - the QNICE Shell's
   generic manual-load CSR protocol (`C_CSR_REQ_LDNG`/`_OK`/`_ERR`, used
   for ROM and mdv1 loading) is a load-only, one-directional mechanism;
   this needs new protocol design, likely a new CSR-like mechanism or an
   extension of the existing one.
6. Re-derive the write side's real-time cycle budget once `md/write.asm`
   is read (step 2), and check it against `ql_timing.sv`'s contention
   model the same way the read side's 37-vs-30-cycle margin was found -
   the `cpu_rom => cpu_rom or ql_io` fix already in place (exempting all
   `zx8302` I/O from video-contention wait states, not just reads) should
   already cover this, but verify rather than assume.

**Phase 3 - implementation:**
7. Staged rollout mirroring how reads were built: get one sector writing
   correctly first, verify with a round-trip check (write, then read back
   with the existing read path, compare checksums - `Fase0/tools/
   mdvcheck.py`, mentioned below, validates checksums and could likely be
   extended or reused directly for this) before scaling to full write
   support.

## Tooling already available (outside this repo, `E:\QL_MEGA65\Fase0\tools\`)

- **`mdvcheck.py`** - validates every sector's checksums in a `.mdv`
  against Minerva's real checksum algorithm; built during the read
  investigation to distinguish "corrupted test image" from "real RTL bug"
  (it turned out to be the former, repeatedly - see `DECISIONES.md`'s
  final microdrive entries). **Very likely directly useful for validating
  write round-trips** - if you write a sector and then have QDOS read the
  image back, or read the modified `.mdv` file with this tool afterward,
  it should tell you immediately whether the written checksums are
  correct.
- **`mdvrepair.py`** - repairs checksum-only corruption without touching
  data. Probably not directly relevant to write support, but good to know
  it exists.
- **`Fase0/tools/README.md`** documents both in detail, including the
  exact sector/checksum layout reverse-engineered from `mdv.v` and
  Minerva's source - this is a genuinely useful reference for the byte-
  level format you'll be writing.
- **Project rule established during phase A: run `mdvcheck.py` on any
  `.mdv` before using it as a hardware test case.** It cost three rounds
  of investigation to learn this; don't relearn it.

## Architectural patterns established in this project (reuse where they fit)

- **CDC (clock-domain-crossing) rule, learned the hard way (see
  `DECISIONES.md`'s M2011 section and the saved memory
  `feedback_cdc_use_xpm_primitives.md`)**: any signal crossing between the
  QNICE clock domain (50MHz) and the core clock domain (84MHz) must use a
  Xilinx `xpm_cdc_*` primitive (`xpm_cdc_handshake` for multi-bit data
  transfers, `xpm_cdc_single` for a single level bit) - never a hand-rolled
  synchronizer process. A hand-rolled one will pass simulation/functional
  review but fail real Vivado timing closure, because it carries no timing
  exception and gets analyzed as an ordinary synchronous path. This will
  matter a lot for the write-back-to-QNICE direction.
- **"Expose ports on the unmodified original, instantiate the modified/new
  logic as an external sibling"** pattern - used for `ipc.vhd` (the T48
  emulation replacing zx8302's embedded 8049) and for `mdv1` itself
  (external sibling of `zx8302.v`, which only gained 5 new ports to link
  to it). If `mdv.v` needs write logic, consider whether it's cleaner to
  modify `mdv.v` directly (if the change is small/contained) or to keep
  `mdv.v` untouched and add a sibling module - decide based on how
  invasive the actual write logic turns out to be once designed.
- **Vivado-clean RAM replacement pattern** - `mdv_dpram.vhd` already
  replaces `mdv.v`'s internal Quartus-only `dpram` megafunction with a
  same-named, same-port-signature VHDL entity backed by
  `dualport_2clk_ram_byteenable` (BRAM). If the write path needs a second
  RAM port or a different memory arrangement, this pattern and file are
  the starting point.

## Build/test workflow (unchanged from phase A)

Two separate git repos: `E:\QL_MEGA65\Fase0\CoreQL` (main M2M port) and
`E:\QL_MEGA65\Fase0\CoreQL\CORE\QL_MiSTer` (nested repo, the vendored QL
core RTL - this is where `mdv.v`/`zx8302.v` actually live). Build via
Vivado batch (`vivado.bat -mode batch -source build_core.tcl`, from
`CORE/`), package with `E:\QL_MEGA65\Mega65Tools\bit2core.exe`, output
`.cor` files go to `E:\QL_MEGA65\Mega65Tools\`. Always check WNS/WHS are
both positive and there are 0 routing errors before considering a build
good. Tag each hardware-tested build (`git tag M2NNN`) in both repos where
relevant, continuing the `M2020`+ numbering (last used: `M2019`, the
microdrive sound build, pending hardware confirmation as of this
handoff).
