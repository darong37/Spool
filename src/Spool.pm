package Spool;

# Terms:
# spool_id は spool を識別する文字列で、[A-Za-z0-9]+ のみを許可する
# spool は /tmp/spool/<spool_id>/ に作られる 1 件分の退避領域
# write フェーズは親プロセスが open() / meta() / add() / close() を行う段階
# confirm フェーズは親とは別の fork プロセスが lines() / records() / group() を行う段階
# read フェーズは count() / get() / remove() で確定済み item を扱う段階
# rows.do は write フェーズで蓄積する全行データ
# meta.do は close() 後は部分形、confirm 後は完全形を持つ
# items/ は confirm 後の公開データ置き場
# lines モードは 1 行を 1 item として確定する
# records モードは同じキー値を持つ連続行を 1 item にまとめて確定する
# group モードは TableTools::validate / TableTools::group / TableTools::detach に委譲して階層 item を作る
#
# Rules:
# 親プロセスは write だけを担当し、全件読み込みや item ファイル生成をしてはいけない
# confirm は必ず親とは別の fork プロセスで行う
# プロセス間で受け渡すものはオブジェクトではなく spool_id 文字列だけにする
# confirm の入力となる rows は TableTools::validate を通せるのと同等の前提を満たしていなければならない
# 各 row は同じキー集合を持たなければならない
# row の undef 値は confirm 前に空文字へ正規化されていなければならない
# records() と group() に必要な並び順は呼び出し側が事前に整えておかなければならない
# records() は入力順をそのまま走査し、非連続な同一キーの再出現をエラーにする
# group() はできる限り TableTools を利用して構造化し、Spool 自体は退避と確定の責務に寄せる
# write 中の中間状態と confirm 後の公開状態は分けて扱う
# confirm 失敗時に壊れた items/ を公開してはいけない
# read フェーズの参照単位は spool_id と index に固定する
# confirm の 3 関数（lines/records/group）は全て fork した子プロセス内で実行する
# 親プロセスは fork 後に全件読み込みや item 生成を行ってはいけない
# 親プロセスは waitpid で子の正常終了を確認してから結果を参照する
# 子プロセスが正常終了しなかった場合は confirm 失敗として扱う

use strict;
use warnings;
use Data::Dumper;
use File::Path qw(remove_tree);
use POSIX qw(_exit);
use TableTools qw(validate detach attach);
# TableTools::group は完全修飾で呼ぶ（Spool::group との衝突回避）

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

sub _run_in_fork {
    my ($dir, $code) = @_;
    my $error_file = "$dir/error.do";
    unlink $error_file if -f $error_file;
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        eval { $code->() };
        my $err = $@;
        if ($err) {
            eval { _write_do($error_file, $err) };
            _exit(1);
        }
        _exit(0);
    }
    waitpid($pid, 0);
    if ($? != 0) {
        my $msg;
        if (-f $error_file) {
            $msg = do($error_file);
            $msg = "confirm failed (error.do unreadable: $@)" if $@;
        }
        $msg //= "confirm failed for spool in $dir";
        unlink $error_file if -f $error_file;
        die $msg;
    }
    unlink $error_file if -f $error_file;
}

# ---- write-side object API ----

sub open {
    my ($class, $spool_id) = @_;
    die "invalid spool_id: '$spool_id'" unless $spool_id =~ /\A[A-Za-z0-9]+\z/;
    my $dir = "$BASE/$spool_id";
    die "spool already exists: $dir" if -e $dir;
    mkdir $BASE unless -d $BASE;
    mkdir $dir or die "Cannot create $dir: $!";
    _write_do("$dir/spool.do", { ready => 0, empty => undef, mode => undef });
    _write_do("$dir/meta.do", {});
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
    warn "spool closed with 0 rows: $self->{spool_id}\n" if $self->{added} == 0;
    my $meta = $self->{meta} // {};
    $meta->{count} = $self->{added};
    _write_do("$self->{dir}/meta.do", $meta);
    return $self;
}

# ---- mode finalization functions ----

sub lines {
    my ($spool_id) = @_;
    my $dir = "$BASE/$spool_id";
    my $spool_state = _read_do("$dir/spool.do");
    die "already confirmed: $spool_id" if $spool_state->{ready} || -d "$dir/items"; # items/ check removed in Task4
    _run_in_fork($dir, sub {
        my $rows = do "$dir/rows.do";
        die "invalid spool data for $spool_id: $@" if $@;
        die "invalid spool data for $spool_id" unless defined $rows;
        my $items_tmp = "$dir/items_tmp";
        remove_tree($items_tmp) if -d $items_tmp;
        my $count = 0;
        if (@$rows) {
            mkdir $items_tmp or die "Cannot create items_tmp/: $!";
            for my $row (@$rows) {
                _write_do(sprintf('%s/%08d.do', $items_tmp, $count), $row);
                $count++;
            }
            rename $items_tmp, "$dir/items" or die "Cannot rename items: $!";
            my $meta = _read_do("$dir/meta.do");
            $meta->{count} = $count;
            _write_do("$dir/meta.do", $meta);
        }
        _write_do("$dir/spool.do", { ready => 1, empty => ($count == 0 ? 1 : 0), mode => 'lines' });
        unlink "$dir/rows.do";
    });
    my $state = _read_do("$dir/spool.do");
    return 0 if $state->{empty};
    my $meta = _read_do("$dir/meta.do");
    return $meta->{count};
}

sub records {
    my ($spool_id, @key_cols) = @_;
    my $dir = "$BASE/$spool_id";
    my $spool_state = _read_do("$dir/spool.do");
    die "already confirmed: $spool_id" if $spool_state->{ready} || -d "$dir/items"; # items/ check removed in Task4
    _run_in_fork($dir, sub {
        my $rows = do "$dir/rows.do";
        die "invalid spool data for $spool_id: $@" if $@;
        die "invalid spool data for $spool_id" unless defined $rows;
        my $meta = _read_do("$dir/meta.do");
        for my $row (@$rows) {
            for my $col (@key_cols) {
                die "key column '$col' not found in row" unless exists $row->{$col};
            }
        }
        my $items_tmp = "$dir/items_tmp";
        remove_tree($items_tmp) if -d $items_tmp;
        my $count = 0;
        if (@$rows) {
            my $table;
            if ($meta->{attrs} && %{ $meta->{attrs} }) {
                $table = attach($rows, { '#' => { attrs => $meta->{attrs}, order => $meta->{order} } });
                $table = validate($table);
            } else {
                $table = validate($rows, $meta->{order});
            }
            my $grouped = TableTools::group($table, [@key_cols]);
            my ($grouped_rows) = detach($grouped);
            mkdir $items_tmp or die "Cannot create items_tmp/: $!";
            for my $g (@$grouped_rows) {
                my %key_vals = map { $_ => $g->{$_} } @key_cols;
                my @item = map { { %key_vals, %$_ } } @{ $g->{'@'} };
                _write_do(sprintf('%s/%08d.do', $items_tmp, $count), \@item);
                $count++;
            }
            rename $items_tmp, "$dir/items" or die "Cannot rename items: $!";
            $meta->{count}    = $count;
            $meta->{key_cols} = \@key_cols;
            _write_do("$dir/meta.do", $meta);
        }
        _write_do("$dir/spool.do", { ready => 1, empty => ($count == 0 ? 1 : 0), mode => 'records' });
        unlink "$dir/rows.do";
    });
    my $state = _read_do("$dir/spool.do");
    return 0 if $state->{empty};
    my $meta = _read_do("$dir/meta.do");
    return $meta->{count};
}

sub group {
    my ($spool_id, @groups) = @_;
    my $dir = "$BASE/$spool_id";
    die "already confirmed: $spool_id" if -d "$dir/items";
    _run_in_fork($dir, sub {
        my $meta = _read_do("$dir/meta.do");
        die "order is required for group(): $spool_id" unless $meta->{order};
        my $rows = do "$dir/rows.do";
        die "invalid spool data for $spool_id: $@" if $@;
        die "invalid spool data for $spool_id" unless defined $rows;

        my $items;
        if (@$rows) {
            my $table;
            if ($meta->{attrs} && %{ $meta->{attrs} }) {
                $table = attach($rows, { '#' => { attrs => $meta->{attrs}, order => $meta->{order} } });
                $table = validate($table);
            } else {
                $table = validate($rows, $meta->{order});
            }
            my $grouped = TableTools::group($table, @groups);
            ($items) = detach($grouped);
        } else {
            $items = [];
        }

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
    });
    my $meta = _read_do("$dir/meta.do");
    return $meta->{count};
}

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

1;
