#!/usr/bin/env bash
# Usage: delete_chronos_resources.sh --resource-group <RESOURCE_GROUP> [--wait]

set -euo pipefail

RESOURCE_GROUP="chronos-test"
WAIT_FOR_DELETE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      echo "delete_chronos_resources.sh - delete an Azure resource group"
      echo ""
      echo "Usage:"
      echo "  ./delete_chronos_resources.sh --resource-group <name> [--wait]"
      echo ""
      echo "Options:"
      echo "  --resource-group <name>   Resource group name (default: chronos-test)"
      echo "  --wait                    Wait until deletion completes"
      exit 0
      ;;
    --resource-group)
      RESOURCE_GROUP="$2"
      shift 2
      ;;
    --resource-group=*)
      RESOURCE_GROUP="${1#*=}"
      shift
      ;;
    --wait)
      WAIT_FOR_DELETE=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

echo "Deleting resource group '$RESOURCE_GROUP'..."
az group delete --name "$RESOURCE_GROUP" --yes --no-wait

if [ "$WAIT_FOR_DELETE" = true ]; then
  echo "Waiting for resource group '$RESOURCE_GROUP' to be deleted..."
  az group wait --name "$RESOURCE_GROUP" --deleted
  echo "Deleted."
else
  echo "Delete request submitted (async)."
fi
