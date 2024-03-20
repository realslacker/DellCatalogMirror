function Import-DellCatalogXml {
    <#
    .SYNOPSIS
    Import a Dell catalog and return an XML object
    .DESCRIPTION
    Import a Dell catalog and return an XML object. By default fetches the catalog from downloads.dell.com.
    #>
    [CmdletBinding( DefaultParameterSetName='Uri' )]
    [OutputType([xml])]
    param(
        
        [Parameter( ParameterSetName='Uri' )]
        [uri]
        $CatalogUri = 'https://downloads.dell.com/catalog/Catalog.xml.gz',

        [Parameter( ParameterSetName='File', Mandatory )]
        [string]
        $Path

    )

    if ( $PSCmdlet.ParameterSetName -eq 'Uri' ) {

        Write-Verbose 'Downloading catalog from Dell...'
        Write-Verbose ( 'Download URI: {0}' -f $CatalogUri )
        
        $CatalogDownload = Invoke-WebRequest -UseBasicParsing -Uri $CatalogUri

        if ( $CatalogDownload.Headers.'Content-Type' -eq 'application/x-gzip' ) {
            
            Write-Verbose 'Decompressing the catalog...'
            
            # decompress catalog
            $MemoryStream = [System.IO.MemoryStream]::new( $CatalogDownload.Content )
            $GZipStream = [System.IO.Compression.GZipStream]::new( $MemoryStream, [System.IO.Compression.CompressionMode]::Decompress )
            $ResultStream = [System.IO.MemoryStream]::new()
            $GZipStream.CopyTo($ResultStream)
            $MemoryStream.Close()
            $GZipStream.Close()
            $ResultStream.Close()
            
            # convert to byte array
            $ResultBytes = $ResultStream.ToArray()

            # convert to string
            $CatalogContent = [Text.Encoding]::Unicode.GetString( $ResultBytes[ 2 .. $ResultBytes.Count ] )

        } else {

            Write-Verbose 'Downloading catalog from Dell...'
            Write-Verbose ( 'Download URI: {0}' -f $CatalogUri )
            
            $CatalogContent = $CatalogDownload.Content

        }

    } else {

        $CatalogContent = Get-Content -Path $Path

    }
        
    Write-Verbose 'Loading XML...'

    try {

        [xml]$CatalogXml = $CatalogContent
    
    } catch {

        throw ( 'Failed to process XML. {0}' -f $_.Exception.Message )

    }


    return $CatalogXml

}

class DellModelInfo {
    [string] $Brand
    [string] $Model
    [string] $SystemId
    [string] $Type
    DellModelInfo() {}
    DellModelInfo( [string]$Model ) {
        $this.Model = $Model
    }
    [string] ToString() {
        return $this.Model
    }
}

function Get-DellCatalogModels {
    <#
    .SYNOPSIS
    Parses supported models from the Dell update catalog.
    #>
    [CmdletBinding()]
    [OutputType([DellModelInfo])]
    param(

        [Parameter( Mandatory, ValueFromPipeline )]
        [xml]
        $CatalogXml

    )

    foreach ( $Brand in $CatalogXml.SelectNodes('/Manifest/SoftwareBundle').TargetSystems.Brand ) {
        foreach ( $Model in $Brand.Model ) {
            [DellModelInfo]@{
                Brand    = $Brand.Display.InnerText
                Model    = $Model.Display.InnerText
                SystemId = $Model.systemId
                Type     = $Model.systemIdType
            }
        }
    }

}

function Optimize-DellCatalogXml {
    <#
    .SYNOPSIS
    Optimize the catalog for specific models
    #>
    [CmdletBinding( DefaultParameterSetName = 'NoReturn' )]
    [OutputType( [xml], ParameterSetName='PassThru' )]
    [OutputType( [void], ParameterSetName='NoReturn' )]
    param(

        [Parameter( Mandatory, ValueFromPipeline )]
        [xml]
        $CatalogXml,

        [Parameter( Mandatory )]
        [string[]]
        $Models,

        [Parameter( Mandatory, ParameterSetName='PassThru')]
        [switch]
        $PassThru

    )

    Write-Verbose ( 'Optimizing Catalog for systems: {0}' -f ( $Models -join ', ' ) )

    Write-Verbose 'Removing unwanted software bundles...'
    
    Write-Verbose ( 'Before processing there are {0} bundles.' -f $CatalogXml.SelectNodes('/Manifest/SoftwareBundle').Count )
    
    # remove unwanted elements
    $CatalogXml.SelectNodes('/Manifest/SoftwareBundle').ForEach({
        if ( $_.TargetSystems.Brand.Model.Display.InnerText.Where({ $_ -in $Models }) ) {
            Write-Verbose ( '[KEEP]: {0} ({1})' -f $_.bundleId, ($_.TargetSystems.Brand.Model.Display.InnerText -join ', ') )
        } else {
            Write-Verbose ( '[REMOVE] {0}' -f $_.bundleId )
            $_.ParentNode.RemoveChild($_) > $null
        }
    })
    
    Write-Verbose ( 'After processing there are {0} bundles.' -f $CatalogXml.SelectNodes('/Manifest/SoftwareBundle').Count )
    
    Write-Verbose 'Removing unwanted software components...'
    
    Write-Verbose ( 'Before processing there are {0} software components.' -f $CatalogXml.SelectNodes('/Manifest/SoftwareComponent').Count )
    
    $PackagePaths = $CatalogXml.SelectNodes('//SoftwareBundle//Package').Path
    
    $CatalogXml.SelectNodes('/Manifest/SoftwareComponent').ForEach({
        if ( $_.Path.Split('/')[-1] -notin $PackagePaths ) {
            Write-Verbose ( '[REMOVE] {0}' -f $_.Name.Display.InnerText )
            $_.ParentNode.RemoveChild($_) > $null
        } else {
            Write-Verbose ( '[KEEP] {0}' -f $_.Name.Display.InnerText )
        }
    })
    
    Write-Verbose ( 'After processing there are {0} software components.' -f $CatalogXml.SelectNodes('/Manifest/SoftwareComponent').Count )

    if ( $PassThru ) {
        return $CatalogXml
    }

}


function Update-DellCatalogMirror {
    <#
    .SYNOPSIS
    Update a local mirror
    .DESCRIPTION
    Update a local mirror by downloading the updates specified in the catalog. Skips existing
    files.
    .PARAMETER Path
    Location of the mirror on disk
    #>
    [CmdletBinding( SupportsShouldProcess, ConfirmImpact='Low' )]
    param(
    
        [Parameter( Mandatory, ValueFromPipeline )]
        [xml]
        $CatalogXml,
    
        [Parameter( Mandatory )]
        [string]
        $Path
    
    )
    
    $ErrorActionPreference = 'Stop'

    $DownloadProtocol = $CatalogXml.Manifest.baseLocationAccessProtocols.ToLower() | Where-Object { $_ -in @( 'http', 'https' ) } | Select-Object -First 1
    $DownloadHost     = $CatalogXml.Manifest.baseLocation.ToLower()

    $BaseDownloadUri = '{0}://{1}' -f $DownloadProtocol, $DownloadHost
    
    $Path = Resolve-Path -Path $Path | Convert-Path
    
    Write-Verbose ( 'Repo Path: {0}' -f $Path )
    
    Write-Verbose 'Looking for existing downloads...'
    
    # find existing files
    [string[]]$ExistingItems = Get-ChildItem -Path $Path -File -Recurse | Where-Object { $_.Directory.FullName -ne $Path } | Select-Object -ExpandProperty FullName
    
    Write-Verbose ( 'Before processing there are {0} downloaded software components.' -f $ExistingItems.Count )

    $UpdatedCatalog = $false
    
    # download the components
    [string[]]$DownloadedItems = $CatalogXml.SelectNodes('/Manifest/SoftwareComponent').ForEach({
    
        $SoftwareComponent = $_
    
        Write-Host ( 'Processing: {0}' -f $SoftwareComponent.SelectNodes("./Name/Display[@lang='en']").InnerText )
    
        $DestinationPath = Join-Path $Path $SoftwareComponent.Path.Replace('/','\')
    
        if ( $DestinationPath -in $ExistingItems ) {
    
            if ( $SoftwareComponent.hashMD5 -eq (Get-FileHash $DestinationPath -Algorithm MD5).Hash ) {
                Write-Verbose ( 'Skipping existing file: {0}' -f $DestinationPath )
                return $DestinationPath
            } else {
                Write-Warning ( 'Existing file hash missmatch!' )
            }
    
        }
    
        New-Item -Path ( Split-Path $DestinationPath -Parent ) -ItemType Directory -Force > $null
    
        $DownloadUri = $BaseDownloadUri, $SoftwareComponent.Path -join '/'
    
        #Write-Verbose ( 'Downloading: {0}' -f $DownloadUri )

        if ( $PSCmdlet.ShouldProcess($DownloadUri, 'Download Software Package') ) {
    
            try {
        
                Invoke-WebRequest -UseBasicParsing -Uri $DownloadUri -OutFile $DestinationPath -ErrorVariable DownloadError -ErrorAction Stop > $null
        
            } catch {
        
                Write-Warning ''.PadRight(40,'-')
                Write-Warning 'DOWNLOAD FAILED'
                Write-Warning ( 'Error: {0}' -f $_.Exception.Message )
                $SoftwareComponent.SelectNodes('.//*[@URL]').URL | ForEach-Object {
                    Write-Warning ( 'Link: {0}' -f $_ )
                }
                Write-Warning ( 'Destination: {0}' -f $DestinationPath )
                Write-Warning ''.PadRight(40,'-')
                return
        
            }
        
            if ( $SoftwareComponent.hashMD5 -ne (Get-FileHash $DestinationPath -Algorithm MD5).Hash ) {
                
                Write-Warning 'Hash of downloaded file does not match manifest!'
        
            }
        
            Write-Verbose ( 'New file: {0}' -f $DestinationPath )

            $UpdatedCatalog = $true
        
            return $DestinationPath

        }
    
    })
    
    Write-Verbose ( 'Processed {0} new software components.' -f $DownloadedItems.Count )

    if ( $UpdatedCatalog ) {
    
        Write-Verbose 'Exporting Catalog...'
        
        # clean up the manifest and save
        $CatalogXml.Manifest.RemoveAttribute('baseLocationAccessProtocols')
        $CatalogXml.Manifest.baseLocation = ''
        $CatalogXml.Save( "$Path\Catalog.xml" )
        
        Write-Verbose 'Cleaning up old software components...'
        
        # remove old downloaded items
        if ( $ExtraItems = $ExistingItems | Where-Object { $_ -notin $DownloadedItems } ) {
            Remove-Item -Path $ExtraItems -Confirm:$false -Force
        }

    }

}

