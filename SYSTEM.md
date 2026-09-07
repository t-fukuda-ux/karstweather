# 四国カルスト 姫鶴荘 天気予報システム 仕様書

最終更新: 2026-09-07

このファイル1つでシステム全体を把握できるようにしてある。旧 `引き継ぎ書.md` の内容はすべてここに取り込んだ。

- このPCの作業リポジトリ: `C:\Users\mezuru\Documents\Codex\天気予報`
- 正本: `https://github.com/t-fukuda-ux/karstweather` の `main` ブランチ
- 他のPCでもGitHubから各PCのローカルディスクへcloneし、作業前に `git pull --rebase`、作業後にcommit・pushする。クラウド同期フォルダへリポジトリのコピーを置かない。

---

## 1. 概要

四国カルスト「姫鶴荘」の天気を **Open-Meteo（無料・APIキー不要）** から取得し、
**毎時予報・週間予報・星空指数・雲海期待度・気象警報** を1枚のHTMLにまとめて表示する。
PowerShell のみで動作する（Python 不要）。**低層雲(%)の把握**が主目的。

同じ地点を**3つのモデル系統**で出力しており、比較検証できる。**公開のメインは平均版**。

| 版 | モデル | URL |
|---|---|---|
| **平均版（トップページ）** | best_match + ECMWF | https://t-fukuda-ux.github.io/karstweather/ |
| 規定版 | best_match | https://t-fukuda-ux.github.io/karstweather/lowcloud.html |
| EC版 | ecmwf_ifs025 | https://t-fukuda-ux.github.io/karstweather/lowcloud_ec.html |
| 平均版（単独URL） | 同上 | https://t-fukuda-ux.github.io/karstweather/lowcloud_avg.html |
| 雲海の検証ページ | 3版すべて | https://t-fukuda-ux.github.io/karstweather/unkai_lab.html |

WordPress 等には トップページを iframe で埋め込む。埋め込み先には高さ自動追従スクリプトが入っている（`postMessage` で親ページに通知）。

雲海の検証ページは**予報ページからリンクしておらず、`noindex` を付けてある**。ただしURLを知っていれば誰でも閲覧できる（中身は予報の診断値のみ）。

---

## 2. 対象地点

| 項目 | 値 |
|---|---|
| 場所 | 四国カルスト 姫鶴荘（めづるそう） |
| 緯度 / 経度 | 33.4666147 / 132.9610114 |
| 標高（気温補正用） | **1380m 指定**（APIの地形標高は約1296m。他予報との気温差を縮めるため1380m指定＋時間帯別補正を併用） |
| タイムゾーン | Asia/Tokyo（JST, UTC+9固定・DSTなし） |
| 気象警報の対象区域 | 久万高原町(3838600・愛媛380000) / 梼原町(3940500・高知390000) |

雲海指数だけは、この地点に加えて**見下ろす谷4地点**も取得する（7-2節）。

---

## 3. ファイル構成

### 実行されるファイル

| ファイル | 役割 |
|---|---|
| `generate_all.ps1` | **生成の起点**。API取得を最小回数にまとめ、3版すべてを同じデータから生成し、`index.html` の更新まで担当。1版が失敗しても他は継続する |
| `lowcloud_common.ps1` | **共有関数**。天気アイコン／天文計算／星空指数／整形／警報／リトライ付きAPI取得。末尾で雲海の2ファイルを読み込む |
| `unkai_common.ps1` | **雲海指数の計算エンジン**（7-2節） |
| `unkai_report.ps1` | 雲海の検証ページとCSVの出力 |
| `lowcloud.ps1` | **本体（規定版）**。`-Models`/`-OutName`/`-ModelLabel` でEC版からも呼ばれる |
| `lowcloud_ec.ps1` | EC版。`lowcloud.ps1` を `-Models ecmwf_ifs025` で呼ぶ薄いラッパー |
| `lowcloud_avg.ps1` | 平均版。2モデルの数値平均＋天気の再判定＋週間の複合表現 |
| `unkai_lab.ps1` | 雲海の検証ページを今すぐ最新化する（公開ページには触れない） |
| `publish.ps1` | ローカルタスク用。origin追従 → `generate_all.ps1` → commit・push |
| `.github/workflows/update.yml` | GitHub Actions。毎時11分・41分に実行し自動push |
| `setup-github.ps1` | 初回のみ。リポジトリの初期設定 |
| `setup-localtask.ps1` | 軽量バックアップタスクの登録入口 |
| `local-trigger/invoke-weather-update.ps1` | 公開ページが古い時だけActionsを起動し、公開反映まで確認 |
| `local-trigger/install-weather-trigger.ps1` | 毎時20分・低優先度のWindowsタスクを安全なACLで登録 |
| `windy_compare.ps1` | 検証用。Windy(GFS) vs Open-Meteo 比較（要APIキー・git未追跡） |

### 生成物

| ファイル | git | 内容 |
|---|---|---|
| `index.html` | 追跡 | 平均版のコピー。GitHub Pages のルート |
| `lowcloud.html` / `lowcloud_ec.html` / `lowcloud_avg.html` | 追跡 | 各版のHTML |
| `unkai_lab.html` | 追跡 | 雲海の検証ページ（3時間おきに更新） |
| `lowcloud*.csv` | 除外 | 各版のCSV |
| `unkai_detail.csv` | 除外 | 雲海の全内訳（67列） |
| `unkai_levels.csv` | 除外 | 雲海の気圧面プロファイル生値 |
| `unkai_log.csv` | 除外 | **雲海の実績記録（手で記入する）。再実行でも上書きしない** |
| `publish.log` | 除外 | `publish.ps1` の実行ログ |

`publish.ps1` と Actions はいずれも `git add` の対象を**上記の追跡5ファイルと `forecast-history/` に明示限定**している。新しい生成物を公開したい場合は両方に追加が必要。

---

## 4. 実行方法

```powershell
cd "C:\Users\mezuru\Documents\Codex\天気予報"

# 3版すべて生成（API取得は最小回数、index.html更新まで。git操作なし）
powershell -ExecutionPolicy Bypass -File ".\generate_all.ps1"

# 雲海の検証ページを間隔を待たずに生成
powershell -ExecutionPolicy Bypass -File ".\generate_all.ps1" -ForceUnkaiLab
powershell -ExecutionPolicy Bypass -File ".\unkai_lab.ps1"      # 検証ページだけ作る

# 3版すべて生成＋GitHub Pages公開（origin追従→生成→commit・push）
powershell -ExecutionPolicy Bypass -File ".\publish.ps1"

# 個別実行（比較用。各自でAPI取得する）
powershell -ExecutionPolicy Bypass -File ".\lowcloud.ps1"
powershell -ExecutionPolicy Bypass -File ".\lowcloud_ec.ps1"
powershell -ExecutionPolicy Bypass -File ".\lowcloud_avg.ps1"
```

**編集後は必ず UTF-8 BOM を再付与すること**（10章）。`.ps1` と `.yml` のどちらも対象。

---

## 5. データ取得の仕様

### 5-1. モデル

- 出典: **Open-Meteo**（無料・キー不要）
- 規定版: `best_match`（この地点では実質 気象庁MSM。検証済み）
- EC版: `ecmwf_ifs025`
- 平均版: 上記2つの平均＋独自の天気判定
  - **降水量・全雲量のみ 規定版0.7 + ECMWF0.3 の加重平均**（2026-07-20〜。当初0.6:0.4。この地点は best_match=MSM の精度が高いため重視）
  - その他（気温／風速／降水確率／低中高層雲）は単純平均
  - 天気判定: **降水量0.2mm以下（0.1mm丸め後）は雨とせず「曇り」**（2026-07-19〜）
  - 雷雨判定: **規定版が雷雨コードのときのみ雷雨**（2026-07-20〜。ECMWFは雷雨予想が過多）
  - 日の出・日の入りは**best_match の daily を共通利用**（モデル間差がないため平均しない）
- ⚠ Open-Meteo の GFS はこの地点で低層雲が全時刻100%に張り付く異常あり。GFS比較が必要なら `windy_compare.ps1` を使う

### 5-2. 取得の一本化とリトライ

`generate_all.ps1` が1回の更新で行う取得は次のとおり。3版すべてが同じデータから生成されるので、データ時点が揃う。

| 対象 | 回数 | 内容 |
|---|---|---|
| Open-Meteo 予報本体 | 2回 | best_match / ECMWF（hourly+daily統合・7日分・1地点） |
| Open-Meteo 雲海 | 2回 | best_match / ECMWF（展望地点＋谷4地点を1リクエストにまとめる） |
| 気象庁 警報JSON | 県別1回 | 愛媛・高知 |

すべて `Invoke-JsonWithRetry` 経由で、**最大3回リトライ（5秒→15秒待ち）・タイムアウト60秒**。

`-Validate` にスクリプトブロックを渡すと、**応答の「中身」も再試行の対象**にできる。Open-Meteo はエラー時こそ HTTP 400 を返すが、**200 のまま毎時データが空の応答を返すことがある**ため（11章）、`Get-ForecastBundle` はこれを使って空応答を再取得する。3回とも空だった場合だけ失敗として扱う。

### 5-3. 空データのガード

APIが200を返しても中身が無いことがあるため、2箇所で本数を確認する。**下回ると例外を投げ、HTMLとCSVを書き出す前に停止する**ので、前回のページがそのまま残る。

| 位置 | 内容 |
|---|---|
| `Assert-BundleUsable` | API応答の `hourly.time` が24本未満なら停止 |
| `Assert-RowsUsable` | 日付で絞り込んだ後の行数が24本未満なら停止 |

正常なら当日0時から数日分あり常に72本以上になる。`generate_all.ps1` はその版を失敗として扱い、**平均版が失敗した場合は `index.html` も更新しない**。

### 5-4. 気温補正（表示のみ。CSVは生値）

他予報より低く出る問題への対処として、標高1380m指定に加えて時間帯別に加算する。

- 毎時: 8-10時 +1℃ ／ 11-15時 +2℃ ／ 16-17時 +1℃ ／ その他なし
- **7〜9月の8〜18時は、晴れ・快晴のときのみさらに +1℃**（2026-07-14追加。規定/EC版は weather_code 0/1、平均版は導出天気キー clear/mclear で判定）
- 週間カードの最高・最低気温は、同じ日の補正後の毎時気温から集計する（最高への一律+2℃は廃止）。欠測は `--`。規定版・EC版も7日分の毎時データを使用する
- 表示は **0捨1入（切り上げ）で整数化**

### 5-5. 降水確率

**3版とも毎時テーブルから削除**している。best_match=MSM には降水確率が無く、GFS由来のダミー値になるため（平均版も2026-07-14に削除して統一）。コンソール・CSVも同様。**週間カードの降水確率は3版とも表示**する（平均版は毎時popの日最大値）。

---

## 6. 表示仕様

### 6-1. 毎時テーブル（横スクロール）

行順: 日付 / 時刻 / 天気 / 低層雲%(霧) / 気温℃ / 風速m/s / 雨量mm / 全雲量% / 月 / 星空指数 / **雲海期待度**

- **天気アイコン**: 自作SVG（外部依存なし）。平均版は内部天気キー→アイコンの対応表（`Get-AvgIconKey`）
- **低層雲セル**: 逓増グラデーション。明度 `L = 100 - (0.3v + 0.003v²)`。明度55%未満は白文字
- **雨量セル**: 青のグラデーション（`L = 100 - min(v,20)/20 × 55`）。1mm未満は1mm相当、**30mm以上は薄橙の単色**
- **風速セル**: 3m/s以上=薄黄 `#fff9c4`、6m/s以上=薄橙 `#ffe0b2`
- **日付行**: 横スクロールしても日付ラベルが左に固定（colspan + sticky）
- **当日の過去時刻は薄く表示**（opacity .4）、**現在時刻の列は黄色でハイライト**（`id="nowcol"`）。開くと現在時刻の列が左端見出しのすぐ右に来るよう自動スクロールする（左へ戻すと当日0時までの過去分が見える）
- **月の欄**: 月が出ている時間帯を明るさに応じた薄黄グラデーションで表示。出／南中／入りの時刻と月齢（絵文字付き）を表示。出↑は橙太字、入り↓は青太字
- **星空指数**（0〜100・5単位）: 夜間のみ（7-1節）
- **雲海期待度**（0〜100）: 日の出前後4時刻のみ。それ以外は `--`（7-2節）
- **気象警報バナー**: テーブル上部に1行。注意報=黄／警報=赤／**危険警報=紫**／特別警報=濃赤。無ければ薄く「発表なし」

### 6-2. 週間カード（横並び）

天気アイコン / 天気名（平均版は複合表現） / 最高°・最低° / 降水確率＋降水量 / 日の出・日の入り / 月相・月の出入り / **雲海期待度**

- 月表示: 絵文字＋月齢X日。月齢0=新月、3=三日月、15=満月（名称表示）
- 土=青・日=赤
- 雲海の行: `雲海 78 南 06時` ＋ 状態ラベルと `3/4地点`

### 6-3. 注意書き（毎時テーブル下）

低層雲と霧の関係／気温が低く出がちな点／山頂の風速増幅／雨量が広域予報の影響でズレる可能性／星空指数／**雲海期待度**、の6項目。

---

## 7. 指数の仕様

### 7-1. 星空指数（0〜100・5単位）

夜間（太陽高度 < 0）のみ算出する。**すべて「満月の南中＝明るさ100」のスケールに統一**している。

```
B   = 月明かり + 薄明        （100で頭打ち）
指数 = (100 - 全雲量) × (1 - B/100)
       × 0.7  （降水 0 < p < 1mm）
       × 0.4  （降水 1mm以上）
```

構成要素:

| 要素 | 方法 |
|---|---|
| 月の位置 | **Meeus の多項補正モデル**（Table 47.A/B の上位20/10項）で赤経・赤緯 |
| 月相 | **月と太陽の黄経差**から算出（平均朔望式より正確。starwalk等の月齢と一致） |
| 月の明るさ | **Krisciunas & Schaefer (1991)** の位相項 `10^(-0.4(0.026α + 4e-9·α⁴))` |
| 高度による減光 | **Kasten & Young (1989)** のエアマス。その夜の南中高度を基準1とする |
| 薄明 | SQM式（hnsky.org のフィット）。太陽高度 -18°以下で0、0°以上で100 |

月の出没・南中は2分刻みの線形補間で求め、地平線の閾値は `+0.35°`（視差補正込み）。日の出・日の入りは Open-Meteo の daily から取得する。

### 7-2. 雲海期待度（0〜100）

**姫鶴平から見下ろす雲海の期待度**。「谷に霧ができるか(F)」と「姫鶴平が雲の上に出るか(V)」を分けて掛ける。山上の湿度だけで判定すると、姫鶴平自体が霧に包まれる日も高得点になってしまうため。

```
指数_dir = round(100 × F_dir × V_dir × ゲート)
V_dir    = min(V_top_fog_dir, V_summit, V_vis)   ← 適用できた補正だけの最小値
```

**係数・しきい値はすべて試作値であり、現地実績で検証された式ではない。** 表示は「期待度」であって発生確率ではない。

#### 地点

| ID | 役割 | 座標 | 返却標高 |
|---|---|---|---|
| S | 展望地点（姫鶴平） | 33.4666147 / 132.9610114 | 1296m |
| N_C | 北・美川 | 33.63 / 133.00 | 457m |
| N_E | 北・面河 | 33.60 / 133.13 | 659m |
| S_A | 南・梼原 | 33.395 / 132.93 | 530m |
| S_B | 南・津野町 | 33.40 / 133.06 | 562m |

いずれも姫鶴平から見える谷であることを現地確認済み。中津(33.66/132.98)は美川と同一の格子セルに落ち、雲量・降水・気圧面がすべて同値になったため除外した。

**判定基準の高度 H_S = 1400m** は定数で持つ。APIが返す `elevation` は要求座標のDEM由来で、モデルの地形標高でも実測標高でもないため使わない。

#### F（谷ごと・0〜1）

対象時刻は**日の出−1h〜+2h の毎正時**。t0 は前夜の日没時刻（気温は線形補間）。

```
M = clamp01((RH - 70) / 20)                    湿度80%で0.5、90%で1.0
W = 0m/s→0.8 / 0.5〜2.0m/s→1.0 / 5.0m/s以上→0（間は直線）
C = 1 - clamp01(中層雲/100 + 0.5 × 高層雲/100)   t0〜対象時刻の平均
R = clamp01((T(t0) - T(対象時刻)) / 5)

F = M × (0.3 + 0.7C) × (0.35 + 0.40W + 0.25R)
```

- **M・W・C を必要条件として掛け、R だけを加点に残す**。加算式では「湿って風が弱い」だけで0.60が確定してしまい、曇天で冷え込みのない朝も60点を超えたため
- M を湿度基準にしたのは、現地の経験則「麓の予報湿度が80%以上だと出やすい」に合わせるため
- C は「上空の雲による冷却の妨げが少ない度合い」であって放射冷却そのものではない。低層雲を外しているのは、APIの低層雲量では「霧を妨げる先在の雲」と「発生した雲海」を区別できないための実用上の工夫
- C を完全には0にせず0.3を残しているのは、中・高層雲が多くても雲海が出ることがあるため（ゲートではなく強い減点として扱う）

#### V（展望条件・0〜1）

3つのうち**適用できたものだけの最小値**をとる。すべて適用できなければ `--`（指数を出さない）。
**補正を適用しないことと「良好(1.0)」は区別する**。湿潤層を検出できない場合や上端が不明な場合を1.0にはしない。

**V_top_fog** — 谷の霧層の上端が展望地点より低いか。谷地点の気圧面を下から見て `RH ≥ 90%` が連続する層の上端を雲頂とする。

| top_status | 条件 | V_top_fog |
|---|---|---|
| `capped` | 湿潤層の上に乾いた面がある | 範囲の中央値で算出 |
| `straddles_summit` | capped だが推定範囲が H_S を跨ぐ | 同上（表示に「雲頂不確実」） |
| `no_moist_layer` | 地上から連続する湿潤層を検出できない | **null（適用しない）** |
| `saturated_to_top` | 取得範囲の上まで湿潤 | **null** |
| `insufficient_levels` | 有効面が2面未満 | **null** |

**V_summit** — 展望地点が雲の中にないか。**地上から離れた層雲**は上のロジックで捉えられないため別に見る。挟む面は固定せず、**その時刻の `geopotential_height` から毎回選ぶ**。

```
下側 = 展望地点の地上湿度 RH_2m（格子標高 約1296m）
上側 = 展望地点の有効面のうち H_S より上で最も低いもの（通常850hPa ≒ 1412m）
```

| 状態 | 条件 | V_summit |
|---|---|---|
| `summit_in_layer` | 上下とも RH≥90% | 0.00 |
| `below_wet` | 下側のみ RH≥90% | 0.40 |
| `above_wet` | 上側のみ RH≥90% | 0.70 |
| `summit_dry` | 上下とも乾燥 | 1.00 |
| `insufficient` | 上下どちらかが欠ける | **null（1.0にはしない）** |

0／0.4／0.7／1.0 はいずれも仮の係数。**0は「確実に霧」ではなく、濃い霧の可能性を重く見た暫定的な強い減点**。上下の湿度だけでは0.4と0.7の差を物理的に確定できない。

**V_vis** — 展望地点の予報視程。`clamp01((視程 - 1000) / 9000)`。**best_match でのみ提供され、ECMWF は全欠測**。欠測は「視界良好」ではなく「視程補正なし」として記録する。

#### 降水ゲート

**対象時刻の降水量が 0.5mm を超えたら 0**。谷で降っていれば放射霧ではなく、山上で降っていれば展望も利かない。前夜の雨は好条件なので、対象時刻だけで判定する。

#### 集約と表示

```
北 = max(美川, 面河)   南 = max(梼原, 津野町)   総合 = max(北, 南)
```

指数が50以上の谷を数え「4地点中3」のように併記する（広がりの目安）。状態ラベルは次のとおり。

| ラベル | 意味 |
|---|---|
| 雲海期待・視界良好 | F高 × V高 |
| 雲海期待・視界不良 | F高 × V中 |
| **雲海期待・霧の恐れ** | F高 × V低。現地に行っても見えない可能性 |
| 雲海期待・雲頂不明 | 雲頂の推定範囲が H_S を跨ぐ |
| 雲海期待・視界不明 | V_summit を算出できない |
| 雲海の条件なし / 降水あり / 判定不能 | — |

#### 気圧面の取得

**1000 / 975 / 950 / 925 / 900 / 875 / 850 / 825 hPa の8段**。谷でおよそ地表〜1720mにあたり、判定に必要な範囲を覆う。800hPa以上（約1980m〜）は使っていないため取得しない（取得量を22%削減）。

地中の面は `surface_pressure` で除外する。ただし `surface_pressure` 自体も返却標高への補正を受けている可能性があるため、**値そのものも記録**して後から検証できるようにしてある。

ECMWF は 1000/925/850hPa しか返さないため谷では実質2面しか使えず、雲頂をほぼ評価できない。**ただし V_summit は850hPa 1面で成立するので、EC版でも指数は出せる**。

#### 平均版の扱い

**F は両モデルの平均、V は best_match 由来**（ECMWFは視程が全欠測で気圧面も粗いため）。混成である旨は凡例に明記している。

#### モデルごとの精度上の限界

展望地点の判定高度1400mは、谷では 875hPa(約1215m) と 850hPa(約1461m) の間にある。**この帯に雲頂が入る日は上下の判定ができない**（`straddles_summit`）。ご経験上「谷は霧だがカルストも霧」という日はこの帯に集中する可能性があり、そこがこの指数の一番弱い部分になる。

### 7-3. 検証の進め方

`unkai_log.csv` に毎朝2軸で記録する。**谷側(F)と展望側(V)を分けて記録するのが要点**で、どちらを直すべきかが分かる。

```
date,valley_unkai,view,direction,note
  valley_unkai : なし / 一部 / 広範囲 / 確認できない
  view         : 良好 / 一部遮られる / 霧で見えない
```

展望地点が霧で谷を確認できない日は `確認できない` とし、**その日は F の正誤判定に使わず、視界側の検証だけに使う**。

検証ページ `unkai_lab.html` には次を並記してある。

- **式バリアント比較**: 現行加算式 / 案b / **案c（本番）** / 当初案 / **経験則ベースライン**
- **経験則ベースライン**: 湿度80%以上・風3m/s未満・日較差8℃以上・中高層雲40%未満 の ○×。**指数がこの単純判定に勝てなければ、複雑な式を使う意味がない**
- M・R の比較（構造は案cで固定）: 湿度版／露点差の線形版・曲線版／日較差版
- 変数の生値、気圧面プロファイルの生値、V の内訳

`unkai_detail.csv`（67列）と `unkai_levels.csv` は手元専用。将来まとめて統計処理する用。

---

## 8. 気象警報

気象庁の防災情報JSONから、久万高原町・梼原町の発表状況を取得してテーブル上部に表示する。

- 取得先: `bosai/warning/data/r8/{県コード}.json`（**2026-05-29 の新形式**）
- 電文種別（VPWW55=大雨・氾濫／56=土砂災害／57=高潮／58=風／59=波浪／60=雪／61=その他注意報）の配列で、`class20Items[].areaCode` ＋ `kinds[].code/status` から読む
- **コード番号は電文種別ごとに意味が異なる**（例: 20 は VPWW55 では氾濫注意報、VPWW61 では濃霧注意報）。そのため `lowcloud_common.ps1` の `$WarnKindTables` で電文種別×コードの2段引きにしている
- レベルは4段階: 注意報 → 警報 → **危険警報（2026年新設）** → 特別警報

---

## 9. 自動更新と公開

### 9-1. GitHub Actions（主担当）

`.github/workflows/update.yml`。**毎時11分・41分**（`cron: '11,41 * * * *'`）に Linux 上の pwsh で `generate_all.ps1` を実行し、変更があれば commit・push する。

- 毎時0分は GitHub 全体で最混雑のため回避（公式も遅延・ドロップを明記）。**毎時2回にしているのは片方がドロップされても更新が続く保険**
- 1版の生成に失敗しても、成功した版は commit・公開される。**全版失敗・履歴保存失敗に加え、平均版が3時間以上古い場合もワークフローを失敗にする**（メールは既存のGitHub通知設定に従う）（一時的な取得失敗のたびに通知が飛ぶと本当の異常が埋もれるため）
- push 前に `git pull --rebase -X theirs` ＋ 最大3回再試行（ローカルのpushと競合しても自走で回復）
- `concurrency` で多重起動防止、`timeout-minutes: 15` でハング対策
- Public リポジトリのため実行時間は**費用ゼロ**。Open-Meteo は4回/実行 × 48実行 = 約200回/日で、無料枠1万回/日に対し余裕がある
- `workflow_dispatch` で手動実行も可能（Actionsタブ → Run workflow）

### 9-2. ⚠ 既知の問題: GitHub側 cron の発火停止

scheduled cron が理由不明で発火しなくなる現象を確認している（2026-07-01 22:07 UTC 以降、7-02 21:49 UTC 以降の2回）。ワークフロー自体は正常で、GitHub側の障害情報も無かった。**scheduled trigger の既知の不安定挙動**とみられる。

- 対策①: cron を毎時2回に増やしてドロップ耐性を持たせた
- 対策②: ローカルタスクを二重化バックアップとして併用（9-3）
- 定期的に Actions タブで schedule 実行が続いているか確認する。長期間止まっていたら `workflow_dispatch` で手動起動するか、ワークフローファイルに軽微な変更を加えて再push（再登録を促す経験則）

### 9-3. ローカル軽量トリガー（Actionsのバックアップ）

- タスク名 `KarstWeatherWorkflowTrigger`。**毎時20分**に起動する。
- 2026-09-07時点でこのサーバーPCへ登録・有効化済み。旧 `LowCloudForecast` タスクは存在せず、使用しない。
- PCでは予報計算やgit操作を行わない。公開ページの取得日時を確認し、**50分以内に更新済みなら約数秒で終了**する。
- 毎時20分は「更新が必要か確認する時刻」であり、毎回GitHubに新しい更新を作る時刻ではない。直前のActionsで更新済みなら起動を省略する。
- 50分以上古い、または公開日時を取得できない時だけGitHub Actionsへ `workflow_dispatch` を送り、Actions成功後に公開ページの取得日時が更新されたことまで確認する。
- タスク優先度7、PowerShellはBelowNormal、非表示・低権限、重複起動は無視、20分で打ち切る。
- Starlink等の一時切断で失敗した場合は、10分間隔で最大3回再実行する。各HTTPS要求は15秒で打ち切る。
- 実体とログは `C:\ProgramData\KarstWeatherTrigger`。フォルダは現在ユーザー・SYSTEM・管理者だけが変更できるACLにする。
- GitHub認証はWindowsに保存されたGit Credential Managerの資格情報を実行中だけ使用し、ログやファイルには保存しない。
- ログは `C:\ProgramData\KarstWeatherTrigger\weather-trigger.log`。1MBを超えたら直近約2000行へ縮小する。
- タスクは現在ユーザーのログオン中に実行する。宿泊管理で常時ログオンしているサーバーPCを前提とする。

```powershell
# 管理者PowerShellで登録・更新
powershell -ExecutionPolicy Bypass -File .\setup-localtask.ps1

# 状態確認
Get-ScheduledTask -TaskName "KarstWeatherWorkflowTrigger" | Select-Object State
Get-ScheduledTaskInfo -TaskName "KarstWeatherWorkflowTrigger" | Select-Object LastRunTime,LastTaskResult,NextRunTime
Get-Content "C:\ProgramData\KarstWeatherTrigger\weather-trigger.log" -Tail 20

# 一時停止 / 再開
Disable-ScheduledTask -TaskName "KarstWeatherWorkflowTrigger"
Enable-ScheduledTask  -TaskName "KarstWeatherWorkflowTrigger"
```

導入前の実測では、Actions起動から公開確認まで79.5秒、ローカルCPU時間4.875秒、最大メモリ93.7MB。登録タスク経由で14:16 JSTの公開反映を確認した。その後の14:20自動実行は、公開ページが4分前に更新済みだったためGitHub起動を省略し、終了コード0で正常終了した。次回実行時刻が15:20へ進むことも確認済み。

### 9-4. GitHub Pages 公開設定

| 項目 | 値 |
|---|---|
| GitHubユーザー | t-fukuda-ux |
| リポジトリ | karstweather（**Public**） |
| リポジトリURL | https://github.com/t-fukuda-ux/karstweather |
| Pages設定 | Settings → Pages → Source: Deploy from a branch → main / (root) |

---

## 10. 技術的な落とし穴

1. **UTF-8 BOM 必須**（`.ps1`・`.yml` とも）
   Windows PowerShell 5.1 は BOM無しUTF-8 を Shift-JIS として読む。編集したら必ず再付与する。
   ```powershell
   $p="C:\Users\mezuru\Documents\Codex\天気予報\lowcloud.ps1"
   $t=[IO.File]::ReadAllText($p,[Text.UTF8Encoding]::new($false))
   [IO.File]::WriteAllText($p,$t,[Text.UTF8Encoding]::new($true))
   ```
   GitHub Actions 上の pwsh（Linux）は BOM の有無どちらでも読める。

2. **`if` をコマンド引数に直接埋め込むと構文エラー**
   `$x = if (cond) {a} else {b}` は変数への直接代入なら動くが、関数呼び出しの引数や `-f` の引数リスト内にネストすると「`if` が認識されない」になる。事前に変数へ代入してから渡す。

3. **`}` と `elseif` の間に改行を置けない**
   複数行に分けた `if/elseif/else` を式として代入するとパースエラーになる。1行にするか、通常の文に組み替える。

4. **`@{ }` ハッシュリテラル内で `-replace 'X','Y'` を裸で書くと構文エラー**
   カンマがハッシュの区切りと誤認される。`(...)` で囲む: `time = ($t -replace 'T', ' ')`

5. **`GetNewClosure()` は関数を解決できなくなる**
   スクリプトブロックに `GetNewClosure()` を使うとモジュールスコープになり、**dot-source した関数が呼べなくなる**。検証用のスクリプトブロックに値を渡したい場合は、束縛ではなく**引数で渡す**こと。

6. **`Get-Date` はサーバーのローカル時刻を返す**
   Actions のランナーは UTC。JSTでの「現在時刻」が必要な箇所は必ず `Get-JstNow` を使う。素の `Get-Date` を使うと、ローカルPC(JST)では気づかず **Actions 上でのみ9時間ズレる**バグになる。

7. **ファイルの更新日時は CI では使えない**
   Actions ではチェックアウト時刻になるため、「前回いつ生成したか」の判定に使えない。雲海の検証ページは**ページ内に埋め込んだ生成時刻**を読んで判定している。

8. **`exit` と `throw` の使い分け**
   `generate_all.ps1` は各版スクリプトを `&` でプロセス内呼び出しする。呼ばれる側で `exit 1` すると呼び出し元ごと終了するため、致命エラーは `throw` にしてある。

9. **Excelロック**: CSVをExcelで開いているとCSV保存が失敗する（HTMLは生成される）。

10. **GitHub認証**: push時に資格情報マネージャーにPATがキャッシュされる。PATを再発行した場合は github.com の項目を削除してから再入力。

11. **Actions の自動commitとの競合**
    生成物のpushは双方 `git pull --rebase -X theirs` ＋再試行で自動解決する（rebase中の `theirs` は「再適用する自分のコミット側」＝今生成した最新HTMLを優先する向きで正しい）。
    **ソースコードを手動でpushする時**は、必ず `git fetch && git log origin/main --oneline` で Actions側の自動更新コミットが挟まっていないか確認し、rebase してから push する。ローカルタスクを止めていると**数百コミット遅れていることがある**（2026-09-06に800コミット遅れを確認）。生成物が競合したら**手元のコードで再生成して解決**する（手で中身を編集しない）。

12. **⚠ 作業リポジトリをクラウド同期フォルダに置かない**（Google Drive・OneDrive等）
    Drive の同期は git の都合を知らないため、`.git` の中身が壊れる。2026-09-07 に
    `H:\マイドライブ\...\karstweather` で実際に発生し、**Drive が `.git/refs` 以下に
    `desktop.ini` を17個作成して `git fetch` が失敗**した。同期対象外に一時コピーを作って
    回避する必要が生じた。2台から同時に触ればさらに危険。

    **正しい形は、各PCが自分の C: ドライブに clone し、GitHub を唯一の正とすること。**
    ```
    各PC: C:\...\karstweather へ clone → 編集 → commit → push
                        ↕  GitHub（唯一の正）
    ```
    仕様書（SYSTEM.md）もリポジトリ内にあるので、`git pull` すればどのPCでも最新が手に入る。
    クラウド側にファイルのコピーを置くと、どちらが新しいか分からなくなるので置かない。

---

## 11. 障害の記録

過去に起きた障害と対処。**同じ症状が出たらまずここを見る。**

| 発生 | 症状 | 原因 | 対処 |
|---|---|---|---|
| 2026-07-01/02 | 更新が止まる | GitHub の scheduled cron が理由不明で発火停止 | cronを毎時2回に／ローカル二重化（9-2） |
| 2026-07-02 | Actions が2回失敗 | Open-Meteo が30秒でタイムアウト | リトライ（3回・5→15秒）＋タイムアウト60秒に延長 |
| 2026-07-03 | pushが永久に失敗 | `publish.ps1` が pull せず push していた | 実行前に origin/main へ追従するよう修正 |
| 2026-07-05 | 警報が「発表なし」のまま | 気象庁が r8形式へ移行。**旧URLは404にならず古いJSONを返し続けた** | 新URL・新パーサへ移行（8章） |
| **2026-09-02 / 09-06** | **予報ページが空になる** | **Open-Meteo が HTTP 200 のまま中身の無い応答を返した** | 空応答をリトライ＋ガードで前回ページを保持（5-2/5-3） |

### 2026-09-06 の空ページ障害（詳細）

**症状**: 規定版と平均版の毎時テーブル・週間予報が完全に空のまま公開された。EC版のみ正常。

**調査で分かったこと**:

- 過去250回の更新を遡ったところ、空になったのは **09-02 21:59 UTC** と **09-06 21:50 UTC** の2回だけ
- 両方とも **21:50〜21:59 UTC（06:49〜06:59 JST）**、両方とも **best_match のみ**
- 気象庁のモデルは 21 UTC に実行され、その配信データが Open-Meteo に取り込まれるのがこの時間帯にあたる。**モデルデータの入れ替わりの隙間**とみられる
- 1回目は雲海指数の追加（09-06 13:04 UTC）より**4日前**であり、機能追加とは無関係
- エラー応答は HTTP 400 で返るため例外になり、その経路では空ページは公開されない。今回は「200で中身が無い」という別の壊れ方だった

**なぜ空のまま公開されたか**: 例外が出ないため「成功」と判定され、空のHTMLを書き出してコミットしていた。

**対処**: 空応答をリトライ対象にし（数秒後の再取得で復旧する）、それでも空なら例外にして前回のページを残すようにした。

---

## 12. 検証ツールと今後の候補

### 検証ツール

- `unkai_lab.html` … 雲海指数の検証ページ（7-3節）。3時間おきに自動更新、公開URLからも見られる
- `unkai_lab.ps1` … 検証ページを今すぐ最新化する
- `windy_compare.ps1` … Windy(GFS) vs Open-Meteo の2者比較。**Windy Point Forecast APIキーが必要**（無料: https://api.windy.com/keys）。`$env:WINDY_KEY="..."` で渡す

### 今後の候補（未着手）

- **雲海指数の係数調整**（最優先）。実績が溜まったら、経験則ベースラインと比較して M の湿度基準・案cの重み・V_summit の 0/0.4/0.7 を見直す。指数がベースラインに勝てないなら式を単純化する判断もありうる
- 移流型の雲海（放射冷却型以外）を別の判定式として追加する
- 雲海の谷地点の絞り込み（実績との対応で主軸を決める）
- Actions の cron 停止が再発する場合の根本原因の切り分け
- `lowcloud.py`（旧Python版）の削除
- 3版比較用の索引ページ（現状は各URLを個別に開く必要がある）

---

## 付録: クイックリファレンス

```powershell
cd "C:\Users\mezuru\Documents\Codex\天気予報"

# 3版すべて生成＋公開
powershell -ExecutionPolicy Bypass -File ".\publish.ps1"

# 3版すべて生成のみ（git操作なし）
powershell -ExecutionPolicy Bypass -File ".\generate_all.ps1"

# 雲海の検証ページだけ今すぐ更新
powershell -ExecutionPolicy Bypass -File ".\unkai_lab.ps1"

# HTMLを開く
start ".\index.html"        # 平均版（公開と同じ内容）
start ".\unkai_lab.html"    # 雲海の検証ページ

# git状態確認（コードをpushする前に必ず）
git fetch origin; git log origin/main --oneline -5; git status --short

# ローカルタスクの状態確認
Get-ScheduledTask -TaskName "KarstWeatherWorkflowTrigger" | Select-Object State
Get-ScheduledTaskInfo -TaskName "KarstWeatherWorkflowTrigger" | Select-Object LastRunTime, LastTaskResult, NextRunTime

# Windy比較（要APIキー）
$env:WINDY_KEY="..."; .\windy_compare.ps1
```

### よく見るURL

| 用途 | URL |
|---|---|
| 公開ページ | https://t-fukuda-ux.github.io/karstweather/ |
| 雲海の検証 | https://t-fukuda-ux.github.io/karstweather/unkai_lab.html |
| Actions の実行状況 | https://github.com/t-fukuda-ux/karstweather/actions/workflows/update.yml |
| リポジトリ | https://github.com/t-fukuda-ux/karstweather |

## 2026-09-07 追加改善

- `check_forecast.ps1`：index.html内の既存の取得日時をJSTとして読み、3時間以上経過・日時欠落・不正な未来日時を異常にする。画面の更新日時表示は変更しない。
- Actionsは成功した版をcommit・pushしてから鮮度を確認する。生成や履歴保存の失敗も最後に失敗状態へ反映する。ローカルpublishも公開後に同じ鮮度確認を実行する。
- この確認はActionsの実行時に働く。GitHub側でスケジュール自体が停止した場合は検知できず、外部監視は含まない。
- HTML保存に失敗した版はthrowで呼出元へ通知し、成功扱いにしない。
- 雲海表示は「雲海期待・視界良好／視界不良／霧の恐れ／雲頂不明／視界不明」に短縮。指数の計算式は変更しない。
- `forecast_history.ps1`：発表時刻（取得・計算完了時刻、JST）・ソースのリビジョン・モデル・平均版の代替状況・対象日時付きの詳細値と気圧面データをJSONに保存する。モデル初期時刻と区別する。
- 毎回の履歴は `forecast-runs/` に保存（git対象外、ローカルのみ蓄積）。Actionsでは実行終了後に残らない。
- 長期比較用には毎日18時以降、その日の最初の有効な翌朝予報をモデルごとに `forecast-history/YYYY-MM-DD/` に保存し、Actionsとローカルpublishからgitへ反映する。以後は上書きしない。予報が全欠測ならその日の後続実行で再試行する。同時実行時は異なるファイル名で両方を保全し、比較では最も早い issued_at を選ぶ。
- この長期履歴は公開リポジトリとPagesで閲覧可能。現地実績 `unkai_log.csv` は含めず、上書きもしない。
- 回帰テスト：`pwsh -NoProfile -File tests/regression.ps1`（Windowsでは必要に応じ `-ExecutionPolicy Bypass`）。PowerShell 5.1でも実行可能。