$env:PATH = "C:\Xilinx\Vivado\2022.2\bin;" + $env:PATH
cd "E:\QL_MEGA65\Fase0\CoreQL\.research\hyperbus-model-sim"

$results = @()
$delays = 0..30 | ForEach-Object { $_ * 2 }   # 0,2,4,...,60 ns
$modes  = @("false","true")

foreach ($mode in $modes) {
    foreach ($d in $delays) {
        $snap = "sw_$($mode)_$d"
        $elabCmd = "xelab tb_hyperbus_margin glbl -generic_top ""G_RWDS_SETTLE_DELAY_NS=$d.0"" -generic_top ""G_DEVICE_2X_LATENCY=$mode"" -s $snap -debug typical > elab_$snap.log 2>&1"
        cmd /c $elabCmd
        if (Select-String -Path "elab_$snap.log" -Pattern "ERROR" -Quiet) {
            $results += "delay_ns=$d 2x=$mode ELAB_ERROR"
            continue
        }
        $runCmd = "xsim $snap -log run_$snap.log -tclbatch sim_run.tcl > xsim_stdout_$snap.log 2>&1"
        cmd /c $runCmd
        $line = Select-String -Path "run_$snap.log" -Pattern "TB_HYPERBUS_MARGIN_RESULT" | Select-Object -First 1
        if ($line) {
            $results += $line.Line.Trim()
        } else {
            $failmsg = Select-String -Path "run_$snap.log" -Pattern "avm_waitrequest never dropped|avm_readdatavalid never arrived" | Select-Object -First 1
            if ($failmsg) {
                $results += "delay_ns=$d 2x=$mode TIMEOUT: $($failmsg.Line.Trim())"
            } else {
                $results += "delay_ns=$d 2x=$mode UNKNOWN (no result line)"
            }
        }
        Remove-Item -Recurse -Force "xsim.dir\$snap" -ErrorAction SilentlyContinue
        Remove-Item -Force "$snap.wdb" -ErrorAction SilentlyContinue
        Remove-Item -Force "elab_$snap.log","xsim_stdout_$snap.log" -ErrorAction SilentlyContinue
    }
}

$results | Out-File -FilePath "sweep_results.txt" -Encoding utf8
$results | ForEach-Object { Write-Output $_ }
