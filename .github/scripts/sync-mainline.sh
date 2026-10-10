#!/usr/bin/env bash
#
# Mirror torvalds master into this repo's `mainline` branch.
#
# `mainline` is the shared-history base that keeps stable-branch pushes thin: a
# version's first sync seeds its clone from `mainline`, so only its stable-
# specific delta is uploaded (see sync-stable.sh). Refreshing `mainline` keeps
# that base current, so a newly added stable series stays cheap to seed.
#
# Incremental and cheap: a bare clone of the published `mainline` provides the
# previous tip, so the upstream fetch and the push carry only the delta since the
# last run. No CI overlay -- `mainline` is a plain mirror, not a test target.

set -euo pipefail

REPO="${REPO:-kernel-patches/linux-stable}"
BASE_BRANCH="${BASE_BRANCH:-mainline}"
TORVALDS_URL="${TORVALDS_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git}"
TORVALDS_BRANCH="${TORVALDS_BRANCH:-master}"

: "${GITHUB_TOKEN:?GITHUB_TOKEN (a GitHub App installation token) is required to push}"
PUSH_URL="https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO}.git"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}" 2>/dev/null || true' EXIT

# Bare clone of the existing mainline (no worktree needed for a mirror); gives
# the previous tip so the fetch and push below are incremental.
echo ">>> Clone ${BASE_BRANCH} (bare)"
git clone --no-tags --bare --single-branch --branch "${BASE_BRANCH}" "${PUSH_URL}" "${workdir}/m.git"
cd "${workdir}/m.git"
old_tip="$(git rev-parse HEAD)"

echo ">>> Fetch torvalds ${TORVALDS_BRANCH}"
git fetch --no-tags "${TORVALDS_URL}" "${TORVALDS_BRANCH}"
new_tip="$(git rev-parse FETCH_HEAD)"

if [[ "${old_tip}" == "${new_tip}" ]]; then
    echo "${BASE_BRANCH}: already at ${new_tip}; nothing to push"
    exit 0
fi

echo ">>> Push ${BASE_BRANCH} (${old_tip} -> ${new_tip})"
git push --force-with-lease="refs/heads/${BASE_BRANCH}:${old_tip}" \
    "${PUSH_URL}" "${new_tip}:refs/heads/${BASE_BRANCH}"
echo "pushed ${BASE_BRANCH} @ ${new_tip}"
