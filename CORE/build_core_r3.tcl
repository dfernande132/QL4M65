# QL4M65: R3 board variant of build_core.tcl. CORE-R3.xpr was created from
# the same M2M scaffold as CORE-R6.xpr and already shares the board-agnostic
# CORE files (vhdl/main.vhd, mega65.vhd, config.vhd, globals.vhd,
# keyboard.vhd, clk.vhd, CORE.xdc - all referenced by literal shared path,
# not per-board copies) plus its own correct R3-specific top-level/XDC
# (M2M/vhdl/top_mega65-r3.vhd, M2M/MEGA65-R3.xdc) and its own correct
# R3-specific audio path (M2M/vhdl/controllers/M65/pcm_to_pdm.vhdl - R3 uses
# direct PWM/PDM audio, not the I2S DAC chip R6's controllers/M65/audio.vhd
# drives, confirmed by reading top_mega65-r3.vhd's own instantiation).
#
# What CORE-R3.xpr never received, because build_core.tcl only ever targeted
# CORE-R6.xpr: every QL-specific RTL file added incrementally after the
# initial scaffold (confirmed by diffing both .xpr files' <File Path=...>
# entries - the gap is exactly this script's own add_files calls, nothing
# more, nothing R3-specific missing). This build has never been tested on
# real R3 hardware - see DECISIONES.md's M2024 section.
set_param general.maxThreads 8

open_project {E:/QL_MEGA65/Fase0/CoreQL/CORE/CORE-R3.xpr}

# QL4M65 Milestone 3, Fase 1 (2026-08-23): same hold-margin fix as
# build_core.tcl's own R6 flow - see that file's comment for the full
# diagnosis (hr_rwds domain, HyperRAM read-data capture, WHS=+0.011ns with
# the default strategy vs +0.213ns with this one, ~19x more margin, no RTL
# change). Applied here too so R3's own eventual release build gets the
# same benefit, not just R6's dev builds.
set_property strategy {Performance_ExplorePostRoutePhysOpt} [get_runs impl_1]

set_property STEPS.SYNTH_DESIGN.TCL.PRE {E:/QL_MEGA65/Fase0/CoreQL/CORE/m2m-rom/synth_pre.tcl} [get_runs synth_1]

set core_ql_dir {E:/QL_MEGA65/Fase0/CoreQL/CORE/QL_MiSTer}
set core_vhdl_dir {E:/QL_MEGA65/Fase0/CoreQL/CORE/vhdl}
set t48_dir "$core_ql_dir/rtl/T48"

add_files -norecurse -fileset sources_1 [list \
    "E:/QL_MEGA65/Fase0/CoreQL/M2M/vhdl/qnice_csr.vhd" \
]
set_property file_type {VHDL 2008} [get_files "E:/QL_MEGA65/Fase0/CoreQL/M2M/vhdl/qnice_csr.vhd"]

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
set_property file_type SystemVerilog [get_files "$core_ql_dir/rtl/zx8301.v"]
set_property file_type SystemVerilog [get_files "$core_ql_dir/rtl/zx8302.v"]

add_files -norecurse -fileset sources_1 [list \
    "$core_ql_dir/rtl/mdv.v" \
    "$core_vhdl_dir/mdv_dpram.vhd" \
]
set_property file_type SystemVerilog [get_files "$core_ql_dir/rtl/mdv.v"]

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
