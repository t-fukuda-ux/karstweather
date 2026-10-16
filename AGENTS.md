## Imported Claude Cowork project instructions

作業を始める前に、必ず `SYSTEM.md` を読むこと。システム全体の仕様（ファイル構成・実行方法・指数の仕様・自動更新と公開・技術的な落とし穴・障害の記録）を1ファイルにまとめてある。

- 公開のメインは平均版（混合版）。`lowcloud_avg.ps1` → `lowcloud_avg.html` / `index.html`
- WordPress の天気予報ページ（日英中韓）は `SYSTEM.md` の「9-6. WordPress の天気予報ページ」を参照
- `.ps1` は UTF-8（BOM付き）で保存する。BOM が外れると日本語を含む行で構文エラーになる
- 生成物（`*.html` `*.csv`）は自動更新が毎時 commit・push する。push 前は `git pull --rebase` で追従する
