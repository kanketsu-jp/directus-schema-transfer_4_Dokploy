#!/bin/bash
# LANG: "en" なら英語 (default) 、"ja" なら日本語 (default)
LANG=${LANG:-ja}

# DEBUG_MODE: 1 なら詳細ログを出力 (default: 0)
DEBUG_MODE=0
# MIGRATE_FOLDERS_ONLY: 1 なら directus_files ではなく directus_folders テーブル（フォルダー構造）のみ移管
MIGRATE_FOLDERS_ONLY=1

if [ "$DEBUG_MODE" -eq 1 ]; then
  set -x
fi
set -e

###############################################################################
# メッセージ出力用関数（デフォルトは日本語）
msg() {
  # Usage: msg "English message" "日本語メッセージ"
  if [ "$LANG" = "ja" ]; then
    echo "$2"
  else
    echo "$1"
  fi
}

# デバッグログ用関数
debug_log() {
  if [ "$DEBUG_MODE" -eq 1 ]; then
    echo "[DEBUG] $1"
  fi
}

# エラー発生時にメッセージを出して終了する関数
error_exit() {
  echo "❌ エラー: $1" >&2
  exit 1
}

###############################################################################
# PostgreSQL クライアントツール (pg_dump, pg_restore, psql) の存在をチェックし、
# なければ apk を使用して自動インストールを試みる関数
install_pg_client_if_missing() {
  local container="$1"
  debug_log "Checking for pg_dump, pg_restore, and psql in container $container"
  msg "【チェック】コンテナ $container 内に PostgreSQL クライアントツールが存在するか確認中..." "【チェック】コンテナ $container 内に pg_dump, pg_restore, psql が存在するか確認中..."
  if docker exec -it "$container" sh -c "command -v pg_dump && command -v pg_restore && command -v psql" > /dev/null 2>&1; then
    msg "PostgreSQL クライアントツールは既にインストール済みです。" "PostgreSQL クライアントツールは既にインストール済みです。"
  else
    msg "PostgreSQL クライアントツールが見つかりません。$container 内に自動インストールを試みます..." "PostgreSQL クライアントツールが見つかりません。$container 内に自動インストールを試みます..."
    # Alpine Linux では apt-get は存在しないため、apk を優先します
    if docker exec -it --user root "$container" sh -c "command -v apk" > /dev/null 2>&1; then
      debug_log "apk を使用します: $container"
      docker exec -it --user root "$container" sh -c "apk update && apk add postgresql-client" || error_exit "$container 内で PostgreSQL クライアントの自動インストールに失敗しました"
    elif docker exec -it --user root "$container" sh -c "command -v apt-get" > /dev/null 2>&1; then
      debug_log "apt-get を使用します: $container"
      docker exec -it --user root "$container" sh -c "apt-get update && apt-get install -y postgresql-client" || error_exit "$container 内で PostgreSQL クライアントの自動インストールに失敗しました"
    else
      error_exit "$container 内で利用可能なパッケージマネージャが見つかりません。"
    fi
  fi
}

###############################################################################
# コンテナ内の指定されたマウント先 (例: /directus/uploads) に対応するボリューム名を自動取得する関数
get_volume_by_destination() {
  local container="$1"
  local dest="$2"
  local vol
  vol=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "'"$dest"'"}}{{.Name}}{{end}}{{end}}' "$container")
  if [ -z "$vol" ]; then
    msg "コンテナ $container の $dest にマウントされているボリューム名を自動取得できませんでした。" "コンテナ $container の $dest にマウントされているボリューム名を自動取得できませんでした。docker inspect の出力を確認してください。"
  fi
  echo "$vol"
}

###############################################################################
# 環境識別子からコンテナ名を生成する関数
get_container_name() {
  echo "directus-$1-directus-1"
}

###############################################################################
# ユーザーから環境識別子を入力（エクスポート元＝開発環境、インポート先＝本番環境）
msg "エクスポート元（開発環境）の識別子 (例: 883409): " "エクスポート元（開発環境）の識別子 (例: 883409) を入力してください: "
read -p "" ENV_A
msg "インポート先（本番環境）の識別子 (例: f09f1b): " "インポート先（本番環境）の識別子 (例: f09f1b) を入力してください: "
read -p "" ENV_B

CONTAINER_A=$(get_container_name "$ENV_A")
CONTAINER_B=$(get_container_name "$ENV_B")

# 各コンテナ内の /directus/uploads にマウントされているボリューム名を自動取得
VOLUME_A=$(get_volume_by_destination "$CONTAINER_A" "/directus/uploads")
VOLUME_B=$(get_volume_by_destination "$CONTAINER_B" "/directus/uploads")

msg "エクスポート元コンテナ: $CONTAINER_A" "エクスポート元コンテナ: $CONTAINER_A"
msg "インポート先コンテナ: $CONTAINER_B" "インポート先コンテナ: $CONTAINER_B"
msg "エクスポート元アップロードボリューム: $VOLUME_A" "エクスポート元アップロードボリューム: $VOLUME_A"
msg "インポート先アップロードボリューム: $VOLUME_B" "インポート先アップロードボリューム: $VOLUME_B"

read -p "$(msg '移管後にインポート先コンテナを再デプロイしますか? (y/n): ' '移管後にインポート先コンテナを再デプロイしますか? (y/n): ')" REDEPLOY

echo ""
msg "移管処理を開始します..." "移管処理を開始します..."

# コンテナ存在確認
docker inspect "$CONTAINER_A" > /dev/null 2>&1 || error_exit "エクスポート元コンテナ $CONTAINER_A が存在しません。"
docker inspect "$CONTAINER_B" > /dev/null 2>&1 || error_exit "インポート先コンテナ $CONTAINER_B が存在しません。"

###############################################################################
# 【Step 1】エクスポート元コンテナ内の既存スナップショットを削除
docker exec -it "$CONTAINER_A" rm -f /tmp/schema.yaml || debug_log "既存のスナップショットが存在しなかったか、削除に失敗しました。"

# 【Step 2】エクスポート元からスナップショット取得
msg "【Step 2】エクスポート元コンテナ ($CONTAINER_A) からスナップショットを取得中..." "【Step 2】エクスポート元コンテナ ($CONTAINER_A) からスナップショットを取得中..."
docker exec -it "$CONTAINER_A" /bin/sh -c "npx directus schema snapshot /tmp/schema.yaml" || error_exit "スナップショットの取得に失敗しました"

# 【Step 3】エクスポート元からホストへスナップショットファイルをコピー
msg "【Step 3】エクスポート元コンテナからホストへスナップショットファイルをコピー中..." "【Step 3】エクスポート元コンテナからホストへスナップショットファイルをコピー中..."
docker cp "$CONTAINER_A":/tmp/schema.yaml ./schema.yaml || error_exit "スナップショットファイルのコピーに失敗しました"

# 【Step 4】ホスト上のスナップショットファイルをインポート先コンテナへ転送
msg "【Step 4】ホスト上のスナップショットファイルをインポート先コンテナ ($CONTAINER_B) へ転送中..." "【Step 4】ホスト上のスナップショットファイルをインポート先コンテナ ($CONTAINER_B) へ転送中..."
docker cp ./schema.yaml "$CONTAINER_B":/tmp/schema.yaml || error_exit "スナップショットファイルの転送に失敗しました"

# 【Step 5】インポート先コンテナ内でスナップショットを適用
msg "【Step 5】インポート先コンテナ ($CONTAINER_B) 内でスナップショットを適用中..." "【Step 5】インポート先コンテナ ($CONTAINER_B) 内でスナップショットを適用中..."
docker exec -it "$CONTAINER_B" /bin/sh -c "npx directus schema apply /tmp/schema.yaml" || error_exit "スナップショットの適用に失敗しました"

# 【Step 6】ストレージデータ（アップロードファイル）の移管
msg "【Step 6】ストレージデータを移管中..." "【Step 6】ストレージデータを移管中..."
msg "エクスポート元アップロードボリューム ($VOLUME_A) からインポート先アップロードボリューム ($VOLUME_B) にコピー中..." "【Step 6】エクスポート元アップロードボリューム ($VOLUME_A) からインポート先アップロードボリューム ($VOLUME_B) にコピー中..."
docker run --rm -v "$VOLUME_A":/data -v "$(pwd)":/backup alpine tar -czvf /backup/uploads.tar.gz -C /data . || error_exit "ストレージデータのアーカイブに失敗しました"
docker run --rm -v "$(pwd)":/backup -v "$VOLUME_B":/data alpine tar -xzvf /backup/uploads.tar.gz -C /data || error_exit "ストレージデータの展開に失敗しました"

###############################################################################
if [ "$MIGRATE_FOLDERS_ONLY" -eq 1 ]; then
  # 【Step 7】エクスポート元コンテナ内で PostgreSQL クライアントがない場合、自動インストールを試みる
  install_pg_client_if_missing "$CONTAINER_A"
  # 【Step 7】エクスポート元コンテナ内で directus_folders テーブルのデータをエクスポート
  msg "【Step 7】エクスポート元コンテナ ($CONTAINER_A) から directus_folders テーブルのデータをエクスポート中..." "【Step 7】エクスポート元コンテナ ($CONTAINER_A) から directus_folders テーブルのデータ（フォルダー構造）をエクスポート中..."
  docker exec -it "$CONTAINER_A" /bin/sh -c "PGPASSWORD=\$DB_PASSWORD pg_dump -h database -U directus -d directus -t directus_folders -a -Fp" > directus_folders.sql || error_exit "directus_folders テーブルのエクスポートに失敗しました"
  sed -i '/^pg_dump:/d' directus_folders.sql
  sed -i '/^SET transaction_timeout/d' directus_folders.sql
  debug_log "Exported directus_folders dump (first 10 lines):"
  if [ "$DEBUG_MODE" -eq 1 ]; then
    head -n 10 directus_folders.sql
  fi

  # 【Step 8】インポート先コンテナ内で PostgreSQL クライアントがない場合、自動インストールを試みる
  install_pg_client_if_missing "$CONTAINER_B"
  # 【Step 8】インポート先コンテナ内で directus_folders テーブルの既存データを削除し、エクスポートしたデータをインポート
  msg "【Step 8】インポート先コンテナ ($CONTAINER_B) 内の directus_folders テーブルのデータを削除し、エクスポートデータをインポート中..." "【Step 8】インポート先コンテナ ($CONTAINER_B) 内の directus_folders テーブルのデータを削除し、エクスポートデータをインポート中..."
  docker exec -it "$CONTAINER_B" /bin/sh -c "PGPASSWORD=\$DB_PASSWORD psql -h database -U directus -d directus -c 'DELETE FROM directus_folders;'" || error_exit "インポート先でのデータ削除に失敗しました"
  docker cp directus_folders.sql "$CONTAINER_B":/tmp/directus_folders.sql || error_exit "directus_folders.sql の転送に失敗しました"
  docker exec -it "$CONTAINER_B" /bin/sh -c "PGPASSWORD=\$DB_PASSWORD psql -h database -U directus -d directus -f /tmp/directus_folders.sql" || error_exit "directus_folders テーブルのインポートに失敗しました"
else
  msg "【Step 7】従来の directus_files テーブルの移管処理を実行中..." "【Step 7】エクスポート元から directus_files テーブルのデータをエクスポートし、インポート先に転送中..."
  install_pg_client_if_missing "$CONTAINER_A"
  docker exec -it "$CONTAINER_A" /bin/sh -c "PGPASSWORD=\$DB_PASSWORD pg_dump -h database -U directus -d directus -t directus_files -a -Fc -f /tmp/directus_files.dump" || error_exit "directus_files テーブルのエクスポートに失敗しました"
  docker cp "$CONTAINER_A":/tmp/directus_files.dump ./directus_files.dump || error_exit "directus_files.dump のコピーに失敗しました"
  install_pg_client_if_missing "$CONTAINER_B"
  docker cp ./directus_files.dump "$CONTAINER_B":/tmp/directus_files.dump || error_exit "directus_files.dump の転送に失敗しました"
  docker exec -it "$CONTAINER_B" /bin/sh -c "PGPASSWORD=\$DB_PASSWORD pg_restore -a --disable-triggers -h database -U directus -d directus /tmp/directus_files.dump" || error_exit "directus_files テーブルのインポートに失敗しました"
fi

###############################################################################
# 【Step 9】インポート先コンテナの再デプロイ（オプション）
if [[ "$REDEPLOY" =~ ^[Yy]$ ]]; then
  msg "【Step 9】インポート先コンテナ ($CONTAINER_B) を再デプロイ中..." "【Step 9】インポート先コンテナ ($CONTAINER_B) を再デプロイ中..."
  docker restart "$CONTAINER_B" || error_exit "インポート先コンテナの再起動に失敗しました"
  msg "インポート先コンテナの再デプロイが完了しました。" "インポート先コンテナの再デプロイが完了しました。"
else
  msg "再デプロイはスキップされました。" "再デプロイはスキップされました。"
fi

# バックアップファイルの保存場所を表示
msg "バックアップファイル (uploads のアーカイブ) は $(pwd)/uploads.tar.gz に保存されています。" "バックアップファイル (uploads のアーカイブ) は $(pwd)/uploads.tar.gz に保存されています。"

echo ""
msg "✨✨✨ 移管処理がすべて完了しました! ✨✨✨" "✨✨✨ 移管処理がすべて完了しました! ✨✨✨"
msg "----------------------------------------------------" "----------------------------------------------------"
