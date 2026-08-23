---------------------------------------------------------------------------------------------------------
-- Sinclair QL for MEGA65 (QL4M65)
--
-- Milestone 3, Fase 1 (2026-08-23, .research/milestone3-memory-speed-plan.md
-- section 2): CPU-facing main RAM, backed by HyperRAM through a private
-- avm_cache instance, replacing dualport_2clk_ram_byteenable (BRAM,
-- 1-cycle synchronous, "milestone 1, 128k, for now" - main.vhd's own
-- comment at the instantiation this replaces).
--
-- NOT a copy of mdv_dpram.vhd's design, on purpose. mdv_dpram.vhd's whole
-- hold-register/settle-counter/periodic-refresh architecture exists to
-- serve a SLOW, TOLERANT client: mdv.v changes its read address once every
-- ~592 ce ticks (~79us real time) and is fine being served a value that is
-- merely "fresh as of a recent refresh", not literally the current
-- HyperRAM content at THIS instant (see that file's own header for the
-- full argument). fx68k is the opposite of that client: it addresses RAM
-- on essentially every bus cycle, and the 68000 DTACKn protocol requires
-- each individual access to be genuinely resolved before the CPU may
-- proceed - there is no such thing as "serve a recent snapshot, refresh in
-- the background" for a CPU read/write. Copying mdv_dpram.vhd's pattern
-- here would be architecturally wrong, not just unnecessary complexity.
--
-- Because there is exactly ONE requester (the CPU - unlike mdv_dpram.vhd's
-- two ports, mdv.v's own read-only playback port and the QNICE loader/
-- flush port, which genuinely need arbitrating against each other), this
-- wrapper needs no arbiter at all: a single small FSM translates fx68k's
-- own bus protocol (cpu_rd_i/cpu_wr_i held as LEVELS for the whole bus
-- cycle, address/data/byteenable stable throughout - main.vhd's existing
-- cpu_rd/cpu_wr/cpu_addr/cpu_dout/cpu_uds/cpu_lds, already shaped exactly
-- like this for the BRAM this replaces) into one-shot avm_cache requests,
-- and reports completion as a LEVEL (cpu_ready_o) held from the moment the
-- access is genuinely done until the CPU itself drops cpu_rd_i/cpu_wr_i -
-- same "level, not pulse" lesson already learned the hard way for mdv1's
-- own q_a_valid_o in M2030-M2032 (a pulse-based "just completed" signal
-- does not compose safely with a client that may re-sample after the pulse
-- has already passed).
--
-- avm_cache protocol timing this FSM relies on (read avm_cache.vhd itself
-- before changing this - it is easy to misread at a glance, and an
-- earlier version of this file got it wrong - see the dispatch-hold note
-- below, found by the isolated simulation in .research/qram-avm-sim/
-- before this ever reached real hardware):
--   - s_avm_waitrequest_o is a COMBINATIONAL function of the CURRENT
--     s_avm_read_i/write_i together with already-REGISTERED state
--     (cache_addr/cache_count/m_avm_write_o/m_avm_read_o from the previous
--     cycle). When avm_cache is genuinely idle (m_avm_write_o/read_o both
--     already '0') it reads '0' on the very first cycle a request is
--     raised, for any request, hit or miss. BUT m_avm_write_o/read_o can
--     still be '1' from a PREVIOUS write that avm_cache itself is still
--     draining to the real backend (its own state stays IDLE_ST
--     immediately after registering a write's master-side dispatch, even
--     though m_avm_write_o stays asserted for as long as the backend's
--     OWN m_avm_waitrequest_i stays high) - while that is happening,
--     s_avm_waitrequest_o correctly reads '1' for any NEW request this
--     wrapper raises. A first version of this FSM pulsed s_avm_write_i/
--     read_i for exactly one cycle and unconditionally assumed
--     acceptance - during back-to-back writes with no idle gap, this
--     silently DROPPED writes issued while avm_cache was still busy
--     draining a previous one (avm_cache's own accept condition is
--     `s_avm_write_i='1' and s_avm_waitrequest_o='0'` - a pulse that lands
--     while waitrequest is still '1' does nothing). Found by the
--     randomised back-to-back test in tb_qram_avm.vhd (addr 2 onward
--     reading back 0x0000 instead of what was written), not by hand-
--     reasoning about the RTL - exactly the point of simulating this in
--     isolation first. Fixed below: this FSM now HOLDS s_avm_write_i/
--     read_i (and address/data/byteenable) stable across a DISPATCH state
--     until s_avm_waitrequest_o is actually observed '0', standard
--     Avalon-MM master behaviour, and only then considers the request
--     accepted.
--   - A WRITE is done as soon as avm_cache accepts it (waitrequest drops
--     with s_avm_write_i asserted) - avm_cache never raises
--     s_avm_readdatavalid_o for a pure write (verified reading
--     avm_cache.vhd: unconditionally cleared at the top of every cycle,
--     only ever set inside read-hit/read-fill branches), so there is no
--     response left to wait for. Same conclusion mdv_dpram.vhd already
--     documented and validated on real hardware for its own port A
--     writes.
--   - A READ is NOT done at accept time. s_avm_readdatavalid_o pulses
--     exactly once, one or more cycles later (one cycle later on a cache
--     hit; after the real HyperRAM burst on a miss), carrying the actual
--     data on s_avm_readdata_o that same cycle.
--
-- Because this wrapper only ever has ONE request in flight (the CPU won't
-- start a new bus cycle until DTACKn - derived from cpu_ready_o here -
-- resolves the current one), there is no dispatch-vs-response ambiguity to
-- resolve the way mdv_dpram.vhd's "owner" tag has to for its two ports.
--
-- Address mapping: G_HMAP_BASE (4kW-block units, see globals.vhd's
-- C_HMAP_QRAM) placed exactly like mdv_dpram.vhd's own G_HMAP_BASE -
-- added, shifted by 12 bits, ahead of the CPU's own word address.
--
-- QL4M65 port done by Jose Daniel Fernandez Santos (dfsantos) in 2026 and
-- licensed under GPL v3
---------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.globals.all;

entity qram_avm is
   generic (
      -- Word address width as seen by the CPU (main.vhd passes
      -- cpu_addr(G_ADDR_WIDTH downto 1)). 2**G_ADDR_WIDTH words are
      -- addressable; Fase 1 instantiates this at 16 (128k bytes, matching
      -- the BRAM it replaces exactly) - Fase 2 (RAM size menu option)
      -- widens it, up to 20 (2048k bytes), without moving G_HMAP_BASE (see
      -- globals.vhd's C_HMAP_QRAM_BLOCKS, already sized for that ceiling).
      G_ADDR_WIDTH : natural := 16;
      G_HMAP_BASE  : std_logic_vector(15 downto 0) := C_HMAP_QRAM
   );
   port (
      clk_i : in std_logic;
      rst_i : in std_logic;

      -- CPU-facing slave port. cpu_rd_i/cpu_wr_i are LEVELS held for the
      -- entire bus cycle (main.vhd's existing cpu_rd/cpu_wr, unchanged -
      -- see main.vhd's own cpu_rd/cpu_wr derivation from cpu_as/cpu_rw/
      -- cpu_uds/cpu_lds), never both '1' at once. cpu_addr_i/cpu_wdata_i/
      -- cpu_be_i must stay stable for as long as cpu_rd_i/cpu_wr_i stays
      -- asserted (already guaranteed - they come straight from fx68k's own
      -- address/data bus, held by the CPU itself until DTACKn resolves the
      -- cycle).
      cpu_addr_i  : in  std_logic_vector(G_ADDR_WIDTH - 1 downto 0);
      cpu_wdata_i : in  std_logic_vector(15 downto 0);
      cpu_be_i    : in  std_logic_vector(1 downto 0);  -- (1)=UDS/high byte, (0)=LDS/low byte - matches main.vhd's cpu_uds & cpu_lds
      cpu_rd_i    : in  std_logic;
      cpu_wr_i    : in  std_logic;
      cpu_rdata_o : out std_logic_vector(15 downto 0);

      -- Level: '1' once THIS access has genuinely completed (write
      -- accepted, or read data valid) - stays '1' until the CPU itself
      -- drops cpu_rd_i/cpu_wr_i (end of its own bus cycle). main.vhd ANDs
      -- this into cpu_dtack alongside ql_timing's own ram_delay_dtack
      -- (contention model), same composition pattern already used there.
      cpu_ready_o : out std_logic;

      -- Avalon-MM master port -> avm_arbit_general (mega65.vhd, alongside
      -- mdv1/mdv2's own master ports) -> avm_fifo CDC -> hr_core_*.
      m_avm_write_o         : out std_logic;
      m_avm_read_o          : out std_logic;
      m_avm_address_o       : out std_logic_vector(31 downto 0);
      m_avm_writedata_o     : out std_logic_vector(15 downto 0);
      m_avm_byteenable_o    : out std_logic_vector(1 downto 0);
      m_avm_burstcount_o    : out std_logic_vector(7 downto 0);
      m_avm_readdata_i      : in  std_logic_vector(15 downto 0) := (others => '0');
      m_avm_readdatavalid_i : in  std_logic := '0';
      m_avm_waitrequest_i   : in  std_logic := '0'
   );
end entity qram_avm;

architecture synthesis of qram_avm is

   constant C_AWIDTH : natural := 32;

   -- Same convention as mdv_dpram.vhd's own C_BASE_ADDR: G_HMAP_BASE is in
   -- 4kW-block units (4096 words = 8KB), so a WORD address is obtained by
   -- appending twelve zero bits (x4096 words) before adding the CPU's own
   -- word address.
   constant C_BASE_ADDR : unsigned(C_AWIDTH - 1 downto 0) :=
      resize(unsigned(G_HMAP_BASE) & "000000000000", C_AWIDTH);

   type t_state is (IDLE, DISPATCH, WAIT_READ, DONE);
   signal state : t_state := IDLE;

   signal s_write         : std_logic := '0';
   signal s_read          : std_logic := '0';
   signal s_address       : std_logic_vector(C_AWIDTH - 1 downto 0) := (others => '0');
   signal s_writedata     : std_logic_vector(15 downto 0) := (others => '0');
   signal s_byteenable    : std_logic_vector(1 downto 0) := (others => '0');
   signal s_waitrequest   : std_logic;
   signal s_readdata      : std_logic_vector(15 downto 0);
   signal s_readdatavalid : std_logic;

   signal req_is_write : std_logic := '0';

begin

   cpu_ready_o <= '1' when state = DONE else '0';

   i_avm_cache : entity work.avm_cache
      generic map (
         G_CACHE_SIZE   => 8,
         G_ADDRESS_SIZE => C_AWIDTH,
         G_DATA_SIZE    => 16
      )
      port map (
         clk_i                 => clk_i,
         rst_i                 => rst_i,
         s_avm_waitrequest_o   => s_waitrequest,
         s_avm_write_i         => s_write,
         s_avm_read_i          => s_read,
         s_avm_address_i       => s_address,
         s_avm_writedata_i     => s_writedata,
         s_avm_byteenable_i    => s_byteenable,
         s_avm_burstcount_i    => x"01",
         s_avm_readdata_o      => s_readdata,
         s_avm_readdatavalid_o => s_readdatavalid,
         m_avm_waitrequest_i   => m_avm_waitrequest_i,
         m_avm_write_o         => m_avm_write_o,
         m_avm_read_o          => m_avm_read_o,
         m_avm_address_o       => m_avm_address_o,
         m_avm_writedata_o     => m_avm_writedata_o,
         m_avm_byteenable_o    => m_avm_byteenable_o,
         m_avm_burstcount_o    => m_avm_burstcount_o,
         m_avm_readdata_i      => m_avm_readdata_i,
         m_avm_readdatavalid_i => m_avm_readdatavalid_i
      );

   p_fsm : process (clk_i)
   begin
      if rising_edge(clk_i) then
         case state is
            when IDLE =>
               s_write <= '0';
               s_read  <= '0';
               if cpu_wr_i = '1' then
                  s_write      <= '1';
                  s_address    <= std_logic_vector(C_BASE_ADDR + resize(unsigned(cpu_addr_i), C_AWIDTH));
                  s_writedata  <= cpu_wdata_i;
                  s_byteenable <= cpu_be_i;
                  req_is_write <= '1';
                  state        <= DISPATCH;
               elsif cpu_rd_i = '1' then
                  s_read       <= '1';
                  s_address    <= std_logic_vector(C_BASE_ADDR + resize(unsigned(cpu_addr_i), C_AWIDTH));
                  s_byteenable <= "11";
                  req_is_write <= '0';
                  state        <= DISPATCH;
               end if;

            -- Hold the request (and address/data/byteenable, unchanged
            -- since IDLE) asserted until avm_cache actually reports
            -- acceptance (s_waitrequest='0' - standard Avalon-MM master
            -- behaviour). Do NOT assume acceptance from a single pulse -
            -- see this entity's own header for the real bug that mistake
            -- caused, found in simulation.
            when DISPATCH =>
               if s_waitrequest = '0' then
                  s_write <= '0';
                  s_read  <= '0';
                  if req_is_write = '1' then
                     state <= DONE;
                  else
                     state <= WAIT_READ;
                  end if;
               end if;

            -- Write already accepted in DISPATCH - only reads reach here,
            -- waiting for the actual data (see this entity's own header:
            -- acceptance and data-valid are two separate events for a
            -- read, never for a write).
            when WAIT_READ =>
               if s_readdatavalid = '1' then
                  cpu_rdata_o <= s_readdata;
                  state       <= DONE;
               end if;

            -- Hold ready asserted until the CPU itself ends this bus
            -- cycle - same "level, not pulse" shape as mdv1's own
            -- q_a_valid_o (M2030-M2032).
            when DONE =>
               if cpu_rd_i = '0' and cpu_wr_i = '0' then
                  state <= IDLE;
               end if;
         end case;

         if rst_i = '1' then
            state   <= IDLE;
            s_write <= '0';
            s_read  <= '0';
         end if;
      end if;
   end process p_fsm;

end architecture synthesis;
