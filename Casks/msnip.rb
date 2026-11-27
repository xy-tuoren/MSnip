cask "msnip" do
  version "0.9.4"
  sha256 :no_check

  url "https://github.com/xy-tuoren/MSnip/releases/download/v#{version}/MSnip-v#{version}-macOS.zip"
  name "MSnip"
  name "麦截"
  desc "Pure-native macOS screenshot, annotation, long-shot, GIF/MP4 recorder, OCR/LaTeX, translation & Pin utility"
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
