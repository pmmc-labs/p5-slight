
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight::Allocator;
use Slight::WorkingMemory;

my $alloc = Slight::Allocator->new;
my $ts    = Slight::WorkingMemory->new( alloc => $alloc );

my $bob   = $alloc->Sym('Bob');
my $alice = $alloc->Sym('Alice');
my $chris = $alloc->Sym('Chris');

my $has_first_name = $alloc->Sym('has-first-name');
my $has_last_name  = $alloc->Sym('has-last-name');
my $has_age        = $alloc->Sym('has-age');
my $knows          = $alloc->Sym('knows?');
my $works_with     = $alloc->Sym('works-with?');

my @facts = (
    $ts->assert( $bob, $has_first_name, $alloc->Str("Robert") ),
    $ts->assert( $bob, $has_last_name,  $alloc->Str("Smith") ),
    $ts->assert( $bob, $has_age,        $alloc->Num(50) ),

    $ts->assert( $alice, $has_first_name, $alloc->Str("Allison") ),
    $ts->assert( $alice, $has_last_name,  $alloc->Str("Chains") ),
    $ts->assert( $alice, $has_age,        $alloc->Num(40) ),

    $ts->assert( $chris, $has_first_name, $alloc->Str("Christopher") ),
    $ts->assert( $chris, $has_last_name,  $alloc->Str("Cross") ),
    $ts->assert( $chris, $has_age,        $alloc->Num(60) ),

    $ts->assert( $bob, $knows, $alice ),
    $ts->assert( $bob, $knows, $chris ),
    $ts->assert( $chris, $knows, $bob ),
    $ts->assert( $alice, $knows, $bob ),
    $ts->assert( $alice, $knows, $chris ),
    $ts->assert( $alice, $works_with, $chris ),
    $ts->assert( $chris, $works_with, $alice ),
);

say $_ foreach @facts;
say '-' x 100;
say '( alice _          chris) = ', join ', ' => $ts->query( $alice,   undef,     $chris );
say '( _     works-with alice) = ', join ', ' => $ts->query( undef,   $works_with, $alice );
say '( bob _       _     ) = ', join ', ' => $ts->query( $bob, undef, undef );
say '( _   _       chris ) = ', join ', ' => $ts->query( undef, undef, $chris );
say '( _   has-age _     ) = ', join ', ' => $ts->query( undef, $has_age, undef );



