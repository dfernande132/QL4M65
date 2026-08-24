----------------------------------------------------------------------------------
-- Sinclair QL for MEGA65 (QL4M65)
--
-- MEGA65 main file that contains the whole machine
--
-- Powered by MiSTer2MEGA65
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
-- QL4M65 port done by Jose Daniel Fernandez Santos (dfsantos) in 2026 and
-- licensed under GPL v3: removed demo device handling and the demo's
-- virtual-drive instance (not needed until milestone 3), fixed menu/video
-- wiring to milestone 1's scope, and wired the ql_rom (Minerva) memory path
-- to main.vhd. i_main's port map still points at the M2M demo core -
-- replacing it with the real QL core is milestone 1's M1001 step
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.globals.all;
use work.types_pkg.all;
use work.video_modes_pkg.all;
use work.qnice_csr_pkg.all;

library xpm;
use xpm.vcomponents.all;

entity MEGA65_Core is
generic (
   G_BOARD : string                                         -- Which platform are we running on.
);
port (
   --------------------------------------------------------------------------------------------------------
   -- QNICE Clock Domain
   --------------------------------------------------------------------------------------------------------

   -- Get QNICE clock from the framework: for the vdrives as well as for RAMs and ROMs
   qnice_clk_i             : in  std_logic;
   qnice_rst_i             : in  std_logic;

   -- Video and audio mode control
   qnice_dvi_o             : out std_logic;              -- 0=HDMI (with sound), 1=DVI (no sound)
   qnice_video_mode_o      : out video_mode_type;        -- Defined in video_modes_pkg.vhd
   qnice_osm_cfg_scaling_o : out std_logic_vector(8 downto 0);
   qnice_scandoubler_o     : out std_logic;              -- 0 = no scandoubler, 1 = scandoubler
   qnice_audio_mute_o      : out std_logic;
   qnice_audio_filter_o    : out std_logic;
   qnice_zoom_crop_o       : out std_logic;
   qnice_ascal_mode_o      : out std_logic_vector(1 downto 0);
   qnice_ascal_polyphase_o : out std_logic;
   qnice_ascal_triplebuf_o : out std_logic;
   qnice_retro15kHz_o      : out std_logic;              -- 0 = normal frequency, 1 = retro 15 kHz frequency
   qnice_csync_o           : out std_logic;              -- 0 = normal HS/VS, 1 = Composite Sync  

   -- Flip joystick ports
   qnice_flip_joyports_o   : out std_logic;

   -- On-Screen-Menu selections
   qnice_osm_control_i     : in  std_logic_vector(255 downto 0);

   -- QNICE general purpose register
   qnice_gp_reg_i          : in  std_logic_vector(255 downto 0);

   -- Core-specific devices
   qnice_dev_id_i          : in  std_logic_vector(15 downto 0);
   qnice_dev_addr_i        : in  std_logic_vector(27 downto 0);
   qnice_dev_data_i        : in  std_logic_vector(15 downto 0);
   qnice_dev_data_o        : out std_logic_vector(15 downto 0);
   qnice_dev_ce_i          : in  std_logic;
   qnice_dev_we_i          : in  std_logic;
   qnice_dev_wait_o        : out std_logic;

   --------------------------------------------------------------------------------------------------------
   -- HyperRAM Clock Domain
   --------------------------------------------------------------------------------------------------------

   hr_clk_i                : in  std_logic;
   hr_rst_i                : in  std_logic;
   hr_core_write_o         : out std_logic;
   hr_core_read_o          : out std_logic;
   hr_core_address_o       : out std_logic_vector(31 downto 0);
   hr_core_writedata_o     : out std_logic_vector(15 downto 0);
   hr_core_byteenable_o    : out std_logic_vector( 1 downto 0);
   hr_core_burstcount_o    : out std_logic_vector( 7 downto 0);
   hr_core_readdata_i      : in  std_logic_vector(15 downto 0);
   hr_core_readdatavalid_i : in  std_logic;
   hr_core_waitrequest_i   : in  std_logic;
   hr_high_i               : in  std_logic;  -- Core is too fast
   hr_low_i                : in  std_logic;  -- Core is too slow

   --------------------------------------------------------------------------------------------------------
   -- Video Clock Domain
   --------------------------------------------------------------------------------------------------------

   video_clk_o             : out std_logic;
   video_rst_o             : out std_logic;
   video_ce_o              : out std_logic;
   video_ce_ovl_o          : out std_logic;
   video_red_o             : out std_logic_vector(7 downto 0);
   video_green_o           : out std_logic_vector(7 downto 0);
   video_blue_o            : out std_logic_vector(7 downto 0);
   video_vs_o              : out std_logic;
   video_hs_o              : out std_logic;
   video_hblank_o          : out std_logic;
   video_vblank_o          : out std_logic;

   --------------------------------------------------------------------------------------------------------
   -- Core Clock Domain
   --------------------------------------------------------------------------------------------------------

   clk_i                   : in  std_logic;              -- 100 MHz clock

   -- Share clock and reset with the framework
   main_clk_o              : out std_logic;              -- CORE's 54 MHz clock
   main_rst_o              : out std_logic;              -- CORE's reset, synchronized

   -- M2M's reset manager provides 2 signals:
   --    m2m:   Reset the whole machine: Core and Framework
   --    core:  Only reset the core
   main_reset_m2m_i        : in  std_logic;
   main_reset_core_i       : in  std_logic;

   main_pause_core_i       : in  std_logic;

   -- On-Screen-Menu selections
   main_osm_control_i      : in  std_logic_vector(255 downto 0);

   -- QNICE general purpose register converted to main clock domain
   main_qnice_gp_reg_i     : in  std_logic_vector(255 downto 0);

   -- Audio output (Signed PCM)
   main_audio_left_o       : out signed(15 downto 0);
   main_audio_right_o      : out signed(15 downto 0);

   -- M2M Keyboard interface (incl. power led and drive led)
   main_kb_key_num_i       : in  integer range 0 to 79;  -- cycles through all MEGA65 keys
   main_kb_key_pressed_n_i : in  std_logic;              -- low active: debounced feedback: is kb_key_num_i pressed right now?
   main_power_led_o        : out std_logic;
   main_power_led_col_o    : out std_logic_vector(23 downto 0);
   main_drive_led_o        : out std_logic;
   main_drive_led_col_o    : out std_logic_vector(23 downto 0);

   -- Joysticks and paddles input
   main_joy_1_up_n_i       : in  std_logic;
   main_joy_1_down_n_i     : in  std_logic;
   main_joy_1_left_n_i     : in  std_logic;
   main_joy_1_right_n_i    : in  std_logic;
   main_joy_1_fire_n_i     : in  std_logic;
   main_joy_1_up_n_o       : out std_logic;
   main_joy_1_down_n_o     : out std_logic;
   main_joy_1_left_n_o     : out std_logic;
   main_joy_1_right_n_o    : out std_logic;
   main_joy_1_fire_n_o     : out std_logic;
   main_joy_2_up_n_i       : in  std_logic;
   main_joy_2_down_n_i     : in  std_logic;
   main_joy_2_left_n_i     : in  std_logic;
   main_joy_2_right_n_i    : in  std_logic;
   main_joy_2_fire_n_i     : in  std_logic;
   main_joy_2_up_n_o       : out std_logic;
   main_joy_2_down_n_o     : out std_logic;
   main_joy_2_left_n_o     : out std_logic;
   main_joy_2_right_n_o    : out std_logic;
   main_joy_2_fire_n_o     : out std_logic;

   main_pot1_x_i           : in  std_logic_vector(7 downto 0);
   main_pot1_y_i           : in  std_logic_vector(7 downto 0);
   main_pot2_x_i           : in  std_logic_vector(7 downto 0);
   main_pot2_y_i           : in  std_logic_vector(7 downto 0);
   main_rtc_i              : in  std_logic_vector(64 downto 0);

   -- CBM-488/IEC serial port
   iec_reset_n_o           : out std_logic;
   iec_atn_n_o             : out std_logic;
   iec_clk_en_o            : out std_logic;
   iec_clk_n_i             : in  std_logic;
   iec_clk_n_o             : out std_logic;
   iec_data_en_o           : out std_logic;
   iec_data_n_i            : in  std_logic;
   iec_data_n_o            : out std_logic;
   iec_srq_en_o            : out std_logic;
   iec_srq_n_i             : in  std_logic;
   iec_srq_n_o             : out std_logic;

   -- C64 Expansion Port (aka Cartridge Port)
   cart_en_o               : out std_logic;  -- Enable port, active high
   cart_phi2_o             : out std_logic;
   cart_dotclock_o         : out std_logic;
   cart_dma_i              : in  std_logic;
   cart_reset_oe_o         : out std_logic;
   cart_reset_i            : in  std_logic;
   cart_reset_o            : out std_logic;
   cart_game_oe_o          : out std_logic;
   cart_game_i             : in  std_logic;
   cart_game_o             : out std_logic;
   cart_exrom_oe_o         : out std_logic;
   cart_exrom_i            : in  std_logic;
   cart_exrom_o            : out std_logic;
   cart_nmi_oe_o           : out std_logic;
   cart_nmi_i              : in  std_logic;
   cart_nmi_o              : out std_logic;
   cart_irq_oe_o           : out std_logic;
   cart_irq_i              : in  std_logic;
   cart_irq_o              : out std_logic;
   cart_roml_oe_o          : out std_logic;
   cart_roml_i             : in  std_logic;
   cart_roml_o             : out std_logic;
   cart_romh_oe_o          : out std_logic;
   cart_romh_i             : in  std_logic;
   cart_romh_o             : out std_logic;
   cart_ctrl_oe_o          : out std_logic; -- 0 : tristate (i.e. input), 1 : output
   cart_ba_i               : in  std_logic;
   cart_rw_i               : in  std_logic;
   cart_io1_i              : in  std_logic;
   cart_io2_i              : in  std_logic;
   cart_ba_o               : out std_logic;
   cart_rw_o               : out std_logic;
   cart_io1_o              : out std_logic;
   cart_io2_o              : out std_logic;
   cart_addr_oe_o          : out std_logic; -- 0 : tristate (i.e. input), 1 : output
   cart_a_i                : in  unsigned(15 downto 0);
   cart_a_o                : out unsigned(15 downto 0);
   cart_data_oe_o          : out std_logic; -- 0 : tristate (i.e. input), 1 : output
   cart_d_i                : in  unsigned( 7 downto 0);
   cart_d_o                : out unsigned( 7 downto 0)
);
end entity MEGA65_Core;

architecture synthesis of MEGA65_Core is

---------------------------------------------------------------------------------------------
-- Clocks and active high reset signals for each clock domain
---------------------------------------------------------------------------------------------

signal main_clk               : std_logic;               -- Core main clock
signal main_rst               : std_logic;

---------------------------------------------------------------------------------------------
-- QL4M65: system ROM (Main 48K + Back 16K) - QNICE write (manual/auto load), core read-only
---------------------------------------------------------------------------------------------

signal qnice_rom_we_u         : std_logic;
signal qnice_rom_we_l         : std_logic;
signal qnice_rom_q_u          : std_logic_vector(7 downto 0);
signal qnice_rom_q_l          : std_logic_vector(7 downto 0);

signal main_rom_addr          : std_logic_vector(14 downto 0);
signal main_rom_q_u           : std_logic_vector(7 downto 0);
signal main_rom_q_l           : std_logic_vector(7 downto 0);

-- QL4M65: Main/Back ROM CSR (4k window 0xFFFF) + "always answer" size-check
-- FSMs - see globals.vhd's C_DEV_QL_MAINROM/BACKROM comment. Neither device
-- ever implemented this M2M protocol before, which is why manual ROM
-- loading has always hung QNICE solid (no timeout on the firmware's poll
-- loop) - not a new bug, present since manual loading was first added; see
-- DECISIONES.md. Modeled on AExp's adf_mount_wrapper.vhd, simplified: no
-- HyperRAM/iterative validation needed, just one fixed-size comparison.
constant C_MAINROM_BYTES      : natural := 49152;                 -- 48 KB exactly
constant C_BACKROM_BYTES      : natural := 16384;                 -- 16 KB exactly
constant C_BACKROM_WORD_OFFS  : natural := C_MAINROM_BYTES / 2;   -- 24576 words into ql_rom_u/l

-- 21 chars each: 19 text chars + the literal 2-char "\n" the Shell's printer interprets
constant C_ROM_ERROR_STRINGS : string_vector(0 to 15) := (
  "OK                 \n",
  "Wrong ROM size     \n",
  "OK                 \n",
  "OK                 \n",
  "OK                 \n",
  "OK                 \n",
  "OK                 \n",
  "OK                 \n",
  "OK                 \n",
  "OK                 \n",
  "OK                 \n",
  "OK                 \n",
  "OK                 \n",
  "OK                 \n",
  "OK                 \n",
  "OK                 \n");

type t_rom_val_state is (VS_IDLE, VS_DONE);

signal main_ce                : std_logic;
signal main_csr_active        : std_logic;
signal main_csr_data          : std_logic_vector(15 downto 0);
signal main_csr_wait          : std_logic;
signal main_req_status        : std_logic_vector( 3 downto 0);
signal main_req_length        : std_logic_vector(22 downto 0);
signal main_resp_status       : std_logic_vector( 3 downto 0) := C_CSR_RESP_IDLE;
signal main_resp_error        : std_logic_vector( 3 downto 0) := x"0";
signal main_val_state         : t_rom_val_state := VS_IDLE;

signal back_ce                : std_logic;
signal back_csr_active        : std_logic;
signal back_csr_data          : std_logic_vector(15 downto 0);
signal back_csr_wait          : std_logic;
signal back_req_status        : std_logic_vector( 3 downto 0);
signal back_req_length        : std_logic_vector(22 downto 0);
signal back_resp_status       : std_logic_vector( 3 downto 0) := C_CSR_RESP_IDLE;
signal back_resp_error        : std_logic_vector( 3 downto 0) := x"0";
signal back_val_state         : t_rom_val_state := VS_IDLE;

-- shared BRAM address bus: Main passes qnice_dev_addr_i through unmodified,
-- Back adds C_BACKROM_WORD_OFFS so its own device-local address 0 lands
-- 48 KB into the same physical ql_rom_u/l instances
signal rom_addr_b             : std_logic_vector(14 downto 0);

-- QL4M65 (Milestone 2 phase A): mdv1 microdrive image CSR (4k window
-- 0xFFFF) + size-check FSM - same "always answer" protocol as Main/Back
-- ROM above, but a RANGE check (<= C_MDV1_MAX_BYTES) instead of an exact
-- match, since real .MDV images vary in length (globals.vhd's own comment
-- on C_MDV1_MAX_BYTES). The actual byte stream itself is NOT buffered here
-- (unlike Main/Back ROM's BRAM) - qnice_mdv1_ce/we/addr/data go straight
-- through to main.vhd's own loader (mdv1's buffer lives there, see
-- .research/microdrive-read-design.md section A.2); qnice_mdv1_wait comes
-- back from main.vhd while a byte is still crossing clock domains.
signal mdv1_ce                : std_logic;
signal mdv1_csr_active        : std_logic;
signal mdv1_csr_data          : std_logic_vector(15 downto 0);
signal mdv1_csr_wait          : std_logic;
signal mdv1_req_status        : std_logic_vector( 3 downto 0);
signal mdv1_req_length        : std_logic_vector(22 downto 0);
signal mdv1_resp_status       : std_logic_vector( 3 downto 0) := C_CSR_RESP_IDLE;
signal mdv1_resp_error        : std_logic_vector( 3 downto 0) := x"0";
signal mdv1_val_state         : t_rom_val_state := VS_IDLE;

signal qnice_mdv1_ce          : std_logic;
signal qnice_mdv1_we          : std_logic;
signal qnice_mdv1_wait        : std_logic;
signal qnice_mdv1_data        : std_logic_vector(15 downto 0);

-- QL4M65 Milestone 2 paso 5, etapa 2 (2026-08-23,
-- .research/microdrive-second-unit-plan.md section 2.1): mdv2's own CSR +
-- size-check FSM, mismo patron exacto que mdv1's own set above (mismo
-- C_MDV1_MAX_BYTES - el formato .mdv es el mismo, el rango de tamano
-- valido no cambia por unidad).
signal mdv2_ce                : std_logic;
signal mdv2_csr_active        : std_logic;
signal mdv2_csr_data          : std_logic_vector(15 downto 0);
signal mdv2_csr_wait          : std_logic;
signal mdv2_req_status        : std_logic_vector( 3 downto 0);
signal mdv2_req_length        : std_logic_vector(22 downto 0);
signal mdv2_resp_status       : std_logic_vector( 3 downto 0) := C_CSR_RESP_IDLE;
signal mdv2_resp_error        : std_logic_vector( 3 downto 0) := x"0";
signal mdv2_val_state         : t_rom_val_state := VS_IDLE;

signal qnice_mdv2_ce          : std_logic;
signal qnice_mdv2_we          : std_logic;
signal qnice_mdv2_wait        : std_logic;
signal qnice_mdv2_data        : std_logic_vector(15 downto 0);
signal qnice_mdv2_loading     : std_logic;

-- QL4M65 (Milestone 2 phase A, M2008): microdrive activity LED, core-clock
-- domain (main.vhd's own "led" tap from zx8302.v - a single level signal,
-- no CDC needed for a board LED)
signal main_mdv1_led          : std_logic;

-- QL4M65 (Milestone 2 phase B, etapa 4, M2029): any mdv1 sector dirty
-- (not yet flushed to SD)? Already in clk_main_i, straight from main.vhd's
-- own mdv1_dirty bitmap - see that port's own comment.
signal main_mdv1_dirty        : std_logic;

-- QL4M65 (Milestone 2 phase A, M2011): raw "is the Shell loading mdv1"
-- level, QNICE clock domain - main.vhd does its own synchronization into
-- clk_main_i (see that file's header comment on qnice_mdv1_loading_i).
signal qnice_mdv1_loading      : std_logic;

-- QL4M65 (Milestone 2 phase C, etapa B): mdv1's own Avalon-MM master,
-- clk_main_i domain - straight from i_main's mdv1_avm_*_o/i ports into
-- i_avm_fifo_mdv1's slave side below (main_clk -> hr_clk CDC).
signal main_mdv1_avm_write         : std_logic;
signal main_mdv1_avm_read          : std_logic;
signal main_mdv1_avm_address       : std_logic_vector(31 downto 0);
signal main_mdv1_avm_writedata     : std_logic_vector(15 downto 0);
signal main_mdv1_avm_byteenable    : std_logic_vector(1 downto 0);
signal main_mdv1_avm_burstcount    : std_logic_vector(7 downto 0);
signal main_mdv1_avm_readdata      : std_logic_vector(15 downto 0);
signal main_mdv1_avm_readdatavalid : std_logic;
signal main_mdv1_avm_waitrequest   : std_logic;

-- QL4M65 Milestone 2 paso 5, etapa 1 (2026-08-23,
-- .research/microdrive-second-unit-plan.md): mdv2's own Avalon-MM master,
-- same pattern as mdv1's own above - arbitrated together (i_avm_arbit_mdv,
-- below) before the shared i_avm_fifo_mdv1 CDC.
signal main_mdv2_avm_write         : std_logic;
signal main_mdv2_avm_read          : std_logic;
signal main_mdv2_avm_address       : std_logic_vector(31 downto 0);
signal main_mdv2_avm_writedata     : std_logic_vector(15 downto 0);
signal main_mdv2_avm_byteenable    : std_logic_vector(1 downto 0);
signal main_mdv2_avm_burstcount    : std_logic_vector(7 downto 0);
signal main_mdv2_avm_readdata      : std_logic_vector(15 downto 0);
signal main_mdv2_avm_readdatavalid : std_logic;
signal main_mdv2_avm_waitrequest   : std_logic;
signal main_mdv2_dirty             : std_logic;

-- QL4M65 Milestone 2 paso 5, etapa 1: the arbitrated stream feeding
-- i_avm_fifo_mdv1's slave side, in main_clk (see plan section 1.1 for why
-- the arbiter sits here, before the CDC, rather than after it).
signal main_mdv_arb_avm_write         : std_logic;
signal main_mdv_arb_avm_read          : std_logic;
signal main_mdv_arb_avm_address       : std_logic_vector(31 downto 0);
signal main_mdv_arb_avm_writedata     : std_logic_vector(15 downto 0);
signal main_mdv_arb_avm_byteenable    : std_logic_vector(1 downto 0);
signal main_mdv_arb_avm_burstcount    : std_logic_vector(7 downto 0);
signal main_mdv_arb_avm_readdata      : std_logic_vector(15 downto 0);
signal main_mdv_arb_avm_readdatavalid : std_logic;
signal main_mdv_arb_avm_waitrequest   : std_logic;

---------------------------------------------------------------------------------------------
-- main_clk (MiSTer core's clock)
---------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------
-- qnice_clk
---------------------------------------------------------------------------------------------

begin

   -- QL4M65 (Milestone 2 phase C, etapa B): mdv1's buffer was the first
   -- real HyperRAM consumer in this project (C_HMAP_MDV1, globals.vhd).
   --
   -- QL4M65 Milestone 2 paso 5, etapa 1 (2026-08-23,
   -- .research/microdrive-second-unit-plan.md section 1.1): now a SECOND
   -- real-time master (mdv2), arbitrated HERE, in main_clk, BEFORE the CDC
   -- - not one avm_fifo per master arbitrated after in hr_clk (that
   -- pattern, used e.g. by AExp's two-master ADF chain, exists there
   -- because ITS two masters live in different clock domains from each
   -- other; mdv1/mdv2 both live in clk_main_i, so one CDC crossing instead
   -- of two is strictly better - fewer resources, one place to reason
   -- about the crossing).
   --
   i_avm_arbit_mdv : entity work.avm_arbit
      generic map (
         G_PREFER_SWAP  => false,  -- arbitrary, see comment above
         G_ADDRESS_SIZE => 32,
         G_DATA_SIZE    => 16
      )
      port map (
         clk_i                  => main_clk,
         rst_i                  => main_reset_m2m_i,

         s0_avm_write_i         => main_mdv1_avm_write,
         s0_avm_read_i          => main_mdv1_avm_read,
         s0_avm_address_i       => main_mdv1_avm_address,
         s0_avm_writedata_i     => main_mdv1_avm_writedata,
         s0_avm_byteenable_i    => main_mdv1_avm_byteenable,
         s0_avm_burstcount_i    => main_mdv1_avm_burstcount,
         s0_avm_readdata_o      => main_mdv1_avm_readdata,
         s0_avm_readdatavalid_o => main_mdv1_avm_readdatavalid,
         s0_avm_waitrequest_o   => main_mdv1_avm_waitrequest,

         s1_avm_write_i         => main_mdv2_avm_write,
         s1_avm_read_i          => main_mdv2_avm_read,
         s1_avm_address_i       => main_mdv2_avm_address,
         s1_avm_writedata_i     => main_mdv2_avm_writedata,
         s1_avm_byteenable_i    => main_mdv2_avm_byteenable,
         s1_avm_burstcount_i    => main_mdv2_avm_burstcount,
         s1_avm_readdata_o      => main_mdv2_avm_readdata,
         s1_avm_readdatavalid_o => main_mdv2_avm_readdatavalid,
         s1_avm_waitrequest_o   => main_mdv2_avm_waitrequest,

         m_avm_write_o          => main_mdv_arb_avm_write,
         m_avm_read_o           => main_mdv_arb_avm_read,
         m_avm_address_o        => main_mdv_arb_avm_address,
         m_avm_writedata_o      => main_mdv_arb_avm_writedata,
         m_avm_byteenable_o     => main_mdv_arb_avm_byteenable,
         m_avm_burstcount_o     => main_mdv_arb_avm_burstcount,
         m_avm_readdata_i       => main_mdv_arb_avm_readdata,
         m_avm_readdatavalid_i  => main_mdv_arb_avm_readdatavalid,
         m_avm_waitrequest_i    => main_mdv_arb_avm_waitrequest
      ); -- i_avm_arbit_mdv

   -- Domain resets follow the framework's own rule (HyperRAM-for-
   -- Beginners.md S5.8 / AExp's own avm_fifo comment): the slave side
   -- resets from the core's own reset (main_reset_m2m_i), the master side
   -- from the framework's HyperRAM reset (hr_rst_i) - never cross them,
   -- or one side thinks a transaction is still in flight after the other
   -- has forgotten it.
   i_avm_fifo_mdv1 : entity work.avm_fifo
      generic map (
         G_WR_DEPTH     => 16,
         G_RD_DEPTH     => 16,
         G_FILL_SIZE    => 1,
         G_ADDRESS_SIZE => 32,
         G_DATA_SIZE    => 16
      )
      port map (
         s_clk_i               => main_clk,
         s_rst_i               => main_reset_m2m_i,
         s_avm_waitrequest_o   => main_mdv_arb_avm_waitrequest,
         s_avm_write_i         => main_mdv_arb_avm_write,
         s_avm_read_i          => main_mdv_arb_avm_read,
         s_avm_address_i       => main_mdv_arb_avm_address,
         s_avm_writedata_i     => main_mdv_arb_avm_writedata,
         s_avm_byteenable_i    => main_mdv_arb_avm_byteenable,
         s_avm_burstcount_i    => main_mdv_arb_avm_burstcount,
         s_avm_readdata_o      => main_mdv_arb_avm_readdata,
         s_avm_readdatavalid_o => main_mdv_arb_avm_readdatavalid,
         m_clk_i               => hr_clk_i,
         m_rst_i               => hr_rst_i,
         m_avm_waitrequest_i   => hr_core_waitrequest_i,
         m_avm_write_o         => hr_core_write_o,
         m_avm_read_o          => hr_core_read_o,
         m_avm_address_o       => hr_core_address_o,
         m_avm_writedata_o     => hr_core_writedata_o,
         m_avm_byteenable_o    => hr_core_byteenable_o,
         m_avm_burstcount_o    => hr_core_burstcount_o,
         m_avm_readdata_i      => hr_core_readdata_i,
         m_avm_readdatavalid_i => hr_core_readdatavalid_i
      ); -- i_avm_fifo_mdv1

   -- Tristate all expansion port drivers that we can directly control
   -- @TODO: As soon as we support modules that can act as busmaster, we need to become more flexible here
   cart_ctrl_oe_o       <= '0';
   cart_addr_oe_o       <= '0';
   cart_data_oe_o       <= '0';

   -- Due to a bug in the R5/R6 boards, the cartridge port needs to be enabled for joystick port 2 to work 
   cart_en_o            <= '1';

   cart_reset_oe_o      <= '0';
   cart_game_oe_o       <= '0';
   cart_exrom_oe_o      <= '0';
   cart_nmi_oe_o        <= '0';
   cart_irq_oe_o        <= '0';
   cart_roml_oe_o       <= '0';
   cart_romh_oe_o       <= '0';

   -- Default values for all signals
   cart_phi2_o          <= '0';
   cart_reset_o         <= '1';
   cart_dotclock_o      <= '0';
   cart_game_o          <= '1';
   cart_exrom_o         <= '1';
   cart_nmi_o           <= '1';
   cart_irq_o           <= '1';
   cart_roml_o          <= '0';
   cart_romh_o          <= '0';
   cart_ba_o            <= '0';
   cart_rw_o            <= '0';
   cart_io1_o           <= '0';
   cart_io2_o           <= '0';
   cart_a_o             <= (others => '0');
   cart_d_o             <= (others => '0');

   main_joy_1_up_n_o    <= '1';
   main_joy_1_down_n_o  <= '1';
   main_joy_1_left_n_o  <= '1';
   main_joy_1_right_n_o <= '1';
   main_joy_1_fire_n_o  <= '1';
   main_joy_2_up_n_o    <= '1';
   main_joy_2_down_n_o  <= '1';
   main_joy_2_left_n_o  <= '1';
   main_joy_2_right_n_o <= '1';
   main_joy_2_fire_n_o  <= '1';


   -- MMCME2_ADV clock generators:
   --   @TODO YOURCORE:       54 MHz
   clk_gen : entity work.clk
      port map (
         sys_clk_i         => clk_i,           -- expects 100 MHz
         main_clk_o        => main_clk,        -- CORE's 54 MHz clock
         main_rst_o        => main_rst         -- CORE's reset, synchronized
      ); -- clk_gen

   main_clk_o  <= main_clk;
   main_rst_o  <= main_rst;
   video_clk_o <= main_clk;
   video_rst_o <= main_rst;

   ---------------------------------------------------------------------------------------------
   -- main_clk (MiSTer core's clock)
   ---------------------------------------------------------------------------------------------

   -- MEGA65's power led: By default, it is on and glows green when the MEGA65 is powered on.
   -- We switch it to blue when a long reset is detected and as long as the user keeps pressing the preset button
   main_power_led_o     <= '1';
   main_power_led_col_o <= x"0000FF" when main_reset_m2m_i else x"00FF00";

   -- main.vhd contains the actual MiSTer core
   i_main : entity work.main
      generic map (
         G_VDNUM              => C_VDNUM
      )
      port map (
         clk_main_i           => main_clk,
         reset_soft_i         => main_reset_core_i,
         reset_hard_i         => main_reset_m2m_i,
         pause_i              => main_pause_core_i,

         clk_main_speed_i     => CORE_CLK_SPEED,

         -- Video output
         -- This is PAL 720x576 @ 50 Hz (pixel clock 27 MHz), but synchronized to main_clk (54 MHz).
         video_ce_o           => video_ce_o,
         video_ce_ovl_o       => video_ce_ovl_o,
         video_red_o          => video_red_o,
         video_green_o        => video_green_o,
         video_blue_o         => video_blue_o,
         video_vs_o           => video_vs_o,
         video_hs_o           => video_hs_o,
         video_hblank_o       => video_hblank_o,
         video_vblank_o       => video_vblank_o,

         -- audio output (pcm format, signed values)
         audio_left_o         => main_audio_left_o,
         audio_right_o        => main_audio_right_o,

         -- M2M Keyboard interface
         kb_key_num_i         => main_kb_key_num_i,
         kb_key_pressed_n_i   => main_kb_key_pressed_n_i,

         -- MEGA65 joysticks and paddles/mouse/potentiometers
         joy_1_up_n_i         => main_joy_1_up_n_i ,
         joy_1_down_n_i       => main_joy_1_down_n_i,
         joy_1_left_n_i       => main_joy_1_left_n_i,
         joy_1_right_n_i      => main_joy_1_right_n_i,
         joy_1_fire_n_i       => main_joy_1_fire_n_i,

         joy_2_up_n_i         => main_joy_2_up_n_i,
         joy_2_down_n_i       => main_joy_2_down_n_i,
         joy_2_left_n_i       => main_joy_2_left_n_i,
         joy_2_right_n_i      => main_joy_2_right_n_i,
         joy_2_fire_n_i       => main_joy_2_fire_n_i,

         pot1_x_i             => main_pot1_x_i,
         pot1_y_i             => main_pot1_y_i,
         pot2_x_i             => main_pot2_x_i,
         pot2_y_i             => main_pot2_y_i,

         -- QL4M65: system ROM (Minerva), see the "Dual Clocks" section below
         ql_rom_addr_o        => main_rom_addr,
         ql_rom_data_i        => main_rom_q_u & main_rom_q_l,

         -- QL4M65 (Milestone 2 phase A): mdv1 loader, QNICE-clock-domain
         -- side passed straight through - main.vhd runs exclusively in the
         -- core's clock domain (see its own header), same pattern as
         -- QL-SD's own (reverted) qnice_qlsd_* ports had.
         qnice_clk_i          => qnice_clk_i,
         qnice_rst_i          => qnice_rst_i,
         qnice_mdv1_addr_i    => qnice_dev_addr_i,
         qnice_mdv1_data_i    => qnice_dev_data_i,
         qnice_mdv1_ce_i      => qnice_mdv1_ce,
         qnice_mdv1_we_i      => qnice_mdv1_we,
         qnice_mdv1_wait_o    => qnice_mdv1_wait,

         -- QL4M65 (Milestone 2 phase B, etapa 2): read-back path (buffer
         -- bytes + dirty-sector bitmap), for the future SD flush.
         qnice_mdv1_data_o    => qnice_mdv1_data,

         -- QL4M65 (Milestone 2 phase A, M2011): raw QNICE-clock-domain
         -- "is the Shell currently loading mdv1" level - main.vhd
         -- synchronizes it into clk_main_i itself (see its own header).
         qnice_mdv1_loading_i => qnice_mdv1_loading,

         -- QL4M65 Milestone 2 paso 5, etapa 2: mdv2's own QNICE-side
         -- window, same pass-through pattern as mdv1's own above.
         qnice_mdv2_addr_i    => qnice_dev_addr_i,
         qnice_mdv2_data_i    => qnice_dev_data_i,
         qnice_mdv2_ce_i      => qnice_mdv2_ce,
         qnice_mdv2_we_i      => qnice_mdv2_we,
         qnice_mdv2_wait_o    => qnice_mdv2_wait,
         qnice_mdv2_data_o    => qnice_mdv2_data,
         qnice_mdv2_loading_i => qnice_mdv2_loading,

         -- QL4M65 (Milestone 2 phase A, M2008): microdrive activity LED
         drive_led_o          => main_mdv1_led,

         -- QL4M65 (Milestone 2 phase B, etapa 4, M2029): any mdv1 sector
         -- dirty (not yet flushed to SD)?
         mdv1_dirty_o         => main_mdv1_dirty,

         -- QL4M65 (Milestone 2 phase C, etapa B): mdv1's own Avalon-MM
         -- master, into i_avm_fifo_mdv1's slave side above.
         mdv1_avm_write_o         => main_mdv1_avm_write,
         mdv1_avm_read_o          => main_mdv1_avm_read,
         mdv1_avm_address_o       => main_mdv1_avm_address,
         mdv1_avm_writedata_o     => main_mdv1_avm_writedata,
         mdv1_avm_byteenable_o    => main_mdv1_avm_byteenable,
         mdv1_avm_burstcount_o    => main_mdv1_avm_burstcount,
         mdv1_avm_readdata_i      => main_mdv1_avm_readdata,
         mdv1_avm_readdatavalid_i => main_mdv1_avm_readdatavalid,
         mdv1_avm_waitrequest_i   => main_mdv1_avm_waitrequest,

         -- QL4M65 Milestone 2 paso 5, etapa 1
         mdv2_dirty_o             => main_mdv2_dirty,
         mdv2_avm_write_o         => main_mdv2_avm_write,
         mdv2_avm_read_o          => main_mdv2_avm_read,
         mdv2_avm_address_o       => main_mdv2_avm_address,
         mdv2_avm_writedata_o     => main_mdv2_avm_writedata,
         mdv2_avm_byteenable_o    => main_mdv2_avm_byteenable,
         mdv2_avm_burstcount_o    => main_mdv2_avm_burstcount,
         mdv2_avm_readdata_i      => main_mdv2_avm_readdata,
         mdv2_avm_readdatavalid_i => main_mdv2_avm_readdatavalid,
         mdv2_avm_waitrequest_i   => main_mdv2_avm_waitrequest,

         osm_control_i            => main_osm_control_i
      ); -- i_main

   ---------------------------------------------------------------------------------------------
   -- Audio and video settings (QNICE clock domain)
   ---------------------------------------------------------------------------------------------

   -- QL4M65: milestone 1's Options menu has no HDMI-resolution submenu and no
   -- CRT/zoom/audio toggles (see CONF_STR table in PORTING-PLAN.md - only ROM
   -- load and Close are real menu items), so every signal here is a fixed
   -- value rather than a qnice_osm_control_i bit lookup. C_VIDEO_HDMI_4_3_50
   -- (PAL 576p, 4:3) matches the QL's PAL/50Hz native timing, same family of
   -- choice as C64MEGA65's default.
   -- (M1003 temporarily forced this to C_VIDEO_HDMI_640_60 to test whether
   -- the OSD clipping tracked the HDMI output resolution - it didn't, ruling
   -- out ascal's own auto-detection and pointing at the OSM's own coordinate
   -- rescaling instead, fixed in video_overlay.vhd for M1004. Reverted here.)
   qnice_video_mode_o         <= C_VIDEO_HDMI_4_3_50;

   qnice_dvi_o                <= '0';                    -- 0=HDMI (with sound), 1=DVI (no sound)
   qnice_scandoubler_o        <= '0';                    -- no scandoubler
   qnice_audio_mute_o         <= '0';                    -- audio is not muted
   qnice_audio_filter_o       <= '0';                     -- raw audio, no filters
   qnice_zoom_crop_o          <= '0';                    -- no zoom/crop

   -- These two signals are often used as a pair (i.e. both '1'), particularly when
   -- you want to run old analog cathode ray tube monitors or TVs (via SCART)
   qnice_retro15kHz_o         <= '0';
   qnice_csync_o              <= '0';
   qnice_osm_cfg_scaling_o    <= (others => '1');

   -- ascal filters that are applied while processing the input
   -- 00 : Nearest Neighbour / 01 : Bilinear / 10 : Sharp Bilinear / 11 : Bicubic
   qnice_ascal_mode_o         <= "00";
   qnice_ascal_polyphase_o    <= '0';

   -- ascal triple-buffering
   -- @TODO: Right now, the M2M framework only supports OFF, so do not touch until the framework is upgraded
   qnice_ascal_triplebuf_o    <= '0';

   -- Flip joystick ports (i.e. the joystick in port 2 is used as joystick 1 and vice versa)
   qnice_flip_joyports_o      <= '0';

   ---------------------------------------------------------------------------------------------
   -- Core specific device handling (QNICE clock domain)
   ---------------------------------------------------------------------------------------------

   core_specific_devices : process(all)
   begin
      -- make sure that this is x"EEEE" by default and avoid a register here by having this default value
      qnice_dev_data_o     <= x"EEEE";
      qnice_dev_wait_o     <= '0';

      qnice_rom_we_u       <= '0';
      qnice_rom_we_l       <= '0';

      main_ce              <= '0';
      back_ce              <= '0';

      mdv1_ce              <= '0';
      qnice_mdv1_ce        <= '0';
      qnice_mdv1_we        <= '0';

      mdv2_ce              <= '0';
      qnice_mdv2_ce        <= '0';
      qnice_mdv2_we        <= '0';

      case qnice_dev_id_i is

         -- QL4M65: manual/auto loading of the Main ROM (48KB, $000000-
         -- $00BFFF) and Back ROM (16KB, $00C000-$00FFFF), reserved in
         -- globals.vhd as C_CRTROMS_MAN's/C_CRTROMS_AUTO's two entries.
         -- qnice_dev_addr_i is a byte address into each device's own linear
         -- space; bit 0 selects the byte lane (even=high byte, odd=low
         -- byte), same pattern as AExp's kick_rom_u/l. Both devices share
         -- the same physical ql_rom_u/l BRAM below (see rom_addr_b's mux) -
         -- window 0xFFFF on either one is the M2M CSR/size-check protocol
         -- (qnice_csr instances below), excluded here via *_csr_active so
         -- it never aliases onto a real ROM address.
         when C_DEV_QL_MAINROM =>
            main_ce <= qnice_dev_ce_i;
            if main_csr_active = '1' then
               qnice_dev_data_o <= main_csr_data;
               qnice_dev_wait_o <= main_csr_wait;
            else
               qnice_rom_we_u <= qnice_dev_ce_i and qnice_dev_we_i and not qnice_dev_addr_i(0);
               qnice_rom_we_l <= qnice_dev_ce_i and qnice_dev_we_i and     qnice_dev_addr_i(0);
               if qnice_dev_addr_i(0) = '0' then
                  qnice_dev_data_o <= x"00" & qnice_rom_q_u;
               else
                  qnice_dev_data_o <= x"00" & qnice_rom_q_l;
               end if;
            end if;

         when C_DEV_QL_BACKROM =>
            back_ce <= qnice_dev_ce_i;
            if back_csr_active = '1' then
               qnice_dev_data_o <= back_csr_data;
               qnice_dev_wait_o <= back_csr_wait;
            else
               qnice_rom_we_u <= qnice_dev_ce_i and qnice_dev_we_i and not qnice_dev_addr_i(0);
               qnice_rom_we_l <= qnice_dev_ce_i and qnice_dev_we_i and     qnice_dev_addr_i(0);
               if qnice_dev_addr_i(0) = '0' then
                  qnice_dev_data_o <= x"00" & qnice_rom_q_u;
               else
                  qnice_dev_data_o <= x"00" & qnice_rom_q_l;
               end if;
            end if;

         -- QL4M65 (Milestone 2 phase A): mdv1 microdrive image, manual load
         -- only (globals.vhd's C_CRTROMS_MAN). Window 0xFFFF is the same
         -- M2M CSR/size-check protocol as Main/Back ROM above; everywhere
         -- else, bytes go straight through to main.vhd's own loader
         -- (mdv1's buffer lives there, not in a local BRAM here) - the
         -- wait state comes back from main.vhd too, since a byte may still
         -- be crossing into the core clock domain.
         --
         -- QL4M65 (Milestone 2 phase B, etapa 2): reads now go through the
         -- same non-CSR branch too (buffer bytes, or the dirty-sector
         -- bitmap at C_MDV1_DIRTY_BASE - main.vhd itself decodes which one
         -- a given address means, see its own mdv1_reader_core comment).
         when C_DEV_QL_MDV1 =>
            mdv1_ce <= qnice_dev_ce_i;
            if mdv1_csr_active = '1' then
               qnice_dev_data_o <= mdv1_csr_data;
               qnice_dev_wait_o <= mdv1_csr_wait;
            else
               qnice_mdv1_ce    <= qnice_dev_ce_i;
               qnice_mdv1_we    <= qnice_dev_we_i;
               qnice_dev_data_o <= qnice_mdv1_data;
               qnice_dev_wait_o <= qnice_mdv1_wait;
            end if;

         -- QL4M65 Milestone 2 paso 5, etapa 2: mdv2, mismo esquema exacto
         -- que C_DEV_QL_MDV1 arriba - propia ventana CSR/tamano, propio
         -- device ID, mismo protocolo de "siempre respuesta" y mismo
         -- reparto CSR/no-CSR.
         when C_DEV_QL_MDV2 =>
            mdv2_ce <= qnice_dev_ce_i;
            if mdv2_csr_active = '1' then
               qnice_dev_data_o <= mdv2_csr_data;
               qnice_dev_wait_o <= mdv2_csr_wait;
            else
               qnice_mdv2_ce    <= qnice_dev_ce_i;
               qnice_mdv2_we    <= qnice_dev_we_i;
               qnice_dev_data_o <= qnice_mdv2_data;
               qnice_dev_wait_o <= qnice_mdv2_wait;
            end if;

         when others => null;
      end case;
   end process core_specific_devices;

   -- shared BRAM address bus: Back's device-local address gets offset by
   -- 48 KB so it lands in the upper half of the same ql_rom_u/l instances
   -- Main already addresses directly. Don't-care (never written/read) while
   -- either device's CSR window is active.
   rom_addr_b <= std_logic_vector(unsigned(qnice_dev_addr_i(15 downto 1)) + C_BACKROM_WORD_OFFS)
                    when back_ce = '1' else
                 qnice_dev_addr_i(15 downto 1);

   ---------------------------------------------------------------------------------------------
   -- QL4M65: Main/Back ROM CSR (window 0xFFFF) + size-check "parser" FSMs
   --
   -- HANDLE_CRTROM_M (M2M/rom/crts-and-roms.asm) busy-waits with NO timeout
   -- for whichever device it just loaded to answer READY/ERROR here - see
   -- the signal declarations above and DECISIONES.md for why this was
   -- missing entirely before (every manual ROM load hung QNICE solid).
   ---------------------------------------------------------------------------------------------

   i_main_csr : entity work.qnice_csr
      generic map (
         G_ERROR_STRINGS => C_ROM_ERROR_STRINGS
      )
      port map (
         qnice_clk_i          => qnice_clk_i,
         qnice_rst_i          => qnice_rst_i,
         qnice_addr_i         => qnice_dev_addr_i,
         qnice_data_i         => qnice_dev_data_i,
         qnice_ce_i           => main_ce,
         qnice_we_i           => qnice_dev_we_i,
         qnice_data_o         => main_csr_data,
         qnice_wait_o         => main_csr_wait,
         qnice_csr_o          => main_csr_active,
         qnice_req_status_o   => main_req_status,
         qnice_req_length_o   => main_req_length,
         qnice_resp_status_i  => main_resp_status,
         qnice_resp_error_i   => main_resp_error,
         qnice_resp_address_i => (others => '0')
      ); -- i_main_csr

   p_main_size_check : process (qnice_clk_i)
   begin
      if falling_edge(qnice_clk_i) then
         case main_val_state is
            when VS_IDLE =>
               if main_req_status = C_CSR_REQ_OK then
                  if unsigned(main_req_length) = C_MAINROM_BYTES then
                     main_resp_status <= C_CSR_RESP_READY;
                     main_resp_error  <= x"0";
                  else
                     main_resp_status <= C_CSR_RESP_ERROR;
                     main_resp_error  <= x"1";
                  end if;
                  main_val_state <= VS_DONE;
               else
                  main_resp_status <= C_CSR_RESP_IDLE;
                  main_resp_error  <= x"0";
               end if;

            when VS_DONE =>
               if main_req_status /= C_CSR_REQ_OK then
                  main_resp_status <= C_CSR_RESP_IDLE;
                  main_resp_error  <= x"0";
                  main_val_state   <= VS_IDLE;
               end if;
         end case;

         if qnice_rst_i = '1' then
            main_val_state   <= VS_IDLE;
            main_resp_status <= C_CSR_RESP_IDLE;
            main_resp_error  <= x"0";
         end if;
      end if;
   end process p_main_size_check;

   i_back_csr : entity work.qnice_csr
      generic map (
         G_ERROR_STRINGS => C_ROM_ERROR_STRINGS
      )
      port map (
         qnice_clk_i          => qnice_clk_i,
         qnice_rst_i          => qnice_rst_i,
         qnice_addr_i         => qnice_dev_addr_i,
         qnice_data_i         => qnice_dev_data_i,
         qnice_ce_i           => back_ce,
         qnice_we_i           => qnice_dev_we_i,
         qnice_data_o         => back_csr_data,
         qnice_wait_o         => back_csr_wait,
         qnice_csr_o          => back_csr_active,
         qnice_req_status_o   => back_req_status,
         qnice_req_length_o   => back_req_length,
         qnice_resp_status_i  => back_resp_status,
         qnice_resp_error_i   => back_resp_error,
         qnice_resp_address_i => (others => '0')
      ); -- i_back_csr

   p_back_size_check : process (qnice_clk_i)
   begin
      if falling_edge(qnice_clk_i) then
         case back_val_state is
            when VS_IDLE =>
               if back_req_status = C_CSR_REQ_OK then
                  if unsigned(back_req_length) = C_BACKROM_BYTES then
                     back_resp_status <= C_CSR_RESP_READY;
                     back_resp_error  <= x"0";
                  else
                     back_resp_status <= C_CSR_RESP_ERROR;
                     back_resp_error  <= x"1";
                  end if;
                  back_val_state <= VS_DONE;
               else
                  back_resp_status <= C_CSR_RESP_IDLE;
                  back_resp_error  <= x"0";
               end if;

            when VS_DONE =>
               if back_req_status /= C_CSR_REQ_OK then
                  back_resp_status <= C_CSR_RESP_IDLE;
                  back_resp_error  <= x"0";
                  back_val_state   <= VS_IDLE;
               end if;
         end case;

         if qnice_rst_i = '1' then
            back_val_state   <= VS_IDLE;
            back_resp_status <= C_CSR_RESP_IDLE;
            back_resp_error  <= x"0";
         end if;
      end if;
   end process p_back_size_check;

   i_mdv1_csr : entity work.qnice_csr
      generic map (
         G_ERROR_STRINGS => C_ROM_ERROR_STRINGS
      )
      port map (
         qnice_clk_i          => qnice_clk_i,
         qnice_rst_i          => qnice_rst_i,
         qnice_addr_i         => qnice_dev_addr_i,
         qnice_data_i         => qnice_dev_data_i,
         qnice_ce_i           => mdv1_ce,
         qnice_we_i           => qnice_dev_we_i,
         qnice_data_o         => mdv1_csr_data,
         qnice_wait_o         => mdv1_csr_wait,
         qnice_csr_o          => mdv1_csr_active,
         qnice_req_status_o   => mdv1_req_status,
         qnice_req_length_o   => mdv1_req_length,
         qnice_resp_status_i  => mdv1_resp_status,
         qnice_resp_error_i   => mdv1_resp_error,
         qnice_resp_address_i => (others => '0')
      ); -- i_mdv1_csr

   -- QL4M65 (Milestone 2 phase A, M2011): see main.vhd's own header comment
   -- on qnice_mdv1_loading_i for why this matters - mdv.v's `download`
   -- input needs to be held for the whole transfer, not just pulsed once.
   qnice_mdv1_loading <= '1' when mdv1_req_status = C_CSR_REQ_LDNG else '0';

   -- QL4M65 (Milestone 2 phase A): unlike Main/Back ROM's exact-size check,
   -- this is a RANGE check (<= C_MDV1_MAX_BYTES) - real .MDV images vary in
   -- length (confirmed against 9 real sample files, see globals.vhd).
   p_mdv1_size_check : process (qnice_clk_i)
   begin
      if falling_edge(qnice_clk_i) then
         case mdv1_val_state is
            when VS_IDLE =>
               if mdv1_req_status = C_CSR_REQ_OK then
                  if unsigned(mdv1_req_length) <= C_MDV1_MAX_BYTES then
                     mdv1_resp_status <= C_CSR_RESP_READY;
                     mdv1_resp_error  <= x"0";
                  else
                     mdv1_resp_status <= C_CSR_RESP_ERROR;
                     mdv1_resp_error  <= x"1";
                  end if;
                  mdv1_val_state <= VS_DONE;
               else
                  mdv1_resp_status <= C_CSR_RESP_IDLE;
                  mdv1_resp_error  <= x"0";
               end if;

            when VS_DONE =>
               if mdv1_req_status /= C_CSR_REQ_OK then
                  mdv1_resp_status <= C_CSR_RESP_IDLE;
                  mdv1_resp_error  <= x"0";
                  mdv1_val_state   <= VS_IDLE;
               end if;
         end case;

         if qnice_rst_i = '1' then
            mdv1_val_state   <= VS_IDLE;
            mdv1_resp_status <= C_CSR_RESP_IDLE;
            mdv1_resp_error  <= x"0";
         end if;
      end if;
   end process p_mdv1_size_check;

   -- QL4M65 Milestone 2 paso 5, etapa 2: mdv2's own CSR + size-check FSM,
   -- mismo patron exacto que i_mdv1_csr/p_mdv1_size_check arriba.
   i_mdv2_csr : entity work.qnice_csr
      generic map (
         G_ERROR_STRINGS => C_ROM_ERROR_STRINGS
      )
      port map (
         qnice_clk_i          => qnice_clk_i,
         qnice_rst_i          => qnice_rst_i,
         qnice_addr_i         => qnice_dev_addr_i,
         qnice_data_i         => qnice_dev_data_i,
         qnice_ce_i           => mdv2_ce,
         qnice_we_i           => qnice_dev_we_i,
         qnice_data_o         => mdv2_csr_data,
         qnice_wait_o         => mdv2_csr_wait,
         qnice_csr_o          => mdv2_csr_active,
         qnice_req_status_o   => mdv2_req_status,
         qnice_req_length_o   => mdv2_req_length,
         qnice_resp_status_i  => mdv2_resp_status,
         qnice_resp_error_i   => mdv2_resp_error,
         qnice_resp_address_i => (others => '0')
      ); -- i_mdv2_csr

   qnice_mdv2_loading <= '1' when mdv2_req_status = C_CSR_REQ_LDNG else '0';

   -- Same range check as mdv1's own (C_MDV1_MAX_BYTES - same .mdv format,
   -- same valid size range regardless of which unit it's loaded into).
   p_mdv2_size_check : process (qnice_clk_i)
   begin
      if falling_edge(qnice_clk_i) then
         case mdv2_val_state is
            when VS_IDLE =>
               if mdv2_req_status = C_CSR_REQ_OK then
                  if unsigned(mdv2_req_length) <= C_MDV1_MAX_BYTES then
                     mdv2_resp_status <= C_CSR_RESP_READY;
                     mdv2_resp_error  <= x"0";
                  else
                     mdv2_resp_status <= C_CSR_RESP_ERROR;
                     mdv2_resp_error  <= x"1";
                  end if;
                  mdv2_val_state <= VS_DONE;
               else
                  mdv2_resp_status <= C_CSR_RESP_IDLE;
                  mdv2_resp_error  <= x"0";
               end if;

            when VS_DONE =>
               if mdv2_req_status /= C_CSR_REQ_OK then
                  mdv2_resp_status <= C_CSR_RESP_IDLE;
                  mdv2_resp_error  <= x"0";
                  mdv2_val_state   <= VS_IDLE;
               end if;
         end case;

         if qnice_rst_i = '1' then
            mdv2_val_state   <= VS_IDLE;
            mdv2_resp_status <= C_CSR_RESP_IDLE;
            mdv2_resp_error  <= x"0";
         end if;
      end if;
   end process p_mdv2_size_check;

   ---------------------------------------------------------------------------------------------
   -- Dual Clocks
   ---------------------------------------------------------------------------------------------

   -- QL4M65: system ROM (Main 48K + Back 16K = 64KB = 32K words x 16 bit
   -- total, matching the original core's "dpram #(15) ql_rom" in QL.sv -
   -- QL.sv itself isn't ported, but the RAM shape is the same). Read-only
   -- from the core side (wren_a fixed '0'); written only by the QNICE Shell
   -- during manual/auto loads of either slot (config.vhd/globals.vhd) - see
   -- rom_addr_b above for how both devices share this single instance.
   -- Split into two 8-bit lanes, same pattern as AExp's kick_rom_u/l, since
   -- the QNICE ROM loader writes one byte at a time.
   ql_rom_u : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH => 15,
         DATA_WIDTH => 8,
         FALLING_B  => true
      )
      port map (
         clock_a   => main_clk,
         address_a => main_rom_addr,
         data_a    => (others => '0'),
         wren_a    => '0',
         q_a       => main_rom_q_u,

         clock_b   => qnice_clk_i,
         address_b => rom_addr_b,
         data_b    => qnice_dev_data_i(7 downto 0),
         wren_b    => qnice_rom_we_u,
         q_b       => qnice_rom_q_u
      ); -- ql_rom_u

   ql_rom_l : entity work.dualport_2clk_ram
      generic map (
         ADDR_WIDTH => 15,
         DATA_WIDTH => 8,
         FALLING_B  => true
      )
      port map (
         clock_a   => main_clk,
         address_a => main_rom_addr,
         data_a    => (others => '0'),
         wren_a    => '0',
         q_a       => main_rom_q_l,

         clock_b   => qnice_clk_i,
         address_b => rom_addr_b,
         data_b    => qnice_dev_data_i(7 downto 0),
         wren_b    => qnice_rom_we_l,
         q_b       => qnice_rom_q_l
      ); -- ql_rom_l

   ---------------------------------------------------------------------------------------
   -- Virtual drive handler
   --
   -- QL4M65 (Milestone 2 phase A, M2008): microdrive activity - main_mdv1_led
   -- comes straight from zx8302.v's own "led" output (lit whenever any
   -- drive is selected, mdv_sel[0], same as real QL hardware) via main.vhd's
   -- drive_led_o. QL-SD's own vdrives activity (Milestone 4, parked) would
   -- OR into this same signal if/when that's revisited.
   --
   -- QL4M65 (Milestone 2 phase B, etapa 4, M2029): while any mdv1 sector is
   -- dirty (MDV1_FLUSH_STEP hasn't finished writing it back to the SD card
   -- yet - m2m-rom.asm), force the LED lit and recolor it blue instead of
   -- red - "don't power off yet". Same pattern C64MEGA65's vdrives
   -- (main.vhd's own cache_dirty -> amber) and AExp's ADF write-back
   -- (main_adf_dirty -> yellow) already use; blue chosen here simply to
   -- stay visually distinct from both. main_mdv1_dirty is combinational
   -- straight off main.vhd's own mdv1_dirty bitmap (clk_main_i already) -
   -- no new CDC needed. See DECISIONES.md's M2029 section.
   ---------------------------------------------------------------------------------------

   -- QL4M65 Milestone 2 paso 5, etapa 1: main_mdv1_led already reflects
   -- ANY drive selected, not just drive 1 - it's zx8302.v's own `led`
   -- output (now |mdv_sel[1:0], see that file's own comment), the name is
   -- just a leftover from when mdv1 was the only drive. The dirty/blue
   -- condition needs both bitmaps ORed explicitly, since each drive
   -- tracks its own independently (main.vhd's p_dirty/p_dirty2).
   main_drive_led_o     <= main_mdv1_led or main_mdv1_dirty or main_mdv2_dirty;
   main_drive_led_col_o <= x"0000FF" when (main_mdv1_dirty = '1' or main_mdv2_dirty = '1') else x"FF0000";  -- 24-bit RGB

end architecture synthesis;

