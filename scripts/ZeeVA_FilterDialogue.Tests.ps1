$ErrorActionPreference = 'Stop'
$cleaner = Join-Path $PSScriptRoot 'ZeeVA_FilterDialogue.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ZeeVA-filter-test-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-DialogueRow {
    param([string]$Voice, [string]$Id, [string]$Text, [string]$Plugin = 'ZeeOgresEnhancedOutposts.esp')
    [pscustomobject]@{
        FILENAME = $Id
        'RESPONSE TEXT' = $Text
        'VOICE TYPE' = $Voice
        'FULL PATH' = "Data\Sound\Voice\$Plugin\$Voice\$Id.wem"
        'SCRIPT NOTES' = 'Keep delivery notes'
        'DIALOGUE BEFORE' = 'Keep context'
    }
}

try {
    $zeePath = Join-Path $testRoot 'dialogueExport_ZeeVT.txt'
    $chikaPath = Join-Path $testRoot 'dialogueExport_ChikaVT.tsv'
    @(
        (New-DialogueRow 'ZeeVT' 'second' 'First, "quoted" response'),
        (New-DialogueRow 'OtherVT' 'outside' 'Wrong voice'),
        (New-DialogueRow 'ZeeVT' 'basegame' 'Wrong plugin' 'Starfield.esm'),
        (New-DialogueRow 'ZeeVT' 'suffix' 'Wrong plugin suffix' 'ZeeOgresEnhancedOutposts.esp.backup'),
        (New-DialogueRow 'ZeeVT' 'first' ('caf' + [char]0xE9 + "`nNext line")),
        (New-DialogueRow 'zeevt' 'SECOND.wav' 'First, "quoted" response')
    ) | Export-Csv -LiteralPath $zeePath -Delimiter "`t" -Encoding UTF8 -NoTypeInformation
    @(
        (New-DialogueRow 'ChikaVT' 'second' 'Different voice, same ID'),
        (New-DialogueRow 'ZeeVT' 'second' 'First, "quoted" response')
    ) | Export-Csv -LiteralPath $chikaPath -Delimiter "`t" -Encoding UTF8 -NoTypeInformation
    $sourceHashes = @((Get-FileHash $zeePath).Hash, (Get-FileHash $chikaPath).Hash)
    $output = Join-Path $testRoot 'Filtered'
    $result = @(& $cleaner -Path @($zeePath, $chikaPath) -OutputDirectory $output)
    Assert-Test ($result.Count -eq 3 -and $result[0].Kept -eq 2 -and $result[1].Kept -eq 1 -and $result[2].Kept -eq 3) 'Filtered or master row counts are incorrect.'
    Assert-Test ($result[0].RemovedDuplicates -eq 1) 'Case-insensitive duplicate recording was retained.'
    $zee = @(Import-Csv -LiteralPath $result[0].Output -Delimiter "`t" -Encoding UTF8)
    $master = @(Import-Csv -LiteralPath $result[2].Output -Delimiter "`t" -Encoding UTF8)
    Assert-Test (($zee.FILENAME -join ',') -ceq 'second,first') 'Cleanup changed script order.'
    Assert-Test ($zee[0].'RESPONSE TEXT' -ceq 'First, "quoted" response' -and $zee[1].'RESPONSE TEXT' -ceq ('caf' + [char]0xE9 + "`nNext line")) 'TSV output corrupted quotes, newlines or UTF-8 text.'
    Assert-Test ($zee[0].'SCRIPT NOTES' -ceq 'Keep delivery notes' -and $zee[0].'DIALOGUE BEFORE' -ceq 'Keep context') 'Cleanup discarded relevant metadata.'
    Assert-Test (@($master | Where-Object FILENAME -eq 'second').Count -eq 2) 'Master incorrectly deduplicated IDs belonging to different voices.'
    Assert-Test ((Get-FileHash $zeePath).Hash -ceq $sourceHashes[0] -and (Get-FileHash $chikaPath).Hash -ceq $sourceHashes[1]) 'Cleanup modified source exports.'
    Write-Output 'PASS: Voice/plugin filtering, deduplication, master output and TSV preservation'

    $rejected = $false
    try { & $cleaner -Path @($zeePath, $chikaPath) -OutputDirectory $output | Out-Null }
    catch { $rejected = $_.Exception.Message -like '*Output already exists*' }
    Assert-Test $rejected 'Existing outputs were overwritten without -Force.'
    $null = & $cleaner -Path @($zeePath, $chikaPath) -OutputDirectory $output -Force
    Write-Output 'PASS: Generated output overwrite protection and explicit replacement'

    $duplicateFolder = Join-Path $testRoot 'Duplicate'
    $null = New-Item -ItemType Directory -Path $duplicateFolder
    $duplicatePath = Join-Path $duplicateFolder 'another_ZeeVT.txt'
    @((New-DialogueRow 'ZeeVT' 'second' 'First, "quoted" response')) |
        Export-Csv -LiteralPath $duplicatePath -Delimiter "`t" -Encoding UTF8 -NoTypeInformation
    $merged = @(& $cleaner -Path @($zeePath, $duplicatePath) -OutputDirectory (Join-Path $testRoot 'Merged'))
    Assert-Test ($merged[-1].Kept -eq 2 -and $merged[-1].RemovedDuplicates -eq 1) 'Master did not deduplicate the same recording across exports.'
    Write-Output 'PASS: Cross-export duplicate recordings'

    @((New-DialogueRow 'ZeeVT' 'second' 'Conflicting response')) |
        Export-Csv -LiteralPath $duplicatePath -Delimiter "`t" -Encoding UTF8 -NoTypeInformation
    $conflictOutput = Join-Path $testRoot 'Conflict'
    $rejected = $false
    try { & $cleaner -Path @($zeePath, $duplicatePath) -OutputDirectory $conflictOutput | Out-Null }
    catch { $rejected = $_.Exception.Message -like '*Conflicting response text*' }
    Assert-Test ($rejected -and -not (Test-Path -LiteralPath $conflictOutput)) 'Conflicting duplicate text was accepted or produced partial output.'

    $missingPath = Join-Path $testRoot 'dialogueExport_MissingVT.txt'
    Copy-Item -LiteralPath $zeePath -Destination $missingPath
    $rejected = $false
    try { & $cleaner -Path $missingPath -OutputDirectory $conflictOutput | Out-Null }
    catch { $rejected = $_.Exception.Message -like '*filename must identify exactly one*' }
    Assert-Test ($rejected -and -not (Test-Path -LiteralPath $conflictOutput)) 'Unknown filename voice was guessed.'
    Write-Output 'PASS: Conflicting recordings and unidentified filename voices fail before writing'
    Write-Output '4 tests passed. Original exports were not modified.'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
