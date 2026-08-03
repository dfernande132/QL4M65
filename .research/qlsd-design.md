# QL-SD design doc (approved, implementation starting)

Status: **approved for implementation (2026-08-03)**. All open questions
below are resolved. Nothing in `main.vhd`/`mega65.vhd`/`globals.vhd` has
been touched yet at the time of this update — implementation starts right
after this revision. Written after the microdrive read-design doc, as a
comparison candidate for Milestone 2 storage; QL-SD won that comparison
(see `DECISIONES.md`, "Milestone 2 — QL-SD elegido sobre microdrive",
2026-08-02).

## Why this is a fundamentally easier problem than the microdrive

- `rtl/qlromext.v` (the QL-SD CPLD, unmodified in the repo, never yet
  instantiated) is **not** a block-device controller. It's a QL-bus-facing
  register interface ($FEE0-$FEFF control page + $FF00 data page) that lets
  the CPU bit-bang or hardware-shift raw SPI transactions
  (`sd_clk`/`sd_cs1l`/`sd_cs2l`/`sd_di`/`sd_do`). All SD protocol logic (CMD0,
  CMD8, CMD17/18 read, CMD24/25 write, ACMD41, CMD58...) is implemented in
  software — by the QL-SD driver ROM running on the 68008 — not in
  `qlromext.v` itself.
- The actual SD *card* is emulated by `sys/sd_card.sv` (also unmodified,
  already present, stock MiSTer framework code, not QL-specific) — a
  hardware SPI-slave state machine that answers those commands and exposes
  the result as MiSTer's **generic "SD" block-storage protocol**:
  `sd_lba`/`sd_rd`/`sd_wr`/`sd_ack`/`sd_buff_addr`/`sd_buff_dout`/
  `sd_buff_din`/`sd_buff_wr`.
- That generic protocol is **exactly** what `M2M/vhdl/vdrives.vhd` bridges to
  QNICE + FAT32 — the same mechanism already proven elsewhere in the M2M
  ecosystem (AExp's ADF/HDF, C64MEGA65's D64). Confirmed by direct signal-name
  match against `vdrives.vhd:155-166`.
- Consequence: **read and write both come for free** from `vdrives.vhd`,
  with no new low-level RTL. Contrast with the microdrive: `mdv.v` has no
  addressable/LBA interface at all (just a continuous full-buffer replay),
  so it doesn't fit `vdrives.vhd`'s model and needs an entirely new
  write-path + HyperRAM buffer design (see `microdrive-read-design.md`).

## Confirmed: MiSTer does require a driver ROM, not automatic

Directly from the core's own `readme.md` (not inferred):

> "Full QL-SD support ... **Needs QL-SD driver 1.08 or higher**"
> "QL-SD can be used if the QL-SD driver is in the extension ROM, but
> otherwise ROMs like TK2 are supported, too."

Minerva alone does **not** include QL-SD support. The driver must occupy the
16 KB extension-ROM slot (the same slot TK2 or other extension ROMs could
occupy instead — TK2 itself has nothing to do with QL-SD, it's just another
possible occupant of the same slot). This is architecturally unavoidable
(chicken-and-egg: you need the driver in ROM before you can read anything
from the disk it would otherwise come from).

**This costs us nothing new to build.** `CORE/QL_MiSTer/releases/
minerva+qlsd_ql.rom` already exists locally — a pre-combined Minerva +
QL-SD-driver image — and our own M1045 Main/Back ROM split
(`C_DEV_QL_MAINROM`/`C_DEV_QL_BACKROM`, `globals.vhd:141-158`) already has a
comment anticipating exactly this ("the extension ROM's 16 KB ... TK2, QL-SD
driver..."). The loading mechanism is done; only sourcing/selecting the ROM
content is left, which is a user action, not RTL work.

Caveat found while checking: the local `minerva+qlsd_ql.rom` is 64298 bytes,
not the readme's documented 65536 (48K+16K exact). **Resolved (2026-08-03,
see "Open questions" below): pad a copy of the file to 65536 bytes exactly
instead of relaxing the size-check FSM** — zero RTL risk, keeps
`p_main_size_check`/`p_back_size_check` untouched.

## Architecture to implement

```
qlromext.v (QL bus, $FEE0-$FEFF/$FF00, unmodified)
   |  raw SPI: sd_clk / sd_cs1l / sd_cs2l / sd_di / sd_do
   v
sd_card.sv (SPI-slave SD emulator, unmodified)
   |  clk_spi domain          |  clk_sys domain
   |  (SPI bit-shifting)      |  (block-level LBA access)
   v                          v
qlromext's SPI timing    sd_lba/sd_rd/sd_wr/sd_ack/sd_buff_* -> vdrives.vhd
   (needs core clock)         (needs QNICE clock, see below)
```

### Key finding: `sd_card.sv` already has the exact clock split `vdrives.vhd` needs

`sd_card.sv`'s port list has **two independent clock inputs**:
`clk_sys` (drives `sd_lba`/`sd_rd`/`sd_wr`/`sd_ack`/`sd_buff_*` — the
block-level side) and `clk_spi` (drives the SPI bit-shift state machine
talking to `qlromext.v`). `vdrives.vhd`'s own header comment is explicit
that its block-level SD ports "run in QNICE's clock domain"
(`vdrives.vhd:153-154`) — different from `img_mounted_o`/cache signals,
which run in the core clock domain and get their own `xpm_cdc` bridge
inside `vdrives.vhd`.

So the wiring is: `sd_card.sv`'s `clk_sys => qnice_clk_i`,
`clk_spi => clk_qlsd` (core-domain, fast enough for real-time SPI timing
toward `qlromext.v`, which lives entirely in the core clock domain since
it's on the QL bus). `sd_card.sv` already synchronizes `sd_ack` across that
boundary internally (`ack[2:0]` 2-FF synchronizer, clocked by `clk_spi`,
`sd_card.sv:190-191`), and its internal `sdbuf` (the byte buffer between the
two sides) is already a genuine dual-clock dual-port RAM (`clock0`/`clock1`
separately parameterized). No new CDC bridge needed — reuse as-is.

### New work required (small, compared to microdrive)

1. **`sd_card.sv` must be instantiated with `WIDE(0)`, not `WIDE(1)` like
   the original `QL.sv` does (confirmed by reading the RTL, 2026-08-03).**
   `QL.sv:287` instantiates `sd_card #(.WIDE(1))` — 16-bit words on the
   `clk_sys` side, MiSTer's own ARM/HPS convention. But `vdrives.vhd` is
   hard-wired to 8 bits on that same side (`constant DW: natural := 7;`,
   `vdrives.vhd:104`) — the same convention every other M2M core uses.
   `WIDE` only affects `sd_card.sv`'s own `AW`/`DW` localparams (address/
   data width on the `clk_sys` port of its internal `sdbuf` RAM); the SPI
   side (`clk_spi` port, talking to `qlromext.v`) is always 8 bits
   regardless of `WIDE`, so this choice is invisible to `qlromext.v` and to
   the SPI protocol itself — it's purely how `sd_card.sv` and `vdrives.vhd`
   agree to address the shared 512-byte sector buffer. No M2M core in this
   project's local reference set (AExp, C64MEGA65) actually pairs
   `sd_card.sv` with `vdrives.vhd` — AExp's ADF/HDF path doesn't use
   `sd_card.sv` at all — so this is the first real instance of that pairing
   here; there's no existing wiring to copy, only `vdrives.vhd`'s own
   header comments and port widths to derive it from.
2. **`sdbuf`'s `altsyncram` needs a Vivado-clean replacement** — same class
   of problem already solved twice (`ql_rom`/`vram`'s `dpram`, and would
   have been needed again for `mdv.v`'s `dpram`). With `WIDE(0)` (point 1
   above), `sdbuf`'s two ports are **both exactly 8 bits wide** (`width_a
   = DW+1 = 8`, `width_b = 8`, `sd_card.sv:117-141`) — genuinely
   symmetric, not just "byte-wide on one side" as an earlier draft of this
   doc assumed. That means the replacement is a plain
   `M2M/vhdl/2port2clk_ram.vhd`'s `dualport_2clk_ram` at `DATA_WIDTH => 8`,
   no asymmetric-width RAM primitive needed. Clocks: `clock_a => clk_sys`
   (`qnice_clk_i`), `clock_b => clk_spi` (core clock). `sd_card.sv` itself
   stays 100% unmodified otherwise (matches the `mdv.v`/`ipc.v` policy) —
   only its own internal `altsyncram` instance needs the swap, same
   surgical approach as `zx8302.v`'s `mdv`/`ipc` removal.
3. **`qlromext.v`'s own `dtack` output must be muxed into `main.vhd`'s
   `cpu_dtack` (missing from the current `main.vhd`, found 2026-08-03).**
   Original `QL.sv:684-688`: `cpu_dtack <= qlsd_sel ? qlsd_dtack : ...` —
   while a QL-SD register/data access is in flight, `qlromext.v` generates
   its own wait-states for the DTACK response instead of the RAM-delay
   chain. Our `main.vhd:315` today is just `cpu_dtack <= not
   ram_delay_dtack`, with no QL-SD branch — needs
   `cpu_dtack <= qlsd_dtack when qlsd_sel = '1' else not ram_delay_dtack;`
   (verify `qlromext.v`'s `dtack` polarity before wiring — same class of
   "looks obvious, turned out inverted" issue as the `IPL` polarity bug
   found in `M1016`/`M1017`).
4. **Address decode into `main.vhd`.** Original `QL.sv:304-308`:
   `qlsd_en = (!gc_en || rom_shadow) && cpu_rom && cpu_rd`. We have no
   GoldCard (`gc_en` always 0) and no `rom_shadow` concept — our own
   `cpu_rom` (`main.vhd:293`, `cpu_addr <= x"00FFFF"`) already covers the
   whole ROM window, OS+extension combined, unconditionally. So our
   equivalent simplifies to `qlsd_en <= cpu_rom and cpu_rd`, no shadow-RAM
   caveat to replicate.
5. **One `vdrives.vhd` instance, `VDNUM => 1`.** `C_VDNUM`/`C_VD_DEVICE`/
   `C_VD_BUFFER` in `globals.vhd:103-108` are currently the "no virtual
   drives" placeholder (`C_VDNUM => 0`) with a stale comment ("milestone 3")
   — updated to Milestone 2 now that the reordering is final.
6. **QNICE menu entry**, "Mount HD image" — **resolved (2026-08-03): its own
   labelled section**, same visual pattern as the existing "ROM" section
   header added in `M1046` (non-selectable title line, e.g. "STORAGE",
   followed by the "Mount HD image:%s" action line) — not a bare line with
   no header, and not a submenu (the user explicitly rejected submenus for
   this flat-menu style in `M1047`). Remember to bump `OPTM_DY`/`OPTM_SIZE`
   together (the `M1046`/`M1047` bug: `OPTM_DY` not updated when
   `OPTM_SIZE` grew, cutting "Close Menu" out of the visible window). Same
   `SC0,WIN` semantic the original core's own `CONF_STR` documents (`QL.sv`,
   not directly reusable syntax but same meaning), matching how AExp/
   C64MEGA65 expose their own `vdrives.vhd` mounts in `config.vhd`.
7. **Sourcing/selecting the combined ROM** — no new RTL; see the Back ROM
   size-check resolution below.

### What stays untouched

- `qlromext.v` — instantiated as-is, same as `mdv.v`'s eventual treatment.
- `sd_card.sv` — as-is except the internal `altsyncram` swap and the
  `WIDE(0)` instantiation parameter (items 1-2 above).
- `vdrives.vhd` — as-is, generic framework module, zero QL-specific changes.

## Tradeoff to flag (not a blocker, just context)

QXL.WIN is a later-era expansion format (real QL-SD hardware was a
third-party add-on, not stock 1984 QL), unlike microdrive cartridges which
are how original QL software was actually distributed. In practice this
likely doesn't cost authenticity: QXL.WIN/.win is the de facto format most
QL software circulates in today for every major software emulator (QPC,
QemuLator, SMSQmulator) and native hardware (QL-SD, Q40/Q60, Q68) per the
core's own readme. Still worth being explicit that this is a different kind
of "storage milestone" than microdrive, not a strict superset.

## Open questions — all resolved (2026-08-03), implementation approved

1. **Which milestone gets built first — RESOLVED.** QL-SD **is** Milestone 2
   (see `DECISIONES.md`, "Milestone 2 — QL-SD elegido sobre microdrive",
   2026-08-02, and `PORTING-PLAN.md` section 7). Microdrive is parked,
   uncancelled, as Milestone 4.
2. **Back ROM size-check tolerance — RESOLVED: pre-pad the file, keep the
   exact-match check.** Rather than relaxing `p_main_size_check`/
   `p_back_size_check` (`mega65.vhd:590-679`) to accept a range, generate a
   65536-byte-exact copy of `minerva+qlsd_ql.rom` (49152 bytes Main as-is +
   15146 bytes Back as-is + 1238 zero-padding bytes to reach 16384) via a
   one-off script, same spirit as the hand-built `M1013` test ROM. Zero RTL
   risk; the tradeoff (any future non-standard Back ROM needs the same
   manual padding) is accepted. No changes needed to the size-check FSMs.
3. **Clocking — resolved, no new PLL needed.** Checked `QL.sv:97-135`: the
   only PLL (`pll pll(...)`) generates the single system clock (`clk_sys`,
   our `clk_qlsd`/core clock), same one everything else already runs on.
   `FRACT_SD` (`QL.sv:113`, "84MHz * 39010 / 65536 = 50MHz, effectively
   25MHz SPI") is the same fractional-NCO clock-enable technique already
   ported for `ce_bus_p`/`ce_11m` (`DECISIONES.md`, "Relojes internos —
   hecho") — `ce_sd` already exists in our clock generator. So:
   `sd_card.sv`'s `clk_spi => clk_qlsd` (raw core clock, matches
   `QL.sv`'s own `.clk_spi(clk_sys)`), and `qlromext.v`'s `ce_sd` input
   uses the `ce_sd` we already have. The "PLL a 25MHz SPI" phrasing in
   `PORTING-PLAN.md` was an early/coarse note referring to this same
   fractional-enable mechanism, not a second dedicated PLL.
4. **`sd_card.sv` instantiation width and the missing `dtack` wire —
   RESOLVED, see "New work required" items 1 and 3 above** (found while
   verifying this design against the actual RTL, 2026-08-03, not part of
   the original draft).

## Build strategy (decided 2026-08-03)

Split into two hardware-tested builds, same precedent as the CPU/chipset
block that became `M1001` — a block of comparable size and risk:

- **`M2001`**: all the RTL wiring above (`sd_card.sv` RAM swap,
  `qlromext.v`/`sd_card.sv`/`vdrives.vhd` instantiation, address decode,
  dtack mux, menu entry). Goal: clean synthesis, WNS/WHS checked (not just
  100% progress — the `M1004` lesson), and **no behavioural change** to the
  existing boot path yet — `Minerva197_rom` alone should still boot exactly
  like `M1048`. No `minerva+qlsd_ql.rom` loading, no `.win` mount attempt
  yet.
- **`M2002`**: load the padded `minerva+qlsd_ql.rom` (Main+Back) for real,
  mount a `.win` test image via the new menu entry, confirm the real
  "QLSD WIN driver 1.09 WL+MK+TL 2023" / "H/W L-SPI: Card 1 initialised"
  banner on hardware (same banner the user already saw working on this core
  before this session).
