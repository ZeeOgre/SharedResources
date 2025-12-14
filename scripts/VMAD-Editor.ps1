#requires -version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

function New-GuidString { [guid]::NewGuid().ToString("N") }

function Get-Timestamp {
    (Get-Date).ToString("yyyyMMdd_HHmmss")
}

function Read-JsonFile([string]$path) {
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    return ($raw | ConvertFrom-Json)
}

function Write-JsonFile($obj, [string]$path) {
    $json = $obj | ConvertTo-Json -Depth 64
    # keep UTF8 without BOM for easiest tooling interop
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Ensure-Dir([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
}

function Is-StructArrayType([string]$t) {
    if (-not $t) { return $false }
    return ($t -match 'Array' -and $t -match 'Struct')
}

function Make-PathKey($questFormId, $scope, $aliasIndex, $scriptIndex, $propName) {
    # stable, human-readable key used by CSV + mapping
    if ($scope -eq "alias") {
        return "Q:$questFormId|SCOPE:alias|A:$aliasIndex|SCRIPT:$scriptIndex|PROP:$propName"
    }
    return "Q:$questFormId|SCOPE:quest|SCRIPT:$scriptIndex|PROP:$propName"
}

function Flatten-SelectionsToRows($model, $selection) {
    # Produces canonical flat rows for selected properties.
    # $selection is a list of hashtables: { quest_formid, scope, alias_index, script_index, property_name }
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($sel in $selection) {
        $q = $model.quests | Where-Object { $_.formid -eq $sel.quest_formid } | Select-Object -First 1
        if (-not $q) { continue }

        if ($sel.scope -eq "quest") {
            $script = $q.scripts[$sel.script_index]
            if (-not $script) { continue }
            $prop = $script.properties | Where-Object { $_.name -eq $sel.property_name } | Select-Object -First 1
            if (-not $prop) { continue }

            $pathKey = Make-PathKey $q.formid "quest" "" $sel.script_index $prop.name

            $rows.Add([pscustomobject]@{
                quest_formid   = $q.formid
                quest_edid     = $q.edid
                scope          = "quest"
                alias_index    = ""
                script_index   = $sel.script_index
                script_name    = $script.name
                property_name  = $prop.name
                property_type  = $prop.type
                path_key       = $pathKey
                value_json     = ($prop.value | ConvertTo-Json -Depth 64 -Compress)
            })
        }
        elseif ($sel.scope -eq "alias") {
            $alias = $q.aliases[$sel.alias_index]
            if (-not $alias) { continue }
            $script = $alias.scripts[$sel.script_index]
            if (-not $script) { continue }
            $prop = $script.properties | Where-Object { $_.name -eq $sel.property_name } | Select-Object -First 1
            if (-not $prop) { continue }

            $pathKey = Make-PathKey $q.formid "alias" $sel.alias_index $sel.script_index $prop.name

            $rows.Add([pscustomobject]@{
                quest_formid   = $q.formid
                quest_edid     = $q.edid
                scope          = "alias"
                alias_index    = $sel.alias_index
                script_index   = $sel.script_index
                script_name    = $script.name
                property_name  = $prop.name
                property_type  = $prop.type
                path_key       = $pathKey
                value_json     = ($prop.value | ConvertTo-Json -Depth 64 -Compress)
            })
        }
    }

    return $rows
}

function Build-SubsetFromSelection($model, $selection) {
    # subset retains quest/script/alias structure but only includes selected properties
    $byQuest = $selection | Group-Object quest_formid

    $subset = [pscustomobject]@{
        format = "VMAD-Subset-1"
        source_file = $model.source_file
        created_utc = (Get-Date).ToUniversalTime().ToString("o")
        quests = @()
    }

    foreach ($qGroup in $byQuest) {
        $qForm = $qGroup.Name
        $qSrc = $model.quests | Where-Object { $_.formid -eq $qForm } | Select-Object -First 1
        if (-not $qSrc) { continue }

        $qOut = [ordered]@{
            formid = $qSrc.formid
            edid   = $qSrc.edid
            scripts = @()
            aliases = @()
        }

        # quest scripts
        $qs = $qGroup.Group | Where-Object { $_.scope -eq "quest" } |
              Group-Object script_index
        foreach ($sg in $qs) {
            $si = [int]$sg.Name
            $sSrc = $qSrc.scripts[$si]
            if (-not $sSrc) { continue }

            $sOut = [ordered]@{
                name = $sSrc.name
                script_index = $si
                properties = @()
            }

            foreach ($pSel in $sg.Group) {
                $pSrc = $sSrc.properties | Where-Object { $_.name -eq $pSel.property_name } | Select-Object -First 1
                if ($pSrc) {
                    $sOut.properties += [ordered]@{
                        name  = $pSrc.name
                        type  = $pSrc.type
                        value = $pSrc.value
                    }
                }
            }

            $qOut.scripts += $sOut
        }

        # alias scripts
        $as = $qGroup.Group | Where-Object { $_.scope -eq "alias" } |
              Group-Object alias_index
        foreach ($ag in $as) {
            $ai = [int]$ag.Name
            $aSrc = $qSrc.aliases[$ai]
            if (-not $aSrc) { continue }

            $aOut = [ordered]@{
                alias_index = $ai
                alias_id    = $aSrc.alias_id
                alias_name  = $aSrc.alias_name
                scripts     = @()
            }

            $asg = $ag.Group | Group-Object script_index
            foreach ($sg in $asg) {
                $si = [int]$sg.Name
                $sSrc = $aSrc.scripts[$si]
                if (-not $sSrc) { continue }

                $sOut = [ordered]@{
                    name = $sSrc.name
                    script_index = $si
                    properties = @()
                }

                foreach ($pSel in $sg.Group) {
                    $pSrc = $sSrc.properties | Where-Object { $_.name -eq $pSel.property_name } | Select-Object -First 1
                    if ($pSrc) {
                        $sOut.properties += [ordered]@{
                            name  = $pSrc.name
                            type  = $pSrc.type
                            value = $pSrc.value
                        }
                    }
                }

                $aOut.scripts += $sOut
            }

            $qOut.aliases += $aOut
        }

        $subset.quests += [pscustomobject]$qOut
    }

    return $subset
}

function Apply-FlatCsvToSubset($subset, [string]$csvPath) {
    $rows = Import-Csv -LiteralPath $csvPath

    foreach ($r in $rows) {
        $q = $subset.quests | Where-Object { $_.formid -eq $r.quest_formid } | Select-Object -First 1
        if (-not $q) { continue }

        $valueObj = $null
        try {
            $valueObj = $r.value_json | ConvertFrom-Json
        } catch {
            # if someone typed a raw scalar (e.g. 5) instead of JSON, treat as string
            $valueObj = $r.value_json
        }

        if ($r.scope -eq "quest") {
            $s = $q.scripts | Where-Object { $_.script_index -eq [int]$r.script_index } | Select-Object -First 1
            if (-not $s) { continue }
            $p = $s.properties | Where-Object { $_.name -eq $r.property_name } | Select-Object -First 1
            if (-not $p) { continue }
            $p.value = $valueObj
        }
        elseif ($r.scope -eq "alias") {
            $a = $q.aliases | Where-Object { $_.alias_index -eq [int]$r.alias_index } | Select-Object -First 1
            if (-not $a) { continue }
            $s = $a.scripts | Where-Object { $_.script_index -eq [int]$r.script_index } | Select-Object -First 1
            if (-not $s) { continue }
            $p = $s.properties | Where-Object { $_.name -eq $r.property_name } | Select-Object -First 1
            if (-not $p) { continue }
            $p.value = $valueObj
        }
    }

    return $subset
}

function Load-ModelFromPath([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    if ([IO.Path]::GetExtension($path).ToLowerInvariant() -ne ".json") { return }

    $global:ModelPath = $path
    $global:Model = Read-JsonFile $global:ModelPath
    Populate-Tree $global:Model

    $lblStatus.Text = "Loaded: $($global:ModelPath)"
    LogLine "Loaded JSON: $($global:ModelPath)"
    LogLine "Source file: $($global:Model.source_file)"
    LogLine "Quests: $(@($global:Model.quests).Count)"
}


function Export-StructTableCsv($model, $sel, $outPath) {
    # Exports Array-of-Struct to a "table" CSV: one row per struct element, columns = member names
    $q = $model.quests | Where-Object { $_.formid -eq $sel.quest_formid } | Select-Object -First 1
    if (-not $q) { return }

    if ($sel.scope -eq "quest") {
        $script = $q.scripts[$sel.script_index]
        $prop = $script.properties | Where-Object { $_.name -eq $sel.property_name } | Select-Object -First 1
    } else {
        $alias = $q.aliases[$sel.alias_index]
        $script = $alias.scripts[$sel.script_index]
        $prop = $script.properties | Where-Object { $_.name -eq $sel.property_name } | Select-Object -First 1
    }
    if (-not $prop) { return }
    if (-not (Is-StructArrayType $prop.type)) { return }

    $arr = @($prop.value)
    if ($arr.Count -eq 0) {
        # emit header-only table with Index column
        [pscustomobject]@{ Index = 0 } | Select-Object Index | Export-Csv -LiteralPath $outPath -NoTypeInformation -Encoding UTF8
        return
    }

    # union of all member names
    $memberNames = New-Object System.Collections.Generic.HashSet[string]
    foreach ($item in $arr) {
        foreach ($p in $item.PSObject.Properties) { [void]$memberNames.Add($p.Name) }
    }
    $cols = @("Index") + ($memberNames | Sort-Object)

    $outRows = New-Object System.Collections.Generic.List[object]
    for ($i=0; $i -lt $arr.Count; $i++) {
        $o = [ordered]@{ Index = $i }
        foreach ($c in $cols | Where-Object { $_ -ne "Index" }) {
            $o[$c] = $arr[$i].PSObject.Properties[$c].Value
        }
        $outRows.Add([pscustomobject]$o)
    }

    $outRows | Select-Object $cols | Export-Csv -LiteralPath $outPath -NoTypeInformation -Encoding UTF8
}

function Sanitize-Name([string]$s) {
    if ($null -eq $s) { return "" }
    return ($s -replace '[^\w\-\.]+', '_')
}

function TableCsv-ToValueJson([string]$tablePath) {
    # Reads tables\*.csv format: Index + member columns
    $rows = Import-Csv -LiteralPath $tablePath
    $out = @()

    foreach ($r in $rows) {
        $obj = [ordered]@{}
        foreach ($p in $r.PSObject.Properties) {
            if ($p.Name -eq "Index") { continue }
            # Keep empty cells as null? For now preserve as string/empty.
            $obj[$p.Name] = $p.Value
        }
        $out += [pscustomobject]$obj
    }

    return ($out | ConvertTo-Json -Depth 64 -Compress)
}

function Merge-TablesIntoFlatCsv([string]$batchDir) {
    $flatPath  = Join-Path $batchDir "flat_properties.csv"
    $tablesDir = Join-Path $batchDir "tables"

    if (-not (Test-Path -LiteralPath $flatPath)) { throw "Missing flat_properties.csv in batch folder." }
    if (-not (Test-Path -LiteralPath $tablesDir)) { return $flatPath } # nothing to merge

    $flat = Import-Csv -LiteralPath $flatPath
    $tableFiles = Get-ChildItem -LiteralPath $tablesDir -Filter "*.csv" -File -ErrorAction SilentlyContinue

    if (-not $tableFiles -or $tableFiles.Count -eq 0) { return $flatPath }

    # Backup flat CSV once per run
    $bakPath = Join-Path $batchDir ("flat_properties.bak_{0}.csv" -f (Get-Date).ToString("yyyyMMdd_HHmmss"))
    Copy-Item -LiteralPath $flatPath -Destination $bakPath -Force

    foreach ($tf in $tableFiles) {
        # Current naming pattern we emit:
        #   {quest_edid}_{script_index}_{safeProp}.csv
        # NOTE: this DOES NOT encode scope/alias_index, so matching is best-effort.
        $base = [IO.Path]::GetFileNameWithoutExtension($tf.Name)
        $parts = $base -split "_", 3
        if ($parts.Count -lt 3) {
            LogLine "Skip table (unexpected name): $($tf.Name)"
            continue
        }

        $questEdid = $parts[0]
        $scriptIdx = $parts[1]
        $safeProp  = $parts[2]

        # Find matching row(s) in flat
        $matches = @(
            $flat | Where-Object {
                $_.quest_edid -eq $questEdid -and
                $_.script_index -eq $scriptIdx -and
                (Sanitize-Name $_.property_name) -eq $safeProp
            }
        )

        if ($matches.Count -eq 0) {
            LogLine "No flat row match for table: $($tf.Name)"
            continue
        }
        if ($matches.Count -gt 1) {
            LogLine "Ambiguous table match (multiple flat rows) for: $($tf.Name)  -> NOT applied"
            continue
        }

        $newValueJson = TableCsv-ToValueJson -tablePath $tf.FullName

        # Apply to the single matching object reference (update the flat row)
        $m = $matches[0]
        $m.value_json = $newValueJson

        LogLine "Applied table -> value_json: $($tf.Name)"
    }

    # Write merged flat back
    $flat | Export-Csv -LiteralPath $flatPath -NoTypeInformation -Encoding UTF8
    LogLine "Merged tables into flat_properties.csv (backup: $(Split-Path -Leaf $bakPath))"

    return $flatPath
}

function Process-BatchFolder([string]$batchDir) {
    # same logic as your $btnProcessBatch click handler, but callable
    if (-not $batchDir -or -not (Test-Path -LiteralPath $batchDir)) { throw "Batch folder not found." }

    LogLine "Processing batch: $batchDir"

    $flatPath = Merge-TablesIntoFlatCsv -batchDir $batchDir

    $subsetPath = Join-Path $batchDir "subset.json"
    if (-not (Test-Path -LiteralPath $subsetPath)) { throw "Missing subset.json in batch folder." }

    $subset = Read-JsonFile $subsetPath
    $subset = Apply-FlatCsvToSubset $subset $flatPath

    $outPath = Join-Path $batchDir "subset.updated.json"
    Write-JsonFile $subset $outPath

    LogLine "Wrote subset.updated.json"
    $global:LastBatchDir = $batchDir
    return $outPath
}

function Rebuild-SubsetFromFlatCsv([string]$flatCsvPath) {
    $batchDir = Split-Path -Parent $flatCsvPath
    $subsetPath = Join-Path $batchDir "subset.json"
    if (-not (Test-Path -LiteralPath $subsetPath)) { throw "Missing subset.json next to flat_properties.csv." }

    LogLine "Rebuilding subset.updated.json from flat CSV: $flatCsvPath"

    $subset = Read-JsonFile $subsetPath
    $subset = Apply-FlatCsvToSubset $subset $flatCsvPath

    $outPath = Join-Path $batchDir "subset.updated.json"
    Write-JsonFile $subset $outPath

    LogLine "Wrote subset.updated.json"
    $global:LastBatchDir = $batchDir
    return $outPath
}


# ---------------- GUI ----------------

$form = New-Object System.Windows.Forms.Form
$form.Text = "VMAD Quest Property Editor (JSON -> CSV -> JSON)"
$form.Size = New-Object System.Drawing.Size(1280, 860)
$form.StartPosition = "CenterScreen"
$form.AllowDrop = $true

$tree = New-Object System.Windows.Forms.TreeView
$tree.CheckBoxes = $true
$tree.HideSelection = $false
$tree.Location = New-Object System.Drawing.Point(12, 12)
$tree.Size = New-Object System.Drawing.Size(780, 700)

$log = New-Object System.Windows.Forms.TextBox
$log.Multiline = $true
$log.ScrollBars = "Vertical"
$log.ReadOnly = $true
$log.Location = New-Object System.Drawing.Point(805, 12)
$log.Size = New-Object System.Drawing.Size(350, 540)

function LogLine([string]$s) {
    $log.AppendText($s + [Environment]::NewLine)
}

$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Text = "Load JSON..."
$btnLoad.Location = New-Object System.Drawing.Point(805, 565)
$btnLoad.Size = New-Object System.Drawing.Size(110, 32)

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = "Create Edit Batch"
$btnExport.Location = New-Object System.Drawing.Point(925, 565)
$btnExport.Size = New-Object System.Drawing.Size(230, 32)

$btnOpenBatch = New-Object System.Windows.Forms.Button
$btnOpenBatch.Text = "Open batch folder"
$btnOpenBatch.Location = New-Object System.Drawing.Point(805, 605)
$btnOpenBatch.Size = New-Object System.Drawing.Size(350, 32)

$btnProcessBatch = New-Object System.Windows.Forms.Button
$btnProcessBatch.Text = "Process updated batch folder"
$btnProcessBatch.Location = New-Object System.Drawing.Point(805, 645)
$btnProcessBatch.Size = New-Object System.Drawing.Size(350, 32)

$btnReintegrate = New-Object System.Windows.Forms.Button
$btnReintegrate.Text = "Rebuild subset.updated.json from CSV..."
$btnReintegrate.Location = New-Object System.Drawing.Point(805, 685)
$btnReintegrate.Size = New-Object System.Drawing.Size(350, 32)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "No file loaded."
$lblStatus.Location = New-Object System.Drawing.Point(12, 670)
$lblStatus.Size = New-Object System.Drawing.Size(780, 60)

$form.Controls.AddRange(@($tree, $log, $btnLoad, $btnExport, $btnProcessBatch, $btnOpenBatch, $btnReintegrate, $lblStatus))

$global:Model = $null
$global:ModelPath = $null
$global:LastBatchDir = $null

function New-Node([string]$text, $tag) {
    $n = New-Object System.Windows.Forms.TreeNode($text)
    $n.Tag = $tag
    return $n
}

function Populate-Tree($model) {
    $tree.Nodes.Clear()

    foreach ($q in $model.quests) {
        $qNode = New-Node ("{0} [{1}]" -f $q.edid, $q.formid) @{ kind="quest"; quest_formid=$q.formid }

        # Quest Scripts
        $qsNode = New-Node "Quest Scripts" @{ kind="quest_scripts"; quest_formid=$q.formid }
        for ($si=0; $si -lt @($q.scripts).Count; $si++) {
            $s = $q.scripts[$si]
            $sNode = New-Node ("[{0}] {1}" -f $s.script_index, $s.name) @{ kind="quest_script"; quest_formid=$q.formid; scope="quest"; script_index=[int]$s.script_index; script_name=$s.name }

            foreach ($p in @($s.properties)) {
                $pNode = New-Node ("{0} : {1}" -f $p.name, $p.type) @{
                    kind="property"; quest_formid=$q.formid; scope="quest"; alias_index=$null;
                    script_index=[int]$s.script_index; script_name=$s.name; property_name=$p.name; property_type=$p.type
                }
                $sNode.Nodes.Add($pNode) | Out-Null
            }
            $qsNode.Nodes.Add($sNode) | Out-Null
        }
        $qNode.Nodes.Add($qsNode) | Out-Null

        # Aliases
        $aRoot = New-Node "Aliases" @{ kind="aliases"; quest_formid=$q.formid }
        for ($ai=0; $ai -lt @($q.aliases).Count; $ai++) {
            $a = $q.aliases[$ai]
            $aText = "[{0}] {1}" -f $ai, $a.alias_name
            $aNode = New-Node $aText @{ kind="alias"; quest_formid=$q.formid; alias_index=$ai; alias_name=$a.alias_name; alias_id=$a.alias_id }

            for ($si=0; $si -lt @($a.scripts).Count; $si++) {
                $s = $a.scripts[$si]
                $sNode = New-Node ("[{0}] {1}" -f $s.script_index, $s.name) @{
                    kind="alias_script"; quest_formid=$q.formid; scope="alias"; alias_index=$ai;
                    script_index=[int]$s.script_index; script_name=$s.name
                }

                foreach ($p in @($s.properties)) {
                    $pNode = New-Node ("{0} : {1}" -f $p.name, $p.type) @{
                        kind="property"; quest_formid=$q.formid; scope="alias"; alias_index=$ai;
                        script_index=[int]$s.script_index; script_name=$s.name; property_name=$p.name; property_type=$p.type
                    }
                    $sNode.Nodes.Add($pNode) | Out-Null
                }

                $aNode.Nodes.Add($sNode) | Out-Null
            }

            $aRoot.Nodes.Add($aNode) | Out-Null
        }
        $qNode.Nodes.Add($aRoot) | Out-Null

        $tree.Nodes.Add($qNode) | Out-Null
    }

    $tree.ExpandAll()
}

function Get-CheckedPropertySelections([System.Windows.Forms.TreeNodeCollection]$nodes) {
    $out = New-Object System.Collections.Generic.List[hashtable]

    foreach ($n in $nodes) {
        if ($n.Checked -and $n.Tag -and $n.Tag.kind -eq "property") {
            $t = $n.Tag
            $out.Add(@{
                quest_formid   = $t.quest_formid
                scope          = $t.scope
                alias_index    = if ($t.scope -eq "alias") { [int]$t.alias_index } else { $null }
                script_index   = [int]$t.script_index
                property_name  = $t.property_name
            })
        }

        if ($n.Nodes.Count -gt 0) {
            foreach ($child in (Get-CheckedPropertySelections $n.Nodes)) { $out.Add($child) }
        }
    }

    return $out
}

$btnLoad.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "VMAD JSON (*.json)|*.json|All files (*.*)|*.*"
    if ($dlg.ShowDialog() -ne "OK") { return }

    try {
        Load-ModelFromPath $dlg.FileName
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to load JSON:`n$($_.Exception.Message)")
    }

})

$btnExport.Add_Click({
    if (-not $global:Model) { return }

    $sel = Get-CheckedPropertySelections $tree.Nodes
    if ($sel.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No properties checked. Check one or more properties in the tree.")
        return
    }

    $baseDir = Split-Path -Parent $global:ModelPath
    $batchDir = Join-Path $baseDir ("VMAD_EditBatch_" + (Get-Timestamp))
    Ensure-Dir $batchDir
    $global:LastBatchDir = $batchDir

    $subset = Build-SubsetFromSelection $global:Model $sel
    $manifest = [pscustomobject]@{
        format = "VMAD-EditManifest-1"
        created_utc = (Get-Date).ToUniversalTime().ToString("o")
        source_master_json = (Split-Path -Leaf $global:ModelPath)
        source_file = $global:Model.source_file
        batch_id = New-GuidString
        selection_count = $sel.Count
        selection = $sel
        outputs = @()
    }

    $subsetPath = Join-Path $batchDir "subset.json"
    $manifestPath = Join-Path $batchDir "manifest.json"
    Write-JsonFile $subset $subsetPath
    Write-JsonFile $manifest $manifestPath

    # flat csv
    $flatRows = Flatten-SelectionsToRows $global:Model $sel
    $flatPath = Join-Path $batchDir "flat_properties.csv"
    $flatRows | Export-Csv -LiteralPath $flatPath -NoTypeInformation -Encoding UTF8

    LogLine "Created batch: $batchDir"
    LogLine "Wrote subset.json"
    LogLine "Wrote manifest.json"
    LogLine "Wrote flat_properties.csv ($($flatRows.Count) rows)"

    # optional table CSVs for Array of Struct
    $tablesDir = Join-Path $batchDir "tables"
    Ensure-Dir $tablesDir
    $tableCount = 0

    foreach ($r in $flatRows) {
        if (Is-StructArrayType $r.property_type) {
            $safeProp = ($r.property_name -replace '[^\w\-\.]+', '_')
            $fileName = "{0}_{1}_{2}.csv" -f $r.quest_edid, $r.script_index, $safeProp
            $outPath = Join-Path $tablesDir $fileName

            $selItem = @{
                quest_formid  = $r.quest_formid
                scope         = $r.scope
                alias_index   = if ($r.scope -eq "alias") { [int]$r.alias_index } else { $null }
                script_index  = [int]$r.script_index
                property_name = $r.property_name
            }

            Export-StructTableCsv $global:Model $selItem $outPath
            $tableCount++
        }
    }

    LogLine "Wrote struct tables: $tableCount (in .\tables\)"
    [System.Windows.Forms.MessageBox]::Show("Batch created.`n`n$batchDir")
})

$btnOpenBatch.Add_Click({
    if (-not $global:LastBatchDir -or -not (Test-Path -LiteralPath $global:LastBatchDir)) {
        [System.Windows.Forms.MessageBox]::Show("No batch folder available yet.")
        return
    }

    Start-Process explorer.exe $global:LastBatchDir
})


$btnReintegrate.Add_Click({
    if (-not $global:LastBatchDir) {
        [System.Windows.Forms.MessageBox]::Show("No batch directory found. Create an edit batch first.")
        return
    }

    $subsetPath = Join-Path $global:LastBatchDir "subset.json"
    if (-not (Test-Path -LiteralPath $subsetPath)) {
        [System.Windows.Forms.MessageBox]::Show("subset.json not found in last batch dir:`n$($global:LastBatchDir)")
        return
    }

    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.InitialDirectory = $global:LastBatchDir
    $dlg.Filter = "Flat CSV (flat_properties.csv)|flat_properties.csv|CSV (*.csv)|*.csv"
    if ($dlg.ShowDialog() -ne "OK") { return }

    try {
        $subset = Read-JsonFile $subsetPath
        $subset = Apply-FlatCsvToSubset $subset $dlg.FileName

        $outPath = Join-Path $global:LastBatchDir "subset.updated.json"
        Write-JsonFile $subset $outPath

        LogLine "Rebuilt subset.updated.json from CSV: $(Split-Path -Leaf $dlg.FileName)"
        [System.Windows.Forms.MessageBox]::Show("Wrote:`n$outPath")
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Reintegrate failed:`n$($_.Exception.Message)")
    }
})

$btnProcessBatch.Add_Click({
    # Choose batch folder (default to last batch)
    $batchDir = $global:LastBatchDir

    if (-not $batchDir -or -not (Test-Path -LiteralPath $batchDir)) {
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "Select a VMAD_EditBatch_* folder"
        if ($fbd.ShowDialog() -ne "OK") { return }
        $batchDir = $fbd.SelectedPath
        $global:LastBatchDir = $batchDir
    }

    try {
        LogLine "Processing batch: $batchDir"

        # 1) Merge table CSVs into flat_properties.csv
        $flatPath = Merge-TablesIntoFlatCsv -batchDir $batchDir

        # 2) Rebuild subset.updated.json from merged flat CSV
        $subsetPath = Join-Path $batchDir "subset.json"
        if (-not (Test-Path -LiteralPath $subsetPath)) { throw "Missing subset.json in batch folder." }

        $subset = Read-JsonFile $subsetPath
        $subset = Apply-FlatCsvToSubset $subset $flatPath

        $outPath = Join-Path $batchDir "subset.updated.json"
        Write-JsonFile $subset $outPath

        LogLine "Wrote subset.updated.json"
        [System.Windows.Forms.MessageBox]::Show("Batch processed successfully.`n`n$outPath")
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Process batch failed:`n$($_.Exception.Message)")
    }
    Start-Process explorer.exe $batchDir
})


# checkbox behavior: if you check a parent, optionally auto-check children
$tree.add_AfterCheck({
    param($sender, $e)
    # prevent recursion storms
    $tree.BeginUpdate()
    try {
        if ($e.Node.Nodes.Count -gt 0) {
            foreach ($child in $e.Node.Nodes) {
                $child.Checked = $e.Node.Checked
            }
        }
    } finally {
        $tree.EndUpdate()
    }
})

$form.add_DragEnter({
    param($sender, $e)
    if ($e.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
        $e.Effect = [Windows.Forms.DragDropEffects]::Copy
    } else {
        $e.Effect = [Windows.Forms.DragDropEffects]::None
    }
})

$form.add_DragDrop({
    param($sender, $e)

    try {
        $files = $e.Data.GetData([Windows.Forms.DataFormats]::FileDrop)
        if (-not $files -or $files.Length -eq 0) { return }

        # If multiple items dropped, just take the first for now (simple + predictable)
        $p = $files[0]

        # 1) Folder dropped -> treat as batch folder -> process
        if (Test-Path -LiteralPath $p -PathType Container) {
            $global:LastBatchDir = $p
            $outPath = Process-BatchFolder -batchDir $p
            [System.Windows.Forms.MessageBox]::Show("Batch processed successfully.`n`n$outPath")
            return
        }

        # From here down, it's a file
        $ext  = [IO.Path]::GetExtension($p).ToLowerInvariant()
        $name = [IO.Path]::GetFileName($p).ToLowerInvariant()

        switch ($ext) {

            ".json" {
                # Treat as main VMAD json -> load into tree
                Load-ModelFromPath $p
                return
            }

            ".csv" {
                # If they dropped flat_properties.csv -> rebuild subset.updated.json directly
                if ($name -eq "flat_properties.csv") {
                    $outPath = Rebuild-SubsetFromFlatCsv -flatCsvPath $p
                    [System.Windows.Forms.MessageBox]::Show("Rebuilt subset.updated.json from flat_properties.csv.`n`n$outPath")
                    return
                }

                # Any other CSV -> find the batch folder (current dir or parent dir)
                $csvDir = Split-Path -Parent $p
                $batchDir = $null
                
                # Build paths to check
                $searchPaths = @()
                if ($csvDir) {
                    $searchPaths += $csvDir
                    $parentDir = Split-Path -Parent $csvDir
                    if ($parentDir) {
                        $searchPaths += $parentDir
                    }
                }
                
                # Try each path
                foreach ($testDir in $searchPaths) {
                    $flatFile = Join-Path $testDir "flat_properties.csv"
                    $subsetFile = Join-Path $testDir "subset.json"
                    
                    if ((Test-Path -LiteralPath $flatFile) -and (Test-Path -LiteralPath $subsetFile)) {
                        $batchDir = $testDir
                        LogLine "Found batch folder: $batchDir"
                        break
                    }
                }
                
                if (-not $batchDir) {
                    $searchDetails = ""
                    foreach ($testDir in $searchPaths) {
                        $flatExists = Test-Path -LiteralPath (Join-Path $testDir "flat_properties.csv")
                        $subsetExists = Test-Path -LiteralPath (Join-Path $testDir "subset.json")
                        $searchDetails += "`n- $testDir (flat: $flatExists, subset: $subsetExists)"
                    }
                    [System.Windows.Forms.MessageBox]::Show("Could not find complete batch folder for CSV file.`n`nSearched paths:$searchDetails")
                    return
                }
                
                $global:LastBatchDir = $batchDir
                
                # First merge tables into flat_properties.csv
                $flatPath = Merge-TablesIntoFlatCsv -batchDir $batchDir
                LogLine "Merged tables into flat_properties.csv"
                
                # Ask user if they want to process the updated flat_properties.csv now
                $result = [System.Windows.Forms.MessageBox]::Show(
                    "Tables have been merged into flat_properties.csv.`n`nDo you want to process the updated flat_properties.csv now to generate subset.updated.json?",
                    "Process Updated CSV?",
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question
                )
                
                if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
                    # Complete the processing
                    $subsetPath = Join-Path $batchDir "subset.json"
                    $subset = Read-JsonFile $subsetPath
                    $subset = Apply-FlatCsvToSubset $subset $flatPath
                    $outPath = Join-Path $batchDir "subset.updated.json"
                    Write-JsonFile $subset $outPath
                    LogLine "Wrote subset.updated.json"
                    [System.Windows.Forms.MessageBox]::Show("Batch processed successfully (from CSV drop).`n`n$outPath")
                } else {
                    [System.Windows.Forms.MessageBox]::Show("Tables merged into flat_properties.csv.`n`nUse 'Process updated batch folder' button when ready to generate subset.updated.json.")
                }
                return
            }

            default {
                [System.Windows.Forms.MessageBox]::Show("Dropped item not recognized:`n$p`n`nDrop a batch folder, a .json, or a .csv.")
                return
            }
        }

    } catch {
        [System.Windows.Forms.MessageBox]::Show("Drop handling failed:`n$($_.Exception.Message)")
    }
})



$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
