cask "msnip" do
  version "1.1.0"
  sha256 "4f74d8b7f88a1fda99de715e03e14a1b47e0d790f9b25c898b9188f50c49b3a1"

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
