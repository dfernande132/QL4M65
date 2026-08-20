# Changelog

All notable changes to QL4M65 (CoreQL) are documented here, milestone by
milestone. For a full technical/design log (in Spanish) see
`DECISIONES.md` and `.research/PORTING-PLAN.md`.

## Milestone 2 - Phase B: Microdrive write support (`SAVE`, saved to SD) - complete

- **M2029** - the MEGA65's drive-activity LED turns blue while mdv1 has
  sectors not yet flushed to the SD card, back to red once they're saved -
  same "don't power off yet" pattern C64MEGA65 and AExp already use for
  their own background write-back indicators.
- **M2028** - etapa 4: automatic background flush, no more manual "Save
  mdv1" menu item. A new `HANDLE_CORE_IO` hook (ported from sy2002/AExp,
  the first deliberate exception to the shared M2M framework this project
  makes - see `doc/m2m/exceptions.md`) gives the core's firmware a time
  slice on every Shell loop iteration to stream dirty sectors back to the
  SD card in small, resumable steps, with a software anti-thrashing gate
  so a burst of writes doesn't trigger a flood of small SD writes.
- **M2027** - fixed a real hardware bug from M2026: the QNICE bus wait
  signal for mdv1 reads missed its own first cycle, so every byte read
  back for the SD flush was silently one request behind the one actually
  asked for, corrupting the saved `.mdv`. Found by a byte-level diff
  against the original image (a clean `mod[N] == orig[N-1]` shift pattern
  within every affected sector) rather than by re-reading the code blind.
- **M2026** - etapa 3: a menu item ("Save mdv1") to flush dirty sectors
  back to the SD card's `.mdv` file, and an automatic flush before mdv1
  gets reloaded so unsaved changes are never silently discarded. Reused
  the already-open file handle from the original load (same pattern
  C64MEGA65's own vdrives write-back and AExp's ADF write-back both use)
  instead of tracking a file path.
- **M2025** - etapa 2: a 256-bit dirty-sector bitmap plus a QNICE-side
  read-back path for the mdv1 buffer and bitmap, laying the groundwork for
  the SD flush - no user-visible change yet.
- **M2024** - root cause of the `SAVE` failure found (after M2022/M2023's
  partial fixes): the write-session byte counter was one bit too narrow
  for a full session, silently overflowing and corrupting the write on
  every single `SAVE`. `SAVE`/`DIR`/`LOAD` round-trips correctly on real
  hardware for the first time.
- **M2023** - fixed a write-strobe timing bug (one clock-enable domain too
  shallow) that caused `SAVE` to write roughly 11 bytes for every real
  byte the CPU sent.
- **M2022** - first real write channel: `rtl/mdv.v` gains the ability to
  commit incoming bytes to the microdrive buffer at the correct positional
  offset, `rtl/zx8302.v` decodes the microdrive transmit-data register for
  the first time.

Along the way, two genuinely instructive debugging journeys - a
clock-enable-domain strobe bug and a counter-width overflow (M2022-M2024),
and a QNICE-bus wait-state timing bug found by byte-level evidence rather
than code review (M2026-M2027). Full technical write-ups for every build in
`DECISIONES.md` and `.research/PORTING-PLAN.md`.

## Milestone 2 - Phase A: Microdrive support (read-only) - complete

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
