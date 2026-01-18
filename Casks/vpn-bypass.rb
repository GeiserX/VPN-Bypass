# Homebrew Cask for VPN Bypass
# Install: brew install --cask geiserx/tap/vpn-bypass
# Or if using local tap: brew install --cask --no-quarantine ./Casks/vpn-bypass.rb

cask "vpn-bypass" do
  version "1.1.0"
  sha256 "37b127a55aec0bdb80e824e59e840ce5b529c09086aac7fc24dc4616abb817bd"

  url "https://github.com/GeiserX/VPNBypass/releases/download/v#{version}/VPNBypass-#{version}.dmg"
  name "VPN Bypass"
  desc "macOS menu bar app to route specific traffic around VPN"
  homepage "https://github.com/GeiserX/VPNBypass"

  depends_on macos: ">= :ventura"

  app "VPN Bypass.app"

  postflight do
    # Sign the app after installation (ad-hoc) for notifications to work
    system_command "/usr/bin/codesign",
                   args: ["--force", "--deep", "--sign", "-", "#{appdir}/VPN Bypass.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/VPNBypass",
    "~/Library/Preferences/com.geiserx.vpn-bypass.plist",
    "~/Library/Caches/com.geiserx.vpn-bypass",
  ]
end
