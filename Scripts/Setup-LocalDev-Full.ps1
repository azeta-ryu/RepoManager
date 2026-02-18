<#
.SYNOPSIS
    1. Creates 'AzApp_Workplace' on Desktop.
    2. Clones repos & Logs content.
    3. Links references via LocalDev.targets.
    4. Generates a MODERN .slnx solution file directly.
    5. Opens the folder in File Explorer.
#>

# --- SETUP DESTINATION ---
$DesktopPath = [Environment]::GetFolderPath("Desktop")
$WorkFolder = "AzApp_Workplace"
$RootFolder = Join-Path $DesktopPath $WorkFolder

if (-not (Test-Path $RootFolder)) { New-Item -ItemType Directory -Force -Path $RootFolder | Out-Null }

# --- HARDCODED URLS ---
$libUrl  = "https://azetagrupo@dev.azure.com/azetagrupo/D365/_git/AzApp.DataEntity"
$app1Url = "https://azetagrupo@dev.azure.com/azetagrupo/D365/_git/BackendAzApp"
$app2Url = "https://azetagrupo@dev.azure.com/azetagrupo/D365/_git/AzServicesQueue"

# --- Configuration Helper ---
function Get-Credentials {
    Clear-Host
    Write-Host "`n=== AzApp Unified Local Dev Setup (Modern Edition) ===`n" -ForegroundColor Cyan
    Write-Host "Target Folder: $RootFolder" -ForegroundColor Gray
    Write-Host "------------------------------------------------"
    Write-Host "Please enter your Git Credentials:" -ForegroundColor Yellow
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
        if ($LASTEXITCODE -ne 0) { Write-Error "Clone failed"; Read-Host "Enter to exit"; exit 1 }

        Write-Host "  [Content of $DestName]" -ForegroundColor Cyan
        try { Get-ChildItem "$RootFolder\$DestName" | Select-Object Name, Mode | Format-Table -AutoSize | Out-String | Write-Host -ForegroundColor DarkGray } catch {}
        Write-Host "------------------------------------------------" -ForegroundColor Gray
    }
}

# --- Main Logic ---

$creds = Get-Credentials

$libName  = ($libUrl  -split '/')[-1] -replace '\.git$', ''
$app1Name = ($app1Url -split '/')[-1] -replace '\.git$', ''
$app2Name = ($app2Url -split '/')[-1] -replace '\.git$', ''

Clone-Repo -Url $libUrl -Creds $creds -DestName $libName
Clone-Repo -Url $app1Url -Creds $creds -DestName $app1Name
Clone-Repo -Url $app2Url -Creds $creds -DestName $app2Name

# --- Analyze Library ---
Write-Host "`nConfiguring References..." -ForegroundColor Cyan
$allLibProjects = Get-ChildItem -Path "$RootFolder\$libName" -Filter "*.csproj" -Recurse
$libCsproj = $allLibProjects | Where-Object { $_.Name -notmatch "Test" } | Select-Object -First 1

if (-not $libCsproj) { Write-Error "Library .csproj not found!"; Read-Host "Enter to exit"; exit 1 }

[xml]$libXml = Get-Content $libCsproj.FullName
$packageId = $libXml.Project.PropertyGroup.PackageId
if (-not $packageId) { $packageId = $libXml.Project.PropertyGroup.AssemblyName }
if (-not $packageId) { $packageId = $libCsproj.BaseName }

Write-Host "  Library Found: $($libCsproj.Name)" -ForegroundColor Green

# --- Create Targets ---
$targetFileName = "LocalDev.targets"
$apps = @( @{ Name=$app1Name; Path="$RootFolder\$app1Name" }, @{ Name=$app2Name; Path="$RootFolder\$app2Name" } )
$foundAppCsprojs = @()

foreach ($app in $apps) {
    $appCsproj = Get-ChildItem -Path $app.Path -Filter "*.csproj" -Recurse | Where-Object { $_.Name -notmatch "Test" } | Select-Object -First 1
    if (-not $appCsproj) { continue }

    # Store for solution generation
    $foundAppCsprojs += $appCsproj

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
        if ($gitContent -notcontains $targetFileName) { Add-Content -Path $gitignorePath -Value "`n$targetFileName" }
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
    }
}

# --- Unified Solution (MANUAL .SLNX GENERATION) ---
$slnxName = "LocalDev.slnx"
$slnxPath = Join-Path $RootFolder $slnxName

Write-Host "`nGenerating Modern Solution ($slnxName)..." -ForegroundColor Cyan

# We build the XML manually to ensure it is valid and includes all projects
$slnxContent = @"
<Solution>
  <Project Path="$($libCsproj.FullName)" />
"@

foreach ($appProj in $foundAppCsprojs) {
    $slnxContent += "`n  <Project Path=`"$($appProj.FullName)`" />"
}

$slnxContent += "`n</Solution>"

$slnxContent | Set-Content -Path $slnxPath
Write-Host "  Created $slnxName successfully." -ForegroundColor Green

Write-Host "`nSUCCESS! Your workplace is ready." -ForegroundColor Green
Write-Host "Opening folder: $RootFolder" -ForegroundColor Gray

# Open the folder automatically
explorer $RootFolder

Write-Host "`n------------------------------------------------"
Read-Host "Press Enter to exit..."
