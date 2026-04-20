cask "tidaldrift" do
  version "1.4.4"
  sha256 "d18eb76ecd74ffa69c27874ec13789ed3cf134ec19ac27e92a9da76cb9ec056d"

  url "https://github.com/goldberg-consulting/measured.one.tidaldrift/releases/download/v#{version}/TidalDrift-#{version}.dmg"
  name "TidalDrift"
  desc "Menu-bar Mac utility for discovering, connecting to, and streaming between Macs on your local network"
  homepage "https://github.com/goldberg-consulting/measured.one.tidaldrift"

  depends_on macos: ">= :ventura"

  app "TidalDrift.app"

  zap trash: [
    "~/Library/Preferences/com.goldbergconsulting.tidaldrift.plist",
    "~/Library/Application Support/TidalDrift",
  ]
end
