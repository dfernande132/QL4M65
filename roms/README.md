# ROMs

The QL4M65 core ships no ROM inside the bitstream — you load one from the SD
card through the Options menu (Help key). These are the ROMs needed to get
going. Copy them to `/ql4m65/rom/` on your SD card.

| File | What it is | Slot |
|---|---|---|
| `main.rom` | Minerva 1.98a1 — the QL operating system | **Main ROM** |
| `back.rom` | Toolkit II 2.23 | **Back ROM** |
| `qlsd_driver_back.rom` | QL-SD driver 1.09 — needed for QXL.WIN hard disks | **Back ROM** |

`back.rom` and `qlsd_driver_back.rom` both go in the **Back ROM** slot, so pick
one: Toolkit II for the extra BASIC commands, or the QL-SD driver if you want
the hard disk. You cannot have both at once.

## Credits

**Minerva** is by Laurence Reeves (Lau's QL Stuff), released under the GPL.

**Toolkit II** is by Tony Tebby / QJUMP, released under the GNU licence.

**The QL-SD driver 1.09 is by Wolfgang Lenerz and Marcel Kilgus ("WL + MK
2020")**, and all credit for it belongs to them. The copy here was extracted
from `Minerva_1.98a1_qlsd109.rom` in
[`MiSTer_QL_OS_qlsd109.zip`](https://www.kilgus.net/soft/MiSTer_QL_OS_qlsd109.zip),
published by Marcel Kilgus at **<https://www.kilgus.net/ql/ql-sd/>** — which is
also where you should go for the original file, the QL-SD hardware
documentation, and any newer version. `main.rom` here is the Minerva half of
that same combined image.

Marcel Kilgus is also the maintainer of
[QL_MiSTer](https://github.com/MiSTer-devel/QL_MiSTer), the core QL4M65 is
ported from. This project owes him a great deal.

The QL-SD driver is included here for convenience only, with attribution and
no claim of ownership. **If the authors would rather it were not redistributed,
say so and it will be removed immediately** — open an issue, or contact the
maintainer of this repository.

## ROMs deliberately NOT included

Other QL ROMs — JS, MGE, AH and the rest of the original Sinclair/Amstrad QDOS
firmware — are **not** included here, and should not be added. They are
commercial software still under copyright, and unlike the ROMs above there is
no author who can simply grant permission. If you own a QL you may have your
own dumps; otherwise see the
[Sinclair QL ROM archive](https://sinclairql.net/djw/qlrom/index.html).
