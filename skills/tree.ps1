# 打印目录树
# 用法: tree.ps1 -Path . -Depth 3

param(
    [string]$Path = '.',
    [int]$Depth = 3
)

if ($Depth -lt 1) { $Depth = 3 }

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "目录不存在：$Path"
    exit 1
}

$root = Get-Item -LiteralPath $Path
if (-not $root.PSIsContainer) {
    Write-Output "这不是目录：$Path"
    exit 1
}

$script:dirCount = 0
$script:fileCount = 0

function Walk {
    param([string]$dir, [int]$level, [string]$prefix)

    if ($level -gt $Depth) { return }

    $items = @()
    try {
        $items = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -notin @('.backup', '.git', 'node_modules') } |
                   Sort-Object @{Expression={$_.PSIsContainer};Descending=$true}, Name)
    } catch { return }

    for ($i = 0; $i -lt $items.Count; $i++) {
        $it = $items[$i]
        $last = ($i -eq $items.Count - 1)
        $branch = if ($last) { '└─ ' } else { '├─ ' }
        $nextPrefix = $prefix + $(if ($last) { '   ' } else { '│  ' })

        if ($it.PSIsContainer) {
            $script:dirCount++
            $sub = @(Get-ChildItem -LiteralPath $it.FullName -Force -ErrorAction SilentlyContinue)
            Write-Output ($prefix + $branch + $it.Name + "/  (" + $sub.Count + " 项)")
            if ($level -lt $Depth) { Walk -dir $it.FullName -level ($level + 1) -prefix $nextPrefix }
        } else {
            $script:fileCount++
            $sz = if ($it.Length -ge 1KB) { "{0:N1}K" -f ($it.Length/1KB) } else { "$($it.Length)B" }
            Write-Output ($prefix + $branch + $it.Name + "  " + $sz)
        }
    }
}

Write-Output ($root.Name + "/")
Walk -dir $root.FullName -level 1 -prefix ''
Write-Output ""
Write-Output ("共 $($script:dirCount) 个目录，$($script:fileCount) 个文件" +
              $(if ($Depth -lt 99) { "（深度限制 $Depth）" } else { "" }))
