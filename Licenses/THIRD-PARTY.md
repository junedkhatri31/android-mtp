Android MTP dynamically links libmtp 1.1.23 and libusb 1.0.30, both licensed under
the GNU Lesser General Public License, version 2.1 or (at your option) any later version.
Their unmodified source releases and complete license texts are available at:

- libmtp: https://downloads.sourceforge.net/project/libmtp/libmtp/1.1.23/libmtp-1.1.23.tar.gz
  Project: https://github.com/libmtp/libmtp
- libusb: https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2
  Project: https://github.com/libusb/libusb

The application bundle includes each library's COPYING file. The libraries are
built from these unmodified source releases with the options in
scripts/build-dependencies.sh and shipped as separate dylibs in Contents/Frameworks.
You may replace these libraries with compatible versions and re-sign the local
bundle using `codesign --force --deep --sign - "Android MTP.app"`.

The matching unmodified libmtp and libusb source archives are also distributed
alongside the app at https://github.com/junedkhatri31/android-mtp/releases/tag/v1.0.0.

This application's source is licensed under MIT. It imposes no restriction on
reverse engineering for debugging modifications to these LGPL libraries.
