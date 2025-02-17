#!/bin/bash
# LANG: "en" for English (default) or "ja" for Japanese.
LANG=${LANG:-en}

# DEBUG_MODE: 1 enables detailed logging (default: 0)
DEBUG_MODE=0
# MIGRATE_FOLDERS_ONLY: 1 transfers only the directus_folders table (folder structure), not directus_files
MIGRATE_FOLDERS_ONLY=1

if [ "$DEBUG_MODE" -eq 1 ]; then
  set -x
fi
set -e

# 関数: 言語切替用メッセージ出力
msg() {
  # Usage: msg "English message" "日本語メッセージ"
  if [ "$LANG" = "ja" ]; then
    echo "$2"
  else
    echo "$1"
  fi
}

# Debug log function remains in English (or can be extended if desired)
debug_log() {
  if [ "$DEBUG_MODE" -eq 1 ]; then
    echo "[DEBUG] $1"
  fi
}

# Error handler function
error_exit() {
  echo "❌ Error: $1" >&2
  exit 1
}

# Check if postgresql-client exists in a container; if not, install it
install_pg_client_if_missing() {
  local container="$1"
  debug_log "Checking pg_dump and pg_restore in container $container"
  msg "【Check】Verifying pg_dump and pg_restore in container $container..." "【チェック】コンテナ $container 内に pg_dump と pg_restore が存在するか確認中..."
  if docker exec -it "$container" sh -c "command -v pg_dump && command -v pg_restore" > /dev/null 2>&1; then
    msg "pg_dump and pg_restore are already installed." "pg_dump と pg_restore は既にインストール済みです。"
  else
    msg "postgresql-client not found in $container. Attempting installation..." "postgresql-client が見つかりません。$container 内に自動インストールを試みます..."
    if docker exec -it --user root "$container" sh -c "command -v apt-get" > /dev/null 2>&1; then
      debug_log "Using apt-get in $container"
      docker exec -it --user root "$container" sh -c "apt-get update && apt-get install -y postgresql-client" || error_exit "Failed to install postgresql-client in $container"
    elif docker exec -it --user root "$container" sh -c "command -v apk" > /dev/null 2>&1; then
      debug_log "Using apk in $container"
      docker exec -it --user root "$container" sh -c "apk update && apk add postgresql-client" || error_exit "Failed to install postgresql-client in $container"
    else
      error_exit "No suitable package manager found in $container."
    fi
  fi
}

# Functions to generate container and volume names from an environment identifier
get_container_name() {
  echo "directus-$1-directus-1"
}

get_volume_name() {
  echo "directus_uploads-directus-$1"
}

# Input environment identifiers
msg "Enter source environment identifier (e.g., 883409): " "開発環境の識別子 (例: 883409) を入力してください: "
read -p "" ENV_A
msg "Enter target environment identifier (e.g., f09f1b): " "本番環境の識別子 (例: f09f1b) を入力してください: "
read -p "" ENV_B

CONTAINER_A=$(get_container_name "$ENV_A")
CONTAINER_B=$(get_container_name "$ENV_B")
VOLUME_A=$(get_volume_name "$ENV_A")
VOLUME_B=$(get_volume_name "$ENV_B")

# Verify that the specified containers exist
docker inspect "$CONTAINER_A" > /dev/null 2>&1 || error_exit "Source container $CONTAINER_A does not exist." 
docker inspect "$CONTAINER_B" > /dev/null 2>&1 || error_exit "Target container $CONTAINER_B does not exist."

echo ""
msg "Environment Settings:" "環境設定:"
msg "  Source container: $CONTAINER_A" "  開発環境コンテナ: $CONTAINER_A"
msg "  Target container: $CONTAINER_B" "  本番環境コンテナ: $CONTAINER_B"
msg "  Source volume: $VOLUME_A" "  開発環境ボリューム: $VOLUME_A"
msg "  Target volume: $VOLUME_B" "  本番環境ボリューム: $VOLUME_B"
msg "  Storage path: /directus/uploads" "  ストレージパス: /directus/uploads"

msg "Redeploy target container after migration? (y/n): " "移管後に本番環境コンテナを再デプロイしますか? (y/n): "
read -p "" REDEPLOY

echo ""
msg "Starting Migration Process..." "移管処理を開始します..."

# Remove existing snapshot in the source container
docker exec -it "$CONTAINER_A" rm -f /tmp/schema.yaml || debug_log "No existing snapshot to remove."

# Step 1: Take new schema snapshot from source
msg "【Step 1】Taking schema snapshot from Source ($CONTAINER_A)..." "【Step 1】開発環境 ($CONTAINER_A) からスナップショットを取得中..."
docker exec -it "$CONTAINER_A" /bin/sh -c "npx directus schema snapshot /tmp/schema.yaml" || error_exit "Failed to take snapshot." 

# Step 2: Copy snapshot file from source to host
msg "【Step 2】Copying snapshot file from Source to host..." "【Step 2】開発環境コンテナからホストへスナップショットファイルをコピー中..."
docker cp "$CONTAINER_A":/tmp/schema.yaml ./schema.yaml || error_exit "Failed to copy snapshot file."

# Step 3: Transfer snapshot file from host to target
msg "【Step 3】Transferring snapshot file to Target ($CONTAINER_B)..." "【Step 3】ホスト上のスナップショットファイルを本番環境 ($CONTAINER_B) コンテナへ転送中..."
docker cp ./schema.yaml "$CONTAINER_B":/tmp/schema.yaml || error_exit "Failed to copy snapshot file to target."

# Step 4: Apply schema snapshot in target
msg "【Step 4】Applying schema snapshot in Target..." "【Step 4】本番環境コンテナ内でスナップショットを適用中..."
docker exec -it "$CONTAINER_B" /bin/sh -c "npx directus schema apply /tmp/schema.yaml" || error_exit "Failed to apply schema."

# Step 5: Migrate storage data (uploads)
msg "【Step 5】Migrating storage data..." "【Step 5】ストレージデータを移管中..."
msg "Copying uploads from Source ($VOLUME_A) to Target ($VOLUME_B)..." "開発環境 ($VOLUME_A) から本番環境 ($VOLUME_B) にアップロードファイルをコピー中..."
docker run --rm -v "$VOLUME_A":/data -v "$(pwd)":/backup alpine tar -czvf /backup/uploads.tar.gz -C /data . || error_exit "Failed to archive storage data."
docker run --rm -v "$(pwd)":/backup -v "$VOLUME_B":/data alpine tar -xzvf /backup/uploads.tar.gz -C /data || error_exit "Failed to extract storage data."

if [ "$MIGRATE_FOLDERS_ONLY" -eq 1 ]; then
  # Step 6: Export folder structure (directus_folders) from source
  msg "【Step 6】Exporting folder structure from Source (directus_folders)..." "【Step 6】開発環境から directus_folders テーブルのデータ（フォルダー構造）をエクスポート中..."
  docker exec -it "$CONTAINER_A" /bin/sh -c "PGPASSWORD=\$DB_PASSWORD pg_dump -h database -U directus -t directus_folders -a -Fp" > directus_folders.sql || error_exit "Failed to export folder structure."
  # Remove pg_dump warning lines and unwanted configuration parameters
  sed -i '/^pg_dump:/d' directus_folders.sql
  sed -i '/^SET transaction_timeout/d' directus_folders.sql
  debug_log "Exported directus_folders dump (first 10 lines):"
  if [ "$DEBUG_MODE" -eq 1 ]; then
    head -n 10 directus_folders.sql
  fi

  # Step 7: Import folder structure into target
  msg "【Step 7】Replacing folder structure data in Target..." "【Step 7】本番環境の directus_folders テーブルのデータを削除し、エクスポートデータをインポート中..."
  docker exec -it "$CONTAINER_B" /bin/sh -c "PGPASSWORD=\$DB_PASSWORD psql -h database -U directus -d directus -c 'DELETE FROM directus_folders;'" || error_exit "Failed to delete existing folder structure in target."
  docker cp directus_folders.sql "$CONTAINER_B":/tmp/directus_folders.sql || error_exit "Failed to copy folder structure dump to target."
  docker exec -it "$CONTAINER_B" /bin/sh -c "PGPASSWORD=\$DB_PASSWORD psql -h database -U directus -d directus -f /tmp/directus_folders.sql" || error_exit "Failed to import folder structure into target."
else
  # Alternative Step 6: For migrating directus_files instead of folder structure
  msg "【Step 6】Exporting file metadata from Source (directus_files)..." "【Step 6】開発環境から directus_files テーブルのデータをエクスポート中..."
  install_pg_client_if_missing "$CONTAINER_A"
  docker exec -it "$CONTAINER_A" /bin/sh -c "PGPASSWORD=\$DB_PASSWORD pg_dump -h database -U directus -t directus_files -a -Fc -f /tmp/directus_files.dump" || error_exit "Failed to export file metadata."
  docker cp "$CONTAINER_A":/tmp/directus_files.dump ./directus_files.dump || error_exit "Failed to copy file metadata dump."
  msg "【Step 7】Importing file metadata into Target..." "【Step 7】本番環境に directus_files テーブルのデータをインポート中..."
  install_pg_client_if_missing "$CONTAINER_B"
  docker cp ./directus_files.dump "$CONTAINER_B":/tmp/directus_files.dump || error_exit "Failed to copy file metadata dump to target."
  docker exec -it "$CONTAINER_B" /bin/sh -c "PGPASSWORD=\$DB_PASSWORD pg_restore -a --disable-triggers -h database -U directus -d directus /tmp/directus_files.dump" || error_exit "Failed to import file metadata into target."
fi

# Step 8: Optionally redeploy the target container
if [[ "$REDEPLOY" =~ ^[Yy]$ ]]; then
    msg "【Step 8】Redeploying Target container..." "【Step 8】本番環境コンテナを再デプロイ中..."
    docker restart "$CONTAINER_B" || error_exit "Failed to restart target container."
    msg "Target container redeployed successfully." "本番環境コンテナの再デプロイが完了しました。"
else
    msg "Redeployment skipped." "再デプロイはスキップされました。"
fi

# Display backup file location
msg "Backup file (uploads archive) is stored at $(pwd)/uploads.tar.gz" "バックアップファイル (uploads のアーカイブ) は $(pwd)/uploads.tar.gz に保存されています。"

echo ""
msg "✨✨✨ Migration process completed successfully! ✨✨✨" "✨✨✨ 移管処理がすべて完了しました! ✨✨✨"
msg "----------------------------------------------------" "----------------------------------------------------"
