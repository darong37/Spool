# Design Concept
Date: 2026-04-08

## Concept
- `Spool` は、親プロセスが巨大な配列を抱えたまま処理を進めないために、行データをファイルへ退避して別プロセスへ渡す仕組みである
- 処理は 3 段階に分ける。write では親プロセスが 1 行ずつ spool へ追加し、confirm では親とは別の fork プロセスが全件を読み込んで返し方を決め、結果が 1 件以上あるときだけ `items/` を作り、read では確定後の item を `spool_id` と `index` で 1 件ずつ取り出す
- 親プロセスは write だけを担当し、全件読み込みや item ファイル生成は必ず親とは別の fork プロセスで行う
- confirm の入力となる行データは、`TableTools::validate` を通せるのと同等の前提を満たしていなければならない。つまり各行は同じキー集合を持ち、`undef` は空文字へ正規化され、必要な並び順は呼び出し側が事前に整えておく
- confirm の返し方は 3 つある。`lines` は 1 行を 1 件として返し、`records` は連続する同一キー行を 1 件として返し、`grouping` は階層構造として返す
- `records` と `grouping` はいずれも内部で `TableTools::validate` / `group` / `detach` を利用して処理する。`Spool` 自体の責務は退避と確定に寄せる
- プロセス間で受け渡すものはオブジェクトではなく `spool_id` 文字列だけにし、書き込み中の中間状態と確定後の公開状態を分けて、確定失敗時に壊れた `items/` を見せないようにする

## Terms
- `spool_id`: spool を識別する文字列。`[A-Za-z0-9]+` のみを許可する
- `spool`: `/tmp/spool/<spool_id>/` に作られる 1 件分の退避領域
- write フェーズ: 親プロセスが `open()` / `meta()` / `add()` / `close()` で行データを書き出す段階
- confirm フェーズ: 別プロセスが `lines()` / `records()` / `grouping()` で取り出し単位を確定する段階
- read フェーズ: 確定済み spool を `count()` / `get()` / `remove()` で扱う段階
- `rows.do`: write フェーズで蓄積する全行データ。未確定 spool の実体
- `meta.do`: spool のメタ情報。`open()` 後から存在し、write フェーズでは作業用メタ、read フェーズでは確定後メタとして使う
- `items/`: confirm 後の公開データ置き場。`count()` と `get()` の対象
- work meta: write フェーズ中の `meta.do`。`order` / `attrs` / `count` など mode 確定に必要な情報を持つ
- complete meta: confirm 後の `meta.do`。`count` とモード固有情報を持つ。`mode` 自体は `spool.do` に持つ
- `lines` モード: 1 行を 1 item として確定する形
- `records` モード: 同じキー値を持つ連続行を 1 item にまとめる形
- `grouping` モード: `TableTools::validate` / `TableTools::group` / `TableTools::detach` に委譲して階層 item を作る形
- confirmed spool: `spool.do` が存在し、`ready => 1` になっている状態
- unconfirmed spool: `spool.do` が存在し、`ready => 0` の状態

## API
記号は次のとおり。

- `$spool_id`: spool 識別子文字列
- `$writer`: write フェーズで使う書き込み用 `Spool` インスタンス
- `$meta`: メタ情報の hashref
- `$row`: 1 行分の hashref
- `@key_cols`: `records()` で使うキー列名の並び
- `@groups`: `grouping()` で使うキー列配列リファレンスの並び
- `$index`: item の 0 始まり添字

| API | 役割 | 入力 | 出力 |
|---|---|---|---|
| `Spool->open($spool_id)` | write 開始 | `$spool_id` | `$writer` |
| `$writer->meta($meta)` | write メタ設定 | `$meta` | なし |
| `$writer->add($row)` | write 行追加 | `$row` | なし |
| `$writer->close()` | write 終了 | なし | なし |
| `Spool::lines($spool_id)` | 行単位で確定 | `$spool_id` | `$count` |
| `Spool::records($spool_id, @key_cols)` | 連続キー単位で確定 | `$spool_id`, `@key_cols` | `$count` |
| `Spool::grouping($spool_id, @groups)` | 階層グループで確定 | `$spool_id`, `@groups` | `$count` |
| `Spool::count($spool_id)` | 件数取得 | `$spool_id` | `$count` |
| `Spool::get($spool_id, $index)` | item 取得 | `$spool_id`, `$index` | `$item` |
| `Spool::remove($spool_id)` | spool 削除 | `$spool_id` | なし |

