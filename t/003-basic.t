
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;

my $r   = Slight::Runtime->new->init;
my $ctx = $r->spawn_context(q[

    (defun adder (x y) (do
        (say (~
                (~ "adder@" (getpid))
                (~ " with"
                    (~
                        (~ " X: " x)
                        (~ " Y: " y)))))
        (+ x y)))


    (let pid1 (fork (adder 10   20)))
    (let pid2 (fork (adder 100  200)))
    (let pid3 (fork (adder 1000 2000)))

    (waitpid pid2)
    (say "PID2 exited!")

    (waitpid pid3)
    (say (~ "Exiting " (getpid)))

]);

my @done = $r->run;

say 'DONE:';
say sprintf '%s => %s' => $_->PID, $_->result // $_->error foreach @done;

