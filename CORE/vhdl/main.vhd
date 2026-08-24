----------------------------------------------------------------------------------
-- Sinclair QL for MEGA65 (QL4M65)
--
-- Wrapper for the MiSTer core that runs exclusively in the core's clock domain
--
-- Powered by MiSTer2MEGA65
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
-- QL4M65 port done by Jose Daniel Fernandez Santos (dfsantos) in 2026 and
-- licensed under GPL v3: added the QL's internal clock enables, the
-- ql_rom (Minerva) memory port, and matched keyboard.vhd's new IPC port
-- list; i_democore is still the M2M demo core - replacing it with the real
-- QL core (fx68k/zx8301/zx8302 + bus glue) is milestone 1's M1001 step
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.video_modes_pkg.all;
-- QL4M65 (Milestone 2 phase B, etapa 2): C_MDV1_DIRTY_BASE/C_MDV1_DIRTY_CLR
-- (globals.vhd) - main.vhd had no dependency on the globals package before
-- this; every other QL4M65-specific constant used here up to now was a
-- local constant (e.g. the motor-hum timing further down).
use work.globals.all;

library xpm;
use xpm.vcomponents.all;

entity main is
   generic (
      G_VDNUM                 : natural                     -- amount of virtual drives
   );
   port (
      clk_main_i              : in  std_logic;
      reset_soft_i            : in  std_logic;
      reset_hard_i            : in  std_logic;
      pause_i                 : in  std_logic;

      -- MiSTer core main clock speed:
      -- Make sure you pass very exact numbers here, because they are used for avoiding clock drift at derived clocks
      clk_main_speed_i        : in  natural;

      -- Video output
      video_ce_o              : out std_logic;
      video_ce_ovl_o          : out std_logic;
      video_red_o             : out std_logic_vector(7 downto 0);
      video_green_o           : out std_logic_vector(7 downto 0);
      video_blue_o            : out std_logic_vector(7 downto 0);
      video_vs_o              : out std_logic;
      video_hs_o              : out std_logic;
      video_hblank_o          : out std_logic;
      video_vblank_o          : out std_logic;

      -- Audio output (Signed PCM)
      audio_left_o            : out signed(15 downto 0);
      audio_right_o           : out signed(15 downto 0);

      -- M2M Keyboard interface
      kb_key_num_i            : in  integer range 0 to 79;    -- cycles through all MEGA65 keys
      kb_key_pressed_n_i      : in  std_logic;                -- low active: debounced feedback: is kb_key_num_i pressed right now?

      -- MEGA65 joysticks and paddles/mouse/potentiometers
      joy_1_up_n_i            : in  std_logic;
      joy_1_down_n_i          : in  std_logic;
      joy_1_left_n_i          : in  std_logic;
      joy_1_right_n_i         : in  std_logic;
      joy_1_fire_n_i          : in  std_logic;

      joy_2_up_n_i            : in  std_logic;
      joy_2_down_n_i          : in  std_logic;
      joy_2_left_n_i          : in  std_logic;
      joy_2_right_n_i         : in  std_logic;
      joy_2_fire_n_i          : in  std_logic;

      pot1_x_i                : in  std_logic_vector(7 downto 0);
      pot1_y_i                : in  std_logic_vector(7 downto 0);
      pot2_x_i                : in  std_logic_vector(7 downto 0);
      pot2_y_i                : in  std_logic_vector(7 downto 0);

      -- QL4M65: system ROM (Main 48K + Back 16K), 32K x 16-bit words total,
      -- loaded by the QNICE Shell via mega65.vhd's ql_rom_u/l
      -- (C_DEV_QL_MAINROM/C_DEV_QL_BACKROM).
      ql_rom_addr_o           : out std_logic_vector(14 downto 0);
      ql_rom_data_i           : in  std_logic_vector(15 downto 0);

      -- QL4M65 (Milestone 2 phase A): QNICE-clock-domain side of the mdv1
      -- microdrive image loader (mega65.vhd owns the qnice_csr/size-check
      -- FSM, same split as QL-SD's own vdrives wiring had - main.vhd runs
      -- exclusively in the core's clock domain, see this file's header, so
      -- these cross-domain signals are passed straight through from
      -- mega65.vhd). qnice_mdv1_wait_o lets the loader hold off the QNICE
      -- bus cycle while a byte is still crossing into the core clock domain
      -- (see .research/microdrive-read-design.md, section A.2).
      qnice_clk_i             : in  std_logic;
      -- QL4M65 (M2017): mdv1_loader_qnice's own reset - see that process's
      -- own comment for why this is needed (neither loader-FSM process had
      -- any reset path at all, so a mid-handshake glitch could wedge the
      -- loader permanently, recoverable only by a full power cycle).
      qnice_rst_i             : in  std_logic;
      qnice_mdv1_addr_i       : in  std_logic_vector(27 downto 0);
      qnice_mdv1_data_i       : in  std_logic_vector(15 downto 0);
      qnice_mdv1_ce_i         : in  std_logic;
      qnice_mdv1_we_i         : in  std_logic;
      qnice_mdv1_wait_o       : out std_logic;
      -- QL4M65 (Milestone 2 phase B, etapa 2): read-back path, for the
      -- future SD flush - byte from the buffer (qnice_mdv1_addr_i in
      -- 0..C_MDV1_MAX_BYTES-1) or from the dirty-sector bitmap
      -- (C_MDV1_DIRTY_BASE..+31), selected by address; valid once
      -- qnice_mdv1_wait_o drops back to '0' after a read request
      -- (qnice_mdv1_ce_i='1', qnice_mdv1_we_i='0'). See
      -- .research/microdrive-write-design.md section 6.
      qnice_mdv1_data_o       : out std_logic_vector(15 downto 0);

      -- QL4M65 (Milestone 2 phase A, M2011): is the QNICE Shell currently
      -- in the middle of an mdv1 file load (CRTROM_CSR_ST_LDNG)? A raw
      -- level from mega65.vhd's CSR (QNICE clock domain), synchronized
      -- into clk_main_i below and used to hold mdv.v's own `download`
      -- input for the WHOLE transfer - see that signal's declaration for
      -- why a single-cycle pulse (the M2004-M2010 behaviour) isn't enough.
      qnice_mdv1_loading_i    : in  std_logic;

      -- QL4M65 Milestone 2 paso 5, etapa 2 (2026-08-23,
      -- .research/microdrive-second-unit-plan.md section 2.1): mdv2's own
      -- QNICE-side window, same shape as mdv1's own set above (qnice_clk_i/
      -- qnice_rst_i are already shared, no per-drive equivalent needed for
      -- those two).
      qnice_mdv2_addr_i       : in  std_logic_vector(27 downto 0);
      qnice_mdv2_data_i       : in  std_logic_vector(15 downto 0);
      qnice_mdv2_ce_i         : in  std_logic;
      qnice_mdv2_we_i         : in  std_logic;
      qnice_mdv2_wait_o       : out std_logic;
      qnice_mdv2_data_o       : out std_logic_vector(15 downto 0);
      qnice_mdv2_loading_i    : in  std_logic;

      -- QL4M65 (Milestone 2 phase A, M2008): microdrive activity LED - real
      -- QL hardware lights it whenever a drive is selected (zx8302.v's own
      -- "led" output, sel[0] of the mdv_sel shift register); previously
      -- computed and discarded (led => open).
      drive_led_o             : out std_logic;

      -- QL4M65 (Milestone 2 phase B, etapa 4, M2029): is any mdv1 sector
      -- dirty (not yet flushed to the SD card)? Already in clk_main_i (the
      -- 256-bit mdv1_dirty bitmap below lives entirely in this domain, see
      -- p_dirty) - no CDC needed. mega65.vhd uses this to recolor
      -- drive_led_o, same "amber/blue while dirty" pattern already proven
      -- by C64MEGA65's vdrives (main.vhd's own cache_dirty) and AExp's ADF
      -- write-back (main_adf_dirty) - see DECISIONES.md's M2029 section.
      mdv1_dirty_o             : out std_logic;

      -- QL4M65 (Milestone 2 phase C, etapa B): mdv1's own Avalon-MM
      -- master, straight through from i_mdv1's new m_avm_* ports (mdv.v)
      -- to mega65.vhd, which crosses into hr_clk via avm_fifo and reaches
      -- the framework's real hr_core_* HyperRAM port. main.vhd runs
      -- exclusively in clk_main_i (see this entity's own header), so
      -- these are plain pass-through, no logic - the CDC lives in
      -- mega65.vhd, same layering as every other clk_main_i/other-domain
      -- boundary in this file.
      mdv1_avm_write_o         : out std_logic;
      mdv1_avm_read_o          : out std_logic;
      mdv1_avm_address_o       : out std_logic_vector(31 downto 0);
      mdv1_avm_writedata_o     : out std_logic_vector(15 downto 0);
      mdv1_avm_byteenable_o    : out std_logic_vector(1 downto 0);
      mdv1_avm_burstcount_o    : out std_logic_vector(7 downto 0);
      mdv1_avm_readdata_i      : in  std_logic_vector(15 downto 0);
      mdv1_avm_readdatavalid_i : in  std_logic;
      mdv1_avm_waitrequest_i   : in  std_logic;

      -- QL4M65 Milestone 2 paso 5, etapa 1 (2026-08-23,
      -- .research/microdrive-second-unit-plan.md): mdv2's own dirty flag
      -- and Avalon-MM master, same pattern as mdv1's own above - a
      -- SEPARATE master (mega65.vhd arbitrates the two before hr_core_*,
      -- not shared avm_cache instances).
      mdv2_dirty_o             : out std_logic;
      mdv2_avm_write_o         : out std_logic;
      mdv2_avm_read_o          : out std_logic;
      mdv2_avm_address_o       : out std_logic_vector(31 downto 0);
      mdv2_avm_writedata_o     : out std_logic_vector(15 downto 0);
      mdv2_avm_byteenable_o    : out std_logic_vector(1 downto 0);
      mdv2_avm_burstcount_o    : out std_logic_vector(7 downto 0);
      mdv2_avm_readdata_i      : in  std_logic_vector(15 downto 0);
      mdv2_avm_readdatavalid_i : in  std_logic;
      mdv2_avm_waitrequest_i   : in  std_logic;

      -- QL4M65 Milestone 3, Fase 1 (2026-08-24, revised after M3001/M3002:
      -- see DECISIONES.md's "Milestone 3 - pivote de HyperRAM a BRAM"): the
      -- RAM-size Options menu selection (config.vhd's OPTM_G_RAMSIZE radio
      -- group, mega65.vhd's C_MENU_RAM_128/640/1024) - read at reset only
      -- (RAM size is a boot-time decision, same as the original MiSTer
      -- core's own CONF_STR item; m2m-rom.asm's OSM_SEL_POST pulses a
      -- plain core reset on this group so a changed selection takes effect
      -- immediately, same mechanism already used for Main/Back ROM loads).
      osm_control_i            : in  std_logic_vector(255 downto 0)
   );
end entity main;

architecture synthesis of main is

---------------------------------------------------------------------------
-- QL4M65: reset (unified soft/hard, same convention already used
-- throughout mega65.vhd/main.vhd)
---------------------------------------------------------------------------

signal reset : std_logic;

---------------------------------------------------------------------------
-- QL4M65: CPU (fx68k) signals - address/data bus, decode, DTACK
---------------------------------------------------------------------------

signal cpu_addr16   : std_logic_vector(23 downto 1);  -- fx68k's eab
signal cpu_addr     : std_logic_vector(23 downto 0);  -- reconstructed byte address, masked to 256KB (milestone 1: 128k RAM only)
signal cpu_din      : std_logic_vector(15 downto 0);
signal cpu_dout     : std_logic_vector(15 downto 0);
signal cpu_uds_n    : std_logic;
signal cpu_lds_n    : std_logic;
signal cpu_uds      : std_logic;
signal cpu_lds      : std_logic;
signal cpu_as_n     : std_logic;
signal cpu_as       : std_logic;
signal cpu_rw       : std_logic;
signal cpu_fc       : std_logic_vector(2 downto 0);
signal cpu_int_ack  : std_logic;
signal cpu_ipl      : std_logic_vector(1 downto 0);

signal cpu_rd       : std_logic;
signal cpu_wr       : std_logic;
signal cpu_io       : std_logic;

-- Address decode (no GoldCard, no QL-SD, no microdrive-mapped memory -
-- those aren't part of the CPU's linear address space)
signal ql_io        : std_logic;  -- $018000-$01BFFF: ZX8301/ZX8302 internal I/O
signal cpu_rom      : std_logic;  -- $000000-$00FFFF: system ROM (Minerva)
signal cpu_ram      : std_logic;  -- $020000-(ram_top_c): main RAM, size selected at reset (128k/640k/1024k)
signal cpu_vram_wr  : std_logic;  -- $020000-$02FFFF: lower half also mirrors into VRAM

signal ram_delay_dtack : std_logic;
signal cpu_dtack       : std_logic;

-- QL4M65 Milestone 3, Fase 1 (2026-08-24, revised after M3001/M3002's
-- real-hardware hang - see DECISIONES.md's "Milestone 3 - pivote de
-- HyperRAM a BRAM"): RAM size is an Options-menu radio choice
-- (config.vhd's OPTM_G_RAMSIZE, osm_control_i bits C_MENU_RAM_128/640/1024
-- from mega65.vhd), latched into this 2-bit register ONLY at reset - RAM
-- size is a boot-time decision (same as the original MiSTer core's own
-- CONF_STR item), never changed mid-operation; m2m-rom.asm's OSM_SEL_POST
-- pulses a reset on this group so a new selection is picked up right away.
-- "10"=1024k, "01"=640k, "00"=128k (also the safe fallback if, somehow,
-- no radio member reads back set - matches Milestone 1/2's fixed size).
signal ram_size_sel : std_logic_vector(1 downto 0) := "00";

-- QL4M65 Milestone 3 (2026-08-24): CPU speed Options menu radio group
-- (config.vhd's OPTM_G_SPEED, osm_control_i bits C_MENU_SPEED_NATIVE/16/
-- 24/FULL from globals.vhd) - same boot-time-only latch pattern as
-- ram_size_sel above, same reset-pulse mechanism in m2m-rom.asm.
-- "00"=native (also the safe fallback), "01"=16MHz, "10"=24MHz, "11"=Full.
signal cpu_speed_sel : std_logic_vector(1 downto 0) := "00";

-- QL4M65 Milestone 3: ql_timing's own enable, one cycle removed from a
-- plain "'1' when cpu_speed_sel=... else '0'" written directly inline in
-- its port map - Vivado's synth_design rejected that (ERROR [Synth
-- 8-2716] "syntax error near 'when'"), a VHDL-2008 conditional expression
-- this particular Vivado version's port-map parser does not accept even
-- though the file is marked VHDL2008. A plain concurrent signal assignment
-- (below, same shape used everywhere else in this file) sidesteps it.
signal ql_timing_enable : std_logic;

signal ram_q_a      : std_logic_vector(15 downto 0);  -- main RAM read data
signal vram_q_b     : std_logic_vector(15 downto 0);  -- VRAM read data (video side)

signal io_dout      : std_logic_vector(15 downto 0);

---------------------------------------------------------------------------
-- QL4M65: ZX8301 (video) signals
---------------------------------------------------------------------------

signal zx8301_ce    : std_logic;                     -- write strobe for mc_stat ($18063)
signal mc_stat      : std_logic_vector(7 downto 0);
signal video_addr   : std_logic_vector(14 downto 0);
signal video_r      : std_logic;
signal video_g      : std_logic;
signal video_b      : std_logic;
signal zx_hs        : std_logic;
signal zx_vs        : std_logic;
signal zx_hblank    : std_logic;
signal zx_vblank    : std_logic;
signal ce_pix       : std_logic;

---------------------------------------------------------------------------
-- QL4M65: ZX8302 (internal I/O) signals
---------------------------------------------------------------------------

signal zx8302_sel   : std_logic;
signal zx8302_addr  : std_logic_vector(1 downto 0);
signal zx8302_dout  : std_logic_vector(15 downto 0);
signal audio_bit    : std_logic;                      -- ZX8302's single-bit beeper output

-- QL4M65 (Milestone 2 phase A, M2019): synthesized microdrive motor hum,
-- mixed into the audio output while mdv1 is selected (mdv_sel(0), the
-- same signal already driving the activity LED) - real microdrives spin
-- for as long as a channel is open, not just during active data transfer,
-- so this matches real hardware timing more closely than gating on
-- rx_ready pulses would. There's no real "microdrive audio" signal from
-- zx8302 to reuse - its own `audio` output is entirely the IPC/keyboard
-- beeper (audio <= ipc_audio_i, zx8302.v:230), unrelated to the drive.
-- QL4M65 (M2021): lowered pitch (~200Hz -> ~100Hz, one octave down) and
-- amplitude (3000 -> 1200) per the user's own listening test on hardware
-- - "más grave y más bajo" - purely a mix/tuning tweak, no change to the
-- gap-gated rhythm from M2020.
constant MDV1_MOTOR_HALF_PERIOD : natural := 420000;  -- 84MHz / (2*420000) ~= 100Hz hum
constant MDV1_MOTOR_AMPLITUDE   : natural := 1200;    -- quieter background hum
signal mdv1_motor_cnt   : natural range 0 to MDV1_MOTOR_HALF_PERIOD - 1 := 0;
signal mdv1_motor_tone  : std_logic := '0';
signal beeper_audio     : signed(15 downto 0);
signal mdv1_motor_audio : signed(15 downto 0);
signal audio_mix        : signed(16 downto 0);

-- QL4M65 Milestone 2 paso 5, etapa 2 (2026-08-24): mdv2's own motor hum -
-- missed in the original etapa 1/2 implementation (found by the user on
-- real hardware: mdv2 worked but stayed silent). Same tuning constants as
-- mdv1's own (MDV1_MOTOR_HALF_PERIOD/MDV1_MOTOR_AMPLITUDE, reused as-is -
-- no reason for the two drives to sound different), same gap-gated
-- rhythm, gated on mdv_sel(1)/mdv2_gap instead of mdv_sel(0)/mdv1_gap.
signal mdv2_motor_cnt   : natural range 0 to MDV1_MOTOR_HALF_PERIOD - 1 := 0;
signal mdv2_motor_tone  : std_logic := '0';
signal mdv2_motor_audio : signed(15 downto 0);

---------------------------------------------------------------------------
-- QL4M65 (Milestone 2 phase A): microdrive 1 - mdv.v (unmodified) + its
-- Vivado-clean dpram (mdv_dpram.vhd, BRAM-backed) + the QNICE-clock-domain
-- image loader (byte-pair accumulation + xpm_cdc_handshake into mdv.v's
-- own dl_addr/dl_data/dl_wr/download ports). See
-- .research/microdrive-read-design.md, section A, and rtl/zx8302.v's own
-- header note for the mdv_sel_o/mdv1_*_i ports this feeds.
---------------------------------------------------------------------------

-- zx8302.v <-> mdv1 (drive-select passthrough and the four "live" signals
-- zx8302.v used to hardcode to "no drive present")
signal mdv_sel        : std_logic_vector(7 downto 0);
signal mdv1_gap       : std_logic;
signal mdv1_tx_empty  : std_logic;
signal mdv1_rx_ready  : std_logic;
signal mdv1_byte      : std_logic_vector(7 downto 0);

-- QL4M65 (Milestone 2 phase A, M2015): raw, unregistered outputs straight
-- off mdv.v - mdv1_gap/tx_empty/rx_ready/byte above are now a registered
-- copy one clk_main_i cycle later (see the registering process near
-- i_mdv1's instantiation), added as a physical-timing-margin hardening
-- experiment for the still-unexplained sustained-read corruption on large
-- files (see DECISIONES.md's M2015 section) - detailed post-route timing
-- analysis showed mdv1/zx8302's own paths (worst hold slack 0.121ns) are
-- tighter than ideal, though not the single worst path in the design.
-- Breaking the mdv.v -> zx8302 combinational chain into two shorter
-- registered halves gives more physical margin regardless of whether
-- this turns out to be the actual root cause.
signal mdv1_gap_raw      : std_logic;
signal mdv1_tx_empty_raw : std_logic;
signal mdv1_rx_ready_raw : std_logic;
signal mdv1_byte_raw     : std_logic_vector(7 downto 0);

-- mdv1's own image-load port (core clock domain - mdv.v itself ties both
-- of its internal dpram's clocks to its single clk input, see the design
-- doc's A.2 finding)
signal mdv1_dl_addr   : std_logic_vector(16 downto 0);
signal mdv1_dl_data   : std_logic_vector(15 downto 0);
signal mdv1_download  : std_logic;
signal mdv1_dl_wr     : std_logic;

---------------------------------------------------------------------------
-- QL4M65 (Milestone 2 phase B, M2022): microdrive write channel, CPU ->
-- zx8302.v -> mdv1. Etapa 1 del diseño (.research/microdrive-write-design.md
-- section 3-5): sin persistencia todavia (bitmap de sucios y volcado a
-- QNICE llegan en M2023/M2024). Los cuatro caminos son intra-dominio
-- (clk_main_i): no hace falta ningun xpm_cdc_* aqui.
---------------------------------------------------------------------------
signal mdv1_wr_data   : std_logic_vector(7 downto 0);
signal mdv1_wr_strobe : std_logic;
signal mdv1_wr_en     : std_logic;
signal mdv1_er_en     : std_logic;
signal mdv1_sector    : std_logic_vector(7 downto 0);
signal mdv1_wr_commit : std_logic;
signal mdv1_dl_q      : std_logic_vector(15 downto 0);
signal mdv1_dl_q_valid : std_logic;

---------------------------------------------------------------------------
-- QL4M65 Milestone 2 paso 5, etapa 1 (2026-08-23,
-- .research/microdrive-second-unit-plan.md): mdv2, real-time path only.
-- Same "live" signals as mdv1's own set above; NO dl_addr/dl_data/
-- download/dl_wr/dl_q/dl_q_valid yet - QNICE can't load into or read back
-- from mdv2 until etapa 2 gives it a way to (its i_mdv2 instantiation ties
-- those ports to "no load in progress" directly, no signals needed for
-- that yet). wr_en/wr_strobe/wr_data are NOT duplicated here - mdv2
-- shares mdv1's own signals (broadcast, see i_mdv2's own instantiation
-- comment for why that's safe).
---------------------------------------------------------------------------
signal mdv2_gap       : std_logic;
signal mdv2_tx_empty  : std_logic;
signal mdv2_rx_ready  : std_logic;
signal mdv2_byte      : std_logic_vector(7 downto 0);
signal mdv2_gap_raw      : std_logic;
signal mdv2_tx_empty_raw : std_logic;
signal mdv2_rx_ready_raw : std_logic;
signal mdv2_byte_raw     : std_logic_vector(7 downto 0);
signal mdv2_sector    : std_logic_vector(7 downto 0);
signal mdv2_wr_commit : std_logic;

-- QL4M65 Milestone 2 paso 5, etapa 2: mdv2's own image-load port, same
-- shape as mdv1's own set (main.vhd:302-305/327-328) - now wired for real
-- (i_mdv2_bridge below), no longer tied to inert '0'/open.
signal mdv2_dl_addr    : std_logic_vector(16 downto 0);
signal mdv2_dl_data    : std_logic_vector(15 downto 0);
signal mdv2_download   : std_logic;
signal mdv2_dl_wr      : std_logic;
signal mdv2_dl_q       : std_logic_vector(15 downto 0);
signal mdv2_dl_q_valid : std_logic;

---------------------------------------------------------------------------
-- QL4M65 (Milestone 2 phase B, etapa 2): bitmap de sectores sucios +
-- lectura del buffer/bitmap desde QNICE, para el futuro volcado a SD
-- (.research/microdrive-write-design.md section 5.2 y 6). Sin cambio
-- funcional visible en la QL - nada de esto se lee todavia desde ningun
-- sitio del lado QL, solo desde QNICE.
---------------------------------------------------------------------------

-- 256 bits, uno por sector (0..254 usados, 255 nunca se marca). Se marca
-- por PALABRA CONFIRMADA (mdv1_wr_commit/mdv1_sector), no por sesion
-- completa - mas simple y estrictamente correcto (design doc S5.2: marcar
-- de mas solo podria pasar si una sesion quedara a caballo entre dos
-- sectores, y wr_in_range dentro de mdv.v ya lo impide).
signal mdv1_dirty       : std_logic_vector(255 downto 0) := (others => '0');
signal mdv1_dirty_clear : std_logic;  -- pulso de 1 ciclo de clk_main_i, ver mas abajo

-- QL4M65 Milestone 2 paso 5, etapa 1: mismo bitmap para mdv2, en pie de
-- igualdad. Sin mdv2_dirty_clear todavia - QNICE no puede volcar/limpiar
-- mdv2 hasta la etapa 2 (.research/microdrive-second-unit-plan.md, section
-- 2.2: el bitmap se queda en registros del core, no se mueve a HyperRAM).
-- Inerte en la practica en esta etapa: mdv2 no puede tener mdv_present='1'
-- sin una imagen cargada, y no hay forma de cargar una todavia.
signal mdv2_dirty       : std_logic_vector(255 downto 0) := (others => '0');

-- QL4M65 Milestone 2 paso 5, etapa 2: mismo pulso de limpieza que
-- mdv1_dirty_clear, ahora que mdv2 tiene su propio i_mdv2_bridge que lo
-- genera (antes inerte, ver p_dirty2's own comment mas abajo).
signal mdv2_dirty_clear : std_logic;

-- QL4M65 Milestone 2 paso 5, etapa 2 (2026-08-23): toda la logica de
-- carga/lectura QNICE<->core que antes vivia aqui (mdv1_ld_*/mdv1_rd_*/
-- mdv1_cdc_*/mdv1_clear_*, tres tipos de FSM) se ha extraido, verbatim, a
-- CORE/vhdl/mdv_qnice_bridge.vhd - ver la cabecera de esa entidad para el
-- porque y .research/microdrive-second-unit-plan.md section 2.1. Se
-- instancia dos veces mas abajo (i_mdv1_bridge, i_mdv2_bridge); ninguna
-- de estas senales existe ya en main.vhd, son internas a esa entidad.

-- IPC link to ipc.vhd (QL4M65 M1031: the real emulated 8049, T48 core +
-- real firmware ROM - replaces both the embedded 8049 emulation removed
-- from zx8302.v AND keyboard.vhd's own hand-rolled M1018-M1030 protocol
-- FSM; see rtl/zx8302.v's header note and CoreQL/doc/m2m/exceptions.md)
signal ipc_comctrl       : std_logic;                    -- ipc.vhd -> zx8302
signal ipc_comdata_zx2kb : std_logic;                    -- zx8302's own outgoing bit -> ipc.vhd
signal ipc_comdata_kb2zx : std_logic;                    -- ipc.vhd's own outgoing bit -> zx8302
signal ipc_ipl           : std_logic_vector(1 downto 0);  -- ipc.vhd -> zx8302
signal ipc_audio         : std_logic;                     -- ipc.vhd -> zx8302

-- QL4M65 (M1031): the MEGA65 keyboard matrix, produced by keyboard.vhd
-- (now just a MEGA65-key -> QL-matrix translator, see its header) and fed
-- to ipc.vhd's P1-selected data-bus-read logic - exactly the interface
-- rtl/ipc.v itself expects from rtl/keyboard.v.
signal ql_matrix : std_logic_vector(63 downto 0);

---------------------------------------------------------------------------
-- QL4M65: internal clock enables, derived from clk_main_i (84.000000 MHz)
--
-- Ported directly from the original core's QL.sv (its fractional-
-- accumulator clock generator, "always @(negedge clk_sys)" block): a
-- single 84 MHz clock, with every other clock in the system derived as a
-- clock-enable rather than a separate PLL output - see PORTING-PLAN.md
-- section 3 for the full table. Runs on the FALLING edge of clk_main_i,
-- matching QL.sv exactly (same physical clock, opposite phase - not a real
-- CDC hazard).
--
-- QL4M65 Milestone 3 (2026-08-24): fract_bus is now multiplexed between
-- QL/16MHz/24MHz/Full, exactly as this comment anticipated back in
-- Milestone 1 - the accumulator structure itself (below) is completely
-- unchanged, only fract_bus's source. Selected once at reset from the
-- Options menu's "Speed" radio group (same boot-time-decision pattern as
-- ram_size_sel - see cpu_speed_sel's own declaration below).
---------------------------------------------------------------------------

constant FRACT_BUS_QL   : unsigned(16 downto 0) := to_unsigned(11702, 17); -- 84MHz*11702/65536 = 14.999MHz phase toggle -> ~7.5MHz effective 68008 clock (QL native)
constant FRACT_BUS_16   : unsigned(16 downto 0) := to_unsigned(24966, 17); -- 84MHz*24966/65536 = 31.999MHz phase toggle -> ~16MHz effective
constant FRACT_BUS_24   : unsigned(16 downto 0) := to_unsigned(37449, 17); -- 84MHz*37449/65536 = 48.000MHz phase toggle -> ~24MHz effective
constant FRACT_BUS_FULL : unsigned(16 downto 0) := to_unsigned(65536, 17); -- 84MHz*65536/65536 = 84MHz phase toggle (no division) -> ~42MHz effective
constant FRACT_SD       : unsigned(16 downto 0) := to_unsigned(19505, 17); -- ~25MHz effective SD-card SPI clock
constant FRACT_11M      : unsigned(16 downto 0) := to_unsigned(8582, 17);  -- 10.999MHz IPC clock
constant DIV_131K     : natural := 640;                                  -- 84MHz/640 = 131250Hz (SDRAM refresh / RTC tick)
constant DIV_VID      : natural := 8;                                    -- 84MHz/8 = 10.5MHz pixel clock

-- QL4M65 (Milestone 2 phase A, M2008->M2009): the M2008 "speed mdv1 up
-- alone via its own ce_mdv1_fast, leave ce_bus_p/CPU untouched" attempt was
-- REVERTED in M2009 - confirmed on hardware to break reads entirely (files
-- that read fine at native 1x, e.g. tetris.mdv, stopped reading at all at
-- 4x). Root cause: QDOS's own microdrive driver is real-time bit-banged
-- code running at whatever speed the CPU itself is clocked at; decoupling
-- mdv1's byte rate from the CPU's service rate breaks the timing budget
-- QDOS needs to keep up - exactly why the ORIGINAL core's turbo option
-- (QL.sv's "O78,CPU speed") scales ce_bus_p for the CPU AND zx8302/mdv
-- TOGETHER via one shared accumulator, never just the storage device alone.
-- A real speedup needs genuine CPU+bus turbo mode (planned, bigger, its own
-- milestone) - not this shortcut. mdv1 is back on ce_bus_p, native 7.5MHz,
-- matching real hardware and the original core exactly. See DECISIONES.md.

signal cnt_bus  : unsigned(15 downto 0) := (others => '0');
signal bus_tick : std_logic := '0';
signal bus_pol  : std_logic := '0';
signal ce_bus_p : std_logic := '0';
signal ce_bus_n : std_logic := '0';

-- QL4M65 Milestone 3: the accumulator's own fractional increment,
-- combinationally selected by cpu_speed_sel (declared further below,
-- latched at reset from the "Speed" Options menu group) - the accumulator
-- process itself (clock_enables) is otherwise completely unchanged from
-- Milestone 1/2.
signal fract_bus : unsigned(16 downto 0);

signal cnt_sd   : unsigned(15 downto 0) := (others => '0');
signal ce_sd    : std_logic := '0';

signal cnt_11m  : unsigned(15 downto 0) := (others => '0');
signal ce_11m   : std_logic := '0';

signal div131k  : unsigned(9 downto 0) := (others => '0');
signal ce_131k  : std_logic := '0';

signal divvid   : unsigned(3 downto 0) := (others => '0');
signal ce_vid   : std_logic := '0';

begin

   ---------------------------------------------------------------------------
   -- QL4M65 clock enables (see declarations above for provenance/constants).
   -- Signal reads below intentionally see each other's PRE-this-edge values
   -- (no variables used, mirroring Verilog's non-blocking-assignment
   -- semantics in the original QL.sv block exactly, including its one-cycle
   -- relationship between bus_tick/cnt_bus and ce_bus_p/ce_bus_n/bus_pol).
   ---------------------------------------------------------------------------
   clock_enables : process (clk_main_i)
      variable v_bus_sum   : unsigned(16 downto 0);
      variable v_sd_sum    : unsigned(16 downto 0);
      variable v_11m_sum   : unsigned(16 downto 0);
   begin
      if falling_edge(clk_main_i) then
         if reset_soft_i = '1' or reset_hard_i = '1' then
            bus_pol       <= '0';
            cnt_bus       <= (others => '0');
            div131k       <= (others => '0');
            divvid        <= (others => '0');
         else
            if div131k = to_unsigned(DIV_131K - 1, div131k'length) then
               div131k <= (others => '0');
            else
               div131k <= div131k + 1;
            end if;

            if divvid = to_unsigned(DIV_VID - 1, divvid'length) then
               divvid <= (others => '0');
            else
               divvid <= divvid + 1;
            end if;
         end if;

         -- CPU clock: two-phase, non-overlapping (fx68k needs both cep/cen)
         v_bus_sum := ('0' & cnt_bus) + fract_bus;
         cnt_bus   <= v_bus_sum(15 downto 0);
         bus_tick  <= v_bus_sum(16);
         ce_bus_p  <= bus_tick and not bus_pol;
         ce_bus_n  <= bus_tick and bus_pol;
         bus_pol   <= bus_tick xor bus_pol;

         -- SDRAM refresh / RTC tick
         if div131k = 0 then
            ce_131k <= '1';
         else
            ce_131k <= '0';
         end if;

         -- 10.5 MHz pixel clock
         if divvid = 0 then
            ce_vid <= '1';
         else
            ce_vid <= '0';
         end if;

         -- QL-SD clock
         v_sd_sum := ('0' & cnt_sd) + FRACT_SD;
         cnt_sd   <= v_sd_sum(15 downto 0);
         ce_sd    <= v_sd_sum(16);

         -- 11 MHz IPC clock
         v_11m_sum := ('0' & cnt_11m) + FRACT_11M;
         cnt_11m   <= v_11m_sum(15 downto 0);
         ce_11m    <= v_11m_sum(16);
      end if;
   end process clock_enables;

   reset <= reset_soft_i or reset_hard_i;

   -- QL4M65 Milestone 3, Fase 1 (2026-08-24): latch the RAM-size Options
   -- menu selection at reset only - see ram_size_sel's own declaration
   -- comment above for why (boot-time decision, not runtime). Priority
   -- chain (1024k checked first) matches the wiki's own suggested pattern
   -- for reading a radio group's bits; falls back to "00" (128k) if,
   -- somehow, no member reads back set (e.g. before the Shell has ever
   -- initialised osm_control_i) - same safe default as Milestone 1/2's
   -- fixed size.
   p_ram_size : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         if reset = '1' then
            if osm_control_i(C_MENU_RAM_1024) = '1' then
               ram_size_sel <= "10";
            elsif osm_control_i(C_MENU_RAM_640) = '1' then
               ram_size_sel <= "01";
            else
               ram_size_sel <= "00";
            end if;
         end if;
      end if;
   end process p_ram_size;

   -- QL4M65 Milestone 3 (2026-08-24): same latch pattern as ram_size_sel
   -- above, for the "Speed" Options menu group. Priority chain (Full
   -- checked first, native as the fallback) - see cpu_speed_sel's own
   -- declaration comment.
   p_cpu_speed : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         if reset = '1' then
            if osm_control_i(C_MENU_SPEED_FULL) = '1' then
               cpu_speed_sel <= "11";
            elsif osm_control_i(C_MENU_SPEED_24) = '1' then
               cpu_speed_sel <= "10";
            elsif osm_control_i(C_MENU_SPEED_16) = '1' then
               cpu_speed_sel <= "01";
            else
               cpu_speed_sel <= "00";
            end if;
         end if;
      end if;
   end process p_cpu_speed;

   -- QL4M65 Milestone 3: fract_bus mux - the accumulator process
   -- (clock_enables, above) consumes this combinationally, unaware of
   -- where it comes from, exactly as this file's own header comment
   -- anticipated back in Milestone 1.
   fract_bus <= FRACT_BUS_FULL when cpu_speed_sel = "11" else
                FRACT_BUS_24   when cpu_speed_sel = "10" else
                FRACT_BUS_16   when cpu_speed_sel = "01" else
                FRACT_BUS_QL;

   -- QL4M65 Milestone 3: contention only applies at native speed, exactly
   -- like the original core's own ql_mode (QL.sv, cpu_speed == 0) - at
   -- 16/24/Full the CPU runs the raw fractional clock with no contention
   -- wait-states, same as QL.sv's own architecture.
   ql_timing_enable <= '1' when cpu_speed_sel = "00" else '0';

   ---------------------------------------------------------------------------
   -- QL4M65: address decode (RAM size selectable 128k/640k/1024k - see
   -- ram_size_sel above; no GoldCard/QL-SD/microdrive-mapped memory)
   ---------------------------------------------------------------------------

   -- QL4M65 Milestone 3, Fase 1: widened from x"03FFFF" (18 bits, 256k -
   -- Milestone 1's fixed 128k RAM scope) to x"1FFFFF" (21 bits, 2MB) to
   -- cover the 1024k tier's own top address ($11FFFF). Safe for the
   -- smaller regions (ROM $000000-$00FFFF, I/O $018000-$01BFFF): widening
   -- this mask only changes behaviour for addresses that have bits set
   -- ABOVE the old 18-bit boundary, which ROM/IO addresses never do -
   -- their own decode below is completely unaffected by the mask's width.
   cpu_addr <= (cpu_addr16 & ((not cpu_uds) and cpu_lds)) and x"1FFFFF";

   cpu_rd <= cpu_as and cpu_rw and (cpu_uds or cpu_lds);
   cpu_wr <= cpu_as and (not cpu_rw) and (cpu_uds or cpu_lds);
   cpu_io <= cpu_rd or cpu_wr;

   ql_io       <= '1' when unsigned(cpu_addr) >= x"018000" and unsigned(cpu_addr) <= x"01BFFF" else '0';
   cpu_rom     <= '1' when unsigned(cpu_addr) <= x"00FFFF" else '0';

   -- QL4M65 Milestone 3, Fase 1: one contiguous RAM region starting at
   -- $020000 (unchanged from Milestone 1/2), its TOP depending on the
   -- selected size - deliberately NOT the original MiSTer core's own
   -- scattered/gapped layout for its 640k/896k tiers (QL.sv's cpu_ram512/
   -- cpu_ram768, see .research/milestone3-memory-speed-plan.md): those
   -- gaps exist for real vintage expansion-board compatibility reasons
   -- that don't apply here, and a single contiguous region is simpler to
   -- reason about while still satisfying Minerva's own RAM-size probe
   -- (which just walks upward from $020000 until it stops seeing real
   -- memory - contiguous or gapped, it can't tell the difference).
   cpu_ram <= '1' when unsigned(cpu_addr) >= x"020000" and
                        ((ram_size_sel = "00" and unsigned(cpu_addr) <= x"03FFFF") or  -- 128k: $020000-$03FFFF
                         (ram_size_sel = "01" and unsigned(cpu_addr) <= x"0BFFFF") or  -- 640k: $020000-$0BFFFF
                         (ram_size_sel = "10" and unsigned(cpu_addr) <= x"11FFFF"))    -- 1024k: $020000-$11FFFF
              else '0';
   cpu_vram_wr <= '1' when unsigned(cpu_addr) >= x"020000" and unsigned(cpu_addr) <= x"02FFFF" else '0';

   -- The ZX8301 has only one write-only register, at $18063
   zx8301_ce <= '1' when (ql_io = '1' and cpu_addr(6) = '1' and cpu_addr(5) = '1'
                          and cpu_addr(1) = '1' and cpu_wr = '1' and cpu_lds = '1') else '0';

   zx8302_sel  <= cpu_io and ql_io and (not cpu_addr(6));
   zx8302_addr <= cpu_addr(5) & cpu_addr(1);

   io_dout <= zx8302_dout when zx8302_sel = '1' else x"0000";

   cpu_din <= io_dout       when ql_io   = '1' else
              ql_rom_data_i when cpu_rom = '1' else
              ram_q_a       when cpu_ram = '1' else
              x"FFFF";

   -- ql_timing's wait-states apply uniformly (matches QL.sv's own default
   -- case - even ROM/IO reads share the contended-memory timing window);
   -- no extra RAM-controller dtack needed, main RAM is BRAM (1-cycle
   -- synchronous) regardless of which size is selected - see DECISIONES.md's
   -- "Milestone 3 - pivote de HyperRAM a BRAM" for why HyperRAM was
   -- abandoned for this (M3001/M3002's real-hardware hang, and three
   -- independent precedents - AExp, C64MEGA65's REU case study, and the
   -- M2M wiki itself - agreeing that a CPU's own directly-addressed RAM
   -- doesn't belong on HyperRAM in this framework).
   cpu_dtack <= not ram_delay_dtack;

   ql_rom_addr_o <= cpu_addr(15 downto 1);

   ---------------------------------------------------------------------------
   -- QL4M65: CPU (fx68k) - Verilog/SystemVerilog original, instantiated
   -- as-is (mixed-language Vivado project), not ported
   ---------------------------------------------------------------------------

   i_fx68k : entity work.fx68k
      port map (
         clk      => clk_main_i,
         HALTn    => '1',
         extReset => reset,
         pwrUp    => reset,
         enPhi1   => ce_bus_p,
         enPhi2   => ce_bus_n,

         eRWn     => cpu_rw,
         ASn      => cpu_as_n,
         UDSn     => cpu_uds_n,
         LDSn     => cpu_lds_n,

         E        => open,
         VMAn     => open,
         FC0      => cpu_fc(0),
         FC1      => cpu_fc(1),
         FC2      => cpu_fc(2),

         BGn        => open,
         oRESETn    => open,
         oHALTEDn   => open,
         DTACKn     => not cpu_dtack,
         VPAn       => not cpu_int_ack,
         BERRn      => '1',
         BRn        => '1',
         BGACKn     => '1',
         -- QL4M65 (M1017): fx68k.sv:212 computes its internal priority
         -- register as `rIpl <= ~{IPL2n,IPL1n,IPL0n}` - these pins are
         -- genuinely active-low, matching real 68000 hardware. zx8302's
         -- "ipl" output is a plain (non-inverted) priority number (0/2 in
         -- our case, per its own "raises ipl to 2" comment), so it must be
         -- inverted here before reaching fx68k. Previously wired without
         -- inversion (matching QL.sv's own literal wiring pattern) - that
         -- verification only checked the STRUCTURE (IPL0n/IPL2n tied
         -- together) was faithful, not that the resulting priority LEVEL
         -- was correct. Confirmed as a real bug via M1016 hardware data:
         -- cpu_ipl="10" (intended level 2) without inversion computes
         -- rIpl=5 in fx68k, and Minerva197_rom's own vector table sends
         -- level 5 to a shared do-nothing RTE stub at $00005E - exactly
         -- where the CPU was found stuck (M1016), instead of the real
         -- level-2 handler at $0006BC. AExp's equivalent wiring also has no
         -- explicit inversion, but its own chip_ipl source is already
         -- generated in active-low form upstream (real Amiga chipset
         -- convention) - zx8302's plain-number "ipl" is not, so it needs
         -- the "not" here that AExp's own source doesn't need.
         IPL0n      => not cpu_ipl(0),
         IPL1n      => not cpu_ipl(1),
         IPL2n      => not cpu_ipl(0),  -- IPL0/IPL2 are tied together on the 68008, matches QL.sv
         iEdb       => cpu_din,
         oEdb       => cpu_dout,
         eab        => cpu_addr16
      ); -- i_fx68k

   cpu_as  <= not cpu_as_n;
   cpu_uds <= not cpu_uds_n;
   cpu_lds <= not cpu_lds_n;
   cpu_int_ack <= '1' when cpu_fc = "111" else '0';

   ---------------------------------------------------------------------------
   -- QL4M65 Milestone 3, Fase 1 (2026-08-24): main RAM - BRAM, sized for the
   -- largest selectable tier (1024k = 2^19 words) always, regardless of
   -- which size is actually selected - cpu_ram's own decode (above) is what
   -- limits how much of it the CPU can actually see, matching how the
   -- original MiSTer core's own SDRAM was always physically present at full
   -- size and only the address decode changed per menu option. Reverted
   -- from qram_avm.vhd/HyperRAM (M3001/M3002) - see DECISIONES.md's
   -- "Milestone 3 - pivote de HyperRAM a BRAM" for why. Both ports tied the
   -- same way as before (only the CPU touches main RAM; port B unused).
   ---------------------------------------------------------------------------

   i_main_ram : entity work.dualport_2clk_ram_byteenable
      generic map (
         G_ADDR_WIDTH => 19,  -- 1024k bytes = 512K words (largest selectable tier)
         G_DATA_WIDTH => 16
      )
      port map (
         a_clk_i        => clk_main_i,
         a_address_i    => cpu_addr(19 downto 1),
         a_data_i       => cpu_dout,
         a_byteenable_i => cpu_uds & cpu_lds,
         a_wren_i       => cpu_wr and cpu_ram,
         a_q_o          => ram_q_a,

         b_clk_i        => clk_main_i,
         b_address_i    => (others => '0'),
         b_data_i       => (others => '0'),
         b_byteenable_i => (others => '0'),
         b_wren_i       => '0',
         b_q_o          => open
      ); -- i_main_ram

   i_vram : entity work.dualport_2clk_ram_byteenable
      generic map (
         G_ADDR_WIDTH => 15,
         G_DATA_WIDTH => 16
      )
      port map (
         a_clk_i        => clk_main_i,
         a_address_i    => cpu_addr(15 downto 1),
         a_data_i       => cpu_dout,
         a_byteenable_i => cpu_uds & cpu_lds,
         a_wren_i       => cpu_wr and cpu_vram_wr,
         a_q_o          => open,

         b_clk_i        => clk_main_i,
         b_address_i    => video_addr,
         b_data_i       => (others => '0'),
         b_byteenable_i => (others => '0'),
         b_wren_i       => '0',
         b_q_o          => vram_q_b
      ); -- i_vram

   ---------------------------------------------------------------------------
   -- QL4M65: contended-memory wait states, ported unmodified (independent of
   -- which memory technology sits behind cpu_ram - see DECISIONES.md Anexo A)
   ---------------------------------------------------------------------------

   i_ql_timing : entity work.ql_timing
      port map (
         clk_sys         => clk_main_i,
         reset           => reset,
         enable          => ql_timing_enable,
         ce_bus_p        => ce_bus_p,
         VBlank          => zx_vblank,
         cpu_uds         => cpu_uds,
         cpu_lds         => cpu_lds,
         cpu_rw          => cpu_rw,
         -- QL4M65 (M2018): the zx8302 I/O registers ($018000-$01BFFF) don't
         -- live in the DRAM the ZX8301 contends for on real hardware, so
         -- they shouldn't wait for the video chunk window either - present
         -- them to ql_timing as if they were ROM (ql_timing.sv:76 only
         -- exempts cpu_rom). Without this, each zx8302 I/O read from
         -- Minerva's md_read polling loop could be delayed 0-11 cycles by
         -- ram_delay_dtack, against a real-time budget of only 7 cycles
         -- (rx_ready window 37 CPU cycles vs the 30-cycle poll loop) -
         -- confirmed as a real, partial contributor: disabling ALL
         -- contention (M2016/M2017, `enable => '0'`) measurably stabilized
         -- sustained mdv1 reads on hardware. The OTHER, larger part of
         -- what looked like a hang turned out to be genuinely corrupted
         -- test .mdv images (see DECISIONES.md's mdv1-sustained-read
         -- resolution) - both were real, independent factors. This
         -- targeted exemption keeps full QL speed fidelity for everything
         -- else (RAM still contends normally) while giving mdv1's polling
         -- loop its margin back. See DECISIONES.md's M2018 section.
         cpu_rom         => cpu_rom or ql_io,
         ram_delay_dtack => ram_delay_dtack
      ); -- i_ql_timing

   ---------------------------------------------------------------------------
   -- QL4M65: ZX8301 (video) - Verilog original, instantiated as-is
   ---------------------------------------------------------------------------

   mc_stat_reg : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         if reset = '1' then
            mc_stat <= x"00";
         elsif zx8301_ce = '1' then
            mc_stat <= cpu_dout(7 downto 0);
         end if;
      end if;
   end process mc_stat_reg;

   i_zx8301 : entity work.zx8301
      port map (
         reset   => reset,
         clk     => clk_main_i,
         ce      => ce_vid,
         ce_out  => ce_pix,
         ntsc    => '0',            -- PAL only for milestone 1
         mc_stat => mc_stat,
         addr    => video_addr,
         din     => vram_q_b,
         r       => video_r,
         g       => video_g,
         b       => video_b,
         hs      => zx_hs,
         vs      => zx_vs,
         HBlank  => zx_hblank,
         VBlank  => zx_vblank
      ); -- i_zx8301

   -- video_ce_o: divides clk_main_i into the core's native pre-scandoubler
   -- pixel clock; video_ce_ovl_o: same rate for milestone 1 (no separate
   -- scandoubler clock enable yet - see globals.vhd's VGA_DX/DY note, may
   -- need revisiting once real video is on screen, Fase 6/9).
   video_ce_o     <= ce_pix;
   video_ce_ovl_o <= video_ce_o;

   video_vs_o     <= zx_vs;
   video_hs_o     <= zx_hs;
   video_hblank_o <= zx_hblank;
   video_vblank_o <= zx_vblank;

   ---------------------------------------------------------------------------
   -- QL4M65: ZX8302 (internal I/O) - Verilog original, modified to expose
   -- the IPC link as top-level ports instead of embedding the 8049
   -- emulation (see rtl/zx8302.v's header note and doc/m2m/exceptions.md)
   ---------------------------------------------------------------------------

   i_zx8302 : entity work.zx8302
      port map (
         clk           => clk_main_i,
         ce_11m        => ce_11m,
         reset         => reset,
         reset_mdv     => '0',  -- M2016: dead port since M1 (no internal mdv instance) - tied off explicitly

         ipl           => cpu_ipl,
         xint          => '0',  -- no mouse in milestone 1

         -- QL4M65 (Milestone 2 phase A): mdv_dl_addr/mdv_dl_data/
         -- mdv_download/mdv_dl_wr are unused leftovers in zx8302.v itself
         -- (never referenced internally, even before our own port) - the
         -- loader below drives mdv1's own dl_* ports directly instead of
         -- routing through zx8302.v. mdv_sel_o/mdv1_*_i are the real link
         -- (see rtl/zx8302.v's own header note and doc/m2m/exceptions.md).
         mdv_dl_addr      => (others => '0'),
         mdv_dl_data      => (others => '0'),
         mdv_download     => '0',
         mdv_dl_wr        => '0',
         mdv_reverse      => '0',  -- normal order, no menu item yet (see design doc)
         mdv_sel_o        => mdv_sel,
         mdv1_gap_i       => mdv1_gap,
         mdv1_tx_empty_i  => mdv1_tx_empty,
         mdv1_rx_ready_i  => mdv1_rx_ready,
         mdv1_byte_i      => mdv1_byte,

         -- QL4M65 Milestone 2 paso 5, etapa 1
         mdv2_gap_i       => mdv2_gap,
         mdv2_tx_empty_i  => mdv2_tx_empty,
         mdv2_rx_ready_i  => mdv2_rx_ready,
         mdv2_byte_i      => mdv2_byte,

         -- QL4M65 fase B (M2022): canal de escritura hacia mdv1
         mdv_wr_data_o    => mdv1_wr_data,
         mdv_wr_strobe_o  => mdv1_wr_strobe,
         mdv_wr_en_o      => mdv1_wr_en,
         mdv_er_en_o      => mdv1_er_en,
         led           => drive_led_o,

         audio         => audio_bit,

         vs            => zx_vs,

         -- IPC link (see ipc.vhd)
         ipc_comctrl_i => ipc_comctrl,
         ipc_comdata_o => ipc_comdata_zx2kb,
         ipc_comdata_i => ipc_comdata_kb2zx,

         -- QL4M65: the real 8049 (ipc.vhd) can assert ipl_o[1] as part of
         -- its own protocol (signalling a pending keyboard event) - but
         -- nothing in this port ever completes the exchange that would
         -- make it lower again, so a genuine assertion can latch
         -- permanently. Combined with zx8302.v's own ipl OR (any pending
         -- internal irq OR the external ipc's line raises Level 2), a
         -- stuck-high ipl[1] is a level-sensitive interrupt storm that
         -- starves the CPU of real execution time (every RTE immediately
         -- re-enters it). Left unconnected here (tied to "00") - the real
         -- fix for what this was blocking (SuperBASIC never reaching the
         -- keyboard) turned out to be unrelated: see zx8302.v's mdv_gap
         -- comment. See DECISIONES.md's M1031-M1040 sections for the full
         -- investigation.
         ipc_ipl_i     => "00",
         ipc_audio_i   => ipc_audio,

         cep           => ce_bus_p,
         cen           => ce_bus_n,

         ce_131k       => ce_131k,
         rtc_data      => (others => '0'),  -- no real-time source yet, see PORTING-PLAN.md section 0

         cpu_sel       => zx8302_sel,
         cpu_wr        => cpu_wr,
         cpu_addr      => zx8302_addr,
         cpu_uds       => cpu_uds,
         cpu_lds       => cpu_lds,
         cpu_din       => cpu_dout,
         cpu_dout      => zx8302_dout
      ); -- i_zx8302

   -- QL4M65 (M2019): microdrive motor hum, gated on mdv_sel(0), see the
   -- signal declarations' header comment above.
   -- QL4M65 (M2020): AExp's own Amiga floppy "click" turned out to be
   -- genuine Kickstart/trackdisk.device audio, passed through Paula
   -- unmodified (doc/m2m/exceptions.md-equivalent research confirmed
   -- there's no M2M framework sound feature, nor an AExp technique, to
   -- copy) - and real microdrives don't step like a floppy anyway (DC tape
   -- motor, not a stepper), so a continuous hum is the honest analogue,
   -- not a click. The M2019 version was gated purely on mdv_sel(0), giving
   -- one unbroken tone for as long as a channel was open - flat and
   -- "monotonous" per the user. Gating on mdv1_gap as well ties the sound
   -- to mdv.v's own real timing (header ~1.1ms, gap ~2.8ms, data ~26ms,
   -- see mdv.v's own gap-timing comments) instead of a single held note,
   -- giving it real rhythm without inventing anything not backed by
   -- actual drive activity.
   mdv1_motor_snd : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         if mdv_sel(0) = '0' or mdv1_gap = '1' then
            mdv1_motor_cnt  <= 0;
            mdv1_motor_tone <= '0';
         elsif mdv1_motor_cnt = MDV1_MOTOR_HALF_PERIOD - 1 then
            mdv1_motor_cnt  <= 0;
            mdv1_motor_tone <= not mdv1_motor_tone;
         else
            mdv1_motor_cnt <= mdv1_motor_cnt + 1;
         end if;
      end if;
   end process mdv1_motor_snd;

   -- QL4M65 Milestone 2 paso 5, etapa 2: mdv2's own counterpart, identical
   -- logic to mdv1_motor_snd above - see that process's own header for the
   -- full rationale.
   mdv2_motor_snd : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         if mdv_sel(1) = '0' or mdv2_gap = '1' then
            mdv2_motor_cnt  <= 0;
            mdv2_motor_tone <= '0';
         elsif mdv2_motor_cnt = MDV1_MOTOR_HALF_PERIOD - 1 then
            mdv2_motor_cnt  <= 0;
            mdv2_motor_tone <= not mdv2_motor_tone;
         else
            mdv2_motor_cnt <= mdv2_motor_cnt + 1;
         end if;
      end if;
   end process mdv2_motor_snd;

   beeper_audio     <= to_signed(16#7FFF#, 16) when audio_bit = '1' else to_signed(0, 16);
   mdv1_motor_audio <= to_signed(MDV1_MOTOR_AMPLITUDE, 16) when mdv1_motor_tone = '1' else to_signed(0, 16);
   mdv2_motor_audio <= to_signed(MDV1_MOTOR_AMPLITUDE, 16) when mdv2_motor_tone = '1' else to_signed(0, 16);

   -- Mix in a 17-bit intermediate and saturate before truncating back to
   -- 16 bits, so a beeper click and both motor hums coinciding can never
   -- wrap around into a loud glitch (worst case 0x7FFF + 1200 + 1200 =
   -- 35167, comfortably inside the 17-bit signed range).
   audio_mix <= resize(beeper_audio, 17) + resize(mdv1_motor_audio, 17) + resize(mdv2_motor_audio, 17);

   audio_left_o  <= to_signed(16#7FFF#, 16)   when audio_mix > to_signed(16#7FFF#, 17) else
                    to_signed(-16#8000#, 16)  when audio_mix < to_signed(-16#8000#, 17) else
                    audio_mix(15 downto 0);
   audio_right_o <= audio_left_o;

   ---------------------------------------------------------------------------
   -- QL4M65: keyboard - MEGA65-native translation to the QL's 8x8 matrix
   -- (see keyboard.vhd's own header). No IPC protocol here anymore - that's
   -- ipc.vhd below (QL4M65 M1031).
   ---------------------------------------------------------------------------

   i_keyboard : entity work.keyboard
      port map (
         clk_main_i      => clk_main_i,
         reset_i         => reset,

         key_num_i       => kb_key_num_i,
         key_pressed_n_i => kb_key_pressed_n_i,

         ql_matrix_o     => ql_matrix
      ); -- i_keyboard

   ---------------------------------------------------------------------------
   -- QL4M65 (M1031): IPC - the real emulated Intel 8049 (T48 core + real
   -- firmware ROM, see ipc.vhd's own header for the full rationale and
   -- DECISIONES.md for the investigation that led here). Replaces
   -- keyboard.vhd's M1018-M1030 hand-rolled comdata/comctrl protocol FSM.
   ---------------------------------------------------------------------------

   i_ipc : entity work.ipc
      port map (
         clk_main_i  => clk_main_i,
         reset_i     => reset,

         -- same real 11MHz IPC clock-enable keyboard.vhd used to consume
         ce_11m_i    => ce_11m,

         ql_matrix_i => ql_matrix,

         comctrl_o   => ipc_comctrl,
         comdata_i   => ipc_comdata_zx2kb,
         comdata_o   => ipc_comdata_kb2zx,
         audio_o     => ipc_audio,
         ipl_o       => ipc_ipl
      ); -- i_ipc

   ---------------------------------------------------------------------------
   -- QL4M65 Milestone 2 paso 5, etapa 2 (2026-08-23,
   -- .research/microdrive-second-unit-plan.md section 2.1): QNICE<->core
   -- bridge for each microdrive's buffer - image load and byte/dirty-bitmap
   -- read-back. Extracted verbatim into mdv_qnice_bridge.vhd (see that
   -- entity's own header for the full M2004-M2032 bug history behind every
   -- rule in it: level-held xpm_cdc_handshake handshakes, registered-only
   -- vs. live-edge-qualified wait_o, reset from day one on both sides of
   -- every CDC, and the q_a_valid LEVEL semantics M2032 settled on).
   -- Instantiated twice: mdv1's own instance is a behavior-preserving
   -- refactor (same signals it always drove); mdv2's is genuinely new.
   ---------------------------------------------------------------------------

   i_mdv1_bridge : entity work.mdv_qnice_bridge
      port map (
         qnice_clk_i     => qnice_clk_i,
         qnice_rst_i     => qnice_rst_i,
         qnice_addr_i    => qnice_mdv1_addr_i,
         qnice_data_i    => qnice_mdv1_data_i,
         qnice_ce_i      => qnice_mdv1_ce_i,
         qnice_we_i      => qnice_mdv1_we_i,
         qnice_wait_o    => qnice_mdv1_wait_o,
         qnice_data_o    => qnice_mdv1_data_o,
         qnice_loading_i => qnice_mdv1_loading_i,

         clk_main_i   => clk_main_i,
         reset_i      => reset,

         download_o   => mdv1_download,
         dl_addr_o    => mdv1_dl_addr,
         dl_data_o    => mdv1_dl_data,
         dl_wr_o      => mdv1_dl_wr,
         dl_q_i       => mdv1_dl_q,
         dl_q_valid_i => mdv1_dl_q_valid,

         dirty_i       => mdv1_dirty,
         dirty_clear_o => mdv1_dirty_clear
      ); -- i_mdv1_bridge

   i_mdv2_bridge : entity work.mdv_qnice_bridge
      port map (
         qnice_clk_i     => qnice_clk_i,
         qnice_rst_i     => qnice_rst_i,
         qnice_addr_i    => qnice_mdv2_addr_i,
         qnice_data_i    => qnice_mdv2_data_i,
         qnice_ce_i      => qnice_mdv2_ce_i,
         qnice_we_i      => qnice_mdv2_we_i,
         qnice_wait_o    => qnice_mdv2_wait_o,
         qnice_data_o    => qnice_mdv2_data_o,
         qnice_loading_i => qnice_mdv2_loading_i,

         clk_main_i   => clk_main_i,
         reset_i      => reset,

         download_o   => mdv2_download,
         dl_addr_o    => mdv2_dl_addr,
         dl_data_o    => mdv2_dl_data,
         dl_wr_o      => mdv2_dl_wr,
         dl_q_i       => mdv2_dl_q,
         dl_q_valid_i => mdv2_dl_q_valid,

         dirty_i       => mdv2_dirty,
         dirty_clear_o => mdv2_dirty_clear
      ); -- i_mdv2_bridge

   -- rtl/mdv.v, unmodified, instantiated as-is (mixed-language Vivado
   -- project). Its own internal "dpram #(17,88000) vram" instance resolves
   -- to CORE/vhdl/mdv_dpram.vhd (Vivado-clean, BRAM-backed for phase A -
   -- see that file's own header and .research/microdrive-read-design.md).
   i_mdv1 : entity work.mdv
      -- QL4M65 Milestone 2 paso 5, etapa 1: explicit even though it
      -- matches mdv.v's own default - i_mdv2 below MUST differ (see its
      -- own comment), so both are spelled out rather than leaving one
      -- implicit.
      generic map (
         HMAP_BASE => C_HMAP_MDV1
      )
      port map (
         clk      => clk_main_i,
         ce       => ce_bus_p,  -- native QL speed - see M2009 revert note above
         -- QL4M65 (M2016): mdv.v's ONLY use of `reset` is to asynchronously
         -- clear mdv_end (mdv.v:77-82) - i.e. "eject the cartridge". The
         -- original core ties this to reset_mdv = osd_reset (QL.sv:83,547),
         -- a DIFFERENT signal from the general core reset - on real
         -- hardware, resetting the CPU does not eject a microdrive
         -- cartridge. This port had it wired to the general `reset`, so
         -- ANY core reset (including the automatic one from reloading a
         -- ROM) zeroed mdv_end even though the image was still intact in
         -- BRAM - explaining "works if the .mdv loads after the last
         -- reset, not before". Tied to '0': mdv_end starts at 0 via the
         -- FF's INIT value (no cartridge, correct) and only ever changes
         -- when an image is actually loaded. See DECISIONES.md's M2016
         -- section / .research/mdv1-sustained-read-analysis.md section 5.1.
         reset    => '0',

         reverse  => '0',

         sel      => mdv_sel(0),

         gap       => mdv1_gap_raw,
         tx_empty  => mdv1_tx_empty_raw,
         rx_ready  => mdv1_rx_ready_raw,
         dout      => mdv1_byte_raw,

         download  => mdv1_download,
         dl_addr   => mdv1_dl_addr,
         dl_data   => mdv1_dl_data,
         dl_wr     => mdv1_dl_wr,
         dl_q      => mdv1_dl_q,
         dl_q_valid => mdv1_dl_q_valid,

         -- QL4M65 fase B (M2022): canal de escritura zx8302 -> mdv1. Van en
         -- la direccion CONTRARIA a gap/tx_empty/rx_ready/dout (que si pasan
         -- por mdv1_output_reg, M2015) - no deben pasar por ese registro.
         --
         -- QL4M65 Milestone 2 paso 5, etapa 1: estas mismas tres senales
         -- (mdv1_wr_en/mdv1_wr_strobe/mdv1_wr_data) se difunden tambien a
         -- i_mdv2 sin enrutar (ver esa instancia mas abajo) - mdv.v se
         -- protege solo (wr_session = wr_en && mdv_present, mdv_present =
         -- sel && mdv_end!=0, mdv.v:150/266) asi que la unidad no
         -- seleccionada nunca procesa un wr_strobe real aunque lo reciba.
         wr_en     => mdv1_wr_en,
         wr_strobe => mdv1_wr_strobe,
         wr_data   => mdv1_wr_data,
         sector    => mdv1_sector,
         wr_commit => mdv1_wr_commit,

         -- QL4M65 (Milestone 2 phase C, etapa B): pass straight through to
         -- this entity's own mdv1_avm_*_o/i ports (see their declaration
         -- above) - mdv.v's own dpram instance is the only real consumer.
         m_avm_write         => mdv1_avm_write_o,
         m_avm_read          => mdv1_avm_read_o,
         m_avm_address       => mdv1_avm_address_o,
         m_avm_writedata     => mdv1_avm_writedata_o,
         m_avm_byteenable    => mdv1_avm_byteenable_o,
         m_avm_burstcount    => mdv1_avm_burstcount_o,
         m_avm_readdata      => mdv1_avm_readdata_i,
         m_avm_readdatavalid => mdv1_avm_readdatavalid_i,
         m_avm_waitrequest   => mdv1_avm_waitrequest_i
      ); -- i_mdv1

   -- QL4M65 (M2015): register mdv1's raw outputs one clk_main_i cycle
   -- before zx8302 sees them - see mdv1_gap_raw's own declaration comment
   -- for the full rationale (post-route timing hardening experiment).
   mdv1_output_reg : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         mdv1_gap       <= mdv1_gap_raw;
         mdv1_tx_empty  <= mdv1_tx_empty_raw;
         mdv1_rx_ready  <= mdv1_rx_ready_raw;
         mdv1_byte      <= mdv1_byte_raw;
      end if;
   end process mdv1_output_reg;

   -- QL4M65 Milestone 2 paso 5, etapa 1 (2026-08-23,
   -- .research/microdrive-second-unit-plan.md): mdv2, real-time path.
   -- QL4M65 etapa 2: download/dl_wr/dl_addr/dl_data/dl_q/dl_q_valid now
   -- wired for real, to i_mdv2_bridge above (etapa 1 left them tied to "no
   -- load in progress"/zero/open). wr_en/wr_strobe/wr_data still reuse
   -- mdv1's own signals (broadcast, see i_mdv1's own instantiation
   -- comment) - unrelated to the QNICE-side load/read path.
   i_mdv2 : entity work.mdv
      -- QL4M65 Milestone 2 paso 5, etapa 1: MUST differ from i_mdv1's own
      -- C_HMAP_MDV1 - without this, both siblings' internal dpram would
      -- silently share the exact same HyperRAM address range and corrupt
      -- each other's data (found by design review before this was ever
      -- built - see .research/microdrive-second-unit-plan.md section 1.4
      -- and the elaboration-time assert near i_mdv2's own instantiation
      -- below, which exists specifically to catch this class of mistake
      -- if it's ever reintroduced).
      generic map (
         HMAP_BASE => C_HMAP_MDV2
      )
      port map (
         clk      => clk_main_i,
         ce       => ce_bus_p,
         reset    => '0',
         reverse  => '0',

         sel      => mdv_sel(1),

         gap       => mdv2_gap_raw,
         tx_empty  => mdv2_tx_empty_raw,
         rx_ready  => mdv2_rx_ready_raw,
         dout      => mdv2_byte_raw,

         download  => mdv2_download,
         dl_addr   => mdv2_dl_addr,
         dl_data   => mdv2_dl_data,
         dl_wr     => mdv2_dl_wr,
         dl_q      => mdv2_dl_q,
         dl_q_valid => mdv2_dl_q_valid,

         wr_en     => mdv1_wr_en,
         wr_strobe => mdv1_wr_strobe,
         wr_data   => mdv1_wr_data,
         sector    => mdv2_sector,
         wr_commit => mdv2_wr_commit,

         m_avm_write         => mdv2_avm_write_o,
         m_avm_read          => mdv2_avm_read_o,
         m_avm_address       => mdv2_avm_address_o,
         m_avm_writedata     => mdv2_avm_writedata_o,
         m_avm_byteenable    => mdv2_avm_byteenable_o,
         m_avm_burstcount    => mdv2_avm_burstcount_o,
         m_avm_readdata      => mdv2_avm_readdata_i,
         m_avm_readdatavalid => mdv2_avm_readdatavalid_i,
         m_avm_waitrequest   => mdv2_avm_waitrequest_i
      ); -- i_mdv2

   mdv2_output_reg : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         mdv2_gap       <= mdv2_gap_raw;
         mdv2_tx_empty  <= mdv2_tx_empty_raw;
         mdv2_rx_ready  <= mdv2_rx_ready_raw;
         mdv2_byte      <= mdv2_byte_raw;
      end if;
   end process mdv2_output_reg;

   -- QL4M65 Milestone 2 paso 5, etapa 1: C_HMAP_MDV1/C_HMAP_MDV2 deben ser
   -- rangos disjuntos - un solape aqui corromperia datos en silencio (cada
   -- avm_cache de mdv_dpram solo ve su propio trafico, ninguna de las dos
   -- instancias puede detectar que la otra esta escribiendo el mismo hueco
   -- de HyperRAM por debajo). Tres lineas, en tiempo de elaboracion.
   assert unsigned(C_HMAP_MDV2) >= unsigned(C_HMAP_MDV1) + C_HMAP_MDV_BLOCKS
      report "main.vhd: C_HMAP_MDV1/C_HMAP_MDV2 overlap - fix globals.vhd before synthesizing"
      severity failure;

   ---------------------------------------------------------------------------
   -- QL4M65 (Milestone 2 phase B, etapa 2): dirty-sector bitmap + read-back
   -- from QNICE. See .research/microdrive-write-design.md sections 5.2/6.
   ---------------------------------------------------------------------------

   -- 256-bit bitmap, marked one bit per CONFIRMED WORD (not per session -
   -- design doc S5.2: simpler and still exact, since mdv.v's own
   -- wr_in_range already forbids a session straddling two sectors).
   p_dirty : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         if reset = '1' then
            mdv1_dirty <= (others => '0');
         elsif mdv1_dirty_clear = '1' then
            mdv1_dirty <= (others => '0');
         elsif mdv1_wr_commit = '1' then
            mdv1_dirty(to_integer(unsigned(mdv1_sector))) <= '1';
         end if;
      end if;
   end process p_dirty;

   -- QL4M65 (M2029): combinational OR-reduce, already in clk_main_i - see
   -- this signal's own port comment.
   mdv1_dirty_o <= '0' when unsigned(mdv1_dirty) = 0 else '1';

   -- QL4M65 Milestone 2 paso 5, etapa 2: mdv2 ahora si tiene "clear" (via
   -- i_mdv2_bridge's own dirty_clear_o) - ver este bitmap's own
   -- declaracion mas arriba.
   p_dirty2 : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         if reset = '1' then
            mdv2_dirty <= (others => '0');
         elsif mdv2_dirty_clear = '1' then
            mdv2_dirty <= (others => '0');
         elsif mdv2_wr_commit = '1' then
            mdv2_dirty(to_integer(unsigned(mdv2_sector))) <= '1';
         end if;
      end if;
   end process p_dirty2;

   mdv2_dirty_o <= '0' when unsigned(mdv2_dirty) = 0 else '1';

   video_red_o    <= (others => video_r);
   video_green_o  <= (others => video_g);
   video_blue_o   <= (others => video_b);

end architecture synthesis;

