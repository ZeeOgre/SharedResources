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

function Save-Ini {
    $lines = @()
    foreach ($key in $config.Keys) {
        $lines += "$key=$($config[$key])"
    }
    $lines | Set-Content -Path $iniPath -Encoding UTF8
}

function Generate-Achlist {
    param ($baseFolder)

    $dataRoot = if (Test-Path (Join-Path $baseFolder 'Data')) {
        Join-Path $baseFolder 'Data'
    } else {
        $baseFolder
    }

    if (-not (Test-Path $dataRoot)) {
        [System.Windows.Forms.MessageBox]::Show("No valid Data folder found.", "Error", 'OK', 'Error')
        return
    }

    $files = Get-ChildItem -Path $dataRoot -Recurse -File | ForEach-Object {
        $_.FullName.Substring($dataRoot.Length + 1).Replace('/', '\').Replace('\\', '\')
    }

    if (-not $files.Count) {
        [System.Windows.Forms.MessageBox]::Show("No files found under Data folder.", "Error", 'OK', 'Error')
        return
    }

    $modName = Split-Path $baseFolder -Leaf
    $achlistPath = Join-Path (Split-Path $dataRoot -Parent) "$modName.achlist"


    $lines = @("[")
    for ($i = 0; $i -lt $files.Count; $i++) {
        $escapedPath = 'Data\\' + ($files[$i] -replace '\\', '\\')
        $comma = if ($i -lt $files.Count - 1) { "," } else { "" }
        $lines += "`"$escapedPath`"$comma"
    }
    $lines += "]"

    # Validate JSON format
    $testJson = $lines -join "`n"
    try {
        $null = $testJson | ConvertFrom-Json -ErrorAction Stop
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Generated .achlist failed JSON validation:`n$($_.Exception.Message)", "JSON Error", 'OK', 'Error')
        return
    }

    # Write file just above Data folder
    $achlistPath = Join-Path (Split-Path $dataRoot -Parent) "$modName.achlist"
    $lines | Set-Content -Path $achlistPath -Encoding UTF8

    [System.Windows.Forms.MessageBox]::Show("Achlist created at:`n$achlistPath", "Success", 'OK', 'Information')

    
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
    if ($drop.Length -gt 0 -and (Test-Path $drop[0])) {
        $textBox.Text = $drop[0]
    }
})

$goButton.Add_Click({
    $folder = $textBox.Text.Trim()
    if (-not (Test-Path $folder)) {
        [System.Windows.Forms.MessageBox]::Show("Invalid folder path", "Error", 'OK', 'Error')
        return
    }
    $config['LastFolder'] = $folder
    Save-Ini
    Generate-Achlist -baseFolder $folder
})

[void]$form.ShowDialog()
