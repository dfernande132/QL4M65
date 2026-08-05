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
      qnice_mdv1_addr_i       : in  std_logic_vector(27 downto 0);
      qnice_mdv1_data_i       : in  std_logic_vector(15 downto 0);
      qnice_mdv1_ce_i         : in  std_logic;
      qnice_mdv1_we_i         : in  std_logic;
      qnice_mdv1_wait_o       : out std_logic;

      -- QL4M65 (Milestone 2 phase A, M2008): microdrive activity LED - real
      -- QL hardware lights it whenever a drive is selected (zx8302.v's own
      -- "led" output, sel[0] of the mdv_sel shift register); previously
      -- computed and discarded (led => open).
      drive_led_o             : out std_logic
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

-- Address decode (milestone 1 scope only: ROM + internal I/O + 128k RAM -
-- no GoldCard, no QL-SD, no microdrive, no extended RAM configs)
signal ql_io        : std_logic;  -- $018000-$01BFFF: ZX8301/ZX8302 internal I/O
signal cpu_rom      : std_logic;  -- $000000-$00FFFF: system ROM (Minerva)
signal cpu_ram      : std_logic;  -- $020000-$03FFFF: 128k main RAM
signal cpu_vram_wr  : std_logic;  -- $020000-$02FFFF: lower half also mirrors into VRAM

signal ram_delay_dtack : std_logic;
signal cpu_dtack       : std_logic;

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

-- mdv1's own image-load port (core clock domain - mdv.v itself ties both
-- of its internal dpram's clocks to its single clk input, see the design
-- doc's A.2 finding)
signal mdv1_dl_addr   : std_logic_vector(16 downto 0);
signal mdv1_dl_data   : std_logic_vector(15 downto 0);
signal mdv1_download  : std_logic;
signal mdv1_dl_wr     : std_logic;

-- QNICE-clock-domain byte-pair accumulator (mdv1_ld_word_addr/data feed
-- xpm_cdc_handshake's src_in once a full 16-bit word is assembled - see
-- the design doc: mdv.v's image format is big-endian at the byte level,
-- first file byte -> data(15 downto 8))
signal mdv1_ld_byte0       : std_logic_vector(7 downto 0);
signal mdv1_ld_word_addr   : std_logic_vector(16 downto 0);
signal mdv1_ld_word_data   : std_logic_vector(15 downto 0);
signal mdv1_ld_send        : std_logic := '0';  -- level-held (see mdv1_loader_qnice), needs a defined power-on value
signal mdv1_ld_busy        : std_logic := '0';  -- '1' for the whole handshake (send asserted through rcv dropping again) - drives qnice_mdv1_wait_o

-- xpm_cdc_handshake's own src/dest signals (33 bits: 17-bit word address + 16-bit word data)
signal mdv1_cdc_src_in    : std_logic_vector(32 downto 0);
signal mdv1_cdc_src_rcv   : std_logic;
signal mdv1_cdc_dest_req  : std_logic;
signal mdv1_cdc_dest_ack  : std_logic := '0';  -- level-held (see mdv1_loader_core), needs a defined power-on value
signal mdv1_cdc_dest_out  : std_logic_vector(32 downto 0);

-- core-clock-domain loader FSM (drives mdv1_dl_addr/dl_data/dl_wr/download
-- from mdv1_cdc_dest_out once xpm_cdc_handshake delivers a word)
type t_mdv1_ld_state is (LD_IDLE, LD_WAIT_REQ_LOW);
signal mdv1_ld_state : t_mdv1_ld_state := LD_IDLE;

---------------------------------------------------------------------------
-- QL4M65 TEMPORARY DEBUG AID (M2007): on-screen mdv1 status readout, see
-- the overlay logic at the end of this architecture.
---------------------------------------------------------------------------
signal dbg_h_cnt           : std_logic_vector(9 downto 0);
signal dbg_v_cnt           : std_logic_vector(9 downto 0);
signal dbg_gap_irq         : std_logic;
signal dbg_mdv_present     : std_logic;
signal dbg_mdv_loaded      : std_logic;
signal dbg_box_active      : std_logic;
signal dbg_box_idx         : integer;
signal dbg_box_lit         : std_logic;
signal dbg_sel             : std_logic;
signal dbg_gap_live        : std_logic;
signal dbg_gap_irq_sticky  : std_logic := '0';
signal dbg_rx_ready_sticky : std_logic := '0';
signal dbg_vs_prev         : std_logic := '0';
signal dbg_vs_count        : natural range 0 to 63 := 0;

-- QL4M65 TEMPORARY DEBUG AID (M2010): 7th box - is mdv.v's own read
-- pointer (mem_addr) actually advancing, or frozen? Lit green whenever
-- mem_addr has changed at all within the last ~250ms, cleared otherwise -
-- a short window (vs. the ~1s one used for GAP_IRQ/RXRDY) so a genuine
-- freeze shows up quickly instead of being masked by the longer window.
signal dbg_mem_addr        : std_logic_vector(16 downto 0);
signal dbg_mem_addr_prev   : std_logic_vector(16 downto 0) := (others => '0');
signal dbg_mem_addr_moving : std_logic := '0';
signal dbg_vs_count2       : natural range 0 to 63 := 0;

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
-- Milestone 1 fixes the CPU to native QL speed (fract_bus = FRACT_BUS_QL);
-- milestone 2 will need to multiplex fract_bus between
-- QL/16MHz/24MHz/Full based on the (not yet existing) speed menu option -
-- the accumulator structure below doesn't change, only fract_bus's source
-- would.
---------------------------------------------------------------------------

constant FRACT_BUS_QL : unsigned(16 downto 0) := to_unsigned(11702, 17); -- 84MHz*11702/65536 = 14.999MHz (QL native)
constant FRACT_SD     : unsigned(16 downto 0) := to_unsigned(19505, 17); -- ~25MHz effective SD-card SPI clock
constant FRACT_11M    : unsigned(16 downto 0) := to_unsigned(8582, 17);  -- 10.999MHz IPC clock
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
         v_bus_sum := ('0' & cnt_bus) + FRACT_BUS_QL;
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

   ---------------------------------------------------------------------------
   -- QL4M65: address decode (milestone 1 scope - see PORTING-PLAN.md
   -- section 4/CONF_STR table: fixed 128k RAM, no GoldCard/QL-SD/microdrive)
   ---------------------------------------------------------------------------

   cpu_addr <= (cpu_addr16 & ((not cpu_uds) and cpu_lds)) and x"03FFFF";

   cpu_rd <= cpu_as and cpu_rw and (cpu_uds or cpu_lds);
   cpu_wr <= cpu_as and (not cpu_rw) and (cpu_uds or cpu_lds);
   cpu_io <= cpu_rd or cpu_wr;

   ql_io       <= '1' when unsigned(cpu_addr) >= x"018000" and unsigned(cpu_addr) <= x"01BFFF" else '0';
   cpu_rom     <= '1' when unsigned(cpu_addr) <= x"00FFFF" else '0';
   cpu_ram     <= '1' when unsigned(cpu_addr) >= x"020000" and unsigned(cpu_addr) <= x"03FFFF" else '0';
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
   -- no extra RAM-controller dtack needed since main RAM is BRAM here, not
   -- SDRAM (see DECISIONES.md: BRAM now, HyperRAM later)
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
   -- QL4M65: memory - main RAM (128k, BRAM for now) and VRAM (64k)
   --
   -- Both use the M2M framework's dualport_2clk_ram_byteenable; only one
   -- port is actually needed for main RAM (only the CPU touches it), the
   -- other side is tied off, same pattern as AExp's chip_ram_u/l. VRAM
   -- genuinely needs both ports (CPU writes, ZX8301 reads) - see
   -- DECISIONES.md Anexo A for why the CPU's own reads of the VRAM address
   -- range still come from main RAM, not from this VRAM instance (VRAM
   -- mirrors CPU writes for the video controller's exclusive use).
   ---------------------------------------------------------------------------

   i_main_ram : entity work.dualport_2clk_ram_byteenable
      generic map (
         G_ADDR_WIDTH => 16,
         G_DATA_WIDTH => 16
      )
      port map (
         a_clk_i        => clk_main_i,
         a_address_i    => cpu_addr(16 downto 1),
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
         enable          => '1',  -- QL-native speed fixed for milestone 1
         ce_bus_p        => ce_bus_p,
         VBlank          => zx_vblank,
         cpu_uds         => cpu_uds,
         cpu_lds         => cpu_lds,
         cpu_rw          => cpu_rw,
         cpu_rom         => cpu_rom,
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
         VBlank  => zx_vblank,

         -- QL4M65 TEMPORARY DEBUG AID (M2007, see mdv1 status overlay below)
         h_cnt_o => dbg_h_cnt,
         v_cnt_o => dbg_v_cnt
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
         reset_mdv     => reset,

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

         -- QL4M65 TEMPORARY DEBUG AID (M2007, see mdv1 status overlay below)
         gap_irq_o        => dbg_gap_irq,
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

   audio_left_o  <= to_signed(16#7FFF#, 16) when audio_bit = '1' else to_signed(0, 16);
   audio_right_o <= to_signed(16#7FFF#, 16) when audio_bit = '1' else to_signed(0, 16);

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
   -- QL4M65 (Milestone 2 phase A): microdrive 1 image loader.
   --
   -- QNICE-clock-domain side: accumulates two incoming bytes (mdv.v's image
   -- format is big-endian at the byte level - the first file byte becomes
   -- the high byte of the word, see rtl/mdv.v:88 and
   -- .research/microdrive-read-design.md) into one 16-bit word, then hands
   -- it to xpm_cdc_handshake. qnice_mdv1_wait_o stalls the QNICE bus cycle
   -- combinationally the instant a word-completing (odd-address) write is
   -- seen, held through mdv1_ld_busy until the core side acknowledges - the
   -- QNICE Shell's own generic byte-loading loop (shell.asm's LOAD_IMAGE)
   -- needs no special-casing, same as Main/Back ROM's own manual load.
   --
   -- IMPORTANT (found 2026-08-04, after M2004 hung on hardware mid-load):
   -- xpm_cdc_handshake's src_send/dest_ack are LEVEL signals that must be
   -- asserted and HELD until the other side's src_rcv/dest_req responds -
   -- NOT one-cycle pulses. Confirmed by reading the actual primitive
   -- source (C:\Xilinx\Vivado\2022.2\data\ip\xpm\xpm_cdc\hdl\xpm_cdc.sv,
   -- module xpm_cdc_handshake) rather than assuming - its own simulation
   -- assertions spell out the exact 4-phase protocol: src_send stays high
   -- until src_rcv='1', then drops, then a NEW send may only start once
   -- src_rcv has also dropped back to '0'. The first version of this loader
   -- pulsed both src_send and dest_ack for a single cycle, which let
   -- xpm_cdc_handshake's internal synchronizers drop the request before
   -- the other side ever safely captured it - a real handshake deadlock
   -- (not a timing/setup issue), matching the hang seen in hardware.
   --
   -- SECOND BUG (found 2026-08-04, M2005 still hung identically): wait_o
   -- must depend ONLY on registered state (mdv1_ld_busy), never on the raw
   -- live qnice_mdv1_ce_i/we_i/addr_i inputs. The QNICE CPU (qnice_cpu.vhd,
   -- state cs_exepost_store_dst_indirect) holds ce/we/addr asserted for as
   -- long as it sees WAIT_FOR_DATA='1', and only retracts them the cycle
   -- AFTER it samples wait='0'. The previous formula OR'd the live ce/we/
   -- addr(0) straight into wait_o, so the instant mdv1_ld_busy dropped back
   -- to '0' (transaction genuinely done), that same live term (still '1',
   -- since the CPU hadn't yet had a chance to react) kept wait_o at '1' -
   -- the CPU never saw a low cycle to retract on, so it held forever and
   -- wait_o never had a reason to drop: a permanent deadlock on every single
   -- odd-byte write, i.e. on the very first word of any .mdv load. This is
   -- also why M2005's CDC-protocol fix alone did not change the symptom -
   -- it fixed a real but different bug; this one is what actually blocked
   -- the loader. Reference: M2M/vhdl/qnice2hyperram.vhd (the mechanism that
   -- successfully loads .win files) computes its wait_o purely from its own
   -- registered m_avm_write_o/m_avm_read_o/reading, never from the raw
   -- incoming s_qnice_cs_i/s_qnice_write_i - same fix, same idiom, applied
   -- here.
   ---------------------------------------------------------------------------

   qnice_mdv1_wait_o <= mdv1_ld_busy;

   mdv1_loader_qnice : process (qnice_clk_i)
   begin
      if rising_edge(qnice_clk_i) then
         if mdv1_ld_busy = '0' then
            if qnice_mdv1_ce_i = '1' and qnice_mdv1_we_i = '1' then
               if qnice_mdv1_addr_i(0) = '0' then
                  -- even address: first byte of the pair, just latch it
                  mdv1_ld_byte0 <= qnice_mdv1_data_i(7 downto 0);
               else
                  -- odd address: second byte - assemble the word and start
                  -- the handshake (src_send asserted and held, see above)
                  mdv1_ld_word_addr <= qnice_mdv1_addr_i(17 downto 1);
                  mdv1_ld_word_data <= mdv1_ld_byte0 & qnice_mdv1_data_i(7 downto 0);
                  mdv1_ld_send      <= '1';
                  mdv1_ld_busy      <= '1';
               end if;
            end if;
         elsif mdv1_ld_send = '1' then
            -- handshake in flight: drop send once the core side confirms
            -- receipt (src_rcv='1') - do NOT drop it any earlier
            if mdv1_cdc_src_rcv = '1' then
               mdv1_ld_send <= '0';
            end if;
         else
            -- send already dropped: wait for src_rcv to also drop before
            -- allowing the next byte-pair's handshake to start
            if mdv1_cdc_src_rcv = '0' then
               mdv1_ld_busy <= '0';
            end if;
         end if;
      end if;
   end process mdv1_loader_qnice;

   mdv1_cdc_src_in <= mdv1_ld_word_addr & mdv1_ld_word_data;

   i_mdv1_cdc : xpm_cdc_handshake
      generic map (
         DEST_EXT_HSK => 1,
         WIDTH        => 33
      )
      port map (
         src_clk  => qnice_clk_i,
         src_in   => mdv1_cdc_src_in,
         src_send => mdv1_ld_send,
         src_rcv  => mdv1_cdc_src_rcv,

         dest_clk => clk_main_i,
         dest_req => mdv1_cdc_dest_req,
         dest_ack => mdv1_cdc_dest_ack,
         dest_out => mdv1_cdc_dest_out
      ); -- i_mdv1_cdc

   -- Core-clock-domain side: on dest_req, drive mdv1's own dl_addr/dl_data
   -- for one cycle with dl_wr asserted (pulsing download too, for exactly
   -- one cycle, when the word address is 0 - see mdv.v:75-117 and the
   -- design doc's A.2: download is a one-shot reset of mdv.v's own
   -- mem_addr/gap state, not something to hold for the whole transfer).
   -- dest_ack itself must be asserted and HELD until dest_req drops back to
   -- '0' (see the loader's own header comment above for why - xpm_cdc_
   -- handshake's documented 4-phase protocol, not a one-cycle pulse).
   mdv1_loader_core : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         mdv1_dl_wr    <= '0';
         mdv1_download <= '0';

         case mdv1_ld_state is
            when LD_IDLE =>
               if mdv1_cdc_dest_req = '1' then
                  mdv1_dl_addr <= mdv1_cdc_dest_out(32 downto 16);
                  mdv1_dl_data <= mdv1_cdc_dest_out(15 downto 0);
                  mdv1_dl_wr   <= '1';
                  if unsigned(mdv1_cdc_dest_out(32 downto 16)) = 0 then
                     mdv1_download <= '1';
                  end if;
                  mdv1_cdc_dest_ack <= '1';
                  mdv1_ld_state     <= LD_WAIT_REQ_LOW;
               end if;

            when LD_WAIT_REQ_LOW =>
               if mdv1_cdc_dest_req = '0' then
                  mdv1_cdc_dest_ack <= '0';
                  mdv1_ld_state     <= LD_IDLE;
               end if;
         end case;
      end if;
   end process mdv1_loader_core;

   -- rtl/mdv.v, unmodified, instantiated as-is (mixed-language Vivado
   -- project). Its own internal "dpram #(17,88000) vram" instance resolves
   -- to CORE/vhdl/mdv_dpram.vhd (Vivado-clean, BRAM-backed for phase A -
   -- see that file's own header and .research/microdrive-read-design.md).
   i_mdv1 : entity work.mdv
      port map (
         clk      => clk_main_i,
         ce       => ce_bus_p,  -- native QL speed - see M2009 revert note above
         reset    => reset,

         reverse  => '0',

         sel      => mdv_sel(0),

         gap       => mdv1_gap,
         tx_empty  => mdv1_tx_empty,
         rx_ready  => mdv1_rx_ready,
         dout      => mdv1_byte,

         download  => mdv1_download,
         dl_addr   => mdv1_dl_addr,
         dl_data   => mdv1_dl_data,
         dl_wr     => mdv1_dl_wr,

         -- QL4M65 TEMPORARY DEBUG AID (M2007/M2010, see mdv1 status overlay below)
         mdv_present_o => dbg_mdv_present,
         mdv_loaded_o  => dbg_mdv_loaded,
         mem_addr_o    => dbg_mem_addr
      ); -- i_mdv1

   ---------------------------------------------------------------------------
   -- QL4M65 TEMPORARY DEBUG AID (M2007): on-screen mdv1 status readout.
   --
   -- Investigating: DIR mdv1_ hangs/misreads intermittently (not tied
   -- cleanly to reset history - M2009 confirmed it's not the mdv1 speed
   -- experiment either) once a real .mdv is loaded and drive 1 is
   -- selected - loading itself completes fine (M2006 fixed that hang).
   -- Seven small boxes, top-left corner, left to right: SEL / LOADED /
   -- PRESENT / GAP / GAP_IRQ / RXRDY / MOVING. Green = '1', red = '0'.
   -- SEL/LOADED/PRESENT/GAP are shown live (level signals); GAP_IRQ/RXRDY
   -- are pulses, shown "sticky" (latched on any '1' seen, cleared roughly
   -- once a second) - same idiom as M1020's sticky debug flags, needed
   -- because a live pulse this narrow would never be caught by eye. MOVING
   -- (M2010) is a shorter-window (~250ms) sticky on mdv.v's own mem_addr
   -- changing at all - lets us see directly whether the read pointer is
   -- genuinely frozen at the moment of a hang, vs. still advancing while
   -- serving wrong data.
   --
   -- Remove this whole block (signals, i_zx8301's h_cnt_o/v_cnt_o,
   -- i_zx8302's gap_irq_o, mdv.v's mdv_present_o/mdv_loaded_o/mem_addr_o,
   -- the video_red/green/blue_o override) once diagnosed - see
   -- doc/m2m/exceptions.md.
   ---------------------------------------------------------------------------

   dbg_box_active <= '1' when unsigned(dbg_v_cnt) >= 8 and unsigned(dbg_v_cnt) < 24 and
                              unsigned(dbg_h_cnt) >= 8 and unsigned(dbg_h_cnt) < 8 + 7 * 20
                     else '0';

   dbg_box_idx <= (to_integer(unsigned(dbg_h_cnt)) - 8) / 20;
   dbg_box_lit <= '0' when (to_integer(unsigned(dbg_h_cnt)) - 8) mod 20 >= 16 else  -- 4px gap between boxes
                  dbg_sel        when dbg_box_idx = 0 else
                  dbg_mdv_loaded when dbg_box_idx = 1 else
                  dbg_mdv_present when dbg_box_idx = 2 else
                  dbg_gap_live   when dbg_box_idx = 3 else
                  dbg_gap_irq_sticky when dbg_box_idx = 4 else
                  dbg_rx_ready_sticky when dbg_box_idx = 5 else
                  dbg_mem_addr_moving;

   dbg_sel      <= mdv_sel(0);
   dbg_gap_live <= mdv1_gap;

   dbg_sticky : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         if reset = '1' then
            dbg_vs_prev  <= '0';
            dbg_vs_count <= 0;
            dbg_vs_count2 <= 0;
            dbg_gap_irq_sticky   <= '0';
            dbg_rx_ready_sticky  <= '0';
            dbg_mem_addr_prev    <= (others => '0');
            dbg_mem_addr_moving  <= '0';
         else
            if mdv1_rx_ready = '1' then
               dbg_rx_ready_sticky <= '1';
            end if;
            if dbg_gap_irq = '1' then
               dbg_gap_irq_sticky <= '1';
            end if;
            if dbg_mem_addr /= dbg_mem_addr_prev then
               dbg_mem_addr_moving <= '1';
               dbg_mem_addr_prev   <= dbg_mem_addr;
            end if;

            dbg_vs_prev <= zx_vs;
            if dbg_vs_prev = '0' and zx_vs = '1' then  -- vsync rising edge
               if dbg_vs_count = 49 then                -- ~1s @ 50Hz PAL vsync
                  dbg_vs_count        <= 0;
                  dbg_gap_irq_sticky  <= '0';
                  dbg_rx_ready_sticky <= '0';
               else
                  dbg_vs_count <= dbg_vs_count + 1;
               end if;

               if dbg_vs_count2 = 11 then                -- ~250ms @ 50Hz PAL
                  dbg_vs_count2       <= 0;
                  dbg_mem_addr_moving <= '0';
               else
                  dbg_vs_count2 <= dbg_vs_count2 + 1;
               end if;
            end if;
         end if;
      end if;
   end process dbg_sticky;

   video_red_o    <= x"00" when dbg_box_active = '1' and dbg_box_lit = '1' else
                      x"FF" when dbg_box_active = '1' else
                      (others => video_r);
   video_green_o  <= x"FF" when dbg_box_active = '1' and dbg_box_lit = '1' else
                      x"00" when dbg_box_active = '1' else
                      (others => video_g);
   video_blue_o   <= x"00" when dbg_box_active = '1' else
                      (others => video_b);

end architecture synthesis;

