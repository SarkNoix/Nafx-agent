# 把 xlsx 转成 csv（纯 PowerShell 解 zip+XML，不依赖 Excel 和任何库）
# 用法: xlsx_to_csv.ps1 -Path data.xlsx [-Sheet 1] [-Out data.csv]

param(
    [string]$Path = '',
    [int]$Sheet = 1,
    [string]$Out = ''
)

if ([string]::IsNullOrWhiteSpace($Path)) {
    Write-Output "要指定表格：-Path data.xlsx"
    exit 1
}
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "文件不存在：$Path"
    exit 1
}

$ext = [IO.Path]::GetExtension($Path).ToLower()
if ($ext -eq '.xls') {
    Write-Output "读不了老的 .xls 格式（那是二进制格式）。"
    Write-Output "请用 WPS 或 Excel 打开它，另存为 .xlsx 再试。"
    exit 1
}
if ($ext -ne '.xlsx' -and $ext -ne '.xlsm') {
    Write-Output "这不是 Excel 文件：$ext（只支持 .xlsx）"
    exit 1
}

# ---- 解压到临时目录 ----
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('nafx_xlsx_' + [Guid]::NewGuid().ToString('N').Substring(0,8))
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    [IO.Compression.ZipFile]::ExtractToDirectory($Path, $tmp)
} catch {
    Write-Output ("解不开这个 xlsx：" + $_.Exception.Message)
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    exit 1
}

try {
    # ---- 共享字符串表 ----
    $shared = New-Object System.Collections.ArrayList
    $ssPath = Join-Path $tmp 'xl\sharedStrings.xml'
    if (Test-Path $ssPath) {
        [xml]$ss = Get-Content $ssPath -Encoding UTF8
        foreach ($si in @($ss.sst.si)) {
            $text = ''
            if ($si.t) {
                if ($si.t -is [string]) { $text = $si.t }
                elseif ($si.t.'#text') { $text = $si.t.'#text' }
                else { $text = [string]$si.t }
            }
            if (-not $text -and $si.r) {
                foreach ($r in @($si.r)) {
                    if ($r.t -is [string]) { $text += $r.t }
                    elseif ($r.t.'#text') { $text += $r.t.'#text' }
                    else { $text += [string]$r.t }
                }
            }
            [void]$shared.Add($text)
        }
    }

    # ---- 样式表：判断哪些单元格是日期 ----
    $dateStyles = @{}
    $stylesPath = Join-Path $tmp 'xl\styles.xml'
    if (Test-Path $stylesPath) {
        try {
            [xml]$st = Get-Content $stylesPath -Encoding UTF8
            # 自定义格式里带 y/m/d/年/月/日 的算日期
            $customFmt = @{}
            foreach ($nf in @($st.styleSheet.numFmts.numFmt)) {
                if (-not $nf) { continue }
                $fid = [int]$nf.numFmtId
                $code = [string]$nf.formatCode
                if ($code -match '[yY]|[dD]|年|月|日' -and $code -notmatch '^[#0,\.]+$') {
                    $customFmt[$fid] = $true
                }
            }
            $xfs = @($st.styleSheet.cellXfs.xf)
            for ($i = 0; $i -lt $xfs.Count; $i++) {
                if (-not $xfs[$i]) { continue }
                $fid = 0
                [void][int]::TryParse([string]$xfs[$i].numFmtId, [ref]$fid)
                # 内置日期格式：14-22 西文日期时间、27-36 中日韩日期、
                # 45-47 时间、50-58 更多东亚日期。中文版 Excel 常用 31。
                $isDate = (($fid -ge 14) -and ($fid -le 22)) -or
                          (($fid -ge 27) -and ($fid -le 36)) -or
                          (($fid -ge 45) -and ($fid -le 47)) -or
                          (($fid -ge 50) -and ($fid -le 58)) -or
                          $customFmt.ContainsKey($fid)
                if ($isDate) { $dateStyles[$i] = $true }
            }
        } catch { }
    }

    # Excel 序列号转日期（基准 1899-12-30）
    function Convert-XLDate([double]$serial) {
        try { return ([datetime]'1899-12-30').AddDays($serial).ToString('yyyy-MM-dd') }
        catch { return $null }
    }
    # ---- 工作表列表 ----
    $sheetDir = Join-Path $tmp 'xl\worksheets'
    $sheetFiles = @(Get-ChildItem -LiteralPath $sheetDir -Filter '*.xml' -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($sheetFiles.Count -eq 0) {
        Write-Output "这个 xlsx 里没有工作表"
        exit 1
    }
    if ($Sheet -gt $sheetFiles.Count) { $Sheet = 1 }
    $targetSheet = $sheetFiles[$Sheet - 1]

    # ---- 列字母 → 序号 ----
    function Convert-ColLetter([string]$letters) {
        $n = 0
        foreach ($ch in $letters.ToUpper().ToCharArray()) {
            $n = $n * 26 + ([int][char]$ch - 64)
        }
        return $n
    }

    # ---- 读单元格 ----
    [xml]$doc = Get-Content -LiteralPath $targetSheet.FullName -Encoding UTF8
    $rows = @()

    foreach ($row in @($doc.worksheet.sheetData.row)) {
        $cells = @{}
        $maxCol = 0
        foreach ($c in @($row.c)) {
            $ref = [string]$c.r
            if (-not $ref) { continue }
            $colLetters = ($ref -replace '\d', '')
            if (-not $colLetters) { continue }
            $colIdx = Convert-ColLetter $colLetters
            if ($colIdx -gt $maxCol) { $maxCol = $colIdx }

            $val = ''
            $type = [string]$c.t
            $vNode = $c.v
            if ($null -ne $vNode) {
                $raw = if ($vNode -is [string]) { $vNode } else { [string]$vNode }
                if ($type -eq 's') {
                    $i = 0
                    if ([int]::TryParse($raw, [ref]$i) -and $i -lt $shared.Count) {
                        $val = $shared[$i]
                    }
                } elseif ($type -eq 'inlineStr') {
                    if ($c.is -and $c.is.t) {
                        $val = if ($c.is.t -is [string]) { $c.is.t } else { [string]$c.is.t }
                    }
                } else {
                    $val = $raw
                    # 这个单元格如果是日期样式，把序列号转成人能看的日期
                    $sAttr = [string]$c.s
                    if ($sAttr -ne '') {
                        $si = 0
                        if ([int]::TryParse($sAttr, [ref]$si) -and $dateStyles.ContainsKey($si)) {
                            $num = 0.0
                            if ([double]::TryParse($raw, [ref]$num)) {
                                $conv = Convert-XLDate $num
                                if ($conv) { $val = $conv }
                            }
                        }
                    }
                }
            } elseif ($type -eq 'inlineStr' -and $c.is -and $c.is.t) {
                $val = if ($c.is.t -is [string]) { $c.is.t } else { [string]$c.is.t }
            }

            if ($val -ne '') { $cells[$colIdx] = $val }
        }

        if ($maxCol -eq 0) { continue }
        $arr = @()
        for ($i = 1; $i -le $maxCol; $i++) {
            $arr += $(if ($cells.ContainsKey($i)) { [string]$cells[$i] } else { '' })
        }
        $rows += , $arr
    }

    if ($rows.Count -eq 0) {
        Write-Output "这张表是空的"
        exit 0
    }

    # ---- 输出 csv ----
    function Quote-Csv([string]$s) {
        if ($s -match '[",\r\n]') { return '"' + $s.Replace('"', '""') + '"' }
        return $s
    }

    $csvLines = @()
    foreach ($r in $rows) {
        $csvLines += (($r | ForEach-Object { Quote-Csv $_ }) -join ',')
    }

    if (-not $Out) {
        $Out = [IO.Path]::Combine((Split-Path -Parent $Path), ([IO.Path]::GetFileNameWithoutExtension($Path) + '.csv'))
    }

    [IO.File]::WriteAllLines($Out, $csvLines, (New-Object Text.UTF8Encoding($false)))

    $first = $rows[0]
    Write-Output ("转好了：" + $Out)
    Write-Output ("  工作表 " + $Sheet + "/" + $sheetFiles.Count + "（" + $targetSheet.BaseName + "）")
    Write-Output ("  " + $rows.Count + " 行（含表头），" + $first.Count + " 列")
    if ($sheetFiles.Count -gt 1) {
        Write-Output ("  这个文件还有 " + ($sheetFiles.Count - 1) + " 张表，用 -Sheet 2 可以看下一张")
    }
    Write-Output ("  表头：" + (($first | Select-Object -First 8) -join ', '))
} finally {
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
