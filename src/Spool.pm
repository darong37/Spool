package Spool;

use strict;
use warnings;
use CommonIO qw(append_file dumpU8 dying read_do run_in_fork write_do write_file);
use File::Path qw(remove_tree);
use TableTools qw(validate detach attach);

my $BASE = '/tmp/spool';

sub _write_items {
    my ($dir, $mode, $items, $meta) = @_;
    my $items_tmp = "$dir/items_tmp";
    my $items_dir = "$dir/items";
    my $count = scalar @$items;

    remove_tree($items_tmp) if -d $items_tmp;

    if ($count) {
        remove_tree($items_dir) if -d $items_dir;
        mkdir $items_tmp or die "Cannot create items_tmp/: $!";
        for my $i (0 .. $count - 1) {
            write_do(sprintf('%s/%08d.do', $items_tmp, $i), $items->[$i]);
        }
        rename $items_tmp, $items_dir or die "Cannot rename items: $!";
    }

    $meta->{count} = $count;
    write_do("$dir/meta.do", $meta);
    write_do("$dir/spool.do", {
        ready => 1,
        empty => ($count == 0 ? 1 : 0),
        mode  => $mode,
    });
    unlink "$dir/rows.do";
}

# ---- write-side object API ----

sub open {
    my ($class, $spool_id) = @_;
    dying "invalid spool_id: '$spool_id'" unless $spool_id =~ /\A[A-Za-z0-9]+\z/;
    my $dir = "$BASE/$spool_id";
    dying "spool already exists: $dir" if -e $dir;
    mkdir $BASE unless -d $BASE;
    mkdir $dir or die "Cannot create $dir: $!";
    write_do("$dir/spool.do", { ready => 0, empty => undef, mode => undef });
    write_do("$dir/meta.do", {});
    write_file("$dir/rows.do", "use utf8;\n\n[\n");
    return bless {
        spool_id => $spool_id,
        dir      => $dir,
        meta     => undef,
        added    => 0,
    }, $class;
}

sub meta {
    my ($self, $meta) = @_;
    dying 'meta must be hashref' if ref($meta) ne 'HASH';
    if (exists $meta->{attrs}) {
        dying 'meta attrs must be hashref' if ref($meta->{attrs}) ne 'HASH';
    }
    if (exists $meta->{order}) {
        dying 'meta order must be arrayref' if ref($meta->{order}) ne 'ARRAY';
    }
    $self->{meta} = $meta;
    return $self;
}

sub add {
    my ($self, $row) = @_;
    my $str = dumpU8($row, indent => 0);
    append_file("$self->{dir}/rows.do", $str . ",\n");
    $self->{added}++;
    return $self;
}

sub close {
    my ($self) = @_;
    append_file("$self->{dir}/rows.do", "]\n");
    warn "spool closed with 0 rows: $self->{spool_id}\n" if $self->{added} == 0;
    my $meta = $self->{meta} // {};
    $meta->{count} = $self->{added};
    write_do("$self->{dir}/meta.do", $meta);
    return $self;
}

# ---- mode finalization functions ----

sub lines {
    my ($spool_id) = @_;
    my $dir = "$BASE/$spool_id";
    my $spool_state = read_do("$dir/spool.do");
    dying "already confirmed: $spool_id" if $spool_state->{ready};

    run_in_fork(sub {
        my $rows = read_do("$dir/rows.do");
        my $meta = read_do("$dir/meta.do");
        my $items = $rows;
        _write_items($dir, 'lines', $items, $meta);
    });
    return count($spool_id);
}

sub records {
    my ($spool_id, @key_cols) = @_;
    my $dir = "$BASE/$spool_id";
    my $spool_state = read_do("$dir/spool.do");
    dying "already confirmed: $spool_id" if $spool_state->{ready};

    run_in_fork(sub {
        my $rows = read_do("$dir/rows.do");
        my $meta = read_do("$dir/meta.do");
        for my $row (@$rows) {
            for my $col (@key_cols) {
                dying "key column '$col' not found in row" unless exists $row->{$col};
            }
        }
        my $table;
        if ($meta->{attrs} && %{ $meta->{attrs} }) {
            $table = attach($rows, { '#' => { attrs => $meta->{attrs}, order => $meta->{order} } });
            $table = validate($table);
        } else {
            $table = validate($rows, $meta->{order});
        }

        my $grouped = TableTools::group($table, [@key_cols]);
        my ($grouped_rows) = detach($grouped);
        my @items;
        for my $g (@$grouped_rows) {
            my %key_vals = map { $_ => $g->{$_} } @key_cols;
            push @items, [ map { { %key_vals, %$_ } } @{ $g->{'@'} } ];
        }

        $meta->{key_cols} = \@key_cols;
        _write_items($dir, 'records', \@items, $meta);
    });
    return count($spool_id);
}

sub grouping {
    my ($spool_id, @groups) = @_;
    my $dir = "$BASE/$spool_id";
    my $spool_state = read_do("$dir/spool.do");
    dying "already confirmed: $spool_id" if $spool_state->{ready};

    run_in_fork(sub {
        my $rows = read_do("$dir/rows.do");
        my $meta = read_do("$dir/meta.do");
        dying "order is required for grouping(): $spool_id" unless $meta->{order};
        my $table;
        if ($meta->{attrs} && %{ $meta->{attrs} }) {
            $table = attach($rows, { '#' => { attrs => $meta->{attrs}, order => $meta->{order} } });
            $table = validate($table);
        } else {
            $table = validate($rows, $meta->{order});
        }

        my $grouped = TableTools::group($table, @groups);
        my ($items) = detach($grouped);

        $meta->{groups} = \@groups;
        _write_items($dir, 'grouping', $items, $meta);
    });
    return count($spool_id);
}

sub count {
    my ($spool_id) = @_;
    my $dir = "$BASE/$spool_id";
    my $spool = read_do("$dir/spool.do");
    dying "spool not ready: $spool_id" unless $spool->{ready};
    return 0 if $spool->{empty};
    my $meta = read_do("$dir/meta.do");
    return $meta->{count};
}

sub get {
    my ($spool_id, $i) = @_;
    my $dir = "$BASE/$spool_id";
    my $spool = read_do("$dir/spool.do");
    dying "spool not ready: $spool_id" unless $spool->{ready};
    dying "index out of range: $i (empty spool)" if $spool->{empty};
    my $meta = read_do("$dir/meta.do");
    dying "index out of range: $i (count=$meta->{count})"
        unless defined $i && $i >= 0 && $i < $meta->{count};
    return read_do(sprintf '%s/items/%08d.do', $dir, $i);
}

sub remove {
    my ($spool_id) = @_;
    my $dir = "$BASE/$spool_id";
    remove_tree($dir) if -d $dir;
}

1;
