cask "tidaldrift" do
  version "1.8.3"
  sha256 "ad54e6df3ad4595eec76ecb0380b4d5bf78bde81a6419e5fc9b18aebb5800343"

  url "https://github.com/goldberg-consulting/measured.one.tidaldrift/releases/download/v#{version}/TidalDrift-#{version}.dmg"
  name "TidalDrift"
  desc "Menu-bar utility for discovering and connecting to local computers"
  homepage "https://github.com/goldberg-consulting/measured.one.tidaldrift"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :ventura

  app "TidalDrift.app"

  # Strip the Gatekeeper quarantine attribute so the freshly downloaded app
  # launches without an "unidentified developer" block. The DMG is Developer ID
  # signed and notarized, so this is a belt-and-suspenders step.
  #
  # We deliberately do NOT run `tccutil reset` here. The app is signed with a
  # stable bundle ID and Developer ID, so macOS preserves Screen Recording,
  # Accessibility, and Input Monitoring grants across upgrades. Resetting on
  # every upgrade wiped those permissions and silently broke hosting/control
  # (e.g. LocalCast capture and remote input) until the user re-granted them.
  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-dr", "com.apple.quarantine", "{{appdir}}/TidalDrift.app"],
        writable_paths: ["{{appdir}}/TidalDrift.app"]
  end

  uninstall quit: "com.goldbergconsulting.tidaldrift"

  zap trash: [
    "~/Library/Application Support/TidalDrift",
    "~/Library/Preferences/com.goldbergconsulting.tidaldrift.plist",
  ]
end
