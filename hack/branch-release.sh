#!/bin/bash -e

# This script is supposed to be used to prepare a release branch based on master.
# The script performs the following steps:
#  - Create a release branch in SBO repository
#  - Add a label to the SBO repository to be used to mark PRs to be cherry-picked in the release branch
#  - Prepare a PR branch for openshift/release repository adding OpenShift CI jobs for running acceptance and performance tests on PRs to the release branch
#  - Bump docs version in the release branch
#  - (TODO: Add a GitHub Action job for cherry-picking in the release branch)

if [ -z "$GITHUB_TOKEN" ] || [ -z "$OPENSHIFT_RELEASE_FORK_REPO" ]; then
    echo ""
    echo "ERROR: All of the following environment variables are required to be set to a non-empty value"
    echo ""
    echo "  GITHUB_TOKEN ... A 'repo' scoped Github token for creating release label"
    echo "  OPENSHIFT_RELEASE_FORK_REPO ... A fork of https://github.com/openshift/release.git"
    echo ""
    exit 1
fi

WS=$(readlink -m .branch-release)

OPENSHIFT_RELEASE_FORK_REPO_URL=git@github.com:$OPENSHIFT_RELEASE_FORK_REPO.git
OPENSHIFT_RELEASE_UPSTREAM_REPO=${OPENSHIFT_RELEASE_UPSTREAM_REPO:-openshift/release}
OPENSHIFT_RELEASE_UPSTREAM_REPO_URL=https://github.com/$OPENSHIFT_RELEASE_UPSTREAM_REPO.git
OPENSHIFT_RELEASE_DIR=$WS/release.git

SBO_REPO=${SBO_REPO:-redhat-developer/service-binding-operator}
SBO_REPO_URL=git@github.com:$SBO_REPO.git
SBO_REPO_API=https://api.github.com/repos/$SBO_REPO
SBO_DIR=$WS/service-binding-operator.git

DRY_RUN=${DRY_RUN:-true}
dry_run_msg() {
    echo ""
    echo "***** DRY-RUN: $1"
    echo ""
}

RELEASE=${RELEASE:-${VERSION%.*}} # assuming VERSION=x.y.z
RELEASE_BRANCH=release-v${RELEASE}.x

rm -rf $WS
mkdir -p $WS
cd $WS

# SBO release branch
git clone $SBO_REPO_URL $SBO_DIR
pushd $SBO_DIR
git fetch

## check if release branch exists and fail if it does
git ls-remote --exit-code --heads $SBO_REPO_URL $RELEASE_BRANCH && echo "ERROR: Branch $RELEASE_BRANCH already exist on remote origin ($(git remote get-url origin))" && exit 1

git checkout -b $RELEASE_BRANCH origin/master

yq eval -i '.version = "'${RELEASE}'.x"' docs/devguide/antora.yml
yq eval -i '.version = "'${RELEASE}'.x"' docs/userguide/antora.yml

cat << EOD >> .github/workflows/pr-cherry-picks.yaml
  cherry_pick_release_v${RELEASE}_x:
    runs-on: ubuntu-latest
    name: Cherry pick into ${RELEASE_BRANCH} branch
    if: contains(github.event.pull_request.labels.*.name, 'release/v${RELEASE}.x') && github.event.pull_request.merged
    steps:
      - name: Checkout
        uses: actions/checkout@v2
        with:
          fetch-depth: 0
      - name: Setup SSH for cherry-pick repo
        uses: webfactory/ssh-agent@v0.5.4
        with:
          ssh-private-key: \${{ secrets.SBO_CHERRY_PICK_REPO_SSH_PRIVATE_KEY }}
      - name: Cherry pick into ${RELEASE_BRANCH}
        uses: pmacik/github-cherry-pick-action@exclude-pr-labels
        with:
          cherry-pick-repo: \${{ secrets.SBO_CHERRY_PICK_REPO }}
          token: \${{ secrets.SBO_CHERRY_PICK_BOT_TOKEN }}
          branch: ${RELEASE_BRANCH}
          labels: |
            cherry-pick
          title-prefix: "cherry-pick(${RELEASE_BRANCH}): "
EOD

git add docs .github
git commit -m "Bump version in docs and add cherry-pick job for ${RELEASE}.x branch"

if [ $DRY_RUN == "false" ]; then
    git push origin $RELEASE_BRANCH
else
    dry_run_msg "Would have pushed $RELEASE_BRANCH branch to $(git remote get-url origin) repository: git push origin $RELEASE_BRANCH"
fi

## release label
release_label='{"name":"release/v'${RELEASE}'.x","description":"Used to mark PRs to be cherry-picked in '$RELEASE_BRANCH' branch","color":"C1E359"}'
if [ $DRY_RUN == "false" ]; then
    curl -X POST -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${GITHUB_TOKEN}" $SBO_REPO_API/labels -d "$release_label"
else
    dry_run_msg "Would have created a label in $SBO_REPO_URL repository: $release_label"
fi

popd

# OpenShift CI jobs for release branch
git clone $OPENSHIFT_RELEASE_FORK_REPO_URL $OPENSHIFT_RELEASE_DIR

pushd $OPENSHIFT_RELEASE_DIR
git remote add upstream $OPENSHIFT_RELEASE_UPSTREAM_REPO_URL
git fetch upstream
pr_branch=rhd-sbo-$RELEASE_BRANCH-branch
git checkout -b $pr_branch upstream/master

## Copy release-v1.1.x jobs and replace the version with the new release
pushd $OPENSHIFT_RELEASE_DIR/ci-operator/config/redhat-developer/service-binding-operator
for i in redhat-developer-service-binding-operator-release-v1.1.x*; do
    sed_expr="s,v1\.1\.x,v${RELEASE}.x,g"
    sed -e "$sed_expr" $i >$(echo -n "$i" | sed -e "$sed_expr")
done
popd

## Prepare YAMLs for the PR
make update
yq eval -i '(.presubmits.redhat-developer/service-binding-operator[] | select(.context == "ci/prow/performance").always_run) = false' $OPENSHIFT_RELEASE_DIR/ci-operator/jobs/redhat-developer/service-binding-operator/redhat-developer-service-binding-operator-$RELEASE_BRANCH-presubmits.yaml
make update
git add ci-operator
git commit -m "[rhd-sbo] Add jobs for ${RELEASE_BRANCH} branch"
if [ $DRY_RUN == "false" ]; then
    git push -u origin $pr_branch
else
    dry_run_msg "Would have pushed $pr_branch branch to $(git remote get-url origin) repository: git push -u origin $pr_branch"
fi
popd
