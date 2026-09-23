# Install or verify Odin for Windows CI. Honors ODIN_TAG (default
# dev-2026-09) and optional ODIN_RELEASE_URL.
$ErrorActionPreference = "Stop"

$OdinTag = if ($env:ODIN_TAG) { $env:ODIN_TAG } else { "dev-2026-09" }
$MinMonth = "2026-09"
$InstallDir = if ($env:ODIN_INSTALL_DIR) { $env:ODIN_INSTALL_DIR } else {
	Join-Path $env:USERPROFILE ".local\odin"
}

function Test-OdinMonth {
	$ver = (& odin version 2>&1 | Out-String).Trim()
	if ($ver -notmatch 'dev-(\d{4}-\d{2})') { return $false }
	return ($Matches[1] -ge $MinMonth)
}

$existing = Get-Command odin -ErrorAction SilentlyContinue
if ($existing -and (Test-OdinMonth)) {
	Write-Host "ci_setup_odin: using existing $($existing.Source)"
	exit 0
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$Arch = $env:PROCESSOR_ARCHITECTURE
if ($Arch -ne "AMD64") {
	throw "ci_setup_odin: unsupported arch $Arch"
}

$urls = @()
if ($env:ODIN_RELEASE_URL) {
	$urls = @($env:ODIN_RELEASE_URL)
} else {
	$urls = @(
		"https://github.com/odin-lang/Odin/releases/download/${OdinTag}/odin-windows-amd64-${OdinTag}.zip",
		"https://github.com/odin-lang/Odin/releases/download/${OdinTag}/windows-amd64.zip"
	)
}

$archive = Join-Path $InstallDir "odin-release.zip"
$tree = Join-Path $InstallDir "tree"
$ok = $false
foreach ($url in $urls) {
	try {
		Write-Host "ci_setup_odin: downloading $url"
		Invoke-WebRequest -Uri $url -OutFile $archive
		if (Test-Path $tree) { Remove-Item $tree -Recurse -Force }
		Expand-Archive -Path $archive -DestinationPath $tree
		$found = Get-ChildItem -Path $tree -Recurse -Filter odin.exe | Select-Object -First 1
		if ($found) {
			$binDir = $found.Directory.FullName
			$ok = $true
			break
		}
	} catch {
		Write-Host "ci_setup_odin: download failed for $url"
	}
}
if (-not $ok) {
	throw "ci_setup_odin: could not download Odin $OdinTag. Set ODIN_RELEASE_URL to a windows-amd64 zip."
}

if ($env:GITHUB_PATH) {
	Add-Content -Path $env:GITHUB_PATH -Value $binDir
}
$env:PATH = "$binDir;$env:PATH"

if (-not (Get-Command odin -ErrorAction SilentlyContinue)) {
	throw "ci_setup_odin: odin.exe still not on PATH"
}
if (-not (Test-OdinMonth)) {
	throw "ci_setup_odin: installed Odin is older than dev-$MinMonth"
}
Write-Host "ci_setup_odin: $(Get-Command odin | Select-Object -ExpandProperty Source)"
