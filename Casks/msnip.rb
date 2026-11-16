cask "msnip" do
  version "1.2.1"
  sha256 "30af1eaca1542ded47be2cd405a37c84b669360c4da8032fc5de770857595739"

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
