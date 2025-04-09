Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# INI path and loader
$iniPath = "$PSScriptRoot\GenerateAchlistFromFolder.ini"
$config = @{}
if (Test-Path $iniPath) {
    Get-Content $iniPath | ForEach-Object {
        if ($_ -match '^\s*([^=]+?)\s*=\s*(.*)$') {
            $key = $matches[1].Trim()
            $val = $matches[2].Trim()
            $config[$key] = $val
        }
    }
}


if (-not ($config.ContainsKey('Archive2Path')) -or -not (Test-Path $config['Archive2Path'])) {
    $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $fileDialog.Title = "Locate Archive2.exe"
    $fileDialog.Filter = "Executable (*.exe)|*.exe"
    $fileDialog.FileName = "Archive2.exe"
    if ($fileDialog.ShowDialog() -eq 'OK') {
        $config['Archive2Path'] = $fileDialog.FileName
        Save-Ini
    } else {
        [System.Windows.Forms.MessageBox]::Show("Archive2.exe is required to extract .ba2 files.", "Missing Tool", 'OK', 'Error')
        exit
    }
}

# Ensure Xbox builder script path is set
if (-not ($config.ContainsKey('XboxBuilderScript')) -or -not (Test-Path $config['XboxBuilderScript'])) {
    $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $fileDialog.Title = "Locate Xbox Builder Script"
    $fileDialog.Filter = "PowerShell Script (*.ps1)|*.ps1"
    $fileDialog.FileName = "XBoxArchiveFromWindowsAchlist.ps1"
    if ($fileDialog.ShowDialog() -eq 'OK') {
        $config['XboxBuilderScript'] = $fileDialog.FileName
        Save-Ini
    } else {
        [System.Windows.Forms.MessageBox]::Show("Xbox builder script is required to continue.", "Missing Script", 'OK', 'Error')
        exit
    }
}

function Save-Ini {
    $lines = @()
    foreach ($key in $config.Keys) {
        $lines += "$key=$($config[$key])"
    }
    $lines | Set-Content -Path $iniPath -Encoding UTF8
}
function Generate-Achlist {
    param (
        [string]$baseFolder,
        [string]$outputPath = $null  # override where to save it
    )

    $dataRoot = if (Test-Path (Join-Path $baseFolder 'Data')) {
        Join-Path $baseFolder 'Data'
    } else {
        $baseFolder
    }

    if (-not (Test-Path $dataRoot)) {
        [System.Windows.Forms.MessageBox]::Show($form, "No valid Data folder found.", "Error", 'OK', 'Error')
        return
    }

    $files = Get-ChildItem -Path $dataRoot -Recurse -File | ForEach-Object {
        $_.FullName.Substring($dataRoot.Length + 1).Replace('/', '\\').Replace('\\\\', '\\')
    }

    if (-not $files.Count) {
        [System.Windows.Forms.MessageBox]::Show($form, "No files found under Data folder.", "Error", 'OK', 'Error')
        return
    }

    $modName = Split-Path $baseFolder -Leaf
    if (-not $outputPath) {
        $outputPath = Join-Path (Split-Path $dataRoot -Parent) "$modName.achlist"
    }

    $lines = @("[")
    for ($i = 0; $i -lt $files.Count; $i++) {
        $escapedPath = 'Data\\' + ($files[$i] -replace '\\', '\\')
        $comma = if ($i -lt $files.Count - 1) { "," } else { "" }
        $lines += '"' + $escapedPath + '"' + $comma
    }
    $lines += "]"
    

    $testJson = $lines -join "`n"
    try {
        $null = $testJson | ConvertFrom-Json -ErrorAction Stop
    } catch {
        [System.Windows.Forms.MessageBox]::Show($form, "Generated .achlist failed JSON validation:`n$($_.Exception.Message)", "JSON Error", 'OK', 'Error')
        return
    }

    [System.IO.File]::WriteAllLines($outputPath, $lines, [System.Text.UTF8Encoding]::new($false))
    [System.Windows.Forms.MessageBox]::Show($form, "Achlist created at:`n$outputPath", "Success", 'OK', 'Information')
}



# UI
$form = New-Object System.Windows.Forms.Form
$form.Text = "Generate .achlist from Folder"
$form.Size = New-Object System.Drawing.Size(500,150)
$form.StartPosition = "CenterScreen"
$form.Topmost = $true
$form.AllowDrop = $true

$label = New-Object System.Windows.Forms.Label
$label.Text = "Drop folder here or click Browse:"
$label.AutoSize = $true
$label.Location = New-Object System.Drawing.Point(10,20)
$form.Controls.Add($label)

$textBox = New-Object System.Windows.Forms.TextBox
$textBox.Size = New-Object System.Drawing.Size(350, 20)
$textBox.Location = New-Object System.Drawing.Point(10, 50)
$textBox.AllowDrop = $true
$textBox.Text = if ($config.ContainsKey('LastFolder')) { $config['LastFolder'] } else { '' }
$form.Controls.Add($textBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = "Browse"
$browseButton.Size = New-Object System.Drawing.Size(100, 24)
$browseButton.Location = New-Object System.Drawing.Point(370, 47)
$form.Controls.Add($browseButton)

$goButton = New-Object System.Windows.Forms.Button
$goButton.Text = "Generate .achlist"
$goButton.Size = New-Object System.Drawing.Size(460, 30)
$goButton.Location = New-Object System.Drawing.Point(10, 80)
$form.Controls.Add($goButton)

$folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog

$browseButton.Add_Click({
    if ($folderDialog.ShowDialog() -eq "OK") {
        $textBox.Text = $folderDialog.SelectedPath
    }
})

$textBox.Add_DragEnter({
    if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
        $_.Effect = 'Copy'
    }
})

$textBox.Add_DragDrop({
    $drop = $_.Data.GetData([Windows.Forms.DataFormats]::FileDrop)
    if ($drop.Length -eq 0) { return }

    $path = $drop[0]
    $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()

# === Case 1: Dropped .ba2 ===
if ($ext -eq ".ba2") {
    $filename = [System.IO.Path]::GetFileName($path)
    $dir = [System.IO.Path]::GetDirectoryName($path)

    # Normalize mod name from filename (case-insensitive strip of suffix)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($filename)
    $modName = $baseName -ireplace '\s*-\s*(Main|Textures|Main_xbox)$', ''



    # If dropped file is NOT a - Main.ba2, find the correct one
    if ($filename -notmatch ' - Main\.ba2$') {
        $mainCandidate = Join-Path $dir "$modName - Main.ba2"
        if (-not (Test-Path $mainCandidate)) {
            [System.Windows.Forms.MessageBox]::Show($form, "Could not find matching ' - Main.ba2' for:`n$modName", "Missing Archive", 'OK', 'Error')
            return
        }
        $mainPath = $mainCandidate
    } else {
        $mainPath = $path
    }

    # Now do the rest as usual
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $tmpFolder = Join-Path $env:TEMP "tmp_$timestamp"
    New-Item -ItemType Directory -Path $tmpFolder | Out-Null

    $archive2 = $config['Archive2Path']
    Start-Process -FilePath $archive2 -ArgumentList "`"$mainPath`"", "-extract=`"$tmpFolder`"" -Wait -NoNewWindow

    $texturesPath = Join-Path $dir "$modName - Textures.ba2"
    if (Test-Path $texturesPath) {
        Start-Process -FilePath $archive2 -ArgumentList "`"$texturesPath`"", "-extract=`"$tmpFolder`"" -Wait -NoNewWindow
    }

    $suppressBuilderPrompt = $true
    $achlistTarget = Join-Path $dir "$modName.achlist"
    Generate-Achlist -baseFolder $tmpFolder -outputPath $achlistTarget

    # Optional sanity check
    $lines = Get-Content $achlistTarget | Where-Object { $_ -match '^\s*"' }
    $fileCount = (Get-ChildItem -Path $tmpFolder -Recurse -File).Count
    if ($lines.Count -ne $fileCount) {
        [System.Windows.Forms.MessageBox]::Show($form, "Sanity check warning:`n.achlist has $($lines.Count) entries, but found $fileCount files.", "Warning", 'OK', 'Warning')
    }


    Remove-Item -Path $tmpFolder -Recurse -Force
    return
}



    # === Case 2: Dropped folder ===
    if (Test-Path $path -and (Get-Item $path).PSIsContainer) {
        $textBox.Text = $path
        return
    }

    # === Case 3: Dropped .achlist (do not generate from it!) ===
    if ($ext -eq ".achlist") {
        $textBox.Text = $path
        return
    }

    # === Case 4: Dropped .esm or .esp (convert to .achlist name) ===
    if ($ext -in @(".esm", ".esp")) {
        $achlistGuess = [System.IO.Path]::ChangeExtension($path, ".achlist")
        if (Test-Path $achlistGuess) {
            $textBox.Text = $achlistGuess
        } else {
            [System.Windows.Forms.MessageBox]::Show("No .achlist found next to:`n$path", "Missing .achlist", 'OK', 'Warning')
        }
        return
    }

    [System.Windows.Forms.MessageBox]::Show("Unsupported drop type: $path", "Error", 'OK', 'Error')
})


$goButton.Add_Click({
    $folder = $textBox.Text.Trim()
    if (-not (Test-Path $folder)) {
        [System.Windows.Forms.MessageBox]::Show("Invalid folder path", "Error", 'OK', 'Error')
        return
    }
    $config['LastFolder'] = $folder
    Save-Ini
    $suppressBuilderPrompt = $false
    Generate-Achlist -baseFolder $folder
})

[void]$form.ShowDialog()
