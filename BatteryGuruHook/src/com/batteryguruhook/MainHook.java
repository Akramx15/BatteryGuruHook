package com.batteryguruhook;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

/**
 * Battery Guru Xposed Hook — Survives app updates automatically.
 * 
 * Instead of hardcoding the obfuscated class name (which changes every update),
 * this hook dynamically discovers the SubscriptionPlan class at runtime by:
 * 
 * 1. Hooking ClassLoader.loadClass to intercept every class as it loads
 * 2. Checking each class for the stable toString() string "SubscriptionPlan(productId="
 * 3. Verifying the class structure (8 fields: String, int, Integer, float, Object, boolean×3)
 * 4. Hooking all constructors of the matched class to force boolean fields to true
 * 
 * This works because Kotlin data class toString() preserves field name strings
 * even through R8/ProGuard obfuscation.
 */
public class MainHook implements IXposedHookLoadPackage {

    private static final String TARGET_PKG = "com.paget96.batteryguru";
    private static final String SIGNATURE = "SubscriptionPlan(productId=";
    private volatile boolean hooked = false;

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lpparam) throws Throwable {
        if (!lpparam.packageName.equals(TARGET_PKG)) return;

        XposedBridge.log("[BatteryGuruHook] Module loaded in " + TARGET_PKG);

        // Hook ClassLoader.loadClass to intercept classes as they load
        XposedHelpers.findAndHookMethod(
            ClassLoader.class,
            "loadClass",
            String.class,
            boolean.class,
            new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) throws Throwable {
                    if (hooked) return;

                    Object result = param.getResult();
                    if (result == null) return;
                    Class<?> loadedClass = (Class<?>) result;

                    // Quick structural pre-filter before expensive toString check
                    if (!matchesStructure(loadedClass)) return;

                    // Deep check: verify toString contains our signature
                    if (!containsSignature(loadedClass)) return;

                    // Found it! 
                    hooked = true;
                    XposedBridge.log("[BatteryGuruHook] ✅ Discovered SubscriptionPlan: " + loadedClass.getName());

                    installHooks(loadedClass);
                }
            }
        );
    }

    /**
     * Quick structural check: the SubscriptionPlan data class has exactly 8 instance fields
     * with types: String, int, Integer, float, <any>, boolean, boolean, boolean
     */
    private boolean matchesStructure(Class<?> clazz) {
        try {
            Field[] allFields = clazz.getDeclaredFields();
            
            // Get only instance (non-static) fields
            List<Field> instanceFields = new ArrayList<>();
            for (Field f : allFields) {
                if (!Modifier.isStatic(f.getModifiers())) {
                    instanceFields.add(f);
                }
            }

            if (instanceFields.size() != 8) return false;

            // Sort by name to get consistent ordering (a, b, c, d, e, f, g, h)
            Collections.sort(instanceFields, new Comparator<Field>() {
                @Override
                public int compare(Field a, Field b) {
                    return a.getName().compareTo(b.getName());
                }
            });

            // Check field types pattern
            if (instanceFields.get(0).getType() != String.class) return false;         // a: productId
            if (instanceFields.get(1).getType() != int.class) return false;            // b: titleResId
            if (instanceFields.get(2).getType() != Integer.class) return false;        // c: description
            if (instanceFields.get(3).getType() != float.class) return false;          // d: periodInWeeks
            // index 4: any type (productDetails - obfuscated)                         // e: productDetails
            if (instanceFields.get(5).getType() != boolean.class) return false;        // f: isOneDay
            if (instanceFields.get(6).getType() != boolean.class) return false;        // g: isFortyEightHour
            if (instanceFields.get(7).getType() != boolean.class) return false;        // h: isPurchased

            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    /**
     * Check if the class contains "SubscriptionPlan(productId=" in its toString() output.
     * Uses Unsafe.allocateInstance to create an instance without calling the constructor,
     * then calls toString() to check the output pattern.
     */
    private boolean containsSignature(Class<?> clazz) {
        try {
            // Use sun.misc.Unsafe to allocate instance without constructor
            Class<?> unsafeClass = Class.forName("sun.misc.Unsafe");
            Field unsafeField = unsafeClass.getDeclaredField("theUnsafe");
            unsafeField.setAccessible(true);
            Object unsafe = unsafeField.get(null);
            Method allocate = unsafeClass.getMethod("allocateInstance", Class.class);

            Object instance = allocate.invoke(unsafe, clazz);
            
            Method toString = clazz.getDeclaredMethod("toString");
            toString.setAccessible(true);
            
            String result = (String) toString.invoke(instance);
            return result != null && result.contains(SIGNATURE);
        } catch (Throwable t) {
            // If Unsafe fails (shouldn't on Android), fall back to structure-only match
            // The structure check is already very specific (8 fields with exact type pattern)
            // so a false positive is extremely unlikely
            XposedBridge.log("[BatteryGuruHook] toString check failed, using structure-only match: " + t.getMessage());
            return true; // trust the structural match
        }
    }

    /**
     * Install constructor hooks on the discovered SubscriptionPlan class.
     * After any constructor completes, all 3 boolean fields are forced to true.
     */
    private void installHooks(Class<?> targetClass) {
        // Find the 3 boolean instance fields
        final List<Field> booleanFields = new ArrayList<>();
        Field[] allFields = targetClass.getDeclaredFields();
        
        List<Field> instanceFields = new ArrayList<>();
        for (Field f : allFields) {
            if (!Modifier.isStatic(f.getModifiers())) {
                instanceFields.add(f);
            }
        }
        Collections.sort(instanceFields, new Comparator<Field>() {
            @Override
            public int compare(Field a, Field b) {
                return a.getName().compareTo(b.getName());
            }
        });

        for (Field f : instanceFields) {
            if (f.getType() == boolean.class) {
                f.setAccessible(true);
                booleanFields.add(f);
            }
        }

        XposedBridge.log("[BatteryGuruHook] Boolean fields to patch: " + booleanFields.size());
        for (Field f : booleanFields) {
            XposedBridge.log("[BatteryGuruHook]   -> " + f.getName() + " (" + f.getType().getSimpleName() + ")");
        }

        // Hook ALL constructors
        XposedBridge.hookAllConstructors(targetClass, new XC_MethodHook() {
            @Override
            protected void afterHookedMethod(MethodHookParam param) throws Throwable {
                for (Field f : booleanFields) {
                    f.setBoolean(param.thisObject, true);
                }
                XposedBridge.log("[BatteryGuruHook] ✅ SubscriptionPlan patched → all booleans = true");
            }
        });

        XposedBridge.log("[BatteryGuruHook] ✅ Hooks installed successfully on " + targetClass.getName());
    }
}
