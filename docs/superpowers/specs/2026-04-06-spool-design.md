# Spool 設計ドキュメント

Date: 2026-04-06

## 概要

`Spool` は行データをファイルベースで退避し、`spool_id` と `index` で取り出せる汎用パッケージ。

主目的：
- 親プロセスが巨大配列を抱えたまま `fork` しないようにする
- DB 結果・AOH などの行データを後続の並列処理へ安全に受け渡す

プロセス間の連携は `spool_id`（文字列）のみで行う。オブジェクトはプロセスをまたがない。

## 設計決定事項

### spool_id と保存先

- `spool_id` は識別子文字列（例：`job001`）
- `spool_id` に使用できる文字は `[A-Za-z0-9]+` のみ。それ以外は `open()` で `die`
- 実保存先は `/tmp/spool/$spool_id/`（ベースディレクトリは `/tmp/spool/` 固定）
- `open()` 時に `/tmp/spool/$spool_id/` が既に存在する場合は `die`

### ファイル構造

```
/tmp/spool/
  job001/
    meta.do        # close() 時に書き出す（order/attrs のみ）。確定後に count/mode 等が追記される
    rows.do        # open() で [ を書き、add() で追記し、close() で ] を締める
    items/
      00000000.do  # モード確定後に生成される出力単位
      00000001.do
      ...
```

### `rows.do` のフォーマット

全ファイル UTF-8。`open()` 時に `[\n` を書き、`add()` のたびに1行を追記し、`close()` で `]\n` を締める。
`do $file` で配列リファレンスとして読み戻せる形になる。

```perl
[
{ filepath => 'a.txt', line => 1, text => 'hello' },
{ filepath => 'a.txt', line => 2, text => 'world' },
{ filepath => 'b.txt', line => 1, text => 'xxx' },
]
```

`close()` が呼ばれていない状態では `]` がなく不正な Perl データになる。
モード確定時に `do $file` が失敗した場合は、不正な spool データとして `die` する。
close 忘れはその代表的な原因だが、書き込み途中・外部要因による破損なども同様に扱う。

### `add()` / `close()` の実装前提

`add()` は `open()` 時に確保した書き込み用ファイルハンドラを使って `rows.do` に追記する。
`close()` はそのファイルハンドラを閉じる操作として実装する。
ハンドラが閉じられた後は `add()` を同じハンドラ経由で実行できない前提とする。
`close()` の二重呼び出しや `close()` 後の `add()` のような不正利用は正常系として扱わず、
実装言語・ハンドラ状態に応じて自然に失敗してよい。

### `meta.do` のフォーマットと書き出しタイミング

`meta.do` は **`close()` 時に書き出す**。
別プロセスがモード確定を行う際に `order` / `attrs` を読み出せるようにするため、
書き込みプロセスが `close()` 時点でディスクに残す必要がある。

**`close()` 時点の `meta.do`（部分形）：**

```perl
# meta() なし
{}

# meta() あり
{
  order => ['filepath', 'line', 'text'],
  attrs => { filepath => 'str', line => 'num', text => 'str' },
}
```

モード確定後、`meta.do` は `count` / `mode` / `key_cols` / `groups` を加えた完全形に上書きされる。

**モード確定後の `meta.do`（完全形）：**

```perl
# lines 確定後（meta() なし）
{
  count => 3,
  mode  => 'lines',
}

# lines 確定後（meta() あり）
{
  order => ['filepath', 'line', 'text'],
  attrs => { filepath => 'str', line => 'num', text => 'str' },
  count => 3,
  mode  => 'lines',
}

# records 確定後（meta() なし）
{
  count    => 2,
  mode     => 'records',
  key_cols => ['filepath'],
}

# group 確定後（meta() あり、group には order 必須）
{
  order  => ['filepath', 'line', 'text'],
  attrs  => { filepath => 'str', line => 'num', text => 'str' },
  count  => 2,
  mode   => 'group',
  groups => [['filepath'], ['line']],
}
```

### 状態管理

ここでの「状態はファイルの存在で決まる」とは、spool 全体の外部可視状態についての話である。
書き込み中オブジェクトのファイルハンドラ状態までをファイル存在で管理するという意味ではない
（ハンドラ状態は「add()/close() の実装前提」節を参照）。

| 状態 | `rows.do` | `meta.do` | `items/` |
|---|---|---|---|
| 書き込み中（close 前）| あり | なし | なし |
| close 済み・未確定 | あり | あり（部分形）| なし |
| モード確定済み | なし（削除済み）| あり（完全形）| あり |

**モード確定は親とは別プロセスで実行する前提とする。**
`rows.do` の全件読み込みと `items/` の生成を親プロセスで行うと、
「親プロセスが巨大配列を抱えたまま `fork` しない」というパッケージの主目的に反する。
親プロセスは `close()` 後に `spool_id` を別プロセスへ渡し、
別プロセスが `spool_id` だけを受け取ってモード確定を行う。

モード確定時の流れ（別プロセス）：
1. `meta.do`（部分形）を読み込む（`group()` の場合は `order` を取得）
2. `do 'rows.do'` で全行を一括読み込み（失敗したら不正な spool データとして `die`）
3. モードに従って `items/` を生成
4. `meta.do` を完全形で上書き
5. `rows.do` を削除

`rows.do` が存在しないことが「確定済み」の証拠。
`rows.do` がある状態でモード確定を再度試みても、`rows.do` の存在自体はエラーにならない（`do` で読んで処理する）。
ただし `items/` が既に存在する場合は確定済みとして `die` する。

### ソート前提と走査ルール

`records()` / `group()` は入力行がキー列でソート済みであることを前提とする（`ORDER BY` は呼び出し側責任）。
Spool はソートを行わず、入力順をそのまま前から走査するだけである。

走査ルール：
- 指定 key 列の値の組が直前と同じ → 同じまとまりに属する
- 値の組が変わった → 新しいまとまりを開始する
- 一度終わった key 値の組が再出現した → 未整列として `die`

比較規則（文字列比較・数値比較等）は Spool の関知しないところ。入力が整列済みである前提で走査するのみ。
`attrs` は比較やソートのためのものではなく、メタ情報として保持するためのものである。

`records()` の成立に `meta()` は不要。
`group()` に必要なのは `order`（`'@'` 配下へどの列をどの順で落とすかを決めるため）であり、`attrs` は `group()` ロジックの必須条件ではない。

## API

プロセス間の連携は `spool_id` 文字列のみで行う。
オブジェクトをプロセスをまたいで渡すことはしない。

### 書き込み側（オブジェクト）— 親プロセス

```perl
my $spool = Spool->open('job001');
$spool->meta($meta);   # 任意。add() より前に呼ぶこと。group() 使用時は order が必須
$spool->add($row);     # rows.do に1行追記（hashref）
$spool->close();       # rows.do を ] で締め、meta.do（部分形）を書き出す

# spool_id は呼び出し側が最初から知っている文字列。オブジェクトから取得する必要はない。
# $spool->spool_id() のような取得 API は持たない。
# ここでは 'job001' をそのまま別プロセスへ渡す。
```

### モード確定側（関数）— 別プロセス

別プロセスは `spool_id` だけを受け取り、モードを確定する。

```perl
Spool::lines($spool_id);              # モード確定：1行 = 1件
Spool::records($spool_id, @key_cols); # モード確定：同キー連続行をフラット配列に
Spool::group($spool_id, @groups);     # モード確定：多段グループ構造に
```

`group()` に `order` が必要な理由：各段の key 列以外の列を `'@'` 配下へ落とす際、
`TableTools` 準拠の列順を保つために全列の順序を把握する必要があるため。
`attrs` は `group()` ロジックの必須条件ではない。`order` がなければ `group()` 呼び出し時に `die`。

### 読み出し側（関数）— 任意のプロセス

```perl
Spool::count($spool_id);      # meta.do の count を返す
Spool::get($spool_id, $i);    # items/$i.do を do で返す
Spool::remove($spool_id);     # /tmp/spool/$spool_id/ ごと削除
```

### エラー条件

| 操作 | 条件 | 結果 |
|---|---|---|
| `open($id)` | `spool_id` が `[A-Za-z0-9]+` 以外 | die |
| `open($id)` | `/tmp/spool/$id/` が既に存在する | die |
| `meta()` | `add()` 後に呼んだ | die |
| `Spool::lines()` 等 | `items/` が既に存在する（確定済み）| die |
| `Spool::lines()` 等 | `do rows.do` 失敗（不正な spool データ）| die |
| `Spool::group()` | `meta.do` に `order` が未設定 | die |
| `Spool::records()` / `Spool::group()` | 一度終わった key 値の組が再出現（未整列検知）| die |
| `Spool::records()` / `Spool::group()` | key 列が行に存在しない | die |
| `Spool::get()` / `Spool::count()` | `rows.do` あり（未確定）| die |
| `Spool::get($id, $i)` | `$i` が範囲外（0 〜 count-1 以外）| die |

## 取り出しモードの出力形式

### `lines()`

1行をそのまま1件として返す。

```perl
Spool::get('job001', 0);
# => { filepath => 'a.txt', line => 1, text => 'hello' }
```

### `records(@key_cols)`

同じキーの連続行をフラットな配列として返す。

```perl
Spool::get('job001', 0);
# => [
#   { filepath => 'a.txt', line => 1, text => 'hello' },
#   { filepath => 'a.txt', line => 2, text => 'world' },
# ]
```

### `group(@groups)`

各段の列名配列リファレンスを受け、多段グループ構造を返す。
`count()` と `get()` の単位は最上位グループ。返却構造は `TableTools.pm` の `group` に準ずる。

**一段の例：**

```perl
Spool::group('job001', ['filepath']);
Spool::get('job001', 0);
# => {
#   filepath => 'a.txt',
#   '@' => [
#     { line => 1, text => 'hello' },
#     { line => 2, text => 'world' },
#   ],
# }
```

**多段の例（各段で複数列を key にする場合）：**

```perl
# group(['dir', 'filepath'], ['line']) の場合
# dir と filepath が最上位 key、line が第2段 key、text が末端
Spool::group('job001', ['dir', 'filepath'], ['line']);
Spool::get('job001', 0);
# => {
#   dir      => '/src',
#   filepath => 'a.txt',
#   '@' => [
#     { line => 1, '@' => [{ text => 'hello' }] },
#     { line => 2, '@' => [{ text => 'world' }] },
#   ],
# }
```

各段の key 列は外側に出し、残りの列が `'@'` 配下に入る。

## docs/design/ との関係

`docs/design/` 以下のファイルは本 spec の前身であり、以下の点で現在の設計と異なる。

| 項目 | docs/design/ の旧案 | 本 spec（優先）|
|---|---|---|
| 保存形式 | `rows/*.pl` / `mode.pl` / `mode_index.pl` | `rows.do` / `items/*.do` / `meta.do` |
| モード確定 API | `$spool->lines()` 等のオブジェクトメソッド | `Spool::lines($spool_id)` 等の関数 |
| プロセスモデル | オブジェクトを引き継ぐ前提 | `spool_id` 文字列のみでプロセス間連携 |

設計全体について本 spec を優先する。

## 今回やらないこと

- 保存ベースディレクトリ（`/tmp/spool/`）の変更
- メモリ上に全件保持する設計
- `rows.do` 以外の保存形式（JSON、TSV 等）
- ソート済みでない入力への対応（呼び出し側責任）

## 将来に回すこと

- `DBOBJ->Meta()` の具体実装との連携
- 保存形式の最適化（大量行時のファイルI/O効率）
- `spool_id` バリデーションルールの拡張（現仕様は `[A-Za-z0-9]+`。追加制限が必要になった場合）
- `remove()` の運用ルール詳細化
