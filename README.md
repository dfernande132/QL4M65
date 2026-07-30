Sinclair QL for MEGA65 (QL4M65)
===============================

A port of the **Sinclair QL** to the **MEGA65**, built on top of the
[MiSTer2MEGA65](https://github.com/sy2002/MiSTer2MEGA65) (M2M) framework and
based on the [MiSTer-devel/QL_MiSTer](https://github.com/MiSTer-devel/QL_MiSTer)
core (68008/`fx68k` CPU, `zx8301` video ULA, `zx8302` I/O ULA).

**Current status: work in progress, Milestone 1, does not boot to a usable
state yet.** The core synthesizes and runs on real MEGA65 R6 hardware - the
RAM-check pattern (the color noise a real QL shows during its self-test)
appears correctly, proving the CPU is executing genuine Minerva ROM code -
but execution becomes extremely slow shortly afterwards, well before
reaching Minerva's identification screen. Root cause is under active
investigation. See `.research/PORTING-PLAN.md` and `DECISIONES.md` (in the
parent directory) for the full, detailed log of what has been tried so far.

Milestone 1 scope
-----------------

- Native QL CPU speed (no QL/16MHz/24MHz/Full speed switch yet)
- PAL video only
- 128 KB RAM (implemented in FPGA BRAM for now; HyperRAM planned for later)
- Manual system ROM loading (Minerva) via the Shell's Options menu
- Keyboard (MEGA65 keys mapped to the QL's matrix, replacing the real
  hardware's Intel 8049 IPC microcontroller with a MEGA65-native
  translator)

Not yet in scope for Milestone 1: microdrive (`.MDV`), QL-SD (`QXL.WIN`),
mouse, or GoldCard/SMSQ,E support - these are planned for later milestones.

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
