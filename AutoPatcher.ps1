<#
.SYNOPSIS
    Battery Guru Auto-Patcher — Survives app updates automatically.
    
.DESCRIPTION
    This script:
    1. Pulls the latest APK from the connected device
    2. Dynamically finds the SubscriptionPlan class (regardless of obfuscated name)
    3. Patches the 3 boolean fields (isOneDay, isFortyEightHour, isPurchased) to true
    4. Rebuilds, signs, and installs the patched APK
    
    Works across ANY version because it searches by the stable string
    "SubscriptionPlan(productId=" instead of hardcoded class names.

.NOTES
    Requirements: Java 17+, ADB, baksmali.jar, smali.jar, uber-apk-signer.jar
#>

param(
    [string]$AdbPath = "C:\Users\A\AppData\Local\Android\Sdk\platform-tools\adb.exe",
    [string]$ToolsDir = "C:\tmp\tools",
    [string]$WorkDir = "C:\tmp\batteryguru_patch",
    [string]$PackageName = "com.paget96.batteryguru"
)

$ErrorActionPreference = "Stop"

# Color helpers
function Write-Success($msg) { Write-Host "[✅] $msg" -ForegroundColor Green }
function Write-Info($msg) { Write-Host "[ℹ️] $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "[⚠️] $msg" -ForegroundColor Yellow }
function Write-Fail($msg) { Write-Host "[❌] $msg" -ForegroundColor Red }

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║   Battery Guru Auto-Patcher v1.0             ║" -ForegroundColor Magenta
Write-Host "║   Survives R8/ProGuard obfuscation changes   ║" -ForegroundColor Magenta
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""

# ── Step 1: Verify tools ──
Write-Info "Checking required tools..."
$baksmali = Join-Path $ToolsDir "baksmali.jar"
$smali = Join-Path $ToolsDir "smali.jar"
$signer = Join-Path $ToolsDir "uber-apk-signer.jar"
$jar = "C:\Program Files\Eclipse Adoptium\jdk-21.0.10.7-hotspot\bin\jar.exe"

foreach ($tool in @($baksmali, $smali, $signer)) {
    if (-not (Test-Path $tool)) { Write-Fail "Missing: $tool"; exit 1 }
}
Write-Success "All tools found"

# ── Step 2: Check device ──
Write-Info "Checking connected device..."
$devices = & $AdbPath devices 2>&1
if ($devices -notmatch "device$") { Write-Fail "No device connected!"; exit 1 }
Write-Success "Device connected"

# ── Step 3: Pull APK ──
Write-Info "Finding APK path on device..."
$apkPath = (& $AdbPath shell pm path $PackageName 2>&1) -replace "package:", ""
if (-not $apkPath) { Write-Fail "Package $PackageName not found on device!"; exit 1 }
Write-Success "APK path: $apkPath"

# Clean work directory
if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

$localApk = Join-Path $WorkDir "base.apk"
Write-Info "Pulling APK..."
& $AdbPath pull $apkPath.Trim() $localApk
Write-Success "APK pulled to $localApk"

# ── Step 4: Extract & disassemble DEX ──
Write-Info "Extracting classes.dex..."
Push-Location $WorkDir
& $jar xf $localApk "classes.dex"
Pop-Location

$smaliOut = Join-Path $WorkDir "smali_out"
Write-Info "Disassembling DEX..."
java -jar $baksmali d (Join-Path $WorkDir "classes.dex") -o $smaliOut
Write-Success "Disassembly complete"

# ── Step 5: DYNAMIC CLASS DISCOVERY ──
# Search for the class containing "SubscriptionPlan(productId=" string
# This is the key to surviving updates — we never hardcode the class name!
Write-Info "Searching for SubscriptionPlan class dynamically..."

$searchResult = Select-String -Path "$smaliOut\*.smali" -Pattern 'SubscriptionPlan\(productId=' -SimpleMatch
if (-not $searchResult) {
    Write-Fail "Could not find SubscriptionPlan class in any smali file!"
    Write-Fail "The app structure may have changed significantly."
    exit 1
}

$targetFile = $searchResult[0].Path
$targetClassName = [System.IO.Path]::GetFileNameWithoutExtension($targetFile)
Write-Success "Found SubscriptionPlan class: $targetClassName (file: $targetFile)"

# ── Step 6: Find and patch boolean fields ──
Write-Info "Analyzing class structure..."

$content = Get-Content $targetFile -Raw

# Find the main constructor with 8 parameters (String, int, Integer, float, Object, boolean, boolean, boolean)
# Pattern: constructor <init>(Ljava/lang/String;ILjava/lang/Integer;FL<anyclass>;ZZZ)V
$constructorPattern = '\.method public constructor <init>\(Ljava/lang/String;ILjava/lang/Integer;FL[^;]+;ZZZ\)V'
if ($content -notmatch $constructorPattern) {
    Write-Fail "Could not find the 8-parameter constructor!"
    exit 1
}
Write-Success "Found target constructor"

# Find the 3 boolean iput instructions and patch them
# Pattern: iput-boolean pN, p0, L<class>;->X:Z
# We need to add "const/4 pN, 0x1" before each iput-boolean for the last 3 boolean fields

$lines = Get-Content $targetFile
$patched = $false
$patchCount = 0
$inMainConstructor = $false
$newLines = @()

for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    
    # Detect entry into the main constructor (the one with ZZZ parameters)
    if ($line -match '\.method public constructor <init>\(Ljava/lang/String;ILjava/lang/Integer;FL[^;]+;ZZZ\)V') {
        $inMainConstructor = $true
    }
    
    if ($line -match '\.end method') {
        $inMainConstructor = $false
    }
    
    # Only patch inside the main constructor
    if ($inMainConstructor -and $line -match '^\s+iput-boolean (p\d+), p0, L([^;]+);->(\w+):Z') {
        $register = $Matches[1]
        $fieldName = $Matches[3]
        
        # Add const/4 before the iput-boolean to force true
        $newLines += "    const/4 $register, 0x1"
        Write-Info "  Patching field '$fieldName' (register $register) -> true"
        $patchCount++
    }
    
    $newLines += $line
}

if ($patchCount -lt 3) {
    Write-Warn "Expected 3 boolean fields to patch, found $patchCount"
    if ($patchCount -eq 0) { Write-Fail "No patches applied!"; exit 1 }
}

Set-Content -Path $targetFile -Value ($newLines -join "`r`n") -NoNewline
Write-Success "Patched $patchCount boolean fields in $targetClassName"

# ── Step 7: Reassemble DEX ──
Write-Info "Reassembling DEX..."
java -jar $smali a $smaliOut -o (Join-Path $WorkDir "classes.dex")
Write-Success "DEX reassembly complete"

# ── Step 8: Inject DEX back into APK ──
Write-Info "Injecting patched DEX into APK..."
Push-Location $WorkDir
& $jar uf $localApk "classes.dex"
Pop-Location
Write-Success "DEX injected"

# ── Step 9: Align & Sign ──
Write-Info "Signing APK..."
java -jar $signer -a $localApk --allowResign --overwrite
Write-Success "APK signed"

# ── Step 10: Install ──
Write-Info "Uninstalling original app..."
& $AdbPath uninstall $PackageName 2>$null

Write-Info "Installing patched APK..."
$signedApk = Get-ChildItem "$WorkDir\*-aligned-debugSigned.apk" | Select-Object -First 1
if (-not $signedApk) {
    # uber-apk-signer with --overwrite replaces in-place
    $signedApk = Get-Item $localApk
}
& $AdbPath install -r $signedApk.FullName
Write-Success "Installation complete!"

# ── Step 11: Launch ──
Write-Info "Launching Battery Guru..."
& $AdbPath shell am start -n "$PackageName/.activities.SplashScreen"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║   ✅ Patch applied successfully!             ║" -ForegroundColor Green
Write-Host "║   Class patched: $($targetClassName.PadRight(28))║" -ForegroundColor Green
Write-Host "║   Fields forced to true: $patchCount                   ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "Next update? Just run this script again!" -ForegroundColor Yellow
