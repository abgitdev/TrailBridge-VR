TrailBridge VR

Play Windows PC VR games on an Apple Silicon Mac with a Meta Quest headset.
Free and open source: https://github.com/abgitdev/TrailBridge-VR


INSTALL

1. Drag TrailBridge VR onto the Applications folder in this window.
2. Eject the TrailBridge VR disk image.


FIRST OPEN

TrailBridge VR is not signed by Apple, so macOS blocks it the first time.

1. Open TrailBridge VR from the Applications folder. macOS says that it
   cannot be opened. Close the message (Done or OK); do not move the app
   to the Trash.
2. Open System Settings > Privacy & Security and scroll down to Security.
3. Click Open Anyway next to the message about TrailBridge VR, then confirm
   with your password or Touch ID.

After that the app opens like any other app.


ROSETTA 2

Wine and Windows games are Intel programs, so the Mac needs Rosetta 2.
If it is not installed, run this in Terminal:

    softwareupdate --install-rosetta --agree-to-license


WINE

Wine is not inside the app. During the first setup the app downloads
Wine 11.10 (about 190 MB, about 720 MB unpacked) from Gcenx's releases on
GitHub into the data folder you choose. The data folder can be on this Mac's
disk, an external disk or network storage.


CHECK THE DOWNLOAD

To make sure the disk image is the published one, run this in Terminal:

    shasum -a 256 ~/Downloads/@DMG_NAME@

Compare the result with the SHA-256 published for this file on the Releases
page: https://github.com/abgitdev/TrailBridge-VR/releases


LICENSES

TrailBridge VR is released under the MIT License and is built on BasaltVR.
The licenses of everything inside the app are in the app itself:
TrailBridge VR.app/Contents/Resources (LICENSE, THIRD_PARTY_NOTICES.md and
BasaltVR/LICENSES).
