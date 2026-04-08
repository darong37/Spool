# group() TableTools 委譲 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Spool::group()` の内部実装をカスタム実装から `TableTools::validate` → `TableTools::group` → `TableTools::detach` への委譲に切り替える。

**Architecture:** `src/Spool.pm` の `group()` のみを変更する。`_build_group` / `_make_group_item` を削除し、`TableTools` に全面委譲する。rows が空の場合は validate/group をスキップして 0 件確定する。`order` は全列の完全列挙が必須で、不一致は validate が die する。

**Tech Stack:** Perl, TableTools（`lib/TableTools.pm`）, Test::More

---

## 変更ファイル一覧

| ファイル | 変更内容 |
|---|---|
| `src/Spool.pm` | `use TableTools` 追加、`group()` を全面書き換え、`_build_group` / `_make_group_item` 削除 |
| `test/spool.t` | テスト38修正（extra 列削除）、テスト43b/43c 新規追加 |

---

### Task 1: テスト38の修正とテスト43b/43c の追加（先にテストを壊す）

**Files:**
- Modify: `test/spool.t:561-583`

- [ ] **Step 1: テスト38を新仕様に合わせて修正する**

`test/spool.t` の `group() single-level produces grouped items` を以下に置き換える：

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
    is Spool::count('test001'), 2,       'count=2 groups';
    my $g0 = Spool::get('test001', 0);
    is $g0->{file}, 'a.txt',             'group 0 file=a.txt';
    is scalar @{ $g0->{'@'} }, 2,        'group 0 has 2 children';
    is $g0->{'@'}[0]{line}, 1,           'child 0 line=1';
    is $g0->{'@'}[0]{text}, 'hello',     'child 0 text=hello';
    ok !exists $g0->{'@'}[0]{file},      'file key removed from child';
    my $g1 = Spool::get('test001', 1);
    is $g1->{file}, 'b.txt',             'group 1 file=b.txt';
    is scalar @{ $g1->{'@'} }, 1,        'group 1 has 1 child';
    cleanup();
};
```

- [ ] **Step 2: テスト43b（order 外の列で die）を追加する**

上記テスト38の直後（`group() works with order only` の前）に追加する：

```perl
subtest 'group() dies if row has column not in order' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->meta({ order => ['file', 'line'] });
    $spool->add({ file => 'a.txt', line => 1, extra => 'unexpected' });
    $spool->close();
    eval { Spool::group('test001', ['file']) };
    like $@, qr/column count mismatch|unexpected column/, 'dies when row has column not in order';
    cleanup();
};
```

- [ ] **Step 3: テスト43c（空 spool の 0 件確定）を追加する**

テスト43b の直後に追加する：

```perl
subtest 'group() confirms with 0 items on empty spool' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->meta({ order => ['file', 'line'] });
    $spool->close();
    my $count = Spool::group('test001', ['file']);
    is $count, 0,                    '0 items confirmed';
    is Spool::count('test001'), 0,   'count() returns 0';
    ok -d '/tmp/spool/test001/items', 'items/ exists';
    ok !-f '/tmp/spool/test001/rows.do', 'rows.do removed';
    cleanup();
};
```

- [ ] **Step 4: テストを実行して失敗を確認する**

```bash
cd /Users/darong/PRJDEV/Spool && perl -Isrc -Ilib test/spool.t 2>&1 | tail -20
```

期待される結果: テスト38が PASS（extra 列を除いたので現行実装でも通る可能性あり）、テスト43b が FAIL（現行実装は extra を無視するため die しない）、テスト43c が PASS（現行実装でも空は 0 件確定できる可能性あり）

---

### Task 2: `src/Spool.pm` の `group()` を TableTools に委譲する

**Files:**
- Modify: `src/Spool.pm`

- [ ] **Step 1: `use TableTools` をファイル先頭に追加する**

`src/Spool.pm` の `use File::Path` の行の直後に追加する：

```perl
use TableTools qw(validate detach attach);
# TableTools::group は完全修飾で呼ぶ（Spool::group との衝突回避）
```

- [ ] **Step 2: `group()` を書き換える**

`src/Spool.pm` の `sub group` から `sub count` の手前までを以下に置き換える：

```perl
sub group {
    my ($spool_id, @groups) = @_;
    my $dir = "$BASE/$spool_id";
    die "already confirmed: $spool_id" if -d "$dir/items";
    my $meta = _read_do("$dir/meta.do");
    die "order is required for group()" unless $meta->{order};
    my $rows = do "$dir/rows.do";
    die "invalid spool data for $spool_id: $@" if $@;
    die "invalid spool data for $spool_id" unless defined $rows;

    # Phase 1: validate and group in memory (die here leaves no partial state)
    my $items;
    if (@$rows) {
        my $table;
        if ($meta->{attrs} && %{ $meta->{attrs} }) {
            $table = attach($rows, { '#' => { attrs => $meta->{attrs}, order => $meta->{order} } });
        } else {
            $table = validate($rows, $meta->{order});
        }
        my $grouped = TableTools::group($table, @groups);
        ($items) = detach($grouped);
    } else {
        $items = [];
    }

    # Phase 2: write atomically via items_tmp/ → items/
    my $items_tmp = "$dir/items_tmp";
    remove_tree($items_tmp) if -d $items_tmp;
    mkdir $items_tmp or die "Cannot create items_tmp/: $!";
    my $count = 0;
    for my $item (@$items) {
        _write_do(sprintf('%s/%08d.do', $items_tmp, $count), $item);
        $count++;
    }
    rename $items_tmp, "$dir/items" or die "Cannot rename items: $!";
    $meta->{mode}   = 'group';
    $meta->{count}  = $count;
    $meta->{groups} = \@groups;
    _write_do("$dir/meta.do", $meta);
    unlink "$dir/rows.do";
    return $count;
}
```

- [ ] **Step 3: `_build_group` と `_make_group_item` を削除する**

`src/Spool.pm` から以下の2つのサブルーチンを削除する（`sub _build_group { ... }` と `sub _make_group_item { ... }`）。

- [ ] **Step 4: テストを実行して全テストが通ることを確認する**

```bash
cd /Users/darong/PRJDEV/Spool && perl -Isrc -Ilib test/spool.t 2>&1
```

期待される結果: `All tests successful.` またはすべての subtest が `ok`。

- [ ] **Step 5: コミットする**

```bash
cd /Users/darong/PRJDEV/Spool
git add src/Spool.pm test/spool.t
git commit -m "feat: delegate group() to TableTools::validate/group/detach"
```
