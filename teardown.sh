#!/bin/bash
set -u
cd "$(dirname "$0")"
[ ! -f .env ] && { echo ".env missing"; exit 1; }
set -a; source .env; set +a

echo "This will DELETE the entire '$NAMESPACE' namespace and all ES data."
read -p "Continue? (yes/no): " ans
[ "$ans" = "yes" ] || exit 1

kubectl delete namespace "$NAMESPACE" --timeout=120s
rm -rf .rendered
echo "Done."
