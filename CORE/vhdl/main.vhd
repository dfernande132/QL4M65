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

      -- QL4M65: system ROM (Minerva), 32K x 16-bit words, loaded by the
      -- QNICE Shell via mega65.vhd's ql_rom_u/l (C_DEV_QL_MINERVA).
      ql_rom_addr_o           : out std_logic_vector(14 downto 0);
      ql_rom_data_i           : in  std_logic_vector(15 downto 0)
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
-- QL4M65 TEMPORARY DEBUG AID (M1018): the M1016 cpu_addr readout (10
-- digits total with M1018's keyboard digits added) pushed timing into a
-- genuine hold violation (WHS=-0.114ns on the M1018 build) - not just a
-- shrinking margin like previous iterations. cpu_addr already answered its
-- question (M1017 fixed the real stall; Minerva reaches the F1/F2 screen
-- now), so it's dropped here to claw back margin. Down to 4 digits: what
-- keyboard.vhd is actually seeing on the comdata/comctrl link - is Minerva
-- sending recognisable IPC commands at all (8="read keyboard", 9="keyrow"),
-- and how many since reset? Remove this whole block (signals, i_dbg_font
-- instance, the h_cnt_o/v_cnt_o ports on zx8301, the
-- video_red/green/blue_o override) once the keyboard issue is diagnosed -
-- see doc/m2m/exceptions.md.
---------------------------------------------------------------------------

constant DBG_FONT_FILE : string  := "../font/Anikki-16x16-m2m.rom";
constant DBG_DX        : natural := 8;
constant DBG_DY        : natural := 8;
constant DBG_DIGITS    : natural := 4;

signal dbg_h_cnt      : std_logic_vector(9 downto 0);
signal dbg_v_cnt      : std_logic_vector(9 downto 0);
signal dbg_active     : std_logic;
signal dbg_digit_idx  : integer;
signal dbg_x_in_char  : integer;
signal dbg_y_in_char  : integer;
signal dbg_nibble     : std_logic_vector(3 downto 0);
signal dbg_ascii      : std_logic_vector(7 downto 0);
signal dbg_font_addr  : std_logic_vector(11 downto 0);
signal dbg_font_data  : std_logic_vector(15 downto 0);
signal dbg_pixel_on   : std_logic;

signal dbg_vs_prev      : std_logic := '0';
signal dbg_vs_count     : natural range 0 to 63 := 0;

-- digits 0-3: last_cmd(1) & seen_flags(1, bit0=cmd8 bit1=cmd9 bit2=cmd6/7
-- bit3=other, all sticky since reset) & matrix_seen(2, one bit per
-- ql_matrix row that's ever gone non-idle, sticky since reset), latched
-- once per second (~50 vsync pulses).
signal dbg_kbd_last_cmd    : std_logic_vector(3 downto 0);
signal dbg_kbd_seen_flags  : std_logic_vector(3 downto 0);
signal dbg_kbd_matrix_seen : std_logic_vector(7 downto 0);
signal dbg_kbd_latched     : std_logic_vector(15 downto 0) := (others => '0');

---------------------------------------------------------------------------
-- QL4M65: ZX8302 (internal I/O) signals
---------------------------------------------------------------------------

signal zx8302_sel   : std_logic;
signal zx8302_addr  : std_logic_vector(1 downto 0);
signal zx8302_dout  : std_logic_vector(15 downto 0);
signal audio_bit    : std_logic;                      -- ZX8302's single-bit beeper output

-- IPC link to keyboard.vhd (replaces the embedded 8049 emulation - see
-- rtl/zx8302.v's header note and CoreQL/doc/m2m/exceptions.md)
signal ipc_comctrl       : std_logic;                    -- keyboard.vhd -> zx8302
signal ipc_comdata_zx2kb : std_logic;                    -- zx8302's own outgoing bit -> keyboard.vhd
signal ipc_comdata_kb2zx : std_logic;                    -- keyboard.vhd's own outgoing bit -> zx8302
signal ipc_ipl           : std_logic_vector(1 downto 0);  -- keyboard.vhd -> zx8302
signal ipc_audio         : std_logic;                     -- keyboard.vhd -> zx8302

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
      variable v_bus_sum : unsigned(16 downto 0);
      variable v_sd_sum  : unsigned(16 downto 0);
      variable v_11m_sum : unsigned(16 downto 0);
   begin
      if falling_edge(clk_main_i) then
         if reset_soft_i = '1' or reset_hard_i = '1' then
            bus_pol <= '0';
            cnt_bus <= (others => '0');
            div131k <= (others => '0');
            divvid  <= (others => '0');
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

         -- QL4M65 TEMPORARY DEBUG AID (M1016, see signal declarations above)
         h_cnt_o => dbg_h_cnt,
         v_cnt_o => dbg_v_cnt
      ); -- i_zx8301

   ---------------------------------------------------------------------------
   -- QL4M65 TEMPORARY DEBUG AID (M1018): on-screen hex readout of the
   -- keyboard IPC command info (see signal declarations above)
   ---------------------------------------------------------------------------

   dbg_active    <= '1' when unsigned(dbg_v_cnt) >= DBG_DY and unsigned(dbg_v_cnt) < DBG_DY + 16 and
                             unsigned(dbg_h_cnt) >= DBG_DX and unsigned(dbg_h_cnt) < DBG_DX + DBG_DIGITS * 16
                     else '0';

   dbg_digit_idx <= (to_integer(unsigned(dbg_h_cnt)) - DBG_DX) / 16;
   dbg_x_in_char <= (to_integer(unsigned(dbg_h_cnt)) - DBG_DX) mod 16;
   dbg_y_in_char <= to_integer(unsigned(dbg_v_cnt)) - DBG_DY;

   dbg_latch : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         if reset = '1' then
            null;
         else
            dbg_vs_prev <= zx_vs;
            if dbg_vs_prev = '0' and zx_vs = '1' then  -- vsync rising edge
               if dbg_vs_count = 49 then
                  dbg_vs_count     <= 0;
                  dbg_kbd_latched  <= dbg_kbd_last_cmd & dbg_kbd_seen_flags & dbg_kbd_matrix_seen;
               else
                  dbg_vs_count <= dbg_vs_count + 1;
               end if;
            end if;
         end if;
      end if;
   end process dbg_latch;

   -- digits 0-3: dbg_kbd_latched (last CMD nibble, last ROWSEL nibble,
   -- 2-digit CMD count since reset)
   with dbg_digit_idx select dbg_nibble <=
      dbg_kbd_latched(15 downto 12)  when 0,
      dbg_kbd_latched(11 downto  8)  when 1,
      dbg_kbd_latched( 7 downto  4)  when 2,
      dbg_kbd_latched( 3 downto  0)  when others;

   dbg_ascii <= x"3" & dbg_nibble when unsigned(dbg_nibble) <= 9 else
                std_logic_vector(resize(unsigned(dbg_nibble), 8) - 10 + 65); -- 'A'..'F'

   dbg_font_addr <= std_logic_vector(to_unsigned(to_integer(unsigned(dbg_ascii)) * 16 + dbg_y_in_char, 12))
                       when dbg_active = '1' else (others => '0');

   i_dbg_font : entity work.ram_init
      generic map (
         G_ADDR_WIDTH   => 12,
         G_DATA_WIDTH   => 16,
         G_ROM_PRELOAD  => true,
         G_ROM_FILE     => DBG_FONT_FILE,
         G_ROM_FILE_HEX => false
      )
      port map (
         clock_i   => clk_main_i,
         clen_i    => '1',
         address_i => dbg_font_addr,
         data_i    => (others => '0'),
         wren_i    => '0',
         q_o       => dbg_font_data
      ); -- i_dbg_font

   dbg_pixel_on <= dbg_font_data(15 - dbg_x_in_char) when dbg_active = '1' else '0';

   -- video_ce_o: divides clk_main_i into the core's native pre-scandoubler
   -- pixel clock; video_ce_ovl_o: same rate for milestone 1 (no separate
   -- scandoubler clock enable yet - see globals.vhd's VGA_DX/DY note, may
   -- need revisiting once real video is on screen, Fase 6/9).
   video_ce_o     <= ce_pix;
   video_ce_ovl_o <= video_ce_o;

   -- QL4M65 TEMPORARY DEBUG AID (M1016): yellow hex text on solid black,
   -- composited on top of the QL's own video. Passes normal video through
   -- unchanged outside the box (dbg_active='0').
   video_red_o    <= x"FF" when dbg_active = '1' and dbg_pixel_on = '1' else
                      x"00" when dbg_active = '1' else
                      (others => video_r);
   video_green_o  <= x"FF" when dbg_active = '1' and dbg_pixel_on = '1' else
                      x"00" when dbg_active = '1' else
                      (others => video_g);
   video_blue_o   <= x"00" when dbg_active = '1' else
                      (others => video_b);
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

         -- microdrive: not in milestone 1 (milestone 3)
         mdv_dl_addr   => (others => '0'),
         mdv_dl_data   => (others => '0'),
         mdv_download  => '0',
         mdv_dl_wr     => '0',
         mdv_reverse   => '0',
         led           => open,

         audio         => audio_bit,

         vs            => zx_vs,

         -- IPC link (see keyboard.vhd)
         ipc_comctrl_i => ipc_comctrl,
         ipc_comdata_o => ipc_comdata_zx2kb,
         ipc_comdata_i => ipc_comdata_kb2zx,
         ipc_ipl_i     => ipc_ipl,
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
   -- QL4M65: keyboard - MEGA65-native, wired for real to the ZX8302's IPC
   -- link (see rtl/zx8302.v's header note and keyboard.vhd's own header for
   -- the disassembly-verified protocol details, still pending
   -- hardware/simulation validation)
   ---------------------------------------------------------------------------

   i_keyboard : entity work.keyboard
      port map (
         clk_main_i      => clk_main_i,
         reset_i         => reset,

         key_num_i       => kb_key_num_i,
         key_pressed_n_i => kb_key_pressed_n_i,

         comctrl_o       => ipc_comctrl,
         comdata_i       => ipc_comdata_zx2kb,
         comdata_o       => ipc_comdata_kb2zx,
         audio_o         => ipc_audio,
         ipl_o           => ipc_ipl,

         -- QL4M65 TEMPORARY DEBUG AID (M1018/M1019/M1020, see signal declarations above)
         dbg_last_cmd_o    => dbg_kbd_last_cmd,
         dbg_seen_flags_o  => dbg_kbd_seen_flags,
         dbg_matrix_seen_o => dbg_kbd_matrix_seen
      ); -- i_keyboard

end architecture synthesis;

