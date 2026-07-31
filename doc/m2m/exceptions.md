How to update QL4M65
=====================

The following changes have been made to MiSTer, MiSTer2MEGA65 and QNICE.
As soon as you update one of these modules, make sure you are applying the
changes described here.

MiSTer core QL_MiSTer
----------------------

### TEMPORARY (M1016, re-added after being removed in M1015): `rtl/zx8301.v` exposes `h_cnt_o`/`v_cnt_o` again

M1007-M1014 used a temporary on-screen hex readout to diagnose a
reproducible post-RAM-test "hang". That investigation concluded (see
`DECISIONES.md`, "LA CAUSA REAL DEL CUELGUE/LENTITUD"): the ROM buffer was
simply never being loaded (the manual "ROM:%s" OSD menu load is required
every time), so the CPU was executing a blank buffer. With Minerva actually
loaded, the core boots at normal speed - the overlay was removed in M1015.

New problem found right after (M1015 hardware test): with Minerva (or an
original QL ROM, "mge") properly loaded, the boot reaches the splash logo
and then stalls - the F1/F2 info screen that should appear ~1 second later
on real hardware never shows, and the keyboard doesn't respond at all. Both
ROMs stall at the same point, hinting at a common IPC/hardware dependency
rather than a per-ROM bug. Re-added a minimal (6-digit, cpu_addr only, no
bus-rate/seconds/PC-verify counters this time - those already answered
their M1007-M1014 questions) version of the same overlay technique to see
empirically whether the CPU is stuck in a narrow polling loop and, if so,
where.

**Revert again once diagnosed**: remove `h_cnt_o`/`v_cnt_o` from
`zx8301.v`, and the "QL4M65 TEMPORARY DEBUG AID (M1016)" block in
`main.vhd` (signal declarations, the `i_dbg_font` instance, the
`video_red_o`/`green_o`/`blue_o` overlay logic, and the `h_cnt_o`/`v_cnt_o`
port map entries on `i_zx8301`).

### Removed the embedded "ipc" instance from `rtl/zx8302.v`

The original `zx8302.v` instantiates `ipc` (an emulation of the QL's real
Intel 8049 IPC microcontroller, itself instantiating `rtl/keyboard.v` +
`rtl/T48/`) directly inside itself, with `comdata`/`comctrl`/`audio`/`ipl`
as purely internal wires never reaching the top level.

QL4M65 replaces the whole `keyboard.v + ipc.v + rtl/T48/` chain with a
MEGA65-native `keyboard.vhd` that speaks the `comdata`/`comctrl` protocol
directly (same architectural choice as C64MEGA65's CIA1 keyboard matrix and
AExp's CIA-A keyboard protocol - see `CoreQL/.research/PORTING-PLAN.md`,
decision #2). For `keyboard.vhd` to plug in as a sibling instance in
`main.vhd` instead of a child of `zx8302`, `zx8302.v` was modified to:

* Remove the internal `ipc ipc (...)` instantiation and its associated wire
  declarations (`ipc_comctrl`, `ipc_comdata_out`, `ipc_ipl`).
* Remove the `js0`/`js1`/`ps2_key` ports (only used by the removed `ipc`'s
  internal `keyboard.v`, for PS/2 and joystick-as-keys input - not needed
  since M2M's own keyboard interface replaces this entirely).
* Add five new top-level ports: `ipc_comctrl_i` (in), `ipc_comdata_o` (out,
  this chip's own outgoing bit), `ipc_comdata_i` (in, the external IPC's
  outgoing bit), `ipc_ipl_i` (in, 2 bits), `ipc_audio_i` (in). `audio` is
  still a top-level output, now driven by `assign audio = ipc_audio_i;`
  instead of being wired straight through from the removed `ipc` instance.

When updating from a newer upstream `zx8302.v`, re-apply this same
surgery: find wherever `ipc ipc (...)` is instantiated, delete it and its
private wires, and re-expose the same five signals as ports with the
`ipc_*_i`/`ipc_*_o` names above so `main.vhd`'s wiring to `keyboard.vhd`
doesn't need to change.

Files that stay in the repository but are excluded from the Vivado
compile list because of this (not deleted, per the project's own
convention - see `doc/m2m/example-file-headers.md`): `rtl/keyboard.v`,
`rtl/ipc.v`, `rtl/T48/*`.

### `rtl/dpram.v` / `rtl/mgc_rom/mgc_rom.v` - not modified, not used

These wrap the Quartus/Intel-specific `altsyncram` primitive and don't
synthesize in Vivado as-is. Rather than rewriting them, QL4M65 doesn't
instantiate them at all: `ql_rom` and `vram` (the only two places the
original core used `dpram`, both inside `QL.sv` which isn't ported) are
built directly in `mega65.vhd`/`main.vhd` using the MiSTer2MEGA65
framework's own `dualport_2clk_ram` (see `DECISIONES.md`, Anexo A, for the
full reasoning and the AExp reference pattern this follows).
`mgc_rom.v` is GoldCard boot ROM support, out of scope until GoldCard
itself is implemented (not part of any of the three defined milestones
yet).

### Removed the embedded "mdv" (microdrive) instance from `rtl/zx8302.v`

Same problem as `ipc`, found the hard way: `zx8302.v` instantiates `mdv`
(`rtl/mdv.v`) directly, and `mdv.v` itself instantiates `dpram` (see above)
for its own internal buffer - so even though milestone 1 doesn't use
microdrive at all, leaving the `mdv` instance in place would pull the
unsynthesizable `dpram` into the Vivado build transitively, just to sit
unused.

Tied `mdv_gap`/`mdv_tx_empty`/`mdv_rx_ready`/`mdv_byte` to a "no drive
present" state (`0`/`1`/`0`/`0x00`) instead of instantiating `mdv`.
`mdv_sel` (drive selection from `mctrl`) and `led` are untouched - harmless
without a real drive behind them.

When milestone 3 (microdrive) is implemented: re-instantiate `mdv`, and
give it a Vivado-clean `dpram` (same treatment `ql_rom`/`vram` already
got - see `DECISIONES.md` Anexo A) rather than trying to synthesize the
original `dpram.v`.

Files that stay in the repository but are excluded from the Vivado
compile list because of this (not deleted): `rtl/mdv.v`.

### Fixed the `ipl` assignment in `rtl/zx8302.v` (interrupt lines)

`assign ipl = { ipc_ipl_i[1] && (irq_pending[4:0] == 0), ipc_ipl_i[0] };`
ANDs the external ipc's `ipl[1]` line with "no irq pending" - the opposite
of its own comment ("any pending irq raises ipl to 2"). With the real
embedded `ipc` (removed, see above), `ipc_ipl_i[1]` apparently defaulted
high whenever the ipc had nothing else to report, so this acted as a
defensive clamp against a genuine ipc signal. QL4M65's external stand-in
(`keyboard.vhd`) never implements the real ipc's serial poll-and-relay
protocol for zx8302's own interrupts (only its own keyboard commands 8/9),
so it permanently drives `ipc_ipl_i` to `"00"` - meaning this line silenced
`ipl[1]` unconditionally, including `zx8302`'s own `vsync_irq` (the ~50Hz
frame interrupt Minerva/QDOS's scheduler depends on). Root-caused as the
leading suspect for the reproducible post-RAM-test hang seen in every
M1001-M1005 hardware test (see `DECISIONES.md`).

Changed the operator to OR + not-equal:
`assign ipl = { ipc_ipl_i[1] || (irq_pending[4:0] != 0), ipc_ipl_i[0] };`
so any zx8302-internal pending irq (xint/vsync/gap) can raise `ipl[1]` on
its own, independent of the external ipc - matching the comment's literal
intent. When updating from a newer upstream `zx8302.v`, re-apply this same
one-line change if the `ipc`-removal surgery above is also re-applied
(the external `ipc_ipl_i` port only exists because of that surgery).

MiSTer2MEGA65
-------------

No changes.

QNICE
-----

No changes.
