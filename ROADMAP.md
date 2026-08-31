QL4M65 Roadmap
==============

This is a wishlist of features being considered for future versions of the
Sinclair QL core for MEGA65, beyond what V1.0 already delivers (native boot,
selectable RAM 128k/640k/1024k, selectable CPU speed native/16/24MHz/Full,
two read/write microdrives with automatic background save).

Nothing here is committed or scheduled yet - this is a list to prioritize
from once V1.01 (the R3 HyperRAM timing fix) is closed and confirmed on
multiple boards.

Under investigation right now
------------------------------

* **V1.01 - R3 HyperRAM timing fix.** A real, 100% reproducible bug on at
  least one MEGA65 R3 board (microdrive reads fail with "bad or changed
  medium"), not present on R6. Leading hypothesis: the HyperRAM controller's
  `SAMPLE_RWDS_ST` sampling point has a real margin of ~27-28ns (confirmed
  in a protocol-accurate HyperBus simulation model against the real,
  unmodified controller RTL), and a die revision difference between R3 and
  R6 HyperRAM chips (`IS66WVH8M8BLL` vs `IS66WVH8M8DBLL`, per a tester's own
  schematic research) may push R3 boards past that margin. Two fixes are
  currently being tested in parallel by real R3 owners: added sampling
  margin in the HyperRAM controller FSM, and a `pblock` placement
  constraint for the HyperRAM controller (matching what C64MEGA65 already
  does). See `DECISIONES.md`'s R3 investigation sections for the full
  story. Once confirmed by a couple of testers, this becomes V1.01.

V2.0 candidates
-----------------

### Memory

* **4MB / 8MB RAM.** Waiting on the upcoming M2M framework v2.0 release,
  which is expected to bring an official, framework-level SDRAM controller
  (already being tested "silently" in C64MEGA65's alpha branch, used there
  for the simulated REU on R4/R5/R6 boards instead of HyperRAM). Once
  released, the QL's RAM ceiling could grow well past the current 1024k
  BRAM limit without re-fighting the HyperRAM-for-CPU-RAM problem that
  blocked Milestone 3's first attempt.

### Storage

* **QXL.WIN / QL-SD support (Milestone 4, paused since 2026-08-04).** Real
  QXL.WIN images run ~50MB, too big for a linear HyperRAM/BRAM buffer
  alongside everything else the core needs. Needs QNICE to stream sectors
  directly from the SD card on demand, instead of requiring the whole image
  preloaded into one buffer (the current `shell.asm`/`vdrives.vhd`
  mechanism's limitation). This would also be the first real "sector
  streaming from SD" work in this M2M ecosystem - potentially useful to
  other cores too, not just the QL.

* **Physical floppy drive support.** Real QL expansions (e.g. Trump Card)
  added floppy controllers based on the WD1772 - the MEGA65 could drive a
  real floppy drive the same way. Would need a WD1772-compatible controller
  in the core plus a real disk driver on the QDOS/SMSQ side.

* **More than 2 microdrives.** QDOS itself supports up to 8 logical units
  (`mdv1_` through `mdv8_`); V1.0 only implements 2. Expanding the count
  should be a straightforward extension of the existing architecture, not a
  redesign.

### Expansion hardware

* **GoldCard implementation.** A real QL accelerator/expansion with its own
  68020 and ROM. Out of scope until the core's own memory/speed foundation
  (RAM expansion, SDRAM) is in place.

* **SMSQ/E.** Most "modern" QL software targets SMSQ/E rather than plain
  QDOS, and SMSQ/E is commonly paired with GoldCard-class hardware -
  evaluate alongside GoldCard rather than as a separate, standalone item.

### Video

* **VGA / analog output.** Clarify scope when prioritizing: real analog
  RGB/SCART/15kHz output (like AExp and C64MEGA65 offer, for real CRTs) is
  a different feature from HDMI-side visual filters (scanlines/CRT
  emulation) - worth deciding whether one, both, or neither make the cut.

### Peripherals

* **Mouse support.** The QL had optional mouse interfaces (e.g. QIMI); the
  MEGA65 already has real mouse-port support wired up and proven in other
  M2M cores (AExp).

* **Serial port (SER1/SER2).** `pc_tctrl` ($18002) is already noted as
  undecoded in `exceptions.md`, explicitly pending "if a serial port is
  ever implemented." Could connect to the MEGA65's real UART for file
  transfer or genuine serial devices.

* **Joystick support.** Some QL-era software/clones supported
  Kempston-style joystick interfaces. The MEGA65's joystick ports are
  currently unused by this core.

* **Virtual RTC.** The QL didn't ship with a built-in clock, but plenty of
  contemporary software knows how to talk to one of the known expansion
  RTCs. The MEGA65 has a real battery-backed RTC already exposed by other
  M2M cores (AExp, C64MEGA65).

### Quality of life

* **Persistent OSD settings.** Save RAM size / CPU speed / ROM selections
  to a config file on the SD card, so they survive a power cycle without
  reconfiguring - same pattern C64MEGA65 already uses.

---

Feel free to add, remove, or reprioritize anything here - this is a working
list, not a commitment.
