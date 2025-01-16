#!/bin/bash

set -euo pipefail

echo "Debug"

load_envs() {
    local konflux_ci_secrets_file="/usr/local/konflux-ci-secrets"
    local konflux_infra_secrets_file="/usr/local/konflux-test-infra"

    declare -A config_envs=(
        [ENABLE_SCHEDULING_ON_MASTER_NODES]="false"
        [UNREGISTER_PAC]="true"
        [EC_DISABLE_DOWNLOAD_SERVICE]="true"
        [DEFAULT_QUAY_ORG]="redhat-appstudio-qe"
        [OCI_STORAGE_USERNAME]="$(jq -r '."quay-username"' ${konflux_infra_secrets_file}/oci-storage)"
        [OCI_STORAGE_TOKEN]="$(jq -r '."quay-token"' ${konflux_infra_secrets_file}/oci-storage)"
    )

    declare -A load_envs_from_file=(
        [DEFAULT_QUAY_ORG_TOKEN]="${konflux_ci_secrets_file}/default-quay-org-token"
        [QUAY_TOKEN]="${konflux_ci_secrets_file}/quay-token"
        [QUAY_OAUTH_USER]="${konflux_ci_secrets_file}/quay-oauth-user"
        [QUAY_OAUTH_TOKEN]="${konflux_ci_secrets_file}/quay-oauth-token"
        [PYXIS_STAGE_KEY]="${konflux_ci_secrets_file}/pyxis-stage-key"
        [PYXIS_STAGE_CERT]="${konflux_ci_secrets_file}/pyxis-stage-cert"
        [ATLAS_STAGE_ACCOUNT]="${konflux_ci_secrets_file}/atlas-stage-account"
        [ATLAS_STAGE_TOKEN]="${konflux_ci_secrets_file}/atlas-stage-token"
        [OFFLINE_TOKEN]="${konflux_ci_secrets_file}/stage_offline_token"
        [TOOLCHAIN_API_URL]="${konflux_ci_secrets_file}/stage_toolchain_api_url"
        [KEYLOAK_URL]="${konflux_ci_secrets_file}/stage_keyloak_url"
        [EXODUS_PROD_KEY]="${konflux_ci_secrets_file}/exodus_prod_key"
        [EXODUS_PROD_CERT]="${konflux_ci_secrets_file}/exodus_prod_cert"
        [CGW_USERNAME]="${konflux_ci_secrets_file}/cgw_username"
        [CGW_TOKEN]="${konflux_ci_secrets_file}/cgw_token"
        [REL_IMAGE_CONTROLLER_QUAY_ORG]="${konflux_ci_secrets_file}/release_image_controller_quay_org"
        [REL_IMAGE_CONTROLLER_QUAY_TOKEN]="${konflux_ci_secrets_file}/release_image_controller_quay_token"
        [QE_SPRAYPROXY_HOST]="${konflux_ci_secrets_file}/qe-sprayproxy-host"
        [QE_SPRAYPROXY_TOKEN]="${konflux_ci_secrets_file}/qe-sprayproxy-token"
        [E2E_PAC_GITHUB_APP_ID]="${konflux_ci_secrets_file}/pac-github-app-id"
        [E2E_PAC_GITHUB_APP_PRIVATE_KEY]="${konflux_ci_secrets_file}/pac-github-app-private-key"
        [PAC_GITHUB_APP_WEBHOOK_SECRET]="${konflux_ci_secrets_file}/pac-github-app-webhook-secret"
        [SLACK_BOT_TOKEN]="${konflux_ci_secrets_file}/slack-bot-token"
        [MULTI_PLATFORM_AWS_ACCESS_KEY]="${konflux_ci_secrets_file}/multi-platform-aws-access-key"
        [MULTI_PLATFORM_AWS_SECRET_ACCESS_KEY]="${konflux_ci_secrets_file}/multi-platform-aws-secret-access-key"
        [MULTI_PLATFORM_AWS_SSH_KEY]="${konflux_ci_secrets_file}/multi-platform-aws-ssh-key"
        [MULTI_PLATFORM_IBM_API_KEY]="${konflux_ci_secrets_file}/multi-platform-ibm-api-key"
        [DOCKER_IO_AUTH]="${konflux_ci_secrets_file}/docker_io"
        [GITLAB_BOT_TOKEN]="${konflux_ci_secrets_file}/gitlab-bot-token"
        [SEALIGHTS_AGENT_TOKEN]="${konflux_ci_secrets_file}/sealights-agent-token"
    )

    for var in "${!config_envs[@]}"; do
        export "$var"="${config_envs[$var]}"
    done

    for var in "${!load_envs_from_file[@]}"; do
        local file="${load_envs_from_file[$var]}"
        if [[ -f "$file" ]]; then
            export "$var"="$(<"$file")"
        else
            log "ERROR" "Secret file for $var not found at $file"
        fi
    done
}

post_actions() {
    local exit_code=$?

    if [[ "${UNREGISTER_PAC}" == "true" ]]; then
        make ci/sprayproxy/unregister | tee "${ARTIFACT_DIR}"/sprayproxy-unregister.log
    fi

    exit "$exit_code"
}

trap post_actions EXIT

load_envs

oc config view --minify --raw > /workspace/kubeconfig
export KUBECONFIG=/workspace/kubeconfig

# ROSA HCP workaround for Docker limits
# for namespaces 'minio-operator' and 'tekton-results'
oc get secret/pull-secret -n openshift-config --template='{{index .data ".dockerconfigjson" | base64decode}}' > ./global-pull-secret.json
oc get secret -n openshift-config -o yaml pull-secret > global-pull-secret.yaml
yq -i e 'del(.metadata.namespace)' global-pull-secret.yaml
oc registry login --registry=docker.io --auth-basic="$DOCKER_IO_AUTH" --to=./global-pull-secret.json

namespace_sa_names=$(cat << 'EOF'
minio-operator|console-sa
minio-operator|minio-operator
product-kubearchive|default
tekton-logging|vector-tekton-logs-collector
tekton-results|storage-sa
tekton-results|postgres-postgresql
EOF
)
while IFS='|' read -r ns sa_name; do
    oc create namespace "$ns" --dry-run=client -o yaml | oc apply -f -
    oc create sa "$sa_name" -n "$ns" --dry-run=client -o yaml | oc apply -f -
    if ! oc get secret/pull-secret -n "$ns" &> /dev/null; then
        oc apply -f global-pull-secret.yaml -n "$ns"
        oc set data secret/pull-secret -n "$ns" --from-file=.dockerconfigjson=./global-pull-secret.json
    fi
    oc secrets link "$sa_name" pull-secret --for=pull -n "$ns"
done <<< "$namespace_sa_names"

make ci/test/e2e 2>&1 | tee "${ARTIFACT_DIR}"/e2e-tests.log

export DOMAIN="redhat.sealights.co"
export SEALIGHTS_AGENT_TOKEN="${SEALIGHTS_AGENT_TOKEN:-""}"
export BUILD_SESSION_ID="${BUILD_SESSION_ID:-""}"

# Create a Sealights test session
echo "INFO: Creating Sealights test session..."
TEST_SESSION_ID=$(curl -X POST "https://$DOMAIN/sl-api/v1/test-sessions" \
  -H "Authorization: Bearer $SEALIGHTS_AGENT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"labId":"","testStage":"integration-service-e2e","bsid":"'${BUILD_SESSION_ID}'","sessionTimeout":10000}' | jq -r '.data.testSessionId')

if [ -n "$TEST_SESSION_ID" ]; then
  echo "Test session ID: $TEST_SESSION_ID"
  export TEST_SESSION_ID
else
  echo "Failed to retrieve test session ID"
  exit 1
fi

# Fetch excluded tests
RESPONSE=$(curl -X GET "https://$DOMAIN/sl-api/v2/test-sessions/$TEST_SESSION_ID/exclude-tests" \
  -H "Authorization: Bearer $SEALIGHTS_AGENT_TOKEN" \
  -H "Content-Type: application/json")

echo "$RESPONSE" | jq .

# Extract excluded tests
mapfile -t EXCLUDED_TESTS < <(echo "$RESPONSE" | jq -r '.data.excludedTests[].testName')

# Process test report
PROCESSED_JSON=$(
  cat "$ARTIFACT_DIR"/report.json | jq -c '.[] | .SpecReports[]' | while IFS= read -r line; do
    name=$(echo "$line" | jq -r '.LeafNodeText')
    start_raw=$(echo "$line" | jq -r '.StartTime')
    end_raw=$(echo "$line" | jq -r '.EndTime')
    status=$(echo "$line" | jq -r '.State')

    # Process start time with `date`
    start=$(date --date="$start_raw" +%s%3N)

    # Check if end_raw is empty or equals "0001-01-01T00:00:00Z", and use the current time
    if [ -z "$end_raw" ] || [ "$end_raw" == "0001-01-01T00:00:00Z" ]; then
      end=$(date +%s%3N)
    else
      end=$(date --date="$end_raw" +%s%3N)
    fi

    if [ "$status" == "passed" ] || [ "$status" == "failed" ]; then
      echo "{\"name\": \"$name\", \"start\": $start, \"end\": $end, \"status\": \"$status\"}"
    fi
  done | jq -s '.'
)

echo "$PROCESSED_JSON" | jq .

# Send test results to Sealights
curl -X POST "https://$DOMAIN/sl-api/v2/test-sessions/$TEST_SESSION_ID" \
  -H "Authorization: Bearer $SEALIGHTS_AGENT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "${PROCESSED_JSON}"

# Delete the test session
curl -X DELETE "https://$DOMAIN/sl-api/v1/test-sessions/$TEST_SESSION_ID" \
  -H "Authorization: Bearer $SEALIGHTS_AGENT_TOKEN" \
  -H "Content-Type: application/json"

echo "INFO: Script completed successfully."
