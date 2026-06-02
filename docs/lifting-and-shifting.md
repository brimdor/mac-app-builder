# Lift and shift: moving an .app to another Mac

This is the headline property of any `.app` built with mac-app-builder. If you can do these steps, the .app is well-formed. If you can't, file a bug against the per-app.

## What "lift and shift" means

The `.app` is a self-contained, portable product. You can copy it to another Mac, drop it in `/Applications`, and double-click — and it works. No installer, no dev tools, no Terminal, no internet required (for the launch; the app may need internet to do its actual job, but the startup works offline).

The user's previous data does **not** come along automatically. That's intentional. The `.app` is a fresh-install product. To bring data too, copy it separately (see below).

## How to do it

```
On the OLD Mac:
    1. Quit the .app
    2. Copy /Applications/MyApp.app to a USB stick, AirDrop, iCloud Drive, etc.
       (Tip: use `ditto -c -k --sequesterRsrc --keepParent /Applications/MyApp.app MyApp.zip`
        to make a properly-preserved zip)

On the NEW Mac:
    3. Drop MyApp.app in /Applications (or anywhere — even ~/Desktop works)
    4. Double-click MyApp.app
    5. The app launches. Done.
```

## Optional: also bring the user data

If you want your data on the new Mac too:

```
On the OLD Mac:
    1. Quit the .app
    2. Copy the data:
       cp -R ~/Library/Application\ Support/<bundle_id>/ /Volumes/USB/data/
    3. Copy the .app:
       cp -R /Applications/MyApp.app /Volumes/USB/

On the NEW Mac:
    4. Install the .app: drop MyApp.app in /Applications
    5. Install the data:
       cp -R /Volumes/USB/<bundle_id>/ ~/Library/Application\ Support/
    6. Double-click MyApp.app
    7. Your data is there.
```

Replace `<bundle_id>` with the actual bundle ID (you can find it in the .app's Info.plist, or in the About panel of the running app). For Odysseus, it's `com.pewdiepie-archdaemon.odysseus`.

## What the .app does NOT do

- **It does not preserve user data automatically.** Move the .app = fresh install.
- **It does not require any system tools on the destination.** No Homebrew, no Python, no Xcode.
- **It does not modify the destination Mac's system in any persistent way.** No LaunchAgents, no `/usr/local` installs, no PATH changes.
- **It does not require internet on the destination.** (The app may need internet for its job, but launching works offline.)

## How to wipe an .app

```
1. Quit the .app
2. Delete /Applications/MyApp.app
3. Optionally: rm -rf ~/Library/Application\ Support/<bundle_id>/
4. Optionally: rm -rf ~/Library/Logs/<bundle_id>/
5. Optionally: rm -rf ~/Library/Caches/<bundle_id>/
6. Done. The Mac is clean.
```

## Why this matters

A real macOS app (Sketch, 1Password, BBEdit, Docker Desktop) works this way. The .app is the product. The user's data is the user's. They're decoupled, and that decouplability is what makes the app supportable, upgradable, and movable.

The `mac-app-builder` standard enforces this property. Every per-app .app is tested for it (see `ci/cardinal-rule-test.sh` and `ci/lift-and-shift-test.sh`).
