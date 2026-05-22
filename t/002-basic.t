
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;

my $r = Slight::Runtime->new->init;

my $countdown = $r->spawn_context(q[

(defun countdown (label n)
    (if (== n 0)
        (do
            (say (~ $PID " is DONE!"))
            label)
        (do
            (say (~ $PID (~ " = ..." n)))
            (countdown label (- n 1)))))

]);

my $ctx = $r->run($countdown);

say "COMPILED: ", $ctx->last_env;

my @countdowns = map {
    $r->spawn_context(
        (sprintf '(countdown "%05d" %d)' => $_, int(rand(50))),
        $ctx->last_env
    )
} 1 .. 100;

my @ctxs = $r->run_all(@countdowns);

say(sprintf 'PID:%04d = %s' => $_->PID, $_->result // $_->error )
    foreach @ctxs;

