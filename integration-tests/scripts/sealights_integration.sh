export DOMAIN="redhat.sealights.co"
export SEALIGHTS_AGENT_TOKEN="${SEALIGHTS_AGENT_TOKEN:-""}"
export BUILD_SESSION_ID="${BUILD_SESSION_ID:-""}"

cat report.json

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
  cat "report.json" | jq -c '.[] | .SpecReports[]' | while IFS= read -r line; do
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