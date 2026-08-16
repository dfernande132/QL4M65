# QL4M65 / CoreQL — microdrive write (`SAVE`) bug: RTL implemented per design, two hardware-tested builds, still failing

## Read this first

This is Milestone 2 phase B (microdrive write support). Phase 1 (recon) and
phase 2 (design) are done and closed — **please read
`.research/microdrive-write-recon.md` and `.research/microdrive-write-design.md`
in full before anything else**, in that order. This document does not repeat
their content and assumes you already know the protocol facts, the byte
layout, the positional-write principle, and the design's own risk register
(R1-R8) established there.

Phase 3 (implementation) has produced **two builds, both tested on real
MEGA65 R6 hardware, both failing** — the first with one confirmed, fixed bug;
the second with a different, still-unexplained failure. You cannot run or
test anything yourself; this is real FPGA hardware, not simulation. Please
read the RTL yourself, carefully and completely, rather than trusting this
summary (or the reasoning in it) at face value. If you reach a confident
conclusion, say so with exact file:line evidence. If you cannot, say that
plainly and recommend the most useful next experiment on real hardware,
rather than forcing a weak conclusion.

## Files touched, following the design doc's own directives exactly

Per `.research/microdrive-write-design.md` §3-§7 and its "etapa 1" scope
(§8): the RTL write path only, no persistence yet (no dirty-sector bitmap,
no QNICE-side flush — those were planned as later stages and have not been
started).

- **`CORE/QL_MiSTer/rtl/mdv.v`** — the microdrive controller. **First
  modification of this file since it was imported pristine from upstream**
  (confirmed byte-identical to `MiSTer-devel/QL_MiSTer` master during recon —
  see `.research/microdrive-write-recon.md` §1). New ports (`wr_en`,
  `wr_strobe`, `wr_data`, `sector`, `wr_commit`, `dl_q`), the `region_base`/
  `region_state` positional anchor (design §3.2), the `mdv_sector` counter
  (design §3.3), the byte-pair accumulator (design §3.4), and the RAM port A
  priority mux (design §3.5). Full current file contents are pasted at the
  bottom of this document (it's short, ~280 lines) so you don't have to
  guess whether you're looking at the latest version.
- **`CORE/QL_MiSTer/rtl/zx8302.v`** — decodes `pc_tdata` (`$18022`) for the
  first time (design §4); exposes `mctrl[3:2]` (`pc..eras`/`pc..writ`).
- **`CORE/vhdl/main.vhd`** — wiring only, intra-domain (`clk_main_i`), no
  `xpm_cdc_*` needed at this stage (design §5.1). New signals declared
  ~line 260-264; `i_zx8302` instantiation gains the write-decode outputs
  ~line 712-715; `i_mdv1` instantiation gains the write-channel ports and
  `dl_q` ~line 1063-1072.
- **`CORE/vhdl/mdv_dpram.vhd`** — exposes the internal RAM's port A read-back
  (`q_a`, was `a_q_o => open`) so `mdv.v`'s new mux can serve `dl_q`.

Not touched: `mega65.vhd`, `globals.vhd`, `config.vhd`, `m2m-rom/m2m-rom.asm`
(the QNICE-side dirty bitmap / read-back / SD flush / menu item — design §6-7
— none of that exists yet, by design, at this stage).

## Build 1 (`M2022`): compiled clean, read regression passed, `SAVE` hung forever

Compiled clean (`WNS`/`WHS` positive in the domain that matters,
`clk_main_i`; a global hold-timing negative slack was isolated to `hr_rwds`,
the unused HyperRAM clock domain — confirmed unrelated, documented in
`DECISIONES.md`'s `M2022` section, not relevant to this bug). 0 unrouted
nets.

**Hardware test, user's own report:** the full phase-A read-regression
battery passed with no regression (`LOAD`/`DIR` on known-good images). But
`SAVE mdv1_dani` **never terminated** — it just kept running indefinitely,
with no error and no completion.

## Root cause found for build 1, and the fix (now build 2, `M2023`)

Per QDOS's own design (recon doc §6, and design doc §8's own acceptance
criteria): data-block writes are retried **without any limit** by
`md_serve` on verify failure (only the medium's own catalog/identity sector
has a bounded retry count, `maxfail=7` — see next section, this becomes
important again for build 2). So "`SAVE` never terminates" is the expected
signature of a write/verify mismatch: the CPU writes fine (no flow control
by design, D2), but whatever gets stored doesn't match what a later read
reproduces, so QDOS loops write→verify→fail forever.

**Root cause, confirmed by careful re-reading, not guessed:**
`mdv1_wr_strobe` (`zx8302.v`'s output, named `mdv_wr_strobe_o` there) is
generated inside a block gated by `cen` — the CPU bus clock enable, roughly
7.5MHz, derived from the 84MHz `clk`. Once the register is set to `1'b1`,
it is **not reassigned again until the next `cen` tick** (there is no
`always @(posedge clk) if(ce) ...` gating on the byte-write logic in
`zx8302.v` — it's a plain `else if(cen) begin ... end`), so from a
`clk`-rate perspective the pulse is held high for roughly 11 consecutive
`clk` cycles, not one.

`mdv.v`'s own new write accumulator (added in build 1) sampled `wr_strobe`
in a plain `always @(posedge clk)` block, **not gated by `ce`** — unlike
the rest of `mdv.v`'s pre-existing read state machine, which is entirely
`if(ce) begin ... end` and therefore never had this problem. Without its
own edge detection, that accumulator counted roughly 11 bytes for every
real byte the CPU wrote, corrupting the word-index mapping from the very
first byte of every session.

This is explicitly the design doc's own "risk R1" (§4.2, "el error más
probable de toda la fase 3") — but R1's mitigation (edge detection on
`prev_mdv_wr_sel` in `zx8302.v`, to stop one CPU `move.b` from generating
multiple `cen`-tick pulses) was implemented correctly and does work; it
just didn't cover this **second, independent** re-occurrence of the same
"signal held longer than the consumer's sample rate" problem one level
deeper in the pipeline (`cen`→`clk` domain-rate mismatch, not
`cpu_sel`/`cpu_wr` bus-cycle-width).

**Fix:** the identical edge-detection pattern, applied a second time,
inside `mdv.v`: a registered `wr_strobe_prev`, updated unconditionally every
`clk`; the accumulator now advances only on `wr_strobe && !wr_strobe_prev`.
See the full current file at the bottom of this document.

## Build 2 (`M2023`): different, still-unexplained failure

Compiled clean — this time **fully** clean, `WNS=+0.096ns`, `WHS=+0.052ns`
globally positive, 0 failing endpoints in any clock domain including
`hr_rwds` (which happened to close this time due to placement shifting;
not something targeted on purpose, not something to read into).

**Hardware test, user's own report (translated from Spanish, detail
preserved):**

> starts reading and takes a long time to stop... could that mean the
> recording corrupted the checksum? it takes a while trying to do `DIR
> mdv1_` and after a while "bad or changed medium" shows up

And, gathering the exact sequence more precisely:

> [tested with] `empty1` [a previously-`mdvcheck.py`-verified clean image],
> and also tried `empty2`, same result. If I do `DIR mdv1_` [before `SAVE`]
> it works. If I try `SAVE`, after 30s it says "bad medium", and if I then
> try `DIR mdv1_` afterward, that doesn't work either. If, after that, I
> switch to the chess image, that works [`DIR` succeeds on it]. If I then
> reload `empty1` again and do `DIR`, it works. But if I try `SAVE` [again,
> on this freshly-reloaded `empty1`], [it fails again].

Timing detail: "how long does it take before the error" → "quite a bit
more, half a minute or more" (not the previous "hangs forever" — this time
it does eventually return an error).

**This is fully reproducible**, not a one-off: two different
`mdvcheck.py`-verified clean source images (`empty1.mdv`, `empty2.mdv`)
both trigger it; reloading the source image from the menu (which fully
resets the RAM buffer to the pristine source file) always restores `DIR` to
working, but the very next `SAVE` attempt always fails the same way again.
Loading an unrelated, larger, non-empty image (`chess`) in between works
completely normally (`DIR` succeeds), which rules out a stuck/broken
hardware state and confirms the read path itself is still fully sound — the
corruption is something the **write** operation itself introduces into the
buffer content.

## My working hypothesis about the `maxfail=7` timing match (uncertain — flagging for your judgment, not asserting)

`DIR` failing **after** a failed `SAVE`, with a very specific ~30-53 second
delay before giving up, lines up arithmetically with `maxfail=7` (recon doc
§6: "`maxfail=7` [`md/serve.asm:135-140`] solo se aplica al sector de mapa
[not regular data blocks, which retry without limit]") combined with one
full tape lap taking roughly 255 sectors × ~30ms/sector ≈ 7.65 seconds:
7 × 7.65s ≈ 53.5 seconds, which is in the right ballpark for "medio minuto
o más" (half a minute or more).

If that arithmetic match is meaningful rather than coincidental, it would
suggest the write is not just producing wrong content in the **target**
sector (which would only affect verifying/reading `dani` specifically, and
would be caught by `SAVE`'s own write→verify loop — data blocks retry
without limit, so on its own that wouldn't explain `DIR` also failing
afterward with a bounded, `maxfail`-shaped timeout). It would suggest the
write is, in some way, **also or instead** corrupting whatever sector QDOS
needs to recognize the medium as valid at all (this project's own read-bug
investigation established a precedent for this exact class of symptom —
see `DECISIONES.md`'s account of `Quill2.mdv`, where all-corrupt sector
headers made even `DIR` fail via a busy-wait tied to medium recognition,
not per-file catalog listing).

**I have not been able to confirm this mechanism, only the arithmetic
coincidence.** I looked for, and could not rule out or confirm with
confidence, whether `region_base` could ever anchor to a wrong/stale
address such that a write consistently lands somewhere other than the
sector QDOS actually intends (which would be the natural explanation if the
hypothesis above is right). Please treat this as one candidate angle to
investigate, not a conclusion.

## What I already re-verified carefully and currently believe is correct (please still check independently)

I re-read `mdv.v` and `zx8302.v` in full, multiple times, specifically
re-deriving the following by hand against the design doc rather than
trusting my own first-pass implementation:

- **Byte order**: first byte written = high byte of the word pair
  (`wr_byte_hi` captured on the first byte of a pair, `wr_word <=
  {wr_byte_hi, wr_data}` on the second) — matches `dout`'s own read-side
  convention (`mdv.v`: `dout = mdv_bit_cnt[3] ? mdv_data[7:0] :
  mdv_data[15:8]`, high byte served first) and the existing QNICE loader's
  own convention (design doc §3.4 cites `main.vhd`'s
  `mdv1_ld_word_data <= mdv1_ld_byte0 & data(7 downto 0)`).
- **Word-index arithmetic**: `wr_word_idx = wr_byte_cnt[8:1]`, traced by
  hand cycle-by-cycit through the first two byte pairs, correctly yields
  word index 0 for bytes 0-1, word index 1 for bytes 2-3, etc.
- **`region_base`/`region_state` anchoring (D1)**: `mem_addr` genuinely does
  not advance during a gap (only incremented in the non-gap `else` branch),
  so `region_base <= mem_addr` captured repeatedly throughout a gap
  converges to a single stable, correct value before the gap ends, and
  `region_state <= !mdv_gap_state` captured at the same instant `mdv_gap_state`
  itself flips (same clock edge, non-blocking assignment) correctly predicts
  the *new* state of the incoming region, not the outgoing one. I traced
  this through the full state machine, including the exact tick where
  `mdv_gap_cnt == 34`.
- **Timing margin**: per the recon doc's own §5 timeline, `wr_en` (`mctrl[2]`)
  only goes high (~t≈7525µs in that timeline) essentially at the same moment
  as the very first real byte write — well after the preceding gap has
  already ended and `region_base` has long since stabilized — so there
  should be no race between when the anchor is captured and when the first
  strobe arrives.
- **RAM port mux**: `wr_addr`/`wr_word`/`wr_do` are all set via non-blocking
  assignment in the same clocked block, same branch, so they update
  atomically together — no stale-data hazard between them.
- **`wr_in_range` bounds**: `region_state ? word_idx<329 : word_idx<14`
  covers the full data-region width (329 words); a normal 538-byte/269-word
  `md_write` session never gets close to that boundary, so no accidental
  spill into the next sector under normal operation.

None of this rules out a bug I'm simply not seeing. I have **not** been
able to test any hypothesis directly on hardware myself (no debug overlay,
no QNICE-side buffer read-back exists yet at this stage — see design doc
§8, that's stage 2/`etapa 2`, not built), so everything above is static
analysis only, same limitation the original recon/design work had before
phase 3 started.

## Where to look

- `.research/microdrive-write-recon.md`, `.research/microdrive-write-design.md`
  — read first, in full, as stated above.
- `E:\QL_MEGA65\Fase0\DECISIONES.md` — search for `M2022` and `M2023` for
  the full build-by-build writeup in Spanish (more detail than this
  document, including the exact Vivado timing numbers).
- `CORE/QL_MiSTer/rtl/mdv.v`, `CORE/QL_MiSTer/rtl/zx8302.v` — pasted in
  full below for convenience, but these paths are the authoritative,
  current source if anything here is stale.
- `CORE/vhdl/main.vhd` — the wiring; not pasted in full (it's a large
  file), but the relevant line ranges are cited above under "Files
  touched".
- `Minerva-source/md/write.asm`, `md/serve.asm`, `md/read.asm` — Minerva's
  own driver source, already extensively cited in the recon doc; re-read
  directly rather than trusting the recon doc's excerpts if precision
  matters (e.g. to verify or refute the `maxfail=7`/"sector de mapa"
  hypothesis above — what exactly is "el sector de mapa", is it a fixed
  sector or however many sectors `DIR`'s own catalog scan happens to touch,
  and does `SAVE`'s write ever touch a sector other than the one it
  intends to?).

## Specific angles worth considering

1. **Is there a real, concrete mechanism by which `region_base` could
   anchor to the wrong sector** — not "the right sector, wrong byte
   offset within it" (which would produce a checksum failure confined to
   that one sector, retried without limit, matching build 1's symptom
   more than build 2's), but genuinely a **different physical sector**
   than the one Minerva/QDOS intends? This is the one thing I could not
   rule in or out with confidence from static reading alone.
2. **What exactly is "el sector de mapa" that `maxfail=7` protects, and
   what does `DIR mdv1_` need to read before it can even start listing
   files?** Precise Minerva source citation would settle whether the
   `maxfail=7` timing coincidence above is meaningful or spurious.
3. **Does `SAVE` on a brand-new/empty medium do anything beyond the single
   `md_write` call already covered by the design doc** — e.g. does saving
   the very first file to an empty cartridge require an additional write to
   register the new file in some catalog/allocation structure, via a
   separate `md_write` or `md_wblok` call to a different sector, close in
   time to the main data write? If so, is there any state in `mdv.v`'s new
   write-channel logic (`wr_byte_cnt`, `wr_pending`, `region_base`) that
   could bleed between two back-to-back write sessions if `mctrl[2]`
   doesn't cleanly drop to 0 between them?
4. Given both failing images were **empty** carts (first file ever saved)
   and the working case was a **populated** cart being read (not written)
   — is there anything specific to the very first write to a previously
   pristine/all-free cartridge that could differ from a write to an
   already-populated one?

## What "done" looks like

A ranked hypothesis (or hypotheses) for why `SAVE` still corrupts the
medium after the `M2023` fix, with exact file:line evidence from `mdv.v`/
`zx8302.v`/`main.vhd`/Minerva's own source — or, if static analysis alone
can't settle it, a precise, minimal recommendation for what to instrument
or observe on real hardware next (this project has real MEGA65 R6 hardware
available, but currently no way to dump the microdrive buffer's live
content for offline inspection — that capability doesn't exist yet at this
stage of the project).

---

## Exact diff, `M2022` → `M2023` (the fix described above, nothing else changed)

```diff
--- a/rtl/mdv.v
+++ b/rtl/mdv.v
@@ -239,14 +239,26 @@ reg         wr_do;       // pulso: hay una palabra que confirmar en este ciclo
 reg  [16:0] wr_addr;
 reg  [15:0] wr_word;
 
+// QL4M65 fase B (fix post-M2022): wr_strobe llega desde zx8302.v generado en
+// un bloque gateado por cen (~7.5MHz) - una vez a 1'b1, se queda retenido a
+// ritmo de clk COMPLETO (84MHz) hasta el siguiente tick de cen, no es un
+// pulso de 1 ciclo de clk. Este bloque muestrea a ritmo de clk (sin gatear
+// por ce, a diferencia del resto de la maquina de estados de lectura), asi
+// que sin deteccion de flanco aqui tambien, contaria cada byte real como
+// ~11 bytes (uno por cada ciclo de clk que wr_strobe se mantiene en alto) -
+// exactamente el riesgo R1 del diseno, colado un nivel mas adentro de lo
+// que protegia la deteccion de flanco de zx8302.v.
+reg wr_strobe_prev;
+
 always @(posedge clk) begin
 	wr_do <= 1'b0;
+	wr_strobe_prev <= wr_strobe;
 
 	if(!wr_session) begin
 		wr_byte_cnt <= 9'd0;      // cada sesion empieza de cero
 		wr_pending  <= 1'b0;
 	end
-	else if(wr_strobe) begin
+	else if(wr_strobe && !wr_strobe_prev) begin
 		wr_byte_cnt <= wr_byte_cnt + 9'd1;
 		if(!wr_pending) begin
 			wr_byte_hi <= wr_data;         // byte alto: el primero del par
```

`rtl/zx8302.v` and `CORE/vhdl/main.vhd` did **not** change between `M2022`
and `M2023` — only `mdv.v` did, with the diff above. The `M2022` build
(read regression clean, `SAVE` hangs forever) already had the full
`zx8302.v`/`main.vhd`/`mdv_dpram.vhd` changes described under "Files
touched" above; `M2023` only adds this one edge-detection fix on top.

## Source files (please read directly rather than relying on excerpts above)

- `CORE/QL_MiSTer/rtl/mdv.v` (280 lines)
- `CORE/QL_MiSTer/rtl/zx8302.v` (467 lines)
- `CORE/vhdl/main.vhd` (large file; relevant ranges cited above under
  "Files touched")
- `CORE/vhdl/mdv_dpram.vhd` (small, ~80 lines)
