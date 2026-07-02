#!/usr/bin/env bash
#
# codecommit-branch-diff.sh
# =========================
# AWS CodeCommit の「指定したリポジトリ・指定したブランチ」のコミット変更の差分を、
# 極めて詳しく・わかりやすく表示する。
#
# 表示内容(1コミットあたり):
#   - コミットヘッダ  : ハッシュ(完全/短縮)、Author/Committer、日時(ISO/相対)、
#                       参照(ブランチ/タグ)、親コミット、Subject、Body
#   - 変更サマリ      : 変更ファイル数 / 追加行数 / 削除行数(shortstat)
#   - 変更ファイル一覧: 変更種別(A=追加/M=変更/D=削除/R=リネーム/C=コピー)付き
#                       + ファイル別の追加/削除行数(numstat)
#   - 詳細差分(patch) : rename/copy 検出(-M -C)、histogram アルゴリズム、
#                       関数名表示付きの unified diff(前後の文脈行数は変更可)
#
# 動作モード(いずれか1つ):
#   (1) 直近モード(既定)   : ブランチ先頭から直近 N コミットを新しい順に表示
#   (2) 単一コミットモード : --commit <sha> で指定した1コミットの差分を表示
#   (3) 範囲モード         : --from <ref> --to <ref> の区間の差分を表示
#                            (全体サマリ + 全体差分 + 区間内の各コミット詳細)
#
# 使い方:
#   ./codecommit-branch-diff.sh -r <リポジトリ名> -b <ブランチ名> [オプション]
#
# オプション:
#   -r, --repository <name>   対象の CodeCommit リポジトリ名(必須。--repo-url 指定時は任意)。
#   -b, --branch <name>       対象ブランチ名(必須)。
#   -c, --commit <sha>        単一コミットモード: 指定コミットの差分のみ表示。
#       --from <ref>          範囲モード: 比較の起点(古い側)のコミット/参照。
#       --to <ref>            範囲モード: 比較の終点(新しい側)。省略時はブランチ先頭。
#   -N, --max-count <n>       直近モードで表示するコミット数(既定: 10)。
#       --context <n>         差分の前後に表示する文脈行数(既定: 5)。
#       --word-diff           行単位ではなく単語単位の差分で表示する。
#       --stat-only           詳細差分(patch)を出さず、サマリと一覧のみ表示する。
#       --color <mode>        色付け: auto(既定) / always / never。
#                             ファイル出力時は auto では色なしになる。
#       --no-pager            ページャ(less)を使わず直接出力する。
#       --output-file <path>  表示内容をファイルへ保存する(画面にも出力)。
#       --repo-url <url>      clone URL。HTTPS もしくは grc 形式
#                             (codecommit::<region>://<repo>)を指定可。
#                             省略時は --repository と --region から HTTPS URL を生成。
#       --region <region>     使用する AWS リージョン(AWS_DEFAULT_REGION を上書き)。
#       --profile <name>      使用する AWS プロファイル(AWS_PROFILE を上書き)。
#       --full-clone          全履歴を clone する。既定は必要な深さのみの shallow clone。
#                             (--commit / --from 指定時は自動的に全履歴 clone になる)
#       --auto-assume-role    CodeCommit 権限が無い場合に終了せず、別チーム提供の
#                             シェルを source して自動でスイッチロールする。
#                             (既定: スイッチロールを促す警告を出して終了)
#       --assume-role-script <path>
#                             自動スイッチロール時に source するシェルのパス。
#                             (環境変数 ASSUME_ROLE_SCRIPT でも指定可)
#   -n, --dry-run             副作用のある操作(clone / 自動スイッチロールの source /
#                             ファイル保存)を実行せず、「実行予定」の内容のみ表示する。
#   -h, --help                このヘルプを表示する。
#
# 事前条件:
#   - 事前に `aws login --remote` で認証しておくこと(未認証なら警告して終了する)。
#   - git が利用可能で、CodeCommit への HTTPS 認証(git 資格情報ヘルパ)が使えること。
#     本スクリプトは clone 時に aws codecommit credential-helper を指定して認証する。
#
# 例:
#   # 直近10コミットの差分を詳細表示
#   ./codecommit-branch-diff.sh -r my-repo -b main --region ap-northeast-1
#
#   # 直近3コミットのみ・文脈行数10行で表示
#   ./codecommit-branch-diff.sh -r my-repo -b develop -N 3 --context 10
#
#   # 特定コミット1件の差分を表示
#   ./codecommit-branch-diff.sh -r my-repo -b main -c 1a2b3c4d
#
#   # リリースタグ間の差分(全体+コミット別)を表示してファイル保存
#   ./codecommit-branch-diff.sh -r my-repo -b main \
#       --from v1.0.0 --to v1.1.0 --output-file ./diff_v1.0.0_v1.1.0.txt
#
#   # 権限が無い場合は別チーム提供シェルで自動スイッチロール
#   ./codecommit-branch-diff.sh -r my-repo -b main \
#       --auto-assume-role --assume-role-script /opt/team/assume_role.sh
#
set -uo pipefail

# ---- 共通部品(common.sh)の読み込み -----------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ---- 前提コマンドの確認 ----------------------------------------------------
require_cmd aws "AWS CLI をインストールしてください"
require_cmd git "git をインストールしてください (RHEL9: sudo dnf install git)"

# ---- オプション解析 --------------------------------------------------------
REPOSITORY_NAME="${CODECOMMIT_REPOSITORY:-}"
BRANCH_NAME=""
COMMIT_SHA=""
FROM_REF=""
TO_REF=""
MAX_COUNT=10
CONTEXT_LINES=5
WORD_DIFF=false
STAT_ONLY=false
COLOR_MODE="auto"
USE_PAGER=true
OUTPUT_FILE=""
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
    -c|--commit)            COMMIT_SHA="${2:?-c/--commit にはコミットSHAを指定してください}"; shift 2 ;;
    --commit=*)             COMMIT_SHA="${1#*=}"; shift ;;
    --from)                 FROM_REF="${2:?--from には起点のコミット/参照を指定してください}"; shift 2 ;;
    --from=*)               FROM_REF="${1#*=}"; shift ;;
    --to)                   TO_REF="${2:?--to には終点のコミット/参照を指定してください}"; shift 2 ;;
    --to=*)                 TO_REF="${1#*=}"; shift ;;
    -N|--max-count)         MAX_COUNT="${2:?-N/--max-count には数値を指定してください}"; shift 2 ;;
    --max-count=*)          MAX_COUNT="${1#*=}"; shift ;;
    --context)              CONTEXT_LINES="${2:?--context には数値を指定してください}"; shift 2 ;;
    --context=*)            CONTEXT_LINES="${1#*=}"; shift ;;
    --word-diff)            WORD_DIFF=true; shift ;;
    --stat-only)            STAT_ONLY=true; shift ;;
    --color)                COLOR_MODE="${2:?--color には auto/always/never を指定してください}"; shift 2 ;;
    --color=*)              COLOR_MODE="${1#*=}"; shift ;;
    --no-pager)             USE_PAGER=false; shift ;;
    --output-file)          OUTPUT_FILE="${2:?--output-file にはパスを指定してください}"; shift 2 ;;
    --output-file=*)        OUTPUT_FILE="${1#*=}"; shift ;;
    --repo-url)             REPO_URL="${2:?--repo-url には clone URL を指定してください}"; shift 2 ;;
    --repo-url=*)           REPO_URL="${1#*=}"; shift ;;
    --region)               REGION="${2:?--region にはリージョンを指定してください}"; shift 2 ;;
    --region=*)             REGION="${1#*=}"; shift ;;
    --profile)              export AWS_PROFILE="${2:?--profile にはプロファイル名を指定してください}"; shift 2 ;;
    --profile=*)            export AWS_PROFILE="${1#*=}"; shift ;;
    --full-clone)           FULL_CLONE=true; shift ;;
    --auto-assume-role)     AUTO_ASSUME_ROLE=true; shift ;;
    --assume-role-script)   ASSUME_ROLE_SCRIPT_OPT="${2:?--assume-role-script にはパスを指定してください}"; shift 2 ;;
    --assume-role-script=*) ASSUME_ROLE_SCRIPT_OPT="${1#*=}"; shift ;;
    -n|--dry-run)           DRY_RUN=true; shift ;;
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

if [ -z "$REPO_URL" ] && [ -z "$REPOSITORY_NAME" ]; then
  die "リポジトリを特定できません。-r <リポジトリ名> もしくは --repo-url <URL> を指定してください。"
fi

case "$MAX_COUNT" in
  ''|*[!0-9]*) die "-N/--max-count には正の整数を指定してください: ${MAX_COUNT}" ;;
esac
[ "$MAX_COUNT" -ge 1 ] || die "-N/--max-count は 1 以上を指定してください: ${MAX_COUNT}"

case "$CONTEXT_LINES" in
  ''|*[!0-9]*) die "--context には 0 以上の整数を指定してください: ${CONTEXT_LINES}" ;;
esac

case "$COLOR_MODE" in
  auto|always|never) ;;
  *) die "--color には auto / always / never のいずれかを指定してください: ${COLOR_MODE}" ;;
esac

if [ -n "$COMMIT_SHA" ] && { [ -n "$FROM_REF" ] || [ -n "$TO_REF" ]; }; then
  die "-c/--commit と --from/--to は同時に指定できません。"
fi
if [ -n "$TO_REF" ] && [ -z "$FROM_REF" ]; then
  die "--to を指定する場合は --from も指定してください。"
fi

# ---- 動作モードの確定 ------------------------------------------------------
#   recent : 直近 N コミット / single : 単一コミット / range : --from..--to
MODE="recent"
[ -n "$COMMIT_SHA" ] && MODE="single"
[ -n "$FROM_REF" ]   && MODE="range"

# 単一コミット/範囲モードは対象が履歴の深い位置にある可能性があるため全履歴 clone にする。
if [ "$MODE" != "recent" ]; then
  FULL_CLONE=true
fi

# ---------------------------------------------------------------------------
# grc 形式(codecommit::<region>://<repo>)の URL を CodeCommit の HTTPS URL に変換する。
#   HTTPS でない(既に https:// 等)場合はそのまま返す。
# ---------------------------------------------------------------------------
codecommit_to_https_url() {
  local url="$1" region="$2"
  case "$url" in
    codecommit::*)
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

# ---- 色付けの有効/無効を確定 -----------------------------------------------
#   auto  : 出力先が端末 かつ ファイル出力なし の場合のみ色付け
#   always: 常に色付け(ANSI コードがファイルにも入る点に注意)
#   never : 常に色なし
GIT_COLOR_OPT="--color=never"
case "$COLOR_MODE" in
  always) GIT_COLOR_OPT="--color=always" ;;
  never)  GIT_COLOR_OPT="--color=never" ;;
  auto)
    if [ -t 1 ] && [ -z "$OUTPUT_FILE" ]; then
      GIT_COLOR_OPT="--color=always"   # ページャ(less -R)経由でも色を維持するため always
    fi
    ;;
esac

# ---- dry-run 対応の実行ヘルパ ----------------------------------------------
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
# ===========================================================================
if [ "$DRY_RUN" = "true" ]; then
  log_warn "dry-run モード: 副作用のある操作(clone / 自動スイッチロールの source / ファイル保存)は実行しません。"
  if _codecommit_access_ok "$PERM_REPO_NAME"; then
    log_info "CodeCommit への操作権限を確認しました (repo: $PERM_REPO_NAME)"
  else
    log_warn "現在の IAM ユーザ/ロールでは CodeCommit への操作が許可されていません (repo: $PERM_REPO_NAME)。"
    if [ "$AUTO_ASSUME_ROLE" = "true" ]; then
      _sr_path="${ASSUME_ROLE_SCRIPT_OPT:-${ASSUME_ROLE_SCRIPT:-}}"
      log_info "[DRY-RUN] スイッチロール用シェルを source する予定です: ${_sr_path:-<未指定(--assume-role-script / ASSUME_ROLE_SCRIPT)>}"
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
log_info "  リポジトリ        : ${PERM_REPO_NAME}"
log_info "  clone URL         : ${REPO_URL}"
log_info "  ブランチ          : ${BRANCH_NAME}"
case "$MODE" in
  recent) log_info "  モード            : 直近 ${MAX_COUNT} コミットの差分表示" ;;
  single) log_info "  モード            : 単一コミット差分表示 (commit: ${COMMIT_SHA})" ;;
  range)  log_info "  モード            : 範囲差分表示 (${FROM_REF} .. ${TO_REF:-<ブランチ先頭>})" ;;
esac
log_info "  文脈行数          : ${CONTEXT_LINES}"
log_info "  単語単位差分      : ${WORD_DIFF}"
log_info "  サマリのみ        : ${STAT_ONLY}"
log_info "  色付け            : ${COLOR_MODE}"
log_info "  出力ファイル      : ${OUTPUT_FILE:-(なし・画面のみ)}"
log_info "  clone 方式        : $([ "$FULL_CLONE" = "true" ] && echo '全履歴' || echo "shallow(--depth $((MAX_COUNT + 10)))")"
log_info "  自動スイッチロール: ${AUTO_ASSUME_ROLE}"
[ "$AUTO_ASSUME_ROLE" = "true" ] && \
  log_info "  切替用シェル      : ${ASSUME_ROLE_SCRIPT_OPT:-${ASSUME_ROLE_SCRIPT:-(未指定)}}"
log_info "  DRY-RUN           : ${DRY_RUN}"

# ===========================================================================
# ステップ3: ブランチを clone
#   HTTPS 認証は aws codecommit credential-helper を用いる。
#   直近モードでは「表示コミット数 + 余裕(マージの親コミット分)」だけの shallow clone
#   とし、取得時間と容量を最小化する。差分表示には各コミットの親が必要なため、
#   depth は MAX_COUNT + 10 とする(不足時は --full-clone で全履歴取得)。
# ===========================================================================
clone_branch() {
  local depth_args=()
  [ "$FULL_CLONE" = "true" ] || depth_args=(--depth "$((MAX_COUNT + 10))")

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] 実行予定: git clone ${depth_args[*]} --single-branch --branch ${BRANCH_NAME} ${REPO_URL} <一時ディレクトリ>"
    return 0
  fi

  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ccdiff.XXXXXX")" \
    || die "一時ディレクトリの作成に失敗しました。"

  log_info "ブランチ '${BRANCH_NAME}' を clone します..."
  if ! git \
        -c credential.helper='!aws codecommit credential-helper $@' \
        -c credential.UseHttpPath=true \
        clone --quiet "${depth_args[@]}" --single-branch --branch "${BRANCH_NAME}" \
        "${REPO_URL}" "${WORKDIR}"; then
    die "clone に失敗しました。リポジトリ名/ブランチ名/権限/リージョンを確認してください (branch: ${BRANCH_NAME})。"
  fi
  log_info "clone 完了。差分を解析します..."
}

# ---------------------------------------------------------------------------
# 作業リポジトリに対する git コマンドの共通ラッパ。
#   ページャ無効・rename/copy 検出などの共通設定を一元化する。
# ---------------------------------------------------------------------------
g() {
  git -C "${WORKDIR}" --no-pager \
      -c core.quotepath=false \
      -c diff.algorithm=histogram \
      "$@"
}

# ---------------------------------------------------------------------------
# 区切り線・見出しの描画ヘルパ(表示部品)。
# ---------------------------------------------------------------------------
hr()      { printf '%s\n' "==========================================================================="; }
hr_thin() { printf '%s\n' "---------------------------------------------------------------------------"; }

# ---------------------------------------------------------------------------
# 変更種別(name-status のステータス文字)の凡例を表示する。
# ---------------------------------------------------------------------------
print_status_legend() {
  printf '%s\n' "  [変更種別の凡例] A=追加  M=変更  D=削除  R###=リネーム(類似度%)  C###=コピー  T=種別変更"
}

# ---------------------------------------------------------------------------
# 1コミット分の詳細を表示する。
#   render_commit <sha> <index> <total>
# ---------------------------------------------------------------------------
render_commit() {
  local sha="$1" idx="$2" total="$3"

  hr
  printf '■ コミット %s / %s\n' "${idx}" "${total}"
  hr

  # --- コミットヘッダ(メタ情報) ------------------------------------------
  g show -s \
    --date=format:'%Y-%m-%d %H:%M:%S %z' \
    --format='コミット     : %H%nコミット(短) : %h%n親コミット   : %p%n参照         : %d%nAuthor       : %an <%ae>%nAuthorDate   : %ad (%ar)%nCommitter    : %cn <%ce>%nCommitDate   : %cd (%cr)%n%nSubject      : %s' \
    "${sha}"

  # --- Body(本文)がある場合のみ表示 ---------------------------------------
  local body
  body="$(g show -s --format='%b' "${sha}")"
  if [ -n "${body//[[:space:]]/}" ]; then
    printf 'Body         :\n'
    printf '%s\n' "${body}" | sed 's/^/    /'
  fi

  # --- 変更サマリ(全体の統計) ---------------------------------------------
  printf '\n'
  hr_thin
  printf '● 変更サマリ\n'
  hr_thin
  local shortstat
  shortstat="$(g show --format='' --shortstat -M -C "${sha}" | sed 's/^[[:space:]]*//')"
  printf '  %s\n' "${shortstat:-(ファイル変更なし ※マージコミット等)}"

  # --- 変更ファイル一覧(変更種別 + ファイル別の増減行数) -------------------
  printf '\n'
  hr_thin
  printf '● 変更ファイル一覧(種別 / +追加行 / -削除行 / パス)\n'
  hr_thin
  print_status_legend
  # name-status(種別+パス) と numstat(増減行数+パス) をパスで突合して1行に整形する。
  # - リネーム/コピー時は「旧パス -> 新パス」の新パス($NF)をキーにする。
  # - バイナリファイルは numstat の行数が "-" となるため "bin" と表示する。
  g show --format='' --numstat     -M -C "${sha}" > "${WORKDIR}/.render_numstat.tmp"
  g show --format='' --name-status -M -C "${sha}" > "${WORKDIR}/.render_status.tmp"
  awk -F'\t' '
    NR == FNR { add[$NF] = $1; del[$NF] = $2; next }      # 1st pass: numstat
    NF >= 2 {
      st = $1; path = $NF
      disp = (NF >= 3) ? $2 " -> " $3 : path              # リネーム/コピーは旧->新で表示
      a = (path in add) ? add[path] : "?"
      d = (path in del) ? del[path] : "?"
      if (a == "-") { a = "bin"; d = "bin" }
      printf "  %-6s +%-6s -%-6s %s\n", st, a, d, disp
    }
  ' "${WORKDIR}/.render_numstat.tmp" "${WORKDIR}/.render_status.tmp"
  rm -f "${WORKDIR}/.render_numstat.tmp" "${WORKDIR}/.render_status.tmp"

  # --- ファイル別の変更量グラフ(git 標準の stat 表示) ----------------------
  printf '\n'
  hr_thin
  printf '● ファイル別変更量(グラフ)\n'
  hr_thin
  g show --format='' --stat=100 -M -C ${GIT_COLOR_OPT} "${sha}"

  # --- 詳細差分(patch) ------------------------------------------------------
  if [ "${STAT_ONLY}" = "true" ]; then
    printf '\n  (--stat-only 指定のため詳細差分は省略)\n\n'
    return 0
  fi

  printf '\n'
  hr_thin
  printf '● 詳細差分(patch / 文脈 %s 行 / rename・copy 検出あり)\n' "${CONTEXT_LINES}"
  hr_thin
  local word_args=()
  if [ "${WORD_DIFF}" = "true" ]; then
    # 色が有効なら色付き単語差分、無効なら [-削除-]{+追加+} 記法のプレーン表示にする。
    case "${GIT_COLOR_OPT}" in
      --color=always) word_args=(--word-diff=color) ;;
      *)              word_args=(--word-diff=plain) ;;
    esac
  fi
  # マージコミットは親が複数あるため、combined diff(--cc)で衝突解決分のみ表示される。
  g show --format='' --patch -M -C \
      --unified="${CONTEXT_LINES}" \
      ${GIT_COLOR_OPT} "${word_args[@]+"${word_args[@]}"}" \
      "${sha}"
  printf '\n'
}

# ---------------------------------------------------------------------------
# レポート先頭のヘッダを表示する。
# ---------------------------------------------------------------------------
render_report_header() {
  hr
  printf '  CodeCommit コミット差分レポート\n'
  hr
  printf '  リポジトリ : %s\n' "${PERM_REPO_NAME}"
  printf '  ブランチ   : %s\n' "${BRANCH_NAME}"
  printf '  生成日時   : %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
  case "$MODE" in
    recent) printf '  対象       : 直近 %s コミット\n' "${MAX_COUNT}" ;;
    single) printf '  対象       : コミット %s\n' "${COMMIT_SHA}" ;;
    range)  printf '  対象       : %s .. %s\n' "${FROM_REF}" "${TO_REF:-${BRANCH_NAME}(先頭)}" ;;
  esac
  printf '\n'
}

# ---------------------------------------------------------------------------
# 直近モード: ブランチ先頭から MAX_COUNT 件を新しい順に表示する。
# ---------------------------------------------------------------------------
render_recent() {
  local -a shas=()
  mapfile -t shas < <(g rev-list --max-count="${MAX_COUNT}" "origin/${BRANCH_NAME}") \
    || die "コミット一覧の取得に失敗しました (branch: ${BRANCH_NAME})。"
  [ "${#shas[@]}" -ge 1 ] || die "ブランチ '${BRANCH_NAME}' にコミットが見つかりませんでした。"

  render_report_header

  # --- コミット一覧(目次) --------------------------------------------------
  printf '● コミット一覧(新しい順)\n'
  hr_thin
  g log --max-count="${MAX_COUNT}" \
      --date=format:'%Y-%m-%d %H:%M' \
      --format='  %h  %ad  %an  %s' \
      "origin/${BRANCH_NAME}"
  printf '\n\n'

  local total="${#shas[@]}" i=0 sha
  for sha in "${shas[@]}"; do
    i=$((i + 1))
    render_commit "${sha}" "${i}" "${total}"
  done
}

# ---------------------------------------------------------------------
# 単一コミットモード: --commit で指定した 1 コミットの差分を表示する。
# ---------------------------------------------------------------------------
render_single() {
  local full_sha
  full_sha="$(g rev-parse --verify --quiet "${COMMIT_SHA}^{commit}")" \
    || die "指定したコミットが見つかりません: ${COMMIT_SHA}（--full-clone で全履歴を取得すると解決する場合があります）"

  render_report_header
  render_commit "${full_sha}" 1 1
}

# ---------------------------------------------------------------------------
# 範囲モード: --from <ref> .. --to <ref>（省略時はブランチ先頭）の差分を表示する。
#   全体サマリ + 全体差分 + 区間内の各コミット詳細（古い順）を出力する。
# ---------------------------------------------------------------------------
render_range() {
  local to_ref="${TO_REF:-origin/${BRANCH_NAME}}"
  local to_disp="${TO_REF:-origin/${BRANCH_NAME}(先頭)}"

  g rev-parse --verify --quiet "${FROM_REF}^{commit}" >/dev/null \
    || die "--from の参照が見つかりません: ${FROM_REF}"
  g rev-parse --verify --quiet "${to_ref}^{commit}" >/dev/null \
    || die "--to の参照が見つかりません: ${to_ref}"

  local -a shas=()
  mapfile -t shas < <(g rev-list --reverse "${FROM_REF}..${to_ref}") \
    || die "範囲内のコミット一覧の取得に失敗しました (${FROM_REF}..${to_ref})。"

  render_report_header

  # --- 区間内コミット一覧(目次 / 古い順) -----------------------------------
  printf '● コミット一覧(%s .. %s / 古い順)\n' "${FROM_REF}" "${to_disp}"
  hr_thin
  if [ "${#shas[@]}" -ge 1 ]; then
    g log --reverse \
        --date=format:'%Y-%m-%d %H:%M' \
        --format='  %h  %ad  %an  %s' \
        "${FROM_REF}..${to_ref}"
  else
    printf '  (この範囲に差分コミットはありません)\n'
  fi
  printf '\n\n'

  # --- 全体差分サマリ ------------------------------------------------------
  hr
  printf '■ 全体差分(%s .. %s)\n' "${FROM_REF}" "${to_disp}"
  hr
  printf '\n'
  hr_thin
  printf '● 変更サマリ\n'
  hr_thin
  local shortstat
  shortstat="$(g diff --shortstat -M -C "${FROM_REF}" "${to_ref}" | sed 's/^[[:space:]]*//')"
  printf '  %s\n' "${shortstat:-(差分なし)}"

  printf '\n'
  hr_thin
  printf '● ファイル別変更量(グラフ)\n'
  hr_thin
  g diff --stat=100 -M -C ${GIT_COLOR_OPT} "${FROM_REF}" "${to_ref}"

  # --- 全体詳細差分(patch) -------------------------------------------------
  if [ "${STAT_ONLY}" != "true" ]; then
    printf '\n'
    hr_thin
    printf '● 全体詳細差分(patch / 文脈 %s 行 / rename・copy 検出あり)\n' "${CONTEXT_LINES}"
    hr_thin
    local word_args=()
    if [ "${WORD_DIFF}" = "true" ]; then
      case "${GIT_COLOR_OPT}" in
        --color=always) word_args=(--word-diff=color) ;;
        *)              word_args=(--word-diff=plain) ;;
      esac
    fi
    g diff --patch -M -C \
        --unified="${CONTEXT_LINES}" \
        ${GIT_COLOR_OPT} "${word_args[@]+"${word_args[@]}"}" \
        "${FROM_REF}" "${to_ref}"
  fi
  printf '\n\n'

  # --- 区間内の各コミット詳細(古い順) --------------------------------------
  if [ "${#shas[@]}" -ge 1 ]; then
    hr
    printf '■ 区間内コミットの個別詳細(古い順)\n'
    hr
    printf '\n'
    local total="${#shas[@]}" i=0 sha
    for sha in "${shas[@]}"; do
      i=$((i + 1))
      render_commit "${sha}" "${i}" "${total}"
    done
  fi
}

# ---------------------------------------------------------------------------
# 動作モードに応じてレポート本体を標準出力へ生成する。
# ---------------------------------------------------------------------------
render_report() {
  case "$MODE" in
    recent) render_recent ;;
    single) render_single ;;
    range)  render_range ;;
    *)      die "内部エラー: 不明なモード: ${MODE}" ;;
  esac
}

# ---------------------------------------------------------------------------
# ページャ(less -R)を使える状況かどうかを判定する。
#   - --no-pager 指定なし かつ 標準出力が端末 かつ less が存在する場合のみ true。
# ---------------------------------------------------------------------------
_can_use_pager() {
  [ "$USE_PAGER" = "true" ] && [ -t 1 ] && command -v less >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# レポートを画面(必要ならページャ)と、指定があればファイルへ出力する。
#   - --output-file 指定時は tee で画面とファイルの両方へ出力する。
#   - 色付き(--color=always 等)の内容を less で表示するため less -R を用いる。
# ---------------------------------------------------------------------------
emit_report() {
  if [ -n "$OUTPUT_FILE" ]; then
    if _can_use_pager; then
      render_report | tee "$OUTPUT_FILE" | less -R
    else
      render_report | tee "$OUTPUT_FILE"
    fi
    log_info "レポートをファイルに保存しました: ${OUTPUT_FILE}"
  else
    if _can_use_pager; then
      render_report | less -R
    else
      render_report
    fi
  fi
}

# ===========================================================================
# ステップ4: clone してレポートを生成・表示する
# ===========================================================================
clone_branch

if [ "$DRY_RUN" = "true" ]; then
  log_info "dry-run モードのため、clone・差分の解析/表示は行いません。"
  exit 0
fi

emit_report

log_info "完了しました。"
