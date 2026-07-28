----------------------------------------------------------------------------------
-- MiSTer2MEGA65 Framework
--
-- Wrapper for the MiSTer core that runs exclusively in the core's clock domanin
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
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
      -- QNICE Shell via mega65.vhd's ql_rom_u/l (C_DEV_QL_MINERVA). Not used
      -- yet - i_democore below has no ROM of its own - but the port exists
      -- already so mega65.vhd's RAM instance has somewhere real to connect
      -- to. Wired for real once the QL core replaces i_democore (M1001).
      ql_rom_addr_o           : out std_logic_vector(14 downto 0);
      ql_rom_data_i           : in  std_logic_vector(15 downto 0)
   );
end entity main;

architecture synthesis of main is

-- @TODO: Remove these demo core signals
signal keyboard_n          : std_logic_vector(79 downto 0);

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

   -- @TODO: Add the actual MiSTer core here
   -- The demo core's purpose is to show a test image and to make sure, that the MiSTer2MEGA65 framework
   -- can be synthesized and run stand-alone without an actual MiSTer core being there, yet
   i_democore : entity work.democore
      port map (
         clk_main_i           => clk_main_i,

         reset_i              => reset_soft_i or reset_hard_i,       -- long and short press of reset button mean the same
         pause_i              => pause_i,

         ball_col_rgb_i       => x"EE4020",                          -- ball color (RGB): orange
         paddle_speed_i       => x"1",                               -- paddle speed is about 50 pixels / sec (due to 50 Hz)

         keyboard_n_i         => keyboard_n,                         -- move the paddle with the cursor left/right keys...
         joy_up_n_i           => joy_1_up_n_i,                       -- ... or move the paddle with a joystick in port #1
         joy_down_n_i         => joy_1_down_n_i,
         joy_left_n_i         => joy_1_left_n_i,
         joy_right_n_i        => joy_1_right_n_i,
         joy_fire_n_i         => joy_1_fire_n_i,

         vga_ce_o             => video_ce_o,
         vga_red_o            => video_red_o,
         vga_green_o          => video_green_o,
         vga_blue_o           => video_blue_o,
         vga_vs_o             => video_vs_o,
         vga_hs_o             => video_hs_o,
         vga_hblank_o         => video_hblank_o,
         vga_vblank_o         => video_vblank_o,

         audio_left_o         => audio_left_o,
         audio_right_o        => audio_right_o
      ); -- i_democore

   -- On video_ce_o and video_ce_ovl_o: You have an important @TODO when porting a core:
   -- video_ce_o: You need to make sure that video_ce_o divides clk_main_i such that it transforms clk_main_i
   --             into the pixelclock of the core (means: the core's native output resolution pre-scandoubler)
   -- video_ce_ovl_o: Clock enable for the OSM overlay and for sampling the core's (retro) output in a way that
   --             it is displayed correctly on a "modern" analog input device: Make sure that video_ce_ovl_o
   --             transforms clk_main_o into the post-scandoubler pixelclock that is valid for the target
   --             resolution specified by VGA_DX/VGA_DY (globals.vhd)
   -- video_retro15kHz_o: '1', if the output from the core (post-scandoubler) in the retro 15 kHz analog RGB mode.
   --             Hint: Scandoubler off does not automatically mean retro 15 kHz on.
   video_ce_ovl_o <= video_ce_o;

   -- @TODO: Keyboard mapping and keyboard behavior
   -- Each core is treating the keyboard in a different way: Some need low-active "matrices", some
   -- might need small high-active keyboard memories, etc. This is why the MiSTer2MEGA65 framework
   -- lets you define literally everything and only provides a minimal abstraction layer to the keyboard.
   -- You need to adjust keyboard.vhd to your needs
   -- QL4M65: keyboard.vhd's entity was already rewritten for the real QL IPC
   -- link (comdata/comctrl), ahead of main.vhd itself, so this instantiation
   -- only matches the new port list mechanically - it is not wired to a real
   -- ZX8302 yet (that happens when the QL core replaces i_democore below, at
   -- milestone 1's M1001 step). keyboard_n (still read by i_democore above)
   -- no longer has anything driving it via example_n_o, so it is tied to
   -- "nothing pressed" just below instead.
   keyboard_n <= (others => '1');

   -- QL4M65: no ROM consumer yet (see entity port comment above); ql_rom_data_i
   -- is simply unused for now.
   ql_rom_addr_o <= (others => '0');

   i_keyboard : entity work.keyboard
      port map (
         clk_main_i           => clk_main_i,
         reset_i              => reset_soft_i or reset_hard_i,

         -- Interface to the MEGA65 keyboard
         key_num_i            => kb_key_num_i,
         key_pressed_n_i      => kb_key_pressed_n_i,

         -- Not connected to a real ZX8302 yet, see comment above
         comctrl_o            => open,
         comdata_i            => '1',
         comdata_o            => open,
         audio_o              => open,
         ipl_o                => open
      ); -- i_keyboard

end architecture synthesis;

