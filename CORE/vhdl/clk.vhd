-------------------------------------------------------------------------------------------------------------
-- Sinclair QL for MEGA65 (QL4M65)
--
-- Clock Generator using the Xilinx specific MMCME2_ADV:
--
--   MiSTer's QL core expects a single 84.000000 MHz master clock (rtl/pll/pll_0002.v,
--   output_clock_frequency0 = 84.000000 MHz, generated there from a 50 MHz reference).
--   All CPU/video/SD/IPC sub-clocks (QL/16MHz/24MHz/Full CPU bus clocks, ZX8301 pixel
--   clock, SD card SPI clock, IPC 8049 clock) are derived from this single 84 MHz clock
--   inside the core itself via fractional clock-enable accumulators - no additional PLLs.
--   See CoreQL/.research/PORTING-PLAN.md, section 3, for the full clock-enable table.
--
-- Frequency math:
--    f_VCO  = 100 MHz x CLKFBOUT_MULT_F / DIVCLK_DIVIDE = 100 x 7.875 / 1 = 787.500 MHz
--    f_OUT  = f_VCO / CLKOUT0_DIVIDE_F                  = 787.500 / 9.375 =  84.000000 MHz
--    Error vs. the original MiSTer 84.000000 MHz: 0 Hz (exact match, 0 ppm) - unlike the
--    C64/Amiga ports, the QL's 84 MHz target divides the MEGA65's 100 MHz board clock
--    exactly, so no HDMI flicker-fix twin clock is needed for this signal.
--
-- MMCME2_ADV legality checks (Artix-7 XC7A200T-2, see Xilinx DS181 / UG472):
--    * VCO = 787.500 MHz is within the -2 speed grade MMCM VCO range of 600..1440 MHz
--    * PFD = 100 MHz / DIVCLK_DIVIDE(1) = 100 MHz, within the allowed 10..500 MHz (-2)
--    * CLKFBOUT_MULT_F = 7.875 is a multiple of 0.125 within 2.000..64.000 (legal fractional)
--    * CLKOUT0_DIVIDE_F = 9.375 is a multiple of 0.125 within 1.000..128.000 (legal fractional)
--
-- No HDMI flicker-free twin clock (unlike C64MEGA65/AExp): milestone 1 fixes the core to
-- native QL speed and PAL video; the frame-rate-vs-50Hz-HDMI question is deferred to when
-- the video pipeline is verified in hardware (see PORTING-PLAN.md, open items).
--
-- Powered by MiSTer2MEGA65
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
-- QL4M65 port: clock retargeted to 84 MHz for the Sinclair QL core, 2026
-------------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

library xpm;
use xpm.vcomponents.all;

entity clk is
   port (
      sys_clk_i       : in  std_logic;   -- expects 100 MHz

      main_clk_o      : out std_logic;   -- QL core's 84 MHz master clock
      main_rst_o      : out std_logic    -- main's reset, synchronized
   );
end entity clk;

architecture rtl of clk is

signal main_fb            : std_logic;
signal main_fb_mmcm       : std_logic;
signal main_clk_mmcm      : std_logic;

signal main_locked        : std_logic;

begin

   -------------------------------------------------------------------------------------
   -- Generate the QL core's 84.000000 MHz master clock
   -------------------------------------------------------------------------------------

   i_clk_main : MMCME2_ADV
      generic map (
         BANDWIDTH            => "OPTIMIZED",
         CLKOUT4_CASCADE      => FALSE,
         COMPENSATION         => "ZHOLD",
         STARTUP_WAIT         => FALSE,
         CLKIN1_PERIOD        => 10.0,       -- INPUT @ 100 MHz
         REF_JITTER1          => 0.010,
         DIVCLK_DIVIDE        => 1,
         CLKFBOUT_MULT_F      => 7.875,      -- VCO = 787.500 MHz
         CLKFBOUT_PHASE       => 0.000,
         CLKFBOUT_USE_FINE_PS => FALSE,
         CLKOUT0_DIVIDE_F     => 9.375,      -- 84.000000 MHz
         CLKOUT0_PHASE        => 0.000,
         CLKOUT0_DUTY_CYCLE   => 0.500,
         CLKOUT0_USE_FINE_PS  => FALSE
      )
      port map (
         -- Output clocks
         CLKFBOUT            => main_fb_mmcm,
         CLKOUT0             => main_clk_mmcm,
         -- Input clock control
         CLKFBIN             => main_fb,
         CLKIN1              => sys_clk_i,
         CLKIN2              => '0',
         -- Tied to always select the primary input clock
         CLKINSEL            => '1',
         -- Ports for dynamic reconfiguration
         DADDR               => (others => '0'),
         DCLK                => '0',
         DEN                 => '0',
         DI                  => (others => '0'),
         DO                  => open,
         DRDY                => open,
         DWE                 => '0',
         -- Ports for dynamic phase shift
         PSCLK               => '0',
         PSEN                => '0',
         PSINCDEC            => '0',
         PSDONE              => open,
         -- Other control and status signals
         LOCKED              => main_locked,
         CLKINSTOPPED        => open,
         CLKFBSTOPPED        => open,
         PWRDWN              => '0',
         RST                 => '0'
      ); -- i_clk_main

   -------------------------------------------------------------------------------------
   -- Output buffering
   -------------------------------------------------------------------------------------

   main_fb_bufg : BUFG
      port map (
         I => main_fb_mmcm,
         O => main_fb
      );

   main_clk_bufg : BUFG
      port map (
         I => main_clk_mmcm,
         O => main_clk_o
      );

   -------------------------------------
   -- Reset generation
   -------------------------------------

   i_xpm_cdc_async_rst_main : xpm_cdc_async_rst
      generic map (
         RST_ACTIVE_HIGH => 1,
         DEST_SYNC_FF    => 6
      )
      port map (
         src_arst  => not main_locked,   -- 1-bit input: Source reset signal.
         dest_clk  => main_clk_o,        -- 1-bit input: Destination clock.
         dest_arst => main_rst_o         -- 1-bit output: src_rst synchronized to the destination clock domain.
                                         -- This output is registered.
      );

end architecture rtl;
