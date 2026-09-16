#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=tests/assertions.sh
. tests/assertions.sh

WORKFLOW='.github/workflows/docker.publish.yml'
README='README.md'

assert_file "$WORKFLOW"
assert_file "$README"

assert_contains "$WORKFLOW" "cron: '0 0 * * 0'"
# shellcheck disable=SC2016 # Intentional literal GitHub Actions expression.
assert_contains "$WORKFLOW" 'EVENT_RELEASE_TAG: ${{ github.event.release.tag_name }}'
assert_contains "$WORKFLOW" "gh release list --limit 1 --json tagName -q '.[0].tagName'"
assert_contains "$WORKFLOW" 'PUBLISH_RELEASE_TAG=false'
# shellcheck disable=SC2016 # Intentional literal GitHub Actions expression.
assert_contains "$WORKFLOW" 'type=raw,value=${{ env.RELEASE_TAG }},enable=${{ env.PUBLISH_RELEASE_TAG == '\''true'\'' }}'
assert_contains "$WORKFLOW" 'type=raw,value=latest'
assert_contains "$WORKFLOW" 'platforms: linux/amd64,linux/arm64'
assert_contains "$WORKFLOW" 'provenance: mode=max'
assert_contains "$WORKFLOW" 'sbom: true'
assert_contains "$WORKFLOW" 'uses: actions/attest@v4'
assert_contains "$WORKFLOW" 'bash tests/localdevstack-contract.sh'
assert_contains "$WORKFLOW" 'Refusing to overwrite immutable release tag'

assert_not_contains "$WORKFLOW" 'cadence_offset'
assert_not_contains "$WORKFLOW" 'iso_week'
assert_not_contains "$WORKFLOW" "cron: '0 0 * * */2'"

assert_contains "$README" 'once per week'
# shellcheck disable=SC2016 # Intentional literal Markdown/code assertions.
assert_contains "$README" 'only `latest`'
# shellcheck disable=SC2016 # Intentional literal Markdown/code assertions.
assert_contains "$README" '`linux/amd64`'
# shellcheck disable=SC2016 # Intentional literal Markdown/code assertions.
assert_contains "$README" '`linux/arm64`'

pass "weekly publishing and release contracts"
