# Spool テスト仕様書

## テストファイル

`test/spool.t`

## テストケース一覧

### open()

`open()` は spool ディレクトリ・`rows.do`・`spool.do`・`meta.do` を作成する。

| # | テスト名 | 確認内容 |
|---|---|---|
| 1 | open creates directory and rows.do | spool ディレクトリが作成される / `rows.do` が存在する / `spool.do` が作成される / `meta.do` が作成される |
| 2 | open() writes initial spool.do | `spool.do` に `ready=0` / `empty=undef` / `mode=undef` が書かれている / `meta.do` は空ハッシュ `{}` である |
| 3 | open dies on invalid spool_id | スラッシュ・スペース・ハイフン・アンダースコア・ドット・日本語・空文字列など `[A-Za-z0-9]+` に合致しない spool_id で die |
| 4 | open dies if spool already exists | 同じ spool_id で2回 open すると die |

### add() / close()

`meta.do` は `open()` 時に空ハッシュとして作られ、`close()` で部分形（work meta）として上書きされ、モード確定後に完全形（complete meta）へ再度上書きされる（3段階）。

| # | テスト名 | 確認内容 |
|---|---|---|
| 5 | add and close write rows.do correctly | close 後も `rows.do` が存在する / 行数が正しい / 各行の値が正しい |
| 6 | close() without meta() writes partial meta.do with count only | `meta()` なしで `close()` すると `meta.do` に `count`（行数）のみが含まれる（`order`・`attrs`・`mode` なし） |
| 7 | close() with meta() writes partial meta.do | `meta()` ありで `close()` すると `meta.do` に `order` / `attrs` / `count`（行数）が入り、`mode` はまだ存在しない |
| 8 | meta() stores order and attrs in meta.do after close | close 後の `meta.do` に `order` / `attrs` が保存される |
| 9 | meta() can be called after add() | `add()` 後に `meta()` を呼んでも die せず、`close()` 後の `meta.do` に `order` が反映される |
| 10 | meta() keeps the last hashref passed | `meta()` を複数回呼んだ場合、最後に渡した hashref の `order` / `attrs` が `close()` 後の `meta.do` に反映される |
| 11 | meta() dies unless meta is hashref | `meta()` に hashref 以外を渡すと die |
| 12 | meta() dies unless attrs is hashref | `meta()` に `attrs` を指定する場合、hashref 以外を渡すと die |
| 13 | meta() dies unless order is arrayref | `meta()` に `order` を指定する場合、arrayref 以外を渡すと die |
| 14 | close() warns on 0 rows | `add()` を一度も呼ばずに `close()` すると warn が出る（die はしない）。`meta.do` の `count` は `0` |
| 15 | close() writes row count to partial meta.do | `add()` を N 回呼んで `close()` すると `meta.do` の `count` が N になる |

### Spool::lines()

モード確定は別プロセスの関数 API（`Spool::lines($spool_id)`）で行う。オブジェクトは不要。

| # | テスト名 | 確認内容 |
|---|---|---|
| 16 | mode confirm works with spool_id only (no object needed) | open/add/close したオブジェクトを捨て、spool_id 文字列だけで `lines()` が確定できる |
| 17 | lines() creates items/ and removes rows.do | `items/` ディレクトリが作成される / 各 item ファイルが存在する / `rows.do` が削除される / item の内容が正しい |
| 18 | lines() overwrites partial meta.do with complete form (meta なし) | `meta()` なしで close() した spool に `lines()` を呼んだとき、`meta.do` に `mode` が含まれない / `count` が正しい / `order`・`attrs` は含まれない。`spool.do` が `ready=1` / `empty=0` / `mode=lines` になる |
| 19 | lines() overwrites partial meta.do with complete form (meta あり) | close() 後の部分形（`count` あり・`mode` なし）を確認してから `lines()` を呼び、`meta.do` に `mode` が含まれず `count` / `order` / `attrs` が保持された完全形へ上書きされる。`spool.do` が `ready=1` / `empty=0` / `mode=lines` になる |
| 20 | lines() dies if already confirmed | 確定済み spool（`spool.do->{ready}=1`）に再度 `lines()` / `records()` / `grouping()` のいずれを呼んでも die |
| 21 | lines() dies on invalid spool data | 不正な `rows.do`（`]` なし）に対して die |
| 22 | records() dies on invalid spool data | 不正な `rows.do`（`]` なし）に対して die |
| 23 | grouping() dies on invalid spool data | 不正な `rows.do`（`]` なし）に対して die |

### Spool::count()

| # | テスト名 | 確認内容 |
|---|---|---|
| 24 | count() returns item count after lines() | `lines()` 確定後に正しい行数を返す |
| 25 | count() returns group count after records() | `records()` 確定後に正しいグループ数を返す |
| 26 | count() returns top-level group count after grouping() | `grouping()` 確定後に正しい最上位グループ数を返す |
| 27 | count() returns 0 for empty spool (no items/) | 0件確定後（`spool.do->{empty}=1`）は `items/` が存在しなくても `count()` が `0` を返す |
| 28 | count() dies if not yet confirmed | 未確定 spool（`spool.do->{ready}=0`）に対して `spool not ready` で die |

### Spool::get()

| # | テスト名 | 確認内容 |
|---|---|---|
| 29 | get() returns correct item after lines() | `lines()` 確定後、インデックス 0・1 で正しい行データを返す |
| 30 | get() returns correct group after records() | `records()` 確定後、インデックスで正しいグループ（配列リファレンス）を返す。キー列は各行に含まれる |
| 31 | get() returns correct group after grouping() | `grouping()` 確定後、インデックスで正しい最上位グループ（ハッシュリファレンス）を返す |
| 32 | get() dies on out-of-range index | count 以上のインデックスで die / 負のインデックスで die |
| 33 | get() dies if not confirmed | 未確定 spool（`spool.do->{ready}=0`）に対して `spool not ready` で die |

### Spool::remove()

| # | テスト名 | 確認内容 |
|---|---|---|
| 34 | remove() deletes unconfirmed spool directory | 未確定 spool（close 済み・`lines()` 前）のディレクトリも削除できる |
| 35 | remove() deletes spool directory | 確定済み spool のディレクトリが削除される |

### Spool::records()

Spool はソートを行わず入力順をそのまま走査する。連続する同一キーをグループ化し、一度終わったキーが再出現したら die する。

| # | テスト名 | 確認内容 |
|---|---|---|
| 36 | records() confirms by spool_id only (no object) | open/add/close したオブジェクトを捨て、spool_id 文字列だけで `records()` が確定できる |
| 37 | records() creates items/ and removes rows.do | `items/` ディレクトリが作成される / 各 item ファイルが存在する / `rows.do` が削除される |
| 38 | records() groups consecutive same-key rows | 同一キーの連続行がグループ化される / キーが変わると新グループになる |
| 39 | records() overwrites partial meta.do with complete form (meta なし) | `meta()` なしで close() した spool に `records()` を呼んだとき、`meta.do` に `mode` が含まれない / `count` / `key_cols` が正しい / `order`・`attrs` は含まれない。`spool.do` が `ready=1` / `empty=0` / `mode=records` になる |
| 40 | records() overwrites partial meta.do with complete form (meta あり) | `records()` 後の `meta.do` に `mode` が含まれない / `count` / `key_cols` / `order` / `attrs` が保持される。`spool.do` が `ready=1` / `mode=records` になる |
| 41 | records() preserves input order | b.txt → a.txt の順で入力した場合、グループの順序・各グループ内の行順が入力順のままになる（Spool は並べ替えない） |
| 42 | records() dies if already confirmed | 確定済み spool（`spool.do->{ready}=1`）に再度 `records()` すると die / 同じく `grouping()` しても die |
| 43 | records() dies on out-of-order key | 一度終わったキー値が再出現したら die（連続していない再出現のみ） |
| 44 | records() dies if key column missing from row | キー列が行に存在しない場合 die |
| 45 | records() supports multi-column key | 複数列キーで正しくグループ化される |

### Spool::grouping()

`grouping()` に必須なのは `order` のみ。`attrs` は必須条件ではない。
`order` は `TableTools::validate` に渡す完全な列定義であり、全行のすべての列を過不足なく列挙しなければならない。
`order` に含まれない列を持つ行を追加すると `grouping()` 確定時に die する。

| # | テスト名 | 確認内容 |
|---|---|---|
| 46 | grouping() confirms by spool_id only (no object) | open/add/close したオブジェクトを捨て、spool_id 文字列だけで `grouping()` が確定できる |
| 47 | grouping() creates items/ and removes rows.do | `items/` ディレクトリが作成される / 各 item ファイルが存在する / `rows.do` が削除される |
| 48 | grouping() preserves input order | b.txt → a.txt の順で入力した場合、グループの順序・各グループ内の子の順序が入力順のままになる（Spool は並べ替えない） |
| 49 | grouping() single-level produces grouped items | キー列が外側に出る / キー列以外の全列が `'@'` 配下に入る / キー列が子から除去される（行の列は `order` と完全一致） |
| 50 | grouping() dies if row has column not in order | `order` に含まれない列を持つ行がある場合 die（validate の column count mismatch / unexpected column） |
| 51 | grouping() confirms with 0 items on empty spool | rows が 0 件の場合、0 件で確定できる。`items/` は作成されない。`spool.do` が `ready=1` / `empty=1` / `mode=grouping` になる |
| 52 | grouping() works with order only (no attrs in meta) | meta に `order` はあるが `attrs` がない場合でも `grouping()` が正常に動作する |
| 53 | grouping() dies if order not in meta | meta に `order` がない場合 die（`meta()` なし・`meta()` で `attrs` のみ指定した場合も同様に die） |
| 54 | grouping() dies on out-of-order key | 一度終わったキー値が再出現したら die |
| 55 | grouping() dies if key column missing from row | キー列が行に存在しない場合 die |
| 56 | grouping() overwrites partial meta.do with complete form | close() 後の部分形（`mode`・`groups` なし）を確認してから `grouping()` を呼び、`meta.do` に `mode` が含まれず `count` / `groups` が追加されつつ `order` / `attrs` が保持された完全形へ上書きされる。`spool.do` が `ready=1` / `empty=0` / `mode=grouping` になる |
| 57 | all mode functions die if already confirmed (group mode) | grouping() 確定済み spool に対して `lines()` / `records()` / `grouping()` のいずれを呼んでも die |
| 58 | grouping() multi-level with single col per level | 二段グループが正しく構築される / 中間段から外側のキー列が除去される |
| 59 | grouping() multi-level with multi-col first level | 複数列キーの最上位段 + 一列キーの第2段が正しく構築される |

### stale items_tmp/ のクリーンアップ

| # | テスト名 | 確認内容 |
|---|---|---|
| 60 | lines() cleans up stale items_tmp/ from previous failed run | 前回の失敗で `items_tmp/` が残っていても `lines()` が正常に確定できる / 完了後 `items_tmp/` が削除される |
| 61 | records() cleans up stale items_tmp/ from previous failed run | 前回の失敗で `items_tmp/` が残っていても `records()` が正常に確定できる / 完了後 `items_tmp/` が削除される |
| 62 | grouping() cleans up stale items_tmp/ from previous failed run | 前回の失敗で `items_tmp/` が残っていても `grouping()` が正常に確定できる / 完了後 `items_tmp/` が削除される |

### UTF-8 可読性

ファイルへ書かれた内容が Perl として再読込できるだけでなく、人間の目で UTF-8 文字列として読めることも確認する。
特に `\x{...}` のような 16 進エスケープへ退避されず、実際の日本語文字がファイル本文に現れることを確認する。

| # | テスト名 | 確認内容 |
|---|---|---|
| 63 | rows.do keeps UTF-8 text human-readable | `rows.do` に書かれた日本語文字列がファイル本文でそのまま読める |
| 64 | meta.do keeps UTF-8 text human-readable | `meta.do` に書かれた日本語の列名・メタ値がファイル本文でそのまま読める |
| 65 | lines() item file keeps UTF-8 text human-readable | `lines()` 後の item ファイルに日本語文字列がそのまま読める |
| 66 | records() item file keeps UTF-8 text human-readable | `records()` 後の item ファイルに日本語文字列がそのまま読める |
| 67 | grouping() item file keeps UTF-8 text human-readable | `grouping()` 後の item ファイルに日本語文字列がそのまま読める |
