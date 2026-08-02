Sinclair QL for MEGA65 (QL4M65)
===============================

A port of the **Sinclair QL** to the **MEGA65**, built on top of the
[MiSTer2MEGA65](https://github.com/sy2002/MiSTer2MEGA65) (M2M) framework and
based on the [MiSTer-devel/QL_MiSTer](https://github.com/MiSTer-devel/QL_MiSTer)
core (68008/`fx68k` CPU, `zx8301` video ULA, `zx8302` I/O ULA).

**Current status: Milestone 1 complete.** The QL boots end-to-end on real
MEGA65 R6 hardware: RAM check, boot logo, F1-F4 screen, 10-second timeout
(or F1/F2/F5 response), and into SuperBASIC with a working keyboard - both
Minerva and MGE tested. System ROM loads either automatically from a fixed
SD card path at boot or manually via the Shell's Options menu, with the core
auto-resetting itself after any manual ROM change. See
`.research/PORTING-PLAN.md` and `DECISIONES.md` (in the parent directory)
for the full, detailed log of the whole investigation and every decision
made along the way.

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

Not yet in scope for Milestone 1: microdrive (`.MDV`, planned as Milestone
2), QL-SD (`QXL.WIN`), memory/CPU-speed expansion, mouse, or
GoldCard/SMSQ,E support - these are planned for later milestones (see
`.research/PORTING-PLAN.md` section 7 for the current milestone order).

Getting the compiled core
--------------------------

This repository is source only - no compiled `.cor` file and no system ROM
(Minerva/MGE/JS are copyrighted Sinclair/AMS software, not redistributable
here). A ready-to-use Milestone 1 `.cor` for MEGA65 R6 is available in the
[MEGA65 community on Discord](https://discord.com/channels/719326990221574164/1177364456896999485)
- ask there if you'd like a copy. Building it yourself from source requires
your own copy of a QL system ROM placed on the SD card (see Milestone 1
scope above).

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
