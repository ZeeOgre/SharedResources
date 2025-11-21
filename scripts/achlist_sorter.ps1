
param (
    [string]$InputFile
)

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = "Sort .achlist JSON File"
$form.Size = New-Object System.Drawing.Size(500,150)
$form.StartPosition = "CenterScreen"
$form.AllowDrop = $true

$label = New-Object System.Windows.Forms.Label
$label.Text = "Drop an .achlist file here or click Browse..."
$label.Dock = "Top"
$label.TextAlign = "MiddleCenter"
$label.Height = 30
$form.Controls.Add($label)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = "Browse"
$browseButton.Dock = "Bottom"
$form.Controls.Add($browseButton)

function Sort-AchlistFile {
    param([string]$filePath)

    if (-not (Test-Path $filePath)) {
        [System.Windows.Forms.MessageBox]::Show("File not found: $filePath") | Out-Null
        return
    }

    try {
        $jsonContent = Get-Content -Raw -Encoding UTF8 -Path $filePath | ConvertFrom-Json
        $sorted = $jsonContent | Sort-Object { $_.ToLowerInvariant() }
        $json = $sorted | ConvertTo-Json -Depth 1

        # Save back to file in UTF8 without BOM
        $utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($filePath, $json, $utf8NoBomEncoding)

        [System.Windows.Forms.MessageBox]::Show("Successfully sorted and saved.") | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to sort file: $_") | Out-Null
    }
}

$form.Add_DragDrop({
    $file = $_.Data.GetData([Windows.Forms.DataFormats]::FileDrop)[0]
    Sort-AchlistFile -filePath $file
})

$form.Add_DragEnter({
    if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
        $_.Effect = 'Copy'
    }
})

$browseButton.Add_Click({
    $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $fileDialog.Filter = "ACHList Files (*.achlist)|*.achlist"
    if ($fileDialog.ShowDialog() -eq "OK") {
        Sort-AchlistFile -filePath $fileDialog.FileName
    }
})

$form.ShowDialog()
