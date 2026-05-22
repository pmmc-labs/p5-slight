
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;

my $r = Slight::Runtime->new->init;

my $countdown = $r->spawn_context(q[

(defun countdown (n orig)
    (if (== n 0)
        (do
            (say (~ (getpid) " is DONE!"))
            (list 'PID: (getpid) 'end: n 'start: orig))
        (do
            (say (~ (getpid) (~ " = ..." n)))
            (countdown (- n 1) orig))))

]);

my ($ctx) = $r->run;

say "COMPILED: ", $ctx->last_env;

my @countdowns = map {
    my $x = int(rand(10));
    $r->fork_context(
        $ctx,
        (sprintf '(countdown %d %d)' => $x, $x),
        $ctx->last_env
    )
} 1 .. 10;

my @ctxs = $r->run;

say(sprintf 'PID:%04d = %s' => $_->PID, $_->result // $_->error )
    foreach @ctxs;

