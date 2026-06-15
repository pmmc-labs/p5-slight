
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];
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
        return $stack[-1]->@*;
    }
}

## -----------------------------------------------------------------------------

class Term {
    use overload '""' => 'to_string';
    method to_string { ... }
    method is_nil { false }
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

    method to_string { sprintf '(lambda %s %s)' => $params->to_string, $body->to_string }
}

class Native :isa(Callable) {
    field $name :param :reader;
    field $proc :param :reader;

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
}

class Eval::Expr :isa(Kontinue) {
    field $expr :param :reader;

    method kontinue ($ctx) {
        $self->DEBUG(expr => $expr);

        given (blessed $expr) {
            when ('Cons') {
                # given (blessed $expr->head)
                #   when Sym      -> resolve it and jump to Apply-Expr
                #   when Callable -> create Apply-Expr and call ->kontinue(Calleble)
                # ...
                return Eval::Expr->new(
                    expr => $expr->head,
                    kont => Apply::Expr->new(
                        args => $expr->tail,
                        kont => $self->kont,
                    )
                )
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
}

class Apply::Expr :isa(Kontinue) {
    field $args :param :reader;

    method kontinue ($ctx, $call) {
        $self->DEBUG(args => $args, '+call' => $call);
        if ($call->is_operative) {
            return $ctx->return_value( $args,
                Apply::Call->new(
                    call => $call,
                    kont => $self->kont,
                )
            );
        } else {
            return Eval::Rest->new(
                rest => $args,
                kont => Apply::Call->new(
                    call => $call,
                    kont => $self->kont,
                )
            )
        }
    }
}

class Eval::Rest :isa(Kontinue) {
    field $rest :param :reader;
    field $done :param :reader = Nil->new;

    method kontinue ($ctx, $evaled=undef) {
        $self->DEBUG(rest => $rest, done => $done, '+evaled' => $evaled // '?');

        $done = Cons->new( head => $evaled, tail => $done )
            if defined $evaled;

        # Literals do not need to be evaled
        # so we can look for any pending ones
        # and put the in done already
        until ($rest->is_nil) {
            last unless $rest->head isa Literal;
            $done = Cons->new( head => $rest->head, tail => $done );
            $rest = $rest->tail;
        }

        return $ctx->return_value( $done->reverse, $self->kont )
            if $rest->is_nil;

        return Eval::Expr->new(
            expr => $rest->head,
            kont => Eval::Rest->new(
                rest => $rest->tail,
                done => $done,
                kont => $self->kont,
            )
        );
    }
}

class Apply::Call :isa(Kontinue) {
    field $call :param :reader;

    method kontinue ($ctx, $args) {
        $self->DEBUG(call => $call, '+args' => $args);

        given (blessed $call) {
            when ('Native') {
                my @args = $args->uncons;
                if ($call->is_operative) {
                    return $call->proc->( $ctx, @args );
                } else {
                    return $ctx->return_value( $call->proc->( @args ), $self->kont );
                }
            }
            when ('Lambda') {
                my %local;

                $local{ $call->name->ident } = $call
                    if $call->has_name;

                my $params = $call->params;
                until ($params->is_nil) {
                    return $ctx->throw_error("Arity Mismatch - missing:${params}", $self)
                        if $args->is_nil;
                    $local{ $params->head->ident } = $args->head;
                    $params = $params->tail;
                    $args   = $args->tail;
                }
                return $ctx->throw_error("Arity Mismatch - additional:${args}", $self)
                    unless $args->is_nil;

                return Scope::Enter->new(
                    env  => $call->env->derive( \%local ),
                    kont => Eval::Expr->new(
                        expr => $call->body,
                        kont => Scope::Leave->new(
                            kont => $self->kont
                        )
                    )
                )
            }
            default {
                die "Cannot call => ${call}";
            }
        }
    }
}

class Scope::Enter :isa(Kontinue) {
    field $env :param :reader;
    method kontinue ($ctx) {
        $self->DEBUG;
        $ctx->enter_scope( $env );
        return $self->kont;
    }
}

class Scope::Leave :isa(Kontinue) {
    method kontinue ($ctx, $result) {
        $self->DEBUG('+result' => $result);
        $ctx->leave_scope;
        return $ctx->return_value( $result, $self->kont );
    }
}

class Bind :isa(Kontinue) {
    field $name :param :reader;
    method kontinue ($ctx, $value) {
        $self->DEBUG('name' => $name, '+value' => $value);
        $ctx->define( $name, $value );
        return $ctx->return_value( $value, $self->kont );
    }
}

class Cond :isa(Kontinue) {
    field $if_true  :param :reader;
    field $if_false :param :reader;

    method kontinue ($ctx, $condition) {
        return Eval::Expr->new(
            expr => ($condition->raw ? $if_true : $if_false),
            kont => $self->kont,
        )
    }
}

class Return :isa(Kontinue) {
    field $value :param :reader;

    method kontinue ($ctx) {
        $self->DEBUG('value' => $value);
        return $value;
    }
}

class Yield :isa(Kontinue) {
    method kontinue ($ctx) {
        $self->DEBUG;
        return undef;
    }
}

class Error :isa(Kontinue) {
    field $error :param :reader;

    method kontinue ($ctx) {
        $self->DEBUG('error' => $error);
        return undef;
    }
}

class Halt :isa(Kontinue) {
    field $result;

    method kontinue ($ctx, $r) {
        $self->DEBUG('+result' => $r);
        $result = $r;
        return undef;
    }
}

## -----------------------------------------------------------------------------

class Strand {
    field $step = 0;
    field @trace;
    field @environments;

    ## -------------------------------------------------------------------------

    method enter_scope ($e) { push @environments => [ $e ] }
    method leave_scope      { pop @environments }
    method current_scope    { $environments[-1] }
    method current_env      { $self->current_scope->[-1] }

    method lookup ($sym) {
        $self->current_env->lookup( $sym )
    }

    method define ($name, $value) {
        push $self->current_scope->@* =>
            $self->current_env->derive( $name->ident, $value );
    }

    ## -------------------------------------------------------------------------

    method bind ($name, $expr, $kont=undef) {
        Eval::Expr->new(
            expr => $expr,
            kont => Bind->new(
                name => $name,
                kont => $kont // $trace[-1]->kont
            )
        )
    }

    method throw_error ($error, $kont=undef) {
        Error->new( error => $error, kont => $kont // $trace[-1]->kont )
    }

    method return_value ($value, $kont=undef) {
        Return->new( value => $value, kont => $kont // $trace[-1]->kont )
    }

    method conditional ($condition, $if_true, $if_false, $kont=undef) {
        Eval::Expr->new(
            expr => $condition,
            kont => Cond->new(
                if_true  => $if_true,
                if_false => $if_false,
                kont     => $kont // $trace[-1]->kont,
            )
        )
    }

    method yield ($expr, $kont=undef) {
        Yield->new(
            kont => Eval::Expr->new(
                expr => $expr,
                kont => $kont // $trace[-1]->kont
            )
        )
    }

    ## -------------------------------------------------------------------------

    method kompile ($env, @exprs) {
        my $expr;
        while (@exprs) {
            return Scope::Enter->new(
                env => $env,
                kont => Eval::Expr->new(
                    expr => $expr,
                    kont => Scope::Leave->new(
                        kont =>
                    )
                )
            )
        }
    }

    ## -------------------------------------------------------------------------

    method run ($env, $expr) {
        $self->execute( $self->kompile($env, $expr) );
    }

    method execute ($kont) {
        while (defined $kont) {
            push @trace => $kont;
            $kont = $self->step($kont);
        }
        return @trace;
    }

    method resume {
        return $self->execute( $trace[-1]->kont ) if $trace[-1] isa Yield;
        return $self->execute( $self->throw_error(
            "You can only resume from a Yield, not ".$trace[-1],
            $trace[-1]
        ));
    }

    method step ($kont) {
        $step++;
        given (blessed $kont) {
            when ('Return') {
                push @trace => $kont->kont;
                return $kont->kont->kontinue( $self, $kont->value );
            }
            default {
                return $kont->kontinue( $self );
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
                my $f = Lambda->new(
                    name   => $name,
                    params => $params,
                    body   => $body,
                    env    => $ctx->current_env,
                );
                $ctx->define( $name, $f );
                return $ctx->return_value( $f );
            },
            is_operative => true,
        ),
    }
);

my $parser = Parser->new;
my $strand = Strand->new;

my @exprs = $parser->parse(q[
    (defun fact (n)
        (if (== n 0) n
            (* n (fact (- n 1)))))

    (fact 6)
]);

say $_ foreach @exprs;

#say join "\n" => $strand->run( $env, $expr );






















