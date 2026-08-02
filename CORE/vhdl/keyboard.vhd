---------------------------------------------------------------------------------------------------------
-- Sinclair QL for MEGA65 (QL4M65)
--
-- MEGA65 keyboard -> QL 8x8 keyboard matrix
--
-- Reuses the exact byte/bit layout of the original rtl/keyboard.v's "matrix"
-- output, just fed from M2M's key_num_i/key_pressed_n_i instead of ps2_key -
-- this is exactly the same interface rtl/ipc.v itself expects from
-- rtl/keyboard.v (a one-hot P1 row select reading back one matrix byte,
-- see ipc.vhd).
--
-- QL4M65 (M1031): this file used to ALSO implement the ZX8302 comdata/comctrl
-- IPC protocol by hand (M1001-M1030), reverse-engineered from a from-scratch
-- disassembly of rtl/ipc8049.hex. That turned out to be the wrong approach:
-- real Minerva never even calls the one command that reimplementation got
-- right (9, "keyrow") - everything is gated behind command 1's status byte
-- bit 0 ("keyboard event pending"), which was always answered clear, and the
-- real keyboard read (command 8) is a stateful event QUEUE that was never
-- implemented at all. Rather than re-derive that whole protocol by hand a
-- second time, the IPC is now the REAL emulated Intel 8049 (see ipc.vhd),
-- running the real firmware ROM - exactly what rtl/ipc.v does. This file's
-- job shrank back to just the keyboard-matrix translation (part 1 of the
-- original two-commit design); all comdata/comctrl/command logic (part 2)
-- was removed. See DECISIONES.md for the full investigation and the M1029/
-- M1030/M1031 history.
--
-- QL4M65 (post-M1044): symbol keys were redesigned to be "MEGA65-native" -
-- whatever a MEGA65 key's own legend shows is what it types on the QL,
-- rather than whatever the real Sinclair QL keyboard has in that physical
-- position. Full rationale, the complete key-by-key table and the QL/MEGA65
-- keyboard photos this was checked against: .research/
-- keyboard-mapping-design.md (decided together with the user in chat).
-- Summary of the technique: several MEGA65 keys now drive a QL matrix bit
-- that is NOT their own "natural" QL counterpart, with ql_shift/ql_ctrl
-- forced to a specific value for that combo regardless of the real MEGA65
-- modifier state - same technique the F1/F3->F2/F4 combo already used
-- before this redesign (suppressing ql_shift while the combo is active).
--
-- Key mapping notes still applying from before this redesign:
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

      -- The QL's 8x8 keyboard matrix (see ipc.vhd, which feeds this to the
      -- real emulated 8049's P1-selected data bus exactly as rtl/ipc.v does)
      ql_matrix_o      : out std_logic_vector(63 downto 0)
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
   constant m65_arrow_left    : integer := 57;  -- symbol, not cursor - genuinely idle, see below
   constant m65_ctrl          : integer := 58;
   constant m65_2             : integer := 59;
   constant m65_space         : integer := 60;
   constant m65_mega          : integer := 61;
   constant m65_q             : integer := 62;
   constant m65_run_stop      : integer := 63;
   constant m65_no_scrl       : integer := 64;  -- genuinely idle, see below
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
   signal shift      : std_logic;  -- either MEGA65 shift key held
   signal mega_ctrl  : std_logic;  -- MEGA65's own Ctrl key only (not the INS/DEL synth below)
   signal ql_shift   : std_logic;
   signal ql_ctrl    : std_logic;
   signal ql_alt     : std_logic;
   signal ql_f1      : std_logic;
   signal ql_f2      : std_logic;
   signal ql_f3      : std_logic;
   signal ql_f4      : std_logic;
   signal ql_f5      : std_logic;

   -- QL4M65 keyboard redesign (.research/keyboard-mapping-design.md):
   -- several MEGA65 keys now donate their Shift or Ctrl legend to a QL
   -- symbol that isn't reachable any other way (e.g. Ctrl+"," -> "~",
   -- because MEGA65's own comma key shows a small tilde). Whenever one of
   -- those donor combos is active, ql_shift/ql_ctrl must show the QL the
   -- SPECIFIC state the target character needs, not whatever the real
   -- MEGA65 modifier keys happen to be doing.
   signal ql_shift_force1    : std_logic;
   signal ql_shift_force0    : std_logic;
   signal ctrl_donor_active  : std_logic;

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
   signal ql_matrix : std_logic_vector(63 downto 0);

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
   shift     <= not (key_pressed_n(m65_left_shift) and key_pressed_n(m65_right_shift));
   mega_ctrl <= not key_pressed_n(m65_ctrl);

   -- F1/F3/F5 physical keys (labelled "F1/F2", "F3/F4", "F5/F6" on the
   -- keycap, like a C64 keyboard) each provide two QL function keys via
   -- Shift; F5 provides only F5 (the QL has no F6+)
   ql_f1 <= not key_pressed_n(m65_f1) and not shift;
   ql_f2 <= not key_pressed_n(m65_f1) and shift;
   ql_f3 <= not key_pressed_n(m65_f3) and not shift;
   ql_f4 <= not key_pressed_n(m65_f3) and shift;
   ql_f5 <= not key_pressed_n(m65_f5);

   ql_alt <= not key_pressed_n(m65_alt);

   -- QL4M65 keyboard redesign: which MEGA65 keys are currently "donating"
   -- their Ctrl legend to a symbol elsewhere in the matrix (see the big
   -- table below and .research/keyboard-mapping-design.md). While any of
   -- these is active, the real MEGA65 Ctrl key must NOT also reach the
   -- QL's own Ctrl matrix bit, or the QL would see two keys at once.
   ctrl_donor_active <= mega_ctrl and (
                            (not key_pressed_n(m65_comma))     or   -- -> GBP ("~")
                            (not key_pressed_n(m65_equal))     or   -- -> "-" ("_")
                            (not key_pressed_n(m65_slash))     or   -- -> "\"
                            (not key_pressed_n(m65_colon))     or   -- -> "[" ("{")
                            (not key_pressed_n(m65_semicolon)) or   -- -> "]" ("}")
                            (not key_pressed_n(m65_dot))            -- -> "\" ("|")
                         );

   -- Same idea for ql_shift: MEGA65 combos that need the QL to see a
   -- SPECIFIC shift state regardless of the real MEGA65 shift/ctrl keys.
   -- force1 covers characters only reachable via a QL-shifted key that the
   -- MEGA65 side doesn't naturally reach with real shift held; force0
   -- covers the reverse (real MEGA65 shift held, but the target QL key
   -- needs to look unshifted). See the big table below for which MEGA65
   -- combo needs which.
   ql_shift_force1 <= (not key_pressed_n(m65_at) and not shift)              -- "@" (was QL-native Shift+2)
                   or  (not key_pressed_n(m65_asterisk))                     -- "*" (was QL-native Shift+8)
                   or  (not key_pressed_n(m65_plus))                        -- "+" (was QL-native Shift+=)
                   or  (not key_pressed_n(m65_colon) and mega_ctrl)          -- "{"
                   or  (not key_pressed_n(m65_semicolon) and mega_ctrl)      -- "}"
                   or  (not key_pressed_n(m65_comma) and mega_ctrl)          -- "~"
                   or  (not key_pressed_n(m65_equal) and mega_ctrl)          -- "_"
                   or  (not key_pressed_n(m65_dot) and mega_ctrl)            -- "|"
                   or  (not key_pressed_n(m65_arrow_up));                   -- "^" (was QL-native Shift+6)

   ql_shift_force0 <= (not key_pressed_n(m65_7) and shift)                                    -- "'" (was QL-native Shift+7's "&")
                   or  (not key_pressed_n(m65_colon) and shift and not mega_ctrl)              -- "["
                   or  (not key_pressed_n(m65_semicolon) and shift and not mega_ctrl)          -- "]"
                   or  (not key_pressed_n(m65_slash) and mega_ctrl);                           -- "\"

   -- QL SHIFT is suppressed while the F1/F3 combo is driving F2/F4, same as
   -- before this redesign; the two new force conditions take priority over
   -- everything else (mutually exclusive triggers - different physical
   -- MEGA65 keys - so priority order between force0/force1 never matters
   -- in practice).
   ql_shift <= '0' when ql_shift_force0 = '1' else
               '1' when ql_shift_force1 = '1' else
               shift and key_pressed_n(m65_f1) and key_pressed_n(m65_f3);

   ql_ctrl <= ((not key_pressed_n(m65_ctrl)) or ins_del_ctrl) and not ctrl_donor_active;

   ---------------------------------------------------------------------------
   -- MEGA65 key -> QL keyboard matrix
   --
   -- Byte/bit layout copied from rtl/keyboard.v's "matrix" output, unchanged
   -- so ipc.vhd can serve it exactly as rtl/ipc.v's P1-select/data-bus-read
   -- logic expects from the real 8049.
   --
   -- QL4M65 keyboard redesign: MEGA65-native symbols (see header comment
   -- and .research/keyboard-mapping-design.md). Several bits below are now
   -- driven by more than one MEGA65 key/modifier combo - each contributing
   -- term is commented with the character it produces. Guards like
   -- "and not shift" appear wherever a key's own unmodified/shifted/
   -- ctrl'd role was reassigned elsewhere, so only one QL matrix bit is
   -- ever asserted for a given physical MEGA65 keypress.
   ---------------------------------------------------------------------------

   -- byte 0: F4 F1 "5" F2 F3 F5 "4" "7"
   ql_matrix(8*0+0) <= ql_f4;
   ql_matrix(8*0+1) <= ql_f1;
   ql_matrix(8*0+2) <= not key_pressed_n(m65_5);
   ql_matrix(8*0+3) <= ql_f2;
   ql_matrix(8*0+4) <= ql_f3;
   ql_matrix(8*0+5) <= ql_f5;
   ql_matrix(8*0+6) <= not key_pressed_n(m65_4);
   ql_matrix(8*0+7) <= (not key_pressed_n(m65_7) and not shift)              -- "7"
                    or (not key_pressed_n(m65_6) and shift);                -- "&" (MEGA65 Shift+6)

   -- byte 1: Ret Left Up Esc Right "\" Space Down
   ql_matrix(8*1+0) <= not key_pressed_n(m65_return);
   ql_matrix(8*1+1) <= (not key_pressed_n(m65_left_crsr)) or ins_del_left;
   ql_matrix(8*1+2) <= not key_pressed_n(m65_up_crsr);
   ql_matrix(8*1+3) <= (not key_pressed_n(m65_esc))                          -- Esc
                    or (not key_pressed_n(m65_at) and shift);               -- "(c)" (MEGA65 Shift+@)
   ql_matrix(8*1+4) <= not key_pressed_n(m65_horz_crsr);   -- QL Right
   ql_matrix(8*1+5) <= (not key_pressed_n(m65_slash) and mega_ctrl)          -- "\" (MEGA65 Ctrl+/)
                    or (not key_pressed_n(m65_dot) and mega_ctrl);          -- "|" (MEGA65 Ctrl+.)
   ql_matrix(8*1+6) <= not key_pressed_n(m65_space);
   ql_matrix(8*1+7) <= not key_pressed_n(m65_vert_crsr);   -- QL Down

   -- byte 2: "]" z . c b "GBP" m '
   ql_matrix(8*2+0) <= (not key_pressed_n(m65_semicolon) and (shift or mega_ctrl)); -- "]" (Shift+;) / "}" (Ctrl+;)
   ql_matrix(8*2+1) <= not key_pressed_n(m65_z);
   ql_matrix(8*2+2) <= not key_pressed_n(m65_dot) and not mega_ctrl;
   ql_matrix(8*2+3) <= not key_pressed_n(m65_c);
   ql_matrix(8*2+4) <= not key_pressed_n(m65_b);
   ql_matrix(8*2+5) <= (not key_pressed_n(m65_gbp))                          -- GBP (incl. its own native Shift -> "~")
                    or (not key_pressed_n(m65_comma) and mega_ctrl);         -- "~" (MEGA65 Ctrl+,)
   ql_matrix(8*2+6) <= not key_pressed_n(m65_m);
   ql_matrix(8*2+7) <= (not key_pressed_n(m65_colon) and not shift and not mega_ctrl) -- "'" (MEGA65 colon, unmodified)
                    or (not key_pressed_n(m65_2) and shift)                 -- '"' (MEGA65 Shift+2)
                    or (not key_pressed_n(m65_7) and shift);                -- "'" (MEGA65 Shift+7)

   -- byte 3: "[" Caps k s f "=" g ;
   ql_matrix(8*3+0) <= (not key_pressed_n(m65_colon) and (shift or mega_ctrl)); -- "[" (Shift+:) / "{" (Ctrl+:)
   ql_matrix(8*3+1) <= not key_pressed_n(m65_capslock);
   ql_matrix(8*3+2) <= not key_pressed_n(m65_k);
   ql_matrix(8*3+3) <= not key_pressed_n(m65_s);
   ql_matrix(8*3+4) <= not key_pressed_n(m65_f);
   ql_matrix(8*3+5) <= (not key_pressed_n(m65_equal) and not mega_ctrl)      -- "=" (incl. its own native Shift -> "+")
                    or (not key_pressed_n(m65_plus));                       -- "+" (MEGA65's own dedicated + key)
   ql_matrix(8*3+6) <= not key_pressed_n(m65_g);
   ql_matrix(8*3+7) <= not key_pressed_n(m65_semicolon) and not shift and not mega_ctrl;

   -- byte 4: l 3 h 1 a p d j
   ql_matrix(8*4+0) <= not key_pressed_n(m65_l);
   ql_matrix(8*4+1) <= not key_pressed_n(m65_3);
   ql_matrix(8*4+2) <= not key_pressed_n(m65_h);
   ql_matrix(8*4+3) <= not key_pressed_n(m65_1);
   ql_matrix(8*4+4) <= not key_pressed_n(m65_a);
   ql_matrix(8*4+5) <= not key_pressed_n(m65_p);
   ql_matrix(8*4+6) <= not key_pressed_n(m65_d);
   ql_matrix(8*4+7) <= not key_pressed_n(m65_j);

   -- byte 5: 9 w i Tab r "-" y o
   ql_matrix(8*5+0) <= (not key_pressed_n(m65_9) and not shift)              -- "9"
                    or (not key_pressed_n(m65_8) and shift);                -- "(" (MEGA65 Shift+8)
   ql_matrix(8*5+1) <= not key_pressed_n(m65_w);
   ql_matrix(8*5+2) <= not key_pressed_n(m65_i);
   ql_matrix(8*5+3) <= not key_pressed_n(m65_tab);
   ql_matrix(8*5+4) <= not key_pressed_n(m65_r);
   ql_matrix(8*5+5) <= (not key_pressed_n(m65_minus))                        -- "-" (incl. its own native Shift -> "_")
                    or (not key_pressed_n(m65_equal) and mega_ctrl);         -- "_" (MEGA65 Ctrl+=)
   ql_matrix(8*5+6) <= not key_pressed_n(m65_y);
   ql_matrix(8*5+7) <= not key_pressed_n(m65_o);

   -- byte 6: 8 2 6 q e 0 t u
   ql_matrix(8*6+0) <= (not key_pressed_n(m65_8) and not shift)              -- "8"
                    or (not key_pressed_n(m65_asterisk));                   -- "*" (MEGA65's own dedicated * key)
   ql_matrix(8*6+1) <= (not key_pressed_n(m65_2) and not shift)              -- "2"
                    or (not key_pressed_n(m65_at) and not shift);           -- "@" (MEGA65's own dedicated @ key)
   ql_matrix(8*6+2) <= (not key_pressed_n(m65_6) and not shift)              -- "6"
                    or (not key_pressed_n(m65_arrow_up));                   -- "^" (MEGA65's spare arrow-up-symbol key)
   ql_matrix(8*6+3) <= not key_pressed_n(m65_q);
   ql_matrix(8*6+4) <= not key_pressed_n(m65_e);
   ql_matrix(8*6+5) <= (not key_pressed_n(m65_0))                            -- "0" (incl. its own native Shift -> ")")
                    or (not key_pressed_n(m65_9) and shift);                -- ")" (MEGA65 Shift+9)
   ql_matrix(8*6+6) <= not key_pressed_n(m65_t);
   ql_matrix(8*6+7) <= not key_pressed_n(m65_u);

   -- byte 7: Shift Ctrl Alt x v / n ,
   ql_matrix(8*7+0) <= ql_shift;
   ql_matrix(8*7+1) <= ql_ctrl;
   ql_matrix(8*7+2) <= ql_alt;
   ql_matrix(8*7+3) <= not key_pressed_n(m65_x);
   ql_matrix(8*7+4) <= not key_pressed_n(m65_v);
   ql_matrix(8*7+5) <= not key_pressed_n(m65_slash) and not mega_ctrl;
   ql_matrix(8*7+6) <= not key_pressed_n(m65_n);
   ql_matrix(8*7+7) <= not key_pressed_n(m65_comma) and not mega_ctrl;

   ql_matrix_o <= ql_matrix;

end architecture beh;
