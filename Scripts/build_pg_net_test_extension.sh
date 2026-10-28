#!/usr/bin/env bash
set -euo pipefail

# Builds the real extension installed by the approved Supabase platform upgrade.
if [[ $# != 2 ]]; then
  echo "Usage: $0 <pg_config path> <new output directory>" >&2
  exit 2
fi
pg_config_path="$1"
output_dir="$2"
if [[ -e "$output_dir" ]]; then
  echo "Refusing to overwrite an existing extension build" >&2
  exit 2
fi
git clone --quiet https://github.com/supabase/pg_net.git "$output_dir"
git -C "$output_dir" checkout --quiet --detach 698fb055f666366a78c112b0578b0a5652ddbcfa
test "$(git -C "$output_dir" rev-parse HEAD)" = 698fb055f666366a78c112b0578b0a5652ddbcfa
make -C "$output_dir" PG_CONFIG="$pg_config_path" -j2
# PostgreSQL 18 can load extensions from a private control-file directory.
# PostgreSQL 17 CI uses make install inside its disposable database container.
mkdir "$output_dir/extension"
cp "$output_dir/pg_net.control" "$output_dir"/sql/pg_net--*.sql "$output_dir/extension/"
