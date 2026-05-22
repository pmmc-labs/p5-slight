
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;

my $r   = Slight::Runtime->new->init;
my $ctx = $r->spawn_context(q[

(let x 10)
(let y 20)

(+ x y)

]);

my @done = $r->run;

say sprintf 'PID:%04d => %s' => $_->PID, $_->result // $_->error foreach @done;

