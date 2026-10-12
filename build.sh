#!/usr/bin/env bash
# Build the AUR packages listed in packages.txt into a signed pacman repo (out/).
# Runs as an unprivileged user with passwordless sudo (makepkg installs build deps).
#   SIGNING_FPR   fingerprint of the key in the user's gpg keyring
#   FORCE=1       rebuild everything, not only packages whose AUR version changed
set -uo pipefail

REPO=hypr-rice
OUT=$PWD/out
WORK=$(mktemp -d)
mkdir -p "$OUT"
FAILED=()

# Current repo state: the published database, so unchanged packages are skipped.
if curl -fsSL -o "$OUT/$REPO.db.tar.gz" \
        "https://github.com/${GITHUB_REPOSITORY:-larion928/hypr-rice-pkgs}/releases/download/repo/$REPO.db.tar.gz"; then
    curl -fsSL -o "$OUT/$REPO.files.tar.gz" \
        "https://github.com/${GITHUB_REPOSITORY:-larion928/hypr-rice-pkgs}/releases/download/repo/$REPO.files.tar.gz" || true
else
    rm -f "$OUT/$REPO.db.tar.gz"
fi

published_version() {  # version of $1 in the current database, empty if absent
    [ -f "$OUT/$REPO.db.tar.gz" ] || return 0
    tar -tzf "$OUT/$REPO.db.tar.gz" 2>/dev/null | grep -E "^$1-[^-]+-[^-]+/$" \
        | sed -E "s|^$1-([^-]+-[^-]+)/$|\1|" | head -n1
}

aur_version() {
    curl -fsSL "https://aur.archlinux.org/rpc/v5/info?arg[]=$1" | jq -r '.results[0].Version // empty'
}

mapfile -t PKGS < <(grep -vE '^\s*(#|$)' packages.txt)
for pkg in "${PKGS[@]}"; do
    want=$(aur_version "$pkg")
    have=$(published_version "$pkg")
    # -git packages report the version of their last PKGBUILD edit, so always rebuild them.
    if [ -z "${FORCE:-}" ] && [ -n "$want" ] && [ "$want" = "$have" ] && [[ $pkg != *-git ]]; then
        echo "== $pkg $have: up to date"
        continue
    fi
    echo "== $pkg: $have -> $want"
    rm -rf "${WORK:?}/$pkg"
    if ! git clone -q --depth 1 "https://aur.archlinux.org/$pkg.git" "$WORK/$pkg"; then
        FAILED+=("$pkg (clone)"); continue
    fi
    # Upstream signing keys the PKGBUILD trusts (papirus-folders checks its git tag).
    for k in $(cd "$WORK/$pkg" && bash -c 'source PKGBUILD >/dev/null 2>&1; echo "${validpgpkeys[@]}"'); do
        gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$k" >/dev/null 2>&1 \
            || gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "$k" >/dev/null 2>&1 || true
    done
    if ! (cd "$WORK/$pkg" && makepkg -s --noconfirm --needed --sign --key "$SIGNING_FPR" \
            PKGDEST="$WORK/pkgs-$pkg" >"$WORK/$pkg.log" 2>&1); then
        tail -n 40 "$WORK/$pkg.log"
        FAILED+=("$pkg (build)"); continue
    fi
    for f in "$WORK/pkgs-$pkg"/*.pkg.tar.zst; do
        # GitHub release assets cannot contain ':' (package epochs), so it is renamed away;
        # the database records whatever name repo-add sees.
        base=$(basename "$f"); safe=${base//:/.}
        mv "$f" "$OUT/$safe"
        mv "$f.sig" "$OUT/$safe.sig"
        repo-add -q -s -k "$SIGNING_FPR" -R "$OUT/$REPO.db.tar.gz" "$OUT/$safe"
    done
done

# Packages that left packages.txt leave the repo too.
if [ -f "$OUT/$REPO.db.tar.gz" ]; then
    for entry in $(tar -tzf "$OUT/$REPO.db.tar.gz" | grep -E '/$'); do
        name=$(sed -E 's|^(.*)-[^-]+-[^-]+/$|\1|' <<<"$entry")
        printf '%s\n' "${PKGS[@]}" | grep -qx "$name" || repo-remove -q -s -k "$SIGNING_FPR" "$OUT/$REPO.db.tar.gz" "$name"
    done
fi

printf '%s\n' "${FAILED[@]}" > "$OUT/failed.txt"
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "FAILED: ${FAILED[*]}"
fi
exit 0
