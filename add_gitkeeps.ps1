$folders = @(
    "assets/audio",
    "assets/fonts",
    "assets/textures",
    "assets/themes",
    "scenes/entities",
    "scenes/ui",
    "scenes/levels",
    "scripts/resources",
    "scripts/utils",
    "docs"
)

foreach ($folder in $folders) {
    $path = Join-Path $folder ".gitkeep"
    if (-not (Test-Path $path)) {
        New-Item -Path $path -ItemType File -Force
        Write-Host "Created: $path"
    }
}
