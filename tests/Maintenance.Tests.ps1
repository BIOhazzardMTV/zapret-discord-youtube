$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Import-ScriptFunctions($path, $names) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors) { throw ($errors -join [Environment]::NewLine) }
    $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names
    }, $false) | ForEach-Object { $_.Extent.Text }
}

function Assert($condition, $message) {
    if (-not $condition) { throw $message }
}

$listsDir = Join-Path $PSScriptRoot ('.maintenance-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($listsDir)
$ipsetFlagFile = Join-Path $listsDir 'ipset_switched.flag'
$list = Join-Path $listsDir 'ipset-all.txt'
$backup = Join-Path $listsDir 'ipset-all.test-backup.txt'
$testUtils = Join-Path $listsDir 'utils'
try {
    . ([scriptblock]::Create(((Import-ScriptFunctions (Join-Path $root 'utils/test zapret.ps1') @('Set-IpsetMode', 'Invoke-DpiSuite')) -join "`n")))
    $output = @(Invoke-DpiSuite -Targets @() -TimeoutSeconds 1 -RangeBytes 32 -MaxParallel 1 6>&1) -join "`n"
    Assert ($output -match 'not run' -and $output -notmatch '\[OK\]') 'An empty DPI suite must not report success.'

    [IO.File]::WriteAllText($list, '192.0.2.0/24')
    Set-IpsetMode -mode any
    Assert ((Test-Path -LiteralPath $ipsetFlagFile) -and [IO.File]::ReadAllText($list) -eq '') 'Switching must leave recovery information and an empty active list.'

    $lock = [IO.File]::Open($list, 'Open', 'Read', 'ReadWrite')
    try {
        $failed = $false
        try { Set-IpsetMode -mode restore } catch { $failed = $true }
        Assert ($failed -and (Test-Path -LiteralPath $ipsetFlagFile) -and [IO.File]::ReadAllText($backup) -eq '192.0.2.0/24') 'A blocked restore must keep its recovery files.'
    } finally {
        $lock.Dispose()
    }
    Set-IpsetMode -mode restore
    Assert ([IO.File]::ReadAllText($list) -eq '192.0.2.0/24' -and -not (Test-Path -LiteralPath $ipsetFlagFile)) 'A retry must restore the original list.'

    [IO.File]::Delete($list)
    Set-IpsetMode -mode any
    Set-IpsetMode -mode restore
    Assert (-not (Test-Path -LiteralPath $list)) 'An originally missing list must remain absent after recovery.'

    $names = 'Get-HostsEntries', 'Test-HostsCurrent', 'Install-StagedFile', 'Replace-ActiveFile', 'Switch-Ipset', 'Test-IpsetDownload',
        'Get-GameServiceArguments', 'Set-GameServicePath', 'Update-GameService'
    . ([scriptblock]::Create(((Import-ScriptFunctions (Join-Path $root 'utils/service-files.ps1') $names) -join "`n")))
    $backup = "$list.backup"
    [IO.File]::WriteAllText($list, '192.0.2.0/24')
    [IO.File]::WriteAllText($backup, '198.51.100.0/24')
    $lock = [IO.File]::Open($list, 'Open', 'Read', 'ReadWrite')
    try {
        $failed = $false
        try { Switch-Ipset $list } catch { $failed = $true }
        Assert ($failed -and [IO.File]::ReadAllText($list) -eq '192.0.2.0/24' -and [IO.File]::ReadAllText($backup) -eq '198.51.100.0/24') 'An IPSet switch blocked by a reader must preserve both copies.'
    } finally {
        $lock.Dispose()
    }
    Switch-Ipset $list
    Assert ([IO.File]::ReadAllText($list).Trim() -eq '203.0.113.113/32' -and [IO.File]::ReadAllText($backup) -eq '192.0.2.0/24') 'Switching to none must back up the loaded list.'
    Switch-Ipset $list
    Assert ([IO.File]::ReadAllText($list) -eq '') 'Switching to any must leave an empty list.'
    Switch-Ipset $list
    Assert ([IO.File]::ReadAllText($list) -eq '192.0.2.0/24') 'Switching to loaded must restore the original list.'

    $downloadedIpset = Join-Path $listsDir 'ipset.download'
    [IO.File]::WriteAllLines($downloadedIpset, @('192.0.2.0/24', '2001:db8::/32'))
    Test-IpsetDownload $downloadedIpset
    [IO.File]::AppendAllText($downloadedIpset, '2001:db8::/129')
    $failed = $false
    try { Test-IpsetDownload $downloadedIpset } catch { $failed = $true }
    Assert $failed 'An invalid network prefix must not pass download validation.'
    $current = Join-Path $listsDir 'hosts'
    $downloaded = Join-Path $listsDir 'hosts.download'
    [IO.File]::WriteAllLines($downloaded, @('192.0.2.1 first.example', '192.0.2.2 middle.example', '2001:db8::1 last.example'))
    [IO.File]::WriteAllLines($current, @('192.0.2.1 first.example', '2001:db8::1 last.example', '# 192.0.2.2 middle.example', '192.0.2.3 middle.example'))
    Assert (-not (Test-HostsCurrent $current $downloaded)) 'Matching endpoints must not hide an absent middle entry.'
    Add-Content -LiteralPath $current -Value '192.0.2.2 custom.example MIDDLE.EXAMPLE # comment'
    Assert (Test-HostsCurrent $current $downloaded) 'Extra entries, aliases and comments must not hide a complete hosts file.'
    [IO.File]::WriteAllText($downloaded, '# empty')
    $failed = $false
    try { $null = Test-HostsCurrent $current $downloaded } catch { $failed = $true }
    Assert $failed 'An empty downloaded hosts file must be rejected.'

    $active = Join-Path $listsDir 'active.bin'
    $source = Join-Path $listsDir 'source.bin'
    [IO.File]::WriteAllText($active, 'original')
    $failed = $false
    try { Replace-ActiveFile $source $active } catch { $failed = $true }
    Assert ($failed -and [IO.File]::ReadAllText($active) -eq 'original') 'A failed copy must leave the original file intact.'
    [IO.File]::WriteAllText($source, 'replacement')
    Replace-ActiveFile $source $active
    Assert ([IO.File]::ReadAllText($active) -eq 'replacement') 'A valid source must replace the active file.'

    [void][IO.Directory]::CreateDirectory($testUtils)
    [IO.File]::WriteAllLines((Join-Path $testUtils 'game_filter.enabled'), @('mode=all', 'tcp=4500-4501', 'udp=6500-6501'))
    $tlsProfile = 'general (FAKE TLS AUTO)'
    Copy-Item -LiteralPath (Join-Path $root 'service.bat'),(Join-Path $root 'general.bat'),(Join-Path $root "$tlsProfile.bat") -Destination $listsDir
    $serviceArgs = Get-GameServiceArguments $listsDir 'general'
    Assert ($serviceArgs -match '--wf-tcp [^ ]*,4500-4501\b' -and $serviceArgs -match '--wf-udp [^ ]*,6500-6501\b') 'The installed profile must receive the newly saved TCP and UDP ranges.'
    $tlsArgs = Get-GameServiceArguments $listsDir $tlsProfile
    Assert (([regex]::Matches($tlsArgs, '--dpi-desync-fake-tls !(?=\s|$)')).Count -eq 5 -and $tlsArgs -notmatch 'EXCL_MARK') 'The service parser must preserve all five built-in TLS markers.'

    & {
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\zapret'
        $oldPath = '"{0}" --zapret-service --wf-tcp 443,12' -f (Join-Path $listsDir 'bin\winws.exe')
        $commands = New-Object 'System.Collections.Generic.List[string]'
        $controller = [pscustomobject]@{ Status = 'Running' }
        $launch = [pscustomobject]@{ Fail = $false }
        function Test-Path($LiteralPath, $PathType) {
            if ($LiteralPath -eq $key) { return $true }
            Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
        }
        function Get-CimInstance { [pscustomobject]@{ PathName = $oldPath } }
        function Get-ItemProperty { [pscustomobject]@{ 'zapret-discord-youtube' = 'general' } }
        function Get-Service { $controller }
        function Stop-Service { $commands.Add('stop') }
        function Start-Service {
            $commands.Add('start')
            if ($launch.Fail) {
                $launch.Fail = $false
                throw 'Simulated start failure'
            }
        }
        function Invoke-CimMethod($InputObject, $MethodName, $Arguments) {
            $commands.Add($Arguments.PathName)
            [pscustomobject]@{ ReturnValue = 0 }
        }

        Update-GameService $listsDir
        Assert ($commands.Count -eq 3 -and $commands[0] -eq 'stop' -and $commands[1].EndsWith($serviceArgs) -and $commands[2] -eq 'start') 'Updating a running service must restart the same strategy with the saved ports.'

        $commands.Clear()
        $controller.Status = 'Stopped'
        Update-GameService $listsDir
        Assert ($commands.Count -eq 1 -and $commands[0].EndsWith($serviceArgs)) 'Updating a stopped service must leave it stopped.'

        $commands.Clear()
        $controller.Status = 'Running'
        $launch.Fail = $true
        $failed = $false
        try { Update-GameService $listsDir } catch { $failed = $true }
        Assert ($failed -and $commands.Count -eq 5 -and $commands[3] -eq $oldPath -and $commands[4] -eq 'start') 'A failed restart must restore the previous service command and start it again.'
    }
    Write-Host 'Maintenance regression tests passed.'
} finally {
    if (Test-Path -LiteralPath $testUtils) {
        Get-ChildItem -LiteralPath $testUtils -File -Force | Remove-Item -Force
        Remove-Item -LiteralPath $testUtils
    }
    Get-ChildItem -LiteralPath $listsDir -File -Force | Remove-Item -Force
    Remove-Item -LiteralPath $listsDir
}
