---------------------------------------------------------------------------------------------------------
-- Sinclair QL for MEGA65 (QL4M65)
--
-- IPC (Intel 8049) - structural VHDL port of rtl/ipc.v
--
-- M1029/M1030 hand-reimplemented the ZX8302's comdata/comctrl protocol
-- from scratch in keyboard.vhd, based on a from-scratch disassembly of
-- rtl/ipc8049.hex. That turned out to be the wrong direction: real
-- Minerva never even calls the one command we got right (9, "keyrow") -
-- it gates everything behind command 1's status byte bit 0 ("keyboard
-- event pending"), which we always answered as clear, and the real
-- keyboard read (command 8) is a stateful event QUEUE we never
-- implemented at all. Re-deriving that whole protocol by hand a second
-- time (right this time) would mean re-solving, from scratch, a problem
-- the ORIGINAL core already solves for free: rtl/ipc.v does not
-- reimplement the 8049's protocol either - it emulates the real 8049
-- microcontroller (CORE/QL_MiSTer/rtl/T48/, an OpenCores project, plain
-- portable VHDL) running the REAL firmware ROM, cycle-accurate. This
-- file is a straight structural port of rtl/ipc.v's wiring - it adds NO
-- protocol logic of its own, it just connects our own MEGA65 keyboard
-- matrix (keyboard.vhd's ql_matrix_o, unchanged - already byte/bit
-- compatible with rtl/keyboard.v's "matrix" output, which is exactly
-- what rtl/ipc.v itself expects on this same interface) to the 8049's
-- P1 data-bus-read logic, and decodes P2 into audio/ipl/comdata exactly
-- as rtl/ipc.v does. See DECISIONES.md for the full investigation.
--
-- The T48 core files themselves (CORE/QL_MiSTer/rtl/T48/*.vhd) are
-- 100% UNMODIFIED OpenCores sources, added to the Vivado project as-is
-- (file list taken from rtl/T48/T8049.qip, the original project's own
-- compile list). The only other new file this needs is
-- ipc_rom_t49.vhd - a Vivado-clean replacement for the Altera
-- "altsyncram" ROM wizard file rtl/rom_t49.vhd (same drop-in pattern
-- already used for ql_rom/vram/the microdrive's dpram.v).
--
-- Powered by MiSTer2MEGA65
-- QL4M65 port done by Jose Daniel Fernandez Santos (dfsantos) in 2026 and
-- licensed under GPL v3
---------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity ipc is
   port (
      clk_main_i    : in  std_logic;   -- QL core clock (84 MHz, main_clk)
      ce_11m_i      : in  std_logic;   -- real 11MHz IPC crystal clock-enable
      reset_i       : in  std_logic;

      -- MEGA65 keyboard matrix (from keyboard.vhd's ql_matrix_o), same
      -- byte/bit layout as rtl/keyboard.v's "matrix" output - this is
      -- exactly what rtl/ipc.v itself wires into the 8049's P1-selected
      -- data bus below.
      ql_matrix_i   : in  std_logic_vector(63 downto 0);

      -- ZX8302 IPC serial link (same ports/direction as keyboard.vhd
      -- used to expose, see rtl/zx8302.v for the framing)
      comctrl_o     : out std_logic;
      comdata_i     : in  std_logic;   -- the ZX8302's own outgoing bit
      comdata_o     : out std_logic;   -- the 8049's own outgoing bit
      audio_o       : out std_logic;
      ipl_o         : out std_logic_vector(1 downto 0)
   );
end entity ipc;

architecture beh of ipc is

   signal p1_o        : std_logic_vector(7 downto 0);
   signal p2_o         : std_logic_vector(7 downto 0);
   signal p2_i         : std_logic_vector(7 downto 0);
   signal db_i         : std_logic_vector(7 downto 0);
   signal comdata_out  : std_logic;

   function repl8(b : std_logic) return std_logic_vector is
      variable v : std_logic_vector(7 downto 0);
   begin
      v := (others => b);
      return v;
   end function repl8;

begin

   -- P1 one-hot row select -> matrix byte read-back, same bitwise
   -- OR-of-masked-bytes as rtl/ipc.v's own t8049_db_i assignment
   db_i <= (ql_matrix_i( 7 downto  0) and repl8(p1_o(0)))
        or (ql_matrix_i(15 downto  8) and repl8(p1_o(1)))
        or (ql_matrix_i(23 downto 16) and repl8(p1_o(2)))
        or (ql_matrix_i(31 downto 24) and repl8(p1_o(3)))
        or (ql_matrix_i(39 downto 32) and repl8(p1_o(4)))
        or (ql_matrix_i(47 downto 40) and repl8(p1_o(5)))
        or (ql_matrix_i(55 downto 48) and repl8(p1_o(6)))
        or (ql_matrix_i(63 downto 56) and repl8(p1_o(7)));

   -- P2: bit7 = comdata (wired-AND with the ZX8302's own outgoing bit,
   -- fed back so the 8049 can read the line it shares with the CPU),
   -- bits 6..0 unused/tied low - same as rtl/ipc.v's t8049_p2_i
   comdata_out <= p2_o(7);
   p2_i        <= (comdata_out and comdata_i) & "0000000";

   comdata_o <= comdata_out;
   audio_o   <= p2_o(1);
   ipl_o     <= p2_o(3 downto 2);

   -- QL4M65: gate_port_input_g => 0 (PASS-THROUGH, not the VHDL default
   -- of 1/gated) - matches rtl/ipc.v's own "t8049_notri #(0) t8049 (...)"
   -- instantiation exactly. p1_i is tied to constant 0 below (no gating
   -- needed, we never drive real data on it) and p2_i already carries
   -- the wired-AND comdata feedback computed explicitly above - gating
   -- it again internally (the g=1 behaviour) would AND it a second time
   -- against the core's own p2_o, which is NOT what the original does.
   i_t8049 : entity work.t8049_notri
      generic map (
         gate_port_input_g => 0
      )
      port map (
         xtal_i        => clk_main_i,
         xtal_en_i     => ce_11m_i,
         reset_n_i     => not reset_i,
         t0_i          => '0',
         t0_o          => open,
         t0_dir_o      => open,
         int_n_i       => '1',        -- never used by the real firmware either (rtl/ipc.v ties this high too)
         ea_i          => '0',        -- all program memory internal (2KB ROM fits the core's 2KB internal range)
         rd_n_o        => open,
         psen_n_o      => open,
         wr_n_o        => comctrl_o,
         ale_o         => open,
         db_i          => db_i,
         db_o          => open,
         db_dir_o      => open,
         t1_i          => '0',
         p2_i          => p2_i,
         p2_o          => p2_o,
         p2l_low_imp_o => open,
         p2h_low_imp_o => open,
         p1_i          => x"00",
         p1_o          => p1_o,
         p1_low_imp_o  => open,
         prog_n_o      => open
      );

end architecture beh;
