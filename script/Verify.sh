#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Verify.sh — verify all BiliquidVIPCard contracts on Basescan (Base Sepolia)
#
# Usage:
#   source .env && bash script/Verify.sh
#
# Required env vars (set in .env):
#   BASESCAN_API_KEY
#
# What gets verified:
#   1. BiliquidVIPCard v7 implementation  0xA8274716dF4B517FB1Ea36380e93C6327ecbD4FC
#   2. ERC1967Proxy (the user-facing proxy) 0xfE73547Ef451d9b6CeD7e0FBf400F10a2C5EAE17
#
# Note: v1 implementation (0x571C30A8E562a73f016AD5F75EA212971336E11a) cannot be
#       re-verified because the source has since been upgraded to v7.  It is no
#       longer the active implementation and does not need verification.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

FORGE="$(dirname "$(dirname "$(realpath "$0")")")/../.foundry/bin/forge"
CAST="$(dirname "$FORGE")/cast"

# Fall back to PATH if the relative path doesn't resolve
command -v forge &>/dev/null && FORGE=forge
command -v cast  &>/dev/null && CAST=cast

: "${BASESCAN_API_KEY:?BASESCAN_API_KEY is not set — run: source .env}"

CHAIN="base-sepolia"

# ── Contract addresses ────────────────────────────────────────────────────────
IMPL_V7="0xA8274716dF4B517FB1Ea36380e93C6327ecbD4FC"
PROXY="0xfE73547Ef451d9b6CeD7e0FBf400F10a2C5EAE17"

# Proxy constructor args (recorded from Deploy.s.sol broadcast):
#   _logic : v1 impl used at deploy time
#   _data  : initialize(usdc, treasury) calldata
IMPL_V1_AT_DEPLOY="0x571C30A8E562a73f016AD5F75EA212971336E11a"
INIT_DATA="0x485cc955000000000000000000000000e644affa10e61452e53ec261f9c715eff50ef2f000000000000000000000000099712af479f91e7297e8f09bc7880b51ad0fc683"

PROXY_CONSTRUCTOR_ARGS="$("$CAST" abi-encode \
  "constructor(address,bytes)" \
  "$IMPL_V1_AT_DEPLOY" \
  "$INIT_DATA")"

# ── 1. Verify v7 implementation ───────────────────────────────────────────────
echo ""
echo "▶ Verifying BiliquidVIPCard v7 implementation @ $IMPL_V7"
"$FORGE" verify-contract \
  --chain "$CHAIN" \
  --etherscan-api-key "$BASESCAN_API_KEY" \
  --watch \
  "$IMPL_V7" \
  src/BiliquidVIPCard.sol:BiliquidVIPCard

# ── 2. Verify ERC1967Proxy ────────────────────────────────────────────────────
echo ""
echo "▶ Verifying ERC1967Proxy (user-facing proxy) @ $PROXY"
"$FORGE" verify-contract \
  --chain "$CHAIN" \
  --etherscan-api-key "$BASESCAN_API_KEY" \
  --constructor-args "$PROXY_CONSTRUCTOR_ARGS" \
  --watch \
  "$PROXY" \
  "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy"

echo ""
echo "✓ All verifications complete."
echo ""
echo "  Implementation v7 : https://sepolia.basescan.org/address/$IMPL_V7#code"
echo "  Proxy             : https://sepolia.basescan.org/address/$PROXY#code"
echo ""
echo "  Basescan should auto-detect the proxy pattern and show the v7 ABI."
echo "  If not, visit the proxy page → 'More Options' → 'Is this a proxy?' → verify."
