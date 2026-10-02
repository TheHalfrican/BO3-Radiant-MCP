<#
.SYNOPSIS
  Logs every new process (command line, parent, start time) until stopped.
  Used in Phase 0 to capture the exact command lines the Mod Tools Launcher
  runs for compile, light, link, and run. No admin rights needed.

.EXAMPLE
  pwsh scripts/watch-processes.ps1 -OutFile launcher-capture.jsonl -Seconds 1800
#>
param(
  [Parameter(Mandatory)] [string] $OutFile,
  [int] $Seconds = 1800,
  [int] $IntervalMs = 100
)

$seen = @{}
Get-CimInstance Win32_Process | ForEach-Object { $seen[$_.ProcessId] = $_.CreationDate }

$deadline = (Get-Date).AddSeconds($Seconds)
Write-Host "Watching for new processes until $deadline. Writing to $OutFile"
while ((Get-Date) -lt $deadline) {
  foreach ($p in Get-CimInstance Win32_Process) {
    if ($seen.ContainsKey($p.ProcessId) -and $seen[$p.ProcessId] -eq $p.CreationDate) { continue }
    $seen[$p.ProcessId] = $p.CreationDate
    $parent = $null
    if ($seen.ContainsKey($p.ParentProcessId)) {
      $parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ParentProcessId)" -ErrorAction SilentlyContinue).Name
    }
    $rec = [ordered]@{
      time        = $p.CreationDate.ToString('o')
      pid         = $p.ProcessId
      ppid        = $p.ParentProcessId
      parent      = $parent
      name        = $p.Name
      exe         = $p.ExecutablePath
      commandLine = $p.CommandLine
    }
    ($rec | ConvertTo-Json -Compress) | Add-Content -Path $OutFile -Encoding utf8
    Write-Host ("{0}  {1}  {2}" -f $rec.time, $p.Name, $p.CommandLine)
  }
  Start-Sleep -Milliseconds $IntervalMs
}
