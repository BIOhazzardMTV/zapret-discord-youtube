param([Parameter(Mandatory = $true)][ValidateSet('UpdateHosts', 'ReplaceActiveFile', 'SwitchIpset', 'UpdateIpset', 'SaveGameFilter')][string]$Action)

$ErrorActionPreference = 'Stop'

function Get-HostsEntries($Path, [switch]$Strict) {
    foreach ($line in [IO.File]::ReadLines($Path)) {
        $entry = ($line -split '#', 2)[0].Trim()
        if (-not $entry) { continue }
        $fields = $entry -split '\s+'
        $address = $null
        if ($fields.Count -lt 2 -or -not [Net.IPAddress]::TryParse($fields[0], [ref]$address)) {
            if ($Strict) { throw "The downloaded hosts file contains an invalid entry: $entry" }
            continue
        }
        for ($i = 1; $i -lt $fields.Count; $i++) {
            "$address $($fields[$i])"
        }
    }
}

function Test-HostsCurrent($Current, $Downloaded) {
    $required = @(Get-HostsEntries $Downloaded -Strict)
    if (-not $required.Count) { throw 'The downloaded hosts file contains no entries.' }
    if (-not (Test-Path -LiteralPath $Current)) { return $false }

    $entries = @{}
    foreach ($entry in (Get-HostsEntries $Current)) { $entries[$entry] = $true }
    foreach ($entry in $required) {
        if (-not $entries.ContainsKey($entry)) { return $false }
    }
    return $true
}

function Install-StagedFile($Staged, $Destination, $Backup = [NullString]::Value) {
    if ([IO.File]::Exists($Destination)) {
        [IO.File]::Replace($Staged, $Destination, $Backup)
    } else {
        [IO.File]::Move($Staged, $Destination)
    }
}

function Replace-ActiveFile($Source, $Destination) {
    $temporary = $Destination + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::Copy($Source, $temporary)
        Install-StagedFile $temporary $Destination
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Switch-Ipset($List) {
    $sentinel = '203.0.113.113/32'
    $backup = "$List.backup"
    $current = if ([IO.File]::Exists($List)) { [IO.File]::ReadAllText($List).Trim() }
    if (-not $current) {
        if (-not [IO.File]::Exists($backup)) { throw 'No IPSet backup to restore. Update the list from the service menu first.' }
        Replace-ActiveFile $backup $List
        Write-Host 'IPSet switched to loaded.'
        return
    }

    $staged = $List + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        if ($current -eq $sentinel) {
            [IO.File]::WriteAllText($staged, '')
            Install-StagedFile $staged $List
            Write-Host 'IPSet switched to any.'
        } else {
            [IO.File]::WriteAllText($staged, $sentinel + [Environment]::NewLine)
            Install-StagedFile $staged $List $backup
            Write-Host 'IPSet switched to none.'
        }
    } finally {
        Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
    }
}

function Test-IpsetDownload($Path) {
    $count = 0
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Trim() -split '/', 2
        $address = $null
        $prefix = 0
        if ($parts.Count -ne 2 -or -not [Net.IPAddress]::TryParse($parts[0], [ref]$address) -or
                -not [int]::TryParse($parts[1], [ref]$prefix) -or $prefix -lt 0 -or $prefix -gt 8 * $address.GetAddressBytes().Length) {
            throw "Invalid network at entry $($count + 1) in the downloaded IPSet list."
        }
        $count++
    }
    if (-not $count) { throw 'The downloaded IPSet list is empty.' }
}

function Get-GameServiceArguments($Root, $Profile) {
    $file = "$Profile.bat"
    if (-not $Profile -or $file.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $file -match '[%!]') {
        throw 'The installed zapret strategy name is invalid.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Root $file) -PathType Leaf)) {
        throw "The installed strategy '$file' is missing. Select a strategy through Install Service."
    }

    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $env:ComSpec
    $info.Arguments = '/d /v:off /c ""{0}" service_args "{1}""' -f (Join-Path $Root 'service.bat'), $file
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $process = [Diagnostics.Process]::Start($info)
    try {
        $arguments = $process.StandardOutput.ReadToEnd().Trim()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0 -or $arguments -notmatch '^--' -or $arguments -match '[\r\n]') {
            throw "Could not read launch arguments from '$file'."
        }
        return $arguments.Replace('\"', '"')
    } finally {
        $process.Dispose()
    }
}

function Set-GameServicePath($Service, $Path) {
    $result = Invoke-CimMethod -InputObject $Service -MethodName Change -Arguments @{ PathName = $Path }
    if ($result.ReturnValue -ne 0) { throw "Could not update the zapret service (Windows error $($result.ReturnValue))." }
}

function Update-GameService($Root) {
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\zapret'
    if (-not (Test-Path -LiteralPath $key)) {
        Write-Host 'Restart a standalone strategy to apply the changes.'
        return
    }

    $service = Get-CimInstance Win32_Service -Filter "Name='zapret'"
    if (-not $service) { throw 'Could not read the installed zapret service.' }
    $engine = Join-Path $Root 'bin\winws.exe'
    $pathMatch = [regex]::Match($service.PathName, '^\s*(?:"([^"]+)"|(\S+))')
    $registeredEngine = $pathMatch.Groups[1].Value + $pathMatch.Groups[2].Value
    if ($registeredEngine -ne $engine) {
        Write-Host 'The zapret service belongs to another folder. Settings saved for this copy.' -ForegroundColor Yellow
        return
    }

    $profile = Get-ItemProperty -LiteralPath $key -Name 'zapret-discord-youtube'
    $arguments = Get-GameServiceArguments $Root $profile.'zapret-discord-youtube'
    $newPath = '"{0}" --zapret-service {1}' -f $engine, $arguments
    if ($service.PathName -ceq $newPath) {
        Write-Host 'The zapret service already has these settings.'
        return
    }

    $controller = Get-Service -Name zapret
    if ($controller.Status -notin 'Running', 'Stopped') { throw 'Wait for the zapret service to finish starting or stopping and try again.' }
    $wasRunning = $controller.Status -eq 'Running'
    if ($wasRunning) { Stop-Service -InputObject $controller }
    $changed = $false
    try {
        Set-GameServicePath $service $newPath
        $changed = $true
        if ($wasRunning) { Start-Service -InputObject $controller }
    } catch {
        $failure = $_
        try {
            if ($changed) { Set-GameServicePath $service $service.PathName }
            if ($wasRunning) { Start-Service -InputObject $controller }
        } catch {
            throw "Could not apply Game Filter or restore the previous service configuration. Update: $failure. Restore: $_"
        }
        throw "Could not apply Game Filter to the service. Its previous configuration was restored. $failure"
    }
    Write-Host 'Game Filter settings applied to the zapret service.'
}

if ($Action -eq 'ReplaceActiveFile') {
    Replace-ActiveFile $env:source_file $env:active_file
    exit 0
}

if ($Action -eq 'SaveGameFilter') {
    $settings = Join-Path $PSScriptRoot 'game_filter.enabled'
    $lock = [IO.File]::Open("$settings.lock", 'OpenOrCreate', 'ReadWrite', 'None')
    $staged = $settings + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllLines($staged, [string[]]@(
            "mode=$env:GameFilterMode", "tcp=$env:GameFilterTCPRange", "udp=$env:GameFilterUDPRange"
        ))
        Install-StagedFile $staged $settings
        try {
            Update-GameService (Split-Path -Parent $PSScriptRoot)
        } catch {
            throw "Game Filter settings were saved. Service update failed. $_"
        }
    } finally {
        Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
        $lock.Dispose()
    }
    exit 0
}

if ($Action -in 'SwitchIpset', 'UpdateIpset') {
    $root = Split-Path -Parent $PSScriptRoot
    $list = Join-Path $root 'lists\ipset-all.txt'
    $flag = Join-Path $root 'ipset_switched.flag'
    try {
        $lock = [IO.File]::Open("$flag.lock", 'OpenOrCreate', 'ReadWrite', 'None')
    } catch {
        throw "Could not lock the IPSet list. Check for a running test or update. $_"
    }
    try {
        if (Test-Path -LiteralPath $flag) { throw 'Run the test tool to restore IPSet before changing the list.' }
        if ($Action -eq 'SwitchIpset') {
            Switch-Ipset $list
        } else {
            $url = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/ipset-service.txt'
            $staged = $list + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
            try {
                $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
                if (Test-Path -LiteralPath $curl) {
                    $tlsOption = if ((& $curl --version) -match 'libcurl/7') { '--ssl-no-revoke' } else { '--ssl-revoke-best-effort' }
                    $curlOptions = @($tlsOption, '-L', '-f', '--max-time', '30', '-o', $staged)
                    & $curl @curlOptions $url
                    if ($LASTEXITCODE -in 18, 28) {
                        Write-Warning "IPSet download interrupted (curl exit code $LASTEXITCODE). Retrying via the GitHub API."
                        $apiUrl = 'https://api.github.com/repos/Flowseal/zapret-discord-youtube/contents/.service/ipset-service.txt?ref=main'
                        & $curl @curlOptions -H 'Accept: application/vnd.github.raw+json' $apiUrl
                    }
                    if ($LASTEXITCODE -ne 0) { throw "IPSet download failed (curl exit code $LASTEXITCODE)." }
                } else {
                    Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Uri $url -OutFile $staged
                }
                Test-IpsetDownload $staged
                Install-StagedFile $staged $list
                Write-Host 'IPSet updated.'
            } finally {
                Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
            }
        }
    } finally {
        $lock.Dispose()
    }
    exit 0
}

$hostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$url = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/hosts?t=' + [guid]::NewGuid().ToString('N')
$temporary = [IO.Path]::GetTempFileName()
$keepDownload = $false
try {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $curl) {
        & $curl -L -sS -f --max-time 10 -o $temporary $url
        if ($LASTEXITCODE -ne 0) { throw "Hosts download failed (curl exit code $LASTEXITCODE)." }
    } else {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Uri $url -OutFile $temporary
    }

    if (Test-HostsCurrent $hostsFile $temporary) {
        Write-Host 'Hosts file is up to date' -ForegroundColor Green
    } else {
        Write-Host "Hosts file needs to be updated. Copy the missing entries from $temporary." -ForegroundColor Yellow
        Start-Process notepad.exe -ArgumentList ('"{0}"' -f $temporary)
        $keepDownload = $true
        Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $hostsFile)
    }
} finally {
    if (-not $keepDownload) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}
