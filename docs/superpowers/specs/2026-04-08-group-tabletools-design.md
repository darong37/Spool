# 変更仕様書: group() の TableTools 委譲
Date: 2026-04-08

## 変更の目的

`Spool::group()` の内部実装を、カスタム実装（`_build_group` / `_make_group_item`）から
`TableTools::group` への委譲に切り替える。

TableTools のルール「validate 済みテーブルを前提に group を扱う」に準拠し、
Spool 独自のグループ化ロジックを排除する。

## 変更スコープ

`src/Spool.pm` の `group()` のみ。
`lines()` / `records()` / `count()` / `get()` / `remove()` / write フェーズの各関数は変更しない。

## 変更内容

### インポートの追加

```perl
use TableTools qw(validate group detach attach);
```

### group() の仕様

#### シグネチャ

```perl
Spool::group($spool_id, \@level1_cols, \@level2_cols, ...)
```

- `$spool_id`: 確定対象 spool の識別子文字列
- `\@levelN_cols`: 各階層のキー列名配列リファレンス
- 戻り値: 最上位グループの件数（整数）

#### 処理フロー

**Phase 1（メモリ内処理）**

1. `items/` が存在する場合は die（確定済み spool への二重確定防止）
2. `meta.do` を読む。`order` が設定されていない場合は die
3. `rows.do` を読む
4. **rows が空の場合は validate / group をスキップして 0 件確定へ進む**
5. rows が空でない場合、`attrs` の有無で validate の呼び方を分ける：
   - `attrs` 設定済みの場合:
     `validate(attach($rows, {'#' => {attrs => $attrs, order => $order}}))`
   - `attrs` 未設定の場合:
     `validate($rows, $order)`
     → TableTools が各列の型（`'str'` / `'num'`）を自動検出する
6. `group($validated_table, @groups)` を呼ぶ
7. `detach($grouped_table)` で items arrayref を取り出す

Phase 1 で die した場合、`items/` は作成されない（状態は変わらない）。

**Phase 2（原子書き込み）**

既存の `items_tmp/` → `items/` リネーム方式をそのまま使う。

1. `items_tmp/` に各 item を書き出す（空の場合はファイルなし）
2. `items_tmp/` を `items/` にリネーム（原子的確定）
3. `meta.do` を完全形（`mode=group` / `count` / `groups`）に上書き
4. `rows.do` を削除

#### `order` と行列の整合制約

`validate` は各行の列集合が `order` と完全一致することを要求する。具体的には：

- 行の列数が `order` の列数と異なる → `column count mismatch` で die
- 行に `order` に含まれない列がある → `unexpected column` で die
- 行の列に `undef` 値がある → die

**`order` は全行のすべての列を過不足なく列挙しなければならない。**
`order` に記載のない余分な列を持つ行を追加した場合、`group()` 確定時に die する。

#### エラー条件

| 条件 | die メッセージ |
|---|---|
| 確定済み spool に対して呼んだ | `already confirmed: $spool_id` |
| `order` が meta に未設定 | `order is required for group()` |
| `rows.do` が読めない / 不正 | `invalid spool data for $spool_id` |
| 行の列が `order` と不一致 | TableTools `column count mismatch` / `unexpected column` |
| キー列が行に存在しない | TableTools `_check_cols` が die |
| 非連続な同一キーの再出現 | TableTools `out of order: key reappeared` |

#### 子行の構造

TableTools の動作に従い、各レベルでキー列を外側に取り出し、
**キー列以外の全列**を `'@'` 配下の子配列に格納する。

単一レベルの例：

入力行: `{ file => 'a.txt', line => 1, text => 'hello' }`
`group($spool_id, ['file'])` + `order = ['file', 'line', 'text']` の場合：

```perl
{
    file => 'a.txt',
    '@'  => [
        { line => 1, text => 'hello' },
    ],
}
```

### 削除するもの

- `sub _build_group`
- `sub _make_group_item`

## spool.t の改訂方針

以下のテストは新仕様と矛盾するため TDD フェーズで改訂する：

| テスト | 現行の前提 | 改訂方針 |
|---|---|---|
| テスト38 `group() single-level produces grouped items` | `extra` 列が order に含まれないため子から除外される | `extra` 列を削除し、行の列を order と完全一致させる。`ok !exists ..{extra}` のアサーションも削除する |

以下のテストを新規追加する：

| テスト | 確認内容 |
|---|---|
| テスト43b `group() dies if row has column not in order` | order に含まれない列を持つ行がある場合 die |
| テスト43c `group() confirms with 0 items on empty spool` | rows が 0 件の場合、0 件で確定できる |

## docs/spec.md との対応

`docs/spec.md` の以下を本仕様書に合わせて更新する：

- `meta()` の `attrs` 説明: 「全列 `'str'` で自動生成」→「`validate` が型を自動検出。`order` は全列の完全列挙が必須」
- `Spool::group` セクション: 空入力の 0 件確定・`order` 完全列挙制約・validate → group → detach フローを明記
- `design-implementation-sketch.md` の `group()` コメント: TableTools に全面委譲する旨を反映
