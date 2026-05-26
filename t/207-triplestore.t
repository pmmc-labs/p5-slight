
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
    (($index{ $s->hash } //= +{})
          ->{ $p->hash } //= +{})
          ->{ $o->hash }
            = $alloc->List( $s, $p, $o )
}

sub query ($s, $p, $o) {
    $alloc->contains(
        Slight::Term::Cons->hash_of(
            $s->hash,
            Slight::Term::Cons->hash_of(
                $p->hash,
                Slight::Term::Cons->hash_of(
                    $o->hash,
                    $alloc->Nil->hash
                )
            )
        )
    )
}

sub match_predicate ($s, $p) {
    map { $alloc->lookup($_) }
    sort { $a cmp $b }
    keys $index{ $s->hash }->{ $p->hash }->%*
}

sub predicates_for ($s) {
    map { $alloc->lookup($_) }
    sort { $a cmp $b }
    keys $index{ $s->hash }->%*
}

sub relations_between ($s, $o) {
    my $subject = $index{ $s->hash };
    my @relations;
    foreach my $p (keys %$subject) {
        push @relations => $alloc->lookup( $p )
            if exists $subject->{ $p }->{ $o->hash };
    }
    return @relations;
}

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
    declare( $dirk, $has_name, $alloc->Str("Dirk Smith") ),
    declare( $dirk, $has_age,  $alloc->Num(46) ),

    declare( $alice, $has_name, $alloc->Str("Alice Jones") ),
    declare( $alice, $has_age,  $alloc->Num(46) ),

    declare( $bob, $has_name, $alloc->Str("Bob Smith") ),
    declare( $bob, $has_age,  $alloc->Num(3) ),

    declare( $cathy, $has_name, $alloc->Str("Cathy Jones") ),
    declare( $cathy, $has_age,  $alloc->Num(23) ),

    # relations
    declare( $dirk,  $has_child,  $cathy ),
    declare( $cathy, $has_parent, $dirk  ),

    declare( $alice, $has_child,  $cathy ),
    declare( $cathy, $has_parent, $alice ),

    declare( $cathy, $has_child,  $bob   ),
    declare( $bob,   $has_parent, $cathy ),
);

dump_index(\%index);

sub is_parent_of ($p) {
    return match_predicate( $p, $has_child );
}

sub is_grandparent_of ($p) {
    my @matches = match_predicate( $p, $has_child );
    return () unless @matches;
    foreach my $m (@matches) {
        if (my @children = match_predicate($m, $has_child)) {
            return @children;
        }
    }
    return ();
}

say 'DIRK HAS CHILDREN: ', join ', ' => is_parent_of( $dirk );
say 'DIRK HAS GRANDCHILDREN: ', join ', ' => is_grandparent_of( $dirk );
say 'CATHY HAS PARENTS: ', join ', ' => match_predicate( $cathy, $has_parent );
say 'BOB HAS PARENTS: ', join ', ' => match_predicate( $bob, $has_parent );


