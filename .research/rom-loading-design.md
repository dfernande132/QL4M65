# Main ROM / Back ROM + auto-reset-on-load (design doc, NOT YET IMPLEMENTED)

Status: **design for review**. Nothing in `globals.vhd`/`config.vhd`/
`mega65.vhd`/`m2m-rom.asm` has been touched yet. Implement together with
the keyboard redesign in the same pass.

## Recap of the confirmed decision

Two fixed-size ROM slots instead of one variable-size one:
- **Main ROM**: 48 KB exactly, `$000000-$00BFFF` (Minerva, MGE, JS...).
- **Back ROM**: 16 KB exactly, `$00C000-$00FFFF` (TK2, Pascal...).
- A **"Remove Back ROM"** action zeroes the 16 KB Back ROM region.

This eliminates the M1043/M1044-era partial-write ambiguity entirely —
each load has one, fixed, known-in-advance size, no size-dependent
branching anywhere.

## Part 0 — ROOT CAUSE FOUND: the CSR/parser protocol was never implemented (this is why manual ROM loading has always frozen)

**This supersedes the earlier "reset doesn't fire" investigation.** The
freeze the user reports (progress bar completes -> OSD totally
unresponsive, can't even navigate to Close Menu) happens **before**
`OSM_SEL_POST` is ever reached — it is not a reset-gating bug at all.

`HANDLE_CRTROM_M` (`M2M/rom/crts-and-roms.asm`), after the byte-copy loop
finishes, writes `CRTROM_CSR_STATUS = ST_OK` ("start cartridge parser")
into 4k window **0xFFFF** of the target device, then busy-waits **with
no timeout** reading `CRTROM_CSR_PARSEST` until the device answers
READY or ERROR. This is a generic M2M protocol
(`M2M/vhdl/qnice_csr.vhd`) that **every** manually-loadable
`C_CRTROMTYPE_DEVICE` target must implement on its own — our
`C_DEV_QL_MINERVA` case in `mega65.vhd` never did. It only handles plain
byte reads/writes; window 0xFFFF just falls through as an ordinary
(aliased, meaningless) BRAM access, so `CRTROM_CSR_PARSEST` never
reports anything QNICE is waiting for. QNICE's poll loop spins forever —
a genuine CPU lockup, not a core/display freeze, matching everything
observed: unresponsive OSD, no visual change, only a full hard reset
(which reboots QNICE too) ever recovered from it. **This bug predates
this session's changes entirely** — it's why the ~2s hard reset was the
original workaround from the very first request, not something M1042+
introduced.

Confirmed by cross-checking AExp's `adf_mount_wrapper.vhd`, which
manually loads its ADF the same way (`C_CRTROMTYPE_DEVICE`) and does
implement this protocol — its own header comment states it outright:
*"The Shell polls PARSEST with no timeout, so this FSM must ALWAYS
answer."* We never built the FSM that "always answers."

### The fix

Instantiate `work.qnice_csr` (generic, framework-provided, handles the
window-0xFFFF register decode) plus a small **size-check FSM** — much
simpler than AExp's ADF track validator, since ours only needs to
compare `qnice_req_length_o` against one fixed expected byte count and
answer READY/ERROR immediately (no HyperRAM, no iterative division
needed). One instance per ROM slot (Main: expects exactly 49152 bytes;
Back: expects exactly 16384 bytes) — this doubles as the "reject
wrong-size files outright" behavior confirmed below.

```vhdl
-- sketch, not final — one instance per slot, G_EXPECTED_SIZE = 49152 (Main) or 16384 (Back)
i_qnice_csr : entity work.qnice_csr
   generic map ( G_ERROR_STRINGS => C_ROM_ERROR_STRINGS )
   port map (
      qnice_clk_i => qnice_clk_i, qnice_rst_i => qnice_rst_i,
      qnice_addr_i => qnice_dev_addr_i, qnice_data_i => qnice_dev_data_i,
      qnice_ce_i => <this slot's scoped ce, i.e. qnice_dev_ce_i when qnice_dev_id_i = C_DEV_QL_MAINROM>,
      qnice_we_i => qnice_dev_we_i,
      qnice_data_o => csr_data, qnice_wait_o => csr_wait, qnice_csr_o => csr_active,
      qnice_req_status_o => req_status, qnice_req_length_o => req_length,
      qnice_resp_status_i => resp_status, qnice_resp_error_i => resp_error,
      qnice_resp_address_i => (others => '0')
   );

-- p_validate (falling_edge, mirrors qnice_csr.vhd's own convention):
--   VS_IDLE: on req_status = REQ_OK, latch req_length, -> VS_CHECK
--   VS_CHECK: resp_status <= READY when req_length = G_EXPECTED_SIZE else ERROR (resp_error <= "wrong size")
--   VS_DONE: hold response until req_status leaves REQ_OK (new load or idle) -> VS_IDLE
-- Normal byte writes to the ROM BRAM only happen when csr_active = '0'
-- (mirrors AExp's `qnice_hr_ce <= qnice_ce_i and not qnice_csr;`).
```

Where this lives: new small entity (or two instances of one generic
entity, `G_EXPECTED_SIZE`/`G_BYTE_OFFSET` generics) instantiated from
`mega65.vhd`, since — unlike AExp's ADF (HyperRAM-backed, needs an
Avalon bridge) — our ROM write path is a plain two-lane BRAM, simple
enough to keep the CSR+FSM logic close to where `ql_rom_u`/`ql_rom_l`
already live rather than a full separate wrapper module.

## Part 1 — splitting the shared BRAM into two independently-loadable halves

`ql_rom_u`/`ql_rom_l` (mega65.vhd) are a single pair of 64 KB BRAMs
(`ADDR_WIDTH => 15`, i.e. 32K words covering the whole $000000-$00FFFF
range) — that doesn't change. What changes is the QNICE *write* side.

Today: one QNICE device (`C_DEV_QL_MINERVA`, 0x0101) owns the whole
64 KB, `qnice_dev_addr_i(15 downto 1)` feeds `address_b` directly.

New: **two QNICE device IDs**, both still driving the *same* physical
`ql_rom_u`/`ql_rom_l` instances, muxed in `core_specific_devices`:

- `C_DEV_QL_MAINROM` (keep 0x0101) — address passed through unmodified,
  0 to 24575 (word address, = bytes 0-49151 = 48 KB).
- `C_DEV_QL_BACKROM` (new, 0x0102) — address gets **+24576 words**
  (`+49152` bytes = the 48 KB offset) added before it reaches
  `address_b`, so device-local byte 0 lands at BRAM byte 49152.

`globals.vhd`'s `C_CRTROMS_MAN` grows to 2 entries (both
`C_CRTROMTYPE_DEVICE`, one per device ID above); `C_CRTROMS_AUTO` also
grows to 2, both `C_CRTROMTYPE_OPTIONAL`, pointing at two fixed SD
paths — proposal: `/ql4m65/main.rom` and `/ql4m65/back.rom` (replaces
today's single `/ql4m65/ql.rom` — existing SD cards need `ql.rom`
renamed to `main.rom`).

Each manually-loadable device gets **hard size validation** at
load time (mirroring AExp's own ADF size guard, `HANDLE_CORE_IO`
pattern) — Main rejects anything != 48 KB, Back rejects anything
!= 16 KB, instead of silently accepting a wrong-size file and leaving
part of the BRAM stale like the old single-slot design did.

## Part 2 — "Remove Back ROM"

CRT/ROM menu items have **no native unmount/clear concept** in the M2M
framework (that's a vdrives-only concept — checked `shell.asm`:
`HANDLE_MOUNTING`'s CRT/ROM branch always opens the file browser
unconditionally, Return or Space makes no difference, unlike vdrives'
own `_HM_MOUNTED_C CMP OPTM_KEY_SELALT` unmount check which only runs
for already-mounted *virtual drives*). Overloading Space on the "Back
ROM:%s" line to mean "clear" would need intercepting the keypress
*before* `OPTM_RUN`'s normal dispatch even reaches `OPTM_CB_SEL` —
not something the framework's callback points (`OSM_SEL_PRE`/
`OSM_SEL_POST`) are positioned to veto.

**Proposal**: a third, separate OSD line, "Extract Back ROM" (confirmed
by user, ES "Extrae Back ROM"), implemented
as a *momentary action* single-select item — same pattern AExp already
uses for its "Reload Screen Config" item (`OPTM_G_SINGLESEL` flag, no
`OPTM_G_LOAD_ROM`/`OPTM_G_MOUNT_DRV`, handled entirely in
`OSM_SEL_POST` by group-ID check, `M2M$FORCE_MENU` resets the "=" marker
right after so it never shows as a persistent toggle). No file browser
involved at all — `OSM_SEL_POST` just switches `M2M$RAMROM_DEV` to
`C_DEV_QL_BACKROM` and loops 16 KB of zero-writes across its 4 4K-windows
(same window/address-increment shape as `CRTROM_AUTOLOAD`'s own byte
loop, just writing constant `0` instead of a file byte) — then falls
into the same auto-reset as Part 3 below, so the cleared Back ROM takes
effect immediately.

## Part 3 — auto-reset on load (already designed + hardware-verified in M1044)

M1044's unconditional-fire diagnostic confirmed: `OSM_SEL_POST` fires
reliably for every menu selection (verified via Close Menu), and a
core-only `M2M$CSR` reset does **not** disturb the manually-loaded ROM
bytes in BRAM (only a *physical hard reset* re-triggers
`CRTROM_AUTOLOAD`, which is expected/documented behavior, not a bug —
see chat history). Nothing left to investigate here; this part is ready
to re-gate and ship as-is once the group IDs below exist:

```
CMP OPTM_G_MAINROM, R8
RBRA _do_reset, Z
CMP OPTM_G_BACKROM, R8
RBRA _do_reset, Z
CMP OPTM_G_BACKROM_EXTRACT, R8
RBRA _do_reset, !Z      ; not one of the three -> skip
RSUB CLEAR_BACK_ROM, 1  ; only for the Extract case: zero the 16 KB
                        ; Back ROM region before falling into the reset
_do_reset:  ... (same M2M$CSR pulse as the M1043 implementation —
            confirmed by user: Extract must also reset, same as a load)
```

(Pseudocode — real implementation follows the existing OSM_SEL_POST
structure, just with three group IDs instead of one.)

## Part 4 — OSD menu structure (config.vhd)

`OPTM_ITEMS` grows from 4 lines to 6:
```
" Sinclair QL\n"          -- headline (unchanged)
" Main ROM:%s\n"          -- was " ROM:%s\n"
" Back ROM:%s\n"          -- new
" Extract Back ROM\n"     -- new, momentary action
"\n"                      -- separator (unchanged)
" Close Menu\n"           -- unchanged
```
`OPTM_SIZE` 4 -> 6. Per the M2M heap-budget rule (documented in AExp's
own AGENTS.md, applies identically here): growing `OPTM_ITEMS`/
`OPTM_SIZE` needs a `MENU_HEAP_SIZE`/`HEAP_SIZE` recheck in
`m2m-rom.asm` afterward — mechanical, not a design question, just don't
forget it during implementation.

## Open questions — ALL RESOLVED, ready to implement

1. ~~Auto-load SD paths~~ — **CONFIRMED: `/ql4m65/main.rom` +
   `/ql4m65/back.rom`.** If both exist, both load; if only `main.rom`
   exists, only Main loads (Back stays cleared/whatever the BRAM's
   power-on state is).
2. ~~"Extract Back ROM" as a third momentary-action menu line~~ —
   **CONFIRMED by user** (also confirmed: it triggers the same
   auto-reset as a normal load, per Part 3's pseudocode above).
3. ~~Hard size validation (reject wrong-size files outright)~~ —
   **CONFIRMED by user.**
4. `qnice_csr` + size-check FSM design (Part 0) — no objection raised,
   proceeding with the sketch as designed.

No open items remain across either design doc (this one and
`keyboard-mapping-design.md`). Both are ready to implement together.
