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
-- QL4M65 Milestone 4 (QL-SD): vd_vec_array/vd_std_array, for bridging
-- sd_card.sv's scalar SD-protocol ports to vdrives.vhd's VDNUM-array ones.
use work.vdrives_pkg.all;

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
      -- group, globals.vhd's C_MENU_RAM_128/640) - read at reset only
      -- (RAM size is a boot-time decision, same as the original MiSTer
      -- core's own CONF_STR item; m2m-rom.asm's OSM_SEL_POST pulses a
      -- plain core reset on this group so a changed selection takes effect
      -- immediately, same mechanism already used for Main/Back ROM loads).
      osm_control_i            : in  std_logic_vector(255 downto 0);

      -- QL4M65 Milestone 4 (QL-SD, paso 1): QNICE-clock-domain side of
      -- vdrives.vhd's QNICE MMIO interface for the QL-SD virtual drive.
      -- main.vhd runs exclusively in the core's clock domain (see this
      -- file's header), so these cross-domain signals are passed straight
      -- through from mega65.vhd - same pattern as C64MEGA65's main.vhd's
      -- c64_clk_sd_i/c64_qnice_*_i ports, and the same shape mdv1/mdv2's
      -- own qnice_mdv1_*/qnice_mdv2_* ports above already use (qnice_clk_i/
      -- qnice_rst_i are already shared, no new port needed for those two).
      qnice_qlsd_addr_i       : in  std_logic_vector(27 downto 0);
      qnice_qlsd_data_i       : in  std_logic_vector(15 downto 0);
      qnice_qlsd_data_o       : out std_logic_vector(15 downto 0);
      qnice_qlsd_ce_i         : in  std_logic;
      qnice_qlsd_we_i         : in  std_logic
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

-- Address decode (no GoldCard, no microdrive-mapped memory - those aren't
-- part of the CPU's linear address space; QL-SD's own decode - qlsd_en/
-- qlsd_reg/qlsd_rd/qlsd_dat/qlsd_sel - lives further down, near its own
-- signal declarations, Milestone 4)
signal ql_io        : std_logic;  -- $018000-$01BFFF: ZX8301/ZX8302 internal I/O
signal cpu_rom      : std_logic;  -- $000000-$00FFFF: system ROM (Minerva)
signal cpu_ram      : std_logic;  -- $020000-(ram_top_c): main RAM, size selected at reset (128k/640k)
signal cpu_vram_wr  : std_logic;  -- $020000-$02FFFF: lower half also mirrors into VRAM

signal ram_delay_dtack : std_logic;
signal cpu_dtack       : std_logic;

-- QL4M65 Milestone 3, Fase 1 (2026-08-24, revised after M3001/M3002's
-- real-hardware hang - see DECISIONES.md's "Milestone 3 - pivote de
-- HyperRAM a BRAM"): RAM size is an Options-menu radio choice
-- (config.vhd's OPTM_G_RAMSIZE, osm_control_i bits C_MENU_RAM_128/640
-- from mega65.vhd), latched into this 2-bit register ONLY at reset - RAM
-- size is a boot-time decision (same as the original MiSTer core's own
-- CONF_STR item), never changed mid-operation; m2m-rom.asm's OSM_SEL_POST
-- pulses a reset on this group so a new selection is picked up right away.
-- "01"=640k, "00"=128k (also the safe fallback if, somehow, no radio
-- member reads back set - matches Milestone 1/2's fixed size).
-- M4010 (2026-09-09): the 1024k tier ("10") was dropped - see the
-- i_main_ram_lo/i_main_ram_hi comment for the BRAM-budget reason.
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

signal ram_q_a      : std_logic_vector(15 downto 0);  -- main RAM read data (bank mux output)

-- QL4M65 M4010 (2026-09-09): main RAM is split into two exactly-sized
-- banks - see the i_main_ram_lo/i_main_ram_hi comment further down.
-- ram_woff is the CPU word address rebased to $020000 (so offset 0 is the
-- first word of RAM), 19 bits wide; only offsets 0..$4FFFF are reachable
-- because cpu_ram's own decode stops at $0BFFFF.
signal ram_woff       : std_logic_vector(18 downto 0);
signal ram_bank_hi    : std_logic;                       -- '1' => top 128k bank
signal ram_bank_hi_r  : std_logic := '0';                -- delayed 1 cycle to match BRAM read latency
signal ram_q_lo       : std_logic_vector(15 downto 0);
signal ram_q_hi       : std_logic_vector(15 downto 0);
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

-- QL4M65 Milestone 3 (2026-08-24, found by the user on real hardware: no
-- motor hum at all at Full speed): MDV1_MOTOR_HALF_PERIOD above is a FIXED
-- main_clk-cycle count, tuned for native speed's own mdv1_gap rhythm. But
-- mdv.v's own gap timing is driven by ce_bus_p, so it speeds up right along
-- with cpu_speed_sel - at Full (~5.6x native), mdv1_gap now toggles ~5.6x
-- more often in real main_clk-cycle terms, so the counter below gets reset
-- (mdv1_gap='1' branch) well before it can ever count up to the fixed
-- 420000 needed to flip mdv1_motor_tone - permanent silence, not a gradual
-- pitch change, exactly the reported symptom. Fix: scale the half-period
-- down by the same ratio cpu_speed_sel speeds the bus up by (420000 *
-- FRACT_BUS_QL/FRACT_BUS_X, precomputed here since this toolchain's
-- port-map lesson from earlier in this same file already showed inline
-- conditional expressions are risky - a plain mux into a signal is safer
-- and matches this file's existing style everywhere else). This exactly
-- tracks how much shorter mdv1_gap's own real-time low period became, so
-- the counter can always complete at least one toggle within it - keeps
-- the hum AUDIBLE at every speed (the actual bug) rather than staying
-- pitch-locked at ~100Hz: the perceived pitch rises with speed as a side
-- effect, which is the physically sensible outcome (spin a real motor
-- faster, it sounds higher-pitched too), not an artifact to avoid.
constant MDV_MOTOR_HALF_PERIOD_16   : natural := 196885;  -- 420000 * FRACT_BUS_QL/FRACT_BUS_16
constant MDV_MOTOR_HALF_PERIOD_24   : natural := 131241;  -- 420000 * FRACT_BUS_QL/FRACT_BUS_24
constant MDV_MOTOR_HALF_PERIOD_FULL : natural := 75000;   -- 420000 * FRACT_BUS_QL/FRACT_BUS_FULL
signal mdv_motor_half_period : natural range 0 to MDV1_MOTOR_HALF_PERIOD;

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
-- Milestone 3: shares mdv_motor_half_period with mdv1 above - same speed,
-- same fix, one mux for both.
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
-- QL4M65 Milestone 4 (QL-SD, paso 1): qlromext.v (QL-bus register
-- interface) + sd_card.sv (SPI-slave SD emulator) + vdrives.vhd
-- (QNICE/FAT32 bridge). See .research/qlsd-design.md for the architecture
-- and doc/m2m/exceptions.md for the sd_card.sv altsyncram-removal surgery.
---------------------------------------------------------------------------

-- Address decode: original QL.sv:304-308 simplified (no GoldCard/
-- rom_shadow in any milestone yet - see qlsd-design.md item 4)
signal qlsd_en      : std_logic;  -- cpu_rom and cpu_rd
signal qlsd_reg     : std_logic;  -- $FEE0-$FEFF control page
signal qlsd_rd      : std_logic;  -- $FEE4 SPI_READ, the only register that returns data
signal qlsd_dat     : std_logic;  -- $FF00-$FFFF SPI background-transfer shift page
signal qlsd_sel     : std_logic;  -- qlsd_reg or qlsd_dat - drives qlromext's romoel and cpu_dtack's mux
signal qlsd_dout    : std_logic_vector(7 downto 0);
signal qlsd_dtack   : std_logic;  -- qlromext's own DTACK, active-high "ready" (same convention as cpu_dtack)

-- qlromext.v <-> sd_card.sv raw SPI wires
signal qlsd_spi_clk  : std_logic;
signal qlsd_spi_cs1l : std_logic;
signal qlsd_spi_cs2l : std_logic;
signal qlsd_spi_di   : std_logic;
signal qlsd_spi_do   : std_logic;

-- sd_card.sv <-> vdrives.vhd: MiSTer's generic "SD" block-storage protocol
-- (confirmed identical signal names/semantics against vdrives.vhd:155-166)
--
-- QL4M65 Milestone 4 (QL-SD, paso 1, M4003): sd_lba/sd_rd/sd_wr below are
-- sd_card.sv's own OUTPUTS - real CDC source, clk_main_i domain (see the
-- CDC note on i_sd_card's instantiation for why). vdrives.vhd's own header
-- documents sd_lba_i/sd_rd_i/sd_wr_i as living in "QNICE's clock domain" -
-- confirmed by reading vdrives.vhd itself: it consumes them raw (no
-- internal CDC of its own for these three, unlike img_mounted/img_size/
-- reset_core_i/drive_mounted_reg, which DO get their own xpm_cdc_array_single
-- instances inside vdrives.vhd - i_cdc_qnice2main/i_cdc_main2qnice). So the
-- _q suffixed signals below (post-CDC, qnice_clk_i domain) are what actually
-- feeds vdrives.vhd - see the xpm_cdc_array_single instance near
-- i_sd_card/i_vdrives further down.
signal qlsd_sd_lba       : std_logic_vector(31 downto 0);
signal qlsd_sd_rd        : std_logic;
signal qlsd_sd_wr        : std_logic;
signal qlsd_sd_lba_q     : std_logic_vector(31 downto 0);  -- qnice_clk_i domain, post-CDC
signal qlsd_sd_rd_q      : std_logic;                      -- qnice_clk_i domain, post-CDC
signal qlsd_sd_wr_q      : std_logic;                      -- qnice_clk_i domain, post-CDC
signal qlsd_sd_ack       : std_logic;
-- vdrives.vhd's sd_buff_addr_o is fixed at 14 bits (its own AW=13 constant,
-- covers up to 16384-byte blocks); sd_card.sv WIDE(0) only needs 9 bits
-- (AW=8) to index one 512-byte sector - low 9 bits used, see i_sd_card
-- below. Upper bits are 0 for the 512-byte BLKSZ=>2 vdrives is configured
-- with (real SD sector size, matches sd_card.sv's own assumption).
signal qlsd_sd_buff_addr : std_logic_vector(13 downto 0);
signal qlsd_sd_buff_dout : std_logic_vector(7 downto 0);  -- vdrives -> sd_card (into the buffer)
signal qlsd_sd_buff_din  : std_logic_vector(7 downto 0);  -- sd_card -> vdrives (out of the buffer)
signal qlsd_sd_buff_wr   : std_logic;

-- vdrives.vhd is generic over VDNUM (array-typed sd_lba_i/sd_rd_i/sd_wr_i/
-- sd_ack_o/sd_buff_din_i); sd_card.sv is not (its ports above are scalar,
-- it only ever models one card) - these single-element (G_VDNUM=1) arrays
-- bridge the two. QL4M65's QL-SD hardware/driver only ever supports one
-- card, so G_VDNUM is fixed at 1 (see globals.vhd's C_VDNUM).
signal qlsd_sd_lba_arr      : vd_vec_array(G_VDNUM - 1 downto 0)(31 downto 0);
signal qlsd_sd_blk_cnt_arr  : vd_vec_array(G_VDNUM - 1 downto 0)(5 downto 0);
signal qlsd_sd_rd_arr       : vd_std_array(G_VDNUM - 1 downto 0);
signal qlsd_sd_wr_arr       : vd_std_array(G_VDNUM - 1 downto 0);
signal qlsd_sd_ack_arr      : vd_std_array(G_VDNUM - 1 downto 0);
signal qlsd_sd_buff_din_arr : vd_vec_array(G_VDNUM - 1 downto 0)(7 downto 0);

-- sd_card.sv's internal "sdbuf" RAM, now externally instantiated
-- (dualport_2clk_ram, ADDR_WIDTH=>11, DATA_WIDTH=>8 - see exceptions.md)
signal qlsd_ram_a_addr : std_logic_vector(10 downto 0);
signal qlsd_ram_a_data : std_logic_vector(7 downto 0);
signal qlsd_ram_a_wren : std_logic;
signal qlsd_ram_a_q    : std_logic_vector(7 downto 0);
signal qlsd_ram_b_addr : std_logic_vector(10 downto 0);
signal qlsd_ram_b_data : std_logic_vector(7 downto 0);
signal qlsd_ram_b_wren : std_logic;
signal qlsd_ram_b_q    : std_logic_vector(7 downto 0);

-- vdrives.vhd img_mounted/img_size - only VDNUM=1 in this milestone, but
-- kept generic-width so G_VDNUM stays authoritative (mirrors AExp/C64's
-- own pattern of sizing these off VDNUM rather than hardcoding 1).
-- img_readonly_o/img_type_o/drive_mounted_o/cache_*_o are left open below -
-- nothing in this milestone's minimal wiring consumes them yet.
signal qlsd_img_mounted   : std_logic_vector(G_VDNUM - 1 downto 0);
signal qlsd_img_size      : std_logic_vector(31 downto 0);

-- QL4M65 Milestone 4 (QL-SD, M4009): plain signals for everything that
-- reaches i_sd_card's port map. Vivado was silently dropping ALL of that
-- instance's port connections (every output reported by
-- "[Synth 8-3848] ... does not have driver", instance optimised away
-- entirely, confirmed absent from the synthesised netlist), and an
-- expression as the actual of a Verilog module's input port is one of the
-- two structural differences against i_qlromext, which binds correctly.
-- Precompute them instead of writing "x\"00000000\" & qlsd_img_size" and
-- "qlsd_img_mounted(0)" inline in the port map.
signal qlsd_img_size64    : std_logic_vector(63 downto 0);
signal qlsd_img_mounted0  : std_logic;
signal qlsd_sd_buff_addr9 : std_logic_vector(8 downto 0);
-- M4011: was "signal ... := '1'" with no driver at all, which only works
-- because Vivado keeps the initial value - a constant says what is meant.
constant C_QLSD_SDHC_ONE  : std_logic := '1';  -- fixed, matches QL.sv's own .sdhc(1)
signal qlsd_sdhc_one      : std_logic;

---------------------------------------------------------------------------
-- QL4M65 Milestone 4 (QL-SD, M4011): the remaining clock-domain crossings
-- between vdrives.vhd (qnice_clk_i) and sd_card.sv (clk_main_i).
--
-- M4009 was the first build where sd_card.sv actually EXISTED in the
-- netlist, and M4010's timing report is therefore the first real look at
-- this boundary. Three paths were being timed with a 0.476ns requirement
-- (qnice_clk fall -> main_clk rise) and failing badly:
--
--   vdrives/sd_ack_reg[0]  -> sd_card/ack_reg[0]                  -4.845ns
--   sd_card/sd_buf_reg[0]  -> i_qlsd_ram/ram_reg/ADDRARDADDR[12]  -2.480ns
--   sd_card/sd_buf_reg[1]  -> i_qlsd_ram/ram_reg/ADDRARDADDR[13]  -2.477ns
--
-- sd_card.sv DOES have a hand-rolled 2-FF synchroniser for sd_ack
-- ("ack[1:0] <= {ack[0],sd_ack}" plus a stability filter), but a
-- hand-rolled synchroniser carries no timing exception, so Vivado times it
-- as a real path and it fails WNS for real - the exact lesson this project
-- already recorded in M2011. The fix is the project's standing rule:
-- cross with xpm_cdc_* primitives, which bring their own constraints.
--
-- Direction 1 (qnice -> main): sd_ack ONLY. img_mounted/img_size look like
-- they belong here too, but they do not: vdrives.vhd splits its own
-- outputs into "Core clock domain: Output registers" (img_mounted_o,
-- img_size_o, img_readonly_o, img_type_o, drive_mounted_o, cache_*_o - all
-- already bridged inside it by i_cdc_q2m_img_mounted/i_cdc_qnice2main) and
-- "QNICE clock domain: Output registers" (sd_ack_o, sd_buff_addr_o,
-- sd_buff_dout_o, sd_buff_wr_o - raw). Bridging the first group again is
-- not merely redundant, it INTRODUCES a main->qnice crossing that did not
-- exist; M4011's first build did exactly that and traded one 4.845ns
-- failure for fifteen. Only the second group crosses. sd_card.sv
-- uses sd_ack in exactly two places - "ram_a_wren_o = sd_ack & sd_buff_wr"
-- (pure qnice-domain, feeds the buffer RAM's port A) and the clk_spi
-- synchroniser above. Only the second one crosses, so i_sd_card is fed the
-- SYNCHRONISED ack and the buffer RAM's port A is driven directly from
-- vdrives' own qnice-domain signals instead of through sd_card's
-- ram_a_data_o/ram_a_wren_o passthroughs.
--
-- Direction 2 (main -> qnice): sd_buf, sd_card.sv's internal 2-bit buffer
-- index, which only appears outside as the top 2 bits of ram_a_addr_o
-- ("assign ram_a_addr_o = {sd_buf,sd_buff_addr}") - i.e. that one port
-- genuinely mixes a main-domain field with a qnice-domain one, which is
-- fine in the original MiSTer core where clk_sys IS clk_spi, and is a real
-- CDC here where they are not. sd_buf only changes on the falling edge of
-- ack, between transfers, so it is quasi-static from the qnice side and a
-- plain array_single is the right primitive (bit skew cannot matter when
-- the value is stable for the whole window in which it is used).
---------------------------------------------------------------------------
signal qlsd_sd_ack_main   : std_logic;                      -- sd_ack, qnice -> main
signal qlsd_sd_buf_main   : std_logic_vector(1 downto 0);   -- sd_card's buffer index (main)
signal qlsd_sd_buf_q      : std_logic_vector(1 downto 0);   -- ... -> qnice
signal qlsd_ram_a_addr_q  : std_logic_vector(10 downto 0);  -- port A address, built in qnice

-- QL4M65 Milestone 4 (QL-SD, M4009): sd_card_wrap is declared as a
-- COMPONENT and instantiated as one, not via "entity work.sd_card_wrap".
-- Direct entity instantiation of this particular Verilog module was
-- silently producing an instance with NO port connections at all (see
-- qlsd_img_size64's own comment above); a component declaration is the
-- pattern the M2M framework itself uses for every Verilog/SystemVerilog
-- module it binds from VHDL (audio_out.v, video_mixer.sv, the xpm_cdc_*
-- primitives - all of which Vivado reports as "module 'X' ... bound to
-- instance 'Y' of component 'X'"), and it is the only such binding style
-- in this project that is known to be reported as bound in the log.
component sd_card_wrap is
   port (
      clk_sys      : in  std_logic;
      reset        : in  std_logic;

      sdhc         : in  std_logic;
      img_mounted  : in  std_logic;
      img_size     : in  std_logic_vector(63 downto 0);

      sd_lba       : out std_logic_vector(31 downto 0);
      sd_rd        : out std_logic;
      sd_wr        : out std_logic;
      sd_ack       : in  std_logic;

      sd_buff_addr : in  std_logic_vector(8 downto 0);
      sd_buff_dout : in  std_logic_vector(7 downto 0);
      sd_buff_din  : out std_logic_vector(7 downto 0);
      sd_buff_wr   : in  std_logic;

      clk_spi      : in  std_logic;

      ss           : in  std_logic;
      sck          : in  std_logic;
      mosi         : in  std_logic;
      miso         : out std_logic;

      ram_a_addr_o : out std_logic_vector(10 downto 0);
      ram_a_data_o : out std_logic_vector(7 downto 0);
      ram_a_wren_o : out std_logic;
      ram_a_q_i    : in  std_logic_vector(7 downto 0);

      ram_b_addr_o : out std_logic_vector(10 downto 0);
      ram_b_data_o : out std_logic_vector(7 downto 0);
      ram_b_wren_o : out std_logic;
      ram_b_q_i    : in  std_logic_vector(7 downto 0)
   );
end component sd_card_wrap;

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
   -- chain (largest tier checked first) matches the wiki's own suggested
   -- pattern for reading a radio group's bits; falls back to "00" (128k)
   -- if, somehow, no member reads back set (e.g. before the Shell has ever
   -- initialised osm_control_i) - same safe default as Milestone 1/2's
   -- fixed size.
   -- M4010 (2026-09-09): the 1024k tier ("10") is gone; 640k is now the
   -- top. See i_main_ram_lo/i_main_ram_hi below for why (BRAM budget).
   p_ram_size : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         if reset = '1' then
            if osm_control_i(C_MENU_RAM_640) = '1' then
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

   -- QL4M65 Milestone 3: mdv1/mdv2 motor hum half-period, scaled down at
   -- higher CPU speeds - see MDV_MOTOR_HALF_PERIOD_16/24/FULL's own
   -- declaration comment for why (fixes real silence at Full speed).
   mdv_motor_half_period <= MDV_MOTOR_HALF_PERIOD_FULL when cpu_speed_sel = "11" else
                             MDV_MOTOR_HALF_PERIOD_24   when cpu_speed_sel = "10" else
                             MDV_MOTOR_HALF_PERIOD_16   when cpu_speed_sel = "01" else
                             MDV1_MOTOR_HALF_PERIOD;

   -- QL4M65 Milestone 3: contention only applies at native speed, exactly
   -- like the original core's own ql_mode (QL.sv, cpu_speed == 0) - at
   -- 16/24/Full the CPU runs the raw fractional clock with no contention
   -- wait-states, same as QL.sv's own architecture.
   ql_timing_enable <= '1' when cpu_speed_sel = "00" else '0';

   ---------------------------------------------------------------------------
   -- QL4M65: address decode (RAM size selectable 128k/640k - see
   -- ram_size_sel above; no GoldCard/microdrive-mapped memory. QL-SD's own
   -- decode is further below, near its i_qlromext/i_sd_card instantiation)
   ---------------------------------------------------------------------------

   -- QL4M65 Milestone 3, Fase 1: widened from x"03FFFF" (18 bits, 256k -
   -- Milestone 1's fixed 128k RAM scope) to x"1FFFFF" (21 bits, 2MB) to
   -- cover the largest tier's own top address (M4010: $0BFFFF, 640k -
   -- was $11FFFF while the 1024k tier existed). Safe for the
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
                         (ram_size_sel = "01" and unsigned(cpu_addr) <= x"0BFFFF"))    -- 640k: $020000-$0BFFFF
              else '0';
   cpu_vram_wr <= '1' when unsigned(cpu_addr) >= x"020000" and unsigned(cpu_addr) <= x"02FFFF" else '0';

   -- The ZX8301 has only one write-only register, at $18063
   zx8301_ce <= '1' when (ql_io = '1' and cpu_addr(6) = '1' and cpu_addr(5) = '1'
                          and cpu_addr(1) = '1' and cpu_wr = '1' and cpu_lds = '1') else '0';

   zx8302_sel  <= cpu_io and ql_io and (not cpu_addr(6));
   zx8302_addr <= cpu_addr(5) & cpu_addr(1);

   io_dout <= zx8302_dout when zx8302_sel = '1' else x"0000";

   -- QL4M65 Milestone 4 (QL-SD): QL-SD maps into the ROM address window
   -- ($FEE0-$FEFF control page, $FF00-$FFFF SPI shift page) - takes
   -- priority over ql_rom_data_i, same priority order as the original
   -- QL.sv (its own cpu_din mux checks qlsd_rd before the ROM read).
   cpu_din <= io_dout               when ql_io   = '1' else
              qlsd_dout & qlsd_dout when qlsd_rd = '1' else
              ql_rom_data_i         when cpu_rom = '1' else
              ram_q_a               when cpu_ram = '1' else
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
   -- QL4M65 Milestone 4 (QL-SD): while a QL-SD register/data access is in
   -- flight, qlromext.v generates its own DTACK instead (original
   -- QL.sv:684-688) - same active-high "ready" convention as cpu_dtack, no
   -- polarity fix needed (confirmed by reading qlromext.v's own dtack
   -- process, unlike the IPL case in M1016/M1017).
   cpu_dtack <= qlsd_dtack when qlsd_sel = '1' else not ram_delay_dtack;

   ql_rom_addr_o <= cpu_addr(15 downto 1);

   -- QL4M65 Milestone 4 (QL-SD): address decode, simplified from the
   -- original QL.sv:304-308 (no GoldCard/rom_shadow in any milestone yet -
   -- see .research/qlsd-design.md item 4).
   qlsd_en  <= cpu_rom and cpu_rd;
   qlsd_reg <= '1' when (qlsd_en = '1' and (cpu_addr(15 downto 4) = x"fee" or cpu_addr(15 downto 4) = x"fef")) else '0';
   qlsd_rd  <= '1' when (qlsd_en = '1' and cpu_addr(15 downto 0) = x"fee4") else '0';  -- only SPI_READ actually returns data
   qlsd_dat <= '1' when (qlsd_en = '1' and cpu_addr(15 downto 8) = x"ff") else '0';
   qlsd_sel <= qlsd_reg or qlsd_dat;

   -- QL4M65 Milestone 4 (QL-SD): bridge sd_card.sv's scalar SD-protocol
   -- ports to vdrives.vhd's VDNUM-array ports (see the signal declarations
   -- above) - sd_lba/sd_rd/sd_wr go through the _q (post-CDC) signals, NOT
   -- the raw clk_main_i-domain ones, see the CDC note above.
   qlsd_sd_lba_arr(0)     <= qlsd_sd_lba_q;
   qlsd_sd_blk_cnt_arr(0) <= (others => '0');  -- one 512-byte block per SD transaction, matches sd_card.sv's own per-LBA behaviour and vdrives' BLKSZ=>2
   qlsd_sd_rd_arr(0)      <= qlsd_sd_rd_q;
   qlsd_sd_wr_arr(0)      <= qlsd_sd_wr_q;
   qlsd_sd_ack            <= qlsd_sd_ack_arr(0);
   -- QL4M65 Milestone 4 (QL-SD, M4008): this used to be assigned the wrong
   -- way round (qlsd_sd_buff_din <= qlsd_sd_buff_din_arr(0)), inherited
   -- from the reverted M2001 attempt. qlsd_sd_buff_din is sd_card.sv's
   -- OUTPUT (a byte read out of its sector buffer); sd_buff_din_i is
   -- vdrives.vhd's INPUT. Data flows sd_card -> vdrives, so it is the array
   -- element that has to be driven. Vivado had been reporting the real
   -- symptom all along: "[Synth 8-3848] Net qlsd_sd_buff_din_arr[0] ... does
   -- not have driver". Only affects the write-back path (HANDLE_DRV_WR), so
   -- it was never the mount blocker - but it would have silently corrupted
   -- every sector written back to the .win file.
   -- M4011: taken straight off the buffer RAM's port A instead of through
   -- sd_card.sv's sd_buff_din output, which is only a passthrough of the
   -- same signal ("assign sd_buff_din = ram_a_q_i;"). With port A now
   -- driven entirely from vdrives (see i_qlsd_ram below), the whole
   -- qnice-domain side of the buffer no longer touches sd_card.sv at all.
   qlsd_sd_buff_din_arr(0) <= qlsd_ram_a_q;

   -- QL4M65 Milestone 4 (QL-SD, M4009): see these signals' own declarations -
   -- nothing but plain signals may reach i_sd_card's port map.
   -- M4011b: img_size/img_mounted are taken RAW from vdrives, with no CDC of
   -- our own. vdrives.vhd already brings them into the core clock domain
   -- itself (i_cdc_q2m_img_mounted / i_cdc_qnice2main, both dest_clk =>
   -- clk_core_i, and its own source comment says so: "Core clock domain:
   -- Output registers"), which is exactly the domain sd_card.sv's clk_sys
   -- block wants here. M4011's first attempt added a second qnice->main
   -- bridge on top, which meant clocking an already-core-domain signal into
   -- a qnice-domain register - a brand new main->qnice crossing that became
   -- the entire remaining timing failure (15 violated paths, WNS -4.234,
   -- every one of them vdrives' own CDC output feeding ours). Only the
   -- QNICE-domain outputs of vdrives (sd_ack, sd_buff_*) need a bridge, and
   -- they get one below.
   qlsd_img_size64    <= x"00000000" & qlsd_img_size;
   qlsd_img_mounted0  <= qlsd_img_mounted(0);
   qlsd_sd_buff_addr9 <= qlsd_sd_buff_addr(8 downto 0);
   qlsd_sdhc_one      <= C_QLSD_SDHC_ONE;

   -- M4011: sd_card.sv's buffer index, main domain (see the CDC note at the
   -- signal declarations). It is the top 2 bits of ram_a_addr_o, which is
   -- the one port of sd_card.sv that genuinely mixes two clock domains.
   qlsd_sd_buf_main <= qlsd_ram_a_addr(10 downto 9);

   -- M4011: the buffer RAM's port A address, assembled entirely in the
   -- qnice domain - CDC'd buffer index + vdrives' own sd_buff_addr, rather
   -- than sd_card.sv's mixed-domain ram_a_addr_o.
   qlsd_ram_a_addr_q <= qlsd_sd_buf_q & qlsd_sd_buff_addr(8 downto 0);

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
   -- QL4M65 Milestone 3, Fase 1 (2026-08-24): main RAM - BRAM. Reverted
   -- from qram_avm.vhd/HyperRAM (M3001/M3002) - see DECISIONES.md's
   -- "Milestone 3 - pivote de HyperRAM a BRAM" for why. Only the CPU
   -- touches main RAM; port B is unused on both banks.
   --
   -- QL4M65 M4010 (2026-09-09): split into two exactly-sized banks and
   -- rebased to $020000. Until M4009 this was ONE dualport_2clk_ram_byte-
   -- enable with G_ADDR_WIDTH=>19 addressed by cpu_addr(19 downto 1) raw,
   -- i.e. 2**19 words = 1MB of BRAM permanently allocated even when the
   -- 128k tier was selected, because tdp_ram.vhd declares its array as
   -- "array(0 to 2**ADDR_WIDTH - 1)" - there is no word-count generic to
   -- size it exactly, and without the $020000 rebase the top address
   -- ($0BFFFF) needs bit 19 anyway. That cost 256 RAMB36 tiles and, once
   -- M4009 finally got sd_card.sv into the design for real, pushed BRAM
   -- to 350/365 (95.9%) and broke timing hard (WNS=-4.844ns) on pure
   -- routing from the CPU's address register to this RAM's ADDRARDADDR.
   --
   -- The 1024k tier is gone (user decision) so 640k is the top: 655360
   -- bytes = 327680 words, which is NOT a power of two. Two banks cover
   -- it exactly - 2**18 words (512k bytes) + 2**16 words (128k bytes) -
   -- for 160 RAMB36 instead of 256, freeing ~96 tiles.
   --
   -- The rebase is cheap: subtracting $020000 from a word address only
   -- touches bits 18..16, so it is a 3-bit decrement, not a 19-bit
   -- subtractor. Offsets 0..$3FFFF land in the low bank, $40000..$4FFFF
   -- in the high one; cpu_ram's own decode guarantees nothing above that
   -- ever reaches here.
   ---------------------------------------------------------------------------

   ram_woff    <= std_logic_vector(unsigned(cpu_addr(19 downto 17)) - 1) & cpu_addr(16 downto 1);
   ram_bank_hi <= ram_woff(18);

   -- Both banks read with one cycle of latency (tdp_ram registers the
   -- address, not the data), so the bank select feeding the output mux has
   -- to be delayed by exactly the same one cycle - unconditionally, since
   -- dualport_2clk_ram_byteenable exposes no clock enable.
   p_ram_bank : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         ram_bank_hi_r <= ram_bank_hi;
      end if;
   end process p_ram_bank;

   ram_q_a <= ram_q_hi when ram_bank_hi_r = '1' else ram_q_lo;

   i_main_ram_lo : entity work.dualport_2clk_ram_byteenable
      generic map (
         G_ADDR_WIDTH => 18,  -- 512k bytes = 256K words ($020000-$09FFFF)
         G_DATA_WIDTH => 16
      )
      port map (
         a_clk_i        => clk_main_i,
         a_address_i    => ram_woff(17 downto 0),
         a_data_i       => cpu_dout,
         a_byteenable_i => cpu_uds & cpu_lds,
         a_wren_i       => cpu_wr and cpu_ram and (not ram_bank_hi),
         a_q_o          => ram_q_lo,

         b_clk_i        => clk_main_i,
         b_address_i    => (others => '0'),
         b_data_i       => (others => '0'),
         b_byteenable_i => (others => '0'),
         b_wren_i       => '0',
         b_q_o          => open
      ); -- i_main_ram_lo

   i_main_ram_hi : entity work.dualport_2clk_ram_byteenable
      generic map (
         G_ADDR_WIDTH => 16,  -- 128k bytes = 64K words ($0A0000-$0BFFFF)
         G_DATA_WIDTH => 16
      )
      port map (
         a_clk_i        => clk_main_i,
         a_address_i    => ram_woff(15 downto 0),
         a_data_i       => cpu_dout,
         a_byteenable_i => cpu_uds & cpu_lds,
         a_wren_i       => cpu_wr and cpu_ram and ram_bank_hi,
         a_q_o          => ram_q_hi,

         b_clk_i        => clk_main_i,
         b_address_i    => (others => '0'),
         b_data_i       => (others => '0'),
         b_byteenable_i => (others => '0'),
         b_wren_i       => '0',
         b_q_o          => open
      ); -- i_main_ram_hi

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
         elsif mdv1_motor_cnt = mdv_motor_half_period - 1 then
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
         elsif mdv2_motor_cnt = mdv_motor_half_period - 1 then
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

   ---------------------------------------------------------------------------
   -- QL4M65 Milestone 4 (QL-SD, paso 1, M4001): qlromext.v, unmodified,
   -- instantiated as-is
   ---------------------------------------------------------------------------

   i_qlromext : entity work.qlromext
      port map (
         clk      => clk_main_i,

         ce_sd    => ce_sd,
         dtack    => qlsd_dtack,

         a        => cpu_addr(15 downto 0),
         d        => qlsd_dout,
         romoel   => not qlsd_sel,

         io1      => open,
         io2      => '0',   -- unused expansion input, tied off (matches QL.sv's own .io2(1'b0))
         io3      => open,
         io4      => open,

         sd_clk   => qlsd_spi_clk,
         sd_cs1l  => qlsd_spi_cs1l,
         sd_cs2l  => qlsd_spi_cs2l,
         sd_do    => qlsd_spi_do,
         sd_di    => qlsd_spi_di
      ); -- i_qlromext

   ---------------------------------------------------------------------------
   -- QL4M65 Milestone 4 (QL-SD, paso 1, M4001/M4003): sd_card.sv (SPI-slave
   -- SD emulator), unmodified except the ram_a_*/ram_b_* port additions
   -- (altsyncram removal, see doc/m2m/exceptions.md) and the WIDE(0)
   -- instantiation parameter (not WIDE(1) like the original QL.sv - see
   -- .research/qlsd-design.md).
   --
   -- clk_sys => clk_main_i (M4003, was qnice_clk_i in M4001/the original
   -- M2001 attempt): re-reading sd_card.sv's actual RTL (not just its
   -- ports/comments) shows sd_lba/sd_rd/sd_wr are generated INSIDE the
   -- `always @(posedge clk_spi)` block, not `always @(posedge clk_sys)`
   -- (that one only computes csd_size/csd_sdhc) - confirmed against the
   -- real QL.sv:287-297, which ties BOTH sd_card's clk_sys and clk_spi to
   -- QL.sv's own single `clk_sys` (the CORE's clock, via Verilog's `.*`
   -- wildcard port connection + the explicit `.clk_spi(clk_sys)`) - i.e.
   -- the reference core never actually separates these two clocks despite
   -- the name "clk_sys" suggesting an HPS/ARM-equivalent clock elsewhere in
   -- the MiSTer ecosystem (see vdrives.vhd's own comment on sd_lba_i: "oddly
   -- deep down in MiSTer code 'clk_sys' is not the core, but the 'sd
   -- write', i.e. QNICE" - accurate general M2M guidance, but not what
   -- THIS core's own sd_card.sv actually does internally). Tying clk_sys to
   -- qnice_clk_i (M4001) left sd_lba/sd_rd/sd_wr genuinely generated in
   -- clk_main_i but consumed raw by vdrives.vhd's qnice_clk_i-domain logic
   -- (confirmed by reading vdrives.vhd itself: unlike img_mounted/img_size/
   -- reset_core_i/drive_mounted_reg, which DO get their own
   -- xpm_cdc_array_single bridges inside vdrives.vhd, sd_lba_i/sd_rd_i/
   -- sd_wr_i get none - the module's contract expects the CALLER to already
   -- provide them synchronized) - a real, unbridged CDC hazard, likely why
   -- M4001/the original M2003 got as far as "Checking FAT" (raw SPI
   -- communication working, once M4001's ss fix landed) but never past it
   -- (block-level LBA/rd/wr corrupted by the crossing). Fixed here by
   -- matching QL.sv's own clk_sys=clk_spi=core-clock wiring exactly, with
   -- the now-necessary CDC added explicitly below (M2M's own architecture
   -- doesn't get an implicit "already-bridged" clk_sys the way real
   -- MiSTer's HPS-facing bridge IP gives every core for free).
   --
   -- ss => qlsd_spi_cs1l direct, NOT inverted: original QL.sv:294 is
   -- .ss(sd_cs1 || ~vsd_sel) - with vsd_sel=1 (always true here, we have
   -- no physical/virtual SD switch at all) that collapses to a plain
   -- ss = sd_cs1l pass-through. sd_cs1l is already active-low (qlromext.v's
   -- own `assign sd_cs1l = interface_enabled ? ss1 : 1'b1`), matching
   -- sd_card.sv's own `if(ss) begin ... reset ... end` (active-low select,
   -- ss=1 = idle) - so no inversion belongs here. (An earlier, reverted
   -- M2001-M2003 attempt at this had `ss => not qlsd_spi_cs1l` here.)
   ---------------------------------------------------------------------------

   -- QL4M65 Milestone 4 (QL-SD, M4008): instantiated through
   -- CORE/vhdl/sd_card_wrap.v, NOT directly. sd_card.sv's own port list
   -- declares several widths with localparams declared after the port list
   -- ([AW:0]/[DW:0]/[SW:0]), which Vivado cannot resolve when binding a
   -- SystemVerilog module from VHDL - it connected NOTHING and every output
   -- of this instance came back undriven ("[Synth 8-3848] Net qlsd_spi_do /
   -- qlsd_sd_lba / qlsd_sd_rd / qlsd_sd_wr / qlsd_ram_* does not have
   -- driver"), i.e. the SD-card emulator was absent from builds M4001-M4007
   -- while we debugged it. The wrapper has literal port widths and does the
   -- WIDE(0)/OCTAL(0) instantiation from Verilog instead - see that file's
   -- own header, doc/m2m/exceptions.md and DECISIONES.md.
   i_sd_card : sd_card_wrap
      port map (
         clk_sys      => clk_main_i,
         reset        => reset,

         sdhc         => qlsd_sdhc_one,
         img_mounted  => qlsd_img_mounted0,
         img_size     => qlsd_img_size64,

         sd_lba       => qlsd_sd_lba,
         sd_rd        => qlsd_sd_rd,
         sd_wr        => qlsd_sd_wr,
         -- M4011: the SYNCHRONISED ack (qnice -> main). sd_card.sv's other
         -- use of sd_ack (ram_a_wren_o) is bypassed entirely - the buffer
         -- RAM's port A is driven straight from vdrives below.
         sd_ack       => qlsd_sd_ack_main,

         sd_buff_addr => qlsd_sd_buff_addr9,
         sd_buff_dout => qlsd_sd_buff_dout,
         sd_buff_din  => qlsd_sd_buff_din,
         sd_buff_wr   => qlsd_sd_buff_wr,

         clk_spi      => clk_main_i,

         ss           => qlsd_spi_cs1l,
         sck          => qlsd_spi_clk,
         mosi         => qlsd_spi_di,
         miso         => qlsd_spi_do,

         ram_a_addr_o => qlsd_ram_a_addr,
         ram_a_data_o => qlsd_ram_a_data,
         ram_a_wren_o => qlsd_ram_a_wren,
         ram_a_q_i    => qlsd_ram_a_q,

         ram_b_addr_o => qlsd_ram_b_addr,
         ram_b_data_o => qlsd_ram_b_data,
         ram_b_wren_o => qlsd_ram_b_wren,
         ram_b_q_i    => qlsd_ram_b_q
      ); -- i_sd_card

   -- QL4M65 Milestone 4 (QL-SD, paso 1, M4003): the CDC bridge sd_lba/sd_rd/
   -- sd_wr genuinely need (see i_sd_card's own comment above) - clk_main_i
   -- (real source, sd_card.sv's clk_spi-domain always block) into
   -- qnice_clk_i (what vdrives.vhd actually requires at its sd_lba_i/
   -- sd_rd_i/sd_wr_i ports). Same primitive, same plain-WIDTH-generic style
   -- vdrives.vhd already uses internally for its own CDC (i_cdc_qnice2main/
   -- i_cdc_main2qnice) - not a hand-rolled synchronizer.
   i_qlsd_sd_block_cdc : xpm_cdc_array_single
      generic map (
         WIDTH => 34
      )
      port map (
         src_clk               => clk_main_i,
         src_in(31 downto 0)   => qlsd_sd_lba,
         src_in(32)            => qlsd_sd_rd,
         src_in(33)            => qlsd_sd_wr,
         dest_clk               => qnice_clk_i,
         dest_out(31 downto 0)  => qlsd_sd_lba_q,
         dest_out(32)           => qlsd_sd_rd_q,
         dest_out(33)           => qlsd_sd_wr_q
      ); -- i_qlsd_sd_block_cdc

   -- QL4M65 Milestone 4 (QL-SD, M4011): sd_buf, main -> qnice. Quasi-static
   -- (only changes on the falling edge of ack, between transfers), so a
   -- plain array_single is correct here - see the CDC note at the signal
   -- declarations for the full reasoning.
   i_qlsd_sd_buf_cdc : xpm_cdc_array_single
      generic map (
         WIDTH => 2
      )
      port map (
         src_clk   => clk_main_i,
         src_in    => qlsd_sd_buf_main,
         dest_clk  => qnice_clk_i,
         dest_out  => qlsd_sd_buf_q
      ); -- i_qlsd_sd_buf_cdc

   -- QL4M65 Milestone 4 (QL-SD, M4011): sd_ack, qnice -> main. This is the
   -- crossing that cost -4.845ns in M4010: sd_card.sv's own hand-rolled
   -- 2-FF synchroniser on this signal carries no timing exception, so
   -- Vivado timed it against a 0.476ns requirement. Feeding it an already
   -- synchronised ack turns that into an ordinary main_clk -> main_clk
   -- path; sd_card.sv's internal 2-FF then just re-registers a signal
   -- already in its own domain, which is harmless.
   i_qlsd_sd_ack_cdc : xpm_cdc_single
      generic map (
         DEST_SYNC_FF   => 4,
         INIT_SYNC_FF   => 0,
         SIM_ASSERT_CHK => 0,
         SRC_INPUT_REG  => 1
      )
      port map (
         src_clk   => qnice_clk_i,
         src_in    => qlsd_sd_ack,
         dest_clk  => clk_main_i,
         dest_out  => qlsd_sd_ack_main
      ); -- i_qlsd_sd_ack_cdc

   -- QL4M65 Milestone 4 (QL-SD, paso 1): sd_card.sv's internal "sdbuf" RAM,
   -- externally instantiated (Vivado-clean replacement for its original
   -- altsyncram - see doc/m2m/exceptions.md). Both ports are genuinely 8
   -- bits wide with WIDE(0) above, so a plain dualport_2clk_ram fits with
   -- no asymmetric width handling needed.
   --
   -- M4011: port A is now driven straight from vdrives.vhd's own
   -- qnice-domain signals (address assembled above, data = sd_buff_dout,
   -- write enable = ack AND sd_buff_wr) instead of from sd_card.sv's
   -- ram_a_addr_o/ram_a_data_o/ram_a_wren_o. Those three are only
   -- passthroughs of exactly these signals ("assign ram_a_data_o =
   -- sd_buff_dout; assign ram_a_wren_o = sd_ack & sd_buff_wr;"), but
   -- routing them through the Verilog module dragged sd_card's own
   -- main-domain sd_buf into a qnice-clocked BRAM address port. Taking
   -- them from vdrives directly keeps this whole port in one domain.
   i_qlsd_ram : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH => 11,
         DATA_WIDTH => 8
      )
      port map (
         clock_a   => qnice_clk_i,
         address_a => qlsd_ram_a_addr_q,
         data_a    => qlsd_sd_buff_dout,
         wren_a    => qlsd_sd_ack and qlsd_sd_buff_wr,
         q_a       => qlsd_ram_a_q,

         clock_b   => clk_main_i,
         address_b => qlsd_ram_b_addr,
         data_b    => qlsd_ram_b_data,
         wren_b    => qlsd_ram_b_wren,
         q_b       => qlsd_ram_b_q
      ); -- i_qlsd_ram

   ---------------------------------------------------------------------------
   -- QL4M65 Milestone 4 (QL-SD, paso 1, M4001): vdrives.vhd, unmodified
   -- generic M2M framework module (zero QL-specific changes), bridges
   -- sd_card.sv's generic "SD" protocol to QNICE/FAT32.
   ---------------------------------------------------------------------------

   i_vdrives : entity work.vdrives
      generic map (
         VDNUM => G_VDNUM,
         BLKSZ => 2   -- 512-byte blocks, matches sd_card.sv's own sector-size assumption
      )
      port map (
         clk_qnice_i       => qnice_clk_i,
         clk_core_i        => clk_main_i,
         reset_core_i      => reset,

         img_mounted_o     => qlsd_img_mounted,
         img_readonly_o    => open,
         img_size_o        => qlsd_img_size,
         img_type_o        => open,

         drive_mounted_o   => open,
         cache_dirty_o     => open,
         cache_flushing_o  => open,

         sd_lba_i          => qlsd_sd_lba_arr,
         sd_blk_cnt_i      => qlsd_sd_blk_cnt_arr,
         sd_rd_i           => qlsd_sd_rd_arr,
         sd_wr_i           => qlsd_sd_wr_arr,
         sd_ack_o          => qlsd_sd_ack_arr,

         sd_buff_addr_o    => qlsd_sd_buff_addr,
         sd_buff_dout_o    => qlsd_sd_buff_dout,
         sd_buff_din_i     => qlsd_sd_buff_din_arr,
         sd_buff_wr_o      => qlsd_sd_buff_wr,

         qnice_addr_i      => qnice_qlsd_addr_i,
         qnice_data_i      => qnice_qlsd_data_i,
         qnice_data_o      => qnice_qlsd_data_o,
         qnice_ce_i        => qnice_qlsd_ce_i,
         qnice_we_i        => qnice_qlsd_we_i
      ); -- i_vdrives

end architecture synthesis;

