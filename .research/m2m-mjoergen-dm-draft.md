# Draft private message to MJoergen (Michael Jørgensen)

Status: DRAFT — not sent.

## Provenance (get this right — sy2002 and MJoergen talk to each other)

The user privately asked sy2002, during the R3 tester period, whether he could
**write an SDRAM controller for the framework** (motivation: 8 MB of shared
HyperRAM is not enough for RAM-hungry cores). sy2002 replied that one already
exists — MJoergen's, going into M2M V2.1.0, silently tested in C64MEGA65 alphas
(develop branch, M2M/vhdl/controllers/SDRAM/sdram.vhd), used there for the
simulated REU — and said: "Please approach MJoergen directly, if you have
questions / need support. He is the author of the controller."

So this DM is follow-through on an explicit referral. It is NOT a reply about
disk images — that public thread is still unanswered by both.

## Already answered by reading the code — do NOT ask these

  - Avalon-MM interface: identical port-for-port to M2M's hyperram.vhd. No
    burst mode.
  - Coexistence: yes. C64MEGA65 develop, framework.vhd:973, "sdram_gen : if
    G_BOARD = "MEGA65_R3" generate" — R3 uses HyperRAM for everything; R4/R5/R6
    give SDRAM to the ascaler and keep HyperRAM for the rest. Runs at 100 MHz
    via G_CLOCK_SPEED_MHZ, same clock as HyperRAM, so no new clock domain. Take
    the M2M-integrated copy, not the standalone repo.

## Decisions behind this draft

  - The "big mount buffer in SDRAM" idea is DEAD: measured mount time is 6-7 s
    for a 1 MB image, so ~5-6 minutes for 50 MB. Unacceptable.
  - The new plan is SDRAM for QL main RAM. This restores the original
    QL_MiSTer architecture: QL.sv:363-390 and 687 put all QL RAM (including the
    4096k tier) in SDRAM with sdram_dtack stalling the CPU. The port dropped
    sdram_dtack only because there was no SDRAM controller available.
  - Milestone 3's "CPU main RAM belongs in BRAM" conclusion was based on three
    precedents that are all about HyperRAM, not SDRAM.
  - Ask both things in ONE message. Waiting two round-trips with a volunteer
    could cost a month, and his answer on streaming changes what gets built.

---

Hi Michael,

sy2002 pointed me your way. I had asked him whether I could write an SDRAM
controller for M2M — my QL core (QL4M65) keeps running out of the 8 MB
HyperRAM — and he told me you had already written one, that it's going into
V2.1.0, and that I should talk to you directly.

We were also in touch a while back, when you helped me chase down the HyperRAM
RWDS problem on MEGA65 R3 — you spotted the missing pblock for the HyperRAM
controller and suggested the IDELAY_VALUE sweep, which fixed it for two of my
testers. Thanks again for that.

I've read through your controller and the way C64MEGA65's develop branch wires
it up — the `G_BOARD` generate in framework.vhd, SDRAM for the ascaler on
R4/R5/R6 with HyperRAM keeping the rest, and the same Avalon-MM interface as
the HyperRAM controller. That answered most of what I was going to ask, so what
follows is what I'd like to do with it.

**What I want to use it for.** The original MiSTer QL core keeps all of the
QL's RAM in SDRAM — base memory and the 512k/768k/4096k expansion tiers alike —
with an `sdram_dtack` stalling the 68008 until data is ready. When I ported it
I had no SDRAM controller, so main RAM went into BRAM and `sdram_dtack` was
simplified away. That works, but BRAM is now the binding constraint: I recently
had to delete the 1 MB RAM option entirely to make room for the QL-SD hard-disk
support, and the design was at 96% BRAM before I split the RAM into
exactly-sized banks. With your controller I could put main RAM back in SDRAM
and offer up to the original 4 MB.

That would make QL4M65 a fairly different test case from the C64: you'd have a
CPU reading and writing main memory directly through the controller, with wait
states, rather than the ascaler's and the REU's more latency-tolerant traffic.
It stresses latency rather than bandwidth. If that's useful to you, I'm happy
to report back what I find — including the unpleasant bits.

Two questions on that:

- Should I work from the copy in C64MEGA65's develop branch, or wait for
  V2.1.0? I'm still on V2.0.1.
- On R4/R5/R6 the ascaler already claims SDRAM. Roughly how much is left for a
  core to use, and is a core claiming the rest an intended use?

**The other thing, which I'd value your opinion on before starting.** I have
QL-SD / QXL.WIN hard-disk images working on a real R6 — mount, boot, read and
write all confirmed — but M2M's `LOAD_IMAGE` copies the whole image into a
linear mount buffer and `HANDLE_DRV_RD` / `HANDLE_DRV_WR` serve sectors out of
it, so image size is capped by whatever RAM the core can spare. I measured the
mount: 6-7 seconds for 1 MB, so a realistic 50 MB QXL.WIN would take five or
six minutes to mount. Putting that buffer in SDRAM doesn't fix it — it just
moves it.

The fix I think is right is having QNICE serve sectors on demand from the FAT32
file instead of preloading. That lifts the size limit, allows several images at
once (the QL-SD driver supports up to eight: QXL.WIN through QXL8.WIN), removes
the write-back flush, and works on R3 too. It would help any M2M core that
wants real hard disks, not only mine. But it means changing shared framework
code, so: is that something you'd want upstream, and how would you want it
shaped? If there's a reason it wasn't built that way originally, I'd much
rather hear it now than find out halfway through.

No rush on any of this — I know it's volunteer time.

Thanks,
Daniel (dfernande132)
QL4M65 — https://github.com/dfernande132/QL4M65
