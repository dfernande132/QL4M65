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

### `sys/sd_card.sv` - internal `altsyncram` ("sdbuf") replaced by an externally-instantiated `dualport_2clk_ram` (Milestone 2, QL-SD)

Same class of problem as `dpram.v` above: `sd_card.sv`'s internal `sdbuf`
RAM is an `altsyncram` instance (Quartus-only, doesn't synthesize in
Vivado), and `sd_card.sv` itself is stock MiSTer framework code shared
across many cores (not QL-specific), so QL4M65 keeps it unmodified as far
as possible rather than rewriting its logic.

The `altsyncram sdbuf (...)` instance and its `defparam` block were
removed and replaced by eight new top-level ports (`ram_a_addr_o`/
`ram_a_data_o`/`ram_a_wren_o`/`ram_a_q_i` for the `clk_sys`-side port,
`ram_b_addr_o`/`ram_b_data_o`/`ram_b_wren_o`/`ram_b_q_i` for the
`clk_spi`-side port) - the same "expose ports, instantiate the Vivado-clean
replacement as a sibling" surgery already used for `zx8302.v`'s `ipc`/`mdv`
removal, rather than trying to instantiate a VHDL entity directly from
inside this Verilog module. `main.vhd` instantiates a `dualport_2clk_ram`
(`ADDR_WIDTH => 11`, `DATA_WIDTH => 8`) wired to those eight ports, with
`clock_a => qnice_clk_i`, `clock_b => ` the core clock.

**Requires instantiating `sd_card` with `WIDE(0)`, not `WIDE(1)` like the
original `QL.sv` does.** `WIDE` only affects the `clk_sys`-side address/data
width (`AW`/`DW` localparams); with `WIDE(0)`, both RAM ports end up
genuinely 8 bits wide (`numwords=2048`/`widthad=11` on both sides), which is
what makes a single symmetric `dualport_2clk_ram` a clean fit and also
matches `M2M/vhdl/vdrives.vhd`'s own fixed 8-bit `sd_buff_*` ports
(`vdrives.vhd:104`, `constant DW: natural := 7`). The SPI-facing side
(`clk_spi`, talking to `qlromext.v`) is unaffected either way. See
`.research/qlsd-design.md` for the full reasoning - this project's local
reference cores (AExp, C64MEGA65) don't actually pair `sd_card.sv` with
`vdrives.vhd`, so there was no existing wiring to copy.

When updating from a newer upstream `sd_card.sv`: re-apply the same
surgery (remove `altsyncram sdbuf (...)` + `defparam`, re-expose the same
eight `ram_a_*`/`ram_b_*` ports, keep instantiating with `WIDE(0)`).

### Removed the embedded "mdv" (microdrive) instance from `rtl/zx8302.v` - but `mdv_gap` is NOT just tied off

Same problem as `ipc`: `zx8302.v` instantiates `mdv` (`rtl/mdv.v`)
directly, and `mdv.v` itself instantiates `dpram` (see above) for its own
internal buffer - so even though no milestone implements real microdrive
storage, leaving the `mdv` instance in place would pull the unsynthesizable
`dpram` into the Vivado build transitively, just to sit unused.

`mdv_tx_empty`/`mdv_rx_ready`/`mdv_byte` are tied to a "no drive present"
state (`1`/`0`/`0x00`) instead of instantiating `mdv` - genuinely unused,
milestone 3 territory. **`mdv_gap` is different and NOT just tied off**:
it generates a periodic ~125ms pulse whenever any microdrive is selected
(`mdv_sel != 0`). This is load-bearing, not cosmetic: QDOS's own boot
sequence (any ROM - Minerva, MGE) looks for a boot file on `mdv1_` right
after the F1-F4 screen resolves, and the code path that detects "no medium
present" and lets boot continue can ONLY be reached via a real gap
interrupt - with `mdv_gap` permanently low, that interrupt never fires
even once and QDOS hangs forever waiting for it. QDOS's own downstream
polling loops already have generous (~0.5s) software timeouts and converge
cleanly to "no medium found" on their own once the chain is started - see
`DECISIONES.md`'s `M1040` section for the full investigation (confirmed
byte-for-byte against both a real ROM disassembly and Minerva's GPL
source).

`mdv_sel` (drive selection from `mctrl`) and `led` are untouched.

When milestone 3 (microdrive) is implemented: re-instantiate `mdv`, and
give it a Vivado-clean `dpram` (same treatment `ql_rom`/`vram` already
got - see `DECISIONES.md` Anexo A) rather than trying to synthesize the
original `dpram.v` - and reconsider whether the `mdv_gap` pulse generator
above is still needed once real gap-detection timing exists.

Files that stay in the repository but are excluded from the Vivado
compile list because of this (not deleted): `rtl/mdv.v`.

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
