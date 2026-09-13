#!/usr/bin/env bash
# Manual deploy — mirrors .github/workflows/deploy.yml (which runs on every
# push to master). The PWA is served from /pwa/ inside the landing site.
set -euo pipefail

echo "==> Building Flutter web..."
flutter build web --release --base-href=/pwa/

echo "==> Copying build into site/public/pwa..."
rm -rf site/public/pwa
cp -r build/web site/public/pwa

echo "==> Deploying to Firebase Hosting..."
firebase deploy --only hosting --project dehla-pakad-game

echo "==> Done: https://dehla-pakad-game.web.app/pwa/"
