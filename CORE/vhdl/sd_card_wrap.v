//----------------------------------------------------------------------------
// Sinclair QL for MEGA65 (QL4M65)
//
// sd_card_wrap: Vivado-clean, fully-literal port view of sys/sd_card.sv
//
// WHY THIS FILE EXISTS (Milestone 4, QL-SD, M4008):
//
// sd_card.sv declares the widths of several of its ports using localparams
// that are themselves declared AFTER the port list:
//
//    input      [AW:0] sd_buff_addr,     // sd_card.sv:42
//    input      [DW:0] sd_buff_dout,     // sd_card.sv:43
//    output     [DW:0] sd_buff_din,      // sd_card.sv:44
//    input      [SW:0] mosi,             // sd_card.sv:52
//    output reg [SW:0] miso,             // sd_card.sv:53
//    ...
//    localparam AW = WIDE  ?  7 : 8;     // sd_card.sv:70-73
//    localparam DW = WIDE  ? 15 : 7;
//    localparam SZ = OCTAL ?  8 : 1;
//    localparam SW = SZ-1;
//
// That is tolerated when the module is instantiated from Verilog (which is
// what the original core does, QL.sv:287) but it silently breaks Vivado's
// mixed-language VHDL -> SystemVerilog binding: Vivado builds the VHDL-facing
// port view from the port list alone, cannot resolve AW/DW/SW there, and
// connects NOTHING. The instance elaborates without an error, and every
// output of the module comes back as an undriven net:
//
//    [Synth 8-6901] identifier 'AW' is used before its declaration [sd_card.sv:42]
//    [Synth 8-3848] Net qlsd_spi_do  ... does not have driver.
//    [Synth 8-3848] Net qlsd_sd_lba  ... does not have driver.
//    [Synth 8-3848] Net qlsd_sd_rd   ... does not have driver.
//    [Synth 8-3848] Net qlsd_sd_wr   ... does not have driver.
//    [Synth 8-3848] Net qlsd_ram_a_* / qlsd_ram_b_* ... does not have driver.
//
// i.e. the whole SD-card emulator was absent from the built design: MISO was
// a constant, so the QL-SD driver's own CMD0/CMD8/ACMD41 never got a valid
// reply and it reported "H/W v1: Card 1 not found" on every boot, and the
// block-level side (sd_rd/sd_ack) never moved, so vdrives.vhd was never
// asked for a single sector. Builds M4001-M4007 all debugged a module that
// was not actually connected. See DECISIONES.md, "Milestone 4".
//
// rtl/mdv.v is also Verilog-instantiated-from-VHDL and binds correctly - its
// own [Synth 8-6901] warnings are for signals in the module BODY, never for
// port widths, which is exactly the difference that matters here.
//
// This wrapper fixes it without touching sd_card.sv's own genericity: it
// presents a port list whose widths are all literal constants (the WIDE=0 /
// OCTAL=0 configuration this project always uses - see
// .research/qlsd-design.md and doc/m2m/exceptions.md for why WIDE must be 0
// to match vdrives.vhd's fixed 8-bit side), and instantiates the real
// sd_card from Verilog, the way the original core does. Same "Vivado-clean
// shim around an upstream module" pattern already used by ipc_rom_t49.vhd
// and mdv_dpram.vhd.
//
// Note mosi/miso: with OCTAL=0, SW=0, so sd_card.sv declares them as 1-bit
// VECTORS ([0:0]). They are plain scalars here, which is what main.vhd's
// std_logic signals actually want.
//
// QL4M65 port done by Jose Daniel Fernandez Santos (dfsantos) in 2026 and
// licensed under GPL v3
//----------------------------------------------------------------------------

module sd_card_wrap
(
	input             clk_sys,
	input             reset,

	input             sdhc,
	input             img_mounted,
	input      [63:0] img_size,

	output     [31:0] sd_lba,
	output            sd_rd,
	output            sd_wr,
	input             sd_ack,

	input       [8:0] sd_buff_addr,
	input       [7:0] sd_buff_dout,
	output      [7:0] sd_buff_din,
	input             sd_buff_wr,

	// SPI interface
	input             clk_spi,

	input             ss,
	input             sck,
	input             mosi,
	output            miso,

	// sd_card.sv's own internal "sdbuf" RAM, instantiated externally
	// (dualport_2clk_ram in main.vhd) - see doc/m2m/exceptions.md
	output     [10:0] ram_a_addr_o,
	output      [7:0] ram_a_data_o,
	output            ram_a_wren_o,
	input       [7:0] ram_a_q_i,

	output     [10:0] ram_b_addr_o,
	output      [7:0] ram_b_data_o,
	output            ram_b_wren_o,
	input       [7:0] ram_b_q_i
);

sd_card #(.WIDE(0), .OCTAL(0)) sd_card_inst
(
	.clk_sys      (clk_sys),
	.reset        (reset),

	.sdhc         (sdhc),
	.img_mounted  (img_mounted),
	.img_size     (img_size),

	.sd_lba       (sd_lba),
	.sd_rd        (sd_rd),
	.sd_wr        (sd_wr),
	.sd_ack       (sd_ack),

	.sd_buff_addr (sd_buff_addr),
	.sd_buff_dout (sd_buff_dout),
	.sd_buff_din  (sd_buff_din),
	.sd_buff_wr   (sd_buff_wr),

	.clk_spi      (clk_spi),

	.ss           (ss),
	.sck          (sck),
	.mosi         (mosi),
	.miso         (miso),

	.ram_a_addr_o (ram_a_addr_o),
	.ram_a_data_o (ram_a_data_o),
	.ram_a_wren_o (ram_a_wren_o),
	.ram_a_q_i    (ram_a_q_i),

	.ram_b_addr_o (ram_b_addr_o),
	.ram_b_data_o (ram_b_data_o),
	.ram_b_wren_o (ram_b_wren_o),
	.ram_b_q_i    (ram_b_q_i)
);

endmodule
