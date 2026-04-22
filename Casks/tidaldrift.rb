cask "tidaldrift" do
  version "1.5.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/goldberg-consulting/measured.one.tidaldrift/releases/download/v#{version}/TidalDrift-#{version}.dmg"
  name "TidalDrift"
  desc "Menu-bar Mac utility for discovering, connecting to, and streaming between Macs on your local network"
  homepage "https://github.com/goldberg-consulting/measured.one.tidaldrift"

  depends_on macos: ">= :ventura"

  app "TidalDrift.app"

  # Strip Gatekeeper quarantine. Required while notarization is pending
  # agreement renewal for team 97UY84BV45; the DMG is Developer ID signed
  # but not yet notarized. Re-notarization will be restored in a follow-up.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/TidalDrift.app"]
  end

  zap trash: [
    "~/Library/Preferences/com.goldbergconsulting.tidaldrift.plist",
    "~/Library/Application Support/TidalDrift",
  ]
end
