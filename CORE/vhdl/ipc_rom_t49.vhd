---------------------------------------------------------------------------------------------------------
-- Sinclair QL for MEGA65 (QL4M65)
--
-- Vivado-clean replacement for the T48 project's rtl/rom_t49.vhd (an Altera
-- "altsyncram" megafunction wizard file), providing the real IPC 8049
-- firmware ROM to the UNMODIFIED T48 core (CORE/QL_MiSTer/rtl/T48/, see
-- rtl/T48/system/t49_rom-struct-a.vhd, which instantiates a component
-- named "rom_t49" with exactly this entity/port shape). Same drop-in
-- pattern already used elsewhere in this port for Quartus-specific
-- RAM/ROM primitives (ql_rom/vram/mdv's dpram.v) - the original T48
-- sources are left completely untouched; this file is simply the only
-- "rom_t49" implementation added to the Vivado project, so it's what gets
-- elaborated.
--
-- Backed by M2M's own ram_init (already used for the OSM/debug font ROMs
-- in this project), loaded from ipc8049-hermes.rom - a flat, one-byte-
-- per-line hex dump of rtl/ipc8049-hermes.hex (the community-patched IPC
-- firmware the original QL_MiSTer/MiST core uses by default, see
-- rtl/rom_t49.vhd's own init_file - not the plain rtl/ipc8049.hex),
-- converted with a one-off Intel-HEX-to-flat-hex script (see
-- DECISIONES.md for the conversion note).
--
-- QL4M65 port done by Jose Daniel Fernandez Santos (dfsantos) in 2026 and
-- licensed under GPL v3
---------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity rom_t49 is
   port (
      address : in  std_logic_vector(10 downto 0);
      clock   : in  std_logic := '1';
      q       : out std_logic_vector(7 downto 0)
   );
end entity rom_t49;

architecture beh of rom_t49 is
begin

   i_ram_init : entity work.ram_init
      generic map (
         G_ADDR_WIDTH   => 11,
         G_DATA_WIDTH   => 8,
         G_ROM_PRELOAD  => true,
         G_ROM_FILE     => "../../CORE/vhdl/ipc8049-hermes.rom",
         G_ROM_FILE_HEX => true
      )
      port map (
         clock_i   => clock,
         clen_i    => '1',
         address_i => address,
         data_i    => (others => '0'),
         wren_i    => '0',
         q_o       => q
      );

end architecture beh;
