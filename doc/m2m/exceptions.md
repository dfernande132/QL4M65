How to update QL4M65
=====================

The following changes have been made to MiSTer, MiSTer2MEGA65 and QNICE.
As soon as you update one of these modules, make sure you are applying the
changes described here.

MiSTer core QL_MiSTer
----------------------

### Removed the embedded "ipc" instance from `rtl/zx8302.v` - replaced by `ipc.vhd` (the real 8049), not by a hand-rolled protocol

The original `zx8302.v` instantiates `ipc` (an emulation of the QL's real
Intel 8049 IPC microcontroller, itself instantiating `rtl/keyboard.v` +
`rtl/T48/`) directly inside itself, with `comdata`/`comctrl`/`audio`/`ipl`
as purely internal wires never reaching the top level. `zx8302.v` was
modified to:

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
* `comdata_reg`'s reset value is `4'b1111` (idle-high), not the original
  `4'b0000` - the real firmware's own receive loop treats a low line as
  "the CPU wants to talk right now", so an idle-low reset value let it
  misread reset garbage as a spurious transfer request every time. See
  `DECISIONES.md`'s `M1033` section.

**What plugs into those five ports**: `CORE/vhdl/ipc.vhd` - a straight
structural VHDL port of `rtl/ipc.v`. It instantiates `t8049_notri` (from
`CORE/QL_MiSTer/rtl/T48/`, added to the Vivado project **unmodified** - see
below) so the REAL emulated Intel 8049, running the real firmware ROM
(`ipc8049-hermes.hex`), handles the entire comdata/comctrl protocol -
no protocol logic of QL4M65's own. `ipc.vhd`'s ports (`comctrl_o`/
`comdata_i`/`comdata_o`/`audio_o`/`ipl_o`) map straight onto `zx8302.v`'s
`ipc_*_i`/`ipc_*_o` ports with no further translation. `CORE/vhdl/
keyboard.vhd` only does the MEGA65-key -> QL-8x8-matrix translation
(`ql_matrix_o`, same byte/bit layout as `rtl/keyboard.v`'s "matrix") and
feeds `ipc.vhd` directly - it does not touch the IPC link at all. (An
earlier, abandoned attempt at a from-scratch hand-rolled comdata/comctrl
protocol lived in `keyboard.vhd` before this - see `DECISIONES.md`'s
`M1031` section if that history is ever relevant again.)

Files that stay in the repository but excluded from the Vivado compile
list (not deleted, per the project's own convention - see
`doc/m2m/example-file-headers.md`): `rtl/keyboard.v` and `rtl/ipc.v` (their
logic is re-implemented in `CORE/vhdl/keyboard.vhd` and `CORE/vhdl/ipc.vhd`
respectively). `rtl/T48/*` is **not** excluded - all 27 of its VHDL files
are added to the Vivado project, unmodified, via `build_core.tcl` (file
list taken verbatim from `rtl/T48/T8049.qip`, the original project's own
compile list - not guessed). The one T48-adjacent file that stays excluded
is `rtl/rom_t49.vhd` (an Altera `altsyncram` megafunction wizard file, same
class of problem as `dpram.v` below) - replaced by `CORE/vhdl/
ipc_rom_t49.vhd`, a Vivado-clean "rom_t49" entity (same name/ports) backed
by `M2M/vhdl/ram_init.vhd`, loaded from `CORE/vhdl/ipc8049-hermes.rom` (a
flat, one-byte-per-line hex dump of `rtl/ipc8049-hermes.hex` - the
Hermes-patched community firmware, not the plain original).

When updating from a newer upstream `zx8302.v`: re-apply the `ipc`-removal
surgery and the `comdata_reg` reset-value change (find wherever
`ipc ipc (...)` is instantiated, delete it and its private wires, re-expose
the same five signals as ports with the `ipc_*_i`/`ipc_*_o` names above).
`ipc.vhd`/`keyboard.vhd`/`ipc_rom_t49.vhd` don't need to change unless the
ports themselves change. When updating from a newer upstream `rtl/T48/`:
re-run the same "take the file list from `T8049.qip`, exclude
`rom_t49.vhd`" procedure in `build_core.tcl`.

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

### `rtl/zx8302.v` microdrive interface: internal `mdv` instance removed (M1), then re-exposed as an external sibling (Milestone 2 phase A)

**M1 (microdrive not implemented yet):** same problem as `ipc` - `zx8302.v`
instantiated `mdv` (`rtl/mdv.v`) directly, and `mdv.v` itself instantiates
`dpram` (see above) for its own internal buffer, so leaving the `mdv`
instance in place would pull the unsynthesizable `dpram` into the Vivado
build transitively just to sit unused. `mdv_tx_empty`/`mdv_rx_ready`/
`mdv_byte` were tied to a "no drive present" state (`1`/`0`/`0x00`) and
`mdv_gap` got a periodic ~125ms pulse generator instead (load-bearing, not
cosmetic - QDOS's own boot sequence needs a real gap interrupt to converge
to "no medium found" and continue booting; see `DECISIONES.md`'s `M1040`
section for the full investigation).

**Milestone 2 phase A: `mdv` re-instantiated, as an external sibling in
`main.vhd` (not re-embedded inside `zx8302.v`)** - same architectural
pattern already used for `ipc` (see above): `zx8302.v` gained five new
ports (`mdv_sel_o`, `mdv1_gap_i`, `mdv1_tx_empty_i`, `mdv1_rx_ready_i`,
`mdv1_byte_i`) instead of taking `mdv` back as an internal instance.
`mdv_tx_empty`/`mdv_rx_ready`/`mdv_byte`/`mdv_gap` are now muxed: the real
`mdv1_*_i` inputs when `mdv_sel[0]` is set (drive 1 selected), the original
M1 placeholders otherwise (`mdv_sel == 0`, or `mdv_sel` selecting drives
2-8 - phase D territory, not backed yet). The original `mdv_dl_addr`/
`mdv_dl_data`/`mdv_download`/`mdv_dl_wr` input ports (present in the
upstream design, never referenced anywhere inside `zx8302.v` even before
our own changes) stay declared but unused - the loader in `main.vhd`
drives the external `mdv` instance's own `dl_addr`/`dl_data`/`download`/
`dl_wr`/`dl_wr` ports directly instead of routing through `zx8302.v`.
`mdv_sel` (drive selection from `mctrl`) and `led` stay untouched, `mdv_sel`
is now also exposed as `mdv_sel_o` for `main.vhd`'s own use.

`mdv.v` itself is instantiated **unmodified** (same policy as `ipc.vhd`
around the real T48 core) - its own internal `dpram #(17, 88000) vram`
gets a Vivado-clean replacement (`CORE/vhdl/mdv_dpram.vhd`, backed by
`dualport_2clk_ram_byteenable`/BRAM for phase A, matching the module name
exactly so Vivado's mixed-language elaboration resolves it - same pattern
as `ipc_rom_t49.vhd` for the T48 core's `rom_t49`). See
`.research/microdrive-read-design.md` for the full design (loader FSM,
clock-domain crossing via `xpm_cdc_handshake`, phase B/C/D plan).

Files: `rtl/mdv.v` is now added to the Vivado compile list (was excluded
during M1); `rtl/dpram.v` stays excluded (same as always).

**M2007 (temporary): three debug-only output ports** added to investigate
`DIR mdv1_` hanging QDOS completely once a real `.mdv` is loaded and
selected (loading itself works fine as of M2006 - detail in
`DECISIONES.md`'s M2006/M2007 sections). Purely additive, no existing
logic touched: `rtl/zx8301.v` gained `h_cnt_o`/`v_cnt_o` (raw pixel
position, needed to draw an on-screen overlay - same pattern as the M1016
`cpu_addr` debug overlay), `rtl/mdv.v` gained `mdv_present_o`/
`mdv_loaded_o` (its own internal `mdv_present`/`mdv_end!=0` wires exposed
as outputs), `rtl/zx8302.v` gained `gap_irq_o` (its own internal `gap_irq`
register exposed). Remove all three once diagnosed, along with
`main.vhd`'s overlay block.

### The `ipl` assignment in `rtl/zx8302.v` (interrupt lines)

`assign ipl = { ipc_ipl_i[1] || (irq_pending[4:0] != 0), ipc_ipl_i[0] };` -
OR, not AND. Any zx8302-internal pending irq (xint/vsync/gap/intri, see
below) can raise `ipl[1]` on its own, independent of the external ipc. This
matters because `vsync_irq` (the ~50Hz tick the entire QDOS scheduler
depends on) must be able to reach the CPU regardless of what the external
ipc's own `ipl_i` line is doing - AND was tried twice (this project's very
first hang, and again once the real 8049 was wired in) and both times it
silenced `vsync_irq` whenever `ipc_ipl_i` happened to be low (i.e. almost
always), freezing the whole system. See `DECISIONES.md`'s `M1006`/
`M1031`-`M1037` sections for the full investigation.

`main.vhd` currently ties `ipc_ipl_i` to `"00"` (see its own comment on the
`i_zx8302` instantiation) because the real 8049 can assert `ipl_o[1]`
without anything in this port ever completing the exchange that would make
it lower again - with that permanently unconnected, this OR effectively
just passes through `zx8302`'s own internal `irq_pending`.

### New: "interface" interrupt (`intri`, bit1 of `irq_pending`) in `rtl/zx8302.v`

Real QL hardware has an interrupt that fires whenever a data transfer with
the IPC completes (`pc.intri`, per Minerva's own `inc/pc`) - the original
`zx8302.v` never implemented it (hardcoded `1'b0` since this project's very
first port). Added: `intri_irq` fires once `ipc_busy` transitions to idle
(a real comdata/comctrl exchange with the external IPC just completed),
cleared via `irq_ack[1]` (a bit already reserved in the interrupt-ack
register, unused before this). It turned out not to be what was blocking
SuperBASIC's own keyboard read (see `DECISIONES.md`'s `M1038`/`M1039`
sections - the real blocker was the microdrive boot-file search above),
but it is a genuine, previously-missing piece of real hardware behaviour,
kept as a correctness improvement.

MiSTer2MEGA65
-------------

No changes.

QNICE
-----

No changes.
