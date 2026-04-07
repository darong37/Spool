# Spool テスト仕様書

## テストファイル

`test/spool.t`

## テストケース一覧

### open()

| # | テスト名 | 確認内容 |
|---|---|---|
| 1 | open creates directory and rows.do | spool ディレクトリが作成される / rows.do が存在する / meta.do はまだ存在しない |
| 2 | open dies on invalid spool_id | スラッシュ・スペース・ハイフン・アンダースコア・ドット・日本語・空文字列など `[A-Za-z0-9]+` に合致しない spool_id で die |
| 3 | open dies if spool already exists | 同じ spool_id で2回 open すると die |

### add() / close()

meta.do は close() で部分形として書かれ、モード確定後に完全形へ上書きされる（2段階）。

| # | テスト名 | 確認内容 |
|---|---|---|
| 4 | add and close write rows.do correctly | close 後も rows.do が存在する / 行数が正しい / 各行の値が正しい |
| 5 | close() without meta() writes empty meta.do | meta() なしで close() すると meta.do が `{}` （空ハッシュ）で作られる |
| 6 | close() with meta() writes partial meta.do | meta() ありで close() すると meta.do に order / attrs のみが入り、count / mode はまだ存在しない |

### meta()

| # | テスト名 | 確認内容 |
|---|---|---|
| 7 | meta() stores order and attrs in meta.do after close | close 後の meta.do に order / attrs が保存される |
| 8 | meta() dies if called after add() | add() 後に meta() を呼ぶと die |

### Spool::lines()

モード確定は別プロセスの関数 API（`Spool::lines($spool_id)`）で行う。オブジェクトは不要。

| # | テスト名 | 確認内容 |
|---|---|---|
| 9 | lines() confirms by spool_id only (no object) | open/add/close したオブジェクトを捨て、spool_id 文字列だけで lines() が確定できる |
| 10 | lines() creates items/ and removes rows.do | items/ ディレクトリが作成される / 各 item ファイルが存在する / rows.do が削除される / item の内容が正しい |
| 11 | lines() overwrites partial meta.do with complete form (meta なし) | meta() なしで close() した spool に lines() を呼び、meta.do が mode=lines / count のみの完全形になることを確認する（order/attrs は含まれない） |
| 12 | lines() overwrites partial meta.do with complete form (meta あり) | close() 後の部分形（count/mode なし）を確認してから lines() を呼び、meta.do に mode=lines / count が追加されつつ元の order/attrs が保持された完全形へ上書きされることを確認する |
| 13 | lines() dies if already confirmed | 確定済み spool（items/ あり）に再度 lines() / records() / group() のいずれを呼んでも die |
| 14 | lines() dies on invalid spool data | 不正な rows.do（`]` なし）に対して die |
| 14a | records() dies on invalid spool data | 不正な rows.do（`]` なし）に対して die |
| 14b | group() dies on invalid spool data | 不正な rows.do（`]` なし）に対して die |

### Spool::count()

| # | テスト名 | 確認内容 |
|---|---|---|
| 15 | count() returns item count after lines() | lines() 確定後に正しい行数を返す |
| 16 | count() returns group count after records() | records() 確定後に正しいグループ数を返す |
| 17 | count() returns top-level group count after group() | group() 確定後に正しい最上位グループ数を返す |
| 18 | count() dies if not yet confirmed | 未確定 spool（rows.do あり）に対して die |

### Spool::get()

| # | テスト名 | 確認内容 |
|---|---|---|
| 19 | get() returns correct item after lines() | lines() 確定後、インデックス 0・1 で正しい行データを返す |
| 20 | get() returns correct group after records() | records() 確定後、インデックスで正しいグループ（配列リファレンス）を返す |
| 21 | get() returns correct group after group() | group() 確定後、インデックスで正しい最上位グループ（ハッシュリファレンス）を返す |
| 22 | get() dies on out-of-range index | count 以上のインデックスで die / 負のインデックスで die |
| 23 | get() dies if not confirmed | 未確定 spool（rows.do あり）に対して die |

### Spool::remove()

| # | テスト名 | 確認内容 |
|---|---|---|
| 24 | remove() deletes confirmed spool directory | 確定済み spool のディレクトリが削除される |
| 25 | remove() deletes unconfirmed spool directory | 未確定 spool（close 済み・lines() 前）のディレクトリも削除できる |

### Spool::records()

Spool はソートを行わず入力順をそのまま走査する。連続する同一キーをグループ化し、一度終わったキーが再出現したら die する。

| # | テスト名 | 確認内容 |
|---|---|---|
| 26 | records() confirms by spool_id only (no object) | open/add/close したオブジェクトを捨て、spool_id 文字列だけで records() が確定できる |
| 27 | records() creates items/ and removes rows.do | items/ ディレクトリが作成される / 各 item ファイルが存在する / rows.do が削除される |
| 28 | records() groups consecutive same-key rows | 同一キーの連続行がグループ化される / キーが変わると新グループになる |
| 29 | records() preserves input order | b.txt → a.txt の順で入力した場合、グループの順序・各グループ内の行順が入力順のままになる（Spool は並べ替えない） |
| 30 | records() overwrites partial meta.do with complete form (meta なし) | meta() なしで close() した spool に records() を呼んだとき、meta.do が mode=records / count / key_cols のみの完全形になる（order/attrs は含まれない） |
| 31 | records() overwrites partial meta.do with complete form (meta あり) | close() 後の部分形（mode/key_cols なし）を確認してから records() を呼び、meta.do に mode=records / count / key_cols が追加されつつ元の order/attrs が保持された完全形へ上書きされることを確認する |
| 32 | records() dies if already confirmed | 確定済み spool（items/ あり）に再度 records() すると die / 同じく group() しても die |
| 33 | records() dies on out-of-order key | 一度終わったキー値が再出現したら die（連続していない再出現のみ） |
| 34 | records() dies if key column missing from row | キー列が行に存在しない場合 die |
| 35 | records() supports multi-column key | 複数列キーで正しくグループ化される |

### Spool::group()

`group()` に必須なのは `order` のみ。`attrs` は必須条件ではない。`order` は `'@'` 配下へ落とす列順を決めるために必要。

| # | テスト名 | 確認内容 |
|---|---|---|
| 36 | group() confirms by spool_id only (no object) | open/add/close したオブジェクトを捨て、spool_id 文字列だけで group() が確定できる |
| 37 | group() creates items/ and removes rows.do | items/ ディレクトリが作成される / 各 item ファイルが存在する / rows.do が削除される |
| 38 | group() single-level produces grouped items | キー列が外側に出る / 残り列が `'@'` 配下に order で指定した列順で入る / キー列が子から除去される |
| 39 | group() preserves input order | b.txt → a.txt の順で入力した場合、グループの順序・各グループ内の子の順序が入力順のままになる（Spool は並べ替えない） |
| 40 | group() works with order only (no attrs in meta) | meta に order はあるが attrs がない場合でも group() が正常に動作する |
| 41 | group() dies if order not in meta | meta に order がない場合 die（meta() なし・meta() で attrs のみ指定した場合も同様に die） |
| 42 | group() dies if already confirmed | 確定済み spool（items/ あり）に再度 lines() / records() / group() のいずれを呼んでも die |
| 43 | group() dies on out-of-order key | 一度終わったキー値が再出現したら die |
| 43a | group() dies if key column missing from row | キー列が行に存在しない場合 die |
| 44 | group() overwrites partial meta.do with complete form (meta あり) | close() 後の部分形（mode/groups なし）を確認してから group() を呼び、meta.do に mode=group / count / groups が追加されつつ元の order/attrs が保持された完全形へ上書きされることを確認する（order・attrs が完全形 meta.do に残っていることを検証する） |
| 45 | group() multi-level with single col per level | 二段グループが正しく構築される / 中間段から外側のキー列が除去される |
| 46 | group() multi-level with multi-col first level | 複数列キーの最上位段 + 一列キーの第2段が正しく構築される |
