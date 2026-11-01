# Template for Casks/eyebreak.rb in Jasurito/homebrew-tap.
# The release workflow fills in @VERSION@ and @SHA256@ and pushes it to the tap.
cask "eyebreak" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/Jasurito/EyeBreak/releases/download/v#{version}/EyeBreak-#{version}.zip"
  name "EyeBreak"
  desc "Menu bar reminder for the 20-20-20 eye strain rule"
  homepage "https://github.com/Jasurito/EyeBreak"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :ventura

  app "EyeBreak.app"

  # The app isn't notarized by Apple, so Gatekeeper would block the first launch.
  postflight_steps do
    run "/usr/bin/xattr",
        args:         ["-dr", "com.apple.quarantine", "{{appdir}}/EyeBreak.app"],
        must_succeed: false
  end

  uninstall quit: "com.jasurito.EyeBreak"

  zap trash: "~/Library/Preferences/com.jasurito.EyeBreak.plist"
end
