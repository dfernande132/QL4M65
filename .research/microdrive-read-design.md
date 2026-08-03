# Milestone 2, phase 1: read-only virtual microdrive (design doc, NOT YET IMPLEMENTED)

Status: **design for review**. Nothing in `main.vhd`/`mega65.vhd`/`globals.vhd`
has been touched yet. Write support is an explicit follow-up phase, not part
of this design at all - see the "Read first, write later" decision in chat.

## Recap of what we confirmed by reading the actual RTL

- `rtl/mdv.v` (unmodified, 100% present in the repo already, just never
  compiled) is **not** an on-demand disk controller - it continuously
  replays one whole image from an internal buffer at 200kbit/s, generating
  its own gap timing. This is architecturally much closer to our own
  Main/Back ROM ("load a whole file into a device buffer") than to a real
  disk protocol.
- Confirmed **read-only, at the RTL level, end-to-end**: `mdv.v` has no
  CPU-facing write-data port at all (only `dl_addr`/`dl_data`/`dl_wr` for
  the one-shot initial image upload), `tx_empty` is hard-wired `1'b0`
  ("never room to write"), and `zx8302.v`'s own CPU register interface only
  ever *writes* the drive-select register (`mctrl`) - the data register
  (`18023`) is read-only in the RTL. Not something MiSTer's HPS/Linux side
  compensates for either - the RTL never captures what the CPU would send.
  Write support is 100% new work for us (Service Manual + Minerva's
  `dd/mdvop.asm`/`md/*.asm` as the spec), explicitly deferred.
- `mctrl`-driven `mdv_sel` (which of up to 8 possible drives is currently
  selected) already exists and works in our `zx8302.v` since `M1040` - it
  just needs to be routed to real drives instead of the placeholder gap
  generator.
- `mdv.v`'s own internal buffer is `dpram #(17, 88000) vram` - the same
  Altera/Quartus-only `altsyncram` wrapper problem as the original
  `ql_rom`/`vram`, needing the same class of Vivado-clean replacement.
  `ADDRWIDTH=17, NUMWORDS=88000` (16-bit words - fits one ~172-176 KB QLAY
  image with some slack; exact image size TBD against a real `.MDV` file).

## Decision: HyperRAM from the start, not BRAM

Current BRAM headroom is healthy (122.5/365 tiles used, `M1048` build) and
one drive would only cost ~38 tiles - BRAM would work fine for 2 drives.
Going to HyperRAM anyway per the user's call: 4 drives on BRAM (~152 tiles)
eats a large chunk of the budget permanently, and the main QL RAM will need
HyperRAM eventually anyway (memory-expansion milestone) - better to build
the HyperRAM plumbing once, now, than twice.

**Why the latency is a non-issue for this specific use case**: `mdv.v`
only advances its internal `mem_addr` once every **~80 microseconds**
(200kbit/s replay rate) - roughly 6700 cycles at 84 MHz. HyperRAM's
round-trip (5 cycles at 100 MHz + CDC, ~9 cycles total per AExp's own
measurements) is on the order of 90 nanoseconds. There is enormous slack
(80us budget vs. ~90ns actual latency) - a HyperRAM-backed buffer can be
functionally invisible to `mdv.v`'s own timing, no redesign of its
internal state machine needed.

## Part 1 — a HyperRAM-backed `dpram` Verilog module, matching the original signature exactly

Rather than touch `mdv.v` (keep it 100% unmodified, same policy as the T48
core), provide our own Verilog module also named `dpram`, matching
`rtl/dpram.v`'s exact parameter/port signature:

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

Internally: a small Avalon-MM master (word-addressed, matching
`hr_core_*`'s 16-bit data width) that (a) on `wren`, issues a HyperRAM
write at the module's own base offset + `wraddress`; (b) on `rdaddress`
changing, issues a HyperRAM read and latches the result into a register
that continuously drives `q` (so `q` is always the *last known good* value,
never X/invalid, matching a real dpram's behavior of holding the previous
output between reads). `rtl/dpram.v` itself gets excluded from the Vivado
compile list (same "stays in repo, never compiled" treatment as
`rtl/keyboard.v`/`rtl/ipc.v`), same as `mdv.v` was until now.

One instance needed per drive (two total for mdv1+mdv2), each at its own
HyperRAM base address (generic parameter, see Part 2).

## Part 2 — HyperRAM arbitration and memory map

`mega65.vhd`'s `hr_core_*` ports are a single Avalon-MM master, currently
tied off entirely unused. Multiple things now want to share it: mdv1's
read/write buffer, mdv2's read/write buffer, and the QNICE-side loader that
streams a `.MDV` file into that same buffer at mount time (Part 3) - at
least 3 masters, maybe more later (main RAM, eventually). Needs an
N-master arbiter feeding the single `hr_core_*` port - same shape as
AExp's own "avm_fifo CDC + 2-master arbiter" (their comment in
`mega65.vhd`'s file map) for their ADF buffer; ours needs one more leg.
Exact arbitration scheme (round-robin vs. priority) - **open question,
propose round-robin since neither microdrive/QNICE-loader access is
latency-critical** (see the 80us-vs-90ns slack above).

Memory map (units of 4kW = 4096 words = 8192 bytes, following
`globals.vhd`'s existing `C_HMAP_*` convention):
```
C_HMAP_MDV1 : new constant, right after C_HMAP_QL's current allocation
C_HMAP_MDV2 : C_HMAP_MDV1 + enough 4kW windows for one image
```
One `.MDV` image (QLAY format) needs confirming the exact byte count
against a real file - `ADDRWIDTH=17/NUMWORDS=88000` in the original
`mdv.v` suggests ~172-176 KB; round up to the next 4kW (8192-byte)
boundary per drive.

## Part 3 — loading a `.MDV` file into the HyperRAM buffer

Same shape as Main/Back ROM's `qnice_csr` + size-check FSM (`M1045`), with
two differences:
1. **Destination is HyperRAM, not BRAM** - the QNICE-side byte-window
   write path needs the same kind of bridge AExp's own
   `adf_mount_wrapper.vhd` already builds (QNICE clock domain, byte-address
   window into a HyperRAM word, via its own Avalon-MM master leg into the
   arbiter from Part 2) - directly reusable pattern, unlike the ADF
   drive's own real-time serving logic which doesn't apply to us.
2. **Size check** is exact-match against the real `.MDV` byte count (TBD,
   see Part 2) instead of Main/Back ROM's 48K/16K.

Two new QNICE devices (`C_DEV_QL_MDV1`/`C_DEV_QL_MDV2`), added to
`C_CRTROMS_MAN` (manual load) and optionally `C_CRTROMS_AUTO` (auto-load
at boot, `OPTIONAL` type, matching Main/Back ROM's own convention) if we
want a fixed-filename boot convenience later - not required for the first
read-only checkpoint, can be manual-only to start.

## Part 4 — wiring into the core

- `main.vhd`: two `mdv` instances (Verilog, instantiated directly from
  VHDL - same cross-language pattern already used for `zx8301`/`zx8302`),
  each with its own HyperRAM-backed `dpram` (Part 1) wired to its own
  `C_HMAP_MDV1`/`C_HMAP_MDV2` base offset (Part 2).
- `sel` on each instance driven by the matching bit of `zx8302.v`'s
  existing `mdv_sel` register (already correct since `M1040`, currently
  unused for anything but the gap-pulse placeholder).
- `zx8302.v`'s single `mdv_gap`/`mdv_tx_empty`/`mdv_rx_ready`/`mdv_byte`
  inputs need to become a 2-way mux (in `main.vhd`, not `zx8302.v` itself)
  selecting whichever drive is currently active in `mdv_sel`, replacing
  the `M1040` gap-pulse placeholder entirely (no longer needed once real
  drives exist - though worth keeping as the *fallback* for when
  `mdv_sel` picks a drive number that isn't mdv1/mdv2, i.e. 3-8, so QDOS's
  own "no medium present" convergence still works for drives we don't
  physically back).
- `reverse` fixed to `1'b0` ("normal") per the earlier chat decision, no
  menu item yet.

## Part 5 — menu / auto-load UX

Matches the user's own earlier mockup:
```
Microdrive
  mdv1:%s
  mdv2:%s
```
Manual load only for this first checkpoint (`C_CRTROMS_MAN`, same
fused status+action single line as Main/Back ROM) - auto-load from a
fixed SD path can follow later once read works and is confirmed on
hardware, mirroring how Main/Back ROM auto-load was added *after* the
manual mechanism was proven.

## Open questions for review

1. **Exact `.MDV` file size** - need to confirm the real byte count from
   an actual QLAY image file (do you have one at hand to check?), to size
   the HyperRAM windows and the size-check FSM precisely.
2. **Arbiter scheme** (round-robin proposed) - any preference, or fine to
   decide during implementation?
3. **Auto-load now or later** - proposed: manual-only for this first
   checkpoint, add auto-load once read is confirmed working on hardware.
4. Anything from this design that doesn't match your own mental model of
   how this should work before I start writing VHDL/Verilog.
