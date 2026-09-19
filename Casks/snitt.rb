cask "snitt" do
  version "0.7.0"
  sha256 "8e4ec5288f07c1561a6f04d4332495c7ba03bac112ac18ac2ffa644f972d3f63"

  url "https://github.com/impressiver/snitt/releases/download/v#{version}/Snitt-#{version}.zip"
  name "Snitt"
  desc "Native macOS screen recorder that a coding agent can drive"
  homepage "https://github.com/impressiver/snitt"

  # Snitt updates itself through Sparkle, so Homebrew is an installer rather
  # than the update channel. Declaring that below stops `brew upgrade` from
  # fighting an app that has already updated itself — without it, Homebrew
  # reinstalls the version it knows over a newer one the user already has.
  #
  # The phrase is deliberately not repeated in this comment: a mutation anchor
  # that also appears in prose mutates the prose and leaves the stanza intact,
  # which reads as a surviving mutant when the test was fine all along.
  auto_updates true
  depends_on macos: ">= :tahoe"

  app "Snitt.app"

  # No `binary` stanza: the `snitt` CLI is not inside the app bundle
  # (Contents/MacOS holds only Snitt and Sparkle.framework), so there is
  # nothing to symlink. Linking a path that does not exist makes every
  # install print a broken-symlink warning.

  zap trash: [
    "~/Library/Application Support/Snitt",
    "~/Library/Preferences/com.impressiver.snitt.plist",
    "~/Library/Caches/com.impressiver.snitt",
    "~/Library/Logs/Snitt",
  ]
end
