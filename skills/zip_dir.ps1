# 把目录或文件压缩成 zip
# 用法: zip_dir.ps1 -Path data            → 生成 data.zip
#       zip_dir.ps1 -Path data -Out bak  → 生成 bak.zip

param(
    [string]$Path = '.',
    [string]$Out = ''
)

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "路径不存在：$Path"
    exit 1
}

$item = Get-Item -LiteralPath $Path
$full = $item.FullName

# 输出文件名：没指定就用原名字
if ([string]::IsNullOrWhiteSpace($Out)) {
    $Out = $item.BaseName
}
if ($Out -notmatch '\.zip$') { $Out = $Out + '.zip' }

# 放在被压缩对象的同级目录
$parent = Split-Path -Parent $item.FullName
$outPath = Join-Path $parent $Out

if (Test-Path -LiteralPath $outPath) {
    Write-Output "已经有同名的包了：$Out（先删掉或者换个名字）"
    exit 1
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

try {
    if ($item.PSIsContainer) {
        # 目录：包里的路径相对于父目录，这样解开后是 Path 这个名字的文件夹
        [IO.Compression.ZipFile]::CreateFromDirectory(
            $full, $outPath,
            [IO.Compression.CompressionLevel]::Optimal,
            $true,   # includeBaseDirectory：解压后保留顶层文件夹
            [Text.Encoding]::UTF8)
        $n = @(Get-ChildItem -LiteralPath $full -File -Recurse -ErrorAction SilentlyContinue).Count
        $size = [math]::Round((Get-Item -LiteralPath $outPath).Length / 1KB, 1)
        Write-Output ("已压缩目录 $($item.Name)：$n 个文件 → $Out（$size KB）")
    } else {
        # 单个文件
        $zip = [IO.Compression.ZipFile]::Open($outPath, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $zip.CreateEntry($item.Name)
            $es = $entry.Open()
            $fs = [IO.File]::OpenRead($full)
            try { $fs.CopyTo($es) } finally { $fs.Close(); $es.Close() }
        } finally { $zip.Dispose() }
        $size = [math]::Round((Get-Item -LiteralPath $outPath).Length / 1KB, 1)
        Write-Output ("已压缩文件 $($item.Name) → $Out（$size KB）")
    }
} catch {
    Write-Output ("压缩失败：" + $_.Exception.Message)
    if (Test-Path -LiteralPath $outPath) { Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue }
    exit 1
}
