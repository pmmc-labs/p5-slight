
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;

## -----------------------------------------------------------------------------
my $sys  = Slight->new;
my $prog = $sys->compile(q[

(defun player (count)
    (if (== count 0)
        (say (~ "Goodbye from " (getpid)))
        (do
            (let msg (recv))
            (let operation (car  msg))
            (let reply-to  (cdar msg))
            (say (~ (~ (~ "Got " count) (~ " for " operation)) (~ " at " (getpid))))
            (if (eq? operation :Ping)
                (send reply-to (list :Pong (getpid)))
                (send reply-to (list :Ping (getpid))))
            (yield (player (- count 1)))
        )
    )
)

(let player-1 (fork (player 10)))
(let player-2 (fork (player 10)))

(send player-1 (list :Ping player-2))

]);

my $prog_ctx = $sys->spawn_context( $prog );
my @halted   = $sys->run;

foreach my $ctx (@halted) {
    my ($last) = $ctx->trace;
    say '-' x 40;
    say $last;
    say "  - ", join "\n  - " => $last->env->chain;
}


__END__

-------------------------------

(defun fact (n)
    (if (== n 0)
        (yield 1)
        (yield (* n (fact (- n 1))))))


(defun fib (n)
    (if (< n 2)
        (yield n)
        (+ (yield (fib (- n 2)))
           (yield (fib (- n 1))))))

(say (fork (fact 6)))
(say (fork (fib  6)))
