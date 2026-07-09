#!/usr/bin/env bash
#
# cc-helper-lib.sh
# ================
# helpers/ 配下のヘルパーシェル(ccdiff.sh / cczip.sh)から source して使う共通部品。
# ヘルパーシェル以外から直接実行・利用する想定はありません。
#
# 提供する公開インターフェース:
#   hl_error / hl_info <msg...>  : ヘルパー用の簡易ログ(stderr)
#   hl_usage_die <msg...>        : エラー表示 + usage 表示(呼び出し側で定義した
#                                  usage 関数を使用)をして exit 1
#   hl_abs_path <path>           : 存在するパスを絶対パスへ変換して stdout へ返す
#   hl_abs_from <base> <path>    : <path> が相対なら <base> 基準で絶対化する
#   hl_resolve_existing <base> <path>
#                                : <base> 基準 → カレントディレクトリ基準 の順で
#                                  実在するパスを探し、絶対パスで返す
#   hl_load_config <helper_dir>  : cc-helper.conf を source する(存在すれば)
#   hl_resolve_main_script <helper_dir> <script_name>
#                                : ラップ対象のメインスクリプトを絶対パスで特定する
#   hl_args_have "<opt|opt|...>" <args...>
#                                : 引数リストに指定オプションが含まれるか判定する
#   hl_build_assume_role_args <helper_dir>
#                                : スイッチロール関連の引数を配列 CC_ROLE_ARGS に構築する
#
# 設計上の注意(重要):
#   - メインスクリプトは「権限不足時に別チーム提供のスイッチロール用シェルを
#     自プロセス内で source する」構造になっている。source は相対パスを
#     「実行時のカレントディレクトリ」基準で解決するため、ヘルパーを別
#     ディレクトリに置いた状態で相対パスをそのまま渡すと source に失敗する。
#     これを防ぐため、スイッチロール用シェルのパスは必ずこのライブラリで
#     絶対パスへ変換してからメインスクリプトへ引き渡すこと
#     (hl_build_assume_role_args がその変換を担当する)。
#   - メインスクリプト自体は source せず、子プロセス(bash <script>)として
#     実行すること。メインスクリプト側は BASH_SOURCE 基準で common.sh を
#     source しているため、どこから起動しても共通部品の読み込みは正常に動く。
#     スイッチロールの source はメインスクリプトのプロセス内で行われるので、
#     子プロセス実行でも従来どおり認証情報は引き継がれる。
#

# 二重 source ガード
if [[ -n "${__CC_HELPER_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
__CC_HELPER_LIB_LOADED=1

hl_error() { printf '[%s] ERROR %s\n' "$(basename "${0}")" "$*" >&2; }
hl_info()  { printf '[%s] INFO  %s\n' "$(basename "${0}")" "$*" >&2; }

# エラーメッセージ + usage(呼び出し側ヘルパーで定義)を表示して終了する。
hl_usage_die() {
  hl_error "$@"
  printf '\n' >&2
  usage >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 存在するパスを絶対パスへ変換する。
#   - ディレクトリ: cd して pwd
#   - ファイル    : 親ディレクトリを絶対化して basename を連結
# 解決できない場合は 1 を返す(出力なし)。
# ---------------------------------------------------------------------------
hl_abs_path() {
  local p="${1:?hl_abs_path: パスが必要です}"
  if [[ -d "$p" ]]; then
    (cd "$p" 2>/dev/null && pwd) || return 1
  else
    local d
    d="$(cd "$(dirname "$p")" 2>/dev/null && pwd)" || return 1
    printf '%s/%s\n' "${d%/}" "$(basename "$p")"
  fi
}

# ---------------------------------------------------------------------------
# <path> が相対パスなら <base> 基準で絶対化する。絶対パスなら正規化のみ行う。
# (Git Bash の /c/... 形式と Windows の C:\... 形式の両方を絶対パスとみなす)
# ---------------------------------------------------------------------------
hl_abs_from() {
  local base="${1:?hl_abs_from: base が必要です}" p="${2:?hl_abs_from: path が必要です}"
  case "$p" in
    /*|[A-Za-z]:[/\\]*) hl_abs_path "$p" ;;
    *)                  hl_abs_path "${base}/${p}" ;;
  esac
}

# ---------------------------------------------------------------------------
# 実在するパスを探して絶対パスで返す。
#   1) <base>(通常は helpers ディレクトリ)基準
#   2) カレントディレクトリ基準
# の順で解決を試み、どちらにも無ければ 1 を返す。
# 設定ファイルに書いた相対パス(helpers 基準)と、コマンドラインで指定された
# 相対パス(CWD 基準)の両方を受け付けるための仕組み。
# ---------------------------------------------------------------------------
hl_resolve_existing() {
  local base="$1" p="$2" abs=""
  abs="$(hl_abs_from "$base" "$p" 2>/dev/null)" || abs=""
  if [[ -n "$abs" && -e "$abs" ]]; then
    printf '%s\n' "$abs"
    return 0
  fi
  abs="$(hl_abs_path "$p" 2>/dev/null)" || abs=""
  if [[ -n "$abs" && -e "$abs" ]]; then
    printf '%s\n' "$abs"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# 設定ファイルを読み込む。
#   - 既定: <helper_dir>/cc-helper.conf
#   - 環境変数 CC_HELPER_CONF で別パスを指定可能
#   - 存在しなければ何もしない(すべて引数/環境変数で指定する運用も可)
# ---------------------------------------------------------------------------
hl_load_config() {
  local helper_dir="${1:?hl_load_config: helper_dir が必要です}"
  local conf="${CC_HELPER_CONF:-${helper_dir}/cc-helper.conf}"
  CC_HELPER_CONF_LOADED=""
  if [[ -f "$conf" ]]; then
    # shellcheck source=/dev/null
    if ! source "$conf"; then
      hl_error "設定ファイルの読み込みに失敗しました: ${conf}"
      exit 1
    fi
    CC_HELPER_CONF_LOADED="$conf"
  fi
}

# ---------------------------------------------------------------------------
# ラップ対象のメインスクリプトを絶対パスで特定して stdout へ返す。
#   - 既定: helpers ディレクトリの親(= 本リポジトリ直下)
#   - 設定 CC_SCRIPTS_DIR で別の場所を指定可能(相対なら helpers 基準)
# ---------------------------------------------------------------------------
hl_resolve_main_script() {
  local helper_dir="${1:?hl_resolve_main_script: helper_dir が必要です}"
  local script_name="${2:?hl_resolve_main_script: script_name が必要です}"
  local dir_in="${CC_SCRIPTS_DIR:-${helper_dir}/..}"
  local dir
  if ! dir="$(hl_abs_from "$helper_dir" "$dir_in")" || [[ ! -d "$dir" ]]; then
    hl_error "メインスクリプトのディレクトリが見つかりません: ${dir_in}"
    hl_error "設定ファイルの CC_SCRIPTS_DIR で場所を指定してください。"
    exit 1
  fi
  local script="${dir}/${script_name}"
  if [[ ! -f "$script" ]]; then
    hl_error "メインスクリプトが見つかりません: ${script}"
    hl_error "設定ファイルの CC_SCRIPTS_DIR で場所を指定してください。"
    exit 1
  fi
  printf '%s\n' "$script"
}

# ---------------------------------------------------------------------------
# 引数リストに指定オプションのいずれかが含まれるか判定する。
#   hl_args_have "-b|--branch|-B|--branch-dir" "$@"
#   --opt=value 形式(オプション名部分)にも対応する。
# ---------------------------------------------------------------------------
hl_args_have() {
  local pat="${1:?hl_args_have: オプションパターンが必要です}"; shift
  local a name
  for a in "$@"; do
    case "|${pat}|" in
      *"|${a}|"*) return 0 ;;
    esac
    case "$a" in
      --*=*)
        name="${a%%=*}"
        case "|${pat}|" in
          *"|${name}|"*) return 0 ;;
        esac
        ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# スイッチロール関連の引数を配列 CC_ROLE_ARGS に構築する。
#   - CC_AUTO_ASSUME_ROLE=true      → --auto-assume-role を付与
#   - CC_ASSUME_ROLE_SCRIPT が設定済 → 絶対パスへ変換して --assume-role-script を付与
#
# パスの絶対化がこの関数の肝:
#   メインスクリプトはスイッチロール用シェルを `source` するため、相対パスの
#   ままだと「メインスクリプトを起動したときのカレントディレクトリ」に依存して
#   解決に失敗しうる。ヘルパー経由でも直接実行と同じように動作させるため、
#   ここで必ず絶対パスに固定してから引き渡す。
# ---------------------------------------------------------------------------
hl_build_assume_role_args() {
  local helper_dir="${1:?hl_build_assume_role_args: helper_dir が必要です}"
  CC_ROLE_ARGS=()

  if [[ "${CC_AUTO_ASSUME_ROLE:-false}" == "true" ]]; then
    CC_ROLE_ARGS+=(--auto-assume-role)
  fi

  local sr="${CC_ASSUME_ROLE_SCRIPT:-}"
  if [[ -n "$sr" ]]; then
    local abs
    if ! abs="$(hl_resolve_existing "$helper_dir" "$sr")" || [[ ! -f "$abs" ]]; then
      hl_error "スイッチロール用シェルが見つかりません: ${sr}"
      hl_error "設定 CC_ASSUME_ROLE_SCRIPT(または環境変数)のパスを確認してください。"
      exit 1
    fi
    CC_ROLE_ARGS+=(--assume-role-script "$abs")
  elif [[ "${CC_AUTO_ASSUME_ROLE:-false}" == "true" && -z "${ASSUME_ROLE_SCRIPT:-}" ]]; then
    hl_error "CC_AUTO_ASSUME_ROLE=true ですが、スイッチロール用シェルのパスが未設定です。"
    hl_error "設定 CC_ASSUME_ROLE_SCRIPT もしくは環境変数 ASSUME_ROLE_SCRIPT を設定してください。"
    exit 1
  fi
}
