# Design Concept
Date: 2026-04-08

## Instruction
この文書は設計を決めるための単一の指示書である。
内容は `Concept`、`API`、`Rules` の順で定める。

- `Concept`: このプロジェクトの設計方針を書く
- `API`: その方針を外から見える操作として定める
- `Rules`: その方針と API を支える制約を、Perl のコメント文として書く

`Concept` には、何を大事にし、どのように作るかを書く。
コードを作るときは、`Rules` を `package` 宣言の直下に必ず置く。

## Concept
- `Spool` は、親プロセスが巨大な配列を抱えたまま処理を進めないために、行データをファイルへ退避して別プロセスへ渡す仕組みである
- 処理は 3 段階に分ける。write では親プロセスが 1 行ずつ spool へ追加し、confirm では親とは別の fork プロセスが全件を読み込んで返し方を決めて `items/` を作り、read では確定後の item を `spool_id` と `index` で 1 件ずつ取り出す
- 親プロセスは write だけを担当し、全件読み込みや item ファイル生成は必ず親とは別の fork プロセスで行う
- confirm の入力となる行データは、`TableTools::validate` を通せるのと同等の前提を満たしていなければならない。つまり各行は同じキー集合を持ち、`undef` は空文字へ正規化され、必要な並び順は呼び出し側が事前に整えておく
- confirm の返し方は 3 つある。`lines` は 1 行を 1 件として返し、`records` は連続する同一キー行を 1 件として返し、`group` は階層構造として返す
- `group` の構造化はできる限り `TableTools` を利用して行い、`Spool` 自体の責務は退避と確定に寄せる
- プロセス間で受け渡すものはオブジェクトではなく `spool_id` 文字列だけにし、書き込み中の中間状態と確定後の公開状態を分けて、確定失敗時に壊れた `items/` を見せないようにする

## Terms
- `spool_id`: spool を識別する文字列。`[A-Za-z0-9]+` のみを許可する
- `spool`: `/tmp/spool/<spool_id>/` に作られる 1 件分の退避領域
- write フェーズ: 親プロセスが `open()` / `meta()` / `add()` / `close()` で行データを書き出す段階
- confirm フェーズ: 別プロセスが `lines()` / `records()` / `group()` で取り出し単位を確定する段階
- read フェーズ: 確定済み spool を `count()` / `get()` / `remove()` で扱う段階
- `rows.do`: write フェーズで蓄積する全行データ。未確定 spool の実体
- `meta.do`: spool のメタ情報。`close()` 後は部分形、confirm 後は完全形を持つ
- `items/`: confirm 後の公開データ置き場。`count()` と `get()` の対象
- partial meta: `close()` 直後の `meta.do`。`order` / `attrs` など confirm に必要な情報だけを持つ
- complete meta: confirm 後の `meta.do`。`mode` / `count` とモード固有情報を加えた完全形
- `lines` モード: 1 行を 1 item として確定する形
- `records` モード: 同じキー値を持つ連続行を 1 item にまとめる形
- `group` モード: `TableTools::validate` / `TableTools::group` / `TableTools::detach` に委譲して階層 item を作る形
- confirmed spool: `items/` が存在し、`rows.do` が削除済みの状態
- unconfirmed spool: `rows.do` が存在し、まだ `items/` を公開していない状態

## API
記号は次のとおり。

- `$spool_id`: spool 識別子文字列
- `$writer`: write フェーズで使う書き込み用 `Spool` インスタンス
- `$meta`: メタ情報の hashref
- `$row`: 1 行分の hashref
- `@key_cols`: `records()` で使うキー列名の並び
- `@groups`: `group()` で使うキー列配列リファレンスの並び
- `$index`: item の 0 始まり添字

| API | 役割 | 入力 | 出力 |
|---|---|---|---|
| `Spool->open($spool_id)` | write 開始 | `$spool_id` | `$writer` |
| `$writer->meta($meta)` | write メタ設定 | `$meta` | なし |
| `$writer->add($row)` | write 行追加 | `$row` | なし |
| `$writer->close()` | write 終了 | なし | なし |
| `Spool::lines($spool_id)` | 行単位で確定 | `$spool_id` | `$count` |
| `Spool::records($spool_id, @key_cols)` | 連続キー単位で確定 | `$spool_id`, `@key_cols` | `$count` |
| `Spool::group($spool_id, @groups)` | 階層グループで確定 | `$spool_id`, `@groups` | `$count` |
| `Spool::count($spool_id)` | 件数取得 | `$spool_id` | `$count` |
| `Spool::get($spool_id, $index)` | item 取得 | `$spool_id`, `$index` | `$item` |
| `Spool::remove($spool_id)` | spool 削除 | `$spool_id` | なし |

## Rules
```perl
# Terms:
# spool_id は spool を識別する文字列で、[A-Za-z0-9]+ のみを許可する
# spool は /tmp/spool/<spool_id>/ に作られる 1 件分の退避領域
# write フェーズは親プロセスが open() / meta() / add() / close() を行う段階
# confirm フェーズは親とは別の fork プロセスが lines() / records() / group() を行う段階
# read フェーズは count() / get() / remove() で確定済み item を扱う段階
# rows.do は write フェーズで蓄積する全行データ
# meta.do は close() 後は部分形、confirm 後は完全形を持つ
# items/ は confirm 後の公開データ置き場
# lines モードは 1 行を 1 item として確定する
# records モードは同じキー値を持つ連続行を 1 item にまとめて確定する
# group モードは TableTools::validate / TableTools::group / TableTools::detach に委譲して階層 item を作る
#
# Rules:
# 親プロセスは write だけを担当し、全件読み込みや item ファイル生成をしてはいけない
# confirm は必ず親とは別の fork プロセスで行う
# プロセス間で受け渡すものはオブジェクトではなく spool_id 文字列だけにする
# confirm の入力となる rows は TableTools::validate を通せるのと同等の前提を満たしていなければならない
# 各 row は同じキー集合を持たなければならない
# row の undef 値は confirm 前に空文字へ正規化されていなければならない
# records() と group() に必要な並び順は呼び出し側が事前に整えておかなければならない
# records() は入力順をそのまま走査し、非連続な同一キーの再出現をエラーにする
# group() はできる限り TableTools を利用して構造化し、Spool 自体は退避と確定の責務に寄せる
# write 中の中間状態と confirm 後の公開状態は分けて扱う
# confirm 失敗時に壊れた items/ を公開してはいけない
# read フェーズの参照単位は spool_id と index に固定する
# confirm の 3 関数（lines/records/group）は全て fork した子プロセス内で実行する
# 親プロセスは fork 後に全件読み込みや item 生成を行ってはいけない
# 親プロセスは waitpid で子の正常終了を確認してから結果を参照する
# 子プロセスが正常終了しなかった場合は confirm 失敗として扱う
```
