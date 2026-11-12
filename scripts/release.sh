#!/bin/bash
# Tag the version in build.zig.zon, push the tag, and write the source-build Homebrew formula into
# the latentbyte/homebrew-tap checkout (TAP_DIR, default ../homebrew-tap). Commit and push the tap
# yourself after reviewing the formula.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAP_DIR="${TAP_DIR:-$ROOT/../homebrew-tap}"
REPO="hamidzr/zmenu"

cd "$ROOT"
VERSION="$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' build.zig.zon)"
[ -n "$VERSION" ] || { echo "no .version in build.zig.zon" >&2; exit 1; }
TAG="v$VERSION"
[ -d "$TAP_DIR/Formula" ] || { echo "tap checkout not found: $TAP_DIR" >&2; exit 1; }

if [ -n "$(git status --porcelain)" ]; then
  echo "working tree is dirty; commit first" >&2
  exit 1
fi
if [ "$(git rev-parse HEAD)" != "$(git rev-parse '@{u}')" ]; then
  echo "HEAD is not pushed; push main first" >&2
  exit 1
fi

if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  git tag -a "$TAG" -m "zmenu $VERSION"
fi
git push origin "refs/tags/$TAG"

URL="https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz"
SHA="$(curl -fsSL "$URL" | shasum -a 256 | cut -d' ' -f1)"

cat >"$TAP_DIR/Formula/zmenu.rb" <<EOF
class Zmenu < Formula
  desc "Fast native fuzzy menu for macOS, a dmenu alternative"
  homepage "https://latentbyte.com/products/zmenu"
  url "$URL"
  sha256 "$SHA"
  license "MIT"
  head "https://github.com/$REPO.git", branch: "main"

  depends_on "zig" => :build
  depends_on :macos

  def install
    system "zig", "build", *std_zig_args
  end

  test do
    assert_match "ipc-protocol", shell_output("#{bin}/zmenu --version")
    assert_path_exists bin/"zmenuctl"
  end
end
EOF

echo "wrote $TAP_DIR/Formula/zmenu.rb for $TAG"
echo "test: brew install --build-from-source $TAP_DIR/Formula/zmenu.rb && brew test zmenu"
