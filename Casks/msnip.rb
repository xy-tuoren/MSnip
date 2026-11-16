cask "msnip" do
  version "1.2.0"
  sha256 "37909f3dff7f896ab65ebef6ce59fa49cebee3c84e63538e2a18ad695fa6f306"

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
