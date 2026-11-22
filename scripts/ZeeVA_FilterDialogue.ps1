# Standalone cleanup of CK dialogue exports; originals are never modified.
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string[]]$Path,
    [string]$OutputDirectory = '',
    [string]$ModName = 'ZeeOgresEnhancedOutposts.esp',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Get-TextVoiceTypeFromFile {
    param([string]$Path, [string[]]$VoiceTypes)

    $stem = [IO.Path]::GetFileNameWithoutExtension($Path)
    $matching = @($VoiceTypes | Where-Object {
        $stem -match ('(?<![A-Za-z0-9])' + [regex]::Escape($_) + '(?![A-Za-z0-9])')
    })
    if ($matching.Count -eq 1) { return $matching[0] }
    return ''
}

if ([string]::IsNullOrWhiteSpace($ModName) -or
    $ModName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
    [IO.Path]::GetExtension($ModName) -notin @('.esp', '.esm', '.esl')) {
    throw 'ModName must be a plugin filename, such as ZeeOgresEnhancedOutposts.esp.'
}

$sources = @(
    foreach ($inputPath in $Path) {
        $file = Get-Item -LiteralPath $inputPath -ErrorAction Stop
        if ($file.PSIsContainer -or $file.Extension -notin @('.txt', '.tsv') -or
            $file.BaseName -match '_(filtered|master)$') {
            throw "Select original .txt/.tsv exports, not directories or generated files: $inputPath"
        }
        $file
    }
)
if (-not $sources.Count) { throw 'Provide at least one original dialogue export.' }
if (@($sources.FullName | Select-Object -Unique).Count -ne $sources.Count) {
    throw 'The same input export was supplied more than once.'
}
if (-not $OutputDirectory) { $OutputDirectory = $sources[0].DirectoryName }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$pluginPattern = '(?:^|[\\/])Sound[\\/](?:Voice[\\/])?' +
    [regex]::Escape($ModName) + '[\\/]'
$plans = [Collections.Generic.List[object]]::new()
$masterRows = [Collections.Generic.List[object]]::new()
$masterIndex = @{}
$headers = @()
$masterDuplicates = 0

for ($fileIndex = 0; $fileIndex -lt $sources.Count; $fileIndex++) {
    $file = $sources[$fileIndex]
    Write-Progress -Activity 'Filtering dialogue exports' `
        -Status ('Reading {0} ({1}/{2})' -f $file.Name, ($fileIndex + 1), $sources.Count) `
        -PercentComplete (100 * $fileIndex / $sources.Count)
    $rows = @(Import-Csv -LiteralPath $file.FullName -Delimiter "`t" -Encoding UTF8)
    if (-not $rows.Count) { throw "The export contains no dialogue rows: $($file.FullName)" }
    $fileHeaders = @($rows[0].PSObject.Properties.Name)
    foreach ($required in @('FILENAME', 'RESPONSE TEXT', 'VOICE TYPE', 'FULL PATH')) {
        if ($required -notin $fileHeaders) { throw "Missing '$required' column in $($file.FullName)." }
    }
    if (-not $headers.Count) { $headers = $fileHeaders }
    elseif (($headers -join "`t") -cne ($fileHeaders -join "`t")) {
        throw "Export columns differ in $($file.FullName). Use the same CK export format for every input."
    }
    $voices = @($rows | ForEach-Object { [string]$_.'VOICE TYPE' } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $voice = Get-TextVoiceTypeFromFile -Path $file.FullName -VoiceTypes $voices
    if (-not $voice) {
        throw "The filename must identify exactly one VOICE TYPE present in the export: $($file.Name)"
    }
    $kept = [Collections.Generic.List[object]]::new()
    $recordings = @{}
    $duplicates = 0
    foreach ($row in $rows) {
        if ($row.'VOICE TYPE' -ine $voice -or $row.'FULL PATH' -notmatch $pluginPattern) { continue }
        $id = [IO.Path]::GetFileNameWithoutExtension([string]$row.FILENAME)
        if ([string]::IsNullOrWhiteSpace($id) -or
            $id.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $id -match '[. ]$|^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw "Invalid recording filename in $($file.Name): $($row.FILENAME)"
        }
        if ($recordings.ContainsKey($id)) {
            if ([string]$recordings[$id].'RESPONSE TEXT' -cne [string]$row.'RESPONSE TEXT') {
                throw "Conflicting response text for $voice / $id in $($file.Name). No outputs were written."
            }
            $duplicates++
            continue
        }
        $recordings[$id] = $row
        $kept.Add($row)
        $key = $voice + '|' + $id
        if ($masterIndex.ContainsKey($key)) {
            if ([string]$masterIndex[$key].'RESPONSE TEXT' -cne [string]$row.'RESPONSE TEXT') {
                throw "Conflicting response text for $voice / $id across exports. No outputs were written."
            }
            $masterDuplicates++
        }
        else {
            $masterIndex[$key] = $row
            $masterRows.Add($row)
        }
    }
    if (-not $kept.Count) {
        throw "No dialogue for $voice owned by $ModName in $($file.Name). No outputs were written."
    }
    $plans.Add([pscustomobject]@{
        Kind = 'Filtered'
        Source = $file.FullName
        VoiceType = $voice
        Imported = $rows.Count
        Duplicates = $duplicates
        Output = Join-Path $OutputDirectory ($file.BaseName + '_filtered.txt')
        Rows = $kept.ToArray()
    })
}
Write-Progress -Activity 'Filtering dialogue exports' -Completed
$plans.Add([pscustomobject]@{
    Kind = 'Master'
    Source = ''
    VoiceType = ''
    Imported = ($plans | ForEach-Object { $_.Rows.Count } | Measure-Object -Sum).Sum
    Duplicates = $masterDuplicates
    Output = Join-Path $OutputDirectory (
        'dialogueExport_' + [IO.Path]::GetFileNameWithoutExtension($ModName) + '_master.txt')
    Rows = $masterRows.ToArray()
})
if (@($plans.Output | Select-Object -Unique).Count -ne $plans.Count) {
    throw 'Input filenames would produce duplicate output paths. Rename the exports before filtering.'
}
foreach ($plan in $plans) {
    if ($plan.Output -iin $sources.FullName) { throw 'An output path would overwrite an original export.' }
    if ((Test-Path -LiteralPath $plan.Output) -and -not $Force) {
        throw "Output already exists: $($plan.Output). Use -Force to replace generated outputs."
    }
}
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
foreach ($plan in $plans) {
    $temporary = Join-Path $OutputDirectory ('ZeeVA-filter-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $plan.Rows | Export-Csv -LiteralPath $temporary -Delimiter "`t" -Encoding UTF8 -NoTypeInformation
        Move-Item -LiteralPath $temporary -Destination $plan.Output -Force:$Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    [pscustomobject]@{
        Kind = $plan.Kind
        VoiceType = $plan.VoiceType
        Imported = $plan.Imported
        Kept = $plan.Rows.Count
        RemovedDuplicates = $plan.Duplicates
        Output = $plan.Output
    }
}
