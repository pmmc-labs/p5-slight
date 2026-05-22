
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;

my $r   = Slight::Runtime->new->init;
my $program = $r->spawn_context(q[

(do
    (say "Hi")
    (raise (list 1 2 3 4))
    (say "Ho"))

]);

my @ctxs = $r->run_all($program);

say $_->result // $_->error foreach @ctxs;

