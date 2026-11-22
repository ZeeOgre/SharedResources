param(
    [ValidateSet('ZeeVA.ps1', 'ZeeVA_TextOnly.ps1')]
    [string]$SourceFile = 'ZeeVA.ps1'
)

$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path $PSScriptRoot $SourceFile
$tokens = $null
$parseErrors = $null
$syntax = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$source = Get-Content -LiteralPath $sourcePath -Raw
$stateStatement = $syntax.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$script:State'
}
$stateInitializer = [scriptblock]::Create($stateStatement.Extent.Text)
. ([scriptblock]::Create($source.Substring(0, $stateStatement.Extent.StartOffset)))
foreach ($definition in $syntax.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] }) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:SessionTrackPrefix = 'ZeeVA Session|'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ZeeVA-test-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$script:TestsPassed = 0

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-TestCase {
    param([string]$Name, [scriptblock]$Body)
    $TextSourceOnly = $false
    . $stateInitializer
    $script:State.Source = $testRoot
    $script:State.OutputRoot = Join-Path $testRoot 'Output'
    $script:State.Files = @([IO.FileInfo]::new((Join-Path $testRoot 'line.wav')))
    $script:State.Originals = @{'line.wav' = 'SRC|line'}
    $script:FeedbackLabel = [pscustomobject]@{Text=''; ForeColor=$null}
    $script:DialogueRows = @()
    $script:MockTracks = @(
        [pscustomobject]@{Index=0; Name='SRC|line'; Start=0.0; End=1.0; Channels=2},
        [pscustomobject]@{Index=1; Name='TAKE|line|one'; Start=2.0; End=3.0; Channels=2}
    )
    $script:MockLabelJson = '[[2,[[2,3,"line"]]],[3,[]]]'
    function Get-AudacityTracks { $script:MockTracks }
    function Choose-Folder { throw 'Unexpected folder prompt in an isolated test.' }
    function Invoke-Audacity {
        param([string]$Command)
        if ($Command -like '*Type=Labels*') { return $script:MockLabelJson }
        if ($Command -like '*Type=Tracks*') { return ($script:MockTracks | ConvertTo-Json -Depth 5 -Compress) }
        throw "Unexpected Audacity command: $Command"
    }
    & $Body
    $script:TestsPassed++
    Write-Output "PASS: $Name"
}

try {
    if ($SourceFile -eq 'ZeeVA_TextOnly.ps1') {
        Invoke-TestCase 'Standalone entry point defaults to text-only without loading another script' {
            . ([scriptblock]::Create($source.Substring(0, $stateStatement.Extent.StartOffset)))
            . $stateInitializer
            Assert-Test $script:State.TextSourceOnly 'Standalone entry point did not initialize text-only mode.'
            Assert-Test ($syntax.ParamBlock.Parameters.Name.VariablePath.UserPath -notcontains 'TextSourceOnly') 'Standalone entry point exposes the WAV-source mode switch.'
            $scriptLoads = @($syntax.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                    $node.InvocationOperator -in @(
                        [Management.Automation.Language.TokenKind]::Ampersand,
                        [Management.Automation.Language.TokenKind]::Dot
                    )
            }, $true))
            Assert-Test ($scriptLoads.Count -eq 0) 'Standalone implementation invokes or dot-sources another script.'
        }

        Invoke-TestCase 'Filename voice selection and bookkeeping exclude other voices and blocks' {
            $script:State.TextSourceOnly = $true
            $path = Join-Path $testRoot 'dialogueExport_TestVT2.txt'
            $rows = @(
                [pscustomobject]@{FILENAME='before'; 'RESPONSE TEXT'='Other voice'; 'VOICE TYPE'='TestVT'},
                [pscustomobject]@{FILENAME='line'; 'RESPONSE TEXT'='Selected'; 'VOICE TYPE'='TestVT2'},
                [pscustomobject]@{FILENAME='later'; 'RESPONSE TEXT'='Another block'; 'VOICE TYPE'='TestVT2'}
            )
            $voice = Select-TextVoiceType -Rows $rows -Path $path
            Assert-Test ($voice -ceq 'TestVT2') 'Filename voice did not take precedence over alphabetic voice order.'
            Assert-Test ((Get-TextVoiceTypeFromFile -Path 'DIALOGUEEXPORT_testvt2.tsv' -VoiceTypes @('TestVT', 'TestVT2')) -ceq 'TestVT2') 'Filename matching is not case-insensitive or matched a voice-name prefix.'
            Assert-Test (-not (Get-TextVoiceTypeFromFile -Path 'dialogueExport.txt' -VoiceTypes @('TestVT', 'TestVT2'))) 'Unspecified filename voice was guessed.'
            Assert-Test (-not (Get-TextVoiceTypeFromFile -Path 'TestVT_TestVT2.txt' -VoiceTypes @('TestVT', 'TestVT2'))) 'Ambiguous filename voice was guessed.'
            $script:State.VoiceType = $voice
            $script:State.DialogueExportPath = $path
            $script:DialogueRows = $rows
            $snapshot = Get-ProjectSessionData @([pscustomobject]@{name=(Get-SessionTrackName)})
            Assert-Test ($snapshot.DialogueRows.Count -eq 1 -and $snapshot.DialogueRows[0].FILENAME -ceq 'line') 'Session labels contain another voice or another recording block.'
            Assert-Test ($script:DialogueRows.Count -eq 3) 'Filtering stored labels removed live reading context.'
        }
    }

    Invoke-TestCase 'Text-only scripts preserve selected voice order and reject output collisions' {
        $script:State.TextSourceOnly = $true
        $rows = @(
            [pscustomobject]@{FILENAME='context'; 'RESPONSE TEXT'='Other before'; 'VOICE TYPE'='OtherVT'},
            [pscustomobject]@{FILENAME='folder\B.fuz'; 'RESPONSE TEXT'='First selected'; 'VOICE TYPE'='TestVT'},
            [pscustomobject]@{FILENAME='middle'; 'RESPONSE TEXT'='Other in center'; 'VOICE TYPE'='OtherVT'},
            [pscustomobject]@{FILENAME='A'; 'RESPONSE TEXT'='Second selected'; 'VOICE TYPE'='TestVT'}
        )
        $path = Join-Path $testRoot 'text-source.tsv'
        $rows | Export-Csv -LiteralPath $path -Delimiter "`t" -Encoding UTF8 -NoTypeInformation
        $rows = @(Import-DialogueExport $path)
        $data = Get-TextDialogueData -Path $path -Rows $rows -VoiceType 'TestVT'
        Assert-Test (($data.Files.Name -join ',') -ceq 'B.wav,A.wav') 'Text-only filtering reordered lines or included another voice.'
        Assert-Test (-not $data.Files[0].Exists -and -not (Test-Path -LiteralPath $data.Source)) 'Fixture unexpectedly depends on source audio.'
        $script:State.DialogueByFile = $data.ByFile
        $script:DialogueRows = $rows
        Assert-Test ((Get-DialogueRow $data.Files[0]).'RESPONSE TEXT' -ceq 'First selected') 'Text-only lookup did not use the imported row directly.'
        foreach ($badName in @('b.wav', '', 'CON', 'bad|id', 'trailing. .wav')) {
            $badRows = $rows + [pscustomobject]@{FILENAME=$badName; 'RESPONSE TEXT'='Bad'; 'VOICE TYPE'='TestVT'}
            $rejected = $false
            try { Get-TextDialogueData -Path $path -Rows $badRows -VoiceType 'TestVT' | Out-Null }
            catch { $rejected = $true }
            Assert-Test $rejected "Unsafe or colliding output name was accepted: $badName"
        }
    }

    Invoke-TestCase 'Opening text-only scripts creates a project without importing audio' {
        $script:State.TextSourceOnly = $true
        $script:State.Files = @()
        $script:MockTracks = @()
        $path = Join-Path $testRoot 'open-text.tsv'
        @(
            [pscustomobject]@{FILENAME='second'; 'RESPONSE TEXT'='First'; 'VOICE TYPE'='TestVT'},
            [pscustomobject]@{FILENAME='first'; 'RESPONSE TEXT'='Last'; 'VOICE TYPE'='TestVT'},
            [pscustomobject]@{FILENAME='context'; 'RESPONSE TEXT'='Other'; 'VOICE TYPE'='OtherVT'}
        ) | Export-Csv -LiteralPath $path -Delimiter "`t" -Encoding UTF8 -NoTypeInformation
        function Select-TextVoiceType { return 'TestVT' }
        function Send-Audacity { throw 'Text import must not create or import audio.' }
        $script:ReadingWindowShown = $false
        function Update-Display {}
        function Save-ProjectBookkeeping {
            if ($SourceFile -eq 'ZeeVA_TextOnly.ps1') {
                Assert-Test $script:ReadingWindowShown 'Reading window was delayed until after project preparation.'
            }
            $script:OpenedSnapshot = Get-SessionTrackName
        }
        function Save-ZeeVAProject {
            param($Path, [switch]$BookkeepingPrepared)
            if ($SourceFile -eq 'ZeeVA_TextOnly.ps1') {
                Assert-Test ([bool]$BookkeepingPrepared) 'Initial save would repeat all bookkeeping labels.'
            }
            $script:SavedTextProject = $Path
        }
        function Show-ScriptWindow { $script:ReadingWindowShown = $true }
        Open-TextDialogue -Path $path
        Assert-Test (($script:State.Files.Name -join ',') -ceq 'second.wav,first.wav' -and $script:State.Originals.Count -eq 0) 'Opening text did not establish a filtered audio-free session.'
        Assert-Test ($script:SavedTextProject -ceq (Join-Path $testRoot 'open-text_TestVT.aup3')) 'Text-only project name is not script-specific and voice-specific.'
        $snapshot = Get-ProjectSessionData @([pscustomobject]@{name=$script:OpenedSnapshot})
        $expectedRows = if ($SourceFile -eq 'ZeeVA_TextOnly.ps1') { 2 } else { 3 }
        Assert-Test ($snapshot.TextSourceOnly -and $snapshot.VoiceType -ceq 'TestVT' -and $snapshot.DialogueRows.Count -eq $expectedRows) 'Project bookkeeping lost voice selection or stored unwanted rows.'
    }

    Invoke-TestCase 'Text-only loading prefers filtered exports and prompts for missing files' {
        $script:State.TextSourceOnly = $true
        $script:State.Files = @()
        $script:MockTracks = @()
        $standard = Join-Path $testRoot 'prefer-text.tsv'
        $filtered = Join-Path $testRoot 'prefer-text_filtered.txt'
        @([pscustomobject]@{FILENAME='standard'; 'RESPONSE TEXT'='Original'; 'VOICE TYPE'='TestVT'}) |
            Export-Csv -LiteralPath $standard -Delimiter "`t" -Encoding UTF8 -NoTypeInformation
        @([pscustomobject]@{FILENAME='filtered'; 'RESPONSE TEXT'='Filtered'; 'VOICE TYPE'='TestVT'}) |
            Export-Csv -LiteralPath $filtered -Delimiter "`t" -Encoding UTF8 -NoTypeInformation
        function Save-SessionSettings {}
        function Save-ProjectBookkeeping {}
        function Save-ZeeVAProject {}
        function Show-ScriptWindow {}
        function Update-Display {}
        function Send-Audacity { throw 'Text import must not import audio.' }
        function Select-DialogueExportFile { throw 'Existing export unexpectedly opened a picker.' }
        Open-TextDialogue -Path $standard
        Assert-Test ($script:State.DialogueExportPath -ceq $filtered -and $script:State.Files[0].Name -ceq 'filtered.wav') 'Text loader did not prefer the filtered sibling.'
        Remove-Item -LiteralPath $filtered
        $script:State.Files = @()
        Open-TextDialogue -Path $filtered
        Assert-Test ($script:State.DialogueExportPath -ceq $standard -and $script:State.Files[0].Name -ceq 'standard.wav') 'Missing filtered export did not fall back to the original TSV.'
        $script:State.Files = @()
        $script:PickerCalls = 0
        function Select-DialogueExportFile {
            param($InitialDirectory, $VoiceType)
            $script:PickerCalls++
            Assert-Test ($InitialDirectory -ceq $testRoot) 'Missing export picker started in the wrong directory.'
            return $standard
        }
        Open-TextDialogue -Path (Join-Path $testRoot 'absent.txt')
        Assert-Test ($script:PickerCalls -eq 1 -and $script:State.DialogueExportPath -ceq $standard) 'Missing text export did not prompt and load the chosen file.'
        $script:State.Files = @()
        function Select-DialogueExportFile { return '' }
        Open-TextDialogue -Path (Join-Path $testRoot 'absent.txt')
        Assert-Test ($script:State.Files.Count -eq 0) 'Cancelling a missing export prompt started a session.'
    }

    Invoke-TestCase 'Text-only navigation and acceptance work on lines without source tracks' {
        $script:State.TextSourceOnly = $true
        $script:State.Connected = $true
        $script:State.Originals = @{}
        $script:State.Files += [IO.FileInfo]::new((Join-Path $testRoot 'second.wav'))
        $script:MockTracks = @($script:MockTracks[1])
        $script:State.Recorded['line.wav'] = @('TAKE|line|one')
        $script:State.Candidate = 'TAKE|line|one'
        $script:Commands = [Collections.Generic.List[string]]::new()
        function Send-Audacity { param($Command) $script:Commands.Add($Command) }
        function Save-ProjectBookkeeping {}
        function Update-Display {}
        function Confirm-DiscardCandidate { return $true }
        Accept-Take
        Assert-Test ($script:State.Index -eq 1 -and $script:State.Accepted['line.wav'] -ceq 'TAKE|line|one') 'Acceptance did not advance to an unrecorded script line.'
        Assert-Test ($script:Commands[-1] -ceq 'SelectNone:') 'Advancing to an unrecorded line attempted to select original audio.'
        Invoke-Action -Id 9
        Assert-Test ($script:State.Index -eq 0 -and -not $script:State.Candidate -and $script:Commands[-1] -ceq 'ZoomSel:') 'Previous did not retain acceptance and select the new take.'
        Invoke-Action -Id 10
        Assert-Test ($script:State.Index -eq 1 -and $script:Commands[-1] -ceq 'SelectNone:' -and -not $script:FeedbackLabel.Text) 'Next failed on an unrecorded line.'
    }

    Invoke-TestCase 'Text-only snapshots resume without the script or original WAV folder' {
        $script:State.TextSourceOnly = $true
        $script:State.VoiceType = 'ResumeVT'
        $script:State.DialogueExportPath = Join-Path $testRoot 'missing-script.tsv'
        $script:DialogueRows = @(
            [pscustomobject]@{FILENAME='line'; 'RESPONSE TEXT'='Saved transcript'; 'VOICE TYPE'='ResumeVT'},
            [pscustomobject]@{FILENAME='second'; 'RESPONSE TEXT'='Not recorded'; 'VOICE TYPE'='ResumeVT'}
        )
        $data = Get-TextDialogueData -Path $script:State.DialogueExportPath -Rows $script:DialogueRows -VoiceType 'ResumeVT'
        $script:State.Source = $data.Source
        $script:State.Files = $data.Files
        $script:State.Originals = @{}
        $script:State.Accepted['line.wav'] = 'TAKE|line|one'
        $script:State.Index = 1
        $metadataName = Get-SessionTrackName
        $script:MockTracks = @($script:MockTracks[1]) + @([pscustomobject]@{Index=1; Name=$metadataName; kind='label'})
        $script:DialogueRows = @()
        Restore-ProjectSession -Quiet
        Assert-Test ($script:State.SessionVerified -and $script:State.Index -eq 1 -and $script:State.Accepted.Count -eq 1) 'Text-only resume lost progress without originals.'
        Assert-Test ((Get-DialogueRow $script:State.Files[0]).'RESPONSE TEXT' -ceq 'Saved transcript') 'Resume did not restore the original imported text.'
        $script:MockTracks = @()
        $rejected = $false
        try { Sync-AudacitySession } catch { $rejected = $_.Exception.Message -like '*not this text-only script*' }
        Assert-Test ($rejected -and $script:State.Accepted.Count -eq 1) 'An unrelated empty project silently discarded text-only progress.'
        $script:State.TextSourceOnly = $false
        $script:MockTracks = @([pscustomobject]@{Name=$metadataName; kind='label'})
        $rejected = $false
        try { Restore-ProjectSession -Quiet } catch { $rejected = $_.Exception.Message -like '*different ZeeVA source mode*' }
        Assert-Test $rejected 'The WAV-based helper accepted a text-only project.'
    }

    Invoke-TestCase 'First text-only take records with no audio tracks to mute' {
        $script:State.TextSourceOnly = $true
        $script:State.Originals = @{}
        $script:State.RecordingCommandsVerified = $true
        $script:MockTracks = @()
        $script:Commands = [Collections.Generic.List[string]]::new()
        function Send-Audacity { param($Command) $script:Commands.Add($Command) }
        function Find-AudioTrack { param($Name) [pscustomobject]@{Index=1; Name=$Name; Channels=2} }
        function Invoke-Audacity {
            param($Command)
            if ($Command -like '*Type=Tracks*') { return '[{"name":"ZeeVA Session|test","kind":"label"}]' }
            if ($Command -like 'GetPreference:*') { return '0' }
            throw "Unexpected command: $Command"
        }
        function Focus-Audacity {}
        Start-Take
        Assert-Test ($script:State.Recording -and $script:Commands[-1] -ceq 'Record1stChoice:') 'The first audio-free take did not start.'
        Assert-Test ('SetTrackAudio: Mute=1 Solo=0' -notin $script:Commands -and 'NewStereoTrack:' -in $script:Commands) 'First take tried to mute labels or failed to create stereo audio.'
    }

    Invoke-TestCase 'Text-only drops and script display separate recording voice from context' {
        $script:State.TextSourceOnly = $true
        $script:State.Originals = @{}
        $script:State.VoiceType = 'TestVT'
        $path = Join-Path $testRoot 'context.tsv'
        [IO.File]::WriteAllText($path, 'drop fixture')
        $script:State.DialogueExportPath = $path
        $rows = @(
            [pscustomobject]@{FILENAME='before'; 'RESPONSE TEXT'='Other before'; 'VOICE TYPE'='OtherVT'},
            [pscustomobject]@{FILENAME='line'; 'RESPONSE TEXT'='Only record me'; 'VOICE TYPE'='TestVT'},
            [pscustomobject]@{FILENAME='after'; 'RESPONSE TEXT'='Other after'; 'VOICE TYPE'='OtherVT'}
        )
        $data = Get-TextDialogueData -Path $path -Rows $rows -VoiceType 'TestVT'
        $script:State.Files = $data.Files
        $script:State.Source = $data.Source
        $script:State.DialogueByFile = $data.ByFile
        $script:DialogueRows = $rows
        $drop = [Windows.Forms.DataObject]::new()
        $drop.SetData([Windows.Forms.DataFormats]::FileDrop, [string[]]@($path))
        Assert-Test ((Get-DroppedActionPath $drop 1) -ceq $path -and -not (Get-DroppedActionPath $drop 3)) 'Script drop was rejected or accepted as an output folder.'
        $drop.SetData([Windows.Forms.DataFormats]::FileDrop, [string[]]@($path, $path))
        Assert-Test (-not (Get-DroppedActionPath $drop 1)) 'Multiple script drops were accepted.'
        $drop.SetData([Windows.Forms.DataFormats]::FileDrop, [string[]]@($testRoot))
        Assert-Test (-not (Get-DroppedActionPath $drop 1) -and (Get-DroppedActionPath $drop 3) -ceq $testRoot) 'Text-only source drop accepted a directory or output drop refused one.'
        $uiStart = $source.IndexOf('$script:Form = [ZeeVA.ControlForm]::new()')
        $uiEnd = $source.IndexOf('$timer = [Windows.Forms.Timer]::new()')
        . ([scriptblock]::Create($source.Substring($uiStart, $uiEnd - $uiStart)))
        try {
            $script:State.Connected = $true
            Update-Display
            Show-ScriptWindow
            Assert-Test ($script:ActionButtons[1].Text -ceq 'Open Script' -and $script:ActionButtons[4].Text -ceq 'Show Script') 'Text-only UI still offers WAV import or original playback.'
            Assert-Test ($script:Form.AllowDrop -and $script:ScriptWindow.AllowDrop) 'Script file drop is missing from a window.'
            Assert-Test ($script:ScriptColumns[1].Body.Text -ceq 'Only record me' -and $script:State.Files.Count -eq 1) 'The current recording column includes other voices.'
            Assert-Test ($script:ScriptColumns[0].Body.Text -ceq 'Other before' -and $script:ScriptColumns[2].Body.Text -ceq 'Other after') 'Filtering recording lines removed other-voice context.'
            Assert-Test (-not $script:ScriptLoadButton.Enabled) 'A loaded project can replace its script or voice type.'
        }
        finally { $script:ScriptWindow.Dispose(); $script:ActionToolTip.Dispose(); $script:Form.Dispose() }
    }

    Invoke-TestCase 'Accepting a second line focuses the existing regions track' {
        $script:State.Index = 1
        $script:State.Files += [IO.FileInfo]::new((Join-Path $testRoot 'second.wav'))
        $script:State.Originals['second.wav'] = 'SRC|second'
        $script:State.Accepted['line.wav'] = 'TAKE|line|one'
        $script:State.Candidate = 'TAKE|second|one'
        $script:MockTracks += @(
            [pscustomobject]@{Index=4; Name='SRC|second'; Start=4.0; End=5.0; Channels=2},
            [pscustomobject]@{Index=5; Name='TAKE|second|one'; Start=6.0; End=7.0; Channels=2}
        )
        $script:RegionTracks = @($script:MockTracks[0..1]) + @(
            [pscustomobject]@{Name='ZeeVA Regions'; kind='label'},
            [pscustomobject]@{Name='ZeeVA Session|old'; kind='label'}
        ) + @($script:MockTracks[2..3])
        $script:RegionLabels = @(
            [pscustomobject]@{Index=0; Track=2; Text='line'; Start=2.0; End=3.0},
            [pscustomobject]@{Index=1; Track=3; Text='ZeeVA Data|0|payload'; Start=0.0; End=0.0}
        )
        $script:SelectedTrack = 5
        $script:FocusedTrack = 5
        function Invoke-Audacity {
            param($Command)
            if ($Command -like '*Type=Tracks*') { return (ConvertTo-Json -InputObject $script:RegionTracks -Depth 5 -Compress) }
            throw "Unexpected query: $Command"
        }
        function Get-AudacityLabels { $script:RegionLabels }
        function Select-AudioTrack { param($Index, $Start, $End) $script:SelectedTrack = $Index }
        function Send-Audacity {
            param($Command)
            if ($Command -eq 'SetTrackStatus: Focused=1') { $script:FocusedTrack = $script:SelectedTrack }
            elseif ($Command -eq 'AddLabel:') {
                Assert-Test ($script:FocusedTrack -eq 2) 'AddLabel would target focus after the regions track, not ZeeVA Regions.'
                $script:RegionLabels = @($script:RegionLabels[0]) + @(
                    [pscustomobject]@{Index=1; Track=2; Text=''; Start=6.0; End=7.0},
                    [pscustomobject]@{Index=2; Track=3; Text='ZeeVA Data|0|payload'; Start=0.0; End=0.0}
                )
            }
            elseif ($Command -match '^SetLabel: Label=1 Text="second"') { $script:RegionLabels[1].Text = 'second' }
            else { throw "Unexpected command: $Command" }
        }
        function Save-ProjectBookkeeping {}
        Accept-Take
        Assert-Test ($script:State.Accepted.Count -eq 2 -and $script:State.Accepted['second.wav'] -ceq 'TAKE|second|one') 'Second acceptance was not recorded.'
        Assert-Test ($script:RegionLabels[0].Text -ceq 'line' -and $script:RegionLabels[1].Text -ceq 'second') 'Acceptance changed the first label or failed to name the second.'
        Assert-Test ($script:RegionLabels[2].Text -ceq 'ZeeVA Data|0|payload') 'Acceptance overwrote session bookkeeping.'
    }

    Invoke-TestCase 'New acceptance labels never use the replaceable bookkeeping track' {
        $script:State.Candidate = 'TAKE|line|one'
        $script:RegionTracks = @($script:MockTracks) + @([pscustomobject]@{Name='ZeeVA Session|old'; kind='label'})
        $script:RegionLabels = @([pscustomobject]@{Index=0; Track=2; Text='ZeeVA Data|0|payload'; Start=0.0; End=0.0})
        $script:SelectedTrack = 2
        function Invoke-Audacity {
            param($Command)
            if ($Command -like '*Type=Tracks*') { return (ConvertTo-Json -InputObject $script:RegionTracks -Depth 5 -Compress) }
            throw "Unexpected query: $Command"
        }
        function Get-AudacityLabels { $script:RegionLabels }
        function Select-AudioTrack { param($Index, $Start, $End) $script:SelectedTrack = $Index }
        function Send-Audacity {
            param($Command)
            if ($Command -eq 'NewLabelTrack:') { $script:RegionTracks += [pscustomobject]@{Name='Labels'; kind='label'} }
            elseif ($Command -match '^SelectTracks: Track=([0-9]+)') { $script:SelectedTrack = [int]$matches[1] }
            elseif ($Command -eq 'SetTrackStatus: Name="ZeeVA Regions"') { $script:RegionTracks[$script:SelectedTrack].Name = 'ZeeVA Regions' }
            elseif ($Command -eq 'AddLabel:') {
                Assert-Test ($script:SelectedTrack -eq 3) 'Acceptance label was added to bookkeeping instead of the dedicated region track.'
                $script:RegionLabels += [pscustomobject]@{Index=1; Track=3; Text=''; Start=2.0; End=3.0}
            }
            elseif ($Command -match '^SetLabel: Label=([0-9]+) Text="line"') { $script:RegionLabels[[int]$matches[1]].Text = 'line' }
        }
        function Save-ProjectBookkeeping {
            $script:RegionLabels = @($script:RegionLabels | Where-Object { $_.Track -ne 2 })
        }
        Accept-Take
        Assert-Test ($script:RegionLabels.Count -eq 1 -and $script:RegionLabels[0].Text -ceq 'line') 'Replacing bookkeeping removed an acceptance region.'
        Assert-AudacitySession
        Sync-AudacitySession
        Assert-Test ($script:State.Accepted['line.wav'] -ceq 'TAKE|line|one') 'Acceptance was lost after saving and reconciling labels.'
    }

    Invoke-TestCase 'Explicit retake choices survive navigation, snapshots and reconciliation' {
        $script:State.Connected = $true
        $script:State.SessionVerified = $true
        $script:State.Files += [IO.FileInfo]::new((Join-Path $testRoot 'second.wav'))
        $script:State.Originals['second.wav'] = 'SRC|second'
        $script:MockTracks += @(
            [pscustomobject]@{Index=3; Name='SRC|second'; Start=4.0; End=5.0; Channels=2},
            [pscustomobject]@{Index=4; Name='TAKE|line|two'; Start=6.0; End=7.0; Channels=2}
        )
        $script:State.Recorded['line.wav'] = @('TAKE|line|one', 'TAKE|line|two')
        $script:State.Candidate = 'TAKE|line|two'
        function Confirm-DiscardCandidate { return $true }
        function Send-Audacity {}
        function Update-Display {}
        Invoke-Action -Id 10
        Assert-Test ($script:State.Candidates['line.wav'] -ceq 'TAKE|line|two') 'Navigation forgot the explicit retake choice.'
        $snapshot = Get-ProjectSessionData @([pscustomobject]@{name=(Get-SessionTrackName)})
        Assert-Test ($snapshot.Candidates.'line.wav' -ceq 'TAKE|line|two') 'Snapshot omitted noncurrent review choices.'
        Invoke-Action -Id 9
        Assert-Test ($script:State.Candidate -ceq 'TAKE|line|two') 'Returning to a multi-take line guessed or lost its selected retake.'
        Sync-AudacitySession
        Assert-Test ($script:State.Candidate -ceq 'TAKE|line|two' -and $script:State.Accepted.Count -eq 0) 'Reconciliation lost or automatically accepted the explicit choice.'
        $script:MockTracks = @($script:MockTracks | Where-Object { $_.Name -cne 'TAKE|line|two' })
        Sync-AudacitySession
        Assert-Test (-not $script:State.Candidates.ContainsKey('line.wav') -and -not $script:State.Candidate) 'Deleted explicit take was retained or replaced during reconciliation.'
    }

    Invoke-TestCase 'Navigation restores reviewable takes and preserves acceptance on other lines' {
        $script:State.Connected = $true
        $script:State.SessionVerified = $true
        $script:State.Files += [IO.FileInfo]::new((Join-Path $testRoot 'second.wav'))
        $script:State.Originals['second.wav'] = 'SRC|second'
        $script:MockTracks += @(
            [pscustomobject]@{Index=3; Name='SRC|second'; Start=4.0; End=5.0; Channels=2},
            [pscustomobject]@{Index=4; Name='TAKE|second|one'; Start=6.0; End=7.0; Channels=2}
        )
        $script:MockLabelJson = '[[2,[[2,3,"line"],[6,7,"second"]]]]'
        $script:State.Recorded = @{'line.wav'=@('TAKE|line|one'); 'second.wav'=@('TAKE|second|one')}
        $script:State.Accepted['line.wav'] = 'TAKE|line|one'
        function Confirm-DiscardCandidate { return $true }
        function Send-Audacity {}
        function Update-Display {}
        function Save-ProjectBookkeeping {}
        Invoke-Action -Id 10
        Assert-Test ($script:State.Candidate -ceq 'TAKE|second|one' -and $script:State.Accepted['line.wav'] -ceq 'TAKE|line|one') 'Navigation lost the destination candidate or existing acceptance.'
        Invoke-Action -Id 9
        Assert-Test (-not $script:State.Candidate -and $script:State.Accepted['line.wav'] -ceq 'TAKE|line|one') 'Accepted line was downgraded during navigation.'
        Invoke-Action -Id 10
        Accept-Take
        Sync-AudacitySession
        Assert-Test ($script:State.Accepted.Count -eq 2 -and $script:State.Accepted['second.wav'] -ceq 'TAKE|second|one') 'Revisited take could not be accepted or acceptance did not survive reconciliation.'
        $script:State.Accepted.Remove('second.wav')
        $script:State.Candidate = $null
        $script:State.Recorded['second.wav'] += 'TAKE|second|two'
        Assert-Test ($null -eq (Get-LineCandidate)) 'Multiple unaccepted takes were guessed between.'
    }

    Invoke-TestCase 'Changing source folders selects the script without prompting on ordinary actions' {
        $script:State.Connected = $true
        $script:State.SessionVerified = $true
        $script:ScriptSelections = 0
        function Update-Display {}
        function Open-SpeakerFolder { param($Folder) $script:State.Source = $Folder }
        function Open-DialogueExport {
            Assert-Test (-not $script:State.Busy -and -not $script:State.Recording) 'Script selection ran while an action or capture was in progress.'
            $script:ScriptSelections++
        }
        Invoke-Action -Id 1 -Folder (Join-Path $testRoot 'NewVoice')
        Assert-Test ($script:ScriptSelections -eq 1) 'New source folder did not trigger script discovery.'
        Invoke-Action -Id 5
        Invoke-Action -Id 1 -Folder $script:State.Source
        Assert-Test ($script:ScriptSelections -eq 1) 'Ordinary actions or the same source reopened script selection.'
        $script:State.Recording = $true
        Invoke-Action -Id 1 -Folder (Join-Path $testRoot 'OtherVoice')
        Assert-Test ($script:ScriptSelections -eq 1 -and $script:State.Recording) 'Script discovery interrupted capture.'
    }

    Invoke-TestCase 'Script discovery derives game root and validates voice type before picker fallback' {
        $gameRoot = Join-Path $testRoot 'Game'
        $null = New-Item -ItemType Directory -Path $gameRoot
        foreach ($relative in @('Data\Sound\Test.esp\TestVT', 'Data\Sound\Voice\Test.esp\TestVT')) {
            $script:State.Source = Join-Path $gameRoot $relative
            $location = Get-DialogueExportLocation
            Assert-Test ($location.GameRoot -ceq $gameRoot -and $location.VoiceType -ceq 'TestVT') 'Game root or voice type was derived incorrectly.'
        }
        $matchingPath = Join-Path $gameRoot 'dialogueExport_TestVT.txt'
        @([pscustomobject]@{FILENAME='00000001'; 'RESPONSE TEXT'='Matched'; 'VOICE TYPE'='TestVT'}) |
            Export-Csv -LiteralPath $matchingPath -Delimiter "`t" -Encoding UTF8 -NoTypeInformation
        $wrongPath = Join-Path $gameRoot 'wrong_TestVT.txt'
        @([pscustomobject]@{FILENAME='00000001'; 'RESPONSE TEXT'='Wrong speaker'; 'VOICE TYPE'='OtherVT'}) |
            Export-Csv -LiteralPath $wrongPath -Delimiter "`t" -Encoding UTF8 -NoTypeInformation
        $export = Find-DialogueExport $location (Join-Path $gameRoot 'missing.txt')
        Assert-Test ($export.Path -ceq $matchingPath -and $export.Rows[0].'RESPONSE TEXT' -ceq 'Matched') 'Automatic discovery missed the matching export or trusted a wrong voice type.'
        $filteredPath = Join-Path $gameRoot 'dialogueExport_TestVT_filtered.txt'
        @([pscustomobject]@{FILENAME='00000002'; 'RESPONSE TEXT'='Filtered'; 'VOICE TYPE'='TestVT'}) |
            Export-Csv -LiteralPath $filteredPath -Delimiter "`t" -Encoding UTF8 -NoTypeInformation
        $export = Find-DialogueExport $location $matchingPath
        Assert-Test ($export.Path -ceq $filteredPath -and $export.Rows[0].'RESPONSE TEXT' -ceq 'Filtered') 'Remembered standard export took precedence over its filtered sibling.'
        $export = Find-DialogueExport $location
        Assert-Test ($export.Path -ceq $filteredPath) 'Standard and filtered exports were treated as ambiguous.'
        $ambiguousPath = Join-Path $gameRoot 'another_TestVT_filtered.txt'
        Copy-Item -LiteralPath $filteredPath -Destination $ambiguousPath
        Assert-Test ($null -eq (Find-DialogueExport $location)) 'Multiple filtered exports were guessed between.'
        Remove-Item -LiteralPath $ambiguousPath
        Remove-Item -LiteralPath $filteredPath
        $export = Find-DialogueExport $location $filteredPath
        Assert-Test ($export.Path -ceq $matchingPath) 'Missing remembered filtered export did not fall back to the standard export.'
        $script:PickerCalls = 0
        function Save-SessionSettings {}
        function Show-ScriptWindow {}
        function Select-DialogueExportFile {
            param($InitialDirectory, $VoiceType)
            $script:PickerCalls++
            Assert-Test ($InitialDirectory -ceq $gameRoot -and $VoiceType -ceq 'TestVT') 'Picker did not start at the derived game root.'
            return $matchingPath
        }
        Open-DialogueExport
        Assert-Test ($script:PickerCalls -eq 0 -and $script:State.DialogueExportPath -ceq $matchingPath) 'Matching automatic export unnecessarily opened the picker.'
        $manualPath = Join-Path $gameRoot 'manual.txt'
        Move-Item -LiteralPath $matchingPath -Destination $manualPath
        $matchingPath = $manualPath
        Open-DialogueExport -Automatic
        Assert-Test ($script:PickerCalls -eq 1 -and $script:State.DialogueExportPath -ceq $manualPath) 'Missing automatic export did not prompt and load the selected script.'
        $script:State.DialogueExportPath = ''
        Open-DialogueExport
        Assert-Test ($script:PickerCalls -eq 2 -and $script:State.DialogueExportPath -ceq $manualPath -and -not $script:State.Busy) 'Missing export did not fall back to the picker.'
        function Select-DialogueExportFile { return $wrongPath }
        Open-DialogueExport -Browse
        Assert-Test ($script:FeedbackLabel.Text -like '*no rows for voice type TestVT*' -and $script:State.DialogueExportPath -ceq $manualPath) 'Manual selection accepted a mismatched voice type.'
        function Select-DialogueExportFile { return '' }
        Open-DialogueExport -Browse
        Assert-Test (-not $script:State.Busy -and $script:State.DialogueExportPath -ceq $manualPath) 'Picker cancellation changed the selected script or left controls busy.'
        $script:State.DialogueExportPath = ''
        Open-DialogueExport -Automatic
        Assert-Test ($script:DialogueRows.Count -eq 0 -and -not $script:State.Busy) 'Cancelling automatic discovery retained stale dialogue or left controls busy.'
    }

    Invoke-TestCase 'WAV transcript replaces comments while preserving PCM and other metadata' {
        $metadataRoot = Join-Path $testRoot 'Metadata'
        $null = New-Item -ItemType Directory -Path $metadataRoot
        $wavPath = Join-Path $metadataRoot 'metadata.wav'
        $writer = [IO.BinaryWriter]::new([IO.File]::Create($wavPath))
        try {
            $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'))
            $writer.Write([uint32]0)
            $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
            $writer.Write([uint32]16)
            $writer.Write([uint16]1)
            $writer.Write([uint16]2)
            $writer.Write([uint32]44100)
            $writer.Write([uint32]176400)
            $writer.Write([uint16]4)
            $writer.Write([uint16]16)
            $writer.Write([Text.Encoding]::ASCII.GetBytes('data'))
            $writer.Write([uint32]8)
            $writer.Write([byte[]]@(1, 2, 3, 4, 5, 6, 7, 8))
            $writer.Write([Text.Encoding]::ASCII.GetBytes('JUNK'))
            $writer.Write([uint32]3)
            $writer.Write([byte[]]@(9, 10, 11, 0))
            $writer.Write([Text.Encoding]::ASCII.GetBytes('LIST'))
            $writer.Write([uint32]28)
            $writer.Write([Text.Encoding]::ASCII.GetBytes('INFOICMT'))
            $writer.Write([uint32]4)
            $writer.Write([Text.Encoding]::ASCII.GetBytes('old' + [char]0))
            $writer.Write([Text.Encoding]::ASCII.GetBytes('IART'))
            $writer.Write([uint32]4)
            $writer.Write([Text.Encoding]::ASCII.GetBytes('acto'))
            $length = $writer.BaseStream.Length - 8
            $writer.BaseStream.Position = 4
            $writer.Write([uint32]$length)
        }
        finally { $writer.Dispose() }
        $original = [IO.File]::ReadAllBytes($wavPath)
        $transcript = 'A quoted "line", caf' + [char]0xE9 + '.'
        Set-WavTranscript $wavPath 'Temporary transcript'
        Set-WavTranscript $wavPath $transcript
        Assert-ExportFormat $wavPath
        $updated = [IO.File]::ReadAllBytes($wavPath)
        Assert-Test (([BitConverter]::ToString($original[12..63])) -ceq ([BitConverter]::ToString($updated[12..63]))) 'PCM, format or odd-sized unknown chunk changed.'
        $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($wavPath))
        $comments = @()
        $artist = ''
        try {
            $reader.BaseStream.Position = 4
            Assert-Test ($reader.ReadUInt32() -eq $reader.BaseStream.Length - 8) 'RIFF length was not updated.'
            $reader.BaseStream.Position = 12
            while ($reader.BaseStream.Position + 8 -le $reader.BaseStream.Length) {
                $id = [Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
                $size = $reader.ReadUInt32()
                $end = $reader.BaseStream.Position + $size
                if ($id -eq 'LIST' -and [Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -eq 'INFO') {
                    while ($reader.BaseStream.Position + 8 -le $end) {
                        $fieldId = [Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
                        $fieldSize = $reader.ReadUInt32()
                        $value = [Text.Encoding]::UTF8.GetString($reader.ReadBytes($fieldSize)).TrimEnd([char]0)
                        if ($fieldId -eq 'ICMT') { $comments += $value }
                        if ($fieldId -eq 'IART') { $artist = $value }
                        $reader.BaseStream.Position += $fieldSize % 2
                    }
                }
                $reader.BaseStream.Position = $end + ($size % 2)
            }
        }
        finally { $reader.Dispose() }
        Assert-Test ($comments.Count -eq 1 -and $comments[0] -ceq $transcript -and $artist -ceq 'acto') 'Transcript was duplicated, corrupted or removed unrelated INFO metadata.'
        $brokenPath = Join-Path $metadataRoot 'broken.wav'
        [IO.File]::WriteAllBytes($brokenPath, $updated[0..($updated.Length - 2)])
        $hash = (Get-FileHash $brokenPath).Hash
        $rejected = $false
        try { Set-WavTranscript $brokenPath 'Must fail' } catch { $rejected = $true }
        Assert-Test ($rejected -and (Get-FileHash $brokenPath).Hash -ceq $hash) 'Truncated WAV was modified.'
        Assert-Test (@(Get-ChildItem $metadataRoot -Filter '*.metadata').Count -eq 0) 'Temporary metadata files were left behind.'

        $script:State.Accepted['line.wav'] = 'TAKE|line|one'
        $script:State.Files += [IO.FileInfo]::new((Join-Path $testRoot 'second.wav'))
        $script:State.Originals['second.wav'] = 'SRC|second'
        $script:State.Accepted['second.wav'] = 'TAKE|second|one'
        $script:MockTracks += @(
            [pscustomobject]@{Index=3; Name='SRC|second'; Start=4.0; End=5.0; Channels=2},
            [pscustomobject]@{Index=4; Name='TAKE|second|one'; Start=6.0; End=7.0; Channels=2}
        )
        $script:DialogueRows = @([pscustomobject]@{FILENAME='line'; 'RESPONSE TEXT'='Exported transcript'})
        function Isolate-AudioTrack { param($Name) $script:MockTracks | Where-Object { $_.Name -ceq $Name } }
        function Get-AudacityLabels {
            [pscustomobject]@{Text='line'; Start=2.0; End=3.0}
            [pscustomobject]@{Text='second'; Start=6.0; End=7.0}
        }
        function Select-AudioTrack {}
        function Send-Audacity {
            param([string]$Command)
            if ($Command -match '^Export2: Filename="([^"]+)" NumChannels=2$') {
                Copy-Item -LiteralPath $wavPath -Destination $matches[1]
            }
        }
        Export-SpeakerFolder
        $receipt = $script:State.Exported['line.wav']
        Assert-Test ($receipt -and $receipt.Hash -ceq (Get-FileHash -LiteralPath $receipt.Path -Algorithm SHA256).Hash) 'Export receipt was not calculated after writing metadata.'
        Assert-Test ($script:State.Accepted.Count -eq 2 -and $script:State.Exported.Count -eq 2) 'Project export lost acceptance or omitted an accepted line.'
        $secondReceipt = $script:State.Exported['second.wav']
        Assert-Test ($secondReceipt.Take -ceq 'TAKE|second|one' -and $secondReceipt.Hash -ceq (Get-FileHash -LiteralPath $secondReceipt.Path -Algorithm SHA256).Hash) 'Second accepted take was not exported with a valid receipt.'
        $exportBytes = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($receipt.Path))
        Assert-Test ($exportBytes.Contains('Exported transcript') -and -not $exportBytes.Contains($transcript)) 'Export did not embed the current dialogue transcript.'
        Assert-Test ($script:FeedbackLabel.Text -like '*1 with transcripts*') 'Export did not report transcript coverage.'

        $script:State.TextSourceOnly = $true
        $script:State.VoiceType = 'ExportVT'
        $script:State.DialogueExportPath = Join-Path $testRoot 'export-text.tsv'
        $script:State.OutputRoot = $testRoot
        $script:State.Source = Join-Path $testRoot 'ExportVT'
        $script:State.Originals = @{}
        $script:State.Exported = @{}
        $script:DialogueRows = @(
            [pscustomobject]@{FILENAME='line'; 'RESPONSE TEXT'='Text-only first'; 'VOICE TYPE'='ExportVT'},
            [pscustomobject]@{FILENAME='second'; 'RESPONSE TEXT'='Text-only second'; 'VOICE TYPE'='ExportVT'}
        )
        $data = Get-TextDialogueData -Path $script:State.DialogueExportPath -Rows $script:DialogueRows -VoiceType 'ExportVT'
        $script:State.Files = $data.Files
        $script:State.DialogueByFile = $data.ByFile
        $script:MockTracks = @($script:MockTracks | Where-Object { $_.Name -like 'TAKE|*' }) +
            @([pscustomobject]@{Name=(Get-SessionTrackName); kind='label'})
        Export-SpeakerFolder
        foreach ($name in @('line.wav', 'second.wav')) {
            $receipt = $script:State.Exported[$name]
            $expected = Join-Path (Join-Path $testRoot 'ExportVT') $name
            Assert-Test ($receipt.Path -ceq $expected -and (Test-Path -LiteralPath $expected)) 'Text-only output was not written under the selected voice type with its recording ID.'
            Assert-ExportFormat $expected
            $bytes = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($expected))
            Assert-Test ($bytes.Contains($data.ByFile[$name].'RESPONSE TEXT') -and $receipt.Hash -ceq (Get-FileHash $expected).Hash) 'Text-only output lost its transcript or has an invalid receipt.'
        }
        Assert-Test ($script:State.Exported.Count -eq 2 -and $script:FeedbackLabel.Text -like '*2 with transcripts*') 'Text-only accepted takes were not exported.'
    }

    Invoke-TestCase 'Dialogue export matches recording IDs first and refuses ambiguous FormIDs' {
        $dialoguePath = Join-Path $testRoot 'dialogue.txt'
        @(
            [pscustomobject]@{FILENAME='00ABCDEF'; 'RESPONSE TEXT'='First, "quoted" line.'; 'VOICE TYPE'=(Split-Path $testRoot -Leaf); TOPICINFO='FormID 00123456'; 'RESPONSE INDEX'='0'},
            [pscustomobject]@{FILENAME='00ABCDE0'; 'RESPONSE TEXT'='Second line.'; 'VOICE TYPE'=(Split-Path $testRoot -Leaf); TOPICINFO='FormID 00123456'; 'RESPONSE INDEX'='1'},
            [pscustomobject]@{FILENAME='00ABCDEF'; 'RESPONSE TEXT'='Other speaker.'; 'VOICE TYPE'='OtherVoice'; TOPICINFO='FormID 00999999'; 'RESPONSE INDEX'='0'}
        ) | Export-Csv -LiteralPath $dialoguePath -Delimiter "`t" -Encoding UTF8 -NoTypeInformation
        $script:DialogueRows = @(Import-DialogueExport $dialoguePath)
        $row = Get-DialogueRow ([IO.FileInfo]::new((Join-Path $testRoot '00ABCDEF.wav')))
        Assert-Test ($row.'RESPONSE TEXT' -ceq 'First, "quoted" line.') 'Recording ID or speaker matching failed.'
        Assert-Test ($null -eq (Get-DialogueRow ([IO.FileInfo]::new((Join-Path $testRoot '00123456.wav'))))) 'Ambiguous FormID was guessed.'
        $row = Get-DialogueRow ([IO.FileInfo]::new((Join-Path $testRoot '00123456_1.wav')))
        Assert-Test ($row.'RESPONSE TEXT' -ceq 'Second line.') 'FormID plus response index did not match.'
        Assert-Test ($null -eq (Get-DialogueRow (Get-CurrentFile))) 'Unknown WAV was assigned a transcript.'
    }

    Invoke-TestCase 'Listen Take without a take reports inline without issuing Audacity commands' {
        $script:State.Connected = $true
        $script:State.SessionVerified = $true
        function Update-Display {}
        function Send-Audacity { throw 'Listen Take must not send a command without a take.' }
        Invoke-Action -Id 5
        Assert-Test ($script:FeedbackLabel.Text -ceq 'There is no take for this line yet.') 'Missing-take feedback was not displayed inline.'
        Assert-Test (-not $script:State.Busy -and -not $script:State.Recording) 'Rejected action changed the workflow state.'
    }

    Invoke-TestCase 'An accidental Listen Take during recording reports inline and preserves capture' {
        $script:State.Connected = $true
        $script:State.SessionVerified = $true
        $script:State.Recording = $true
        function Update-Display {}
        function Send-Audacity { throw 'Rejected action must not send commands during capture.' }
        Invoke-Action -Id 5
        Assert-Test ($script:FeedbackLabel.Text -ceq 'Stop recording before using another action.') 'Recording guard did not report inline.'
        Assert-Test ($script:State.Recording -and -not $script:State.Busy) 'Rejected action interrupted capture or left controls busy.'
    }

    Invoke-TestCase 'Accepting a take advances to the next WAV and stays on the final WAV' {
        $script:State.Files += [IO.FileInfo]::new((Join-Path $testRoot 'second.wav'))
        $script:State.Originals['second.wav'] = 'SRC|second'
        $script:MockTracks += @(
            [pscustomobject]@{Index=3; Name='SRC|second'; Start=4.0; End=5.0; Channels=2},
            [pscustomobject]@{Index=4; Name='TAKE|second|one'; Start=6.0; End=7.0; Channels=2}
        )
        $script:MockLabelJson = '[[2,[[2,3,"line"],[6,7,"second"]]]]'
        $script:Commands = [Collections.Generic.List[string]]::new()
        function Send-Audacity { param($Command) $script:Commands.Add($Command) }
        function Save-ProjectBookkeeping {}
        $script:State.Candidate = 'TAKE|line|one'
        $script:State.Exported['line.wav'] = 'old receipt'
        Accept-Take
        Assert-Test ($script:State.Accepted['line.wav'] -ceq 'TAKE|line|one' -and -not $script:State.Exported.ContainsKey('line.wav') -and -not $script:State.Candidate) 'Acceptance did not retain the completed take correctly.'
        Assert-Test ($script:State.Index -eq 1 -and (Get-CurrentFile).Name -ceq 'second.wav' -and $script:Commands[-2] -like 'Select: Track=3 *' -and $script:Commands[-1] -ceq 'ZoomSel:') 'Acceptance did not select the next original.'
        $script:State.Candidate = 'TAKE|second|one'
        Accept-Take
        Assert-Test ($script:State.Index -eq 1 -and $script:State.Accepted['second.wav'] -ceq 'TAKE|second|one' -and $script:State.SessionDirty) 'Final acceptance moved past the list or failed to accept.'
    }

    Invoke-TestCase 'Retake starts immediately without confirming an existing candidate' {
        $script:State.Connected = $true
        $script:State.SessionVerified = $true
        $script:State.Candidate = 'TAKE|line|one'
        $script:RetakeStarted = $false
        $script:RetakePrompted = $false
        function Confirm-DiscardCandidate { $script:RetakePrompted = $true; return $false }
        function Start-Take { $script:RetakeStarted = $true }
        function Update-Display {}
        Invoke-Action -Id 8
        Assert-Test ($script:RetakeStarted -and -not $script:RetakePrompted) 'Retake was blocked by confirmation.'
        Assert-Test ($script:State.Candidate -ceq 'TAKE|line|one' -and $script:State.Accepted.Count -eq 0) 'Retake removed or accepted the previous candidate.'
    }

    Invoke-TestCase 'Recording start sends no scripting queries or pause commands after Record' {
        $script:RecordIssued = $false
        $script:RecordCommands = [Collections.Generic.List[string]]::new()
        $script:State.RecordingCommandsVerified = $true
        function Send-Audacity {
            param([string]$Command)
            Assert-Test (-not $script:RecordIssued) "Command after Record can interrupt capture: $Command"
            $script:RecordCommands.Add($Command)
            if ($Command -like 'Record*Choice:') { $script:RecordIssued = $true }
        }
        function Invoke-Audacity {
            param([string]$Command)
            Assert-Test (-not $script:RecordIssued) "Query after Record stops capture: $Command"
            if ($Command -like 'GetPreference:*') { return '0' }
            if ($Command -like '*Type=Tracks*') { return (ConvertTo-Json -InputObject $script:MockTracks -Depth 5 -Compress) }
            throw "Unexpected query: $Command"
        }
        function Find-AudioTrack {
            param([string]$Name)
            $null = Invoke-Audacity 'GetPreference: Name="test-pre-record-only"'
            [pscustomobject]@{Index=2; Name=$Name; Start=0.0; End=0.0; Channels=2}
        }
        function Focus-Audacity {}
        Start-Take
        Assert-Test ($script:RecordIssued -and $script:State.Recording -and $script:State.SessionDirty) 'Recording did not start.'
        Assert-Test ($script:RecordCommands[-1] -ceq 'Record1stChoice:') 'Record was not the final command.'
    }

    Invoke-TestCase 'Large speaker folders split into stable blocks with their own projects' {
        $names = @(1..330 | ForEach-Object { 'Line{0:D4}.wav' -f $_ })
        $files = @($names | ForEach-Object { [IO.FileInfo]::new((Join-Path $testRoot $_)) })
        $blocks = @(Get-SpeakerFileBlocks -Files $files)
        Assert-Test ($blocks.Count -eq 9) 'A 330-file folder did not split into 9 blocks of 40.'
        Assert-Test (@($blocks[0..7] | Where-Object { $_.Files.Count -ne 40 }).Count -eq 0 -and $blocks[8].Files.Count -eq 10) 'Block sizes are wrong.'
        Assert-Test ($blocks[1].Number -eq 2 -and $blocks[1].Files[0].Name -ceq 'Line0041.wav' -and $blocks[1].Files[-1].Name -ceq 'Line0080.wav') 'Block boundaries are not contiguous.'
        $joined = @($blocks | ForEach-Object { $_.Files } | ForEach-Object { $_.Name })
        Assert-Test (($joined -join ',') -ceq ($names -join ',')) 'Blocks reordered or dropped files.'
        Assert-Test (@(Get-SpeakerFileBlocks -Files @($files[0..39])).Count -eq 1 -and @(Get-SpeakerFileBlocks -Files @($files[0..40])).Count -eq 2) 'The block boundary at exactly 40 files is wrong.'
        $path = Get-SpeakerBlockProjectPath -Folder (Join-Path $testRoot 'MaleEvenToned') -Block 3
        Assert-Test ($path -ceq (Join-Path $testRoot 'MaleEvenToned_Block3.aup3')) 'Block projects are not named beside the folder.'
        $choice = Format-SpeakerBlockChoice -Block $blocks[1] -ProjectExists $true
        Assert-Test ($choice -ceq 'Block 2 | files 41-80 | Line0041.wav - Line0080.wav | project exists') 'The block chooser label is wrong.'
        $choice = Format-SpeakerBlockChoice -Block $blocks[8] -ProjectExists $false
        Assert-Test ($choice -ceq 'Block 9 | files 321-330 | Line0321.wav - Line0330.wav') 'The final partial block label is wrong.'
    }

    Invoke-TestCase 'Recording refuses takes beyond the Audacity scripting track cap' {
        $script:State.RecordingCommandsVerified = $true
        $script:Commands = [Collections.Generic.List[string]]::new()
        function Send-Audacity { param($Command) $script:Commands.Add($Command) }
        function Invoke-Audacity {
            param([string]$Command)
            if ($Command -like '*Type=Tracks*') {
                return (ConvertTo-Json -InputObject @(
                    1..$script:MockTrackTotal | ForEach-Object {
                        [pscustomobject]@{kind='wave'; name="T$_"; start=0.0; end=1.0; channels=2}
                    }) -Depth 5 -Compress)
            }
            throw "Unexpected query: $Command"
        }
        $script:MockTrackTotal = 102
        $rejected = ''
        try { Start-Take } catch { $rejected = $_.Exception.Message }
        Assert-Test ($rejected -like '*cannot address tracks beyond index 100*') 'An over-limit project did not refuse a new take.'
        Assert-Test ('NewStereoTrack:' -notin $script:Commands) 'A recording target was created beyond the scripting cap.'
        Assert-Test (-not $script:State.Recording) 'ZeeVA believes it is recording after the refusal.'
        $script:MockTrackTotal = 95
        Assert-AudacityTrackBudget
        Assert-Test ($script:FeedbackLabel.Text -like '*95 of 101*') 'Approaching the track cap produced no warning.'
        $script:MockTrackTotal = 89
        $script:FeedbackLabel.Text = ''
        Assert-AudacityTrackBudget
        Assert-Test ($script:FeedbackLabel.Text -ceq '') 'A small project warned about the track cap.'
    }

    Invoke-TestCase 'Snapshot restores folders, current line, candidate and export receipts' {
        $script:State.Accepted['line.wav'] = 'TAKE|line|one'
        $script:State.Candidate = 'TAKE|line|two'
        $script:State.Exported['line.wav'] = [pscustomobject]@{Take='TAKE|line|one'; Hash='saved'}
        $snapshot = Get-ProjectSessionData @([pscustomobject]@{name=(Get-SessionTrackName)})
        Assert-Test ($snapshot.Source -ceq $testRoot -and $snapshot.CurrentFile -ceq 'line.wav') 'Session identity lost.'
        Assert-Test ($snapshot.Candidate -ceq 'TAKE|line|two' -and $snapshot.Exported.'line.wav'.Hash -ceq 'saved') 'Workflow stages lost.'
        $rejected = $false
        try { Get-ProjectSessionData @([pscustomobject]@{name='ZeeVA Session|invalid'}) } catch { $rejected = $true }
        Assert-Test $rejected 'Corrupt bookkeeping was accepted.'
    }

    Invoke-TestCase 'Large sessions use bounded metadata chunks and replace only bookkeeping' {
        foreach ($number in 1..300) {
            $fileName = 'DialogueLine{0:D5}.wav' -f $number
            $script:State.Files += [IO.FileInfo]::new((Join-Path $testRoot $fileName))
            $script:State.Originals[$fileName] = 'SRC|' + [IO.Path]::GetFileNameWithoutExtension($fileName)
        }
        $script:ProjectTracks = @($script:MockTracks) + @([pscustomobject]@{Name='Regions'; kind='label'})
        $script:ProjectLabels = @([pscustomobject]@{Index=0; Track=2; Text='line'; Start=2.0; End=3.0})
        $script:SelectedTrack = 0
        $script:SelectedStart = 0.0
        $script:SelectedEnd = 0.0
        $script:Commands = [Collections.Generic.List[string]]::new()
        $script:ProgressAtWrites = [Collections.Generic.List[string]]::new()
        function Get-AudacityLabels { $script:ProjectLabels }
        function Invoke-Audacity {
            param($Command)
            if ($Command -like '*Type=Tracks*') { return (ConvertTo-Json -InputObject $script:ProjectTracks -Depth 5 -Compress) }
            throw "Unexpected query: $Command"
        }
        function Send-Audacity {
            param($Command)
            $script:Commands.Add($Command)
            if ($Command -match '^Select(?:Tracks)?: Track=([0-9]+)') {
                $script:SelectedTrack = [int]$matches[1]
                if ($Command -match ' Start=([0-9.]+) End=([0-9.]+)') {
                    $script:SelectedStart = [double]$matches[1]
                    $script:SelectedEnd = [double]$matches[2]
                }
            }
            elseif ($Command -eq 'NewLabelTrack:') {
                $script:ProjectTracks += [pscustomobject]@{Name='Labels'; kind='label'}
            }
            elseif ($Command -eq 'AddLabel:') {
                $script:ProjectLabels += [pscustomobject]@{Index=$script:ProjectLabels.Count; Track=$script:SelectedTrack; Text=''; Start=$script:SelectedStart; End=$script:SelectedEnd}
            }
            elseif ($Command -match '^SetLabel: Label=([0-9]+) Text="([^"]*)"') {
                $script:ProgressAtWrites.Add([string]$script:State.ProjectProgress)
                $script:ProjectLabels[[int]$matches[1]].Text = $matches[2]
            }
            elseif ($Command -match '^SetTrackStatus: Name="(.*)"$') {
                $script:ProjectTracks[$script:SelectedTrack].Name = $matches[1]
            }
            elseif ($Command -eq 'RemoveTracks:') {
                $script:ProjectLabels = @($script:ProjectLabels | Where-Object { $_.Track -ne $script:SelectedTrack })
                foreach ($label in $script:ProjectLabels) {
                    if ($label.Track -gt $script:SelectedTrack) { $label.Track-- }
                }
                for ($labelIndex = 0; $labelIndex -lt $script:ProjectLabels.Count; $labelIndex++) {
                    $script:ProjectLabels[$labelIndex].Index = $labelIndex
                }
                $script:ProjectTracks = @(
                    for ($trackIndex = 0; $trackIndex -lt $script:ProjectTracks.Count; $trackIndex++) {
                        if ($trackIndex -ne $script:SelectedTrack) { $script:ProjectTracks[$trackIndex] }
                    }
                )
            }
        }
        Save-ProjectBookkeeping
        if ($SourceFile -eq 'ZeeVA_TextOnly.ps1') {
            $total = $script:ProgressAtWrites.Count
            for ($index = 0; $index -lt $total; $index++) {
                Assert-Test ($script:ProgressAtWrites[$index] -ceq ('Preparing project - {0}/{1} labels' -f $index, $total)) 'Preparation progress did not match completed and total labels.'
            }
            Assert-Test ($script:FeedbackLabel.Text -ceq ('Preparing project - {0}/{0} labels' -f $total)) 'Preparation never reported its final completed label.'
            Assert-Test (-not $script:State.ProjectProgress) 'Preparation status was left active after completion.'
        }
        Assert-Test ((Get-SessionTrackName).Length -gt 10000) 'The test session is not large enough to reproduce the original risk.'
        foreach ($command in $script:Commands) {
            Assert-Test ([Text.Encoding]::UTF8.GetByteCount($command + "`r`n") -lt 1024) 'An oversized metadata command would reach Audacity.'
        }
        $snapshot = Get-ProjectSessionData $script:ProjectTracks
        Assert-Test ($snapshot.Files.Count -eq 301 -and $snapshot.CurrentFile -ceq 'line.wav') 'Chunked session did not round trip.'
        Save-ProjectBookkeeping
        Assert-Test ($script:ProjectTracks.Count -eq 4 -and $script:ProjectLabels[0].Text -ceq 'line') 'Repeated save damaged user labels or accumulated bookkeeping tracks.'
        $script:ProjectLabels[0].Track = 3
        $script:State.Accepted['line.wav'] = 'TAKE|line|one'
        Save-ProjectBookkeeping
        $preserved = @($script:ProjectLabels | Where-Object { $_.Text -ceq 'line' })
        Assert-Test ($preserved.Count -eq 1 -and $script:ProjectTracks[$preserved[0].Track].Name -ceq 'ZeeVA Regions') 'Saving erased an existing filename label on the old bookkeeping track.'
        Assert-Test ($preserved[0].Start -eq 2.0 -and $preserved[0].End -eq 3.0) 'Preserving the acceptance label changed its region boundaries.'
        $script:State.TextSourceOnly = $true
        $script:State.VoiceType = 'BookkeepingVT'
        $script:State.DialogueExportPath = Join-Path $testRoot 'bookkeeping.tsv'
        $script:State.Source = Join-Path $testRoot 'BookkeepingVT'
        $script:State.Originals = @{}
        $script:State.Accepted = @{}
        $script:State.Candidate = $null
        $script:State.Index = $script:State.Files.Count - 1
        $script:DialogueRows = @($script:State.Files | ForEach-Object {
            [pscustomobject]@{FILENAME=$_.BaseName; 'RESPONSE TEXT'=('Text for ' + $_.BaseName); 'VOICE TYPE'='BookkeepingVT'}
        })
        Save-ProjectBookkeeping
        $snapshot = Get-ProjectSessionData $script:ProjectTracks
        Assert-Test ($snapshot.TextSourceOnly -and $snapshot.DialogueRows.Count -eq 301 -and $snapshot.VoiceType -ceq 'BookkeepingVT') 'Chunked bookkeeping lost text-only script data.'
        Assert-Test ($snapshot.CurrentFile -ceq 'DialogueLine00300.wav' -and $script:Commands[-1] -ceq 'SelectNone:') 'Saving on an unrecorded line required original audio or lost the current line.'
        foreach ($command in $script:Commands) {
            Assert-Test ([Text.Encoding]::UTF8.GetByteCount($command + "`r`n") -lt 1024) 'Text-only script data exceeded the Audacity command size limit.'
        }
        $script:ProjectLabels[1].Text += 'A'
        $rejected = $false
        try { Get-ProjectSessionData $script:ProjectTracks } catch { $rejected = $_.Exception.Message -like '*checksum*' }
        Assert-Test $rejected 'Corrupt session chunks were accepted.'
    }

    Invoke-TestCase 'Oversized ASCII and UTF-8 commands never reach the pipe' {
        $definition = $syntax.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Invoke-Audacity'
        }
        . ([scriptblock]::Create($definition.Extent.Text))
        foreach ($payload in @(('x' * 20000), (([string][char]0x20AC) * 400))) {
            $rejected = $false
            try { Invoke-Audacity ('SetTrackStatus: Name="' + $payload + '"') }
            catch { $rejected = $_.Exception.Message -like '*safety limit*' }
            Assert-Test $rejected 'Unsafe command passed the pre-connection guard.'
        }
    }

    Invoke-TestCase 'INI round trip preserves paths and equals signs' {
        $script:IniPath = Join-Path $testRoot 'settings.ini'
        $script:State.OutputRoot = Join-Path $testRoot 'Output = WAVs'
        $script:State.LastSource = $testRoot
        $script:State.LastProject = Join-Path $testRoot 'Speaker.aup3'
        $script:State.DialogueExportPath = Join-Path $testRoot 'dialogue = script.txt'
        Save-SessionSettings
        $expected = $script:State.OutputRoot
        $script:State.OutputRoot = ''
        $script:State.DialogueExportPath = ''
        Read-SessionSettings
        Assert-Test ($script:State.OutputRoot -ceq $expected -and $script:State.LastSource -ceq $testRoot) 'INI values did not round trip.'
        Assert-Test ($script:State.DialogueExportPath -ceq (Join-Path $testRoot 'dialogue = script.txt')) 'Dialogue export path was not remembered.'
    }

    Invoke-TestCase 'Grouped labels retain global label indices' {
        $script:MockLabelJson = '[[2,[[2,3,"line"]]],[3,[]],[4,[[4,5,"second"]]]]'
        $labels = @(Get-AudacityLabels)
        Assert-Test ($labels.Count -eq 2 -and $labels[1].Index -eq 1 -and $labels[1].Track -eq 4) 'Label indices are incorrect.'
    }

    Invoke-TestCase 'Recorded is not accepted and accepted is not exported' {
        Sync-AudacitySession
        Assert-Test ($script:State.Recorded['line.wav'].Count -eq 1 -and $script:State.Accepted.Count -eq 0) 'A recording was promoted to accepted.'
        $script:State.Accepted['line.wav'] = 'TAKE|line|one'
        Sync-AudacitySession
        Assert-Test ($script:State.Accepted.Count -eq 1 -and $script:State.Exported.Count -eq 0) 'Acceptance was promoted to exported.'
    }

    Invoke-TestCase 'Export receipts require matching take, region, destination and bytes' {
        $destination = Join-Path (Join-Path $script:State.OutputRoot (Split-Path $testRoot -Leaf)) 'line.wav'
        $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
        [IO.File]::WriteAllBytes($destination, [byte[]]@(1, 2, 3))
        $receipt = [pscustomobject]@{Take='TAKE|line|one'; Path=$destination; Start=2.0; End=3.0; Hash=(Get-FileHash -LiteralPath $destination).Hash}
        $script:State.Accepted['line.wav'] = 'TAKE|line|one'
        $script:State.Exported['line.wav'] = $receipt
        Sync-AudacitySession
        Assert-Test ($script:State.Exported.Count -eq 1) 'Verified export was lost.'
        [IO.File]::WriteAllBytes($destination, [byte[]]@(4, 5, 6))
        Sync-AudacitySession
        Assert-Test ($script:State.Exported.Count -eq 0 -and $script:State.Accepted.Count -eq 1) 'Changed export was not invalidated independently.'
        $receipt.Hash = (Get-FileHash -LiteralPath $destination).Hash
        foreach ($property in @('Take', 'Path', 'Start', 'End')) {
            $previous = $receipt.$property
            if ($property -in @('Start', 'End')) { $receipt.$property = 2.5 }
            else { $receipt.$property = 'different' }
            $script:State.Exported['line.wav'] = $receipt
            Sync-AudacitySession
            Assert-Test ($script:State.Exported.Count -eq 0 -and $script:State.Accepted.Count -eq 1) "Stale $property did not invalidate export independently."
            $receipt.$property = $previous
        }
        $script:State.Exported['line.wav'] = $receipt
        Remove-Item -LiteralPath $destination
        Sync-AudacitySession
        Assert-Test ($script:State.Exported.Count -eq 0) 'Missing output still counts as exported.'
    }

    Invoke-TestCase 'Deleted takes and labels downgrade saved acceptance' {
        $script:State.Accepted['line.wav'] = 'TAKE|line|one'
        $script:MockLabelJson = '[]'
        $explained = $false
        try { Assert-AudacitySession }
        catch { $explained = $_.Exception.Message -like '*filename labels*Review Take*' }
        Assert-Test $explained 'Missing acceptance label was incorrectly diagnosed as the wrong project.'
        $script:State.Accepted['line.wav'] = 'TAKE|line|one'
        $script:State.Candidate = 'TAKE|line|missing'
        $script:MockLabelJson = '[]'
        Sync-AudacitySession
        Assert-Test ($script:State.Accepted.Count -eq 0 -and -not $script:State.Candidate -and $script:State.Recorded['line.wav'].Count -eq 1) 'Missing labels or candidate were not reconciled.'
        $script:State.Accepted['line.wav'] = 'TAKE|line|one'
        $script:MockTracks = @($script:MockTracks[0])
        Sync-AudacitySession
        Assert-Test ($script:State.Accepted.Count -eq 0 -and $script:State.Recorded['line.wav'].Count -eq 0) 'Deleted take still counts as accepted.'
    }

    Invoke-TestCase 'Wrong project is rejected without modifying session mappings' {
        $script:State.Accepted['line.wav'] = 'TAKE|line|one'
        $script:MockTracks = @()
        $rejected = $false
        try { Sync-AudacitySession } catch { $rejected = $true }
        Assert-Test ($rejected -and $script:State.Accepted.Count -eq 1) 'Wrong project changed the saved session.'
    }

    Invoke-TestCase 'Saved project resumes and reconciles missing accepted take' {
        $script:State.Accepted['line.wav'] = 'TAKE|line|missing'
        $metadataName = Get-SessionTrackName
        $script:MockTracks += [pscustomobject]@{Index=2; Name=$metadataName; Kind='label'}
        $projectJson = Invoke-Audacity 'GetInfo: Type=Tracks Format=JSON'
        [object[]]$projectTracks = $projectJson | ConvertFrom-Json
        $snapshot = Get-ProjectSessionData $projectTracks
        Assert-Test ([bool]$snapshot) 'Fixture metadata missing.'
        Restore-ProjectSession -Quiet
        Assert-Test ($script:State.SessionVerified -and $script:State.Accepted.Count -eq 0 -and $script:State.SessionDirty) 'Saved project was not reconciled on restore.'
    }

    Invoke-TestCase 'Crash recovery reconciles newer labels and takes with an initial snapshot' {
        foreach ($baseName in @('second', 'third')) {
            $script:State.Files += [IO.FileInfo]::new((Join-Path $testRoot ($baseName + '.wav')))
            $script:State.Originals[$baseName + '.wav'] = 'SRC|' + $baseName
            $script:MockTracks += [pscustomobject]@{Index=$script:MockTracks.Count; Name=('SRC|' + $baseName); Start=4.0; End=5.0; Channels=2}
        }
        $metadataName = Get-SessionTrackName
        $script:MockTracks += @(
            [pscustomobject]@{Index=4; Name='TAKE|second|one'; Start=6.0; End=7.0; Channels=2},
            [pscustomobject]@{Index=5; Name='TAKE|third|one'; Start=8.0; End=9.0; Channels=2},
            [pscustomobject]@{Index=6; Name=$metadataName; Kind='label'}
        )
        $script:MockLabelJson = '[[7,[[2,3,"line"],[6,7,"second"]]]]'
        Restore-ProjectSession -Quiet
        Assert-Test ($script:State.Accepted.Count -eq 2 -and $script:State.Accepted['second.wav'] -ceq 'TAKE|second|one') 'Recovered labels were ignored because an older snapshot exists.'
        Assert-Test ($script:State.Index -eq 2 -and $script:State.Candidate -ceq 'TAKE|third|one') 'Recovery returned to the initial line instead of the recovered candidate.'
        Assert-Test ($script:State.Recorded['third.wav'].Count -eq 1 -and $script:State.SessionDirty -and $script:State.Exported.Count -eq 0) 'Recovered workflow stages were not reconciled safely.'
    }

    Invoke-TestCase 'Interrupted recording audio is recovered without accepting it or empty targets' {
        $script:State.Files += [IO.FileInfo]::new((Join-Path $testRoot 'third.wav'))
        $script:State.Originals['third.wav'] = 'SRC|third'
        $metadataName = Get-SessionTrackName
        $script:MockTracks += @(
            [pscustomobject]@{Index=2; Name='SRC|third'; Start=4.0; End=5.0; Channels=2},
            [pscustomobject]@{Index=3; Name='RECORDING|third|interrupted'; Start=6.0; End=7.0; Channels=2},
            [pscustomobject]@{Index=4; Name='RECORDING|third|empty'; Start=0.0; End=0.0; Channels=2},
            [pscustomobject]@{Index=5; Name=$metadataName; Kind='label'}
        )
        $script:MockLabelJson = '[]'
        $script:Commands = [Collections.Generic.List[string]]::new()
        function Send-Audacity { param($Command) $script:Commands.Add($Command) }
        Restore-ProjectSession -Quiet
        Assert-Test ($script:State.Index -eq 1 -and $script:State.Candidate -ceq 'TAKE|third|interrupted') 'Interrupted audio did not restore its current line and candidate.'
        Assert-Test ($script:State.Recorded['third.wav'].Count -eq 1 -and $script:State.Accepted.Count -eq 0 -and $script:State.SessionDirty) 'Interrupted or empty audio was classified incorrectly.'
        Assert-Test ($script:Commands[-1] -ceq 'SetTrackStatus: Name="TAKE|third|interrupted"' -and $script:MockTracks[4].Name -ceq 'RECORDING|third|empty') 'Recovery failed to finalize only the nonempty recording track.'
    }

    Invoke-TestCase 'Stopping and accepting checkpoint the candidate and advanced line' {
        $script:State.Files += [IO.FileInfo]::new((Join-Path $testRoot 'second.wav'))
        $script:State.Originals['second.wav'] = 'SRC|second'
        $script:MockTracks += [pscustomobject]@{Index=3; Name='SRC|second'; Start=4.0; End=5.0; Channels=2}
        $script:MockTracks[1].Name = 'RECORDING|line|active'
        $script:State.Recording = $true
        $script:State.RecordingTargetName = $script:MockTracks[1].Name
        $script:State.RecordingStart = 2.0
        $script:State.ProjectPath = Join-Path $testRoot 'Speaker.aup3'
        $script:Checkpoints = @()
        function Save-ZeeVAProject {
            Assert-Test (-not $script:State.Recording -and -not $script:State.RecordingTargetName) 'Checkpoint ran before recording stopped and cleared its target.'
            $script:Checkpoints += Get-SessionTrackName
        }
        function Send-Audacity {
            param($Command)
            if ($Command -match '^SetTrackStatus: Name="(.*)"$') { $script:MockTracks[1].Name = $matches[1] }
        }
        Stop-Take
        Assert-Test ($script:Checkpoints.Count -eq 1 -and $script:State.Candidate -like 'TAKE|line|*') 'Stopped take was not checkpointed.'
        Accept-Take
        $snapshot = Get-ProjectSessionData @([pscustomobject]@{name=$script:Checkpoints[-1]})
        Assert-Test ($script:Checkpoints.Count -eq 2 -and $snapshot.CurrentFile -ceq 'second.wav' -and $snapshot.Accepted.'line.wav' -like 'TAKE|line|*' -and -not $snapshot.Candidate) 'Acceptance checkpoint did not preserve the advanced line and accepted take.'
        $script:State.ProjectPath = ''
        function Save-ZeeVAProject { throw 'A scanned project must not prompt for a save destination.' }
        function Save-ProjectBookkeeping { $script:Checkpoints += Get-SessionTrackName }
        $script:MockTracks[1].Name = 'RECORDING|second|active'
        $script:MockLabelJson = '[[2,[[2,3,"second"]]]]'
        $script:State.Recording = $true
        $script:State.RecordingTargetName = $script:MockTracks[1].Name
        $script:State.RecordingStart = 2.0
        Stop-Take
        Accept-Take
        $snapshot = Get-ProjectSessionData @([pscustomobject]@{name=$script:Checkpoints[-1]})
        Assert-Test ($script:Checkpoints.Count -eq 4 -and $snapshot.Accepted.'second.wav' -like 'TAKE|second|*' -and $script:State.SessionDirty) 'Scanned project did not checkpoint in-project bookkeeping while retaining unsaved status.'
    }

    Invoke-TestCase 'Legacy scan uses acceptance labels, not recorded tracks alone' {
        $null = New-Item -ItemType File -Path (Join-Path $testRoot 'line.wav') -Force
        Restore-ProjectSession -SourceFolder $testRoot -Quiet
        Assert-Test ($script:State.Accepted['line.wav'] -ceq 'TAKE|line|one' -and $script:State.Exported.Count -eq 0) 'Legacy acceptance label was not recovered.'
        $script:MockLabelJson = '[]'
        Restore-ProjectSession -SourceFolder $testRoot -Quiet
        Assert-Test ($script:State.Accepted.Count -eq 0 -and $script:State.Recorded['line.wav'].Count -eq 1) 'Unlabelled recording was accepted.'
    }

    Invoke-TestCase 'Opening a folder auto-saves foldername.aup3 beside that folder' {
        $script:State.Files = @()
        $script:ImportFinished = $false
        $script:SavedPath = ''
        $script:Status = [Windows.Forms.Label]::new()
        $script:Form = [Windows.Forms.Form]::new()
        function Get-AudacityTracks { if ($script:ImportFinished) { $script:MockTracks[0] } }
        function Send-Audacity { param($Command) if ($Command -like 'Import2:*') { $script:ImportFinished = $true } }
        function Save-ZeeVAProject { param($Path) $script:SavedPath = $Path }
        try {
            Open-SpeakerFolder -Folder $testRoot
            $expected = Join-Path (Split-Path $testRoot -Parent) ((Split-Path $testRoot -Leaf) + '.aup3')
            Assert-Test ($script:SavedPath -ceq $expected) 'Automatic project name is incorrect.'
        }
        finally { $script:Form.Dispose(); $script:Status.Dispose() }
    }

    Invoke-TestCase 'Existing folder projects offer resume, cancel and explicit overwrite' {
        $folder = Join-Path $testRoot 'ExistingSpeaker'
        $null = New-Item -ItemType Directory -Path $folder
        $null = New-Item -ItemType File -Path (Join-Path $folder 'line.wav')
        $projectPath = Join-Path $testRoot 'ExistingSpeaker.aup3'
        [IO.File]::WriteAllText($projectPath, 'original')
        $script:Status = [Windows.Forms.Label]::new()
        $script:Form = [Windows.Forms.Form]::new()
        function Get-ExistingProjectAction { param($Path) return $script:ConflictChoice }
        function Get-AudacityTracks { if ($script:ImportFinished) { $script:MockTracks[0] } }
        function Send-Audacity { param($Command) if ($Command -like 'Import2:*') { $script:ImportFinished = $true } }
        function Open-ZeeVAProject { param($Path, $SourceFolder) $script:ResumePath = $Path; $script:ResumeSource = $SourceFolder }
        function Save-ZeeVAProject { param($Path, [switch]$Overwrite) $script:SavedPath = $Path; $script:OverwriteRequested = $Overwrite.IsPresent }
        try {
            foreach ($choice in @('Cancel', 'Resume', 'Overwrite')) {
                $script:State.Files = @()
                $script:ConflictChoice = $choice
                $script:ImportFinished = $false
                $script:ResumePath = ''
                $script:SavedPath = ''
                Open-SpeakerFolder -Folder $folder
                switch ($choice) {
                    'Cancel' { Assert-Test (-not $script:ImportFinished -and -not $script:ResumePath -and -not $script:SavedPath) 'Cancel changed the session.' }
                    'Resume' { Assert-Test ($script:ResumePath -ceq $projectPath -and $script:ResumeSource -ceq $folder -and -not $script:ImportFinished -and -not $script:SavedPath) 'Resume did not open the existing project directly.' }
                    'Overwrite' { Assert-Test ($script:ImportFinished -and $script:SavedPath -ceq $projectPath -and $script:OverwriteRequested) 'Overwrite did not request a fresh replacement.' }
                }
                Assert-Test ([IO.File]::ReadAllText($projectPath) -ceq 'original') 'Conflict handling deleted the original before saving.'
            }
        }
        finally { $script:Form.Dispose(); $script:Status.Dispose() }
    }

    Invoke-TestCase 'Opening a supplied project path automatically restores and remembers it' {
        $script:State.Files = @()
        $script:MockTracks = @()
        $script:Operations = [Collections.Generic.List[string]]::new()
        function Send-Audacity { param($Command) $script:Operations.Add($Command) }
        function Restore-ProjectSession { param($SourceFolder) $script:RestoredSource = $SourceFolder; $script:Operations.Add('Restore') }
        function Save-SessionSettings { $script:Operations.Add('INI') }
        $path = Join-Path $testRoot 'ExistingSpeaker.aup3'
        Open-ZeeVAProject -Path $path -SourceFolder $testRoot
        Assert-Test ($script:Operations[0] -ceq ('OpenProject2: Filename=' + (Quote-Audacity $path)) -and $script:Operations[1] -ceq 'Restore' -and $script:Operations[2] -ceq 'INI') 'Project open did not restore automatically.'
        Assert-Test ($script:RestoredSource -ceq $testRoot -and $script:State.LastProject -ceq $path) 'Resume lost its source folder or project path.'
    }

    Invoke-TestCase 'Overwrite preserves a backup and failed replacement restores the original' {
        $path = Join-Path $testRoot 'Replace.aup3'
        function Save-ProjectBookkeeping {}
        function Save-SessionSettings {}
        function Send-Audacity {
            Assert-Test (-not (Test-Path -LiteralPath $path)) 'Audacity would refuse to overwrite the existing path.'
            [IO.File]::WriteAllText($path, 'replacement')
        }
        [IO.File]::WriteAllText($path, 'original')
        Save-ZeeVAProject -Path $path -Overwrite
        $backups = @(Get-ChildItem -LiteralPath $testRoot -Filter 'Replace.backup-*.aup3')
        Assert-Test ($backups.Count -eq 1 -and [IO.File]::ReadAllText($backups[0].FullName) -ceq 'original' -and [IO.File]::ReadAllText($path) -ceq 'replacement') 'Overwrite did not preserve the original backup.'
        $script:State.SessionDirty = $true
        function Send-Audacity { throw 'Simulated replacement failure' }
        $failed = $false
        try { Save-ZeeVAProject -Path $path -Overwrite } catch { $failed = $true }
        Assert-Test ($failed -and $script:State.SessionDirty -and [IO.File]::ReadAllText($path) -ceq 'replacement') 'Failed replacement did not restore the previous project.'
        [IO.File]::WriteAllText(($path + '-wal'), 'active')
        $blocked = $false
        try { Save-ZeeVAProject -Path $path -Overwrite } catch { $blocked = $_.Exception.Message -like '*Close the existing project*' }
        Assert-Test ($blocked -and [IO.File]::ReadAllText($path) -ceq 'replacement') 'An active project was moved.'
    }

    Invoke-TestCase 'Saving writes metadata first and keeps dirty state on failure' {
        $script:Operations = [Collections.Generic.List[string]]::new()
        function Save-ProjectBookkeeping { $script:Operations.Add('Metadata') }
        function Save-SessionSettings { $script:Operations.Add('INI') }
        function Send-Audacity { param($Command) $script:Operations.Add($Command) }
        $path = Join-Path $testRoot 'Speaker.aup3'
        Save-ZeeVAProject -Path $path
        Assert-Test ($script:Operations[0] -ceq 'Metadata' -and $script:Operations[1] -like 'SaveProject2:*' -and $script:State.LastProject -ceq $path) 'Save order is incorrect.'
        $script:State.SessionDirty = $true
        function Send-Audacity { throw 'Simulated save failure' }
        try { Save-ZeeVAProject -Path $path } catch { }
        Assert-Test $script:State.SessionDirty 'Failed save marked the session clean.'
    }

    if ($SourceFile -eq 'ZeeVA_TextOnly.ps1') {
        Invoke-TestCase 'Prepared initial save avoids duplicate labels and clears progress on failures' {
            $script:Preparations = 0
            function Save-ProjectBookkeeping { $script:Preparations++ }
            function Save-SessionSettings {}
            function Send-Audacity {
                Assert-Test ($script:State.ProjectProgress -ceq 'Saving Audacity project...') 'Disk save has no visible saving status.'
            }
            Save-ZeeVAProject -Path (Join-Path $testRoot 'Prepared.aup3') -BookkeepingPrepared
            Assert-Test ($script:Preparations -eq 0 -and -not $script:State.ProjectProgress) 'Prepared save repeated label creation or left progress active.'
            Save-ZeeVAProject -Path $script:State.ProjectPath
            Assert-Test ($script:Preparations -eq 1) 'Ordinary saves stopped updating bookkeeping.'
            $script:State.SessionDirty = $true
            function Send-Audacity { throw 'Simulated project-save failure' }
            $failed = $false
            try { Save-ZeeVAProject -Path $script:State.ProjectPath -BookkeepingPrepared }
            catch { $failed = $_.Exception.Message -ceq 'Simulated project-save failure' }
            Assert-Test ($failed -and -not $script:State.ProjectProgress -and $script:State.SessionDirty) 'Failed save hid the error, retained progress or marked the project clean.'

            $definition = $syntax.EndBlock.Statements | Where-Object {
                $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Save-ProjectBookkeeping'
            }
            . ([scriptblock]::Create($definition.Extent.Text))
            function Invoke-Audacity { throw 'Simulated preparation failure' }
            $failed = $false
            try { Save-ProjectBookkeeping } catch { $failed = $_.Exception.Message -ceq 'Simulated preparation failure' }
            Assert-Test ($failed -and -not $script:State.ProjectProgress) 'Failed preparation hid the error or left progress active.'
        }
    }

    Invoke-TestCase 'Closing without a live attached Audacity skips bookkeeping prompts' {
        $registration = $syntax.Find({
            param($node)
            $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                $node.Member.Value -eq 'Add_FormClosing'
        }, $true)
        $handler = $registration.Arguments[0].ScriptBlock.GetScriptBlock()
        $script:State.SessionDirty = $true
        foreach ($recording in @($false, $true)) {
            $script:State.Recording = $recording
            $eventArgs = [Windows.Forms.FormClosingEventArgs]::new(
                [Windows.Forms.CloseReason]::UserClosing, $false
            )
            & $handler $null $eventArgs
            Assert-Test (-not $eventArgs.Cancel) 'A detached session prevented closing.'
        }
        $staleProcess = Get-Process -Id $PID
        $script:State.AudacityProcess = $staleProcess
        $script:State.AudacityProcessId = $staleProcess.Id
        $staleProcess.Dispose()
        & $handler $null $eventArgs
        Assert-Test (-not $eventArgs.Cancel) 'A stale process reference prevented closing.'
    }

    Invoke-TestCase 'Folder drop accepts exactly one directory' {
        $data = [Windows.Forms.DataObject]::new()
        $data.SetData([Windows.Forms.DataFormats]::FileDrop, [string[]]@($testRoot))
        Assert-Test ((Get-DroppedFolder $data) -ceq $testRoot) 'Valid folder was rejected.'
        $data.SetData([Windows.Forms.DataFormats]::FileDrop, [string[]]@($testRoot, $testRoot))
        Assert-Test (-not (Get-DroppedFolder $data)) 'Multiple folders were accepted.'
        $data.SetData([Windows.Forms.DataFormats]::FileDrop, [string[]]@($sourcePath))
        Assert-Test (-not (Get-DroppedFolder $data)) 'File was accepted as a folder.'
    }

    Invoke-TestCase 'Window controls expose project operations and folder drops' {
        $uiStart = $source.IndexOf('$script:Form = [ZeeVA.ControlForm]::new()')
        $uiEnd = $source.IndexOf('$timer = [Windows.Forms.Timer]::new()')
        . ([scriptblock]::Create($source.Substring($uiStart, $uiEnd - $uiStart)))
        try {
            Update-Display
            $script:State.Connected = $true
            $script:State.Recorded['line.wav'] = @('TAKE|line|one')
            Update-Display
            Assert-Test ($script:ListenTakeButton.Enabled -and $script:AcceptButton.Enabled) 'Revisited recorded line still disables review or acceptance.'
            $script:State.Recorded['line.wav'] += 'TAKE|line|two'
            Update-Display
            Assert-Test ($script:TakeSelectionStatus.Available -and -not $script:AcceptButton.Enabled) 'Ambiguous takes were guessed or offered no explicit selector.'
            Show-TakeSelection
            $script:TakeMenu.Items[1].PerformClick()
            Assert-Test ($script:State.Candidate -ceq 'TAKE|line|two' -and $script:AcceptButton.Enabled -and $script:ListenTakeButton.Enabled) 'Explicit take selection did not restore review and acceptance controls.'
            $script:TakeMenu.Close()
            $script:State.Candidate = $null
            $script:State.Candidates = @{}
            $script:State.Accepted['line.wav'] = 'TAKE|line|one'
            Update-Display
            Assert-Test ($script:ListenTakeButton.Enabled -and -not $script:AcceptButton.Enabled) 'Accepted line was incorrectly offered for acceptance again.'
            $script:State.Accepted = @{}
            $script:State.Recorded = @{}
            Update-Display
            $script:State.Files = @(
                [IO.FileInfo]::new((Join-Path $testRoot '00000001.wav')),
                [IO.FileInfo]::new((Join-Path $testRoot '00000002.wav')),
                [IO.FileInfo]::new((Join-Path $testRoot '00000003.wav'))
            )
            $script:DialogueRows = @(
                [pscustomobject]@{FILENAME='00000001'; 'RESPONSE TEXT'='First'},
                [pscustomobject]@{FILENAME='00000002'; 'RESPONSE TEXT'='Current'; 'DIALOGUE BEFORE'='Actual preceding dialogue'; 'DIALOGUE AFTER'='Actual follow-up'; 'SCRIPT NOTES'='Delivery note'},
                [pscustomobject]@{FILENAME='00000003'; 'RESPONSE TEXT'='Last'}
            )
            $script:State.Index = 1
            Show-ScriptWindow
            Assert-Test ($script:ScriptColumns.Count -eq 3 -and $script:ScriptColumns[1].Body.Text -like 'Current*') 'Three-column script window did not select the current WAV.'
            Assert-Test ($script:ScriptColumns[1].Body.Text -ceq 'Current' -and $script:ScriptColumns[1].Metadata.Text -like '*00000002*Delivery note*') 'Dialogue and metadata were not separated.'
            Assert-Test ($script:ScriptColumns[0].Body.Text -ceq 'Actual preceding dialogue' -and $script:ScriptColumns[2].Body.Text -ceq 'Actual follow-up') 'Explicit dialogue context was not used.'
            $script:State.Index = 0
            Update-Display
            Assert-Test ($script:ScriptColumns[1].Body.Text -like 'First*' -and $script:ScriptColumns[2].Body.Text -like 'Current*') 'Script window did not follow navigation.'
            Assert-Test ($script:ScriptColumns[0].Body.Text -ceq 'No matching dialogue.' -and $script:ScriptColumns[2].Heading.Text -ceq 'Next WAV') 'Fallback context was misleading or crossed the directory boundary.'
            Assert-Test ($script:ScriptColumns[0].Metadata.Text -ceq '' -and $script:ScriptColumns[2].Metadata.Text -like '*00000002*Delivery note*') 'Navigation left stale or incorrect metadata.'
            foreach ($size in @([Drawing.Size]::new(780, 320), [Drawing.Size]::new(1200, 480))) {
                $script:ScriptWindow.ClientSize = $size
                $script:ScriptWindow.PerformLayout()
                Assert-Test ($script:ScriptColumns[1].Body.Width -gt $script:ScriptColumns[0].Body.Width -and $script:ScriptColumns[0].Body.Height -gt 150) 'Script columns do not fit the window size.'
                foreach ($column in $script:ScriptColumns) {
                    Assert-Test ([Math]::Abs($column.Body.Height - 3 * $column.MetadataArea.Height) -lt 16) 'Dialogue and metadata do not use a 75/25 height split.'
                    Assert-Test ($column.MetadataArea.Top -ge $column.Body.Bottom -and $column.Metadata.Font.Size -lt $column.Body.Font.Size) 'Metadata overlaps dialogue or uses oversized text.'
                }
                Assert-Test ($script:ScriptLoadButton.Width -ge 100 -and $script:ScriptLoadButton.Height -ge 24 -and $script:ScriptColumns[1].Metadata.Height -gt 20) 'Script selector does not fit inside the metadata area.'
            }
            $script:SelectionBrowse = $null
            function Open-DialogueExport { param([switch]$Browse) $script:SelectionBrowse = [bool]$Browse }
            $script:ScriptLoadButton.PerformClick()
            Assert-Test ($script:SelectionBrowse -eq $true) 'Loaded script button did not request an explicit file selection.'
            $script:DialogueRows = @()
            Update-ScriptDisplay
            Assert-Test ($script:ScriptLoadButton.Text -ceq 'Find Script...' -and $script:ScriptExportLabel.Text -ceq 'No matching script loaded') 'Missing script was not exposed in the metadata area.'
            $script:ScriptLoadButton.PerformClick()
            Assert-Test ($script:SelectionBrowse -eq $false) 'Missing script button did not request discovery before browsing.'
            $script:State.Recording = $true
            Update-ScriptDisplay
            Assert-Test (-not $script:ScriptLoadButton.Enabled) 'Script selection remained enabled during recording.'
            $script:State.Recording = $false
            Update-Display
            $activation = $script:ScriptWindow.GetType().GetProperty('ShowWithoutActivation', [Reflection.BindingFlags]'NonPublic,Instance')
            Assert-Test ([bool]$activation.GetValue($script:ScriptWindow, $null)) 'Script window steals focus when shown.'
            Assert-Test ($script:ActionButtons.ContainsKey(12) -and $script:ActionButtons.ContainsKey(13)) 'Project controls are missing.'
            Assert-Test ($script:SourcePathLabel.AllowDrop -and $script:OutputPathLabel.AllowDrop -and $script:ActionButtons[1].AllowDrop -and $script:ActionButtons[3].AllowDrop) 'Folder drop targets are missing.'
            Assert-Test ($script:Status.Text -like '*Not recorded') 'A fresh line was incorrectly marked as recorded.'
            $script:Form.ClientSize = [Drawing.Size]::new(760, 540)
            $script:Form.PerformLayout()
            foreach ($button in $script:ActionButtons.Values) {
                Assert-Test ($button.Width -gt 100 -and $button.Height -gt 30) 'A control is too small at the minimum window size.'
            }
        }
        finally { if ($script:TakeMenu) { $script:TakeMenu.Dispose() }; if ($script:ScriptWindow) { $script:ScriptWindow.Dispose() }; $script:ActionToolTip.Dispose(); $script:Form.Dispose() }
    }

    Write-Output "$script:TestsPassed tests passed. No live Audacity project was modified."
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}