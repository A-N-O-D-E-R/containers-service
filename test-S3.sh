#!/usr/bin/env bash
# Test script for Garage S3 using AWS CLI

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
ENDPOINT="${S3_ENDPOINT:-https://s3.anode.com}"
REGION="${S3_REGION:-garage}"
ACCESS_KEY="${AWS_ACCESS_KEY_ID:-}"
SECRET_KEY="${AWS_SECRET_ACCESS_KEY:-}"
export AWS_CA_BUNDLE="${CA_BUNDLE:-$HOME/.local/share/mkcert/rootCA.pem}"
BUCKET="bucket-$(date +%s)"  # Unique bucket name for testing
TEST_FILE="/tmp/s3-test-upload.txt"
DOWNLOAD_FILE="/tmp/s3-test-download.txt"
OBJECT_KEY="test-object.txt"

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; FAILED=$((FAILED + 1)); }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }

FAILED=0

# ── Pre-flight checks ────────────────────────────────────────────────────────
if ! command -v aws &>/dev/null; then
  echo "aws CLI not found. Install it first." >&2
  exit 1
fi

if [[ -z "$ACCESS_KEY" || -z "$SECRET_KEY" ]]; then
  echo "Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY before running." >&2
  exit 1
fi

AWS="aws --endpoint-url $ENDPOINT --region $REGION"

# ── Cleanup trap ─────────────────────────────────────────────────────────────
cleanup() {
  info "Cleaning up..."
  $AWS s3 rm "s3://$BUCKET/$OBJECT_KEY" --quiet 2>/dev/null || true
  $AWS s3api delete-bucket --bucket "$BUCKET" 2>/dev/null || true
  rm -f "$TEST_FILE" "$DOWNLOAD_FILE"
}
trap cleanup EXIT

echo "────────────────────────────────────────────"
echo "  Garage S3 Test — $ENDPOINT"
echo "  Bucket: $BUCKET"
echo "────────────────────────────────────────────"

# ── 1. Connectivity ──────────────────────────────────────────────────────────
info "Testing connectivity..."
if $AWS s3 ls &>/dev/null; then
  pass "Connected to S3 endpoint"
else
  fail "Cannot reach endpoint $ENDPOINT"
  exit 1
fi

# ── 2. Create bucket ─────────────────────────────────────────────────────────
info "Creating bucket '$BUCKET'..."
if $AWS s3api create-bucket --bucket "$BUCKET" &>/dev/null; then
  pass "Bucket created"
else
  fail "Failed to create bucket"
fi

# ── 3. List buckets ──────────────────────────────────────────────────────────
info "Listing buckets..."
if $AWS s3 ls | grep -q "$BUCKET"; then
  pass "Bucket appears in listing"
else
  fail "Bucket not found in listing"
fi

# ── 4. Upload object ─────────────────────────────────────────────────────────
CONTENT="Garage S3 test — $(date -u)"
echo "$CONTENT" > "$TEST_FILE"
info "Uploading object..."
if $AWS s3 cp "$TEST_FILE" "s3://$BUCKET/$OBJECT_KEY" &>/dev/null; then
  pass "Object uploaded"
else
  fail "Failed to upload object"
fi

# ── 5. List objects ──────────────────────────────────────────────────────────
info "Listing objects in bucket..."
if $AWS s3 ls "s3://$BUCKET/" | grep -q "$OBJECT_KEY"; then
  pass "Object appears in bucket listing"
else
  fail "Object not found in bucket listing"
fi

# ── 6. Head object (metadata) ────────────────────────────────────────────────
info "Fetching object metadata..."
if $AWS s3api head-object --bucket "$BUCKET" --key "$OBJECT_KEY" &>/dev/null; then
  pass "head-object succeeded"
else
  fail "head-object failed"
fi

# ── 7. Download and verify ───────────────────────────────────────────────────
info "Downloading object..."
if $AWS s3 cp "s3://$BUCKET/$OBJECT_KEY" "$DOWNLOAD_FILE" &>/dev/null; then
  DOWNLOADED=$(cat "$DOWNLOAD_FILE")
  if [[ "$DOWNLOADED" == "$CONTENT" ]]; then
    pass "Downloaded content matches uploaded content"
  else
    fail "Content mismatch: expected '$CONTENT', got '$DOWNLOADED'"
  fi
else
  fail "Failed to download object"
fi

# ── 8. Presigned URL ─────────────────────────────────────────────────────────
info "Generating presigned URL..."
PRESIGNED=$($AWS s3 presign "s3://$BUCKET/$OBJECT_KEY" --expires-in 60 2>/dev/null || true)
if [[ -n "$PRESIGNED" ]]; then
  pass "Presigned URL generated"
  if command -v curl &>/dev/null; then
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "$PRESIGNED")
    if [[ "$HTTP_CODE" == "200" ]]; then
      pass "Presigned URL is reachable (HTTP $HTTP_CODE)"
    else
      fail "Presigned URL returned HTTP $HTTP_CODE"
    fi
  fi
else
  fail "Failed to generate presigned URL"
fi

# ── 9. Delete object ─────────────────────────────────────────────────────────
info "Deleting object..."
if $AWS s3 rm "s3://$BUCKET/$OBJECT_KEY" &>/dev/null; then
  pass "Object deleted"
else
  fail "Failed to delete object"
fi

# ── 10. Delete bucket ────────────────────────────────────────────────────────
info "Deleting bucket..."
if $AWS s3api delete-bucket --bucket "$BUCKET" &>/dev/null; then
  pass "Bucket deleted"
else
  fail "Failed to delete bucket"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo "────────────────────────────────────────────"
if [[ $FAILED -eq 0 ]]; then
  echo -e "${GREEN}All tests passed.${NC}"
else
  echo -e "${RED}$FAILED test(s) failed.${NC}"
  exit 1
fi
