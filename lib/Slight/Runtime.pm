
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight::Allocator;
use Slight::Machine;
use Slight::Parser;
use Slight::Term;

## -----------------------------------------------------------------------------
## Runtime
## -----------------------------------------------------------------------------

class Slight::Runtime {
    field $alloc   :param :reader = undef;
    field $parser  :param :reader = undef;
    field $machine :param :reader = undef;

    ADJUST {
        $alloc    //= Slight::Allocator->new;
        $parser   //= Slight::Parser->new( alloc => $alloc );
        $machine  //= Slight::Machine->new( alloc => $alloc, parser => $parser );
    }

    method init {
        my sub add ($n, $m) { $alloc->Num( $n->raw + $m->raw ) }
        my sub sub ($n, $m) { $alloc->Num( $n->raw - $m->raw ) }
        my sub mul ($n, $m) { $alloc->Num( $n->raw * $m->raw ) }
        my sub div ($n, $m) { $alloc->Num( $n->raw / $m->raw ) }
        my sub mod ($n, $m) { $alloc->Num( $n->raw % $m->raw ) }

        my sub num_eq ($n, $m) { $n->raw == $m->raw ? $alloc->True : $alloc->False }
        my sub num_ne ($n, $m) { $n->raw != $m->raw ? $alloc->True : $alloc->False }
        my sub num_gt ($n, $m) { $n->raw >  $m->raw ? $alloc->True : $alloc->False }
        my sub num_lt ($n, $m) { $n->raw <  $m->raw ? $alloc->True : $alloc->False }
        my sub num_ge ($n, $m) { $n->raw >= $m->raw ? $alloc->True : $alloc->False }
        my sub num_le ($n, $m) { $n->raw <= $m->raw ? $alloc->True : $alloc->False }

        my sub concat ($n, $m) { $alloc->Str( $n->raw . $m->raw ) }

        my sub eqp ($n, $m) { $n->hash eq $m->hash ? $alloc->True : $alloc->False }

        my sub atomp ($n) { $n isa Slight::Term::Literal  ? $alloc->True : $alloc->False }
        my sub nilp  ($n) { $n isa Slight::Term::Nil      ? $alloc->True : $alloc->False }

        my sub car ($l) { $l->head }
        my sub cdr ($l) { $l->tail }

        my sub caar  ($l) { $l->head->head }
        my sub cadr  ($l) { $l->head->tail }
        my sub cdar  ($l) { $l->tail->head }
        my sub cadar ($l) { $l->head->tail->head }
        my sub caddr ($l) { $l->head->tail->tail }
        my sub cddar ($l) { $l->tail->tail->head }

        my sub cons ($h, $t) { $alloc->Cons( $h, $t ) }
        my sub list (@items) { $alloc->List( @items ) }

        my sub lambda ($E, $p, $b) {
            Slight::Machine::Just( $E, $alloc->Lambda( $p, $b, $E ) )
        }

        my sub quote  ($E, @terms) {
            Slight::Machine::Just( $E, (scalar @terms == 1) ? $terms[0] : $alloc->List(@terms) )
        }

        my sub defun  ($E, $sym, $p, $b) {
            return Slight::Machine::Bind( $E, $sym ),
                   Slight::Machine::EvalExpr( $E, $alloc->Lambda( $p, $b, $E, $sym ) );
        }

        my sub _if ($E, $cond, $if_true, $if_false) {
            return Slight::Machine::Cond( $E, $if_true, $if_false ),
                   Slight::Machine::EvalExpr( $E, $cond )
        }

        $machine->init(
            'lambda' => $alloc->Procedure( $alloc->Sym('lambda' ), \&lambda, is_operative => true ),
            'quote'  => $alloc->Procedure( $alloc->Sym('quote'  ), \&quote,  is_operative => true ),
            'defun'  => $alloc->Procedure( $alloc->Sym('defun'  ), \&defun,  is_operative => true ),
            'if'     => $alloc->Procedure( $alloc->Sym('if'     ), \&_if,    is_operative => true ),
            'atom?'  => $alloc->Procedure( $alloc->Sym('atom?'  ), \&atomp, is_applicative => true ),
            'nil?'   => $alloc->Procedure( $alloc->Sym('nil?'   ), \&nilp,  is_applicative => true ),
            'eq?'    => $alloc->Procedure( $alloc->Sym('eq?'    ), \&eqp,   is_applicative => true ),
            'list'   => $alloc->Procedure( $alloc->Sym('list'   ), \&list,  is_applicative => true ),
            'cons'   => $alloc->Procedure( $alloc->Sym('cons'   ), \&cons,  is_applicative => true ),
            'car'    => $alloc->Procedure( $alloc->Sym('car'    ), \&car,   is_applicative => true ),
            'cdr'    => $alloc->Procedure( $alloc->Sym('cdr'    ), \&cdr,   is_applicative => true ),
            'caar'   => $alloc->Procedure( $alloc->Sym('caar'   ), \&caar,  is_applicative => true ),
            'cadr'   => $alloc->Procedure( $alloc->Sym('cadr'   ), \&cadr,  is_applicative => true ),
            'cdar'   => $alloc->Procedure( $alloc->Sym('cdar'   ), \&cdar,  is_applicative => true ),
            'cadar'  => $alloc->Procedure( $alloc->Sym('cadar'  ), \&cadar, is_applicative => true ),
            'caddr'  => $alloc->Procedure( $alloc->Sym('caddr'  ), \&caddr, is_applicative => true ),
            'cddar'  => $alloc->Procedure( $alloc->Sym('cddar'  ), \&cddar, is_applicative => true ),

            '~' => $alloc->Procedure( $alloc->Sym('~'), \&concat, is_applicative => true ),
            '+' => $alloc->Procedure( $alloc->Sym('+'), \&add, is_applicative => true ),
            '-' => $alloc->Procedure( $alloc->Sym('-'), \&sub, is_applicative => true ),
            '*' => $alloc->Procedure( $alloc->Sym('*'), \&mul, is_applicative => true ),
            '/' => $alloc->Procedure( $alloc->Sym('/'), \&div, is_applicative => true ),
            '%' => $alloc->Procedure( $alloc->Sym('%'), \&mod, is_applicative => true ),

            '==' => $alloc->Procedure( $alloc->Sym('=='), \&num_eq, is_applicative => true ),
            '!=' => $alloc->Procedure( $alloc->Sym('!='), \&num_ne, is_applicative => true ),
            '>'  => $alloc->Procedure( $alloc->Sym('>' ), \&num_gt, is_applicative => true ),
            '<'  => $alloc->Procedure( $alloc->Sym('<' ), \&num_lt, is_applicative => true ),
            '>=' => $alloc->Procedure( $alloc->Sym('>='), \&num_ge, is_applicative => true ),
            '<=' => $alloc->Procedure( $alloc->Sym('<='), \&num_le, is_applicative => true ),
        );

        $machine->add_effect( Slight::Effect::TTY->new( alloc => $alloc ) );

        return $machine;
    }

}
