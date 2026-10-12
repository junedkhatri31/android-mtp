# Install Android MTP

Requires an Apple Silicon Mac (M1 or later) running macOS 14 or later.

## Install

1. Download **AndroidMTP-arm64.dmg** from the [latest GitHub release](https://github.com/junedkhatri31/android-mtp/releases/latest).
2. Double-click the DMG to open it.
3. Drag **Android MTP.app** onto **Applications** in the disk image.
4. Eject the **Android MTP** disk image, then launch the app from Applications.

The ZIP is an alternative: extract it and move **Android MTP.app** to Applications.
The packaged app includes its USB libraries. No Homebrew, Terminal commands, or
Android companion app is required to use it.

## Allow the first launch in macOS

This release is locally signed and has not been notarized by Apple. macOS may
block the first launch because it cannot verify the developer.

1. Try opening **Android MTP** from Applications and dismiss the warning.
2. Open **Apple menu → System Settings → Privacy & Security**.
3. Under **Security**, find the message for **Android MTP** and choose **Open Anyway**.
4. Confirm with **Open** and follow any macOS confirmation prompts.

Approve the copy downloaded from this repository. The exception applies to this
app; future launches normally work directly from Applications. These steps follow
[Apple's instructions](https://support.apple.com/en-us/102445).

## Connect your phone

Connect a USB data cable, unlock the phone, and select **File transfer / MTP** in
its USB notification. Click **Connect device** in Android MTP. Quit other Android
MTP apps before connecting.

This is an early release. Automated transfer tests pass, but real Android USB
transfers and macOS 14 runtime compatibility still need physical hardware testing.
