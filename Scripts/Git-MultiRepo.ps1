<#
.SYNOPSIS
    Manages Git operations across all sub-repositories in the current folder.
#>

param (
    [string]$RootFolder = (Get-Location)
)

function Get-GitRepos {
    # Finds all subfolders that contain a .git folder
    return Get-ChildItem -Path $RootFolder -Directory | Where-Object { Test-Path "$($_.FullName)\.git" }
}

function Run-GitCommand {
    param ($Repos, $Command, $ArgsList, $Description)

    Write-Host "`n--- $Description ---" -ForegroundColor Cyan

    foreach ($repo in $Repos) {
        Write-Host "[$($repo.Name)]" -NoNewline -ForegroundColor Yellow
        Push-Location $repo.FullName

        # Run the git command
        try {
            # We use Invoke-Expression or direct execution. Direct is safer.
            $output = & git $ArgsList 2>&1

            if ($LASTEXITCODE -eq 0) {
                Write-Host " Success" -ForegroundColor Green
            } else {
                Write-Host " FAILED" -ForegroundColor Red
                Write-Host $output -ForegroundColor DarkGray
            }
        }
        catch {
            Write-Host " Error: $_" -ForegroundColor Red
        }

        Pop-Location
    }
}

# --- Menu ---

Clear-Host
Write-Host "=== Multi-Repo Git Manager ===" -ForegroundColor Magenta
Write-Host "1. Create New Branch (Checkout -b)"
Write-Host "2. Switch Branch (Checkout)"
Write-Host "3. Pull All (Fetch & Pull)"
Write-Host "4. Check Status"
Write-Host "Q. Quit"

$repos = Get-GitRepos
if ($repos.Count -eq 0) {
    Write-Warning "No git repositories found in this folder."
    exit
}
Write-Host "`nFound $($repos.Count) repositories: $($repos.Name -join ', ')" -ForegroundColor DarkGray

$choice = Read-Host "`nSelect an option"

switch ($choice) {
    "1" {
        $branch = Read-Host "Enter NEW branch name"
        if (-not $branch) { break }
        # args: checkout -b <name>
        Run-GitCommand -Repos $repos -Command "git" -ArgsList "checkout", "-b", $branch -Description "Creating branch '$branch'"
    }
    "2" {
        $branch = Read-Host "Enter existing branch to switch to"
        if (-not $branch) { break }
        # args: checkout <name>
        Run-GitCommand -Repos $repos -Command "git" -ArgsList "checkout", $branch -Description "Switching to '$branch'"
    }
    "3" {
        # args: pull
        Run-GitCommand -Repos $repos -Command "git" -ArgsList "pull" -Description "Pulling latest changes"
    }
    "4" {
        # args: status -s
        Write-Host "`n--- Status Report ---" -ForegroundColor Cyan
        foreach ($repo in $repos) {
            Push-Location $repo.FullName
            $status = git status -s
            if ($status) {
                Write-Host "[$($repo.Name)] Has Changes:" -ForegroundColor Red
                Write-Host $status -ForegroundColor Gray
            } else {
                Write-Host "[$($repo.Name)] Clean" -ForegroundColor Green
            }
            Pop-Location
        }
    }
    "Q" { exit }
    default { Write-Warning "Invalid option." }
}
