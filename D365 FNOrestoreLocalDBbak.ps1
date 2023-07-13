$f = Get-ChildItem 'C:\temp\AxDB 7-14-2021 1242.bak'  #Please note that this file should be accsessable from SQL server service account
$dbName = 'AxDB_NEW'  #Temporary Database name for new AxDB. Use a file name or any meaningfull name.

#############################################
$ErrorActionPreference = "Stop"

#region Installing d365fo.tools and dbatools <--
# This is requried by Find-Module, by doing it beforehand we remove some warning messages
Write-Host "Installing PowerShell modules d365fo.tools and dbatools" -ForegroundColor Yellow
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers

Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true 
Set-DbatoolsConfig -FullName sql.connection.encrypt -Value $false
$modules2Install = @('d365fo.tools','dbatools')
foreach($module in  $modules2Install)
{
    Write-Host "..working on module" $module -ForegroundColor Yellow
    if ($null -eq $(Get-Command -Module $module)) {
        Write-Host "....installing module" $module -ForegroundColor Gray
        Install-Module -Name $module -SkipPublisherCheck -Scope AllUsers
    } else {
        Write-Host "....updating module" $module -ForegroundColor Gray
        Update-Module -Name $module
    }
}
#endregion Installing d365fo.tools and dbatools -->
## Stop D365FO instance
Write-Host "Stopping D365FO environment" -ForegroundColor Yellow
Stop-D365Environment | FT
## Restore New Database to SQL Server. Database name is AxDB_NEW
Write-Host "Restoring new Database" -ForegroundColor Yellow
#$f = Get-ChildItem C:\users\Admind9fca084f4\Downloads\AxDB_CTS-1005-BU2-202005051340.bak  #Please note that this file should be accsessable from SQL server service account
If (-not (Test-DbaPath -SqlInstance localhost -Path $($f.FullName)))
{
    Write-Warning "Database file $($f.FullName) could not be found by SQL Server. Try to move it to C:\Temp"
    throw "Database file $($f.FullName) could not be found by SQL Server. Try to move it to C:\Temp"
}
$f | Unblock-File
#$dbName = 'AxDB_CTS1005BU2'  #$f.BaseName
$f | Restore-DbaDatabase -SqlInstance localhost -DatabaseName $dbName -ReplaceDbNameInFile -Verbose
Rename-DbaDatabase -SqlInstance localhost -Database $dbName -LogicalName "$($f.BaseName)_<FT>"
## (Optional) Backup curent AxDB just in case. You can find this DB as AxDB_original.
## You can skip this step
Write-Host "Backup current AxDB (Optional)" -ForegroundColor Yellow
Backup-DbaDatabase -SqlInstance localhost -Database AxDB -Type Full -CompressBackup -BackupFileName dbname-1005_original-backuptype-timestamp.bak -ReplaceInName
#Remove AxDB_Original database, if it exists
Write-Host "Switching databases" -ForegroundColor Yellow
Remove-D365Database -DatabaseName AxDB_original
#Switch AxDB   AxDB_original <-- AxDB <-- AxDB_NEW
Switch-D365ActiveDatabase -NewDatabaseName $dbName
## Enable SQL Change Tracking
Write-Host "Enabling SQL Change Tracking" -ForegroundColor Yellow
## ALTER DATABASE AxDB SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 6 DAYS, AUTO_CLEANUP = ON)
Invoke-DbaQuery -SqlInstance localhost -Database AxDB -Query "ALTER DATABASE AxDB SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 6 DAYS, AUTO_CLEANUP = ON)"
## Disable all current Batch Jobs
Write-Host "Disabling all current Batch Jobs" -ForegroundColor Yellow
Invoke-DbaQuery -SqlInstance localhost -Database AxDB -Query "UPDATE BatchJob SET STATUS = 0 WHERE STATUS IN (1,2,5,7) --Set any waiting, executing, ready, or canceling batches to withhold."
## Trancate System tables. Values there will be re-created after AOS start
Write-Host "Trancating System tables. Values there will be re-created after AOS start" -ForegroundColor Yellow
$sqlSysTablesTruncate = @"
TRUNCATE TABLE SYSSERVERCONFIG
TRUNCATE TABLE SYSSERVERSESSIONS
TRUNCATE TABLE SYSCORPNETPRINTERS
TRUNCATE TABLE SYSCLIENTSESSIONS
TRUNCATE TABLE BATCHSERVERCONFIG
TRUNCATE TABLE BATCHSERVERGROUP
"@
Invoke-DbaQuery -SqlInstance localhost -Database AxDB -Query $sqlSysTablesTruncate
## INFO: get Admin email address/tenant
Write-Host "Getting information about tenant and admin account from AxDB" -ForegroundColor Yellow
Invoke-DbaQuery -SqlInstance localhost -Database AxDB -Query "Select ID, Name, NetworkAlias from UserInfo where ID = 'Admin'" | FT
## Execute Database Sync
Write-Host "Executing Database Sync" -ForegroundColor Yellow
Invoke-D365DbSync -ShowOriginalProgress
## Start D365FO environment. Then open UI and refresh Data Entities.
Write-Host "Starting D365FO environment. Then open UI and refresh Data Entities." -ForegroundColor Yellow
Start-D365Environment | FT
