param(
    [string]$InputFile
)

[System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()

# --------------------------------
#  Config / INI handling
# --------------------------------
$scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Definition)
if (-not $scriptName) {
    # Fallback if running interactively
    $scriptName = "VoiceFolderSwitcher"
}

$configPath = Join-Path $PSScriptRoot "$scriptName.ini"

if ($PSScriptRoot -and (Test-Path $PSScriptRoot)) {
    Set-Location $PSScriptRoot
}

# Manual flat key=value parser (like your other tools)
$config = @{}
if (Test-Path $configPath) {
    Get-Content $configPath | ForEach-Object {
        if ($_ -match '^\s*([^=]+)=(.*)$') {
            $key = $matches[1].Trim()
            $val = $matches[2].Trim()
            $config[$key] = $val
        }
    }
}

# --------------------------------
#  Form & Controls
# --------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Voice Folder Switcher (ESP → ESM)"
$form.Size = New-Object System.Drawing.Size(650, 540)
$form.StartPosition = "CenterScreen"
$form.AllowDrop = $true

# Drag & drop support for input file
$form.Add_DragEnter({
    if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
        $_.Effect = 'Copy'
    }
})

$form.Add_DragDrop({
    $file = $_.Data.GetData([Windows.Forms.DataFormats]::FileDrop)[0]
    if ($file -match '\\([^\\]+)\.(esp|esm|ba2)$') {
        $inputBox.Text = $file
    }
})

# Input File
$inputLabel = New-Object System.Windows.Forms.Label
$inputLabel.Text = "Input File (.esp / .esm / .ba2):"
$inputLabel.Location = New-Object System.Drawing.Point(10, 10)
$inputLabel.AutoSize = $true
$form.Controls.Add($inputLabel)

$inputBox = New-Object System.Windows.Forms.TextBox
$inputBox.Location = New-Object System.Drawing.Point(200, 10)
$inputBox.Width = 340
if ($InputFile) {
    $inputBox.Text = $InputFile
} elseif ($config['InputFile']) {
    $inputBox.Text = $config['InputFile']
} else {
    $inputBox.Text = ''
}
$form.Controls.Add($inputBox)

$inputButton = New-Object System.Windows.Forms.Button
$inputButton.Text = "..."
$inputButton.Location = New-Object System.Drawing.Point(550, 10)
$inputButton.Add_Click({
    $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $fileDialog.Filter = "Mod Files (*.esp;*.esm;*.ba2)|*.esp;*.esm;*.ba2|All Files (*.*)|*.*"
    if ($fileDialog.ShowDialog() -eq 'OK') {
        $inputBox.Text = $fileDialog.FileName
    }
})
$form.Controls.Add($inputButton)

# Game Data Folder (PC)
$dataLabel = New-Object System.Windows.Forms.Label
$dataLabel.Text = "Game Data Folder:"
$dataLabel.Location = New-Object System.Drawing.Point(10, 50)
$dataLabel.AutoSize = $true
$form.Controls.Add($dataLabel)

$dataBox = New-Object System.Windows.Forms.TextBox
$dataBox.Location = New-Object System.Drawing.Point(200, 50)
$dataBox.Width = 340
$dataBox.Text = $config['DataFolder']
$form.Controls.Add($dataBox)

$dataButton = New-Object System.Windows.Forms.Button
$dataButton.Text = "..."
$dataButton.Location = New-Object System.Drawing.Point(550, 50)
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
$xboxLabel.Location = New-Object System.Drawing.Point(10, 90)
$xboxLabel.AutoSize = $true
$form.Controls.Add($xboxLabel)

$xboxBox = New-Object System.Windows.Forms.TextBox
$xboxBox.Location = New-Object System.Drawing.Point(200, 90)
$xboxBox.Width = 340
$xboxBox.Text = $config['XBoxDataPath']
$form.Controls.Add($xboxBox)

$xboxButton = New-Object System.Windows.Forms.Button
$xboxButton.Text = "..."
$xboxButton.Location = New-Object System.Drawing.Point(550, 90)
$xboxButton.Add_Click({
    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($folderDialog.ShowDialog() -eq 'OK') {
        $xboxBox.Text = $folderDialog.SelectedPath
    }
})
$form.Controls.Add($xboxButton)

# Log Box
$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = "Log:"
$logLabel.Location = New-Object System.Drawing.Point(10, 130)
$logLabel.AutoSize = $true
$form.Controls.Add($logLabel)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(10, 150)
$logBox.Width = 610
$logBox.Height = 280
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$form.Controls.Add($logBox)

# Rebuild achlist checkbox
$achlistCheck = New-Object System.Windows.Forms.CheckBox
$achlistCheck.Text = "Rebuild .achlist voice entries from ESM"
$achlistCheck.Location = New-Object System.Drawing.Point(10, 440)
$achlistCheck.AutoSize = $true
$achFlag = $false
if ($config['RebuildAchlist']) {
    $val = $config['RebuildAchlist'].Trim().ToLowerInvariant()
    if ($val -eq 'true' -or $val -eq '1' -or $val -eq 'yes') {
        $achFlag = $true
    }
}
$achlistCheck.Checked = $achFlag
$form.Controls.Add($achlistCheck)

# Run Button
$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = "Run Voice Folder Update"
$runButton.Location = New-Object System.Drawing.Point(10, 470)
$runButton.Width = 200
$form.Controls.Add($runButton)

# Close Button
$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = "Close"
$closeButton.Location = New-Object System.Drawing.Point(520, 470)
$closeButton.Width = 100
$closeButton.Add_Click({
    $form.Close()
})
$form.Controls.Add($closeButton)

# --------------------------------
#  Helper: Rebuild achlist
# --------------------------------
function Rebuild-AchlistFromEsmVoice {
    param(
        [string]$AchlistPath,
        [string]$DataRoot,
        [string]$ModName,
        [string]$PcEsmVoiceFolder,
        [System.Windows.Forms.TextBox]$LogBox
    )

    if (-not (Test-Path $AchlistPath)) {
        $LogBox.AppendText("achlist not found, skipping rebuild:`r`n  $AchlistPath`r`n")
        return
    }

    if (-not (Test-Path $PcEsmVoiceFolder)) {
        $LogBox.AppendText("PC ESM voice folder not found, skipping achlist rebuild:`r`n  $PcEsmVoiceFolder`r`n")
        return
    }

    try {
        $LogBox.AppendText("Rebuilding achlist for mod '$ModName'`r`n")
        $LogBox.AppendText("  achlist: $AchlistPath`r`n")
        $LogBox.AppendText("  source : $PcEsmVoiceFolder`r`n")

        # Backup original achlist (YYMMDDhhmm)
        $timestamp = Get-Date -Format "yyMMddHHmm"
        $backupPath = "$AchlistPath.$timestamp.bak"
        Copy-Item -Path $AchlistPath -Destination $backupPath -Force
        $LogBox.AppendText("Backup created:`r`n  $backupPath`r`n")

        # Load JSON
        $rawJson = Get-Content -Path $AchlistPath -Raw
        $assets = $null
        try {
            $assets = $rawJson | ConvertFrom-Json
        } catch {
            $LogBox.AppendText("ERROR: Failed to parse achlist as JSON. Skipping rebuild.`r`n  $($_.Exception.Message)`r`n")
            return
        }

        if (-not $assets) {
            $LogBox.AppendText("WARNING: achlist JSON is empty. Starting from empty list.`r`n")
            $assets = @()
        }

        # Remove existing Data\Sound\Voice\<modname>.esm entries
        $LogBox.AppendText("Removing existing 'Data\\Sound\\Voice\\$ModName.esm\\' entries from achlist...`r`n")

        $filteredAssets = @()
        foreach ($entry in $assets) {
            if ($entry -like "Data\Sound\Voice\$ModName.esm\*") {
                $LogBox.AppendText("  REMOVED: $entry`r`n")
            } else {
                $filteredAssets += $entry
            }
        }

        # Scan ESM voice folder for .wem and .ffxanim
        $LogBox.AppendText("Scanning ESM voice folder for .wem and .ffxanim...`r`n")
        $newAssets = @()

        if (-not ($DataRoot -like "*\")) {
            # ensure trailing backslash
            $DataRoot = $DataRoot.TrimEnd('\','/') + '\'
        }

        $files = Get-ChildItem -Path $PcEsmVoiceFolder -Recurse -File -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            $ext = $file.Extension.ToLowerInvariant()
            if ($ext -eq '.wem' -or $ext -eq '.ffxanim') {
                # Build achlist-style path: 'Data\...' relative to $DataRoot
                $fullPath = $file.FullName
                if ($fullPath.StartsWith($DataRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $relative = $fullPath.Substring($DataRoot.Length).TrimStart('\','/')
                    $relative = $relative.Replace('/', '\')
                    $achPath = "Data\" + $relative
                    $newAssets += $achPath
                    $LogBox.AppendText("  ADD: $achPath`r`n")
                } else {
                    $LogBox.AppendText("  WARNING: File not under Game Data root, skipping:`r`n    $fullPath`r`n")
                }
            }
        }

        $finalAssets = $filteredAssets + $newAssets

        # Write back to achlist as JSON
        $LogBox.AppendText("Writing updated achlist...`r`n")
        $jsonOut = $finalAssets | ConvertTo-Json -Depth 3
        $jsonOut | Set-Content -Path $AchlistPath -Encoding UTF8

        $LogBox.AppendText("achlist rebuild complete.`r`n")
    }
    catch {
        $LogBox.AppendText("ERROR during achlist rebuild: $($_.Exception.Message)`r`n")
    }
}

# --------------------------------
#  Core Logic
# --------------------------------
$runButton.Add_Click({
    $inputPath = $inputBox.Text.Trim()
    $dataRoot  = $dataBox.Text.Trim()
    $xboxRoot  = $xboxBox.Text.Trim()

    $logBox.Clear()

    if (-not (Test-Path $inputPath)) {
        [System.Windows.Forms.MessageBox]::Show("Input file not found:`r`n$inputPath", "Error", 'OK', 'Error') | Out-Null
        return
    }

    if (-not (Test-Path $dataRoot)) {
        [System.Windows.Forms.MessageBox]::Show("Game Data Folder does not exist:`r`n$dataRoot", "Error", 'OK', 'Error') | Out-Null
        return
    }

    if (-not (Test-Path $xboxRoot)) {
        [System.Windows.Forms.MessageBox]::Show("Xbox Data Folder does not exist:`r`n$xboxRoot", "Error", 'OK', 'Error') | Out-Null
        return
    }

    if (-not ($dataRoot -like "*\Data")) {
        [System.Windows.Forms.MessageBox]::Show("Game Data Folder must end with 'Data'", "Invalid Path", 'OK', 'Error') | Out-Null
        return
    }

    if (-not ($xboxRoot -like "*\Data")) {
        [System.Windows.Forms.MessageBox]::Show("Xbox Data Folder must end with 'Data'", "Invalid Path", 'OK', 'Error') | Out-Null
        return
    }

    $modName = [System.IO.Path]::GetFileNameWithoutExtension($inputPath)
    if ([string]::IsNullOrWhiteSpace($modName)) {
        [System.Windows.Forms.MessageBox]::Show("Unable to derive mod name from input file.", "Error", 'OK', 'Error') | Out-Null
        return
    }

    # Persist config (including checkbox state)
    $configData = @"
InputFile=$inputPath
DataFolder=$dataRoot
XBoxDataPath=$xboxRoot
LastModName=$modName
RebuildAchlist=$($achlistCheck.Checked)
"@
    $configData | Set-Content -Path $configPath -Encoding UTF8

    $logBox.AppendText("Using config file:`r`n  $configPath`r`n")
    $logBox.AppendText("Mod Name: $modName`r`n")
    $logBox.AppendText("Game Data Folder: $dataRoot`r`n")
    $logBox.AppendText("Xbox Data Folder: $xboxRoot`r`n")
    $logBox.AppendText("RebuildAchlist: $($achlistCheck.Checked)`r`n")
    $logBox.AppendText("=====================================`r`n")

    try {
        # 1) Delete Data\sound\voice\<modname>.esm if it exists
        $pcEsmVoiceFolder = Join-Path $dataRoot ("sound\voice\{0}.esm" -f $modName)
        if (Test-Path $pcEsmVoiceFolder) {
            $logBox.AppendText("Deleting existing PC ESM voice folder:`r`n  $pcEsmVoiceFolder`r`n")
            Remove-Item -Path $pcEsmVoiceFolder -Recurse -Force
        } else {
            $logBox.AppendText("No existing PC ESM voice folder found (OK):`r`n  $pcEsmVoiceFolder`r`n")
        }

        # 2) Copy Data\sound\voice\<modname>.esp -> <modname>.esm (preserving structure)
        $pcEspVoiceFolder = Join-Path $dataRoot ("sound\voice\{0}.esp" -f $modName)
        if (Test-Path $pcEspVoiceFolder) {
            $logBox.AppendText("Copying PC ESP voice folder:`r`n  $pcEspVoiceFolder`r`n  =>  $pcEsmVoiceFolder`r`n")
            New-Item -ItemType Directory -Force -Path (Split-Path $pcEsmVoiceFolder) | Out-Null
            Copy-Item -Path $pcEspVoiceFolder -Destination $pcEsmVoiceFolder -Recurse -Force
        } else {
            $logBox.AppendText("WARNING: PC ESP voice folder not found:`r`n  $pcEspVoiceFolder`r`n")
        }

        # 3) Delete .wav and .dat files from the <modname>.esm tree
        if (Test-Path $pcEsmVoiceFolder) {
            $logBox.AppendText("Removing .wav and .dat from PC ESM voice tree...`r`n")
            Get-ChildItem -Path $pcEsmVoiceFolder -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.wav', '.dat' } |
                ForEach-Object {
                    $logBox.AppendText("  DELETE: $($_.FullName)`r`n")
                    Remove-Item -Path $_.FullName -Force
                }
        } else {
            $logBox.AppendText("PC ESM voice folder does not exist after copy step; skipping .wav/.dat cleanup.`r`n")
        }

        $logBox.AppendText("=====================================`r`n")

        # 4 & 5) Xbox safety: only replace .esm if .esp exists
        $xboxEsmVoiceFolder = Join-Path $xboxRoot ("sound\voice\{0}.esm" -f $modName)
        $xboxEspVoiceFolder = Join-Path $xboxRoot ("sound\voice\{0}.esp" -f $modName)

        if (Test-Path $xboxEspVoiceFolder) {
            $logBox.AppendText("Xbox ESP found — proceeding with replacement:`r`n  $xboxEspVoiceFolder`r`n")

            if (Test-Path $xboxEsmVoiceFolder) {
                $logBox.AppendText("Deleting old Xbox ESM voice folder:`r`n  $xboxEsmVoiceFolder`r`n")
                Remove-Item -Path $xboxEsmVoiceFolder -Recurse -Force
            }

            $logBox.AppendText("Renaming Xbox ESP voice folder to ESM:`r`n  $xboxEspVoiceFolder`r`n")
            New-Item -ItemType Directory -Force -Path (Split-Path $xboxEsmVoiceFolder) | Out-Null
            Rename-Item -Path $xboxEspVoiceFolder -NewName ("{0}.esm" -f $modName)
            $logBox.AppendText("  =>  $xboxEsmVoiceFolder`r`n")
        }
        else {
            $logBox.AppendText("WARNING: Xbox ESP folder NOT found!`r`n")
            $logBox.AppendText("  Expected: $xboxEspVoiceFolder`r`n")
            $logBox.AppendText("  Xbox ESM tree will NOT be deleted or modified.`r`n")

            if (Test-Path $xboxEsmVoiceFolder) {
                $logBox.AppendText("  Existing Xbox ESM left untouched:`r`n    $xboxEsmVoiceFolder`r`n")
            } else {
                $logBox.AppendText("  No Xbox ESM exists either; nothing to change.`r`n")
            }
        }

        $logBox.AppendText("=====================================`r`n")

        # 6) Optional: rebuild achlist
        if ($achlistCheck.Checked) {
            $achlistPath = [System.IO.Path]::ChangeExtension($inputPath, ".achlist")
            $logBox.AppendText("Attempting achlist rebuild using:`r`n  $achlistPath`r`n")
            Rebuild-AchlistFromEsmVoice -AchlistPath $achlistPath -DataRoot $dataRoot -ModName $modName -PcEsmVoiceFolder $pcEsmVoiceFolder -LogBox $logBox
            $logBox.AppendText("=====================================`r`n")
        } else {
            $logBox.AppendText("achlist rebuild not selected; skipping.`r`n")
        }

        $logBox.AppendText("Done.`r`n")
    }
    catch {
        $logBox.AppendText("ERROR: $($_.Exception.Message)`r`n")
        [System.Windows.Forms.MessageBox]::Show("An error occurred: $($_.Exception.Message)", "Error", 'OK', 'Error') | Out-Null
    }
})

# Show the form
[void]$form.ShowDialog()
