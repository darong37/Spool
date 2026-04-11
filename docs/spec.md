# Spool 仕様書

## 概要

Spool は、行データをファイルに蓄積し、fork 前にメモリを使い切らずに子プロセスへデータを渡すための Perl パッケージです。
親プロセスが行を書き込み（write フェーズ）、子プロセスまたは別プロセスがモードを確定する（confirm フェーズ）という2段階の設計を持ちます。

## ストレージ構造

すべての spool は `/tmp/spool/<spool_id>/` ディレクトリに格納されます。

| ファイル | 存在タイミング | 内容 |
|---|---|---|
| `rows.do` | open〜close 後・confirm 前 | 行データの配列（Perl データ構造） |
| `spool.do` | open 後から常に存在 | spool の状態ハッシュ（`ready`・`empty`・`mode`） |
| `meta.do` | open 後から存在 | メタ情報ハッシュ |
| `items/NNNNNNNN.do` | confirm 後（1件以上のとき） | 各アイテム（行・グループ） |

**状態判定：**
- `spool.do->{ready} == 0` → 未確定（unconfirmed）
- `spool.do->{ready} == 1` → 確定済み（confirmed）
- `spool.do->{empty} == 1` → 結果 0 件で確定済み

## spool_id の制約

`[A-Za-z0-9]+` に合致する文字列のみ有効。スラッシュ・スペース・ハイフン・アンダースコア・ドット・非 ASCII 文字・空文字列は die。

## write フェーズ（オブジェクト API）

write-side object は `open()` から `close()` までの一連の構築専用として使う。
正しい使い方の前提は次のとおり。

- `meta()` と `add()` は `close()` 前にだけ呼ぶ
- `close()` 後に同じ object を再利用しない
- `meta()` に渡す値は hashref とし、`attrs` を指定する場合は hashref、`order` を指定する場合は arrayref にする
- confirm フェーズへ進める前に、呼び出し側が必要な `meta` を出し切っている前提で使う

### `Spool->open($spool_id)`

新しい spool を作成してオブジェクトを返す。同一 spool_id が既に存在する場合は die。
`open()` 時点で `rows.do` に加えて、初期状態の `spool.do` と空の `meta.do` を作成する。

### `$spool->meta($hashref)`

メタ情報を設定する。`add()` の前後どちらで呼んでもよい。`meta()` を呼ばない場合は `order`・`attrs` なしで `close()` が進む。
設定内容が `meta.do` に反映されるのは `close()` 時である。
`meta()` は値を置き換える setter であり、複数回呼んだ場合は最後に渡した hashref が採用される。

`$hashref` に指定できるキー：

| キー | 型 | 用途 |
|---|---|---|
| `order` | arrayref of strings | `grouping()` 確定時に `TableTools` へ渡す列順序（`grouping()` 必須） |
| `attrs` | hashref | 列属性（任意。`grouping()` 時に未指定の場合は `validate` が型を自動検出する。`order` は全行のすべての列を過不足なく列挙していること） |

### `$spool->add($row_hashref)`

行を追加する。

### `$spool->close()`

書き込みを完了し、`meta.do` を更新する。
`meta.do` は `order`・`attrs`（`meta()` が呼ばれた場合）と `count`（行数 = `add()` の呼び出し回数）を含む。`mode` は含まれない。
`add()` が一度も呼ばれていない場合（`count` = 0）は `warn` を標準エラーへ出力する（die はしない）。
`close()` 後は write-side object の役割は終わる。以後に `meta()` / `add()` / `close()` を再度呼ぶ使い方は契約外とする。

## confirm フェーズ（関数 API）

オブジェクト不要。`spool_id` 文字列だけで呼び出せる。

いずれの関数も、確定済み（`spool.do->{ready}` が真）の spool に対して呼ぶと die。

### `Spool::lines($spool_id)`

各行を個別の item として保存する。
結果が 1 件以上なら `items/` を作成し、`meta.do` の `count` を item 件数に更新する。
結果が 0 件なら `items/` は作らない。
いずれの場合も `spool.do` を `{ ready => 1, empty => ..., mode => 'lines' }` に更新する。

### `Spool::records($spool_id, @key_cols)`

連続する同一キーの行をグループ化して item として保存する。Spool はソートを行わず入力順を走査する。一度終わったキーが再出現した場合は die。キー列が行に存在しない場合も die。

内部では `TableTools::validate` → `TableTools::group` → `TableTools::detach` を使って処理する。`meta()` で `order` が設定されていれば `validate` に渡し、なければ列型を自動検出する。

各グループの item は **配列リファレンス**（行ハッシュの配列）であり、キー列の値はグループ内の各行にも含まれる（グループ化で外に取り出されたキー列は各行へ再付与される）。

結果が 1 件以上なら `items/` を作成し、`meta.do` に `count`・`key_cols` を書く。
結果が 0 件なら `items/` は作らない。
いずれの場合も `spool.do` を `{ ready => 1, empty => ..., mode => 'records' }` に更新する。

### `Spool::grouping($spool_id, \@level1_cols, \@level2_cols, ...)`

`TableTools::validate` → `TableTools::group` → `TableTools::detach` の順で処理し、階層グループを構築して item として保存する。

`meta()` で `order` が設定されていることが必須（ない場合は die）。

rows が空の場合も `validate` / `group` を呼ぶ。`TableTools::validate` は空配列を正常に処理し、結果として 0 件で確定する。このとき `items/` は作らない。

rows が空でない場合、`attrs` の有無で `validate` の呼び方を分ける：

- `attrs` 設定済みの場合: `attach` でメタを付けてから `validate` を呼ぶ
- `attrs` 未設定の場合: `validate($rows, $order)` を呼び、TableTools が各列の型（`'str'` / `'num'`）を自動検出する

`validate` は各行の列集合が `order` と完全一致することを要求する。`order` に記載のない列を持つ行・列数の不一致は die。`undef` 値は die せず空文字 `''` へ正規化する（TableTools::validate の動作による）。

`TableTools::group` の動作に従い、各レベルでキー列を外側に取り出し、**キー列以外の全列**を `'@'` キー配下の子配列に格納する。

結果が 1 件以上なら `meta.do` に `count`・`groups` を書く。
いずれの場合も `spool.do` を `{ ready => 1, empty => ..., mode => 'grouping' }` に更新する。

#### grouping item の構造（単一レベル例）

入力行: `{ file => 'a.txt', line => 1, text => 'hello' }`
`Spool::grouping($spool_id, ['file'])` + `order = ['file', 'line', 'text']` の場合：

```perl
{
    file => 'a.txt',
    '@'  => [
        { line => 1, text => 'hello' },
        ...
    ],
}
```

## 読み取り API（関数）

### `Spool::count($spool_id)`

`spool.do` を先に読み、確定済み spool のアイテム数を返す。未確定の場合は die。
`empty => 1` のときは `meta.do` を読まず 0 を返す。

### `Spool::get($spool_id, $index)`

`spool.do` を先に読み、指定インデックスのアイテムを返す。範囲外インデックスや未確定の場合は die。
`empty => 1` のときは常に範囲外として die する。

| モード | 戻り値 |
|---|---|
| `lines` | ハッシュリファレンス（行データ） |
| `records` | 配列リファレンス（行ハッシュの配列） |
| `grouping` | ハッシュリファレンス（キー列 + `'@'` 配下に子配列） |

### `Spool::remove($spool_id)`

spool ディレクトリをまるごと削除する。未確定・確定済みどちらでも動作する。

## `spool.do`

`spool.do` は spool 自体の状態管理に使う。

```perl
{
    ready => 0,         # 0=未確定, 1=確定済み
    empty => undef,     # 1=結果0件, 0=結果あり, undef=未確定
    mode  => undef,     # 'lines' | 'records' | 'grouping' | undef
}
```

- `open()` 時に作成する
- `close()` しただけでは `ready` は `0` のまま
- `lines()` / `records()` / `grouping()` が正常終了したときだけ `ready` を `1` にする
- `mode` は `meta.do` ではなく `spool.do` に持つ

## `meta.do` の段階

| タイミング | 内容 |
|---|---|
| `open()` 直後 | 空ハッシュ |
| `close()` 後（work meta） | `order`・`attrs`（`meta()` が呼ばれた場合）・`count`（行数） |
| confirm 後（complete meta） | `count` とモード固有フィールド。`order`・`attrs` があれば保持 |

モード固有フィールド：

| モード | 追加フィールド |
|---|---|
| `lines` | なし |
| `records` | `key_cols` |
| `grouping` | `groups` |

## 状態遷移の安全性

`lines()` / `records()` / `grouping()` はいずれも確定処理を fork した子プロセスで実行し、`items_tmp/` への書き出し後に `items/` へアトミックリネームして確定する：

1. **書き出し**: 子プロセスが `items_tmp/` に全 item を書き出す。途中で die しても `items/` は作成されない。
2. **公開**: `items_tmp/` → `items/` にリネームして原子的に確定。子プロセスが正常終了した場合のみ `items/` が公開される。
3. **再実行時**: `items_tmp/` が残っていた場合は次回の確定処理開始時に削除する。

結果 0 件のときは `items_tmp/` と `items/` は作られず、`spool.do` の `empty => 1` で確定済みを表す。
