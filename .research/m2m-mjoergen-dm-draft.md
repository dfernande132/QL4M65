# Draft private message to MJoergen (Michael Jørgensen)

Status: DRAFT — not sent.

## Provenance (get this right — sy2002 and MJoergen talk to each other)

The user privately asked sy2002, back during the R3 tester period, whether he
could **write an SDRAM controller for the framework** (motivation: 8 MB of
shared HyperRAM is not enough for RAM-hungry cores — Amiga 1200, a 386 with
4 MB, 512 KB ROMs). sy2002 replied that one already exists:

  - https://github.com/MJoergen/SDRAM — MJoergen is the author
  - Going into M2M V2.1.0
  - Silently tested in C64MEGA65 alphas (develop branch,
    M2M/vhdl/controllers/SDRAM/sdram.vhd)
  - Used there for the simulated REU: "On 2024+ MEGA65s this feature works even
    better, smoother and more compatible as it uses the built-in SDRAM instead
    of HyperRAM" (C64MEGA65 issue #206)
  - The Vixen core also uses SDRAM, but not this controller
  - "Please approach MJoergen directly, if you have questions / need support.
    He is the author of the controller."

So this DM is follow-through on an explicit referral. NOT a reply about disk
images — the public thread about disk images is still unanswered by both.

## Already answered by reading the code — do NOT ask these

  - Avalon-MM interface: identical port-for-port to M2M's hyperram.vhd
    (avm_write_i / avm_read_i / avm_address_i(31:0) / avm_writedata_i(15:0) /
    avm_byteenable_i(1:0) / avm_burstcount_i(7:0) / avm_readdata_o(15:0) /
    avm_readdatavalid_o / avm_waitrequest_o). No burst mode support.
  - Coexistence with HyperRAM: yes. C64MEGA65 develop, framework.vhd:973,
    "sdram_gen : if G_BOARD = "MEGA65_R3" generate" — R3 uses HyperRAM for
    everything (3-slave arbiter); R4/R5/R6 use SDRAM for the ascaler and
    HyperRAM for the rest (2-slave arbiter), with
    "sdram_inst : entity work.sdram generic map (G_CLOCK_SPEED_MHZ => 100)
    -- Same clock speed as HyperRAM". So no new clock domain is needed, and
    the M2M-integrated copy (not the standalone repo) is the one to take.

---

Hi Michael,

sy2002 pointed me your way. I had asked him whether I could write an SDRAM
controller for M2M — my QL core (QL4M65) keeps running out of the 8 MB
HyperRAM — and he told me you had already written one, that it's going into
V2.1.0, and that I should talk to you directly.

We were also in touch a while back, when you helped me chase down the HyperRAM
RWDS problem on MEGA65 R3 — you spotted the missing pblock for the HyperRAM
controller and suggested the IDELAY_VALUE sweep, which ended up fixing it for
two of my testers. Thanks again for that.

I've read through your controller and the way C64MEGA65's develop branch wires
it up, so I think I understand the shape of it: same Avalon-MM interface as the
HyperRAM controller, and the `G_BOARD` generate in framework.vhd that gives
SDRAM to the ascaler on R4/R5/R6 while HyperRAM keeps the rest. That answers
most of what I was going to ask.

What I'm actually trying to solve: QL4M65 now has QL-SD / QXL.WIN hard-disk
images working on a real R6 — mount, boot, read and write all confirmed. But
M2M's `LOAD_IMAGE` copies the whole image into a linear mount buffer and
`HANDLE_DRV_RD` / `HANDLE_DRV_WR` serve sectors out of it, so image size is
capped by whatever RAM the core can spare. Sharing 8 MB of HyperRAM with two
microdrives puts me at about 1 MB. A real QXL.WIN hard disk is 50-100 MB.

So I see two routes, and I'd value your view on which is worth the effort:

1. Put the mount buffer in SDRAM. A 50 MB image would fit, and your controller
   makes it straightforward. But it caps at SDRAM size (shared with the
   ascaler), only allows one image at a time — the QL-SD driver actually
   supports up to eight, QXL.WIN through QXL8.WIN — costs mount time
   proportional to image size, and doesn't help R3 at all.

2. Have QNICE serve sectors on demand from the FAT32 file instead of
   preloading. That lifts the size limit entirely, allows several images,
   removes the write-back flush, and works on every board. It also helps any
   M2M core that wants real hard disks, not just mine. But it means changing
   shared framework code (`shell.asm`, `vdrives.vhd`).

My instinct is that (2) is the right answer and (1) is a workaround that
happens to fit my particular case. But it's your framework, so: is (2)
something you'd want upstream, and if so how would you want it shaped? If
there's a reason it wasn't built that way originally, I'd rather hear it now
than discover it halfway through.

Two smaller questions on the SDRAM controller either way:

- Should I work from the copy in C64MEGA65's develop branch, or wait for
  V2.1.0? I'm still on V2.0.1.
- On R4/R5/R6 the ascaler already claims SDRAM. Roughly how much is left for a
  core to use, and is that an intended use?

No rush on any of this — I know it's volunteer time.

Thanks,
Daniel (dfernande132)
QL4M65 — https://github.com/dfernande132/QL4M65
