#!/usr/bin/env bash
# Upload out/ to the "repo" release and drop package files the database no longer lists.
set -euo pipefail
REPO=hypr-rice
TAG=repo
cd out

R=(-R "$GITHUB_REPOSITORY")
gh release view "$TAG" "${R[@]}" >/dev/null 2>&1 \
    || gh release create "$TAG" "${R[@]}" --title "pacman repo" --latest=false \
        --notes "pacman repository for hypr-rice. Add to /etc/pacman.conf:
[hypr-rice]
SigLevel = Required DatabaseOptional
Server = https://github.com/${GITHUB_REPOSITORY}/releases/download/repo"

# pacman asks for <repo>.db / <repo>.files; release assets cannot be symlinks.
for kind in db files; do
    [ -f "$REPO.$kind.tar.gz" ] || continue
    # repo-add leaves these as symlinks to the .tar.gz.
    rm -f "$REPO.$kind" "$REPO.$kind.sig"
    cp "$REPO.$kind.tar.gz" "$REPO.$kind"
    [ -f "$REPO.$kind.tar.gz.sig" ] && cp "$REPO.$kind.tar.gz.sig" "$REPO.$kind.sig"
done
rm -f -- *.old *.old.sig

shopt -s nullglob
files=(*.pkg.tar.zst *.pkg.tar.zst.sig "$REPO".db* "$REPO".files*)
[ ${#files[@]} -eq 0 ] || gh release upload "$TAG" "${R[@]}" "${files[@]}" --clobber

# Whatever package the database does not mention is an old version.
listed=$(tar -xzOf "$REPO.db.tar.gz" --wildcards '*/desc' | awk '/^%FILENAME%$/ {getline; print}')
gh release view "$TAG" "${R[@]}" --json assets --jq '.assets[].name' | while read -r asset; do
    case "$asset" in
        *.pkg.tar.zst|*.pkg.tar.zst.sig)
            grep -qxF "${asset%.sig}" <<<"$listed" || gh release delete-asset "$TAG" "${R[@]}" "$asset" --yes ;;
    esac
done
