; ****************************************************************************
; YOUR-PROJECT-NAME (GITHUB-REPO-SHORTNAME) QNICE ROM
;
; Main program that is used to build m2m-rom.rom by make-rom.sh.
; The ROM is loaded by TODO-ADD-NAME-OF-VHDL-FILE-HERE.
;
; The execution starts at the label START_FIRMWARE.
;
; done by YOURNAME in YEAR and licensed under GPL v3
; ****************************************************************************

; If the define RELEASE is defined, then the ROM will be a self-contained and
; self-starting ROM that includes the Monitor (QNICE "operating system") and
; jumps to START_FIRMWARE. In this case it is assumed, that the firmware is
; located in ROM and the variables are located in RAM.
;
; If RELEASE is not defined, then it is assumed that we are in the develop and
; debug mode so that the firmware runs in RAM and can be changed/loaded using
; the standard QNICE Monitor mechanisms such as "M/L" or QTransfer.

#define RELEASE

; ----------------------------------------------------------------------------
; Firmware: M2M system
; ----------------------------------------------------------------------------

; main.asm is the mandatory, so always include it
; It jumps to START_FIRMWARE (see below) after the QNICE "operating system"
; called "Monitor" has been included and initialized
#include "../../M2M/rom/main.asm"

; Only include the Shell, if you want to use the pre-build core automation
; and user experience. If you build your own, then remove this include and
; also remove the include "shell_vars.asm" in the variables section below.
#include "../../M2M/rom/shell.asm"

; ----------------------------------------------------------------------------
; Firmware: Main Code
; ----------------------------------------------------------------------------

                ; Run the Shell: This is where you could put your own system
                ; instead of the shell
START_FIRMWARE  RBRA    START_SHELL, 1

; ----------------------------------------------------------------------------
; Core specific callback functions: Submenus
; ----------------------------------------------------------------------------

; SUBMENU_SUMMARY callback function:
;
; Called when displaying the main menu for every %s that is found in the
; "headline" / starting point of any submenu in config.vhd: You are able to
; change the standard semantics when it comes to summarizing the status of the
; very submenu that is meant by the "headline" / starting point.
;
; Input:
;   R8: pointer to the string that includes the "%s"
;   R9: pointer to the menu item within the M2M$CFG_OPTM_GROUPS structure
;  R10: end-of-menu-marker: if R9 == R10: we reached end of the menu structure
; Output:
;   R8: 0, if no custom SUBMENU_SUMMARY, else:
;       string pointer to completely new headline (do not modify/re-use R8)
;   R9, R10: unchanged

SUBMENU_SUMMARY XOR     R8, R8                  ; R8 = 0 = no custom string
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: File browsing and disk image mounting
; ----------------------------------------------------------------------------

; FILTER_FILES callback function:
;
; Called by the file- and directory browser. Used to make sure that the 
; browser is only showing valid files and directories.
;
; Input:
;   R8: Name of the file in capital letters
;   R9: 0=file, 1=directory
;  R10: @TODO: Future release: Context (see CTX_* in sysdef.asm)
; Output:
;   R8: 0=do not filter file, i.e. show file
FILTER_FILES    XOR     R8, R8                  ; R8 = 0 = do not filter file
                RET

; PREP_LOAD_IMAGE callback function:
;
; Some images need to be parsed, for example to extract configuration data or
; to move the file read pointer to the start position of the actual data.
; Sanity checks ("is this a valid file") can also be implemented here.
; Last but not least: The mount system supports the concept of a 2-bit
; "image type". In case this is used at the core of your choice, make sure
; you return the correct image type.
;
; Input:
;   R8: File handle: You are allowed to modify the read pointer of the handle
;   R9: @TODO: Future release: Context (see CTX_* in sysdef.asm)
; Output:
;   R8: 0=OK, error code otherwise
;   R9: image type if R8=0, otherwise 0 or optional ptr to  error msg string
PREP_LOAD_IMAGE XOR     R8, R8                  ; no errors
                XOR     R9, R9                  ; image type hardcoded to 0
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: Custom tasks
; ----------------------------------------------------------------------------

; PREP_START callback function:
;
; Called right before the core is being started. At this point, the core
; is ready to run, settings are loaded (if the core uses settings) and the
; core is still held in reset (if RESET_KEEP is on). So at this point in time,
; you can execute tasks that change the run-state of the core.
;
; Input: None
; Output:
;   R8: 0=OK, else pointer to string with error message
;   R9: 0=OK, else error code
PREP_START      INCRB
                XOR     R8, R8
                XOR     R9, R9
                DECRB
                RET

; OSM_SEL_POST callback function:
;
; Called each time the user selects something in the on-screen-menu (OSM),
; and while the OSM is still visible. This means, that this callback function
; is called on each press of one of the valid selection keys with the
; exception that pressing a selection key while hovering over a submenu entry
; or exit point does not call this function. All the functionality and
; semantics associated with a certain menu item is already handled by the
; framework when OSM_SELECTED is called, so you are not able to change the
; basic semantics but you are able to add core specific additional
; "intelligent" semantics and behaviors.
;
; Input:
;   R8: selected menu group (as defined in config.vhd)
;   R9: selected item within menu group
;       in case of single selected items: 0=not selected, 1=selected
;   R10: OPTM_KEY_SELECT (by default means "Return") or
;        OPTM_KEY_SELALT (by default means "Space")
; Output:
;   R8: 0=OK, else pointer to string with error message
;   R9: 0=OK, else error code
;
; QL4M65: "Main ROM:%s"/"Back ROM:%s" (OPTM_G_MAINROM/OPTM_G_BACKROM,
; config.vhd) are manual CRT/ROM loads - options.asm's OPTM_CB_SEL already
; ran HANDLE_MOUNTING (the actual file load into the QNICE device buffer)
; before calling us, so by the time we get here the new ROM is already
; sitting in ql_rom_u/l. Without a reset, the CPU keeps running against
; the old ROM's now-stale BRAM contents (previously required a manual ~2s
; hard reset - and worse, before M2M/vhdl/qnice_csr.vhd was wired up in
; mega65.vhd, QNICE itself hung solid on every manual load and a hard
; reset was the ONLY way out - see DECISIONES.md). Pulse the core reset
; via M2M$CSR the same way the boot sequence itself un-resets the core
; (shell.asm START_CONNECT) - reset_manager.vhd stretches this to the
; hardware-guaranteed minimum duration (RESET_COUNTER, config.vhd), so a
; short WAIT333MS here is enough headroom. Confirmed on real hardware
; (M1044): this core-only reset does not disturb the freshly-loaded ROM
; bytes in BRAM - only a *physical* hard reset re-runs CRTROM_AUTOLOAD
; and would revert to whatever's on the SD card, which is expected.
;
; "Extract Back ROM" (OPTM_G_BACKROM_EXTRACT) is a momentary action, no
; file browser involved: zero the 16K Back ROM device directly
; (CLEAR_BACK_ROM below), then reset the same way, so the cleared ROM
; takes effect immediately, same as a normal load. Two cosmetic fixes
; on top (found in testing): CRTROM_MAN_LDF only gets cleared by a real
; file load, so "Back ROM:%s" would otherwise keep showing the just-
; extracted ROM's stale name instead of reverting to "<Load>"; and
; being a plain OPTM_G_SINGLESEL item, "Extract Back ROM" would show a
; persistent "=" mark once triggered (same issue AExp's own "Reload
; Screen Config" momentary action guards against, same fix applied here:
; M2M$FORCE_MENU clears the selection, OPTM_SHOW repaints every label,
; OPTM_SELECT restores the cursor highlight).
;
; mdv1's SD write-back had a "Save mdv1" momentary action here for one
; build (M2026). Milestone 2 phase B etapa 4 (M2028) replaced it with a
; fully automatic background flush (MDV1_FLUSH_STEP, called from
; HANDLE_CORE_IO below) - see DECISIONES.md's M2028 section.
OSM_SEL_POST    INCRB

                CMP     OPTM_G_MAINROM, R8
                RBRA    _OSM_SP_RESET, Z
                CMP     OPTM_G_BACKROM, R8
                RBRA    _OSM_SP_RESET, Z
                CMP     OPTM_G_BACKROM_EXTRACT, R8
                RBRA    _OSM_SP_BEXTR, Z
                RBRA    _OSM_SP_RET, 1

_OSM_SP_BEXTR   RSUB    CLEAR_BACK_ROM, 1

                MOVE    CRTROM_MAN_LDF, R0
                ADD     1, R0                   ; Back ROM = manual CRT/ROM #1
                MOVE    0, @R0                  ; "not loaded" -> "%s" shows <Load>

                MOVE    OPTM_CUR_SEL, R8
                MOVE    @R8, R8
                XOR     R9, R9                  ; 0 = unselected
                RSUB    M2M$FORCE_MENU, 1
                RSUB    OPTM_SHOW, 1
                MOVE    OPTM_CUR_SEL, R8
                MOVE    @R8, R8
                MOVE    OPTM_SEL_SEL, R9
                RSUB    OPTM_SELECT, 1

_OSM_SP_RESET   MOVE    M2M$CSR, R0
                OR      M2M$CSR_RESET, @R0
                RSUB    WAIT333MS, 1
                AND     M2M$CSR_UN_RESET, @R0
                RBRA    _OSM_SP_RET, 1

_OSM_SP_RET     XOR     R8, R8
                XOR     R9, R9
                DECRB
                RET

; CLEAR_BACK_ROM: zeroes the entire 16K Back ROM device (C_DEV_QL_BACKROM)
; via the normal QNICE byte window (M2M$RAMROM_DEV/4KWIN/DATA) - no file,
; no parse step, this isn't a load, just a direct write of 4 windows x
; 4096 zero bytes. Trashes R0-R3; called from OSM_SEL_POST above only.
CLEAR_BACK_ROM  INCRB

                MOVE    M2M$RAMROM_DEV, R0
                MOVE    C_DEV_QL_BACKROM, @R0

                XOR     R1, R1                  ; R1: window number 0..3
_CBR_NXTWN      MOVE    M2M$RAMROM_4KWIN, R0
                MOVE    R1, @R0

                MOVE    M2M$RAMROM_DATA, R2     ; R2: write pointer
                MOVE    M2M$RAMROM_DATA, R3
                ADD     0x1000, R3              ; R3: end of this window
_CBR_NXTB       MOVE    0, @R2++
                CMP     R3, R2
                RBRA    _CBR_NXTB, !Z

                ADD     1, R1
                CMP     4, R1
                RBRA    _CBR_NXTWN, !Z

                DECRB
                RET

; ----------------------------------------------------------------------------
; QL4M65 (Milestone 2 phase B, etapas 3-4, M2026/M2028): microdrive
; write-back to SD - automatic in the background since M2028, see
; MDV1_FLUSH_STEP/HANDLE_CORE_IO further down.
; ----------------------------------------------------------------------------
;
; The design question this had to answer first: how does the write-back
; know the SD card path of the currently-loaded .mdv, to write into the
; right file? It doesn't need to - HNDL_RM_FILES[MDV1_MAN_IDX] already
; holds an open file handle from the original load (f32_fclose is never
; called anywhere in the M2M rom sources, confirmed by grep), and
; FAT32$FILE_OPEN opens for reading and writing at once (no separate
; mode) - so the same handle that loaded the image can be seeked and
; written directly. This is exactly the pattern shell.asm's own
; FLUSH_CACHE already uses for vdrives (HNDL_VD_FILES), just with the
; manually-loaded-CRT/ROM twin array instead, since mdv1 is not (and
; should not become) a vdrive - the microdrive is a continuous tape that
; has to be preloaded whole into mdv.v's own buffer, not a sector-
; addressable device vdrives.vhd's on-demand protocol expects (same
; reason AExp's own Amiga floppy doesn't use vdrives either). Checked
; against both AExp's and this framework's own write-back mechanisms
; before writing any of this - see DECISIONES.md's M2026 section.

; MDV1_ADDR2WIN: convert a 32-bit mdv1 device byte address into a
; M2M$RAMROM_4KWIN window number and an offset within that window.
; Input:  R8 = address hi, R9 = address lo
; Output: R8 = window number, R9 = offset within window (0..0xFFF)
MDV1_ADDR2WIN   INCRB
                MOVE    R9, R0                  ; R0: offset = lo & 0xFFF
                AND     0x0FFF, R0
                MOVE    R9, R1                  ; R1: lo >> 12
                SHR     12, R1
                MOVE    R8, R2                  ; R2: hi << 4
                SHL     4, R2
                OR      R1, R2                  ; R2: window = (hi<<4)|(lo>>12)
                MOVE    R2, R8
                MOVE    R0, R9
                DECRB
                RET

; READ_MDV1_BYTE: read one byte from the mdv1 device's linear address
; space (buffer bytes 0..C_MDV1_MAX_BYTES-1, or the dirty bitmap at
; C_MDV1_DIRTY_BASE..+31) via the generic M2M device window mechanism -
; same pattern as CLEAR_BACK_ROM above, one window/offset pair instead of
; a fixed 4-window sweep.
; Input:  R8 = address hi, R9 = address lo
; Output: R8 = byte value (0..255)
READ_MDV1_BYTE  INCRB
                RSUB    MDV1_ADDR2WIN, 1        ; R8: window, R9: offset
                MOVE    R8, R0
                MOVE    R9, R1

                MOVE    M2M$RAMROM_DEV, R8
                MOVE    C_DEV_QL_MDV1, @R8
                MOVE    M2M$RAMROM_4KWIN, R8
                MOVE    R0, @R8
                MOVE    M2M$RAMROM_DATA, R8
                ADD     R1, R8
                MOVE    @R8, R8                 ; R8: byte value

                DECRB
                RET

; READ_MDV2_BYTE: QL4M65 Milestone 2 paso 5, etapa 2 (2026-08-23) - mdv2's
; own counterpart, identical to READ_MDV1_BYTE above except for the device
; ID (C_DEV_QL_MDV2). MDV1_ADDR2WIN is reused as-is: the window/offset math
; is pure address arithmetic, independent of which device it's applied to.
; Input:  R8 = address hi, R9 = address lo
; Output: R8 = byte value (0..255)
READ_MDV2_BYTE  INCRB
                RSUB    MDV1_ADDR2WIN, 1        ; R8: window, R9: offset
                MOVE    R8, R0
                MOVE    R9, R1

                MOVE    M2M$RAMROM_DEV, R8
                MOVE    C_DEV_QL_MDV2, @R8
                MOVE    M2M$RAMROM_4KWIN, R8
                MOVE    R0, @R8
                MOVE    M2M$RAMROM_DATA, R8
                ADD     R1, R8
                MOVE    @R8, R8                 ; R8: byte value

                DECRB
                RET

; MDV1_FLUSH_STEP: one resumable step of the mdv1 SD write-back (Milestone
; 2 phase B etapa 4, M2028) - replaces the one-shot, blocking FLUSH_MDV1 of
; M2026/M2027, called from both HANDLE_CORE_IO below (background, gated)
; and OSM_SEL_PRE (forced, looped to completion before a reload).
;
; Cooperative multitasking, same discipline as vdrives' FLUSH_CACHE
; (M2M/rom/shell.asm) and AExp's own FLUSH_ADF_STEP (sy2002/AExp,
; CORE/m2m-rom/m2m-rom.asm - the same problem for its Amiga ADF floppy,
; which isn't a vdrive either). One real difference from both: mdv1's
; dirty bitmap only supports a single all-or-nothing hardware clear
; (globals.vhd's C_MDV1_DIRTY_CLR) - unlike vdrives' hardware dirty flag
; or AExp's WBC register, there is no per-sector write-1-to-clear. So
; this gates and snapshots entirely in software instead of relying on a
; hardware anti-thrash countdown: MDV1_GATE_CNT is a plain iteration
; counter (MDV1_GATE_THRESHOLD, an approximation - there is no real-time
; clock wired to QNICE here - tune to taste), reset whenever the live
; bitmap grows since the last idle check, so a burst of writes gets a
; fresh grace period instead of flushing on every single dirty sector.
;
; One call does at most one of:
;   * idle, nothing dirty: reset the gate, done
;   * idle, dirty sectors pending, gate closed (and not forced): count
;     the gate down, or reset it if new sectors went dirty since the
;     last check - work remains, but not yet
;   * idle, dirty sectors pending, gate open (or forced): freeze a
;     snapshot of the live bitmap for this pass, seek to the first
;     dirty sector in it
;   * active session: stream up to MDV1_FLUSH_CHUNK bytes of the current
;     sector, then f32_fflush - never leave a dirty SD sector buffer
;     across a yield, since the FAT32 hardware sector buffer is shared
;     with every other SD user polled from the very same wait loops
;     (e.g. the OSM settings save) - at sector end, seek to the next
;     dirty sector in this pass's snapshot, or - if none left - try to
;     close the pass out: re-read the live bitmap, and only clear it if
;     it is still IDENTICAL to the snapshot (nothing new went dirty
;     while this pass was running). Clearing unconditionally could
;     silently wipe the dirty flag for a sector this pass never actually
;     wrote. If new bits appeared, leave everything dirty for the next
;     pass instead - already-flushed sectors just risk being redundantly
;     rewritten, never lost.
;
; A card swap (SD_CHANGED) aborts any in-flight session and reports
; "clean" without touching the SD card or the dirty bitmap - the same
; "never write to a card we may not have opened this handle on"
; precedent as ROSM_INTEGRITY and AExp's own HANDLE_CORE_IO guard.
; Reporting "clean" here (rather than "work remains") also guarantees
; OSM_SEL_PRE's forced loop below can never hang on a stuck SD_CHANGED.
;
; FAT32 errors are FATAL, matching shell.asm's own FLUSH_CACHE policy
; for vdrives (write-back errors are not something to recover from
; gracefully here either).
;
; Persistent state lives in RAM (MDV1_FL_*/MDV1_GATE_CNT/MDV1_DIRTY_SNAP/
; MDV1_LAST_DIRTY/MDV1_BM_TMP, see the Variables section) rather than
; registers, since separate calls to this routine do not share a
; register bank - only a single call's own local work uses R0-R7
; (register-banked, safe across the RSUB/SYSCALL calls below) and R8-R11
; (global/parameter-passing, never expected to survive a call).
;
; Input:
;   R8: 0=respect the anti-thrashing gate (background), 1=force (used by
;       OSM_SEL_PRE, in a loop, before mdv1 gets reloaded)
; Output:
;   R8: 0=clean and idle (nothing left to do), 1=dirty work remains
MDV1_FLUSH_STEP INCRB
                MOVE    R8, R0                  ; R0: force flag

                MOVE    SD_CHANGED, R1
                CMP     1, @R1
                RBRA    _MFS_SDOK, !Z
                MOVE    MDV1_FL_STATE, R1
                MOVE    0, @R1
                RBRA    _MFS_RET0, 1

                ; nothing to flush if mdv1 was never loaded - CRTROM_INIT
                ; zeroes CRTROM_MAN_LDF at boot, and a zero/uninitialized
                ; file handle would crash the very first f32_fseek below
_MFS_SDOK       MOVE    CRTROM_MAN_LDF, R1
                ADD     MDV1_MAN_IDX, R1
                CMP     0, @R1
                RBRA    _MFS_RET0, Z

                MOVE    MDV1_FL_STATE, R1
                CMP     1, @R1
                RBRA    _MFS_CHUNK, Z

                ; --- idle: read the live 32-byte dirty bitmap fresh
                ; (C_MDV1_DIRTY_BASE_HI/_LO: the real address, 0x30000,
                ; does not fit a 16-bit QNICE word/.EQU - see the constant
                ; declarations below) ---
                MOVE    MDV1_BM_TMP, R1         ; R1: destination pointer
                XOR     R2, R2                  ; R2: byte index 0..31
_MFS_RDBM       MOVE    C_MDV1_DIRTY_BASE_HI, R8
                MOVE    C_MDV1_DIRTY_BASE_LO, R9
                ADD     R2, R9                  ; no carry possible: max 0+31
                RSUB    READ_MDV1_BYTE, 1       ; R8: byte value
                MOVE    R8, @R1++
                ADD     1, R2
                CMP     32, R2
                RBRA    _MFS_RDBM, !Z

                ; anything dirty at all?
                MOVE    MDV1_BM_TMP, R1
                MOVE    32, R2
                XOR     R3, R3                  ; R3: OR-accumulator
_MFS_CHKZ       OR      @R1++, R3
                SUB     1, R2
                RBRA    _MFS_CHKZ, !Z
                CMP     0, R3
                RBRA    _MFS_IDLECLEAN, Z

                CMP     1, R0                   ; forced? skip the gate
                RBRA    _MFS_STARTPASS, Z

                ; unchanged since the last idle check?
                MOVE    MDV1_BM_TMP, R1
                MOVE    MDV1_LAST_DIRTY, R2
                MOVE    32, R3
_MFS_CMPLAST    MOVE    @R1++, R5
                CMP     @R2++, R5
                RBRA    _MFS_NEWDIRT, !Z
                SUB     1, R3
                RBRA    _MFS_CMPLAST, !Z

                MOVE    MDV1_GATE_CNT, R1       ; unchanged: count the
                CMP     0, @R1                  ; anti-thrash gate down
                RBRA    _MFS_STARTPASS, Z       ; gate open: start the pass
                SUB     1, @R1
                RBRA    _MFS_RET1, 1            ; gated: work remains

_MFS_NEWDIRT    MOVE    MDV1_BM_TMP, R1         ; new sectors went dirty:
                MOVE    MDV1_LAST_DIRTY, R2     ; remember them and restart
                MOVE    32, R3                  ; the grace period
_MFS_SAVELAST   MOVE    @R1++, @R2++
                SUB     1, R3
                RBRA    _MFS_SAVELAST, !Z
                MOVE    MDV1_GATE_CNT, R1
                MOVE    MDV1_GATE_THRESHOLD, @R1
                RBRA    _MFS_RET1, 1

_MFS_IDLECLEAN  MOVE    MDV1_GATE_CNT, R1       ; nothing dirty: keep the
                MOVE    MDV1_GATE_THRESHOLD, @R1 ; gate primed for the
                RBRA    _MFS_RET0, 1            ; next burst

                ; --- start a new pass: freeze the snapshot, arm sector 0 ---
_MFS_STARTPASS  MOVE    MDV1_BM_TMP, R1
                MOVE    MDV1_DIRTY_SNAP, R2
                MOVE    32, R3
_MFS_FREEZE     MOVE    @R1++, @R2++
                SUB     1, R3
                RBRA    _MFS_FREEZE, !Z
                MOVE    MDV1_FL_SECTOR, R1
                MOVE    0, @R1
                RBRA    _MFS_FINDNEXT, 1

                ; --- active session: stream one chunk of the current
                ; sector, then f32_fflush (never leave a dirty SD sector
                ; buffer across a yield - see this routine's own header) ---
_MFS_CHUNK      MOVE    HNDL_RM_FILES, R7       ; R7: file handle
                ADD     MDV1_MAN_IDX, R7
                MOVE    @R7, R7

                MOVE    MDV1_FL_SECTOR, R6      ; R6: sector number
                MOVE    @R6, R6
                MOVE    R6, R8
                MOVE    686, R9
                SYSCALL(mulu, 1)                ; R11:R10 = sector*686 (hi:lo)
                MOVE    R10, R4                 ; R4/R5: sector base addr
                MOVE    R11, R5

                MOVE    MDV1_FL_BYTE, R1
                MOVE    @R1, R1                 ; R1: byte-within-sector
                MOVE    MDV1_FLUSH_CHUNK, R2    ; R2: bytes left in this chunk

_MFS_WLOOP      MOVE    R4, R0                  ; addr lo = base_lo+R1
                MOVE    R5, R3                  ; addr hi = base_hi(+carry)
                ADD     R1, R0                  ; sets carry on 16-bit overflow
                ADDC    0, R3                   ; same idiom as FAT32$FILE_RWB

                MOVE    R3, R8                  ; R8: addr hi
                MOVE    R0, R9                  ; R9: addr lo
                RSUB    READ_MDV1_BYTE, 1       ; R8: byte value

                MOVE    R8, R0                  ; R0: byte value (stash - R8
                                                 ; is about to become the
                                                 ; file handle for f32_fwrite)
                MOVE    R7, R8                  ; R8: file handle
                MOVE    R0, R9                  ; R9: byte to write
                SYSCALL(f32_fwrite, 1)
                CMP     0, R9
                RBRA    _MFS_WROK, Z
                MOVE    ERR_FATAL_WRITE, R8
                RBRA    FATAL, 1

_MFS_WROK       ADD     1, R1
                CMP     686, R1
                RBRA    _MFS_CHUNKDONE, Z       ; sector finished early
                SUB     1, R2
                RBRA    _MFS_WLOOP, !Z

_MFS_CHUNKDONE  MOVE    MDV1_FL_BYTE, R3
                MOVE    R1, @R3                 ; persist the byte position

                MOVE    R7, R8                  ; drain the shared SD sector
                SYSCALL(f32_fflush, 1)          ; buffer before yielding
                CMP     0, R9
                RBRA    _MFS_FLUSHOK, Z
                MOVE    ERR_FATAL_WRITE, R8
                RBRA    FATAL, 1

_MFS_FLUSHOK    CMP     686, R1
                RBRA    _MFS_RET1, !Z           ; more bytes remain: same
                                                 ; sector, work remains

                MOVE    MDV1_FL_SECTOR, R3      ; sector done: advance and
                ADD     1, @R3                  ; look for the next dirty one

                ; --- find the next dirty sector from MDV1_FL_SECTOR onward
                ; in this pass's snapshot; arm it, or close the pass out ---
_MFS_FINDNEXT   MOVE    MDV1_FL_SECTOR, R6
                MOVE    @R6, R6                 ; R6: sector candidate

_MFS_SCAN       CMP     255, R6
                RBRA    _MFS_PASSDONE, Z        ; scanned past the end

                MOVE    R6, R1
                SHR     3, R1                   ; R1: bitmap byte index
                MOVE    MDV1_DIRTY_SNAP, R2
                ADD     R1, R2
                MOVE    @R2, R3                 ; R3: that bitmap byte
                MOVE    R6, R1
                AND     0x0007, R1              ; R1: bit index
                MOVE    1, R2                    ; R2: bit mask, built below
_MFS_SHIFTB     CMP     0, R1
                RBRA    _MFS_SHIFTED, Z
                SHL     1, R2
                SUB     1, R1
                RBRA    _MFS_SHIFTB, 1
_MFS_SHIFTED    AND     R2, R3
                RBRA    _MFS_FOUND, !Z

                ADD     1, R6                   ; not dirty: next sector
                RBRA    _MFS_SCAN, 1

_MFS_FOUND      MOVE    MDV1_FL_SECTOR, R1      ; persist and seek to it
                MOVE    R6, @R1
                MOVE    R6, R8
                MOVE    686, R9
                SYSCALL(mulu, 1)                ; R11:R10 = sector*686

                MOVE    HNDL_RM_FILES, R7
                ADD     MDV1_MAN_IDX, R7
                MOVE    @R7, R7                 ; R7: file handle
                MOVE    R7, R8
                MOVE    R10, R9
                MOVE    R11, R10
                SYSCALL(f32_fseek, 1)
                CMP     0, R9
                RBRA    _MFS_SEEKOK, Z
                MOVE    ERR_FATAL_SEEK, R8
                RBRA    FATAL, 1

_MFS_SEEKOK     MOVE    MDV1_FL_BYTE, R1
                MOVE    0, @R1
                MOVE    MDV1_FL_STATE, R1
                MOVE    1, @R1
                RBRA    _MFS_RET1, 1

                ; --- no more dirty sectors in this pass: try to close it
                ; out - only clear the hardware bitmap if it is still
                ; IDENTICAL to the snapshot this pass just flushed (see
                ; this routine's own header comment) ---
_MFS_PASSDONE   MOVE    MDV1_FL_STATE, R1
                MOVE    0, @R1

                MOVE    MDV1_BM_TMP, R1
                XOR     R2, R2
_MFS_RDBM2      MOVE    C_MDV1_DIRTY_BASE_HI, R8
                MOVE    C_MDV1_DIRTY_BASE_LO, R9
                ADD     R2, R9
                RSUB    READ_MDV1_BYTE, 1
                MOVE    R8, @R1++
                ADD     1, R2
                CMP     32, R2
                RBRA    _MFS_RDBM2, !Z

                MOVE    MDV1_BM_TMP, R1
                MOVE    MDV1_DIRTY_SNAP, R2
                MOVE    32, R3
_MFS_CMPCLR     MOVE    @R1++, R5
                CMP     @R2++, R5
                RBRA    _MFS_STILLDIRTY, !Z
                SUB     1, R3
                RBRA    _MFS_CMPCLR, !Z

                ; unchanged: safe to clear. C_MDV1_DIRTY_CLR (0x30020)
                ; sits 0x20 bytes into the same 4K window as
                ; C_MDV1_DIRTY_BASE (0x30000) - no need to recompute
                ; window/offset, just reuse the known window number and
                ; add the fixed offset.
                MOVE    M2M$RAMROM_DEV, R8
                MOVE    C_DEV_QL_MDV1, @R8
                MOVE    M2M$RAMROM_4KWIN, R8
                MOVE    C_MDV1_DIRTY_WIN, @R8
                MOVE    M2M$RAMROM_DATA, R8
                ADD     C_MDV1_DIRTY_CLR_OFS, R8
                MOVE    1, @R8                  ; any value clears the bitmap

                MOVE    MDV1_LAST_DIRTY, R1     ; bitmap is clean now
                XOR     R2, R2
                MOVE    32, R3
_MFS_CLRLAST    MOVE    R2, @R1++
                SUB     1, R3
                RBRA    _MFS_CLRLAST, !Z
                MOVE    MDV1_GATE_CNT, R1
                MOVE    MDV1_GATE_THRESHOLD, @R1
                RBRA    _MFS_RET0, 1

_MFS_STILLDIRTY MOVE    MDV1_GATE_CNT, R1       ; changed: leave it dirty,
                MOVE    MDV1_GATE_THRESHOLD, @R1 ; work remains for the
                RBRA    _MFS_RET1, 1            ; next pass

_MFS_RET0       XOR     R8, R8
                RBRA    _MFS_RET, 1
_MFS_RET1       MOVE    1, R8
_MFS_RET        DECRB
                RET

; MDV2_FLUSH_STEP: QL4M65 Milestone 2 paso 5, etapa 2 (2026-08-23) - mdv2's
; own resumable SD write-back step, identical logic to MDV1_FLUSH_STEP
; above (see that routine's own header for the full design rationale),
; duplicated rather than parametrized: this routine already carries three
; real hardware bugs' worth of hard-won timing/protocol detail (M2026-
; M2028), and it is entirely self-contained (own RAM state block, own
; device ID, no shared mutable state with mdv1's copy) - a mechanical
; rename carries far less risk than threading per-drive parameters through
; every line of a routine this delicate, for a routine only ever called
; from two fixed call sites (HANDLE_CORE_IO, OSM_SEL_PRE) rather than
; something that scales with more units. MDV1_ADDR2WIN, MDV1_FLUSH_CHUNK,
; MDV1_GATE_THRESHOLD, C_MDV1_DIRTY_BASE_HI/_LO/_WIN/_CLR_OFS, and the
; ERR_FATAL_*/HNDL_RM_FILES/CRTROM_MAN_LDF/SD_CHANGED globals are all
; reused as-is (device-independent or shared-format constants - see their
; own declarations).
;
; Input:
;   R8: 0=respect the anti-thrashing gate (background), 1=force
; Output:
;   R8: 0=clean and idle (nothing left to do), 1=dirty work remains
MDV2_FLUSH_STEP INCRB
                MOVE    R8, R0                  ; R0: force flag

                MOVE    SD_CHANGED, R1
                CMP     1, @R1
                RBRA    _MFS2_SDOK, !Z
                MOVE    MDV2_FL_STATE, R1
                MOVE    0, @R1
                RBRA    _MFS2_RET0, 1

_MFS2_SDOK      MOVE    CRTROM_MAN_LDF, R1
                ADD     MDV2_MAN_IDX, R1
                CMP     0, @R1
                RBRA    _MFS2_RET0, Z

                MOVE    MDV2_FL_STATE, R1
                CMP     1, @R1
                RBRA    _MFS2_CHUNK, Z

_MFS2_RDBM      MOVE    MDV2_BM_TMP, R1
                XOR     R2, R2
_MFS2_RDBM_L    MOVE    C_MDV1_DIRTY_BASE_HI, R8
                MOVE    C_MDV1_DIRTY_BASE_LO, R9
                ADD     R2, R9
                RSUB    READ_MDV2_BYTE, 1       ; R8: byte value
                MOVE    R8, @R1++
                ADD     1, R2
                CMP     32, R2
                RBRA    _MFS2_RDBM_L, !Z

                MOVE    MDV2_BM_TMP, R1
                MOVE    32, R2
                XOR     R3, R3
_MFS2_CHKZ      OR      @R1++, R3
                SUB     1, R2
                RBRA    _MFS2_CHKZ, !Z
                CMP     0, R3
                RBRA    _MFS2_IDLECLEAN, Z

                CMP     1, R0
                RBRA    _MFS2_STARTPASS, Z

                MOVE    MDV2_BM_TMP, R1
                MOVE    MDV2_LAST_DIRTY, R2
                MOVE    32, R3
_MFS2_CMPLAST   MOVE    @R1++, R5
                CMP     @R2++, R5
                RBRA    _MFS2_NEWDIRT, !Z
                SUB     1, R3
                RBRA    _MFS2_CMPLAST, !Z

                MOVE    MDV2_GATE_CNT, R1
                CMP     0, @R1
                RBRA    _MFS2_STARTPASS, Z
                SUB     1, @R1
                RBRA    _MFS2_RET1, 1

_MFS2_NEWDIRT   MOVE    MDV2_BM_TMP, R1
                MOVE    MDV2_LAST_DIRTY, R2
                MOVE    32, R3
_MFS2_SAVELAST  MOVE    @R1++, @R2++
                SUB     1, R3
                RBRA    _MFS2_SAVELAST, !Z
                MOVE    MDV2_GATE_CNT, R1
                MOVE    MDV1_GATE_THRESHOLD, @R1
                RBRA    _MFS2_RET1, 1

_MFS2_IDLECLEAN MOVE    MDV2_GATE_CNT, R1
                MOVE    MDV1_GATE_THRESHOLD, @R1
                RBRA    _MFS2_RET0, 1

_MFS2_STARTPASS MOVE    MDV2_BM_TMP, R1
                MOVE    MDV2_DIRTY_SNAP, R2
                MOVE    32, R3
_MFS2_FREEZE    MOVE    @R1++, @R2++
                SUB     1, R3
                RBRA    _MFS2_FREEZE, !Z
                MOVE    MDV2_FL_SECTOR, R1
                MOVE    0, @R1
                RBRA    _MFS2_FINDNEXT, 1

_MFS2_CHUNK     MOVE    HNDL_RM_FILES, R7
                ADD     MDV2_MAN_IDX, R7
                MOVE    @R7, R7

                MOVE    MDV2_FL_SECTOR, R6
                MOVE    @R6, R6
                MOVE    R6, R8
                MOVE    686, R9
                SYSCALL(mulu, 1)
                MOVE    R10, R4
                MOVE    R11, R5

                MOVE    MDV2_FL_BYTE, R1
                MOVE    @R1, R1
                MOVE    MDV1_FLUSH_CHUNK, R2

_MFS2_WLOOP     MOVE    R4, R0
                MOVE    R5, R3
                ADD     R1, R0
                ADDC    0, R3

                MOVE    R3, R8
                MOVE    R0, R9
                RSUB    READ_MDV2_BYTE, 1

                MOVE    R8, R0
                MOVE    R7, R8
                MOVE    R0, R9
                SYSCALL(f32_fwrite, 1)
                CMP     0, R9
                RBRA    _MFS2_WROK, Z
                MOVE    ERR_FATAL_WRITE, R8
                RBRA    FATAL, 1

_MFS2_WROK      ADD     1, R1
                CMP     686, R1
                RBRA    _MFS2_CHUNKDONE, Z
                SUB     1, R2
                RBRA    _MFS2_WLOOP, !Z

_MFS2_CHUNKDONE MOVE    MDV2_FL_BYTE, R3
                MOVE    R1, @R3

                MOVE    R7, R8
                SYSCALL(f32_fflush, 1)
                CMP     0, R9
                RBRA    _MFS2_FLUSHOK, Z
                MOVE    ERR_FATAL_WRITE, R8
                RBRA    FATAL, 1

_MFS2_FLUSHOK   CMP     686, R1
                RBRA    _MFS2_RET1, !Z

                MOVE    MDV2_FL_SECTOR, R3
                ADD     1, @R3

_MFS2_FINDNEXT  MOVE    MDV2_FL_SECTOR, R6
                MOVE    @R6, R6

_MFS2_SCAN      CMP     255, R6
                RBRA    _MFS2_PASSDONE, Z

                MOVE    R6, R1
                SHR     3, R1
                MOVE    MDV2_DIRTY_SNAP, R2
                ADD     R1, R2
                MOVE    @R2, R3
                MOVE    R6, R1
                AND     0x0007, R1
                MOVE    1, R2
_MFS2_SHIFTB    CMP     0, R1
                RBRA    _MFS2_SHIFTED, Z
                SHL     1, R2
                SUB     1, R1
                RBRA    _MFS2_SHIFTB, 1
_MFS2_SHIFTED   AND     R2, R3
                RBRA    _MFS2_FOUND, !Z

                ADD     1, R6
                RBRA    _MFS2_SCAN, 1

_MFS2_FOUND     MOVE    MDV2_FL_SECTOR, R1
                MOVE    R6, @R1
                MOVE    R6, R8
                MOVE    686, R9
                SYSCALL(mulu, 1)

                MOVE    HNDL_RM_FILES, R7
                ADD     MDV2_MAN_IDX, R7
                MOVE    @R7, R7
                MOVE    R7, R8
                MOVE    R10, R9
                MOVE    R11, R10
                SYSCALL(f32_fseek, 1)
                CMP     0, R9
                RBRA    _MFS2_SEEKOK, Z
                MOVE    ERR_FATAL_SEEK, R8
                RBRA    FATAL, 1

_MFS2_SEEKOK    MOVE    MDV2_FL_BYTE, R1
                MOVE    0, @R1
                MOVE    MDV2_FL_STATE, R1
                MOVE    1, @R1
                RBRA    _MFS2_RET1, 1

_MFS2_PASSDONE  MOVE    MDV2_FL_STATE, R1
                MOVE    0, @R1

                MOVE    MDV2_BM_TMP, R1
                XOR     R2, R2
_MFS2_RDBM2     MOVE    C_MDV1_DIRTY_BASE_HI, R8
                MOVE    C_MDV1_DIRTY_BASE_LO, R9
                ADD     R2, R9
                RSUB    READ_MDV2_BYTE, 1
                MOVE    R8, @R1++
                ADD     1, R2
                CMP     32, R2
                RBRA    _MFS2_RDBM2, !Z

                MOVE    MDV2_BM_TMP, R1
                MOVE    MDV2_DIRTY_SNAP, R2
                MOVE    32, R3
_MFS2_CMPCLR    MOVE    @R1++, R5
                CMP     @R2++, R5
                RBRA    _MFS2_STILLDIRTY, !Z
                SUB     1, R3
                RBRA    _MFS2_CMPCLR, !Z

                MOVE    M2M$RAMROM_DEV, R8
                MOVE    C_DEV_QL_MDV2, @R8
                MOVE    M2M$RAMROM_4KWIN, R8
                MOVE    C_MDV1_DIRTY_WIN, @R8
                MOVE    M2M$RAMROM_DATA, R8
                ADD     C_MDV1_DIRTY_CLR_OFS, R8
                MOVE    1, @R8                  ; any value clears the bitmap

                MOVE    MDV2_LAST_DIRTY, R1
                XOR     R2, R2
                MOVE    32, R3
_MFS2_CLRLAST   MOVE    R2, @R1++
                SUB     1, R3
                RBRA    _MFS2_CLRLAST, !Z
                MOVE    MDV2_GATE_CNT, R1
                MOVE    MDV1_GATE_THRESHOLD, @R1
                RBRA    _MFS2_RET0, 1

_MFS2_STILLDIRTY MOVE   MDV2_GATE_CNT, R1
                MOVE    MDV1_GATE_THRESHOLD, @R1
                RBRA    _MFS2_RET1, 1

_MFS2_RET0      XOR     R8, R8
                RBRA    _MFS2_RET, 1
_MFS2_RET1      MOVE    1, R8
_MFS2_RET       DECRB
                RET

; HANDLE_CORE_IO callback function:
;
; Called from HANDLE_IO (M2M/rom/shell.asm, "core-io-hook" - see that
; file's own comment) in every iteration of the main loop and of all
; blocking wait loops. QL4M65 uses the time slice for mdv1's background
; SD write-back (Milestone 2 phase B etapa 4, M2028): one gated step of
; MDV1_FLUSH_STEP above.
;
; Input/Output: none; all registers are preserved.
HANDLE_CORE_IO  SYSCALL(enter, 1)

                XOR     R8, R8                  ; 0 = respect the gate
                RSUB    MDV1_FLUSH_STEP, 1

                ; QL4M65 Milestone 2 paso 5, etapa 2: mdv2's own gated
                ; background flush, same time-slice pattern as mdv1's above.
                XOR     R8, R8                  ; 0 = respect the gate
                RSUB    MDV2_FLUSH_STEP, 1

                SYSCALL(leave, 1)
                RET

; OSM_SEL_PRE callback function:
;
; Identical to the OSM_SEL_POST callback function (see above) but it is being
; called before the functionality and semantics associated with a certain
; menu item has been handled by the framework.
;
; QL4M65 (Milestone 2 phase B, etapa 3/4, M2026/M2028): force-flush before
; mdv1 gets reloaded, looping MDV1_FLUSH_STEP with the force flag until it
; reports clean. options.asm calls OSM_SEL_PRE before shell.asm's own
; _LI_OPENFILE re-opens HNDL_RM_FILES for the new image - if we don't flush
; here first, any dirty sectors from a previous SAVE are silently lost the
; moment the new image overwrites the buffer (AExp's own ADF write-back
; hit this exact "stale FDH across re-mounts" bug class - .research/
; microdrive-write-design.md section 7.4 already flagged it as a risk).
; Returning non-zero here is FATAL (options.asm:1168-1171), not "cancel" -
; there is no way to offer a Y/N prompt from this callback, so this always
; flushes silently rather than asking. MDV1_FLUSH_STEP's own SD_CHANGED
; guard (see its header comment) guarantees this loop terminates even if
; the SD card was just swapped.
OSM_SEL_PRE     INCRB

                CMP     OPTM_G_MDV1, R8
                RBRA    _OSM_SPR_MDV2, !Z
_OSM_SPR_LOOP1  MOVE    1, R8                   ; 1 = force
                RSUB    MDV1_FLUSH_STEP, 1
                CMP     1, R8
                RBRA    _OSM_SPR_LOOP1, Z       ; work remains: keep going
                RBRA    _OSM_SPR_RET, 1

                ; QL4M65 Milestone 2 paso 5, etapa 2 (2026-08-23): mdv2,
                ; same force-flush-before-reload logic as mdv1 above.
_OSM_SPR_MDV2   CMP     OPTM_G_MDV2, R8
                RBRA    _OSM_SPR_RET, !Z
_OSM_SPR_LOOP2  MOVE    1, R8                   ; 1 = force
                RSUB    MDV2_FLUSH_STEP, 1
                CMP     1, R8
                RBRA    _OSM_SPR_LOOP2, Z       ; work remains: keep going

_OSM_SPR_RET    XOR     R8, R8
                XOR     R9, R9
                DECRB
                RET

; ----------------------------------------------------------------------------
; Core specific callback functions: Custom messages
; ----------------------------------------------------------------------------

; CUSTOM_MSG callback function:
;
; Called in various situations where the Shell needs to output a message
; to the end user. The situations and contexts are described in sysdef.asm
;
; Input:
;   R8: Situation (CMSG_* constants in sysdef.asm)
;   R9: Context   (CTX_* constants in sysdef.asm)
; Output:
;   R8: 0=no custom message available, otherwise pointer to string

CUSTOM_MSG      XOR     R8, R8
                RET              

; ----------------------------------------------------------------------------
; Core specific constants and strings
; ----------------------------------------------------------------------------

; Add your core specific constants and strings here

; Mirrors config.vhd's OPTM_G_MAINROM/OPTM_G_BACKROM/OPTM_G_BACKROM_EXTRACT/
; OPTM_G_MDV1 (the "Main ROM:%s"/"Back ROM:%s"/"Extract Back ROM"/
; "mdv1:%s" menu items' group IDs) - used by OSM_SEL_POST/OSM_SEL_PRE
; above. Keep in sync if config.vhd ever changes these.
OPTM_G_MAINROM         .EQU 1
OPTM_G_BACKROM         .EQU 2
OPTM_G_BACKROM_EXTRACT .EQU 3
OPTM_G_MDV1            .EQU 4
OPTM_G_MDV2            .EQU 5

; Mirrors globals.vhd's C_DEV_QL_BACKROM - used by CLEAR_BACK_ROM above.
C_DEV_QL_BACKROM       .EQU 0x0102

; QL4M65 (Milestone 2 phase B, etapa 3, M2026): mirrors globals.vhd's
; C_DEV_QL_MDV1/C_MDV1_DIRTY_BASE/C_MDV1_DIRTY_CLR, used by
; MDV1_FLUSH_STEP/READ_MDV1_BYTE above. C_MDV1_DIRTY_BASE/_CLR are
; 0x30000/0x30020 in globals.vhd - both exceed a 16-bit QNICE word, so
; they're mirrored here already split into the pieces the code actually
; needs (hi/lo for the bitmap's own base address; window+offset for the
; fixed-size bitmap and its single-word clear register, since 0x30000
; happens to be exactly 4K-aligned and 0x30020 sits in that same window,
; 0x20 bytes in).
C_DEV_QL_MDV1           .EQU 0x0103
C_MDV1_DIRTY_BASE_HI    .EQU 0x0003
C_MDV1_DIRTY_BASE_LO    .EQU 0x0000
C_MDV1_DIRTY_WIN        .EQU 48                 ; = 0x30000 / 4096
C_MDV1_DIRTY_CLR_OFS    .EQU 0x0020             ; = 0x30020 - 0x30000

; QL4M65 Milestone 2 paso 5, etapa 2 (2026-08-23): mirrors globals.vhd's
; C_DEV_QL_MDV2 - the only new per-drive constant mdv2 actually needs.
; C_MDV1_DIRTY_BASE_HI/_LO/_WIN/_CLR_OFS above are reused unchanged: the
; dirty bitmap sits at the same DEVICE-WINDOW-RELATIVE offset for every
; microdrive (same reasoning as mdv_qnice_bridge.vhd's own header, on the
; VHDL side of this exact design decision).
C_DEV_QL_MDV2           .EQU 0x0104

; Mirrors globals.vhd's C_CRTROMS_MAN order (Main=0, Back=1, MDV1=2,
; MDV2=3) - used by MDV1_FLUSH_STEP/MDV2_FLUSH_STEP above to index
; CRTROM_MAN_LDF/HNDL_RM_FILES. Keep in sync if that array's order in
; globals.vhd ever changes.
MDV1_MAN_IDX            .EQU 2
MDV2_MAN_IDX            .EQU 3

; QL4M65 (Milestone 2 phase B, etapa 4, M2028): tuning constants for
; MDV1_FLUSH_STEP's background write-back - see that routine's own header
; comment. MDV1_FLUSH_CHUNK: bytes streamed per HANDLE_CORE_IO call while
; a sector is active (~11 calls per 686-byte sector, similar ratio to
; AExp's own FLUSH_ADF_STEP: 512 B chunks over 5632-byte tracks).
; MDV1_GATE_THRESHOLD: HANDLE_CORE_IO calls of "no new dirty sectors"
; before a background pass is allowed to start - a plain iteration count,
; not a real time base (no RTC/timer is wired to QNICE here, unlike
; vdrives'/AExp's own hardware ms countdowns) - tune to taste if the
; real-hardware feel is too eager or too sluggish.
MDV1_FLUSH_CHUNK        .EQU 64
MDV1_GATE_THRESHOLD     .EQU 2000

; This needs to be the last thing before the "Variables" sections starts
END_OF_ROM      .DW 0

; ----------------------------------------------------------------------------
; Variables: Need to be located in RAM
; ----------------------------------------------------------------------------

#ifdef RELEASE
                .ORG    0x8000                  ; RAM starts at 0x8000
#endif

;
; add your own variables here
;

; QL4M65 (Milestone 2 phase B, etapa 3/4, M2026/M2028): local RAM copies
; of mdv1's 32-byte dirty-sector bitmap - one word per byte (not packed)
; to keep READ_MDV1_BYTE's one-byte-per-call interface simple; 3*32 words
; is a rounding error next to MENU_HEAP_SIZE below. Persistent state for
; MDV1_FLUSH_STEP's resumable background write-back - see that routine's
; own header comment for the full design.
MDV1_DIRTY_SNAP .BLOCK  32              ; this pass's frozen work list
MDV1_LAST_DIRTY .BLOCK  32              ; bitmap as last seen while idle,
                                        ; to detect fresh writes and reset
                                        ; the anti-thrashing gate
MDV1_BM_TMP     .BLOCK  32              ; scratch: freshly re-read bitmap
MDV1_FL_STATE   .BLOCK  1               ; 0=idle, 1=streaming a sector
MDV1_FL_SECTOR  .BLOCK  1               ; sector 0..254 being scanned/streamed
MDV1_FL_BYTE    .BLOCK  1               ; next byte 0..685 within that sector
MDV1_GATE_CNT   .BLOCK  1               ; anti-thrashing countdown

; QL4M65 Milestone 2 paso 5, etapa 2 (2026-08-23): mdv2's own copy of the
; same state block, used by MDV2_FLUSH_STEP - see that routine's own
; header for why this is a duplicate block rather than a parametrized
; shared one.
MDV2_DIRTY_SNAP .BLOCK  32
MDV2_LAST_DIRTY .BLOCK  32
MDV2_BM_TMP     .BLOCK  32
MDV2_FL_STATE   .BLOCK  1
MDV2_FL_SECTOR  .BLOCK  1
MDV2_FL_BYTE    .BLOCK  1
MDV2_GATE_CNT   .BLOCK  1

; M2M Shell variables (only include, if you included "shell.asm" above)
#include "../../M2M/rom/shell_vars.asm"

; ----------------------------------------------------------------------------
; Heap and Stack: Need to be located in RAM after the variables
; ----------------------------------------------------------------------------

; The On-Screen-Menu uses the heap for several data structures. This heap
; is located before the main system heap in memory.
; You need to deduct MENU_HEAP_SIZE from the actual heap size below.
; Example: If your HEAP_SIZE would be 29696, then you write 29696-1024=28672
; instead, but when doing the sanity check calculations, you use 29696
MENU_HEAP_SIZE  .EQU 1024

#ifndef RELEASE

; heap for storing the sorted structure of the current directory entries
; this needs to be the last variable before the monitor variables as it is
; only defined as "BLOCK 1" to avoid a large amount of null-values in
; the ROM file
HEAP_SIZE       .EQU 6144                       ; 7168 - 1024 = 6144
HEAP            .BLOCK 1

; in RELEASE mode: 28k of heap which leads to a better user experience when
; it comes to folders with a lot of files
#else

HEAP_SIZE       .EQU 28672                      ; 29696 - 1024 = 28672
HEAP            .BLOCK 1

; The monitor variables use 22 words, round to 32 for being safe and subtract
; it from FF00 because this is at the moment the highest address that we
; can use as RAM: 0xFEE0
; The stack starts at 0xFEE0 (search var VAR$STACK_START in osm_rom.lis to
; calculate the address). To see, if there is enough room for the stack
; given the HEAP_SIZE do this calculation: Add 29696 words to HEAP which
; is currently 0xXXXX and subtract the result from 0xFEE0. This yields
; currently a stack size of more than 1.5k words, which is sufficient
; for this program.

                .ORG    0xFEE0                  ; TODO: automate calculation
#endif

; STACK_SIZE: Size of the global stack and should be a minimum of 768 words
; after you subtract B_STACK_SIZE.
; B_STACK_SIZE: Size of local stack of the the file- and directory browser. It
; should also have a minimum size of 768 words. If you are not using the
; Shell, then B_STACK_SIZE is not used.
STACK_SIZE      .EQU    1536
B_STACK_SIZE    .EQU    768

#include "../../M2M/rom/main_vars.asm"
