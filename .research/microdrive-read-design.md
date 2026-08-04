# Milestone 2 — virtual microdrive design doc

Status: **approved for phased implementation (updated 2026-08-04)**. Originally
written 2026-08-02 assuming 2 drives on HyperRAM from day one; rewritten after
the QL-SD pivot (see `DECISIONES.md`, "Milestone 2 — QL-SD pausado, pivote a
microdrive") to match the staged plan actually agreed with the user:

1. Prepare Milestone 2 (this document + supporting docs) — done by this rewrite.
2. **Phase A (this doc's main focus): one microdrive, read-only, in BRAM.**
3. Phase B: write support (separate design pass once A is confirmed on hardware).
4. Phase C: migrate the buffer from BRAM to HyperRAM.
5. Phase D: expand to 2-4 simultaneous drives.

Nothing in `main.vhd`/`mega65.vhd`/`globals.vhd`/`zx8302.v` has been touched
yet for this milestone (QL-SD's own changes to those files were reverted,
see `DECISIONES.md`).

## Recap of what we confirmed by reading the actual RTL (still valid)

- `rtl/mdv.v` (unmodified, 100% present in the repo already, never compiled
  since `M1001` removed the instance that pulled in the unsynthesizable
  `dpram.v` — see `doc/m2m/exceptions.md`) is **not** an on-demand disk
  controller — it continuously replays one whole image from an internal
  buffer at 200kbit/s, generating its own gap timing. Architecturally much
  closer to our own Main/Back ROM ("load a whole file into a device buffer")
  than to a real disk protocol.
- Confirmed **read-only, at the RTL level, end-to-end**: `mdv.v` has no
  CPU-facing write-data port at all (only `dl_addr`/`dl_data`/`dl_wr` for the
  one-shot initial image upload), `tx_empty` is hard-wired `1'b0` ("never
  room to write"), and `zx8302.v`'s own CPU register interface only ever
  *writes* the drive-select register (`mctrl`) — the data register (`18023`)
  is read-only in the RTL. Write support is 100% new work (Service Manual +
  Minerva's `dd/mdvop.asm`/`md/*.asm` as the spec), explicitly deferred to
  Phase B.
- `mctrl`-driven `mdv_sel` (which of up to 8 possible drives is currently
  selected) already exists and works in our `zx8302.v` since `M1040` — it
  just needs routing to a real drive instead of the placeholder gap
  generator, for whichever drive number(s) we actually back.
- `mdv.v`'s own internal buffer is `dpram #(17, 88000) vram` — the same
  Altera/Quartus-only `altsyncram` wrapper problem as the original
  `ql_rom`/`vram`, needing the same class of Vivado-clean replacement.
  `ADDRWIDTH=17, NUMWORDS=88000` (16-bit words) fits one ~172-176 KB QLAY
  image with some slack — exact image size to confirm against a real
  `.MDV` file (174930 bytes per the core's own `readme.md`, ~171 KiB).
- **`mdv.v`'s own `dpram` instantiation ties both `wrclock` and `rdclock` to
  its single `clk` input** (`rtl/mdv.v:49-59`: `dpram #(17,88000) vram
  (.wrclock(clk), ..., .rdclock(clk), ...)`) — i.e. mdv.v itself expects a
  **single-clock-domain** RAM, not a genuinely dual-clocked one, even though
  the replacement primitive (`dpram`) supports independent clocks in its own
  port signature. This matters a lot for Phase A's loader design (see below)
  — it's a new finding versus the original 2026-08-02 draft of this doc,
  which assumed the HyperRAM bridge would sit directly on this same
  `wrclock`/`wraddress`/`wren`/`data` port without a clock-domain problem.

## Phase A — one microdrive, read-only, in BRAM

### A.1 — Vivado-clean `dpram` replacement (BRAM, not HyperRAM)

Same policy as everywhere else in this project: `mdv.v` stays 100%
unmodified. Its own `dpram #(17, 88000) vram (...)` instantiation gets a
Vivado-clean implementation matching `rtl/dpram.v`'s exact port signature —
this time backed by BRAM (`M2M/vhdl/dualport_2clk_ram_byteenable.vhd`, the
same module already used for main RAM/VRAM in `main.vhd`), not HyperRAM.
`rtl/dpram.v` itself stays excluded from the Vivado compile list (same
"stays in repo, never compiled" treatment as `rtl/keyboard.v`/`rtl/ipc.v`).

```verilog
module dpram #(parameter ADDRWIDTH=0, NUMWORDS=1<<ADDRWIDTH)
(
   input                  wrclock,
   input  [ADDRWIDTH-1:0] wraddress,
   input                  wren,
   input            [1:0] byteena_a,
   input           [15:0] data,
   input                  rdclock,
   input  [ADDRWIDTH-1:0] rdaddress,
   output          [15:0] q
);
```

BRAM sizing: `dualport_2clk_ram_byteenable` at `G_ADDR_WIDTH => 17,
G_DATA_WIDTH => 16` gives 256K words = 512 KB of BRAM allocated — much more
than the ~176 KB actually needed (mdv.v's own `ADDRWIDTH=17` is already
oversized relative to a real image, presumably to leave headroom). Worth
sizing the replacement to the *real* file size once confirmed (open question
1 below) rather than blindly matching `mdv.v`'s 88000-word default, to avoid
wasting BRAM tiles for no reason — `MAXIMUM_SIZE` generic (already supported
by `dualport_2clk_ram`, see `mega65.vhd`'s own D64 mount buffer precedent in
C64MEGA65) can cap it without changing `ADDRWIDTH`.

### A.2 — the loader: a real clock-domain-crossing problem, not just a BRAM-vs-HyperRAM one

The original design doc's Part 3 assumed the QNICE-side file loader would
feed data in through the same port a HyperRAM bridge would use, sidestepping
clock-domain questions by construction. Now that Phase A stays on BRAM and
directly targets `mdv.v`'s own `download`/`dl_addr`/`dl_data`/`dl_wr` ports,
the finding above (both `wrclock`/`rdclock` tied to `mdv.v`'s single `clk`
input) means those four top-level ports are **core-clock-domain signals**
(`clk_main_i`), not something a `dualport_2clk_ram`'s own dual-port
capability can absorb for free the way Main/Back ROM's loading does (there,
the *destination RAM itself* is genuinely dual-clocked at the BRAM primitive
level, so QNICE and the CPU each get their own native port — no FSM needed).
Here, mdv.v's fixed internal wiring means the write side of its own buffer
is nailed to the core clock, so the QNICE Shell's byte stream (from reading
the `.MDV` file over FAT32, in `qnice_clk_i` domain) needs an actual
clock-domain-crossing bridge before it reaches `mdv.v`'s ports.

Proposed design: a small loader FSM in `main.vhd`, clocked by `clk_main_i`,
using the same two-phase toggle handshake this project already relies on
elsewhere (`ipc_busy`-driven `intri_irq` in `zx8302.v`; AExp's own
dirty-track write-back channel between `adf_track_engine.vhd` and
`adf_mount_wrapper.vhd`) rather than hand-rolled flip-flops — `xpm_cdc_*`
primitives are already used by the framework (`vdrives.vhd`'s own
`xpm_cdc_array_single`), so this isn't introducing a new CDC technique to
the project, just applying an existing one in a new spot:

1. QNICE side (in a new device, e.g. `C_DEV_QL_MDV1`, same shape as
   `C_DEV_QL_MAINROM`/`BACKROM`'s manual-load CSR handling): for each file
   byte, QNICE writes address+data into a small register pair and toggles a
   `req` bit.
2. Core-clock side: synchronizes `req` (2-FF, or `xpm_cdc_single`), and on
   each detected toggle edge, latches address+data, drives `mdv.v`'s
   `download<=1`/`dl_addr`/`dl_data`, pulses `dl_wr` for one `clk_main_i`
   cycle, then toggles `ack` back.
3. QNICE side waits for `ack` to match its own `req` before sending the next
   byte (same throttling shape as any of this project's other toggle
   handshakes) — this is the actual load-time cost: one full CDC round trip
   per byte, ~176000 times for one image. Should still be fast in absolute
   terms (each round trip is on the order of a few core-clock cycles once
   synchronized, well under the QNICE Shell's own per-byte FAT32 read
   overhead which almost certainly dominates total load time anyway — same
   order of magnitude as Main/Back ROM's own byte-at-a-time loading, which
   is already proven fast enough on hardware since `M1042`).

**`download`/`mdv_end` semantics, confirmed by reading the rest of `mdv.v`
(`:75-117`):** `download` only matters as a synchronous reset pulse — while
high, `mdv.v` resets `mem_addr` to 0 and re-initialises its gap state
machine to "start of gap", every cycle it's held high. It does **not** gate
`dl_wr` in any way (that logic is entirely separate, `:77-82`). So the
loader FSM (A.2) only needs to pulse `download` once, briefly, *before* the
first `dl_wr` of a load — holding it high for the whole transfer would also
work (idempotent, same reset state re-applied every cycle) but is
unnecessary. Separately, **`mdv_end` (the image's end-of-data marker,
consulted by `mdv_present = sel && (mdv_end != 0)`) is simply whatever
`dl_addr` value was present on the *last* `dl_wr` pulse** (`:80`:
`if(dl_wr) mdv_end <= dl_addr;`) — the loader must write words in strictly
increasing address order (0, 1, 2, ... up to the last word), since `mdv.v`
doesn't compute a real "highest address written" independently, it just
remembers whatever the final write's address happened to be.

### A.3 — wiring into the core

- `main.vhd`: one `mdv` instance (Verilog, instantiated directly from VHDL —
  same cross-language pattern already used for `zx8301`/`zx8302`), with the
  new BRAM-backed `dpram` (A.1) and the loader FSM (A.2).
- `sel` driven by bit 0 of `zx8302.v`'s existing `mdv_sel` register (mdv1) —
  matches "first occurrence = drive 0" convention already used for
  `OPTM_G_MOUNT_DRV`/`OPTM_G_LOAD_ROM` elsewhere in this project's own menu
  code, kept consistent even though this isn't going through `vdrives.vhd`.
- `zx8302.v`'s single `mdv_gap`/`mdv_tx_empty`/`mdv_rx_ready`/`mdv_byte`
  inputs become a mux in `main.vhd` (not `zx8302.v` itself): when `mdv_sel`
  selects drive 1, use the real `mdv` instance's outputs; for any other
  selected drive number (0, or 2-8 until Phase D backs more), fall back to
  the existing `M1040` gap-pulse placeholder so QDOS's own "no medium
  present" convergence keeps working for drives we don't physically back.
- `reverse` fixed to `1'b0` ("normal") — no menu item yet, matches the
  original design's own call.

### A.4 — menu / manual load

```
Microdrive
  mdv1:%s
```
Manual load only for Phase A (`C_CRTROMS_MAN`, same fused status+action
single line as Main/Back ROM) — auto-load from a fixed SD path can follow
once read is confirmed working on hardware, mirroring how Main/Back ROM
auto-load was added *after* the manual mechanism was proven (`M1042`
attempted auto-load before manual load was even solid and had to backtrack
— worth not repeating that ordering mistake here).

## Phase B — write support (separate design pass)

Not designed yet — explicitly deferred until Phase A is confirmed on
hardware. Needs: the real microdrive sector/write protocol (Service Manual +
Minerva's `dd/mdvop.asm`/`md/*.asm` as the spec, since `mdv.v` has zero write
support to crib from), and a write-back mechanism to flush changes to the SD
card file. AExp's own `adf_mount_wrapper.vhd`/`adf_track_engine.vhd` pattern
(dirty-bitmap + anti-thrashing delay + `HANDLE_CORE_IO` background flush) is
the architectural reference to adapt, not something to reuse verbatim — ADF
write-back operates at the MFM/track level, microdrive's own format is
different at the protocol level even though the "dirty region + background
flush to SD" shape should carry over.

## Phase C — migrate the buffer to HyperRAM

Deferred design, but keeping the useful analysis from the original draft
since it remains valid whenever this phase starts:

**Why the latency is a non-issue for this specific use case**: `mdv.v` only
advances its internal `mem_addr` once every **~80 microseconds** (200kbit/s
replay rate) — roughly 6700 cycles at 84 MHz. HyperRAM's round-trip (5
cycles at 100 MHz + CDC, ~9 cycles total per AExp's own measurements) is on
the order of 90 nanoseconds. Enormous slack (80us budget vs. ~90ns actual
latency) — a HyperRAM-backed buffer can be functionally invisible to
`mdv.v`'s own timing, no redesign of its internal state machine needed.

**Mandatory pre-flight check before writing any `C_HMAP_MDV1` constant**
(lesson from `M2003`'s QL-SD bug, see `DECISIONES.md`): do the arithmetic by
hand — `C_HMAP_*` base (in 4kW = 4096-word units) × 4096 words × 2 bytes must
land, plus the buffer's own full size, strictly inside the physical 8 MB
(2^23 bytes = 2^22 words) of the MEGA65's HyperRAM chip. "Right after the
last reserved constant" is **not** a safe placement rule by itself — it was
exactly how the QL-SD mount buffer ended up addressing byte 8388608 (one
byte past the end) on an 8 MB chip. Write out the actual byte-address range
`[base, base+size)` and confirm `base+size <= 8*1024*1024` before compiling,
every time a new `C_HMAP_*` constant is added.

`hr_core_*` arbitration: by Phase C, this project will already have built
and then reverted one working QNICE↔HyperRAM bridge (QL-SD's mount buffer,
`qnice2hyperram.vhd`+`avm_fifo.vhd`, both unmodified framework files) — that
same pattern is directly reusable here, single master again if nothing else
is on HyperRAM yet by then. If Phase D (multiple drives) or the memory-
expansion milestone lands first, an actual N-master arbiter becomes
necessary (round-robin proposed, matches the original draft's own
reasoning — neither microdrive nor QNICE-loader access is latency-critical
per the slack analysis above).

## Phase D — expand to 2-4 simultaneous drives

Deferred design. Once one drive works end-to-end (read + write + HyperRAM),
replicate the `mdv` instance + buffer + loader per additional drive,
extending the `main.vhd` mux (A.3) to cover more of `mdv_sel`'s 8 possible
values, and adding one menu line per drive (`mdv2:%s`, `mdv3:%s`, ...).

## Open questions for review

1. **Exact `.MDV` file size** — need to confirm the real byte count from an
   actual QLAY image file, to size the BRAM buffer precisely (currently
   assuming the core's own `readme.md` figure, 174930 bytes) and the
   size-check FSM.
2. **CDC handshake implementation detail** — hand-rolled toggle + 2-FF
   synchronizer (matching `intri_irq`'s own style) vs. `xpm_cdc_pulse`/
   `xpm_cdc_handshake` (Xilinx primitives, `vdrives.vhd` already uses
   `xpm_cdc_array_single` elsewhere in this project) — leaning toward the
   `xpm_cdc_*` primitives for anything new, but no strong reason either way
   yet.
3. Anything from this design that doesn't match your own mental model of how
   Phase A should work before writing VHDL/Verilog.
