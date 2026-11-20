cask "msnip" do
  version "1.4.4"
  sha256 "1113efb4c924ad34b2bf7ea654e055bdb753b4ecc267cbfaba1d721d2e77658d"

  url "https://github.com/xy-tuoren/MSnip/releases/download/v#{version}/MSnip-v#{version}-macOS.zip"
  name "MSnip"
  name "麦截"
  desc "Ultra-lightweight pure-native macOS screenshot, long-shot, GIF/MP4 recorder, OCR & Pin utility"
  homepage "https://github.com/xy-tuoren/MSnip"

  depends_on macos: ">= :monterey"

  app "MSnip.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/MSnip.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/MSnip",
    "~/Library/Caches/top.xy.msnip",
    "~/Library/LaunchAgents/top.xy.msnip.launch.plist",
  ]
end
