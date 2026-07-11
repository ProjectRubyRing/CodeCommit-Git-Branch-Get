# CodeCommit ブランチ ZIP 取得スクリプト

AWS CodeCommit の **指定リポジトリ・指定ブランチ** の内容を取得し、
そのブランチに登録されている全ファイルを **ZIP に固めて指定ディレクトリへ保存** します。

## 構成

| ファイル | 説明 |
| --- | --- |
| `codecommit_branch_zip.sh` | 本体スクリプト |
| `common.sh` | 他プロジェクトと共通のヘルパ部品（ログ／認証チェック／スイッチロール）。最新版を利用 |

## 動作の流れ

1. **事前認証チェック** … `aws sts get-caller-identity` で `aws login --remote` 実施済みかを確認。
   未認証なら警告して終了します。
2. **CodeCommit 権限チェック** … `aws codecommit get-repository`（読み取り）で操作権限を確認。
   - 既定：権限が無ければ **スイッチロールを促して終了**。
   - `--auto-assume-role` 指定時：終了せず、**別チーム提供のシェルを `source` して自動スイッチロール**し、再確認します。
3. **取得** … `git clone`（既定は shallow / 単一ブランチ）で対象ブランチを一時ディレクトリへ取得。
4. **ZIP 化** … `git archive` でブランチのツリー（登録済みファイルのみ、`.git` は含まない）を ZIP 化し、保存先へ出力。
5. 一時ディレクトリは終了時に自動削除します。

> 取得方式は **git clone + git archive**。HTTPS 認証は `aws codecommit credential-helper` を
> スクリプト内で指定して行います（別途 git-remote-codecommit は不要）。

## 前提

- 事前に `aws login --remote` で認証していること。
- `aws` CLI と `git` が利用可能なこと。
- （任意）`unzip` があれば、生成後に ZIP 内ファイル数を表示します。

## 使い方

```bash
./codecommit_branch_zip.sh -r <リポジトリ名> -b <ブランチ名> -o <保存先ディレクトリ> [オプション]
```

### 主なオプション

| オプション | 説明 |
| --- | --- |
| `-r, --repository <name>` | 対象リポジトリ名（必須。`--repo-url` 指定時は任意） |
| `-b, --branch <name>` | ZIP 化するブランチ名（必須） |
| `-o, --output-dir <dir>` | ZIP の保存先ディレクトリ（必須。無ければ作成） |
| `--zip-name <name>` | 出力 ZIP 名（既定: `<repo>_<branch>_<日時>.zip`） |
| `--repo-url <url>` | clone URL。HTTPS もしくは grc 形式 `codecommit::<region>://<repo>` |
| `--region <region>` | AWS リージョン（URL 生成・認証で使用） |
| `--profile <name>` | AWS プロファイル |
| `--full-clone` | 全履歴を clone（既定は `--depth 1`） |
| `--auto-assume-role` | 権限が無い場合に終了せず自動スイッチロール |
| `--assume-role-script <path>` | スイッチロール用に `source` するシェルのパス（環境変数 `ASSUME_ROLE_SCRIPT` でも指定可） |
| `-n, --dry-run` | 副作用のある操作（clone / ZIP 生成 / ディレクトリ作成 / 自動スイッチロールの source）を実行せず、実行予定のみ表示 |
| `-h, --help` | ヘルプ表示 |

### 例

```bash
# 基本
./codecommit_branch_zip.sh -r my-repo -b main -o ./out --region ap-northeast-1

# 出力ファイル名を指定
./codecommit_branch_zip.sh -r my-repo -b develop -o /tmp/zips --zip-name develop.zip

# 権限が無ければ自動スイッチロール（別チーム提供シェルを source）
./codecommit_branch_zip.sh -r my-repo -b main -o ./out \
    --auto-assume-role --assume-role-script /opt/team/assume_role.sh

# ドライラン（何も保存せず実行内容だけ確認）
./codecommit_branch_zip.sh -r my-repo -b main -o ./out --dry-run
```

## スイッチロールについて

権限不足時のスイッチロールは、**別チームが用意した専用シェルを `source`** して行います
（`source` することで、そのシェル内で `export` された認証情報を本スクリプトのプロセスへ引き継ぎます）。
シェルの配置場所は `--assume-role-script <path>` または環境変数 `ASSUME_ROLE_SCRIPT` で指定してください。
ロール ARN 等の指定は専用シェル側に委ねる方式です。

## dry-run の挙動

`--dry-run` では読み取り（認証確認・権限確認）は通常どおり行い、
副作用のある操作（clone・ZIP 生成・ディレクトリ作成・自動スイッチロールの `source`）は
実行せず「実行予定」を表示します。
