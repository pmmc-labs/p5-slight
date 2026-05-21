
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;

my $r   = Slight::Runtime->new->init;
my $fact = $r->spawn_context(q[

(defun fact (n)
    (if (== n 0) 1
        (* n (fact (- n 1)))))

(fact 6)

]);

my $fib = $r->spawn_context(q[

(defun fib (n)
        (if (< n 2) n
            (+ (fib (- n 2))
               (fib (- n 1)))))

(fib 6)

]);

my @ctxs = $r->run_all($fact, $fib);

say $_->result foreach @ctxs;

