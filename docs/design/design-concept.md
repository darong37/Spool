# Spool Concepts

Date: 2026-04-06

## この文書の位置づけ

この文書は `Spool` の概念整理用メモである。
現在の正本は `docs/superpowers/specs/2026-04-06-spool-design.md` とし、
この文書はその内容を人間向けに噛み砕いて共有するための補助資料として扱う。

保存形式、API、プロセスモデルを含む設計判断は正本 spec を優先する。

## 概要

`Spool` は、行データをいったんファイルへ逃がし、
後から `spool_id` と `index` で取り出せる汎用パッケージである。

主目的は次の2つ。

- 親プロセスが巨大配列を抱えたまま `fork` しないようにする
- DB 結果・AOH などの行データを、後続の並列処理へ安全に受け渡す

`Spool` は `DBOBJ` 専用ではなく、
同じ形の行データを出せる入力元なら汎用に扱える前提とする。

## 業務モデル

`Spool` が想定する流れは次の通り。

1. 親プロセスが行データを順次受け取る
2. 親プロセスは巨大配列を持たず、`Spool` に逐次書き出す
3. 親プロセスは `close()` 後、`spool_id` だけを別プロセスへ渡す
4. 別プロセスが `spool_id` を使ってモード確定を行う
5. 後続処理は `Spool::count()` / `Spool::get()` で取り出す

ここでプロセス間をまたいで受け渡すのは `spool_id` 文字列だけである。
`Spool` オブジェクト自体をプロセス間で受け渡すことはしない。

## 設計方針

- 書き込み側は状態を持つためオブジェクト API とする
- モード確定側と読み出し側は `spool_id` ベースの関数 API とする
- 書き込みフェーズとモード確定フェーズを分離する
- `get($spool_id, $index)` の呼び出し形は固定する
- 行データは常に `hashref` とする
- メタ情報は行データとは別に扱う
- `Spool` 自体はソートを行わず、入力順をそのまま扱う

## 入力モデル

### 行データ

各行は必ず `hashref` とする。

```perl
{ filepath => 'a.txt', line => 1, text => 'hello' }
```

### メタ情報

メタ情報は `meta()` で別途渡す。
常に必須ではない。

- `lines()` / `records()` ではメタなしでも成立してよい
- `group()` では `order` が必須
- `attrs` は比較やソートのためではなく、メタ情報として保持するためのもの

想定するメタ形:

```perl
{
  order => ['filepath', 'line', 'text'],
  attrs => {
    filepath => 'str',
    line     => 'num',
    text     => 'str',
  },
}
```

## 2 段階モデル

`Spool` は次の 2 段階で動く。

### 1. 書き込みフェーズ

親プロセスが行う。

- `Spool->open($spool_id)`
- `$spool->meta($meta)` 任意
- `$spool->add($row)` を繰り返す
- `$spool->close()`

この時点で `rows.do` と、必要なら `meta.do` の部分形だけが存在する。
まだ `count()` / `get()` は使えない。

### 2. モード確定フェーズ

別プロセスが `spool_id` だけを受け取って行う。

- `Spool::lines($spool_id)`
- `Spool::records($spool_id, @key_cols)`
- `Spool::group($spool_id, @groups)`

ここで `rows.do` を読み込み、`items/` と完全形 `meta.do` を生成する。
確定後は `rows.do` を削除し、`count()` / `get()` が使えるようになる。

## 出力モデル

### `lines()`

1行をそのまま 1 件として返す。

```perl
{ filepath => 'a.txt', line => 1, text => 'hello' }
```

### `records($spool_id, @key_cols)`

同じ key 列の値の組が連続する行群を、
フラットな配列として返す。

```perl
[
  { filepath => 'a.txt', line => 1, text => 'hello' },
  { filepath => 'a.txt', line => 2, text => 'world' },
]
```

`Spool` 自体はソートしない。
入力順を前から見て、
同じ key 値の組なら同じまとまり、
変わったら新しいまとまりとして扱う。

### `group($spool_id, @groups)`

`TableTools.pm` の `group` と同じ方向で、
行群を木構造へ組み替えて返す。

```perl
{
  filepath => 'a.txt',
  '@' => [
    { line => 1, text => 'hello' },
    { line => 2, text => 'world' },
  ],
}
```

多段 group でも `count()` / `get()` の単位は最上位グループとする。

`group()` に必要なのは `order` であり、
これは key 以外の列を `'@'` 配下へどの順に落とすかを決めるために使う。

## 保存モデル

保存物は `/tmp/spool/$spool_id/` 配下に置く。
`spool_id` に使える文字は `[A-Za-z0-9]+` のみとする。

ファイル構造の概念は次の通り。

```text
/tmp/spool/
  job001/
    meta.do
    rows.do
    items/
      00000000.do
      00000001.do
      ...
```

- `rows.do`: 生の全行
- `meta.do`: `close()` 時の部分形メタ、確定後は完全形メタ
- `items/`: 確定後の取り出し単位

## API 整理

### 書き込み側

- `Spool->open($spool_id)`
- `$spool->meta($meta)`
- `$spool->add($row)`
- `$spool->close()`

### モード確定側

- `Spool::lines($spool_id)`
- `Spool::records($spool_id, @key_cols)`
- `Spool::group($spool_id, @groups)`

### 読み出し側

- `Spool::count($spool_id)`
- `Spool::get($spool_id, $index)`
- `Spool::remove($spool_id)`

## エラーの考え方

- `spool_id` が不正なら `open()` で `die`
- `meta()` を `add()` 後に呼んだら `die`
- `rows.do` が不正ならモード確定時に `die`
- `group()` に必要な `order` がなければ `die`
- 未整列入力を検知したら `records()` / `group()` で `die`
- 未確定状態で `count()` / `get()` を呼んだら `die`

## DBOBJ 連携の位置づけ

`DBOBJ` 連携は自然な利用例の一つである。
たとえば `DBOBJ` 側で `meta()` / `add()` / `close()` を内包する
`spool($spool_id)` のような補助メソッドを持たせることはできる。

ただし `Spool` 自体は `DBOBJ` 専用に閉じない。

## docs/design の読み方

`docs/design/design-implementation-sketch.md` も、
現在はこの概念文書と同じく正本 spec に追従する補助資料として扱う。
差分がある場合は正本 spec を優先する。
