# Spool Implementation Image

Date: 2026-04-06

## 目的

この文書は、
`docs/superpowers/specs/2026-04-06-spool-design.md` を実装イメージに落とした補助資料である。

ここに書くコード片は完成コードではなく、
「どの責務をどの段階で果たすか」を共有するための骨格として読む。
正本は spec とし、差分がある場合は spec を優先する。

## 全体像

`Spool` は 3 つの責務に分かれる。

1. 親プロセスで生行を書き出す
2. 別プロセスでモードを確定する
3. 任意のプロセスで件数取得・読み出し・削除を行う

重要なのは、
親プロセスは `rows.do` の書き出しまでに責務を限定し、
`rows.do` を全件読み戻して `items/` を作る重い処理は別プロセスへ逃がすこと。

## API の骨格

```perl
package Spool;

sub open    { ... }  # object
sub meta    { ... }  # object
sub add     { ... }  # object
sub close   { ... }  # object

sub lines   { ... }  # function
sub records { ... }  # function
sub group   { ... }  # function

sub count   { ... }  # function
sub get     { ... }  # function
sub remove  { ... }  # function
```

## フェーズ 1: 親プロセスで書き込む

### `open($spool_id)`

親プロセスは `spool_id` を指定して書き込みコンテキストを作る。

```perl
sub open($class, $spool_id) {
    die "bad spool_id" unless $spool_id =~ /\A[A-Za-z0-9]+\z/;

    my $dir = "/tmp/spool/$spool_id";
    die "already exists" if -e $dir;

    mkdir "/tmp/spool" unless -d "/tmp/spool";
    mkdir $dir or die "mkdir failed: $!";

    open my $fh, '>:encoding(UTF-8)', "$dir/rows.do" or die $!;
    print {$fh} "[\n" or die $!;

    return bless {
        spool_id => $spool_id,
        dir      => $dir,
        rows_fh  => $fh,
        meta     => undef,
    }, $class;
}
```

### `meta($meta)`

`meta()` は親プロセス内でメモリに保持する。
この時点ではまだ `meta.do` へは書かない。

```perl
sub meta($self, $meta) {
    die "meta() after add()" if $self->{added};
    $self->{meta} = $meta;
    return $self;
}
```

ここで保持したいのは主に次の情報である。

- `order`
- `attrs`

このメタは将来利用や後続処理のために保持するものであり、
`records()` / `group()` のソートや比較のために推測利用するものではない。

### `add($row)`

`add()` は `rows.do` に対する追記だけを担当する。

```perl
sub add($self, $row) {
    my $fh = $self->{rows_fh} or die "rows fh closed";

    print {$fh} Data::Dumper
        ->new([$row])
        ->Terse(1)
        ->Indent(0)
        ->Dump, ",\n" or die $!;

    $self->{added} = 1;
    return $self;
}
```

### `close()`

`close()` では 2 つだけやる。

1. `rows.do` を閉じる
2. `meta.do` の部分形を書き出す

```perl
sub close($self) {
    my $fh = delete $self->{rows_fh} or die "already closed";

    print {$fh} "]\n" or die $!;
    close $fh or die $!;

    my $meta = $self->{meta} // {};
    write_do_file("$self->{dir}/meta.do", $meta);

    return $self;
}
```

`close()` 後に親プロセスが持つべきものは、
大きな配列ではなく `spool_id` 文字列だけである。

## フェーズ 2: 別プロセスでモード確定

別プロセスは `spool_id` を受け取り、
対応する `/tmp/spool/$spool_id/` を見てモード確定する。
ここではオブジェクトを引き継がない。

### 共通の流れ

```perl
sub _load_pending_spool($spool_id) {
    my $dir = "/tmp/spool/$spool_id";

    die "already finalized" if -d "$dir/items";

    my $meta = do "$dir/meta.do";
    my $rows = do "$dir/rows.do";
    die "invalid spool data" unless defined $rows;

    return ($dir, $meta, $rows);
}
```

### `lines($spool_id)`

`lines()` は行をそのまま `items/` に切り出す。

```perl
sub lines($spool_id) {
    my ($dir, $meta, $rows) = _load_pending_spool($spool_id);

    mkdir "$dir/items" or die $!;

    for my $i (0 .. $#$rows) {
        my $file = sprintf '%s/items/%08d.do', $dir, $i;
        write_do_file($file, $rows->[$i]);
    }

    $meta->{count} = scalar @$rows;
    $meta->{mode}  = 'lines';

    write_do_file("$dir/meta.do", $meta);
    unlink "$dir/rows.do" or die $!;
}
```

### `records($spool_id, @key_cols)`

`records()` は入力順をそのまま前から見て、
同じ key 値の組が続く区間をひとまとまりにする。
ここで `Spool` はソートしない。

```perl
sub records($spool_id, @key_cols) {
    my ($dir, $meta, $rows) = _load_pending_spool($spool_id);

    mkdir "$dir/items" or die $!;

    my @items;
    my %seen_done;
    my ($current_key, @current_rows);

    for my $row (@$rows) {
        die "missing key col" if grep { !exists $row->{$_} } @key_cols;

        my @key = map { $row->{$_} } @key_cols;
        my $key = join "\0", map { defined $_ ? $_ : '' } @key;

        if (!defined $current_key) {
            $current_key = $key;
            @current_rows = ($row);
            next;
        }

        if ($key eq $current_key) {
            push @current_rows, $row;
            next;
        }

        $seen_done{$current_key} = 1;
        die "unsorted input" if $seen_done{$key};

        push @items, [@current_rows];
        $current_key = $key;
        @current_rows = ($row);
    }

    push @items, [@current_rows] if @current_rows;

    for my $i (0 .. $#items) {
        my $file = sprintf '%s/items/%08d.do', $dir, $i;
        write_do_file($file, $items[$i]);
    }

    $meta->{count}    = scalar @items;
    $meta->{mode}     = 'records';
    $meta->{key_cols} = \@key_cols;

    write_do_file("$dir/meta.do", $meta);
    unlink "$dir/rows.do" or die $!;
}
```

ここで必要なのは、

- 直前と同じ key か
- いったん終わった key が再出現したか

だけである。
文字列比較や数値比較の規則を `Spool` が持つ必要はない。

### `group($spool_id, @groups)`

`group()` も入力順はそのまま使う。
必要なのは `order` を使って、
key 以外の列を `'@'` 配下へどの順序で落とすかを決めること。

```perl
sub group($spool_id, @groups) {
    my ($dir, $meta, $rows) = _load_pending_spool($spool_id);

    my $order = $meta->{order} or die "order required for group()";

    my @top_items = build_group_items($rows, $order, @groups);

    mkdir "$dir/items" or die $!;
    for my $i (0 .. $#top_items) {
        my $file = sprintf '%s/items/%08d.do', $dir, $i;
        write_do_file($file, $top_items[$i]);
    }

    $meta->{count}  = scalar @top_items;
    $meta->{mode}   = 'group';
    $meta->{groups} = \@groups;

    write_do_file("$dir/meta.do", $meta);
    unlink "$dir/rows.do" or die $!;
}
```

`attrs` は保持していてよいが、
`group()` ロジックの必須条件ではない。

## フェーズ 3: 取り出し

### `count($spool_id)`

```perl
sub count($spool_id) {
    my $meta = do "/tmp/spool/$spool_id/meta.do";
    die "not finalized" if -e "/tmp/spool/$spool_id/rows.do";
    return $meta->{count};
}
```

### `get($spool_id, $index)`

```perl
sub get($spool_id, $index) {
    die "not finalized" if -e "/tmp/spool/$spool_id/rows.do";

    my $meta = do "/tmp/spool/$spool_id/meta.do";
    die "out of range" if $index < 0 || $index >= $meta->{count};

    my $file = sprintf '/tmp/spool/%s/items/%08d.do', $spool_id, $index;
    return do $file;
}
```

### `remove($spool_id)`

```perl
sub remove($spool_id) {
    my $dir = "/tmp/spool/$spool_id";
    remove_tree($dir);
}
```

## 状態イメージ

```text
1. open() 後
   rows.do あり
   meta.do なし
   items/ なし

2. close() 後
   rows.do あり
   meta.do あり（部分形）
   items/ なし

3. モード確定後
   rows.do なし
   meta.do あり（完全形）
   items/ あり
```

## 実装メモ

- `spool_id` に使える文字は `[A-Za-z0-9]+` のみ
- `open()` 時に既存ディレクトリがあれば `die`
- `rows.do` が壊れていればモード確定時に `die`
- `meta()` を呼ばなかった場合でも `close()` 時に `meta.do` は `{}` として作る
- `records()` に `meta()` は不要
- `group()` には `order` が必要

## docs/design の役割

この文書は実装イメージの共有用である。
設計判断の正本は spec とし、
将来差分が出た場合はこの文書側を spec に合わせて更新する。
