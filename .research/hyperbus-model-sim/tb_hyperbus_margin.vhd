-- QL4M65 R3 investigation (2026-08-27): drives the REAL, unmodified
-- hyperram.vhd (the full controller chain this project ships, unchanged)
-- against hyperbus_device_model.vhd through explicit tri-state muxing
-- (mirrors what a real IOBUF does - no VHDL resolved-type tricks), issues
-- one Avalon-MM read, and checks whether the word that comes back matches
-- the device model's own known pattern - for a given
-- G_RWDS_SETTLE_DELAY_NS (how long after CS# falls the device's RWDS pin
-- reflects its real latency decision). Swept externally (xelab
-- -generic_top) across many elaborations to find the real margin.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_hyperbus_margin is
   generic (
      G_RWDS_SETTLE_DELAY_NS : real    := 2.0;
      G_DEVICE_2X_LATENCY    : boolean := false
   );
end entity tb_hyperbus_margin;

architecture sim of tb_hyperbus_margin is

   signal clk         : std_logic := '0';  -- 100 MHz
   signal clk_del     : std_logic := '0';  -- 100 MHz, 90 degrees (2.5ns) behind clk
   signal delay_refclk : std_logic := '0'; -- 200 MHz
   signal rst         : std_logic := '1';
   signal sim_done    : boolean := false;

   -- Avalon-MM (test driver side)
   signal avm_write         : std_logic := '0';
   signal avm_read          : std_logic := '0';
   signal avm_address       : std_logic_vector(31 downto 0) := (others => '0');
   signal avm_writedata     : std_logic_vector(15 downto 0) := (others => '0');
   signal avm_byteenable    : std_logic_vector(1 downto 0) := "11";
   signal avm_burstcount    : std_logic_vector(7 downto 0) := x"01";
   signal avm_readdata      : std_logic_vector(15 downto 0);
   signal avm_readdatavalid : std_logic;
   signal avm_waitrequest   : std_logic;

   -- hr_* pins, controller side (hyperram.vhd's own outputs/inputs)
   signal hr_resetn    : std_logic;
   signal hr_csn       : std_logic;
   signal hr_ck        : std_logic;
   signal hr_rwds_in   : std_logic;
   signal hr_rwds_out  : std_logic;
   signal hr_rwds_oe_n : std_logic;
   signal hr_dq_in     : std_logic_vector(7 downto 0);
   signal hr_dq_out    : std_logic_vector(7 downto 0);
   signal hr_dq_oe_n   : std_logic_vector(7 downto 0);

   -- hr_* pins, device side (hyperbus_device_model.vhd's own outputs)
   signal dev_rwds_out : std_logic;
   signal dev_dq_out   : std_logic_vector(7 downto 0);

   signal xfer_done : std_logic;
   signal xfer_ok   : std_logic;

   signal result_reported : boolean := false;

begin

   p_clk : process
   begin
      while not sim_done loop
         clk <= '0'; wait for 5 ns;
         clk <= '1'; wait for 5 ns;
      end loop;
      wait;
   end process p_clk;

   -- 90 degrees behind clk at 100 MHz = 2.5 ns delay.
   p_clk_del : process
   begin
      wait for 2.5 ns;
      while not sim_done loop
         clk_del <= '0'; wait for 5 ns;
         clk_del <= '1'; wait for 5 ns;
      end loop;
      wait;
   end process p_clk_del;

   p_delay_refclk : process
   begin
      while not sim_done loop
         delay_refclk <= '0'; wait for 2.5 ns;
         delay_refclk <= '1'; wait for 2.5 ns;
      end loop;
      wait;
   end process p_delay_refclk;

   -- Tri-state pin emulation, same principle as a real IOBUF: whichever
   -- side currently has its output-enable asserted drives the wire; the
   -- OTHER side's own _in_i port reads that same resolved wire value.
   hr_rwds_in <= hr_rwds_out when hr_rwds_oe_n = '0' else dev_rwds_out;

   dq_mux : for i in 0 to 7 generate
      hr_dq_in(i) <= hr_dq_out(i) when hr_dq_oe_n(i) = '0' else dev_dq_out(i);
   end generate dq_mux;

   i_hyperram : entity work.hyperram
      generic map (
         G_ERRATA_ISSI_D_FIX => true
      )
      port map (
         clk_i               => clk,
         clk_del_i           => clk_del,
         delay_refclk_i      => delay_refclk,
         rst_i                => rst,

         avm_write_i          => avm_write,
         avm_read_i            => avm_read,
         avm_address_i         => avm_address,
         avm_writedata_i       => avm_writedata,
         avm_byteenable_i      => avm_byteenable,
         avm_burstcount_i      => avm_burstcount,
         avm_readdata_o        => avm_readdata,
         avm_readdatavalid_o   => avm_readdatavalid,
         avm_waitrequest_o     => avm_waitrequest,

         count_long_o          => open,
         count_short_o         => open,

         hr_resetn_o           => hr_resetn,
         hr_csn_o              => hr_csn,
         hr_ck_o                => hr_ck,
         hr_rwds_in_i           => hr_rwds_in,
         hr_rwds_out_o          => hr_rwds_out,
         hr_rwds_oe_n_o         => hr_rwds_oe_n,
         hr_dq_in_i             => hr_dq_in,
         hr_dq_out_o            => hr_dq_out,
         hr_dq_oe_n_o           => hr_dq_oe_n
      ); -- i_hyperram

   i_device : entity work.hyperbus_device_model
      generic map (
         G_LATENCY              => 4,
         G_DEVICE_2X_LATENCY    => G_DEVICE_2X_LATENCY,
         G_RWDS_SETTLE_DELAY_NS => G_RWDS_SETTLE_DELAY_NS,
         G_DATA_PATTERN_SEED    => 16#A5A5#
      )
      port map (
         hr_csn_i        => hr_csn,
         hr_ck_i          => hr_ck,
         hr_resetn_i      => hr_resetn,

         hr_rwds_ctrl_i    => hr_rwds_out,
         hr_rwds_oe_n_i    => hr_rwds_oe_n,
         hr_rwds_dev_o     => dev_rwds_out,

         hr_dq_ctrl_i       => hr_dq_out,
         hr_dq_oe_n_i       => hr_dq_oe_n,
         hr_dq_dev_o        => dev_dq_out,

         xfer_done_o        => xfer_done,
         xfer_ok_o          => xfer_ok
      ); -- i_device

   p_monitor : process (clk)
   begin
      if rising_edge(clk) then
         if avm_readdatavalid = '1' then
            report "MONITOR: T=" & time'image(now) & " avm_readdata=" & to_hstring(avm_readdata);
         end if;
      end if;
   end process p_monitor;

   p_stim : process
      variable waited : integer := 0;
   begin
      wait for 20 ns;
      rst <= '1';
      wait for 40 ns;
      rst <= '0';

      -- hyperram_config's own 150us power-up wait, then its CR0 write -
      -- let it finish before issuing our own read (matches how the real
      -- controller is always used - config always runs first).
      wait for 155 us;

      avm_address <= x"00000000";
      avm_read    <= '1';
      wait until rising_edge(clk);
      waited := 0;
      while avm_waitrequest = '1' loop
         wait until rising_edge(clk);
         waited := waited + 1;
         assert waited < 2000
            report "TB_HYPERBUS_MARGIN: FAIL - avm_waitrequest never dropped (request never accepted)"
            severity failure;
      end loop;
      avm_read <= '0';

      waited := 0;
      while avm_readdatavalid = '0' loop
         wait until rising_edge(clk);
         waited := waited + 1;
         assert waited < 2000
            report "TB_HYPERBUS_MARGIN: FAIL - avm_readdatavalid never arrived (delay=" &
                   real'image(G_RWDS_SETTLE_DELAY_NS) & "ns)"
            severity failure;
      end loop;

      if avm_readdata = x"A5A5" then
         report "TB_HYPERBUS_MARGIN_RESULT: delay_ns=" & real'image(G_RWDS_SETTLE_DELAY_NS) &
                " 2x=" & boolean'image(G_DEVICE_2X_LATENCY) &
                " PASS got=" & to_hstring(avm_readdata);
      else
         report "TB_HYPERBUS_MARGIN_RESULT: delay_ns=" & real'image(G_RWDS_SETTLE_DELAY_NS) &
                " 2x=" & boolean'image(G_DEVICE_2X_LATENCY) &
                " FAIL expected=A5A5 got=" & to_hstring(avm_readdata);
      end if;

      wait for 200 ns;
      sim_done <= true;
      wait;
   end process p_stim;

end architecture sim;
