# Changelog

All notable changes to QL4M65 (CoreQL) are documented here, milestone by
milestone. For a full technical/design log (in Spanish) see
`DECISIONES.md` and `.research/PORTING-PLAN.md`.

## Milestone 2 - Phase A: Microdrive support (read-only) - in progress

- **M2021** - lowered the microdrive motor hum's pitch (~200Hz -> ~100Hz)
  and volume, per hardware listening tests.
- **M2020** - gated the motor hum on real header/gap/data activity
  instead of a flat continuous tone while a drive is selected, so it
  follows the microdrive's actual timing.
- **M2019** - added a synthesized microdrive motor hum, mixed into the
  existing beeper audio path.
- **M2018** - real fix for the microdrive read timing margin: QL I/O
  accesses (`zx8302` range) no longer wait on the video-contention
  model that only real DRAM needs, restoring full QL-native read speed
  and closing out the long microdrive read-reliability investigation.
- **M2017** - fixed the microdrive loader state machines never
  resetting, which could wedge the core until a full power cycle.
- **M2016** - diagnostic build that confirmed the read-timing margin
  hypothesis; removed all on-screen debug overlay instrumentation added
  during the investigation.
- **M2015** - hardening experiment (extra pipeline register on the
  microdrive-to-zx8302 data path); kept, though not the root fix.
- **M2012** - fixed `DIR mdv1_` read corruption by treating the
  download-start signal as a level instead of a one-cycle pulse across
  the QNICE/core clock-domain crossing.
- **M2004-M2010** - initial microdrive 1 implementation: BRAM-backed
  image buffer, QNICE-side loader, on-screen diagnostics used during
  bring-up (later removed).

Along the way, several `.MDV` test images used during development
turned out to have corrupted sector checksums (not an RTL bug) - see
the README's "Microdrive image format" section. `Fase0/tools/mdvcheck.py`
can validate any `.mdv` before use.

## Milestone 2 - QL-SD (mount SD card image as hard drive)

- **M2001-M2003** - RTL plumbing for mounting an SD card image as a QL
  hard drive: `vdrives`/`sd_card` integration, a HyperRAM-backed mount
  buffer, a dedicated OSD menu entry, and a fix for a mount-buffer
  address that could run past HyperRAM's end.

## Milestone 1 - Core bring-up

- **M1001-M1012** - first working QL core on MEGA65: HDMI/VGA output
  and OSD scaling fixes, IPL/vsync interrupt hang fix, keyboard bring-up,
  ROM loading. Milestone 1 complete: the QL boots end-to-end, keyboard
  works, ROM loading works.
