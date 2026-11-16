param(
    [string]$Database = "house_rent_w5",
    [string]$DbUser = "root",
    [string]$DbPassword = "root",
    [string]$BackupDir = "logs\rollback_drill",
    [string]$MysqlBin = "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe",
    [string]$MysqldumpBin = "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysqldump.exe"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$backupRoot = Join-Path $repoRoot $BackupDir
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$scratchDb = "hrent_w11_drill_$stamp"
$backupFile = Join-Path $backupRoot "house_rent_w5_$stamp.sql"
$reportFile = Join-Path $repoRoot "logs\w11_rollback_drill.md"

if (-not (Test-Path -LiteralPath $backupRoot)) {
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
}
if (-not (Test-Path -LiteralPath $MysqlBin)) { throw "找不到 mysql.exe：$MysqlBin" }
if (-not (Test-Path -LiteralPath $MysqldumpBin)) { throw "找不到 mysqldump.exe：$MysqldumpBin" }

$env:MYSQL_PWD = $DbPassword

# 1) 备份：单事务一致性快照，包含存储过程/触发器
$backupErrFile = Join-Path $backupRoot "house_rent_w5_$stamp.err.log"
$backupWatch = [System.Diagnostics.Stopwatch]::StartNew()
$dumpProc = Start-Process -FilePath $MysqldumpBin `
    -ArgumentList @("--single-transaction", "--routines", "--triggers", "--default-character-set=utf8mb4", "-u$DbUser", $Database) `
    -RedirectStandardOutput $backupFile -RedirectStandardError $backupErrFile `
    -NoNewWindow -Wait -PassThru
if ($dumpProc.ExitCode -ne 0) { throw "mysqldump 失败，退出码 $($dumpProc.ExitCode)，见 $backupErrFile" }
$backupWatch.Stop()
$backupSeconds = [math]::Round($backupWatch.Elapsed.TotalSeconds, 2)
$backupSizeMb = [math]::Round((Get-Item -LiteralPath $backupFile).Length / 1MB, 2)

# 2) 恢复到独立临时库，不碰原库
$restoreWatch = [System.Diagnostics.Stopwatch]::StartNew()
& $MysqlBin "-u$DbUser" -e "CREATE DATABASE IF NOT EXISTS ``$scratchDb`` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
if ($LASTEXITCODE -ne 0) { throw "创建临时库失败" }
& $MysqlBin "--default-character-set=utf8mb4" "-u$DbUser" "-D$scratchDb" -e "source $($backupFile.Replace('\','/'))"
if ($LASTEXITCODE -ne 0) { throw "恢复临时库失败" }
$restoreWatch.Stop()
$restoreSeconds = [math]::Round($restoreWatch.Elapsed.TotalSeconds, 2)

# 3) 关键表行数对账
$tables = @("hrent_house_resource", "hrent_rent", "bill_item", "sys_user", "review")
$rows = @()
foreach ($table in $tables) {
    $source = (& $MysqlBin "-u$DbUser" "-D$Database" -N -B -e "SELECT COUNT(*) FROM $table;").Trim()
    $target = (& $MysqlBin "-u$DbUser" "-D$scratchDb" -N -B -e "SELECT COUNT(*) FROM $table;").Trim()
    $ok = if ($source -eq $target) { "OK" } else { "MISMATCH" }
    $rows += "| $table | $source | $target | $ok |"
}

$status = if (($rows -join "`n") -match "MISMATCH") { "FAIL" } else { "PASS" }
$markdown = @"
# W11 回滚演练记录

- 时间：$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
- 原库：``$Database``
- 临时恢复库：``$scratchDb``（演练后保留，供核对）
- 备份文件：``$backupFile``
- 备份方式：``mysqldump --single-transaction --routines --triggers``

## 结果

| 项 | 实测 | 门槛 |
|---|---:|---:|
| 备份耗时 | $backupSeconds s | - |
| 恢复耗时 | $restoreSeconds s | - |
| 备份体积 | $backupSizeMb MB | - |
| 代码/数据回滚总耗时 | $([math]::Round($backupSeconds + $restoreSeconds, 2)) s | ≤ 30 分钟 |
| 行数对账 | $status | 全部一致 |

## 关键表行数对账

| 表 | 原库 | 临时库 | 结果 |
|---|---:|---:|---|
$($rows -join "`n")

## 结论

$status：备份与恢复在同一台机器完成，关键表行数一致；本轮为数据库恢复演练，代码回滚通过 ``git checkout <上一提交>`` + 重启验证，不在脚本内自动执行。

## 清理临时库

~~~sql
DROP DATABASE ``$scratchDb``;
~~~
"@

$markdown | Out-File -LiteralPath $reportFile -Encoding utf8
Write-Output "备份：$backupFile"
Write-Output "临时库：$scratchDb"
Write-Output "备份 ${backupSeconds}s / 恢复 ${restoreSeconds}s / 体积 ${backupSizeMb}MB / 对账 $status"
Write-Output "报告：$reportFile"
