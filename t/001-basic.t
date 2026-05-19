
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;

my $i = Slight::Machine->new;
my $a = $i->alloc;

## Builtins
my sub add ($n, $m) { $a->Num( $n->raw + $m->raw ) }
my sub sub ($n, $m) { $a->Num( $n->raw - $m->raw ) }
my sub mul ($n, $m) { $a->Num( $n->raw * $m->raw ) }
my sub div ($n, $m) { $a->Num( $n->raw / $m->raw ) }
my sub mod ($n, $m) { $a->Num( $n->raw % $m->raw ) }

my sub num_eq ($n, $m) { $n->raw == $m->raw ? $a->True : $a->False }
my sub num_ne ($n, $m) { $n->raw != $m->raw ? $a->True : $a->False }
my sub num_gt ($n, $m) { $n->raw >  $m->raw ? $a->True : $a->False }
my sub num_lt ($n, $m) { $n->raw <  $m->raw ? $a->True : $a->False }
my sub num_ge ($n, $m) { $n->raw >= $m->raw ? $a->True : $a->False }
my sub num_le ($n, $m) { $n->raw <= $m->raw ? $a->True : $a->False }

my sub concat ($n, $m) { $a->Str( $n->raw . $m->raw ) }

my sub eqp ($n, $m) { $n->hash eq $m->hash ? $a->True : $a->False }

my sub atomp ($n) { $n isa Slight::Term::Literal  ? $a->True : $a->False }
my sub nilp  ($n) { $n isa Slight::Term::Nil      ? $a->True : $a->False }

my sub car ($l) { $l->head }
my sub cdr ($l) { $l->tail }

my sub caar  ($l) { $l->head->head }
my sub cadr  ($l) { $l->head->tail }
my sub cdar  ($l) { $l->tail->head }
my sub cadar ($l) { $l->head->tail->head }
my sub caddr ($l) { $l->head->tail->tail }
my sub cddar ($l) { $l->tail->tail->head }

my sub cons ($h, $t) { $a->Cons( $h, $t ) }
my sub list (@items) { $a->List( @items ) }

my sub lambda ($E, $p, $b) {
    Slight::Machine::Just( $E, $a->Lambda( $p, $b, $E ) )
}

my sub quote  ($E, @terms) {
    Slight::Machine::Just( $E, (scalar @terms == 1) ? $terms[0] : $a->List(@terms) )
}

my sub defun  ($E, $sym, $p, $b) {
    return Slight::Machine::Bind( $E, $sym ),
           Slight::Machine::EvalExpr( $E, $a->Lambda( $p, $b, $E, $sym ) );
}

my sub _if ($E, $cond, $if_true, $if_false) {
    return Slight::Machine::Cond( $E, $if_true, $if_false ),
           Slight::Machine::EvalExpr( $E, $cond )
}

## define root environment

$i->init(
    'lambda' => $a->Procedure( $a->Sym('lambda' ), \&lambda, is_operative => true ),
    'quote'  => $a->Procedure( $a->Sym('quote'  ), \&quote,  is_operative => true ),
    'defun'  => $a->Procedure( $a->Sym('defun'  ), \&defun,  is_operative => true ),
    'if'     => $a->Procedure( $a->Sym('if'     ), \&_if,    is_operative => true ),
    'atom?'  => $a->Procedure( $a->Sym('atom?'  ), \&atomp, is_applicative => true ),
    'nil?'   => $a->Procedure( $a->Sym('nil?'   ), \&nilp,  is_applicative => true ),
    'eq?'    => $a->Procedure( $a->Sym('eq?'    ), \&eqp,   is_applicative => true ),
    'list'   => $a->Procedure( $a->Sym('list'   ), \&list,  is_applicative => true ),
    'cons'   => $a->Procedure( $a->Sym('cons'   ), \&cons,  is_applicative => true ),
    'car'    => $a->Procedure( $a->Sym('car'    ), \&car,   is_applicative => true ),
    'cdr'    => $a->Procedure( $a->Sym('cdr'    ), \&cdr,   is_applicative => true ),
    'caar'   => $a->Procedure( $a->Sym('caar'   ), \&caar,  is_applicative => true ),
    'cadr'   => $a->Procedure( $a->Sym('cadr'   ), \&cadr,  is_applicative => true ),
    'cdar'   => $a->Procedure( $a->Sym('cdar'   ), \&cdar,  is_applicative => true ),
    'cadar'  => $a->Procedure( $a->Sym('cadar'  ), \&cadar, is_applicative => true ),
    'caddr'  => $a->Procedure( $a->Sym('caddr'  ), \&caddr, is_applicative => true ),
    'cddar'  => $a->Procedure( $a->Sym('cddar'  ), \&cddar, is_applicative => true ),

    '~' => $a->Procedure( $a->Sym('~'), \&concat, is_applicative => true ),
    '+' => $a->Procedure( $a->Sym('+'), \&add, is_applicative => true ),
    '-' => $a->Procedure( $a->Sym('-'), \&sub, is_applicative => true ),
    '*' => $a->Procedure( $a->Sym('*'), \&mul, is_applicative => true ),
    '/' => $a->Procedure( $a->Sym('/'), \&div, is_applicative => true ),
    '%' => $a->Procedure( $a->Sym('%'), \&mod, is_applicative => true ),

    '==' => $a->Procedure( $a->Sym('=='), \&num_eq, is_applicative => true ),
    '!=' => $a->Procedure( $a->Sym('!='), \&num_ne, is_applicative => true ),
    '>'  => $a->Procedure( $a->Sym('>' ), \&num_gt, is_applicative => true ),
    '<'  => $a->Procedure( $a->Sym('<' ), \&num_lt, is_applicative => true ),
    '>=' => $a->Procedure( $a->Sym('>='), \&num_ge, is_applicative => true ),
    '<=' => $a->Procedure( $a->Sym('<='), \&num_le, is_applicative => true ),
);

## add effects

$i->add_effect( Slight::Effect::TTY->new( alloc => $a ) );

## tests

say $i->run(q[

(defun fact (n)
    (if (== n 0) 1
        (* n (fact (- n 1)))))

(say (fact 6))

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
