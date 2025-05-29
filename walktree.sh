#!/usr/bin/env bash

# スクリプトの堅牢性を高める設定
set -e # エラーが発生したらスクリプトを即座に終了
set -u # 未定義変数を参照しようとしたらエラー
set -o pipefail # パイプラインの途中でコマンドが失敗したら、パイプライン全体を失敗とする

# --- グローバル変数 (リポジトリルートは後で設定) ---
REPO_ROOT=""

# --- 関数の定義 ---

# エラーメッセージを表示して終了する関数
error_exit() {
    echo "エラー: $1" >&2
    exit 1
}

# Gitリポジトリ内で実行されているか確認する関数
check_git_repo() {
    if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        error_exit "Gitリポジトリ内で実行してください。"
    fi
    REPO_ROOT=$(git rev-parse --show-toplevel)
    if [ -z "$REPO_ROOT" ]; then
        error_exit "Gitリポジトリのルートディレクトリを取得できませんでした。"
    fi
}

# fzfがインストールされているか確認する関数
check_fzf() {
    if ! command -v fzf &> /dev/null; then
        error_exit "fzf が見つかりません。fzfをインストールしてください。(例: sudo apt install fzf / brew install fzf)"
    fi
}

# Worktreeを作成または既存のものを開く関数
create_or_open_worktree() {
    echo "--- Worktree作成/オープン ---"
    # 1. リモートブランチの選択
    remote_branches_list=$(git branch -r --format='%(refname:short)' | grep -v '/HEAD$' || true) # || true で空でもエラーにしない
    if [ -z "$remote_branches_list" ]; then
        echo "リモートブランチが見つかりません。"
        exit 0
    fi

    selected_remote_branch=$(echo "$remote_branches_list" | fzf --prompt="Select a remote branch: " --height 40% --border --exit-0)
    if [ -z "$selected_remote_branch" ]; then
        echo "ブランチが選択されませんでした。"
        exit 0
    fi
    echo "選択されたリモートブランチ: $selected_remote_branch"

    # 2. ローカルブランチ名とworktreeパスを決定
    local_branch_name=$(echo "$selected_remote_branch" | sed 's|^[^/]*/||')
    worktree_path_relative_to_repo="$local_branch_name"
    prospective_worktree_abs_path="$REPO_ROOT/$worktree_path_relative_to_repo"
    target_worktree_abs_path="$prospective_worktree_abs_path" # デフォルトのターゲットパス

    echo "ローカルブランチ名 (ターゲット): $local_branch_name"
    echo "Worktreeパス (リポジトリルートからの相対): $worktree_path_relative_to_repo"

    # 3. 既存worktreeの確認
    expected_branch_ref="refs/heads/$local_branch_name"
    found_existing_worktree_abs_path=""
    current_path_in_loop=""
    while IFS= read -r line; do
        if [[ "$line" == "worktree "* ]]; then
            current_path_in_loop="${line#worktree }"
        elif [[ "$line" == "branch "* ]]; then
            if [ -n "$current_path_in_loop" ]; then
                current_branch_ref="${line#branch }"
                if [[ "$current_branch_ref" == "$expected_branch_ref" ]]; then
                    found_existing_worktree_abs_path="$current_path_in_loop"
                    break
                fi
            fi
            current_path_in_loop=""
        elif [[ "$line" == "" && -n "$current_path_in_loop" ]]; then
            current_path_in_loop=""
        fi
    done < <(git worktree list --porcelain)

    if [ -n "$found_existing_worktree_abs_path" ]; then
        echo "既存のworktreeが見つかりました: $found_existing_worktree_abs_path"
        target_worktree_abs_path="$found_existing_worktree_abs_path"
    else
        echo "Worktree for branch '$local_branch_name' は存在しません。新規作成します..."
        if [ -e "$target_worktree_abs_path" ]; then
            if [ -e "$target_worktree_abs_path/.git" ]; then
                error_exit "パス '$target_worktree_abs_path' は既にGit worktreeとして使用されていますが、ブランチ '$local_branch_name' とは関連付けられていませんでした。\n'git worktree list' を確認し、必要であれば 'git worktree remove \"$worktree_path_relative_to_repo\"' で削除してください。"
            elif [ -d "$target_worktree_abs_path" ] && [ -n "$(ls -A "$target_worktree_abs_path" 2>/dev/null)" ]; then
                error_exit "パス '$target_worktree_abs_path' は既に存在し、空のディレクトリではありません。\nworktreeを作成するには、存在しないパスか空のディレクトリを指定してください。"
            elif [ -f "$target_worktree_abs_path" ] && ! [ -d "$target_worktree_abs_path" ]; then
                error_exit "パス '$target_worktree_abs_path' には既にファイルが存在します。"
            fi
        fi

        echo "コマンド実行: git -C \"$REPO_ROOT\" worktree add \"$worktree_path_relative_to_repo\" \"$selected_remote_branch\""
        if git -C "$REPO_ROOT" worktree add "$worktree_path_relative_to_repo" "$selected_remote_branch"; then
            echo "Worktreeが正常に作成されました: $target_worktree_abs_path (ブランチ: $local_branch_name)"
        else
            error_exit "Worktreeの作成に失敗しました。"
        fi
    fi

    # 5. シェルを開く
    echo "Opening shell in '$target_worktree_abs_path'..."
    cd "$target_worktree_abs_path" || error_exit "ディレクトリ '$target_worktree_abs_path' に移動できませんでした。"
    exec "$SHELL"
}

# Worktreeを削除する関数
remove_worktree() {
    echo "--- Worktree削除 ---"
    # プライマリワークツリーを除いたリストを取得 (パスとブランチ情報を表示)
    # `git worktree list` の出力例:
    # /path/to/repo              0a1b2c3 [main]  <-- プライマリ
    # /path/to/repo/feature-foo  d4e5f6a [feature-foo]
    # /path/to/repo/fix-bar      c7b8a99 (detached HEAD)
    worktree_candidates=$(git -C "$REPO_ROOT" worktree list | tail -n +2 | awk '{ path=$1; $1=$2=""; branch_info=substr($0,3); printf "%s %s\n", path, branch_info }' || true)
    primary_worktree_path=$(git -C "$REPO_ROOT" worktree list | head -n 1 | awk '{print $1}')
    if [ -z "$worktree_candidates" ]; then
        echo "削除可能な追加のworktreeはありません。"
        exit 0
    fi

    selected_line=$(echo "$worktree_candidates" | fzf --prompt="Select worktree to remove: " --height 40% --border --exit-0)
    if [ -z "$selected_line" ]; then
        echo "Worktreeが選択されませんでした。"
        exit 0
    fi

    worktree_path_to_remove=$(echo "$selected_line" | awk '{print $1}')
    branch_info_part=$(echo "$selected_line" | awk '{$1=""; print substr($0,2)}') # Pathを除いた部分 (例: "[feature-foo]" or "(detached HEAD)")
    
    local_branch_to_potentially_delete=""
    if [[ "$branch_info_part" == "["*"]" ]]; then # "[branch]" 形式
        local_branch_to_potentially_delete=$(echo "$branch_info_part" | sed -e 's/^\[//' -e 's/\]$//')
    fi

    echo "--------------------------------------------------"
    echo "削除対象のworktreeパス: $worktree_path_to_remove"
    if [ -n "$local_branch_to_potentially_delete" ]; then
        echo "関連ブランチ (候補): $local_branch_to_potentially_delete"
    fi
    echo "--------------------------------------------------"

    read -rp "Worktree '$worktree_path_to_remove' を本当に削除しますか？ (y/N): " confirmation
    if [ "$(echo "$confirmation" | tr '[:upper:]' '[:lower:]')" != "y" ]; then # 小文字に変換して比較
        echo "削除をキャンセルしました。"
        exit 0
    fi

    # Worktree削除試行
    if [ ! -d "$worktree_path_to_remove" ]; then
        error_exit "指定されたworktreeパス '$worktree_path_to_remove' は存在しません。"
    fi
    if [  "$REPO_ROOT" = "$worktree_path_to_remove" ]; then
        echo "cd \"$primary_worktree_path\" でリポジトリルートの親に移動します"
        cd "$primary_worktree_path" || error_exit "リポジトリルート '$primary_worktree_path' に移動できませんでした。"
    fi

    echo "コマンド実行: git -C \"$REPO_ROOT\" worktree remove \"$worktree_path_to_remove\""
    if git -C "$REPO_ROOT" worktree remove "$worktree_path_to_remove"; then
        echo "Worktree '$worktree_path_to_remove' は正常に削除されました。"

        # primary_worktree_path より下で、worktree_path_to_remove までの親ディレクトリを空なら削除
        parent_dir="$worktree_path_to_remove"
        while true; do
            parent_dir=$(dirname "$parent_dir")
            # ルートまたはprimary_worktree_pathに到達したら終了
            if [ "$parent_dir" = "$primary_worktree_path" ] || [ "$parent_dir" = "/" ]; then
            break
            fi
            # ディレクトリが空なら削除
            if [ -d "$parent_dir" ] && [ -z "$(ls -A "$parent_dir")" ]; then
            read -rp "空の親ディレクトリ '$parent_dir' を削除しますか？ (y/N): " remove_parent_confirmation
            if [ "$(echo "$remove_parent_confirmation" | tr '[:upper:]' '[:lower:]')" = "y" ]; then
                rmdir "$parent_dir"
            else
                break
            fi
            else
            break
            fi
        done
        # 削除したworktreeの中にいる場合はcdで抜ける
        current_dir="$(pwd)"
        if [[ "$current_dir" == "$worktree_path_to_remove"* ]]; then
            echo "現在ディレクトリが削除したworktreeの中にあるため、リポジトリルートに移動します。"
            cd "$primary_worktree_path" || error_exit "リポジトリルート '$primary_worktree_path' に移動できませんでした。"
        fi
    else
        echo "エラー: Worktree '$worktree_path_to_remove' の削除に失敗しました。"
        echo "考えられる原因: 未コミットの変更、ブランチのマージされていない変更など。"
        read -r -p "強制的に削除 (--force) しますか？ (y/N): " force_remove_confirmation
        if [ "$(echo "$force_remove_confirmation" | tr '[:upper:]' '[:lower:]')" = "y" ]; then
            echo "コマンド実行: git -C \"$REPO_ROOT\" worktree remove --force \"$worktree_path_to_remove\""
            if git -C "$REPO_ROOT" worktree remove --force "$worktree_path_to_remove"; then
                echo "Worktree '$worktree_path_to_remove' は強制的に削除されました。"
                # primary_worktree_path より下で、worktree_path_to_remove までの親ディレクトリを空なら削除
                parent_dir="$worktree_path_to_remove"
                while true; do
                    parent_dir=$(dirname "$parent_dir")
                    # ルートまたはprimary_worktree_pathに到達したら終了
                    if [ "$parent_dir" = "$primary_worktree_path" ] || [ "$parent_dir" = "/" ]; then
                    break
                    fi
                    # ディレクトリが空なら削除
                    if [ -d "$parent_dir" ] && [ -z "$(ls -A "$parent_dir")" ]; then
                    read -rp "空の親ディレクトリ '$parent_dir' を削除しますか？ (y/N): " remove_parent_confirmation
                    if [ "$(echo "$remove_parent_confirmation" | tr '[:upper:]' '[:lower:]')" = "y" ]; then
                        rmdir "$parent_dir"
                    else
                        break
                    fi
                    else
                    break
                    fi
                done
                # 削除したworktreeの中にいる場合はcdで抜ける
                current_dir="$(pwd)"
                if [[ "$current_dir" == "$worktree_path_to_remove"* ]]; then
                    echo "現在ディレクトリが削除したworktreeの中にあるため、リポジトリルートに移動します。"
                    cd "$primary_worktree_path" || error_exit "リポジトリルート '$primary_worktree_path' に移動できませんでした。"
                fi
            else
                error_exit "Worktreeの強制削除に失敗しました。"
            fi
        else
            echo "削除は実行されませんでした。"
            exit 0
        fi
    fi

    # ローカルブランチの削除を確認 (worktreeが削除された後)
    if [ -n "$local_branch_to_potentially_delete" ]; then
        # ブランチがまだ存在するか確認
        if git -C "$REPO_ROOT" rev-parse --verify "$local_branch_to_potentially_delete" > /dev/null 2>&1; then
            echo "--------------------------------------------------"
            read -rp "関連するローカルブランチ '$local_branch_to_potentially_delete' も削除しますか？ (y/N): " delete_branch_confirmation
            if [ "$(echo "$delete_branch_confirmation" | tr '[:upper:]' '[:lower:]')" = "y" ]; then
                echo "ブランチ削除オプション:"
                echo "  d: 通常削除 (-d, マージ済みブランチのみ)"
                echo "  D: 強制削除 (-D, 未マージでも削除)"
                echo "  N: 削除しない"
                read -rp "ブランチ '$local_branch_to_potentially_delete' の削除方法を選択してください (d/D/N): " branch_delete_mode
                
                delete_command_branch=""
                if [[ "${branch_delete_mode,,}" == "d" ]]; then
                    delete_command_branch="git -C \"$REPO_ROOT\" branch -d \"$local_branch_to_potentially_delete\""
                elif [[ "${branch_delete_mode,,}" == "D" ]]; then
                    delete_command_branch="git -C \"$REPO_ROOT\" branch -D \"$local_branch_to_potentially_delete\""
                fi

                if [ -n "$delete_command_branch" ]; then
                    echo "コマンド実行: $delete_command_branch"
                    if eval "$delete_command_branch"; then
                        echo "ブランチ '$local_branch_to_potentially_delete' は正常に削除されました。"
                    else
                        echo "エラー: ブランチ '$local_branch_to_potentially_delete' の削除に失敗しました。"
                        echo "手動でコマンドを試してください: git branch [-d|-D] $local_branch_to_potentially_delete"
                    fi
                else
                    echo "ブランチ '$local_branch_to_potentially_delete' の削除はスキップされました。"
                fi
            else
                echo "ブランチ '$local_branch_to_potentially_delete' の削除はスキップされました。"
            fi
        else
            echo "ローカルブランチ '$local_branch_to_potentially_delete' は既に存在しないか、worktreeと共に削除されたようです。"
        fi
    fi
    echo "--- Worktree削除完了 ---"
    exit 0
}

# --- メイン処理 ---
check_git_repo # REPO_ROOT がここで設定される
check_fzf

echo "Git Worktree Manager"
echo "--------------------"
echo "リポジトリルート: $REPO_ROOT"
echo "現在のブランチ: $(git rev-parse --abbrev-ref HEAD || echo '不明')"
echo "現在の作業ツリー:"
git worktree list --porcelain | awk '/^worktree / {print $2}' | sed 's|^|  - |' || echo "  (なし)"
echo "--------------------"
echo "実行したいアクションを選択してください:"
PS3="番号を入力してください: " # selectプロンプトのカスタマイズ
actions=("新しいworktreeを作成 / 既存のworktreeを開く" "既存のworktreeを削除する" "ローカルのWorktreeリストを表示" "キャンセルして終了")

select _ in "${actions[@]}"; do
    case "$REPLY" in
        1)
            create_or_open_worktree # この関数は exec $SHELL で終了するため、ここには戻らない
            break #念のため
            ;;
        2)
            remove_worktree # この関数は exit で終了する
            break #念のため
            ;;
        3)
            echo "リストを表示します..."
            git worktree list --porcelain | awk '/^worktree / {print $2}' | sed 's|^|  - |' || echo "  (なし)"
            echo "--------------------"
            continue # ループを継続して再度プロンプトを表示
            ;;  
        4)
            echo "キャンセルしました。"
            exit 0
            ;;
        
        *)
            echo "無効な選択です: '$REPLY'"
            # ループは継続し、再度プロンプトが表示される
            ;;
    esac
done
