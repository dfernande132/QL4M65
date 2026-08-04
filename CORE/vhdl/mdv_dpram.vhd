---------------------------------------------------------------------------------------------------------
-- Sinclair QL for MEGA65 (QL4M65)
--
-- Vivado-clean replacement for rtl/dpram.v (an Altera "altsyncram" wrapper),
-- providing the internal buffer for the UNMODIFIED rtl/mdv.v (see
-- rtl/mdv.v:49-60, which instantiates a module named "dpram" with exactly
-- this parameter/port shape: `dpram #(17, 88000) vram (...)`). Same
-- drop-in pattern already used for the T48 core's rom_t49 (see
-- ipc_rom_t49.vhd's own header) - mdv.v itself is left completely
-- untouched, this is simply the only "dpram" implementation added to the
-- Vivado project, so it's what gets elaborated. rtl/dpram.v stays excluded
-- from the compile list (see build_core.tcl / doc/m2m/exceptions.md).
--
-- Milestone 2 phase A (read-only microdrive, BRAM) - see
-- .research/microdrive-read-design.md, section A.1. ADDRWIDTH/NUMWORDS
-- come from mdv.v's own fixed instantiation (17, 88000) - not something we
-- can shrink without modifying mdv.v itself, even though a real .MDV image
-- only needs ~87465 words (174930 bytes / 2) of that.
--
-- QL4M65 port done by Jose Daniel Fernandez Santos (dfsantos) in 2026 and
-- licensed under GPL v3
---------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity dpram is
   generic (
      ADDRWIDTH : natural := 8;
      NUMWORDS  : natural := 256   -- unused here: BRAM size is driven by ADDRWIDTH (2**ADDRWIDTH words), matches dpram.v's own behaviour
   );
   port (
      wrclock   : in  std_logic;
      wraddress : in  std_logic_vector(ADDRWIDTH - 1 downto 0);
      wren      : in  std_logic;
      byteena_a : in  std_logic_vector(1 downto 0);
      data      : in  std_logic_vector(15 downto 0);

      rdclock   : in  std_logic;
      rdaddress : in  std_logic_vector(ADDRWIDTH - 1 downto 0);
      q         : out std_logic_vector(15 downto 0)
   );
end entity dpram;

architecture synthesis of dpram is
begin

   i_ram : entity work.dualport_2clk_ram_byteenable
      generic map (
         G_ADDR_WIDTH => ADDRWIDTH,
         G_DATA_WIDTH => 16
      )
      port map (
         a_clk_i        => wrclock,
         a_address_i    => wraddress,
         a_data_i       => data,
         a_byteenable_i => byteena_a,
         a_wren_i       => wren,
         a_q_o          => open,

         b_clk_i        => rdclock,
         b_address_i    => rdaddress,
         b_data_i       => (others => '0'),
         b_byteenable_i => (others => '0'),
         b_wren_i       => '0',
         b_q_o          => q
      ); -- i_ram

end architecture synthesis;
