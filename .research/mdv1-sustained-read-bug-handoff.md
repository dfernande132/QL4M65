# QL4M65 / CoreQL — mdv1 (microdrive) sustained-read corruption: analysis request

## Who you're talking to and what this is

You are being handed an unsolved hardware bug in a FPGA port of the Sinclair QL
computer to the MEGA65 (a modern FPGA-based retrocomputer). This is real,
physical FPGA hardware (Xilinx Vivado 2022.2, target part `xc7a200tfbg484-2`,
MEGA65 revision 6 board) — not a simulation. You cannot run or test anything
yourself. Your job is to read the code and the investigation history very
carefully and thoroughly, and produce a written analysis: your best-supported
hypothesis (or hypotheses, ranked) for the root cause, with exact file:line
citations, and — if you find something concrete — a proposed fix. If you
genuinely cannot find the cause, say so plainly rather than forcing a weak
conclusion; but please do not stop early. Take your time and go through the
RTL/VHDL in detail rather than pattern-matching on the summary below.

Please start by reading the project's own decision log and porting plan (see
"Where to start reading" below) — a great deal of investigation has already
happened, and you should build on it, not repeat it. But do not treat any
conclusion in there as gospel: re-derive things yourself where you can, and
say so explicitly if you disagree with something previously concluded.

## The project, briefly

QL4M65 is a port of the Sinclair QL (a 1984 British home computer, 68008 CPU)
to the MEGA65, using the MiSTer2MEGA65 ("M2M") framework. The QL core RTL
itself (CPU, video chip zx8301, I/O chip zx8302, microdrive controller mdv.v)
is vendored from the MiSTer-devel/QL_MiSTer open-source core (originally
targeting the MiSTer platform, a Terasic DE10-Nano board with an Intel/Altera
Cyclone V FPGA — **a completely different FPGA vendor/family from our Xilinx
Artix-7**). The M2M framework provides a "QNICE" service CPU (a small 50MHz
soft CPU) that handles the on-screen menu, SD card access, and loading
ROMs/disk images into the core, running in its own clock domain, separate
from the QL core's own 84MHz clock domain.

## The two symptoms (both still open, both on real hardware)

**1. Large/sustained reads from a loaded microdrive corrupt or fail; small
reads mostly work.** The user loads a `.mdv` microdrive image (always exactly
174930 bytes as a container, per the QLAY format used by this core) via the
on-screen menu. `DIR mdv1_` (scanning the tape's file catalog — short,
scattered reads) mostly works. But `LRUN mdv1_boot` (running a boot program —
much more data, read continuously) on a *larger* program reads for a very long
time and then fails with QDOS's own **"bad or changed medium"** error (QDOS's
own checksum validation on the data it received, not something this project's
RTL computes or filters). A *smaller* program on the same size-174930-byte
container loads and runs fine (though see symptom 2). So the corruption is
not tied to the `.mdv` file's on-disk size — it's tied to how much data is
read *continuously* in one sitting: the more sectors read in a row, the more
likely a failure becomes.

Debug instrumentation (see "Empirical evidence already gathered" below) shows
the actual bytes served to the CPU (via `mdv1_rx_ready` pulses) during a
*failing* large read amounts to some **6-7× the total file size** in served
bytes before QDOS gives up — i.e. QDOS is retrying heavily, and even many
retries don't recover for large reads, while small reads succeed within
roughly 1-1.5× the file size (one attempt, or very few retries).

**2. Unreliable first boot / needs a reset before things work.** Loading a
ROM and/or a `.mdv` image often does not work correctly the very first time
after power-on — the user frequently has to reset (or reload a ROM, which
also triggers a core reset) before a subsequent `.mdv` load/read becomes
reliable. This pattern is **not perfectly deterministic** — the user
explicitly reported "a veces cambio de ROM y no lee, otras cambio y sí lee"
(sometimes reloading the ROM fixes it, sometimes it doesn't) — so whatever is
going on is not a clean, 100%-reproducible "missing reset" story either.

**Both symptoms have persisted across several rounds of fixes and
investigation** (see history below) and remain unsolved. **The same `mdv.v`
RTL, byte-for-byte identical, is understood to work correctly on the
original MiSTer platform** (different FPGA, ARM-less loading path is
irrelevant since MiSTer ALSO uses a similar one-shot `ioctl` image-load
mechanism for this core) — please do not treat "it works on MiSTer" as
sufficient explanation on its own; dig into *why* our specific
implementation might differ in effect even where the RTL text is identical
(different FPGA family, different overall chip utilization, different
physical timing closure — but verify with real numbers/paths where you can,
don't just assert this).

## Where to start reading (do this first)

- `E:\QL_MEGA65\Fase0\DECISIONES.md` — the project's full decision/investigation
  log, in Spanish. **Read the sections from "Milestone 2 — microdrive fase A,
  `M2004`" through the end of the file** (search for `M2004` through `M2015` —
  each is a dated, timestamped section). This documents, in detail, every fix
  attempt, every hypothesis tested and ruled out, and the exact reasoning and
  evidence for each. This is the single most important document to read
  first.
- `E:\QL_MEGA65\Fase0\CoreQL\.research\PORTING-PLAN.md` — section 0 (top of
  file) has a running state-of-the-project snapshot, updated each session.
- `E:\QL_MEGA65\Fase0\CoreQL\.research\microdrive-read-design.md` — the
  original design document for the microdrive implementation (phases A/B/C/D),
  written before implementation started.
- `E:\QL_MEGA65\Fase0\CoreQL\doc\m2m\exceptions.md` — documents every place
  this port's RTL deviates from the pristine upstream MiSTer-devel source,
  with rationale. Important for knowing what's *actually* been changed vs.
  what's original.

## Key files (the actual RTL/VHDL to analyze)

Two separate git repositories are involved:
- `E:\QL_MEGA65\Fase0\CoreQL` (the main M2M port)
- `E:\QL_MEGA65\Fase0\CoreQL\CORE\QL_MiSTer` (a **separate git repo**,
  nested inside the above, containing the vendored/ported QL core RTL itself)

**The microdrive controller and its immediate surroundings:**
- `CORE\QL_MiSTer\rtl\mdv.v` — the microdrive emulation itself. **Pristine,
  never modified from upstream MiSTer-devel** (confirmed repeatedly). Emulates
  a 200kbit/s bit-serial tape device: internal free-running read pointer
  `mem_addr` (17-bit), internal dual-port RAM (`dpram #(17, 88000) vram`),
  gap/sector timing state machine, `rx_ready`/`gap`/`dout` outputs. Critically:
  **`mem_addr` has no reset path at all in this file** — it and the
  gap/sector state machine registers are touched only by the `always @(posedge
  clk)` block gated on `ce`/`download`, never by `reset`. Only `mdv_end` (a
  separate always block) has an actual `posedge reset` sensitivity.
- `CORE\QL_MiSTer\rtl\zx8302.v` — the QL's I/O controller chip (real-time
  clock, interrupts, microdrive interface, IPC/keyboard link). **This file
  HAS been modified** from upstream: 5 new ports added to expose a link to an
  externally-instantiated `mdv1` (see `doc\m2m\exceptions.md` for the exact
  diff/rationale). The `mdv_sel` register (an 8-bit shift register tracking
  which of up to 8 microdrives is currently selected, driven by CPU writes to
  the `mctrl` register) **also has no reset path**, in both the original and
  this port.
- `CORE\QL_MiSTer\QL.sv` — the ORIGINAL MiSTer top-level (unmodified,
  kept for reference/comparison). Shows how the real MiSTer platform wires
  `ioctl_download`/`ioctl_wr`/`ioctl_dout` (from the platform's `hps_io`
  SD-card-loading module) into `mdv_download`/`mdv_dl_wr`/`mdv_dl_data`, and
  how it instantiates `zx8302`/`mdv` with the same clock enable (`ce_bus_p`)
  for both the CPU and the I/O chip.
- `CORE\vhdl\main.vhd` — this port's core-clock-domain wrapper (all QL
  core instantiation happens here: CPU, zx8301, zx8302, mdv1, clock-enable
  generation). **This is where the microdrive loader FSM lives** — search for
  `mdv1_loader_qnice`, `mdv1_loader_core`, `xpm_cdc_handshake`,
  `xpm_cdc_single`, `mdv1_download`, `mdv1_loading_sync`. Also has the debug
  overlay (currently present, see below) and the clock-enable generation
  (`clock_enables` process, `ce_bus_p`/`FRACT_BUS_QL`).
- `CORE\vhdl\mega65.vhd` — the QNICE-clock-domain side: the CSR
  (control/status register) protocol for the manual-load mechanism
  (`qnice_csr` instance, `mdv1_req_status`, `p_mdv1_size_check` process,
  `C_MDV1_MAX_BYTES`), and the dispatch logic routing QNICE bus cycles to the
  mdv1 device.
- `CORE\vhdl\mdv_dpram.vhd` — a Vivado-clean drop-in replacement for
  `mdv.v`'s internal `dpram` Quartus/Altera megafunction (which doesn't
  synthesize on Xilinx). Backs onto `dualport_2clk_ram_byteenable`.
- `M2M\vhdl\2port2clk_ram_byteenable.vhd` → `2port2clk_ram.vhd` →
  `tdp_ram.vhd` — the actual BRAM inference chain used by `mdv_dpram.vhd`
  (and by other buffers in the project, e.g. ROM loading). `tdp_ram.vhd` uses
  a plain VHDL array (`type t_ram is array(...) of t_word`) with a registered
  address and combinational read — standard, portable, tool-agnostic BRAM
  inference (already checked: not a custom/manual multi-primitive cascade,
  see DECISIONES.md's M2015 section for detail — but please verify this
  yourself rather than trusting the summary; look closely for anything about
  *this specific instantiation's size* — mdv1's buffer needs 64 physical
  BRAM36 primitives, confirmed via Vivado's routed checkpoint, much larger
  than most other buffers in the project — that could behave differently).
- `M2M\vhdl\qnice_csr.vhd` — the generic manual-load CSR protocol (used by
  Main/Back ROM loading too, not just mdv1). `qnice_req_status_o` reflects
  whatever QNICE last wrote to the STATUS register.
- `M2M\rom\shell.asm` and `M2M\rom\crts-and-roms.asm` — the QNICE Shell
  firmware (assembly) implementing the generic `LOAD_IMAGE` byte-transfer
  loop and the CRT/ROM-category manual-load protocol (`CRTROM_CSR_ST_LDNG` /
  `_ERR` / `_OK` status codes) that mdv1 also uses (mdv1 is registered as a
  3rd manual-load "CRT/ROM"-category device, alongside Main and Back ROM).

## Investigation history — fixes already made (confirmed real bugs, now fixed)

Read DECISIONES.md for full detail, but in summary, chronologically:

1. **M2006**: `qnice_mdv1_wait_o` (the wait-state signal stalling the QNICE
   CPU while a byte crosses into the core clock domain) incorrectly OR'd the
   QNICE CPU's own *live* `ce`/`we`/`addr` signals into the wait formula,
   which — because those signals stay asserted until the CPU sees wait
   drop — created a permanent protocol deadlock on the very first word of
   any load. Fixed by making wait depend only on registered internal state.
2. **M2011 → M2012**: `mdv1_download` (mdv.v's `download` input, meant to
   hold the internal `mem_addr` pointer at 0 while the buffer is being
   filled) was implemented as a **one-cycle pulse** fired only when the
   first word (address 0) arrived — unlike the original MiSTer platform,
   where the equivalent `ioctl_download` is a **level held for the entire
   multi-hundred-millisecond transfer**. Because `mdv.v`'s own `mem_addr`
   advance logic (`if(ce) begin ... mem_addr <= mem_addr + 1 ... end`) is
   **unconditional** — not gated by `sel` or by whether the buffer is fully
   written — a one-cycle-only `download` pulse let `mem_addr` start
   free-running through the *same* dual-port RAM the QNICE loader was still
   writing, a genuine unsynchronized read/write race. This was made worse by
   `mdv_sel` having no reset (see above): if a drive was already selected
   from an earlier session, `mdv_present` (`= sel && mdv_end != 0`) could go
   true after just the *second* word of a *new* load, exposing the race
   directly to QDOS. **Fixed**: `mdv1_download` is now derived from
   `mdv1_req_status = C_CSR_REQ_LDNG` (QNICE-domain, the same flag
   `shell.asm`/`crts-and-roms.asm` use to track an in-progress vs. completed
   load) and synchronized into the core clock domain via `xpm_cdc_single`
   (an early attempt at this used a hand-rolled 2-FF synchronizer instead,
   which failed real Vivado timing closure because it wasn't recognized as a
   genuine clock-domain crossing without an XPM primitive — corrected).

**This fix measurably improved things** (loading itself, and short reads
like `DIR`, became much more reliable) but **did not fully solve either
symptom** — both are still present after M2012 and all subsequent builds
through M2015.

## Hypotheses already investigated and their current status

Please don't just re-propose these without reading why they were
ruled out/deprioritized — but do feel free to disagree if you find a flaw in
the earlier reasoning:

- **`ce_bus_p` clock-enable rate mismatch vs. original MiSTer**: checked —
  identical (same 84MHz base clock, same `FRACT_BUS_QL = 11702` fractional
  divider constant, in both `QL.sv` and `main.vhd`). Not the cause.
- **mdv1 and zx8302 running on different/desynced clock enables**: checked —
  both are driven by the literal same `ce_bus_p` signal (single wire,
  fanned out), no possibility of drift between them.
- **Manual/custom BRAM primitive cascading bug**: checked — the RAM
  inference chain (`tdp_ram.vhd`) uses a plain, standard VHDL array
  description, not a manual cascade. Considered unlikely, though the *size*
  specifically (64 physical BRAM36 primitives for mdv1's buffer, largest
  buffer in the project) hasn't been independently stress-tested — **you may
  want to look at this again with fresh eyes**.
- **HyperRAM contention stealing CPU bus cycles**: checked — QL main system
  RAM is currently plain on-chip BRAM (`dualport_2clk_ram_byteenable`), not
  HyperRAM; no HyperRAM is in the CPU's own memory path today. Ruled out.
- **`pause_i` (OSD menu pause) stalling the core during a read**: checked —
  `pause_i` is a `main.vhd` entity port that is **never referenced anywhere
  in the architecture body** (dead code). Ruled out as a cause, though
  arguably still worth fixing/wiring up correctly later for its own sake.
- **Detailed post-route static timing analysis** (via `report_timing
  -through` on the routed Vivado checkpoint, not just the global WNS/WHS
  summary numbers): `mdv1`/`zx8302`-area paths have a worst hold slack around
  0.107-0.121ns across recent builds — objectively tight by normal FPGA
  design standards, but **not the single worst path in the whole design**
  (something else — observed once to be the HyperRAM DDR input-capture
  IDDR primitives in the M2M framework — has an even tighter, near-zero
  margin in some builds). An experiment adding an extra pipeline register
  between `mdv.v`'s outputs and `zx8302` (M2015) compiled clean but detailed
  analysis showed the actual worst path in that area was dominated by
  `xpm_cdc_handshake`'s own internal synchronizer register (expected to be
  tight, that's normal for a CDC synchronizer, not evidence of a problem) —
  so this hardening attempt has **no strong evidence of having fixed
  anything**, and the underlying timing-margin hypothesis remains unproven
  either way. **This whole angle deserves more rigorous re-examination** —
  in particular, nobody has yet correlated a *specific* tight timing path
  with the *specific* signals involved in serving mdv1 data to the CPU
  during an actual failure (as opposed to just generically noting "margins
  are tight everywhere").
- **Architectural comparison with sibling MiSTer2MEGA65 cores**: C64MEGA65's
  1541 emulation streams sectors on-demand (`sd_rd`/`sd_ack` handshake,
  never preloads a whole disk image) — structurally cannot have this class
  of bug. AExp's Amiga floppy emulation uses `avm_fifo`/Avalon-MM with real
  backpressure (`avm_waitrequest_i`/`avm_readdatavalid_i`) for its ADF
  buffer in HyperRAM — but this was confirmed to be a *faithful*
  implementation of how real Amiga chipset floppy DMA always worked
  (address/pointer-based DMA into Chip RAM, confirmed via the real
  `DSKPTH`/`DSKPTL` hardware registers in `agnus_diskdma.v`), **not** a
  more-robust replacement of an mdv.v-like module — no such module exists
  in the Amiga chipset RTL. The QL's real microdrive hardware is genuinely
  serial/unbuffered/unacknowledged by design (unlike Amiga's addressed disk
  DMA), and `mdv.v` faithfully reproduces that. So there is no "just copy
  AExp's approach" fix available without deviating from real QL hardware
  behavior — **but this does NOT mean our specific implementation of that
  serial protocol is bug-free**; it only rules out "wrong architecture
  choice" as the explanation.

## Empirical evidence already gathered (from on-hardware testing with debug instrumentation)

As of the most recent build (M2015), `main.vhd` still contains an on-screen
debug overlay (search for `TEMPORARY DEBUG AID` comments) showing two
16-box progress bars in the top-left of the screen:
- Row 0 (top): count of `mdv1_dl_wr` pulses (words written into mdv1's
  buffer by the QNICE loader) since the last reset. Full successful load =
  ~15/16 boxes lit (a threshold-calibration quirk — the true max is 87465
  words, the bar's 16-box scale tops out at 88000, so 15/16 is actually a
  *complete, correct* load, not a partial one — don't be misled by this if
  you see it mentioned as "only 15/16" anywhere).
- Row 1 (bottom): count of `mdv1_rx_ready` rising edges (bytes served back
  to the CPU) since the last reset. Wraps/cycles every 16 boxes = 174930
  bytes (one file's worth).

**Key observations from real testing** (paraphrased from the user, who
tested extensively):
- The write bar reliably completes fully on every load — **the load/write
  side appears solid** after the M2012 fix. This is a real, if indirect,
  point of evidence that the corruption is specifically in the *read/serve*
  side, not the load side — but it does NOT rule out something in
  `mdv_dpram.vhd`/the BRAM read port itself (as opposed to the write side).
- A successful `DIR` (catalog scan) advances the read bar roughly 1-1.5×
  through the full file's worth of bytes before completing.
- A *failing* `LRUN` of a larger boot program: the read bar cycles through
  **6-7 complete wraps** (i.e. roughly 6-7× the file's total byte count in
  served-byte events) before QDOS gives up with "bad or changed medium".
  After the error is shown on screen, the read bar **keeps incrementing
  forever**, confirming mdv.v's internal state machine never stops running
  regardless of whether QDOS is happy or not (this matches real hardware:
  "the tape motor is always spinning").
- A small game (~"invaders") loads and runs successfully via `LRUN`,
  though the user still had to reset first in that session for it to work
  reliably (see symptom 2).
- The counters do **not** reset between successive loads within the same
  power-on session — only a genuine core reset zeroes them. (This caused
  some confusing intermediate readings during testing that were later
  correctly attributed to counter accumulation across multiple loads, not
  new corruption — please don't be misled if old conversation logs mention
  a bar "jumping to full" mid-session; that's an artifact of the debug
  counter design, not the QL's behavior.)

## Specific angles the user wants you to make sure you consider

The user explicitly asked that you not stop at "it works on MiSTer" and
specifically look hard at:

1. **Could this be a BRAM (block RAM) problem specific to this large a
   buffer** (87465 16-bit words ≈ 1.4Mbit per byte-lane, ~64 physical
   BRAM36 primitives on the Artix-7) — e.g. read-latency assumptions,
   read-during-write behavior/collision semantics (even though no write
   should be happening during a steady-state read after the M2012 fix — but
   verify this claim: is `mdv1_dl_wr` truly guaranteed inactive throughout a
   read, in *every* code path, including whatever happens right after a
   file finishes loading and before the user selects the drive?), or
   anything about how Vivado's XST/synthesis infers and times a BRAM this
   large compared to the smaller buffers elsewhere in the project (ROM
   loading, etc.) that apparently work fine.
2. **Could something in the M2M framework itself be interfering** — not
   just `pause_i` (already ruled out) but anything else framework-side that
   might, even occasionally/rarely, glitch or delay signals reaching the
   core clock domain during a long, continuous QL-core-only operation (video
   generation, OSD compositing even when the menu is nominally closed, HDMI
   output timing, keyboard scanning, IPC/8049 keyboard-link protocol
   activity, RTC/real-time-clock tick handling, anything using `reset` or
   `ce_bus_p`/`ce_11m`/`ce_131k`/`ce_vid` that could have an interaction
   with mdv1/zx8302 not yet considered).
3. **The still-unexplained "needs a reset/reload before it works reliably"
   pattern** (symptom 2) — this may or may not be the same root cause as
   symptom 1, but please form a view on whether they're linked. Candidate:
   `mdv_sel`'s missing reset (noted above, never fully chased down as a
   confirmed cause, only flagged as plausible) — is there a concrete
   mechanism by which `mdv_sel`'s power-up/post-reset value could differ
   between "fresh boot" and "after a ROM-reload reset", given that
   `main_reset_core_i`/`reset_soft_i`/`reset_hard_i` ultimately produce the
   `reset` signal in `main.vhd` that feeds `zx8302`? Trace this precisely.

## What "done" looks like for this task

A written report (does not need to be code, though a proposed patch is
welcome if you're confident in it) covering:
- Your ranked hypothesis (or hypotheses) for the root cause of symptom 1
  (sustained-read corruption scaling with data volume), with exact
  file:line evidence.
- Your view on whether symptom 2 (unreliable first boot) shares the same
  root cause or is separate, with reasoning.
- What you'd recommend investigating next if you cannot reach a confident
  conclusion from static analysis alone (e.g. specific signals worth
  capturing with a hardware ILA/logic analyzer, specific experiments worth
  trying on real hardware, etc.) — this project has real MEGA65 R6 hardware
  available for testing, so a recommendation that requires a specific
  hardware experiment is completely fine, just be precise about what to
  build/observe.

Please work through this carefully and completely rather than quickly. This
bug has resisted several rounds of investigation already; a hasty pass is
unlikely to add much.
