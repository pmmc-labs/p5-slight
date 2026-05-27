
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;


my $alloc = Slight::Allocator->new;

my %index;

sub dump_index ($index, $depth=0) {
    my $indent = '  ' x $depth;
    foreach my ($k, $v) ($index->%*) {
        if ($v isa Slight::Term::List) {
            say "${indent}╰─${k} = ${v}"
        }
        elsif (ref $v eq 'ARRAY') {
            say "${indent}╰─${k} ", join ', ' => @$v;
        } else {
            if ($depth == 0) {
                say "${indent}${k}";
            } else {
                say "${indent}╰─${k}";
            }
            dump_index($v, $depth + 1);
        }
    }
}

sub declare ($s, $p, $o) {
    (($index{ $o->hash } //= +{})
        ->{ $p->hash } //= +{})
        ->{ $s->hash }
        = $alloc->List( $s, $p, $o )
}

sub query_hash ($first, @rest) {
    return Slight::Term::Cons->hash_of( $first->hash, $alloc->Nil->hash ) if scalar @rest == 0;
    return Slight::Term::Cons->hash_of( $first->hash, query_hash( @rest ) );
}

sub query (@args) { $alloc->contains( query_hash( @args ) ) }

my $bob   = $alloc->Sym('Bob');
my $alice = $alloc->Sym('Alice');
my $cathy = $alloc->Sym('Cathy');
my $dirk  = $alloc->Sym('Dirk');

my $has_name   = $alloc->Sym('has:=name');
my $has_age    = $alloc->Sym('has:=age');
my $has_parent = $alloc->Sym('has:=parent');
my $has_child  = $alloc->Sym('has:=child');

my @facts = (
    # data
    declare( $dirk, $has_name,  $alloc->Str("Dirk Smith") ),
    declare( $dirk, $has_age,   $alloc->Num(46) ),
    declare( $dirk, $has_child, $cathy ),

    declare( $alice, $has_name,  $alloc->Str("Alice Jones") ),
    declare( $alice, $has_age,   $alloc->Num(46) ),
    declare( $alice, $has_child, $cathy ),

    declare( $cathy, $has_name,   $alloc->Str("Cathy Jones") ),
    declare( $cathy, $has_age,    $alloc->Num(23) ),
    declare( $cathy, $has_child,  $bob   ),

    declare( $bob, $has_name,   $alloc->Str("Bob Smith") ),
    declare( $bob, $has_age,    $alloc->Num(3) ),
);

dump_index(\%index);

say query( $has_child, $cathy ) ? 'y' : 'n';

say join ', ' => map { $alloc->lookup($_) } keys $index{ $cathy->hash }->{ $has_child->hash }->%*;



