QL4M65 Roadmap
==============

This is a wishlist of features being considered for future versions of the
Sinclair QL core for MEGA65, beyond what V1.0 already delivers (native boot,
selectable RAM 128k/640k/1024k, selectable CPU speed native/16/24MHz/Full,
two read/write microdrives with automatic background save).

Nothing here is committed or scheduled yet - this is a list to prioritize
from once V1.01 (the R3 HyperRAM timing fix) is closed and confirmed on
multiple boards.

Recently shipped
-----------------

* **V1.01 - R3 HyperRAM microdrive reliability (2026-09-02).** A real,
  reproducible bug on some (not all) MEGA65 R3 boards - microdrive reads
  intermittently failing with "bad or changed medium", not present on R6.
  Root cause: a real board-to-board timing margin difference in the
  physical HyperRAM chip's RWDS signal, not a logic bug - confirmed via a
  protocol-accurate HyperBus simulation model against the real, unmodified
  controller RTL (`SAMPLE_RWDS_ST`'s margin is ~27-28ns), and independently
  supported by a die revision difference between R3 and R6 HyperRAM chips
  (`IS66WVH8M8BLL` vs `IS66WVH8M8DBLL`). Fixed for most affected boards by
  tuning R3's HyperRAM RWDS `IDELAY_VALUE` (now a board-specific generic,
  `8` for R3 vs the framework default `20` for R6 - found empirically
  across an extensive sweep, not derived), plus a HyperRAM controller
  `pblock` placement constraint added to both R3 and R6 (matching
  C64MEGA65). **Not a 100% guaranteed fix on every single R3 unit** - see
  the README's "Known issues" and `DECISIONES.md`'s full R3 investigation
  for the whole story (many hypotheses tested and ruled out along the
  way). Released: https://github.com/dfernande132/QL4M65/releases/tag/V1.01

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

* **QXL.WIN / QL-SD support (Milestone 4, retaken 2026-09-02/03). Step 1
  DONE, confirmed on real hardware 2026-09-10.** Three steps: (1) **done** -
  a small (1MB) test `.win` image mounted in a HyperRAM buffer, working
  end-to-end with the QL-SD driver 1.09 in the Back ROM: the card is
  detected, the image mounts, a game stored inside it loads and runs, and
  writing back to the image works too - reads and writes both confirmed on
  real hardware (`M4011b`). This re-implements the `M2001`-`M2003` wiring
  (August 2026, reverted) against the current tree, which has changed a lot
  since (mdv1/mdv2 now really use HyperRAM). Getting here took eleven
  builds, eight of which were spent debugging a module that Vivado had
  silently dropped from the netlist - see `DECISIONES.md` and
  `doc/m2m/exceptions.md`. (2) Modify the M2M framework itself so QNICE
  streams sectors directly from the SD card on demand, instead of requiring
  the whole image preloaded into one linear buffer (the current
  `shell.asm`/`vdrives.vhd` mechanism's limitation) - explicitly intended
  to be proposed upstream so any M2M core can mount large hard-disk
  images, not a QL4M65-only hack. (3) A real ~50MB QXL.WIN image straight
  from the SD card, no HyperRAM/BRAM size ceiling. See `DECISIONES.md`'s
  "Milestone 4" section for the full architecture and progress.

  Note: the RAM-size menu lost its 1024k tier in `M4010` - once the SD card
  emulator was really in the design, BRAM hit 95.9% and the design stopped
  meeting timing. 640k is the ceiling now, and it is allocated exactly
  (two banks, 2^18 + 2^16 words) rather than rounded up to a power of two.

* **Main RAM in SDRAM (Milestone 5). DONE on R6, confirmed on real hardware
  2026-09-12 — 4 MB of RAM at full CPU speed, moving files between microdrive
  and QXL.WIN.** `M5001` brought in MJoergen's SDRAM controller and proved it
  by serving the QL-SD mount buffer from it; `M5002` moved main RAM across,
  restoring the `sdram_dtack` wait-state handshake the original MiSTer core
  always had and this port had simplified away; `M5003` brought back the 1024k
  tier deleted in `M4010` and added the original core's 4096k tier. BRAM went
  from 254/365 to 94/365 and timing to `WNS=+0.312ns`, the best margin this
  project has ever had.

  **Open regression: the MEGA65 R3 is broken on the development branch.** R3
  has no SDRAM device, `top_mega65-r3.vhd` has no SDRAM pins at all, and
  `framework.vhd` instantiates the controller unconditionally — so since
  `M5002` the QL's main RAM on R3 is wired to nothing. The published `V1.01`
  release predates all of this and is unaffected, but nothing can be released
  from the current branch, and no development build should go to the R3
  testers, until `M5004` fixes it. See `DECISIONES.md` for the three options.

* **Main RAM in SDRAM — original entry (Milestone 5, started 2026-09-11).** The MEGA65 R6 has
  64 MB of SDRAM (`IS42S16320F-6BL`) that this core does not use at all -
  every pin is tied off. Moving main RAM there restores the original
  MiSTer QL architecture, which keeps all of the QL's RAM in SDRAM with an
  `sdram_dtack` stalling the 68008 (`QL.sv:363-391, 687`); this port dropped
  that only because no SDRAM controller was available. It would bring back
  the 1024k tier deleted in `M4010` and reach the original 4096k tier, while
  freeing ~160 BRAM tiles. Uses MJoergen's controller (M2M V2.1.0), run at
  84 MHz in the CPU's own clock domain so no CDC is needed. Expected cost:
  Full speed will slow down, since a 12-cycle read is 143 ns against a
  ~95 ns bus cycle. Design in `.research/milestone5-sdram-design.md`.

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
