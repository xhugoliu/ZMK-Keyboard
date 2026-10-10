#!/usr/bin/env bash
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${ZMK_P31N_REPO:-$SCRIPT_ROOT}"
SHIELD="${ZMK_P31N_SHIELD:-p31n}"
BOARD="${ZMK_P31N_BOARD:-nrfmicro/nrf52840/zmk}"
WORKSPACE="${ZMK_P31N_WORKSPACE:-}"
VENV="${ZMK_P31N_VENV:-}"
SDK="${ZMK_P31N_SDK:-$HOME/Projects/zmk-build-env/toolchains/zephyr-sdk-0.16.9}"
OUTPUT="${ZMK_P31N_OUTPUT:-}"

PUBLIC_BUILD=0
CLEAN=0
UPDATE=0
COPY_TO_SHIELD=0
FLASH=0
FLASH_ONLY=0
BOOTLOADER_VOLUME="${ZMK_P31N_BOOTLOADER_VOLUME:-/Volumes/NICENANO}"

usage() {
  cat <<'USAGE'
Build X.Tips P31n ZMK firmware locally.

Usage:
  build_p31n.sh [options]

Options:
  --repo PATH           ZMK-Keyboard repo path
  --shield NAME         Shield name, default p31n
  --board NAME          Board target, default nrfmicro/nrf52840/zmk
  --workspace PATH      West workspace, default REPO/.omx/ci-workspace
  --venv PATH           Python venv, default REPO/.omx/ci-venv
  --sdk PATH            Zephyr SDK path, default verified SDK 0.16.9
  --output PATH         Copy UF2 to this path
  --public              Use public placeholder macros; write a separate public UF2
  --copy-to-shield      Also copy UF2 to REPO/SHIELD/SHIELD.uf2
  --flash               Copy the built UF2 to the mounted bootloader volume
  --flash-only          Skip build and flash the existing output UF2
  --bootloader-volume PATH
                        Bootloader volume path, default /Volumes/NICENANO
  --clean               Remove the build directory before building
  --update              Run west update before building
  -h, --help            Show this help

Environment overrides:
  ZMK_P31N_REPO, ZMK_P31N_SHIELD, ZMK_P31N_BOARD, ZMK_P31N_WORKSPACE,
  ZMK_P31N_VENV, ZMK_P31N_SDK, ZMK_P31N_OUTPUT, ZMK_P31N_BOOTLOADER_VOLUME
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="$2"
      shift 2
      ;;
    --shield)
      SHIELD="$2"
      shift 2
      ;;
    --board)
      BOARD="$2"
      shift 2
      ;;
    --workspace)
      WORKSPACE="$2"
      shift 2
      ;;
    --venv)
      VENV="$2"
      shift 2
      ;;
    --sdk)
      SDK="$2"
      shift 2
      ;;
    --output)
      OUTPUT="$2"
      shift 2
      ;;
    --public)
      PUBLIC_BUILD=1
      shift
      ;;
    --copy-to-shield)
      COPY_TO_SHIELD=1
      shift
      ;;
    --flash)
      FLASH=1
      shift
      ;;
    --flash-only)
      FLASH=1
      FLASH_ONLY=1
      shift
      ;;
    --bootloader-volume)
      BOOTLOADER_VOLUME="$2"
      shift 2
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    --update)
      UPDATE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$WORKSPACE" ]]; then
  WORKSPACE="$REPO/.omx/ci-workspace"
fi
if [[ -z "$VENV" ]]; then
  VENV="$REPO/.omx/ci-venv"
fi

SAFE_BOARD="${BOARD//\//_}"
BUILD_DIR="$WORKSPACE/build-$SHIELD-sdk016"
if [[ "$PUBLIC_BUILD" -eq 1 ]]; then
  BUILD_DIR="$WORKSPACE/build-$SHIELD-public-sdk016"
fi
if [[ -z "$OUTPUT" ]]; then
  OUTPUT="$REPO/.omx/artifacts/$SHIELD-$SAFE_BOARD.uf2"
  if [[ "$PUBLIC_BUILD" -eq 1 ]]; then
    OUTPUT="$REPO/.omx/artifacts/$SHIELD-$SAFE_BOARD-public.uf2"
  fi
fi

die() {
  echo "error: $*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

ensure_repo() {
  [[ -d "$REPO" ]] || die "repo not found: $REPO"
  [[ -f "$REPO/config/west.yml" ]] || die "missing manifest: $REPO/config/west.yml"
  [[ -d "$REPO/$SHIELD" ]] || die "missing shield directory: $REPO/$SHIELD"
  [[ -f "$REPO/$SHIELD/$SHIELD.keymap" ]] || die "missing keymap: $REPO/$SHIELD/$SHIELD.keymap"
}

ensure_venv() {
  mkdir -p "$(dirname "$VENV")"

  if [[ ! -x "$VENV/bin/python" ]]; then
    if have uv; then
      uv venv --python 3.11 "$VENV"
    elif have python3.11; then
      python3.11 -m venv "$VENV"
    else
      die "need uv or python3.11 to create $VENV"
    fi
  fi

  if have uv; then
    uv pip install --python "$VENV/bin/python" west cmake ninja grpcio-tools >/dev/null
  elif [[ -x "$VENV/bin/pip" ]]; then
    "$VENV/bin/pip" install west cmake ninja grpcio-tools >/dev/null
  else
    die "venv has no pip and uv is unavailable: $VENV"
  fi

  cat > "$VENV/bin/protoc" <<SH
#!/bin/sh
exec "$VENV/bin/python" -m grpc_tools.protoc "\$@"
SH
  chmod +x "$VENV/bin/protoc"
}

ensure_workspace() {
  mkdir -p "$WORKSPACE/config"
  if ! cmp -s "$REPO/config/west.yml" "$WORKSPACE/config/west.yml" 2>/dev/null; then
    cp "$REPO/config/west.yml" "$WORKSPACE/config/west.yml"
    UPDATE=1
  fi

  if [[ ! -d "$WORKSPACE/.west" ]]; then
    (cd "$WORKSPACE" && "$VENV/bin/west" init -l config)
    UPDATE=1
  fi

  if [[ "$UPDATE" -eq 1 || ! -d "$WORKSPACE/zmk/app" || ! -d "$WORKSPACE/zephyr" ]]; then
    (cd "$WORKSPACE" && "$VENV/bin/west" update)
    (cd "$WORKSPACE" && "$VENV/bin/west" zephyr-export)
  fi

  if have uv; then
    uv pip install --python "$VENV/bin/python" -r "$WORKSPACE/zephyr/scripts/requirements.txt" >/dev/null
    uv pip install --python "$VENV/bin/python" -r "$WORKSPACE/zmk/app/scripts/requirements.txt" >/dev/null
  elif [[ -x "$VENV/bin/pip" ]]; then
    "$VENV/bin/pip" install -r "$WORKSPACE/zephyr/scripts/requirements.txt" >/dev/null
    "$VENV/bin/pip" install -r "$WORKSPACE/zmk/app/scripts/requirements.txt" >/dev/null
  fi

  mkdir -p "$WORKSPACE/zmk/app/boards/shields"
  ln -sfn "$REPO/$SHIELD" "$WORKSPACE/zmk/app/boards/shields/$SHIELD"
}

ensure_sdk() {
  [[ -d "$SDK" ]] || die "Zephyr SDK not found: $SDK"
  [[ -x "$SDK/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc" ]] || die "arm-zephyr-eabi-gcc not executable under SDK: $SDK"
}

build_firmware() {
  if [[ "$CLEAN" -eq 1 ]]; then
    rm -rf "$BUILD_DIR"
  elif [[ -f "$BUILD_DIR/CMakeCache.txt" ]] && ! grep -Fq "$SDK" "$BUILD_DIR/CMakeCache.txt"; then
    echo "SDK path changed; clearing stale build cache: $BUILD_DIR"
    rm -rf "$BUILD_DIR"
  fi

  local module_args=()
  if [[ "$PUBLIC_BUILD" -eq 1 ]]; then
    module_args+=("-DDTS_EXTRA_CPPFLAGS=-DP31N_PUBLIC_BUILD=1")
  fi
  if [[ -f "$REPO/modules/p31n-telemetry/zephyr/module.yml" ]]; then
    module_args+=("-DZMK_EXTRA_MODULES=$REPO/modules/p31n-telemetry")
  fi

  env \
    PATH="$VENV/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    ZEPHYR_BASE="$WORKSPACE/zephyr" \
    ZEPHYR_SDK_INSTALL_DIR="$SDK" \
    ZEPHYR_TOOLCHAIN_VARIANT=zephyr \
    "$VENV/bin/west" build \
      -s "$WORKSPACE/zmk/app" \
      -b "$BOARD" \
      -d "$BUILD_DIR" \
      -S studio-rpc-usb-uart \
      -- \
      -DZephyr_DIR="$WORKSPACE/zephyr/share/zephyr-package/cmake" \
      -DSHIELD="$SHIELD" \
      -DCONFIG_ZMK_STUDIO=y \
      "${module_args[@]}"
}

copy_outputs() {
  local uf2="$BUILD_DIR/zephyr/zmk.uf2"
  [[ -f "$uf2" ]] || die "expected UF2 not found: $uf2"

  mkdir -p "$(dirname "$OUTPUT")"
  cp "$uf2" "$OUTPUT"

  if [[ "$COPY_TO_SHIELD" -eq 1 ]]; then
    cp "$uf2" "$REPO/$SHIELD/$SHIELD.uf2"
  fi

  echo
  echo "Build complete"
  echo "UF2: $OUTPUT"
  if [[ "$COPY_TO_SHIELD" -eq 1 ]]; then
    echo "Shield copy: $REPO/$SHIELD/$SHIELD.uf2"
  fi
  ls -lh "$OUTPUT"
}

flash_output() {
  [[ -f "$OUTPUT" ]] || die "UF2 not found: $OUTPUT"
  [[ -d "$BOOTLOADER_VOLUME" ]] || die "bootloader volume not mounted: $BOOTLOADER_VOLUME"

  echo
  echo "Flashing UF2"
  echo "Source: $OUTPUT"
  echo "Target: $BOOTLOADER_VOLUME"
  cp -X "$OUTPUT" "$BOOTLOADER_VOLUME/"
  sync
  echo "UF2 copied. The bootloader volume should disappear and the keyboard should reboot."
}

ensure_repo
if [[ "$FLASH_ONLY" -eq 0 ]]; then
  ensure_venv
  ensure_workspace
  ensure_sdk
  build_firmware
  copy_outputs
fi
if [[ "$FLASH" -eq 1 ]]; then
  flash_output
fi
