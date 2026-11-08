# 批量解压目录里所有压缩包，每个解到同名目录
# 用法: unzip_all.ps1 -Path downloads -Out .\unpacked

param(
    [string]$Path = '.',
    [string]$Out = ''
)

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "目录不存在：$Path"
    exit 1
}

$root = Get-Item -LiteralPath $Path
if (-not $root.PSIsContainer) {
    Write-Output "这不是目录：$Path"
    exit 1
}

$exts = @('.zip', '.tar', '.gz', '.tgz', '.bz2', '.xz', '.7z', '.rar')
$archives = @(Get-ChildItem -LiteralPath $root.FullName -File -ErrorAction SilentlyContinue |
              Where-Object { $exts -contains $_.Extension.ToLower() -and
                             -not $_.Name.EndsWith('.tar.gz') } )
# .tar.gz 单独收
$archives += @(Get-ChildItem -LiteralPath $root.FullName -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -like '*.tar.gz' })
$archives = @($archives | Sort-Object FullName -Unique)

if ($archives.Count -eq 0) {
    Write-Output "没有找到压缩包（找的是 " + ($exts -join ' ') + "）"
    exit 0
}

$outRoot = if ($Out) { $Out } else { $root.FullName }
if (-not (Test-Path -LiteralPath $outRoot)) { New-Item -ItemType Directory -Force -Path $outRoot | Out-Null }

# 找 7-Zip
$sevenZip = @('C:\Program Files\7-Zip\7z.exe', 'C:\Program Files (x86)\7-Zip\7z.exe') |
            Where-Object { Test-Path $_ } | Select-Object -First 1

$ok = 0
$fail = 0
Write-Output ("发现 " + $archives.Count + " 个压缩包：")

foreach ($a in $archives) {
    $baseName = $a.Name
    foreach ($s in @('.tar.gz', '.tgz')) {
        if ($baseName.EndsWith($s)) { $baseName = $baseName.Substring(0, $baseName.Length - $s.Length); break }
    }
    if ($baseName -eq $a.Name) { $baseName = [IO.Path]::GetFileNameWithoutExtension($a.Name) }

    $dest = Join-Path $outRoot $baseName
    try {
        if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }

        $ext = $a.Extension.ToLower()
        if ($a.Name -like '*.tar.gz' -or $ext -eq '.tgz' -or $ext -in @('.tar', '.gz', '.bz2', '.xz')) {
            & tar.exe -xf $a.FullName -C $dest 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "tar 退出码 $LASTEXITCODE" }
        }
        elseif ($ext -eq '.zip') {
            Expand-Archive -LiteralPath $a.FullName -DestinationPath $dest -Force -ErrorAction Stop
        }
        elseif ($ext -in @('.7z', '.rar')) {
            if (-not $sevenZip) { throw "需要 7-Zip（没装）" }
            & $sevenZip x $a.FullName "-o$dest" -y 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "7-Zip 退出码 $LASTEXITCODE" }
        }
        else {
            throw "不认识的格式 $ext"
        }

        $n = @(Get-ChildItem -LiteralPath $dest -Recurse -File -ErrorAction SilentlyContinue).Count
        Write-Output ("  OK  " + $a.Name + "  →  " + $baseName + "/  (" + $n + " 个文件)")
        $ok++
    } catch {
        Write-Output ("  失败 " + $a.Name + " — " + $_.Exception.Message)
        $fail++
    }
}

Write-Output ""
Write-Output ("解压成功 $ok 个" + $(if ($fail -gt 0) { "，失败 $fail 个" } else { "" }))
