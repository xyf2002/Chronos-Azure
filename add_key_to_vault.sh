#!/usr/bin/bash
set -euo pipefail

# Variables
VAULT_NAME="chronos-expr"
SECRET_NAME="chronos-key"
PEM_FILE_PATH="./azure-key"

# Validate file exists
if [ ! -f "$PEM_FILE_PATH" ]; then
  echo "ERROR: Key file not found at $PEM_FILE_PATH"
  exit 1
fi

# Read first line and strip any stray CR characters (useful if file has CRLF)
first_line=$(head -n 1 "$PEM_FILE_PATH" | tr -d '\r')

# Detect key type from the first line and choose a content-type for Key Vault
case "$first_line" in
  "-----BEGIN OPENSSH PRIVATE KEY-----")
    CONTENT_TYPE="application/ssh-private-key"
    ;;
  "-----BEGIN RSA PRIVATE KEY-----"|"-----BEGIN PRIVATE KEY-----"|"-----BEGIN EC PRIVATE KEY-----")
    CONTENT_TYPE="application/x-pem-file"
    ;;
  *)
    # Fallback
    CONTENT_TYPE="text/plain"
    ;;
esac

echo "Uploading key file '$PEM_FILE_PATH' to Key Vault '$VAULT_NAME' as secret '$SECRET_NAME' with content-type '$CONTENT_TYPE'"

CONTENT_TYPE="application/ssh-private-key"

# Upload the private key as a secret
az keyvault secret set \
  --vault-name "$VAULT_NAME" \
  --name "$SECRET_NAME" \
  --file "$PEM_FILE_PATH" \
  --content-type "$CONTENT_TYPE"


# Upload the private key as a secret
az keyvault secret set \
  --vault-name "chronos-expr" \
  --name "chronos-key" \
  --file "./azure-key" \
  --content-type "application/ssh-private-key"

