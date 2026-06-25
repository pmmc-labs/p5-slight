
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];
#use Test::More;
use Data::Dumper qw[ Dumper ];

## -----------------------------------------------------------------------------

use constant DEBUG => $ENV{DEBUG} // 0;

# this is for debugging stuff
use Term::ReadKey ();
our $WIDTH = (Term::ReadKey::GetTerminalSize)[0];

## -----------------------------------------------------------------------------

class Term {
    method is_nil { false }
}

class Sym :isa(Term) { field $ident :reader :param; }

class Literal :isa(Term) {}
class Str  :isa(Literal) { field $raw :reader :param; }
class Num  :isa(Literal) { field $raw :reader :param; }
class Bool :isa(Literal) { field $raw :reader :param; }

class List :isa(Term) {}
class Nil :isa(List) { method is_nil { true } }
class Cons :isa(List) {
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

class Error :isa(Literal) {
    field $msg :param :reader;
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

# ...

class Env :isa(Term) {
    field $parent   :reader :param = undef;
    field $bindings :reader :param = +{};

    method bind ($sym, $value) {
        $bindings->{ $sym->ident } = $value;
    }

    method lookup ($name) {
        $bindings->{ $name->ident }
            // (defined $parent ? $parent->lookup( $name ) : undef)
    }
}

class Allocator {
    method Nil   { state $Nil   = Nil->new }
    method True  { state $True  = Bool->new( raw => true ) }
    method False { state $False = Bool->new( raw => false ) }

    method Bool ($b) { $b ? $self->True : $self->False }

    method Sym ($i) { Sym->new( ident => $i ) }
    method Str ($s) { Str->new( raw   => $s ) }
    method Num ($n) { Num->new( raw   => $n ) }

    method Cons ($h, $t=undef) { Cons->new( head => $h, tail => $t // $self->Nil ) }

    method Error ($m) { Error->new( msg => $m ) }

    method Env ($b, $p=undef) { Env->new( bindings => $b, parent => $p ) }

    method Lambda ($p, $b, $e) { Lambda->new( params => $p, body => $b, env => $e ) }

    method BuiltIn ($n, $b) { BuiltIn->new( name => $n, body => $b ) }

    method Condition ($c, $t, $f) { Condition->new( cond => $c, if_true => $t, if_false => $f ) }

    ## -------------------------------------------------------------------------

    method List (@list) {
        my $list = $self->Nil;
        while (@list) {
            $list = $self->Cons( pop @list, $list );
        }
        return $list;
    }

    method Map ($f, $list) { $self->List( map { $f->($_) } $list->uncons ) }
    method Reverse ($list) { $self->List( reverse $list->uncons ) }

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

sub pprint ($term) {
    given (blessed $term) {
        when ('Sym')       { $term->ident }
        when ('Str')       { $term->raw }
        when ('Num')       { $term->raw }
        when ('Bool')      { $term->raw ? '#t' : '#f' }
        when ('Nil')       { '#n' }
        when ('Cons')      { sprintf '(%s)' => join ' ' => map { pprint($_) } $term->uncons }
        when ('Lambda')    { sprintf '(<lambda> %s %s)' => pprint($term->params), pprint($term->body) }
        when ('BuiltIn')   { sprintf '&<%s>' => $term->name }
        when ('Env')       { '#env' }
        when ('Error')     { pprint($term->msg) }
        when ('Condition') {
            sprintf '(<if> %s %s %s)' => pprint($term->cond),
                pprint($term->if_true),
                pprint($term->if_false)
        }
        default {
            die "WTF! $term";
        }
    }
}

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

package Kontinue::HALT  {}
package Kontinue::ERROR {}
package Kontinue::APPLY {}
package Kontinue::EVAL  {}
package Kontinue::COND  {}
package Kontinue::LEAVE {}

class Interpreter {
    field $alloc :reader :param;

    field $halted :reader = false;
    field $steps  :reader = 0;

    sub kontinue ($name, $f) { bless $f => "Kontinue::${name}" }

    my $HALT  = kontinue HALT  => sub ($c, $e) { return $c, $e, undef };
    my $ERROR = kontinue ERROR => sub ($c, $e) { return $c, $e, undef };

    method run ($exprs, $env) {
        my $result = $alloc->Nil;
        while (@$exprs) {
            $result = $self->execute( shift @$exprs, $env, $HALT );
        }
        return $result;
    }

    method execute ($expr, $env, $kont) {
        until ($halted) {
            $steps++;
            ($expr, $env, $kont) = $self->evaluate( $expr, $env, $kont );
            last if not defined $kont;
            ($expr, $env, $kont) = $kont->( $expr, $env ) if $expr isa Literal;
        }
        return $expr;
    }

    method evaluate ($expr, $env, $kont) {
        my $depth = 0;
        1 while caller( ++$depth );
        say sprintf '[%02d] EVAL: %s' => $depth, ::pprint($expr);
        given (blessed $expr) {
            when ('Condition') {
                return $expr->cond, $env, kontinue COND => sub ($c, $e) {
                    return $alloc->Error("Expected a Bool, got (".::pprint($c).")"), $env, $ERROR
                        unless $c isa Bool;
                    return ($c->raw ? $expr->if_true : $expr->if_false), $env, $kont;
                }
            }
            when ('Cons') {
                if ($expr->tail->is_nil) {
                    return $expr->head, $env, kontinue APPLY => sub ($c, $e) {
                        return $self->apply( $c, $expr->tail, $e, $kont );
                    }
                } else {
                    my $call  = $expr->head;
                    my $first = $expr->tail->head;
                    my $rest  = $expr->tail->tail;
                    my $done  = $alloc->Nil;
                    return $first, $env, kontinue EVAL => sub ($c, $e) {
                        $done = $alloc->Cons( $c, $done );

                        my $depth = 0;
                        1 while caller( ++$depth );
                        say sprintf '   [%02d] ARGS: %s -> %s' => $depth, ::pprint($expr), ::pprint($done);

                        if ($rest->is_nil) {
                            say sprintf '   [%02d]  <- : %s' => $depth, ::pprint($done);
                            return $call, $env, kontinue APPLY => sub ($c, $e) {
                                $done = $alloc->Reverse( $done );
                                say "    ... APPLY: ",::pprint($call)," w/ ".::pprint($done);
                                given (blessed $c) {
                                    when ('Lambda') {
                                        return $c->body, $alloc->CallerEnv( $c, $done ), kontinue LEAVE => sub ($c, $e) {
                                            return $c, $env, $kont;
                                        }
                                    }
                                    when ('BuiltIn') {
                                        return $c->body->( $done->uncons ), $env, $kont;
                                    }
                                    default {
                                        return $alloc->Error("Could not apply (".::pprint($c).")"), $env, $ERROR;
                                    }
                                }
                            }
                        } else {
                            my $next = $rest->head;
                            $rest = $rest->tail;
                            return $next, $e, __SUB__;
                        }
                    }
                }
            }
            when ('Sym') {
                if (my $found = $env->lookup( $expr )) {
                    return $found, $env, $kont;
                }
                return $alloc->Error("Could not find (".::pprint($expr).") in Env"), $env, $ERROR;
            }
            default {
                say sprintf '[%02d]  <- : %s' => $depth, ::pprint($expr);
                return $expr, $env, $kont;
            }
        }
    }
}


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
    'cdr'   => $a->BuiltIn('car'  => sub ($list)  { $list->tail }),
});

my $source = q[
    (defun fact (n)
        (if (== n 0) 1
            (* n (fact (- n 1)))))

    (defun fib (n)
        (if (< n 2) n
            (+ (fib (- n 1)) (fib (- n 2)))))

    (fact (fib 6))
];

my $parsed   = $p->parse($source);
my $compiled = $c->compile( $parsed, $env );
my $evaled   = $i->run( $compiled, $env );
say "GOT: ",pprint($evaled)," in ",$i->steps," steps";

