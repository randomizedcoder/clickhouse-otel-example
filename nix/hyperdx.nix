{ lib
, stdenv
, fetchFromGitHub
, nodejs_22
, makeWrapper
, yarn-berry
# Fonts for Next.js build (avoiding Google Fonts download in sandbox)
, inter
, ibm-plex
, roboto
, roboto-mono
}:

# HyperDX build from source using Yarn Berry (v4)
# This uses the nixpkgs yarn-berry infrastructure for reproducible builds

let
  # Import port configuration
  ports = import ./ports.nix;

in
stdenv.mkDerivation (finalAttrs: {
  pname = "hyperdx";
  version = "2.16.0";

  src = fetchFromGitHub {
    owner = "hyperdxio";
    repo = "hyperdx";
    rev = "90a733aab8e2e64573a9aae939c9f08816b0454c";
    hash = "sha256-nFRIuFA8Do1cZDzrLJh2SqRge3KGw+F0sNw8oUefsfE=";
  };

  # Missing hashes for native packages without checksums in yarn.lock
  missingHashes = ./hyperdx-missing-hashes.json;

  # Prefetch yarn dependencies for offline build
  # To update hash: use lib.fakeHash, build, copy the "got:" hash
  offlineCache = yarn-berry.fetchYarnBerryDeps {
    inherit (finalAttrs) src missingHashes;
    hash = "sha256-G+jhv0kAPV+Zu9scdO5K3budrafCoF74XhhZ7CgEgzI=";
  };

  nativeBuildInputs = [
    nodejs_22
    makeWrapper
    yarn-berry  # Provides yarn command for build phase
    yarn-berry.yarnBerryConfigHook
  ];

  # Build environment
  env = {
    NODE_ENV = "production";
    NEXT_TELEMETRY_DISABLED = "1";
    NX_DAEMON = "false";
    NEXT_OUTPUT_STANDALONE = "true";  # Produce standalone Next.js output
  };

  # Patch fonts.ts to use local fonts instead of Google Fonts
  # Next.js tries to download Google Fonts during build, which fails in Nix sandbox
  # We copy fonts from nixpkgs and use next/font/local instead
  postPatch = ''
    # Copy fonts from nixpkgs to app source
    mkdir -p packages/app/src/fonts
    cp ${inter}/share/fonts/truetype/InterVariable.ttf packages/app/src/fonts/Inter.ttf
    cp ${ibm-plex}/share/fonts/opentype/IBMPlexMono-Regular.otf packages/app/src/fonts/IBMPlexMono.otf
    cp ${roboto}/share/fonts/truetype/Roboto-Regular.ttf packages/app/src/fonts/Roboto.ttf
    cp ${roboto-mono}/share/fonts/truetype/RobotoMono/RobotoMono-Regular.ttf packages/app/src/fonts/RobotoMono.ttf

    # Patch fonts.ts to use local fonts
    cat > packages/app/src/fonts.ts << 'EOF'
import localFont from 'next/font/local';

export const ibmPlexMono = localFont({
  src: './fonts/IBMPlexMono.otf',
  variable: '--font-ibm-plex-mono',
  display: 'swap',
});

export const robotoMono = localFont({
  src: './fonts/RobotoMono.ttf',
  variable: '--font-roboto-mono',
  display: 'swap',
});

export const inter = localFont({
  src: './fonts/Inter.ttf',
  variable: '--font-inter',
  display: 'swap',
});

export const roboto = localFont({
  src: './fonts/Roboto.ttf',
  variable: '--font-roboto',
  display: 'swap',
});
EOF
  '';

  buildPhase = ''
    runHook preBuild

    # Build common-utils first (dependency for other packages)
    yarn workspace @hyperdx/common-utils build || true

    # Build API
    yarn workspace @hyperdx/api build || true

    # Build App (Next.js) with standalone output
    yarn workspace @hyperdx/app build || true

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/{app,bin}

    # Copy API build
    mkdir -p $out/app/packages/api
    cp -r packages/api/build $out/app/packages/api/ 2>/dev/null || true
    cp packages/api/package.json $out/app/packages/api/ 2>/dev/null || true

    # Copy App build (Next.js standalone)
    mkdir -p $out/app/packages/app
    if [ -d packages/app/.next/standalone ]; then
      cp -r packages/app/.next/standalone/* $out/app/packages/app/
      [ -d packages/app/.next/static ] && cp -r packages/app/.next/static $out/app/packages/app/.next/
      [ -d packages/app/public ] && cp -r packages/app/public $out/app/packages/app/
    fi

    # Copy common-utils
    mkdir -p $out/app/packages/common-utils
    cp -r packages/common-utils/dist $out/app/packages/common-utils/ 2>/dev/null || true
    cp packages/common-utils/package.json $out/app/packages/common-utils/ 2>/dev/null || true

    # Copy node_modules (excluding broken workspace symlinks)
    cp -r node_modules $out/app/ 2>/dev/null || true

    # Remove broken symlinks to workspace packages we didn't include
    find $out/app/node_modules -type l ! -exec test -e {} \; -delete 2>/dev/null || true

    # Create start script
    # Note: Next.js standalone in a monorepo creates nested packages/ structure
    cat > $out/bin/hyperdx-start << 'SCRIPT'
#!/bin/sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../app"

export HYPERDX_API_PORT=''${HYPERDX_API_PORT:-${toString ports.services.hyperdxApi}}
export HYPERDX_APP_PORT=''${HYPERDX_APP_PORT:-${toString ports.services.hyperdxApp}}

echo "Starting HyperDX API on port $HYPERDX_API_PORT"
echo "Starting HyperDX App on port $HYPERDX_APP_PORT"

node packages/api/build/index.js &
API_PID=$!

# Next.js standalone in monorepo creates nested structure
PORT=$HYPERDX_APP_PORT node packages/app/packages/app/server.js &
APP_PID=$!

trap "kill $API_PID $APP_PID 2>/dev/null" EXIT INT TERM
wait
SCRIPT

    chmod +x $out/bin/hyperdx-start
    wrapProgram $out/bin/hyperdx-start --prefix PATH : ${nodejs_22}/bin

    runHook postInstall
  '';

  meta = with lib; {
    description = "HyperDX - Open source observability platform";
    homepage = "https://github.com/hyperdxio/hyperdx";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "hyperdx-start";
  };
})
