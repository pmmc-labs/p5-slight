
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight::Allocator;
use Slight::Context;
use Slight::Host;
use Slight::Kontinue;
use Slight::Parser;
use Slight::Term;
use Slight::Timers;
use Slight::WorkingMemory;

class Slight {
    use Time::HiRes qw[ gettimeofday ];

    field $alloc     :reader;
    field $root_env  :reader;
    field $timers    :reader;

    field $host :reader;
    field $init :reader;

    ADJUST {
        $alloc    = Slight::Allocator->new;
        $timers   = Slight::Timers->new;
        $root_env = $self->initialize_root_environment;
        $host     = Slight::Host->new(
            alloc    => $alloc,
            timers   => $timers,
            root_env => $root_env,
        );
    }

    ## host access

    method run ($src) {
        $init = $host->spawn_context( $self->compile( $src ) );
        $host->run;
    }

    ## compiler

    method compile ($src) {
        my @exprs = Slight::Parser->new( alloc => $alloc )->parse( $src );
        return $host->assemble( $root_env, @exprs );
    }

    ## env initialization

    method initialize_root_environment {
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

        my sub concat (@args) {
            $alloc->Str( join '' => map $_->stringify, @args )
        }

        my sub eqp ($n, $m) { $n->hash eq $m->hash ? $alloc->True : $alloc->False }
        my sub nep ($n, $m) { $n->hash ne $m->hash ? $alloc->True : $alloc->False }

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

        my sub _say (@args) {
            say map $_->stringify, @args;
            return $alloc->Nil;
        }

        # ...

        my sub lambda ($E, $p, $b) {
            Slight::Kontinue::Just->new( env => $E )->PUSH( $alloc->Lambda( $p, $b, $E ) )
        }

        my sub quote  ($E, @terms) {
            Slight::Kontinue::Just->new( env => $E )->PUSH( scalar @terms == 1 ? $terms[0] : $alloc->List(@terms) )
        }

        my sub defun  ($E, $sym, $p, $b) {
            return Slight::Kontinue::Bind->new( env => $E, name => $sym ),
                   Slight::Kontinue::Eval::Expr->new( env => $E, expr => $alloc->Lambda( $p, $b, $E, $sym ) );
        }

        my sub let  ($E, $sym, $value) {
            return Slight::Kontinue::Bind->new( env => $E, name => $sym ),
                   Slight::Kontinue::Eval::Expr->new( env => $E, expr => $value );
        }

        my sub _if ($E, $cond, $if_true, $if_false) {
            return Slight::Kontinue::Cond->new( env => $E, if_true => $if_true, if_false => $if_false ),
                   Slight::Kontinue::Eval::Expr->new( env => $E, expr => $cond );
        }

        my sub _do ($E, @exprs) {
            my @progn = reverse map {
                Slight::Kontinue::Drop->new( env => $E ),
                Slight::Kontinue::Eval::Expr->new( env => $E, expr => $_ )
            } @exprs;
            pop @progn;
            return @progn;
        }

        # ...

        my sub _sleep ($E, $timeout) {
            return Slight::Kontinue::Sleep->new( env => $E ),
                    Slight::Kontinue::Eval::Expr->new( env => $E, expr => $timeout );
        }

        my sub _set_timeout ($E, $timeout, $callback) {
            return Slight::Kontinue::Timeout->new( env => $E ),
                    Slight::Kontinue::Eval::Rest->new( env => $E,
                        rest => $alloc->List( $timeout, $callback ) );
        }

        my sub _exit ($E) {
            return Slight::Kontinue::Halt->new( env => $E );
        }

        my sub _getpid ($E) {
            return Slight::Kontinue::Getpid->new( env => $E );
        }

        my sub _fork ($E, $expr) {
            return Slight::Kontinue::Fork->new( env => $E, expr => $expr );
        }

        my sub _waitpid ($E, @pids) {
            return Slight::Kontinue::Waitpid->new( env => $E ),
                    Slight::Kontinue::Eval::Rest->new( env => $E, rest => $alloc->List( @pids ) );
        }

        my sub yield ($E, $expr) {
            return Slight::Kontinue::Eval::Expr->new( env => $E, expr => $expr ),
                   Slight::Kontinue::Yield->new( env => $E );
        }

        my sub _send ($E, $pid, $msg) {
            return Slight::Kontinue::Send->new( env => $E ),
                    Slight::Kontinue::Eval::Rest->new( env => $E, rest => $alloc->List( $pid, $msg ) );
        }

        my sub _recv ($E) {
            return Slight::Kontinue::Recv->new( env => $E );
        }

        # ...

        my sub _query ($E, $s, $p, $o) {
            return Slight::Kontinue::MemOp::Query->new( env => $E ),
                    Slight::Kontinue::Eval::Rest->new( env => $E,
                        rest => $alloc->List( $s, $p, $o ) );
        }

        my sub _assert ($E, $s, $p, $o) {
            return Slight::Kontinue::MemOp::Assert->new( env => $E ),
                    Slight::Kontinue::Eval::Rest->new( env => $E,
                        rest => $alloc->List( $s, $p, $o ) );
        }

        my sub _retract ($E, $s, $p, $o) {
            return Slight::Kontinue::MemOp::Retract->new( env => $E ),
                    Slight::Kontinue::Eval::Rest->new( env => $E,
                        rest => $alloc->List( $s, $p, $o ) );
        }

        my sub _subject   ($t) { $t->subject   }
        my sub _predicate ($t) { $t->predicate }
        my sub _object    ($t) { $t->object    }

        my sub _gettod () {
            my ($s, $f) = Time::HiRes::gettimeofday;
            return $alloc->Pair( $alloc->Num($s), $alloc->Num($f) );
        }

        # ...

        $alloc->Env(

            'gettimeofday' => $alloc->Procedure( $alloc->Sym('gettimeofday'), \&_gettod, is_applicative => true ),


            # special forms
            'lambda' => $alloc->Procedure( $alloc->Sym('lambda' ), \&lambda, is_operative => true ),
            'quote'  => $alloc->Procedure( $alloc->Sym('quote'  ), \&quote,  is_operative => true ),
            'defun'  => $alloc->Procedure( $alloc->Sym('defun'  ), \&defun,  is_operative => true ),
            'let'    => $alloc->Procedure( $alloc->Sym('let'    ), \&let,    is_operative => true ),
            'if'     => $alloc->Procedure( $alloc->Sym('if'     ), \&_if,    is_operative => true ),
            'do'     => $alloc->Procedure( $alloc->Sym('do'     ), \&_do,    is_operative => true ),
            'exit'   => $alloc->Procedure( $alloc->Sym('exit'   ), \&_exit, is_operative => true ),

            # concurrency forms
            'sleep'   => $alloc->Procedure( $alloc->Sym('sleep'  ), \&_sleep,   is_operative => true ),
            'fork'    => $alloc->Procedure( $alloc->Sym('fork'   ), \&_fork,    is_operative => true ),
            'yield'   => $alloc->Procedure( $alloc->Sym('yield'  ), \&yield,    is_operative => true ),
            'send'    => $alloc->Procedure( $alloc->Sym('send'   ), \&_send,    is_operative => true ),
            'recv'    => $alloc->Procedure( $alloc->Sym('recv'   ), \&_recv,    is_operative => true ),
            'getpid'  => $alloc->Procedure( $alloc->Sym('getpid' ), \&_getpid,  is_operative => true ),
            'waitpid' => $alloc->Procedure( $alloc->Sym('waitpid'), \&_waitpid, is_operative => true ),

            'set-timeout' => $alloc->Procedure( $alloc->Sym('set-timeout'), \&_set_timeout, is_operative => true ),

            # memory operations
            'query?'     => $alloc->Procedure( $alloc->Sym('query?'   ), \&_query,   is_operative => true ),
            'assert+'    => $alloc->Procedure( $alloc->Sym('assert+'  ), \&_assert,  is_operative => true ),
            'retract!'   => $alloc->Procedure( $alloc->Sym('retract!' ), \&_retract, is_operative => true ),
            # memory fact operations
            '.subject'   => $alloc->Procedure( $alloc->Sym('.subject'   ), \&_subject,   is_applicative => true ),
            '.predicate' => $alloc->Procedure( $alloc->Sym('.predicate' ), \&_predicate, is_applicative => true ),
            '.object'    => $alloc->Procedure( $alloc->Sym('.object'    ), \&_object,    is_applicative => true ),

            # i/o helpers
            'say'    => $alloc->Procedure( $alloc->Sym('say'    ), \&_say,  is_applicative => true ),

            # predicates
            'atom?'  => $alloc->Procedure( $alloc->Sym('atom?'  ), \&atomp, is_applicative => true ),
            'nil?'   => $alloc->Procedure( $alloc->Sym('nil?'   ), \&nilp,  is_applicative => true ),
            'eq?'    => $alloc->Procedure( $alloc->Sym('eq?'    ), \&eqp,   is_applicative => true ),
            'ne?'    => $alloc->Procedure( $alloc->Sym('ne?'    ), \&nep,   is_applicative => true ),

            # lists
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

            # ops for strings
            '~' => $alloc->Procedure( $alloc->Sym('~'), \&concat, is_applicative => true ),

            # maths for numbers
            '+' => $alloc->Procedure( $alloc->Sym('+'), \&add, is_applicative => true ),
            '-' => $alloc->Procedure( $alloc->Sym('-'), \&sub, is_applicative => true ),
            '*' => $alloc->Procedure( $alloc->Sym('*'), \&mul, is_applicative => true ),
            '/' => $alloc->Procedure( $alloc->Sym('/'), \&div, is_applicative => true ),
            '%' => $alloc->Procedure( $alloc->Sym('%'), \&mod, is_applicative => true ),

            # eq/ordering for numbers
            '==' => $alloc->Procedure( $alloc->Sym('=='), \&num_eq, is_applicative => true ),
            '!=' => $alloc->Procedure( $alloc->Sym('!='), \&num_ne, is_applicative => true ),
            '>'  => $alloc->Procedure( $alloc->Sym('>' ), \&num_gt, is_applicative => true ),
            '<'  => $alloc->Procedure( $alloc->Sym('<' ), \&num_lt, is_applicative => true ),
            '>=' => $alloc->Procedure( $alloc->Sym('>='), \&num_ge, is_applicative => true ),
            '<=' => $alloc->Procedure( $alloc->Sym('<='), \&num_le, is_applicative => true ),
        )
    }

}
