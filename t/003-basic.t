
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;

my $r   = Slight::Runtime->new->init;
my $program = $r->spawn_context(q[



]);

$r->run($program);

my $fork = $r->fork_context($program, q[

]);

my @ctxs = $r->run_all($fork);

say $_->result // $_->error foreach @ctxs;

