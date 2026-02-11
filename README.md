# 313 Soundboard

Shared soundboard addon for TeamSpeak 6. Plays sounds from MyInstants in your voice channel.

## Windows

1. Close TeamSpeak 6
2. Download and extract this repo
3. Open `windows-installer/` and double-click **Install 313 Soundboard.bat**
4. The installer will patch TeamSpeak and inject the addon
5. If Java is not installed, grab it from [adoptium.net](https://adoptium.net/) first — the binary patch requires it
6. Restart TeamSpeak 6

## Linux

```bash
git clone https://github.com/Buku313/313-soundboard.git
cd 313-soundboard

# Binary patch TeamSpeak first (requires Java)
java -jar TS6AddonInstaller-3.4.0-all.jar

# Then inject the addon
sudo python3 install-addon.py --ts-dir /path/to/TeamSpeak
```

## Bazzite / Immutable Linux (Flatpak)

```bash
# Install Java
brew install openjdk

# Clone the repo
git clone https://github.com/Buku313/313-soundboard.git
cd 313-soundboard

# Close TeamSpeak, then binary patch it first
sudo $(which java) -jar TS6AddonInstaller-3.4.0-all.jar
# In the GUI: browse to the TeamSpeak Flatpak directory and click Patch

# Symlink the Flatpak path for easy access
ln -s "$(flatpak info --show-location com.teamspeak.TeamSpeak)/files/extra" ~/ts6-flatpak

# Install the addon
TS_DIR="$(flatpak info --show-location com.teamspeak.TeamSpeak)/files/extra"
sudo ./install-bazzite.sh "$TS_DIR"
```

## After Install

Restart TeamSpeak 6. You'll see an orange speaker button in the bottom-right corner. Click it to open the soundboard.

**Room code: 313**

## Uninstall

The addon only modifies one file: `TeamSpeak/html/client_ui/index.html`

To uninstall, reinstall/repair TeamSpeak or remove the block between the `ADDON_START` and `ADDON_END` comments in that file.
