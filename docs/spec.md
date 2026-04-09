# Spool 仕様書

## 概要

Spool は、行データをファイルに蓄積し、fork 前にメモリを使い切らずに子プロセスへデータを渡すための Perl パッケージです。
親プロセスが行を書き込み（write フェーズ）、子プロセスまたは別プロセスがモードを確定する（confirm フェーズ）という2段階の設計を持ちます。

## ストレージ構造

すべての spool は `/tmp/spool/<spool_id>/` ディレクトリに格納されます。

| ファイル | 存在タイミング | 内容 |
|---|---|---|
| `rows.do` | open〜close 後・confirm 前 | 行データの配列（Perl データ構造） |
| `meta.do` | close 後（部分形）→ confirm 後（完全形） | メタ情報ハッシュ |
| `items/NNNNNNNN.do` | confirm 後 | 各アイテム（行・グループ） |

**状態判定：**
- `rows.do` が存在する → 未確定（unconfirmed）
- `items/` が存在する → 確定済み（confirmed）

## spool_id の制約

`[A-Za-z0-9]+` に合致する文字列のみ有効。スラッシュ・スペース・ハイフン・アンダースコア・ドット・非 ASCII 文字・空文字列は die。

## write フェーズ（オブジェクト API）

### `Spool->open($spool_id)`

新しい spool を作成してオブジェクトを返す。同一 spool_id が既に存在する場合は die。

### `$spool->meta($hashref)`

メタ情報を設定する。`add()` を呼んだ後に呼ぶと die。

`$hashref` に指定できるキー：

| キー | 型 | 用途 |
|---|---|---|
| `order` | arrayref of strings | `group()` 確定時に `TableTools` へ渡す列順序（`group()` 必須） |
| `attrs` | hashref | 列属性（任意。`group()` 時に未指定の場合は `validate` が型を自動検出する。`order` は全行のすべての列を過不足なく列挙していること） |

### `$spool->add($row_hashref)`

行を追加する。

### `$spool->close()`

書き込みを完了し、`meta.do` を部分形で書く。`meta()` が呼ばれていない場合は `{}` を書く。
部分形は `order`・`attrs` のみを含み、`mode`・`count` はまだ含まれない。

## confirm フェーズ（関数 API）

オブジェクト不要。`spool_id` 文字列だけで呼び出せる。

いずれの関数も、確定済み（`items/` あり）の spool に対して呼ぶと die。

### `Spool::lines($spool_id)`

各行を個別の item として保存する。`meta.do` を完全形（`mode=lines`・`count`）に上書きする。

### `Spool::records($spool_id, @key_cols)`

連続する同一キーの行をグループ化して item として保存する。Spool はソートを行わず入力順を走査する。一度終わったキーが再出現した場合は die。キー列が行に存在しない場合も die。`meta.do` を完全形（`mode=records`・`count`・`key_cols`）に上書きする。

### `Spool::group($spool_id, \@level1_cols, \@level2_cols, ...)`

`TableTools::validate` → `TableTools::group` → `TableTools::detach` の順で処理し、階層グループを構築して item として保存する。

`meta()` で `order` が設定されていることが必須（ない場合は die）。

rows が空の場合は `validate` / `group` をスキップし、0 件で確定する。

rows が空でない場合、`attrs` の有無で `validate` の呼び方を分ける：

- `attrs` 設定済みの場合: `attach` でメタを付けてから `validate` を呼ぶ
- `attrs` 未設定の場合: `validate($rows, $order)` を呼び、TableTools が各列の型（`'str'` / `'num'`）を自動検出する

`validate` は各行の列集合が `order` と完全一致することを要求する。`order` に記載のない列を持つ行・列数の不一致は die。`undef` 値は die せず空文字 `''` へ正規化する（TableTools::validate の動作による）。

`TableTools::group` の動作に従い、各レベルでキー列を外側に取り出し、**キー列以外の全列**を `'@'` キー配下の子配列に格納する。

`meta.do` を完全形（`mode=group`・`count`・`groups`）に上書きする。

#### group item の構造（単一レベル例）

入力行: `{ file => 'a.txt', line => 1, text => 'hello' }`
`Spool::group($spool_id, ['file'])` + `order = ['file', 'line', 'text']` の場合：

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

確定済み spool のアイテム数を返す。未確定の場合は die。

### `Spool::get($spool_id, $index)`

指定インデックスのアイテムを返す。範囲外インデックスや未確定の場合は die。

| モード | 戻り値 |
|---|---|
| `lines` | ハッシュリファレンス（行データ） |
| `records` | 配列リファレンス（行ハッシュの配列） |
| `group` | ハッシュリファレンス（キー列 + `'@'` 配下に子配列） |

### `Spool::remove($spool_id)`

spool ディレクトリをまるごと削除する。未確定・確定済みどちらでも動作する。

## meta.do の2段階

| タイミング | 内容 |
|---|---|
| `close()` 後（部分形） | `order`・`attrs`（`meta()` が呼ばれた場合のみ） |
| confirm 後（完全形） | 部分形の内容 + `mode`・`count`・モード固有フィールド |

モード固有フィールド：

| モード | 追加フィールド |
|---|---|
| `lines` | なし |
| `records` | `key_cols` |
| `group` | `groups` |

## 状態遷移の安全性

`lines()` / `records()` / `group()` はいずれも確定処理を fork した子プロセスで実行し、`items_tmp/` への書き出し後に `items/` へアトミックリネームして確定する：

1. **書き出し**: 子プロセスが `items_tmp/` に全 item を書き出す。途中で die しても `items/` は作成されない。
2. **公開**: `items_tmp/` → `items/` にリネームして原子的に確定。子プロセスが正常終了した場合のみ `items/` が公開される。
3. **再実行時**: `items_tmp/` が残っていた場合は次回の確定処理開始時に削除する。
