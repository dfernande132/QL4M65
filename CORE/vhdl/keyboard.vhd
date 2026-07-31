---------------------------------------------------------------------------------------------------------
-- Sinclair QL for MEGA65 (QL4M65)
--
-- MEGA65 keyboard -> ZX8302 IPC link
--
-- Replaces rtl/keyboard.v + rtl/ipc.v + rtl/T48/ (which emulates the QL's real
-- Intel 8049 IPC microcontroller) with a MEGA65-native translator that speaks
-- the ZX8302's comdata/comctrl serial link directly - the same architectural
-- choice as C64MEGA65 (drives the CIA1 matrix directly instead of emulating
-- PS/2) and AExp (synthesizes the CIA-A protocol directly instead of
-- emulating the Amiga's keyboard MCU).
--
-- This file was built in two commits:
--   1) MEGA65 key -> QL 8x8 keyboard matrix. Reuses the exact byte/bit layout
--      of the original rtl/keyboard.v's "matrix" output, just fed from M2M's
--      key_num_i/key_pressed_n_i instead of ps2_key, so the IPC protocol
--      logic below can serve it exactly as rtl/ipc.v's P1-select/data-bus-
--      read logic expected from the real 8049.
--   2) The comdata/comctrl IPC protocol logic (THIS COMMIT) that serves this
--      matrix to the ZX8302 in place of the 8049. Bit-level framing is HIGH
--      confidence, verified against rtl/zx8302.v: comctrl is a free-running
--      strobe WE generate (the ZX8302 is a passive clock slave to it), and
--      each 1-bit transfer takes exactly 2 of our falling edges (1st just
--      consumes the CPU's Start bit, 2nd is the real bidirectional
--      exchange).
--
--      Byte/command-level semantics were originally a low-confidence guess
--      from public QL community documentation, then corrected by actually
--      disassembling rtl/ipc8049.hex (the real IPC ROM MiSTer's T48 core
--      executes) with a from-scratch MCS-48 disassembler built from
--      github.com/jblang/d52's opcode tables. Verified findings:
--        - The command dispatch (address 0x020B, `jmpp @a`) is a genuine
--          16-entry jump table keyed by a 4-BIT NIBBLE, not a byte - the
--          command value is received by a single call to the nibble-receive
--          routine at 0x074F. Commands 2/3, 4/5 and 6/7 share handlers in
--          pairs (consistent with symmetric "open/close/receive ser1 vs
--          ser2" commands); 8 and 9 are distinct, consistent with "read
--          keyboard" and "keyrow".
--        - Command 9 ("keyrow", address 0x0276): receives ONE MORE NIBBLE
--          (low 3 bits = row 0-7), builds a one-hot mask, reads the
--          matching kbd_matrix byte, and answers with a full BYTE (two
--          nibbles, high nibble first) - confirms the ROWSEL/RESPOND shape
--          below, but as nibble+nibble+byte, not byte+byte+byte.
--        - Bit order is MSB-first throughout (nibble reception via
--          repeated RLC at 0x0750-ish; byte transmission via JB7-then-
--          rotate at 0x0762), not LSB-first as first assumed.
--        - Command 8 ("read keyboard") turned out to service an internal
--          keyboard-event QUEUE (RAM 0x2B/0x2C onward), not a direct matrix
--          read - replicating it exactly would need reverse-engineering the
--          scan/interrupt routine that fills that queue, which has not been
--          done; left as the same safe 0x00 stub as before.
--      PENDING VALIDATION (real hardware/simulation) before main.vhd wires
--      this entity in for real (milestone 1's M1001 build) - this is now
--      grounded in the actual ROM instead of forum summaries, but a
--      hand-written disassembler is itself unverified until it's been
--      seen working against real hardware.
--
-- Key mapping notes (decided together with the user in chat, flagging the
-- non-obvious ones so they are easy to find and revisit):
--   - ALT: MEGA65's own ALT key (m65_alt), not MEGA/C= (m65_mega).
--   - F1..F5: the QL has 5 plain function keys, no shift relationship
--     between them. MEGA65 exposes only F1/F3/F5 as separate physical keys
--     (F2/F4 come from Shift+F1/Shift+F3, like the "F1/F2" style keycaps on
--     a C64 keyboard). Chosen mapping: F1<-m65_f1, F2<-Shift+m65_f1,
--     F3<-m65_f3, F4<-Shift+m65_f3, F5<-m65_f5. QL SHIFT itself is
--     suppressed while this combo is what's driving F2/F4, so the QL
--     doesn't also see a spurious SHIFT press.
--   - Cursor keys: mapped directly from MEGA65's dedicated
--     left_crsr/up_crsr/horz_crsr/vert_crsr keys, with no Shift trick (the
--     QL has real dedicated Up/Down/Left/Right keys, unlike the C64).
--   - QL "[", "]", "\" have no C64-style keyboard equivalent: mapped to
--     MEGA65 keys with no meaning of their own here (arrow_left, arrow_up,
--     no_scrl respectively). QL "'" (apostrophe) similarly has no obvious
--     match; mapped to the spare "colon" key (m65_colon).
--   - INS/DEL: the QL has no physical delete key at all - rtl/keyboard.v's
--     own PS/2 driver already synthesizes CTRL+LEFT for Backspace
--     (special[1]). Reproduced here the same way, including the delay
--     between asserting CTRL and LEFT: the QL's keyboard driver only
--     accepts the combo if CTRL was already held by the time LEFT arrives,
--     not if both appear in the very same scan (same reasoning
--     rtl/keyboard.v documents for its own combo keys).
--
-- Powered by MiSTer2MEGA65
-- QL4M65 port done by Jose Daniel Fernandez Santos (dfsantos) in 2026 and
-- licensed under GPL v3
---------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity keyboard is
   port (
      clk_main_i       : in  std_logic;   -- QL core clock (84 MHz, main_clk)
      reset_i          : in  std_logic;

      -- M2M's MEGA65 keyboard interface (same convention as C64MEGA65/AExp
      -- keyboard.vhd): key_num_i cycles 0..79 at 1kHz, key_pressed_n_i is the
      -- debounced, low-active "is this key pressed now" answer.
      key_num_i        : in  integer range 0 to 79;
      key_pressed_n_i  : in  std_logic;

      -- ZX8302 IPC serial link (replaces rtl/ipc.v's ports of the same
      -- name/direction, see rtl/zx8302.v for the framing this must match)
      comctrl_o        : out std_logic;                    -- strobe toward the ZX8302, free-running
      comdata_i        : in  std_logic;                    -- the ZX8302's own raw outgoing bit (rtl/zx8302.v's ipc_comdata_in)
      comdata_o        : out std_logic;                    -- '1' = released, '0' = driven low
      audio_o          : out std_logic;                    -- IPC-generated audio: not implemented, unused in milestone 1
      ipl_o            : out std_logic_vector(1 downto 0); -- IPC interrupt-priority lines: not implemented, tied to "no IRQ"

      -- QL4M65 TEMPORARY DEBUG AID (M1018/M1019): expose what's actually
      -- coming through the comdata/comctrl link, to check whether Minerva
      -- is really talking to us at all and with which command (see
      -- main.vhd for how these get displayed; doc/m2m/exceptions.md for
      -- the revert). M1018 showed CMD "6"/"7" (serial receive, not
      -- keyboard-related) dominating - repurposed the "last ROWSEL" digit
      -- (M1019) into a STICKY "ever seen" flag for commands 8/9 (and
      -- anything else) specifically, since a once-per-second "last value"
      -- sample would statistically favour whatever's most frequent and
      -- could hide a rare cmd 8/9 entirely.
      dbg_last_cmd_o     : out std_logic_vector(3 downto 0); -- last CMD nibble seen (CMD state)
      dbg_seen_flags_o   : out std_logic_vector(3 downto 0); -- bit0=cmd8 ever seen, bit1=cmd9 ever seen, bit2=cmd6/7 ever seen, bit3=any other cmd ever seen (all sticky since reset)

      -- QL4M65 TEMPORARY DEBUG AID (M1020): the real QL confirms holding
      -- ANY key down forever also prevents Minerva's own 8-10s "no key ->
      -- auto TV mode" timeout from ever firing - matching exactly what we
      -- see (never times out). Prime suspect: a phantom/stuck-high bit in
      -- ql_matrix even though nothing is actually pressed. Sticky, one bit
      -- per matrix byte (row): sees a byte go non-idle ('/= "00000000"')
      -- even once since reset.
      dbg_matrix_seen_o  : out std_logic_vector(7 downto 0)
   );
end entity keyboard;

architecture beh of keyboard is

   -- MEGA65 key codes that key_num_i cycles through (M2M's fixed physical
   -- keyboard numbering, identical table to C64MEGA65/AExp keyboard.vhd -
   -- this was already present in the template, unchanged here)
   constant m65_ins_del       : integer := 0;
   constant m65_return        : integer := 1;
   constant m65_horz_crsr     : integer := 2;
   constant m65_f7            : integer := 3;
   constant m65_f1            : integer := 4;
   constant m65_f3            : integer := 5;
   constant m65_f5            : integer := 6;
   constant m65_vert_crsr     : integer := 7;
   constant m65_3             : integer := 8;
   constant m65_w             : integer := 9;
   constant m65_a             : integer := 10;
   constant m65_4             : integer := 11;
   constant m65_z             : integer := 12;
   constant m65_s             : integer := 13;
   constant m65_e             : integer := 14;
   constant m65_left_shift    : integer := 15;
   constant m65_5             : integer := 16;
   constant m65_r             : integer := 17;
   constant m65_d             : integer := 18;
   constant m65_6             : integer := 19;
   constant m65_c             : integer := 20;
   constant m65_f             : integer := 21;
   constant m65_t             : integer := 22;
   constant m65_x             : integer := 23;
   constant m65_7             : integer := 24;
   constant m65_y             : integer := 25;
   constant m65_g             : integer := 26;
   constant m65_8             : integer := 27;
   constant m65_b             : integer := 28;
   constant m65_h             : integer := 29;
   constant m65_u             : integer := 30;
   constant m65_v             : integer := 31;
   constant m65_9             : integer := 32;
   constant m65_i             : integer := 33;
   constant m65_j             : integer := 34;
   constant m65_0             : integer := 35;
   constant m65_m             : integer := 36;
   constant m65_k             : integer := 37;
   constant m65_o             : integer := 38;
   constant m65_n             : integer := 39;
   constant m65_plus          : integer := 40;
   constant m65_p             : integer := 41;
   constant m65_l             : integer := 42;
   constant m65_minus         : integer := 43;
   constant m65_dot           : integer := 44;
   constant m65_colon         : integer := 45;
   constant m65_at            : integer := 46;
   constant m65_comma         : integer := 47;
   constant m65_gbp           : integer := 48;
   constant m65_asterisk      : integer := 49;
   constant m65_semicolon     : integer := 50;
   constant m65_clr_home      : integer := 51;
   constant m65_right_shift   : integer := 52;
   constant m65_equal         : integer := 53;
   constant m65_arrow_up      : integer := 54;  -- symbol, not cursor
   constant m65_slash         : integer := 55;
   constant m65_1             : integer := 56;
   constant m65_arrow_left    : integer := 57;  -- symbol, not cursor
   constant m65_ctrl          : integer := 58;
   constant m65_2             : integer := 59;
   constant m65_space         : integer := 60;
   constant m65_mega          : integer := 61;
   constant m65_q             : integer := 62;
   constant m65_run_stop      : integer := 63;
   constant m65_no_scrl       : integer := 64;
   constant m65_tab           : integer := 65;
   constant m65_alt           : integer := 66;
   constant m65_help          : integer := 67;
   constant m65_f9            : integer := 68;
   constant m65_f11           : integer := 69;
   constant m65_f13           : integer := 70;
   constant m65_esc           : integer := 71;
   constant m65_capslock      : integer := 72;
   constant m65_up_crsr       : integer := 73;
   constant m65_left_crsr     : integer := 74;
   constant m65_restore       : integer := 75;

   -- continuously-updated "is this MEGA65 key currently pressed" array
   -- (low-active, same convention as key_pressed_n_i)
   signal key_pressed_n : std_logic_vector(79 downto 0) := (others => '1');

   -- derived modifier / F-key combo signals (see header comment)
   signal shift    : std_logic;  -- either MEGA65 shift key held
   signal ql_shift : std_logic;
   signal ql_ctrl  : std_logic;
   signal ql_alt   : std_logic;
   signal ql_f1    : std_logic;
   signal ql_f2    : std_logic;
   signal ql_f3    : std_logic;
   signal ql_f4    : std_logic;
   signal ql_f5    : std_logic;

   -- INS/DEL -> CTRL+LEFT combo (mirrors rtl/keyboard.v's special[1]
   -- "Backspace -> CTRL+LEFT"). ins_del_ctrl asserts CTRL immediately;
   -- ins_del_left only asserts LEFT once CTRL has already been "seen" for a
   -- short while, same reasoning as rtl/keyboard.v's own combo-key delay.
   -- Divider ratio approximate (not yet validated on hardware, same caveat
   -- as the rest of this file's timing behaviour).
   signal ins_del_ctrl : std_logic;
   signal ins_del_left : std_logic;
   signal ce_1k        : std_logic;
   signal div_cnt      : unsigned(12 downto 0) := (others => '0');

   -- the QL's 8x8 keyboard matrix: bit(8*byte + pos), same addressing as
   -- rtl/ipc.v's one-hot P1 byte-select into this 64-bit value
   signal ql_matrix_real : std_logic_vector(63 downto 0);
   signal ql_matrix      : std_logic_vector(63 downto 0);

   -- QL4M65 TEMPORARY TEST (M1021): force the matrix zx8302/Minerva actually
   -- sees to permanently idle (nothing ever pressed), regardless of the
   -- real MEGA65 keyboard state (still computed into ql_matrix_real above,
   -- just not used while this is true). Isolates whether Minerva's own
   -- 8-10s no-input auto-timeout (confirmed on real QL hardware, never
   -- observed on ours) is blocked by something in our keyboard-state
   -- generation specifically, or by something else entirely (e.g. the
   -- interrupt/scheduler chain) - see DECISIONES.md. Set back to false once
   -- diagnosed.
   constant DBG_FORCE_IDLE_MATRIX : boolean := true;

   -- IPC comdata/comctrl link (see architecture-level comment above)
   type t_cmd_state is (CMD, ROWSEL, RESPOND);

   signal comctrl_r  : std_logic := '1';
   signal phase_cnt  : unsigned(5 downto 0) := (others => '0');
   signal edge_pulse : std_logic := '0';
   signal edge_phase : std_logic := '0';   -- '0' before edge 1, '1' before edge 2

   signal bit_cnt    : unsigned(2 downto 0) := (others => '0');
   signal shift_in   : std_logic_vector(7 downto 0) := (others => '0');
   signal resp_byte  : std_logic_vector(7 downto 0) := (others => '1');
   signal cmd_state  : t_cmd_state := CMD;

   -- QL4M65 TEMPORARY DEBUG AID (M1018/M1019/M1020)
   signal dbg_last_cmd    : std_logic_vector(3 downto 0) := (others => '0');
   signal dbg_seen_flags  : std_logic_vector(3 downto 0) := (others => '0');
   signal dbg_matrix_seen : std_logic_vector(7 downto 0) := (others => '0');

begin

   ---------------------------------------------------------------------------
   -- Continuously track which MEGA65 keys are currently pressed
   ---------------------------------------------------------------------------
   keyboard_state : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         key_pressed_n(key_num_i) <= key_pressed_n_i;
      end if;
   end process keyboard_state;

   ---------------------------------------------------------------------------
   -- ~10 kHz clock enable (84 MHz / 8192, same divider constant as
   -- rtl/keyboard.v's ce_1k off its 11 MHz clock) and the INS/DEL->CTRL+LEFT
   -- delay counter
   ---------------------------------------------------------------------------
   ins_del_ctrl <= not key_pressed_n(m65_ins_del);

   clk_div : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         div_cnt <= div_cnt + 1;
         if div_cnt = 0 then
            ce_1k <= '1';
         else
            ce_1k <= '0';
         end if;
      end if;
   end process clk_div;

   ins_del_delay : process (clk_main_i)
      variable delay : unsigned(4 downto 0);
   begin
      if rising_edge(clk_main_i) then
         if reset_i = '1' or ins_del_ctrl = '0' then
            delay := (others => '0');
         elsif ce_1k = '1' and delay(4) = '0' then
            delay := delay + 1;
         end if;
         ins_del_left <= delay(4) and ins_del_ctrl;
      end if;
   end process ins_del_delay;

   ---------------------------------------------------------------------------
   -- Modifier / F-key combos
   ---------------------------------------------------------------------------
   shift <= not (key_pressed_n(m65_left_shift) and key_pressed_n(m65_right_shift));

   -- F1/F3/F5 physical keys (labelled "F1/F2", "F3/F4", "F5/F6" on the
   -- keycap, like a C64 keyboard) each provide two QL function keys via
   -- Shift; F5 provides only F5 (the QL has no F6+)
   ql_f1 <= not key_pressed_n(m65_f1) and not shift;
   ql_f2 <= not key_pressed_n(m65_f1) and shift;
   ql_f3 <= not key_pressed_n(m65_f3) and not shift;
   ql_f4 <= not key_pressed_n(m65_f3) and shift;
   ql_f5 <= not key_pressed_n(m65_f5);

   -- QL SHIFT is suppressed while the F1/F3 combo is driving F2/F4
   ql_shift <= shift and key_pressed_n(m65_f1) and key_pressed_n(m65_f3);
   ql_ctrl  <= (not key_pressed_n(m65_ctrl)) or ins_del_ctrl;
   ql_alt   <= not key_pressed_n(m65_alt);

   ---------------------------------------------------------------------------
   -- MEGA65 key -> QL keyboard matrix
   --
   -- Byte/bit layout copied from rtl/keyboard.v's "matrix" output, unchanged
   -- so the IPC protocol logic below can serve it exactly as rtl/ipc.v's
   -- P1-select/data-bus-read logic expected from the real 8049.
   ---------------------------------------------------------------------------

   -- byte 0: F4 F1 "5" F2 F3 F5 "4" "7"
   ql_matrix_real(8*0+0) <= ql_f4;
   ql_matrix_real(8*0+1) <= ql_f1;
   ql_matrix_real(8*0+2) <= not key_pressed_n(m65_5);
   ql_matrix_real(8*0+3) <= ql_f2;
   ql_matrix_real(8*0+4) <= ql_f3;
   ql_matrix_real(8*0+5) <= ql_f5;
   ql_matrix_real(8*0+6) <= not key_pressed_n(m65_4);
   ql_matrix_real(8*0+7) <= not key_pressed_n(m65_7);

   -- byte 1: Ret Left Up Esc Right "\" Space Down
   ql_matrix_real(8*1+0) <= not key_pressed_n(m65_return);
   ql_matrix_real(8*1+1) <= (not key_pressed_n(m65_left_crsr)) or ins_del_left;
   ql_matrix_real(8*1+2) <= not key_pressed_n(m65_up_crsr);
   ql_matrix_real(8*1+3) <= not key_pressed_n(m65_esc);
   ql_matrix_real(8*1+4) <= not key_pressed_n(m65_horz_crsr);   -- QL Right
   ql_matrix_real(8*1+5) <= not key_pressed_n(m65_no_scrl);     -- QL "\"
   ql_matrix_real(8*1+6) <= not key_pressed_n(m65_space);
   ql_matrix_real(8*1+7) <= not key_pressed_n(m65_vert_crsr);   -- QL Down

   -- byte 2: "]" z . c b "GBP" m '
   ql_matrix_real(8*2+0) <= not key_pressed_n(m65_arrow_up);    -- QL "]"
   ql_matrix_real(8*2+1) <= not key_pressed_n(m65_z);
   ql_matrix_real(8*2+2) <= not key_pressed_n(m65_dot);
   ql_matrix_real(8*2+3) <= not key_pressed_n(m65_c);
   ql_matrix_real(8*2+4) <= not key_pressed_n(m65_b);
   ql_matrix_real(8*2+5) <= not key_pressed_n(m65_gbp);
   ql_matrix_real(8*2+6) <= not key_pressed_n(m65_m);
   ql_matrix_real(8*2+7) <= not key_pressed_n(m65_colon);       -- QL "'"

   -- byte 3: "[" Caps k s f "=" g ;
   ql_matrix_real(8*3+0) <= not key_pressed_n(m65_arrow_left);  -- QL "["
   ql_matrix_real(8*3+1) <= not key_pressed_n(m65_capslock);
   ql_matrix_real(8*3+2) <= not key_pressed_n(m65_k);
   ql_matrix_real(8*3+3) <= not key_pressed_n(m65_s);
   ql_matrix_real(8*3+4) <= not key_pressed_n(m65_f);
   ql_matrix_real(8*3+5) <= not key_pressed_n(m65_equal);
   ql_matrix_real(8*3+6) <= not key_pressed_n(m65_g);
   ql_matrix_real(8*3+7) <= not key_pressed_n(m65_semicolon);

   -- byte 4: l 3 h 1 a p d j
   ql_matrix_real(8*4+0) <= not key_pressed_n(m65_l);
   ql_matrix_real(8*4+1) <= not key_pressed_n(m65_3);
   ql_matrix_real(8*4+2) <= not key_pressed_n(m65_h);
   ql_matrix_real(8*4+3) <= not key_pressed_n(m65_1);
   ql_matrix_real(8*4+4) <= not key_pressed_n(m65_a);
   ql_matrix_real(8*4+5) <= not key_pressed_n(m65_p);
   ql_matrix_real(8*4+6) <= not key_pressed_n(m65_d);
   ql_matrix_real(8*4+7) <= not key_pressed_n(m65_j);

   -- byte 5: 9 w i Tab r "-" y o
   ql_matrix_real(8*5+0) <= not key_pressed_n(m65_9);
   ql_matrix_real(8*5+1) <= not key_pressed_n(m65_w);
   ql_matrix_real(8*5+2) <= not key_pressed_n(m65_i);
   ql_matrix_real(8*5+3) <= not key_pressed_n(m65_tab);
   ql_matrix_real(8*5+4) <= not key_pressed_n(m65_r);
   ql_matrix_real(8*5+5) <= not key_pressed_n(m65_minus);
   ql_matrix_real(8*5+6) <= not key_pressed_n(m65_y);
   ql_matrix_real(8*5+7) <= not key_pressed_n(m65_o);

   -- byte 6: 8 2 6 q e 0 t u
   ql_matrix_real(8*6+0) <= not key_pressed_n(m65_8);
   ql_matrix_real(8*6+1) <= not key_pressed_n(m65_2);
   ql_matrix_real(8*6+2) <= not key_pressed_n(m65_6);
   ql_matrix_real(8*6+3) <= not key_pressed_n(m65_q);
   ql_matrix_real(8*6+4) <= not key_pressed_n(m65_e);
   ql_matrix_real(8*6+5) <= not key_pressed_n(m65_0);
   ql_matrix_real(8*6+6) <= not key_pressed_n(m65_t);
   ql_matrix_real(8*6+7) <= not key_pressed_n(m65_u);

   -- byte 7: Shift Ctrl Alt x v / n ,
   ql_matrix_real(8*7+0) <= ql_shift;
   ql_matrix_real(8*7+1) <= ql_ctrl;
   ql_matrix_real(8*7+2) <= ql_alt;
   ql_matrix_real(8*7+3) <= not key_pressed_n(m65_x);
   ql_matrix_real(8*7+4) <= not key_pressed_n(m65_v);
   ql_matrix_real(8*7+5) <= not key_pressed_n(m65_slash);
   ql_matrix_real(8*7+6) <= not key_pressed_n(m65_n);
   ql_matrix_real(8*7+7) <= not key_pressed_n(m65_comma);

   -- QL4M65 TEMPORARY TEST (M1021, see DBG_FORCE_IDLE_MATRIX declaration above)
   ql_matrix <= (others => '0') when DBG_FORCE_IDLE_MATRIX else ql_matrix_real;

   ---------------------------------------------------------------------------
   -- QL4M65 TEMPORARY DEBUG AID (M1020): sticky "this matrix byte (row) has
   -- shown at least one bit set" per row, continuously monitored (not tied
   -- to the IPC exchange at all) - checks for a phantom/stuck-pressed key
   -- independent of whether keyboard.vhd is even being asked for it.
   ---------------------------------------------------------------------------
   dbg_matrix_watch : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         if reset_i = '1' then
            dbg_matrix_seen <= (others => '0');
         else
            for b in 0 to 7 loop
               if ql_matrix(8*b+7 downto 8*b) /= "00000000" then
                  dbg_matrix_seen(b) <= '1';
               end if;
            end loop;
         end if;
      end if;
   end process dbg_matrix_watch;

   ---------------------------------------------------------------------------
   -- IPC comdata/comctrl protocol (see architecture-level comment above for
   -- the confidence level of each part of this)
   ---------------------------------------------------------------------------

   -- Free-running comctrl strobe: toggle level every 64 main_clk cycles
   -- (84 MHz/128 =~ 656 kHz full pulse rate - arbitrary but comfortably fast
   -- with clean margins; rtl/zx8302.v only needs clean edges, not a specific
   -- rate, since it has no baud-rate concept of its own, see header comment).
   comctrl_gen : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         if reset_i = '1' then
            phase_cnt  <= (others => '0');
            comctrl_r  <= '1';
            edge_pulse <= '0';
         else
            edge_pulse <= '0';
            phase_cnt  <= phase_cnt + 1;
            if phase_cnt = 0 then
               if comctrl_r = '1' then
                  edge_pulse <= '1';   -- about to fall: this IS the falling edge
               end if;
               comctrl_r <= not comctrl_r;
            end if;
         end if;
      end if;
   end process comctrl_gen;

   comctrl_o <= comctrl_r;

   -- Bit/unit/command tracking, advanced once per edge_pulse that lands on
   -- "edge 2" (the real bidirectional data exchange; edge 1 only consumes
   -- the CPU's Start bit and carries no information, see rtl/zx8302.v).
   --
   -- Unit length depends on state: CMD and ROWSEL are single 4-bit nibbles
   -- (verified: rtl/ipc8049.hex receives the command and the keyrow
   -- row-select each via one call to its 4-bit nibble-receive routine),
   -- RESPOND is a full 8-bit byte (two nibbles, high nibble first, in the
   -- real ROM). Bits are MSB-first throughout (verified in the ROM's
   -- receive/transmit routines), so both directions shift left with the new
   -- bit entering at the LSB - after N shifts, the first bit received/sent
   -- ends up as the most significant bit of the N-bit unit.
   ipc_fsm : process (clk_main_i)
      variable v_shift  : std_logic_vector(7 downto 0);
      variable v_unitlen : natural range 4 to 8;
   begin
      if rising_edge(clk_main_i) then
         if reset_i = '1' then
            edge_phase <= '0';
            bit_cnt    <= (others => '0');
            shift_in   <= (others => '0');
            resp_byte  <= (others => '1');
            cmd_state  <= CMD;
            dbg_last_cmd   <= (others => '0');
            dbg_seen_flags <= (others => '0');
         elsif edge_pulse = '1' then
            edge_phase <= not edge_phase;

            if edge_phase = '1' then   -- this pulse is edge 2: the real exchange
               if cmd_state = RESPOND then
                  v_unitlen := 8;
               else
                  v_unitlen := 4;   -- CMD and ROWSEL are both single nibbles
               end if;

               if cmd_state /= RESPOND then
                  -- receiving: MSB-first, shift left, new bit enters at LSB
                  v_shift := shift_in(6 downto 0) & comdata_i;
                  shift_in <= v_shift;
               end if;

               if bit_cnt = v_unitlen - 1 then
                  bit_cnt <= (others => '0');

                  case cmd_state is
                     -- command nibble ends up in shift_in(3 downto 0)
                     when CMD =>
                        dbg_last_cmd <= v_shift(3 downto 0);
                        if v_shift(3 downto 0) = x"9" then       -- "keyrow"
                           dbg_seen_flags(1) <= '1';
                           cmd_state <= ROWSEL;
                        elsif v_shift(3 downto 0) = x"8" then     -- "read keyboard"
                           dbg_seen_flags(0) <= '1';
                           resp_byte <= x"00";                    -- real encoding not reverse-engineered, safe stub
                           cmd_state <= RESPOND;
                        elsif v_shift(3 downto 0) = x"6" or v_shift(3 downto 0) = x"7" then
                           dbg_seen_flags(2) <= '1';
                           cmd_state <= CMD;
                        else                                      -- any other command: passive ACK
                           dbg_seen_flags(3) <= '1';
                           cmd_state <= CMD;
                        end if;

                     -- row-select nibble: its low 3 bits choose which of
                     -- the 8 ql_matrix bytes to answer with next
                     when ROWSEL =>
                        case to_integer(unsigned(v_shift(2 downto 0))) is
                           when 0 => resp_byte <= ql_matrix( 7 downto  0);
                           when 1 => resp_byte <= ql_matrix(15 downto  8);
                           when 2 => resp_byte <= ql_matrix(23 downto 16);
                           when 3 => resp_byte <= ql_matrix(31 downto 24);
                           when 4 => resp_byte <= ql_matrix(39 downto 32);
                           when 5 => resp_byte <= ql_matrix(47 downto 40);
                           when 6 => resp_byte <= ql_matrix(55 downto 48);
                           when others => resp_byte <= ql_matrix(63 downto 56);
                        end case;
                        cmd_state <= RESPOND;

                     when RESPOND =>
                        cmd_state <= CMD;
                  end case;
               else
                  bit_cnt <= bit_cnt + 1;
               end if;
            end if;
         end if;
      end if;
   end process ipc_fsm;

   -- Drive our answer bit only while actually responding, MSB-first (bit 7
   -- first); passive (released) otherwise, so we never interfere with a
   -- command/parameter nibble we don't recognise.
   comdata_o <= resp_byte(7 - to_integer(bit_cnt)) when cmd_state = RESPOND else '1';

   -- Not implemented (see entity port comments): no IPC-driven audio or
   -- interrupt-priority lines in milestone 1.
   audio_o <= '0';
   ipl_o   <= "00";

   -- QL4M65 TEMPORARY DEBUG AID (M1018/M1019/M1020)
   dbg_last_cmd_o    <= dbg_last_cmd;
   dbg_seen_flags_o  <= dbg_seen_flags;
   dbg_matrix_seen_o <= dbg_matrix_seen;

end architecture beh;
