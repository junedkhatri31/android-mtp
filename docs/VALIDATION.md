# Validation — October 12, 2026

- Debug and release builds compile with Swift 6 and the native C bridge.
- 15 Swift Testing tests pass for recursive transfer behavior, overwrite
  prevention, path validation, symlinks, partial-file cleanup, cancellation,
  and recursive deletion ordering.
- The bundled executable, libmtp, and libusb are arm64 binaries targeting
  macOS 14.0. Both USB libraries were built from checksum-verified source.
- `codesign --verify --deep --strict` succeeds for the packaged application.
- `otool -L` confirms non-system libraries use app-relative `@rpath` references,
  with no runtime dependency on Homebrew or this checkout's library paths.
- The packaged app launches in both normal USB mode and read-only preview mode.
- Native UI checks cover nested folder navigation, search, storage switching,
  appearance settings layout, disabled preview writes, and the connection screen.

No Android MTP device was attached during validation. Real upload/download,
USB removal during a transfer, rename/delete on a phone, multiple-device selection,
and runtime compatibility on macOS 14 need physical hardware / OS testing.
The app is ad-hoc signed for local use; Developer ID signing and notarization
have not been performed.
