
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;

say Slight::Runtime->new->init->run(q[

(defun fact (n)
    (if (== n 0) 1
        (* n (fact (- n 1)))))

(defun fib (n)
        (if (< n 2) n
            (+ (fib (- n 2))
               (fib (- n 1)))))

(say (~ "fact(6) + fib(6) = " (+ (fact 6) (fib 6))))

]);


## -----------------------------------------------------------------------------


__END__



(defun fact (n)
    (if (== n 0) 1
        (* n (fact (- n 1)))))

(fact 6)

# 0, 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144
(defun fib (n)
        (if (< n 2) n
            (+ (fib (- n 2))
               (fib (- n 1)))))
