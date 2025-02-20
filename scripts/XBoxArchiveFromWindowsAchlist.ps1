[System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()

# Configuration File Path
$configPath = "$PSScriptRoot\config.ini"

# Load Config if it exists
$config = @{}
if (Test-Path $configPath) {
    $config = Get-Content $configPath | ConvertFrom-StringData
}

# Create Form
$form = New-Object System.Windows.Forms.Form
$form.Text = "XBox Archives from Windows Achlist"
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
$archiverLabel.Text = "Archive2.exe Path:"
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
    
    $achlistFile = "$dataFolder\$baseName`_xbox.achlist"
    $textureFile = "$dataFolder\$baseName`_xboxtextures.txt"
    
    $achlistContent = @()
    $textureContent = @()
    
    foreach ($item in $jsonData) {
        if ($item -match '^Data\\Sound') {
            $achlistContent += $item -replace '^Data\\Sound', "$xboxDataPath\Data\Sound"
        } elseif ($item -match '^DATA\\Textures') {
            $textureContent += $item -replace '^DATA\\Textures', "$xboxDataPath\Data\Textures" -replace '"', ''
        } else {
            $achlistContent += $item
        }
    }
    
    $achlistContent | Set-Content $achlistFile
    $textureContent | Set-Content $textureFile
    
    $achlistBa2File = "$dataFolder\$baseName - Main_xbox.ba2"
    $achlistCommand = "& '$archiverPath' -c='$achlistBa2File' -s='$achlistFile' -format=General -compression=Xbox"
    Invoke-Expression $achlistCommand

    $textureBa2File = "$dataFolder\$baseName - Textures_xbox.ba2"
    $textureCommand = "& '$archiverPath' -c='$textureBa2File' -s='$textureFile' -format=XBoxDDS -compression=XBox"
    Invoke-Expression $textureCommand
    
    [System.Windows.Forms.MessageBox]::Show("Processing Complete!", "Success", "OK", "Information")
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
