# MacOnCall

MacOnCall is a menu-bar-only macOS utility for keeping a Mac awake while you are on call. It uses the system-wide `pmset disablesleep` setting and asks for administrator authentication when that setting needs to change.

## Status

> FYI: I don't know Swift and Mac development, but I would think I kinda know how to code :)
>
> PRs to improve are definitely welcome!

This app was vibe coded and is currently untested in real-world use. In particular, power-source transitions, display hot-plugging, authorization behavior, sleep/wake behavior, and different macOS hardware configurations still need to be tested. Use it at your own risk and verify the live setting yourself.

## Requirements

- macOS 14 or later
- Xcode, to build the project
- Administrator access, because changing `pmset disablesleep` requires authorization

## Run from Xcode

1. Open `MacOnCall.xcodeproj` in Xcode.
2. Select the **MacOnCall** scheme and **My Mac** as the run destination.
3. Build and run.

The app appears in the menu bar. It does not show a normal Dock window.

## Modes

### Automatic

Automatic mode is the default. Sleep prevention is enabled whenever the number of connected external displays is **1 or more** (`externalDisplayCount >= 1`). It is restored when the external display count returns to zero.

### Manual

In Manual mode, the **Prevent Sleep** toggle directly controls sleep prevention.

## Power-source changes

macOS can switch the active power profile when the Mac is plugged in or unplugged. MacOnCall observes AC/battery transitions, re-reads the live `pmset` value, and reapplies the selected mode if macOS reset the setting.

## Safety and persistence

- The selected mode and Manual toggle are saved between launches.
- MacOnCall only turns sleep prevention off if it previously enabled it.
- Quitting the app does not change the current power setting, avoiding an unexpected authorization prompt.
- The setting is system-wide, so another utility or an administrator can change it outside MacOnCall.
- If another tool owns the power setting, MacOnCall may not be able to maintain the expected behavior.

## Check the live setting

Run this in Terminal:

```sh
pmset -g | grep -i sleepdisabled
```

The result means:

- `SleepDisabled 1`: sleep prevention is enabled.
- `SleepDisabled 0`: normal sleep behavior is enabled.

`SleepDisabled` is not shown by `pmset -g custom`.

## Build a release app

Install `create-dmg` once if you want to package the app:

```sh
brew install create-dmg
```

Build a release app into the repository's `build` directory:

```sh
./scripts/build.sh
```

Then create the DMG:

```sh
./scripts/make-dmg.sh
```

Copy the resulting app to `/Applications`, replacing any older version, before testing the changes.

## Automated releases

Every push to `main`—including a merged pull request—runs the GitHub Actions workflow at `.github/workflows/publish-release.yml`. It builds an unsigned Release app, creates `MacOnCall.dmg`, and publishes a new GitHub release with the DMG attached.

The workflow requires the repository's default `GITHUB_TOKEN` to have permission to write repository contents. The generated releases are build artifacts, not signed or notarized production releases.
