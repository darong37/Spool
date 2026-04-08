# Spool Implementation Sketch
Date: 2026-04-06

## package Spool

### open
インターフェース:
- `$class`: `Spool` クラス
- `$spool_id`: spool の識別子文字列
- 戻り値 `$spool`: 親プロセスが書き込みに使うインスタンス

```perl
sub open($class, $spool_id) {
    # spool_id を受け取り、書き込み用の Spool インスタンスを作る
    # 親プロセスが 1 行ずつ書くための入口にする
    # spool の保存先を初期化する
    # 書き込み用ファイルハンドラを保持する
}
```

### meta
インターフェース:
- `$self`: 書き込み中の `Spool` インスタンス
- `$meta`: `order` / `attrs` などのメタ情報
- 戻り値 `$self`: 同じインスタンス

```perl
sub meta($self, $meta) {
    # order / attrs などのメタ情報を受け取る
    # 行データとは別にインスタンスへ保持する
    # add() より前に呼ぶ前提にする
}
```

### add
インターフェース:
- `$self`: 書き込み中の `Spool` インスタンス
- `$row`: 追加する 1 行分の hashref
- 戻り値 `$self`: 同じインスタンス

```perl
sub add($self, $row) {
    # 1 行分のデータを spool へ追記する
    # 親プロセスは配列にためず、来た行をそのまま書く
    # 親プロセスが全件をメモリに持たないための基本動作にする
}
```

### close
インターフェース:
- `$self`: 書き込み中の `Spool` インスタンス
- 戻り値 `$self`: close 済みの同じインスタンス

```perl
sub close($self) {
    # 書き込みを閉じる
    # 子プロセスが読める状態にする
    # 必要なメタ情報をディスクへ残す
    # 親プロセスが以後持つものを spool_id だけにする
}
```

### lines
インターフェース:
- `$spool_id`: 確定対象 spool の識別子文字列
- 戻り値 `$count`: 確定後の件数

```perl
sub lines($spool_id) {
    # 子プロセスで spool 全体を読み込む
    # 1 行をそのまま 1 件として確定する
    # 確定後の取り出し単位を書き出す
    # 親プロセスではこの重い処理を行わない
}
```

### records
インターフェース:
- `$spool_id`: 確定対象 spool の識別子文字列
- `@key_cols`: レコード単位を決めるキー列名
- 戻り値 `$count`: 確定後の件数

```perl
sub records($spool_id, @key_cols) {
    # 子プロセスで spool 全体を読み込む
    # 入力順をそのまま前から見て同じ key の連続行を 1 件にまとめる
    # ソートはせず、整列済み入力を前提にする
    # 確定後の取り出し単位を書き出す
}
```

### group
インターフェース:
- `$spool_id`: 確定対象 spool の識別子文字列
- `@groups`: 各段の group キー列名配列
- 戻り値 `$count`: 最上位グループ件数

```perl
sub group($spool_id, @groups) {
    # 子プロセスで spool 全体を読み込む
    # rows が空なら validate/group をスキップして 0 件確定する
    # rows が空でなければ TableTools::validate でテーブルを検証する
    # TableTools::group で階層グループを構築する（キー列以外の全列を '@' 配下へ）
    # TableTools::detach で grouped items を取り出して確定後の取り出し単位を書き出す
}
```

### count
インターフェース:
- `$spool_id`: 確定済み spool の識別子文字列
- 戻り値 `$count`: mode に応じた件数

```perl
sub count($spool_id) {
    # 確定済み spool の件数を返す
    # 件数の単位は mode に従う
}
```

### get
インターフェース:
- `$spool_id`: 確定済み spool の識別子文字列
- `$index`: 取り出したい位置
- 戻り値 `$item`: その位置の 1 件

```perl
sub get($spool_id, $index) {
    # 確定済み spool から index 指定で 1 件返す
    # 取り出しは spool_id と index で行う
}
```

### remove
インターフェース:
- `$spool_id`: 削除対象 spool の識別子文字列
- 戻り値: なし

```perl
sub remove($spool_id) {
    # spool 全体を削除する
    # 後始末用の API として使う
}
```

## 実装の前提
- 親は 1 行ずつ書くだけで、全件読み込みをしない
- 全件読み込みと mode 変換は子プロセスで行う
- 子が終了すれば、その全件読み込みで使ったメモリも消える
- `records()` / `group()` の整列は呼び出し側責任にする
- `group()` は自前で木構造を作り込まず `TableTools` を使う
