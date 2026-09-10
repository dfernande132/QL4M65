# Draft message to the MiSTer2MEGA65 maintainers (sy2002, MJoergen)

Status: DRAFT — not sent. Review before posting.
Where to post: GitHub Discussions on MiSTer2MEGA65 (or an issue, if Discussions
are not enabled). Not a PR — this is a "should I, and how?" question, asked
before any of the work is designed.

---

**Title:** Streaming disk images from SD instead of preloading them into a RAM buffer

Hi sy2002, MJoergen,

I'm building QL4M65, a Sinclair QL core on top of M2M. I've just got QL-SD /
QXL.WIN hard-disk images working end-to-end on a real R6 — the image mounts,
the QL boots from it, and a program stored inside it loads and runs.

The limitation I've run into: `LOAD_IMAGE` copies the *entire* disk image into
a linear mount buffer, and `HANDLE_DRV_RD` / `HANDLE_DRV_WR` then serve sectors
out of that buffer. So the maximum image size is whatever RAM the core can
dedicate to it — in my case a HyperRAM window, which caps me at a few MB. A
realistic QXL.WIN hard disk is 50-100 MB or more.

What I'd like to build is an alternative path where QNICE reads and writes
sectors directly from the FAT32 file on demand, so image size stops depending
on core RAM at all.

Before I design anything: is this something you'd want upstream in M2M, and if
so, how would you prefer it shaped? I'd rather agree the approach with you
first than build it my way and hand you something you'd want restructured.
Happy to do the work and submit it as a PR.

Thanks for the framework — it's been a pleasure to build on.

Daniel (dfernande132)
