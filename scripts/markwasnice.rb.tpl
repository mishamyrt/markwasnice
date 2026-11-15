cask "markwasnice" do
  version "{%APP_VERSION%}"
  sha256 "{%APP_SHA256%}"

  url "https://github.com/mishamyrt/markwasnice/releases/download/v#{version}/Markwasnice-arm64.dmg"
  name "Markwasnice"
  desc "Opinionated Markdown editor"
  homepage "https://github.com/mishamyrt/markwasnice"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Markwasnice.app"

  postflight_steps do
    run "/usr/bin/xattr",
        args: ["-dr", "com.apple.quarantine", "{{appdir}}/Markwasnice.app"]
  end
end
