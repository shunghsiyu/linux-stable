#!/usr/bin/env bash
#
# Sync one upstream Linux stable version into a CI branch.
#
# Usage: sync-stable.sh <version>          # e.g. sync-stable.sh 6.6
#
# Regenerates and force-pushes branch linux-X.Y.y as:
#   <released linux-X.Y.y tip> + stable-queue queue-X.Y (best effort)
#                              + .github and ci overlaid from `main`
# so the push triggers the CI workflow (test.yml) on that kernel snapshot.
#
# $GITHUB_TOKEN must be a GitHub App installation token: a push made with the
# default Actions GITHUB_TOKEN would not trigger downstream CI. Version branches
# are disposable (force-regenerated each run) -- edit CI code on `main`. An
# unchanged version is a no-op: the resulting tree is compared before pushing.

set -euo pipefail

VERSION="${1:?usage: sync-opensuse.sh <version>  (e.g. 6.6)}"

REPO="${REPO:-kernel-patches/linux-stable}"
CI_SOURCE_BRANCH="${CI_SOURCE_BRANCH:-main}"
BASE_BRANCH="${BASE_BRANCH:-mainline}"
OPENSUSE_URL="${OPENSUSE_URL:-https://github.com/openSUSE/kernel.git}"
BOT_NAME="${BOT_NAME:-bpf-ci[bot]}"
BOT_EMAIL="${BOT_EMAIL:-bot+bpf-ci@kernel.org}"
BRANCH="${VERSION}"

: "${GITHUB_TOKEN:?GITHUB_TOKEN (a GitHub App installation token) is required to push}"
PUSH_URL="https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO}.git"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}" 2>/dev/null || true' EXIT

# Seed the working clone so the push stays thin: git only omits objects the
# client also has locally. Prefer the published version branch (incremental
# re-sync); else the shared mainline base (torvalds history, seeded once) so the
# first sync of a version uploads only its stable-specific delta -- without it a
# first push would re-upload the entire kernel history; else `main` (full push,
# only if mainline has not been seeded).
if git ls-remote --exit-code --heads "${PUSH_URL}" "${BRANCH}" >/dev/null 2>&1; then
    have_published=1; seed="${BRANCH}"
elif git ls-remote --exit-code --heads "${PUSH_URL}" "${BASE_BRANCH}" >/dev/null 2>&1; then
    have_published=0; seed="${BASE_BRANCH}"
else
    have_published=0; seed="${CI_SOURCE_BRANCH}"
fi

echo ">>> Clone ${seed}"
git clone --no-tags --single-branch --branch "${seed}" "${PUSH_URL}" "${workdir}/repo"
cd "${workdir}/repo"
git config user.name "${BOT_NAME}"
git config user.email "${BOT_EMAIL}"
if [[ "${have_published}" -eq 1 ]]; then
    old_head="$(git rev-parse HEAD)"
    old_tree="$(git rev-parse 'HEAD^{tree}')"
fi
git fetch --no-tags origin "+refs/heads/${CI_SOURCE_BRANCH}:refs/remotes/origin/${CI_SOURCE_BRANCH}"
ci_ref="$(git rev-parse "refs/remotes/origin/${CI_SOURCE_BRANCH}")"

echo ">>> Fetch openSUSE ${BRANCH}"
git remote add opensuse "${OPENSUSE_URL}"
git fetch --no-tags opensuse "+refs/heads/${BRANCH}:refs/remotes/opensuse/${BRANCH}"
base="$(git rev-parse "refs/remotes/opensuse/${BRANCH}")"
git checkout -q -B "${BRANCH}" "${base}"

# Overlay CI code from `main` (checkout, not merge: no shared history here).
# .github is required; ci/ is optional during bring-up, so overlay it only if
# it exists on the CI source.
echo ">>> Overlay CI code from ${CI_SOURCE_BRANCH}"
overlay=(.github)
if git cat-file -e "${ci_ref}:ci" 2>/dev/null; then
    overlay+=(ci)
fi
git checkout "${ci_ref}" -- "${overlay[@]}"
# -f past the kernel tree's top-level .gitignore (`.*`), which ignores .github.
git add -f "${overlay[@]}"
git commit -q -m "ci: overlay ${overlay[*]} from ${CI_SOURCE_BRANCH}@$(git rev-parse --short "${ci_ref}")"

# Push only if the resulting tree changed (skips the CI run for no-op syncs).
echo ">>> Push ${BRANCH}"
new_tree="$(git rev-parse 'HEAD^{tree}')"
if [[ "${have_published}" -eq 1 ]]; then
    if [[ "${old_tree}" == "${new_tree}" ]]; then
        echo "${BRANCH}: tree unchanged (${new_tree}); skipping push"
        exit 0
    fi
    git push --force-with-lease="refs/heads/${BRANCH}:${old_head}" "${PUSH_URL}" "HEAD:refs/heads/${BRANCH}"
else
    git push "${PUSH_URL}" "HEAD:refs/heads/${BRANCH}"
fi
echo "pushed ${BRANCH} (tree ${new_tree})"
