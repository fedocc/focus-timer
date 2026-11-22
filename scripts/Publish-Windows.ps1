param([ValidateSet('win-x64','win-arm64')][string]$Runtime = 'win-x64')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$artifacts = Join-Path $root 'artifacts'
$publish = Join-Path $artifacts "publish-$Runtime"
New-Item -ItemType Directory -Force $artifacts | Out-Null
& dotnet publish (Join-Path $root 'windows/FocusTimer.App/FocusTimer.App.csproj') -c Release -r $Runtime --self-contained true -p:DebugType=None -p:DebugSymbols=false -o $publish
if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed' }
Copy-Item (Join-Path $publish 'FocusTimer.exe') (Join-Path $publish 'InstallFocus.exe') -Force
Copy-Item (Join-Path $root 'windows/README.md') (Join-Path $publish 'README.txt') -Force
$exe = [IO.File]::ReadAllBytes((Join-Path $publish 'FocusTimer.exe'))
$pe = [BitConverter]::ToInt32($exe, 0x3c)
if ([BitConverter]::ToUInt16($exe, $pe + 92) -ne 2) { throw 'App must use the Windows GUI subsystem' }
$manifest = [ordered]@{ version = '1.3.0'; runtime = $Runtime; commit = $env:GITHUB_SHA; selfContained = $true }
$manifest | ConvertTo-Json | Set-Content (Join-Path $publish 'build-info.json') -Encoding utf8
$files = @([IO.Directory]::EnumerateFiles($publish, '*', [IO.SearchOption]::AllDirectories) | ForEach-Object { [IO.Path]::GetRelativePath($publish, $_) } | Where-Object { $_ -ne 'distribution-files.json' })
ConvertTo-Json -InputObject $files | Set-Content (Join-Path $publish 'distribution-files.json') -Encoding utf8
$zip = Join-Path $artifacts "FocusTimer-Windows-$Runtime-1.3.0.zip"
Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $zip -Force
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $([IO.Path]::GetFileName($zip))" | Set-Content "$zip.sha256" -Encoding ascii
Write-Host "Packaged $zip"
