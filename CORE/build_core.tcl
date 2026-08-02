# Windows defaults general.maxThreads to 2 (Linux defaults to 8) - Vivado's
# own hard cap is 8 regardless of how many CPU cores are available, and each
# command has its own further internal cap (synth_design: 4, route_design: 8).
# Setting this to the max lets synthesis go 2->4 threads and routing 2->8.
set_param general.maxThreads 8

open_project {E:/QL_MEGA65/Fase0/CoreQL/CORE/CORE-R6.xpr}

set core_ql_dir {E:/QL_MEGA65/Fase0/CoreQL/CORE/QL_MiSTer}
set core_vhdl_dir {E:/QL_MEGA65/Fase0/CoreQL/CORE/vhdl}
set t48_dir "$core_ql_dir/rtl/T48"

add_files -norecurse -fileset sources_1 [list \
    "$core_ql_dir/rtl/fx68k/fx68k.sv" \
    "$core_ql_dir/rtl/fx68k/fx68kAlu.sv" \
    "$core_ql_dir/rtl/fx68k/uaddrPla.sv" \
    "$core_ql_dir/rtl/fx68k/microrom.mem" \
    "$core_ql_dir/rtl/fx68k/nanorom.mem" \
    "$core_ql_dir/rtl/zx8301.v" \
    "$core_ql_dir/rtl/zx8302.v" \
    "$core_ql_dir/rtl/ql_timing.sv" \
]

# QL4M65 (M1031): the real emulated IPC (Intel 8049) - T48 core (OpenCores
# project, plain VHDL, 100% unmodified) replacing keyboard.vhd's own
# M1018-M1030 hand-rolled comdata/comctrl protocol FSM. File list taken
# verbatim from the original project's own compile list
# (rtl/T48/T8049.qip) - not guessed. ipc.vhd/ipc_rom_t49.vhd are QL4M65's
# own new glue files (see their headers); ipc_rom_t49.vhd provides a
# Vivado-clean "rom_t49" so t49_rom-struct-a.vhd (below, unmodified) never
# sees the Altera-only rtl/rom_t49.vhd this project doesn't add.
add_files -norecurse -fileset sources_1 [list \
    "$t48_dir/t49_rom-struct-a.vhd" \
    "$t48_dir/system/t49_rom-e.vhd" \
    "$t48_dir/system/generic_ram_ena.vhd" \
    "$t48_dir/decoder_pack-p.vhd" \
    "$t48_dir/timer.vhd" \
    "$t48_dir/t48_core_comp_pack-p.vhd" \
    "$t48_dir/t48_pack-p.vhd" \
    "$t48_dir/t48_comp_pack-p.vhd" \
    "$t48_dir/psw.vhd" \
    "$t48_dir/pmem_ctrl_pack-p.vhd" \
    "$t48_dir/pmem_ctrl.vhd" \
    "$t48_dir/p2.vhd" \
    "$t48_dir/p1.vhd" \
    "$t48_dir/opc_table.vhd" \
    "$t48_dir/opc_decoder.vhd" \
    "$t48_dir/int.vhd" \
    "$t48_dir/decoder.vhd" \
    "$t48_dir/db_bus.vhd" \
    "$t48_dir/clock_ctrl.vhd" \
    "$t48_dir/bus_mux.vhd" \
    "$t48_dir/alu_pack-p.vhd" \
    "$t48_dir/dmem_ctrl.vhd" \
    "$t48_dir/dmem_ctrl_pack-p.vhd" \
    "$t48_dir/cond_branch_pack-p.vhd" \
    "$t48_dir/cond_branch.vhd" \
    "$t48_dir/alu.vhd" \
    "$t48_dir/t48_core.vhd" \
    "$t48_dir/t8049_notri.vhd" \
    "$core_vhdl_dir/ipc_rom_t49.vhd" \
    "$core_vhdl_dir/ipc.vhd" \
]

set_property file_type SystemVerilog [get_files "$core_ql_dir/rtl/fx68k/fx68k.sv"]
set_property file_type SystemVerilog [get_files "$core_ql_dir/rtl/fx68k/fx68kAlu.sv"]
set_property file_type SystemVerilog [get_files "$core_ql_dir/rtl/fx68k/uaddrPla.sv"]
set_property file_type SystemVerilog [get_files "$core_ql_dir/rtl/ql_timing.sv"]
# QL4M65: zx8301.v/zx8302.v use "declare a reg inside an unnamed always block"
# (legal SystemVerilog, rejected by Vivado's stricter plain-Verilog-2001
# parser) - marking them SystemVerilog instead of Verilog fixes this without
# touching the original files at all (build-setting only, not a code change).
set_property file_type SystemVerilog [get_files "$core_ql_dir/rtl/zx8301.v"]
set_property file_type SystemVerilog [get_files "$core_ql_dir/rtl/zx8302.v"]

# QL4M65: mdv.v was added in a previous attempt but is no longer instantiated
# by zx8302.v (see its header note) - remove it if Vivado still has it from
# an earlier run of this script.
if {[llength [get_files -quiet "$core_ql_dir/rtl/mdv.v"]] > 0} {
    remove_files "$core_ql_dir/rtl/mdv.v"
}

update_compile_order -fileset sources_1

reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
puts "SYNTH_STATUS=$synth_status"
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "RESULT=SYNTH_FAILED"
    close_project
    exit 1
}

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
puts "IMPL_STATUS=$impl_status"
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "RESULT=IMPL_FAILED"
    close_project
    exit 1
}

puts "RESULT=BUILD_OK"
close_project
exit 0
