param (
    [string]$InputFile
)

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

# Create form
$form = New-Object System.Windows.Forms.Form
$form.Text = "Sort .achlist JSON File"
$form.Size = New-Object System.Drawing.Size(500,150)
$form.StartPosition = "CenterScreen"
$form.AllowDrop = $true

# Label
$label = New-Object System.Windows.Forms.Label
$label.Text = "Drop an .achlist file here or click Browse..."
$label.Dock = "Top"
$label.TextAlign = "MiddleCenter"
$label.Height = 30
$form.Controls.Add($label)

# Browse button
$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = "Browse"
$browseButton.Dock = "Bottom"
$form.Controls.Add($browseButton)

# Drag-and-drop handler
$form.Add_DragEnter({
    if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
        $_.Effect = 'Copy'
    }
})
$form.Add_DragDrop({
    $droppedFile = $_.Data.GetData("FileDrop")[0]
    Process-File $droppedFile
    $form.Close()
})

# Browse click handler
$browseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "JSON files (*.achlist)|*.achlist"
    if ($dialog.ShowDialog() -eq "OK") {
        Process-File $dialog.FileName
        $form.Close()
    }
})

# Sorting logic
function Process-File($filePath) {
    try {
        $label.Text = "Sorting: $filePath"
        $data = Get-Content $filePath -Raw | ConvertFrom-Json
        $sorted = $data | Sort-Object { $_.ToLowerInvariant() }
        $sorted | ConvertTo-Json -Depth 1 | Set-Content $filePath -Encoding UTF8
        [System.Windows.Forms.MessageBox]::Show("Sorted file saved (overwritten):`n$filePath", "Done")
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Error processing file:`n$($_.Exception.Message)", "Error")
    }
}

# Auto-run if file was passed on command line
if ($InputFile -and (Test-Path $InputFile)) {
    Process-File $InputFile
    return
}

# Run GUI
[void]$form.ShowDialog()
