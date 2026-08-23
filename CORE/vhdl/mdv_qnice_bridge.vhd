---------------------------------------------------------------------------------------------------------
-- Sinclair QL for MEGA65 (QL4M65)
--
-- QL4M65 Milestone 2 paso 5, etapa 2 (2026-08-23,
-- .research/microdrive-second-unit-plan.md section 2.1): QNICE<->core
-- bridge for ONE microdrive's buffer - image load (QNICE -> core) and
-- byte/dirty-bitmap read-back (core -> QNICE, for the SD flush). Extracted
-- verbatim from main.vhd's own mdv1-specific code (M2004-M2032, three
-- real hardware bugs found and fixed along the way - M2027's wait_o
-- one-request-behind, M2031's fixed-2-cycle read wait, M2032's pulse-vs-
-- level q_a_valid), made reusable by generalizing port names only - the
-- internal logic, timing, and CDC discipline are UNCHANGED from what
-- M2030-M2033 already confirmed on real hardware. Deliberately has NO
-- generics: the two QNICE-address-space constants this logic depends on
-- (C_MDV1_DIRTY_BASE/C_MDV1_DIRTY_CLR, globals.vhd) are offsets WITHIN a
-- device's own QNICE window (0x0000000 upward), not global addresses -
-- every microdrive's own window starts fresh at 0, so the exact same
-- constants apply unchanged to any instance of this entity, whichever
-- QNICE device ID (C_DEV_QL_MDV1, C_DEV_QL_MDV2, ...) mega65.vhd decodes
-- into its qnice_ce_i/we_i.
--
-- Instantiated once per microdrive (i_mdv1_bridge, i_mdv2_bridge, ... in
-- main.vhd) - main.vhd wires each instance to that drive's own dl_*
-- ports on its own mdv.v sibling, its own dirty bitmap (p_dirtyN, still
-- living in main.vhd itself - NOT moved into this entity, since dirty
-- tracking is driven by the QL CPU's own writes via wr_commit/sector,
-- nothing to do with QNICE), and its own qnice_mdvN_*_i/o ports (in turn
-- wired to that drive's own QNICE device-ID branch and qnice_csr instance
-- in mega65.vhd).
--
-- QL4M65 port done by Jose Daniel Fernandez Santos (dfsantos) in 2026 and
-- licensed under GPL v3
---------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.globals.all;

library xpm;
use xpm.vcomponents.all;

entity mdv_qnice_bridge is
   port (
      -- QNICE-side device window (qnice_clk_i domain) - main.vhd wires
      -- these straight to whichever qnice_mdvN_*_i/o ports this instance
      -- corresponds to (see that entity's own header).
      qnice_clk_i     : in  std_logic;
      qnice_rst_i     : in  std_logic;
      qnice_addr_i    : in  std_logic_vector(27 downto 0);
      qnice_data_i    : in  std_logic_vector(15 downto 0);
      qnice_ce_i      : in  std_logic;
      qnice_we_i      : in  std_logic;
      qnice_wait_o    : out std_logic;
      qnice_data_o    : out std_logic_vector(15 downto 0);

      -- raw QNICE-domain "is a load currently in progress" level, from
      -- this drive's own qnice_csr instance (mega65.vhd) - synchronized
      -- into clk_main_i inside this entity, same as main.vhd always did.
      qnice_loading_i : in  std_logic;

      -- core-side (clk_main_i domain)
      clk_main_i : in  std_logic;
      reset_i    : in  std_logic;

      -- this drive's own mdv.v sibling's port A / download interface
      download_o   : out std_logic;
      dl_addr_o    : out std_logic_vector(16 downto 0);
      dl_data_o    : out std_logic_vector(15 downto 0);
      dl_wr_o      : out std_logic;
      dl_q_i       : in  std_logic_vector(15 downto 0);
      dl_q_valid_i : in  std_logic;

      -- this drive's own dirty-sector bitmap (owned by main.vhd's own
      -- per-drive p_dirtyN process, NOT by this entity - see header)
      dirty_i       : in  std_logic_vector(255 downto 0);
      dirty_clear_o : out std_logic
   );
end entity mdv_qnice_bridge;

architecture synthesis of mdv_qnice_bridge is

   -- QNICE-clock-domain side of the loader handshake
   signal ld_byte0     : std_logic_vector(7 downto 0);
   signal ld_word_addr : std_logic_vector(16 downto 0);
   signal ld_word_data : std_logic_vector(15 downto 0);
   signal ld_send      : std_logic := '0';  -- level-held, needs a defined power-on value
   signal ld_busy      : std_logic := '0';  -- '1' for the whole handshake - drives qnice_wait_o

   signal cdc_src_in   : std_logic_vector(32 downto 0);
   signal cdc_src_rcv  : std_logic;
   signal cdc_dest_req : std_logic;
   signal cdc_dest_ack : std_logic := '0';  -- level-held, needs a defined power-on value
   signal cdc_dest_out : std_logic_vector(32 downto 0);

   type t_ld_state is (LD_IDLE, LD_WAIT_REQ_LOW);
   signal ld_state : t_ld_state := LD_IDLE;

   -- core-clock-domain side of the loader
   signal ld_dl_addr : std_logic_vector(16 downto 0);
   signal dl_data_i_reg : std_logic_vector(15 downto 0);

   -- qnice_loading_i synchronized into clk_main_i
   signal loading_sync : std_logic;

   -- dirty-bitmap clear detection (QNICE level -> core edge)
   signal clear_req       : std_logic;  -- QNICE domain, level
   signal clear_sync      : std_logic;  -- core domain, synchronized level
   signal clear_sync_prev : std_logic := '0';

   -- read-back path (QNICE clock domain side)
   signal rd_addr    : std_logic_vector(27 downto 0);
   signal rd_send    : std_logic := '0';

   signal cdc_req_src_rcv  : std_logic;
   signal cdc_req_dest_req : std_logic;
   signal cdc_req_dest_ack : std_logic := '0';
   signal cdc_req_dest_out : std_logic_vector(27 downto 0);

   signal rd_result_send : std_logic := '0';
   signal rd_result_data : std_logic_vector(15 downto 0);

   signal cdc_resp_src_rcv  : std_logic;
   signal cdc_resp_dest_req : std_logic;
   signal cdc_resp_dest_ack : std_logic := '0';
   signal cdc_resp_dest_out : std_logic_vector(15 downto 0);

   type t_rd_state is (RD_IDLE, RD_SEND_WAIT_RCV, RD_SEND_WAIT_RCV_LOW, RD_WAIT_RESP, RD_RESP_WAIT_LOW);
   signal rd_state : t_rd_state := RD_IDLE;

   signal rd_req_prev : std_logic := '0';

   -- read-back path (core clock domain side)
   type t_rdcore_state is (RDC_IDLE, RDC_REQ_WAIT_LOW, RDC_LATCH1, RDC_LATCH2, RDC_SEND_WAIT_RCV, RDC_SEND_WAIT_RCV_LOW);
   signal rdcore_state : t_rdcore_state := RDC_IDLE;
   signal rd_req_addr  : std_logic_vector(27 downto 0);
   signal rd_dl_addr   : std_logic_vector(16 downto 0);

   signal qnice_data_o_i : std_logic_vector(15 downto 0);

begin

   ---------------------------------------------------------------------------
   -- wait_o: covers both the loader (registered mdv1_ld_busy-equivalent -
   -- a write's DATA is captured unconditionally on the very first
   -- ce_i/we_i cycle regardless of wait_o, so nothing to race there) and
   -- the read-back path (needs a LIVE, non-registered contribution -
   -- M2027's own root cause: QNICE's cs_exeprep_get_src_indirect checks
   -- WAIT_FOR_DATA the SAME cycle it asserts ce_i/addr for an indirect
   -- read, no extra setup cycle - qualified with rd_req_prev='0' so it
   -- only fires on a genuine rising edge, not a held level, matching
   -- M2006's own lesson about the opposite mistake). See DECISIONES.md's
   -- M2004-M2027 sections for the full history behind every rule here.
   ---------------------------------------------------------------------------
   qnice_wait_o <= '1' when (ld_busy = '1' or rd_state /= RD_IDLE or
                              (qnice_ce_i = '1' and qnice_we_i = '0' and rd_req_prev = '0'))
                   else '0';

   p_rd_edge : process (qnice_clk_i)
   begin
      if rising_edge(qnice_clk_i) then
         rd_req_prev <= qnice_ce_i and not qnice_we_i;
      end if;
   end process p_rd_edge;

   ---------------------------------------------------------------------------
   -- Loader: QNICE writes byte pairs, forwarded to the core clock domain
   -- via a level-held 4-phase xpm_cdc_handshake (both sides reset from day
   -- one - M2017: an interrupted handshake mid-transaction used to wedge
   -- ld_busy permanently, recoverable only by a power cycle).
   ---------------------------------------------------------------------------

   loader_qnice : process (qnice_clk_i)
   begin
      if rising_edge(qnice_clk_i) then
         if qnice_rst_i = '1' then
            ld_busy <= '0';
            ld_send <= '0';
         elsif ld_busy = '0' then
            if qnice_ce_i = '1' and qnice_we_i = '1' then
               if qnice_addr_i(0) = '0' then
                  -- even address: first byte of the pair, just latch it
                  ld_byte0 <= qnice_data_i(7 downto 0);
               else
                  -- odd address: second byte - assemble the word and start
                  -- the handshake (src_send asserted and held, see above)
                  ld_word_addr <= qnice_addr_i(17 downto 1);
                  ld_word_data <= ld_byte0 & qnice_data_i(7 downto 0);
                  ld_send      <= '1';
                  ld_busy      <= '1';
               end if;
            end if;
         elsif ld_send = '1' then
            -- handshake in flight: drop send once the core side confirms
            -- receipt (src_rcv='1') - do NOT drop it any earlier
            if cdc_src_rcv = '1' then
               ld_send <= '0';
            end if;
         else
            -- send already dropped: wait for src_rcv to also drop before
            -- allowing the next byte-pair's handshake to start
            if cdc_src_rcv = '0' then
               ld_busy <= '0';
            end if;
         end if;
      end if;
   end process loader_qnice;

   cdc_src_in <= ld_word_addr & ld_word_data;

   i_loader_cdc : xpm_cdc_handshake
      generic map (
         DEST_EXT_HSK => 1,
         WIDTH        => 33
      )
      port map (
         src_clk  => qnice_clk_i,
         src_in   => cdc_src_in,
         src_send => ld_send,
         src_rcv  => cdc_src_rcv,

         dest_clk => clk_main_i,
         dest_req => cdc_dest_req,
         dest_ack => cdc_dest_ack,
         dest_out => cdc_dest_out
      ); -- i_loader_cdc

   -- Core-clock-domain side: on dest_req, drive this drive's own dl_addr/
   -- dl_data for one cycle with dl_wr asserted. dest_ack must be asserted
   -- and HELD until dest_req drops back to '0' (xpm_cdc_handshake's own
   -- documented 4-phase protocol, not a one-cycle pulse).
   loader_core : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         dl_wr_o <= '0';

         if reset_i = '1' then
            cdc_dest_ack <= '0';
            ld_state     <= LD_IDLE;
         else
            case ld_state is
               when LD_IDLE =>
                  if cdc_dest_req = '1' then
                     ld_dl_addr    <= cdc_dest_out(32 downto 16);
                     dl_data_i_reg <= cdc_dest_out(15 downto 0);
                     dl_wr_o       <= '1';
                     cdc_dest_ack  <= '1';
                     ld_state      <= LD_WAIT_REQ_LOW;
                  end if;

               when LD_WAIT_REQ_LOW =>
                  if cdc_dest_req = '0' then
                     cdc_dest_ack <= '0';
                     ld_state     <= LD_IDLE;
                  end if;
            end case;
         end if;
      end if;
   end process loader_core;

   dl_data_o <= dl_data_i_reg;

   -- QL4M65 (M2011): mdv.v's `download` must be a LEVEL held for the whole
   -- transfer, not a one-shot pulse - see main.vhd's own original comment
   -- (kept verbatim there, this is the mechanical CDC only).
   i_loading_cdc : xpm_cdc_single
      generic map (
         DEST_SYNC_FF   => 4,
         INIT_SYNC_FF   => 0,
         SIM_ASSERT_CHK => 0,
         SRC_INPUT_REG  => 1
      )
      port map (
         src_clk  => qnice_clk_i,
         src_in   => qnice_loading_i,
         dest_clk => clk_main_i,
         dest_out => loading_sync
      ); -- i_loading_cdc

   download_o <= loading_sync;

   ---------------------------------------------------------------------------
   -- Dirty-bitmap clear: QNICE writes any value to (window-relative)
   -- C_MDV1_DIRTY_CLR. Rising-edge detection on the synchronized level
   -- turns however-long QNICE holds ce_i/we_i into exactly one clear pulse
   -- (same lesson as rtl/mdv.v's own wr_strobe_prev, M2023/M2024).
   ---------------------------------------------------------------------------

   clear_req <= '1' when (qnice_ce_i = '1' and qnice_we_i = '1'
                          and unsigned(qnice_addr_i) = to_unsigned(C_MDV1_DIRTY_CLR, 28))
                else '0';

   i_clear_cdc : xpm_cdc_single
      generic map (
         DEST_SYNC_FF   => 4,
         INIT_SYNC_FF   => 0,
         SIM_ASSERT_CHK => 0,
         SRC_INPUT_REG  => 1
      )
      port map (
         src_clk  => qnice_clk_i,
         src_in   => clear_req,
         dest_clk => clk_main_i,
         dest_out => clear_sync
      ); -- i_clear_cdc

   p_clear_edge : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         clear_sync_prev <= clear_sync;
      end if;
   end process p_clear_edge;

   dirty_clear_o <= clear_sync and not clear_sync_prev;

   ---------------------------------------------------------------------------
   -- Read-back path: QNICE requests a byte (buffer or dirty bitmap), core
   -- answers. Two xpm_cdc_handshake instances, same 4-phase discipline as
   -- the loader above (level-held send/ack, wait_o from registered state
   -- only, reset from day one on BOTH sides).
   ---------------------------------------------------------------------------

   qnice_data_o <= qnice_data_o_i;

   reader_qnice : process (qnice_clk_i)
   begin
      if rising_edge(qnice_clk_i) then
         if qnice_rst_i = '1' then
            rd_state <= RD_IDLE;
            rd_send  <= '0';
         else
            case rd_state is
               when RD_IDLE =>
                  if qnice_ce_i = '1' and qnice_we_i = '0' then
                     rd_addr  <= qnice_addr_i;
                     rd_send  <= '1';
                     rd_state <= RD_SEND_WAIT_RCV;
                  end if;

               when RD_SEND_WAIT_RCV =>
                  if cdc_req_src_rcv = '1' then
                     rd_send  <= '0';
                     rd_state <= RD_SEND_WAIT_RCV_LOW;
                  end if;

               when RD_SEND_WAIT_RCV_LOW =>
                  if cdc_req_src_rcv = '0' then
                     rd_state <= RD_WAIT_RESP;
                  end if;

               when RD_WAIT_RESP =>
                  if cdc_resp_dest_req = '1' then
                     qnice_data_o_i  <= cdc_resp_dest_out;
                     cdc_resp_dest_ack <= '1';
                     rd_state <= RD_RESP_WAIT_LOW;
                  end if;

               when RD_RESP_WAIT_LOW =>
                  if cdc_resp_dest_req = '0' then
                     cdc_resp_dest_ack <= '0';
                     rd_state <= RD_IDLE;
                  end if;
            end case;
         end if;
      end if;
   end process reader_qnice;

   i_read_req_cdc : xpm_cdc_handshake
      generic map (
         DEST_EXT_HSK => 1,
         WIDTH        => 28
      )
      port map (
         src_clk  => qnice_clk_i,
         src_in   => rd_addr,
         src_send => rd_send,
         src_rcv  => cdc_req_src_rcv,

         dest_clk => clk_main_i,
         dest_req => cdc_req_dest_req,
         dest_ack => cdc_req_dest_ack,
         dest_out => cdc_req_dest_out
      ); -- i_read_req_cdc

   i_read_resp_cdc : xpm_cdc_handshake
      generic map (
         DEST_EXT_HSK => 1,
         WIDTH        => 16
      )
      port map (
         src_clk  => clk_main_i,
         src_in   => rd_result_data,
         src_send => rd_result_send,
         src_rcv  => cdc_resp_src_rcv,

         dest_clk => qnice_clk_i,
         dest_req => cdc_resp_dest_req,
         dest_ack => cdc_resp_dest_ack,
         dest_out => cdc_resp_dest_out
      ); -- i_read_resp_cdc

   -- Core-clock-domain side: on a request, latch the address, drive this
   -- drive's own dl_addr for a buffer read (harmless to do even for a
   -- bitmap request - dl_wr stays '0'), wait for dl_q_valid_i (the dpram's
   -- own "q_a just became fresh for this address" level - M2031/M2032:
   -- NOT a fixed cycle count, NOT a one-shot pulse), then pick the byte
   -- from either dl_q_i (buffer) or dirty_i (bitmap, 8 bits per byte
   -- index) and send it back.
   reader_core : process (clk_main_i)
      variable v_bm_idx : integer range 0 to 31;
   begin
      if rising_edge(clk_main_i) then
         if reset_i = '1' then
            cdc_req_dest_ack <= '0';
            rd_result_send   <= '0';
            rdcore_state     <= RDC_IDLE;
         else
            case rdcore_state is
               when RDC_IDLE =>
                  if cdc_req_dest_req = '1' then
                     rd_req_addr      <= cdc_req_dest_out;
                     rd_dl_addr       <= cdc_req_dest_out(17 downto 1);
                     cdc_req_dest_ack <= '1';
                     rdcore_state     <= RDC_REQ_WAIT_LOW;
                  end if;

               when RDC_REQ_WAIT_LOW =>
                  if cdc_req_dest_req = '0' then
                     cdc_req_dest_ack <= '0';
                     rdcore_state     <= RDC_LATCH1;
                  end if;

               when RDC_LATCH1 =>
                  if dl_q_valid_i = '1' then
                     rdcore_state <= RDC_LATCH2;
                  end if;

               when RDC_LATCH2 =>
                  if unsigned(rd_req_addr) >= C_MDV1_DIRTY_BASE and
                     unsigned(rd_req_addr) < C_MDV1_DIRTY_BASE + 32 then
                     -- dirty bitmap: byte index 0..31 straight from the low
                     -- 5 bits (C_MDV1_DIRTY_BASE is 32-byte aligned)
                     v_bm_idx := to_integer(unsigned(rd_req_addr(4 downto 0)));
                     rd_result_data <= x"00" & dirty_i(v_bm_idx * 8 + 7 downto v_bm_idx * 8);
                  elsif rd_req_addr(0) = '0' then
                     rd_result_data <= x"00" & dl_q_i(15 downto 8);
                  else
                     rd_result_data <= x"00" & dl_q_i(7 downto 0);
                  end if;
                  rd_result_send <= '1';
                  rdcore_state   <= RDC_SEND_WAIT_RCV;

               when RDC_SEND_WAIT_RCV =>
                  -- rd_result_send: not reassigned here, so it simply holds
                  -- '1' (same "hold by omission" idiom as the loader's own
                  -- ld_send in its equivalent state)
                  if cdc_resp_src_rcv = '1' then
                     rd_result_send <= '0';
                     rdcore_state   <= RDC_SEND_WAIT_RCV_LOW;
                  end if;

               when RDC_SEND_WAIT_RCV_LOW =>
                  if cdc_resp_src_rcv = '0' then
                     rdcore_state <= RDC_IDLE;
                  end if;
            end case;
         end if;
      end if;
   end process reader_core;

   -- Port A address mux: the loader (writes) and the reader both need to
   -- drive this drive's own dl_addr, but never at the same time in
   -- practice (QNICE's own bus is inherently sequential - a load and a
   -- read-back can't be in flight together). Give the reader priority
   -- whenever its own state machine is active; the loader otherwise. Same
   -- "two logical owners, one mux" pattern as mdv.v's own wr_do/dl_wr
   -- priority mux (M2022, design doc S3.5).
   dl_addr_o <= rd_dl_addr when rdcore_state /= RDC_IDLE else ld_dl_addr;

end architecture synthesis;
