# QL4M65 / CoreQL — mdv1 sustained-read bug, round 2: both proposed fixes tested on real hardware, neither worked

## Read this first

This is a **follow-up** to an earlier handoff document
(`.research/mdv1-sustained-read-bug-handoff.md`, in the same directory as
this file) which led to a detailed analysis by another reasoning model
(saved outside this repo at `E:\QL_MEGA65\Fase0\mdv1-sustained-read-analysis.md`
— **please read both of those files in full before anything else**). That
analysis proposed a precise, well-argued mechanism and two concrete fixes.
**Both fixes were implemented and tested on real MEGA65 R6 hardware. Neither
resolved the bug.** This document exists to report that negative result
precisely, add new symptom detail gathered since, and ask you to dig deeper
— explicitly not down the same path.

Please do not re-propose the previous analysis's central hypothesis (video
contention wait-states eating into a 7-CPU-cycle real-time budget) as the
sole explanation without addressing why disabling it entirely, on real
hardware, did not fix the problem (see "What was tried" below). It may
still be a *real, partial* contributing factor — the previous analysis's
reasoning (the exact cycle-budget arithmetic, the `maxfail=7` correlation,
the M2008 retrospective-control-experiment argument) was genuinely strong
and internally consistent, and none of that is being retracted — but
empirically it is evidently **not the whole story**, and there is very
likely at least one more, so far unidentified, bug.

You cannot run or test anything yourself; this is real FPGA hardware, not
simulation. Please read the RTL/VHDL yourself, carefully and completely,
rather than trusting summaries (including this one) at face value. If you
reach a confident conclusion, say so with exact file:line evidence. If you
cannot, say that plainly and recommend the most useful next experiment on
real hardware (this project has real MEGA65 R6 hardware available) rather
than forcing a weak conclusion.

## What was tried, in order, and the precise result of each

**Fix A (from the previous analysis) — disable ALL video-contention wait
states.** `CORE/vhdl/main.vhd`, the `i_ql_timing` instantiation, `enable`
generic input set to `'0'` instead of `'1'`. This makes `ql_timing.sv`
permanently hold `ram_delay_dtack <= 0` (confirmed by reading
`ql_timing.sv:44-48`: `if (reset || !enable) begin ... ram_delay_dtack <= 0;
end`), i.e. **zero wait states on every memory/IO access, always** — the
CPU's real-time polling loop for `zx8302` I/O reads should now have no
jitter at all from this mechanism. This was shipped as build `M2016` and
is **still in place** as of the current build (`M2017`) — confirmed by
re-reading the current source, this was not accidentally reverted.

**Result on hardware:** genuinely, measurably better (the user's own words:
"mucho más estable" / much more stable) but **sustained reads still fail**,
sometimes hanging completely.

**Fix B (found independently while investigating a NEW symptom that
appeared after Fix A) — the microdrive loader's clock-domain-crossing
handshake had no reset path at all.** The QNICE-side loader process
(`mdv1_loader_qnice`, `main.vhd`, clocked on `qnice_clk_i`) and its
core-clock-domain counterpart (`mdv1_loader_core`, clocked on `clk_main_i`)
implement a hand-driven `xpm_cdc_handshake` protocol to cross a loaded
byte-pair from QNICE's 50MHz domain into the QL core's 84MHz domain.
**Neither process had ANY `if reset = '1' then ...` branch** — if the
handshake protocol were ever interrupted mid-transaction, the QNICE side's
`mdv1_ld_busy` register could latch at `'1'` permanently (it only had a
power-up initial value, `:= '0'`, which only applies once, at FPGA
configuration time), permanently asserting `qnice_mdv1_wait_o` and hanging
every subsequent load attempt — **recoverable only by a full power cycle
(FPGA reconfiguration)**, not by any in-system reset, since neither process
ever checked one. This matched a real symptom precisely: after a hang, an
in-system reset would stop recognizing any microdrive change at all, and
only a power-off/power-on cycle would recover.

Fixed by adding a new `qnice_rst_i` port to `main.vhd` (wired from
`mega65.vhd`'s already-existing `qnice_rst_i`, the same signal used
successfully elsewhere for CSR resets) and proper reset handling to both
processes. Shipped as build `M2017` (still in place in the current build).

**Result on hardware, user's own words, verbatim (translated from
Spanish):** *"sigue quedándose atascado, el chess no funciona... no parece
que se haya arreglado nada"* (it's still getting stuck, chess doesn't
work... it doesn't seem like anything got fixed).

**So: as of the current build, BOTH fixes are in place simultaneously
(contention fully disabled AND the loader reset fix applied), and the core
hang/corruption symptom is still present, essentially unchanged from before
either fix.**

## Precise current symptom description (gathered directly from the user, verbatim detail preserved)

**`LRUN mdv1_boot` on a `.mdv` containing a two-stage program ("chess"):**
the microdrive image's `BOOT` file is itself a small loader program. It
loads successfully and runs (the screen shows "cargando chess..." — loading
chess..., printed by the boot program itself once it's running), and it
then tries to load the actual, larger chess program as a second read from
the same microdrive. **This second load never completes. It hangs
completely** (not "eventually fails after several retries" — it simply
never finishes, indefinitely, as far as the user has waited).

**A second, separately-prepared `.mdv`:** the user started from a
previously-empty microdrive image (which read fine when empty — `DIR`
worked, nothing to list), then added one large program file to it via
another tool, and re-tested. **Now even `DIR mdv1_` (a catalog scan, not a
full data read) does not complete** on this image ("ya no va ni el dir" —
not even DIR works now). This is notable: earlier in the investigation,
`DIR` was reported as reliable/mostly-working after the M2011/M2012 loader
fix, even for other imperfect files; now, for THIS specific larger-content
image, even DIR fails.

Both of these point at the same underlying pattern that's been present
throughout this investigation: **the more data has to be read continuously
in one sitting, the more likely — now apparently to the point of a
complete, permanent hang, not just eventual failure — the read is to never
complete.** Small/short reads (a small BOOT stub, an empty catalog, small
games like "invaders"/"tetris") are reliable. Larger continuous reads are
not, and disabling the previously-suspected contention mechanism did not
fix this.

## An important, independent, parallel data point (in progress, not yet resolved)

The user is separately asking someone with genuine, real MiSTer hardware
running this same upstream QL_MiSTer core to test the exact same `chess`
`.mdv` file, to determine whether the file itself is a bad/corrupted dump
(in which case none of this project's RTL is at fault for THIS specific
file, though the second symptom — a freshly-authored large-content `.mdv`
also failing even at DIR — would still need explaining) or whether it
loads/runs correctly on genuine MiSTer hardware (which would conclusively
rule out "bad dump" and confirm the bug is specific to this MEGA65 port).
**This result is not available yet.** Please proceed with your own RTL
analysis in parallel rather than waiting for it, but keep in mind that if
the file turns out to be bad on real hardware too, that would only explain
the `chess`-specific case, not the independently-reported failure on the
freshly-authored large `.mdv`.

## Where to look (unchanged from the first handoff, repeated for convenience)

- `E:\QL_MEGA65\Fase0\DECISIONES.md` — read the sections from `M2004`
  through the end (the file grows with each build; `M2016`/`M2017` are the
  two most recent, documenting exactly what's described above in more
  detail, in Spanish).
- `E:\QL_MEGA65\Fase0\CoreQL\.research\PORTING-PLAN.md` section 0 for the
  current state snapshot.
- `E:\QL_MEGA65\Fase0\CoreQL\.research\mdv1-sustained-read-bug-handoff.md`
  — the original round-1 handoff, with the full file/architecture map
  (which files matter, both git repos involved, etc.) — **not repeated
  here, please read it.**
- `E:\QL_MEGA65\Fase0\mdv1-sustained-read-analysis.md` — the round-1
  external analysis this document is following up on. Read it in full; it
  contains real, verified findings (e.g. the BRAM read/write collision
  analysis via Vivado's `SYNTH-16` report, the clock-generation fidelity
  check, the register-decode verification against Minerva's actual source)
  that remain valid and should not be re-derived from scratch — only its
  central causal claim (video contention as the *sufficient* explanation)
  is now in question.
- `CORE\QL_MiSTer\rtl\mdv.v` — the microdrive controller, pristine
  upstream code, never modified.
- `CORE\QL_MiSTer\rtl\zx8302.v` — the QL I/O controller, modified only to
  expose an external `mdv1` link (5 new ports, documented in
  `doc/m2m/exceptions.md`).
- `CORE\vhdl\main.vhd` — this port's core-clock-domain wrapper; the
  microdrive loader FSMs, clock-enable generation, and the `i_ql_timing`
  instantiation (currently `enable => '0'`, Fix A above) all live here.
- `CORE\vhdl\mega65.vhd` — the QNICE-clock-domain CSR/dispatch logic for
  the manual-load protocol.

## Specific angles worth considering this round, given the negative result

1. **Is the cycle-budget/contention mechanism from round 1 real but only a
   partial contributor, with a second, independent mechanism also
   present?** Given fixing it measurably helped ("mucho más estable") but
   did not fully resolve the bug, this is plausible. What ELSE could eat
   into the microdrive protocol's real-time budget, or otherwise corrupt/
   stall sustained reads, that's independent of `ql_timing.sv`'s
   contention model? Consider: interrupt latency (does servicing some
   OTHER interrupt — vsync, the IPC/keyboard link, the real-time clock
   tick — ever block the CPU for longer than the microdrive protocol can
   tolerate, independent of memory wait-states entirely)? Bus arbitration
   elsewhere? Something about how `zx8302.v`'s own edge-detected `gap_irq`
   interacts with a LONG run of many consecutive gap transitions specifically
   (as opposed to the few that occur during a short catalog scan)?

2. **The new symptom (complete, indefinite hang rather than eventual
   failure-after-retries) may indicate a genuinely different failure mode**
   than the round-1 analysis's "occasional byte gets dropped, checksum
   fails, QDOS retries, eventually gives up after `maxfail=7`" model. A
   hang that never resolves, ever, sounds more like a genuine **protocol
   deadlock or livelock** (something waiting for a condition that
   structurally cannot occur) than a low-probability-per-byte corruption
   event that QDOS eventually gives up on. Please reconsider the microdrive
   protocol's actual state machines (both `mdv.v`'s own gap/sector timing
   and Minerva's `md/read.asm`/`md/serve.asm` polling and retry logic, cited
   extensively in the round-1 analysis) specifically for a scenario where
   Minerva's driver could end up waiting forever for a status-bit
   transition that never happens, as opposed to one that happens too late.

3. **Does the failure threshold/behavior depend on the read address range
   specifically (not just total volume)?** The freshly-authored
   large-content `.mdv` that now fails even at `DIR` was built by taking a
   previously-*empty* image (which worked) and adding a large file. Is
   there anything specific to reading through the **later/larger portion**
   of `mdv.v`'s buffer address space (higher `mem_addr` values, closer to
   `mdv_end`, or crossing more `mem_addr` wraparounds during one continuous
   read) that could behave differently than reading through a small,
   early portion? (`mdv.v`'s own read-pointer wraparound logic was
   examined in round 1 and found to cleanly reset every wrap with no
   state carried over — but consider re-verifying this given the new
   "even DIR fails on a large-content image" data point, since a full DIR
   catalog scan on a fuller disk would, for the first time, plausibly
   require traversing MUCH more of the address space / many more wraps
   than the smaller test cases that worked.)

4. **Is there anything in the QNICE-side loading step itself that could
   leave the BRAM buffer in a subtly inconsistent state specifically for
   LARGER images** (not the timing/CDC race already fixed in
   `M2011`/`M2012`, but something about total transfer duration, or
   something size-dependent in how the QNICE Shell's generic
   `LOAD_IMAGE` byte-copy loop, `M2M/rom/shell.asm`, interacts with the
   SD card filesystem driver for a longer transfer)? This hasn't been
   ruled out as thoroughly as the read side has.

## What "done" looks like

Same as round 1: a written report with your ranked hypothesis (or
hypotheses) for the root cause, exact file:line evidence, and — if you
can't reach a confident conclusion from static analysis — a precise
recommendation for what to build/instrument/observe next on real
hardware. Please take your time; this has now resisted three rounds of
investigation (two internal, one external) and a hasty pass is very
unlikely to add much.
