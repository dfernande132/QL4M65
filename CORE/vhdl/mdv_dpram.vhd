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
-- Milestone 2 phase B (write support) - see .research/microdrive-write-design.md
-- section 3.5. Port A gains a read output (q_a, wired to a_q_o - previously
-- "open" since only the loader ever wrote through port A and nothing ever
-- needed to read it back). mdv.v's own instantiation connects it by name as
-- q_a, so port order below doesn't matter, but the entity and this instance
-- must agree on the name.
--
-- Milestone 2 phase C, etapa B (buffer -> HyperRAM) - see DECISIONES.md's
-- "migración del buffer de mdv1 a HyperRAM" section. Direct BRAM
-- (dualport_2clk_ram_byteenable) replaced by a protocol-translation layer
-- in front of a single shared avm_cache (M2M/vhdl/memory/avm_cache.vhd,
-- unmodified), whose own Avalon-MM master reaches out through nine
-- mechanical pass-through ports added to mdv.v (m_avm_*, same
-- "pass-through only, zero logic change" pattern already used for
-- zx8302.v's mdv_wr_*/mdv_er_en_o ports in M2022 - see
-- doc/m2m/exceptions.md) and on through main.vhd/mega65.vhd's avm_fifo CDC
-- to the framework's real hr_core_* HyperRAM port. Exhaustively verified in
-- isolated simulation first (.research/hyperram-migration-sim/, backend
-- latency stress-tested to 200 cycles, three real bugs found and fixed
-- there before this file existed) - see DECISIONES.md for the full
-- writeup, including two bugs that are NOT this file's concern (both
-- root-caused to mdv.v's own region_base/gap-tracking, one a genuine class
-- of testbench-timing artifact, documented as a known limitation rather
-- than "fixed" here).
--
-- Why this is safe despite mdv.v assuming a 1-cycle-latency RAM: mdv.v
-- only changes rdaddress once every ~592 ce ticks (real hardware: ~79us,
-- thousands of clk_main_i cycles) and only samples q ONE cycle after that
-- change is committed on the SAME clock edge that computes the new
-- address (mdv.v:147-149) - by which point rdaddress has already been
-- STABLE for the entire previous ~592-tick interval. So the actual
-- invariant this wrapper must uphold is "q/q_a reflect the CURRENT
-- address's true content, given ample settling time before the next
-- sample" - not "1-cycle turnaround" - which a hold register updated in
-- the background comfortably satisfies.
--
-- Port A (wraddress/wren/data/byteena_a -> q_a) serves three logical
-- consumers muxed together by mdv.v itself before reaching this entity's
-- boundary (wr_do write-commits from the QL CPU win over dl_wr from the
-- QNICE loader/reader, mdv.v:66-68) - from here it's just one read/write
-- stream: wren='1' is a write (captured into a 1-deep pending-write latch,
-- since QL/QNICE write pulses are far sparser than avm_cache's own
-- turnaround time), wren='0' means wraddress is being used as a read
-- address (QNICE's read-back for the SD flush).
--
-- Port B (rdaddress -> q) is mdv.v's own continuous bit-serial playback
-- read, read-only.
--
-- Both ports share ONE avm_cache instance (write-through) for coherence:
-- a write must be visible to a same-address read through the SAME cache,
-- not just to a lucky hit on the writer's own port. A small arbiter
-- (port A write > port A read > port B read, write always wins since a
-- write must never be dropped) feeds requests into avm_cache's single
-- Avalon-MM slave port one at a time.
--
-- Staleness/refresh: PORT B ONLY (a_hold_q/port A needs no periodic
-- refresh at all - see p_track's own comment for why). b_hold_q is a
-- snapshot taken when its last fetch completed - it does not, by itself,
-- notice a write-through update to the SAME address that happens later
-- (mdv1's own dirty-sector-bitmap-driven writes update the shared cache
-- correctly, but a port that isn't asking for a fresh fetch never learns
-- about it). This matters specifically across an mdv1 image reload:
-- mdv.v pins rdaddress=mem_addr at 0 for the whole download (mdv.v:131),
-- so port B's "address changed" trigger alone would only ever fetch ONCE
-- near the start of the load and could keep serving that early snapshot
-- long after the reload finished. Fixed with a periodic refresh
-- (C_REFRESH_PERIOD clk cycles, well under the ~thousands-of-cycles gap
-- between real address changes, and comfortably above HyperRAM's own
-- worst-case transaction latency through the arbiter, to avoid port B
-- re-arming and chaining transactions faster than they can complete) that
-- re-arms port B's read tracker even when the address hasn't moved -
-- self-healing for ANY staleness cause, not just reload, and needs no
-- signal reaching in from outside this entity (mdv1_download is not
-- visible here - see the header note on why dpram's port list can't grow
-- arbitrarily).
--
-- OPEN ITEM, not fixed here (flagged in review, low risk, deferred):
-- the write-latch overflow assertion (p_track, "a second port-A write
-- arrived...") only fires in SIMULATION - Vivado ignores assert
-- statements when synthesizing, so on real hardware an overflow would
-- silently drop a write with no trace of it ever having happened. The
-- margin argument (real writes are tens of us apart, an avm_cache/
-- HyperRAM transaction is tens of clk cycles) makes this unlikely, but a
-- small sticky "this has happened at least once" latch (same spirit as
-- the existing mdv1_dirty bitmap), readable from a future diagnostic
-- screen, would be cheap insurance - not required for this to function
-- correctly, so deferred rather than adding a port nothing reads yet.
--
-- QL4M65 port done by Jose Daniel Fernandez Santos (dfsantos) in 2026 and
-- licensed under GPL v3
---------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.globals.all;

entity dpram is
   generic (
      ADDRWIDTH : natural := 8;
      NUMWORDS  : natural := 256;   -- unused here: BRAM size is driven by ADDRWIDTH (2**ADDRWIDTH words), matches dpram.v's own behaviour

      -- QL4M65 Milestone 2 paso 5, etapa 1 (2026-08-23,
      -- .research/microdrive-second-unit-plan.md): which 4kW-block window
      -- of the 8MB HyperRAM chip this instance's own buffer lives at -
      -- see C_HMAP_MDV1/C_HMAP_MDV2 (globals.vhd). A GENERIC, not a
      -- direct reference to C_HMAP_MDV1, so mdv.v's own second sibling
      -- (i_mdv2, main.vhd) can override it to C_HMAP_MDV2 without a
      -- second copy of this entity - mdv.v threads it through to its own
      -- internal "dpram" instantiation as the new HMAP_BASE parameter
      -- (mechanical pass-through, same pattern as the existing m_avm_*
      -- ports - see mdv.v's own header comment). Defaults to C_HMAP_MDV1
      -- so an instantiation that doesn't override it (there is none left
      -- in this project - both i_mdv1 and i_mdv2 now pass this
      -- explicitly) behaves exactly as M2030-M2032 already verified on
      -- real hardware.
      G_HMAP_BASE : std_logic_vector(15 downto 0) := C_HMAP_MDV1
   );
   port (
      wrclock   : in  std_logic;
      wraddress : in  std_logic_vector(ADDRWIDTH - 1 downto 0);
      wren      : in  std_logic;
      byteena_a : in  std_logic_vector(1 downto 0);
      data      : in  std_logic_vector(15 downto 0);

      rdclock   : in  std_logic;
      rdaddress : in  std_logic_vector(ADDRWIDTH - 1 downto 0);
      q         : out std_logic_vector(15 downto 0);

      q_a       : out std_logic_vector(15 downto 0);  -- QL4M65 fase B: lectura de puerto A, para el volcado a QNICE

      -- QL4M65 M2030 (encontrado en hardware real): pulso de un ciclo
      -- cuando q_a acaba de quedar actualizado con un valor DEFINITIVAMENTE
      -- fresco para la dirección actual de wraddress - bien por una
      -- escritura (write-through inmediato) o por la llegada real de una
      -- lectura despachada. main.vhd's mdv1_reader_core (el volcado a SD)
      -- esperaba antes un numero FIJO de 2 ciclos tras fijar la direccion -
      -- valido contra la BRAM original (1 ciclo de latencia) pero
      -- totalmente insuficiente contra este backend (contador de
      -- estabilizacion + avm_cache + avm_fifo + HyperRAM real, decenas de
      -- ciclos) - encontrado por una regresion real: SAVE seguido de
      -- apagado/reencendido persistia contenido sin escribir en varios
      -- sectores, con el LED indicando (incorrectamente) que ya estaba
      -- todo volcado. mdv1_reader_core ahora espera este pulso en vez de
      -- adivinar un numero de ciclos.
      q_a_valid_o : out std_logic;

      -- QL4M65 fase C (etapa B): maestro Avalon-MM hacia los puertos de
      -- paso puro nuevos de mdv.v (m_avm_*), que a su vez llegan hasta el
      -- hr_core_* real de mega65.vhd a través de un avm_fifo de CDC.
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
end entity dpram;

architecture synthesis of dpram is

   constant C_AWIDTH          : natural := 32;

   -- QL4M65 fase C (etapa B): dónde vive este buffer dentro de los 8MB de
   -- HyperRAM. G_HMAP_BASE (generic, ver la entidad más arriba - antes era
   -- una referencia directa a C_HMAP_MDV1, sin variar por instancia) está
   -- en unidades de bloque de 4kW (4096 palabras de 16 bits = 8KB); una
   -- dirección de PALABRA se obtiene añadiendo doce bits cero (× 4096
   -- palabras) - ver HyperRAM-for-Beginners.md sección 5.5. avm_cache/
   -- HyperRAM direccionan por PALABRA, igual que wraddress/rdaddress aquí,
   -- así que esta constante se suma directamente a cada dirección antes de
   -- despacharla - sin ella, el buffer caería en la dirección 0, dentro de
   -- C_HMAP_M2M (reservado para el framework), la misma clase de bug que
   -- el desbordamiento de C_HMAP_QLSD de M2003.
   constant C_BASE_ADDR : unsigned(C_AWIDTH - 1 downto 0) :=
      resize(unsigned(G_HMAP_BASE) & "000000000000", C_AWIDTH);

   -- QL4M65 (raised after the 3000-cycle latency stress test, per
   -- review): 400 was chosen only against the ~2368-6512-cycle real gap
   -- between genuine address changes (mem_addr/wraddress), without
   -- weighing it against the backend's OWN worst-case transaction
   -- latency. With a fast refresh period and a slow backend, port B can
   -- re-arm and re-dispatch faster than transactions complete, chaining
   -- back-to-back and starving a pending write of any bounded wait -
   -- found empirically (a write-latch overflow during the load phase
   -- that a 6x-wider write spacing alone did not fix - the real ceiling
   -- on write latency is "one already-in-flight transaction's worth",
   -- but back-to-back-chained port-B refreshes could mean several in a
   -- row before a write ever gets seen as pending). 2000 sits
   -- comfortably above the simulated stress latency's realistic
   -- transaction time in typical cases while staying well under the
   -- ~2368-6512-cycle real refresh interval - the working principle is
   -- C_REFRESH_PERIOD should always be set above the backend's own
   -- expected worst-case transaction latency, not chosen independently
   -- of it.
   constant C_REFRESH_PERIOD  : natural := 2000;

   -- QL4M65 (found in the SAME stress-test investigation as the write-
   -- fall spurious-read bug, one level deeper): a loader/writer sets its
   -- target address a cycle or two BEFORE asserting wren (mdv1_loader_
   -- core's own xpm_cdc_handshake protocol does this too, not just a
   -- testbench) - during that brief gap wren='0' and the address has
   -- just "changed", which a simple write-fall exclusion alone does not
   -- catch (wren is already '0' on both the current and previous cycle
   -- by then). A genuine QNICE read-back
   -- (READ_MDV1_BYTE) holds its address stable for many cycles while
   -- waiting out the M2M bus protocol; a write's own address-setup gap
   -- lasts only a cycle or two. Requiring the address to stay stable
   -- (wren='0' throughout) for C_A_SETTLE_CYCLES before treating it as a
   -- real read - comfortably longer than any write's own setup gap,
   -- utterly negligible against a genuine read's own natural duration -
   -- filters this out without needing to special-case "is this address
   -- about to be written to" (not knowable from here anyway).
   constant C_A_SETTLE_CYCLES : natural := 8;

   -- local power-on reset for avm_cache - mdv.v's own dpram instantiation
   -- has no reset port to pass one in (matching the original, unmodified
   -- entity - see header), so this is generated internally instead of
   -- relying on any external signal.
   signal por_cnt   : unsigned(3 downto 0) := (others => '0');
   signal por_rst   : std_logic := '1';

   -- shared avm_cache slave-side signals (one in-flight request at a time)
   signal s_write         : std_logic := '0';
   signal s_read          : std_logic := '0';
   signal s_address       : std_logic_vector(C_AWIDTH - 1 downto 0) := (others => '0');
   signal s_writedata     : std_logic_vector(15 downto 0) := (others => '0');
   signal s_byteenable    : std_logic_vector(1 downto 0) := (others => '0');
   signal s_waitrequest   : std_logic;
   signal s_readdata      : std_logic_vector(15 downto 0);
   signal s_readdatavalid : std_logic;

   type t_owner is (NONE, PORT_A, PORT_B);
   signal owner : t_owner := NONE;
   signal req_is_write : std_logic := '0';

   -- Port A: 1-deep pending-write latch + settle-counter read tracker
   -- (see C_A_SETTLE_CYCLES above)
   signal a_addr_prev      : std_logic_vector(ADDRWIDTH - 1 downto 0) := (others => '1');
   signal a_pend_write     : std_logic := '0';
   signal a_pend_addr      : std_logic_vector(ADDRWIDTH - 1 downto 0);
   signal a_pend_data      : std_logic_vector(15 downto 0);
   signal a_pend_be        : std_logic_vector(1 downto 0);
   signal a_pend_read      : std_logic := '0';
   signal a_pend_read_addr : std_logic_vector(ADDRWIDTH - 1 downto 0);
   signal a_hold_q         : std_logic_vector(15 downto 0) := (others => '0');
   signal a_hold_addr      : std_logic_vector(ADDRWIDTH - 1 downto 0) := (others => '1');
   signal a_settle_cnt     : unsigned(3 downto 0) := (others => '0');
   signal a_settled        : std_logic := '0';  -- already fired for this stable stretch

   -- Port B: "address changed or refresh timeout" read tracker
   signal b_addr_prev      : std_logic_vector(ADDRWIDTH - 1 downto 0) := (others => '1');
   signal b_pend_read      : std_logic := '0';
   signal b_pend_read_addr : std_logic_vector(ADDRWIDTH - 1 downto 0);
   signal b_hold_q         : std_logic_vector(15 downto 0) := (others => '0');
   signal b_refresh_cnt    : unsigned(15 downto 0) := (others => '0');

begin

   assert wrclock = rdclock
      report "dpram: wrclock and rdclock must be the same net (mdv.v's own instantiation ties both to clk)"
      severity failure;

   q   <= b_hold_q;
   q_a <= a_hold_q;

   -- QL4M65 M2031 fix #2 (found in hardware after the first M2031 fix):
   -- q_a_valid is NOT "a fetch just completed this cycle" (a one-shot
   -- pulse) - it is "a_hold_q is KNOWN CORRECT for wraddress RIGHT NOW",
   -- a level. The difference matters for a very common access pattern:
   -- QNICE reads a 16-bit word as two back-to-back byte reads (high byte,
   -- then low byte) at the SAME wraddress - e.g. every single call to
   -- MDV1_FLUSH_STEP starts by reading the 32-byte dirty bitmap this way
   -- (16 words, m2m-rom.asm's _MFS_RDBM loop). The FIRST byte's read
   -- genuinely dispatches and completes, correctly settling a_hold_q/
   -- a_settled for that address. The SECOND byte's request reuses the
   -- EXACT SAME wraddress (same word, other half) - wraddress does not
   -- change, a_settled is already '1' from the first byte, so the
   -- settle-counter correctly does NOT dispatch a second, redundant
   -- fetch (a_hold_q already has the right word cached). A pulse-based
   -- q_a_valid (the original M2031 fix) only fired on the ACT of
   -- fetching, so it never fired for this second, cache-hit request -
   -- main.vhd's mdv1_reader_core (M2031's own new wait-for-valid logic)
   -- hung forever waiting for a pulse that correctly never needed to
   -- come. Found on real hardware: MEGA65 froze at the OSD main menu
   -- right after any LOAD (OSM_SEL_PRE force-flushes before returning,
   -- and even an all-clean bitmap still gets read once, in full, every
   -- single call). Comparing addresses instead of pulsing on the fetch
   -- event handles a cache hit and a cache miss identically and
   -- correctly: valid the instant a_hold_q's own address matches
   -- whatever is being asked for RIGHT NOW, whether that took 8 cycles
   -- (a genuine new fetch) or 0 (already cached from the read right
   -- before it).
   q_a_valid_o <= '1' when a_hold_addr = wraddress else '0';

   p_por : process (wrclock)
   begin
      if rising_edge(wrclock) then
         if por_cnt /= "1111" then
            por_cnt <= por_cnt + 1;
            por_rst <= '1';
         else
            por_rst <= '0';
         end if;
      end if;
   end process p_por;

   -- avm_cache decides its OWN downstream bursts (up to G_CACHE_SIZE
   -- words on a miss, single words on a hit-adjacent fetch) - its m_avm_*
   -- master port is wired straight through to this entity's own m_avm_*_o/i
   -- ports, never re-derived from this wrapper's slave-side request.
   i_avm_cache : entity work.avm_cache
      generic map (
         G_CACHE_SIZE   => 8,
         G_ADDRESS_SIZE => C_AWIDTH,
         G_DATA_SIZE    => 16
      )
      port map (
         clk_i                 => wrclock,
         rst_i                 => por_rst,
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

   p_track : process (wrclock)
   begin
      if rising_edge(wrclock) then
         -- Port A: latch a write, or note a genuinely new, SETTLED read
         -- address.
         --
         -- QL4M65 (found by review, root-caused via a 3000-cycle stress
         -- test's C_REFRESH_PERIOD-invariance during etapa A simulation -
         -- see DECISIONES.md): the original version fired a_pend_read on
         -- ANY (wraddress, wren) change, two different ways, both
         -- spurious:
         --   1. wren's own 1->0 falling edge right after every write -
         --      every write was immediately followed by a pointless read
         --      of its own just-written address. Fixed first by also
         --      requiring the PREVIOUS cycle to already be non-write -
         --      but that alone was not enough (see next).
         --   2. a writer setting its target address a cycle or two
         --      BEFORE asserting wren (mdv1_loader_core's own
         --      xpm_cdc_handshake protocol does exactly this) - during
         --      that brief gap wren='0' on both the current AND previous
         --      cycle, so fix #1 alone does not exclude it either.
         -- Both wasted a read that could delay a pending write behind it
         -- (a read in flight blocks the arbiter until readdatavalid, see
         -- p_arbiter's own comment - correct behaviour on its own, but
         -- combined with a spurious read it eats into the write's real
         -- margin for no reason).
         --
         -- Fixed properly with a settle counter: the address must stay
         -- UNCHANGED with wren='0' for C_A_SETTLE_CYCLES in a row before
         -- it is treated as a real read target. A write's own address-
         -- setup gap (a cycle or two) never reaches that; a genuine
         -- QNICE read-back (READ_MDV1_BYTE) holds its address for many
         -- cycles waiting out the M2M bus protocol, so the extra
         -- C_A_SETTLE_CYCLES of latency before dpram starts fetching is
         -- negligible against it.
         --
         -- Also: port A does not need a periodic refresh at all (unlike
         -- port B, whose address mdv.v pins at 0 for the whole download -
         -- mdv.v:131 - with nothing else to force a re-read). Port A's
         -- address changes on every genuine access: during a load/write
         -- session it's the writer, with no reader consuming q_a at all;
         -- during a QNICE read-back it gets a fresh dl_addr per byte, so
         -- the settle-then-fetch trigger alone is sufficient.
         a_addr_prev <= wraddress;

         if wren = '1' then
            -- 1-deep write latch: a second wren pulse before the first
            -- write has even been DISPATCHED (owner still NONE, or still
            -- PORT_A but not yet accepted) would silently overwrite and
            -- lose it. Real mdv1 traffic has orders of magnitude more
            -- spacing between writes than a single avm_cache/HyperRAM
            -- transaction takes (see this entity's own header comment) -
            -- this assertion exists to make sure that margin actually
            -- holds in simulation (Vivado ignores it when synthesizing -
            -- see the header's OPEN ITEM note).
            assert a_pend_write = '0'
               report "dpram: a second port-A write arrived before the previous one was dispatched - 1-deep write latch overflow"
               severity failure;
            a_pend_write  <= '1';
            a_pend_addr   <= wraddress;
            a_pend_data   <= data;
            a_pend_be     <= byteena_a;
            -- Mark this address as already-settled, NOT pending-settle:
            -- the write itself is the freshest possible value for
            -- wraddress, so no subsequent auto-read is needed here.
            -- Setting a_settled='0' instead (as an earlier version of
            -- this fix did, found in etapa A simulation) reintroduced the
            -- exact same spurious-read-after-write bug this whole
            -- mechanism exists to remove - worse, deterministically on
            -- EVERY write.
            a_settle_cnt  <= (others => '0');
            a_settled     <= '1';
            -- QL4M65 M2030 real-hardware finding (2026-08-22): a_hold_q
            -- MUST be updated here too. Without this line, a_settled='1'
            -- (above) permanently blocks any future read-trigger for THIS
            -- address until wraddress moves away and comes back - so if
            -- QNICE's own SD-flush read-back (READ_MDV1_BYTE) later asks
            -- for the EXACT SAME address the QL just wrote (very common:
            -- it reads back each dirty sector right after the write that
            -- dirtied it), neither branch below ever fires, and q_a keeps
            -- serving whatever a_hold_q held from some earlier, unrelated
            -- read - stale data gets silently flushed to the SD card as
            -- if it were the fresh write, and the dirty bit clears as if
            -- it succeeded (found via a real hardware SAVE+reboot: 4
            -- sectors persisted with pre-write filler content, LED showed
            -- "clean" the whole time). The original BRAM
            -- (dualport_2clk_ram_byteenable) never had this gap - a real
            -- dual-port RAM serves the just-written value on its own read
            -- port immediately, which this line restores.
            a_hold_q      <= data;
            a_hold_addr   <= wraddress;
         elsif wraddress /= a_addr_prev then
            -- address just moved (a genuine new read target, OR a
            -- writer setting up its NEXT target a cycle or two before
            -- asserting wren, mdv.v:66-68's own dl_addr/wr_addr mux) -
            -- restart the settle count, do not fire yet.
            a_settle_cnt <= (others => '0');
            a_settled    <= '0';
         elsif a_settled = '0' then
            if a_settle_cnt = C_A_SETTLE_CYCLES - 1 then
               a_pend_read      <= '1';
               a_pend_read_addr <= wraddress;
               a_settled        <= '1';
            else
               a_settle_cnt <= a_settle_cnt + 1;
            end if;
         end if;

         -- Port B: note a changed read address / a refresh timeout
         b_addr_prev <= rdaddress;
         if rdaddress /= b_addr_prev then
            b_pend_read      <= '1';
            b_pend_read_addr <= rdaddress;
            b_refresh_cnt    <= (others => '0');
         elsif b_refresh_cnt = C_REFRESH_PERIOD then
            b_pend_read      <= '1';
            b_pend_read_addr <= rdaddress;
            b_refresh_cnt    <= (others => '0');
         else
            b_refresh_cnt <= b_refresh_cnt + 1;
         end if;

         -- Arbiter clears the flag it just serviced (see p_arbiter).
         -- "and wren = '0'" guards a_pend_write's clear specifically:
         -- both this clear and the fresh-write latch above write the
         -- SAME signal, and VHDL's last-assignment-wins-per-cycle
         -- semantics mean whichever runs later in program order decides
         -- the final value if both fire the same cycle. Found by
         -- simulation (etapa A write-path test, see DECISIONES.md): a
         -- new wren pulse landing on the exact cycle the PREVIOUS
         -- write's dispatch is accepted (s_waitrequest drops) silently
         -- lost that new write - not a 1-deep-latch overflow (the
         -- assertion above only catches a SECOND write arriving before
         -- the FIRST is even dispatched, a different case), but the
         -- opposite: a new write arriving exactly as the old one clears
         -- getting immediately wiped straight back to '0' by this same
         -- block, one delta cycle later in program order. Safe to
         -- suppress the clear here: the outgoing write's own address/
         -- data were already copied into s_address/s_writedata at
         -- dispatch time (in a previous cycle, see p_arbiter's NONE
         -- state), so overwriting a_pend_addr/a_pend_data with the new
         -- write's values this same cycle cannot corrupt the one
         -- already in flight.
         if owner = PORT_A then
            if s_write = '1' and s_waitrequest = '0' and wren = '0' then
               a_pend_write <= '0';
            end if;
            if s_read = '1' and s_waitrequest = '0' and a_pend_write = '0' then
               a_pend_read <= '0';
            end if;
         elsif owner = PORT_B then
            if s_read = '1' and s_waitrequest = '0' then
               b_pend_read <= '0';
            end if;
         end if;

         -- QL4M65 M2030: a_hold_q's OTHER source (a genuine dispatched
         -- read completing) - moved here from p_arbiter, which used to
         -- also assign a_hold_q directly. Two different PROCESSES driving
         -- the same signal simulates fine (std_logic is a resolved type,
         -- and the two conditions never truly overlap) but is a real
         -- synthesis error (Vivado DRC MDRV-1, "multiple drivers" -
         -- inferred two separate registers both fighting to drive q_a).
         -- Both of a_hold_q's writers now live in this one process.
         if owner = PORT_A and s_readdatavalid = '1' then
            a_hold_q    <= s_readdata;
            a_hold_addr <= a_pend_read_addr;
         end if;

         if por_rst = '1' then
            a_pend_write <= '0';
            a_pend_read  <= '0';
            b_pend_read  <= '0';
         end if;
      end if;
   end process p_track;

   -- Owner-completion timing: a WRITE is done as soon as avm_cache accepts
   -- it (s_waitrequest drops with s_write asserted) - avm_cache never
   -- raises s_avm_readdatavalid_o for a pure write (verified against
   -- avm_cache.vhd: it is unconditionally cleared at the top of every
   -- cycle and only ever set inside read-hit/read-fill branches), so
   -- there is no response left to wait for. A READ is NOT done at accept
   -- time - s_read/s_waitrequest dropping only means avm_cache has taken
   -- the request in (e.g. started a READING_ST refill on a miss); the
   -- actual data can arrive many cycles later via s_avm_readdatavalid_o.
   -- Releasing "owner" at accept time instead of at the real data arrival
   -- would let the arbiter start servicing the OTHER port's request while
   -- this one is still in flight, and avm_cache's response has no request
   -- tag on it - the FIRST readdatavalid pulse after a read is issued
   -- unambiguously belongs to THAT read (avm_cache completes one request
   -- before the next can be issued from this wrapper, since "owner" gates
   -- p_arbiter's own NONE-state dispatch), but only as long as "owner"
   -- itself stays held until that pulse actually arrives. Hence
   -- req_is_write below, and reads only release owner on readdatavalid.
   req_track : process (wrclock)
   begin
      if rising_edge(wrclock) then
         if owner = NONE then
            if a_pend_write = '1' then
               req_is_write <= '1';
            elsif a_pend_read = '1' or b_pend_read = '1' then
               req_is_write <= '0';
            end if;
         end if;
      end if;
   end process req_track;

   p_arbiter : process (wrclock)
   begin
      if rising_edge(wrclock) then
         if s_waitrequest = '0' then
            s_write <= '0';
            s_read  <= '0';
         end if;

         case owner is
            when NONE =>
               if a_pend_write = '1' then
                  owner        <= PORT_A;
                  s_write      <= '1';
                  s_address    <= std_logic_vector(C_BASE_ADDR + resize(unsigned(a_pend_addr), C_AWIDTH));
                  s_writedata  <= a_pend_data;
                  s_byteenable <= a_pend_be;
               elsif a_pend_read = '1' then
                  owner        <= PORT_A;
                  s_read       <= '1';
                  s_address    <= std_logic_vector(C_BASE_ADDR + resize(unsigned(a_pend_read_addr), C_AWIDTH));
                  -- QL4M65 (found in review): the read branches never
                  -- touched s_byteenable, so avm_cache saw whatever the
                  -- LAST write happened to leave there ("00" before the
                  -- first write of the session ever ran) - avm_cache
                  -- reads s_avm_byteenable_i(MSB) to decide whether to
                  -- trigger its own speculative half-line prefetch
                  -- (avm_cache.vhd:113), so this made that prefetch's
                  -- arming depend on write history instead of being
                  -- deterministic. Harmless functionally (a line miss
                  -- always reloads whole), but real undefined-by-accident
                  -- behaviour that could differ between sim and synthesis
                  -- if anything else changes - fixed by always driving
                  -- both byte lanes on a read.
                  s_byteenable <= "11";
               elsif b_pend_read = '1' then
                  owner        <= PORT_B;
                  s_read       <= '1';
                  s_address    <= std_logic_vector(C_BASE_ADDR + resize(unsigned(b_pend_read_addr), C_AWIDTH));
                  s_byteenable <= "11";
               end if;

            when PORT_A =>
               if s_readdatavalid = '1' then
                  -- a_hold_q's own update for this event lives in p_track
                  -- now (M2030 - see that process's own comment on why:
                  -- Vivado DRC MDRV-1, two processes can't both drive it).
                  owner    <= NONE;
               elsif req_is_write = '1' and s_write = '0' and s_read = '0' then
                  owner <= NONE;
               end if;

            when PORT_B =>
               if s_readdatavalid = '1' then
                  b_hold_q <= s_readdata;
                  owner    <= NONE;
               elsif req_is_write = '1' and s_write = '0' and s_read = '0' then
                  owner <= NONE;
               end if;
         end case;

         if por_rst = '1' then
            owner   <= NONE;
            s_write <= '0';
            s_read  <= '0';
         end if;
      end if;
   end process p_arbiter;

end architecture synthesis;
