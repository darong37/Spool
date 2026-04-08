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
    eval { Spool->open('bad-id') };
    like $@, qr/invalid spool_id/, 'dies on hyphen';
    eval { Spool->open('bad_id') };
    like $@, qr/invalid spool_id/, 'dies on underscore';
    eval { Spool->open('bad.id') };
    like $@, qr/invalid spool_id/, 'dies on dot';
    eval { Spool->open('日本語') };
    like $@, qr/invalid spool_id/, 'dies on non-ascii';
    eval { Spool->open('') };
    like $@, qr/invalid spool_id/, 'dies on empty string';
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

subtest 'close() without meta() writes empty meta.do' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ a => 1 });
    $spool->close();
    my $meta = do "$BASE/test001/meta.do";
    is_deeply $meta, {}, 'meta.do is empty hash without meta()';
    ok !exists $meta->{count}, 'no count in partial meta.do';
    ok !exists $meta->{mode},  'no mode in partial meta.do';
    cleanup();
};

subtest 'close() with meta() writes partial meta.do (no count/mode)' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->meta({ order => ['a', 'b'], attrs => { a => 'num' } });
    $spool->add({ a => 1, b => 'x' });
    $spool->close();
    my $meta = do "$BASE/test001/meta.do";
    is_deeply $meta->{order}, ['a', 'b'], 'order in partial meta.do';
    is $meta->{attrs}{a}, 'num',          'attrs in partial meta.do';
    ok !exists $meta->{count},            'no count in partial meta.do';
    ok !exists $meta->{mode},             'no mode in partial meta.do';
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

subtest 'mode confirm works with spool_id only (no object needed)' => sub {
    cleanup();
    {
        my $spool = Spool->open('test001');
        $spool->add({ a => 1 });
        $spool->add({ a => 2 });
        $spool->close();
        # オブジェクト $spool はここで破棄される
    }
    # 別プロセス相当: spool_id だけで確定できる
    Spool::lines('test001');
    is Spool::count('test001'), 2, 'confirmed by spool_id only';
    cleanup();
};

subtest 'lines() creates items/ and removes rows.do' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ a => 1 });
    $spool->add({ a => 2 });
    $spool->close();
    Spool::lines('test001');
    ok -d  "$BASE/test001/items",             'items/ created';
    ok -f  "$BASE/test001/items/00000000.do", 'item 0 exists';
    ok -f  "$BASE/test001/items/00000001.do", 'item 1 exists';
    ok !-f "$BASE/test001/rows.do",           'rows.do removed';
    my $item = do "$BASE/test001/items/00000000.do";
    is $item->{a}, 1, 'item 0 has a=1';
    cleanup();
};

subtest 'lines() overwrites partial meta.do with complete form (no meta)' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ a => 1 });
    $spool->add({ a => 2 });
    $spool->close();
    Spool::lines('test001');
    my $complete = do "$BASE/test001/meta.do";
    is $complete->{mode},  'lines', 'mode=lines';
    is $complete->{count}, 2,       'count=2';
    ok !exists $complete->{order},  'no order when meta() not called';
    ok !exists $complete->{attrs},  'no attrs when meta() not called';
    cleanup();
};

subtest 'lines() overwrites partial meta.do with complete form (with meta)' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->meta({ order => ['a'], attrs => { a => 'num' } });
    $spool->add({ a => 1 });
    $spool->add({ a => 2 });
    $spool->close();
    my $partial = do "$BASE/test001/meta.do";
    ok !exists $partial->{count}, 'no count before lines()';
    ok !exists $partial->{mode},  'no mode before lines()';
    Spool::lines('test001');
    my $complete = do "$BASE/test001/meta.do";
    is $complete->{mode},  'lines',     'mode=lines in complete meta.do';
    is $complete->{count}, 2,           'count=2 in complete meta.do';
    is_deeply $complete->{order}, ['a'], 'order preserved in complete meta.do';
    is $complete->{attrs}{a}, 'num',    'attrs preserved in complete meta.do';
    cleanup();
};

subtest 'lines() dies if already confirmed' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ a => 1 });
    $spool->close();
    Spool::lines('test001');
    eval { Spool::lines('test001') };
    like $@, qr/already confirmed/, 'lines() dies on re-confirm';
    eval { Spool::records('test001', 'a') };
    like $@, qr/already confirmed/, 'records() dies on already-lines spool';
    eval { Spool::group('test001', ['a']) };
    like $@, qr/already confirmed/, 'group() dies on already-lines spool';
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
    Spool::_write_do("$BASE/test001/meta.do", {});
    eval { Spool::lines('test001') };
    like $@, qr/invalid spool data/, 'dies on broken rows.do';
    cleanup();
};

subtest 'records() dies on invalid spool data' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ file => 'a.txt' });
    CORE::close $spool->{fh};
    open my $fh, '>:encoding(UTF-8)', "$BASE/test001/rows.do";
    print $fh "[ { file => 'a.txt' },\n";  # ] がない不正データ
    CORE::close $fh;
    Spool::_write_do("$BASE/test001/meta.do", {});
    eval { Spool::records('test001', 'file') };
    like $@, qr/invalid spool data/, 'records() dies on broken rows.do';
    cleanup();
};

subtest 'group() dies on invalid spool data' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ file => 'a.txt' });
    CORE::close $spool->{fh};
    open my $fh, '>:encoding(UTF-8)', "$BASE/test001/rows.do";
    print $fh "[ { file => 'a.txt' },\n";  # ] がない不正データ
    CORE::close $fh;
    Spool::_write_do("$BASE/test001/meta.do", { order => ['file'] });
    eval { Spool::group('test001', ['file']) };
    like $@, qr/invalid spool data/, 'group() dies on broken rows.do';
    cleanup();
};

subtest 'count() returns item count after lines()' => sub {
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

subtest 'count() returns group count after records()' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ file => 'a.txt', line => 1 });
    $spool->add({ file => 'a.txt', line => 2 });
    $spool->add({ file => 'b.txt', line => 1 });
    $spool->close();
    Spool::records('test001', 'file');
    is Spool::count('test001'), 2, 'count=2 groups after records()';
    cleanup();
};

subtest 'count() returns top-level group count after group()' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->meta({ order => ['file', 'line'], attrs => {} });
    $spool->add({ file => 'a.txt', line => 1 });
    $spool->add({ file => 'a.txt', line => 2 });
    $spool->add({ file => 'b.txt', line => 1 });
    $spool->close();
    Spool::group('test001', ['file']);
    is Spool::count('test001'), 2, 'count=2 top-level groups after group()';
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

subtest 'get() returns correct item after lines()' => sub {
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

subtest 'get() returns correct group after records()' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ file => 'a.txt', line => 1 });
    $spool->add({ file => 'a.txt', line => 2 });
    $spool->close();
    Spool::records('test001', 'file');
    my $g = Spool::get('test001', 0);
    is ref($g), 'ARRAY',         'get() returns arrayref after records()';
    is scalar @$g, 2,            'group has 2 rows';
    is $g->[0]{file}, 'a.txt',   'row 0 file=a.txt';
    is $g->[1]{line}, 2,         'row 1 line=2';
    cleanup();
};

subtest 'get() returns correct group after group()' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->meta({ order => ['file', 'line', 'text'], attrs => {} });
    $spool->add({ file => 'a.txt', line => 1, text => 'hello' });
    $spool->add({ file => 'a.txt', line => 2, text => 'world' });
    $spool->close();
    Spool::group('test001', ['file']);
    my $g = Spool::get('test001', 0);
    is ref($g), 'HASH',          'get() returns hashref after group()';
    is $g->{file}, 'a.txt',      'group file=a.txt';
    is scalar @{ $g->{'@'} }, 2, 'group has 2 children';
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

subtest 'remove() deletes unconfirmed spool directory' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ a => 1 });
    $spool->close();
    Spool::remove('test001');
    ok !-d "$BASE/test001", 'unconfirmed spool dir removed';
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

subtest 'records() confirms by spool_id only (no object)' => sub {
    cleanup();
    {
        my $spool = Spool->open('test001');
        $spool->add({ file => 'a.txt', line => 1 });
        $spool->add({ file => 'b.txt', line => 1 });
        $spool->close();
    }
    Spool::records('test001', 'file');
    is Spool::count('test001'), 2, 'confirmed by spool_id only';
    cleanup();
};

subtest 'records() creates items/ and removes rows.do' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ file => 'a.txt', line => 1 });
    $spool->add({ file => 'b.txt', line => 1 });
    $spool->close();
    Spool::records('test001', 'file');
    ok -d  "$BASE/test001/items",             'items/ created';
    ok -f  "$BASE/test001/items/00000000.do", 'item 0 exists';
    ok -f  "$BASE/test001/items/00000001.do", 'item 1 exists';
    ok !-f "$BASE/test001/rows.do",           'rows.do removed';
    cleanup();
};

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

subtest 'records() overwrites partial meta.do with complete form (no meta)' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ file => 'a.txt', line => 1 });
    $spool->add({ file => 'b.txt', line => 1 });
    $spool->close();
    my $partial = do "$BASE/test001/meta.do";
    ok !exists $partial->{mode},     'no mode before records()';
    ok !exists $partial->{key_cols}, 'no key_cols before records()';
    Spool::records('test001', 'file');
    my $complete = do "$BASE/test001/meta.do";
    is $complete->{mode},  'records',          'mode=records';
    is $complete->{count}, 2,                  'count=2';
    is_deeply $complete->{key_cols}, ['file'], 'key_cols in complete meta.do';
    ok !exists $complete->{order},             'no order when meta() not called';
    ok !exists $complete->{attrs},             'no attrs when meta() not called';
    cleanup();
};

subtest 'records() overwrites partial meta.do with complete form (with meta)' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->meta({ order => ['file', 'line'], attrs => { file => 'str' } });
    $spool->add({ file => 'a.txt', line => 1 });
    $spool->add({ file => 'b.txt', line => 1 });
    $spool->close();
    Spool::records('test001', 'file');
    my $complete = do "$BASE/test001/meta.do";
    is $complete->{mode},  'records',                  'mode=records';
    is $complete->{count}, 2,                          'count=2';
    is_deeply $complete->{key_cols}, ['file'],         'key_cols preserved';
    is_deeply $complete->{order}, ['file', 'line'],    'order preserved';
    is $complete->{attrs}{file}, 'str',                'attrs preserved';
    cleanup();
};

subtest 'records() preserves input order within and across groups' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    # b.txt を先、a.txt を後（ソートされていない順序）
    $spool->add({ file => 'b.txt', line => 2 });
    $spool->add({ file => 'b.txt', line => 1 });
    $spool->add({ file => 'a.txt', line => 3 });
    $spool->close();
    Spool::records('test001', 'file');
    my $g0 = Spool::get('test001', 0);
    my $g1 = Spool::get('test001', 1);
    is $g0->[0]{file}, 'b.txt', 'first group is b.txt (input order preserved)';
    is $g0->[0]{line}, 2,       'b.txt row 0 is line=2 (input order preserved)';
    is $g0->[1]{line}, 1,       'b.txt row 1 is line=1 (input order preserved)';
    is $g1->[0]{file}, 'a.txt', 'second group is a.txt (input order preserved)';
    cleanup();
};

subtest 'records() dies if already confirmed' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ file => 'a.txt', line => 1 });
    $spool->close();
    Spool::records('test001', 'file');
    eval { Spool::records('test001', 'file') };
    like $@, qr/already confirmed/, 'records() dies on re-confirm';
    eval { Spool::group('test001', ['file']) };
    like $@, qr/already confirmed/, 'group() dies on already-records spool';
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

subtest 'group() confirms by spool_id only (no object)' => sub {
    cleanup();
    {
        my $spool = Spool->open('test001');
        $spool->meta({ order => ['file', 'line'], attrs => {} });
        $spool->add({ file => 'a.txt', line => 1 });
        $spool->add({ file => 'b.txt', line => 1 });
        $spool->close();
    }
    Spool::group('test001', ['file']);
    is Spool::count('test001'), 2, 'confirmed by spool_id only';
    cleanup();
};

subtest 'group() creates items/ and removes rows.do' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->meta({ order => ['file', 'line'], attrs => {} });
    $spool->add({ file => 'a.txt', line => 1 });
    $spool->add({ file => 'b.txt', line => 1 });
    $spool->close();
    Spool::group('test001', ['file']);
    ok -d  "$BASE/test001/items",             'items/ created';
    ok -f  "$BASE/test001/items/00000000.do", 'item 0 exists';
    ok -f  "$BASE/test001/items/00000001.do", 'item 1 exists';
    ok !-f "$BASE/test001/rows.do",           'rows.do removed';
    cleanup();
};

subtest 'group() preserves input order within and across groups' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->meta({ order => ['file', 'line'], attrs => {} });
    # b.txt を先、a.txt を後（ソートされていない順序）
    $spool->add({ file => 'b.txt', line => 2 });
    $spool->add({ file => 'b.txt', line => 1 });
    $spool->add({ file => 'a.txt', line => 3 });
    $spool->close();
    Spool::group('test001', ['file']);
    my $g0 = Spool::get('test001', 0);
    my $g1 = Spool::get('test001', 1);
    is $g0->{file},            'b.txt', 'first group is b.txt (input order preserved)';
    is $g0->{'@'}[0]{line}, 2,          'b.txt child 0 is line=2 (input order preserved)';
    is $g0->{'@'}[1]{line}, 1,          'b.txt child 1 is line=1 (input order preserved)';
    is $g1->{file},            'a.txt', 'second group is a.txt (input order preserved)';
    cleanup();
};

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

subtest 'group() confirms with 0 items on empty spool' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->meta({ order => ['file', 'line'] });
    $spool->close();
    my $count = Spool::group('test001', ['file']);
    is $count, 0,                         '0 items confirmed';
    is Spool::count('test001'), 0,        'count() returns 0';
    ok -d "$BASE/test001/items",          'items/ exists';
    ok !-f "$BASE/test001/rows.do",       'rows.do removed';
    cleanup();
};

subtest 'group() works with order only (no attrs in meta)' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->meta({ order => ['file', 'line'] }); # attrs なし
    $spool->add({ file => 'a.txt', line => 1 });
    $spool->add({ file => 'b.txt', line => 1 });
    $spool->close();
    Spool::group('test001', ['file']);
    is Spool::count('test001'), 2, 'group() works without attrs';
    cleanup();
};

subtest 'group() dies if order not in meta' => sub {
    # meta() なし
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ file => 'a.txt', line => 1 });
    $spool->close();
    eval { Spool::group('test001', ['file']) };
    like $@, qr/order.*required/, 'dies without order in meta';
    cleanup();
    # meta() で attrs のみ指定した場合も die
    my $spool2 = Spool->open('test001');
    $spool2->meta({ attrs => { file => 'str' } }); # order なし
    $spool2->add({ file => 'a.txt' });
    $spool2->close();
    eval { Spool::group('test001', ['file']) };
    like $@, qr/order.*required/, 'dies with attrs but no order in meta';
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

subtest 'group() dies if key column missing from row' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->meta({ order => ['file', 'line'], attrs => {} });
    $spool->add({ line => 1 }); # file がない
    $spool->close();
    eval { Spool::group('test001', ['file']) };
    like $@, qr/column count mismatch|unexpected column|not found/, 'dies on missing key col';
    cleanup();
};

subtest 'group() overwrites partial meta.do with complete form' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->meta({ order => ['file', 'line'], attrs => {} });
    $spool->add({ file => 'a.txt', line => 1 });
    $spool->add({ file => 'b.txt', line => 1 });
    $spool->close();
    my $partial = do "$BASE/test001/meta.do";
    ok !exists $partial->{mode},   'no mode before group()';
    ok !exists $partial->{groups}, 'no groups before group()';
    Spool::group('test001', ['file']);
    my $complete = do "$BASE/test001/meta.do";
    is $complete->{mode},  'group',            'mode=group in complete meta.do';
    is $complete->{count}, 2,                  'count=2 in complete meta.do';
    is_deeply $complete->{groups}, [['file']],         'groups in complete meta.do';
    is_deeply $complete->{order},  ['file', 'line'],   'order preserved in complete meta.do';
    is_deeply $complete->{attrs},  {},                 'attrs preserved in complete meta.do';
    cleanup();
};

subtest 'all mode functions die if already confirmed (group mode)' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->meta({ order => ['file', 'line'], attrs => {} });
    $spool->add({ file => 'a.txt', line => 1 });
    $spool->close();
    Spool::group('test001', ['file']);
    eval { Spool::lines('test001') };
    like $@, qr/already confirmed/, 'lines() dies on already-group spool';
    eval { Spool::records('test001', 'file') };
    like $@, qr/already confirmed/, 'records() dies on already-group spool';
    eval { Spool::group('test001', ['file']) };
    like $@, qr/already confirmed/, 'group() dies on re-group spool';
    cleanup();
};

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

subtest 'lines() cleans up stale items_tmp/ from previous failed run' => sub {
    cleanup();
    my $spool = Spool->open('test001');
    $spool->add({ a => 1 });
    $spool->close();
    # 前回の失敗で残った items_tmp/ を再現
    mkdir "$BASE/test001/items_tmp";
    open my $fh, '>', "$BASE/test001/items_tmp/stale.do"; CORE::close $fh;
    Spool::lines('test001');
    ok  -d  "$BASE/test001/items",     'items/ created';
    ok  !-d "$BASE/test001/items_tmp", 'items_tmp/ cleaned up after lines()';
    cleanup();
};

done_testing;
