#!/usr/bin/env bash
#
# cczip.sh
# ========
# codecommit_branch_zip.sh の入力を簡略化するヘルパーシェル。
# リポジトリ名・リージョン・保存先・スイッチロール設定などの毎回同じ指定を
# 設定ファイル(cc-helper.conf)へ寄せることで、通常は
#
#   ./cczip.sh <ブランチ名>
#
# だけでブランチの ZIP を取得できるようにする。
#
# 使い方:
#   ./cczip.sh <ブランチ名> [<保存先ディレクトリ>] [追加オプション...]
#   ./cczip.sh [追加オプション...]      # 設定 CC_BRANCH_DIR があれば対話選択
#
# 引数:
#   <ブランチ名>              対象ブランチ(第1引数)。省略時は設定 CC_BRANCH_DIR
#                             配下からの対話選択、もしくは追加オプションの
#                             -b/-B 指定が必要。
#   <保存先ディレクトリ>      ZIP の保存先(第2引数・省略可)。
#                             省略時は設定 CC_ZIP_OUTPUT_DIR を使用する。
#
# オプション(ヘルパー自身が解釈するもの):
#   -r, --repository <name>  リポジトリ名(設定 CC_REPOSITORY を上書き)。
#   -o, --output-dir <dir>   保存先ディレクトリ(第2引数と同じ・後指定優先)。
#       --print-cmd          元スクリプトを実行せず、組み立てたコマンドラインを
#                            表示して終了する(設定確認・デバッグ用)。
#   -h, --help               このヘルプを表示する。
#
# 上記以外の引数はすべて、そのままの順序で codecommit_branch_zip.sh へ
# 引き渡される(--zip-name / --full-clone / -n など全オプション使用可)。
# 同じオプションを設定ファイルと両方で指定した場合はコマンドライン側が優先される。
#
# 例:
#   ./cczip.sh main                          # CC_ZIP_OUTPUT_DIR へ保存
#   ./cczip.sh develop ./out                 # 保存先を指定
#   ./cczip.sh main --zip-name release.zip   # ZIP ファイル名を指定
#   ./cczip.sh                               # CC_BRANCH_DIR からブランチを対話選択
#   ./cczip.sh main --print-cmd              # 実行内容(コマンドライン)の確認のみ
#
set -uo pipefail

HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cc-helper-lib.sh
source "${HELPER_DIR}/cc-helper-lib.sh"

MAIN_SCRIPT_NAME="codecommit_branch_zip.sh"

usage() {
  awk 'NR>1{ if(/^#/){sub(/^# ?/,"");print}else{exit} }' "${BASH_SOURCE[0]}"
}

# ---- 設定ファイルの読み込み --------------------------------------------------
hl_load_config "${HELPER_DIR}"

# ---- 引数解析 ----------------------------------------------------------------
# 先頭の「-」始まりでない引数を最大2つ、ブランチ名・保存先として受け取る。
# それ以外の引数は -r/-o/--print-cmd/-h を除き、すべて元スクリプトへ素通しする。
BRANCH=""
OUTPUT_DIR=""
PRINT_CMD=false
PASS_ARGS=()

if [[ "$#" -ge 1 && "$1" != -* ]]; then
  BRANCH="$1"
  shift
  if [[ "$#" -ge 1 && "$1" != -* ]]; then
    OUTPUT_DIR="$1"
    shift
  fi
fi

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -h|--help)       usage; exit 0 ;;
    -r|--repository) CC_REPOSITORY="${2:?-r/--repository にはリポジトリ名を指定してください}"; shift 2 ;;
    --repository=*)  CC_REPOSITORY="${1#*=}"; shift ;;
    -o|--output-dir) OUTPUT_DIR="${2:?-o/--output-dir には保存先ディレクトリを指定してください}"; shift 2 ;;
    --output-dir=*)  OUTPUT_DIR="${1#*=}"; shift ;;
    --print-cmd)     PRINT_CMD=true; shift ;;
    --)              shift; PASS_ARGS+=("$@"); break ;;
    *)               PASS_ARGS+=("$1"); shift ;;
  esac
done

# 保存先の既定値(引数指定が無ければ設定ファイルの値)。
[[ -z "${OUTPUT_DIR}" ]] && OUTPUT_DIR="${CC_ZIP_OUTPUT_DIR:-}"

# ---- 必須項目のチェック --------------------------------------------------------
# 素通し引数に -h/--help が含まれる場合は元スクリプトのヘルプ表示が目的なので
# 必須チェックはスキップする。
if ! hl_args_have "-h|--help" ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}; then

  # リポジトリ: 設定 CC_REPOSITORY / -r / 素通しの --repo-url のいずれかが必要。
  if [[ -z "${CC_REPOSITORY:-}" ]] \
      && ! hl_args_have "-r|--repository|--repo-url" ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}; then
    hl_usage_die "リポジトリ名が未指定です。設定ファイル(${CC_HELPER_CONF_LOADED:-${HELPER_DIR}/cc-helper.conf})の CC_REPOSITORY、もしくは -r <リポジトリ名> で指定してください。"
  fi

  # ブランチ: 第1引数 / 素通しの -b・-B / 設定 CC_BRANCH_DIR のいずれかが必要。
  if [[ -z "${BRANCH}" && -z "${CC_BRANCH_DIR:-}" ]] \
      && ! hl_args_have "-b|--branch|-B|--branch-dir" ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}; then
    hl_usage_die "ブランチが未指定です。第1引数に <ブランチ名> を指定するか、設定ファイルの CC_BRANCH_DIR を設定してください。"
  fi

  # 保存先: 第2引数 / -o / 設定 CC_ZIP_OUTPUT_DIR のいずれかが必要。
  if [[ -z "${OUTPUT_DIR}" ]] \
      && ! hl_args_have "-o|--output-dir" ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}; then
    hl_usage_die "ZIP の保存先が未指定です。第2引数に <保存先ディレクトリ> を指定するか、設定ファイルの CC_ZIP_OUTPUT_DIR を設定してください。"
  fi
fi

# ---- 元スクリプトの特定 --------------------------------------------------------
MAIN_SCRIPT="$(hl_resolve_main_script "${HELPER_DIR}" "${MAIN_SCRIPT_NAME}")" || exit 1

# ---- スイッチロール関連引数の構築(絶対パス化込み) ------------------------------
# ヘルパーを別ディレクトリへ配置しても、元スクリプト内の source が
# 正常に動作するよう、パスは CC_ROLE_ARGS の構築時に絶対化される。
hl_build_assume_role_args "${HELPER_DIR}"

# ---- コマンドラインの組み立て ---------------------------------------------------
# 設定由来の値を先、コマンドライン指定(素通し引数)を後に置くことで、
# 同一オプションはコマンドライン側が優先される(元スクリプトは後勝ち)。
CMD=(bash "${MAIN_SCRIPT}")
[[ -n "${CC_REPOSITORY:-}" ]] && CMD+=(-r "${CC_REPOSITORY}")
[[ -n "${CC_REGION:-}"     ]] && CMD+=(--region "${CC_REGION}")
[[ -n "${OUTPUT_DIR}"      ]] && CMD+=(-o "${OUTPUT_DIR}")

if [[ -n "${BRANCH}" ]]; then
  CMD+=(-b "${BRANCH}")
elif [[ -n "${CC_BRANCH_DIR:-}" ]] \
    && ! hl_args_have "-b|--branch|-B|--branch-dir" ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}; then
  BRANCH_DIR_ABS="$(hl_resolve_existing "${HELPER_DIR}" "${CC_BRANCH_DIR}")" \
    || { hl_error "CC_BRANCH_DIR のディレクトリが見つかりません: ${CC_BRANCH_DIR}"; exit 1; }
  CMD+=(-B "${BRANCH_DIR_ABS}")
fi

CMD+=(${CC_ROLE_ARGS[@]+"${CC_ROLE_ARGS[@]}"})
CMD+=(${CC_ZIP_EXTRA_ARGS[@]+"${CC_ZIP_EXTRA_ARGS[@]}"})
CMD+=(${PASS_ARGS[@]+"${PASS_ARGS[@]}"})

# ---- 実行 ----------------------------------------------------------------------
if [[ "${PRINT_CMD}" == "true" ]]; then
  hl_info "--print-cmd 指定のため実行はしません。組み立てたコマンドライン:"
  printf '%q ' "${CMD[@]}"
  printf '\n'
  exit 0
fi

hl_info "実行します: ${CMD[*]}"
exec "${CMD[@]}"
