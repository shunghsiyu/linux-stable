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

VERSION="${1:?usage: sync-stable.sh <version>  (e.g. 6.6)}"

REPO="${REPO:-kernel-patches/linux-stable}"
CI_SOURCE_BRANCH="${CI_SOURCE_BRANCH:-main}"
BASE_BRANCH="${BASE_BRANCH:-mainline}"
STABLE_URL="${STABLE_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"
QUEUE_URL="${QUEUE_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/stable-queue.git}"
BOT_NAME="${BOT_NAME:-bpf-ci[bot]}"
BOT_EMAIL="${BOT_EMAIL:-bot+bpf-ci@kernel.org}"
BRANCH="linux-${VERSION}.y"

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

# EOL gate: skip versions stable-queue no longer tracks. Sparse + depth=1 keeps
# this cheap; cone mode always checks out top-level active_kernel_versions.
echo ">>> Fetch stable-queue queue-${VERSION}"
qrepo="${workdir}/stable-queue"
git clone --no-tags --depth=1 --single-branch --branch master --sparse "${QUEUE_URL}" "${qrepo}"
git -C "${qrepo}" sparse-checkout set "queue-${VERSION}"
if ! grep -qxF "${VERSION}" "${qrepo}/active_kernel_versions"; then
    echo "::warning::stable ${VERSION} not in active_kernel_versions (EOL?), skipping"
    exit 0
fi

# Base the branch on the released upstream tip (incremental given the seed).
echo ">>> Fetch upstream ${BRANCH}"
git remote add stable "${STABLE_URL}"
git fetch --no-tags stable "+refs/heads/${BRANCH}:refs/remotes/stable/${BRANCH}"
base="$(git rev-parse "refs/remotes/stable/${BRANCH}")"
git checkout -q -B "${BRANCH}" "${base}"

# Apply the queued stable patches as individual commits (git am), best effort:
# abort and skip any that don't apply cleanly so the rest still land, and each
# applied patch keeps its upstream author and message in the branch history.
echo ">>> Apply queue-${VERSION}"
applied=0
series="${qrepo}/queue-${VERSION}/series"
if [[ -f "${series}" ]]; then
    while read -r p; do
        [[ -z "${p}" ]] && continue
        f="${qrepo}/queue-${VERSION}/${p}"
        [[ -f "${f}" ]] || { echo "skip    ${p} (not found)"; continue; }
        if git am -q "${f}"; then
            applied=$((applied + 1)); echo "applied $(git log -1 --format='%h %s')"
        else
            git am --abort >/dev/null 2>&1 || true
            echo "skip    ${p} (does not apply cleanly)"
        fi
    done <"${series}"
fi
echo "applied ${applied} patch(es)"

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
