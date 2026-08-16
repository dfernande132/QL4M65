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
; "Save mdv1" (OPTM_G_MDV1_SAVE, Milestone 2 phase B etapa 3, M2026) is
; also a momentary action, same "=" mark cleanup as "Extract Back ROM" -
; but no core reset: FLUSH_MDV1 only reads the mdv1 buffer and writes to
; the SD card, it never changes anything the CPU is running against.
OSM_SEL_POST    INCRB

                CMP     OPTM_G_MAINROM, R8
                RBRA    _OSM_SP_RESET, Z
                CMP     OPTM_G_BACKROM, R8
                RBRA    _OSM_SP_RESET, Z
                CMP     OPTM_G_BACKROM_EXTRACT, R8
                RBRA    _OSM_SP_BEXTR, Z
                CMP     OPTM_G_MDV1_SAVE, R8
                RBRA    _OSM_SP_MDV1SV, Z
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

_OSM_SP_MDV1SV  RSUB    FLUSH_MDV1, 1

                MOVE    OPTM_CUR_SEL, R8
                MOVE    @R8, R8
                XOR     R9, R9                  ; 0 = unselected
                RSUB    M2M$FORCE_MENU, 1
                RSUB    OPTM_SHOW, 1
                MOVE    OPTM_CUR_SEL, R8
                MOVE    @R8, R8
                MOVE    OPTM_SEL_SEL, R9
                RSUB    OPTM_SELECT, 1

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
; QL4M65 (Milestone 2 phase B, etapa 3, M2026): microdrive write-back to SD
; ----------------------------------------------------------------------------
;
; The design question this had to answer first: how does FLUSH_MDV1 know
; the SD card path of the currently-loaded .mdv, to write back into the
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

; FLUSH_MDV1: write all dirty mdv1 sectors back to the SD card and clear
; the dirty bitmap - but only if every single sector wrote and flushed
; without error (a partial failure leaves the bitmap untouched, so a
; later retry - manual or the next auto-flush - still knows what's left
; to write; clearing on a partial failure would silently lose whatever
; wasn't written yet). A real FAT32 error is FATAL, matching
; shell.asm's own FLUSH_CACHE policy for vdrives (write-back errors are
; not something to recover from gracefully here either).
;
; Register map used throughout (own INCRB bank, R0-R7):
;   R0/R1: transient scratch, never expected to survive a call
;   R2:    byte-within-sector counter (0..685), inner loop only
;   R3:    bitmap byte / bit-test scratch, outer loop only
;   R4/R5: current sector's base address (lo/hi), set once per sector
;   R6:    sector number (0..254), whole-routine lifetime
;   R7:    file handle, whole-routine lifetime
; (R0-R7 are register-banked - RSUB/SYSCALL callees get their own bank,
; so none of the above needs manual save/restore across nested calls;
; only R8+ are the shared parameter-passing registers.)
;
; Input: None    Output: None (returns quietly if mdv1 isn't loaded or
;                nothing is dirty; never returns at all on a FAT32 error)
FLUSH_MDV1      INCRB

                ; nothing to flush if mdv1 was never loaded - CRTROM_INIT
                ; zeroes CRTROM_MAN_LDF at boot, and a zero/uninitialized
                ; file handle would crash the very first f32_fseek below
                MOVE    CRTROM_MAN_LDF, R0
                ADD     MDV1_MAN_IDX, R0
                CMP     0, @R0
                RBRA    _FMDV1_RET, Z

                ; read the 32-byte dirty bitmap into our own RAM copy
                ; (C_MDV1_DIRTY_BASE_HI/_LO: the real address, 0x30000,
                ; does not fit a 16-bit QNICE word/.EQU - see the constant
                ; declarations below)
                MOVE    MDV1_DIRTY_SNAP, R0     ; R0: destination pointer
                XOR     R1, R1                  ; R1: byte index 0..31
_FMDV1_RDBM     MOVE    C_MDV1_DIRTY_BASE_HI, R8
                MOVE    C_MDV1_DIRTY_BASE_LO, R9
                ADD     R1, R9                  ; R9: address lo (+index, no
                                                 ; carry possible: max 0+31)
                RSUB    READ_MDV1_BYTE, 1       ; R8: byte value
                MOVE    R8, @R0++
                ADD     1, R1
                CMP     32, R1
                RBRA    _FMDV1_RDBM, !Z

                ; anything set at all? if not, nothing to do
                MOVE    MDV1_DIRTY_SNAP, R0
                MOVE    32, R1
_FMDV1_CHKZ     CMP     0, @R0++
                RBRA    _FMDV1_HASDATA, !Z
                SUB     1, R1
                RBRA    _FMDV1_CHKZ, !Z
                RBRA    _FMDV1_RET, 1

                ; get the already-open file handle - see this section's
                ; own header comment for why no path lookup is needed
_FMDV1_HASDATA  MOVE    HNDL_RM_FILES, R7
                ADD     MDV1_MAN_IDX, R7
                MOVE    @R7, R7                 ; R7: file handle

                ; walk all 255 sectors, write back the ones marked dirty
                ; in our RAM snapshot (byte m, bit n = sector m*8+n)
                XOR     R6, R6                  ; R6: sector number 0..254
_FMDV1_SECLOOP  MOVE    R6, R0
                SHR     3, R0                   ; R0: byte index = sector/8
                MOVE    MDV1_DIRTY_SNAP, R1
                ADD     R0, R1
                MOVE    @R1, R3                 ; R3: that bitmap byte
                MOVE    R6, R0
                AND     0x0007, R0              ; R0: bit index = sector&7
                MOVE    1, R1                    ; R1: bit mask, built below
_FMDV1_SHIFTB   CMP     0, R0
                RBRA    _FMDV1_SHIFTED, Z
                SHL     1, R1
                SUB     1, R0
                RBRA    _FMDV1_SHIFTB, 1
_FMDV1_SHIFTED  AND     R1, R3
                RBRA    _FMDV1_NEXTSEC, Z       ; this sector isn't dirty

                ; dirty: seek to sector*686 (32-bit - 254*686=174244 does
                ; not fit in 16 bits, hence MTH$MULU's R11:R10 result)
                MOVE    R6, R8
                MOVE    686, R9
                SYSCALL(mulu, 1)                ; R11:R10 = sector*686 (hi:lo)
                MOVE    R10, R4                 ; R4: sector base addr lo
                MOVE    R11, R5                 ; R5: sector base addr hi

                MOVE    R7, R8                  ; R8: file handle
                MOVE    R4, R9                  ; R9: seek pos lo
                MOVE    R5, R10                 ; R10: seek pos hi
                SYSCALL(f32_fseek, 1)
                CMP     0, R9
                RBRA    _FMDV1_SEEKOK, Z
                MOVE    ERR_FATAL_SEEK, R8
                RBRA    FATAL, 1

                ; write this sector's 686 bytes, one at a time
_FMDV1_SEEKOK   XOR     R2, R2                  ; R2: byte-within-sector 0..685
_FMDV1_BYTLOOP  MOVE    R4, R0                  ; R0: addr lo = base_lo+R2
                MOVE    R5, R1                  ; R1: addr hi = base_hi(+carry)
                ADD     R2, R0                  ; sets carry on 16-bit overflow
                ADDC    0, R1                   ; same idiom as FAT32$FILE_RWB

                MOVE    R1, R8                  ; R8: addr hi
                MOVE    R0, R9                  ; R9: addr lo
                RSUB    READ_MDV1_BYTE, 1       ; R8: byte value

                MOVE    R8, R0                  ; R0: byte value (stash - R8
                                                 ; is about to become the
                                                 ; file handle for f32_fwrite)
                MOVE    R7, R8                  ; R8: file handle
                MOVE    R0, R9                  ; R9: byte to write
                SYSCALL(f32_fwrite, 1)
                CMP     0, R9
                RBRA    _FMDV1_WROK, Z
                MOVE    ERR_FATAL_WRITE, R8
                RBRA    FATAL, 1

_FMDV1_WROK     ADD     1, R2
                CMP     686, R2
                RBRA    _FMDV1_BYTLOOP, !Z

_FMDV1_NEXTSEC  ADD     1, R6
                CMP     255, R6
                RBRA    _FMDV1_SECLOOP, !Z

                ; every dirty sector written: flush the FAT32 sector
                ; buffer, then - and only then - clear the bitmap
                MOVE    R7, R8
                SYSCALL(f32_fflush, 1)
                CMP     0, R9
                RBRA    _FMDV1_FLUSHOK, Z
                MOVE    ERR_FATAL_WRITE, R8
                RBRA    FATAL, 1

                ; C_MDV1_DIRTY_CLR (0x30020) sits 0x20 bytes into the same
                ; 4K window as C_MDV1_DIRTY_BASE (0x30000) - no need to
                ; recompute window/offset, just reuse the known window
                ; number and add the fixed offset.
_FMDV1_FLUSHOK  MOVE    M2M$RAMROM_DEV, R8
                MOVE    C_DEV_QL_MDV1, @R8
                MOVE    M2M$RAMROM_4KWIN, R8
                MOVE    C_MDV1_DIRTY_WIN, @R8
                MOVE    M2M$RAMROM_DATA, R8
                ADD     C_MDV1_DIRTY_CLR_OFS, R8
                MOVE    1, @R8                  ; any value clears the bitmap

_FMDV1_RET      DECRB
                RET

; OSM_SEL_PRE callback function:
;
; Identical to the OSM_SEL_POST callback function (see above) but it is being
; called before the functionality and semantics associated with a certain
; menu item has been handled by the framework.
;
; QL4M65 (Milestone 2 phase B, etapa 3, M2026): auto-flush before mdv1 gets
; reloaded. options.asm calls OSM_SEL_PRE before shell.asm's own
; _LI_OPENFILE re-opens HNDL_RM_FILES for the new image - if we don't flush
; here first, any dirty sectors from a previous SAVE are silently lost the
; moment the new image overwrites the buffer (AExp's own ADF write-back
; hit this exact "stale FDH across re-mounts" bug class - .research/
; microdrive-write-design.md section 7.4 already flagged it as a risk).
; Returning non-zero here is FATAL (options.asm:1168-1171), not "cancel" -
; there is no way to offer a Y/N prompt from this callback, so this always
; flushes silently rather than asking.
OSM_SEL_PRE     INCRB

                CMP     OPTM_G_MDV1, R8
                RBRA    _OSM_SPR_RET, !Z
                RSUB    FLUSH_MDV1, 1

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
; OPTM_G_MDV1/OPTM_G_MDV1_SAVE (the "Main ROM:%s"/"Back ROM:%s"/
; "Extract Back ROM"/"mdv1:%s"/"Save mdv1" menu items' group IDs) - used
; by OSM_SEL_POST/OSM_SEL_PRE above. Keep in sync if config.vhd ever
; changes these.
OPTM_G_MAINROM         .EQU 1
OPTM_G_BACKROM         .EQU 2
OPTM_G_BACKROM_EXTRACT .EQU 3
OPTM_G_MDV1            .EQU 4
OPTM_G_MDV1_SAVE        .EQU 5

; Mirrors globals.vhd's C_DEV_QL_BACKROM - used by CLEAR_BACK_ROM above.
C_DEV_QL_BACKROM       .EQU 0x0102

; QL4M65 (Milestone 2 phase B, etapa 3, M2026): mirrors globals.vhd's
; C_DEV_QL_MDV1/C_MDV1_DIRTY_BASE/C_MDV1_DIRTY_CLR, used by FLUSH_MDV1/
; READ_MDV1_BYTE above. C_MDV1_DIRTY_BASE/_CLR are 0x30000/0x30020 in
; globals.vhd - both exceed a 16-bit QNICE word, so they're mirrored here
; already split into the pieces the code actually needs (hi/lo for the
; bitmap's own base address; window+offset for the fixed-size bitmap and
; its single-word clear register, since 0x30000 happens to be exactly
; 4K-aligned and 0x30020 sits in that same window, 0x20 bytes in).
C_DEV_QL_MDV1           .EQU 0x0103
C_MDV1_DIRTY_BASE_HI    .EQU 0x0003
C_MDV1_DIRTY_BASE_LO    .EQU 0x0000
C_MDV1_DIRTY_WIN        .EQU 48                 ; = 0x30000 / 4096
C_MDV1_DIRTY_CLR_OFS    .EQU 0x0020             ; = 0x30020 - 0x30000

; Mirrors globals.vhd's C_CRTROMS_MAN order (Main=0, Back=1, MDV1=2) -
; used by FLUSH_MDV1 above to index CRTROM_MAN_LDF/HNDL_RM_FILES. Keep in
; sync if that array's order in globals.vhd ever changes.
MDV1_MAN_IDX            .EQU 2

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

; QL4M65 (Milestone 2 phase B, etapa 3, M2026): local RAM copy of mdv1's
; 32-byte dirty-sector bitmap, filled by FLUSH_MDV1 before it walks the
; 255 sectors - one word per byte (not packed) to keep READ_MDV1_BYTE's
; one-byte-per-call interface simple; 32 words is a rounding error next
; to MENU_HEAP_SIZE below.
MDV1_DIRTY_SNAP .BLOCK  32

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
