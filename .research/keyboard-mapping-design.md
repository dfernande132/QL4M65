# Keyboard mapping redesign — "MEGA65-native symbols" (design doc, NOT YET IMPLEMENTED)

Status: **design for review**. Nothing in `keyboard.vhd` has been touched yet.
Review this together with the Main ROM / Back ROM design before either goes
into code — both are queued for the same next implementation pass.

## Decision (confirmed in chat)

Whatever symbol is silkscreened on a MEGA65 key is what must appear when
typing on the QL — not whatever the real Sinclair QL keyboard happens to
have in that shift position. Confirmed example: MEGA65 Shift+2 -> `"`,
MEGA65 Shift+7 -> `'`. The QL's own apostrophe/quote key (today driven by
`m65_colon`, see below) is being *replaced* by these two combos, not kept
as a third way to reach the same characters.

This is a deliberate, MEGA65-first divergence from the real QL (and from
upstream MiSTer's own PS/2 table, which keeps QL-native shift symbols).
Not "wrong", just a different, explicit product decision for this port.

## Ground truth used

1. **`CORE/QL_MiSTer/rtl/keyboard.v` lines 143-217** — the *original*
   MiSTer core's PS/2-scancode -> QL-matrix-bit table. This is
   authoritative for "which matrix bit is which physical key" (both
   ports, ours and upstream, use the exact same byte/bit matrix layout).
   It does NOT tell us shift-symbols (PS/2 scancodes are shift-agnostic;
   the QL's own IPC firmware decides the character).
2. Real MEGA65 keyboard photo (user-supplied) for MEGA65's own legends.
3. Real Sinclair QL keyboard photo (user-supplied) + well-documented QL
   keyboard layout for the QL's own legends.
4. `keyboard.vhd`'s current mapping (source of truth for "what we do
   today").

## Symbol-key matrix budget (from the PS/2 table — hard limit)

The QL physically has exactly these dedicated symbol-bearing matrix
positions, each with an unshifted + a QL-shifted character:
`-`, `=`, Pound(£), `\`, `[`, `]`, `;`, `'`, `,`, `.`, `/` — 11 keys, plus
the 10 digit keys' own shift row. That is the entire budget available to
receive MEGA65 symbols. Anything that doesn't fit is an orphan (Table D).

---

## Table A — already correct today, no change

| MEGA65 key | QL target (today) | Note |
|---|---|---|
| A-Z | matching QL letter, unshifted | 1:1, unambiguous |
| 0-9 (unshifted) | matching QL digit, unshifted | 1:1, unambiguous |
| `,` / `<` (m65_comma) | QL `,` key, native shift | MEGA65 and QL agree: `,`/`<` on both |
| `.` / `>` (m65_dot) | QL `.` key, native shift | MEGA65 and QL agree: `.`/`>` on both |
| `/` / `?` (m65_slash) | QL `/` key, native shift | MEGA65 and QL agree: `/`/`?` on both |
| `;` (m65_semicolon, unshifted) | QL `;` key, unshifted | MEGA65's own unshifted legend already is `;` |
| `-` (m65_minus) | QL `-` key, unshifted | MEGA65's own legend already is `-` |
| `=` (m65_equal, unshifted) | QL `=` key, unshifted | MEGA65's own legend already is `=` |
| £ (m65_gbp) | QL Pound key | dedicated-to-dedicated, both sides agree |
| `'` via **Shift+Colon** (m65_colon + shift) | QL apostrophe key, QL-shifted | already gives `"` today — `ql_shift` already reflects real MEGA65 shift whenever no override applies, so this falls out for free. **Being replaced per the new design** (see Table B) so Shift+2 becomes the one true way to get `"`, not a second accidental path. |
| m65_left_crsr / m65_horz_crsr (right) / m65_up_crsr / m65_vert_crsr (down) | QL Left/Right/Up/Down | confirmed (user): 1:1, cursor-to-cursor, key to key. NOT to be confused with `m65_arrow_left`/`m65_arrow_up`, the separate PETSCII-symbol keys used elsewhere in this doc (Tables B/D) |
| RET/SPACE/TAB/ESC/CAPS/CTRL/ALT/SHIFT/F1-F5 | dedicated QL keys | already 1:1 |

## Table B — confirmed fixes (ready to implement, no further verification needed)

Each of these needs a new conditional: MEGA65 key pressed (with/without
MEGA65 shift as specified) drives a QL matrix bit that is *not* its own
"natural" QL counterpart, and forces `ql_shift` to a specific value
regardless of whatever MEGA65 shift is doing. Same technique already used
for F1/F3 -> F2/F4 (`ql_shift <= shift and key_pressed_n(m65_f1) and
key_pressed_n(m65_f3)`).

| MEGA65 combo | Today | New target | ql_shift forced to |
|---|---|---|---|
| Shift+2 | QL `2`+shift = `@` | QL apostrophe-key bit | **1** (QL-shifted = `"`) |
| Shift+7 | QL `7`+shift = `&` | QL apostrophe-key bit | **0** (QL-unshifted = `'`) |
| `@` (m65_at, unshifted) | nothing (unused key) | QL `2`-key bit | **1** (reproduces QL-native `@`, relocated off Shift+2) |
| `*` (m65_asterisk, unshifted) | nothing (unused key) | QL `8`-key bit | **1** (reproduces QL-native `*`, relocated off Shift+8) |
| Shift+6 | QL `6`+shift = `^` | QL `7`-key bit | **1** (reproduces QL-native `&`, relocated off Shift+7) |
| Shift+8 | QL `8`+shift = `*` | QL `9`-key bit | **1** (reproduces QL-native `(`, relocated off Shift+9) |
| Shift+9 | QL `9`+shift = `(` | QL `0`-key bit | **1** (reproduces QL-native `)`, relocated off Shift+0) |
| `+` (m65_plus, unshifted) | nothing (unused key) | QL `=`-key bit | **1** (confirmed: QL Shift+`=` = `+`, relocated off Shift+`=`) |
| Shift+`:` (m65_colon) | QL apostrophe-key, ql_shift=0 (unaffected — see Table A) | QL `[`-key bit | **0** (QL-unshifted = `[`; rationale: MEGA65's own Shift+`:` legend is `(`, already redundant since Shift+8 covers `(` above — free real estate for the two QL keys right of P, `[`/`]`) |
| Shift+`;` (m65_semicolon) | QL `;`, unaffected (see Table A) | QL `]`-key bit | **0** (QL-unshifted = `]`; same rationale — MEGA65's own Shift+`;` legend `)` is redundant since Shift+9 covers `)` above) |
| Shift+`@` (m65_at + shift) | nothing (unused combo — unshifted `@` is spoken for above) | QL ESC-key bit | **1** (confirmed, user: QL Shift+ESC = `©`, was orphaned — real QL keycap shows `©` above ESC) |

Unshifted `:` and `;` (m65_colon, m65_semicolon, no MEGA65 shift held) are
**unchanged** — they still drive the QL apostrophe-key and QL `;` exactly
as in Table A. Only the *shifted* combos above are new/redirected. This
resolves Table D's `[`/`]` orphans (moved out of Table D below) —
`m65_arrow_left` becomes free/idle once this lands (`m65_arrow_up` does
NOT stay idle — see Table D, it gets reassigned to `^`).

Unshifted 2, 7, 6, 8, 9, 0 keep typing their own digit as today — only
the *shifted* combos above get redirected. Shift+0 (MEGA65: `Ø`) is left
alone (Table D — no QL equivalent exists).

**Implementation note**: each row needs its own suppression term added to
`ql_shift`'s expression (so MEGA65's real shift key doesn't also leak
through when we're forcing a specific state), mirroring the existing
`key_pressed_n(m65_f1) and key_pressed_n(m65_f3)` pattern.

## Table C — empirical hardware checks (all resolved)

1. ~~Does QL Shift+`=` produce `+`?~~ **CONFIRMED (user, hardware):
   QL Shift+`=` = `+`.** Table B's `+` row (MEGA65's own dedicated `+`
   key, right of `0`) is now fully specified.
2. ~~What does QL Shift+Pound (£) produce?~~ **CONFIRMED (user, hardware):
   QL Shift+Pound = `~`.** Table E's CTRL+`,` proposal is fully specified.

Everything in Table B/E is now backed by either the well-documented
standard QL shift-row (`!@#$%^&*()` on 1-0, matching the QL keyboard
photo) or a direct hardware confirmation above. No open verification
items remain.

## Table E — extra technique: CTRL/MEGA-key combo legends as symbol donors

MEGA65 keycaps carry up to 4 legends: unshifted (bottom-right), shifted
(top-right), and two more small ones bottom-left reached via CTRL and/or
the MEGA (C=) key — the C64/C65 PETSCII graphics-character legends. These
are otherwise idle for a QL core and can donate symbols the same way
Table B's digit keys do: intercept "MEGA65 CTRL + key" before it reaches
`ql_ctrl`'s normal pass-through, and redirect to whatever QL bit+shift
produces the wanted character instead (same suppression pattern as
everywhere else in Table B).

Confirmed and ready to implement:

| MEGA65 combo | Legend used | New target | Status |
|---|---|---|---|
| CTRL+`,` (m65_comma) | small `~` on the `,`/`<` key | QL Pound-key bit, ql_shift=1 | confirmed (user, hardware: QL Shift+Pound = `~`) |
| CTRL+`=` (m65_equal) | — (chosen slot, no matching printed legend) | QL `-`-key bit, ql_shift=1 | confirmed (user: QL underscore `_` was Shift+`-` on the real QL; now reached via MEGA65 CTRL+`=` instead) |
| CTRL+`/` (m65_slash) | — (chosen slot, no matching printed legend) | QL `\`-key bit, ql_shift=0 | confirmed (user) — the one remaining Table D orphan (`\`) now has a home |
| CTRL+`:` (m65_colon) | — (chosen slot) | QL `[`-key bit, ql_shift=**1** | confirmed (user): QL-shifted `[`-key = `{`, the shifted twin of Table B's Shift+`:` -> `[` |
| CTRL+`;` (m65_semicolon) | — (chosen slot) | QL `]`-key bit, ql_shift=**1** | confirmed (user): QL-shifted `]`-key = `}`, the shifted twin of Table B's Shift+`;` -> `]` |
| CTRL+`.` (m65_dot) | — (chosen slot) | QL `\`-key bit, ql_shift=**1** | confirmed (user): produces `|`, the shifted twin of CTRL+`/` -> `\` above |

`m65_colon` and `m65_semicolon` now each carry three distinct QL
functions depending on modifier: unshifted (Table A, unchanged),
MEGA65-shifted (Table B, `[`/`]`), and MEGA65-CTRL (here, `{`/`}`). All
three need their own branch in the matrix-bit/ql_shift logic for these
two keys.

## Table D — orphans

`\` is resolved (Table E's CTRL+`/`). One reopened:

| QL character | Why orphaned | Proposed fix (awaiting confirmation) |
|---|---|---|
| `^` | Was QL-native Shift+6; MEGA65's own Shift+6 is now repurposed to `&` (Table B), leaving `^` with no MEGA65 trigger | `m65_arrow_up`, unmodified (now idle since Table B's `[` no longer needs it) -> QL `6`-key bit, ql_shift=**1** |

**MEGA65 characters with no QL slot available** — no fix possible/needed:

| MEGA65 key | Legend | Why orphaned |
|---|---|---|
| Shift+0 | `Ø` | Not part of the QL's character set via a simple key combo |

**Genuinely idle MEGA65 keys** (no QL function assigned anywhere in this
doc, freed up by the redesign — available for future use, left
disconnected otherwise):

| MEGA65 key | Was previously used for |
|---|---|
| m65_arrow_left | `[` placeholder (Table D, pre-redesign) — now superseded by Table B's Shift+`:` |
| m65_no_scrl | `\` placeholder (Table D, pre-redesign) — now superseded by Table E's CTRL+`/` |

`m65_arrow_up` is **not** idle — it's reassigned to `^` above, do not
confuse it with the two truly-idle keys in this list.

(`~` and `_` are no longer orphaned — see Table E. `[` and `]` are no
longer orphaned — see Table B.)

---

## Review notes

**Consistency pass done** (this revision): found and fixed two stale
claims left over from earlier edits — `m65_arrow_up` was listed both as
reassigned to `^` (Table D top) and as still idle (Table D bottom, now
removed); the "arrow_left/arrow_up both become idle" line near Table B
was corrected to only claim that for `arrow_left`. No other bit
conflicts found: every QL matrix bit is driven by exactly one MEGA65
combo per given modifier state (colon/semicolon each cleanly split three
ways by unshifted/MEGA-shift/MEGA-CTRL, no overlap).

**Two harmless incidental duplicates, noted for awareness, not fixed**
(matches the already-accepted pattern from Table A's original
apostrophe/`"` case — an old incidental path coexisting with a new
explicit one, same output, no conflict):
- MEGA65 Shift+`-` (m65_minus) isn't suppressed anywhere, so it still
  incidentally reaches QL's native `-`-key shifted = `_`, alongside
  Table E's explicit CTRL+`=`.
- MEGA65 Shift+`=` (m65_equal) isn't suppressed either, so it still
  incidentally reaches QL's native `=`-key shifted = `+`, alongside
  Table B's explicit dedicated `+` key.

**Implementation-pass proposal (not blocking this design)**: Table B's
`ql_shift`-forcing touches `ql_shift`'s combinational expression many
times over (2, 7, 6, 8, 9, `^`, plus the `@`/`*`/`+` unshifted-key cases
that force it to `1` unconditionally). Worth a small lookup-style
structure instead of one giant boolean when this actually gets coded.

**Open**: anything from the real QL keyboard photo misread here that
should be corrected before implementation — otherwise this design is
ready to build against.
