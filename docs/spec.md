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
| `order` | arrayref of strings | `group()` 確定時に `'@'` 配下へ落とす列の順序（`group()` 必須） |
| `attrs` | hashref | 列属性（任意） |

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

階層グループを構築して item として保存する。`meta()` で `order` が設定されていることが必須（ない場合は die）。

各レベルでキー列を外側に取り出し、残りの列（`meta->{order}` に含まれるもの）を `'@'` キー配下の子配列に格納する。`order` に含まれない列は子に渡らない。キー列が行に存在しない場合や再出現した場合は die。

`meta.do` を完全形（`mode=group`・`count`・`groups`）に上書きする。

#### group item の構造（単一レベル例）

入力行: `{ file => 'a.txt', line => 1, text => 'hello' }`  
`group('id', ['file'])` + `order = ['file', 'line', 'text']` の場合：

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

`records()` と `group()` は確定処理をフェーズ分割して実装する：

1. **フェーズ1**（メモリ内）: バリデーション・グループ化。ここで die しても `items/` は作成されない。
2. **フェーズ2**（ファイル書き込み）: `items_tmp/` に書き込み後、`items/` にリネームして原子的に確定。
