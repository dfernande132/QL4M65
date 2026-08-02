# QL4M65: regenerate the QNICE firmware ROM (m2m-rom.rom) from
# m2m-rom.asm before every synthesis run, so a firmware-only edit can
# never silently ship stale - this bit us once (M1042: OSM_SEL_POST's
# auto-reset-on-ROM-change code was written but the .rom Vivado actually
# used was 9 days stale, from before the edit, because this hook was
# never wired into the .xpr's synth_1 run - see build_core.tcl's
# set_property STEPS.SYNTH_DESIGN.TCL.PRE and DECISIONES.md).
#
# Vivado itself runs natively on Windows here, but M2M/QNICE/assembler's
# qasm/qasm2rom are Linux ELF binaries (this project has no Windows build
# of the QNICE toolchain) and make_rom.sh's own OS-detection
# (M2M/QNICE/tools/detect.include) doesn't recognize Git Bash's
# MSYS/cygwin $OSTYPE either - so the rebuild has to happen inside WSL,
# not via a plain Tcl "exec" of the shell script.
# Tcl's "exec" raises an error on ANY stderr output, even with a 0 exit
# code - the C preprocessor's harmless warnings about apostrophes inside
# .asm comments (cpp isn't comment-aware) go to stderr and would abort
# the whole synth run otherwise, so fold stderr into stdout here.
exec wsl.exe -d Ubuntu -- bash -c "cd /mnt/e/QL_MEGA65/Fase0/CoreQL/CORE/m2m-rom && ./make_rom.sh 2>&1"
