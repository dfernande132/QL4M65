# QL4M65 (CoreQL) - Version 1.5 - Installation instructions

## Read this first: V1.5 is for the MEGA65 R6

V1.5 keeps the QL's main memory in the MEGA65's **SDRAM** chip, and this
release ships an **R6** core.

**R3 owners: stay on [V1.01](https://github.com/dfernande132/QL4M65/releases/tag/V1.01).**
The R3 has no SDRAM chip at all, so this version cannot run on it. V1.01 is
still available, still supported, and includes a HyperRAM timing fix made
specifically for the R3 - it is the best build this core has ever had for that
board. You are not missing a bug fix by staying there; you are missing features
your hardware cannot run.

**R4 and R5 owners**: your board has the same SDRAM chip as the R6, but each
revision needs its own core build and nobody has yet tested one. Only an R6
`.cor` is published here. If you have an R4 or R5 and would like to try, open
an issue.

## What's in this release

| File | What it is |
|---|---|
| `QL4M65-CoreQL-V1.5_r6.cor` | The compiled core for MEGA65 **R6** |
| `main.rom` | Minerva 1.98a1 system ROM |
| `back.rom` | Toolkit II (TK2) ROM |
| `qlsd_driver_back.rom` | QL-SD driver 1.09 - needed for QXL.WIN hard disks |
| `blank.mdv` | A blank, correctly-formatted microdrive test image |

### Credits for the ROMs

**Minerva** is by Laurence Reeves and **Toolkit II** by Tony Tebby / QJUMP,
both GPL/GNU-licensed and freely redistributable.

**The QL-SD driver 1.09 is by Wolfgang Lenerz and Marcel Kilgus ("WL + MK
2020")** - all credit for it is theirs. It was extracted from
`MiSTer_QL_OS_qlsd109.zip`, published by Marcel Kilgus at
<https://www.kilgus.net/ql/ql-sd/>, which is where to go for the original
file, the QL-SD hardware documentation and any newer version. It is included
here for convenience only, with attribution and no claim of ownership; if the
authors would rather it were not redistributed, it will be removed
immediately - please just say so.

Marcel Kilgus also maintains [QL_MiSTer](https://github.com/MiSTer-devel/QL_MiSTer),
the core this is ported from. The SDRAM controller that makes V1.5 possible is
by **Michael Jørgensen** (<https://github.com/MJoergen/SDRAM>).

For any other QL ROM (JS, MGE, AH, ...) see the
[Sinclair QL ROM archive](https://sinclairql.net/djw/qlrom/index.html) - those
are commercial software still under copyright and are not distributed here.

## 1. Install the core

Copy `QL4M65-CoreQL-V1.5_r6.cor` onto your MEGA65's SD card, wherever your
MEGA65 firmware expects `.cor` files, and flash it the same way as any other
core.

## 2. Install the ROMs

On the SD card used by the core, create:

```
/ql4m65/
/ql4m65/rom/
```

and copy in:

- `main.rom` -> `/ql4m65/rom/main.rom`
- `back.rom` -> `/ql4m65/rom/back.rom`
- `qlsd_driver_back.rom` -> `/ql4m65/rom/` (only needed for the hard disk)
- `blank.mdv` -> anywhere under `/ql4m65/`, e.g. `/ql4m65/mdv/blank.mdv`

`main.rom` and `back.rom` auto-load at boot. Microdrive and hard disk images
are mounted manually from the Options menu.

**Toolkit II and the QL-SD driver share the Back ROM slot**, so you can have
one or the other, not both: `back.rom` for the extra BASIC commands, or
`qlsd_driver_back.rom` for the hard disk. Swap between them from the Options
menu ("Back ROM") whenever you like - the core resets itself automatically.

## 3. First boot

Power on with the QL4M65 core active. You should get the QL boot sequence
(RAM check, boot logo, F1-F4 screen) and then SuperBASIC with a working
keyboard.

**Use HDMI.** VGA output does not currently work correctly on this core,
including the on-screen menu.

## 4. RAM size and CPU speed

Two radio groups in the Options menu:

- **RAM**: `128k` (default) / `640k` / `1024k` / **`4096k`**. All of it lives
  in the MEGA65's SDRAM. 4096k is the largest size the original MiSTer core
  offers, and is new in V1.5.
- **Speed**: `QL native` (default, ~7.5 MHz effective) / `16 MHz` / `24 MHz` /
  `Full` (~42 MHz). The CPU, the video/IO ULAs and both microdrives all scale
  together, so turbo speeds up microdrive transfers too. The original QL's
  video/CPU memory contention is only modelled at native speed, exactly like
  the original core.

Changing either triggers an automatic core reset, so anything unsaved in the
QL's RAM is lost - same as any other reset.

## 5. The QXL.WIN hard disk (new in V1.5)

Put the **QL-SD driver** in the Back ROM slot (step 2), then mount a `.win`
image with **Mount HD image** in the Options menu. The QL will see it as
`win1_`:

```
DIR win1_
```

Reading and writing both work. Writes go to the in-memory copy and are
flushed back to the SD card in the background, exactly like the microdrives.

**Keep images small - 4 to 8 MB is a good size.** Mounting copies the whole
image into memory at roughly **6-7 seconds per megabyte**, so an 8 MB image
costs about a minute every time you mount it. The core will not accept
anything above 32 MB. A future version will stream sectors straight from the
SD card and remove both the wait and the limit.

If the driver reports **"Card 1 not found"**, the image is not mounted - mount
it from the Options menu first, then let the core reset.

## 6. The microdrives

Mount `.mdv` images as `mdv1_` and `mdv2_` from the Options menu - each has
its own line. From SuperBASIC:

```
DIR mdv1_
10 PRINT "hello"
SAVE mdv1_test
LOAD mdv1_test
RUN
```

**Both drives save themselves, no menu item needed.** After a `SAVE`, each
drive's activity LED goes **blue** while sectors are still waiting to be
written back to the SD card, and returns to **red** once flushed. Once red, it
is safe to power off. Switching to a different image flushes any pending
writes first.

Each drive has its own synthesized motor hum while selected, so you can hear
which one is running.

**Only use `.mdv` images in QLAY format (exactly 174930 bytes).**
QDOS/Minerva checksums every sector as it reads, just like real hardware, so
an image with corrupted checksums will fail here even if other emulators
tolerate it. See the repository README for the full story.

## Known limitations

- **MEGA65 R3 is not supported by this version** - see the top of this file.
- QXL.WIN images are capped at 32 MB and take 6-7 seconds per megabyte to
  mount.
- Toolkit II and the QL-SD driver cannot both be loaded at once.
- Video is PAL only, over HDMI; VGA does not work correctly.
- No mouse.
- A physical reset button press or an abrupt power loss runs no firmware, so
  writes from the last moment before that can still be lost - the same
  accepted limitation other M2M cores with background write-back share.
  Everything saved before that point is safe.

## Questions / problems

Open an issue on the [QL4M65 GitHub repository](https://github.com/dfernande132/QL4M65)
or ask in the [MEGA65 community on Discord](https://discord.com/channels/719326990221574164/1177364456896999485).
Real-hardware reports are genuinely useful, working or not.
