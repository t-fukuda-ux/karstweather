# ローカル軽量トリガー設計

## 目的

GitHubのscheduledイベントが欠落しても、サーバーPCから毎時20分に`workflow_dispatch`を送り、天気予報を更新する。宿泊管理を最優先とし、このPCでは予報生成・git操作を行わない。

## 処理

1. 多重起動防止mutexを取得する。前回分が動作中なら終了する。
2. 自プロセスを低優先度へ変更する。
3. 公開ページが50分以内に更新済みなら、その時点で正常終了する。
4. Windowsに保存されたGitHub認証を一時的に読み、GitHub Actionsを起動する。認証情報はログやファイルへ書かない。
5. 15秒以下のHTTPS要求を間欠的に送り、起動した実行を最大12分待つ。
6. 成功後、公開ページの取得日時が今回の開始時刻以降になるまで最大3分確認する。
7. 回線断などで失敗した場合、タスクスケジューラが10分間隔で最大3回再実行する。

## 宿泊管理を守る設定

- タスク優先度7、PowerShellプロセスもBelowNormal。
- 実体はProgramDataの専用フォルダに置き、現在のユーザー・SYSTEM・管理者以外の変更をACLで禁止する。
- 非対話・非表示で実行し、宿泊管理の画面を遮らない。
- ローカルではAPIデータ取得、HTML生成、git clone/pull/pushをしない。
- 同時実行は1つだけ。20分で強制終了する。
- 通信の間はsleepし、CPUを占有しない。
- ログは1MBを超えたら直近約2000行へ縮小する。

## 成功条件

GitHub Actionsの成功だけでは成功にしない。公開URLを読み直し、HTML内の「取得」時刻が今回の起動時刻以降であることを確認する。

## 制約

- PC停止、Windows未ログオン、GitHub全体の障害、保存済み認証の失効時には更新できない。
- GitHub Actionsの実行自体が長時間停止した場合は20分で打ち切る。
- タスクの失敗はWindowsのタスク履歴と`weather-trigger.log`に残る。通知機能は今回の範囲に含めない。

## 停止・削除

一時停止：`Disable-ScheduledTask -TaskName KarstWeatherWorkflowTrigger`

再開：`Enable-ScheduledTask -TaskName KarstWeatherWorkflowTrigger`

タスク削除：`Unregister-ScheduledTask -TaskName KarstWeatherWorkflowTrigger -Confirm:$false`

タスクを削除しても、`C:\ProgramData\KarstWeatherTrigger`のスクリプトとログは残る。
