cask "tidaldrift-experimental" do
  version "1.5.0-metal.1"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/goldberg-consulting/measured.one.tidaldrift/releases/download/v#{version}/TidalDrift-#{version}.dmg"
  name "TidalDrift (Experimental — Metal Streaming)"
  desc "Pre-release TidalDrift with Metal-accelerated full-desktop screen streaming (LocalCast pipeline)"
  homepage "https://github.com/goldberg-consulting/measured.one.tidaldrift"

  livecheck do
    skip "Experimental channel tracks the latest GitHub pre-release"
  end

  conflicts_with cask: "tidaldrift"

  depends_on macos: ">= :ventura"

  app "TidalDrift.app"

  caveats <<~EOS
    This is the experimental Metal-streaming build. It ships the full-desktop
    Metal-accelerated streaming pipeline (ScreenCaptureKit → VideoToolbox →
    UDP → VideoToolbox → Metal). Per-app streaming is compiled out of this
    build and will return in a later release.

    First launch will request Screen Recording and Accessibility permission.
    Grant both to host streams and to accept remote input from clients.

    If you were previously running the stable build:
      brew uninstall --cask tidaldrift

    To switch back to stable:
      brew uninstall --cask tidaldrift-experimental
      brew install --cask tidaldrift
  EOS

  zap trash: [
    "~/Library/Preferences/com.goldbergconsulting.tidaldrift.plist",
    "~/Library/Application Support/TidalDrift",
    "~/Library/Caches/com.goldbergconsulting.tidaldrift",
  ]
end
