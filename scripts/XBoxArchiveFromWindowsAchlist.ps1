[System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()

# Configuration File Path
$configPath = "$PSScriptRoot\XBoxArchivesFromAchlist.ini"
Set-Location $PSScriptRoot

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

# Panel for checkboxes
$checkboxPanel = New-Object System.Windows.Forms.Panel
$checkboxPanel.Location = New-Object System.Drawing.Point(120, 140)
$checkboxPanel.Size = New-Object System.Drawing.Size(300, 30)
$form.Controls.Add($checkboxPanel)

# Checkboxes for Archive Selection
$xboxArchiveCheckbox = New-Object System.Windows.Forms.CheckBox
$xboxArchiveCheckbox.Text = "XBox Archive"
$xboxArchiveCheckbox.Location = New-Object System.Drawing.Point(10, 10)
$xboxArchiveCheckbox.Checked = if ($config.ContainsKey('XboxArchive')) { [bool]$config.XboxArchive } else { $true }
$checkboxPanel.Controls.Add($xboxArchiveCheckbox)

$windowsArchiveCheckbox = New-Object System.Windows.Forms.CheckBox
$windowsArchiveCheckbox.Text = "Windows Archive"
$windowsArchiveCheckbox.Location = New-Object System.Drawing.Point(120, 10)
$windowsArchiveCheckbox.Checked = if ($config.ContainsKey('WindowsArchive')) { [bool]$config.WindowsArchive } else { $true }
$checkboxPanel.Controls.Add($windowsArchiveCheckbox)

# Process Button
$processButton = New-Object System.Windows.Forms.Button
$processButton.Text = "Process"
$processButton.Location = New-Object System.Drawing.Point(250, 180)
$form.Controls.Add($processButton)

$processButton.Add_Click({
    # Save configuration for reuse
    $configData = @"
InputFile=$($inputBox.Text)
ArchiverPath=$($archiverBox.Text)
DataFolder=$($dataFolderBox.Text)
XBoxDataPath=$($xboxDataBox.Text)
XboxArchive=$($xboxArchiveCheckbox.Checked)
WindowsArchive=$($windowsArchiveCheckbox.Checked)
"@
    $configData | Set-Content $configPath
    $inputFile = $inputBox.Text
    $archiverPath = $archiverBox.Text
    $dataFolder = $dataFolderBox.Text
    $xboxDataPath = $xboxDataBox.Text
    
    # Preserve logic from existing script, ensuring archive checkboxes apply

    # Ensure inputFile is properly assigned before use
    Write-Host "Input File Path: $inputFile" # Debugging output to confirm file path
    $inputFile = $inputBox.Text
    $archiverPath = $archiverBox.Text

    if ([string]::IsNullOrWhiteSpace($inputFile) -or !(Test-Path $inputFile)) {
        [System.Windows.Forms.MessageBox]::Show("Input file not found.", "Error", "OK", "Error")
        return
    }
    
    if ([string]::IsNullOrWhiteSpace($archiverPath) -or !(Test-Path $archiverPath)) {
        [System.Windows.Forms.MessageBox]::Show("Archiver path is invalid or not set.", "Error", "OK", "Error")
        return
    }

    if ([string]::IsNullOrWhiteSpace($inputFile) -or !(Test-Path $inputFile)) {
        [System.Windows.Forms.MessageBox]::Show("Input file not found.", "Error", "OK", "Error")
        return
    }
    
    $jsonData = Get-Content $inputFile | ConvertFrom-Json
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputFile)
    
    $xboxMainFile = "$dataFolder\$baseName`_xboxMain.txt"
    $xboxTextureFile = "$dataFolder\$baseName`_xboxTextures.txt"
    $windowsMainFile = "$dataFolder\$baseName`_windowsMain.txt"
    $windowsTextureFile = "$dataFolder\$baseName`_windowsTextures.txt"
    
    $xboxMainContent = @()
$xboxTextureContent = @()
$windowsMainContent = @()
$windowsTextureContent = @()

$hasWemFiles = $false
$hasTextureFiles = $false

foreach ($item in $jsonData) {
    $item = $item -replace '/', '\\'  # Ensure all paths use backslashes
    if ($item -match '^DATA\\Textures') {
        $xboxTextureContent += $item -replace '^DATA\\Textures', "$xboxDataPath\\Data\\Textures"
        $windowsTextureContent += $item
        $hasTextureFiles = $true
    } elseif ($item -match '^DATA\\Sound.*\.wem$') {
        $xboxMainContent += $item -replace '^DATA\\Sound', "$xboxDataPath\\Data\\Sound"
        $windowsMainContent += $item
        $hasWemFiles = $true
    } else {
        $xboxMainContent += $item -replace '^Data', "$dataFolder"
        $windowsMainContent += $item
    }
}

    $xboxMainContent | Set-Content -Path $xboxMainFile -Encoding ASCII
    $windowsMainContent | Set-Content -Path $windowsMainFile -Encoding ASCII

if ($hasTextureFiles) {
    $xboxTextureContent | Set-Content -Path $xboxTextureFile -Encoding ASCII
    $windowsTextureContent | Set-Content -Path $windowsTextureFile -Encoding ASCII
}

Write-Host "Windows and Xbox archive lists written successfully."

$compressionType = if ($hasWemFiles) { "None" } else { "Default" }

if ($xboxArchiveCheckbox.Checked) {
    Invoke-Expression "& '$archiverPath' -create='$dataFolder\$baseName - Main_xbox.ba2' -sourceFile='$dataFolder\$baseName`_xboxMain.txt' -format=General -compression=$compressionType"

    if ($hasTextureFiles) {
        Invoke-Expression "& '$archiverPath' -create='$dataFolder\$baseName - Textures_xbox.ba2' -sourceFile='$dataFolder\$baseName`_xboxTextures.txt' -format=XBoxDDS -compression=XBox"
    }
}

if ($windowsArchiveCheckbox.Checked) {
    Invoke-Expression "& '$archiverPath' -create='$dataFolder\$baseName - Main.ba2' -sourceFile='$dataFolder\$baseName`_windowsMain.txt' -format=General -compression=$compressionType"

    if ($hasTextureFiles) {
        Invoke-Expression "& '$archiverPath' -create='$dataFolder\$baseName - Textures.ba2' -sourceFile='$dataFolder\$baseName`_windowsTextures.txt' -format=DDS -compression=Default"
    }
}

    
    Write-Host "Processing completed for both Xbox and Windows archives."
    [System.Windows.Forms.Application]::Exit()
})

# Show Form
$form.ShowDialog()
