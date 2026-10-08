param([string]$Output = (Join-Path $PSScriptRoot "..\dist\windows-x64"))
$ErrorActionPreference = "Stop"
dotnet publish (Join-Path $PSScriptRoot "AIExitWatch\AIExitWatch.csproj") -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:PublishTrimmed=false -o $Output
if ($LASTEXITCODE -ne 0) { throw "Windows 构建失败" }
Copy-Item (Join-Path $PSScriptRoot "使用说明.txt") (Join-Path $Output "使用说明.txt")
foreach ($file in @("LICENSE", "PRIVACY.md", "THIRD_PARTY_NOTICES.md")) {
    Copy-Item (Join-Path $PSScriptRoot "..\$file") (Join-Path $Output $file)
}
$assets = Get-Content (Join-Path $PSScriptRoot "AIExitWatch\obj\project.assets.json") -Raw | ConvertFrom-Json
$framework = $assets.project.frameworks.PSObject.Properties.Value | Select-Object -First 1
$packages = $assets.packageFolders.PSObject.Properties.Name
$licenseDir = Join-Path $Output "runtime-licenses"
New-Item -ItemType Directory -Force $licenseDir | Out-Null
$runtimeLicenses = @{
    "Microsoft.NETCore.App.Runtime.win-x64" = @("LICENSE.TXT", "THIRD-PARTY-NOTICES.TXT")
    "Microsoft.WindowsDesktop.App.Runtime.win-x64" = @("LICENSE")
}
foreach ($name in $runtimeLicenses.Keys) {
    $dependency = $framework.downloadDependencies | Where-Object name -eq $name | Select-Object -First 1
    if (-not $dependency) { throw "缺少运行包版本：$name" }
    $version = $dependency.version.Trim('[', ']').Split(',')[0].Trim()
    foreach ($file in $runtimeLicenses[$name]) {
        $source = $packages | ForEach-Object { Join-Path $_ "$($name.ToLowerInvariant())/$version/$file" } | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $source) { throw "缺少运行库声明：$name/$file" }
        Copy-Item $source (Join-Path $licenseDir "$name-$file.txt")
    }
}
Write-Host "Windows x64 便携版已生成：$Output"
