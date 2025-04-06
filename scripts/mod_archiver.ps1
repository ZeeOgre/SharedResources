#  gui interface that you can drag/drop an achlist or esm onto to produce a backup of all your source files
#  assumes achlist is named the same as your mod
#  requires a folder for your xbox files that replicates your data folder structure for relavant mods (i.e. exactly the same as archiver script)
#  basically pulls all the files from achlist + psc + the wav files for the esp from your folder structure, and consolidates
#  will make a dated zip of the folder if you want it to

[System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()

# Configuration File Path
$scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Definition)
$configPath = "$PSScriptRoot\$scriptName.ini"

Set-Location $PSScriptRoot

# Load Config if it exists
$config = @{}
if (Test-Path $configPath) {
    $config = Get-Content $configPath | ForEach-Object { $_ -replace '\\', '\\' } | ConvertFrom-StringData
}

# Create Form
$form = New-Object System.Windows.Forms.Form
$form.Text = "Mod Archiver"
$form.Size = New-Object System.Drawing.Size(600, 700)
$form.StartPosition = "CenterScreen"
$form.AllowDrop = $true

$form.Add_DragEnter({
    if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
        $_.Effect = 'Copy'
    }
})

$form.Add_DragDrop({
    $file = $_.Data.GetData([Windows.Forms.DataFormats]::FileDrop)[0]
    if ($file -match '\\([^\\]+)\.(achlist|esm|txt)$') {
        $inputBox.Text = $file
    }
})

# Input File
$inputLabel = New-Object System.Windows.Forms.Label
$inputLabel.Text = "Input File (.achlist or .esm):"
$inputLabel.Location = New-Object System.Drawing.Point(10, 10)
$inputLabel.AutoSize = $true
$form.Controls.Add($inputLabel)

$inputBox = New-Object System.Windows.Forms.TextBox
$inputBox.Location = New-Object System.Drawing.Point(200, 10)
$inputBox.Width = 300
$inputBox.Text = if ($config.ContainsKey('InputFile')) { $config.InputFile } else { '' }
$form.Controls.Add($inputBox)

$inputButton = New-Object System.Windows.Forms.Button
$inputButton.Text = "..."
$inputButton.Location = New-Object System.Drawing.Point(510, 10)
$inputButton.Add_Click({
    $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $fileDialog.Filter = "Mod input files (*.achlist;*.esm;*.txt)|*.achlist;*.esm;*.txt|All files (*.*)|*.*"
    if ($fileDialog.ShowDialog() -eq 'OK') {
        $inputBox.Text = $fileDialog.FileName
    }
})
$form.Controls.Add($inputButton)

# Backup Destination Folder
$destLabel = New-Object System.Windows.Forms.Label
$destLabel.Text = "Backup Destination Folder:"
$destLabel.Location = New-Object System.Drawing.Point(10, 50)
$destLabel.AutoSize = $true
$form.Controls.Add($destLabel)

$destBox = New-Object System.Windows.Forms.TextBox
$destBox.Location = New-Object System.Drawing.Point(200, 50)
$destBox.Width = 300
$destBox.Text = if ($config.ContainsKey('BackupFolder')) { $config.BackupFolder } else { '' }
$form.Controls.Add($destBox)

$destButton = New-Object System.Windows.Forms.Button
$destButton.Text = "..."
$destButton.Location = New-Object System.Drawing.Point(510, 50)
$destButton.Add_Click({
    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($folderDialog.ShowDialog() -eq 'OK') {
        $destBox.Text = $folderDialog.SelectedPath
    }
})
$form.Controls.Add($destButton)

# Game Data Folder
$dataLabel = New-Object System.Windows.Forms.Label
$dataLabel.Text = "Game Data Folder:"
$dataLabel.Location = New-Object System.Drawing.Point(10, 90)
$dataLabel.AutoSize = $true
$form.Controls.Add($dataLabel)

$dataBox = New-Object System.Windows.Forms.TextBox
$dataBox.Location = New-Object System.Drawing.Point(200, 90)
$dataBox.Width = 300
$dataBox.Text = if ($config.ContainsKey('DataFolder')) { $config.DataFolder } else { '' }
$form.Controls.Add($dataBox)

$dataButton = New-Object System.Windows.Forms.Button
$dataButton.Text = "..."
$dataButton.Location = New-Object System.Drawing.Point(510, 90)
$dataButton.Add_Click({
    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($folderDialog.ShowDialog() -eq 'OK') {
        $dataBox.Text = $folderDialog.SelectedPath
    }
})
$form.Controls.Add($dataButton)

# Xbox Data Folder
$xboxLabel = New-Object System.Windows.Forms.Label
$xboxLabel.Text = "Xbox Data Folder:"
$xboxLabel.Location = New-Object System.Drawing.Point(10, 130)
$xboxLabel.AutoSize = $true
$form.Controls.Add($xboxLabel)

$xboxBox = New-Object System.Windows.Forms.TextBox
$xboxBox.Location = New-Object System.Drawing.Point(200, 130)
$xboxBox.Width = 300
$xboxBox.Text = if ($config.ContainsKey('XboxFolder')) { $config.XboxFolder } else { '' }
$form.Controls.Add($xboxBox)

$xboxButton = New-Object System.Windows.Forms.Button
$xboxButton.Text = "..."
$xboxButton.Location = New-Object System.Drawing.Point(510, 130)
$xboxButton.Add_Click({
    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($folderDialog.ShowDialog() -eq 'OK') {
        $xboxBox.Text = $folderDialog.SelectedPath
    }
})
$form.Controls.Add($xboxButton)

# Copy Files Checkbox
$copyCheckbox = New-Object System.Windows.Forms.CheckBox
$copyCheckbox.Text = "Copy Files to Backup Structure"
$copyCheckbox.Checked = if ($config.ContainsKey('Copy')) { [bool]::Parse($config.Copy) } else { $false }
$copyCheckbox.Location = New-Object System.Drawing.Point(200, 170)
$copyCheckbox.AutoSize = $true
$form.Controls.Add($copyCheckbox)

# Create Zip Checkbox
$zipCheckbox = New-Object System.Windows.Forms.CheckBox
$zipCheckbox.Text = "Create Dated Zip"
$zipCheckbox.Checked = if ($config.ContainsKey('Zip')) { [bool]::Parse($config.Zip) } else { $false }
$zipCheckbox.Location = New-Object System.Drawing.Point(200, 200)
$zipCheckbox.AutoSize = $true
$form.Controls.Add($zipCheckbox)

# Progress Bar
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(10, 600)
$progressBar.Size = New-Object System.Drawing.Size(560, 20)
$form.Controls.Add($progressBar)

# Status Label
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = ""
$statusLabel.Location = New-Object System.Drawing.Point(10, 570)
$statusLabel.Size = New-Object System.Drawing.Size(560, 20)
$form.Controls.Add($statusLabel)

# Add Live LogBox UI above Run Button
$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$logBox.Location = New-Object System.Drawing.Point(10, 240)
$logBox.Size = New-Object System.Drawing.Size(560, 290)
$form.Controls.Add($logBox)

# Run Button
$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = "Run"
$runButton.Location = New-Object System.Drawing.Point(250, 540)
$form.Controls.Add($runButton)

$runButton.Add_Click({
    $enableLogging = $true
    $logLines = @()

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLines += "Log Start: $timestamp"
    $logLines += "----------------------------------------"

    $configOut = @()
    $configOut += "InputFile=$($inputBox.Text)"
    $configOut += "BackupFolder=$($destBox.Text)"
    $configOut += "DataFolder=$($dataBox.Text)"
    $configOut += "XboxFolder=$($xboxBox.Text)"
    $configOut += "Copy=$($copyCheckbox.Checked)"
    $configOut += "Zip=$($zipCheckbox.Checked)"
    $configOut | Set-Content -Path $configPath

    if (-not ($dataBox.Text -like "*\Data")) {
        [System.Windows.Forms.MessageBox]::Show("Game Data Folder must end with 'Data'", "Invalid Path", 'OK', 'Error')
        return
    }
    if (-not ($xboxBox.Text -like "*\Data")) {
        [System.Windows.Forms.MessageBox]::Show("Xbox Data Folder must end with 'Data'", "Invalid Path", 'OK', 'Error')
        return
    }

    $inputPath = $inputBox.Text
    $backupRoot = $destBox.Text
    $dataRoot = $dataBox.Text
    $xboxRoot = $xboxBox.Text
    $modName = [System.IO.Path]::GetFileNameWithoutExtension($inputPath)
    $achlistPath = Join-Path -Path $dataRoot -ChildPath "$modName.achlist"
    if (-not (Test-Path $achlistPath)) {
        [System.Windows.Forms.MessageBox]::Show("Achlist file not found at: $achlistPath", "Missing File", 'OK', 'Error')
        return
    }

    $logLines += "CHECK [DataRoot]: $dataRoot"
    $logLines += "CHECK [XboxRoot]: $xboxRoot"
    $logLines += "CHECK [BackupRoot]: $backupRoot"
    $logLines += "CHECK [Achlist]: $achlistPath"
    $logBox.Clear()
    $logBox.AppendText("CHECK [DataRoot]: $dataRoot`r`n")
    $logBox.AppendText("CHECK [XboxRoot]: $xboxRoot`r`n")
    $logBox.AppendText("CHECK [BackupRoot]: $backupRoot`r`n")
    $logBox.AppendText("CHECK [Achlist]: $achlistPath`r`n")

    # Collect and copy extra files (.esm, .esp, .ba2, .txt)
    $basePath = Split-Path $inputPath
    Get-ChildItem -Path $basePath -Filter "$modName*" | Where-Object {
        $_.Extension -in '.esm', '.esp', '.ba2', '.txt'
    } | ForEach-Object {
        $src = $_.FullName
        $dst = Join-Path "$backupRoot\$modName" $_.Name
        New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
        Copy-Item -Path $src -Destination $dst -Force
        $logLines += "COPY: $src => $dst"
        $logBox.AppendText("COPY: $src => $dst`r`n")
    }

    $jsonData = Get-Content $achlistPath | ConvertFrom-Json
    $voiceFolders = @()
    $total = $jsonData.Count
    $progressBar.Maximum = $total
    $count = 0

    foreach ($item in $jsonData) {
        $item = $item -replace '/', '\\'
        $relPath = $item -replace '^DATA\\', ''
        $srcPath = Join-Path -Path $dataRoot -ChildPath $relPath
        $dstPC = Join-Path -Path "$backupRoot\$modName\loose_pc" -ChildPath $relPath

        $logLines += "CHECK [Main Copy]: $srcPath"
        $logBox.AppendText("CHECK [Main Copy]: $srcPath`r`n")

        if (Test-Path $srcPath) {
            New-Item -ItemType Directory -Force -Path (Split-Path $dstPC) | Out-Null
            Copy-Item $srcPath -Destination $dstPC -Force
            $logLines += "COPY: $srcPath => $dstPC"
            $logBox.AppendText("COPY: $srcPath => $dstPC`r`n")
        }

        if ($relPath.ToLower().EndsWith('.dds')) {
            $dstXbox = Join-Path "$backupRoot\$modName\loose_xbox" $relPath
            $srcXbox = Join-Path $xboxRoot $relPath
            $logLines += "CHECK [Xbox DDS]: $srcXbox"
            $logBox.AppendText("CHECK [Xbox DDS]: $srcXbox`r`n")
            if (Test-Path $srcXbox) {
                New-Item -ItemType Directory -Force -Path (Split-Path $dstXbox) | Out-Null
                Copy-Item $srcXbox -Destination $dstXbox -Force
                $logLines += "COPY: $srcXbox => $dstXbox"
                $logBox.AppendText("COPY: $srcXbox => $dstXbox`r`n")
            }
        }

        if ($relPath.ToLower().EndsWith('.wem')) {
            $dstXbox = Join-Path "$backupRoot\$modName\loose_xbox" $relPath
            $srcXbox = Join-Path $xboxRoot $relPath
            $logLines += "CHECK [Xbox WEM]: $srcXbox"
            $logBox.AppendText("CHECK [Xbox WEM]: $srcXbox`r`n")
            if (Test-Path $srcXbox) {
                New-Item -ItemType Directory -Force -Path (Split-Path $dstXbox) | Out-Null
                Copy-Item $srcXbox -Destination $dstXbox -Force
                $logLines += "COPY: $srcXbox => $dstXbox"
                $logBox.AppendText("COPY: $srcXbox => $dstXbox`r`n")
            }
            $voiceMatch = $relPath -replace "Sound\\Voice\\$modName\.esm\\", ''
            $vf = $voiceMatch.Split('\\')[0]
            if ($vf -and $vf -notin $voiceFolders) {
                $voiceFolders += $vf
                $logLines += "TRACK [Voice Folder]: $vf"
                $logBox.AppendText("TRACK [Voice Folder]: $vf`r`n")
            }
        }

        if ($relPath.ToLower().EndsWith('.pex')) {
            $relSubPath = $relPath -replace '^Scripts\\', ''
            $pscRel = "Scripts\Source\" + $relSubPath.Replace('.pex', '.psc')
            $srcPSC = Join-Path $dataRoot $pscRel
            $dstPSC = Join-Path "$backupRoot\$modName\loose_pc" $pscRel
            $logLines += "CHECK [PSC Source]: $srcPSC"
            $logBox.AppendText("CHECK [PSC Source]: $srcPSC`r`n")
            if (Test-Path $srcPSC) {
                New-Item -ItemType Directory -Force -Path (Split-Path $dstPSC) | Out-Null
                Copy-Item -Path $srcPSC -Destination $dstPSC -Force
                $logLines += "COPY: $srcPSC => $dstPSC"
                $logBox.AppendText("COPY: $srcPSC => $dstPSC`r`n")
            }
        }

        $count++
        $progressBar.Value = $count
        $form.Refresh()
    }

    if ($voiceFolders.Count -gt 0) {
        foreach ($vf in $voiceFolders) {
            $srcFolder = Join-Path $dataRoot "Sound\Voice\$modName.esp\$vf"
            $dstFolder = Join-Path "$backupRoot\$modName\loose_pc\Sound\Voice\$modName.esp" $vf
            $logLines += "CHECK [ESP Voice Folder]: $srcFolder"
            $logBox.AppendText("CHECK [ESP Voice Folder]: $srcFolder`r`n")
            if (Test-Path $srcFolder) {
                Get-ChildItem -Path $srcFolder -Recurse | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
                    $rel = $_.FullName.Substring($srcFolder.Length).TrimStart('\\')
                    $dst = Join-Path $dstFolder $rel
                    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
                    Copy-Item -Path $_.FullName -Destination $dst -Force
                    $logLines += "COPY: $($_.FullName) => $dst"
                    $logBox.AppendText("COPY: $($_.FullName) => $dst`r`n")
                }
            }
        }
    }



    # ZIP logic (added just before final log write and message)
    if ($zipCheckbox.Checked) {
        $zipTime = Get-Date -Format "yyyyMMdd_HHmmss"
        $zipTarget = Join-Path -Path (Join-Path $destBox.Text $modName) -ChildPath "backup"
        if (-not (Test-Path $zipTarget)) {
            New-Item -ItemType Directory -Force -Path $zipTarget | Out-Null
        }
        $zipName = "$modName-$zipTime.zip"
        $zipPath = Join-Path $zipTarget $zipName
        $srcFolder = Join-Path $backupRoot $modName

        try {
            $itemsToZip = Get-ChildItem -Path $srcFolder -Recurse | Where-Object { $_.FullName -notlike "$zipTarget*" }
            $tempZipFolder = Join-Path $env:TEMP "mod_zip_temp_$modName"
            if (Test-Path $tempZipFolder) { Remove-Item $tempZipFolder -Recurse -Force }
            New-Item -ItemType Directory -Path $tempZipFolder | Out-Null

            foreach ($item in $itemsToZip) {
                $relativePath = $item.FullName.Substring($srcFolder.Length).TrimStart('\')
                $targetPath = Join-Path $tempZipFolder $relativePath
                New-Item -ItemType Directory -Force -Path (Split-Path $targetPath) | Out-Null
                Copy-Item $item.FullName -Destination $targetPath -Force
            }

            Compress-Archive -Path "$tempZipFolder\*" -DestinationPath $zipPath -Force
            Remove-Item $tempZipFolder -Recurse -Force

            $logLines += "ZIP: Created backup at $zipPath"
            $logBox.AppendText("ZIP: Created backup at $zipPath`r`n")
        } catch {
            $logLines += "ZIP ERROR: $_"
            $logBox.AppendText("ZIP ERROR: $_`r`n")
        }
    }
    $progressBar.Value = $progressBar.Maximum
    $logLines += "Log End: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $logBox.AppendText("Log End: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n")
    $logLines | Set-Content -Path (Join-Path $PSScriptRoot "mod_archiver_log.txt") -Force
    [System.Windows.Forms.MessageBox]::Show("Finished processing mod: $modName", "Done", "OK", "Information")
})

$form.ShowDialog()
