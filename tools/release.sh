#!/usr/bin/env bash
# Cut a DRLive release: bump the version, rebuild the zip, and rewrite repo.xml
# so its <version>, <url> and <sha> all agree with the artefact.
#
# These three must move together - LMS downloads the zip named in <url> and
# refuses it if the sha1 doesn't match <sha>, so a partial bump ships a plugin
# that silently fails to install.
#
#   tools/release.sh 0.1.1            # bump + build + rewrite, nothing published
#   tools/release.sh 0.1.1 --publish  # ...then commit, tag and create the GitHub release
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
PUBLISH="${2:-}"
REPO_SLUG="NikolajChristensen/lyrion-drlive"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "usage: tools/release.sh <major.minor.patch> [--publish]" >&2
	exit 2
fi

ZIP="dist/DRLive-${VERSION}.zip"
URL="https://github.com/${REPO_SLUG}/releases/download/v${VERSION}/DRLive-${VERSION}.zip"

echo "==> tests"
perl tools/test-variant.pl
./tools/test-compile.sh

echo "==> version -> $VERSION"
perl -i -pe "s{<version>[^<]*</version>}{<version>${VERSION}</version>}" Plugins/DRLive/install.xml

echo "==> build $ZIP"
mkdir -p dist
# Keep only the current artefact: older zips are already attached to their own
# GitHub releases, and a dist/ full of stale versions invites installing one.
rm -f dist/DRLive-*.zip
# -X drops uid/gid and platform extra fields, so the archive carries no local
# user metadata. It is NOT byte-reproducible - entry mtimes still vary - which
# is fine here because the sha1 below is computed from the artefact just built
# and written straight into repo.xml.
zip -qrX "$ZIP" Plugins/DRLive -x '*.swp' '*~' '*/.DS_Store'
unzip -l "$ZIP"

SHA=$(sha1sum "$ZIP" | cut -d' ' -f1)
echo "==> sha1 $SHA"

echo "==> repo.xml"
perl -i -pe "
	s{<plugin name=\"DRLive\" version=\"[^\"]*\"}{<plugin name=\"DRLive\" version=\"${VERSION}\"};
	s{<url>[^<]*</url>}{<url>${URL}</url>};
	s{<sha>[^<]*</sha>}{<sha>${SHA}</sha>};
" repo.xml

# Fail loudly rather than shipping a repo.xml that disagrees with the zip.
grep -q "<sha>${SHA}</sha>" repo.xml || { echo "repo.xml sha not updated" >&2; exit 1; }
grep -q "version=\"${VERSION}\"" repo.xml || { echo "repo.xml version not updated" >&2; exit 1; }
grep -q "<version>${VERSION}</version>" Plugins/DRLive/install.xml || { echo "install.xml not updated" >&2; exit 1; }

echo
echo "ready: $ZIP  ($SHA)"

if [[ "$PUBLISH" != "--publish" ]]; then
	echo "re-run with --publish to commit, tag v${VERSION} and create the GitHub release."
	exit 0
fi

echo "==> publishing v${VERSION}"
git add -A
if git diff --cached --quiet; then
	echo "    (already committed, nothing to add)"
else
	git commit -m "DRLive ${VERSION}"
fi
git tag "v${VERSION}"
git push origin HEAD --tags
gh release create "v${VERSION}" "$ZIP" --title "DRLive ${VERSION}" --generate-notes
echo "done: https://github.com/${REPO_SLUG}/releases/tag/v${VERSION}"
