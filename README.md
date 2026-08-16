Sinclair QL for MEGA65 (QL4M65)
===============================

A port of the **Sinclair QL** to the **MEGA65**, built on top of the
[MiSTer2MEGA65](https://github.com/sy2002/MiSTer2MEGA65) (M2M) framework and
based on the [MiSTer-devel/QL_MiSTer](https://github.com/MiSTer-devel/QL_MiSTer)
core (68008/`fx68k` CPU, `zx8301` video ULA, `zx8302` I/O ULA).

**Current status: Milestone 1 complete. Milestone 2 in progress - microdrive
read (phase A) and write (phase B, etapa 1) both working.** The QL boots
end-to-end on real MEGA65 R6 hardware: RAM check, boot logo, F1-F4 screen,
10-second timeout (or F1/F2/F5 response), and into SuperBASIC with a working
keyboard - both Minerva and MGE tested. System ROM loads either
automatically from a fixed SD card path at boot or manually via the Shell's
Options menu, with the core auto-resetting itself after any manual ROM
change. On top of that, a single microdrive (`mdv1_`) can be loaded from a
`.MDV` image via the Shell's Options menu and both read and written by
QDOS/Minerva - `DIR mdv1_`/`LRUN mdv1_xxx` (sustained, continuous reads of
full-size programs) and `SAVE mdv1_xxx`/reload round-trips both tested
working on real hardware. See `.research/PORTING-PLAN.md` and
`DECISIONES.md` (in the parent directory) for the full, detailed log of the
whole investigation and every decision made along the way - both the
microdrive read path and the write path took long, genuinely instructive
debugging journeys (see the "Microdrive image format" note below for the
read-side headline lesson).

Milestone 2 continues towards: persisting microdrive writes back to the SD
card's `.mdv` file (currently they only live in the FPGA's own buffer until
reload), moving the microdrive buffer from BRAM to HyperRAM, expanding from
1 to up to 4 simultaneous microdrives, memory expansion (640 KB / 4096 KB),
and CPU speed switching (16 MHz / 24 MHz / Full) - see
`.research/PORTING-PLAN.md` section 7 for the current milestone order and
scope of each remaining phase.

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

Milestone 2 scope (in progress)
--------------------------------

- **Microdrive, phase A (done): one drive, read-only.** Load a `.MDV` image
  (QLAY format, exactly 174930 bytes) as `mdv1_` via the Shell's Options
  menu; `DIR mdv1_` and `LRUN mdv1_xxx` both work reliably, including full,
  sustained reads of real programs. `mdv.v` (the microdrive controller
  itself) is unmodified upstream MiSTer-devel code, faithfully emulating
  real 1984 microdrive hardware bit-serially at 200 kbit/s.
- **Microdrive, phase B, etapa 1 (done): write support (`SAVE`) on an
  already-formatted cartridge.** `SAVE mdv1_xxx` followed by `DIR mdv1_` and
  `LOAD mdv1_xxx` round-trips correctly on real hardware, verified by
  QDOS/Minerva's own write-then-verify logic. Writes only land in the FPGA's
  own buffer for now - persisting them back to the SD card's `.mdv` file is
  the next etapa, not implemented yet, so a reload or power cycle discards
  anything written since the image was last loaded.
- Still to come: persisting writes to the SD card, moving the microdrive
  buffer to HyperRAM, expanding to 2-4 simultaneous drives, memory
  expansion, CPU speed switching.

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

This repository is source only - no compiled `.cor` file is committed here.
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
- `M2M/` - the MiSTer2MEGA65 framework itself (not modified)
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
