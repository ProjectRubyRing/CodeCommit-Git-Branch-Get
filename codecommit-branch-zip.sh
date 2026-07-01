#!/usr/bin/env bash
#
# codecommit-branch-zip.sh
# ========================
# AWS CodeCommit の「指定したリポジトリ・指定したブランチ」の内容を取得し、
# そのブランチに登録されている全ファイルを ZIP に固めて、指定ディレクトリへ保存する。
#
# 取得方式:
#   git clone(shallow / 単一ブランチ) でブランチを取得し、git archive で ZIP 化する。
#   git archive はブランチのツリー(登録済みファイル)のみを ZIP にするため、
#   .git ディレクトリなどの作業用ファイルは含まれない。
#
# 使い方:
#   ./codecommit-branch-zip.sh -r <リポジトリ名> -b <ブランチ名> -o <保存先ディレクトリ> [オプション]
#
# オプション:
#   -r, --repository <name>   対象の CodeCommit リポジトリ名(必須。--repo-url 指定時は任意)。
#   -b, --branch <name>       ZIP 化するブランチ名(必須)。
#   -o, --output-dir <dir>    ZIP の保存先ディレクトリ(必須。無ければ作成する)。
#       --zip-name <name>     出力する ZIP ファイル名。
#                             (既定: <repo>_<branch>_<YYYYmmdd-HHMMSS>.zip)
#       --repo-url <url>      clone URL。HTTPS もしくは grc 形式
#                             (codecommit::<region>://<repo>)を指定可。
#                             省略時は --repository と --region から HTTPS URL を生成。
#       --region <region>     使用する AWS リージョン(AWS_DEFAULT_REGION を上書き)。
#                             --repo-url 未指定時の URL 生成、および認証で使用。
#       --profile <name>      使用する AWS プロファイル(AWS_PROFILE を上書き)。
#       --full-clone          全履歴を clone する(既定: --depth 1 の shallow clone)。
#       --auto-assume-role    CodeCommit 権限が無い場合に終了せず、別チーム提供の
#                             シェルを source して自動でスイッチロールする。
#                             (既定: 警告して終了)
#       --assume-role-script <path>
#                             自動スイッチロール時に source するシェルのパス。
#                             (環境変数 ASSUME_ROLE_SCRIPT でも指定可)
#   -n, --dry-run             副作用のある操作(clone / ZIP 生成 / ディレクトリ作成 /
#                             自動スイッチロールの source)を実行せず、
#                             「実行予定」の内容のみ表示する。
#   -h, --help                このヘルプを表示する。
#
# 事前条件:
#   - 事前に `aws login --remote` で認証しておくこと(未認証なら警告して終了する)。
#   - git が利用可能で、CodeCommit への HTTPS 認証(git 資格情報ヘルパ)が使えること。
#     本スクリプトは clone 時に aws codecommit credential-helper を指定して認証する。
#
# 例:
#   ./codecommit-branch-zip.sh -r my-repo -b main -o ./out --region ap-northeast-1
#   ./codecommit-branch-zip.sh -r my-repo -b develop -o /tmp/zips --zip-name develop.zip
#   ./codecommit-branch-zip.sh -r my-repo -b main -o ./out \
#       --auto-assume-role --assume-role-script /opt/team/assume_role.sh
#   ./codecommit-branch-zip.sh -r my-repo -b main -o ./out --dry-run
#
set -uo pipefail

# ---- 共通部品(common.sh)の読み込み -----------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ---- 前提コマンドの確認 ----------------------------------------------------
require_cmd aws "AWS CLI をインストールしてください"
require_cmd git "git をインストールしてください"

# ---- オプション解析 --------------------------------------------------------
REPOSITORY_NAME="${CODECOMMIT_REPOSITORY:-}"
BRANCH_NAME=""
OUTPUT_DIR=""
ZIP_NAME=""
REPO_URL=""
REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-}}"
FULL_CLONE=false
AUTO_ASSUME_ROLE=false
ASSUME_ROLE_SCRIPT_OPT=""
DRY_RUN=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    -r|--repository)        REPOSITORY_NAME="${2:?-r/--repository にはリポジトリ名を指定してください}"; shift 2 ;;
    --repository=*)         REPOSITORY_NAME="${1#*=}"; shift ;;
    -b|--branch)            BRANCH_NAME="${2:?-b/--branch にはブランチ名を指定してください}"; shift 2 ;;
    --branch=*)             BRANCH_NAME="${1#*=}"; shift ;;
    -o|--output-dir)        OUTPUT_DIR="${2:?-o/--output-dir には保存先ディレクトリを指定してください}"; shift 2 ;;
    --output-dir=*)         OUTPUT_DIR="${1#*=}"; shift ;;
    --zip-name)             ZIP_NAME="${2:?--zip-name にはファイル名を指定してください}"; shift 2 ;;
    --zip-name=*)           ZIP_NAME="${1#*=}"; shift ;;
    --repo-url)             REPO_URL="${2:?--repo-url には clone URL を指定してください}"; shift 2 ;;
    --repo-url=*)           REPO_URL="${1#*=}"; shift ;;
    --region)               REGION="${2:?--region にはリージョンを指定してください}"; shift 2 ;;
    --region=*)             REGION="${1#*=}"; shift ;;
    --profile)              export AWS_PROFILE="${2:?--profile にはプロファイル名を指定してください}"; shift 2 ;;
    --profile=*)            export AWS_PROFILE="${1#*=}"; shift ;;
    --full-clone)           FULL_CLONE=true; shift ;;
    -n|--dry-run)           DRY_RUN=true; shift ;;
    --auto-assume-role)     AUTO_ASSUME_ROLE=true; shift ;;
    --assume-role-script)   ASSUME_ROLE_SCRIPT_OPT="${2:?--assume-role-script にはパスを指定してください}"; shift 2 ;;
    --assume-role-script=*) ASSUME_ROLE_SCRIPT_OPT="${1#*=}"; shift ;;
    -h|--help)              awk 'NR>1{ if(/^#/){sub(/^# ?/,"");print}else{exit} }' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)                     die "不明なオプション: $1" ;;
    *)                      die "余分な引数です: $1" ;;
  esac
done

# ---- リージョンを環境へ反映 ------------------------------------------------
if [ -n "$REGION" ]; then
  export AWS_DEFAULT_REGION="$REGION"
  export AWS_REGION="$REGION"
fi

# ---- 入力の検証 ------------------------------------------------------------
[ -n "$BRANCH_NAME" ] || die "ブランチ名が指定されていません。-b <ブランチ名> で指定してください。"
[ -n "$OUTPUT_DIR" ]  || die "保存先ディレクトリが指定されていません。-o <ディレクトリ> で指定してください。"

if [ -z "$REPO_URL" ] && [ -z "$REPOSITORY_NAME" ]; then
  die "リポジトリを特定できません。-r <リポジトリ名> もしくは --repo-url <URL> を指定してください。"
fi

# ---------------------------------------------------------------------------
# grc 形式(codecommit::<region>://<repo>)の URL を CodeCommit の HTTPS URL に変換する。
#   HTTPS でない(既に https:// 等)場合はそのまま返す。
# ---------------------------------------------------------------------------
codecommit_to_https_url() {
  local url="$1" region="$2"
  case "$url" in
    codecommit::*)
      # codecommit::<region>://<repo>[@profile] 形式を分解する
      local rest region_in repo
      rest="${url#codecommit::}"        # <region>://<repo>
      region_in="${rest%%://*}"         # <region>
      repo="${rest#*://}"               # <repo>[@profile]
      repo="${repo%%@*}"                # プロファイル指定を除去
      [ -n "$region_in" ] && region="$region_in"
      [ -n "$region" ] || return 1
      printf 'https://git-codecommit.%s.amazonaws.com/v1/repos/%s\n' "$region" "$repo"
      ;;
    *)
      printf '%s\n' "$url"
      ;;
  esac
}

# ---- clone URL の確定 ------------------------------------------------------
if [ -z "$REPO_URL" ]; then
  [ -n "$REGION" ] || die "HTTPS URL の生成にリージョンが必要です。--region を指定するか --repo-url で URL を直接指定してください。"
  REPO_URL="https://git-codecommit.${REGION}.amazonaws.com/v1/repos/${REPOSITORY_NAME}"
else
  if ! REPO_URL="$(codecommit_to_https_url "$REPO_URL" "$REGION")"; then
    die "grc 形式 URL の HTTPS 変換にリージョンが必要です。--region を指定してください。"
  fi
fi

# ---- 権限確認に用いるリポジトリ名(URL からも導出) --------------------------
PERM_REPO_NAME="$REPOSITORY_NAME"
if [ -z "$PERM_REPO_NAME" ]; then
  PERM_REPO_NAME="${REPO_URL##*/}"   # HTTPS URL 末尾のリポジトリ名
fi

# ---- 出力 ZIP パスの確定 ---------------------------------------------------
if [ -z "$ZIP_NAME" ]; then
  # ブランチ名の '/' などファイル名に使えない文字を '_' へ置換する
  _safe_branch="$(printf '%s' "$BRANCH_NAME" | tr '/ :\\' '____')"
  ZIP_NAME="${PERM_REPO_NAME}_${_safe_branch}_$(date +%Y%m%d-%H%M%S).zip"
fi
case "$ZIP_NAME" in
  *.zip) ;;
  *) ZIP_NAME="${ZIP_NAME}.zip" ;;
esac
ZIP_PATH="${OUTPUT_DIR%/}/${ZIP_NAME}"

# ---- dry-run 対応の実行ヘルパ ----------------------------------------------
# 副作用のあるコマンドはこの run() を通す。dry-run 時は実行せず内容のみ表示する。
run() {
  if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] 実行予定: $*"
    return 0
  fi
  "$@"
}

# ---- 一時作業ディレクトリ(clone 先)と後始末 --------------------------------
WORKDIR=""
cleanup() {
  if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

# ===========================================================================
# ステップ1: 事前認証(aws login --remote)の確認
#   未認証なら common.sh 側で警告して終了する。
# ===========================================================================
require_aws_auth

# ===========================================================================
# ステップ2: CodeCommit への操作権限の確認
#   権限が無い場合、既定では「スイッチロールを促して終了」。
#   --auto-assume-role 指定時は別チーム提供シェルを source して自動スイッチロール。
#   (source する専用シェルのパスは --assume-role-script / 環境変数 ASSUME_ROLE_SCRIPT で指定)
#
#   dry-run 時は「副作用のある操作」= 自動スイッチロールの source を実行しない。
#   権限の有無は読み取り(get-repository)で判定し、source は「実行予定」を表示するのみ。
# ===========================================================================
if [ "$DRY_RUN" = "true" ]; then
  log_warn "dry-run モード: 副作用のある操作(clone / ZIP 生成 / 自動スイッチロールの source)は実行しません。"
  if _codecommit_access_ok "$PERM_REPO_NAME"; then
    log_info "CodeCommit への操作権限を確認しました (repo: $PERM_REPO_NAME)"
  else
    log_warn "現在の IAM ユーザ/ロールでは CodeCommit への操作が許可されていません (repo: $PERM_REPO_NAME)。"
    if [ "$AUTO_ASSUME_ROLE" = "true" ]; then
      _sr_path="${ASSUME_ROLE_SCRIPT_OPT:-${ASSUME_ROLE_SCRIPT:-}}"
      log_info "[DRY-RUN] スイッチロール用シェルを source する予定です: ${_sr_path:-<未指定(--assume-role-script / ASSUME_ROLE_SCRIPT)>}"
      log_info "[DRY-RUN] dry-run のため source は実行しません(実行するには -n/--dry-run を外してください)。"
    else
      log_info "[DRY-RUN] スイッチロールを促して終了する予定です(--auto-assume-role 指定で自動スイッチロール可能)。"
    fi
    log_warn "dry-run のため、権限取得は行わず以降の処理はスキップして終了します。"
  fi
else
  require_codecommit_access "$PERM_REPO_NAME" "$AUTO_ASSUME_ROLE" "$ASSUME_ROLE_SCRIPT_OPT"
fi

# ===========================================================================
# 実行内容の表示
# ===========================================================================
log_info "=== 実行内容 ==="
log_info "  リポジトリ      : ${PERM_REPO_NAME}"
log_info "  clone URL       : ${REPO_URL}"
log_info "  ブランチ        : ${BRANCH_NAME}"
log_info "  clone 方式      : $([ "$FULL_CLONE" = "true" ] && echo '全履歴' || echo 'shallow(--depth 1)')"
log_info "  保存先ディレクトリ: ${OUTPUT_DIR}"
log_info "  出力 ZIP        : ${ZIP_PATH}"
log_info "  自動スイッチロール: ${AUTO_ASSUME_ROLE}"
[ "$AUTO_ASSUME_ROLE" = "true" ] && \
  log_info "  切替用シェル    : ${ASSUME_ROLE_SCRIPT_OPT:-${ASSUME_ROLE_SCRIPT:-(未指定)}}"
log_info "  DRY-RUN         : ${DRY_RUN}"

# ===========================================================================
# ステップ3: ブランチを clone
#   HTTPS 認証は aws codecommit credential-helper を用いる。
#   --single-branch --branch <branch> で対象ブランチのみを取得する。
# ===========================================================================
clone_branch() {
  local depth_args=()
  [ "$FULL_CLONE" = "true" ] || depth_args=(--depth 1)

  if [ "$DRY_RUN" = "true" ]; then
    # dry-run では一時ディレクトリも作らず、実行予定の clone コマンドのみ表示する。
    log_info "[DRY-RUN] 実行予定: git clone ${depth_args[*]} --single-branch --branch ${BRANCH_NAME} ${REPO_URL} <一時ディレクトリ>"
    return 0
  fi

  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ccbranch.XXXXXX")" \
    || die "一時ディレクトリの作成に失敗しました。"

  log_info "ブランチ '${BRANCH_NAME}' を clone します..."
  if ! git \
        -c credential.helper='!aws codecommit credential-helper $@' \
        -c credential.UseHttpPath=true \
        clone "${depth_args[@]}" --single-branch --branch "${BRANCH_NAME}" \
        "${REPO_URL}" "${WORKDIR}"; then
    die "clone に失敗しました。リポジトリ名/ブランチ名/権限/リージョンを確認してください (branch: ${BRANCH_NAME})。"
  fi
}

# ===========================================================================
# ステップ4: ブランチ内容を ZIP 化して保存先へ出力
#   git archive はチェックアウト中のブランチ(登録済みファイル)を ZIP 化する。
# ===========================================================================
create_zip() {
  run mkdir -p "${OUTPUT_DIR}"

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] 実行予定: git -C <一時ディレクトリ> archive --format=zip -o ${ZIP_PATH} ${BRANCH_NAME}"
    log_info "[DRY-RUN] 完了: 上記の clone / ZIP 生成が実行されます。"
    return 0
  fi

  log_info "ブランチ内容を ZIP 化します -> ${ZIP_PATH}"
  if ! git -C "${WORKDIR}" archive --format=zip \
        --output "${ZIP_PATH}" "${BRANCH_NAME}"; then
    die "ZIP の生成に失敗しました: ${ZIP_PATH}"
  fi

  [ -f "${ZIP_PATH}" ] || die "ZIP ファイルが生成されませんでした: ${ZIP_PATH}"

  local size count=""
  size="$(du -h "${ZIP_PATH}" 2>/dev/null | cut -f1)"
  if command -v unzip >/dev/null 2>&1; then
    count="$(unzip -l "${ZIP_PATH}" 2>/dev/null | tail -1 | awk '{print $2}')"
  fi
  log_info "ZIP 生成 OK: ${ZIP_PATH} (サイズ: ${size:-?}${count:+, ファイル数: ${count}})"
}

# ===========================================================================
# メイン
# ===========================================================================
main() {
  clone_branch
  create_zip

  if [ "$DRY_RUN" = "true" ]; then
    log_info "DRY-RUN 完了。実際に保存するには -n/--dry-run を外して再実行してください。"
  else
    log_info "完了: ブランチ '${BRANCH_NAME}' の内容を ${ZIP_PATH} に保存しました。"
  fi
}

main
