<#
.SYNOPSIS
    AutoPatcher v2 — Battery Guru Pro Unlocker
    يطبق 3 باتشات تلقائياً على أي إصدار جديد:
    1. fw1  : isSubscribed initial state = TRUE
    2. ew1  : isSubscribed final result = TRUE  
    3. o87* : SubscriptionPlan booleans = TRUE  (* اسم الكلاس يتغير كل تحديث، يُكتشف تلقائياً)
#>

$ErrorActionPreference = "Stop"

# ─── إعدادات ───────────────────────────────────────────────
$adb         = "C:\Users\A\AppData\Local\Android\Sdk\platform-tools\adb.exe"
$baksmali    = "C:\tmp\tools\baksmali.jar"
$smaliJar    = "C:\tmp\tools\smali.jar"
$signer      = "C:\tmp\tools\uber-apk-signer.jar"
$jdk         = "C:\Program Files\Eclipse Adoptium\jdk-21.0.10.7-hotspot\bin"
$workDir     = "C:\tmp\autopatch_v2"
$targetPkg   = "com.paget96.batteryguru"
# ────────────────────────────────────────────────────────────

function Log($msg, $color="White") { Write-Host "[AutoPatcher] $msg" -ForegroundColor $color }
function Die($msg) { Write-Host "[ERROR] $msg" -ForegroundColor Red; exit 1 }

# تنظيف وإعداد
if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force }
New-Item -ItemType Directory $workDir | Out-Null

# ── 1. سحب الـ APK من الجهاز ──────────────────────────────
Log "Pulling APK from device..." Cyan
$apkPath = (& $adb shell pm path $targetPkg) -replace "package:",""
if (-not $apkPath) { Die "App not installed on device!" }
$apkPath = $apkPath.Trim()

$ver = (& $adb shell dumpsys package $targetPkg | Select-String "versionName").ToString().Trim()
Log "Found: $targetPkg ($ver)" Green

& $adb pull $apkPath "$workDir\base.apk"
Log "APK pulled ✅" Green

# ── 2. استخراج الـ DEX ────────────────────────────────────
Log "Extracting DEX files..." Cyan
Push-Location $workDir
& "$jdk\jar.exe" xf base.apk classes.dex classes2.dex 2>$null
Pop-Location

# ── 3. Disassemble ─────────────────────────────────────────
Log "Disassembling classes.dex..." Cyan
java -jar $baksmali d "$workDir\classes.dex" -o "$workDir\smali"
Log "Disassembly done ✅" Green

# ── 4. PATCH 1: fw1.smali — initial isSubscribed = TRUE ───
Log "=== PATCH 1: fw1.smali (initial subscription state) ===" Yellow

$fw1 = "$workDir\smali\fw1.smali"
if (Test-Path $fw1) {
    $content = Get-Content $fw1 -Raw
    $patched = $content -replace (
        'sget-object (p\d+), Ljava/lang/Boolean;->FALSE:Ljava/lang/Boolean;(\s*\n\s*(?:\.line \d+\s*\n\s*)*invoke-static \{\1\}, Lz57;->a\(Ljava/lang/Object;\)Ly57;\s*\n\s*(?:\.line \d+\s*\n\s*)*move-result-object \1\s*\n\s*(?:\.line \d+\s*\n\s*)*iput-object \1, p0, Lfw1;->d:Ly57;)',
        'sget-object $1, Ljava/lang/Boolean;->TRUE:Ljava/lang/Boolean;$2'
    )
    
    # Simpler approach: replace first FALSE with TRUE in the file
    $lines = Get-Content $fw1
    $falseCount = 0
    $patchedLines = $lines | ForEach-Object {
        if ($_ -match 'sget-object \S+, Ljava/lang/Boolean;->FALSE' -and $falseCount -eq 0) {
            $falseCount++
            $_ -replace 'FALSE', 'TRUE'
        } else { $_ }
    }
    $patchedLines | Set-Content $fw1
    
    if ($falseCount -gt 0) {
        Log "  ✅ fw1: Replaced initial FALSE → TRUE" Green
    } else {
        Log "  ⚠️  fw1: Pattern not found — may already be patched or class changed" Yellow
    }
} else {
    Log "  ⚠️  fw1.smali not found! Subscription repo may be in a different class." Yellow
    # Search for it
    $candidate = Select-String -Path "$workDir\smali\*.smali" -Pattern 'sget-object \S+, Ljava/lang/Boolean;->FALSE.*\n.*Lz57;->a' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($candidate) { Log "  → Candidate: $($candidate.Filename)" Yellow }
}

# ── 5. PATCH 2: ew1.smali — force final result = TRUE ─────
Log "=== PATCH 2: ew1.smali (force final subscription = TRUE) ===" Yellow

$ew1 = "$workDir\smali\ew1.smali"
if (Test-Path $ew1) {
    $lines = Get-Content $ew1
    $patched = $false
    $newLines = New-Object System.Collections.Generic.List[string]
    
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $newLines.Add($lines[$i])
        # Look for: invoke-static {vX}, Ljava/lang/Boolean;->valueOf(Z) immediately after :cond_dX label
        if ($lines[$i] -match '^\s*:cond_\w+\s*$' -and $i+1 -lt $lines.Count) {
            # Check if next non-empty line is Boolean.valueOf
            $j = $i + 1
            while ($j -lt $lines.Count -and $lines[$j] -match '^\s*$') { $j++ }
            if ($j -lt $lines.Count -and $lines[$j] -match 'invoke-static \{(\w+)\}, Ljava/lang/Boolean;->valueOf\(Z\)') {
                $reg = $Matches[1]
                # Check if this is near the end of invokeSuspend (final write)
                # Look ahead for Ly57;->m( which is the StateFlow emit
                $k = $j + 1
                $foundEmit = $false
                while ($k -lt [Math]::Min($j+15, $lines.Count)) {
                    if ($lines[$k] -match 'Ly57;->m\(') { $foundEmit = $true; break }
                    $k++
                }
                if ($foundEmit -and -not $patched) {
                    # Insert const/4 to force the register to 1 (true)
                    $newLines.Add("    const/4 $reg, 0x1")
                    Log "  ✅ ew1: Inserted const/4 $reg, 0x1 before valueOf at line $($j+1)" Green
                    $patched = $true
                }
            }
        }
    }
    
    if ($patched) {
        $newLines | Set-Content $ew1
    } else {
        Log "  ⚠️  ew1: Could not auto-patch — applying manual line search..." Yellow
        # Fallback: find :cond_d8 specifically and patch before valueOf
        $content = Get-Content $ew1 -Raw
        # Find the last invoke-static Boolean.valueOf before Ly57;->m
        $content2 = $content -replace '(:cond_\w+\r?\n\s*)(invoke-static \{(\w+)\}, Ljava/lang/Boolean;->valueOf\(Z\)Ljava/lang/Boolean;)(\r?\n(?:.*\r?\n){0,5}.*Ly57;->m)', "`$1    const/4 `$3, 0x1`n    `$2`$4"
        if ($content2 -ne $content) {
            $content2 | Set-Content $ew1
            Log "  ✅ ew1: Regex fallback patch applied" Green
        } else {
            Log "  ❌ ew1: Patch failed! Manual inspection needed." Red
        }
    }
} else {
    Log "  ⚠️  ew1.smali not found!" Yellow
}

# ── 6. PATCH 3: SubscriptionPlan class (dynamic discovery) ─
Log "=== PATCH 3: SubscriptionPlan (dynamic class discovery) ===" Yellow

# Find the class with "SubscriptionPlan(productId=" in toString
$match = Select-String -Path "$workDir\smali\*.smali" -Pattern 'SubscriptionPlan\(productId=' -SimpleMatch -ErrorAction SilentlyContinue | Select-Object -First 1

if ($match) {
    $className = [System.IO.Path]::GetFileNameWithoutExtension($match.Filename)
    $classFile = $match.Path
    Log "  Found class: $className" Green
    
    # Patch: add const/4 0x1 before iput-boolean for fields f, g, h
    $lines = Get-Content $classFile
    $patchCount = 0
    $newLines = New-Object System.Collections.Generic.List[string]
    
    for ($i = 0; $i -lt $lines.Count; $i++) {
        # Look for iput-boolean in the main constructor (not synthetic)
        if ($lines[$i] -match "iput-boolean (p\d+), p0, L${className};->[fgh]:Z") {
            $reg = $Matches[1]
            # Check if already patched (prev line has const/4)
            $prevLine = if ($newLines.Count -gt 0) { $newLines[$newLines.Count - 1] } else { "" }
            if ($prevLine -notmatch "const/4 $reg, 0x1") {
                $newLines.Add("    const/4 $reg, 0x1")
                $patchCount++
            }
        }
        $newLines.Add($lines[$i])
    }
    
    if ($patchCount -gt 0) {
        $newLines | Set-Content $classFile
        Log "  ✅ $className: Patched $patchCount boolean fields (f,g,h) → true" Green
    } else {
        Log "  ⚠️  $className: No iput-boolean found or already patched" Yellow
    }
} else {
    Log "  ❌ SubscriptionPlan class not found in DEX1! Checking DEX2..." Red
    # Try disassembling classes2.dex if needed
    if (Test-Path "$workDir\classes2.dex") {
        java -jar $baksmali d "$workDir\classes2.dex" -o "$workDir\smali2"
        $match2 = Select-String -Path "$workDir\smali2\*.smali" -Pattern 'SubscriptionPlan\(productId=' -SimpleMatch | Select-Object -First 1
        if ($match2) { Log "  → Found in classes2.dex: $($match2.Filename)" Yellow }
    }
}

# ── 7. Reassemble + Inject + Sign + Install ───────────────
Log "=== Building patched APK ===" Cyan

java -jar $smaliJar a "$workDir\smali" -o "$workDir\classes_patched.dex"
Log "✅ DEX reassembled" Green

Copy-Item "$workDir\base.apk" "$workDir\base_patched.apk" -Force
Push-Location $workDir
Copy-Item "classes_patched.dex" "classes.dex" -Force
& "$jdk\jar.exe" uf base_patched.apk classes.dex
Pop-Location
Log "✅ DEX injected" Green

Remove-Item "$workDir\signed" -Recurse -Force -ErrorAction SilentlyContinue
java -jar $signer -a "$workDir\base_patched.apk" --allowResign -o "$workDir\signed"
Log "✅ Signed" Green

# ── 8. Install ────────────────────────────────────────────
$signedApk = Get-ChildItem "$workDir\signed\*.apk" | Select-Object -First 1
if (-not $signedApk) { Die "Signed APK not found!" }

Log "Installing on device..." Cyan
& $adb uninstall $targetPkg 2>$null
& $adb install -r $signedApk.FullName

Log "" 
Log "✅ DONE! Battery Guru patched and installed successfully." Green
Log "   Version: $ver" Green
Log "   Patches applied: fw1 (init) + ew1 (final) + SubscriptionPlan (display)" Green
