# Spool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `src/Spool.pm` に書き込み・モード確定・読み出し・削除の全 API を実装し、プロセス間を `spool_id` 文字列のみで連携できる汎用行データ退避パッケージを完成させる。

**Architecture:** 書き込みフェーズはオブジェクト API（`Spool->open` / `$spool->add` / `$spool->close`）、モード確定と読み出しは関数 API（`Spool::lines` / `Spool::records` / `Spool::group` / `Spool::count` / `Spool::get` / `Spool::remove`）として分離する。全ファイルは UTF-8 の Perl データ形式（`do $file` で読み戻せる形）で `/tmp/spool/$spool_id/` に保存する。プロセス間連携は `spool_id` 文字列のみで行い、オブジェクトはプロセスをまたがない。

**Tech Stack:** Perl 5、Test::More、Data::Dumper（標準モジュールのみ）

---

## ファイル構成

| ファイル | 役割 |
|---|---|
| `src/Spool.pm` | 全 API の実装。内部ヘルパー `_write_do` / `_read_do` / `_build_group` を含む |
| `test/spool.t` | 全テスト。subtest で機能ごとに分割 |

---

## Task 1: ヘルパー関数と open() / meta() / add() / close()

**Files:**
- Modify: `src/Spool.pm`
- Modify: `test/spool.t`

### Step 1-1: テストを書く（失敗確認用）

- [ ] `test/spool.t` を以下の内容に書き換える

```perl
use strict;
use warnings;
use Test::More;
use File::Path qw(remove_tree);

my $BASE = '/tmp/spool';

sub cleanup { remove_tree("$BASE/test001") if -d "$BASE/test001" }

use_ok 'Spool';

subtest 'open creates directory and rows.do' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    ok -d "$BASE/test001",           'spool dir exists';
    ok -f "$BASE/test001/rows.do",   'rows.do exists';
    ok !-f "$BASE/test001/meta.do",  'meta.do not yet written';
    cleanup();
};

subtest 'open dies on invalid spool_id' => sub {
    eval { Spool->open('bad/id') };
    like $@, qr/invalid spool_id/, 'dies on slash';
    eval { Spool->open('bad id') };
    like $@, qr/invalid spool_id/, 'dies on space';
};

subtest 'open dies if spool already exists' => sub {
    cleanup();
    Spool->open('test001')->close();
    eval { Spool->open('test001') };
    like $@, qr/already exists/, 'dies on duplicate open';
    cleanup();
};

subtest 'add and close write rows.do correctly' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ a => 1, b => 'x' });
    $spool->add({ a => 2, b => 'y' });
    $spool->close();
    ok -f "$BASE/test001/rows.do", 'rows.do exists after close';
    ok -f "$BASE/test001/meta.do", 'meta.do written by close';
    my $rows = do "$BASE/test001/rows.do";
    is scalar @$rows, 2,       'two rows';
    is $rows->[0]{a}, 1,       'first row a=1';
    is $rows->[1]{b}, 'y',     'second row b=y';
    cleanup();
};

subtest 'meta() stores order and attrs in meta.do after close' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->meta({ order => ['a', 'b'], attrs => { a => 'num', b => 'str' } });
    $spool->add({ a => 1, b => 'x' });
    $spool->close();
    my $meta = do "$BASE/test001/meta.do";
    is_deeply $meta->{order}, ['a', 'b'], 'order preserved';
    is $meta->{attrs}{a}, 'num',          'attrs preserved';
    cleanup();
};

subtest 'meta() dies if called after add()' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ a => 1 });
    eval { $spool->meta({ order => ['a'] }) };
    like $@, qr/before add/, 'dies when called after add';
    cleanup();
};

done_testing;
```

### Step 1-2: テストが失敗することを確認する

- [ ] 実行する

```bash
perl -Ilib -Isrc test/spool.t
```

Expected: `use_ok 'Spool'` 以外は全て FAIL または compile error

### Step 1-3: `src/Spool.pm` に Task 1 の実装を書く

- [ ] `src/Spool.pm` を以下の内容に書き換える

```perl
package Spool;

use strict;
use warnings;
use Data::Dumper;
use File::Path qw(remove_tree);

my $BASE = '/tmp/spool';

# ---- internal helpers ----

sub _write_do {
    my ($path, $data) = @_;
    open my $fh, '>:encoding(UTF-8)', $path or die "Cannot write $path: $!";
    print {$fh} Data::Dumper->new([$data])->Terse(1)->Indent(1)->Dump;
    close $fh;
}

sub _read_do {
    my ($path) = @_;
    my $data = do $path;
    die "Failed to read $path: $@" if $@;
    die "Failed to read $path: file not found or empty" unless defined $data;
    return $data;
}

# ---- write-side object API ----

sub open {
    my ($class, $spool_id) = @_;
    die "invalid spool_id: '$spool_id'" unless $spool_id =~ /\A[A-Za-z0-9]+\z/;
    my $dir = "$BASE/$spool_id";
    die "spool already exists: $dir" if -e $dir;
    mkdir $BASE unless -d $BASE;
    mkdir $dir or die "Cannot create $dir: $!";
    open my $fh, '>:encoding(UTF-8)', "$dir/rows.do" or die "Cannot open rows.do: $!";
    print {$fh} "[\n";
    return bless {
        spool_id => $spool_id,
        dir      => $dir,
        fh       => $fh,
        meta     => undef,
        added    => 0,
    }, $class;
}

sub meta {
    my ($self, $meta) = @_;
    die "meta() must be called before add()" if $self->{added};
    $self->{meta} = $meta;
    return $self;
}

sub add {
    my ($self, $row) = @_;
    my $str = Data::Dumper->new([$row])->Terse(1)->Indent(0)->Dump;
    print { $self->{fh} } $str . ",\n";
    $self->{added}++;
    return $self;
}

sub close {
    my ($self) = @_;
    print { $self->{fh} } "]\n";
    CORE::close $self->{fh};
    _write_do("$self->{dir}/meta.do", $self->{meta} // {});
    return $self;
}

1;
```

### Step 1-4: テストが通ることを確認する

- [ ] 実行する

```bash
perl -Ilib -Isrc test/spool.t
```

Expected: 全 subtest PASS

### Step 1-5: コミット

- [ ] 実行する

```bash
git add src/Spool.pm test/spool.t
git commit -m "feat: implement Spool open/meta/add/close (write phase)"
```

---

## Task 2: Spool::lines() — lines モード確定

**Files:**
- Modify: `src/Spool.pm`
- Modify: `test/spool.t`

### Step 2-1: テストを追加する

- [ ] `test/spool.t` の `done_testing;` の直前に以下を追加する

```perl
subtest 'lines() creates items/ and removes rows.do' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ a => 1 });
    $spool->add({ a => 2 });
    $spool->close();
    Spool::lines('test001');
    ok -d  "$BASE/test001/items",           'items/ created';
    ok -f  "$BASE/test001/items/00000000.do", 'item 0 exists';
    ok -f  "$BASE/test001/items/00000001.do", 'item 1 exists';
    ok !-f "$BASE/test001/rows.do",         'rows.do removed';
    my $item = do "$BASE/test001/items/00000000.do";
    is $item->{a}, 1, 'item 0 has a=1';
    cleanup();
};

subtest 'lines() writes complete meta.do' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->meta({ order => ['a'], attrs => { a => 'num' } });
    $spool->add({ a => 1 });
    $spool->add({ a => 2 });
    $spool->close();
    Spool::lines('test001');
    my $meta = do "$BASE/test001/meta.do";
    is $meta->{mode},  'lines', 'mode=lines';
    is $meta->{count}, 2,       'count=2';
    is_deeply $meta->{order}, ['a'], 'order preserved';
    cleanup();
};

subtest 'lines() dies if already confirmed' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ a => 1 });
    $spool->close();
    Spool::lines('test001');
    eval { Spool::lines('test001') };
    like $@, qr/already confirmed/, 'dies on re-confirm';
    cleanup();
};

subtest 'lines() dies on invalid spool data' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ a => 1 });
    # close() を呼ばずに rows.do を直接壊す
    CORE::close $spool->{fh};
    open my $fh, '>:encoding(UTF-8)', "$BASE/test001/rows.do";
    print $fh "[ { a => 1 },\n";  # ] がない不正データ
    CORE::close $fh;
    _write_do("$BASE/test001/meta.do", {});
    eval { Spool::lines('test001') };
    like $@, qr/invalid spool data/, 'dies on broken rows.do';
    cleanup();
};
```

### Step 2-2: テストが失敗することを確認する

- [ ] 実行する

```bash
perl -Ilib -Isrc test/spool.t
```

Expected: lines 関連 subtest が FAIL

### Step 2-3: `Spool::lines` を実装する

- [ ] `src/Spool.pm` の `close` サブルーチンの後に以下を追加する

```perl
# ---- mode finalization functions ----

sub lines {
    my ($spool_id) = @_;
    my $dir = "$BASE/$spool_id";
    die "already confirmed: $spool_id" if -d "$dir/items";
    my $rows = do "$dir/rows.do";
    die "invalid spool data for $spool_id: $@" if $@;
    die "invalid spool data for $spool_id" unless defined $rows;
    my $meta = _read_do("$dir/meta.do");
    mkdir "$dir/items" or die "Cannot create items/: $!";
    my $count = 0;
    for my $row (@$rows) {
        _write_do(sprintf('%s/items/%08d.do', $dir, $count), $row);
        $count++;
    }
    $meta->{mode}  = 'lines';
    $meta->{count} = $count;
    _write_do("$dir/meta.do", $meta);
    unlink "$dir/rows.do";
    return $count;
}
```

### Step 2-4: テストが通ることを確認する

- [ ] 実行する

```bash
perl -Ilib -Isrc test/spool.t
```

Expected: 全 subtest PASS

### Step 2-5: コミット

- [ ] 実行する

```bash
git add src/Spool.pm test/spool.t
git commit -m "feat: implement Spool::lines (mode finalization)"
```

---

## Task 3: Spool::count() / Spool::get() / Spool::remove()

**Files:**
- Modify: `src/Spool.pm`
- Modify: `test/spool.t`

### Step 3-1: テストを追加する

- [ ] `test/spool.t` の `done_testing;` の直前に以下を追加する

```perl
subtest 'count() returns number of items' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ a => 1 });
    $spool->add({ a => 2 });
    $spool->add({ a => 3 });
    $spool->close();
    Spool::lines('test001');
    is Spool::count('test001'), 3, 'count=3';
    cleanup();
};

subtest 'count() dies if not yet confirmed' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ a => 1 });
    $spool->close();
    eval { Spool::count('test001') };
    like $@, qr/not confirmed/, 'dies before mode confirm';
    cleanup();
};

subtest 'get() returns correct item' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ a => 10 });
    $spool->add({ a => 20 });
    $spool->close();
    Spool::lines('test001');
    my $item0 = Spool::get('test001', 0);
    my $item1 = Spool::get('test001', 1);
    is $item0->{a}, 10, 'item 0 a=10';
    is $item1->{a}, 20, 'item 1 a=20';
    cleanup();
};

subtest 'get() dies on out-of-range index' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ a => 1 });
    $spool->close();
    Spool::lines('test001');
    eval { Spool::get('test001', 1) };
    like $@, qr/out of range/, 'dies on index >= count';
    eval { Spool::get('test001', -1) };
    like $@, qr/out of range/, 'dies on negative index';
    cleanup();
};

subtest 'get() dies if not confirmed' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ a => 1 });
    $spool->close();
    eval { Spool::get('test001', 0) };
    like $@, qr/not confirmed/, 'dies before mode confirm';
    cleanup();
};

subtest 'remove() deletes spool directory' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ a => 1 });
    $spool->close();
    Spool::lines('test001');
    Spool::remove('test001');
    ok !-d "$BASE/test001", 'spool dir removed';
};
```

### Step 3-2: テストが失敗することを確認する

- [ ] 実行する

```bash
perl -Ilib -Isrc test/spool.t
```

Expected: count/get/remove 関連 subtest が FAIL

### Step 3-3: `count` / `get` / `remove` を実装する

- [ ] `src/Spool.pm` の `lines` の後に以下を追加する

```perl
sub count {
    my ($spool_id) = @_;
    my $dir = "$BASE/$spool_id";
    die "spool not confirmed: $spool_id" if -f "$dir/rows.do";
    my $meta = _read_do("$dir/meta.do");
    return $meta->{count};
}

sub get {
    my ($spool_id, $i) = @_;
    my $dir = "$BASE/$spool_id";
    die "spool not confirmed: $spool_id" if -f "$dir/rows.do";
    my $meta = _read_do("$dir/meta.do");
    die "index out of range: $i (count=$meta->{count})"
        unless defined $i && $i >= 0 && $i < $meta->{count};
    return _read_do(sprintf '%s/items/%08d.do', $dir, $i);
}

sub remove {
    my ($spool_id) = @_;
    my $dir = "$BASE/$spool_id";
    remove_tree($dir) if -d $dir;
}
```

### Step 3-4: テストが通ることを確認する

- [ ] 実行する

```bash
perl -Ilib -Isrc test/spool.t
```

Expected: 全 subtest PASS

### Step 3-5: コミット

- [ ] 実行する

```bash
git add src/Spool.pm test/spool.t
git commit -m "feat: implement Spool::count / get / remove (read phase)"
```

---

## Task 4: Spool::records() — records モード確定

**Files:**
- Modify: `src/Spool.pm`
- Modify: `test/spool.t`

### Step 4-1: テストを追加する

- [ ] `test/spool.t` の `done_testing;` の直前に以下を追加する

```perl
subtest 'records() groups consecutive same-key rows' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ file => 'a.txt', line => 1 });
    $spool->add({ file => 'a.txt', line => 2 });
    $spool->add({ file => 'b.txt', line => 1 });
    $spool->close();
    Spool::records('test001', 'file');
    is Spool::count('test001'), 2, 'count=2 groups';
    my $g0 = Spool::get('test001', 0);
    my $g1 = Spool::get('test001', 1);
    is scalar @$g0, 2,          'group 0 has 2 rows';
    is $g0->[0]{line}, 1,       'group 0 row 0 line=1';
    is $g0->[1]{line}, 2,       'group 0 row 1 line=2';
    is scalar @$g1, 1,          'group 1 has 1 row';
    is $g1->[0]{file}, 'b.txt', 'group 1 file=b.txt';
    cleanup();
};

subtest 'records() writes complete meta.do' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ file => 'a.txt', line => 1 });
    $spool->close();
    Spool::records('test001', 'file');
    my $meta = do "$BASE/test001/meta.do";
    is $meta->{mode}, 'records',     'mode=records';
    is_deeply $meta->{key_cols}, ['file'], 'key_cols preserved';
    cleanup();
};

subtest 'records() dies on out-of-order key' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ file => 'a.txt', line => 1 });
    $spool->add({ file => 'b.txt', line => 1 });
    $spool->add({ file => 'a.txt', line => 2 }); # a.txt が再出現
    $spool->close();
    eval { Spool::records('test001', 'file') };
    like $@, qr/out of order/, 'dies on key reappearance';
    cleanup();
};

subtest 'records() dies if key column missing from row' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ line => 1 }); # file がない
    $spool->close();
    eval { Spool::records('test001', 'file') };
    like $@, qr/key column .* not found/, 'dies on missing key col';
    cleanup();
};

subtest 'records() supports multi-column key' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ dir => '/src', file => 'a.txt', line => 1 });
    $spool->add({ dir => '/src', file => 'a.txt', line => 2 });
    $spool->add({ dir => '/src', file => 'b.txt', line => 1 });
    $spool->close();
    Spool::records('test001', 'dir', 'file');
    is Spool::count('test001'), 2, 'count=2 with multi-col key';
    my $g0 = Spool::get('test001', 0);
    is scalar @$g0, 2, 'group 0 has 2 rows';
    cleanup();
};
```

### Step 4-2: テストが失敗することを確認する

- [ ] 実行する

```bash
perl -Ilib -Isrc test/spool.t
```

Expected: records 関連 subtest が FAIL

### Step 4-3: `Spool::records` を実装する

- [ ] `src/Spool.pm` の `lines` の後に以下を追加する

```perl
sub records {
    my ($spool_id, @key_cols) = @_;
    my $dir = "$BASE/$spool_id";
    die "already confirmed: $spool_id" if -d "$dir/items";
    my $rows = do "$dir/rows.do";
    die "invalid spool data for $spool_id: $@" if $@;
    die "invalid spool data for $spool_id" unless defined $rows;
    my $meta = _read_do("$dir/meta.do");
    mkdir "$dir/items" or die "Cannot create items/: $!";
    my $count = 0;
    my ($current_key, @current_group, %seen_keys);
    for my $row (@$rows) {
        for my $col (@key_cols) {
            die "key column '$col' not found in row" unless exists $row->{$col};
        }
        my $key = join "\0", map { $row->{$_} // '' } @key_cols;
        if (!defined $current_key) {
            $current_key = $key;
        } elsif ($key ne $current_key) {
            _write_do(sprintf('%s/items/%08d.do', $dir, $count), \@current_group);
            $count++;
            die "out of order: key reappeared" if $seen_keys{$key};
            $seen_keys{$current_key} = 1;
            $current_key = $key;
            @current_group = ();
        }
        push @current_group, $row;
    }
    if (@current_group) {
        _write_do(sprintf('%s/items/%08d.do', $dir, $count), \@current_group);
        $count++;
    }
    $meta->{mode}     = 'records';
    $meta->{count}    = $count;
    $meta->{key_cols} = \@key_cols;
    _write_do("$dir/meta.do", $meta);
    unlink "$dir/rows.do";
    return $count;
}
```

### Step 4-4: テストが通ることを確認する

- [ ] 実行する

```bash
perl -Ilib -Isrc test/spool.t
```

Expected: 全 subtest PASS

### Step 4-5: コミット

- [ ] 実行する

```bash
git add src/Spool.pm test/spool.t
git commit -m "feat: implement Spool::records (records mode finalization)"
```

---

## Task 5: Spool::group() — 一段グループ

**Files:**
- Modify: `src/Spool.pm`
- Modify: `test/spool.t`

### Step 5-1: テストを追加する

- [ ] `test/spool.t` の `done_testing;` の直前に以下を追加する

```perl
subtest 'group() single-level produces grouped items' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->meta({ order => ['file', 'line', 'text'], attrs => {} });
    $spool->add({ file => 'a.txt', line => 1, text => 'hello' });
    $spool->add({ file => 'a.txt', line => 2, text => 'world' });
    $spool->add({ file => 'b.txt', line => 1, text => 'xxx' });
    $spool->close();
    Spool::group('test001', ['file']);
    is Spool::count('test001'), 2, 'count=2 groups';
    my $g0 = Spool::get('test001', 0);
    is $g0->{file}, 'a.txt',           'group 0 file=a.txt';
    is scalar @{ $g0->{'@'} }, 2,      'group 0 has 2 children';
    is $g0->{'@'}[0]{line}, 1,         'child 0 line=1';
    is $g0->{'@'}[0]{text}, 'hello',   'child 0 text=hello';
    ok !exists $g0->{'@'}[0]{file},    'file key removed from child';
    my $g1 = Spool::get('test001', 1);
    is $g1->{file}, 'b.txt',           'group 1 file=b.txt';
    is scalar @{ $g1->{'@'} }, 1,      'group 1 has 1 child';
    cleanup();
};

subtest 'group() dies if order not in meta' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ file => 'a.txt', line => 1 });
    $spool->close();
    eval { Spool::group('test001', ['file']) };
    like $@, qr/order.*required/, 'dies without order in meta';
    cleanup();
};

subtest 'group() dies on out-of-order key' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->meta({ order => ['file', 'line'], attrs => {} });
    $spool->add({ file => 'a.txt', line => 1 });
    $spool->add({ file => 'b.txt', line => 1 });
    $spool->add({ file => 'a.txt', line => 2 }); # a.txt 再出現
    $spool->close();
    eval { Spool::group('test001', ['file']) };
    like $@, qr/out of order/, 'dies on key reappearance';
    cleanup();
};

subtest 'group() writes complete meta.do' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->meta({ order => ['file', 'line'], attrs => {} });
    $spool->add({ file => 'a.txt', line => 1 });
    $spool->close();
    Spool::group('test001', ['file']);
    my $meta = do "$BASE/test001/meta.do";
    is $meta->{mode}, 'group',             'mode=group';
    is_deeply $meta->{groups}, [['file']], 'groups preserved';
    cleanup();
};
```

### Step 5-2: テストが失敗することを確認する

- [ ] 実行する

```bash
perl -Ilib -Isrc test/spool.t
```

Expected: group 関連 subtest が FAIL

### Step 5-3: `Spool::group` と `_build_group` を実装する

- [ ] `src/Spool.pm` の `records` の後に以下を追加する

```perl
sub _build_group {
    my ($rows, $order, @groups) = @_;
    my $level_cols = $groups[0];
    my @rest       = @groups[1 .. $#groups];
    my %key_set    = map { $_ => 1 } @$level_cols;
    my @result;
    my ($current_key, @current_rows, %seen_keys);
    for my $row (@$rows) {
        my $key = join "\0", map { $row->{$_} // '' } @$level_cols;
        if (!defined $current_key) {
            $current_key = $key;
        } elsif ($key ne $current_key) {
            push @result, _make_group_item(\@current_rows, $order, $level_cols, \%key_set, \@rest);
            die "out of order: key reappeared" if $seen_keys{$key};
            $seen_keys{$current_key} = 1;
            $current_key = $key;
            @current_rows = ();
        }
        push @current_rows, $row;
    }
    if (@current_rows) {
        push @result, _make_group_item(\@current_rows, $order, $level_cols, \%key_set, \@rest);
    }
    return \@result;
}

sub _make_group_item {
    my ($rows, $order, $level_cols, $key_set, $rest) = @_;
    my $head = $rows->[0];
    my %item = map { $_ => $head->{$_} } @$level_cols;
    my @children = map {
        my %child = %$_;
        delete $child{$_} for @$level_cols;
        \%child;
    } @$rows;
    if (@$rest) {
        $item{'@'} = _build_group(\@children, $order, @$rest);
    } else {
        $item{'@'} = \@children;
    }
    return \%item;
}

sub group {
    my ($spool_id, @groups) = @_;
    my $dir = "$BASE/$spool_id";
    die "already confirmed: $spool_id" if -d "$dir/items";
    my $meta = _read_do("$dir/meta.do");
    die "order is required for group()" unless $meta->{order};
    my $rows = do "$dir/rows.do";
    die "invalid spool data for $spool_id: $@" if $@;
    die "invalid spool data for $spool_id" unless defined $rows;
    my $grouped = _build_group($rows, $meta->{order}, @groups);
    mkdir "$dir/items" or die "Cannot create items/: $!";
    my $count = 0;
    for my $item (@$grouped) {
        _write_do(sprintf('%s/items/%08d.do', $dir, $count), $item);
        $count++;
    }
    $meta->{mode}   = 'group';
    $meta->{count}  = $count;
    $meta->{groups} = \@groups;
    _write_do("$dir/meta.do", $meta);
    unlink "$dir/rows.do";
    return $count;
}
```

### Step 5-4: テストが通ることを確認する

- [ ] 実行する

```bash
perl -Ilib -Isrc test/spool.t
```

Expected: 全 subtest PASS

### Step 5-5: コミット

- [ ] 実行する

```bash
git add src/Spool.pm test/spool.t
git commit -m "feat: implement Spool::group single-level"
```

---

## Task 6: Spool::group() — 多段グループ

**Files:**
- Modify: `test/spool.t`（実装は Task 5 の `_build_group` で完結している）

### Step 6-1: テストを追加する

- [ ] `test/spool.t` の `done_testing;` の直前に以下を追加する

```perl
subtest 'group() multi-level with single col per level' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->meta({ order => ['file', 'line', 'text'], attrs => {} });
    $spool->add({ file => 'a.txt', line => 1, text => 'hello' });
    $spool->add({ file => 'a.txt', line => 2, text => 'world' });
    $spool->add({ file => 'b.txt', line => 1, text => 'xxx' });
    $spool->close();
    Spool::group('test001', ['file'], ['line']);
    is Spool::count('test001'), 2, 'count=2 top-level groups';
    my $g0 = Spool::get('test001', 0);
    is $g0->{file}, 'a.txt',                  'g0 file=a.txt';
    is scalar @{ $g0->{'@'} }, 2,             'g0 has 2 line-groups';
    is $g0->{'@'}[0]{line}, 1,                'g0 line-group 0 line=1';
    is scalar @{ $g0->{'@'}[0]{'@'} }, 1,     'g0 line-group 0 has 1 child';
    is $g0->{'@'}[0]{'@'}[0]{text}, 'hello',  'g0 line-group 0 text=hello';
    ok !exists $g0->{'@'}[0]{file},            'file removed from nested';
    cleanup();
};

subtest 'group() multi-level with multi-col first level' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->meta({ order => ['dir', 'file', 'line', 'text'], attrs => {} });
    $spool->add({ dir => '/src', file => 'a.txt', line => 1, text => 'hello' });
    $spool->add({ dir => '/src', file => 'a.txt', line => 2, text => 'world' });
    $spool->add({ dir => '/src', file => 'b.txt', line => 1, text => 'xxx' });
    $spool->close();
    Spool::group('test001', ['dir', 'file'], ['line']);
    is Spool::count('test001'), 2, 'count=2 (dir+file groups)';
    my $g0 = Spool::get('test001', 0);
    is $g0->{dir},  '/src',   'g0 dir=/src';
    is $g0->{file}, 'a.txt',  'g0 file=a.txt';
    is scalar @{ $g0->{'@'} }, 2, 'g0 has 2 line groups';
    is $g0->{'@'}[0]{line}, 1,    'nested line=1';
    ok !exists $g0->{'@'}[0]{dir},  'dir removed from nested';
    ok !exists $g0->{'@'}[0]{file}, 'file removed from nested';
    cleanup();
};
```

### Step 6-2: テストが通ることを確認する（実装は既存）

- [ ] 実行する

```bash
perl -Ilib -Isrc test/spool.t
```

Expected: 全 subtest PASS（`_build_group` が再帰的に動作するため）

### Step 6-3: コミット

- [ ] 実行する

```bash
git add test/spool.t
git commit -m "test: add multi-level group tests"
```

---

## 自己レビューチェックリスト（実装後確認）

- [ ] spec の全エラー条件がテストでカバーされているか確認する

  - `open()`: invalid spool_id ✓、already exists ✓
  - `meta()`: after add ✓
  - `lines()`/`records()`/`group()`: already confirmed ✓、invalid spool data ✓
  - `group()`: order missing ✓
  - `records()`/`group()`: out-of-order key ✓、key col missing ✓
  - `count()`/`get()`: not confirmed ✓
  - `get()`: out of range ✓

- [ ] 全テストが通っていることを最終確認する

```bash
perl -Ilib -Isrc test/spool.t
```

Expected: `1..N` の全テスト PASS、`ok N - ...` のみ

