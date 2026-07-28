How to update QL4M65
=====================

The following changes have been made to MiSTer, MiSTer2MEGA65 and QNICE.
As soon as you update one of these modules, make sure you are applying the
changes described here.

MiSTer core QL_MiSTer
----------------------

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

MiSTer2MEGA65
-------------

No changes.

QNICE
-----

No changes.
