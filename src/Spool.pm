package Spool;

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

# ---- mode finalization functions ----

sub lines {
    my ($spool_id) = @_;
    my $dir = "$BASE/$spool_id";
    die "already confirmed: $spool_id" if -d "$dir/items";
    _run_in_fork($dir, sub {
        my $rows = do "$dir/rows.do";
        die "invalid spool data for $spool_id: $@" if $@;
        die "invalid spool data for $spool_id" unless defined $rows;
        my $meta = _read_do("$dir/meta.do");
        my $items_tmp = "$dir/items_tmp";
        remove_tree($items_tmp) if -d $items_tmp;
        mkdir $items_tmp or die "Cannot create items_tmp/: $!";
        my $count = 0;
        for my $row (@$rows) {
            _write_do(sprintf('%s/%08d.do', $items_tmp, $count), $row);
            $count++;
        }
        rename $items_tmp, "$dir/items" or die "Cannot rename items: $!";
        $meta->{mode}  = 'lines';
        $meta->{count} = $count;
        _write_do("$dir/meta.do", $meta);
        unlink "$dir/rows.do";
    });
    my $meta = _read_do("$dir/meta.do");
    return $meta->{count};
}

sub records {
    my ($spool_id, @key_cols) = @_;
    my $dir = "$BASE/$spool_id";
    die "already confirmed: $spool_id" if -d "$dir/items";
    _run_in_fork($dir, sub {
        my $rows = do "$dir/rows.do";
        die "invalid spool data for $spool_id: $@" if $@;
        die "invalid spool data for $spool_id" unless defined $rows;
        my $meta = _read_do("$dir/meta.do");

        # キー列の存在を事前確認（エラーメッセージを保証する）
        for my $row (@$rows) {
            for my $col (@key_cols) {
                die "key column '$col' not found in row" unless exists $row->{$col};
            }
        }

        # TableTools で 1 段階グルーピング（非連続再出現は TableTools が die する）
        my $table;
        if ($meta->{attrs} && %{ $meta->{attrs} }) {
            $table = attach($rows, { '#' => { attrs => $meta->{attrs}, order => $meta->{order} } });
            $table = validate($table);
        } else {
            $table = validate($rows, $meta->{order});
        }
        my $grouped = TableTools::group($table, [@key_cols]);
        my ($grouped_rows) = detach($grouped);

        # 各グループのキー列値を子行にマージして item を構成する
        my $items_tmp = "$dir/items_tmp";
        remove_tree($items_tmp) if -d $items_tmp;
        mkdir $items_tmp or die "Cannot create items_tmp/: $!";
        my $count = 0;
        for my $g (@$grouped_rows) {
            my %key_vals = map { $_ => $g->{$_} } @key_cols;
            my @item = map { { %key_vals, %$_ } } @{ $g->{'@'} };
            _write_do(sprintf('%s/%08d.do', $items_tmp, $count), \@item);
            $count++;
        }
        rename $items_tmp, "$dir/items" or die "Cannot rename items: $!";

        $meta->{mode}     = 'records';
        $meta->{count}    = $count;
        $meta->{key_cols} = \@key_cols;
        _write_do("$dir/meta.do", $meta);
        unlink "$dir/rows.do";
    });
    my $meta = _read_do("$dir/meta.do");
    return $meta->{count};
}

sub group {
    my ($spool_id, @groups) = @_;
    my $dir = "$BASE/$spool_id";
    die "already confirmed: $spool_id" if -d "$dir/items";
    my $meta = _read_do("$dir/meta.do");
    die "order is required for group(): $spool_id" unless $meta->{order};
    my $rows = do "$dir/rows.do";
    die "invalid spool data for $spool_id: $@" if $@;
    die "invalid spool data for $spool_id" unless defined $rows;

    # Phase 1: validate and group in memory (die here leaves no partial state)
    my $items;
    if (@$rows) {
        my $table;
        # attrs が空ハッシュの場合は未設定扱いとして自動型検出ルートを使う
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
