
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];
#use Test::More;
use Data::Dumper qw[ Dumper ];

## -----------------------------------------------------------------------------
## TODO
## -----------------------------------------------------------------------------
## - use the DEBUG flag
## - add a Bind term, similar to Condition
## - clean up the Interpreter a bit
##      - stuff like:
##          - the kontinue helper is kind gross now
##          - error handling could be improved
##      - in both cases, a new method is probably the right answer
## - add equal_to method to Term
##      - make it similar to pprint
## -----------------------------------------------------------------------------

use constant DEBUG => $ENV{DEBUG} // 0;

# this is for debugging stuff
use Term::ReadKey ();
our $WIDTH = (Term::ReadKey::GetTerminalSize)[0];

## -----------------------------------------------------------------------------

class Term {
    method is_nil { false }
    method pprint {
        given (__CLASS__) {
            when ('Sym')       { $self->ident }
            when ('Str')       { $self->raw }
            when ('Num')       { $self->raw }
            when ('Bool')      { $self->raw ? '#t' : '#f' }
            when ('Nil')       { '#n' }
            when ('Cons')      { sprintf '(%s)' => join ' ' => map { $_->pprint } $self->uncons }
            when ('Lambda')    { sprintf '(<lambda> %s %s)' => $self->params->pprint, $self->body->pprint }
            when ('BuiltIn')   { sprintf '&<%s>' => $self->name }
            when ('Env')       { '#env' }
            when ('Error')     { sprintf 'ERROR(%s)' => $self->msg }
            when ('Condition') {
                sprintf '(<if> %s %s %s)' => $self->cond->pprint,
                    $self->if_true->pprint,
                    $self->if_false->pprint
            }
            default {
                die "WTF! $self";
            }
        }
    }
}

class Sym     :isa(Term)    { field $ident :reader :param; }
class Literal :isa(Term)    {}
class Str     :isa(Literal) { field $raw :reader :param; }
class Num     :isa(Literal) { field $raw :reader :param; }
class Bool    :isa(Literal) { field $raw :reader :param; }
class Error   :isa(Literal) { field $msg :param :reader; }
class List    :isa(Term)    {}
class Nil     :isa(List)    { method is_nil { true } }
class Cons    :isa(List)    {
    field $head :reader :param;
    field $tail :reader :param;
    method uncons {
        my @out;
        my $list = $self;
        until ($list->is_nil) {
            push @out => $list->head;
            $list = $list->tail;
        }
        return @out;
    }
}

class Env :isa(Term) {
    field $parent   :reader :param = undef;
    field $bindings :reader :param = +{};
    method bind   ($name, $value) { $bindings->{ $name->ident } = $value }
    method lookup ($name) {
        $bindings->{ $name->ident }
            // (defined $parent ? $parent->lookup( $name ) : undef)
    }
}

## compiled forms ...

class Lambda :isa(Literal) {
    field $params :reader :param;
    field $body   :reader :param;
    field $env    :reader :param;
}

class BuiltIn :isa(Literal) {
    field $name :reader :param;
    field $body :reader :param;
}

class Condition :isa(Literal) {
    field $cond     :reader :param;
    field $if_true  :reader :param;
    field $if_false :reader :param;
}

## -----------------------------------------------------------------------------

class Allocator {
    # constants ...
    method Nil   { state $Nil   = Nil->new }
    method True  { state $True  = Bool->new( raw => true ) }
    method False { state $False = Bool->new( raw => false ) }
    # terms ...
    method Bool  ($b)           { $b ? $self->True : $self->False }
    method Sym   ($i)           { Sym->new( ident => $i ) }
    method Str   ($s)           { Str->new( raw   => $s ) }
    method Num   ($n)           { Num->new( raw   => $n ) }
    method Cons  ($h, $t=undef) { Cons->new( head => $h, tail => $t // $self->Nil ) }
    method Env   ($b, $p=undef) { Env->new( bindings => $b, parent => $p ) }
    method Error ($m)           { Error->new( msg => $m ) }
    # compiled forms ...
    method Lambda    ($p, $b, $e) { Lambda->new( params => $p, body => $b, env => $e ) }
    method BuiltIn   ($n, $b)     { BuiltIn->new( name => $n, body => $b ) }
    method Condition ($c, $t, $f) { Condition->new( cond => $c, if_true => $t, if_false => $f ) }
    # ... list utils
    method Map ($f, $list) { $self->List( map { $f->($_) } $list->uncons ) }
    method Reverse ($list) { $self->List( reverse $list->uncons ) }
    method List    (@list) {
        my $list = $self->Nil;
        while (@list) {
            $list = $self->Cons( pop @list, $list );
        }
        return $list;
    }
    # ... env utils
    method CallerEnv ($call, $args) {
        my %local;
        my $env    = $call->env;
        my $params = $call->params;
        until ($params->is_nil) {
            $local{ $params->head->ident } = $args->head;
            $params = $params->tail;
            $args   = $args->tail;
        }
        return $self->Env( \%local, $env );
    }
}

## -----------------------------------------------------------------------------

class Parser {
    field $alloc  :param :reader;
    field @chars  :reader;
    field @tokens :reader;

    method peek    { $chars[0] }
    method advance { shift @chars }

    method skip_whitespace {
        while (@chars) {
            last if $chars[0] =~ /\S/;
            shift @chars
        }
    }

    method skip_until_newline {
        while (@chars) {
            last if $chars[0] =~ /\n/;
            shift @chars
        }
    }

    method push_stack ($value) { push $tokens[-1]->@* => $value }
    method pop_stack           { pop $tokens[-1]->@* }

    method parse ($source) {
        @tokens = (+[]);
        @chars  = split // => $source;
        while (@chars) {
            $self->find_next_token;
        }
        return pop @tokens;
    }

    method find_next_token {
        my $next = $self->advance;
        given ($next) {
            when (/\s/) {
                $self->skip_whitespace;
            }
            when (';') {
                $self->skip_until_newline;
            }
            when ('(') {
                push @tokens => +[];
            }
            when (')') {
                my $list = pop @tokens;
                $self->push_stack( $alloc->List( @$list ) );
            }
            when (/[0-9]/) {
                $self->push_stack( $alloc->Num( $self->parse_number( $next ) ) );
            }
            when ('"') {
                $self->push_stack( $alloc->Str( $self->parse_string( $next ) ) );
            }
            when ('-') {
                if ($self->peek =~ /[0-9]/) {
                    $self->push_stack( $alloc->Num( $self->parse_number( $next ) ) );
                } else {
                    $self->push_stack( $alloc->Sym( $self->parse_symbol( $next ) ) );
                }
            }
            when ('#') {
                given ($self->advance) {
                    when ('t') { $self->push_stack( $alloc->True ) }
                    when ('f') { $self->push_stack( $alloc->False ) }
                    when ('n') { $self->push_stack( $alloc->Nil ) }
                }
            }
            default {
                $self->push_stack( $alloc->Sym( $self->parse_symbol( $next ) ) );
            }
        }
    }

    method parse_number ($start) {
        $self->peek =~ /[0-9.]/
            ? $self->parse_number( $start . $self->advance )
            : $start;
    }

    method parse_string ($start) {
        if ($self->peek eq '\\') {
            $start .= $self->advance;
            $start .= $self->advance if $self->peek eq '"';
            $self->parse_string( $start );
        } elsif ($self->peek eq '"') {
            $start . $self->advance;
        } else {
            $self->parse_string( $start . $self->advance );
        }
    }

    method parse_symbol ($start) {
        $self->peek !~ /[\s\(\)]/
            ? $self->parse_symbol( $start . $self->advance )
            : $start;
    }
}

## -----------------------------------------------------------------------------

class Compiler {
    field $alloc :param :reader;

    method compile ($exprs, $env) {
        +[ grep !$_->is_nil, map $self->compile_expr($_, $env), @$exprs ];
    }

    method compile_expr ($expr, $env) {
        given (blessed $expr) {
            when ('Cons') {
                if ($expr->head isa Sym) {
                    given ($expr->head->ident) {
                        when ('lambda') {
                            my ($params, $body) = $expr->tail->uncons;
                            return $alloc->Lambda(
                                $params,
                                $self->compile_expr( $body, $env ),
                                $env
                            )
                        }
                        when ('if') {
                            my ($cond, $if_true, $if_false) = $expr->tail->uncons;
                            return $alloc->Condition(
                                $self->compile_expr( $cond,     $env ),
                                $self->compile_expr( $if_true,  $env ),
                                $self->compile_expr( $if_false, $env ),
                            )
                        }
                        when ('defun') {
                            my ($name, $params, $body) = $expr->tail->uncons;
                            my $f = $alloc->Lambda(
                                $params,
                                $self->compile_expr( $body, $env ),
                                $env
                            );
                            $env->bind( $name, $f );
                            return $alloc->Nil;
                        }
                    }
                }
                return $alloc->Map(sub ($e) { $self->compile_expr( $e, $env ) }, $expr )
            }
            default {
                return $expr;
            }
        }
    }
}

## -----------------------------------------------------------------------------

package Kontinue::HALT  {}
package Kontinue::ERROR {}
package Kontinue::COND  {}
package Kontinue::LEAVE {}
package Kontinue::APPLY {}
package Kontinue::EVAL_EXPR {}
package Kontinue::EVAL_HEAD {}
package Kontinue::EVAL_ARGS {}

class Interpreter {
    field $alloc :reader :param;
    field $steps :reader = 0;

    sub kontinue ($name, $f) { bless $f => "Kontinue::${name}" }

    my $HALT  = kontinue HALT  => sub ($c, $e) { return $c, $e, undef };
    my $ERROR = kontinue ERROR => sub ($c, $e) { return $c, $e, undef };

    method run ($exprs, $env) {
        return $self->evaluate_statements( $exprs, $env );
    }

    method execute ($expr, $env, $kont) {
        while (true) {
            $steps++;
            ($expr, $env, $kont) = $self->evaluate( $expr, $env, $kont );
            last if not defined $kont;
        }
        return $expr;
    }

    method evaluate ($expr, $env, $kont) {
        say sprintf '> EVAL : %s' => $expr->pprint;
        given (blessed $expr) {
            when ('Condition') { $self->conditional   ( $expr, $env, $kont ) }
            when ('Cons')      { $self->evaluate_head ( $expr, $env, $kont ) }
            when ('Sym')       { $self->resolve_symbol( $expr, $env, $kont ) }
            default            { $self->return_value  ( $expr, $env, $kont ) }
        }
    }

    method apply ($args, $env, $kont) {
        kontinue APPLY => sub ($call, $e) {
            say sprintf '@ APPLY : %s %s' => $call->pprint, $args->pprint;
            given (blessed $call) {
                when ('Lambda') {
                    return
                        $call->body,
                        $alloc->CallerEnv( $call, $args ),
                        $kont isa Kontinue::LEAVE
                            ? $kont
                            : kontinue LEAVE => sub ($c, $) {
                                return $self->return_value( $c, $env, $kont )
                            }
                }
                when ('BuiltIn') {
                    return $self->return_value( $call->body->( $args->uncons ), $env, $kont );
                }
                default {
                    return $self->throw_error("Could not apply (".$call->pprint.")");
                }
            }
        }
    }

    method throw_error ($msg, $env) {
        return $alloc->Error($msg), $env, $ERROR;
    }

    method return_value ($expr, $env, $kont) {
        my $depth = 0;
        1 while caller( ++$depth );
        say sprintf 'RETURN(%d) : %s' => $depth, $expr->pprint;
        $kont->( $expr, $env )
    }

    method conditional ($expr, $env, $kont) {
        return $expr->cond, $env, kontinue COND => sub ($c, $e) {
            return $self->throw_error("Expected a Bool, got (".$c->pprint.")")
                unless $c isa Bool;
            return ($c->raw ? $expr->if_true : $expr->if_false), $e, $kont;
        }
    }

    method resolve_symbol ($expr, $env, $kont) {
        my $found = $env->lookup( $expr );
        return $self->throw_error("Could not find (".$expr->pprint.") in Env")
            unless defined $found;
        return $self->return_value( $found, $env, $kont )
    }

    method evaluate_args ($call, $args, $env, $kont) {
        my $done = $alloc->Nil;
        return $args->head, $env, kontinue EVAL_ARGS => sub ($c, $e) {
            $done = $alloc->Cons( $c, $done );
            $args = $args->tail;
            say sprintf '+ ARGS : %s DONE : %s' => $args->pprint, $done->pprint;
            return $call, $env, $self->apply( $alloc->Reverse( $done ), $env, $kont ) if $args->is_nil;
            return $args->head, $e, __SUB__;
        }
    }

    method evaluate_head ($expr, $env, $kont) {
        my $args = $expr->tail;
        return $expr->head, $env, kontinue EVAL_HEAD => sub ($call, $e) {
            say sprintf '> GOT CALL : %s' => $call->pprint;
            return $call, $env, $self->apply( $args, $env, $kont ) if $args->is_nil;
            return $self->evaluate_args( $call, $args, $env, $kont );
        }
    }

    method evaluate_statements ($exprs, $env, $kont=undef) {
        my @exprs = @$exprs;
        return $alloc->Nil unless @exprs;
        return $self->execute( shift @exprs, $env, kontinue EVAL_EXPR => sub ($c, $e) {
            return shift @exprs, $e, __SUB__ if @exprs;
            return $c, $e, $kont;
        });
    }
}

## -----------------------------------------------------------------------------

my $a = Allocator->new;
my $p = Parser->new( alloc => $a );
my $c = Compiler->new( alloc => $a );
my $i = Interpreter->new( alloc => $a );

my $env = $a->Env({
    '+' => $a->BuiltIn('+' => sub ($n, $m) { $a->Num( $n->raw + $m->raw ) }),
    '-' => $a->BuiltIn('-' => sub ($n, $m) { $a->Num( $n->raw - $m->raw ) }),
    '*' => $a->BuiltIn('*' => sub ($n, $m) { $a->Num( $n->raw * $m->raw ) }),
    '/' => $a->BuiltIn('/' => sub ($n, $m) { $a->Num( $n->raw / $m->raw ) }),
    '%' => $a->BuiltIn('%' => sub ($n, $m) { $a->Num( $n->raw % $m->raw ) }),

    '==' => $a->BuiltIn('==' => sub ($n, $m) { $a->Bool( $n->raw == $m->raw ) }),
    '!=' => $a->BuiltIn('!=' => sub ($n, $m) { $a->Bool( $n->raw != $m->raw ) }),
    '>=' => $a->BuiltIn('>=' => sub ($n, $m) { $a->Bool( $n->raw >= $m->raw ) }),
    '<=' => $a->BuiltIn('<=' => sub ($n, $m) { $a->Bool( $n->raw <= $m->raw ) }),
    '>'  => $a->BuiltIn('>'  => sub ($n, $m) { $a->Bool( $n->raw >  $m->raw ) }),
    '<'  => $a->BuiltIn('<'  => sub ($n, $m) { $a->Bool( $n->raw <  $m->raw ) }),

    'nil?'  => $a->BuiltIn('nil?' => sub ($n)     { $a->Bool( $n isa Nil ) }),
    'list'  => $a->BuiltIn('list' => sub (@items) { $a->List( @items ) }),
    'cons'  => $a->BuiltIn('cons' => sub ($h, $t) { $a->Cons( $h, $t ) }),
    'car'   => $a->BuiltIn('car'  => sub ($list)  { $list->head }),
    'cdr'   => $a->BuiltIn('cdr'  => sub ($list)  { $list->tail }),
});

## -----------------------------------------------------------------------------

my $source = q[

    (defun adder (n m) (+ n m))

    (defun double (n) (adder n n))

    (defun fact (n)
        (if (== n 0) 1
            (* n (fact (- n 1)))))

    (defun fib (n)
        (if (< n 2) n
            (+ (fib (- n 1)) (fib (- n 2)))))

    (defun tail-call-demo (n)
        (if (== n 0) 0
           (tail-call-demo (- n 1))))

    (defun length (list)
        (if (nil? list) 0
            (+ 1 (length (cdr list)))))

    (defun length-iter (list count)
        (if (nil? list) count
            (length-iter (cdr list) (+ count 1))))

    (defun range (b e)
        (if (== b e)
            (cons e ())
            (cons b (range (+ b 1) e))))

    (defun map (f lst)
        (if (nil? lst) ()
            (cons (f (car lst)) (map f (cdr lst)))))

    (defun grep (f lst)
        (if (nil? lst) ()
            (if (f (car lst))
                (cons (car lst) (grep f (cdr lst)))
                (grep f (cdr lst)))))

    (defun reduce (acc f lst)
        (if (nil? lst) acc
            (reduce (f (car lst) acc) f (cdr lst))))

    (defun sum (lst)
        (reduce 0 (lambda (n acc) (+ acc n)) lst))

    (defun product (lst)
        (reduce 1 (lambda (n acc) (* acc n)) lst))

    (list
        (fact 6)
        (fib 6)
        (fact (fib 6))
        (length (list 1 2 3 4 5))
        (length-iter (list 1 2 3 4 5) 0)
        (tail-call-demo 10)
        ;; bunch of silly ways to get 30
        (list
            30
            (+ 10 20)
            (+ (* 2 5) 20)
            (+ 10 (* 4 5))
            (+ (* 2 5) (* 4 5))
            (+ (* 2 (- 9 4)) (* 4 5))
            (+ (* 2 (- 9 4)) (* 4 (+ 4 1)))
            (adder 10 20)
            (adder (double 5) 20)
            (adder 10 (* (double 2) 5))
            (adder (fib 6) 22)
            (adder (fib 8) (+ 1 (double 4)))
            (- (fact 6) (+ (* (fact 3) 100) 90))
            ((lambda (n m) (+ n m)) 10 20)
            ((lambda (f n m) (f n m)) + 10 20)
            (+ (length (list 0 1 2 3 4 5 6 7 8 9)) 20)
            (length (range 1 30))
            (+ (length (range 1 10)) (length (range 1 (* 4 5))))
            (+ (product (list 2 1 5)) (sum (list 2 4 6 8)))
            (sum (list 4 (fib 8) (- (fact 3) 1)))
            (+ (sum (range 0 (fib 6))) (- 2 8))
            (sum (grep
                    (lambda (x) (>= x 10))
                    (list 0 2 10 4 7 20 3 1)))
            (sum (map
                    (lambda (x) (if (<= x 20) x 0))
                    (list 100 25 10 411 75 20 35 1000)))
        )
    )

];

my $parsed   = $p->parse($source);
my $compiled = $c->compile( $parsed, $env );
my $evaled   = $i->run( $compiled, $env );
say "GOT: ",$evaled->pprint," in ",$i->steps," steps";



