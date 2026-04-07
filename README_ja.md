# Spool

行データをファイルに蓄積し、fork 後に子プロセスへ渡すための Perl パッケージです。親プロセスのメモリを消費せずに大量データを受け渡せます。

## 概要

Spool はデータ収集（write フェーズ）とデータ確定（confirm フェーズ）を分離します。親プロセスはオブジェクト API で行を追記し、別プロセス（fork 後など）は `spool_id` 文字列だけで関数 API を呼び出して確定します。

確定モードは3種類：

| モード | 説明 |
|---|---|
| `lines` | 各行が個別の item になる |
| `records` | 連続する同一キーの行がグループ化される |
| `group` | 行が階層的にグループ化される |

## 動作要件

- Perl 5.10 以上
- `Data::Dumper`（コアモジュール）
- `File::Path`（コアモジュール）

## インストール

`src/Spool.pm` をプロジェクトにコピーし、`src/` を `PERL5LIB` に追加してください。

## 使い方

### write フェーズ（オブジェクト API）

```perl
use Spool;

my $spool = Spool->open('myspool');          # spool を作成
$spool->meta({ order => ['file', 'line'] }); # メタ情報（任意）
$spool->add({ file => 'a.txt', line => 1 }); # 行を追加
$spool->add({ file => 'a.txt', line => 2 });
$spool->close();                             # 書き込み完了
```

`meta()` は `add()` より前に呼ぶ必要があります。`group()` を使う場合は `order` が必須です。

### confirm フェーズ（関数 API、オブジェクト不要）

```perl
# lines: 各行が1つの item
Spool::lines('myspool');

# records: 連続する同一キーの行をグループ化
Spool::records('myspool', 'file');

# group: 階層グループ化（meta に order が必要）
Spool::group('myspool', ['file']);
```

### 結果の読み取り

```perl
my $count = Spool::count('myspool');

for my $i (0 .. $count - 1) {
    my $item = Spool::get('myspool', $i);
    # lines/group → ハッシュリファレンス
    # records → 配列リファレンス
}

Spool::remove('myspool'); # 使い終わったら削除
```

### group() の item 構造

`order = ['file', 'line', 'text']` で `group('id', ['file'])` を呼んだ場合：

```perl
# item 0:
{
    file => 'a.txt',
    '@'  => [
        { line => 1, text => 'hello' },
        { line => 2, text => 'world' },
    ],
}
```

`order` に含まれない列は子には渡りません。

## spool_id の制約

`/\A[A-Za-z0-9]+\z/` に合致する必要があります。ハイフン・アンダースコア・スペース・ドット・非 ASCII 文字・空文字列は die します。

## ストレージ

すべての spool は `/tmp/spool/<spool_id>/` に格納されます。

| ファイル | 存在タイミング | 内容 |
|---|---|---|
| `rows.do` | open 後〜confirm 前 | 行データの配列 |
| `meta.do` | close 後（部分形）/ confirm 後（完全形） | メタ情報ハッシュ |
| `items/NNNNNNNN.do` | confirm 後 | 各アイテム |

## エラー処理

| 条件 | 動作 |
|---|---|
| 不正な `spool_id` | `die` |
| 重複 `open` | `die` |
| `add()` 後の `meta()` | `die` |
| 確定済み spool への再確定 | `die` |
| 行にキー列が存在しない | `die` |
| キー値の順序違反（再出現） | `die` |
| `group()` で `order` がない | `die` |
| `get()` で範囲外インデックス | `die` |
| 未確定 spool への `count()`/`get()` | `die` |

## ライセンス

MIT
