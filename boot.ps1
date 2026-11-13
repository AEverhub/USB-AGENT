param([string]$Base = '')
# Agent 中控中心 × T-Dongle-S3：插上就能用的引導程式（Windows）
#  1. 找到 Dongle 的 TF 卡是哪個磁碟
#  2. TF 卡上沒有軟體、或網路上有新版 → 下載（比對官方 SHA-256）、解壓到 TF 卡（data 資料夾不動）
#  3. 啟動 AgentCenter
#  進度都會顯示在 Dongle 的小螢幕上。
#  $Base：放 latest.json、AgentCenter-USB-*.zip、boot.ps1 的網址（結尾要有 /）；沒給就讀 TF 卡上的 AgentCenter\update-url.txt
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$here = if ($PSScriptRoot) { $PSScriptRoot } else { '' }
if ($here -and (Test-Path (Join-Path $here 'dongle.ps1'))) { . (Join-Path $here 'dongle.ps1') } else {
$script:DongleSp = $null
  function Dongle-Open {
    try {
      $n = (Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -match 'VID_303A' -and $_.Name -match '\(COM\d+\)' } | Select-Object -First 1).Name
      if (-not $n) { return $false }
      $com = [regex]::Match($n, 'COM\d+').Value
      $sp = New-Object System.IO.Ports.SerialPort $com, 115200
      $sp.Encoding = [Text.Encoding]::UTF8; $sp.NewLine = "`n"; $sp.DtrEnable = $true; $sp.WriteTimeout = 1000
      $sp.Open(); $script:DongleSp = $sp; return $true
    } catch { $script:DongleSp = $null; return $false }
  }
  function Dongle-Say([string]$k, [string]$v) { if ($script:DongleSp) { try { $script:DongleSp.WriteLine("$k $v") } catch { $script:DongleSp = $null } } }
  function Dongle-Screen([string]$state, [string]$title, [string]$l1 = '', [string]$l2 = '') {
    if ($state) { Dongle-Say 'S' $state }; if ($title) { Dongle-Say 'T' $title }; Dongle-Say '1' $l1; Dongle-Say '2' $l2; Dongle-Say 'P' '0 0'
  }
  function Dongle-Close { if ($script:DongleSp) { try { $script:DongleSp.Close() } catch {}; $script:DongleSp = $null } }
  
}
[void](Dongle-Open)
function Fail([string]$title, [string]$l1, [string]$msg) { Dongle-Screen 'error' $title $l1 '按按鈕重試'; Write-Host ''; Write-Host $msg -ForegroundColor Red; Dongle-Close; Read-Host '按 Enter 關閉'; exit 1 }

Write-Host 'Agent 中控中心：準備中…'
Dongle-Screen 'boot' '找 TF 卡…' '' ''
# ---- 1. 找 Dongle 的磁碟 ----
$root = $null
for ($i = 0; $i -lt 15 -and -not $root; $i++) {
  try { $v = Get-Disk | Where-Object { $_.FriendlyName -match 'T-Dongle' } | Get-Partition | Get-Volume | Where-Object { $_.DriveLetter } | Select-Object -First 1; if ($v) { $root = "$($v.DriveLetter):\" } } catch {}
  if (-not $root) { Start-Sleep -Seconds 1 }
}
if (-not $root -and $here -match '\\AgentCenter\\tools$') { $root = [IO.Path]::GetPathRoot($here) }   # 從 TF 卡上執行的：就是這個磁碟（從暫存資料夾執行的不算）
if (-not $root) {
  $raw = $null; try { $raw = Get-Disk | Where-Object { $_.FriendlyName -match 'T-Dongle' } | Select-Object -First 1 } catch {}
  if ($raw) { Fail 'TF 卡要先格式化' '用 exFAT 格式化' 'Dongle 的 TF 卡還沒格式化。請在「檔案總管」對它按右鍵 → 格式化 → exFAT，再按 Dongle 的按鈕重試。' }
  Fail '找不到 TF 卡' '請插入 TF 卡' '找不到 Dongle 的 TF 卡。請確認 TF 卡有插好，重新插上 Dongle。'
}
$ac = Join-Path $root 'AgentCenter'
Write-Host "TF 卡：$root"
if (-not $Base) { $uf = Join-Path $ac 'update-url.txt'; if (Test-Path $uf) { $Base = (Get-Content $uf -Raw).Trim() } }
if ($Base -and -not $Base.EndsWith('/')) { $Base += '/' }

# ---- 1.5 啟動流程只跑一次：已經有一個在啟動或執行 → 把那個視窗叫到前面就好（也不能在執行中更新程式） ----
$once = Join-Path $ac 'tools\once.ps1'
if (Test-Path $once) { & $once -Quiet; if ($LASTEXITCODE -eq 1) { Write-Host 'Agent Center 已經在執行了。'; Dongle-Close; exit 0 } }

# ---- 2. 需要下載或更新嗎 ----
$local = ''; $vf = Join-Path $ac 'app\VERSION'; if (Test-Path $vf) { $local = (Get-Content $vf -Raw).Trim() }
$man = $null
if ($Base) {
  Dongle-Screen 'boot' '檢查更新…' '' ''
  try { $man = Invoke-RestMethod -Uri ($Base + 'latest.json') -TimeoutSec 15 } catch { $man = $null }
}
if (-not $local -and -not $man) {
  if (-not $Base) { Fail 'TF 卡沒有軟體' '請放入 AgentCenter' "TF 卡上沒有 AgentCenter，也沒有設定下載網址。請把 AgentCenter 資料夾放到 $root，或在韌體設定 BOOT_BASE_URL。" }
  Fail '連不上網路' '需要網路才能下載' "第一次使用要從網路下載軟體，但連不上 $Base。請確認網路後按 Dongle 的按鈕重試。"
}
$running = Join-Path $ac 'data\.running.json'
if ($man -and (Test-Path $running) -and ((Get-Date) - (Get-Item $running).LastWriteTime).TotalSeconds -lt 90) { Write-Host 'AgentCenter 正在執行，這次不更新。'; $man = $null }   # 正在跑就不要蓋掉程式檔
if ($man -and $man.version -and $man.version -ne $local) {
  $zip = Join-Path $env:TEMP ('agentcenter-' + [guid]::NewGuid().ToString('N') + '.zip')
  $what = if ($local) { '更新軟體' } else { '下載軟體' }
  Write-Host "$what：$($man.version)"
  Dongle-Screen 'busy' $what $man.version ''
  try {
    $req = [Net.HttpWebRequest]::Create($Base + $man.zip); $req.Timeout = 30000; $res = $req.GetResponse()
    $total = [int64]$res.ContentLength; if ($total -le 0) { $total = [int64]$man.size }
    $in = $res.GetResponseStream(); $out = [IO.File]::Create($zip); $buf = New-Object byte[] 262144; $got = [int64]0; $lastPct = -1
    while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
      $out.Write($buf, 0, $n); $got += $n
      if ($total -gt 0) { $pct = [int](100 * $got / $total); if ($pct -ne $lastPct) { $lastPct = $pct; Dongle-Say 'P' "$pct 100"; Dongle-Say '1' ("{0} {1}%" -f $what, $pct); Write-Progress -Activity $what -PercentComplete $pct } }
    }
    $out.Close(); $in.Close(); $res.Close(); Write-Progress -Activity $what -Completed
  } catch { try { $out.Close() } catch {}; Remove-Item $zip -Force -ErrorAction SilentlyContinue; if ($local) { Write-Host "更新失敗（$($_.Exception.Message)），先用 TF 卡上的舊版。" -ForegroundColor Yellow; $man = $null } else { Fail '下載失敗' '按按鈕重試' "下載失敗：$($_.Exception.Message)" } }
  if ($man) {
    Dongle-Screen 'busy' '檢查檔案…' '' ''
    $h = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
    if ($man.sha256 -and $h -ne ([string]$man.sha256).ToLower()) { Remove-Item $zip -Force; if ($local) { Write-Host '下載的檔案檢查碼不符，先用舊版。' -ForegroundColor Yellow } else { Fail '檔案檢查失敗' '可能被竄改' '下載的檔案和官方檢查碼不符（可能下載不完整或被竄改），已放棄。' } }
    else {
      # ---- 解壓到 TF 卡：data 資料夾（你的資料）一律不動 ----
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      $z = [IO.Compression.ZipFile]::OpenRead($zip); $ents = @($z.Entries); $i = 0
      foreach ($e in $ents) {
        $i++; $rel = $e.FullName -replace '/', '\'
        if ($rel -match '^AgentCenter\\data\\' -and $rel -notmatch '^AgentCenter\\data\\\.keep$') { continue }
        $dst = Join-Path $root $rel
        if ($rel.EndsWith('\')) { New-Item -ItemType Directory -Path $dst -Force | Out-Null; continue }
        New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
        [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dst, $true)
        if ($i % 10 -eq 0 -or $i -eq $ents.Count) { $pct = [int](100 * $i / $ents.Count); Dongle-Say 'P' "$pct 100"; Dongle-Say '1' "安裝到 TF 卡 $pct%" }
      }
      $z.Dispose(); Remove-Item $zip -Force -ErrorAction SilentlyContinue
      if ($Base) { Set-Content -Path (Join-Path $ac 'update-url.txt') -Value $Base -Encoding ASCII }
      Write-Host "已安裝 $($man.version) 到 $ac" -ForegroundColor Green
    }
  }
}
# ---- 3. 啟動 ----
$start = Join-Path $ac 'start.bat'
if (-not (Test-Path $start)) { Fail '軟體不完整' '請重新下載' "找不到 $start" }
Dongle-Screen 'boot' '啟動中…' '' ''
Dongle-Close   # 交棒：啟動程式會自己再打開序列埠
Start-Process -FilePath $start -WorkingDirectory $ac
exit 0
