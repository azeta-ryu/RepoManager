<#
.SYNOPSIS
    1. Clones the Library and two Apps.
    2. Links them via LocalDev.targets (swapping NuGet for Source).
    3. Creates a unified 'LocalDev.sln' for Visual Studio.
#>

param (
    [string]$RootFolder = (Get-Location)
)

# --- Configuration Helper ---
function Get-RepoUrl {
    param ([string]$Prompt)
    $url = Read-Host -Prompt $Prompt
    return $url.Trim()
}

function Get-Credentials {
    $useCreds = Read-Host "Do you want to embed a PAT (Personal Access Token) for cloning? (y/n) [Default: n]"
    if ($useCreds -eq 'y') {
        $user = Read-Host "Username"
        $token = Read-Host "PAT/Password"
        return @{ User = $user; Token = $token }
    }
    return $null
}

function Clone-Repo {
    param ($Url, $Creds, $DestName)

    $finalUrl = $Url
    if ($Creds) {
        $cleanUrl = $Url -replace "^https?://", ""
        $finalUrl = "https://$($Creds.User):$($Creds.Token)@$cleanUrl"
    }

    if (Test-Path "$RootFolder\$DestName") {
        Write-Host "  Folder '$DestName' already exists. Skipping clone." -ForegroundColor Yellow
    }
    else {
        Write-Host "  Cloning $DestName..." -ForegroundColor Green
        git clone $finalUrl "$RootFolder\$DestName"
        if ($LASTEXITCODE -ne 0) { Write-Error "Clone failed for $DestName"; exit 1 }
    }
}

# --- Main Logic ---

Write-Host "`n=== .NET Unified Local Dev Setup ===`n" -ForegroundColor Cyan

# 1. Gather Info
$libUrl  = Get-RepoUrl "Enter URL for the SHARED LIBRARY repo"
$app1Url = Get-RepoUrl "Enter URL for APP #1 repo"
$app2Url = Get-RepoUrl "Enter URL for APP #2 repo"
$creds   = Get-Credentials

# 2. Clone Repositories
$libName = ($libUrl -split '/')[-1] -replace '\.git$', ''
$app1Name = ($app1Url -split '/')[-1] -replace '\.git$', ''
$app2Name = ($app2Url -split '/')[-1] -replace '\.git$', ''

Clone-Repo -Url $libUrl -Creds $creds -DestName $libName
Clone-Repo -Url $app1Url -Creds $creds -DestName $app1Name
Clone-Repo -Url $app2Url -Creds $creds -DestName $app2Name

# 3. Analyze Library Project
Write-Host "`nConfiguring References..." -ForegroundColor Cyan
$libCsproj = Get-ChildItem -Path "$RootFolder\$libName" -Filter "*.csproj" -Recurse | Select-Object -First 1
if (-not $libCsproj) { Write-Error "Could not find .csproj in library repo!"; exit 1 }

[xml]$libXml = Get-Content $libCsproj.FullName
$packageId = $libXml.Project.PropertyGroup.PackageId
if (-not $packageId) { $packageId = $libXml.Project.PropertyGroup.AssemblyName }
if (-not $packageId) { $packageId = $libCsproj.BaseName }

Write-Host "  Library: $($libCsproj.Name) (PackageId: $packageId)" -ForegroundColor Gray

# 4. Create Targets File & Inject Import
$targetFileName = "LocalDev.targets"
$apps = @(
    @{ Name=$app1Name; Path="$RootFolder\$app1Name" },
    @{ Name=$app2Name; Path="$RootFolder\$app2Name" }
)

foreach ($app in $apps) {
    $appCsproj = Get-ChildItem -Path $app.Path -Filter "*.csproj" -Recurse | Select-Object -First 1
    if (-not $appCsproj) { continue }

    # Create the targets file content
    $targetsContent = @"
<Project>
  <ItemGroup>
    <PackageReference Remove="$packageId" />
    <ProjectReference Include="$($libCsproj.FullName)" />
  </ItemGroup>
</Project>
"@
    # Write targets file
    $targetsPath = Join-Path $appCsproj.DirectoryName $targetFileName
    $targetsContent | Set-Content -Path $targetsPath

    # Add to .gitignore
    $gitignorePath = Join-Path $app.Path ".gitignore"
    if (Test-Path $gitignorePath) {
        $gitContent = Get-Content $gitignorePath
        if ($gitContent -notcontains $targetFileName) { Add-Content -Path $gitignorePath -Value "`n$targetFileName" }
    }

    # Inject Import into .csproj
    [xml]$appXml = Get-Content $appCsproj.FullName
    $existingImport = $appXml.Project.Import | Where-Object { $_.Project -eq $targetFileName }

    if (-not $existingImport) {
        $newImport = $appXml.CreateElement("Import", $appXml.Project.NamespaceURI)
        $newImport.SetAttribute("Project", $targetFileName)
        $newImport.SetAttribute("Condition", "Exists('$targetFileName')")
        $appXml.Project.AppendChild($newImport) | Out-Null
        $appXml.Save($appCsproj.FullName)
        Write-Host "  Linked Library to $($app.Name)" -ForegroundColor Green
    }
}

# 5. Create Unified Solution (The New Part)
$slnName = "LocalDev.sln"
$slnPath = "$RootFolder\$slnName"

Write-Host "`nGenerating Unified Solution ($slnName)..." -ForegroundColor Cyan

if (Test-Path $slnPath) {
    # If it exists, we just update it
    Write-Host "  Solution already exists, refreshing projects..." -ForegroundColor Yellow
} else {
    dotnet new sln -n "LocalDev" -o $RootFolder | Out-Null
    Write-Host "  Created new empty solution." -ForegroundColor Green
}

# Add Library to Solution
dotnet sln $slnPath add $libCsproj.FullName --in-root
Write-Host "  Added Library project." -ForegroundColor Gray

# Add Apps to Solution
foreach ($app in $apps) {
    $appCsproj = Get-ChildItem -Path $app.Path -Filter "*.csproj" -Recurse | Select-Object -First 1
    if ($appCsproj) {
        dotnet sln $slnPath add $appCsproj.FullName --in-root
        Write-Host "  Added $($app.Name) project." -ForegroundColor Gray
    }
}

Write-Host "`nSUCCESS! Open '$slnName' in Visual Studio to start coding." -ForegroundColor Green
