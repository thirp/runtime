# Build a Windows data-plane release tree: thirp-agent.exe, thirp-connect.exe,
# libthirp.dll, docs, provenance, SHA-256 checksums, optional GPG / Authenticode.
param(
	[switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

function Write-Utf8Lf([string]$Path, [string]$Content) {
	# LF-only so Linux verify_dataplane_release.sh (grep/sha256sum) works on Windows trees.
	$utf8 = New-Object System.Text.UTF8Encoding $false
	[System.IO.File]::WriteAllText($Path, ($Content -replace "`r`n", "`n" -replace "`r", "`n"), $utf8)
}


$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = (Resolve-Path (Join-Path $ScriptDir "..")).Path
Set-Location $Root

if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
		[System.Runtime.InteropServices.OSPlatform]::Windows)) {
	throw "release_windows: must run on Windows"
}

$VersionPath = Join-Path $Root "VERSION.txt"
if (-not (Test-Path $VersionPath)) {
	throw "release_windows: VERSION.txt is missing"
}
$Version = (Get-Content -Raw $VersionPath).Trim()
if ($Version -notmatch '^0\.[0-9]+\.[0-9]+$') {
	throw "release_windows: VERSION.txt must be 0.x.y, got: $Version"
}

$Commit = "unknown"
$Worktree = "clean"
try {
	$Commit = (git rev-parse HEAD).Trim()
	git diff --quiet
	if ($LASTEXITCODE -ne 0) { $Worktree = "dirty" }
	git diff --cached --quiet
	if ($LASTEXITCODE -ne 0) { $Worktree = "dirty" }
} catch {
	$Commit = "unknown"
}

$Odin = Get-Command odin -ErrorAction SilentlyContinue
if (-not $Odin) {
	throw "release_windows: odin compiler not found"
}
$OdinVer = (& odin version 2>&1 | Out-String).Trim() -replace '\s+', ' '
if ($OdinVer -notmatch 'dev-(\d{4}-\d{2})') {
	throw "release_windows: could not parse Odin month from: $OdinVer"
}
$OdinMonth = $Matches[1]
if ($OdinMonth -lt "2026-07") {
	throw "release_windows: Odin $OdinVer is older than minimum dev-2026-07"
}

$OpenSsl = Get-Command openssl -ErrorAction SilentlyContinue
if (-not $OpenSsl) {
	throw "release_windows: OpenSSL not found. Install OpenSSL 3 for Windows"
}
$OpenSslVer = (& openssl version 2>&1 | Out-String).Trim() -replace '\s+', ' '

$Arch = $env:PROCESSOR_ARCHITECTURE
if (-not $Arch) { $Arch = "AMD64" }
$Date = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")

$Out = Join-Path $Root "dist\thirp-runtime-windows-$Version"
$Archive = Join-Path $Root "dist\thirp-runtime-windows-$Arch-$Version.zip"

Write-Host "release_windows: building $Version commit $Commit ($Worktree) $Arch"
Write-Host "release_windows: openssl=$OpenSslVer path=$($OpenSsl.Source)"
Write-Host "release_windows: odin=$OdinVer path=$($Odin.Source)"
if (-not $SkipBuild) {
	$BuildBatRel = "scripts\build_windows.bat"
	if (-not (Test-Path (Join-Path $Root $BuildBatRel))) {
		throw "release_windows: missing $BuildBatRel"
	}
	$prev = Get-Location
	Set-Location $Root
	try {
		cmd.exe /c "call $BuildBatRel dataplane"
		$buildExit = $LASTEXITCODE
	} finally {
		Set-Location $prev
	}
	if ($buildExit -ne 0) {
		throw "release_windows: build_windows.bat dataplane failed ($buildExit)"
	}
} else {
	Write-Host "release_windows: SkipBuild - packaging existing dist tree"
}

foreach ($name in @("thirp-agent.exe", "thirp-connect.exe", "libthirp.dll")) {
	if (-not (Test-Path (Join-Path $Out $name))) {
		throw "release_windows: missing $name in $Out"
	}
}

Copy-Item (Join-Path $Root "c_abi\thirp.h") (Join-Path $Out "thirp.h") -Force
Copy-Item (Join-Path $Root "LICENSE") (Join-Path $Out "LICENSE") -Force
Copy-Item (Join-Path $Root "NOTICE") (Join-Path $Out "NOTICE") -Force
Copy-Item (Join-Path $Root "docs\CHANGELOG.md") (Join-Path $Out "CHANGELOG.md") -Force
Copy-Item (Join-Path $Root "docs\DEPENDENCIES.md") (Join-Path $Out "DEPENDENCIES.md") -Force

$Provenance = @"
name: thirp-runtime
version: $Version
source_commit: $Commit
worktree: $Worktree
odin: $OdinVer
openssl: $OpenSslVer
target: windows $Arch
artifact_kind: dataplane
components: thirp-agent thirp-connect libthirp
build_command: scripts/release_windows.ps1
built_at: $Date
"@
Write-Utf8Lf (Join-Path $Out "PROVENANCE.txt") $Provenance

$Pfx = $env:THIRP_WINDOWS_PFX
if ($Pfx) {
	$SignTool = Get-Command signtool -ErrorAction SilentlyContinue
	if (-not $SignTool) {
		throw "release_windows: THIRP_WINDOWS_PFX is set but signtool.exe is not on PATH"
	}
	$PfxPass = $env:THIRP_WINDOWS_PFX_PASSWORD
	foreach ($bin in @("thirp-agent.exe", "thirp-connect.exe", "libthirp.dll")) {
		$args = @("sign", "/fd", "SHA256", "/td", "SHA256", "/tr", "http://timestamp.digicert.com", "/f", $Pfx)
		if ($PfxPass) { $args += @("/p", $PfxPass) }
		$args += (Join-Path $Out $bin)
		& signtool @args
		if ($LASTEXITCODE -ne 0) {
			throw "release_windows: signtool failed for $bin"
		}
	}
	Write-Host "release_windows: Authenticode-signed with THIRP_WINDOWS_PFX"
} else {
	Write-Host "release_windows: Authenticode PFX not set (THIRP_WINDOWS_PFX); binaries are unsigned"
}

$SumFiles = @(
	"thirp-agent.exe",
	"thirp-connect.exe",
	"libthirp.dll",
	"thirp.h",
	"LICENSE",
	"NOTICE",
	"CHANGELOG.md",
	"DEPENDENCIES.md",
	"PROVENANCE.txt"
)
$SumLines = foreach ($name in $SumFiles) {
	$hash = (Get-FileHash -Algorithm SHA256 (Join-Path $Out $name)).Hash.ToLowerInvariant()
	"{0}  {1}" -f $hash, $name
}
Write-Utf8Lf (Join-Path $Out "SHA256SUMS") (($SumLines -join "`n") + "`n")

$GpgKey = $env:THIRP_GPG_KEY
$PublishFp = "3B8559D8754FB3C5B21110C786897A405CF3D8C4"
$Gpg = Get-Command gpg -ErrorAction SilentlyContinue
if (-not $GpgKey -and $Gpg) {
	$existing = & gpg --list-secret-keys --with-colons $PublishFp 2>$null
	if ($LASTEXITCODE -eq 0 -and $existing) {
		$GpgKey = $PublishFp
	}
}
if ($GpgKey) {
	$sec = Join-Path $Root "docs\SECURITY.md"
	if ((Test-Path $sec) -and -not (Select-String -Path $sec -Pattern $PublishFp -Quiet)) {
		throw "release_windows: signing fingerprint does not match docs/SECURITY.md"
	}
	$sums = Join-Path $Out "SHA256SUMS"
	& gpg --detach-sign --armor --local-user $GpgKey --output "$sums.asc" $sums
	if ($LASTEXITCODE -ne 0) {
		throw "release_windows: gpg sign failed"
	}
	& gpg --verify "$sums.asc" $sums
	Write-Host "release_windows: signed SHA256SUMS with $GpgKey"
} else {
	Write-Host "release_windows: GPG signatures not produced (publish key not in the agent; set THIRP_GPG_KEY)"
}

function Assert-CliVersion([string]$Bin) {
	$ver = & $Bin --version
	Write-Host "release_windows: $ver"
	if ($ver -notlike "*$Version*") {
		throw "release_windows: --version missing $Version : $ver"
	}
	if ($Commit -ne "unknown" -and $ver -notlike "*$Commit*") {
		throw "release_windows: --version missing commit $Commit : $ver"
	}
}

Assert-CliVersion (Join-Path $Out "thirp-agent.exe")
Assert-CliVersion (Join-Path $Out "thirp-connect.exe")

if (Test-Path $Archive) { Remove-Item $Archive -Force }
Compress-Archive -Path $Out -DestinationPath $Archive
Write-Host "release_windows: wrote $Out"
Write-Host "release_windows: wrote $Archive"
