library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.numeric_std_unsigned.all;

entity video_overlay is
   generic  (
      G_VGA_DX          : natural;
      G_VGA_DY          : natural;
      G_FONT_FILE       : string;
      G_FONT_DX         : natural;
      G_FONT_DY         : natural
   );
   port (
      vga_clk_i         : in  std_logic;

      -- VGA input
      vga_ce_i          : in  std_logic;
      vga_red_i         : in  std_logic_vector(7 downto 0);
      vga_green_i       : in  std_logic_vector(7 downto 0);
      vga_blue_i        : in  std_logic_vector(7 downto 0);
      vga_hs_i          : in  std_logic;
      vga_vs_i          : in  std_logic;
      vga_de_i          : in  std_logic;

      -- QNICE
      vga_cfg_scaling_i : in  natural range 0 to 8;
      vga_cfg_hscale_i  : in  natural;
      vga_cfg_vscale_i  : in  natural;
      vga_cfg_enable_i  : in  std_logic;
      vga_cfg_r15kHz_i  : in  std_logic;
      vga_cfg_xy_i      : in  std_logic_vector(15 downto 0);
      vga_cfg_dxdy_i    : in  std_logic_vector(15 downto 0);
      vga_vram_addr_o   : out std_logic_vector(15 downto 0);
      vga_vram_data_i   : in  std_logic_vector(15 downto 0);

      -- VGA output
      vga_ce_o          : out std_logic;
      vga_red_o         : out std_logic_vector(7 downto 0);
      vga_green_o       : out std_logic_vector(7 downto 0);
      vga_blue_o        : out std_logic_vector(7 downto 0);
      vga_hs_o          : out std_logic;
      vga_vs_o          : out std_logic;
      vga_de_o          : out std_logic
   );
end entity video_overlay;

architecture synthesis of video_overlay is

   type stage_t is record
      vga_ce      : std_logic;
      vga_pix_x   : std_logic_vector(10 downto 0);
      vga_pix_y   : std_logic_vector(10 downto 0);
      vga_red     : std_logic_vector( 7 downto 0);
      vga_green   : std_logic_vector( 7 downto 0);
      vga_blue    : std_logic_vector( 7 downto 0);
      vga_hs      : std_logic;
      vga_vs      : std_logic;
      vga_de      : std_logic;
      vga_col     : integer range 0 to 2047;
      vga_row     : integer range 0 to 2047;
   end record stage_t;

   signal stage1 : stage_t;
   signal stage2 : stage_t;
   signal stage3 : stage_t;
   signal stage4 : stage_t;
   signal stage5 : stage_t;
   signal stage6 : stage_t;
   signal stage7 : stage_t;
   signal stage8 : stage_t;
   signal stage9 : stage_t;

   signal stage8_vga_osm_on  : std_logic;
   signal stage8_vga_osm_rgb : std_logic_vector(23 downto 0);   -- 23..0 = RGB, 8 bits each

begin

   -----------------------------------------------
   -- Stage 1 : Recover pixel counters
   -----------------------------------------------

   i_vga_recover_counters : entity work.vga_recover_counters
      port map (
         vga_clk_i   => vga_clk_i,
         vga_ce_i    => vga_ce_i,
         vga_red_i   => vga_red_i,
         vga_green_i => vga_green_i,
         vga_blue_i  => vga_blue_i,
         vga_hs_i    => vga_hs_i,
         vga_vs_i    => vga_vs_i,
         vga_de_i    => vga_de_i,
         vga_ce_o    => stage1.vga_ce,
         vga_pix_x_o => stage1.vga_pix_x,
         vga_pix_y_o => stage1.vga_pix_y,
         vga_red_o   => stage1.vga_red,
         vga_green_o => stage1.vga_green,
         vga_blue_o  => stage1.vga_blue,
         vga_hs_o    => stage1.vga_hs,
         vga_vs_o    => stage1.vga_vs,
         vga_de_o    => stage1.vga_de
      ); -- i_vga_recover_counters

   -- QL4M65: vga_pix_x/y are recovered from whatever hs/vs/de this instance
   -- actually sees - for the HDMI path (digital_pipeline.vhd) that is ascal's
   -- OUTPUT (e.g. 720x576), not the core's native canvas (G_VGA_DX x G_VGA_DY,
   -- 512x256 for the QL). A flat pixel offset (the previous vga_cfg_shift_i)
   -- only corrects a small letterbox border and breaks down when ascal is
   -- doing a real stretch (512->720/640, ~1.4x) rather than a near 1:1 fit -
   -- confirmed on M1002/M1003 hardware tests, where the Welcome/Options OSD
   -- was clipped top-left regardless of the HDMI output resolution chosen.
   --
   -- Rescaling proportionally maps back to the OSM's native coordinate frame
   -- regardless of the actual stretch factor. vga_cfg_hscale_i/vscale_i are a
   -- Q16 fixed-point reciprocal scale (65536 = "1.0", i.e. no rescale, used
   -- by the analog path) computed by the CALLER from compile-time constants
   -- only (see digital_pipeline.vhd) - a per-pixel runtime DIVISION here blew
   -- the 84 MHz timing budget badly (WNS ~-25ns) on the first attempt, so
   -- this uses a multiply plus a shift-by-a-literal-power-of-2 instead, which
   -- Vivado maps to a single DSP48 multiply with no combinational divider.
   stage1.vga_col <= (to_integer(stage1.vga_pix_x) * vga_cfg_hscale_i) / 65536;
   stage1.vga_row <= (to_integer(stage1.vga_pix_y) * vga_cfg_vscale_i) / 65536 * 2 when vga_cfg_r15kHz_i = '1' else
                     (to_integer(stage1.vga_pix_y) * vga_cfg_vscale_i) / 65536;


   -----------------------------------------------
   -- Instantiate On-Screen-Menu generator
   -----------------------------------------------

   i_vga_osm : entity work.vga_osm
      generic map (
         G_VGA_DX              => G_VGA_DX,
         G_VGA_DY              => G_VGA_DY,
         G_FONT_FILE           => G_FONT_FILE,
         G_FONT_DX             => G_FONT_DX,
         G_FONT_DY             => G_FONT_DY
      )
      port map (
         clk_i                 => vga_clk_i,
         vga_col_i             => stage1.vga_col,
         vga_row_i             => stage1.vga_row,
         vga_osm_cfg_scaling_i => vga_cfg_scaling_i,
         vga_osm_cfg_xy_i      => vga_cfg_xy_i,
         vga_osm_cfg_dxdy_i    => vga_cfg_dxdy_i,
         vga_osm_cfg_enable_i  => vga_cfg_enable_i,
         vga_osm_vram_addr_o   => vga_vram_addr_o,              -- Stage 5
         vga_osm_vram_data_i   => vga_vram_data_i( 7 downto 0), -- Stage 6
         vga_osm_vram_attr_i   => vga_vram_data_i(15 downto 8), -- Stage 6
         vga_osm_on_o          => stage8_vga_osm_on,
         vga_osm_rgb_o         => stage8_vga_osm_rgb
      ); -- i_vga_osm


   -- Clear video output outside visible screen.
   p_stage2 : process (vga_clk_i)
   begin
      if rising_edge(vga_clk_i) then
         stage2 <= stage1;
         if not stage1.vga_de then
            stage2.vga_red   <= (others => '0');
            stage2.vga_blue  <= (others => '0');
            stage2.vga_green <= (others => '0');
         end if;
      end if;
   end process p_stage2;

   -- Delay the video stream to bring it in sync with the OSM overlay.
   p_stage345678 : process (vga_clk_i)
   begin
      if rising_edge(vga_clk_i) then
         stage3 <= stage2;
         stage4 <= stage3;
         stage5 <= stage4;
         stage6 <= stage5;
         stage7 <= stage6;
         stage8 <= stage7;
      end if;
   end process p_stage345678;

   p_stage9 : process (vga_clk_i)
   begin
      if rising_edge(vga_clk_i) then
         stage9 <= stage8;

         -- On-Screen Menu overlay
         if stage8_vga_osm_on = '1' then
            stage9.vga_red   <= stage8_vga_osm_rgb(23 downto 16);
            stage9.vga_green <= stage8_vga_osm_rgb(15 downto  8);
            stage9.vga_blue  <= stage8_vga_osm_rgb( 7 downto  0);
         end if;

      end if;
   end process p_stage9;

   vga_hs_o    <= stage9.vga_hs;
   vga_vs_o    <= stage9.vga_vs;
   vga_de_o    <= stage9.vga_de;
   vga_ce_o    <= stage9.vga_ce;
   vga_red_o   <= stage9.vga_red;
   vga_green_o <= stage9.vga_green;
   vga_blue_o  <= stage9.vga_blue;

end architecture synthesis;

