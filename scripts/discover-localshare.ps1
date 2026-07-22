param(
  [string]$Service = "localshare",
  [int]$TimeoutSeconds = 10,
  [switch]$Open,
  [switch]$NoTouch
)

$dnsSd = Get-Command dns-sd -ErrorAction SilentlyContinue
if (-not $dnsSd) {
  Write-Error "dns-sd not found. Install Bonjour / Apple Bonjour Print Services."
  exit 1
}

$job = Start-Job -ScriptBlock {
  param($Service)
  & dns-sd -L $Service _http._tcp local
} -ArgumentList $Service

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$url = $null

try {
  while ((Get-Date) -lt $deadline) {
    $lines = Receive-Job $job
    foreach ($line in $lines) {
      if ($line -match "can be reached at\s+(.+?)\.?\s*:\s*(\d+)") {
        $hostName = $matches[1].TrimEnd(".")
        $port = $matches[2]
        $url = "http://${hostName}:${port}/"
        break
      }
    }
    if ($url) { break }
    Start-Sleep -Milliseconds 100
  }
} finally {
  Stop-Job $job -ErrorAction SilentlyContinue | Out-Null
  Remove-Job $job -Force -ErrorAction SilentlyContinue | Out-Null
}

if (-not $url) {
  Write-Error "Timed out after ${TimeoutSeconds}s waiting for ${Service}._http._tcp.local"
  exit 1
}

Write-Output $url

if (-not $NoTouch) {
  Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSeconds | Out-Null
}

if ($Open) {
  Start-Process $url
}
