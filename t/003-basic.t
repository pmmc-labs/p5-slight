
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

    (list
        (fork (adder 10   20))
        (fork (adder 100  200))
        (fork (adder 1000 2000))
    )

]);

my @done = $r->run;

say sprintf 'PID:%04d => %s' => $_->PID, $_->result // $_->error foreach @done;

