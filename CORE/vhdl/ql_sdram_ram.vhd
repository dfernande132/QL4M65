----------------------------------------------------------------------------------
-- QL4M65 Milestone 5 (M5002): the QL's main RAM, backed by SDRAM
--
-- Adapts the 68008 bus (as presented by fx68k plus main.vhd's own decode) to
-- the Avalon-MM master port of MJoergen's SDRAM controller, and generates the
-- wait-state handshake the CPU needs while SDRAM is busy.
--
-- Why this module has to exist at all
-- -----------------------------------
-- Until M5001 the QL's main RAM was BRAM, which answers in one cycle and is
-- always ready, so nothing in this core could ever make the CPU wait for
-- memory. main.vhd's cpu_dtack was simply "not ram_delay_dtack", and
-- ram_delay_dtack is NOT a memory-latency mechanism at all - it is ql_timing's
-- emulation of ZX8301 display contention, and it is only enabled at native QL
-- speed. At 16/24/Full speed DTACK was granted unconditionally.
--
-- SDRAM answers in roughly a dozen clocks, so that wait path has to be built.
-- The original MiSTer core has exactly this and calls it sdram_dtack
-- (QL.sv:687, "cpu_ram ? sdram_dtack && !ram_delay_dtack"); this port dropped
-- it when main RAM went to BRAM, because there was no SDRAM controller
-- available. This module restores it. See
-- .research/milestone5-sdram-design.md.
--
-- Transaction framing
-- -------------------
-- cpu_rd_i/cpu_wr_i already include the CPU's own AS, so one CPU bus cycle is
-- exactly one interval in which cpu_sel_i and (cpu_rd_i or cpu_wr_i) are both
-- high. Exactly one Avalon transaction is issued per such interval: the state
-- machine will not return to ST_IDLE (and so cannot start a second one) until
-- the CPU has dropped AS, which a 68000 always does between bus cycles.
--
-- Address mapping
-- ---------------
-- The QL's own RAM starts at byte $020000, and this deliberately does NOT
-- subtract that base: mapping the CPU address straight through wastes the
-- first 128 KB of a 64 MB device and saves a subtractor from the CPU's
-- address path. (The BRAM version had to rebase, because there every wasted
-- word was a real BRAM tile - see main.vhd's M4010 comment.)
--
-- Reads present byteenable "11" rather than uds/lds: Avalon reads return the
-- whole word and fx68k picks the half it wants, exactly as it did from BRAM.
-- Writes do use uds/lds, matching what dualport_2clk_ram_byteenable got.
----------------------------------------------------------------------------------

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;

entity ql_sdram_ram is
   generic (
      -- Word address in SDRAM at which the QL address space is mapped.
      -- Default 0x0400000 words = 8 MB into the device, leaving the low 8 MB
      -- for the QL-SD mount buffer (which sits at 0 since M5001) and room for
      -- it to grow.
      G_BASE_WORD : natural := 16#400000#
   );
   port (
      clk_i               : in  std_logic;
      rst_i               : in  std_logic;

      -- QL CPU side. cpu_addr_i is a BYTE address; bit 0 is ignored here
      -- (it only ever selects which half of the word uds/lds already name).
      cpu_addr_i          : in  std_logic_vector(23 downto 0);
      cpu_sel_i           : in  std_logic;   -- main.vhd's cpu_ram decode
      cpu_rd_i            : in  std_logic;
      cpu_wr_i            : in  std_logic;
      cpu_uds_i           : in  std_logic;
      cpu_lds_i           : in  std_logic;
      cpu_writedata_i     : in  std_logic_vector(15 downto 0);
      cpu_readdata_o      : out std_logic_vector(15 downto 0);
      cpu_dtack_o         : out std_logic;   -- active HIGH, like main.vhd's cpu_dtack

      -- Avalon-MM master, same clock domain (the SDRAM controller is clocked
      -- from main_clk too - see framework.vhd's i_sdram), so there is no CDC
      -- anywhere on this path.
      avm_write_o         : out std_logic;
      avm_read_o          : out std_logic;
      avm_address_o       : out std_logic_vector(31 downto 0);
      avm_writedata_o     : out std_logic_vector(15 downto 0);
      avm_byteenable_o    : out std_logic_vector( 1 downto 0);
      avm_burstcount_o    : out std_logic_vector( 7 downto 0);
      avm_readdata_i      : in  std_logic_vector(15 downto 0);
      avm_readdatavalid_i : in  std_logic;
      avm_waitrequest_i   : in  std_logic
   );
end entity ql_sdram_ram;

architecture synthesis of ql_sdram_ram is

   type t_state is (ST_IDLE, ST_CMD, ST_DATA, ST_ACK);
   signal state : t_state := ST_IDLE;

   -- Driven as plain signals rather than reading the output ports back -
   -- reading an 'out' port is VHDL-2008 only, and this project has already
   -- been bitten once by Vivado's tolerance for 2008 constructs varying by
   -- context (see main.vhd's ql_timing_enable comment, M3004).
   signal avm_write   : std_logic := '0';
   signal avm_read    : std_logic := '0';
   signal avm_address : std_logic_vector(31 downto 0) := (others => '0');
   signal avm_wdata   : std_logic_vector(15 downto 0) := (others => '0');
   signal avm_be      : std_logic_vector( 1 downto 0) := (others => '0');

   signal rdata       : std_logic_vector(15 downto 0) := (others => '0');

   -- One CPU bus cycle, framed by AS (already folded into cpu_rd_i/cpu_wr_i).
   signal access_active : std_logic;

begin

   access_active <= cpu_sel_i and (cpu_rd_i or cpu_wr_i);

   p_fsm : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if rst_i = '1' then
            state     <= ST_IDLE;
            avm_write <= '0';
            avm_read  <= '0';
         else

            case state is

               when ST_IDLE =>
                  if access_active = '1' then
                     avm_address <= std_logic_vector(
                                       to_unsigned(G_BASE_WORD, 32) +
                                       resize(unsigned(cpu_addr_i(23 downto 1)), 32));
                     avm_wdata   <= cpu_writedata_i;
                     avm_write   <= cpu_wr_i;
                     avm_read    <= cpu_rd_i;
                     if cpu_wr_i = '1' then
                        avm_be <= cpu_uds_i & cpu_lds_i;
                     else
                        avm_be <= "11";
                     end if;
                     state <= ST_CMD;
                  end if;

               when ST_CMD =>
                  -- Avalon: the command is accepted on the first cycle where
                  -- waitrequest is low. Drop it immediately afterwards so
                  -- exactly one transaction is issued.
                  if avm_waitrequest_i = '0' then
                     if avm_read = '1' then
                        avm_read <= '0';
                        state    <= ST_DATA;
                     else
                        avm_write <= '0';
                        -- Writes are acknowledged as soon as the controller
                        -- has taken them; there is nothing to wait for. The
                        -- original core does the same ("so CPU can continue
                        -- without any waitstates", sdram.sv).
                        state     <= ST_ACK;
                     end if;
                  end if;

               when ST_DATA =>
                  if avm_readdatavalid_i = '1' then
                     rdata <= avm_readdata_i;
                     state <= ST_ACK;
                  end if;

               when ST_ACK =>
                  -- Hold DTACK until the CPU ends the bus cycle, then arm for
                  -- the next one.
                  if access_active = '0' then
                     state <= ST_IDLE;
                  end if;

            end case;

         end if;
      end if;
   end process p_fsm;

   avm_write_o      <= avm_write;
   avm_read_o       <= avm_read;
   avm_address_o    <= avm_address;
   avm_writedata_o  <= avm_wdata;
   avm_byteenable_o <= avm_be;
   avm_burstcount_o <= x"01";          -- no bursts: this controller has none

   cpu_readdata_o   <= rdata;
   cpu_dtack_o      <= '1' when state = ST_ACK else '0';

end architecture synthesis;
