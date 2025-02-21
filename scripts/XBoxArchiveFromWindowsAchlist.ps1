[System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()

# Configuration File Path
$configPath = "$PSScriptRoot\XBoxArchivesFromAchlist.ini"

# Load Config if it exists
$config = @{}
if (Test-Path $configPath) {
    $config = Get-Content $configPath | ForEach-Object { $_ -replace '\\', '\\' } | ConvertFrom-StringData
}

# Create Form
$form = New-Object System.Windows.Forms.Form
$form.Text = "Load XBox Archives from Windows Achlist"
$form.Size = New-Object System.Drawing.Size(600, 400)
$form.StartPosition = "CenterScreen"
$form.AllowDrop = $true

# Input File Label & Textbox
$inputLabel = New-Object System.Windows.Forms.Label
$inputLabel.Text = "Input File:"
$inputLabel.Location = New-Object System.Drawing.Point(10, 10)
$inputLabel.AutoSize = $true
$form.Controls.Add($inputLabel)

$inputBox = New-Object System.Windows.Forms.TextBox
$inputBox.Location = New-Object System.Drawing.Point(100, 10)
$inputBox.Width = 400
$inputBox.Text = $config.InputFile
$form.Controls.Add($inputBox)

# Archiver Path
$archiverLabel = New-Object System.Windows.Forms.Label
$archiverLabel.Text = "Archiver2.exe Path:"
$archiverLabel.Location = New-Object System.Drawing.Point(10, 40)
$archiverLabel.AutoSize = $true
$form.Controls.Add($archiverLabel)

$archiverBox = New-Object System.Windows.Forms.TextBox
$archiverBox.Location = New-Object System.Drawing.Point(150, 40)
$archiverBox.Width = 350
$archiverBox.Text = $config.ArchiverPath
$form.Controls.Add($archiverBox)

# Data Folder
$dataFolderLabel = New-Object System.Windows.Forms.Label
$dataFolderLabel.Text = "Data Folder:"
$dataFolderLabel.Location = New-Object System.Drawing.Point(10, 70)
$dataFolderLabel.AutoSize = $true
$form.Controls.Add($dataFolderLabel)

$dataFolderBox = New-Object System.Windows.Forms.TextBox
$dataFolderBox.Location = New-Object System.Drawing.Point(100, 70)
$dataFolderBox.Width = 300
$dataFolderBox.Text = $config.DataFolder
$form.Controls.Add($dataFolderBox)

$dataFolderButton = New-Object System.Windows.Forms.Button
$dataFolderButton.Text = "..."
$dataFolderButton.Location = New-Object System.Drawing.Point(410, 70)
$dataFolderButton.Add_Click({
    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($folderDialog.ShowDialog() -eq 'OK') {
        $dataFolderBox.Text = $folderDialog.SelectedPath
    }
})
$form.Controls.Add($dataFolderButton)

# XBox Data Folder
$xboxDataLabel = New-Object System.Windows.Forms.Label
$xboxDataLabel.Text = "XBox Data Path:"
$xboxDataLabel.Location = New-Object System.Drawing.Point(10, 100)
$xboxDataLabel.AutoSize = $true
$form.Controls.Add($xboxDataLabel)

$xboxDataBox = New-Object System.Windows.Forms.TextBox
$xboxDataBox.Location = New-Object System.Drawing.Point(130, 100)
$xboxDataBox.Width = 270
$xboxDataBox.Text = $config.XBoxDataPath
$form.Controls.Add($xboxDataBox)

$xboxDataButton = New-Object System.Windows.Forms.Button
$xboxDataButton.Text = "..."
$xboxDataButton.Location = New-Object System.Drawing.Point(410, 100)
$xboxDataButton.Add_Click({
    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($folderDialog.ShowDialog() -eq 'OK') {
        $xboxDataBox.Text = $folderDialog.SelectedPath
    }
})
$form.Controls.Add($xboxDataButton)

# Process Button
$processButton = New-Object System.Windows.Forms.Button
$processButton.Text = "Process"
$processButton.Location = New-Object System.Drawing.Point(250, 140)
$processButton.Add_Click({
    # Save configuration for reuse
    $configData = @"
InputFile=$($inputBox.Text)
ArchiverPath=$($archiverBox.Text)
DataFolder=$($dataFolderBox.Text)
XBoxDataPath=$($xboxDataBox.Text)
"@
    $configData | Set-Content $configPath
    $inputFile = $inputBox.Text
    $archiverPath = $archiverBox.Text
    $dataFolder = $dataFolderBox.Text
    $xboxDataPath = $xboxDataBox.Text
    
    if (!(Test-Path $inputFile)) {
        [System.Windows.Forms.MessageBox]::Show("Input file not found.", "Error", "OK", "Error")
        return
    }
    
    $jsonData = Get-Content $inputFile | ConvertFrom-Json
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputFile)
    
    $achlistFile = "$dataFolder\$baseName`_xboxMain.txt"
    $textureFile = "$dataFolder\$baseName`_xboxTextures.txt"
    $soundFile = "$dataFolder\$baseName`_xboxSounds.txt"
    $achlistContent = @()
    $textureContent = @()
    
    foreach ($item in $jsonData) {
        $item = $item -replace '/', '\'  # Ensure all paths use backslashes
    
        if ($item -match '^Data\\Sound.*\.wem$') {
            $soundContent += ($item -replace '^Data\\Sound', "$xboxDataPath\Data\Sound") + "`r`n"
        } elseif ($item -match '^DATA\\Textures') {
            $textureContent += ($item -replace '^DATA\\Textures', "$xboxDataPath\Data\Textures") -replace '"', ''
        } else {
            $achlistContent += $item -replace '^Data', "$dataFolder"
        }
    }
    if ($soundContent) {
        # Trim only trailing whitespace and newline characters
        $soundContent = $soundContent.TrimEnd("`r", "`n")
    
        # Write to file as ASCII using Set-Content (while ensuring no extra newline)
        $soundContent -split "`r`n" | Set-Content -Path $soundFile -Encoding ASCII
    } else {
        Write-Host "Warning: No valid sound entries found. File will not be created."
    }
    
    # Keep these lines unchanged to maintain consistency
    $achlistContent | Set-Content -Path $achlistFile -Encoding ASCII
    $textureContent | Set-Content -Path $textureFile -Encoding ASCII
    
    
    $achlistContent | Set-Content -Path $achlistFile -Encoding ASCII
    $textureContent | Set-Content -Path $textureFile -Encoding ASCII
    
    
    $mainba2File = "$dataFolder\$baseName - Main_xbox.ba2"
    $textureba2File = "$dataFolder\$baseName - Textures_xbox.ba2"
    $voicesba2File = "$dataFolder\$baseName - Sound_xbox.ba2"

    $textureCommand = "& '$archiverPath' -create='$textureba2File' -sourceFile='$textureFile' -format=XBoxDDS -compression=XBox"
    $mainCommand = "& '$archiverPath' -create='$mainba2File' -sourceFile='$achlistFile' -format=General -compression=Default"
    $soundCommand = "& '$archiverPath' -create='$voicesba2File' -sourceFile='$soundFile' -format=General -compression=None"  # No compression
    
    Invoke-Expression $mainCommand
    Write-Host $mainCommand
    
    Invoke-Expression $soundCommand
    Write-Host $soundCommand

    Invoke-Expression $textureCommand
    Write-Host $textureCommand
    
    Invoke-Expression $mainCommand
    Invoke-Expression $textureCommand
    Invoke-Expression "& '$archiverPath'  '$mainba2File' -format=General -compression=None"

    &explorer.exe "$xboxDataPath\Data\Sound\Voice"
    

    #[System.Windows.Forms.MessageBox]::Show("Processing Complete!", "Success", "OK", "Information")
})
$form.Controls.Add($processButton)

# Drag and Drop Functionality
$form.Add_DragEnter({
    param($sender, $e)
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    }
})

$form.Add_DragDrop({
    param($sender, $e)
    $files = $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop, $true)
    if ($files.Count -gt 0) {
        $inputBox.Text = $files[0]
    }
})

# Show Form
$form.ShowDialog()
