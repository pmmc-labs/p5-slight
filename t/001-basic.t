
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;

## -----------------------------------------------------------------------------
my $sys    = Slight->new;
my $rqueue = $sys->run(q[

(defun player (count)
    (if (== count 0)
        (say (~ "Goodbye from " (getpid)))
        (do
            (let msg (recv))
            (let operation (car  msg))
            (let reply-to  (cdar msg))
            (say (~ "Got " count " for " operation " at " (getpid)))
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

(waitpid player-1 player-2)
(say "GAME OVER")

]);

say '=' x 40;
say 'RESULTS:';
foreach my $ctx ($rqueue->halted) {
    my ($last) = $ctx->trace;
    say '-' x 40;
    if ($last isa Slight::Kontinue::Error) {
        say sprintf '%s => %s %s' => $ctx->pid, $last, $last->error;
    } else {
        say sprintf '%s => %s' => $ctx->pid, $last;
    }
    say "  - ", join "\n  - " => $last->env->chain;
}
say '-' x 40;
say 'ZOMBIES!';
say "  - $_" foreach $rqueue->running;
say '-' x 40;
say 'BLOCKED!';
say "  - $_" foreach $rqueue->blocked;
say '-' x 40;
say 'DEAD LETTERS!';
say "  - $_" foreach $sys->host->dead_letters;
say '-' x 40;
say 'UNDELIVERED!';
my %mb = $sys->host->mailboxes;
say "  - $_" foreach map $_->@*, values %mb;
say '=' x 40;


__END__


-------------------------------

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
