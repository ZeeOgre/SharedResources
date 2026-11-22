# ZeeVA_TextOnly.ps1
# Run with:
# powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "C:\Scripts\ZeeVA_TextOnly.ps1"

param(
    [string]$AudacityPath = '',
    [string]$DialoguePath = ''
)

$TextSourceOnly = $true

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('ZeeVA.ControlForm' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace ZeeVA {
    public class ScriptForm : Form {
        protected override bool ShowWithoutActivation { get { return true; } }
    }

    public class ControlForm : Form {
        [DllImport("user32.dll")]
        static extern bool RegisterHotKey(IntPtr h, int id, uint modifiers, uint key);
        [DllImport("user32.dll")]
        static extern bool UnregisterHotKey(IntPtr h, int id);
        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr h);

        public readonly Queue<int> Actions = new Queue<int>();
        public readonly List<int> FailedKeys = new List<int>();
        readonly List<int> registeredKeys = new List<int>();

        public void RegisterKey(int id, uint modifiers, uint key) {
            if (RegisterHotKey(Handle, id, modifiers, key))
                registeredKeys.Add(id);
            else
                FailedKeys.Add(id);
        }

        protected override void WndProc(ref Message m) {
            if (m.Msg == 0x0312) Actions.Enqueue(m.WParam.ToInt32());
            base.WndProc(ref m);
        }

        protected override void OnFormClosed(FormClosedEventArgs e) {
            foreach (int id in registeredKeys) UnregisterHotKey(Handle, id);
            base.OnFormClosed(e);
        }
    }
}
'@
}

# Audacity's scripting commands (Select:, SelectTracks:) reject Track and
# TrackCount values above 100, so only tracks 0-100 of a project can be
# addressed over the script pipe. Sources, takes and bookkeeping tracks all
# count, so large speaker folders are recorded in blocks of files.
$script:AudacityMaxTrackIndex = 100
$script:AudacityTrackWarnThreshold = 90
$script:SpeakerBlockSize = 40

$script:State = @{
    Files                = @()
    Index                = 0
    Originals            = @{}
    Recorded             = @{}
    Accepted             = @{}
    Exported             = @{}
    Candidate            = $null
    Candidates           = @{}
    Recording            = $false
    RecordingTargetName  = $null
    RecordingStart       = 0.0
    RecordingCommandsVerified = $false
    Source               = ''
    OutputRoot           = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'ZeeVA_Output'
    Busy                 = $false
    AudacityPath         = $AudacityPath
    AudacityProcess      = $null
    AudacityProcessId    = 0
    AudacityWindowHandle = [IntPtr]::Zero
    Connected            = $false
    ConnectionState      = 'Starting'
    ConnectionError      = ''
    SessionVerified      = $true
    InterruptedRecording = $false
    LastProcessCheck     = [DateTime]::MinValue
    ProjectPath          = ''
    LastProject          = ''
    LastSource           = ''
    SessionDirty         = $false
    DialogueExportPath   = ''
    TextSourceOnly       = [bool]$TextSourceOnly
    VoiceType            = ''
    DialogueByFile       = @{}
    ProjectProgress      = ''
}

$script:ConfigPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ZeeVA\settings.json'
$script:IniPath = Join-Path $PSScriptRoot $(if ($TextSourceOnly) { 'ZeeVA_TextOnly.ini' } else { 'ZeeVA.ini' })
$script:SessionTrackPrefix = 'ZeeVA Session|'
$script:InstanceMutex = $null
$script:OwnsInstanceMutex = $false
$script:DialogueRows = @()
$script:DialogueIndexedRows = $null
$script:DialogueIndex = @{}
$script:ScriptWindow = $null
$script:ScriptColumns = @()

function Import-DialogueExport {
    param([string]$Path)

    $rows = @(Import-Csv -LiteralPath $Path -Delimiter "`t" -Encoding UTF8 -ErrorAction Stop)
    if ($rows.Count -eq 0 -or
        -not $rows[0].PSObject.Properties['FILENAME'] -or
        -not $rows[0].PSObject.Properties['RESPONSE TEXT']) {
        throw 'The dialogue export must contain FILENAME and RESPONSE TEXT columns.'
    }
    $rows
}

function Resolve-DialogueExportPath {
    param([string]$Path)

    if (-not $Path) { return '' }
    $directory = Split-Path ([IO.Path]::GetFullPath($Path)) -Parent
    $extension = [IO.Path]::GetExtension($Path)
    $stem = [IO.Path]::GetFileNameWithoutExtension($Path) -replace '_filtered$', ''
    $candidates = if ($extension -in @('.txt', '.tsv')) {
        @(
            (Join-Path $directory ($stem + '_filtered.txt'))
            (Join-Path $directory ($stem + '_filtered.tsv'))
            (Join-Path $directory ($stem + $extension))
            (Join-Path $directory ($stem + '.txt'))
            (Join-Path $directory ($stem + '.tsv'))
        )
    } else { @($Path) }
    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return ''
}

function Get-SessionVoiceType {
    if ($script:State.TextSourceOnly) { return $script:State.VoiceType }
    Split-Path $script:State.Source -Leaf
}

function Get-TextDialogueData {
    param([string]$Path, [object[]]$Rows, [string]$VoiceType)

    if (-not $Rows.Count -or -not $Rows[0].PSObject.Properties['VOICE TYPE'] -or
        -not $Rows[0].PSObject.Properties['FILENAME'] -or
        -not $Rows[0].PSObject.Properties['RESPONSE TEXT']) {
        throw 'A text-only script must contain VOICE TYPE, FILENAME and RESPONSE TEXT columns.'
    }
    if ([string]::IsNullOrWhiteSpace($VoiceType) -or
        $VoiceType.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
        $VoiceType -match '[. ]$|^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
        throw 'The selected voice type is not a valid output folder name.'
    }
    $sourceFolder = Join-Path (Split-Path ([IO.Path]::GetFullPath($Path)) -Parent) $VoiceType
    $byFile = @{}
    $files = @(
        foreach ($row in $Rows) {
            if ($row.'VOICE TYPE' -ine $VoiceType) { continue }
            $baseName = [IO.Path]::GetFileNameWithoutExtension([string]$row.FILENAME)
            if ([string]::IsNullOrWhiteSpace($baseName) -or
                $baseName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
                $baseName -match '[. ]$|^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
                throw "Invalid recording filename for voice type ${VoiceType}: $($row.FILENAME)"
            }
            $name = $baseName + '.wav'
            if ($byFile.ContainsKey($name)) {
                throw "Duplicate output filename for voice type ${VoiceType}: $name"
            }
            $byFile[$name] = $row
            [IO.FileInfo]::new((Join-Path $sourceFolder $name))
        }
    )
    if (-not $files.Count) { throw "The dialogue export contains no rows for voice type $VoiceType." }
    [pscustomobject]@{Source=$sourceFolder; Files=$files; ByFile=$byFile}
}

function Get-TextVoiceTypeFromFile {
    param([string]$Path, [string[]]$VoiceTypes)

    $stem = [IO.Path]::GetFileNameWithoutExtension($Path)
    $matching = @($VoiceTypes | Where-Object {
        $stem -match ('(?<![A-Za-z0-9])' + [regex]::Escape($_) + '(?![A-Za-z0-9])')
    })
    if ($matching.Count -eq 1) { return $matching[0] }
    return ''
}

function Select-TextVoiceType {
    param([object[]]$Rows, [string]$Path = '')

    $voices = @($Rows | ForEach-Object { [string]$_.'VOICE TYPE' } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if (-not $voices.Count) { throw 'The dialogue export contains no voice types.' }
    $filenameVoice = Get-TextVoiceTypeFromFile -Path $Path -VoiceTypes $voices
    if ($filenameVoice) { return $filenameVoice }
    if ($voices.Count -eq 1) { return $voices[0] }
    $dialog = [Windows.Forms.Form]::new()
    try {
        $dialog.Text = 'Choose the voice type for this session'
        $dialog.ClientSize = [Drawing.Size]::new(480, 112)
        $dialog.StartPosition = 'CenterParent'
        $dialog.FormBorderStyle = 'FixedDialog'
        $dialog.MinimizeBox = $false
        $dialog.MaximizeBox = $false
        $combo = [Windows.Forms.ComboBox]::new()
        $combo.DropDownStyle = 'DropDownList'
        $combo.SetBounds(16, 16, 448, 24)
        foreach ($voice in $voices) { $null = $combo.Items.Add($voice) }
        $combo.SelectedIndex = 0
        $dialog.Controls.Add($combo)
        $ok = [Windows.Forms.Button]::new()
        $ok.Text = 'Use Voice Type'
        $ok.SetBounds(224, 64, 128, 30)
        $ok.DialogResult = 'OK'
        $dialog.Controls.Add($ok)
        $dialog.AcceptButton = $ok
        $cancel = [Windows.Forms.Button]::new()
        $cancel.Text = 'Cancel'
        $cancel.SetBounds(360, 64, 104, 30)
        $cancel.DialogResult = 'Cancel'
        $dialog.Controls.Add($cancel)
        $dialog.CancelButton = $cancel
        if ($dialog.ShowDialog($script:Form) -eq 'OK') { return [string]$combo.SelectedItem }
        return ''
    }
    finally { $dialog.Dispose() }
}

function Open-TextDialogue {
    param([string]$Path = '')

    if ($script:State.Recording) { throw 'Stop recording before opening another script.' }
    if (-not $script:State.Connected -or -not $script:State.SessionVerified) {
        throw 'Reconnect and verify the current Audacity session before opening another script.'
    }
    [object[]]$tracks = (Invoke-Audacity 'GetInfo: Type=Tracks Format=JSON') | ConvertFrom-Json
    if ($tracks.Count -and -not $script:State.Files.Count) {
        throw 'Start with one empty Audacity project open, or use Scan Project to resume it.'
    }
    $initialDirectory = if ($Path) {
        Split-Path ([IO.Path]::GetFullPath($Path)) -Parent
    } elseif ($script:State.DialogueExportPath) {
        Split-Path $script:State.DialogueExportPath -Parent
    } else { '' }
    $Path = Resolve-DialogueExportPath $Path
    if (-not $Path) {
        $Path = Select-DialogueExportFile -InitialDirectory $initialDirectory -VoiceType 'Starfield script'
    }
    if (-not $Path) { return }
    $Path = Resolve-DialogueExportPath $Path
    if (-not $Path) { throw 'The selected dialogue export no longer exists.' }
    $Path = (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName
    $rows = @(Import-DialogueExport $Path)
    $voice = Select-TextVoiceType -Rows $rows -Path $Path
    if (-not $voice) { return }
    $data = Get-TextDialogueData -Path $Path -Rows $rows -VoiceType $voice
    $files = @($data.Files)
    $projectStem = [IO.Path]::GetFileNameWithoutExtension($Path) + '_' + $voice
    $projectPath = Join-Path (Split-Path $Path -Parent) ($projectStem + '.aup3')
    if ($files.Count -gt $script:SpeakerBlockSize) {
        $blocks = @(Get-SpeakerFileBlocks -Files $files)
        $blockFolder = Join-Path (Split-Path $Path -Parent) $projectStem
        $blockNumber = Choose-SpeakerBlock -Folder $blockFolder -Blocks $blocks -TotalFiles $files.Count
        if (-not $blockNumber) { return }
        $files = @($blocks[$blockNumber - 1].Files)
        $projectPath = Get-SpeakerBlockProjectPath -Folder $blockFolder -Block $blockNumber
    }
    if ($script:State.ProjectPath -and
        [IO.Path]::GetFullPath($projectPath) -ieq [IO.Path]::GetFullPath($script:State.ProjectPath)) {
        Show-ScriptWindow
        Set-StatusMessage 'This recording block is already open.'
        return
    }
    $overwrite = $false
    $resume = $false
    if (Test-Path -LiteralPath $projectPath) {
        switch (Get-ExistingProjectAction -Path $projectPath) {
            'Resume' { $resume = $true }
            'Overwrite' { $overwrite = $true }
            default { return }
        }
    }
    if ($script:State.Files.Count) { Close-TextProject }
    if ($resume) { Open-ZeeVAProject -Path $projectPath; Show-ScriptWindow; return }
    $script:State.Source = $data.Source
    $script:State.Files = $files
    $script:State.Index = 0
    $script:State.VoiceType = $voice
    $script:State.DialogueByFile = $data.ByFile
    $script:State.DialogueExportPath = $Path
    $script:State.LastSource = $data.Source
    $script:State.Originals = @{}
    $script:State.SessionDirty = $true
    $script:DialogueRows = $rows
    Update-Display
    Show-ScriptWindow
    Save-ProjectBookkeeping
    Save-ZeeVAProject -Path $projectPath -Overwrite:$overwrite -BookkeepingPrepared
    Set-StatusMessage ("Loaded {0} lines for {1}. No source WAVs required." -f $files.Count, $voice)
}

function Close-TextProject {
    if ($script:State.Recording -or -not $script:State.Connected -or
        -not $script:State.SessionVerified) {
        throw 'Stop recording and reconnect to the current project before switching scripts.'
    }
    Save-ZeeVAProject
    $script:State.SessionVerified = $false
    Send-Audacity 'Stop:'
    # File > Close keeps Audacity running and creates an empty project on Windows.
    Send-Audacity 'Close:'
    [object[]]$tracks = (Invoke-Audacity 'GetInfo: Type=Tracks Format=JSON') | ConvertFrom-Json
    if ($tracks.Count) {
        throw 'Audacity did not switch to an empty project. Open the saved block and Reconnect, or close other project windows and Scan Project before continuing.'
    }
    $script:State.Files = @()
    $script:State.Index = 0
    foreach ($map in @('Originals', 'Recorded', 'Accepted', 'Exported', 'Candidates', 'DialogueByFile')) {
        $script:State[$map] = @{}
    }
    $script:State.Candidate = $null
    $script:State.RecordingTargetName = $null
    $script:State.RecordingStart = 0.0
    $script:State.InterruptedRecording = $false
    $script:State.Source = ''
    $script:State.ProjectPath = ''
    $script:State.VoiceType = ''
    $script:State.DialogueExportPath = ''
    $script:State.ProjectProgress = ''
    $script:State.SessionDirty = $false
    $script:DialogueRows = @()
    $script:DialogueIndexedRows = $null
    $script:DialogueIndex = @{}
    $script:State.SessionVerified = $true
}

function Select-TextLineTrack {
    $file = Get-CurrentFile
    $name = Get-LineCandidate
    if (-not $name) { $name = $script:State.Accepted[$file.Name] }
    if (-not $name) { Send-Audacity 'SelectNone:'; return }
    $track = Find-AudioTrack $name
    Select-AudioTrack $track.Index $track.Start $track.End
    Send-Audacity 'ZoomSel:'
}

function Assert-TextProjectIdentity {
    [object[]]$tracks = (Invoke-Audacity 'GetInfo: Type=Tracks Format=JSON') | ConvertFrom-Json
    $snapshot = Get-ProjectSessionData $tracks
    if (-not $snapshot -or -not $snapshot.TextSourceOnly -or
        $snapshot.Source -ine $script:State.Source -or
        $snapshot.VoiceType -ine $script:State.VoiceType -or
        $snapshot.DialogueExportPath -ine $script:State.DialogueExportPath -or
        (@($snapshot.Files) -join '|') -cne (@($script:State.Files | ForEach-Object { $_.Name }) -join '|')) {
        throw 'The connected Audacity project is not this text-only script, voice type and recording block. Open the correct project and reconnect.'
    }
}

function Get-DialogueRow {
    param([IO.FileInfo]$File)

    if (-not $File -or $script:DialogueRows.Count -eq 0) { return $null }
    if ($script:State.TextSourceOnly) { return $script:State.DialogueByFile[$File.Name] }
    if (-not [object]::ReferenceEquals($script:DialogueIndexedRows, $script:DialogueRows)) {
        $script:DialogueIndex = @{}
        foreach ($row in $script:DialogueRows) {
            $recordingKey = 'Recording|' + [IO.Path]::GetFileNameWithoutExtension([string]$row.FILENAME)
            $infoKey = 'Info|' + ([string]$row.'TOPICINFO' -replace '^FormID\s+', '')
            foreach ($key in @($recordingKey, $infoKey)) {
                if (-not $script:DialogueIndex.ContainsKey($key)) {
                    $script:DialogueIndex[$key] = [Collections.Generic.List[object]]::new()
                }
                $script:DialogueIndex[$key].Add($row)
            }
        }
        $script:DialogueIndexedRows = $script:DialogueRows
    }
    $voiceType = Get-SessionVoiceType
    $matchesById = @($script:DialogueIndex['Recording|' + $File.BaseName] | Where-Object {
        $_ -and (
        -not $_.'VOICE TYPE' -or $_.'VOICE TYPE' -ieq $voiceType
        )
    })
    if ($matchesById.Count -eq 1) { return $matchesById[0] }
    if ($matchesById.Count -gt 1) { return $null }

    if ($File.BaseName -match '^(?:FormID[ _-]*)?([0-9A-Fa-f]{8})(?:[_-]([0-9]+))?$') {
        $infoId = $matches[1]
        $responseIndex = $matches[2]
        $matchesByInfo = @($script:DialogueIndex['Info|' + $infoId] | Where-Object {
            $_ -and (-not $_.'VOICE TYPE' -or $_.'VOICE TYPE' -ieq $voiceType) -and
            (-not $responseIndex -or [string]$_.'RESPONSE INDEX' -eq $responseIndex)
        })
        if ($matchesByInfo.Count -eq 1) { return $matchesByInfo[0] }
    }
    return $null
}

function Format-DialogueRow {
    param($Row, [switch]$Metadata)

    if (-not $Row) {
        if ($Metadata) { return '' }
        return 'No matching dialogue.'
    }
    if (-not $Metadata) { return [string]$Row.'RESPONSE TEXT' }
    $details = @($Row.'VOICE TYPE', $Row.FILENAME, $Row.TOPICINFO,
        $Row.QUEST, $Row.SCENE) | Where-Object { $_ }
    $text = $details -join ' | '
    if ($Row.'SCRIPT NOTES') { $text += "`r`n`r`n" + $Row.'SCRIPT NOTES' }
    return $text
}

function Update-ScriptDisplay {
    if (-not $script:ScriptWindow -or $script:ScriptWindow.IsDisposed) { return }
    $file = if ($script:State.Files.Count -gt 0) { Get-CurrentFile } else { $null }
    $current = Get-DialogueRow $file
    $script:ScriptWindow.Text = if ($file) { 'ZeeVA Script - ' + $file.Name } else { 'ZeeVA Script' }
    $hasScript = $script:DialogueRows.Count -gt 0
    $script:ScriptExportLabel.Text = if ($hasScript) {
        [IO.Path]::GetFileName($script:State.DialogueExportPath)
    } else { 'No matching script loaded' }
    $script:ScriptLoadButton.Text = if ($hasScript) { 'Load Script...' } else { 'Find Script...' }
    $script:ScriptLoadButton.Enabled = -not $script:State.Busy -and -not $script:State.Recording -and
        (-not $script:State.TextSourceOnly -or
            ($script:State.Connected -and $script:State.SessionVerified))
    if ($script:ActionToolTip) {
        $script:ActionToolTip.SetToolTip($script:ScriptExportLabel, $script:State.DialogueExportPath)
    }
    $script:ScriptColumns[1].Heading.Text = 'Current Dialogue'
    $script:ScriptColumns[1].Body.Text = Format-DialogueRow $current
    $script:ScriptColumns[1].Metadata.Text = Format-DialogueRow $current -Metadata
    foreach ($side in @(0, 2)) {
        $field = if ($side -eq 0) { 'DIALOGUE BEFORE' } else { 'DIALOGUE AFTER' }
        $heading = if ($side -eq 0) { 'Preceding Dialogue' } else { 'Following Dialogue' }
        if ($current -and $current.$field) {
            $script:ScriptColumns[$side].Heading.Text = $heading
            $script:ScriptColumns[$side].Body.Text = [string]$current.$field
            $script:ScriptColumns[$side].Metadata.Text = 'Context supplied for ' + $file.Name
        }
        else {
            if ($script:State.TextSourceOnly) {
                $rowIndex = [Array]::IndexOf($script:DialogueRows, $current)
                $neighborIndex = $rowIndex + $(if ($side -eq 0) { -1 } else { 1 })
                $neighbor = if ($current -and $neighborIndex -ge 0 -and $neighborIndex -lt $script:DialogueRows.Count) {
                    $script:DialogueRows[$neighborIndex]
                } else { $null }
                $script:ScriptColumns[$side].Heading.Text = $heading + ' (export order)'
                $script:ScriptColumns[$side].Body.Text = Format-DialogueRow $neighbor
                $script:ScriptColumns[$side].Metadata.Text = Format-DialogueRow $neighbor -Metadata
                continue
            }
            $neighborIndex = $script:State.Index + $(if ($side -eq 0) { -1 } else { 1 })
            $script:ScriptColumns[$side].Heading.Text = if ($side -eq 0) { 'Previous WAV' } else { 'Next WAV' }
            $neighbor = if ($file -and $neighborIndex -ge 0 -and $neighborIndex -lt $script:State.Files.Count) {
                Get-DialogueRow $script:State.Files[$neighborIndex]
            } else { $null }
            $script:ScriptColumns[$side].Body.Text = Format-DialogueRow $neighbor
            $script:ScriptColumns[$side].Metadata.Text = Format-DialogueRow $neighbor -Metadata
        }
    }
}

function Show-ScriptWindow {
    if (-not $script:ScriptWindow -or $script:ScriptWindow.IsDisposed) {
        $script:ScriptWindow = [ZeeVA.ScriptForm]::new()
        $script:ScriptWindow.Size = [Drawing.Size]::new(1200, 480)
        $script:ScriptWindow.MinimumSize = [Drawing.Size]::new(780, 320)
        $script:ScriptWindow.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi
        $script:ScriptWindow.Font = [Drawing.Font]::new('Segoe UI', 12)
        $script:ScriptWindow.ShowInTaskbar = $false
        $layout = [Windows.Forms.TableLayoutPanel]::new()
        $layout.Dock = 'Fill'
        $layout.Padding = [Windows.Forms.Padding]::new(12)
        $layout.ColumnCount = 3
        $layout.RowCount = 1
        $script:ScriptColumns = @()
        foreach ($column in 0..2) {
            $width = if ($column -eq 1) { 44 } else { 28 }
            $layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, $width)) | Out-Null
            $panel = [Windows.Forms.TableLayoutPanel]::new()
            $panel.Dock = 'Fill'
            $panel.ColumnCount = 1
            $panel.RowCount = 3
            $panel.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 32)) | Out-Null
            $panel.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 75)) | Out-Null
            $panel.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 25)) | Out-Null
            $heading = [Windows.Forms.Label]::new()
            $heading.Dock = 'Fill'
            $heading.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
            $body = [Windows.Forms.RichTextBox]::new()
            $body.Dock = 'Fill'
            $body.ReadOnly = $true
            $body.BorderStyle = 'None'
            $body.WordWrap = $true
            $body.DetectUrls = $false
            $body.BackColor = if ($column -eq 1) { [Drawing.Color]::Honeydew } else { [Drawing.SystemColors]::Window }
            $body.Font = [Drawing.Font]::new('Segoe UI', $(if ($column -eq 1) { 18 } else { 12 }))
            $metadata = [Windows.Forms.RichTextBox]::new()
            $metadata.Dock = 'Fill'
            $metadata.ReadOnly = $true
            $metadata.BorderStyle = 'None'
            $metadata.WordWrap = $true
            $metadata.DetectUrls = $false
            $metadata.BackColor = [Drawing.SystemColors]::ControlLight
            $metadata.Font = [Drawing.Font]::new('Segoe UI', 9)
            $metadataArea = $metadata
            if ($column -eq 1) {
                $metadataArea = [Windows.Forms.TableLayoutPanel]::new()
                $metadataArea.Dock = 'Fill'
                $metadataArea.ColumnCount = 1
                $metadataArea.RowCount = 2
                $metadataArea.BackColor = [Drawing.SystemColors]::ControlLight
                $metadataArea.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 28)) | Out-Null
                $metadataArea.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
                $scriptControls = [Windows.Forms.TableLayoutPanel]::new()
                $scriptControls.Dock = 'Fill'
                $scriptControls.Margin = [Windows.Forms.Padding]::new(0)
                $scriptControls.ColumnCount = 2
                $scriptControls.RowCount = 1
                $scriptControls.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100)) | Out-Null
                $scriptControls.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, 108)) | Out-Null
                $script:ScriptExportLabel = [Windows.Forms.Label]::new()
                $script:ScriptExportLabel.Dock = 'Fill'
                $script:ScriptExportLabel.AutoEllipsis = $true
                $script:ScriptExportLabel.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
                $script:ScriptExportLabel.Font = [Drawing.Font]::new('Segoe UI', 9)
                $script:ScriptLoadButton = [Windows.Forms.Button]::new()
                $script:ScriptLoadButton.Dock = 'Fill'
                $script:ScriptLoadButton.Margin = [Windows.Forms.Padding]::new(0)
                $script:ScriptLoadButton.Font = [Drawing.Font]::new('Segoe UI', 9)
                $script:ScriptLoadButton.Add_Click({
                    if ($script:State.TextSourceOnly) { Invoke-Action 1 }
                    else { Open-DialogueExport -Browse:($script:DialogueRows.Count -gt 0) }
                })
                $scriptControls.Controls.Add($script:ScriptExportLabel, 0, 0)
                $scriptControls.Controls.Add($script:ScriptLoadButton, 1, 0)
                $metadataArea.Controls.Add($scriptControls, 0, 0)
                $metadataArea.Controls.Add($metadata, 0, 1)
            }
            $panel.Controls.Add($heading, 0, 0)
            $panel.Controls.Add($body, 0, 1)
            $panel.Controls.Add($metadataArea, 0, 2)
            $layout.Controls.Add($panel, $column, 0)
            $script:ScriptColumns += [pscustomobject]@{Heading=$heading; Body=$body; Metadata=$metadata; MetadataArea=$metadataArea}
        }
        $script:ScriptWindow.Controls.Add($layout)
        if ($script:State.TextSourceOnly) { Enable-FolderDrop $script:ScriptWindow 1 }
    }
    Update-ScriptDisplay
    if (-not $script:ScriptWindow.Visible) { $script:ScriptWindow.Show($script:Form) }
}

function Get-DialogueExportLocation {
    $sourceFolder = if ($script:State.Source) { $script:State.Source } else { $script:State.LastSource }
    if (-not $sourceFolder) { throw 'Select a source WAV folder before loading its dialogue script.' }
    $directory = [IO.DirectoryInfo]::new([IO.Path]::GetFullPath($sourceFolder))
    $gameRoot = ''
    $modDirectory = $directory.Parent
    if ($modDirectory -and $modDirectory.Extension -in @('.esp', '.esm', '.esl')) {
        $soundDirectory = $modDirectory.Parent
        if ($soundDirectory -and $soundDirectory.Name -ieq 'Voice') { $soundDirectory = $soundDirectory.Parent }
        if ($soundDirectory -and $soundDirectory.Name -ieq 'Sound' -and
            $soundDirectory.Parent -and $soundDirectory.Parent.Name -ieq 'Data' -and
            $soundDirectory.Parent.Parent) {
            $gameRoot = $soundDirectory.Parent.Parent.FullName
        }
    }
    [pscustomobject]@{VoiceType=$directory.Name; GameRoot=$gameRoot}
}

function Read-VoiceDialogueExport {
    param([string]$Path, [string]$VoiceType)

    $rows = @(Import-DialogueExport $Path)
    if (-not $rows[0].PSObject.Properties['VOICE TYPE'] -or
        @($rows | Where-Object { $_.'VOICE TYPE' -ieq $VoiceType }).Count -eq 0) {
        throw "The dialogue export contains no rows for voice type $VoiceType."
    }
    [pscustomobject]@{Path=(Get-Item -LiteralPath $Path -ErrorAction Stop).FullName; Rows=$rows}
}

function Find-DialogueExport {
    param($Location, [string]$Path = '')

    $Path = Resolve-DialogueExportPath $Path
    $files = if ($Location.GameRoot -and (Test-Path -LiteralPath $Location.GameRoot -PathType Container)) {
        foreach ($file in Get-ChildItem -LiteralPath $Location.GameRoot -File -ErrorAction Stop) {
            if ($file.Extension -notin @('.txt', '.tsv') -or
                $file.BaseName.IndexOf($Location.VoiceType, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $file
        }
    } else { @() }
    foreach ($filtered in @($true, $false)) {
        if ($Path -and (([IO.Path]::GetFileNameWithoutExtension($Path) -match '_filtered$') -eq $filtered)) {
            try { return (Read-VoiceDialogueExport $Path $Location.VoiceType) }
            catch { Set-StatusMessage $_.Exception.Message -IsError }
        }
        $exports = @(
            foreach ($file in $files) {
                if ($file.FullName -ieq $Path -or (($file.BaseName -match '_filtered$') -ne $filtered)) { continue }
                try { Read-VoiceDialogueExport $file.FullName $Location.VoiceType }
                catch { Set-StatusMessage $_.Exception.Message -IsError }
            }
        )
        if ($exports.Count -eq 1) { return $exports[0] }
        if ($exports.Count -gt 1) { return $null }
    }
    return $null
}

function Select-DialogueExportFile {
    param([string]$InitialDirectory, [string]$VoiceType)

    $dialog = [Windows.Forms.OpenFileDialog]::new()
    try {
        $dialog.Title = 'Load dialogue export - ' + $VoiceType
        $dialog.Filter = 'Dialogue export (*.txt;*.tsv)|*.txt;*.tsv|All files (*.*)|*.*'
        if ($InitialDirectory) { $dialog.InitialDirectory = $InitialDirectory }
        if ($dialog.ShowDialog($script:Form) -ne 'OK') { return '' }
        return $dialog.FileName
    }
    finally { $dialog.Dispose() }
}

function Open-DialogueExport {
    param([string]$Path = '', [switch]$Browse, [switch]$Automatic)

    if ($script:State.Busy -or $script:State.Recording) { return }
    $script:State.Busy = $true
    try {
        $location = Get-DialogueExportLocation
        if (-not $Path) { $Path = $script:State.DialogueExportPath }
        $export = if (-not $Browse) { Find-DialogueExport $location $Path } else { $null }
        if (-not $export) {
            if ($Automatic) {
                $script:DialogueRows = @()
                Show-ScriptWindow
                Set-StatusMessage ('No matching dialogue export found for ' + $location.VoiceType + '.')
            }
            $Path = Select-DialogueExportFile -InitialDirectory $location.GameRoot -VoiceType $location.VoiceType
            if (-not $Path) { return }
            $Path = Resolve-DialogueExportPath $Path
            if (-not $Path) { throw 'The selected dialogue export no longer exists.' }
            $export = Read-VoiceDialogueExport $Path $location.VoiceType
        }
        $script:DialogueRows = $export.Rows
        $script:State.DialogueExportPath = $export.Path
        Save-SessionSettings
        Show-ScriptWindow
        Set-StatusMessage ('Loaded dialogue script: ' + $export.Path)
    }
    catch { Set-StatusMessage $_.Exception.Message -IsError }
    finally {
        $script:State.Busy = $false
        Update-ScriptDisplay
    }
}

function Read-SessionSettings {
    if (-not (Test-Path -LiteralPath $script:IniPath)) { return }
    foreach ($line in Get-Content -LiteralPath $script:IniPath -Encoding UTF8) {
        if ($line -match '^\s*(OutputRoot|LastSource|LastProject|DialogueExportPath)=(.+)$') {
            $script:State[$matches[1]] = $matches[2]
        }
    }
}

function Save-SessionSettings {
    $lines = @('[Session]')
    foreach ($key in @('OutputRoot', 'LastSource', 'LastProject', 'DialogueExportPath')) {
        $value = [string]$script:State[$key]
        if ($value -match '[\r\n]') { throw "Invalid INI value: $key" }
        $lines += '{0}={1}' -f $key, $value
    }
    $temporary = $script:IniPath + '.tmp'
    $lines | Set-Content -LiteralPath $temporary -Encoding UTF8 -ErrorAction Stop
    Move-Item -LiteralPath $temporary -Destination $script:IniPath -Force -ErrorAction Stop
}

function Get-SessionTrackName {
    param([string]$CheckpointHash = '')

    $snapshot = [ordered]@{
        Version = 1
        Source = $script:State.Source
        OutputRoot = $script:State.OutputRoot
        Files = @($script:State.Files | ForEach-Object { $_.Name })
        CurrentFile = (Get-CurrentFile).Name
        Originals = $script:State.Originals
        Accepted = $script:State.Accepted
        Exported = $script:State.Exported
        Candidate = $script:State.Candidate
        Candidates = $script:State.Candidates
    }
    if ($script:State.TextSourceOnly) {
        $snapshot.TextSourceOnly = $true
        $snapshot.VoiceType = $script:State.VoiceType
        $snapshot.DialogueExportPath = $script:State.DialogueExportPath
        $fileNames = @($script:State.Files | ForEach-Object { $_.Name })
        $snapshot.DialogueRows = @($script:DialogueRows | Where-Object {
            $_.'VOICE TYPE' -ieq $script:State.VoiceType -and
            ([IO.Path]::GetFileNameWithoutExtension([string]$_.FILENAME) + '.wav') -in $fileNames
        })
    }
    if ($CheckpointHash) {
        $snapshot = [ordered]@{
            Version = 1
            CheckpointHash = $CheckpointHash
            OutputRoot = $script:State.OutputRoot
            CurrentFile = (Get-CurrentFile).Name
            Accepted = $script:State.Accepted
            Exported = $script:State.Exported
            Candidate = $script:State.Candidate
            Candidates = $script:State.Candidates
        }
    }
    $json = $snapshot | ConvertTo-Json -Depth 5 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $buffer = [IO.MemoryStream]::new()
    try {
        $gzip = [IO.Compression.GZipStream]::new($buffer, [IO.Compression.CompressionLevel]::Optimal, $true)
        try { $gzip.Write($bytes, 0, $bytes.Length) }
        finally { $gzip.Dispose() }
        $script:SessionTrackPrefix + [Convert]::ToBase64String($buffer.ToArray())
    }
    finally { $buffer.Dispose() }
}

function Read-SessionTrackPayload {
    param([object[]]$Tracks, $Metadata, [string]$Prefix)

    $encoded = ([string]$Metadata.name).Substring($Prefix.Length)
    if ($encoded.StartsWith('v2|')) {
        if ($encoded -notmatch '^v2\|([1-9][0-9]*)\|([A-F0-9]{64})$') {
            throw 'Invalid session chunk manifest.'
        }
        $chunkCount = [int]$matches[1]
        $expectedHash = $matches[2]
        $metadataIndex = [Array]::IndexOf($Tracks, $Metadata)
        $labels = @(Get-AudacityLabels | Where-Object {
            $_.Track -eq $metadataIndex -and
            (-not [string]::IsNullOrEmpty($_.Text)) -and
            (-not $_.Text.StartsWith('ZeeVA Checkpoint|')) -and
            (-not $_.Text.StartsWith('ZeeVA Checkpoint Data|'))
        })
        if ($labels.Count -ne $chunkCount) { throw 'Session chunks are missing or duplicated.' }
        $chunks = @{}
        foreach ($label in $labels) {
            if ($label.Text -notmatch '^ZeeVA Data\|([0-9]+)\|([A-Za-z0-9+/=]+)$') {
                throw 'Invalid session chunk.'
            }
            $chunkIndex = [int]$matches[1]
            if ($chunkIndex -ge $chunkCount -or $chunks.ContainsKey($chunkIndex)) {
                throw 'Session chunk indices are invalid or duplicated.'
            }
            $chunks[$chunkIndex] = $matches[2]
        }
        $encoded = -join @(for ($chunkIndex = 0; $chunkIndex -lt $chunkCount; $chunkIndex++) {
            $chunks[$chunkIndex]
        })
        if ((Get-SessionPayloadHash $encoded) -cne $expectedHash) {
            throw 'The session chunk checksum does not match.'
        }
    }
    return $encoded
}

function Read-CheckpointJournalPayload {
    param([object[]]$Labels, [string]$Manifest = '')

    if (-not $Manifest) {
        $commits = @($Labels | Where-Object { $_.Text.StartsWith('ZeeVA Checkpoint|') })
        if (-not $commits.Count) { return $null }
        foreach ($commit in $commits) {
            if ($commit.Text -cnotmatch '^ZeeVA Checkpoint\|v3\|([1-9][0-9]*)\|([1-9][0-9]*)\|([A-F0-9]{64})$') {
                throw 'Invalid checkpoint journal manifest.'
            }
        }
        if (@($commits | ForEach-Object { [long]($_.Text.Split('|')[2]) } | Sort-Object -Unique).Count -ne $commits.Count) {
            throw 'Duplicate checkpoint journal commits.'
        }
        $latest = @($commits | Sort-Object { [long]($_.Text.Split('|')[2]) } -Descending)[0]
        $Manifest = $latest.Text
    }
    if ($Manifest -cnotmatch '^ZeeVA Checkpoint\|v3\|([1-9][0-9]*)\|([1-9][0-9]*)\|([A-F0-9]{64})$') {
        throw 'Invalid checkpoint journal manifest.'
    }
    $generation = [long]$matches[1]
    $chunkCount = [int]$matches[2]
    $expectedHash = $matches[3]
    if (@($Labels | Where-Object Text -CEQ $Manifest).Count -gt 1) {
        throw 'Duplicate checkpoint journal commits.'
    }
    $prefix = 'ZeeVA Checkpoint Data|' + $generation + '|'
    $chunks = @{}
    foreach ($label in @($Labels | Where-Object { $_.Text.StartsWith($prefix) })) {
        if ($label.Text -cnotmatch '^ZeeVA Checkpoint Data\|[1-9][0-9]*\|([0-9]+)\|([A-Za-z0-9+/=]+)$') {
            throw 'Invalid checkpoint journal chunk.'
        }
        $index = [int]$matches[1]
        if ($index -ge $chunkCount -or $chunks.ContainsKey($index)) {
            throw 'Invalid or duplicate checkpoint journal chunk index.'
        }
        $chunks[$index] = $matches[2]
    }
    if ($chunks.Count -ne $chunkCount) { throw 'Checkpoint journal chunks are missing.' }
    $encoded = -join @(for ($i = 0; $i -lt $chunkCount; $i++) { $chunks[$i] })
    if ((Get-SessionPayloadHash $encoded) -cne $expectedHash) { throw 'Checkpoint journal checksum does not match.' }
    return $encoded
}

function ConvertFrom-SessionPayload {
    param([string]$Encoded)

    $bytes = [Convert]::FromBase64String($Encoded)
    # Older projects store plain UTF-8 JSON; new payloads have a gzip header.
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0x1F -and $bytes[1] -eq 0x8B) {
        $inputBuffer = [IO.MemoryStream]::new($bytes, $false)
        $outputBuffer = [IO.MemoryStream]::new()
        try {
            $gzip = [IO.Compression.GZipStream]::new($inputBuffer, [IO.Compression.CompressionMode]::Decompress, $true)
            try { $gzip.CopyTo($outputBuffer) }
            finally { $gzip.Dispose() }
            $bytes = $outputBuffer.ToArray()
        }
        finally {
            $inputBuffer.Dispose()
            $outputBuffer.Dispose()
        }
    }
    [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -ErrorAction Stop
}

function Get-ProjectSessionData {
    param([object[]]$Tracks)

    $metadata = @($Tracks | Where-Object {
        ([string]$_.name).StartsWith($script:SessionTrackPrefix)
    })
    if ($metadata.Count -eq 0) { return $null }
    if ($metadata.Count -ne 1) { throw 'The project contains multiple ZeeVA session tracks.' }
    try {
        $encoded = Read-SessionTrackPayload -Tracks $Tracks -Metadata $metadata[0] -Prefix $script:SessionTrackPrefix
        $snapshot = ConvertFrom-SessionPayload $encoded
        if ($snapshot.Version -ne 1 -or -not $snapshot.Source -or
            -not $snapshot.OutputRoot -or @($snapshot.Files).Count -eq 0 -or
            -not $snapshot.CurrentFile -or -not $snapshot.Originals) {
            throw 'Missing or unsupported session fields.'
        }
        $metadataIndex = [Array]::IndexOf($Tracks, $metadata[0])
        $journal = Read-CheckpointJournalPayload -Labels @(Get-AudacityLabels | Where-Object Track -eq $metadataIndex)
        if (-not $journal) {
            $checkpoints = @($Tracks | Where-Object { ([string]$_.name).StartsWith('ZeeVA Progress|') })
            if ($checkpoints.Count -gt 1) { throw 'The project contains multiple ZeeVA progress tracks.' }
            if ($checkpoints.Count -eq 1) {
                $journal = Read-SessionTrackPayload -Tracks $Tracks -Metadata $checkpoints[0] -Prefix 'ZeeVA Progress|'
            }
        }
        if ($journal) {
            $payload = $journal
            $checkpoint = ConvertFrom-SessionPayload $payload
            if ($checkpoint.Version -ne 1 -or $checkpoint.CheckpointHash -cne (Get-SessionPayloadHash $encoded)) {
                throw 'The progress checkpoint does not match this session.'
            }
            foreach ($property in @('OutputRoot', 'CurrentFile', 'Accepted', 'Exported', 'Candidate', 'Candidates')) {
                if (-not $checkpoint.PSObject.Properties[$property]) { throw "Missing checkpoint field: $property" }
                $snapshot | Add-Member -MemberType NoteProperty -Name $property -Value $checkpoint.$property -Force
            }
            if (-not $snapshot.OutputRoot -or $snapshot.CurrentFile -cnotin $snapshot.Files) {
                throw 'Invalid checkpoint output folder or current line.'
            }
        }
        return $snapshot
    }
    catch {
        throw "Cannot read ZeeVA project bookkeeping: $($_.Exception.Message)"
    }
}

function Get-SessionPayloadHash {
    param([string]$Payload)

    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        [BitConverter]::ToString($hasher.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($Payload)
        )).Replace('-', '')
    }
    finally { $hasher.Dispose() }
}

function Set-ProjectProgress {
    param([string]$Message)

    $script:State.ProjectProgress = $Message
    if ($Message) {
        Set-StatusMessage $Message
        if ($script:Status -and -not $script:Status.IsDisposed) {
            $script:Status.Text = $Message
            $script:Status.Refresh()
        }
    }
}

function Save-SessionCheckpoint {
    param([object[]]$Tracks, [string]$Baseline)

    $encoded = (Get-SessionTrackName -CheckpointHash (Get-SessionPayloadHash $Baseline)).Substring($script:SessionTrackPrefix.Length)
    $saved = Get-ProjectSessionData $Tracks
    $current = ConvertFrom-SessionPayload $encoded
    $unchanged = $true
    foreach ($property in @('OutputRoot', 'CurrentFile', 'Accepted', 'Exported', 'Candidate', 'Candidates')) {
        if ((ConvertTo-Json -InputObject $saved.$property -Depth 5 -Compress) -cne
            (ConvertTo-Json -InputObject $current.$property -Depth 5 -Compress)) {
            $unchanged = $false
            break
        }
    }
    if ($unchanged) { return }
    $metadata = @($Tracks | Where-Object { ([string]$_.name).StartsWith($script:SessionTrackPrefix) })
    if ($metadata.Count -ne 1 -or $metadata[0].kind -cne 'label') {
        throw 'A unique baseline label track is required for checkpoint saves.'
    }
    $index = [Array]::IndexOf($Tracks, $metadata[0])
    $allLabels = @(Get-AudacityLabels)
    $labels = @($allLabels | Where-Object Track -eq $index)
    $generation = 1L
    foreach ($label in $labels) {
        if ($label.Text -cmatch '^ZeeVA Checkpoint(?: Data)?\|(?:v3\|)?([1-9][0-9]*)\|') {
            $generation = [Math]::Max($generation, [long]$matches[1] + 1L)
        }
    }
    $chunks = @(
        for ($offset = 0; $offset -lt $encoded.Length; $offset += 512) {
            $encoded.Substring($offset, [Math]::Min(512, $encoded.Length - $offset))
        }
    )
    if ($allLabels.Count + $chunks.Count + 1 -gt 10001) {
        throw 'No room for a checkpoint within Audacity''s scripting label limit. The previous checkpoint is unchanged.'
    }
    $manifest = 'ZeeVA Checkpoint|v3|{0}|{1}|{2}' -f $generation, $chunks.Count, (Get-SessionPayloadHash $encoded)
    Set-ProjectProgress ('Saving progress - 0/{0} labels' -f $chunks.Count)
    $script:State.SessionDirty = $true
    for ($chunkIndex = 0; $chunkIndex -lt $chunks.Count; $chunkIndex++) {
        $time = ($allLabels.Count + $chunkIndex) / 100.0
        $labelIndex = New-AudacityLabel -Track $index -Start $time -End $time
        Send-Audacity ('SetLabel: Label={0} Text={1}' -f $labelIndex,
            (Quote-Audacity ('ZeeVA Checkpoint Data|{0}|{1}|{2}' -f $generation, $chunkIndex, $chunks[$chunkIndex])))
        Set-ProjectProgress ('Saving progress - {0}/{1} labels' -f ($chunkIndex + 1), $chunks.Count)
    }
    $written = @(Get-AudacityLabels | Where-Object Track -eq $index)
    if ((Read-CheckpointJournalPayload -Labels $written -Manifest $manifest) -cne $encoded) {
        throw 'Checkpoint verification failed. The previous checkpoint is unchanged.'
    }
    # Commit only after every new chunk is verified; interrupted writes leave the old checkpoint readable.
    $time = ($allLabels.Count + $chunks.Count) / 100.0
    $labelIndex = New-AudacityLabel -Track $index -Start $time -End $time
    Send-Audacity ('SetLabel: Label={0} Text={1}' -f $labelIndex, (Quote-Audacity $manifest))
    if ((Read-CheckpointJournalPayload -Labels @(Get-AudacityLabels | Where-Object Track -eq $index)) -cne $encoded) {
        throw 'Checkpoint commit verification failed. Inspect the project before continuing.'
    }
}

function Assert-SelectedLabelTrack {
    [CmdletBinding()]
    param([int]$Index)

    [object[]]$tracks = (Invoke-Audacity 'GetInfo: Type=Tracks Format=JSON') | ConvertFrom-Json
    $selected = @(
        for ($i = 0; $i -lt $tracks.Count; $i++) {
            if ($tracks[$i].selected) { $i }
        }
    )
    if ($Index -lt 0 -or $Index -ge $tracks.Count -or $tracks[$Index].kind -cne 'label' -or
        $selected.Count -ne 1 -or $selected[0] -ne $Index) {
        $exception = [InvalidOperationException]::new(
            'Metadata operation stopped: exactly one intended label track must be selected. The checkpoint was not completed. No audio track was renamed or removed. Leave Audacity untouched and retry Save Project; reconnect and inspect the project if this repeats.'
        )
        $PSCmdlet.ThrowTerminatingError([Management.Automation.ErrorRecord]::new(
            $exception, 'ZeeVAMetadataSelection', [Management.Automation.ErrorCategory]::InvalidOperation, $Index
        ))
    }
}

function Restore-SessionSelection {
    if ($script:State.Recording) { throw 'Stop recording before restoring the take view.' }
    Send-Audacity 'SelectNone:'
    $file = Get-CurrentFile
    $name = $script:State.Candidate
    if (-not $name) { $name = $script:State.Accepted[$file.Name] }
    if (-not $name) { $name = $script:State.Originals[$file.Name] }
    if (-not $name -and $script:State.TextSourceOnly) { return }
    $track = Find-AudioTrack $name
    # Setting track focus alone does not scroll. Navigate from the preceding track without wrapping.
    if ($track.Index -gt 0) {
        Send-Audacity ('SelectTracks: Track={0} TrackCount=1 Mode=Set' -f ($track.Index - 1))
        Send-Audacity 'SetTrackStatus: Focused=1'
    }
    Select-AudioTrack $track.Index $track.Start $track.End
    if ($track.Index -eq 0) {
        Send-Audacity 'SetTrackStatus: Focused=1'
        Send-Audacity 'FirstTrack:'
    }
    else {
        Send-Audacity 'NextTrack:'
    }
}

function New-AudacityLabel {
    param([int]$Track, [double]$Start, [double]$End)

    Select-AudioTrack $Track $Start $End
    Assert-SelectedLabelTrack $Track
    # AddLabel follows focus, not the selected track.
    Send-Audacity 'SetTrackStatus: Focused=1'
    Send-Audacity 'AddLabel:'
    $created = @(Get-AudacityLabels | Where-Object {
        $_.Track -eq $Track -and [string]::IsNullOrEmpty($_.Text) -and
        [Math]::Abs($_.Start - $Start) -lt 0.001 -and
        [Math]::Abs($_.End - $End) -lt 0.001
    })
    if ($created.Count -ne 1) {
        throw "Could not identify the new label on track $Track. No existing label was renamed."
    }
    return $created[0].Index
}

function Save-ProjectBookkeeping {
    $null = Get-CurrentFile
    $previousProgress = $script:State.ProjectProgress
    try {
        [object[]]$tracks = (Invoke-Audacity 'GetInfo: Type=Tracks Format=JSON') | ConvertFrom-Json
        $metadataIndices = @(
            for ($trackIndex = 0; $trackIndex -lt $tracks.Count; $trackIndex++) {
                if (([string]$tracks[$trackIndex].name).StartsWith($script:SessionTrackPrefix)) {
                    $trackIndex
                }
            }
        )
        if ($metadataIndices.Count -gt 1) { throw 'The project contains multiple ZeeVA session tracks.' }
        $filenameLabels = @()
        if ($metadataIndices.Count -eq 1) {
            $filenameLabels = @(Get-AudacityLabels | Where-Object {
                $_.Track -eq $metadataIndices[0] -and
                $_.Text -cin @($script:State.Files | ForEach-Object { $_.BaseName })
            })
            if ($filenameLabels.Count -gt 0) {
                $regionIndex = Get-AcceptanceLabelTrackIndex
                foreach ($label in $filenameLabels) {
                    Select-AudioTrack $regionIndex $label.Start $label.End
                    Send-Audacity 'SetTrackStatus: Focused=1'
                    Send-Audacity 'AddLabel:'
                    $created = @(Get-AudacityLabels | Where-Object {
                        $_.Track -eq $regionIndex -and [string]::IsNullOrEmpty($_.Text) -and
                        [Math]::Abs($_.Start - $label.Start) -lt 0.001 -and
                        [Math]::Abs($_.End - $label.End) -lt 0.001
                    })
                    if ($created.Count -ne 1) { throw 'Could not preserve a filename label before replacing bookkeeping.' }
                    Send-Audacity ('SetLabel: Label={0} Text={1} Start={2} End={3}' -f
                        $created[0].Index, (Quote-Audacity $label.Text),
                        (Format-Time $label.Start), (Format-Time $label.End))
                }
                $tracks = (Invoke-Audacity 'GetInfo: Type=Tracks Format=JSON') | ConvertFrom-Json
            }
        }
        $encoded = (Get-SessionTrackName).Substring($script:SessionTrackPrefix.Length)
        if ($metadataIndices.Count -eq 1 -and -not $filenameLabels.Count) {
            $baseline = Read-SessionTrackPayload -Tracks $tracks -Metadata $tracks[$metadataIndices[0]] -Prefix $script:SessionTrackPrefix
            $saved = ConvertFrom-SessionPayload $baseline
            $current = ConvertFrom-SessionPayload $encoded
            $sameSession = $true
            foreach ($property in @('Version', 'Source', 'Files', 'Originals', 'TextSourceOnly', 'VoiceType', 'DialogueExportPath', 'DialogueRows')) {
                if ((ConvertTo-Json -InputObject $saved.$property -Depth 5 -Compress) -cne
                    (ConvertTo-Json -InputObject $current.$property -Depth 5 -Compress)) {
                    $sameSession = $false
                    break
                }
            }
            if ($sameSession) {
                Save-SessionCheckpoint -Tracks $tracks -Baseline $baseline
                Restore-SessionSelection
                return
            }
        }
        $checkpoints = @($tracks | Where-Object { ([string]$_.name).StartsWith('ZeeVA Progress|') })
        if ($checkpoints.Count -gt 1) { throw 'The project contains multiple ZeeVA progress tracks.' }
        if ($checkpoints.Count -eq 1) {
            if ($checkpoints[0].kind -cne 'label') { throw 'The ZeeVA progress track must be a label track.' }
            Send-Audacity ('SelectTracks: Track={0} TrackCount=1 Mode=Set' -f ([Array]::IndexOf($tracks, $checkpoints[0])))
            Assert-SelectedLabelTrack ([Array]::IndexOf($tracks, $checkpoints[0]))
            Send-Audacity 'RemoveTracks:'
            $tracks = (Invoke-Audacity 'GetInfo: Type=Tracks Format=JSON') | ConvertFrom-Json
            $metadataIndices = @(
                for ($index = 0; $index -lt $tracks.Count; $index++) {
                    if (([string]$tracks[$index].name).StartsWith($script:SessionTrackPrefix)) { $index }
                }
            )
        }
        Set-ProjectProgress 'Preparing project...'
        $chunks = @(
            for ($offset = 0; $offset -lt $encoded.Length; $offset += 512) {
                $encoded.Substring($offset, [Math]::Min(512, $encoded.Length - $offset))
            }
        )
        Set-ProjectProgress ('Preparing project - 0/{0} labels' -f $chunks.Count)
        Send-Audacity 'SelectNone:'
        if ($metadataIndices.Count -eq 1) {
            if ($tracks[$metadataIndices[0]].kind -cne 'label') {
                throw 'The ZeeVA bookkeeping track must be a label track, not audio.'
            }
            Send-Audacity ('SelectTracks: Track={0} TrackCount=1 Mode=Set' -f $metadataIndices[0])
            Assert-SelectedLabelTrack $metadataIndices[0]
            Send-Audacity 'RemoveTracks:'
        }
        $metadataIndex = $tracks.Count - $metadataIndices.Count
        Send-Audacity 'NewLabelTrack:'
        for ($chunkIndex = 0; $chunkIndex -lt $chunks.Count; $chunkIndex++) {
            $time = $chunkIndex / 1000.0
            $labelIndex = New-AudacityLabel -Track $metadataIndex -Start $time -End $time
            Send-Audacity ('SetLabel: Label={0} Text={1}' -f
                $labelIndex,
                (Quote-Audacity ('ZeeVA Data|{0}|{1}' -f $chunkIndex, $chunks[$chunkIndex])))
            Set-ProjectProgress ('Preparing project - {0}/{1} labels' -f ($chunkIndex + 1), $chunks.Count)
        }
        Send-Audacity ('SelectTracks: Track={0} TrackCount=1 Mode=Set' -f $metadataIndex)
        Assert-SelectedLabelTrack $metadataIndex
        $manifest = '{0}v2|{1}|{2}' -f $script:SessionTrackPrefix,
            $chunks.Count, (Get-SessionPayloadHash $encoded)
        Send-Audacity ('SetTrackStatus: Name=' + (Quote-Audacity $manifest))
        Restore-SessionSelection
    }
    finally { Set-ProjectProgress $previousProgress }
}

function Get-AudacityLabels {
    $groups = (Invoke-Audacity 'GetInfo: Type=Labels Format=JSON') | ConvertFrom-Json
    $labelIndex = 0
    foreach ($group in $groups) {
        foreach ($label in $group[1]) {
            [pscustomobject]@{
                Index = $labelIndex
                Track = [int]$group[0]
                Start = [double]$label[0]
                End = [double]$label[1]
                Text = [string]$label[2]
            }
            $labelIndex++
        }
    }
}

function Update-TrimmedAcceptanceRegions {
    param(
        [hashtable]$Accepted,
        [hashtable]$Exported,
        [object[]]$Tracks,
        [object[]]$Labels
    )

    $updated = 0
    foreach ($fileName in $Accepted.Keys) {
        $baseName = [IO.Path]::GetFileNameWithoutExtension($fileName)
        $takeName = [string]$Accepted[$fileName]
        if (-not $takeName.StartsWith('TAKE|' + $baseName + '|')) {
            throw 'The project contains an invalid accepted-take mapping.'
        }
        $takes = @($Tracks | Where-Object { $_.Name -ceq $takeName })
        $regions = @($Labels | Where-Object { $_.Text -ceq $baseName })
        if ($takes.Count -ne 1 -or $regions.Count -ne 1 -or
            $takes[0].Channels -ne 2 -or $takes[0].End -le $takes[0].Start) { continue }
        $take = $takes[0]
        $region = $regions[0]
        if (Test-LabelWithinTake $region $take) { continue }
        # Only an inward trim of the already accepted take can follow its old region.
        $oldBounds = [pscustomobject]@{Start=$region.Start; End=$region.End; Channels=2}
        if (-not (Test-LabelWithinTake $take $oldBounds)) { continue }
        $script:State.SessionDirty = $true
        Send-Audacity ('SetLabel: Label={0} Start={1} End={2}' -f
            $region.Index, (Format-Time $take.Start), (Format-Time $take.End))
        $Exported.Remove($fileName)
        $updated++
        # Changing a label's start can change global label indices.
        $Labels = @(Get-AudacityLabels)
        $written = @($Labels | Where-Object { $_.Text -ceq $baseName })
        if ($written.Count -ne 1 -or -not (Test-LabelWithinTake $written[0] $take)) {
            throw "Could not update the accepted region for $fileName after trimming. Inspect the region before continuing."
        }
    }
    if ($updated) { Set-StatusMessage "Updated $updated accepted region(s) to match trimmed takes." }
    return $updated
}

function Sync-AudacitySession {
    if ($script:State.Files.Count -eq 0) { return }
    if ($script:State.TextSourceOnly) { Assert-TextProjectIdentity }
    $tracks = @(Get-AudacityTracks)
    $labels = @(Get-AudacityLabels)
    if ($script:State.TextSourceOnly -and
        (Update-TrimmedAcceptanceRegions -Accepted $script:State.Accepted -Exported $script:State.Exported -Tracks $tracks -Labels $labels)) {
        $script:State.SessionDirty = $true
        $labels = @(Get-AudacityLabels)
    }
    foreach ($name in $script:State.Originals.Values) {
        if (@($tracks | Where-Object { $_.Name -ceq $name }).Count -ne 1) {
            throw "The project does not contain exactly one source track named '$name'. Open the correct project and reconnect."
        }
    }
    $recorded = @{}
    $accepted = @{}
    $exported = @{}
    $candidates = @{}
    foreach ($file in $script:State.Files) {
        $prefix = 'TAKE|' + $file.BaseName + '|'
        $takes = @($tracks | Where-Object {
            $_.Name.StartsWith($prefix) -and $_.Channels -eq 2 -and $_.End -gt $_.Start
        })
        $recorded[$file.Name] = @($takes | ForEach-Object { $_.Name })
        $savedTake = $script:State.Accepted[$file.Name]
        if (-not $savedTake) { continue }
        $matching = @($takes | Where-Object { $_.Name -ceq $savedTake })
        $regions = @($labels | Where-Object { $_.Text -ceq $file.BaseName })
        if ($matching.Count -ne 1 -or $regions.Count -ne 1 -or
            -not (Test-LabelWithinTake $regions[0] $matching[0])) { continue }
        $accepted[$file.Name] = $savedTake
        $receipt = $script:State.Exported[$file.Name]
        if (-not $receipt) { continue }
        $destination = Join-Path (Join-Path $script:State.OutputRoot (
            Get-SessionVoiceType
        )) $file.Name
        if ($receipt.Take -cne $savedTake -or $receipt.Path -ine $destination -or
            [Math]::Abs([double]$receipt.Start - [Math]::Max($regions[0].Start, $matching[0].Start)) -gt 0.000001 -or
            [Math]::Abs([double]$receipt.End - [Math]::Min($regions[0].End, $matching[0].End)) -gt 0.000001 -or
            -not $receipt.Hash -or -not (Test-Path -LiteralPath $destination -PathType Leaf)) { continue }
        try {
            $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256 -ErrorAction Stop).Hash
            if ($hash -ceq $receipt.Hash) { $exported[$file.Name] = $receipt }
        }
        catch { }
    }
    foreach ($file in $script:State.Files) {
        $savedCandidate = $script:State.Candidates[$file.Name]
        if ($savedCandidate -and $savedCandidate -cin $recorded[$file.Name] -and
            $savedCandidate -cne $accepted[$file.Name]) {
            $candidates[$file.Name] = $savedCandidate
        }
    }
    $candidate = $script:State.Candidate
    if ($candidate) {
        $current = Get-CurrentFile
        if (@($recorded[$current.Name] | Where-Object { $_ -ceq $candidate }).Count -ne 1 -or
            $candidate -in $accepted.Values) { $candidate = $null }
    }
    $current = Get-CurrentFile
    if ($candidate) { $candidates[$current.Name] = $candidate }
    elseif ($candidates.ContainsKey($current.Name)) { $candidate = $candidates[$current.Name] }
    if ($accepted.Count -ne $script:State.Accepted.Count -or
        $exported.Count -ne $script:State.Exported.Count -or
        $candidates.Count -ne $script:State.Candidates.Count -or
        $candidate -cne $script:State.Candidate) {
        $script:State.SessionDirty = $true
    }
    $script:State.Recorded = $recorded
    $script:State.Accepted = $accepted
    $script:State.Exported = $exported
    $script:State.Candidate = $candidate
    $script:State.Candidates = $candidates
}

function Restore-ProjectSession {
    param([string]$SourceFolder = '', [switch]$Quiet)

    [object[]]$projectTracks = (Invoke-Audacity 'GetInfo: Type=Tracks Format=JSON') | ConvertFrom-Json
    $snapshot = Get-ProjectSessionData $projectTracks
    if ([bool]$snapshot.TextSourceOnly -ne [bool]$script:State.TextSourceOnly) {
        throw 'This project uses a different ZeeVA source mode. Open it with the matching ZeeVA or ZeeVA_TextOnly helper.'
    }
    $textData = $null
    if ($script:State.TextSourceOnly) {
        if (-not $snapshot) { throw 'This text-only project has no ZeeVA session bookkeeping.' }
        if (-not $snapshot.DialogueExportPath -or -not $snapshot.VoiceType -or
            -not @($snapshot.DialogueRows).Count) {
            throw 'The text-only project is missing its script or selected voice type.'
        }
        $textData = Get-TextDialogueData -Path $snapshot.DialogueExportPath `
            -Rows @($snapshot.DialogueRows) -VoiceType $snapshot.VoiceType
        if ($snapshot.Source -ine $textData.Source -or
            @($snapshot.Originals.PSObject.Properties).Count -ne 0) {
            throw 'The text-only project contains invalid source data or original audio mappings.'
        }
        $SourceFolder = $textData.Source
    }
    $tracks = @(Get-AudacityTracks)
    $originals = @{}
    $accepted = @{}
    $exported = @{}
    $candidates = @{}
    $candidate = $null
    $currentFile = ''
    $outputRoot = $script:State.OutputRoot
    if ($snapshot) {
        $fileNames = @($snapshot.Files)
        if (-not $SourceFolder) { $SourceFolder = [string]$snapshot.Source }
        $outputRoot = [string]$snapshot.OutputRoot
        $currentFile = [string]$snapshot.CurrentFile
        $candidate = $snapshot.Candidate
        if ($snapshot.Candidates) {
            foreach ($property in $snapshot.Candidates.PSObject.Properties) {
                $candidates[$property.Name] = [string]$property.Value
            }
        }
        foreach ($property in $snapshot.Originals.PSObject.Properties) {
            $originals[$property.Name] = [string]$property.Value
        }
        foreach ($property in $snapshot.Accepted.PSObject.Properties) {
            $accepted[$property.Name] = [string]$property.Value
        }
        foreach ($property in $snapshot.Exported.PSObject.Properties) {
            $exported[$property.Name] = $property.Value
        }
    }
    else {
        foreach ($track in $tracks) {
            if ($track.Name.StartsWith('SRC|')) {
                $fileName = $track.Name.Substring(4) + '.wav'
                if ($originals.ContainsKey($fileName)) { throw "Duplicate source track: $fileName" }
                $originals[$fileName] = $track.Name
            }
        }
        $fileNames = @($originals.Keys | Sort-Object)
        if ($fileNames.Count -eq 0) { throw 'This project contains no ZeeVA source tracks (SRC|filename).' }
        if (-not $SourceFolder) { $SourceFolder = $script:State.LastSource }
    }
    foreach ($fileName in $fileNames) {
        if ([string]::IsNullOrWhiteSpace($fileName) -or
            [IO.Path]::GetFileName($fileName) -cne $fileName -or
            [IO.Path]::GetExtension($fileName) -ine '.wav' -or
            (-not $script:State.TextSourceOnly -and -not $originals.ContainsKey($fileName)) -or
            ($script:State.TextSourceOnly -and -not $textData.ByFile.ContainsKey($fileName))) {
            throw 'The project contains invalid source filenames or mappings.'
        }
    }
    if (@($fileNames | Select-Object -Unique).Count -ne $fileNames.Count) {
        throw 'The project contains duplicate source filenames.'
    }
    $sourceValid = $script:State.TextSourceOnly -or
        ($SourceFolder -and (Test-Path -LiteralPath $SourceFolder -PathType Container))
    if ($sourceValid -and -not $snapshot) {
        $missingFiles = @($fileNames | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $SourceFolder $_) -PathType Leaf)
        })
        $sourceValid = $missingFiles.Count -eq 0
    }
    if (-not $sourceValid) {
        $SourceFolder = Choose-Folder 'Locate the original speaker folder for this project'
        if (-not $SourceFolder) { throw 'Project scan cancelled; no session was loaded.' }
    }
    if (-not $snapshot) {
        foreach ($fileName in $fileNames) {
            if (-not (Test-Path -LiteralPath (Join-Path $SourceFolder $fileName) -PathType Leaf)) {
                throw "The selected source folder does not contain $fileName. Select the correct folder and scan again."
            }
        }
    }

    $recoveredProgress = $false
    $interruptedFile = ''
    $interruptedStart = [double]::NegativeInfinity
    foreach ($fileName in $fileNames) {
        $prefix = 'RECORDING|' + [IO.Path]::GetFileNameWithoutExtension($fileName) + '|'
        foreach ($track in @($tracks | Where-Object {
            $_.Name.StartsWith($prefix) -and $_.Channels -eq 2 -and $_.End -gt $_.Start
        })) {
            $name = 'TAKE|' + $track.Name.Substring('RECORDING|'.Length)
            if (@($tracks | Where-Object { $_.Name -ceq $name }).Count) {
                throw "Cannot recover interrupted recording: duplicate take '$name'."
            }
            Select-AudioTrack $track.Index $track.Start $track.End
            Send-Audacity ('SetTrackStatus: Name=' + (Quote-Audacity $name))
            $track.Name = $name
            $recoveredProgress = $true
            if ($track.Start -gt $interruptedStart) {
                $interruptedFile = $fileName
                $interruptedStart = $track.Start
            }
        }
    }
    $labels = @(Get-AudacityLabels)
    foreach ($fileName in $accepted.Keys) {
        if ($fileName -cnotin $fileNames -or -not $accepted[$fileName].StartsWith(
            'TAKE|' + [IO.Path]::GetFileNameWithoutExtension($fileName) + '|')) {
            throw 'The project contains an invalid accepted-take mapping.'
        }
    }
    if ($script:State.TextSourceOnly -and
        (Update-TrimmedAcceptanceRegions -Accepted $accepted -Exported $exported -Tracks $tracks -Labels $labels)) {
        $recoveredProgress = $true
        $labels = @(Get-AudacityLabels)
    }
    $ambiguous = 0
    foreach ($fileName in $fileNames) {
        $baseName = [IO.Path]::GetFileNameWithoutExtension($fileName)
        $regions = @($labels | Where-Object { $_.Text -ceq $baseName })
        if ($regions.Count -eq 0) { continue }
        $matchesForLine = @($tracks | Where-Object {
            $_.Name.StartsWith('TAKE|' + $baseName + '|') -and
            $_.Channels -eq 2 -and $regions.Count -eq 1 -and
            (Test-LabelWithinTake $regions[0] $_)
        })
        if ($matchesForLine.Count -eq 1) {
            if (-not $accepted.ContainsKey($fileName)) {
                $accepted[$fileName] = $matchesForLine[0].Name
                $recoveredProgress = $true
            }
        }
        else { $ambiguous++ }
    }
    if (-not $snapshot -or $recoveredProgress) {
        $remaining = @($fileNames | Where-Object { -not $accepted.ContainsKey($_) })
        $currentFile = if ($remaining.Count) { $remaining[0] } else { $fileNames[-1] }
        if ($interruptedFile) { $currentFile = $interruptedFile }
        $candidate = $null
    }
    if (-not $candidate) {
        $prefix = 'TAKE|' + [IO.Path]::GetFileNameWithoutExtension($currentFile) + '|'
        $unaccepted = @($tracks | Where-Object {
            $_.Name.StartsWith($prefix) -and $_.Channels -eq 2 -and
            $_.End -gt $_.Start -and $_.Name -notin $accepted.Values
        })
        if ($unaccepted.Count -eq 1) {
            $candidate = $unaccepted[0].Name
            $recoveredProgress = $true
        }
    }
    if ($currentFile -cnotin $fileNames) { throw 'The saved current WAV is not in the session.' }
    if ($candidate -and -not $candidate.StartsWith(
        'TAKE|' + [IO.Path]::GetFileNameWithoutExtension($currentFile) + '|')) {
        throw 'The saved candidate does not belong to the current WAV.'
    }

    $previous = $script:State.Clone()
    $previousRows = $script:DialogueRows
    try {
        $script:State.Source = [IO.Path]::GetFullPath($SourceFolder)
        $script:State.OutputRoot = $outputRoot
        $script:State.Files = @($fileNames | ForEach-Object { [IO.FileInfo]::new((Join-Path $SourceFolder $_)) })
        $script:State.Index = [Array]::IndexOf($fileNames, $currentFile)
        $script:State.Originals = $originals
        $script:State.Accepted = $accepted
        $script:State.Exported = $exported
        $script:State.Candidate = $candidate
        $script:State.Candidates = $candidates
        if ($script:State.TextSourceOnly) {
            $script:State.VoiceType = [string]$snapshot.VoiceType
            $script:State.DialogueExportPath = [string]$snapshot.DialogueExportPath
            $script:State.DialogueByFile = $textData.ByFile
            $script:DialogueRows = @($snapshot.DialogueRows)
        }
        $script:State.SessionDirty = -not [bool]$snapshot -or $recoveredProgress
        Sync-AudacitySession
        Assert-AudacitySession
        $script:State.SessionVerified = $true
        $script:State.LastSource = $script:State.Source
    }
    catch {
        $script:State = $previous
        $script:DialogueRows = $previousRows
        throw
    }
    if (-not $Quiet) {
        Set-StatusMessage "Loaded $($fileNames.Count) lines; $($script:State.Accepted.Count) accepted; $($script:State.Exported.Count) exported. Current: $currentFile. Ambiguous labels left unaccepted: $ambiguous"
    }
}

function Save-ZeeVAProject {
    param([string]$Path = '', [switch]$Overwrite, [switch]$BookkeepingPrepared)

    if ($script:State.Recording) { throw 'Stop recording before saving the project.' }
    if ($script:State.TextSourceOnly -and $script:State.Accepted.Count) {
        Assert-TextProjectIdentity
        if (Update-TrimmedAcceptanceRegions -Accepted $script:State.Accepted -Exported $script:State.Exported `
            -Tracks @(Get-AudacityTracks) -Labels @(Get-AudacityLabels)) {
            $script:State.SessionDirty = $true
        }
    }
    Assert-AudacitySession
    if (-not $Path) { $Path = $script:State.ProjectPath }
    if (-not $Path) {
        $dialog = [Windows.Forms.SaveFileDialog]::new()
        try {
            $dialog.Title = 'Save Audacity project'
            $dialog.Filter = 'Audacity projects (*.aup3)|*.aup3'
            $dialog.DefaultExt = 'aup3'
            $dialog.FileName = (Get-SessionVoiceType) + '.aup3'
            $dialog.InitialDirectory = Split-Path $script:State.Source -Parent
            if ($dialog.ShowDialog($script:Form) -ne 'OK') { throw 'Project save cancelled.' }
            $Path = $dialog.FileName
        }
        finally { $dialog.Dispose() }
    }
    if (-not $BookkeepingPrepared) { Save-ProjectBookkeeping }
    $backupPath = ''
    if ($Overwrite -and (Test-Path -LiteralPath $Path)) {
        foreach ($suffix in @('-wal', '-shm')) {
            if (Test-Path -LiteralPath ($Path + $suffix)) {
                throw 'Close the existing project in Audacity before overwriting it.'
            }
        }
        $backupPath = Join-Path (Split-Path $Path -Parent) (
            [IO.Path]::GetFileNameWithoutExtension($Path) + '.backup-' +
            [Guid]::NewGuid().ToString('N') + '.aup3'
        )
        Move-Item -LiteralPath $Path -Destination $backupPath -ErrorAction Stop
    }
    $previousProgress = $script:State.ProjectProgress
    try {
        Set-ProjectProgress 'Saving Audacity project...'
        Send-Audacity ('SaveProject2: Filename=' + (Quote-Audacity $Path))
    }
    catch {
        if ($backupPath) {
            if (-not (Test-Path -LiteralPath $Path)) {
                Move-Item -LiteralPath $backupPath -Destination $Path -ErrorAction Stop
            }
            else {
                throw "Project save failed: $($_.Exception.Message)`nThe previous project is preserved at $backupPath"
            }
        }
        throw
    }
    finally { Set-ProjectProgress $previousProgress }
    $script:State.ProjectPath = $Path
    $script:State.SessionDirty = $false
    if ($script:State.ProjectPath) {
        $script:State.LastProject = $script:State.ProjectPath
    }
    $script:State.LastSource = $script:State.Source
    Save-SessionSettings
}

function Open-ZeeVAProject {
    param([string]$Path = '', [string]$SourceFolder = '')

    [object[]]$projectTracks = (Invoke-Audacity 'GetInfo: Type=Tracks Format=JSON') | ConvertFrom-Json
    if ($projectTracks.Count -gt 0 -or $script:State.Files.Count -gt 0) {
        throw 'Save and close the current project in Audacity, then restart ZeeVA to open another project. To use the currently open project, click Scan Project.'
    }
    if (-not $Path) {
        $dialog = [Windows.Forms.OpenFileDialog]::new()
        try {
            $dialog.Title = 'Open Audacity project'
            $dialog.Filter = 'Audacity projects (*.aup3)|*.aup3'
            if ($script:State.LastProject) { $dialog.FileName = $script:State.LastProject }
            if ($dialog.ShowDialog($script:Form) -ne 'OK') { return }
            $Path = $dialog.FileName
        }
        finally { $dialog.Dispose() }
    }
    Send-Audacity ('OpenProject2: Filename=' + (Quote-Audacity $path))
    $script:State.ProjectPath = $path
    $script:State.SessionVerified = $false
    Restore-ProjectSession -SourceFolder $SourceFolder
    $script:State.LastProject = $path
    Save-SessionSettings
}

function Get-DroppedFolder {
    param([Windows.Forms.IDataObject]$Data)

    if (-not $Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { return '' }
    $paths = @($Data.GetData([Windows.Forms.DataFormats]::FileDrop))
    if ($paths.Count -ne 1 -or -not (Test-Path -LiteralPath $paths[0] -PathType Container)) { return '' }
    return [string]$paths[0]
}

function Get-DroppedActionPath {
    param([Windows.Forms.IDataObject]$Data, [int]$ActionId)

    if (-not $script:State.TextSourceOnly -or $ActionId -ne 1) {
        return (Get-DroppedFolder $Data)
    }
    if (-not $Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { return '' }
    $paths = @($Data.GetData([Windows.Forms.DataFormats]::FileDrop))
    if ($paths.Count -ne 1 -or -not (Test-Path -LiteralPath $paths[0] -PathType Leaf) -or
        [IO.Path]::GetExtension($paths[0]) -notin @('.txt', '.tsv')) { return '' }
    return [string]$paths[0]
}

function Enable-FolderDrop {
    param([Windows.Forms.Control]$Control, [int]$ActionId)

    $Control.AllowDrop = $true
    $Control.Tag = $ActionId
    $Control.Add_DragEnter({
        param($sender, $eventArgs)
        $eventArgs.Effect = [Windows.Forms.DragDropEffects]::None
        if (-not $script:State.Busy -and -not $script:State.Recording -and
            ($eventArgs.AllowedEffect -band [Windows.Forms.DragDropEffects]::Copy) -and
            (Get-DroppedActionPath $eventArgs.Data ([int]$sender.Tag))) {
            $eventArgs.Effect = [Windows.Forms.DragDropEffects]::Copy
        }
    })
    $Control.Add_DragDrop({
        param($sender, $eventArgs)
        $folder = Get-DroppedActionPath $eventArgs.Data ([int]$sender.Tag)
        if ($folder) { Invoke-Action -Id ([int]$sender.Tag) -Folder $folder }
    })
}

function Enter-SingleInstance {
    $script:InstanceMutex = [Threading.Mutex]::new(
        $false, 'Local\ZeeVA.AudacityPipeClient'
    )

    try {
        $script:OwnsInstanceMutex = $script:InstanceMutex.WaitOne(0)
    }
    catch [Threading.AbandonedMutexException] {
        $script:OwnsInstanceMutex = $true
    }

    if (-not $script:OwnsInstanceMutex) {
        throw 'Another ZeeVA helper is already running. Close it before starting another instance so that only one helper can issue Audacity pipe commands.'
    }
}

function Get-SavedAudacityPath {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { return '' }

    try {
        $settings = Get-Content -LiteralPath $script:ConfigPath -Raw |
            ConvertFrom-Json
        if ($settings.AudacityPath) { return [string]$settings.AudacityPath }
    }
    catch {
        return ''
    }
    return ''
}

function Save-AudacityPath {
    param([Parameter(Mandatory)][string]$Path)

    $directory = Split-Path $script:ConfigPath -Parent
    $null = New-Item -ItemType Directory -Path $directory -Force
    @{ AudacityPath = $Path } | ConvertTo-Json |
        Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
}

function Select-AudacityExecutable {
    $dialog = [Windows.Forms.OpenFileDialog]::new()
    try {
        $dialog.Title = 'Locate Audacity.exe'
        $dialog.Filter = 'Audacity executable (Audacity.exe)|Audacity.exe'
        $dialog.CheckFileExists = $true
        $dialog.Multiselect = $false
        if ($dialog.ShowDialog($script:Form) -eq 'OK') {
            Save-AudacityPath $dialog.FileName
            return $dialog.FileName
        }
    }
    finally {
        $dialog.Dispose()
    }
    return ''
}

function Resolve-AudacityExecutable {
    $candidates = [Collections.Generic.List[string]]::new()
    if ($script:State.AudacityPath) {
        $candidates.Add([string]$script:State.AudacityPath)
    }

    $savedPath = Get-SavedAudacityPath
    if ($savedPath) { $candidates.Add($savedPath) }

    foreach ($registryPath in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\Audacity.exe',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\Audacity.exe',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\Audacity.exe'
    )) {
        try {
            $key = Get-Item -LiteralPath $registryPath -ErrorAction Stop
            $registeredPath = [string]$key.GetValue('')
            if ($registeredPath) { $candidates.Add($registeredPath.Trim('"')) }
        }
        catch {}
    }

    try {
        $command = Get-Command Audacity.exe -ErrorAction Stop
        if ($command.Source) { $candidates.Add([string]$command.Source) }
    }
    catch {}

    foreach ($root in @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        (Join-Path $env:LocalAppData 'Programs')
    )) {
        if ($root) { $candidates.Add((Join-Path $root 'Audacity\Audacity.exe')) }
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $script:State.AudacityPath = [IO.Path]::GetFullPath($candidate)
            return $script:State.AudacityPath
        }
    }

    $selectedPath = Select-AudacityExecutable
    if ($selectedPath) {
        $script:State.AudacityPath = $selectedPath
        return $selectedPath
    }
    throw 'Audacity.exe could not be located. Select Audacity.exe to continue.'
}

function Get-AudacityProcesses {
    @(Get-Process -Name Audacity -ErrorAction SilentlyContinue)
}

function Set-RetainedAudacityProcess {
    param([Parameter(Mandatory)][Diagnostics.Process]$Process)

    $previousProcess = $script:State.AudacityProcess
    if ($previousProcess -and
        -not [object]::ReferenceEquals($previousProcess, $Process)) {
        $previousProcess.Dispose()
        $script:State.RecordingCommandsVerified = $false
    }

    $Process.Refresh()
    $script:State.AudacityProcess = $Process
    $script:State.AudacityProcessId = $Process.Id
    $script:State.AudacityWindowHandle = $Process.MainWindowHandle
}

function Get-RetainedAudacityProcess {
    if ($script:State.AudacityProcessId -le 0 -or
        -not $script:State.AudacityProcess) {
        return $null
    }

    try {
        $process = $script:State.AudacityProcess
        if ($process.HasExited -or $process.Id -ne $script:State.AudacityProcessId -or
            $process.ProcessName -ine 'Audacity') {
            return $null
        }
        Set-RetainedAudacityProcess $process
        return $process
    }
    catch {
        return $null
    }
}

function Wait-TaskResponsive {
    param(
        [Parameter(Mandatory)][Threading.Tasks.Task]$Task,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds,
        [Parameter(Mandatory)][string]$TimeoutMessage
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while (-not $Task.IsCompleted) {
        if ($stopwatch.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
            throw [TimeoutException]::new($TimeoutMessage)
        }
        [Windows.Forms.Application]::DoEvents()
        [Threading.Thread]::Sleep(25)
    }
    $null = $Task.GetAwaiter().GetResult()
}

function Wait-ResponsiveDelay {
    param([Parameter(Mandatory)][int]$Milliseconds)

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.ElapsedMilliseconds -lt $Milliseconds) {
        if ($script:Form -and $script:Form.IsDisposed) {
            throw 'ZeeVA closed while waiting for Audacity.'
        }
        [Windows.Forms.Application]::DoEvents()
        [Threading.Thread]::Sleep(25)
    }
}

function Connect-PipeResponsive {
    param(
        [Parameter(Mandatory)][IO.Pipes.NamedPipeClientStream]$Pipe,
        [Parameter(Mandatory)][string]$PipeName,
        [int]$TimeoutMilliseconds = 8000
    )

    $task = $Pipe.ConnectAsync($TimeoutMilliseconds)
    Wait-TaskResponsive $task ($TimeoutMilliseconds + 500) `
        "Timed out waiting for Audacity's $PipeName scripting pipe."
}

function Set-AudacityDisconnected {
    param(
        [string]$Message = 'Audacity is disconnected.',
        [string]$State = 'Disconnected'
    )

    $script:State.Connected = $false
    $script:State.ConnectionState = $State
    $script:State.ConnectionError = $Message
    if ($script:State.Files.Count -gt 0) {
        $script:State.SessionVerified = $false
    }
}

function Invoke-Audacity {
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [switch]$AllowDisconnected,

        [int]$ResponseTimeoutMilliseconds = 15000,

        [int]$PipeTimeoutMilliseconds = 8000
    )

    if ([Text.Encoding]::UTF8.GetByteCount($Command + "`r`n") -ge 1024) {
        throw 'The Audacity command exceeds ZeeVA''s 1024-byte safety limit and was not sent. Long commands can crash mod-script-pipe.'
    }

    if (-not $AllowDisconnected -and -not $script:State.Connected) {
        throw 'Audacity is not connected. Use Reconnect after resolving the connection status.'
    }

    if (-not (Get-RetainedAudacityProcess)) {
        Set-AudacityDisconnected 'The retained Audacity process is no longer running.'
        throw $script:State.ConnectionError
    }

    $send = $null
    $receive = $null
    $writer = $null
    $exchangeCompleted = $false

    $responseText = [Text.StringBuilder]::new()
    try {
        $send = [IO.Pipes.NamedPipeClientStream]::new(
            '.',
            'ToSrvPipe',
            [IO.Pipes.PipeDirection]::Out,
            [IO.Pipes.PipeOptions]::Asynchronous
        )
        $receive = [IO.Pipes.NamedPipeClientStream]::new(
            '.',
            'FromSrvPipe',
            [IO.Pipes.PipeDirection]::In,
            [IO.Pipes.PipeOptions]::Asynchronous
        )

        Connect-PipeResponsive $send 'ToSrvPipe' $PipeTimeoutMilliseconds
        Connect-PipeResponsive $receive 'FromSrvPipe' $PipeTimeoutMilliseconds

        $encoding = [Text.UTF8Encoding]::new($false)
        $decoder = $encoding.GetDecoder()

        $writer = [IO.StreamWriter]::new($send, $encoding)
        $writer.AutoFlush = $true
        $writer.Write("$Command`r`n`0")

        $byteBuffer = [byte[]]::new(4096)
        $charBuffer = [char[]]::new(
            $encoding.GetMaxCharCount($byteBuffer.Length)
        )

        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $terminalMatch = $null

        while ($true) {
            $remaining = $ResponseTimeoutMilliseconds -
                [int]$stopwatch.ElapsedMilliseconds

            if ($remaining -le 0) {
                throw [TimeoutException]::new(
                    "Audacity response timed out: $Command"
                )
            }

            $readTask = $receive.ReadAsync(
                $byteBuffer,
                0,
                $byteBuffer.Length
            )

            Wait-TaskResponsive $readTask $remaining `
                "Audacity response timed out: $Command"

            $bytesRead = $readTask.GetAwaiter().GetResult()

            if ($bytesRead -eq 0) {
                throw 'Audacity closed its response pipe before completing the command.'
            }

            $charactersRead = $decoder.GetChars(
                $byteBuffer,
                0,
                $bytesRead,
                $charBuffer,
                0,
                $false
            )

            $null = $responseText.Append(
                $charBuffer,
                0,
                $charactersRead
            )

            $text = $responseText.ToString()

            $terminalMatch = [regex]::Match(
                $text,
                '(?m)(?:^|[\r\n\x00])[\x00 \t]*BatchCommand finished:[ \t]*OK(?=[\r\n\x00]|$)'
            )

            if ($terminalMatch.Success) {
                $exchangeCompleted = $true
                break
            }

            $terminalMatch = [regex]::Match(
                $text,
                '(?m)(?:^|[\r\n\x00])[\x00 \t]*BatchCommand finished:[^\r\n\x00]*(?=[\r\n\x00])'
            )

            if ($terminalMatch.Success) {
                $exchangeCompleted = $true
                throw "Audacity rejected the command: $Command`n$text"
            }

            $terminalMatch = [regex]::Match(
                $text,
                '(?m)(?:^|[\r\n\x00])[\x00 \t]*BatchCommand finished:[ \t]*Failed!(?=[\r\n\x00]|$)'
            )

            if ($terminalMatch.Success) {
                $exchangeCompleted = $true
                throw "Audacity rejected the command: $Command`n$text"
            }
        }

        $payload = $responseText.ToString().Substring(
            0,
            $terminalMatch.Index
        )

        return $payload.Trim(
            [char[]]@(
                [char]0,
                [char]0xFEFF,
                [char]13,
                [char]10,
                [char]32,
                [char]9
            )
        )
    }
    catch {
        $message = $_.Exception.Message

        if (-not $exchangeCompleted) {
            $message += "`nCommand: $($Command.Split(':')[0])"
            $received = $responseText.ToString()

            if ($received.Length -eq 0) {
                $received = '<no response bytes received>'
            }
            else {
                $received = $received.Replace(
                    [string][char]0,
                    '<NUL>'
                ).Replace("`r", '<CR>').Replace("`n", "<LF>`n")
            }

            $message += "`n`nReceived from Audacity:`n$received"

            Set-AudacityDisconnected $message 'Connection error'
        }

        throw $message
    }
    finally {
        if ($writer)  { $writer.Dispose() }
        if ($send)    { $send.Dispose() }
        if ($receive) { $receive.Dispose() }
    }
}

function Send-Audacity {
    param([string]$Command)
    $null = Invoke-Audacity $Command
}

function Get-AudacityTracks {
    $payload = Invoke-Audacity 'GetInfo: Type=Tracks Format=JSON'
    $parsed = $payload | ConvertFrom-Json

    $projectIndex = 0
    foreach ($track in $parsed) {
        if ($null -eq $track) {
            $projectIndex++
            continue
        }

        $properties = $track.PSObject.Properties
        if ($properties['kind'] -and $track.kind -ceq 'wave' -and
            $properties['name'] -and $properties['start'] -and
            $properties['end']) {
            [pscustomobject]@{
                Index    = $projectIndex
                Name     = [string]$track.name
                Start    = [double]$track.start
                End      = [double]$track.end
                Channels = [int]$track.channels
            }
        }
        $projectIndex++
    }
}

function Quote-Audacity {
    param([string]$Text)
    if ($Text -match '["\r\n]') {
        throw 'A path or name contains an unsupported quote or newline.'
    }
    '"' + $Text + '"'
}

function Format-Time {
    param([double]$Value)
    $Value.ToString('0.#########', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-CurrentFile {
    if ($script:State.Files.Count -eq 0) {
        throw 'Open a speaker folder first.'
    }
    $script:State.Files[$script:State.Index]
}

function Find-AudioTrack {
    param([string]$Name)

    $tracks = @(Get-AudacityTracks)
    for ($i = 0; $i -lt $tracks.Count; $i++) {
        if ($tracks[$i].name -ceq $Name) {
            return [pscustomobject]@{
                Index = [int]$tracks[$i].Index
                Start = [double]$tracks[$i].start
                End   = [double]$tracks[$i].end
                Channels = [int]$tracks[$i].Channels
            }
        }
    }
    throw "Track not found: $Name"
}

function Assert-AudacityRecordingCommands {
    if ($script:State.RecordingCommandsVerified) { return }

    foreach ($commandName in @(
        'GetPreference',
        'SetTrackStatus'
    )) {
        $definition = Invoke-Audacity (
            'Help: Command={0} Format=JSON' -f $commandName
        )
        if ($definition -match '(?i)Command not found' -or
            [string]::IsNullOrWhiteSpace($definition)) {
            throw "This Audacity version does not expose the required scripting command: $commandName."
        }
    }

    $script:State.RecordingCommandsVerified = $true
}

function Get-AudacityAppendRecordCommand {
    Assert-AudacityRecordingCommands

    try {
        $value = Invoke-Audacity (
            'GetPreference: Name=' +
            (Quote-Audacity '/GUI/PreferNewTrackRecord')
        )
    }
    catch {
        if (-not $script:State.Connected -or
            $_.Exception.Message -notmatch 'Audacity rejected the command') {
            throw
        }
        # Audacity's default is false when this preference has not been saved.
        $value = '0'
    }

    switch ($value.Trim().Trim('"').ToLowerInvariant()) {
        { $_ -in @('0', 'false') } { return 'Record1stChoice:' }
        { $_ -in @('1', 'true') }  { return 'Record2ndChoice:' }
        default {
            throw "Audacity returned an unexpected value for /GUI/PreferNewTrackRecord: $value"
        }
    }
}

function Select-AudioTrack {
    param(
        [int]$Index,
        [double]$Start,
        [double]$End
    )

    Send-Audacity (
        'Select: Track={0} TrackCount=1 Start={1} End={2}' -f
        $Index, (Format-Time $Start), (Format-Time $End)
    )
}

function Isolate-AudioTrack {
    param([string]$Name)

    Send-Audacity 'SelectAll:'
    Send-Audacity 'SetTrackAudio: Mute=1 Solo=0'

    $track = Find-AudioTrack $Name
    Select-AudioTrack $track.Index $track.Start $track.End
    Send-Audacity 'SetTrackAudio: Mute=0 Solo=0'
    return $track
}

function Remove-AudacityTrackIfPresent {
    param([string]$Name)

    if (-not $Name) { return }

    try {
        $track = Find-AudioTrack $Name
    }
    catch {
        if ($_.Exception.Message -eq "Track not found: $Name") { return }
        throw
    }

    Select-AudioTrack $track.Index $track.Start $track.End
    Send-Audacity 'RemoveTracks:'
}

function Focus-Audacity {
    $process = Get-RetainedAudacityProcess
    if (-not $process) {
        Set-AudacityDisconnected 'The retained Audacity process exited. Use Reconnect.'
        throw $script:State.ConnectionError
    }

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($process.MainWindowHandle -eq [IntPtr]::Zero -and
        $stopwatch.ElapsedMilliseconds -lt 3000) {
        [Windows.Forms.Application]::DoEvents()
        $null = $process.WaitForInputIdle(100)
        $process.Refresh()
    }

    $script:State.AudacityWindowHandle = $process.MainWindowHandle
    if ($script:State.AudacityWindowHandle -eq [IntPtr]::Zero) {
        throw "Audacity PID $($process.Id) does not currently have a usable window."
    }
    $null = [ZeeVA.ControlForm]::SetForegroundWindow(
        $script:State.AudacityWindowHandle
    )
}

function Choose-Folder {
    param([string]$Description)

    $dialog = [Windows.Forms.FolderBrowserDialog]::new()
    try {
        $dialog.Description = $Description
        $dialog.ShowNewFolderButton = $true
        if ($script:State.LastSource -and (Test-Path -LiteralPath $script:State.LastSource -PathType Container)) {
            $dialog.SelectedPath = $script:State.LastSource
        }
        if ($dialog.ShowDialog($script:Form) -eq 'OK') {
            return $dialog.SelectedPath
        }
    }
    finally {
        $dialog.Dispose()
    }
}

function Confirm-DiscardCandidate {
    if (-not $script:State.Candidate) { return $true }

    $answer = [Windows.Forms.MessageBox]::Show(
        $script:Form,
        'This take has not been accepted. Leave it unaccepted and continue? ' +
        'Its audio will remain in the project.',
        'Unaccepted take',
        [Windows.Forms.MessageBoxButtons]::YesNo
    )
    return ($answer -eq 'Yes')
}

function Get-ExistingProjectAction {
    param([string]$Path)

    $dialog = [Windows.Forms.Form]::new()
    try {
        $dialog.Text = 'Existing ZeeVA project'
        $dialog.ClientSize = [Drawing.Size]::new(580, 185)
        $dialog.FormBorderStyle = 'FixedDialog'
        $dialog.StartPosition = 'CenterParent'
        $dialog.MinimizeBox = $false
        $dialog.MaximizeBox = $false
        $message = [Windows.Forms.Label]::new()
        $message.SetBounds(16, 16, 548, 110)
        $message.Text = "A project already exists:`r`n$Path`r`n`r`nResume it, or replace it with a fresh import. Overwrite keeps a backup of the previous project."
        $dialog.Controls.Add($message)
        $buttonIndex = 0
        foreach ($choice in @(
            @{Text='Open and Resume'; Result='Yes'},
            @{Text='Overwrite'; Result='No'},
            @{Text='Cancel'; Result='Cancel'}
        )) {
            $button = [Windows.Forms.Button]::new()
            $button.Text = $choice.Text
            $button.DialogResult = $choice.Result
            $button.SetBounds((16 + $buttonIndex * 184), 140, 176, 30)
            $dialog.Controls.Add($button)
            if ($buttonIndex -eq 0) { $dialog.AcceptButton = $button }
            if ($choice.Result -eq 'Cancel') { $dialog.CancelButton = $button }
            $buttonIndex++
        }
        switch ($dialog.ShowDialog($script:Form)) {
            'Yes' { return 'Resume' }
            'No' { return 'Overwrite' }
            default { return 'Cancel' }
        }
    }
    finally { $dialog.Dispose() }
}

function Get-SpeakerFileBlocks {
    param([object[]]$Files, [int]$BlockSize = $script:SpeakerBlockSize)

    if ($BlockSize -lt 1) { throw 'The speaker block size must be at least 1.' }
    for ($offset = 0; $offset -lt $Files.Count; $offset += $BlockSize) {
        $last = [Math]::Min($offset + $BlockSize, $Files.Count) - 1
        [pscustomobject]@{
            Number = [int]($offset / $BlockSize) + 1
            Files  = @($Files[$offset..$last])
        }
    }
}

function Get-SpeakerBlockProjectPath {
    param([string]$Folder, [int]$Block)

    Join-Path (Split-Path $Folder -Parent) (
        '{0}_Block{1}.aup3' -f (Split-Path $Folder -Leaf), $Block)
}

function Format-SpeakerBlockChoice {
    param([object]$Block, [bool]$ProjectExists)

    $firstOrdinal = ($Block.Number - 1) * $script:SpeakerBlockSize + 1
    $suffix = if ($ProjectExists) { ' | project exists' } else { '' }
    'Block {0} | files {1}-{2} | {3} - {4}{5}' -f
        $Block.Number, $firstOrdinal,
        ($firstOrdinal + $Block.Files.Count - 1),
        $Block.Files[0].Name, $Block.Files[-1].Name, $suffix
}

function Choose-SpeakerBlock {
    param([string]$Folder, [object[]]$Blocks, [int]$TotalFiles)

    $dialog = [Windows.Forms.Form]::new()
    try {
        $dialog.Text = 'Choose a recording block'
        $dialog.ClientSize = [Drawing.Size]::new(580, 168)
        $dialog.FormBorderStyle = 'FixedDialog'
        $dialog.StartPosition = 'CenterParent'
        $dialog.MinimizeBox = $false
        $dialog.MaximizeBox = $false
        $message = [Windows.Forms.Label]::new()
        $message.SetBounds(16, 12, 548, 52)
        $message.Text = $(if ($script:State.TextSourceOnly) {
            'The selected voice type contains {0} script lines. Audacity scripting addresses at most {1} tracks per project, so ZeeVA records in blocks of {2} lines, each saved as its own project.'
        } else {
            'The folder contains {0} WAVs. Audacity scripting addresses at most {1} tracks per project, so ZeeVA records in blocks of {2} files, each saved as its own project.'
        }) -f
            $TotalFiles, ($script:AudacityMaxTrackIndex + 1), $script:SpeakerBlockSize
        $dialog.Controls.Add($message)
        $combo = [Windows.Forms.ComboBox]::new()
        $combo.DropDownStyle = 'DropDownList'
        $combo.SetBounds(16, 72, 548, 24)
        $defaultIndex = -1
        foreach ($block in $Blocks) {
            $exists = Test-Path -LiteralPath (
                Get-SpeakerBlockProjectPath -Folder $Folder -Block $block.Number)
            if (-not $exists -and $defaultIndex -lt 0) { $defaultIndex = $block.Number - 1 }
            $null = $combo.Items.Add((Format-SpeakerBlockChoice -Block $block -ProjectExists $exists))
        }
        $combo.SelectedIndex = if ($defaultIndex -ge 0) { $defaultIndex } else { 0 }
        $dialog.Controls.Add($combo)
        $buttonIndex = 0
        foreach ($choice in @(
            @{Text='Open Block'; Result='OK'},
            @{Text='Cancel'; Result='Cancel'}
        )) {
            $button = [Windows.Forms.Button]::new()
            $button.Text = $choice.Text
            $button.DialogResult = $choice.Result
            $button.SetBounds((16 + $buttonIndex * 196), 120, 176, 30)
            $dialog.Controls.Add($button)
            if ($choice.Result -eq 'OK') { $dialog.AcceptButton = $button }
            else { $dialog.CancelButton = $button }
            $buttonIndex++
        }
        if ($dialog.ShowDialog($script:Form) -eq 'OK') {
            return $Blocks[$combo.SelectedIndex].Number
        }
    }
    finally { $dialog.Dispose() }
}

function Open-SpeakerFolder {
    param([string]$Folder = '')

    if ($script:State.Files.Count -gt 0) {
        throw 'For another speaker, save this Audacity project and restart the helper with an empty project.'
    }

    $tracks = @(Get-AudacityTracks)
    if ($tracks.Count -gt 0) {
        throw 'Start with one empty Audacity project open.'
    }

    if (-not $folder) { $folder = Choose-Folder 'Select the speaker folder containing source WAVs' }
    if (-not $folder) { return }
    $folder = (Get-Item -LiteralPath $folder -ErrorAction Stop).FullName.TrimEnd('\')

    $files = @(Get-ChildItem -LiteralPath $folder -File -Filter '*.wav' |
        Sort-Object Name)

    if ($files.Count -eq 0) { throw 'That folder contains no WAV files.' }

    $projectPath = Join-Path (Split-Path $folder -Parent) ((Split-Path $folder -Leaf) + '.aup3')
    if ($files.Count -gt $script:SpeakerBlockSize) {
        $blocks = @(Get-SpeakerFileBlocks -Files $files)
        $blockNumber = Choose-SpeakerBlock -Folder $folder -Blocks $blocks -TotalFiles $files.Count
        if (-not $blockNumber) { return }
        $files = @($blocks[$blockNumber - 1].Files)
        $projectPath = Get-SpeakerBlockProjectPath -Folder $folder -Block $blockNumber
    }

    $overwrite = $false
    if (Test-Path -LiteralPath $projectPath) {
        switch (Get-ExistingProjectAction -Path $projectPath) {
            'Resume' {
                Open-ZeeVAProject -Path $projectPath -SourceFolder $folder
                return
            }
            'Overwrite' { $overwrite = $true }
            default { return }
        }
    }

    # Import originals end to end, retaining an individual named track per file.
    $position = 0.0
    $importIndex = 0
    foreach ($file in $files) {
        $importIndex++
        $script:Status.Text = '{0} | Importing {1} of {2}' -f
            $file.Name, $importIndex, $files.Count
        $script:Form.Refresh()

        Send-Audacity ('Import2: Filename=' + (Quote-Audacity $file.FullName))

        $tracks = @(Get-AudacityTracks)
        $track = $tracks[$tracks.Count - 1]
        $index = [int]$track.Index
        $duration = [double]$track.end - [double]$track.start
        $name = 'SRC|' + $file.BaseName

        Select-AudioTrack $index ([double]$track.start) ([double]$track.end)
        Send-Audacity ('SetTrackStatus: Name=' + (Quote-Audacity $name))
        Send-Audacity (
            'SetClip: At={0} Start={1}' -f
            (Format-Time (([double]$track.start + [double]$track.end) / 2)),
            (Format-Time $position)
        )
        Send-Audacity 'SetTrackAudio: Mute=1 Solo=0'
        $script:State.Originals[$file.Name] = $name
        $position += $duration + 0.5
    }

    Send-Audacity 'SetProject: Rate=44100'
    $script:State.Source = $folder
    $script:State.Files = $files
    $script:State.Index = 0
    $script:State.LastSource = $folder
    $script:State.SessionDirty = $true

    $first = Find-AudioTrack $script:State.Originals[$files[0].Name]
    Select-AudioTrack $first.Index $first.Start $first.End
    Send-Audacity 'ZoomSel:'
    Save-ZeeVAProject -Path $projectPath -Overwrite:$overwrite
}

function Play-NamedTrack {
    param([string]$Name)

    Send-Audacity 'Stop:'
    $null = Isolate-AudioTrack $Name
    Focus-Audacity
    Send-Audacity 'Play:'
}

function Assert-AudacityTrackBudget {
    [object[]]$projectTracks = (Invoke-Audacity 'GetInfo: Type=Tracks Format=JSON') | ConvertFrom-Json
    $count = $projectTracks.Count
    if ($count -gt $script:AudacityMaxTrackIndex) {
        throw ('This project already has {0} tracks; Audacity scripting cannot address tracks beyond index {1}, so a new take cannot be placed. Export the accepted takes, then record the remaining lines in the next block or a new project.' -f
            $count, $script:AudacityMaxTrackIndex)
    }
    if ($count -ge $script:AudacityTrackWarnThreshold) {
        Set-StatusMessage ('The project uses {0} of {1} scriptable tracks; about {2} more takes fit. Export this block and continue in the next one soon.' -f
            $count, ($script:AudacityMaxTrackIndex + 1),
            ($script:AudacityMaxTrackIndex + 1 - $count)) -IsError
    }
}

function Start-Take {
    $file = Get-CurrentFile
    Send-Audacity 'Stop:'
    Assert-AudacityRecordingCommands
    Assert-AudacityTrackBudget

    $tracks = @(Get-AudacityTracks)

    # Place new takes after existing audio, with no fixed duration limit.
    $end = 0.0
    foreach ($track in $tracks) {
        $end = [Math]::Max($end, [double]$track.end)
    }
    $start = $end + 1.0

    if ($tracks.Count) {
        Send-Audacity 'SelectAll:'
        Send-Audacity 'SetTrackAudio: Mute=1 Solo=0'
    }
    Send-Audacity 'SelectNone:'
    Send-Audacity 'SetProject: Rate=44100'

    $targetName = 'RECORDING|' + $file.BaseName + '|' +
        [Guid]::NewGuid().ToString('N')
    $script:State.RecordingTargetName = $targetName
    $script:State.RecordingStart = $start

    try {
        Send-Audacity 'NewStereoTrack:'
        Send-Audacity ('SetTrackStatus: Name=' + (Quote-Audacity $targetName))

        $target = Find-AudioTrack $targetName
        if ($target.Channels -ne 2) {
            throw 'Audacity did not create the required stereo recording target.'
        }

        Send-Audacity 'SelectNone:'
        Select-AudioTrack $target.Index $start $start
        Send-Audacity 'SetTrackAudio: Mute=0 Solo=0'

        $recordCommand = Get-AudacityAppendRecordCommand
        Focus-Audacity
        Send-Audacity $recordCommand

        $script:State.Recording = $true
        $script:State.SessionDirty = $true
    }
    catch {
        try { Send-Audacity 'Stop:' } catch {}
        $script:State.Recording = $false
        $script:State.RecordingTargetName = $null
        $script:State.RecordingStart = 0.0
        try { Remove-AudacityTrackIfPresent $targetName } catch {}
        throw
    }
}

function Stop-Take {
    $targetName = [string]$script:State.RecordingTargetName
    if (-not $targetName) {
        throw 'The active recording target is unknown. Stop and inspect Audacity before continuing.'
    }

    try {
        Send-Audacity 'Stop:'
    }
    finally {
        $script:State.Recording = $false
    }

    try {
        $target = Find-AudioTrack $targetName
        if ($target.Channels -ne 2) {
            throw 'The recording target is no longer stereo.'
        }
        if ($target.End -le $target.Start -or
            $target.End -le $script:State.RecordingStart) {
            throw 'The recording target contains no audio.'
        }

        $file = Get-CurrentFile
        $name = 'TAKE|' + $file.BaseName + '|' +
            [Guid]::NewGuid().ToString('N')

        Select-AudioTrack $target.Index $target.Start $target.End
        Send-Audacity ('SetTrackStatus: Name=' + (Quote-Audacity $name))
        Send-Audacity 'ZoomSel:'

        $script:State.Candidate = $name
        $script:State.Candidates[$file.Name] = $name
        $script:State.Recorded[$file.Name] = @($script:State.Recorded[$file.Name] | Where-Object { $_ }) + @($name)
        $script:State.SessionDirty = $true
    }
    finally {
        $script:State.RecordingTargetName = $null
        $script:State.RecordingStart = 0.0
    }
    if ($script:State.ProjectPath) { Save-ZeeVAProject }
    else { Save-ProjectBookkeeping }
}

function Get-LineCandidate {
    $file = Get-CurrentFile
    if ($script:State.Candidate) { return $script:State.Candidate }
    $remembered = $script:State.Candidates[$file.Name]
    if ($remembered -and $remembered -cin $script:State.Recorded[$file.Name] -and
        $remembered -cne $script:State.Accepted[$file.Name]) { return $remembered }
    if ($script:State.Accepted.ContainsKey($file.Name)) { return $null }
    $takes = @($script:State.Recorded[$file.Name] | Where-Object { $_ })
    if ($takes.Count -eq 1) { return $takes[0] }
    return $null
}

function Show-TakeSelection {
    if ($script:State.Busy -or $script:State.Recording -or $script:State.Files.Count -eq 0) { return }
    $file = Get-CurrentFile
    $takes = @($script:State.Recorded[$file.Name] | Where-Object { $_ })
    if ($takes.Count -eq 0) { Set-StatusMessage 'There are no recorded takes for this line.'; return }
    if ($script:TakeMenu) { $script:TakeMenu.Dispose() }
    $script:TakeMenu = [Windows.Forms.ContextMenuStrip]::new()
    foreach ($index in 0..($takes.Count - 1)) {
        $name = $takes[$index]
        $item = [Windows.Forms.ToolStripMenuItem]::new(('Take {0} | {1}' -f ($index + 1), $name))
        $item.Tag = [pscustomobject]@{FileName=$file.Name; Take=$name}
        $item.Add_Click({
            param($menuItem, $eventArgs)
            if ($script:State.Busy -or $script:State.Recording -or
                (Get-CurrentFile).Name -cne $menuItem.Tag.FileName) { return }
            $script:State.Candidate = $menuItem.Tag.Take
            $script:State.Candidates[$menuItem.Tag.FileName] = $menuItem.Tag.Take
            $script:State.SessionDirty = $true
            Update-Display
        })
        $script:TakeMenu.Items.Add($item) | Out-Null
    }
    $script:TakeMenu.Show($script:Form, [Drawing.Point]::new(12, $script:Form.ClientSize.Height - 28))
}

function Get-AcceptanceLabelTrackIndex {
    [object[]]$tracks = (Invoke-Audacity 'GetInfo: Type=Tracks Format=JSON') | ConvertFrom-Json
    $indices = @(
        for ($index = 0; $index -lt $tracks.Count; $index++) {
            if ($tracks[$index].name -ceq 'ZeeVA Regions') { $index }
        }
    )
    if ($indices.Count -gt 1) { throw 'The project contains multiple ZeeVA Regions tracks.' }
    if ($indices.Count -eq 1) {
        if ($tracks[$indices[0]].kind -cne 'label') { throw 'ZeeVA Regions must be a label track.' }
        return $indices[0]
    }
    Send-Audacity 'NewLabelTrack:'
    Send-Audacity ('SelectTracks: Track={0} TrackCount=1 Mode=Set' -f $tracks.Count)
    Assert-SelectedLabelTrack $tracks.Count
    Send-Audacity ('SetTrackStatus: Name=' + (Quote-Audacity 'ZeeVA Regions'))
    return $tracks.Count
}

function Accept-Take {
    $file = Get-CurrentFile
    $candidate = Get-LineCandidate
    if (-not $candidate) {
        throw 'Record a take first, or select an unambiguous recorded take for this line.'
    }

    $track = Find-AudioTrack $candidate
    Select-AudioTrack $track.Index $track.Start $track.End

    [object[]]$projectTracks = (Invoke-Audacity 'GetInfo: Type=Tracks Format=JSON') | ConvertFrom-Json
    $metadataIndices = @(
        for ($index = 0; $index -lt $projectTracks.Count; $index++) {
            if (([string]$projectTracks[$index].name).StartsWith($script:SessionTrackPrefix)) { $index }
        }
    )
    $labels = @(Get-AudacityLabels)
    $existing = @($labels | Where-Object { $_.Text -ceq $file.BaseName -and $_.Track -notin $metadataIndices })
    if ($existing.Count -gt 1) { throw "Multiple acceptance labels exist for $($file.Name). Resolve the duplicate regions before accepting." }
    $labelIndex = -1
    if ($existing.Count -eq 1) { $labelIndex = $existing[0].Index }
    foreach ($label in $labels | Where-Object { $_.Text -ceq $file.BaseName -and $_.Track -in $metadataIndices }) {
        Send-Audacity ('SetLabel: Label={0} Text=""' -f $label.Index)
    }

    if ($labelIndex -lt 0) {
        $regionTrack = Get-AcceptanceLabelTrackIndex
        Select-AudioTrack $regionTrack $track.Start $track.End
        Send-Audacity 'SetTrackStatus: Focused=1'
        Send-Audacity 'AddLabel:'
        $labels = @(Get-AudacityLabels)
        $created = @($labels | Where-Object {
            $_.Track -eq $regionTrack -and [string]::IsNullOrEmpty($_.Text) -and
            [Math]::Abs($_.Start - $track.Start) -lt 0.001 -and
            [Math]::Abs($_.End - $track.End) -lt 0.001
        })
        if ($created.Count -ne 1) { throw 'Could not identify the new acceptance label on ZeeVA Regions.' }
        $labelIndex = $created[0].Index
    }

    Send-Audacity (
        'SetLabel: Label={0} Text={1} Start={2} End={3}' -f
        $labelIndex, (Quote-Audacity $file.BaseName),
        (Format-Time $track.Start), (Format-Time $track.End)
    )

    $script:State.Accepted[$file.Name] = $candidate
    $script:State.Exported.Remove($file.Name)
    $script:State.Candidates.Remove($file.Name)
    $script:State.Candidate = $null
    $script:State.SessionDirty = $true

    if ($script:State.Index -lt $script:State.Files.Count - 1) {
        $script:State.Index++
        $script:State.Candidate = Get-LineCandidate
        if ($script:State.TextSourceOnly) { Select-TextLineTrack }
        else {
            $nextFile = Get-CurrentFile
            $nextTrack = Find-AudioTrack $script:State.Originals[$nextFile.Name]
            Select-AudioTrack $nextTrack.Index $nextTrack.Start $nextTrack.End
            Send-Audacity 'ZoomSel:'
        }
    }
    if ($script:State.ProjectPath) { Save-ZeeVAProject }
    else { Save-ProjectBookkeeping }
}

function Copy-WavBytes {
    param([IO.BinaryReader]$Reader, [IO.BinaryWriter]$Writer, [long]$Count)

    $buffer = [byte[]]::new(65536)
    while ($Count -gt 0) {
        $read = $Reader.Read($buffer, 0, [int][Math]::Min($Count, $buffer.Length))
        if ($read -eq 0) { throw 'The WAV contains a truncated chunk.' }
        $Writer.Write($buffer, 0, $read)
        $Count -= $read
    }
}

function Set-WavTranscript {
    param([string]$Path, [string]$Transcript)

    if (-not $Transcript) { return }
    Assert-ExportFormat $Path
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.metadata'
    $reader = $null
    $writer = $null
    try {
        $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($Path))
        $writer = [IO.BinaryWriter]::new([IO.File]::Create($temporary))
        $null = $reader.ReadBytes(4)
        $riffEnd = [long]$reader.ReadUInt32() + 8
        if ($riffEnd -ne $reader.BaseStream.Length) { throw 'The WAV RIFF length does not match its file size.' }
        $null = $reader.ReadBytes(4)
        $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'))
        $writer.Write([uint32]0)
        $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVE'))
        while ($reader.BaseStream.Position + 8 -le $riffEnd) {
            $id = $reader.ReadBytes(4)
            $size = $reader.ReadUInt32()
            $start = $reader.BaseStream.Position
            $end = $start + $size
            $next = $end + ($size % 2)
            if ($next -gt $riffEnd) { throw 'The WAV contains a truncated chunk.' }
            $isInfo = $false
            if ([Text.Encoding]::ASCII.GetString($id) -eq 'LIST' -and $size -ge 4) {
                $isInfo = [Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -eq 'INFO'
            }
            $writer.Write($id)
            if ($isInfo) {
                $sizePosition = $writer.BaseStream.Position
                $writer.Write([uint32]0)
                $infoStart = $writer.BaseStream.Position
                $writer.Write([Text.Encoding]::ASCII.GetBytes('INFO'))
                while ($reader.BaseStream.Position + 8 -le $end) {
                    $fieldId = $reader.ReadBytes(4)
                    $fieldSize = $reader.ReadUInt32()
                    $fieldLength = [long]$fieldSize + ($fieldSize % 2)
                    if ($reader.BaseStream.Position + $fieldLength -gt $end) {
                        throw 'The WAV contains a truncated INFO field.'
                    }
                    if ([Text.Encoding]::ASCII.GetString($fieldId) -eq 'ICMT') {
                        $reader.BaseStream.Position += $fieldLength
                    }
                    else {
                        $writer.Write($fieldId)
                        $writer.Write($fieldSize)
                        Copy-WavBytes $reader $writer $fieldLength
                    }
                }
                if ($reader.BaseStream.Position -ne $end) { throw 'The WAV INFO list contains incomplete metadata.' }
                $infoEnd = $writer.BaseStream.Position
                $writer.BaseStream.Position = $sizePosition
                $writer.Write([uint32]($infoEnd - $infoStart))
                $writer.BaseStream.Position = $infoEnd
                $reader.BaseStream.Position = $next
            }
            else {
                $writer.Write($size)
                $reader.BaseStream.Position = $start
                Copy-WavBytes $reader $writer ([long]$size + ($size % 2))
            }
        }
        if ($reader.BaseStream.Position -ne $riffEnd) { throw 'The WAV contains an incomplete chunk header.' }
        $comment = [Text.Encoding]::UTF8.GetBytes($Transcript + [char]0)
        $padding = $comment.Length % 2
        $writer.Write([Text.Encoding]::ASCII.GetBytes('LIST'))
        $writer.Write([uint32](12 + $comment.Length + $padding))
        $writer.Write([Text.Encoding]::ASCII.GetBytes('INFOICMT'))
        $writer.Write([uint32]$comment.Length)
        $writer.Write($comment)
        if ($padding) { $writer.Write([byte]0) }
        $length = $writer.BaseStream.Length - 8
        if ($length -gt [uint32]::MaxValue) { throw 'Transcript metadata exceeds the RIFF WAV size limit.' }
        $writer.BaseStream.Position = 4
        $writer.Write([uint32]$length)
        $writer.Dispose()
        $writer = $null
        $reader.Dispose()
        $reader = $null
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    }
    finally {
        if ($writer) { $writer.Dispose() }
        if ($reader) { $reader.Dispose() }
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Assert-ExportFormat {
    param([string]$Path)

    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($Path))
    try {
        if ([Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -ne 'RIFF') {
            throw 'Export is not a RIFF WAV.'
        }
        $null = $reader.ReadUInt32()
        if ([Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -ne 'WAVE') {
            throw 'Export is not a WAV.'
        }

        while ($reader.BaseStream.Position + 8 -le $reader.BaseStream.Length) {
            $id = [Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
            $size = $reader.ReadUInt32()
            $next = $reader.BaseStream.Position + $size + ($size % 2)

            if ($id -eq 'fmt ') {
                $format = $reader.ReadUInt16()
                $channels = $reader.ReadUInt16()
                $rate = $reader.ReadUInt32()
                $null = $reader.ReadUInt32()
                $null = $reader.ReadUInt16()
                $bits = $reader.ReadUInt16()

                if ($format -ne 1 -or $channels -ne 2 -or
                    $rate -ne 44100 -or $bits -ne 16) {
                    throw "Export was format=$format, channels=$channels, rate=$rate, bits=$bits. Set Audacity's WAV export to signed 16-bit PCM at 44100 Hz, then retry."
                }
                return
            }

            $reader.BaseStream.Position = $next
        }
        throw 'WAV format header was not found.'
    }
    finally {
        $reader.Dispose()
    }
}

function Export-SpeakerFolder {
    $null = Get-CurrentFile
    Sync-AudacitySession
    if ($script:State.Accepted.Count -eq 0) {
        throw 'No takes have been accepted yet.'
    }

    $speaker = Get-SessionVoiceType
    $destination = Join-Path $script:State.OutputRoot $speaker

    if (-not $script:State.TextSourceOnly -and
        [IO.Path]::GetFullPath($destination).TrimEnd('\') -ieq
        [IO.Path]::GetFullPath($script:State.Source).TrimEnd('\')) {
        throw 'Choose an output root that does not overwrite the source folder.'
    }

    $null = New-Item -ItemType Directory -Path $destination -Force

    $existing = @($script:State.Accepted.Keys | Where-Object {
        Test-Path -LiteralPath (Join-Path $destination $_)
    })

    if ($existing.Count -gt 0) {
        $answer = [Windows.Forms.MessageBox]::Show(
            $script:Form,
            "Replace $($existing.Count) existing output WAV(s)?",
            'Export folder',
            [Windows.Forms.MessageBoxButtons]::YesNo
        )
        if ($answer -ne 'Yes') { return }
    }

    Send-Audacity 'Stop:'
    Send-Audacity 'SetProject: Rate=44100'
    $exported = 0
    $transcriptsWritten = 0

    foreach ($file in $script:State.Files) {
        if (-not $script:State.Accepted.ContainsKey($file.Name)) { continue }

        $track = Isolate-AudioTrack $script:State.Accepted[$file.Name]
        $labels = @(Get-AudacityLabels)
        $matching = @($labels | Where-Object { $_.Text -ceq $file.BaseName })
        if ($matching.Count -ne 1) {
            throw "Expected exactly one region label for $($file.Name)."
        }

        if (-not (Test-LabelWithinTake $matching[0] $track)) {
            throw "The label region for $($file.Name) extends outside its take."
        }
        $start = [Math]::Max($matching[0].Start, $track.Start)
        $end = [Math]::Min($matching[0].End, $track.End)

        Select-AudioTrack $track.Index $start $end
        $temporary = Join-Path $destination (
            'ZeeVA-' + [Guid]::NewGuid().ToString('N') + '.wav'
        )

        try {
            Send-Audacity (
                'Export2: Filename={0} NumChannels=2' -f
                (Quote-Audacity $temporary)
            )
            Assert-ExportFormat $temporary
            $dialogue = Get-DialogueRow $file
            if ($dialogue -and $dialogue.'RESPONSE TEXT') {
                Set-WavTranscript -Path $temporary -Transcript $dialogue.'RESPONSE TEXT'
                Assert-ExportFormat $temporary
                $transcriptsWritten++
            }

            Move-Item -LiteralPath $temporary `
                -Destination (Join-Path $destination $file.Name) -Force -ErrorAction Stop
            $outputPath = Join-Path $destination $file.Name
            $script:State.Exported.Remove($file.Name)
            $script:State.SessionDirty = $true
            $script:State.Exported[$file.Name] = [pscustomobject]@{
                Take = $script:State.Accepted[$file.Name]
                Path = $outputPath
                Start = $start
                End = $end
                Hash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256 -ErrorAction Stop).Hash
            }
            $exported++
        }
        finally {
            if (Test-Path -LiteralPath $temporary) {
                Remove-Item -LiteralPath $temporary
            }
        }
    }

    Set-StatusMessage "Exported $exported WAVs; $transcriptsWritten with transcripts. Skipped $($script:State.Files.Count - $exported) unaccepted lines. $destination"
}

function Test-LabelWithinTake {
    param($Region, $Take)

    if ($Take.Channels -ne 2 -or $Take.End -le $Take.Start -or
        $Region.End -le $Region.Start -or $Region.Start -ge $Take.End -or $Region.End -le $Take.Start) {
        return $false
    }
    # Audacity's JSON transport reports times with six significant digits.
    $magnitude = [Math]::Max(1.0, [Math]::Max([Math]::Abs($Take.Start), [Math]::Abs($Take.End)))
    $tolerance = [Math]::Max(1.0 / 44100.0, [Math]::Pow(10.0, [Math]::Floor([Math]::Log10($magnitude)) - 5.0))
    return ($Region.Start -ge $Take.Start - $tolerance -and $Region.End -le $Take.End + $tolerance)
}

function Assert-AudacitySession {
    if ($script:State.Files.Count -eq 0) { return }
    if ($script:State.TextSourceOnly) { Assert-TextProjectIdentity }

    $tracks = @(Get-AudacityTracks)
    $trackNames = @($tracks | ForEach-Object { [string]$_.name })
    $requiredTracks = @($script:State.Originals.Values) +
        @($script:State.Accepted.Values)
    if ($script:State.Candidate) {
        $requiredTracks += [string]$script:State.Candidate
    }

    foreach ($trackName in @($requiredTracks | Select-Object -Unique)) {
        if (@($trackNames | Where-Object { $_ -ceq $trackName }).Count -ne 1) {
            throw "The connected Audacity project does not contain exactly one expected track named '$trackName'. Open the correct saved project, then reconnect."
        }
    }

    $labels = @(Get-AudacityLabels)
    foreach ($fileName in $script:State.Accepted.Keys) {
        $baseName = [IO.Path]::GetFileNameWithoutExtension($fileName)
        $matching = @($labels | Where-Object { $_.Text -ceq $baseName })
        if ($matching.Count -ne 1) {
            throw "The saved acceptance for '$baseName' has $($matching.Count) filename labels; expected one. Reconnect to reconcile the session, then use Review Take and explicitly accept the intended take again."
        }
        $track = Find-AudioTrack $script:State.Accepted[$fileName]
        if (-not (Test-LabelWithinTake $matching[0] $track)) {
            throw "The accepted region for $fileName is outside its stereo take."
        }
    }
}

function Connect-Audacity {
    $script:State.ConnectionState = 'Connecting'
    $script:State.ConnectionError = ''
    $script:State.Connected = $false
    Update-Display
    [Windows.Forms.Application]::DoEvents()

    try {
        $launchedAudacity = $false
        $processes = @(Get-AudacityProcesses)
        if ($processes.Count -gt 1) {
            $processList = ($processes | ForEach-Object { $_.Id }) -join ', '
            foreach ($process in $processes) { $process.Dispose() }
            throw "Multiple Audacity processes are running (PIDs: $processList). Audacity's scripting pipes are not PID-specific, so ZeeVA cannot safely bind them to one process. Close the extra Audacity processes, then click Reconnect."
        }

        if ($processes.Count -eq 1) {
            Set-RetainedAudacityProcess $processes[0]
        }
        else {
            $executable = Resolve-AudacityExecutable
            $script:State.ConnectionState = 'Starting'
            Update-Display
            [Windows.Forms.Application]::DoEvents()
            $process = Start-Process -FilePath $executable -PassThru -ErrorAction Stop
            Set-RetainedAudacityProcess $process
            $launchedAudacity = $true
            $script:State.ConnectionState = 'Connecting'
            Update-Display
        }

        try {
            if ($launchedAudacity) {
                $readinessTimeout = 30000
                $readinessStopwatch = [Diagnostics.Stopwatch]::StartNew()
                $lastReadinessError = $null

                Wait-ResponsiveDelay 1500

                while ($readinessStopwatch.ElapsedMilliseconds -lt
                    $readinessTimeout) {
                    try {
                        $script:State.ConnectionState = 'Connecting'
                        $script:State.ConnectionError = ''
                        Update-Display

                        $trackJson = Invoke-Audacity `
                            'GetInfo: Type=Tracks Format=JSON' `
                            -AllowDisconnected `
                            -ResponseTimeoutMilliseconds 3000 `
                            -PipeTimeoutMilliseconds 1500
                        $null = $trackJson | ConvertFrom-Json
                        $lastReadinessError = $null
                        break
                    }
                    catch {
                        $lastReadinessError = $_.Exception
                        if (-not (Get-RetainedAudacityProcess)) {
                            throw 'Audacity exited while ZeeVA was waiting for scripting to become ready.'
                        }
                        Wait-ResponsiveDelay 500
                    }
                }

                if ($lastReadinessError) {
                    throw "Audacity scripting did not become ready within $([int]($readinessTimeout / 1000)) seconds.`n`n$($lastReadinessError.Message)"
                }
            }
            else {
                $trackJson = Invoke-Audacity `
                    'GetInfo: Type=Tracks Format=JSON' -AllowDisconnected
                $null = $trackJson | ConvertFrom-Json
            }
        }
        catch {
            $pidText = $script:State.AudacityProcessId
            throw "Audacity PID $pidText is running, but its scripting pipes did not complete a GetInfo exchange. Ensure Audacity's mod-script-pipe module is installed and enabled, restart Audacity if you changed that setting, then click Reconnect. ZeeVA does not change Audacity preferences automatically.`n`n$($_.Exception.Message)"
        }

        $script:State.Connected = $true
        $script:State.ConnectionState = 'Connected'
        $script:State.ConnectionError = ''
        $script:State.SessionVerified = $false

        try {
            if ($script:State.Files.Count -eq 0) {
                [object[]]$projectTracks = $trackJson | ConvertFrom-Json
                if (Get-ProjectSessionData $projectTracks) {
                    Restore-ProjectSession -Quiet
                }
            }
            Sync-AudacitySession
            Assert-AudacitySession
            $script:State.SessionVerified = $true
            $script:State.InterruptedRecording = $false
        }
        catch {
            $script:State.ConnectionError = 'Session unverified: ' +
                $_.Exception.Message
            throw
        }
    }
    catch {
        if (-not $script:State.Connected) {
            Set-AudacityDisconnected $_.Exception.Message 'Connection error'
        }
        elseif (-not $script:State.SessionVerified) {
            $script:State.ConnectionState = 'Connected'
        }
        throw
    }
    finally {
        Update-Display
    }
}

function Invoke-Reconnect {
    if ($script:State.Busy) { return }
    if ($script:State.Recording) {
        Set-StatusMessage 'Stop the current recording before reconnecting.' -IsError
        return
    }

    $script:State.Busy = $true
    try {
        Connect-Audacity
    }
    catch {
        Set-StatusMessage $_.Exception.Message -IsError
    }
    finally {
        $script:State.Busy = $false
        Update-Display
    }
}

function Test-AudacityProcessState {
    if ($script:State.AudacityProcessId -le 0) { return }
    if (([DateTime]::UtcNow - $script:State.LastProcessCheck).TotalSeconds -lt 1) {
        return
    }
    $script:State.LastProcessCheck = [DateTime]::UtcNow

    $retainedProcess = Get-RetainedAudacityProcess
    if (-not $retainedProcess) {
        if ($script:State.Recording) {
            $script:State.Recording = $false
            $script:State.InterruptedRecording = $true
        }
        Set-AudacityDisconnected `
            "Audacity PID $($script:State.AudacityProcessId) exited. Bookkeeping was preserved; open the correct project and click Reconnect."
        Update-Display
        return
    }

    if ($script:State.Connected) {
        $processes = @(Get-AudacityProcesses)
        try {
            if ($processes.Count -ne 1 -or
                $processes[0].Id -ne $script:State.AudacityProcessId) {
                Set-AudacityDisconnected `
                    'The Audacity process set became ambiguous. Close extra Audacity processes and click Reconnect.' `
                    'Connection error'
                Update-Display
            }
        }
        finally {
            foreach ($process in $processes) { $process.Dispose() }
        }
    }
}

function Update-Display {
    Update-ScriptDisplay
    $loaded = $script:State.Files.Count -gt 0
    $audioReady = $script:State.Connected -and
        (-not $loaded -or $script:State.SessionVerified)
    $projectName = if ($script:State.ProjectPath) {
        [IO.Path]::GetFileName($script:State.ProjectPath)
    } elseif ($loaded) {
        Split-Path $script:State.Source -Leaf
    } else { 'Audacity Recording Helper' }
    $dirty = if ($script:State.SessionDirty) { ' *' } else { '' }
    $script:Form.Text = $(if ($script:State.TextSourceOnly) { 'ZeeVA Text Only - ' } else { 'ZeeVA - ' }) + $projectName + $dirty

    if ($loaded) {
        $file = Get-CurrentFile
        $stateText = if ($script:State.Recording) {
            'RECORDING'
        } elseif ($script:State.Candidate) {
            'New take - not accepted'
        } elseif ($script:State.Accepted.ContainsKey($file.Name)) {
            if ($script:State.Exported.ContainsKey($file.Name)) { 'Exported' }
            else { 'Accepted - not exported' }
        } elseif ($script:State.Recorded.ContainsKey($file.Name) -and
            $script:State.Recorded[$file.Name].Count -gt 0) {
            'Recorded - not accepted'
        } else {
            'Not recorded'
        }

        $script:Status.Text = '{0} | {1} of {2} | {3}' -f
            $file.Name, ($script:State.Index + 1),
            $script:State.Files.Count, $stateText
    }
    else {
        $script:Status.Text = if ($script:State.TextSourceOnly) { 'No active script line' } else { 'No active WAV' }
    }
    if ($script:State.ProjectProgress) { $script:Status.Text = $script:State.ProjectProgress }

    if ($script:SourcePathLabel) {
        $sourceText = if ($loaded) {
            if ($script:State.TextSourceOnly) {
                $script:State.DialogueExportPath + ' | ' + $script:State.VoiceType
            } else { $script:State.Source }
        } else {
            if ($script:State.TextSourceOnly) { 'Open or drop a Starfield script (.txt / .tsv)' }
            else { 'No source folder selected' }
        }
        $script:SourcePathLabel.Text = $sourceText
        $script:ActionToolTip.SetToolTip(
            $script:SourcePathLabel, $sourceText
        )
    }

    if ($script:OutputPathLabel) {
        $outputDestination = if ($loaded) {
            Join-Path $script:State.OutputRoot (
                Get-SessionVoiceType
            )
        } else {
            $script:State.OutputRoot
        }
        $script:OutputPathLabel.Text = $outputDestination
        $script:ActionToolTip.SetToolTip(
            $script:OutputPathLabel, $outputDestination
        )
    }

    $script:RecordButton.Text = if ($script:State.Recording) {
        'Stop Recording'
    } else {
        'Record / Stop'
    }

    $lineCandidate = if ($loaded) { Get-LineCandidate } else { $null }
    if ($script:TakeSelectionStatus) {
        $script:TakeSelectionStatus.Visible = $loaded -and
            @($script:State.Recorded[(Get-CurrentFile).Name]).Count -gt 1
        $script:TakeSelectionStatus.Enabled = $audioReady -and -not $script:State.Busy -and
            -not $script:State.Recording
    }
    $hasTake = $loaded -and (
        $lineCandidate -or
        $script:State.Accepted.ContainsKey((Get-CurrentFile).Name)
    )
    $script:ListenTakeButton.Enabled = $audioReady -and $hasTake -and
        -not $script:State.Recording
    $script:AcceptButton.Enabled = (
        $audioReady -and $null -ne $lineCandidate -and
        -not $script:State.Recording
    )

    if ($script:ActionButtons) {
        $script:ActionButtons[1].Enabled = $audioReady -and -not $script:State.Busy -and
            -not $script:State.Recording -and
            ($script:State.TextSourceOnly -or -not $loaded)
        $script:ActionButtons[2].Enabled = $audioReady -and $loaded -and
            $script:State.Accepted.Count -gt 0 -and -not $script:State.Recording
        $script:ActionButtons[3].Enabled = -not $script:State.Recording
        $script:ActionButtons[4].Enabled = $script:State.TextSourceOnly -or
            ($audioReady -and $loaded -and -not $script:State.Recording)
        $script:ActionButtons[7].Enabled = $audioReady
        $script:ActionButtons[8].Enabled = $audioReady -and $loaded -and
            -not $script:State.Recording
        $script:ActionButtons[9].Enabled = $audioReady -and $loaded -and
            -not $script:State.Recording
        $script:ActionButtons[10].Enabled = $audioReady -and $loaded -and
            -not $script:State.Recording
        $script:ActionButtons[11].Enabled = $audioReady -and
            $loaded -and -not $script:State.Recording
        $script:ActionButtons[12].Enabled = $script:State.Connected -and
            -not $script:State.Recording
        $script:ActionButtons[13].Enabled = $script:State.Connected -and
            -not $script:State.Recording
    }

    if ($script:SpeakerStatus) {
        $script:SpeakerStatus.Text = if ($loaded) {
            $recordedCount = @($script:State.Recorded.Keys | Where-Object {
                @($script:State.Recorded[$_]).Count -gt 0
            }).Count
            '{0} lines | {1} recorded | {2} accepted | {3} exported' -f
                $script:State.Files.Count, $recordedCount,
                $script:State.Accepted.Count, $script:State.Exported.Count
        } else {
            if ($script:State.TextSourceOnly) { 'No script loaded' } else { 'No speaker folder loaded' }
        }
    }

    if ($script:ConnectionStatus) {
        $connectionText = if ($script:State.AudacityProcessId -gt 0) {
            'Audacity.exe | PID {0} | {1}' -f
                $script:State.AudacityProcessId,
                $script:State.ConnectionState
        } else {
            'Audacity.exe | {0}' -f $script:State.ConnectionState
        }
        if ($script:State.Connected -and -not $script:State.SessionVerified) {
            $connectionText += ' | Session unverified'
        }
        $script:ConnectionStatus.Text = $connectionText
        $script:ConnectionStatus.ToolTipText = $script:State.ConnectionError
        $script:ConnectionStatus.ForeColor = if (
            $script:State.Connected -and $script:State.SessionVerified
        ) {
            [Drawing.Color]::DarkGreen
        } elseif ($script:State.ConnectionState -in @('Starting', 'Connecting')) {
            [Drawing.Color]::DarkGoldenrod
        } else {
            [Drawing.Color]::Firebrick
        }
    }

    if ($script:ReconnectStatus) {
        $script:ReconnectStatus.Enabled = -not $script:State.Busy -and
            -not $script:State.Recording
    }
}

function Set-StatusMessage {
    param([string]$Message, [switch]$IsError, [switch]$IsWarning)

    if ($IsWarning) { $Message = 'Warning: ' + $Message }
    $script:FeedbackLabel.Text = $Message -replace '[\r\n]+', ' '
    $script:FeedbackLabel.BackColor = if ($IsWarning) {
        [Drawing.Color]::LightGoldenrodYellow
    } else { [Drawing.SystemColors]::Control }
    $script:FeedbackLabel.ForeColor = if ($IsWarning) {
        [Drawing.Color]::Black
    } elseif ($IsError) {
        [Drawing.Color]::Firebrick
    } else {
        [Drawing.Color]::DarkGreen
    }
    if ($script:ActionToolTip) {
        $script:ActionToolTip.SetToolTip($script:FeedbackLabel, $Message)
    }
}

function Invoke-Action {
    param([int]$Id, [string]$Folder = '')

    if ($script:State.Busy) { return }
    $previousSource = $script:State.Source
    $actionCompleted = $false
    $script:State.Busy = $true
    Set-StatusMessage ''

    try {
        if (($Id -ne 3 -and -not $script:State.Connected) -or
            ($Id -notin @(3, 12, 13) -and $script:State.Files.Count -gt 0 -and
                -not $script:State.SessionVerified)) {
            throw 'Audacity controls are unavailable. Resolve the connection status and click Reconnect.'
        }

        if ($script:State.Recording -and $Id -ne 7) {
            throw 'Stop recording before using another action.'
        }

        switch ($Id) {
            1 {
                if ($script:State.TextSourceOnly) { Open-TextDialogue -Path $Folder; break }
                [object[]]$projectTracks = (Invoke-Audacity 'GetInfo: Type=Tracks Format=JSON') | ConvertFrom-Json
                if ($Folder -and $projectTracks.Count -gt 0 -and $script:State.Files.Count -eq 0) {
                    Restore-ProjectSession -SourceFolder $Folder
                    Save-SessionSettings
                }
                else { Open-SpeakerFolder -Folder $Folder }
            }
            2 { Export-SpeakerFolder }
            3 {
                if (-not $folder) {
                    $folder = Choose-Folder 'Select output root; speaker subfolder is added automatically'
                }
                if ($folder) {
                    $script:State.OutputRoot = (Get-Item -LiteralPath $folder -ErrorAction Stop).FullName
                    $script:State.Exported = @{}
                    $script:State.SessionDirty = $script:State.Files.Count -gt 0
                    Save-SessionSettings
                }
            }
            4 {
                if ($script:State.TextSourceOnly) { Show-ScriptWindow }
                else {
                    $file = Get-CurrentFile
                    Play-NamedTrack $script:State.Originals[$file.Name]
                }
            }
            5 {
                $file = Get-CurrentFile
                $name = Get-LineCandidate
                if (-not $name) { $name = $script:State.Accepted[$file.Name] }
                if (-not $name) { throw 'There is no take for this line yet.' }
                Play-NamedTrack $name
            }
            6 { Accept-Take }
            7 {
                if ($script:State.Recording) { Stop-Take }
                elseif (Confirm-DiscardCandidate) { Start-Take }
            }
            8 {
                $null = Get-CurrentFile
                Start-Take
            }
            { $_ -in 9, 10 } {
                $null = Get-CurrentFile
                if (Confirm-DiscardCandidate) {
                    if ($script:State.Candidate) {
                        $script:State.Candidates[(Get-CurrentFile).Name] = $script:State.Candidate
                    }
                    Send-Audacity 'Stop:'
                    $step = if ($Id -eq 9) { -1 } else { 1 }
                    $script:State.Index = [Math]::Max(
                        0, [Math]::Min(
                            $script:State.Files.Count - 1,
                            $script:State.Index + $step
                        )
                    )
                    $script:State.Candidate = $null
                    $script:State.Candidate = Get-LineCandidate
                    $script:State.SessionDirty = $true

                    if ($script:State.TextSourceOnly) { Select-TextLineTrack }
                    else {
                        $file = Get-CurrentFile
                        $name = $script:State.Accepted[$file.Name]
                        if (-not $name) { $name = $script:State.Originals[$file.Name] }
                        $track = Find-AudioTrack $name
                        Select-AudioTrack $track.Index $track.Start $track.End
                        Send-Audacity 'ZoomSel:'
                    }
                }
            }
            11 { Save-ZeeVAProject }
            12 { Open-ZeeVAProject }
            13 {
                if ($script:State.SessionDirty) {
                    throw 'Save the current session before rescanning, so its current line and take status are not discarded.'
                }
                Restore-ProjectSession
                Save-SessionSettings
            }
        }
        $actionCompleted = $true
    }
    catch {
        Set-StatusMessage $_.Exception.Message -IsError `
            -IsWarning:($_.FullyQualifiedErrorId -like 'ZeeVAMetadataSelection*')
    }
    finally {
        $script:State.Busy = $false
        Update-Display
        if ($actionCompleted -and $Id -in @(1, 12, 13) -and
            $script:State.Files.Count -gt 0 -and $script:State.Source -ine $previousSource) {
            if ($script:State.TextSourceOnly) { Show-ScriptWindow }
            else { Open-DialogueExport -Automatic }
        }
    }
}

try {
    Enter-SingleInstance
    Read-SessionSettings
}
catch {
    [Windows.Forms.MessageBox]::Show(
        $_.Exception.Message, 'ZeeVA',
        [Windows.Forms.MessageBoxButtons]::OK,
        [Windows.Forms.MessageBoxIcon]::Exclamation
    ) | Out-Null
    if ($script:InstanceMutex) { $script:InstanceMutex.Dispose() }
    return
}

$script:Form = [ZeeVA.ControlForm]::new()
$script:Form.Text = 'ZeeVA - Audacity Recording Helper'
$script:Form.Size = [Drawing.Size]::new(966, 669)
$script:Form.MinimumSize = [Drawing.Size]::new(760, 540)
$script:Form.StartPosition = 'CenterScreen'
$script:Form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi
$script:Form.Font = [Drawing.Font]::new('Segoe UI', 10)
if ($script:State.TextSourceOnly) { Enable-FolderDrop $script:Form 1 }

$script:ActionDefinitions = @(
    [pscustomobject]@{ Id = 1;  Text = 'Open Folder';        Shortcut = 'Ctrl+Shift+F1';  Area = 'Keypad';     Column = 0; Row = 0; Modifiers = 0x4006; Key = 112 }
    [pscustomobject]@{ Id = 2;  Text = 'Export Folder';      Shortcut = 'Ctrl+Shift+F2';  Area = 'Keypad';     Column = 1; Row = 0; Modifiers = 0x4006; Key = 113 }
    [pscustomobject]@{ Id = 3;  Text = 'Set Output Folder';  Shortcut = 'Ctrl+Shift+F3';  Area = 'Keypad';     Column = 2; Row = 0; Modifiers = 0x4006; Key = 114 }
    [pscustomobject]@{ Id = 4;  Text = 'Listen Original';    Shortcut = 'Ctrl+Shift+F4'; Area = 'Keypad';     Column = 0; Row = 1; Modifiers = 0x4006; Key = 115 }
    [pscustomobject]@{ Id = 5;  Text = 'Listen Take';        Shortcut = 'Ctrl+Shift+F5';  Area = 'Keypad';     Column = 1; Row = 1; Modifiers = 0x4006; Key = 116 }
    [pscustomobject]@{ Id = 6;  Text = 'Save / Accept Take'; Shortcut = 'Ctrl+Shift+F6';  Area = 'Keypad';     Column = 2; Row = 1; Modifiers = 0x4006; Key = 117 }
    [pscustomobject]@{ Id = 7;  Text = 'Record / Stop';      Shortcut = 'Ctrl+Shift+F7';  Area = 'Keypad';     Column = 0; Row = 2; Modifiers = 0x4006; Key = 118 }
    [pscustomobject]@{ Id = 8;  Text = 'Retake';             Shortcut = 'Ctrl+Shift+F8';  Area = 'Keypad';     Column = 1; Row = 2; Modifiers = 0x4006; Key = 119 }
    [pscustomobject]@{ Id = 11; Text = 'Save Project';       Shortcut = 'Ctrl+Shift+F11'; Area = 'Keypad';     Column = 2; Row = 2; Modifiers = 0x4006; Key = 122 }
    [pscustomobject]@{ Id = 9;  Text = 'Previous';           Shortcut = 'Ctrl+Shift+F9';  Area = 'Navigation'; Column = 1; Row = 0; Modifiers = 0x4006; Key = 120 }
    [pscustomobject]@{ Id = 10; Text = 'Next';               Shortcut = 'Ctrl+Shift+F10'; Area = 'Navigation'; Column = 2; Row = 0; Modifiers = 0x4006; Key = 121 }
    [pscustomobject]@{ Id = 12; Text = 'Open Project';       Shortcut = 'Ctrl+Shift+F12'; Area = 'Navigation'; Column = 0; Row = 0; Modifiers = 0x4006; Key = 123 }
    [pscustomobject]@{ Id = 13; Text = 'Scan Project';       Shortcut = 'Ctrl+Shift+R'; Area = 'Navigation'; Column = 3; Row = 0; Modifiers = 0x4006; Key = 82 }
)
if ($script:State.TextSourceOnly) {
    ($script:ActionDefinitions | Where-Object Id -eq 1).Text = 'Open Script'
    ($script:ActionDefinitions | Where-Object Id -eq 4).Text = 'Show Script'
}

$rootLayout = [Windows.Forms.TableLayoutPanel]::new()
$rootLayout.Dock = 'Fill'
$rootLayout.ColumnCount = 1
$rootLayout.RowCount = 4
$rootLayout.Padding = [Windows.Forms.Padding]::new(18, 14, 18, 10)
$rootLayout.RowStyles.Add(
    [Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 56)
) | Out-Null
$rootLayout.RowStyles.Add(
    [Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100)
) | Out-Null
$rootLayout.RowStyles.Add(
    [Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 76)
) | Out-Null
$rootLayout.RowStyles.Add(
    [Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 42)
) | Out-Null
$script:Form.Controls.Add($rootLayout)

$headerLayout = [Windows.Forms.TableLayoutPanel]::new()
$headerLayout.Dock = 'Fill'
$headerLayout.ColumnCount = 1
$headerLayout.RowCount = 2
$headerLayout.Margin = [Windows.Forms.Padding]::new(0)
$headerLayout.RowStyles.Add(
    [Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 21)
) | Out-Null
$headerLayout.RowStyles.Add(
    [Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100)
) | Out-Null
$rootLayout.Controls.Add($headerLayout, 0, 0)

$headerCaption = [Windows.Forms.Label]::new()
$headerCaption.Dock = 'Fill'
$headerCaption.Text = if ($script:State.TextSourceOnly) { 'Active Script Line' } else { 'Active WAV' }
$headerCaption.ForeColor = [Drawing.SystemColors]::GrayText
$headerCaption.Font = [Drawing.Font]::new('Segoe UI', 9)
$headerLayout.Controls.Add($headerCaption, 0, 0)

$script:Status = [Windows.Forms.Label]::new()
$script:Status.Dock = 'Fill'
$script:Status.AutoEllipsis = $true
$script:Status.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
$script:Status.Font = [Drawing.Font]::new('Segoe UI Semibold', 11)
$headerLayout.Controls.Add($script:Status, 0, 1)

$keypadLayout = [Windows.Forms.TableLayoutPanel]::new()
$keypadLayout.Dock = 'Fill'
$keypadLayout.ColumnCount = 3
$keypadLayout.RowCount = 3
$keypadLayout.Margin = [Windows.Forms.Padding]::new(0, 0, 0, 4)
for ($index = 0; $index -lt 3; $index++) {
    $keypadLayout.ColumnStyles.Add(
        [Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 33.333)
    ) | Out-Null
    $keypadLayout.RowStyles.Add(
        [Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 33.333)
    ) | Out-Null
}
$rootLayout.Controls.Add($keypadLayout, 0, 1)

$navigationLayout = [Windows.Forms.TableLayoutPanel]::new()
$navigationLayout.Dock = 'Fill'
$navigationLayout.ColumnCount = 4
$navigationLayout.RowCount = 1
$navigationLayout.Margin = [Windows.Forms.Padding]::new(0)
$navigationLayout.ColumnStyles.Add(
    [Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 25)
) | Out-Null
$navigationLayout.ColumnStyles.Add(
    [Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 25)
) | Out-Null
$navigationLayout.ColumnStyles.Add(
    [Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 25)
) | Out-Null
$navigationLayout.ColumnStyles.Add(
    [Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 25)
) | Out-Null
$rootLayout.Controls.Add($navigationLayout, 0, 2)

$script:ActionButtons = @{}
$script:ActionToolTip = [Windows.Forms.ToolTip]::new()
$script:ActionToolTip.ShowAlways = $true
foreach ($definition in $script:ActionDefinitions) {
    $button = [Windows.Forms.Button]::new()
    $button.Text = $definition.Text
    $button.Tag = [int]$definition.Id
    $button.Dock = 'Fill'
    $button.Margin = [Windows.Forms.Padding]::new(6)
    $button.Font = [Drawing.Font]::new('Segoe UI Semibold', 11)
    $button.UseVisualStyleBackColor = $true
    $button.Add_Click({ Invoke-Action ([int]$this.Tag) })
    $script:ActionToolTip.SetToolTip(
        $button,
        ('{0} ({1})' -f $definition.Text, $definition.Shortcut)
    )

    if ($definition.Area -eq 'Keypad') {
        $cellLayout = [Windows.Forms.TableLayoutPanel]::new()
        $cellLayout.Dock = 'Fill'
        $cellLayout.ColumnCount = 1
        $cellLayout.RowCount = 2
        $cellLayout.Margin = [Windows.Forms.Padding]::new(0)
        $cellLayout.RowStyles.Add(
            [Windows.Forms.RowStyle]::new(
                [Windows.Forms.SizeType]::Percent, 100
            )
        ) | Out-Null
        $cellLayout.RowStyles.Add(
            [Windows.Forms.RowStyle]::new(
                [Windows.Forms.SizeType]::Absolute, 28
            )
        ) | Out-Null
        $cellLayout.Controls.Add($button, 0, 0)

        $pathLabel = [Windows.Forms.Label]::new()
        $pathLabel.Dock = 'Fill'
        $pathLabel.AutoEllipsis = $true
        $pathLabel.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
        $pathLabel.Font = [Drawing.Font]::new('Segoe UI', 8.5)
        $pathLabel.ForeColor = [Drawing.SystemColors]::GrayText
        $pathLabel.Margin = [Windows.Forms.Padding]::new(8, 0, 8, 2)
        $cellLayout.Controls.Add($pathLabel, 0, 1)

        switch ([int]$definition.Id) {
            1 {
                $script:SourcePathLabel = $pathLabel
                Enable-FolderDrop $button 1
                Enable-FolderDrop $pathLabel 1
                Enable-FolderDrop $cellLayout 1
            }
            3 {
                $script:OutputPathLabel = $pathLabel
                Enable-FolderDrop $button 3
                Enable-FolderDrop $pathLabel 3
                Enable-FolderDrop $cellLayout 3
            }
        }

        $keypadLayout.Controls.Add(
            $cellLayout, [int]$definition.Column, [int]$definition.Row
        )
    }
    else {
        $navigationLayout.Controls.Add(
            $button, [int]$definition.Column, [int]$definition.Row
        )
    }
    $script:ActionButtons[[int]$definition.Id] = $button

    switch ([int]$definition.Id) {
        5 { $script:ListenTakeButton = $button }
        6 { $script:AcceptButton = $button }
        7 { $script:RecordButton = $button }
    }
}

$script:FeedbackLabel = [Windows.Forms.Label]::new()
$script:FeedbackLabel.Dock = 'Fill'
$script:FeedbackLabel.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
$script:FeedbackLabel.AutoEllipsis = $true
$script:FeedbackLabel.Text = ''
$rootLayout.Controls.Add($script:FeedbackLabel, 0, 3)

$script:StatusStrip = [Windows.Forms.StatusStrip]::new()
$script:StatusStrip.SizingGrip = $true

$script:SpeakerStatus = [Windows.Forms.ToolStripStatusLabel]::new()
$script:SpeakerStatus.Spring = $true
$script:SpeakerStatus.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
$script:StatusStrip.Items.Add($script:SpeakerStatus) | Out-Null

$script:TakeSelectionStatus = [Windows.Forms.ToolStripStatusLabel]::new()
$script:TakeSelectionStatus.Text = 'Review Take...'
$script:TakeSelectionStatus.IsLink = $true
$script:TakeSelectionStatus.Add_Click({ Show-TakeSelection })
$script:StatusStrip.Items.Add($script:TakeSelectionStatus) | Out-Null

$script:ScriptStatus = [Windows.Forms.ToolStripStatusLabel]::new()
$script:ScriptStatus.Text = 'Script'
$script:ScriptStatus.IsLink = $true
$script:ScriptStatus.Add_Click({ Show-ScriptWindow })
$script:StatusStrip.Items.Add($script:ScriptStatus) | Out-Null

$script:ConnectionStatus = [Windows.Forms.ToolStripStatusLabel]::new()
$script:ConnectionStatus.TextAlign = [Drawing.ContentAlignment]::MiddleRight
$script:StatusStrip.Items.Add($script:ConnectionStatus) | Out-Null

$script:ReconnectStatus = [Windows.Forms.ToolStripStatusLabel]::new()
$script:ReconnectStatus.Text = 'Reconnect'
$script:ReconnectStatus.IsLink = $true
$script:ReconnectStatus.Add_Click({ Invoke-Reconnect })
$script:StatusStrip.Items.Add($script:ReconnectStatus) | Out-Null
$script:Form.Controls.Add($script:StatusStrip)

$timer = [Windows.Forms.Timer]::new()
$timer.Interval = 100
$timer.Add_Tick({
    Test-AudacityProcessState
    if (-not $script:State.Busy -and $script:Form.Actions.Count -gt 0) {
        Invoke-Action $script:Form.Actions.Dequeue()
    }
})

$script:Form.Add_Shown({
    foreach ($definition in $script:ActionDefinitions) {
        $script:Form.RegisterKey(
            [int]$definition.Id,
            [uint32]$definition.Modifiers,
            [uint32]$definition.Key
        )
    }
    if ($script:Form.FailedKeys.Count -gt 0) {
        $failedShortcuts = @(
            foreach ($failedId in $script:Form.FailedKeys) {
                ($script:ActionDefinitions | Where-Object Id -eq $failedId).Shortcut
            }
        )
        Set-StatusMessage "Some global shortcuts are already in use: $($failedShortcuts -join ', '). The on-screen buttons still work." -IsError
    }
    $timer.Start()
    Invoke-Reconnect
    if ($script:State.TextSourceOnly) {
        if ($script:State.Files.Count) { Show-ScriptWindow }
        elseif ($DialoguePath) { Invoke-Action -Id 1 -Folder $DialoguePath }
    }
    elseif ($script:State.Source -or $script:State.LastSource) {
        Open-DialogueExport -Path $DialoguePath -Automatic
    }
})

$script:Form.Add_FormClosing({
    param($sender, $eventArgs)
    if (-not (Get-RetainedAudacityProcess)) { return }
    if ($script:State.Recording) {
        $eventArgs.Cancel = $true
        return
    }

    if (-not $script:State.SessionDirty) { return }
    $answer = [Windows.Forms.MessageBox]::Show(
        $script:Form,
        'Save audio and session bookkeeping to the Audacity project before closing?',
        'Close ZeeVA',
        [Windows.Forms.MessageBoxButtons]::YesNoCancel
    )
    if ($answer -eq 'Cancel') { $eventArgs.Cancel = $true; return }
    if ($answer -eq 'Yes') {
        try {
            if (-not $script:State.Connected -or -not $script:State.SessionVerified) {
                throw 'Reconnect to the correct Audacity project before saving.'
            }
            Save-ZeeVAProject
        }
        catch {
            $eventArgs.Cancel = $true
            Set-StatusMessage $_.Exception.Message -IsError `
                -IsWarning:($_.FullyQualifiedErrorId -like 'ZeeVAMetadataSelection*')
        }
    }
})

Update-Display
try {
    [Windows.Forms.Application]::Run($script:Form)
}
finally {
    $timer.Stop()
    $timer.Dispose()
    $script:ActionToolTip.Dispose()
    if ($script:ScriptWindow) { $script:ScriptWindow.Dispose() }
    if ($script:TakeMenu) { $script:TakeMenu.Dispose() }
    $script:Form.Dispose()
    if ($script:State.AudacityProcess) {
        $script:State.AudacityProcess.Dispose()
        $script:State.AudacityProcess = $null
    }
    if ($script:InstanceMutex) {
        if ($script:OwnsInstanceMutex) {
            try { $script:InstanceMutex.ReleaseMutex() }
            catch [ApplicationException] {}
        }
        $script:InstanceMutex.Dispose()
    }
}