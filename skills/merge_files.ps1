# 把多个文件合并成一个
# 用法: merge_files.ps1 -Path data -Ext .txt -Out merged.txt

param(
    [string]$Path = '.',
    [string]$Ext = '.txt',
    [string]$Out = 'merged.txt',
    [switch]$WithName
)

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "路径不存在：$Path"
    exit 1
}

$item = Get-Item -LiteralPath $Path
if ($item.PSIsContainer) {
    $files = @(Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -eq $Ext } | Sort-Object FullName)
} else {
    $files = @($item)
}

if ($files.Count -eq 0) {
    Write-Output ("没有 $Ext 文件可合并（在 " + $Path + " 里找的）")
    exit 0
}

$sb = New-Object System.Text.StringBuilder
foreach ($f in $files) {
    if ($WithName) { [void]$sb.AppendLine("===== " + $f.Name + " =====") }
    try {
        $text = [IO.File]::ReadAllText($f.FullName)
        [void]$sb.Append($text)
        if (-not $text.EndsWith("`n")) { [void]$sb.AppendLine() }
    } catch {
        Write-Output ("  读不了：" + $f.Name)
    }
    [void]$sb.AppendLine()
}

try {
    [IO.File]::WriteAllText($Out, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
} catch {
    Write-Output ("写不进去：" + $_.Exception.Message)
    exit 1
}

$outItem = Get-Item -LiteralPath $Out
Write-Output ("合并了 " + $files.Count + " 个文件 → " + $Out)
Write-Output ("结果大小 " + $outItem.Length + " 字节")
foreach ($f in $files) { Write-Output ("  + " + $f.Name) }
