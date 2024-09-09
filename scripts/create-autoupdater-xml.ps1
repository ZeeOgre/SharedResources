param (
    [string]$version = "0.0.1",
    [string]$url = "https://github.com/ZeeOgre/DevModManager/releases/latest/download/DevModManager.zip",
    [string]$changelog = "https://github.com/ZeeOgre/DevModManager/releases/latest",
    [string]$xmlOutputPath = "../output/AutoUpdater.xml"
)

$xmlContent = @"
<item>
  <version>$version</version>
  <url>$url</url>
  <changelog>$changelog</changelog>
</item>
"@

Set-Content -Path $xmlOutputPath -Value $xmlContent

Write-Output "AutoUpdater XML file created successfully."
