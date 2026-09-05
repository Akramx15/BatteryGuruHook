<#
.SYNOPSIS
    Build the BatteryGuru Xposed Module APK from source
#>

$ErrorActionPreference = "Stop"

$projectDir = "C:\Users\A\Downloads\Compressed\BatteryGuruModule"
$buildDir   = "$projectDir\build"
$srcDir     = "$projectDir\src"
$sdk        = "C:\Users\A\AppData\Local\Android\Sdk"
$jdk        = "C:\Program Files\Eclipse Adoptium\jdk-21.0.10.7-hotspot"
$buildTools = "$sdk\build-tools\36.0.0"
$androidJar = "$sdk\platforms\android-36\android.jar"
$xposedJar  = "C:\tmp\tools\xposed-api-82.jar"
$signer     = "C:\tmp\tools\uber-apk-signer.jar"

$javac = "$jdk\bin\javac.exe"
$jar   = "$jdk\bin\jar.exe"
$aapt2 = "$buildTools\aapt2.exe"
$d8    = "$buildTools\d8.bat"

# Clean
if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }
New-Item -ItemType Directory "$buildDir\classes" -Force | Out-Null
New-Item -ItemType Directory "$buildDir\apk" -Force | Out-Null

Write-Host "=== Step 1: Compile resources with aapt2 ===" -ForegroundColor Cyan
& $aapt2 compile --dir "$projectDir\res" -o "$buildDir\compiled_res.zip"

Write-Host "=== Step 2: Link resources + manifest ===" -ForegroundColor Cyan
& $aapt2 link `
    -o "$buildDir\apk\base.apk" `
    -I $androidJar `
    --manifest "$projectDir\AndroidManifest.xml" `
    --min-sdk-version 26 `
    --target-sdk-version 36 `
    "$buildDir\compiled_res.zip"

Write-Host "=== Step 3: Compile Java source ===" -ForegroundColor Cyan
& $javac `
    -source 17 -target 17 `
    -classpath "$androidJar;$xposedJar" `
    -d "$buildDir\classes" `
    (Get-ChildItem "$srcDir" -Filter "*.java" -Recurse | Select-Object -ExpandProperty FullName)

Write-Host "=== Step 4: Convert to DEX (d8) ===" -ForegroundColor Cyan
$classFiles = Get-ChildItem "$buildDir\classes" -Filter "*.class" -Recurse | Select-Object -ExpandProperty FullName
& $d8 --min-api 26 --output "$buildDir" $classFiles

Write-Host "=== Step 5: Inject DEX + assets into APK ===" -ForegroundColor Cyan
# Copy the APK to work with
Copy-Item "$buildDir\apk\base.apk" "$buildDir\module.apk"

# Add classes.dex
Push-Location $buildDir
& $jar uf "module.apk" "classes.dex"
Pop-Location

# Add assets/xposed_init
Push-Location $projectDir
& $jar uf "$buildDir\module.apk" "assets\xposed_init"
Pop-Location

Write-Host "=== Step 6: Zipalign + Sign ===" -ForegroundColor Cyan
java -jar $signer -a "$buildDir\module.apk" --allowResign -o "$buildDir\signed"

$signedApk = Get-ChildItem "$buildDir\signed\*-aligned-debugSigned.apk" | Select-Object -First 1
if ($signedApk) {
    Copy-Item $signedApk.FullName "$projectDir\BatteryGuruHook.apk"
    Write-Host ""
    Write-Host "✅ Module built successfully!" -ForegroundColor Green
    Write-Host "   Output: $projectDir\BatteryGuruHook.apk" -ForegroundColor Green
} else {
    Write-Host "❌ Build failed!" -ForegroundColor Red
}
