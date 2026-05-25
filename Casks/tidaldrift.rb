cask "tidaldrift" do
  version "1.5.2"
  sha256 "f74fc86bb98b02fbd97eb8fe2abcfad52f3680c3b2088f9f6d95f30bc629ea51"

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

  uninstall quit: "com.goldbergconsulting.tidaldrift"

  # Strip Gatekeeper quarantine. Required while notarization is pending
  # agreement renewal for team 97UY84BV45; the DMG is Developer ID signed
  # but not yet notarized. Re-notarization will be restored in a follow-up.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/TidalDrift.app"]

    # Brew upgrades replace the signed app bundle, but macOS TCC permissions
    # remain keyed to the bundle identity and can get stuck on the prior build.
    # Reset only on install/upgrade, not app launch, so the next app start gets
    # fresh visible prompts without blocking the menu bar UI.
    ["ScreenCapture", "Accessibility", "ListenEvent", "LocalNetwork"].each do |service|
      system_command "/usr/bin/tccutil",
                     args: ["reset", service, "com.goldbergconsulting.tidaldrift"],
                     must_succeed: false
    end
  end

  zap trash: [
    "~/Library/Application Support/TidalDrift",
    "~/Library/Preferences/com.goldbergconsulting.tidaldrift.plist",
  ]
end
