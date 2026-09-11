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

      -- Sticky, set if the deadlock watchdog has ever fired. Never expected
      -- to be '1'; if it is, there is a real bug in the SDRAM path and this
      -- module has papered over it to keep the machine alive. See the
      -- watchdog comment in the architecture.
      timeout_seen_o      : out std_logic;

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

   -- Deadlock watchdog.
   --
   -- Without this, a transaction that never completes hangs the QL forever
   -- with no way out but a power cycle: ST_CMD waits for waitrequest and
   -- ST_DATA waits for readdatavalid, and neither has an escape. That is too
   -- fragile a failure mode to leave in, especially now that SDRAM has TWO
   -- masters (main RAM and the QL-SD mount buffer, arbitrated by
   -- i_avm_arbit_sdram in mega65.vhd) - avm_arbit routes read responses by
   -- last_grant, so a lost or misrouted response is a real, if unproven,
   -- possibility that simply could not happen while SDRAM had one client.
   --
   -- Deliberately generous: 4096 cycles at 84 MHz is ~49 us, which is orders
   -- of magnitude beyond any legitimate access even with the other master
   -- hogging the bus (a read is ~12 cycles, and arbitration is round-robin).
   -- So this can only ever fire on a genuine deadlock, never on slow-but-
   -- working traffic - it must not be allowed to paper over ordinary
   -- contention.
   --
   -- On expiry it releases DTACK with whatever data is in rdata and rearms.
   -- That trades an unrecoverable hang for one corrupted memory access, which
   -- is the better of two bad outcomes: the machine stays usable and the
   -- symptom is visible rather than terminal. It is NOT a fix - if this ever
   -- fires in practice there is a real bug underneath and timeout_seen_o says
   -- so.
   constant C_TIMEOUT      : natural := 4096;
   signal   timeout_cnt    : natural range 0 to C_TIMEOUT := 0;
   signal   timeout_hit    : std_logic := '0';

begin

   access_active <= cpu_sel_i and (cpu_rd_i or cpu_wr_i);

   p_fsm : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if rst_i = '1' then
            state       <= ST_IDLE;
            avm_write   <= '0';
            avm_read    <= '0';
            timeout_cnt <= 0;
            timeout_hit <= '0';
         else

            -- Watchdog: runs only while a transaction is outstanding, i.e.
            -- in the two states that can wait on the controller.
            if state = ST_CMD or state = ST_DATA then
               if timeout_cnt = C_TIMEOUT then
                  -- Give up: drop the request, acknowledge the CPU with
                  -- whatever rdata holds, and leave a sticky marker behind.
                  avm_write   <= '0';
                  avm_read    <= '0';
                  timeout_hit <= '1';
                  state       <= ST_ACK;
               else
                  timeout_cnt <= timeout_cnt + 1;
               end if;
            else
               timeout_cnt <= 0;
            end if;

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
   timeout_seen_o   <= timeout_hit;

end architecture synthesis;
