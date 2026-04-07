# Spool

[日本語版はこちら](README_ja.md)

A Perl package for buffering row data to files, designed to pass large datasets to child processes after fork without consuming memory in the parent.

## Overview

Spool separates data collection (write phase) from data finalization (confirm phase). The parent process appends rows via an object API; a separate process (e.g., after fork) confirms the spool using a function API with only the `spool_id` string.

Three confirmation modes are available:

| Mode | Description |
|---|---|
| `lines` | Each row becomes an individual item |
| `records` | Consecutive rows with the same key(s) are grouped |
| `group` | Rows are organized into a nested hierarchy |

## Requirements

- Perl 5.10+
- `Data::Dumper` (core)
- `File::Path` (core)

## Installation

Copy `src/Spool.pm` to your project and add `src/` to `PERL5LIB`.

## Usage

### Write Phase (Object API)

```perl
use Spool;

my $spool = Spool->open('myspool');          # create spool
$spool->meta({ order => ['file', 'line'] }); # optional metadata
$spool->add({ file => 'a.txt', line => 1 }); # append rows
$spool->add({ file => 'a.txt', line => 2 });
$spool->close();                             # finalize write
```

`meta()` must be called before any `add()`. `order` is required when using `group()`.

### Confirm Phase (Function API, no object needed)

```perl
# lines: each row becomes one item
Spool::lines('myspool');

# records: consecutive same-key rows become one item
Spool::records('myspool', 'file');

# group: hierarchical grouping (requires order in meta)
Spool::group('myspool', ['file']);
```

### Reading Results

```perl
my $count = Spool::count('myspool');

for my $i (0 .. $count - 1) {
    my $item = Spool::get('myspool', $i);
    # $item is a hashref (lines/group) or arrayref (records)
}

Spool::remove('myspool'); # delete spool when done
```

### group() Item Structure

Given rows with `order = ['file', 'line', 'text']` and `group('id', ['file'])`:

```perl
# Item 0:
{
    file => 'a.txt',
    '@'  => [
        { line => 1, text => 'hello' },
        { line => 2, text => 'world' },
    ],
}
```

Columns not listed in `order` are excluded from children.

## spool_id Rules

Must match `/\A[A-Za-z0-9]+\z/`. Hyphens, underscores, spaces, dots, non-ASCII characters, and empty strings are rejected.

## Storage

All spools are stored under `/tmp/spool/<spool_id>/`.

| File | Present When | Contents |
|---|---|---|
| `rows.do` | After open, before confirm | Array of row hashrefs |
| `meta.do` | After close (partial) / after confirm (complete) | Metadata hash |
| `items/NNNNNNNN.do` | After confirm | Individual items |

## Error Handling

| Condition | Behavior |
|---|---|
| Invalid `spool_id` | `die` |
| Duplicate `open` | `die` |
| `meta()` after `add()` | `die` |
| Confirm on already-confirmed spool | `die` |
| Missing key column in row | `die` |
| Out-of-order key reappearance | `die` |
| Missing `order` for `group()` | `die` |
| `get()` with out-of-range index | `die` |
| `count()`/`get()` on unconfirmed spool | `die` |

## License

MIT
