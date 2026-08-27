$env:PATH = "C:\Xilinx\Vivado\2022.2\bin;" + $env:PATH
cd "E:\QL_MEGA65\Fase0\CoreQL\.research\hyperbus-model-sim"

$results = @()
$delays = 26..28

foreach ($d in $delays) {
    $snap = "swf_$d"
    $elabCmd = "xelab tb_hyperbus_margin glbl -generic_top ""G_RWDS_SETTLE_DELAY_NS=$d.0"" -generic_top ""G_DEVICE_2X_LATENCY=false"" -s $snap -debug typical > elab_$snap.log 2>&1"
    cmd /c $elabCmd
    $runCmd = "xsim $snap -log run_$snap.log -tclbatch sim_run.tcl > xsim_stdout_$snap.log 2>&1"
    cmd /c $runCmd
    $line = Select-String -Path "run_$snap.log" -Pattern "TB_HYPERBUS_MARGIN_RESULT" | Select-Object -First 1
    $results += $line.Line.Trim()
    Remove-Item -Recurse -Force "xsim.dir\$snap" -ErrorAction SilentlyContinue
    Remove-Item -Force "$snap.wdb" -ErrorAction SilentlyContinue
    Remove-Item -Force "elab_$snap.log","xsim_stdout_$snap.log" -ErrorAction SilentlyContinue
}
$results | Out-File -FilePath "sweep_fine_results.txt" -Encoding utf8
$results | ForEach-Object { Write-Output $_ }
