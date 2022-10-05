# Dell Catalog Mirror
PowerShell module to mirror Dell update catalog.

## Install
This module is available on the PSGallery.

```powershell
PS> Install-Module DellCatalogMirror
```

## Usage
This example creates or updates a mirror for the R640 model server into the current directory.

```powershell
PS C:\dell-mirror> Import-DellCatalogXml | Optimize-DellCatalogXml -Models 'R640' -PassThru | Update-DellCatalogMirror
```
