
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight::Allocator;

class Edb {
    field $alloc :param :reader;

    field %facts;

    field %SPO;
    field %SOP;
    field %PSO;
    field %POS;
    field %OPS;
    field %OSP;

    my method index_fact ($s, $p, $o, $fact) {
        $facts{ $fact->hash } //= do {
            (($SPO{ $s->hash } //= +{})->{ $p->hash } //= +{})->{ $o->hash } =
            (($SOP{ $s->hash } //= +{})->{ $o->hash } //= +{})->{ $p->hash } =
            (($PSO{ $p->hash } //= +{})->{ $s->hash } //= +{})->{ $o->hash } =
            (($POS{ $p->hash } //= +{})->{ $o->hash } //= +{})->{ $s->hash } =
            (($OPS{ $o->hash } //= +{})->{ $p->hash } //= +{})->{ $s->hash } =
            (($OSP{ $o->hash } //= +{})->{ $s->hash } //= +{})->{ $p->hash } = $fact;
        }
    }

    method assert ($s, $p, $o) {
        die "Ground Facts cannot be symbols ($s $p $o)"
            if blessed $s eq 'Slight::Term::Sym'
            || blessed $p eq 'Slight::Term::Sym'
            || blessed $p eq 'Slight::Term::Sym';
        $self->&index_fact( $s, $p, $o, $alloc->Triple( $s, $p, $o ) );
    }

    my sub isSym  ($s) { blessed $s eq 'Slight::Term::Sym' }
    my sub isTerm ($t) { blessed $t ne 'Slight::Term::Sym' }

    method query ($s, $p, $o) {
        # s p o
        if (isTerm($s) && isTerm($p) && isTerm($o)) {
            return $SPO{ $s->hash }->{ $p->hash }->{ $o->hash };
        }
        # s p _
        if (isTerm($s) && isTerm($p) && isSym($o)) {
            return values $SPO{ $s->hash }->{ $p->hash }->%*;
        }
        # s _ o
        if (isTerm($s) && isSym($p) && isTerm($o)) {
            return values $SOP{ $s->hash }->{ $o->hash }->%*;
        }
        # _ p o
        if (isSym($s) && isTerm($p) && isTerm($o)) {
            return values $POS{ $p->hash }->{ $o->hash }->%*;
        }
        # _ p _
        if (isSym($s) && isTerm($p) && isSym($o)) {
            return map {
                values $PSO{ $p->hash }->{ $_ }->%*
            } keys $PSO{ $p->hash }->%*
        }
        # _ _ o
        if (isSym($s) && isSym($p) && isTerm($o)) {
            return map {
                values $OPS{ $o->hash }->{ $_ }->%*
            } keys $OPS{ $o->hash }->%*
        }
        # s _ _
        if (isTerm($s) && isSym($p) && isSym($o)) {
            return map {
                values $SPO{ $s->hash }->{ $_ }->%*
            } keys $SPO{ $s->hash }->%*
        }
    }
}

my $alloc = Slight::Allocator->new;

my $__ = $alloc->Sym('_');
my $X = $alloc->Sym('X');
my $Y = $alloc->Sym('Y');

my $Alice = $alloc->Tag('Alice');
my $Bob   = $alloc->Tag('Bob');
my $Carol = $alloc->Tag('Carol');
my $Dirk  = $alloc->Tag('Dirk');

my $is_a      = $alloc->Tag('is-a');
my $age_is    = $alloc->Tag('age-is');
my $parent_of = $alloc->Tag('parent-of');

my $Person = $alloc->Tag('Person');

my $edb = Edb->new( alloc => $alloc );

$edb->assert( $Alice, $is_a,   $Person );
$edb->assert( $Alice, $age_is, $alloc->Num(46) );

$edb->assert( $Bob,   $is_a,   $Person );
$edb->assert( $Bob,   $age_is, $alloc->Num(23) );

$edb->assert( $Carol, $is_a,   $Person );
$edb->assert( $Carol, $age_is, $alloc->Num(69) );

$edb->assert( $Dirk,  $is_a,   $Person );
$edb->assert( $Dirk,  $age_is, $alloc->Num(46) );

$edb->assert( $Carol, $parent_of, $Alice );
$edb->assert( $Alice, $parent_of, $Bob );
$edb->assert( $Dirk,  $parent_of, $Bob );


say $_ foreach $edb->query( $__, $age_is, $__ );























