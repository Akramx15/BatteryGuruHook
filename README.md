# Battery Guru Pro Unlocker — Xposed Module

<p align="center">
  <img src="https://img.shields.io/badge/Platform-Android-green?logo=android" />
  <img src="https://img.shields.io/badge/Framework-Xposed%2FVector-blue" />
  <img src="https://img.shields.io/badge/Root-KernelSU%2FMagisk-orange" />
  <img src="https://img.shields.io/badge/Target-Battery%20Guru-purple" />
</p>

> **Xposed module that hooks `com.paget96.batteryguru` to unlock Pro features — survives R8/ProGuard obfuscation across app updates automatically.**

---

## 📌 How It Works

Battery Guru uses R8/ProGuard obfuscation which **renames class names on every update**:

| Version | Class Name |
|---------|-----------|
| Old     | `et6`     |
| v2.5.0.8-beta1 | `u57` |
| v2.5.0.8 | `o87`  |
| Future  | `???` — **auto-discovered ✅** |

Instead of hardcoding the class name (which breaks every update), this module uses **Dynamic Class Discovery**:

1. Hooks `ClassLoader.loadClass()` to intercept every class as it loads
2. Checks structural signature: `8 fields (String, int, Integer, float, Object, bool, bool, bool)`
3. Verifies `toString()` contains the stable string `"SubscriptionPlan(productId="`
4. Hooks ALL constructors → forces `isOneDay`, `isFortyEightHour`, `isPurchased` to `true`

The string `"SubscriptionPlan(productId="` is baked into Kotlin `data class toString()` and **cannot be removed by R8** — making this hook resilient to any future update.

---

## 📁 Project Structure

```
BatteryGuruHook/
├── src/com/batteryguruhook/
│   └── MainHook.java          ← Dynamic hook (update-resilient)
├── assets/
│   └── xposed_init            ← Xposed entry point
├── res/values/
│   └── arrays.xml             ← Module scope
├── AndroidManifest.xml
├── build.ps1                  ← Build script (no Gradle needed)
│
releases/
└── BatteryGuruHook.apk        ← Ready-to-install module APK

smali/
├── o87.smali                  ← Patched SubscriptionPlan (v2.5.0.8)
└── u57_old_version.smali      ← Patched SubscriptionPlan (v2.5.0.8-beta1)

AutoPatcher.ps1                ← Auto-patcher script for smali approach
```

---

## 🚀 Installation

### Option 1 — Xposed Module (Recommended — no re-patching needed)

1. Install `BatteryGuruHook.apk` from [Releases](../../releases)
2. Open **Vector Manager** (or LSPosed Manager)
3. Enable **"BatteryGuru Hook"** module
4. Set scope to `com.paget96.batteryguru`
5. Force stop Battery Guru and reopen

> Works with **Vector**, **LSPosed**, **EdXposed** — any Xposed-compatible framework.

### Option 2 — Auto-Patcher (Smali patch — run after each update)

```powershell
powershell -ExecutionPolicy Bypass -File AutoPatcher.ps1
```

Automatically pulls APK from device, finds the `SubscriptionPlan` class dynamically, patches it, signs and installs.

**Requirements:** ADB connected device, JDK 17+, Android SDK

---

## 🔧 Building From Source

No Gradle/Android Studio needed — just JDK + Android SDK:

```powershell
powershell -ExecutionPolicy Bypass -File BatteryGuruHook\build.ps1
```

**Requirements:**
- JDK 21 (Eclipse Adoptium or any JDK 17+)
- Android SDK Build-Tools 36.0.0
- `xposed-api-82.jar` (auto-downloaded or from [xposed.info](https://api.xposed.info/))
- `uber-apk-signer.jar`

---

## ⚙️ Target App

| Field | Value |
|-------|-------|
| Package | `com.paget96.batteryguru` |
| Tested version | v2.5.0.8 |
| Android | API 26+ |
| Root | KernelSU / Magisk + Zygisk |

---

## 📝 Technical Notes

### What's patched

The `SubscriptionPlan` Kotlin data class has 3 boolean fields set to `true` in the constructor:

```smali
const/4 p6, 0x1
iput-boolean p6, p0, Lo87;->f:Z   # isOneDay = true

const/4 p7, 0x1
iput-boolean p7, p0, Lo87;->g:Z   # isFortyEightHour = true

const/4 p8, 0x1
iput-boolean p8, p0, Lo87;->h:Z   # isPurchased = true
```

### Why it survives updates

R8/ProGuard can rename `o87` to anything, but it **cannot obfuscate string literals** inside `toString()` of Kotlin data classes. The string `"SubscriptionPlan(productId="` stays constant forever.

---

## ⚠️ Disclaimer

This project is for **educational purposes only**. Use it only on apps you own or have permission to modify. The authors are not responsible for any misuse.

---

## 📄 License

MIT License — see [LICENSE](LICENSE)
