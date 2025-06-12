param (
    [string]$TextureRoot = "G:\SteamLibrary\steamapps\common\Starfield\XBOX\Data\Textures",
    [string]$XTexConvPath = "G:\SteamLibrary\steamapps\common\Starfield\Tools\AssetWatcher\Plugins\Starfield\xtexconv.exe"
)

Function Get-DDSFormatViaXTexconv {
    param($filePath)

    $procInfo = New-Object System.Diagnostics.ProcessStartInfo
    $procInfo.FileName = $XTexConvPath
    $procInfo.Arguments = "-info `"$filePath`""
    $procInfo.RedirectStandardOutput = $true
    $procInfo.UseShellExecute = $false
    $procInfo.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $procInfo
    $proc.Start() | Out-Null
    $infoOutput = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()

    $formatLine = $infoOutput -split "`n" | Where-Object { $_ -match "Format\s*:" } | Select-Object -First 1
    if ($formatLine -match ":\s*(.+)$") {
        return $matches[1].Trim()
    }

    return "Unknown"
}


$nonBc7 = @()

Write-Host "Scanning for DDS files in $TextureRoot..."
$ddsFiles = Get-ChildItem -Recurse -Path $TextureRoot -Filter *.dds

$i = 0
$total = $ddsFiles.Count
foreach ($dds in $ddsFiles) {
    $i++
    Write-Host "[$i / $total] Checking format of $($dds.FullName)"
    
    $format = Get-DDSFormatViaXTexconv $dds.FullName
    if ($format -notmatch "BC7") {
        $nonBc7 += [PSCustomObject]@{
            Format = $format
            Path   = $dds.FullName
        }
    }
}

if ($nonBc7.Count -eq 0) {
    Write-Host "All DDS files are already BC7 format."
    return
}

Write-Host "Found $($nonBc7.Count) files not using BC7:"
$nonBc7 | ForEach-Object { Write-Host "$($_.Format): $($_.Path)" }

$confirm = Read-Host "Convert all to BC7 in place? (Y/N)"
if ($confirm -ne "Y") { return }

foreach ($entry in $nonBc7) {
    $filePath = $entry.Path
    $folder = Split-Path $filePath
    $name = [System.IO.Path]::GetFileName($filePath)

    Write-Host "Converting $name..."

    & "$XTexConvPath" `
        -f BC7_UNORM_SRGB `
        -ft dds `
        -xbox `
        -m 1 `
        -if LINEAR `
        -y `
        -o "$folder" `
        "$filePath"
}

Write-Host "Conversion complete."
