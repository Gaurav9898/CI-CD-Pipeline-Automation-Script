Import-Module WebAdministration

Write-Host "--- Deep Scan: Identifying Unused Application Pools (Sites & Apps) ---" -ForegroundColor Cyan

# 1. Collect all pools
$allPools = Get-ChildItem IIS:\AppPools

# 2. Identify used pools (Checking Sites and Sub-Applications)
$usedPoolNames = @()
$usedPoolNames += Get-Website | Select-Object -ExpandProperty applicationPool
$usedPoolNames += Get-WebApplication | Select-Object -ExpandProperty applicationPool
$usedPoolNames = $usedPoolNames | Select-Object -Unique

# 3. Filter for orphans
$unusedPools = $allPools | Where-Object { $usedPoolNames -notcontains $_.Name }

if ($null -eq $unusedPools -or $unusedPools.Count -eq 0) {
    Write-Host "No unused Application Pools found. Your IIS is clean!" -ForegroundColor Green
    exit
}

# 4. List them for review
Write-Host "Found $($unusedPools.Count) unused pools:" -ForegroundColor Yellow
$unusedPools | Select-Object Name, State | Format-Table -AutoSize

# 5. The One and Only Global Confirmation
Write-Host "WARNING: You are about to bulk delete $($unusedPools.Count) Application Pools." -ForegroundColor Red -BackgroundColor Black

$confirmAll = Read-Host "Type 'CONFIRM' to delete ALL listed pools automatically"

if ($confirmAll -eq "CONFIRM") {
    $count = 0
    foreach ($pool in $unusedPools) {
        try {
            Write-Host "[$($count+1)/$($unusedPools.Count)] Removing: $($pool.Name)... " -NoNewline -ForegroundColor White
            Remove-WebAppPool -Name $pool.Name -ErrorAction Stop
            Write-Host "DONE" -ForegroundColor Green
            $count++
        }
        catch {
            Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Write-Host "`nSuccessfully removed $count pools." -ForegroundColor Green
}
else {
    Write-Host "Bulk removal cancelled. No changes were made." -ForegroundColor White
}
