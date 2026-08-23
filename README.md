Sinclair QL for MEGA65 (QL4M65)
===============================

A port of the **Sinclair QL** to the **MEGA65**, built on top of the
[MiSTer2MEGA65](https://github.com/sy2002/MiSTer2MEGA65) (M2M) framework and
based on the [MiSTer-devel/QL_MiSTer](https://github.com/MiSTer-devel/QL_MiSTer)
core (68008/`fx68k` CPU, `zx8301` video ULA, `zx8302` I/O ULA).

**Current status: Milestone 1 complete. Milestone 2 (two independent
microdrives, HyperRAM-backed, full read/write with automatic SD write-back)
complete.**
The QL boots end-to-end on real MEGA65 R6 hardware: RAM check, boot logo,
F1-F4 screen, 10-second timeout (or F1/F2/F5 response), and into SuperBASIC
with a working keyboard - both Minerva and MGE tested. System ROM loads
either automatically from a fixed SD card path at boot or manually via the
Shell's Options menu, with the core auto-resetting itself after any manual
ROM change. On top of that, **two independent microdrives** (`mdv1_`,
`mdv2_`) can each be loaded from a `.MDV` image via the Shell's Options menu
and both read and written by QDOS/Minerva - `DIR mdv1_`/`LRUN mdv1_xxx`
(sustained, continuous reads of full-size programs) and `SAVE
mdv1_xxx`/reload round-trips both tested working on real hardware for both
units independently, **and those writes are saved back to each drive's own
`.mdv` file automatically, in the background, with no menu interaction
required** - each drive's activity LED turns blue whenever there are
unsaved changes and back to red once they've been written out, so a power
cycle no longer discards anything. Both drives' image buffers live in real
HyperRAM (not FPGA BRAM), sharing the physical chip through a small
round-robin arbiter. See `.research/PORTING-PLAN.md` and `DECISIONES.md`
(in the parent directory) for the full, detailed log of the whole
investigation and every decision made along the way - the microdrive read
path, the write path, the HyperRAM migration, and the second unit each took
genuinely instructive debugging journeys (see the "Microdrive image format"
note below for the read-side headline lesson).

Next up, Milestone 3: memory expansion (640 KB / 4096 KB) and CPU speed
switching (16 MHz / 24 MHz / Full), both already present in the original
core as multiples of the base clock - see `.research/PORTING-PLAN.md`
section 7 for the current milestone order and scope.

Milestone 1 scope
-----------------

- Native QL CPU speed (no QL/16MHz/24MHz/Full speed switch yet)
- PAL video only
- 128 KB RAM (implemented in FPGA BRAM for now; HyperRAM planned for a later
  milestone)
- System ROM: **Main ROM** (48 KB - Minerva, MGE, JS...) and **Back ROM**
  (16 KB - TK2, Pascal...) as two independent, fixed-size slots. Each
  auto-loads at boot from a fixed SD card path (`/ql4m65/main.rom` /
  `/ql4m65/back.rom`, both optional) and can also be changed at any time via
  the Shell's Options menu ("Main ROM:%s" / "Back ROM:%s" / "Extract Back
  ROM" to clear the Back ROM slot) - the core resets itself automatically
  after any manual change, no hard reset needed.
- Keyboard: MEGA65 keys mapped to the QL's matrix (replacing the real
  hardware's Intel 8049 IPC microcontroller with a real emulated one running
  the real community-patched firmware, `ipc.vhd`), using a deliberately
  MEGA65-native symbol layout - whatever's silkscreened on a MEGA65 key is
  what it types on the QL, not necessarily what the real Sinclair QL
  keyboard has in that position. Full key-by-key rationale in
  `.research/keyboard-mapping-design.md`.

Not yet in scope for Milestone 1: microdrive (`.MDV`, now underway as
Milestone 2, see below), QL-SD (`QXL.WIN`), memory/CPU-speed expansion,
mouse, or GoldCard/SMSQ,E support - these are planned for later milestones
(see `.research/PORTING-PLAN.md` section 7 for the current milestone
order).

Milestone 2 scope (complete)
-----------------------------

- **Microdrive, phase A: one drive, read-only.** Load a `.MDV` image
  (QLAY format, exactly 174930 bytes) as `mdv1_` via the Shell's Options
  menu; `DIR mdv1_` and `LRUN mdv1_xxx` both work reliably, including full,
  sustained reads of real programs. `mdv.v` (the microdrive controller
  itself) is unmodified upstream MiSTer-devel code, faithfully emulating
  real 1984 microdrive hardware bit-serially at 200 kbit/s.
- **Microdrive, phase B: full read/write, saved back to the SD card
  automatically.** `SAVE mdv1_xxx` followed by `DIR mdv1_` and `LOAD
  mdv1_xxx` round-trips correctly on real hardware, verified by
  QDOS/Minerva's own write-then-verify logic. Dirty sectors are flushed
  back to the `.mdv` file on the SD card **in the background, with no menu
  interaction** - no "Save" menu item to remember to use - and survive a
  full power cycle; verified with `Fase0/tools/mdvcheck.py` reporting 0
  checksum failures on the saved-and-reloaded image. The MEGA65's
  drive-activity LED turns blue while there are unsaved sectors and back to
  red once they're written out, so it's obvious when it's safe to power
  off. (A physical reset button press or an abrupt power loss still doesn't
  run any firmware, so writes from the last moment before that can still be
  lost - the same accepted limitation vdrives-based cores and other M2M
  ports with background write-back share.)
- **Microdrive, phase C: migrated from FPGA BRAM to real HyperRAM.** Same
  read/write/SD-write-back behaviour as phase B, now backed by the MEGA65's
  actual HyperRAM chip through a small write-through cache, freeing up BRAM
  for future use and paving the way for more than one drive.
- **Second microdrive (`mdv2_`): fully independent, same feature set as
  `mdv1_`.** Both drives share the physical HyperRAM through a round-robin
  arbiter and can be loaded, read, written, and saved independently -
  writing to one never affects the other. The QNICE-side loading/read-back
  mechanism is a single, generic VHDL component instantiated twice, rather
  than two separate hand-written copies.
- Each drive has its own activity LED (blue while dirty, red once saved)
  and its own synthesized motor hum while selected.

### Microdrive image format: it must be a genuinely valid QLAY `.mdv`

QDOS/Minerva validates every microdrive sector against a real checksum as it
reads it - just like it would on real hardware. This port's `mdv.v` emulates
the microdrive at the same low, bit-serial level real hardware used, so it's
just as strict as the real thing: **if a `.MDV` image's checksums don't
match its data, QDOS will refuse to read it**, exactly as a real QL would
reject a damaged cartridge. This bit us hard during development - several
downloaded/re-authored test images turned out to have corrupted sector or
block-header checksums (usually because whatever tool wrote a file onto a
blank image never recalculated the checksum for the header it overwrote),
which looked for a long time like a hardware/timing bug because higher-level
emulators (that model the microdrive as a filesystem, or intercept QDOS's
own calls, rather than emulating the real bit-serial protocol) never
noticed the corruption and loaded the same files without complaint.

If a `.MDV` doesn't load - `DIR` never finishing, or a `LRUN`'d program
hanging partway through - **check the image before suspecting the core**:
`Fase0/tools/mdvcheck.py` (not in this repository) validates every sector's
checksums against the real Minerva algorithm and reports exactly where a
`.mdv` is broken; `mdvrepair.py` can fix checksum-only corruption without
touching any data. See `DECISIONES.md`'s microdrive sections for the full
story.

Getting the compiled core
--------------------------

This repository is source only - no compiled QL4M65 `.cor` file is
committed here. (The only `.cor` files tracked in this repo are unrelated
QNICE-FPGA demo bitstreams bundled with the M2M framework's own
`M2M/QNICE/dist_kit/`, not the QL4M65 core itself.)
Ready-to-use `.cor` files for MEGA65 **R6** (tested on real hardware) and
**R3** (compiles clean, not yet tested on real R3 hardware - see the
release notes), together with a Minerva system ROM, are published on the
[GitHub Releases page](https://github.com/dfernande132/QL4M65/releases) - see the instructions file bundled
with each release for exactly where each file goes on the SD card. Minerva
and TK2 are GPL/GNU-licensed and can be redistributed, which is why they're
included; other QL ROMs (MGE, JS, ...) are not, since their licensing is
unclear or restrictive - for those, see the
[Sinclair QL ROM archive](https://sinclairql.net/djw/qlrom/index.html),
which has the full set. The
[MEGA65 community on Discord](https://discord.com/channels/719326990221574164/1177364456896999485)
is also a good place to ask if you're missing something. Building the core
yourself from source requires your own copy of a QL system ROM placed on
the SD card (see Milestone 1 scope above).

Repository layout
------------------

- `CORE/vhdl/` - the actual QL4M65 port (clock generation, memory map, video/
  keyboard wiring, Shell configuration)
- `CORE/QL_MiSTer/` - git submodule, the MiSTer QL core (mostly unmodified;
  see `doc/m2m/exceptions.md` for the handful of deliberate changes and why)
- `M2M/` - the MiSTer2MEGA65 framework itself (one deliberate, documented
  exception - a small hook in `shell.asm` needed for mdv1's background SD
  write-back, since it's not a vdrive; see `doc/m2m/exceptions.md`)
- `.research/PORTING-PLAN.md` - the porting dossier and hardware-test log
  (every tested build, what changed, what happened)
- `DECISIONES.md` (parent directory) - chronological log of every technical
  decision and diagnosis made during this port, in Spanish

Credits
-------

- QL4M65 port by Jose Daniel Fernandez Santos ([dfsantos](https://github.com/dfernande132))
- MiSTer2MEGA65 framework by sy2002 and MJoergen
- MiSTer-devel/QL_MiSTer core by the MiSTer QL community

Licensed under GPL v3.

---

Built on the [MiSTer2MEGA65](https://github.com/sy2002/MiSTer2MEGA65)
framework - learn more about M2M itself via
[The Ultimate MiSTer2MEGA65 Porting Guide](https://github.com/sy2002/MiSTer2MEGA65/wiki/The-Ultimate-MiSTer2MEGA65-Porting-Guide)
or the [friendly MEGA65 community on Discord](https://discord.com/channels/719326990221574164/1177364456896999485).
