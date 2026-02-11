# 313 Soundboard - TeamSpeak 6 Addon Installer
# Run as: powershell -ExecutionPolicy Bypass -File install.ps1

$ErrorActionPreference = "Stop"

$ADDON_ID     = "myinstants_soundboard"
$ADDON_NAME   = "MyInstants Soundboard"
$ADDON_VERSION = "1.0.0"

# --- Addon source files (embedded) ---

$SOUNDBOARD_CSS = @'
#mi-soundboard-toggle {
	position: fixed;
	bottom: 60px;
	right: 16px;
	width: 42px;
	height: 42px;
	border-radius: 0;
	background: #D4520A;
	border: 3px solid #2D1B0E;
	cursor: pointer;
	z-index: 99999;
	display: flex;
	align-items: center;
	justify-content: center;
	box-shadow: 3px 3px 0 #2D1B0E;
	transition: background 0.1s, transform 0.04s, box-shadow 0.04s;
}
#mi-soundboard-toggle:hover { background: #E86920; }
#mi-soundboard-toggle:active {
	transform: translate(2px, 2px);
	box-shadow: 1px 1px 0 #2D1B0E;
}
#mi-soundboard-toggle svg { width: 22px; height: 22px; fill: #FAF4EA; }
#mi-soundboard-panel {
	position: fixed;
	bottom: 110px;
	right: 16px;
	width: 420px;
	height: 500px;
	background: #EDE0CC;
	border: 3px solid #2D1B0E;
	z-index: 99998;
	display: none;
	box-shadow: 6px 6px 0 #2D1B0E;
	overflow: hidden;
}
#mi-soundboard-panel.open { display: block; }
#mi-soundboard-iframe { width: 100%; height: 100%; border: none; }
'@

$SOUNDBOARD_JS = @'
(function () {
	"use strict";
	var SOUNDBOARD_URL = "http://178.156.220.61:3000";
	var panelOpen = false;
	function init() {
		var toggle = document.createElement("button");
		toggle.id = "mi-soundboard-toggle";
		toggle.title = "313 Soundboard";
		var svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
		svg.setAttribute("viewBox", "0 0 24 24");
		var path = document.createElementNS("http://www.w3.org/2000/svg", "path");
		path.setAttribute("d", "M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z");
		svg.appendChild(path);
		toggle.appendChild(svg);
		document.body.appendChild(toggle);
		var panel = document.createElement("div");
		panel.id = "mi-soundboard-panel";
		var iframe = document.createElement("iframe");
		iframe.src = SOUNDBOARD_URL;
		iframe.id = "mi-soundboard-iframe";
		iframe.setAttribute("allow", "autoplay");
		panel.appendChild(iframe);
		document.body.appendChild(panel);
		toggle.addEventListener("click", function () {
			panelOpen = !panelOpen;
			panel.classList.toggle("open", panelOpen);
		});
	}
	if (document.readyState === "complete" || document.readyState === "interactive") {
		setTimeout(init, 500);
	} else {
		document.addEventListener("DOMContentLoaded", function () { setTimeout(init, 500); });
	}
})();
'@

# --- Find TeamSpeak 6 ---

function Find-TeamSpeak {
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\TeamSpeak",
        "$env:PROGRAMFILES\TeamSpeak",
        "${env:PROGRAMFILES(x86)}\TeamSpeak",
        "$env:APPDATA\TeamSpeak",
        "$env:LOCALAPPDATA\TeamSpeak"
    )

    foreach ($dir in $candidates) {
        $indexPath = Join-Path $dir "html\client_ui\index.html"
        if (Test-Path $indexPath) {
            return $dir
        }
    }

    # Search common install locations
    $drives = (Get-PSDrive -PSProvider FileSystem).Root
    foreach ($drive in $drives) {
        foreach ($sub in @("TeamSpeak", "Program Files\TeamSpeak", "Program Files (x86)\TeamSpeak")) {
            $dir = Join-Path $drive $sub
            $indexPath = Join-Path $dir "html\client_ui\index.html"
            if (Test-Path $indexPath) {
                return $dir
            }
        }
    }

    return $null
}

# --- Inject addon into index.html ---

function Install-Addon {
    param([string]$TSDir)

    $indexPath = Join-Path $TSDir "html\client_ui\index.html"
    if (-not (Test-Path $indexPath)) {
        throw "index.html not found at $indexPath"
    }

    # Build the inject payload (inline CSS + JS)
    $injectContent = "<style>$SOUNDBOARD_CSS</style><script>$SOUNDBOARD_JS</script>"

    # Wrap with addon markers
    $installId = [guid]::NewGuid().ToString()
    $nameB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ADDON_NAME))
    $startMarker = "<!-- ADDON_START v2 $ADDON_ID $ADDON_VERSION `"$nameB64`" $installId -->"
    $endMarker = "<!-- ADDON_END $installId -->"
    $wrapped = "$startMarker$injectContent$endMarker"

    # Read current index.html
    $index = Get-Content -Path $indexPath -Raw -Encoding UTF8

    # Remove existing addon with same ID (if re-installing)
    $pattern = "<!-- ADDON_START v\d+ $([regex]::Escape($ADDON_ID)) .*?<!-- ADDON_END[^>]*-->"
    $index = [regex]::Replace($index, $pattern, "", [System.Text.RegularExpressions.RegexOptions]::Singleline)

    # Inject before </body>
    $index = $index.Replace("</body>", "$wrapped</body>")

    # Write back
    [System.IO.File]::WriteAllText($indexPath, $index, [System.Text.UTF8Encoding]::new($false))

    return $true
}

# --- Binary patching via JAR (optional) ---

function Find-JarFile {
    $jarName = "TS6AddonInstaller-3.4.0-all.jar"
    $searchPaths = @(
        $PSScriptRoot,
        (Split-Path $PSScriptRoot -Parent),
        (Join-Path (Split-Path $PSScriptRoot -Parent) ".."),
        $PWD.Path
    )
    foreach ($dir in $searchPaths) {
        $candidate = Join-Path $dir $jarName
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function Invoke-BinaryPatch {
    param([string]$TSDir)

    $jarPath = Find-JarFile
    if (-not $jarPath) {
        Write-Host ""
        Write-Host "  ERROR: TS6AddonInstaller JAR not found!" -ForegroundColor Red
        Write-Host "  Make sure TS6AddonInstaller-3.4.0-all.jar is in the same" -ForegroundColor Yellow
        Write-Host "  folder as this installer." -ForegroundColor Yellow
        return $false
    }

    # Check for Java
    $java = Get-Command java -ErrorAction SilentlyContinue
    if (-not $java) {
        Write-Host ""
        Write-Host "  Java is required but not installed!" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Opening the Java download page in your browser..." -ForegroundColor Cyan
        Write-Host "  Download and install Java, then run this installer again." -ForegroundColor Cyan
        Write-Host ""
        Start-Process "https://adoptium.net/temurin/releases/?os=windows&package=jdk"
        return $false
    }

    Write-Host "  Found Java. Launching TS6 Addon Installer..." -ForegroundColor Green
    Write-Host ""
    Write-Host "  A new window will open. Follow these steps:" -ForegroundColor Cyan
    Write-Host "    1. Click the Browse button" -ForegroundColor White
    Write-Host "    2. Navigate to: $TSDir" -ForegroundColor White
    Write-Host "    3. Click Patch" -ForegroundColor White
    Write-Host "    4. Close the window when done" -ForegroundColor White
    Write-Host ""
    Start-Process -FilePath "java" -ArgumentList "-jar `"$jarPath`"" -Wait
    return $true
}

# --- Main ---

Write-Host ""
Write-Host "  ================================================" -ForegroundColor DarkYellow
Write-Host "       313 SOUNDBOARD - TS6 ADDON INSTALLER" -ForegroundColor Yellow
Write-Host "  ================================================" -ForegroundColor DarkYellow
Write-Host ""

# Step 1: Find TeamSpeak
Write-Host "[1/3] Looking for TeamSpeak 6..." -ForegroundColor Cyan
$tsDir = Find-TeamSpeak

if (-not $tsDir) {
    Write-Host ""
    Write-Host "  TeamSpeak 6 not found automatically." -ForegroundColor Yellow
    Write-Host "  Enter the path to your TeamSpeak 6 folder:"
    Write-Host "  (e.g. C:\Users\YourName\AppData\Local\Programs\TeamSpeak)"
    Write-Host ""
    $tsDir = Read-Host "  Path"
    $tsDir = $tsDir.Trim('"').Trim("'").Trim()

    $checkIndex = Join-Path $tsDir "html\client_ui\index.html"
    if (-not (Test-Path $checkIndex)) {
        Write-Host ""
        Write-Host "  ERROR: No index.html found at that location." -ForegroundColor Red
        Write-Host "  Make sure you've selected the correct TeamSpeak 6 folder."
        Write-Host ""
        Read-Host "  Press Enter to exit"
        exit 1
    }
}

Write-Host "  Found: $tsDir" -ForegroundColor Green
Write-Host ""

# Step 2: Binary patching (required for addon to work)
Write-Host "[2/3] Patching TeamSpeak binary..." -ForegroundColor Cyan
$patched = Invoke-BinaryPatch -TSDir $tsDir
if (-not $patched) {
    Write-Host ""
    Write-Host "  WARNING: Binary patching failed or was skipped." -ForegroundColor Yellow
    Write-Host "  The addon WILL NOT WORK without the binary patch." -ForegroundColor Yellow
    Write-Host "  TeamSpeak validates its files and will reject the modified HTML." -ForegroundColor Yellow
    Write-Host ""
    $continue = Read-Host "  Continue anyway? (y/N)"
    if ($continue -ne "y" -and $continue -ne "Y") {
        Write-Host "  Install cancelled."
        Read-Host "  Press Enter to exit"
        exit 1
    }
}
Write-Host ""

# Step 3: Inject addon
Write-Host "[3/3] Injecting 313 Soundboard addon..." -ForegroundColor Cyan
try {
    Install-Addon -TSDir $tsDir
    Write-Host "  Addon injected successfully!" -ForegroundColor Green
} catch {
    Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "  Press Enter to exit"
    exit 1
}
Write-Host ""

# Done
Write-Host "  ================================================" -ForegroundColor DarkYellow
Write-Host "       INSTALLATION COMPLETE!" -ForegroundColor Green
Write-Host "  ================================================" -ForegroundColor DarkYellow
Write-Host ""
Write-Host "  Restart TeamSpeak 6 to see the soundboard button."
Write-Host "  Room code: 313"
Write-Host ""
Read-Host "  Press Enter to exit"
