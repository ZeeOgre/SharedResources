param (
    [string]$SettingsFile,
    [string]$CsprojFilePath,
    [string]$AppConfigFilePath,
    [string]$VersionTxtFilePath
)

Write-Output "SettingsFile: $SettingsFile"
Write-Output "CsprojFilePath: $CsprojFilePath"
Write-Output "AppConfigFilePath: $AppConfigFilePath"
Write-Output "VersionTxtFilePath: $VersionTxtFilePath"
Write-Output "WhatIf: $WhatIf"

# Resolve paths to absolute paths
$ResolvedSettingsFile = (Resolve-Path -Path $SettingsFile).Path
$ResolvedCsprojFilePath = (Resolve-Path -Path $CsprojFilePath).Path
$ResolvedAppConfigFilePath = (Resolve-Path -Path $AppConfigFilePath).Path
$ResolvedVersionTxtFilePath = (Resolve-Path -Path $VersionTxtFilePath).Path
$ResolvedVdprojFilePath = (Resolve-Path -Path $VdprojFilePath).Path

Write-Host "Resolved SettingsFile: $ResolvedSettingsFile"
Write-Host "Resolved VersionTxtFilePath: $ResolvedVersionTxtFilePath"
Write-Host "Resolved CsprojFilePath: $ResolvedCsprojFilePath"
Write-Host "Resolved AppConfigFilePath: $ResolvedAppConfigFilePath"
Write-Host "Resolved VdprojFilePath: $ResolvedVdprojFilePath"


# Function to load XML file
function Get-CurrentVersion {
    param (
        [string]$filePath
    )

    [xml]$xml = Get-Content -Path $filePath -Raw -Encoding UTF8

    $namespaceManager = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $namespaceManager.AddNamespace("ns", "http://schemas.microsoft.com/VisualStudio/2004/01/settings")

    $currentVersionNode = $xml.SelectSingleNode("//ns:Setting[@Name='version']/ns:Value", $namespaceManager)
    $currentVersion = $currentVersionNode.InnerText

    $result = [PSCustomObject]@{
        Version = $currentVersion
        Node = $currentVersionNode
        Xml = $xml
    }

    return $result
}

# Function to increment the version
function Increment-Version {
    param (
        [string]$currentVersion
    )
    $versionParts = $currentVersion -split '\.'
    if ($versionParts.Length -eq 3) {
        $newVersion = "$($versionParts[0]).$($versionParts[1]).$([int]$versionParts[2] + 1)"
        return $newVersion
    } else {
        Write-Output "Error: Version format is incorrect. Expected format: X.X.X"
        exit 1
    }
}

# Function to update the version in the settings file
function Update-SettingsVersion {
    param (
        [xml]$xml,
        [System.Xml.XmlNode]$currentVersionNode,
        [string]$newVersion,
        [string]$settingsFile,
        [switch]$WhatIf
    )
    
    Write-Output "Updating settings file..."
    Write-Output "Current Version Node: $currentVersionNode"
    Write-Output "New Version: $newVersion"
    Write-Output "Settings File: $settingsFile"
    
    $currentVersionNode.InnerText = $newVersion
    
    if ($WhatIf) {
        Write-Output "WhatIf: $settingsFile would be updated with new version $newVersion"
    } else {
        if (![string]::IsNullOrEmpty($settingsFile)) {
            $xml.Save($settingsFile)
            Write-Output "Settings file updated successfully."
        } else {
            throw "Settings file path is empty or null."
        }
    }
}

# Function to update the version in the .csproj file
function Update-CsprojVersion {
    param (
        [string]$newVersion,
        [string]$csprojFilePath,
        [switch]$WhatIf
    )
    if ([string]::IsNullOrEmpty($csprojFilePath)) {
        throw "Csproj file path is empty or null."
    }
    
    # Read the .csproj file with UTF-8 encoding
    [xml]$csprojXml = [xml](Get-Content -Path $csprojFilePath -Raw -Encoding UTF8)
    
    $versionNode = $csprojXml.SelectSingleNode("//Version")
    if ($versionNode -ne $null) {
        $versionNode.InnerText = $newVersion
        Write-Output "Updated Version in csproj: $newVersion"
    } else {
        $propertyGroupNode = $csprojXml.SelectSingleNode("//PropertyGroup")
        if ($propertyGroupNode -ne $null) {
            $newVersionNode = $csprojXml.CreateElement("Version")
            $newVersionNode.InnerText = $newVersion
            $propertyGroupNode.AppendChild($newVersionNode)
            Write-Output "Created and updated Version node in csproj: $newVersion"
        } else {
            Write-Output "Error: PropertyGroup node not found in csproj file."
            return
        }
    }
    
    if ($WhatIf) {
        Write-Output "WhatIf: $csprojFilePath would be updated with new version $newVersion"
    } else {
        $maxRetries = 5
        $retryCount = 0
        $success = $false

        while (-not $success -and $retryCount -lt $maxRetries) {
            try {
                # Write the .csproj file with UTF-8 encoding
                $csprojXml.Save($csprojFilePath)
                [System.IO.File]::WriteAllText($csprojFilePath, [System.IO.File]::ReadAllText($csprojFilePath), [System.Text.Encoding]::UTF8)
                $success = $true
            } catch {
                $retryCount++
                Write-Output "Attempt ${retryCount}: Failed to write to $csprojFilePath. Retrying in 1 second..."
                Start-Sleep -Seconds 1
            }
        }

        if (-not $success) {
            throw "Failed to write to $csprojFilePath after $maxRetries attempts."
        }
    }
}

# Function to update the version in the App.config file
function Update-AppConfigVersion {
    param (
        [string]$newVersion,
        [string]$appConfigFilePath,
        [switch]$WhatIf
    )
    if ([string]::IsNullOrEmpty($appConfigFilePath)) {
        throw "App.config file path is empty or null."
    }
    [xml]$appConfigXml = Get-Content $appConfigFilePath
    $versionNode = $appConfigXml.SelectSingleNode("//DevModManager.App.Properties.Settings/setting[@name='version']/value")
    if ($versionNode -ne $null) {
        $versionNode.InnerText = $newVersion
        Write-Output "Updated Version in App.config: $newVersion"
        if ($WhatIf) {
            Write-Output "WhatIf: $appConfigFilePath would be updated with new version $newVersion"
        } else {
            $appConfigXml.Save($appConfigFilePath)
        }
    } else {
        Write-Output "Error: Version node not found in App.config file."
    }
}

# Function to update the version in the version.txt file
function Update-VersionTxt {
    param (
        [string]$newVersion,
        [string]$versionTxtFilePath,
        [switch]$WhatIf
    )
    if ([string]::IsNullOrEmpty($versionTxtFilePath)) {
        throw "Version.txt file path is empty or null."
    }
    Write-Output "Updating version.txt file..."
    if ($WhatIf) {
        Write-Output "WhatIf: $versionTxtFilePath would be updated with new version $newVersion"
    } else {
        Set-Content -Path $versionTxtFilePath -Value $newVersion
        Write-Output "version.txt file updated successfully."
    }
}
# Function to create AutoUpdater.xml
function Create-AutoUpdaterXml {
    param (
        [string]$version,
        [string]$url = "https://github.com/ZeeOgre/DevModManager/releases/latest/download/DevModManager.msi",
        [string]$changelog = "https://github.com/ZeeOgre/DevModManager/releases/latest",
        [string]$xmlOutputPath
    )

    $xmlContent = @"
<item>
  <version>$version</version>
  <url>$url</url>
  <changelog>$changelog</changelog>
</item>
"@

    Set-Content -Path $xmlOutputPath -Value $xmlContent
    Write-Output "AutoUpdater XML file created successfully at $xmlOutputPath."
}

try {
    # Main script execution
    Write-Host "Resolved SettingsFile: $ResolvedSettingsFile"
    Write-Host "Resolved CsprojFilePath: $ResolvedCsprojFilePath"
    Write-Host "Resolved AppConfigFilePath: $ResolvedAppConfigFilePath"
    Write-Host "Resolved VersionTxtFilePath: $ResolvedVersionTxtFilePath"

    $result = Get-CurrentVersion -filePath $SettingsFile
    $currentVersion = $result.Version
    $currentVersionNode = $result.Node
    $xml = $result.Xml
    $newVersion = Increment-Version -currentVersion $currentVersion

    Update-SettingsVersion -xml $xml -currentVersionNode $currentVersionNode -newVersion $newVersion -settingsFile $SettingsFile -WhatIf:$WhatIf
    Update-VersionTxt -newVersion $newVersion -versionTxtFilePath $VersionTxtFilePath -WhatIf:$WhatIf
    Update-CsprojVersion -newVersion $newVersion -csprojFilePath $CsprojFilePath -WhatIf:$WhatIf
    Update-AppConfigVersion -newVersion $newVersion -appConfigFilePath $AppConfigFilePath -WhatIf:$WhatIf
    # Derive XmlOutputPath from VersionTxtFilePath
    $XmlOutputPath = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($VersionTxtFilePath), "AutoUpdater.xml")

    # Create AutoUpdater.xml
    Create-AutoUpdaterXml -version $newVersion -xmlOutputPath $XmlOutputPath

    Write-Output "Version increment completed successfully."
} catch {
    Write-Error "An error occurred: $_"
    exit 1
}
