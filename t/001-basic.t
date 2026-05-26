
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;

my $r   = Slight::Runtime->new->init;
my $ctx = $r->spawn_context(q[

(say "Hello World")

]);

my @done = $r->run;

say 'DONE:';
say sprintf '%s => %s' => $_->PID, $_->result // $_->error foreach @done;

