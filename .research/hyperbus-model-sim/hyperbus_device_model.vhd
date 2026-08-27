-- QL4M65 R3 investigation (2026-08-27): behavioral HyperBus DEVICE-side
-- model, for testing hyperram_ctrl.vhd's SAMPLE_RWDS_ST margin (the
-- latency-mode decision) against a real device's own RWDS timing - the H1
-- concern from the round-3 review (Agente A): a device whose RWDS
-- transition, during the CA phase, lands close to the controller's fixed
-- sampling point could get mis-sampled, deterministically, on every single
-- transaction from that specific physical die - which would explain a
-- 100%-reproducible (not marginal) symptom that only shows up on one board
-- revision if that revision's real chip happens to transition RWDS at a
-- different point relative to CS# than the other.
--
-- This is NOT a generic AVM-level fake (like fake_avm_backend.vhd, used
-- elsewhere in this project's own sim work) - it plugs into the REAL
-- hr_* pins of the REAL, unmodified hyperram.vhd (which in turn
-- instantiates the real hyperram_ctrl/tx/rx/config/errata - the exact RTL
-- that ships), so whatever this finds is a property of the real
-- controller, not of a simplified model.
--
-- Deliberately narrow scope: this model does NOT implement the full
-- HyperBus command set (register writes, wrapped bursts, etc.) - only
-- what's needed to drive one linear read transaction end to end and
-- measure whether it comes back correct, for a given RWDS transition
-- timing. G_LATENCY must match hyperram.vhd's own C_LATENCY (4, hardcoded
-- there) for the wait-cycle counting below to line up with what the real
-- controller expects.
--
-- Timing note (found the hard way, see this file's own git history):
-- hyperram_rx.vhd captures DQ on BOTH edges of the (delayed) RWDS signal
-- (`c => not rwds_in_delay` feeding an IDDR) - a real chip toggles RWDS
-- at the full DDR rate (twice per hr_ck_i cycle), not once. The data
-- phase below is driven from a process sensitive to BOTH edges of
-- hr_ck_i for exactly that reason - an earlier version only toggled on
-- rising edges and no data ever arrived (avm_readdatavalid never fired).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity hyperbus_device_model is
   generic (
      G_LATENCY              : natural := 4;     -- must match hyperram.vhd's C_LATENCY
      G_DEVICE_2X_LATENCY    : boolean := false;  -- true = device asserts RWDS high through CA (2x latency needed), false = 1x
      G_RWDS_SETTLE_DELAY_NS : real    := 2.0;    -- how long after CS# falls the device's RWDS output reflects its real latency decision - THE swept variable
      G_DATA_PATTERN_SEED    : natural := 16#A5A5#
   );
   port (
      -- Device-side pins (mirror of hyperram.vhd's own hr_* ports, from
      -- the chip's point of view - driven/observed directly, no real
      -- tri-state resolution needed since the testbench wires each pin
      -- through an explicit oe_n-based mux, same pattern as a real IOBUF).
      hr_csn_i       : in    std_logic;
      hr_ck_i        : in    std_logic;
      hr_resetn_i    : in    std_logic;

      hr_rwds_ctrl_i    : in  std_logic;  -- controller's own RWDS drive (valid only while hr_rwds_oe_n_i='0')
      hr_rwds_oe_n_i    : in  std_logic;  -- controller's RWDS output-enable (active low) - '0' = controller drives, '1' = device's turn
      hr_rwds_dev_o     : out std_logic;  -- device's own RWDS drive (only meaningful while hr_rwds_oe_n_i='1')

      hr_dq_ctrl_i      : in  std_logic_vector(7 downto 0);  -- controller's own DQ drive
      hr_dq_oe_n_i      : in  std_logic_vector(7 downto 0);  -- controller's DQ output-enable (active low), all 8 bits ganged in practice
      hr_dq_dev_o       : out std_logic_vector(7 downto 0);  -- device's own DQ drive

      -- Test result reporting
      xfer_done_o    : out   std_logic := '0';  -- pulses once per completed read transaction
      xfer_ok_o      : out   std_logic := '0'   -- valid the same cycle as xfer_done_o
   );
end entity hyperbus_device_model;

architecture sim of hyperbus_device_model is

   type   t_state is (ST_IDLE, ST_CA, ST_LATENCY, ST_DATA);
   signal state : t_state := ST_IDLE;

   signal ck_count     : natural := 0;
   signal latency_left : integer := 0;

   -- Single driver each: p_rwds_ca drives rwds_ca_level (CA-phase latency
   -- indicator only), p_data_strobe drives rwds_data_level/dq_drive (data
   -- phase only) - combined into the real output pin by a plain
   -- concurrent mux below, avoiding the two-drivers-on-one-signal bug an
   -- earlier version of this file hit at elaboration.
   signal rwds_ca_level   : std_logic := '1';
   signal rwds_data_level : std_logic := '1';
   signal dq_drive        : std_logic_vector(7 downto 0) := (others => '0');

   -- Deterministic pseudo-data pattern, so a received burst can be checked
   -- word-by-word against what SHOULD have arrived.
   impure function next_word(seed : natural; idx : natural) return std_logic_vector is
      variable v : unsigned(15 downto 0);
   begin
      v := to_unsigned((seed + idx * 4099) mod 65536, 16);
      return std_logic_vector(v);
   end function;

   signal word_idx  : natural := 0;
   signal data_beat : natural := 0;  -- 0 or 1 within a word (high byte first, DDR)

begin

   -- RWDS during CA phase only: high impedance from the device's point of
   -- view until CS# has been low for G_RWDS_SETTLE_DELAY_NS - real chips
   -- don't commit to a final RWDS value instantly at CS#'s falling edge
   -- either (internal refresh-pending decision + pad delay) - THIS delay,
   -- swept across runs, is the actual experiment.
   p_rwds_ca : process
   begin
      rwds_ca_level <= '1';  -- HyperBus devices default to asserting RWDS (busy/2x) until they've decided otherwise
      wait until hr_csn_i = '0';
      wait for G_RWDS_SETTLE_DELAY_NS * 1 ns;
      if G_DEVICE_2X_LATENCY then
         rwds_ca_level <= '1';
      else
         rwds_ca_level <= '0';
      end if;
      wait until hr_csn_i = '1';
   end process p_rwds_ca;

   hr_rwds_dev_o <= rwds_ca_level when state /= ST_DATA else rwds_data_level;
   hr_dq_dev_o   <= dq_drive;

   -- FSM / CA / latency / data phase - ALL in one process. This must NOT
   -- be split across two processes reacting separately to "state" (an
   -- earlier version did exactly that, with a second process testing
   -- `state = ST_DATA`): a process that only READS a signal another
   -- process just assigned, on the SAME clock edge, sees the signal's
   -- PRE-update value (VHDL signals only take their new value after the
   -- delta cycle completes) - so the "just entered ST_DATA" check was
   -- always one edge late, and the very first data byte got sampled by
   -- the real controller as whatever dq_drive/rwds_data_level happened to
   -- be left at, not the intended first-word value. Symptom seen:
   -- avm_readdata came back as 00A5 instead of A5A5 - low byte (second
   -- DDR beat, correctly timed one process-activation later) right, high
   -- byte (first beat, the one needing same-edge state+data consistency)
   -- wrong. Keeping the whole FSM in one process makes the ST_LATENCY ->
   -- ST_DATA transition and the first byte's dq_drive assignment part of
   -- the exact same signal-assignment set, eliminating the race.
   p_ck : process (hr_ck_i, hr_resetn_i, hr_csn_i)
   begin
      if hr_resetn_i = '0' then
         state            <= ST_IDLE;
         ck_count         <= 0;
         latency_left     <= 0;
         rwds_data_level  <= '1';
         word_idx         <= 0;
         data_beat        <= 0;
         dq_drive         <= (others => '0');
         xfer_done_o      <= '0';
      elsif falling_edge(hr_csn_i) then
         state    <= ST_CA;
         ck_count <= 0;
      elsif rising_edge(hr_ck_i) then
         xfer_done_o <= '0';

         case state is
            when ST_IDLE =>
               null;

            when ST_CA =>
               ck_count <= ck_count + 1;
               if ck_count = 2 then  -- 3 CA words clocked in (0,1,2) - matches ca_count starting at 2 in hyperram_ctrl.vhd
                  ck_count <= 0;
                  -- Must land ST_DATA on the EXACT same cycle
                  -- hyperram_ctrl.vhd's own READ_ST begins, derived
                  -- directly from that FSM's source (SAMPLE_RWDS_ST sets
                  -- latency_count to 2*G_LATENCY-4 (2x) or G_LATENCY-4
                  -- (1x); LATENCY_ST then takes latency_count+1 cycles;
                  -- plus the fixed 3 CA + 1 WAIT_ST + 1 SAMPLE_RWDS_ST = 5
                  -- cycles before LATENCY_ST is even entered). Working
                  -- backwards the same way for THIS process (ST_LATENCY
                  -- entered here, one cycle after this ck_count=2 edge,
                  -- taking latency_left+1 cycles): latency_left =
                  -- (2*G_LATENCY-2) for 2x, (G_LATENCY-2) for 1x.
                  if G_DEVICE_2X_LATENCY then
                     latency_left <= 2 * G_LATENCY - 2;
                  else
                     latency_left <= G_LATENCY - 2;
                  end if;
                  state <= ST_LATENCY;
               end if;

            when ST_LATENCY =>
               if latency_left > 0 then
                  latency_left <= latency_left - 1;
               else
                  -- Enter the data phase: deliver the FIRST byte right
                  -- here, in the same signal-assignment set as the state
                  -- transition itself - no separate process, no lag.
                  -- rwds_data_level is forced to the OPPOSITE of
                  -- rwds_ca_level here so the mux output always produces
                  -- a genuine edge at this exact transition, regardless
                  -- of latency mode - that edge is what a real device's
                  -- IDDR-facing RWDS strobe uses to mark "first byte
                  -- ready", and hyperram_rx.vhd's IDDR needs an actual
                  -- transition to capture on. Bug this caught: in 1x mode
                  -- rwds_ca_level had already dropped to '0' during CA,
                  -- so leaving rwds_data_level at its '1' reset default
                  -- happened to produce an edge by coincidence and the
                  -- first read passed; in 2x mode rwds_ca_level stays '1'
                  -- through the whole CA/latency phase (that's the point
                  -- of 2x - RWDS signals "busy" the entire time), which
                  -- matched rwds_data_level's own '1' reset default with
                  -- NO edge at all - every 2x-mode read failed, at every
                  -- settle delay including 0ns, until this line was added.
                  state           <= ST_DATA;
                  word_idx        <= 0;
                  data_beat       <= 0;
                  rwds_data_level <= not rwds_ca_level;
                  dq_drive        <= next_word(G_DATA_PATTERN_SEED, 0)(15 downto 8);
               end if;

            when ST_DATA =>
               -- A rising edge while ALREADY in ST_DATA (i.e. not the
               -- entry edge above, which came via the ST_LATENCY branch)
               -- - this is a normal second-or-later DDR beat.
               rwds_data_level <= not rwds_data_level;
               if data_beat = 0 then
                  dq_drive  <= next_word(G_DATA_PATTERN_SEED, word_idx)(7 downto 0);
                  data_beat <= 1;
               else
                  data_beat <= 0;
                  word_idx  <= word_idx + 1;
                  dq_drive  <= next_word(G_DATA_PATTERN_SEED, word_idx + 1)(15 downto 8);
               end if;

         end case;
      elsif falling_edge(hr_ck_i) then
         -- The other half of each DDR beat pair. By the time this fires,
         -- any ST_LATENCY->ST_DATA transition from the paired rising edge
         -- has already settled (this is a genuinely later simulation
         -- time, not the same delta), so reading `state` here is safe.
         if state = ST_DATA then
            rwds_data_level <= not rwds_data_level;
            if data_beat = 0 then
               dq_drive  <= next_word(G_DATA_PATTERN_SEED, word_idx)(7 downto 0);
               data_beat <= 1;
            else
               data_beat <= 0;
               word_idx  <= word_idx + 1;
               dq_drive  <= next_word(G_DATA_PATTERN_SEED, word_idx + 1)(15 downto 8);
            end if;
         end if;
      end if;
   end process p_ck;

end architecture sim;
