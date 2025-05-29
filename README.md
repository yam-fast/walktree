# walktree.sh

`walktree.sh` は、Gitリポジトリの [worktree](https://git-scm.com/docs/git-worktree) を対話的に管理するための Bash スクリプトです。  
fzf によるブランチ選択や、worktree の作成・削除・一覧表示を簡単に行えます。

## 特徴

- **リモートブランチから新しい worktree を作成**  
  既存の worktree があれば自動で開き、なければ新規作成します。
- **worktree の削除**  
  fzf で選択し、不要な worktree を安全に削除できます。関連ローカルブランチの削除も選択可能。
- **worktree 一覧表示**  
  現在の worktree をリスト表示します。
- **対話的な操作**  
  すべての操作は対話的なメニューから選択できます。

## 必要要件

- bash
- git
- [fzf](https://github.com/junegunn/fzf)（インストールされていない場合は `brew install fzf` などで導入してください）

## 使い方

1. **スクリプトを配置**  
   PATH内部のディレクトリ、リポジトリのルート、または任意の場所に `walktree.sh` を置きます。

2. **実行権限を付与**  
   ```sh
   chmod +x walktree.sh
   ```

3. **Gitリポジトリ内で実行**  
   ```sh
   walktree.sh
   ```

4. **メニューが表示されるので、番号で操作を選択**  
   - 1: 新しい worktree を作成 / 既存の worktree を開く
   - 2: 既存の worktree を削除する
   - 3: ローカルの worktree リストを表示
   - 4: キャンセルして終了

### 新しい worktree の作成

- リモートブランチ一覧から fzf で選択
- 既存 worktree があればそのディレクトリでシェルを開く
- なければ新規作成し、そのディレクトリでシェルを開く

### worktree の削除

- 追加 worktree のみ選択肢に表示
- 削除後、関連ローカルブランチの削除も選択可能

## 注意事項

- **リポジトリ直下で実行してください。**
- **fzf が必要です。**  
  インストールされていない場合は、エラーが表示されます。
- **worktree の削除は慎重に！**  
  未コミットの変更や未マージのブランチは削除できない場合があります（強制削除も選択可能）。