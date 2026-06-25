
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

class Literal :isa(Term) { field $raw :reader :param; }
class Str  :isa(Literal) {}
class Num  :isa(Literal) {}
class Bool :isa(Literal) {}

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

class Error :isa(Term) {
    field $msg :param :reader;
}

## compiled forms ...

class Lambda :isa(Term) {
    field $params :reader :param;
    field $body   :reader :param;
    field $env    :reader :param;
}

class BuiltIn :isa(Term) {
    field $name :reader :param;
    field $body :reader :param;
}

class Condition :isa(Term) {
    field $condition :reader :param;
    field $if_true   :reader :param;
    field $if_false  :reader :param;
}

# ...

class Env :isa(Term) {
    field $parent   :reader :param = undef;
    field $bindings :reader :param = +{};

    method lookup ($name) {
        $bindings->{ $name->ident }
            // (defined $parent ? $parent->lookup( $name ) : undef)
    }
}

class Allocator {
    method Nil   { state $Nil   = Nil->new }
    method True  { state $True  = Bool->new( raw => true ) }
    method False { state $False = Bool->new( raw => false ) }

    method Sym ($i) { Sym->new( ident => $i ) }
    method Str ($s) { Str->new( raw   => $s ) }
    method Num ($n) { Num->new( raw   => $n ) }

    method Cons ($h, $t=undef) { Cons->new( head => $h, tail => $t // $self->Nil ) }

    method Error ($m) { Error->new( msg => $m ) }

    method Env ($b, $p=undef) { Env->new( bindings => $b, parent => $p ) }

    method Lambda ($p, $b, $e) { Lambda->new( params => $p, body => $b, env => $e ) }

    method BuiltIn ($n, $b) { BuiltIn->new( name => $n, body => $b ) }

    method Condition ($c, $t, $f) { Condition->new( condition => $c, if_true => $t, if_false => $f ) }

    ## -------------------------------------------------------------------------

    method List (@list) {
        my $list = $self->Nil;
        while (@list) {
            $list = $self->Cons( pop @list, $list );
        }
        return $list;
    }

    method Map ($f, $list) {
        $self->List( map { $f->($_) } $list->uncons )
    }

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
        when ('Sym')    { $term->ident }
        when ('Str')    { $term->raw }
        when ('Num')    { $term->raw }
        when ('Bool')   { $term->raw ? '#t' : '#f' }
        when ('Nil')    { '#n' }
        when ('Cons')   { sprintf '(%s)' => join ' ' => map { pprint($_) } $term->uncons }
        when ('Lambda') { sprintf '(<lambda> %s %s)' => pprint($term->params), pprint($term->body) }
        when ('BuiltIn') { sprintf '&<%s>' => $term->name }
        when ('Env')    { '#env' }
        when ('Condition') {
            sprintf '(<if> %s %s %s)' =>
                pprint($term->condition),
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
            when (/[1-9]/) {
                $self->push_stack( $alloc->Num( $self->parse_number( $next ) ) );
            }
            when ('"') {
                $self->push_stack( $alloc->Str( $self->parse_string( $next ) ) );
            }
            when ('-') {
                if ($self->peek =~ /[1-9]/) {
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

    method compile ($expr, $env) {
        given (blessed $expr) {
            when ('Cons') {
                if ($expr->head isa Sym) {
                    given ($expr->head->ident) {
                        when ('lambda') {
                            my ($params, $body) = $expr->tail->uncons;
                            return $alloc->Lambda(
                                $params,
                                $self->compile( $body, $env ),
                                $env
                            )
                        }
                        when ('if') {
                            my ($condition, $if_true, $if_false) = $expr->tail->uncons;
                            return $alloc->Condition(
                                $self->compile( $condition, $env ),
                                $self->compile( $if_true,   $env ),
                                $self->compile( $if_false,  $env ),
                            )
                        }
                    }
                }
                return $alloc->Map(sub ($e) { $self->compile( $e, $env ) }, $expr )
            }
            default {
                return $expr;
            }
        }
    }
}

package Kontinue::HALT  {}
package Kontinue::YIELD {}
package Kontinue::ERROR {}
package Kontinue::APPLY {}
package Kontinue::EARGS {}
package Kontinue::LKUP  {}

class Interpreter {
    field $alloc :reader :param;

    field $halted :reader = false;

    sub kontinue ($name, $f) { bless $f => "Kontinue::${name}" }

    my $HALT  = kontinue HALT  => sub ($c, $e) { return $c, $e, undef };
    my $ERROR = kontinue ERROR => sub ($c, $e) { return $c, $e, undef };

    method run ($expr, $env, $kont=$HALT) {
        until ($halted) {
            ($expr, $env, $kont) = $self->evaluate( $expr, $env, $kont );
            last unless defined $kont;
        }
        return $expr;
    }

    method evaluate ($expr, $env, $kont) {
        say "EVAL: ",::pprint($expr);
        given (blessed $expr) {
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
                    return $first, $env, kontinue EARGS => sub ($c, $e) {
                        $done = $alloc->Cons( $c, $done );
                        if ($rest->is_nil) {
                            return $call, $env, kontinue APPLY => sub ($c, $e) {
                                return $self->apply( $c, $done, $e, $kont );
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
                    return $kont->( $found, $env );
                }
                return $alloc->Error("Could not find (".::pprint($expr).") in Env"), $env, $ERROR;
            }
            default {
                return $kont->( $expr, $env );
            }
        }
    }

    method apply ($call, $args, $env, $kont) {
        say " APPLY: ",::pprint($call)," ".::pprint($args);
        given (blessed $call) {
            when ('Lambda') {
                return $call->body, $alloc->CallerEnv( $call, $args ), $kont
            }
            when ('BuiltIn') {
                return $call->body->( $args->uncons ), $env, $kont;
            }
            default {
                return $alloc->Error("Could not apply (".::pprint($call).")"), $env, $ERROR;
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
});

my $source = q[
    (+ 10 (* 4 5))
];

my ($parsed) = $p->parse($source)->@*;
my $compiled = $c->compile( $parsed, $env );
my $evaled   = $i->run( $compiled, $env );
say "GOT: ",pprint($evaled);


