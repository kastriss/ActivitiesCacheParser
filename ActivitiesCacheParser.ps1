
$cdpPath = "$env:LOCALAPPDATA\ConnectedDevicesPlatform"
if (-not (Test-Path $cdpPath)) {
    Write-Error "ConnectedDevicesPlatform directory not found."
    return
}

$dbFile = Get-ChildItem -Path $cdpPath -Filter "ActivitiesCache.db" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $dbFile) {
    Write-Error "Could not locate ActivitiesCache.db file. Might be disabled"
    return
}

Write-Host "Accessing the Activitiescache.db file..." -ForegroundColor Cyan
$tempDbPath = Join-Path $env:TEMP "ActivitiesCache_Timeline.db"

try {
    Copy-Item -Path $dbFile.FullName -Destination $tempDbPath -Force -ErrorAction Stop
}
catch {
    Write-Error "Failed to clone database file: $_"
    return
}

Write-Host "Extracting paths and timeline execution history timestamps..." -ForegroundColor Cyan

$results = New-Object System.Collections.Generic.List[PSObject]
$seenPaths = @{}

try {
    # Read the cloned database as bytes to analyze nearby data headers
    $fileBytes = [System.IO.File]::ReadAllBytes($tempDbPath)
    $rawText = [System.Text.Encoding]::UTF8.GetString($fileBytes)

    # Split the raw data array into logical string fragments
    $stringChunks = $rawText -split '"'

    for ($i = 0; $i -lt $stringChunks.Count; $i++) {
        $chunk = $stringChunks[$i]

        if ($chunk -like "*:\*" -and $chunk -like "*.exe*") {
            
            $cleanPath = $chunk.Replace('\\', '\').Trim()

            if ($cleanPath -match '^([A-Za-z]:\\[^ ]+\.exe)') {
                $cleanPath = $Matches[1]
            }

            $lowerPath = $cleanPath.ToLower()
            if ($seenPaths.ContainsKey($lowerPath) -or $cleanPath -notmatch '^[A-Z]:\\') {
                continue
            }
            $seenPaths[$lowerPath] = $true

            $exeName = Split-Path $cleanPath -Leaf

            # --- TIMESTAMP EXTRACTION LAYER ---
            # Search nearby binary text fragments for the corresponding Unix Epoch time window
            $launchTime = "Unknown / Not Captured"
            
            # Search the preceding text strings for execution date properties
            for ($j = [Math]::Max(0, $i-5); $j -lt $i; $j++) {
                if ($stringChunks[$j] -match '(\d{10})') {
                    $epochVal = [int64]$Matches[1]
                    # Filter out values that fall well outside modern time frameworks
                    if ($epochVal -gt 1500000000 -and $epochVal -lt 2500000000) {
                        $utcTime = [DateTimeOffset]::FromUnixTimeSeconds($epochVal).DateTime
                        $launchTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($utcTime, [System.TimeZoneInfo]::Local).ToString("yyyy-MM-dd HH:mm:ss")
                        break
                    }
                }
            }

            # If the database does not contain a specific timeline tracking flag, use the last modified time of the file itself
            if ($launchTime -eq "Unknown / Not Captured" -and (Test-Path $cleanPath -PathType Leaf)) {
                $launchTime = (Get-Item $cleanPath).LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss") + " (File Modified Time)"
            }

            # Check digital signature authenticode details
            $signatureStatus = "File Not Found"
            if (Test-Path $cleanPath -PathType Leaf) {
                try {
                    $sig = Get-AuthenticodeSignature -FilePath $cleanPath -ErrorAction SilentlyContinue
                    $signatureStatus = $sig.Status.ToString()
                } catch {
                    $signatureStatus = "Check Error"
                }
            }

            # Append the data row properties including our new Launch Time column
            $results.Add([PSCustomObject]@{
                "Executable Name" = $exeName
                "Full Path"       = $cleanPath
                "Launch Time"     = $launchTime
                "Signature"       = $signatureStatus
            })
        }
    }
}
catch {
    Write-Error "An error occurred reading binary data blocks: $_"
}
finally {
    if (Test-Path $tempDbPath) {
        Remove-Item $tempDbPath -Force -ErrorAction SilentlyContinue
    }
}

# CSV OUTPUT
if ($results.Count -gt 0) {
    # Define file target directly to your Windows desktop environment
    $csvPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "Timeline_Execution_Report.csv"
    
    # Save the structured file output layout
    $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    
    Write-Host "Success! Found $($results.Count) historical application log traces." -ForegroundColor Green
    Write-Host "Report generated successfully at: $csvPath" -ForegroundColor Green
    
    # Still open the interactive graphic grid layout on screen for immediate viewing
    $results | Out-GridView -Title "ActivitiesCache Internal Execution Records"
} else {
    Write-Warning "Database read successfully, but zero application paths were found inside."
}

# Credits
Write-Host "Made by kastris_" -ForegroundColor Magenta
