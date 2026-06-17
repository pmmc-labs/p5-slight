
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use constant DEBUG => $ENV{DEBUG} // 0;
use constant TRACE => $ENV{TRACE} // 0;

use constant LINKING_ENABLED => true;
use constant OPTIMIZE_CALLS  => true;
use constant PRECOMPILE_DEFS => true;

our %ALLOCATIONS = (
    TERMS => +{},
    KONTS => +{},
    MISC  => +{},
);

=pod

# NOTES:

- add Cable (collection of Strands)

- create an EDB
    - (assert! Bob :knows Alice)
    - (query?  @_  :knows Alice)
        - everyone that knows Alice
    - (query?  @_  :knows @_ )
        - every :knows relation
    - (query?  (ne? Bob) :knows Alice)
        - filtering, with a partial sub
    - (query?  @_  :knows (Alice Carol))
        - everyone that knows Alice and Carol
    - (query?  %_  :knows (Alice Carol))
        - two groups, one for Alice, the other for Carol
    - (query? (and ($_ :parent Alice)
                   ($_ :knows Bob)))
        - do any of Alice's parents know Bob?
    - (query? (and ($_ :parent @_)
                   ($_ :knows Bob)))
        - all the parents that know bob

=cut

## -----------------------------------------------------------------------------

class Parser {
    field @stack = (+[]);

    method tokenizer ($source) {
        $source =~ s/\;.*\n//g if $source =~ /\;/;
        grep !/^\s*$/, split /(\'\(|\(|\)|"(?:[^"\\]|\\.)*"|\s)/ => $source;
    }

    method parse ($source) {
        my @tokens = $self->tokenizer($source);
        while (@tokens) {
            my $token = shift @tokens;
            if ($token =~ /^\'[^\(]/) {
                $token =~ s/^\'//;
                push @stack => +[ Sym->new(ident => 'quote' ) ];
                unshift @tokens => ')';
            }
            given ($token) {
                when (/^\"/)   { push $stack[-1]->@*, Str->new( raw => substr($token, 1, -1) ); }
                when (/^\d+$/) { push $stack[-1]->@*, Num->new( raw => $token+0 ); }
                when ('nil')   { push $stack[-1]->@*, Nil->new; }
                when ('true')  { push $stack[-1]->@*, Bool->TRUE; }
                when ('false') { push $stack[-1]->@*, Bool->FALSE; }
                when ('\'(')   { push @stack => +[ Sym->new(ident => 'quote' ) ]; }
                when ('(')     { push @stack => +[]; }
                when (')')     {
                    my $list = pop @stack;
                    push $stack[-1]->@*, (scalar $list->@* > 0)
                        ? Cons->of( $list->@* )
                        : Nil->new;
                }
                default {
                    push $stack[-1]->@*, Sym->new( ident => $token );
                }
            }
        }
        return $stack[-1];
    }
}

## -----------------------------------------------------------------------------

class Term {
    use overload '""' => 'to_string';
    method to_string { ... }
    method is_nil { false }

    ADJUST { $::ALLOCATIONS{TERMS}->{ blessed $self }++ }
}

class Sym :isa(Term) {
    field $ident :param :reader;
    method to_string { $ident }
}

class List :isa(Term) {}

class Nil :isa(List) {
    method to_string { '()' }
    method is_nil { true }
}

class Cons :isa(List) {
    field $head :param :reader;
    field $tail :param :reader;

    sub of ($, @args) {
        my $list = Nil->new;
        $list = Cons->new( head => (pop @args), tail => $list )
            while @args;
        return $list;
    }

    method reverse { Cons->of( reverse $self->uncons ) }

    method uncons {
        my @list;
        my $l = $self;
        until ($l->is_nil) {
            push @list => $l->head;
            $l = $l->tail;
        }
        return @list;
    }

    method to_string { sprintf '(%s)' => join ' ' => map $_->to_string, $self->uncons }
}

class Literal :isa(Term) {}

class Str :isa(Literal) {
    field $raw :param :reader;
    method to_string { $raw }
}

class Num :isa(Literal) {
    field $raw :param :reader;
    method to_string { "${raw}" }
}

class Bool :isa(Literal) {
    field $raw :param :reader;
    sub TRUE  { Bool->new( raw => true ) }
    sub FALSE { Bool->new( raw => false ) }
    method to_string { $raw ? 'true' : 'false' }
}

class Callable :isa(Literal) {
    method is_operative   { ... }
    method is_applicative { ... }
}

class Lambda :isa(Callable) {
    field $params :param :reader;
    field $body   :param :reader;
    field $env    :param :reader;
    field $name   :param :reader = undef;

    method has_name { defined $name }

    method is_operative   { false }
    method is_applicative { true  }

    method to_string { sprintf '(<lambda> %s %s)' => $params->to_string, $body->to_string }
}

class Native :isa(Callable) {
    field $name :param :reader;
    field $proc :param :reader;

    method has_name { defined $name }

    field $is_operative :param :reader = false;
    method is_applicative { !$is_operative }

    method to_string { sprintf '#<%s>' => $name }
}

## -----------------------------------------------------------------------------

class Env {
    field $parent   :param :reader = undef;
    field $bindings :param :reader = +{};

    method lookup ($sym) {
        return $bindings->{ $sym->ident }
            // (defined $parent ? $parent->lookup($sym) : undef);
    }

    method derive (%bindings) {
        return Env->new( parent => $self, bindings => \%bindings )
    }

    method DUMP {
        return () unless defined $parent; # do not DUMP the root
        return $parent->DUMP, %$bindings;
    }

    ADJUST { $::ALLOCATIONS{MISC}->{ blessed $self }++ }
}

## -----------------------------------------------------------------------------

class Kontinue {
    use overload '""' => 'to_string';

    field $kont :param :reader = undef;

    method kontinue ($ctx) { ... }

    method to_string {
        return sprintf '%s!!', __CLASS__ if not defined $kont;
        return sprintf '%s > %s', __CLASS__, $kont->to_string;
    }

    method DEBUG (@args) {
        say '-' x 120;
        say sprintf '=> %-12s : %s' => __CLASS__, $self->kont // '!!';
        say '-' x 120;
        foreach my ($name, $arg) (@args) {
            say sprintf '%15s : %s' =>
                $name,
                (blessed $arg ? $arg->to_string : $arg);
        }
    }

    ADJUST { $::ALLOCATIONS{KONTS}->{ blessed $self }++ }
}

## -----------------------------------------------------------------------------

class Eval::Expr :isa(Kontinue) {
    field $expr :param :reader;

    method kontinue ($ctx) {
        $self->DEBUG(expr => $expr) if ::DEBUG;

        given (blessed $expr) {
            when ('Cons') {
                my $next = Apply::Expr->new( args => $expr->tail, kont => $self->kont );

                my $head;
                if (::LINKING_ENABLED) {
                    $head = $next->kontinue( $ctx, $expr->head )
                        if $expr->head isa Callable;
                }

                if (::OPTIMIZE_CALLS) {
                    if ($expr->head isa Sym) {
                        my $call = $ctx->lookup( $expr->head );
                        return $ctx->throw_error("Unable to find ".$expr->head." in Env", $self)
                            if not defined $call;
                        $head = $next->kontinue( $ctx, $call );
                    }
                }

                if (::LINKING_ENABLED || ::OPTIMIZE_CALLS) {
                    if (defined $head) {
                        return $head->kontinue( $ctx ) if $head isa Eval::Args;
                        return $head;
                    }
                }

                return Eval::Expr->new( expr => $expr->head, kont => $next );
            }
            when ('Sym') {
                my $value = $ctx->lookup($expr);
                return $ctx->throw_error("Unable to find ${expr} in Env", $self)
                    if not defined $value;
                return $ctx->return_value($value, $self->kont);
            }
            default {
                return $ctx->return_value($expr, $self->kont);
            }
        }
    }

    method to_string {
        return sprintf '%s[%s] > %s', __CLASS__, $expr->to_string, $self->kont->to_string;
    }
}

class Apply::Expr :isa(Kontinue) {
    field $args :param :reader;

    method kontinue ($ctx, $call) {
        $self->DEBUG(args => $args, '+call' => $call) if ::DEBUG;

        my $next = Apply::Call->new( call => $call, kont => $self->kont );

        return $ctx->return_value( $args, $next ) if $call->is_operative;

        if (::OPTIMIZE_CALLS) {
            if ($args->is_nil) {
                return $next;
            } elsif ($args->tail->is_nil) {
                return $ctx->return_value( Cons->of( $args->head ), $next )
                    if $args->head isa Literal;
                return Eval::Expr->new( expr => $args->head, kont => $next );
            } else {
                return Eval::Args->new( rest => $args, kont => $next )
            }
        }

        return Eval::Args->new( rest => $args, kont => $next )
    }

    method to_string {
        return sprintf '%s[%s] > %s', __CLASS__, $args->to_string, $self->kont->to_string;
    }
}

class Eval::Args :isa(Kontinue) {
    field $rest :param :reader;
    field $done :param :reader = Nil->new;

    method kontinue ($ctx, $value=undef) {
        $self->DEBUG(rest => $rest, done => $done, '+value' => $value // '?') if ::DEBUG;

        $done = Cons->new( head => $value, tail => $done )
            if defined $value;

        if (::OPTIMIZE_CALLS)  {
            until ($rest->is_nil) {
                last unless $rest->head isa Literal;
                $done = Cons->new( head => $rest->head, tail => $done );
                $rest = $rest->tail;
            }
        }

        # if no more left, return it
        return $ctx->return_value( $done->reverse, $self->kont )
            if $rest->is_nil;

        return Eval::Expr->new(
            expr => $rest->head,
            kont => Eval::Args->new(
                rest => $rest->tail,
                done => $done,
                kont => $self->kont,
            )
        );
    }

    method to_string {
        return sprintf '%s[%s][%s] > %s', __CLASS__, $rest->to_string, $done->to_string, $self->kont->to_string;
    }
}

class Apply::Call :isa(Kontinue) {
    field $call :param :reader;

    method bind_params ($ctx, $call, $args) {
        my %local;

        $local{ $call->name->ident } = $call
            if $call->has_name;

        my $params = $call->params;
        if ($args isa List) {
            until ($params->is_nil) {
                return $ctx->throw_error("Arity Mismatch - missing:${params}", $self)
                    if $args->is_nil;
                $local{ $params->head->ident } = $args->head;
                $params = $params->tail;
                $args   = $args->tail;
            }
            return $ctx->throw_error("Arity Mismatch - additional:${args}", $self)
                unless $args->is_nil;
        } else {
            return $ctx->throw_error("Arity Mismatch - additional:${args}", $self) if $params->is_nil;
            return $ctx->throw_error("Arity Mismatch - missing:${params}",  $self) unless $params->tail->is_nil;
            $local{ $params->head->ident } = $args;
        }

        return $call->env->derive( %local );
    }

    method kontinue ($ctx, $args) {
        $self->DEBUG(call => $call, '+args' => $args) if ::DEBUG;

        given (blessed $call) {
            when ('Native') {
                my @args = $args isa List ? $args->uncons : $args;
                if ($call->is_operative) {
                    return $call->proc->( $ctx, @args );
                } else {
                    return $ctx->return_value( $call->proc->( @args ), $self->kont );
                }
            }
            when ('Lambda') {
                return $ctx->wrap_in_scope(
                    $self->bind_params( $ctx, $call, $args ),
                    $call->body,
                    $self->kont
                )
            }
            default {
                die "Cannot call => ${call}";
            }
        }
    }

    method to_string {
        return sprintf '%s[%s] > %s', __CLASS__, $call->name, $self->kont->to_string;
    }
}

class Scope::Enter :isa(Kontinue) {
    field $env :param :reader;
    method kontinue ($ctx) {
        $self->DEBUG if ::DEBUG;
        $ctx->strand->enter_scope( $env );
        return $self->kont;
    }

    method to_string {
        return sprintf '%s[%s] > %s', __CLASS__, ($env =~ /(0x.*)\)$/), $self->kont->to_string;
    }
}

class Scope::Leave :isa(Kontinue) {
    method kontinue ($ctx, $result) {
        $self->DEBUG('+result' => $result) if ::DEBUG;
        $ctx->strand->leave_scope;
        return $ctx->return_value( $result, $self->kont );
    }
}

class Bind :isa(Kontinue) {
    field $name :param :reader;
    method kontinue ($ctx, $value) {
        $self->DEBUG('name' => $name, '+value' => $value) if ::DEBUG;
        $ctx->define( $name, $value );
        return $ctx->return_value( Nil->new, $self->kont );
    }

    method to_string {
        return sprintf '%s[%s] > %s', __CLASS__, $name->to_string, $self->kont->to_string;
    }
}

class Cond :isa(Kontinue) {
    field $if_true  :param :reader;
    field $if_false :param :reader;

    method kontinue ($ctx, $condition) {
        return Eval::Expr->new(
            expr => ($condition->raw ? $if_true : $if_false),
            kont => $self->kont
        );
    }
}

class Return :isa(Kontinue) {
    field $value :param :reader;

    method kontinue ($ctx) {
        $self->DEBUG('value' => $value) if ::DEBUG;
        return $self->kont;
    }

    method to_string {
        return sprintf '%s[%s] > %s', __CLASS__, $value->to_string, $self->kont->to_string;
    }
}

class Drop :isa(Kontinue) {
    method kontinue ($ctx, $dropped) {
        $self->DEBUG('-dropped' => $dropped) if ::DEBUG;
        return $self->kont;
    }
}

class Yield :isa(Kontinue) {
    method kontinue ($ctx) {
        $self->DEBUG if ::DEBUG;
        return undef;
    }
}

class Error :isa(Kontinue) {
    field $error :param :reader;

    method kontinue ($ctx) {
        $self->DEBUG('error' => $error) if ::DEBUG;
        return undef;
    }
}

class Halt :isa(Kontinue) {
    field $result :reader;

    method kontinue ($ctx, $r) {
        $self->DEBUG('+result' => $r) if ::DEBUG;
        $result = $r;
        return undef;
    }

    method to_string {
        return sprintf '%s!! %s', __CLASS__, defined $result ? $result->to_string : '??';
    }
}

## -----------------------------------------------------------------------------

class Strand::Ref {
    field $strand :param :reader;

    method current_env     { $strand->current_env }
    method lookup ($s)     { $strand->lookup( $s ) }
    method define ($n, $v) { $strand->define( $n, $v ) }

    method wrap_in_scope ($env, $body, $kont) {
        Scope::Enter->new(
            env  => $env,
            kont => Eval::Expr->new(
                expr => $body,
                kont => Scope::Leave->new(
                    kont => $kont
                )
            )
        )
    }

    method bind ($name, $expr, $kont=undef) {
        Eval::Expr->new(
            expr => $expr,
            kont => Bind->new(
                name => $name,
                kont => $kont // $strand->next_kont
            )
        )
    }

    method throw_error ($error, $kont=undef) {
        Error->new( error => $error, kont => $kont // $strand->next_kont )
    }

    method return_value ($value, $kont=undef) {
        Return->new( value => $value, kont => $kont // $strand->next_kont )
    }

    method conditional ($condition, $if_true, $if_false, $kont=undef) {
        Eval::Expr->new(
            expr => $condition,
            kont => Cond->new(
                if_true  => $if_true,
                if_false => $if_false,
                kont     => $kont // $strand->next_kont,
            )
        )
    }

    method yield ($expr, $kont=undef) {
        Yield->new(
            kont => Eval::Expr->new(
                expr => $expr,
                kont => $kont // $strand->next_kont
            )
        )
    }

    ADJUST { $::ALLOCATIONS{MISC}->{ blessed $self }++ }
}

## -----------------------------------------------------------------------------

class Strand {
    field $ref   :reader;
    field $steps :reader;
    field @trace :reader;
    field @envs  :reader;

    ADJUST {
        $ref   = Strand::Ref->new( strand => $self );
        $steps = 0;

        $::ALLOCATIONS{MISC}->{ blessed $self }++;
    }

    ## -------------------------------------------------------------------------

    method enter_scope ($e) { push @envs => [ $e ] }
    method leave_scope      { pop @envs }
    method current_scope    { $envs[-1] }
    method current_env      { $self->current_scope->[-1] }

    method lookup ($sym) {
        $self->current_env->lookup( $sym )
    }

    method define ($name, $value) {
        push $self->current_scope->@* =>
            $self->current_env->derive( $name->ident, $value );
    }

    ## -------------------------------------------------------------------------

    method prev_kont { $trace[-1] }
    method next_kont { $trace[-1]->kont }

    ## -------------------------------------------------------------------------

    method link ($env, $expr) {
        given (blessed $expr) {
            when ('Cons') {
                return Cons->of( map { $self->link( $env, $_ ) } $expr->uncons );
            }
            when ('Sym') {
                return $env->lookup($expr) // $expr;
            }
            default {
                return $expr;
            }
        }
    }

    method kompile ($env, $exprs) {
        my $kont  = Scope::Leave->new( kont => Halt->new );
        my @exprs = ::LINKING_ENABLED ? map { $self->link( $env, $_ ) } @$exprs : @$exprs;

        if (::PRECOMPILE_DEFS) {
            @exprs = map {
                if ($_ isa Cons
                &&  $_->head isa Callable
                &&  $_->head->name eq 'defun') {
                    my ($name, $params, $body) = $_->tail->uncons;
                    $env = $env->derive(
                        $name->ident, Lambda->new(
                            name   => $name,
                            params => $params,
                            body   => $body,
                            env    => $env,
                        )
                    );
                    ();
                } elsif ($_ isa Cons
                    &&  $_->head isa Callable
                    &&  $_->head->name eq 'let') {
                    my ($name, $value) = $_->tail->uncons;
                    if ($value isa Literal) {
                        $env = $env->derive( $name->ident, $value );
                        ();
                    } else {
                        $_;
                    }
                } else {
                    $_;
                }
            } @exprs;
        }

        foreach my $expr (reverse @exprs) {
            $kont = Eval::Expr->new(
                expr => $expr,
                kont => ($kont isa Scope::Leave)
                        ? $kont
                        : Drop->new( kont => $kont ));
        }
        return Scope::Enter->new( env => $env, kont => $kont );
    }

    method run ($kont) {
        while (defined $kont) {
            push @trace => $kont;
            $kont = $self->step($kont);
        }
        return @trace;
    }

    method resume {
        return $self->execute( $self->next_kont ) if $self->prev_kont isa Yield;
        return $self->execute( $self->ref->throw_error(
            "You can only resume from a Yield, not ".$self->prev_kont,
        ));
    }

    method step ($kont) {
        $steps++;
        given (blessed $kont) {
            when ('Return') {
                push @trace => $kont->kont;
                return $kont->kont->kontinue( $self->ref, $kont->value );
            }
            default {
                return $kont->kontinue( $self->ref );
            }
        }
    }
}

## -----------------------------------------------------------------------------

my $env = Env->new(
    bindings => +{
        '+' => Native->new( name => '+', proc => sub ($n, $m) { Num->new( raw => $n->raw + $m->raw ) }),
        '-' => Native->new( name => '-', proc => sub ($n, $m) { Num->new( raw => $n->raw - $m->raw ) }),
        '*' => Native->new( name => '*', proc => sub ($n, $m) { Num->new( raw => $n->raw * $m->raw ) }),
        '/' => Native->new( name => '/', proc => sub ($n, $m) { Num->new( raw => $n->raw / $m->raw ) }),
        '%' => Native->new( name => '%', proc => sub ($n, $m) { Num->new( raw => $n->raw % $m->raw ) }),

        '==' => Native->new( name => '==', proc => sub ($n, $m) { $n->raw == $m->raw ? Bool->TRUE : Bool->FALSE }),
        '!=' => Native->new( name => '!=', proc => sub ($n, $m) { $n->raw != $m->raw ? Bool->TRUE : Bool->FALSE }),
        '<=' => Native->new( name => '<=', proc => sub ($n, $m) { $n->raw <= $m->raw ? Bool->TRUE : Bool->FALSE }),
        '>=' => Native->new( name => '>=', proc => sub ($n, $m) { $n->raw >= $m->raw ? Bool->TRUE : Bool->FALSE }),
        '>'  => Native->new( name => '>',  proc => sub ($n, $m) { $n->raw >  $m->raw ? Bool->TRUE : Bool->FALSE }),
        '<'  => Native->new( name => '<',  proc => sub ($n, $m) { $n->raw <  $m->raw ? Bool->TRUE : Bool->FALSE }),

        'lambda' => Native->new(
            name => 'lambda',
            proc => sub ($ctx, $p, $b) {
                $ctx->return_value(
                    Lambda->new( params => $p, body => $b, env => $ctx->current_env )
                )
            },
            is_operative => true,
        ),

        'if' => Native->new(
            name => 'if',
            proc => sub ($ctx, $condition, $if_true, $if_false) {
                $ctx->conditional( $condition, $if_true, $if_false )
            },
            is_operative => true,
        ),

        'yield' => Native->new(
            name => 'yield',
            proc => sub ($ctx, $expr) { $ctx->yield( $expr ) },
            is_operative => true,
        ),

        'let' => Native->new(
            name => 'let',
            proc => sub ($ctx, $name, $value) { $ctx->bind( $name, $value ) },
            is_operative => true,
        ),

        'defun' => Native->new(
            name => 'defun',
            proc => sub ($ctx, $name, $params, $body) {
                return $ctx->bind(
                    $name,
                    Lambda->new(
                        name   => $name,
                        params => $params,
                        body   => $body,
                        env    => $ctx->current_env,
                    )
                )
            },
            is_operative => true,
        ),
    }
);

my $parser = Parser->new;
my $strand = Strand->new;

#my $PRELUDE = join '' => grep !/^\s*$/, <DATA>;

my $exprs = $parser->parse(q[

(defun fact (n)
    (if (== n 0) 1
        (* n (fact (- n 1)))))

(defun fib (n)
    (if (< n 2) n
        (+ (fib (- n 2)) (fib (- n 1)))))

(fact (fib 6))

]);

say "PARSED:";
say '    - ', $_ foreach @$exprs;

my $compiled = $strand->kompile( $env, $exprs );

say "COMPILED:";
foreach my ($name, $f) ($compiled->env->DUMP) {
    say '    - ', $name, ' := ', $f;
}
say '    + (main)';
say '       ', $compiled;

my @trace = $strand->run( $compiled );
say "STEPS: ", scalar @trace;

if (TRACE) {
    say "TRACE:";
    say join "\n" => @trace;
} else {
    say "GOT:";
    say '    - ', $trace[-1];
}

say "ALLOCATIONS:";
say " +TERMS:";
foreach my $type (sort { $ALLOCATIONS{TERMS}->{$b} <=> $ALLOCATIONS{TERMS}->{$a} } keys $ALLOCATIONS{TERMS}->%*) {
    say sprintf '%16s : %d' => $type, $ALLOCATIONS{TERMS}->{$type};
}
say " +KONTS:";
foreach my $type (sort { $ALLOCATIONS{KONTS}->{$b} <=> $ALLOCATIONS{KONTS}->{$a} } keys $ALLOCATIONS{KONTS}->%*) {
    say sprintf '%16s : %d' => $type, $ALLOCATIONS{KONTS}->{$type};
}
say " +MISC:";
foreach my $type (sort { $ALLOCATIONS{MISC}->{$b} <=> $ALLOCATIONS{MISC}->{$a} } keys $ALLOCATIONS{MISC}->%*) {
    say sprintf '%16s : %d' => $type, $ALLOCATIONS{MISC}->{$type};
}


__DATA__
(let x 6)





















