
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;

my $r   = Slight::Runtime->new->init;
my $ctx = $r->spawn_context(q[

(defun fact (n)
    (if (== n 0) 1
        (* n (fact (- n 1)))))

(defun fib (n)
        (if (< n 2) n
            (+ (fib (- n 2))
               (fib (- n 1)))))

(say (~ "fact(6) + fib(6) = " (+ (fact 6) (fib 6))))

]);

say $r->run($ctx);

