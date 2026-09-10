#!/usr/bin/env bash
set -euo pipefail

echo "==> Building Flutter web..."
flutter build web

echo "==> Deploying to Firebase Hosting..."
firebase deploy --only hosting

echo "==> Done: https://dehla-pakad-game.web.app"
