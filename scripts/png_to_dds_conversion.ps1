# Paths
$Xtexconv = "M:\SteamLibrary\steamapps\common\Starfield\Tools\AssetWatcher\Plugins\Starfield\xtexconv.exe"
$SourceFolder = "M:\SyncShare\GameDriveShare\image_source\raw_source\PNGTEST"
$DestPC = "M:\SyncShare\GameDriveShare\image_source\ready_source\textures\PNGTEST"
$DestXbox = "M:\SyncShare\GameDriveShare\image_source\xbox_out\textures\pngtest"

# Function to Convert PNG to DDS
function Convert-PNGToDDS {
    param (
        [string]$SourceFile,
        [string]$OutputFolder,
        [string]$Format,
        [string]$Platform
    )

    # Preserve relative path structure
    $RelativePath = $SourceFile.Substring($SourceFolder.Length + 1)
    $RelativePath = $RelativePath -replace '\\', '/'  # Standardize slashes
    $OutputFile = "$OutputFolder\$RelativePath" -replace "\.png$", ".dds"

    # Ensure output directory exists
    $OutputDir = Split-Path -Parent $OutputFile
    if (!(Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    # Run conversion using xtexconv
    Write-Host "[$Platform] Converting: $SourceFile -> $OutputFile"
    Start-Process -NoNewWindow -Wait -FilePath $Xtexconv -ArgumentList `
        "-f $Format -m 10 -y -o `"$OutputDir`" `"$SourceFile`""
}

# Find all PNG files recursively
$PNGFiles = Get-ChildItem -Path $SourceFolder -Recurse -Filter "*.png"

# Process for PC
foreach ($PNG in $PNGFiles) {
    Convert-PNGToDDS -SourceFile $PNG.FullName -OutputFolder $DestPC -Format "BC3_UNORM" -Platform "PC"
}

# Process for Xbox
#foreach ($PNG in $PNGFiles) {
#    Convert-PNGToDDS -SourceFile $PNG.FullName -OutputFolder $DestXbox -Format "BC7_UNORM" -Platform "Xbox"
#}

Write-Host "✅ Conversion Complete!"
