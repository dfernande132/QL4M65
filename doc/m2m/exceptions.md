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

`mdv.v` itself is instantiated **unmodified through Milestone 2 phase A**
(same policy as `ipc.vhd` around the real T48 core) - see the M2022 section
below for its first real modification, once write support (phase B)
started. Its own internal `dpram #(17, 88000) vram`
gets a Vivado-clean replacement (`CORE/vhdl/mdv_dpram.vhd`, backed by
`dualport_2clk_ram_byteenable`/BRAM for phase A, matching the module name
exactly so Vivado's mixed-language elaboration resolves it - same pattern
as `ipc_rom_t49.vhd` for the T48 core's `rom_t49`). See
`.research/microdrive-read-design.md` for the full design (loader FSM,
clock-domain crossing via `xpm_cdc_handshake`, phase B/C/D plan).

Files: `rtl/mdv.v` is now added to the Vivado compile list (was excluded
during M1); `rtl/dpram.v` stays excluded (same as always).

**M2007-M2010 (temporary, removed in M2011): on-screen debug overlay.**
Added four debug-only output ports (`rtl/zx8301.v`'s `h_cnt_o`/`v_cnt_o`,
`rtl/mdv.v`'s `mdv_present_o`/`mdv_loaded_o`/`mem_addr_o`, `rtl/zx8302.v`'s
`gap_irq_o`) and an on-screen status-box overlay in `main.vhd` to
investigate `DIR mdv1_` hanging/misreading once a real `.mdv` was loaded.
The overlay itself never pinpointed the root cause (mem_addr turned out to
free-run constantly regardless of health, so its "MOVING" box wasn't
diagnostic); the actual bug (see M2011 below and `DECISIONES.md`) was
found by comparing this port's loader architecture against the original
MiSTer platform and sibling M2M cores (C64MEGA65, AExp), not from the
overlay's readings. All four ports and the overlay block were removed in
M2011 once the real fix landed.

**M2011: `mdv1_download` fixed from a one-cycle pulse to a level held for
the whole transfer**, matching the original core's `ioctl_download`
semantics (`QL.sv:534,582`). `rtl/mdv.v`'s own `if(ce)` block that advances
`mem_addr` is unconditional - not gated by `sel` or by whether the buffer
is fully written - so a single-cycle `download` pulse let `mem_addr` free-run
through the same dual-port BRAM the QNICE loader was still writing, a
genuine unsynchronized read/write race (worse yet exposed early to QDOS
whenever `mdv_sel` - itself never reset - was already `'1'` from an earlier
session). Fixed in `main.vhd` by deriving `mdv1_download` from a new
`qnice_mdv1_loading_i` port (driven by `mega65.vhd` from
`mdv1_req_status = C_CSR_REQ_LDNG`, the same flag `shell.asm`/
`crts-and-roms.asm` use to track an in-progress vs. completed load),
synchronized into `clk_main_i` with a plain 2-FF synchronizer (sufficient
for a single level signal, unlike the word-at-a-time loader data which
needs the full `xpm_cdc_handshake`). `mdv.v` itself remains unmodified as
of M2011 (see M2022 below for its first real modification).

### Milestone 2 phase B (M2022): `rtl/mdv.v` write channel - first modification of `mdv.v` itself

Everything above this point left `mdv.v` byte-for-byte identical to
upstream (confirmed against `MiSTer-devel/QL_MiSTer` master - see
`.research/microdrive-write-recon.md` section 1). `SAVE` support broke that
streak: `mdv.v` gained a real write channel.

New ports: `wr_en` (level, `mctrl[2]`/`pc..writ`, already routed through
`zx8302.v`), `wr_strobe` (1-cycle-of-`clk` pulse per byte written to
`$18022`), `wr_data[7:0]`, `sector[7:0]` (output - which physical 686-byte
sector is under the "head" right now, 0..254), `wr_commit` (output, 1-cycle
pulse per confirmed 16-bit word), `dl_q[15:0]` (output - read-back of the
buffer's port A, for the eventual QNICE-side flush).

Design principle (`.research/microdrive-write-design.md`): writing is the
positional mirror of reading. Each incoming 16-bit word is written to
`region_base + word_index`, where `region_base` is `mem_addr` captured
continuously while the last gap was active (`mem_addr` doesn't advance
during a gap, so it's already the address of the region that's about to
start) - never derived from whenever the byte happens to arrive in real
time. Recon phase found the CPU's write timing lands the first byte
~11 words *into* the data region if taken at face value (`.research/
microdrive-write-recon.md` section 5), which is exactly why the anchor has
to be structural, not temporal. `tx_empty` stays hardcoded `1'b0` (never
signals "buffer full") on purpose: since writes are positional rather than
real-time, nothing is lost by letting the CPU run ahead of the tape's own
timing, and a real level-based `txfl` would add real complexity for zero
benefit in this MVP.

Port A of the internal `dpram` (`mdv_dpram.vhd`) is now a priority mux:
write-confirmation (`wr_do`) beats the QNICE loader/flush
(`dl_wr`/`dl_addr`/`dl_data`) - in practice they never collide during a
load (load and playback are mutually exclusive), but a flush can genuinely
overlap with a live write from the QL, and losing a flush cycle (QNICE
retries, it's just waiting) is preferable to losing a word the QL actually
wrote. `mdv_dpram.vhd`'s `dpram` entity gained the `q_a` output port
(previously `a_q_o => open`, nothing ever needed to read port A back) to
support this.

`sector` assumes `reverse = '0'` (true in this port today - see
`main.vhd`'s `i_mdv1` instantiation); it counts gap-to-gap regions in
playback order, which only matches physical sector order when the tape
isn't being replayed backwards.

Etapa 1 (`M2022`, fixed in `M2023` - see below) only wires the RTL path end
to end - no dirty-sector bitmap, no QNICE-side flush yet (see
`.research/microdrive-write-design.md` section 8 for the design's original
4-stage rollout sketch; actual build numbers drift from that sketch
whenever a stage needs more than one hardware-tested build, same as
happened repeatedly during phase A - `DECISIONES.md` has the real sequence).

**`M2023`: `wr_strobe` needs its own edge detection inside `mdv.v` too, not
just in `zx8302.v`.** `M2022` compiled clean and passed the read-regression
battery on real hardware, but `SAVE` never terminated - QDOS retries data
blocks without limit, so a `SAVE` that never returns is the signature of a
verify-after-write mismatch. Root cause: `mdv1_wr_strobe` is generated
inside `zx8302.v`'s `cen`-gated block (`cen` is the ~7.5MHz CPU bus enable,
not `clk` itself) - once set, the register holds its value at full `clk`
rate (84MHz) until the *next* `cen` tick, roughly 11 `clk` cycles later.
`mdv.v`'s own write accumulator samples `wr_strobe` in a plain
`always @(posedge clk)`, **not gated by `ce`** (unlike the rest of `mdv.v`'s
read state machine, which is `if(ce) begin ... end` throughout and never
had this problem) - so without its own edge detection, it counted roughly
11 bytes for every real byte the CPU wrote, corrupting the word-index
mapping from the very first byte. Same class of bug as "risk R1" in the
design doc, one level deeper than the edge detection already added in
`zx8302.v` for that risk. Fixed with the identical pattern one level in:
a registered `wr_strobe_prev`, advancing the accumulator only on
`wr_strobe && !wr_strobe_prev`.

### `rtl/zx8302.v`: `pc_tdata` ($18022) write decoding (Milestone 2 phase B, M2022)

`$18022` (`pc_tdata`, the microdrive transmit-data register) was never
decoded before - writes to it were silently dropped since the very first
port. Added: `mdv_wr_data_o`/`mdv_wr_strobe_o` (byte + strobe, decoded from
`cpu_addr == 2'b11` with `cpu_uds`, the same address-decode pattern already
used for `mctrl`/`pc_intr`) and `mdv_wr_en_o`/`mdv_er_en_o` (`mctrl[2]`/
`mctrl[3]`, `pc..writ`/`pc..eras` - already captured into `mctrl` but never
exposed before).

Edge detection is mandatory here and easy to get wrong: a single 68000
`move.b` holds `cpu_sel`/`cpu_wr`/`cpu_uds`/`cpu_addr` stable across
several `cen` ticks (one bus cycle spans several ticks of the bus clock
enable), so gating the strobe purely on those conditions would fire
multiple pulses - and write duplicate bytes into the microdrive buffer -
for every single write instruction. Fixed with a registered
`prev_mdv_wr_sel` and pulsing only on its rising edge, inside the same
`cen`-gated always block that already handles `mctrl` (see
`.research/microdrive-write-design.md` section 4.2 and its "risk R1").

`pc_tctrl` ($18002) is still not decoded - out of scope until/unless a
serial port is ever implemented (it would be needed to disambiguate
`pc_tdata`'s two possible destinations). Noted here so nobody assumes it
already exists.

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
