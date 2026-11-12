param([switch]$Test)

$ErrorActionPreference = 'Stop'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$sources = 'WinwsLauncher.cs', 'InterfaceSettings.cs', 'ProcessJob.cs' | ForEach-Object { Join-Path $PSScriptRoot $_ }
$options = '/nologo', '/optimize+', '/platform:x64', '/codepage:65001', '/reference:System.ServiceProcess.dll,System.Runtime.Serialization.dll'
if ($Test) {
    $output = Join-Path ([IO.Path]::GetTempPath()) ("zapret-tests-" + [guid]::NewGuid() + ".exe")
    $engine = [IO.Path]::ChangeExtension($output, 'engine.exe')
    $testSource = Join-Path $PSScriptRoot 'InterfaceBinding.Tests.cs'
    try {
        & $csc @options /main:FakeWinws "/out:$engine" @sources $testSource
        if ($LASTEXITCODE -ne 0) { throw "Test engine build failed ($LASTEXITCODE)." }
        & $csc @options /main:InterfaceBindingTests "/out:$output" @sources $testSource
        if ($LASTEXITCODE -ne 0) { throw "Launcher test build failed ($LASTEXITCODE)." }
        & $output $engine
        if ($LASTEXITCODE -ne 0) { throw "Launcher tests failed ($LASTEXITCODE)." }
    } finally {
        Remove-Item -LiteralPath $output,$engine -ErrorAction SilentlyContinue
    }
} else {
    $bin = Join-Path (Split-Path $PSScriptRoot) 'bin'
    if (-not (Test-Path -LiteralPath (Join-Path $bin 'winws-engine.exe'))) { throw "Bundled winws-engine.exe is missing." }
    $output = Join-Path $bin 'winws.exe'
    & $csc @options "/win32manifest:$PSScriptRoot\winws.manifest" "/out:$output" @sources
    if ($LASTEXITCODE -ne 0) { throw "Launcher build failed ($LASTEXITCODE)." }
}
