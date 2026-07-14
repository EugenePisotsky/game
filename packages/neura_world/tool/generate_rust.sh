#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$(cd "${script_dir}/.." && pwd)"
repo_root="$(cd "${package_dir}/../.." && pwd)"

cd "${repo_root}"

rm -rf "${package_dir}/lib/src/rust"
mkdir -p "${package_dir}/lib/src/rust"

flutter_rust_bridge_codegen generate \
  --rust-root packages/neura_world/rust \
  --rust-input crate::api \
  --rust-output packages/neura_world/rust/src/frb_generated.rs \
  --dart-output packages/neura_world/lib/src/rust \
  --dart-root packages/neura_world \
  --dart-entrypoint-class-name RustLib \
  --no-add-mod-to-lib

cargo fmt --manifest-path packages/neura_world/rust/Cargo.toml
dart format packages/neura_world/lib/src/rust
