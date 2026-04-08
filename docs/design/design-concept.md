# Spool Concept
Date: 2026-04-06

## Concept
`Spool` は、親プロセスのメモリを汚さずに行データを後続処理へ渡すための仕組みである。
親は結果を配列で持たず、`Spool` インスタンスへ 1 行ずつ書く。
その後で `fork` した子プロセスが全件を読み込み、`lines` / `records` / `group` の形へ変換して保存する。
重い全件読み込みは子だけで行い、子が終わればそのメモリも消える。
取り出しは `spool_id` と `index` で行う。

## Why Instance
書き込み側は、open したファイルハンドラと書き込み中の状態を持つのでインスタンス API にする。
親は `Spool` インスタンスを使って 1 行ずつ追加し、`close()` したら役目を終える。
プロセス間で渡すのはオブジェクトではなく `spool_id` だけにする。

## Process Model
- 親プロセス: `open()` / `meta()` / `add()` / `close()`
- 子プロセス: `lines()` / `records()` / `group()`
- 読み出し側: `count()` / `get()` / `remove()`

## Rules
- 親は全件読み込みをしない
- 子が全件を読み込んでモード確定する
- `records()` / `group()` の整列は呼び出し側責任
- `group()` は `TableTools` を使って構造化する
- 取り出しの単位は `spool_id` と `index`

## API
| API | 役割 | 説明 |
|---|---|---|
| `Spool->open($spool_id)` | 親 | 書き込み用インスタンスを作る |
| `$spool->meta($meta)` | 親 | `order` / `attrs` などのメタを渡す |
| `$spool->add($row)` | 親 | 行データを 1 行ずつ追加する |
| `$spool->close()` | 親 | 書き込みを閉じて子へ渡せる状態にする |
| `Spool::lines($spool_id)` | 子 | 全件を読んで 1 行 = 1 件に確定する |
| `Spool::records($spool_id, @key_cols)` | 子 | 全件を読んで連続行をレコード単位に確定する |
| `Spool::group($spool_id, @groups)` | 子 | 全件を読んで `TableTools` で group 構造に確定する |
| `Spool::count($spool_id)` | 読み出し | 件数を返す |
| `Spool::get($spool_id, $index)` | 読み出し | index で 1 件取り出す |
| `Spool::remove($spool_id)` | 読み出し | spool を削除する |
