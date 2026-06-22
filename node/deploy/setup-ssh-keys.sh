#!/bin/bash
source /opt/deploy-actions/config.env

# Override VAULT_NAME from cloud-init injected file (set at deploy time by Bicep)
if [ -f /opt/deploy-actions/keyvault.env ]; then
  source /opt/deploy-actions/keyvault.env
fi

# Fetch VMSS SSH private key from Azure Key Vault using managed identity.
# The public key is already in authorized_keys via osProfile.ssh.publicKeys.
# This script installs the private key so VMs can SSH to each other.
# Runs with a delay + retry to allow Key Vault access policy to propagate.

SSH_DIR="$USER_HOME/.ssh"
MAX_RETRIES=5
RETRY_DELAY=15

sleep $RETRY_DELAY

for attempt in $(seq 1 $MAX_RETRIES); do
  echo "Attempt $attempt/$MAX_RETRIES: Fetching SSH key from Key Vault..."

  TOKEN=$(curl -s -H "Metadata:true" \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net" \
    | jq -r .access_token)

  if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    echo "WARNING: Failed to get managed identity token. Retrying in ${RETRY_DELAY}s..."
    sleep $RETRY_DELAY
    continue
  fi

  PRIVATE_KEY=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "https://${VAULT_NAME}.vault.azure.net/secrets/${SSH_SECRET_NAME}?api-version=7.4" \
    | jq -r .value)

  if [ -n "$PRIVATE_KEY" ] && [ "$PRIVATE_KEY" != "null" ]; then
    printf '%s\n' "$PRIVATE_KEY" > "$SSH_DIR/id_ed25519"
    chown $DEPLOY_USER:$DEPLOY_USER "$SSH_DIR/id_ed25519"
    chmod 600 "$SSH_DIR/id_ed25519"

    # Derive SSH Host pattern from VNET_PREFIX (e.g., 10.5.0.0/16 -> 10.5.*.*)
    VNET_BASE="${VNET_PREFIX%%/*}"
    IFS='.' read -r v1 v2 v3 v4 <<< "$VNET_BASE"
    VNET_CIDR="${VNET_PREFIX##*/}"
    if [ "$VNET_CIDR" -le 16 ]; then
      SSH_HOST_PATTERN="$v1.$v2.*"
    elif [ "$VNET_CIDR" -le 24 ]; then
      SSH_HOST_PATTERN="$v1.$v2.$v3.*"
    else
      SSH_HOST_PATTERN="$v1.$v2.$v3.*"
    fi

    printf '%s\n' \
      "Host $SSH_HOST_PATTERN" \
      "  StrictHostKeyChecking no" \
      "  UserKnownHostsFile /dev/null" \
      > "$SSH_DIR/config"
    chown $DEPLOY_USER:$DEPLOY_USER "$SSH_DIR/config"
    chmod 644 "$SSH_DIR/config"

    echo "SSH key setup complete. Inter-VM SSH enabled."
    exit 0
  fi

  echo "WARNING: Failed to fetch key. Retrying in ${RETRY_DELAY}s..."
  sleep $RETRY_DELAY
done

echo "ERROR: Could not fetch SSH key after $MAX_RETRIES attempts. Run post-deploy.ps1 manually."
exit 0
