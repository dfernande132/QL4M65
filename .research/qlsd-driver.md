# What we know about the QL-SD driver (reference, 2026-08-02)

Standalone reference so a new session doesn't have to hunt through
`DECISIONES.md`. The RTL-side design (how `qlromext.v`/`sd_card.sv` wire to
`vdrives.vhd`) is in `qlsd-design.md` — this file is only about the
**software** driver that has to live in ROM for any of that RTL to be
useful to QDOS/Minerva.

## What it is

A piece of QDOS-side software (not RTL, not something we write) that
implements the actual QL-SD protocol on the 68008 side: it talks to
`qlromext.v`'s registers ($FEE0-$FEFF control page, $FF00 SPI shift page),
drives the SD card's SPI command set itself, and exposes the result to
QDOS/Minerva as mountable `WINx_` devices (e.g. `DIR WIN1_`). Without it in
ROM, `qlromext.v`/`sd_card.sv` are just silicon with nothing on the QL side
that knows how to talk to them.

Real banner seen on a working boot (user's own screenshot, this core, this
session):
```
QLSD WIN driver 1.09 WL+MK+TL 2023
H/W L-SPI: Card 1 initialised
```
"WL+MK+TL" = the driver's credited authors' initials; "2023" = that build's
date. The MiSTer core's own `readme.md` (`CORE/QL_MiSTer/readme.md:10,22`)
states the minimum version needed: **"Needs QL-SD driver 1.08 or higher"**.

## Confirmed: not automatic, must be resident in ROM

Directly quoting `readme.md:22`: *"QL-SD can be used if the QL-SD driver is
in the extension ROM, but otherwise ROMs like TK2 are supported, too."*
TK2 is an unrelated toolkit ROM — it's mentioned only because it's another
possible occupant of the same 16 KB extension-ROM slot, not because it
provides QL-SD support itself.

A claim was checked and rejected during this investigation: an external
source claimed MiSTer/MiST "injects the driver automatically, no ROM
needed." This conflates two different things — "no manual `LRESPR driver`
keystroke needed" (true, because the driver is already baked into the boot
ROM image the user loads) with "no driver exists at all" (false). The
screenshot banner above is direct proof it's real running code with its own
identification string, not something transparent at the hardware level.
Chicken-and-egg logic also rules the automatic claim out: you need driver
code already resident in ROM before you can read anything from the SD
card the driver itself would otherwise come from.

## What we already have, no new sourcing needed

`CORE/QL_MiSTer/releases/minerva+qlsd_ql.rom` — Minerva OS + QL-SD driver
already combined into one image, present in the repo (came with the
upstream `QL_MiSTer` checkout, not something we added). Verified size:
**64298 bytes** — not the 65536 (48 K + 16 K exact) the `readme.md`
describes as the canonical "OS + extension ROM" size. This needs handling
(pad to 65536, or make the Back ROM size-check tolerant of a range) before
wiring the loader — flagged as open question 2 in `qlsd-design.md`, not
resolved yet.

Our own M1045 infrastructure already anticipated loading exactly this:
`globals.vhd:141-158` splits ROM loading into `C_DEV_QL_MAINROM` (low 48 KB,
$000000-$00BFFF) and `C_DEV_QL_BACKROM` (extension 16 KB, $00C000-$00FFFF),
with the Back ROM's own comment already saying *"TK2, QL-SD driver..."*.
Both support manual menu load ("Main ROM:%s"/"Back ROM:%s") and auto-load
from fixed SD paths (`/ql4m65/main.rom`, `/ql4m65/back.rom`) at boot. No new
RTL needed for this part — only deciding how to split
`minerva+qlsd_ql.rom` into those two devices (or loading it as one 64298-byte
blob into Main ROM's space if we widen that slot instead — not decided).

## Not investigated, parked for later (not blocking Milestone 2)

- **`gitlab.com/thesmog358/qlnext`** — the ZX Spectrum Next's own QL core.
  User's own reading: it loads the driver in ROM the same way, then TK2
  separately from file — consistent with everything above, not a different
  mechanism. Not cloned/read by us yet.
- **Phoebus Dokos's new FAT32 driver** (WIP as of the source the user found,
  shared with Kilgus — the maintainer of the more actively updated
  `QL_MiSTer` fork we did *not* choose, see `DECISIONES.md` Fase 3 for why
  we picked the official `MiSTer-devel` repo instead). Claimed
  improvements: FAT12/16/32 (not just FAT32), up to 4 partitions per drive,
  no more "one image per card" limitation, live ROM autopatching for >1 MB
  RAM visibility, `WIN_FORMAT`/`FORMAT`/`FDISK`/`CHKDSK` commands, planned
  MDV/FLP virtual container support. Potentially relevant to us **only** as
  a future upgrade once basic QL-SD is working — the current
  `minerva+qlsd_ql.rom` driver is sufficient for Milestone 2 as designed in
  `qlsd-design.md`.

## What we deliberately don't need to know

The driver's internal command sequence over `qlromext.v`'s SPI registers is
opaque to us and doesn't need reverse-engineering (unlike the keyboard IPC
protocol in Milestone 1's `Anexo B`, which we *did* have to reverse-engineer
because we replaced the hardware it talked to). Here we're keeping
`qlromext.v` and `sd_card.sv` unmodified — the driver already knows how to
talk to that exact interface, since it's the same interface the real
QL-SD/MiSTer hardware exposes. Our job is only the RTL plumbing in
`qlsd-design.md`, not the software protocol.
