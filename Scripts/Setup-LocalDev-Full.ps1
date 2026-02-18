<#
.SYNOPSIS
    1. Creates a folder 'AzApp_Workplace' on your Desktop.
    2. Clones the specific AzApp repositories into it.
    3. Smart-detects the correct .csproj (ignoring Test projects).
    4. Links them via LocalDev.targets.
    5. Creates a unified 'LocalDev.sln' inside that folder.
#>

# --- SETUP DESTINATION ---
$DesktopPath = [Environment]::GetFolderPath("Desktop")
$WorkFolder = "AzApp_Workplace"
$RootFolder = Join-Path $DesktopPath $WorkFolder

# Create the directory if it doesn't exist
if (-not (Test-Path $RootFolder)) {
    New-Item -ItemType Directory -Force -Path $RootFolder | Out-Null
}

# --- HARDCODED URLS ---
$libUrl  = "https://azetagrupo@dev.azure.com/azetagrupo/D365/_git/AzApp.DataEntity"
$app1Url = "https://azetagrupo@dev.azure.com/azetagrupo/D365/_git/BackendAzApp"
$app2Url = "https://azetagrupo@dev.azure.com/azetagrupo/D365/_git/AzServicesQueue"

# --- Configuration Helper ---
function Get-Credentials {
    Clear-Host
    Write-Host "`n=== AzApp Unified Local Dev Setup ===`n" -ForegroundColor Cyan
    Write-Host "Target Folder: $RootFolder" -ForegroundColor Gray
    Write-Host "------------------------------------------------"
    Write-Host "Please enter your Git Credentials (from the 'Generate Git Credentials' button):" -ForegroundColor Yellow
    $user = Read-Host "Username"
    $token = Read-Host "Password/PAT"

    if (-not $token) { return $null }
    return @{ User = $user; Token = $token }
}

function Clone-Repo {
    param ($Url, $Creds, $DestName)

    $finalUrl = $Url
    if ($Creds) {
        $cleanUrl = $Url -replace "^https?://([^@]+@)?", ""
        $finalUrl = "https://$($Creds.User):$($Creds.Token)@$cleanUrl"
    }

    if (Test-Path "$RootFolder\$DestName") {
        Write-Host "  Folder '$DestName' already exists. Skipping clone." -ForegroundColor Yellow
    }
    else {
        Write-Host "  Cloning $DestName..." -ForegroundColor Green
        git clone $finalUrl "$RootFolder\$DestName"
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Clone failed for $DestName"
            Read-Host "Press Enter to exit..."
            exit 1
        }
    }
}

# --- Main Logic ---

# 1. Gather Credentials
$creds = Get-Credentials

# 2. Clone Repositories
$libName = ($libUrl -split '/')[-1] -replace '\.git$', ''
$app1Name = ($app1Url -split '/')[-1] -replace '\.git$', ''
$app2Name = ($app2Url -split '/')[-1] -replace '\.git$', ''

Clone-Repo -Url $libUrl -Creds $creds -DestName $libName
Clone-Repo -Url $app1Url -Creds $creds -DestName $app1Name
Clone-Repo -Url $app2Url -Creds $creds -DestName $app2Name

# 3. Analyze Library Project (SMARTER SELECTION)
Write-Host "`nConfiguring References..." -ForegroundColor Cyan

# Find all csproj files in the library folder
$allLibProjects = Get-ChildItem -Path "$RootFolder\$libName" -Filter "*.csproj" -Recurse

# Filter OUT any project that contains "Test" in the name to ensure we get the SRC project
$libCsproj = $allLibProjects | Where-Object { $_.Name -notmatch "Test" } | Select-Object -First 1

if (-not $libCsproj) {
    Write-Error "Could not find a valid Library .csproj (ignoring Tests) in $libName!"
    Read-Host "Press Enter to exit..."
    exit 1
}

[xml]$libXml = Get-Content $libCsproj.FullName
$packageId = $libXml.Project.PropertyGroup.PackageId
if (-not $packageId) { $packageId = $libXml.Project.PropertyGroup.AssemblyName }
if (-not $packageId) { $packageId = $libCsproj.BaseName }

Write-Host "  Library Found: $($libCsproj.Name)" -ForegroundColor Green
Write-Host "  Package ID:    $packageId" -ForegroundColor Gray

# 4. Create Targets File & Inject Import
$targetFileName = "LocalDev.targets"
$apps = @(
    @{ Name=$app1Name; Path="$RootFolder\$app1Name" },
    @{ Name=$app2Name; Path="$RootFolder\$app2Name" }
)

foreach ($app in $apps) {
    # Find App csproj (Also ignoring Tests just in case)
    $appCsproj = Get-ChildItem -Path $app.Path -Filter "*.csproj" -Recurse | Where-Object { $_.Name -notmatch "Test" } | Select-Object -First 1

    if (-not $appCsproj) {
        Write-Warning "  No .csproj found in $($app.Name). Skipping."
        continue
    }

    $targetsContent = @"
<Project>
  <ItemGroup>
    <PackageReference Remove="$packageId" />
    <ProjectReference Include="$($libCsproj.FullName)" />
  </ItemGroup>
</Project>
"@
    $targetsPath = Join-Path $appCsproj.DirectoryName $targetFileName
    $targetsContent | Set-Content -Path $targetsPath

    $gitignorePath = Join-Path $app.Path ".gitignore"
    if (Test-Path $gitignorePath) {
        $gitContent = Get-Content $gitignorePath
        if ($gitContent -notcontains $targetFileName) {
            Add-Content -Path $gitignorePath -Value "`n$targetFileName"
        }
    }

    [xml]$appXml = Get-Content $appCsproj.FullName
    $existingImport = $appXml.Project.Import | Where-Object { $_.Project -eq $targetFileName }

    if (-not $existingImport) {
        $newImport = $appXml.CreateElement("Import", $appXml.Project.NamespaceURI)
        $newImport.SetAttribute("Project", $targetFileName)
        $newImport.SetAttribute("Condition", "Exists('$targetFileName')")

        $appXml.Project.AppendChild($newImport) | Out-Null
        $appXml.Save($appCsproj.FullName)
        Write-Host "  Linked Library to $($app.Name)" -ForegroundColor Green
    } else {
        Write-Host "  Link already exists for $($app.Name)" -ForegroundColor Yellow
    }
}

# 5. Create Unified Solution
$slnName = "LocalDev.sln"

Write-Host "`nGenerating Unified Solution ($slnName)..." -ForegroundColor Cyan

# Change context to the WORKPLACE folder on Desktop
Push-Location $RootFolder

try {
    # 1. Create Solution if missing
    if (-not (Test-Path $slnName)) {
        dotnet new sln -n "LocalDev"
        Write-Host "  Created new empty solution." -ForegroundColor Green
    } else {
        Write-Host "  Solution already exists." -ForegroundColor Yellow
    }

    # 2. Add Library (Using Quotes for safety)
    dotnet sln $slnName add "$($libCsproj.FullName)"
    Write-Host "  Added Library project." -ForegroundColor Gray

    # 3. Add Apps
    foreach ($app in $apps) {
        $appCsproj = Get-ChildItem -Path $app.Path -Filter "*.csproj" -Recurse | Where-Object { $_.Name -notmatch "Test" } | Select-Object -First 1
        if ($appCsproj) {
            dotnet sln $slnName add "$($appCsproj.FullName)"
            Write-Host "  Added $($app.Name) project." -ForegroundColor Gray
        }
    }
}
catch {
    Write-Error "Error updating solution: $_"
}
finally {
    # Always return to original folder
    Pop-Location
}

Write-Host "`nSUCCESS! Check your Desktop for the 'AzApp_Workplace' folder." -ForegroundColor Green
Write-Host "Open '$WorkFolder\LocalDev.sln' to start."
Write-Host "`n------------------------------------------------"
Read-Host "Press Enter to exit..."
