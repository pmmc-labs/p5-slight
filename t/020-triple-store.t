
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight::Allocator;
use Slight::WorkingMemory;

my $alloc = Slight::Allocator->new;
my $wm    = Slight::WorkingMemory->new( alloc => $alloc );

my $bob   = $alloc->Sym('Bob');
my $alice = $alloc->Sym('Alice');
my $chris = $alloc->Sym('Chris');

my $has_first_name = $alloc->Sym('has-first-name');
my $has_last_name  = $alloc->Sym('has-last-name');
my $has_age        = $alloc->Sym('has-age');
my $knows          = $alloc->Sym('knows?');
my $works_with     = $alloc->Sym('works-with?');

my @facts = (
    $wm->assert( $bob, $has_first_name, $alloc->Str("Robert") ),
    $wm->assert( $bob, $has_last_name,  $alloc->Str("Smith") ),
    $wm->assert( $bob, $has_age,        $alloc->Num(50) ),

    $wm->assert( $alice, $has_first_name, $alloc->Str("Allison") ),
    $wm->assert( $alice, $has_last_name,  $alloc->Str("Chains") ),
    $wm->assert( $alice, $has_age,        $alloc->Num(40) ),

    $wm->assert( $chris, $has_first_name, $alloc->Str("Christopher") ),
    $wm->assert( $chris, $has_last_name,  $alloc->Str("Cross") ),
    $wm->assert( $chris, $has_age,        $alloc->Num(60) ),

    $wm->assert( $bob, $knows, $alice ),
    $wm->assert( $bob, $knows, $chris ),
    $wm->assert( $chris, $knows, $bob ),
    $wm->assert( $alice, $knows, $bob ),
    $wm->assert( $alice, $knows, $chris ),
    $wm->assert( $alice, $works_with, $chris ),
    $wm->assert( $chris, $works_with, $alice ),
);

my $__ = $wm->HOLE;

say $_ foreach @facts;
say '-' x 100;
say '( alice _          chris) = ', join ', ' => $wm->query( $alice, $__,         $chris );
say '( _     works-with alice) = ', join ', ' => $wm->query( $__,    $works_with, $alice );
say '( bob _       _     ) = ', join ', ' => $wm->query( $bob, $__,      $__ );
say '( _   _       chris ) = ', join ', ' => $wm->query( $__,  $__,      $chris );
say '( _   has-age _     ) = ', join ', ' => $wm->query( $__,  $has_age, $__ );



