"""Project reviewed results for the shared inline chart and source receipts."""
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEST = Path('C:/Users/mezuru/.codex/visualizations/2026/10/09/01a11f19-c16c-7892-a603-2ffa3a3bc8c7')
d = json.loads((HERE/'fog-audit-20261009.json').read_text(encoding='utf-8'))
labels = {'low':'○ 低め・16帯','mid':'◐ 可能性あり・6帯','midrain':'◐ 雨予報あり・5帯','high':'● 高め・2帯'}
rows = [{'forecast':labels[k], 'fogShare':round(g['mean_fog_rate']*100,1),
         'blocks':g['blocks'], 'days':g['days'], 'images':g['obs'], 'fogImages':g['fog_obs']}
        for k,g in d['post_visual_blocks']['evening']['groups'].items()]
source = {
    'label':'事前予報と保存カメラ画像',
    'files':[{'label':x} for x in ['fog_forecast.csv','mezuru_contrast.csv','visual-review-20261009.json','fog-audit-20261009.py']],
    'metricDefinitions':[{'label':'観測時刻の霧割合',
                          'definition':'各時間帯で奥の斜面が見えなかった観測の割合を求め、同じ予報段階の時間帯の間で平均する。予報正解率や発生確率ではない。'}],
    'filters':['前日18:25発表の予報','朝5〜10時・昼11〜15時','終了した時間帯','4枚以上の昼間観測','予報の全正時が保存されている時間帯'],
    'caveats':['目視はCodexによる判定で、予報の集計を見た後の非盲検。現地の人による判定ではない。',
               '高い段階は2日・2時間帯だけで、群の順位や改善効果を確定できない。',
               '夕16〜20時は20時の予報が未保存のため対象外。',
               '履歴は標高指定なし、公開予報は1380m指定。公開された表示そのものの完全な検証ではない。'],
    'evidenceFlow':[{'kind':'source','title':'照合資料','detail':'実装後189枚をすべて目視し、保存された前夜予報から現行の30%、60%、雨1mmの段階を再現した。'},
                    {'kind':'validation','title':'分類の照合','detail':'29時間帯の分類を本番Get-FogLevelと照合し、全件一致した。'}]
}
chart = {'schemaVersion':1,'id':'fog-outlook-calibration','title':'霧予想と観測（9/25〜10/9）',
         'chart':{'type':'bar','x':'forecast','y':'fogShare','yLabel':'観測時刻の霧割合（%）','showXAxisLabel':False,
                  'startAtZero':True,'showValues':True},
         'rows':rows,'source':source,'generatedAt':d['created_at'],'height':320}
chart_receipt = {'schemaVersion':1,'items':[{'id':'fog-outlook-calibration','title':'時間帯の霧予想と観測',
    'queries':[{'id':'blocks-evening','source':source,'rows':rows,
                'columns':[{'field':'forecast','label':'予報段階'},{'field':'fogShare','label':'霧割合（%）'},
                           {'field':'blocks','label':'時間帯数'},{'field':'days','label':'日数'},
                           {'field':'images','label':'観測画像数'},{'field':'fogImages','label':'霧の画像数'}],
                'reportingPeriod':'2026-09-25〜2026-10-09 13:50 JST',
                'methods':[{'language':'calculation','code':'各時間帯の霧割合 = 霧の画像数 / 観測画像数\n段階ごとの霧割合 = 同じ段階の時間帯の霧割合の算術平均 × 100'}]}]}]}
hour_rows=[]
for c,label in [('evening','前夜18:25'),('morning','当日06:25')]:
    s=d['post_visual_results'][c]; t=s['thresholds']['30']
    hour_rows.append({'issue':label,'images':s['n'],'fog':s['fog'],'accuracy':round(t['accuracy']*100,1),
                      'recall':round(t['recall']*100,1),'falseAlarms':t['fp'],'misses':t['fn'],
                      'baseline':round(s['no_fog_baseline']*100,1),'auc':round(s['metrics']['cl_avg']['auc'],3),
                      'withinDayAuc':round(s['metrics']['cl_avg']['within_day_auc'],3)})
extra_source={
    'label':'毎時予報の照合と画像判定',
    'files':[{'label':x} for x in ['fog_forecast.csv','visual-review-20261009.json','fog-audit-20261009.py',
                                'capture-mezuru.ps1','save-fog-forecast.ps1','lowcloud_common.ps1']],
    'metricDefinitions':[{'label':'便宜的な毎時正解率',
                         'definition':'平均版低層雲30%以上を霧ありとして、HH:50の画像を翌正時の予報と比較した霧あり・なしの一致割合。公開の時間帯表示の正解率ではない。'}],
    'filters':['霧ありはD+B、霧なしはH+C','前夜は189時刻、当日朝は発表後の176時刻'],
    'caveats':['対象は15日だけ。朝と前夜は対象時刻が異なるため更新の良し悪しを直接比較しない。',
               '非盲検のAI目視で、薄明や分類境界に誤差がある。',
               '将来の別期間で検証していない改善候補を、精度が向上する確定策とは扱わない。'],
    'evidenceFlow':[{'kind':'validation','title':'AUC計算','detail':'前夜・朝のランク法によるAUCが正例と負例の全組比較と一致した。'},
                    {'kind':'result','title':'同日内の識別','detail':'当日朝の同日内AUCは低層雲平均版0.660、規定版地上湿度0.805。湿度の組み合わせは今後の検証候補。'},
                    {'kind':'result','title':'観測ラベルの問題','detail':'近景だけを使う本番CSVラベルとは別に遠景の固定基準を評価した。固定基準と今回の目視の霧あり・なし不一致は6/189、うち5件が05:50か17:50。'},
                    {'kind':'result','title':'記録範囲','detail':'予報は05〜19時の未来時刻だけを保存するため、20時の夕予報と当日06:25以前を含む朝全体を再現できない。'}]
}
extra_receipt={'schemaVersion':1,'items':[{'id':'hourly-fog-skill','title':'毎時の霧の識別と改善候補',
    'queries':[{'id':'hourly-comparison','source':extra_source,'rows':hour_rows,
                'columns':[{'field':k,'label':label} for k,label in [('issue','発表'),('images','時刻数'),('fog','霧の時刻数'),
                  ('accuracy','正解率（%）'),('recall','霧の捕捉（%）'),('falseAlarms','空振り'),('misses','見逃し'),
                  ('baseline','常に霧なし（%）'),('auc','AUC'),('withinDayAuc','同日内AUC')]],
                'reportingPeriod':'2026-09-25〜2026-10-09 13:50 JST',
                'methods':[{'language':'python','code':(HERE/'fog-audit-20261009.py').read_text(encoding='utf-8')}]}]}]}
for filename,payload in [('fog-audit-chart.json',chart),('fog-audit-chart-sources.json',chart_receipt),('fog-audit-sources.json',extra_receipt)]:
    (DEST/filename).write_text(json.dumps(payload,ensure_ascii=False,indent=2),encoding='utf-8')
print('Wrote 3 reviewed visualization inputs')
